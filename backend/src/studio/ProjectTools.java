package studio;

import static studio.Json.*;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.util.*;

import ghidra.app.util.Option;
import ghidra.app.util.bin.ByteProvider;
import ghidra.app.util.importer.LibrarySearchPathManager;
import ghidra.app.util.importer.MessageLog;
import ghidra.app.util.opinion.*;
import ghidra.formats.gfilesystem.*;
import ghidra.formats.gfilesystem.crypto.*;
import ghidra.formats.gfilesystem.fileinfo.FileAttribute;
import ghidra.formats.gfilesystem.fileinfo.FileAttributes;
import ghidra.framework.data.ConvertFileSystem;
import ghidra.framework.data.DefaultProjectData;
import ghidra.framework.generic.auth.Password;
import ghidra.framework.model.*;
import ghidra.framework.store.ItemCheckoutStatus;
import ghidra.framework.store.local.IndexedLocalFileSystem;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.Program;
import ghidra.util.task.TaskMonitor;

/** Project window extras: other projects, copies and links, the flat table, checkouts, loaders and file systems. */
final class ProjectTools {
	private ProjectTools() {
	}

	// ---------------------------------------------------------------- other projects (read-only views)

	private static final Map<String, DefaultProjectData> VIEWS = new LinkedHashMap<>();

	private static ProjectLocator locator(String gpr) {
		File f = new File(gpr);
		String name = f.getName().replaceAll("\\.gpr$", "");
		return new ProjectLocator(f.getParent(), name);
	}

	private static DefaultProjectData view(String gpr) throws Exception {
		DefaultProjectData data = VIEWS.get(gpr);
		if (data == null) {
			ProjectLocator loc = locator(gpr);
			if (!loc.exists()) {
				throw new IllegalArgumentException("No hay ningún proyecto .gpr en " + gpr);
			}
			data = new DefaultProjectData(loc, true, false);
			VIEWS.put(gpr, data);
		}
		return data;
	}

	private static void rows(DomainFolder folder, List<Map<String, Object>> out, boolean recurse) {
		for (DomainFile f : folder.getFiles()) {
			if (out.size() >= 50000) {
				return;
			}
			Map<String, String> meta = Map.of();
			try {
				meta = f.getMetadata();
			}
			catch (Exception e) {
				// unreadable metadata
			}
			out.add(map("name", f.getName(), "path", f.getPathname(), "folder", folder.getPathname(),
				"type", f.getContentType(), "format", meta.getOrDefault("Executable Format", ""),
				"processor", meta.getOrDefault("Processor", ""), "language", meta.getOrDefault("Language ID", ""),
				"compiler", meta.getOrDefault("Compiler ID", ""), "functions", meta.getOrDefault("# of Functions", ""),
				"md5", meta.getOrDefault("Executable MD5", ""), "modified", f.getLastModifiedTime(),
				"readOnly", f.isReadOnly(), "versioned", f.isVersioned(), "checkedOut", f.isCheckedOut(),
				"hijacked", f.isHijacked(), "link", f.isLink(), "version", f.isVersioned() ? f.getLatestVersion() : 0,
				"changed", f.isChanged()));
		}
		if (recurse) {
			for (DomainFolder sub : folder.getFolders()) {
				rows(sub, out, true);
			}
		}
	}

