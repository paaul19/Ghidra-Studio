package studio;

import static studio.Json.*;

import java.io.File;
import java.io.InputStream;
import java.io.PrintWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.TimeUnit;

import ghidra.app.util.bin.ByteProvider;
import ghidra.app.util.importer.MessageLog;
import ghidra.app.util.importer.ProgramLoader;
import ghidra.app.util.opinion.*;
import ghidra.file.crypto.CryptoKey;
import ghidra.file.crypto.CryptoKeyFactory;
import ghidra.file.formats.android.dex.DexToJarFileSystem;
import ghidra.file.formats.android.xml.AndroidXmlFileSystem;
import ghidra.formats.gfilesystem.*;
import ghidra.framework.model.DomainFolder;
import ghidra.framework.model.ProjectDataUtils;
import ghidra.plugins.importer.batch.*;
import ghidra.plugins.importer.tasks.ImportBatchTask;
import ghidra.program.model.lang.LanguageCompilerSpecPair;
import ghidra.program.model.listing.Program;
import ghidra.program.util.DefaultLanguageService;
import ghidra.program.util.GhidraProgramUtilities;
import ghidra.util.NumericUtilities;
import ghidra.util.task.TaskMonitor;

/**
 * The rest of the importer: batch import with its options, and the actions the classic file-system
 * browser adds for particular formats (crypto key templates, iOS kernels, decompiling JARs, Eclipse projects).
 */
final class ImportExtras {
	private ImportExtras() {
	}

	// ---------------------------------------------------------------- batch import

	private static final Map<String, BatchInfo> BATCHES = new LinkedHashMap<>();

	private static BatchInfo batch(String id) {
		BatchInfo info = BATCHES.get(id);
		if (info == null) {
			throw new IllegalArgumentException("La importación por lotes ya no existe: " + id);
		}
		return info;
	}

	private static String specName(BatchGroupLoadSpec spec) {
		return spec == null || spec.lcsPair == null ? "" : spec.lcsPair.languageID + " · " + spec.lcsPair.compilerSpecID;
	}

	private static Map<String, Object> describe(String id, BatchInfo info) {
		List<Map<String, Object>> groups = new ArrayList<>();
		int index = 0;
		for (BatchGroup g : info.getGroups()) {
			List<String> specs = new ArrayList<>();
			for (BatchGroupLoadSpec spec : g.getCriteria().getBatchGroupLoadSpecs()) {
				specs.add(specName(spec));
			}
			List<String> files = new ArrayList<>();
			for (BatchGroup.BatchLoadConfig c : g.getBatchLoadConfig()) {
				if (files.size() >= 200) {
					break;
				}
				files.add(c.getFSRL().toPrettyFullpathString());
			}
			groups.add(map("index", index++, "loader", g.getCriteria().getLoader(), "extension",
				g.getCriteria().getFileExt(), "count", g.size(), "specs", specs, "selected",
				specName(g.getSelectedBatchGroupLoadSpec()), "enabled", g.isEnabled(), "files", files));
		}
		List<Map<String, Object>> sources = new ArrayList<>();
		for (UserAddedSourceInfo u : info.getUserAddedSources()) {
			sources.add(map("path", u.getFSRL().toPrettyFullpathString(), "fsrl", u.getFSRL().toString(), "files",
				u.getFileCount(), "raw", u.getRawFileCount(), "containers", u.getContainerCount(), "depth",
				u.getMaxNestLevel(), "truncated", u.wasRecurseTerminatedEarly()));
		}
		return map("id", id, "groups", groups, "sources", sources, "total", info.getTotalCount(), "enabled",
			info.getEnabledCount(), "depth", info.getMaxDepth(), "truncated", info.wasRecurseTerminatedEarly());
	}

	/** Scans files, folders and containers (recursively, up to a depth) and groups what can be imported. */
	static Map<String, Object> batchScan(String id, List<String> sources, int depth, TaskMonitor monitor) throws Exception {
		BatchInfo info = id == null || id.isEmpty() ? null : BATCHES.get(id);
		if (info == null) {
			id = UUID.randomUUID().toString();
			info = new BatchInfo(depth);
			BATCHES.put(id, info);
		}
		else if (info.getMaxDepth() != depth) {
			// a new depth means scanning the same sources again
			List<FSRL> again = new ArrayList<>();
			for (UserAddedSourceInfo u : info.getUserAddedSources()) {
				again.add(u.getFSRL());
			}
			info = new BatchInfo(depth);
			BATCHES.put(id, info);
			for (FSRL f : again) {
				info.addFile(f, monitor);
			}
		}
		for (String source : sources) {
			info.addFile(Importer.fsrl(source), monitor);
		}
		return describe(id, info);
	}

	static Object batchRemove(String id, String fsrl) throws Exception {
		BatchInfo info = batch(id);
		info.remove(FSRL.fromString(fsrl));
		return describe(id, info);
	}

	static Object batchClose(String id) {
		BATCHES.remove(id);
		return true;
	}

	/** The project path the classic gives to an imported file, from the same rules (strip leading / container paths). */
	static String batchPath(FSRL file, FSRL userSource, boolean stripLeading, boolean stripContainers) throws Exception {
		Method m = ImportBatchTask.class.getDeclaredMethod("fsrlToPath", FSRL.class, FSRL.class, boolean.class,
			boolean.class);
		m.setAccessible(true);
		return (String) m.invoke(null, file, userSource, stripLeading, stripContainers);
	}

	/**
	 * Imports every enabled group. {@code choices} maps a group index to "off" or to the language · compiler
	 * to use for it.
	 */
	static Map<String, Object> batchImport(StudioServer server, String id, String folder, Map<String, String> choices,
			boolean stripLeading, boolean stripContainers, boolean mirror, TaskMonitor monitor) throws Exception {
		BatchInfo info = batch(id);
		int index = 0;
		for (BatchGroup g : info.getGroups()) {
			String choice = choices.get(String.valueOf(index++));
			if (choice == null) {
				continue;
			}
			if (choice.equals("off")) {
				g.setEnabled(false);
				continue;
			}
			for (BatchGroupLoadSpec spec : g.getCriteria().getBatchGroupLoadSpecs()) {
				if (specName(spec).equals(choice)) {
					g.setSelectedBatchGroupLoadSpec(spec);
					g.setEnabled(true);
				}
			}
		}
		String root = folder == null || folder.isBlank() ? "/" : folder;
		List<String> imported = new ArrayList<>();
		List<String> errors = new ArrayList<>();
		monitor.initialize(info.getEnabledCount());
		for (BatchGroup g : info.getGroups()) {
			BatchGroupLoadSpec chosen = g.getSelectedBatchGroupLoadSpec();
			if (!g.isEnabled() || chosen == null) {
				continue;
			}
			for (BatchGroup.BatchLoadConfig config : g.getBatchLoadConfig()) {
				monitor.checkCancelled();
				monitor.setMessage(config.getFSRL().getName());
				try {
					LoadSpec spec = config.getLoadSpec(chosen);
					if (spec == null) {
						throw new IllegalArgumentException("sin especificación de carga para " + specName(chosen));
					}
					String path = batchPath(config.getFSRL(), config.getUasi().getFSRL(), stripLeading, stripContainers);
					int slash = path.lastIndexOf('/');
					String sub = slash > 0 ? path.substring(0, slash) : "";
					String name = slash >= 0 ? path.substring(slash + 1) : path;
					String dest = (root.endsWith("/") ? root.substring(0, root.length() - 1) : root)
						+ (sub.startsWith("/") || sub.isEmpty() ? sub : "/" + sub);
					LanguageCompilerSpecPair pair = spec.getLanguageCompilerSpec();
					ProgramLoader.Builder b = ProgramLoader.builder()
							.source(config.getFSRL())
							.project(server.project().getProject())
							.projectFolderPath(dest.isEmpty() ? "/" : dest)
							.name(name)
							.mirror(mirror)
							.loaders(config.getLoader().getClass())
							.log(new MessageLog())
							.monitor(monitor);
					if (pair != null) {
						b = b.language(pair.languageID).compiler(pair.compilerSpecID);
					}
					try (LoadResults<Program> results = b.load()) {
						results.save(monitor);
						imported.add(results.getPrimary().getSavedDomainFile().getPathname());
					}
				}
				catch (ghidra.util.exception.CancelledException e) {
					throw e;
				}
				catch (Exception e) {
					errors.add(config.getFSRL().getName() + ": " + (e.getMessage() == null ? e.toString() : e.getMessage()));
				}
				monitor.incrementProgress(1);
			}
		}
		BATCHES.remove(id);
		return map("imported", imported, "errors", errors);
	}