	/** Every file of another project, opened read-only (View Other Projects). */
	static Map<String, Object> viewProject(String gpr) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		rows(view(gpr).getRootFolder(), out, true);
		return map("gpr", gpr, "files", out);
	}

	static Object closeView(String gpr) {
		DefaultProjectData data = VIEWS.remove(gpr);
		if (data != null) {
			data.close();
		}
		return true;
	}

	static void closeAllViews() {
		for (DefaultProjectData d : VIEWS.values()) {
			d.close();
		}
		VIEWS.clear();
	}

	/** Copies files of the viewed project into the open one. */
	static Object copyFromView(StudioServer server, String gpr, List<String> paths, String destFolder, TaskMonitor monitor)
			throws Exception {
		DomainFolder dest = server.folderFor(destFolder);
		List<String> created = new ArrayList<>();
		for (String path : paths) {
			DomainFile f = view(gpr).getFile(path);
			if (f == null) {
				throw new IllegalArgumentException("No existe " + path);
			}
			created.add(f.copyTo(dest, monitor).getPathname());
		}
		return created;
	}

	// ---------------------------------------------------------------- the open project

	/** Flat table of every file of the project with its metadata (the project window's table view). */
	static List<Map<String, Object>> table(StudioServer server) {
		List<Map<String, Object>> out = new ArrayList<>();
		if (server.projectOrNull() != null) {
			rows(server.projectOrNull().getProjectData().getRootFolder(), out, true);
		}
		return out;
	}

	private static DomainFile file(StudioServer server, String path) {
		DomainFile f = server.projectOrNull() == null ? null : server.projectOrNull().getProjectData().getFile(path);
		if (f == null) {
			throw new IllegalArgumentException("No existe " + path);
		}
		return f;
	}

	private static DomainFolder folder(StudioServer server, String path) {
		DomainFolder f = server.projectOrNull() == null ? null : server.projectOrNull().getProjectData().getFolder(path);
		if (f == null) {
			throw new IllegalArgumentException("No existe " + path);
		}
		return f;
	}

	/** Copies a file or a folder (with everything inside) to another folder of the project. */
	static Object copy(StudioServer server, String path, boolean isFolder, String destFolder, TaskMonitor monitor)
			throws Exception {
		DomainFolder dest = server.folderFor(destFolder);
		if (isFolder) {
			return map("path", folder(server, path).copyTo(dest, monitor).getPathname());
		}
		return map("path", file(server, path).copyTo(dest, monitor).getPathname());
	}

	/** A link to a file or folder (relative or absolute), in another folder. */
	static Object link(StudioServer server, String path, boolean isFolder, String destFolder, boolean relative)
			throws Exception {
		DomainFolder dest = server.folderFor(destFolder);
		DomainFile created = isFolder ? folder(server, path).copyToAsLink(dest, relative)
				: file(server, path).copyToAsLink(dest, relative);
		if (created == null) {
			throw new IllegalStateException("Ese elemento no admite enlaces");
		}
		return map("path", created.getPathname());
	}

	static Object setReadOnly(StudioServer server, String path, boolean on) throws IOException {
		file(server, path).setReadOnly(on);
		return true;
	}

	/** Saves the open program under another name: a copy in the project, which the interface then opens. */
	static Object saveAs(StudioServer server, Session s, String destFolder, String name, TaskMonitor monitor)
			throws Exception {
		if (s.program.canSave()) {
			s.save();
		}
		DomainFolder dest = server.folderFor(destFolder);
		if (dest.getFile(name) != null) {
			throw new IllegalArgumentException("Ya existe " + name);
		}
		DomainFile copy = s.program.getDomainFile().copyTo(dest, monitor);
		if (!copy.getName().equals(name)) {
			copy = copy.setName(name);
		}
		return map("path", copy.getPathname());
	}

	/** Whether the project keeps its files in the indexed layout (long names, many files) or the old one. */
	static Map<String, Object> storage(StudioServer server) {
		Project p = server.projectOrNull();
		if (p == null) {
			throw new IllegalStateException("No hay ningún proyecto abierto");
		}
		File dir = p.getProjectLocator().getProjectDir();
		return map("directory", dir.getAbsolutePath(), "indexed", IndexedLocalFileSystem.isIndexed(new File(dir, "idata").getAbsolutePath()));
	}

	/** Converts a closed project to the indexed layout. */
	static Object convertStorage(String gpr) throws Exception {
		ProjectLocator loc = locator(gpr);
		if (!loc.exists()) {
			throw new IllegalArgumentException("No hay ningún proyecto .gpr en " + gpr);
		}
		StringBuilder log = new StringBuilder();
		ConvertFileSystem.convertProject(loc.getProjectDir(), msg -> log.append(msg).append('\n'));
		return map("log", log.toString(), "indexed", IndexedLocalFileSystem.isIndexed(new File(loc.getProjectDir(), "idata").getAbsolutePath()));
	}

	// ---------------------------------------------------------------- version control extras

	/** Every file of the project that is checked out or hijacked (Find Checkouts). */
	static List<Map<String, Object>> findCheckouts(StudioServer server) throws IOException {
		List<Map<String, Object>> all = table(server);
		List<Map<String, Object>> out = new ArrayList<>();
		for (Map<String, Object> row : all) {
			if (Boolean.TRUE.equals(row.get("checkedOut")) || Boolean.TRUE.equals(row.get("hijacked"))) {
				DomainFile f = file(server, (String) row.get("path"));
				ItemCheckoutStatus status = null;
				try {
					status = f.getCheckoutStatus();
				}
				catch (Exception e) {
					// not connected
				}
				row.put("checkoutVersion", status == null ? 0 : status.getCheckoutVersion());
				row.put("exclusive", f.isCheckedOutExclusive());
				row.put("modifiedSinceCheckout", f.modifiedSinceCheckout());
				out.add(row);
			}
		}
		return out;
	}

	/** Removes the private file that hides a versioned one of the same name (optionally keeping a copy). */
	static Object undoHijack(StudioServer server, String path, boolean keepCopy, TaskMonitor monitor) throws Exception {
		DomainFile f = file(server, path);
		if (!f.isHijacked()) {
			throw new IllegalArgumentException("Ese archivo no tapa a uno versionado");
		}
		String kept = null;
		if (keepCopy) {
			DomainFile copy = f.copyTo(f.getParent(), monitor);
			String name = f.getName() + ".keep";
			for (int i = 1; f.getParent().getFile(name) != null; i++) {
				name = f.getName() + ".keep" + i;
			}
			kept = copy.setName(name).getPathname();
		}
		f.delete();
		return map("kept", kept);
	}

	// ---------------------------------------------------------------- add to program / import selection

	private static List<Option> options(Loader loader, ByteProvider provider, LoadSpec spec, Program program,
			Map<String, String> values) {
		List<Option> options = loader.getDefaultOptions(provider, spec, program, true, false);
		for (Option o : options) {
			String v = values.get(o.getName());
			if (v != null && !o.parseAndSetValueByType(v, program.getAddressFactory())) {
				throw new IllegalArgumentException("Valor inválido para «" + o.getName() + "»: " + v);
			}
		}
		return options;
	}

	/** Loaders that can add this file to the open program, with their options. */
	static List<Map<String, Object>> addToProgramOptions(Session s, String source) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		try (ByteProvider provider = FileSystemService.getInstance().getByteProvider(Importer.fsrl(source), true, TaskMonitor.DUMMY)) {
			for (Map.Entry<Loader, Collection<LoadSpec>> e : LoaderService.getAllSupportedLoadSpecs(provider).entrySet()) {
				Loader loader = e.getKey();
				if (!loader.supportsLoadIntoProgram(s.program) || e.getValue().isEmpty()) {
					continue;
				}
				List<Map<String, Object>> opts = new ArrayList<>();
				for (Option o : loader.getDefaultOptions(provider, e.getValue().iterator().next(), s.program, true, false)) {
					if (o.isHidden()) {
						continue;
					}
					Class<?> c = o.getValueClass();
					opts.add(map("name", o.getName(), "value", o.getValue() == null ? "" : o.getValue().toString(),
						"type", c == Boolean.class ? "bool" : "text", "group", o.getGroup()));
				}
				out.add(map("loader", loader.getName(), "options", opts));
			}
		}
		return out;
	}

	/** Loads a file into the open program (new memory blocks, like File ▸ Add To Program). */
	static Object addToProgram(StudioServer server, Session s, String source, String loaderName, Map<String, String> values,
			TaskMonitor monitor) throws Exception {
		MessageLog log = new MessageLog();
		try (ByteProvider provider = FileSystemService.getInstance().getByteProvider(Importer.fsrl(source), true, monitor)) {
			for (Map.Entry<Loader, Collection<LoadSpec>> e : LoaderService.getAllSupportedLoadSpecs(provider).entrySet()) {
				Loader loader = e.getKey();
				if (!loader.supportsLoadIntoProgram(s.program) || e.getValue().isEmpty()
						|| (loaderName != null && !loaderName.isBlank() && !loader.getName().equals(loaderName))) {
					continue;
				}
				LoadSpec spec = e.getValue().iterator().next();
				List<Option> options = options(loader, provider, spec, s.program, values);
				String problem = loader.validateOptions(provider, spec, options, s.program);
				if (problem != null) {
					throw new IllegalArgumentException(problem);
				}
				int before = s.program.getMemory().getBlocks().length;
				Object consumer = new Object();
				s.edit("Añadir al programa", () -> {
					loader.loadInto(s.program, new Loader.ImporterSettings(provider, provider.getName(),
						server.projectOrNull(), "/", false, spec, options, consumer, log, monitor));
					return true;
				});
				return map("loader", loader.getName(), "blocks", s.program.getMemory().getBlocks().length - before,
					"log", log.toString());
			}
		}
		throw new IllegalArgumentException("Ningún cargador puede añadir ese archivo a este programa");
	}

	/** Makes a new program of the project out of bytes of the open one (Import Selection). */
	static Object importSelection(StudioServer server, Session s, AddressSet set, String folder, String name) throws Exception {
		if (set.isEmpty()) {
			throw new IllegalArgumentException("No hay nada seleccionado");
		}
		File tmp = File.createTempFile("studio-selection", ".bin");
		try {
			java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
			for (AddressRange r : set) {
				byte[] b = new byte[(int) Math.min(r.getLength(), 256L << 20)];
				s.program.getMemory().getBytes(r.getMinAddress(), b);
				bytes.write(b);
			}
			Files.write(tmp.toPath(), bytes.toByteArray());
			Map<String, String> args = new LinkedHashMap<>();
			args.put("-baseAddr", "0x" + set.getMinAddress().toString(false));
			List<String> paths = Importer.importSource(server, tmp.getAbsolutePath(), folder, name, "Raw Binary",
				s.program.getLanguageID().getIdAsString(), s.program.getCompilerSpec().getCompilerSpecID().getIdAsString(), args);
			return map("path", paths.get(0), "bytes", bytes.size());
		}
		finally {
			tmp.delete();
		}
	}

	// ---------------------------------------------------------------- library search paths

	static List<String> libraryPaths() {
		return Arrays.asList(LibrarySearchPathManager.getLibraryPaths());
	}

	/** Replaces the ordered list of places where libraries are looked for; an empty list restores the defaults. */
	static List<String> setLibraryPaths(List<String> paths) {
		if (paths.isEmpty()) {
			LibrarySearchPathManager.reset();
		}
		else {
			LibrarySearchPathManager.setLibraryPaths(paths.toArray(new String[0]));
		}
		return libraryPaths();
	}

	// ---------------------------------------------------------------- file system browser

	private static final List<char[]> PASSWORDS = new ArrayList<>();
	private static boolean providerInstalled;

	/** Passwords to try on encrypted containers (zip, 7z…); they are tried in order. */
	static synchronized Object setPasswords(List<String> passwords) {
		PASSWORDS.clear();
		for (String p : passwords) {
			PASSWORDS.add(p.toCharArray());
		}
		if (!providerInstalled) {
			CryptoProviders.getInstance().registerCryptoProvider(new PasswordProvider() {
				@Override
				public Iterator<Password> getPasswordsFor(FSRL fsrl, String prompt, CryptoProvider.Session session) {
					List<Password> list = new ArrayList<>();
					synchronized (ProjectTools.class) {
						for (char[] p : PASSWORDS) {
							list.add(Password.copyOf(p));
						}
					}
					return list.iterator();
				}
			});
			providerInstalled = true;
		}
		return PASSWORDS.size();
	}

	static List<Map<String, Object>> mounted() {
		List<Map<String, Object>> out = new ArrayList<>();
		for (FSRLRoot root : FileSystemService.getInstance().getMountedFilesystems()) {
			out.add(map("fsrl", root.toString(), "type", root.getProtocol(),
				"container", root.getContainer() == null ? "" : root.getContainer().getName()));
		}
		return out;
	}

	static Object closeUnused() {
		FileSystemService.getInstance().closeUnusedFileSystems();
		return mounted();
	}

	/** Everything the file system knows about a file (size, dates, compression, comments…). */
	static List<Map<String, Object>> fileInfo(String source) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		FSRL fsrl = Importer.fsrl(source);
		try (RefdFile ref = FileSystemService.getInstance().getRefdFile(fsrl, TaskMonitor.DUMMY)) {
			out.add(map("name", "FSRL", "value", fsrl.toString()));
			out.add(map("name", "File system", "value", ref.file.getFilesystem().getType()));
			FileAttributes attrs = ref.file.getFilesystem().getFileAttributes(ref.file, TaskMonitor.DUMMY);
			if (attrs != null) {
				for (FileAttribute<?> a : attrs.getAttributes()) {
					out.add(map("name", a.getAttributeDisplayName(), "value", String.valueOf(a.getAttributeValue())));
				}
			}
		}
		return out;
	}

	/** The first bytes of a file inside a container, to show it as text or as an image. */
	static Map<String, Object> readFile(String source, int max) throws Exception {
		FSRL fsrl = Importer.fsrl(source);
		try (ByteProvider provider = FileSystemService.getInstance().getByteProvider(fsrl, false, TaskMonitor.DUMMY)) {
			int n = (int) Math.min(provider.length(), Math.max(1, max));
			byte[] data = provider.readBytes(0, n);
			return map("name", fsrl.getName(), "length", provider.length(), "base64", Base64.getEncoder().encodeToString(data));
		}
	}

	/** Writes a file (or everything under a folder) of a container to disk. */
	static Object extract(String source, String output, TaskMonitor monitor) throws Exception {
		FSRL fsrl = Importer.fsrl(source);
		int[] count = { 0 };
		try (RefdFile ref = FileSystemService.getInstance().getRefdFile(fsrl, monitor)) {
			extract(ref.file, new File(output), count, monitor);
		}
		return map("files", count[0], "path", output);
	}

	private static void extract(GFile file, File target, int[] count, TaskMonitor monitor) throws Exception {
		monitor.checkCancelled();
		if (file.isDirectory()) {
			target.mkdirs();
			for (GFile child : file.getListing()) {
				extract(child, new File(target, child.getName()), count, monitor);
			}
			return;
		}
		monitor.setMessage(file.getName());
		if (target.getParentFile() != null) {
			target.getParentFile().mkdirs();
		}
		try (InputStream in = file.getFilesystem().getInputStream(file, monitor)) {
			if (in != null) {
				Files.copy(in, target.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
				count[0]++;
			}
		}
	}
}