	// ---------------------------------------------------------------- crypto keys

	private static File keysDir(StudioServer server) {
		File dir = new File(server.supportDir(), "crypto");
		dir.mkdirs();
		return dir;
	}

	/**
	 * Ghidra only reads key files from inside its installation; Studio keeps the user's ones in its support
	 * folder and hands them to Ghidra's key table.
	 */
	@SuppressWarnings("unchecked")
	static int loadKeys(StudioServer server) {
		int loaded = 0;
		try {
			Field f = CryptoKeyFactory.class.getDeclaredField("cryptoMap");
			f.setAccessible(true);
			Map<String, Map<String, CryptoKey>> table = (Map<String, Map<String, CryptoKey>>) f.get(null);
			File[] files = keysDir(server).listFiles((d, n) -> n.endsWith(".xml"));
			if (files == null) {
				return 0;
			}
			for (File file : files) {
				org.jdom2.Document doc = ghidra.util.xml.XmlUtilities.readDocFromFile(file);
				org.jdom2.Element rootElement = doc.getRootElement();
				String firmware = rootElement.getAttributeValue("NAME");
				Map<String, CryptoKey> keys = new HashMap<>();
				for (Object o : rootElement.getChildren()) {
					org.jdom2.Element e = (org.jdom2.Element) o;
					String path = e.getAttributeValue("PATH");
					if (e.getAttribute("not_encrypted") != null) {
						keys.put(path, CryptoKey.NOT_ENCRYPTED_KEY);
						continue;
					}
					String key = e.getChildTextTrim("KEY");
					String iv = e.getChildTextTrim("IV");
					if (key == null || key.isEmpty() || key.length() % 2 != 0 || iv == null || iv.length() % 2 != 0) {
						continue;
					}
					keys.put(path, new CryptoKey(NumericUtilities.convertStringToBytes(key),
						NumericUtilities.convertStringToBytes(iv)));
					loaded++;
				}
				table.put(firmware, keys);
			}
		}
		catch (Exception e) {
			// a broken key file must not stop the browser
		}
		return loaded;
	}

	static List<Map<String, Object>> keyFiles(StudioServer server) {
		List<Map<String, Object>> out = new ArrayList<>();
		File[] files = keysDir(server).listFiles((d, n) -> n.endsWith(".xml"));
		if (files != null) {
			Arrays.sort(files);
			for (File f : files) {
				out.add(map("name", f.getName(), "path", f.getPath(), "size", f.length()));
			}
		}
		return out;
	}

	private static void collect(GFile dir, GFileSystem fs, List<String> names, TaskMonitor monitor) throws Exception {
		for (GFile f : fs.getListing(dir)) {
			monitor.checkCancelled();
			if (f.isDirectory()) {
				collect(f, fs, names, monitor);
			}
			else {
				names.add(f.getName());
			}
		}
	}

	/** Writes the key file template for a container: one entry per file, with empty KEY and IV. */
	static Map<String, Object> keyTemplate(StudioServer server, String source, boolean overwrite, TaskMonitor monitor)
			throws Exception {
		FSRL fsrl = Importer.fsrl(source);
		File file = new File(keysDir(server), fsrl.getName() + ".xml");
		if (file.exists() && !overwrite) {
			return map("path", file.getPath(), "exists", true, "entries", 0);
		}
		List<String> names = new ArrayList<>();
		try (GFileSystem fs = FileSystemService.getInstance().openFileSystemContainer(fsrl, monitor)) {
			if (fs == null) {
				throw new IllegalArgumentException("No es un contenedor: " + fsrl.getName());
			}
			collect(null, fs, names, monitor);
		}
		try (PrintWriter w = new PrintWriter(file, StandardCharsets.UTF_8)) {
			w.println("<FIRMWARE NAME=\"" + xml(fsrl.getName()) + "\">");
			for (String n : names) {
				w.println("    <FILE PATH=\"" + xml(n) + "\">");
				w.println("        <KEY></KEY>");
				w.println("        <IV></IV>");
				w.println("    </FILE>");
			}
			w.println("</FIRMWARE>");
		}
		return map("path", file.getPath(), "exists", false, "entries", names.size());
	}

	private static String xml(String s) {
		return s.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;");
	}

	// ---------------------------------------------------------------- iOS kernel

	private static void kexts(GFile dir, GFileSystem fs, List<GFile> out, TaskMonitor monitor) throws Exception {
		GFileSystemProgramProvider provider = (GFileSystemProgramProvider) fs;
		for (GFile f : fs.getListing(dir)) {
			monitor.checkCancelled();
			if (f.isDirectory() && !provider.canProvideProgram(f)) {
				kexts(f, fs, out, monitor);
			}
			else if (f.getLength() != 0 && f.getName().endsWith(".kext")) {
				out.add(f);
			}
		}
	}

	/** Loads a prelinked kernel: every KEXT of the container becomes a program of the project. */
	static Map<String, Object> loadKernel(StudioServer server, String source, String folder, TaskMonitor monitor)
			throws Exception {
		FSRL fsrl = Importer.fsrl(source);
		List<String> imported = new ArrayList<>();
		List<String> errors = new ArrayList<>();
		Object consumer = new Object();
		try (GFileSystem fs = FileSystemService.getInstance().openFileSystemContainer(fsrl, monitor)) {
			if (!(fs instanceof GFileSystemProgramProvider provider)) {
				throw new IllegalArgumentException(
					"No es un kernel de iOS con extensiones enlazadas (prelinked): " + fsrl.getName());
			}
			List<GFile> files = new ArrayList<>();
			kexts(null, fs, files, monitor);
			if (files.isEmpty()) {
				throw new IllegalArgumentException("El contenedor no tiene extensiones del kernel (.kext)");
			}
			monitor.initialize(files.size());
			DomainFolder rootFolder = server.project().getProject().getProjectData().getFolder(
				folder == null || folder.isBlank() ? "/" : folder);
			if (rootFolder == null) {
				throw new IllegalArgumentException("No existe la carpeta " + folder);
			}
			for (GFile f : files) {
				monitor.checkCancelled();
				monitor.setMessage(f.getName());
				Program program = null;
				try {
					program = provider.getProgram(f, DefaultLanguageService.getLanguageService(), monitor, consumer);
					if (program != null) {
						DomainFolder dest = ProjectDataUtils.createDomainFolderPath(rootFolder,
							f.getParentFile() == null ? "/" : f.getParentFile().getPath());
						String name = ProjectDataUtils.getUniqueName(dest, program.getName());
						GhidraProgramUtilities.markProgramAnalyzed(program);
						imported.add(dest.createFile(name, program, monitor).getPathname());
					}
				}
				catch (ghidra.util.exception.CancelledException e) {
					throw e;
				}
				catch (Exception e) {
					errors.add(f.getName() + ": " + e.getMessage());
				}
				finally {
					if (program != null) {
						program.release(consumer);
					}
				}
				monitor.incrementProgress(1);
			}
		}
		return map("imported", imported, "errors", errors);
	}

	// ---------------------------------------------------------------- Java decompiler (JAD or a decompiler jar)

	private static void checkTool(String tool) {
		if (tool == null || tool.isBlank() || !new File(tool).isFile()) {
			throw new IllegalArgumentException(
				"Hace falta un descompilador de Java: elige el ejecutable de JAD o el .jar de CFR");
		}
	}

	/** Runs the decompiler over the .class files of one folder; sources are written next to them. */
	private static void decompileFolder(String tool, File dir, File outputRoot, List<String> log, TaskMonitor monitor)
			throws Exception {
		File[] classes = dir.listFiles((d, n) -> n.endsWith(".class"));
		if (classes == null || classes.length == 0) {
			return;
		}
		List<String> cmd = new ArrayList<>();
		if (tool.toLowerCase().endsWith(".jar")) {
			cmd.add(System.getProperty("java.home") + "/bin/java");
			cmd.add("-jar");
			cmd.add(tool);
			for (File c : classes) {
				cmd.add(c.getAbsolutePath());
			}
			cmd.add("--outputdir");
			cmd.add(outputRoot.getAbsolutePath());
		}
		else {
			// the same switches the classic passes to JAD
			cmd.addAll(List.of(tool, "-dead", "-ff", "-nonlb", "-o", "-radix16", "-sjava", "-space", "-t"));
			for (File c : classes) {
				cmd.add(c.getAbsolutePath());
			}
		}
		monitor.setMessage(dir.getName());
		Process process = new ProcessBuilder(cmd).directory(dir).redirectErrorStream(true).start();
		String output;
		try (InputStream in = process.getInputStream()) {
			output = new String(in.readAllBytes(), StandardCharsets.UTF_8);
		}
		if (!process.waitFor(120, TimeUnit.SECONDS)) {
			process.destroyForcibly();
			log.add(dir.getName() + ": se agotó el tiempo");
		}
		else if (process.exitValue() != 0) {
			String first = output.strip().lines().findFirst().orElse("");
			log.add(dir.getName() + ": salida " + process.exitValue() + (first.isEmpty() ? "" : " · " + first));
		}
	}

	private static void decompileTree(String tool, File dir, File outputRoot, List<String> log, TaskMonitor monitor)
			throws Exception {
		monitor.checkCancelled();
		decompileFolder(tool, dir, outputRoot, log, monitor);
		File[] children = dir.listFiles(File::isDirectory);
		if (children != null) {
			for (File c : children) {
				decompileTree(tool, c, outputRoot, log, monitor);
			}
		}
	}

	private static int countSources(File dir) {
		int n = 0;
		File[] children = dir.listFiles();
		if (children != null) {
			for (File c : children) {
				n += c.isDirectory() ? countSources(c) : c.getName().endsWith(".java") ? 1 : 0;
			}
		}
		return n;
	}

	private static void unpack(FSRL container, File output, TaskMonitor monitor) throws Exception {
		try (GFileSystem fs = FileSystemService.getInstance().openFileSystemContainer(container, monitor)) {
			if (fs == null) {
				throw new IllegalArgumentException("No es un archivo JAR: " + container.getName());
			}
			for (GFile file : fs) {
				monitor.checkCancelled();
				File target = new File(output.getAbsolutePath(), file.getPath());
				if (!target.getCanonicalPath().startsWith(output.getCanonicalPath())) {
					throw new java.io.IOException("El archivo saldría de la carpeta de destino: " + file.getPath());
				}
				if (file.isDirectory()) {
					target.mkdirs();
					continue;
				}
				target.getParentFile().mkdirs();
				try (ByteProvider bp = fs.getByteProvider(file, monitor)) {
					FSUtilities.copyByteProviderToFile(bp, target, monitor);
				}
			}
		}
	}

	/** Unpacks a JAR and decompiles its classes (the classic's Decompile JAR, with a decompiler of your choice). */
	static Map<String, Object> decompileJar(String source, String output, String tool, TaskMonitor monitor)
			throws Exception {
		checkTool(tool);
		File out = new File(output);
		out.mkdirs();
		List<String> log = new ArrayList<>();
		unpack(Importer.fsrl(source), out, monitor);
		decompileTree(tool, out, out, log, monitor);
		return map("path", out.getPath(), "sources", countSources(out), "log", log);
	}

	// ---------------------------------------------------------------- Eclipse project from an APK

	private static void copy(InputStream in, File target) throws Exception {
		target.getParentFile().mkdirs();
		try (InputStream is = in) {
			Files.copy(is, target.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
		}
	}

	private static void exportListing(File outDir, File srcDir, GFileSystem fs, List<GFile> listing, String tool,
			List<String> log, TaskMonitor monitor) throws Exception {
		FileSystemService svc = FileSystemService.getInstance();
		for (GFile child : listing) {
			monitor.checkCancelled();
			String name = child.getName();
			File target = new File(outDir, name);
			if (!target.getCanonicalPath().startsWith(outDir.getCanonicalPath())) {
				continue;
			}
			if (child.isDirectory()) {
				if (name.equals("META-INF")) {
					continue;
				}
				target.mkdirs();
				exportListing(target, srcDir, fs, child.getListing(), tool, log, monitor);
				continue;
			}
			monitor.setMessage(name);
			try (ByteProvider bp = fs.getByteProvider(child, monitor)) {
				if (name.endsWith(".xml") && AndroidXmlFileSystem.isAndroidXmlFile(bp, monitor)) {
					try (AndroidXmlFileSystem xml = svc.mountSpecificFileSystem(child.getFSRL(), AndroidXmlFileSystem.class,
						monitor)) {
						copy(xml.getInputStream(xml.getPayloadFile(), monitor), target);
					}
				}
				else if (name.endsWith("classes.dex")) {
					try (DexToJarFileSystem dex = svc.mountSpecificFileSystem(child.getFSRL(), DexToJarFileSystem.class,
						monitor)) {
						unpack(dex.getJarFile().getFSRL(), srcDir, monitor);
						if (tool != null && !tool.isBlank()) {
							decompileTree(tool, srcDir, srcDir, log, monitor);
						}
					}
				}
				else {
					copy(bp.getInputStream(0), target);
					if (name.endsWith(".class") && tool != null && !tool.isBlank()) {
						decompileFolder(tool, outDir, outDir, log, monitor);
					}
				}
			}
			catch (ghidra.util.exception.CancelledException e) {
				throw e;
			}
			catch (Exception e) {
				log.add(child.getPath() + ": " + e.getMessage());
			}
		}
	}

	/**
	 * Exports an APK as an Eclipse project: resources and manifest decoded, classes.dex converted to classes,
	 * and decompiled when a Java decompiler is given.
	 */
	static Map<String, Object> eclipseProject(String source, String output, String tool, TaskMonitor monitor)
			throws Exception {
		if (tool != null && !tool.isBlank()) {
			checkTool(tool);
		}
		FSRL fsrl = Importer.fsrl(source);
		File out = new File(output);
		File src = new File(out, "src");
		src.mkdirs();
		new File(out, "gen").mkdirs();
		new File(out, "asset").mkdirs();
		List<String> log = new ArrayList<>();
		try (GFileSystem fs = FileSystemService.getInstance().openFileSystemContainer(fsrl, monitor)) {
			if (fs == null) {
				throw new IllegalArgumentException("No es un APK: " + fsrl.getName());
			}
			exportListing(out, src, fs, fs.getListing(null), tool, log, monitor);
		}
		generic.jar.ResourceFile templates = ghidra.framework.Application.getModuleDataSubDirectory("FileFormats", "android");
		try (InputStream in = new generic.jar.ResourceFile(templates, "eclipse-classpath").getInputStream()) {
			copy(in, new File(out, ".classpath"));
		}
		String project;
		try (InputStream in = new generic.jar.ResourceFile(templates, "eclipse-project").getInputStream()) {
			project = new String(in.readAllBytes(), StandardCharsets.UTF_8);
		}
		project = project.replaceFirst("<name>[^<]*</name>", "<name>" + xml(fsrl.getName()) + "</name>");
		Files.writeString(new File(out, ".project").toPath(), project);
		return map("path", out.getPath(), "sources", countSources(out), "log", log);
	}
}
