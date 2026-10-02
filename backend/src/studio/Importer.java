package studio;

import static studio.Json.*;

import java.io.File;
import java.util.*;

import ghidra.app.util.Option;
import ghidra.app.util.bin.ByteProvider;
import ghidra.app.util.importer.MessageLog;
import ghidra.app.util.importer.ProgramLoader;
import ghidra.app.util.opinion.*;
import ghidra.formats.gfilesystem.*;
import ghidra.framework.model.DomainFile;
import ghidra.program.model.lang.LanguageCompilerSpecPair;
import ghidra.program.model.listing.Program;
import ghidra.util.task.TaskMonitor;

/** Importing with Ghidra's ProgramLoader: containers (file systems), loader options, libraries. */
final class Importer {
	private Importer() {
	}

	/** A local path or an FSRL string ("file:///…|zip:///…"). */
	static FSRL fsrl(String source) throws Exception {
		if (source.startsWith("file://")) {
			return FSRL.fromString(source);
		}
		return FileSystemService.getInstance().getLocalFSRL(new File(source));
	}

	/** Lists the contents of a container (zip, firmware, disk image, dyld cache…) or a folder inside one. */
	static Map<String, Object> list(String source) throws Exception {
		FileSystemService svc = FileSystemService.getInstance();
		FSRL fsrl = fsrl(source);
		List<GFile> listing = null;
		String fsType = null;
		try (RefdFile ref = svc.getRefdFile(fsrl, TaskMonitor.DUMMY)) {
			if (ref.file.isDirectory()) {
				listing = ref.file.getListing();
				fsType = ref.file.getFilesystem().getType();
			}
		}
		if (listing == null) {
			GFileSystem fs = svc.openFileSystemContainer(fsrl, TaskMonitor.DUMMY);
			if (fs == null) {
				return map("container", false, "entries", List.of(), "type", null);
			}
			listing = fs.getListing(null);
			fsType = fs.getType() + " · " + fs.getDescription();
		}
		List<Map<String, Object>> entries = new ArrayList<>();
		for (GFile f : listing) {
			if (entries.size() >= 5000) {
				break;
			}
			entries.add(map("name", f.getName(), "fsrl", f.getFSRL().toString(), "directory", f.isDirectory(),
				"size", f.getLength()));
		}
		entries.sort(Comparator.<Map<String, Object>, Boolean> comparing(e -> !(Boolean) e.get("directory"))
				.thenComparing(e -> ((String) e.get("name")).toLowerCase()));
		return map("container", true, "entries", entries, "type", fsType);
	}

	static List<Map<String, Object>> loadSpecs(String source) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		try (ByteProvider provider = FileSystemService.getInstance().getByteProvider(fsrl(source), false, TaskMonitor.DUMMY)) {
			LoaderMap specs = LoaderService.getAllSupportedLoadSpecs(provider);
			for (Map.Entry<Loader, Collection<LoadSpec>> e : specs.entrySet()) {
				for (LoadSpec spec : e.getValue()) {
					LanguageCompilerSpecPair pair = spec.getLanguageCompilerSpec();
					out.add(map("loader", e.getKey().getName(), "tier", e.getKey().getTier().toString(),
						"language", pair != null ? pair.languageID.getIdAsString() : null,
						"compiler", pair != null ? pair.compilerSpecID.getIdAsString() : null,
						"preferred", spec.isPreferred(), "imageBase", Long.toHexString(spec.getDesiredImageBase())));
				}
			}
		}
		return out;
	}

	/** The loader's own options (base address, load libraries, block names…) with their command-line args. */
	static List<Map<String, Object>> loaderOptions(String source, String loaderName) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		try (ByteProvider provider = FileSystemService.getInstance().getByteProvider(fsrl(source), false, TaskMonitor.DUMMY)) {
			LoaderMap specs = LoaderService.getAllSupportedLoadSpecs(provider);
			for (Map.Entry<Loader, Collection<LoadSpec>> e : specs.entrySet()) {
				if (loaderName != null && !e.getKey().getName().equals(loaderName)) {
					continue;
				}
				LoadSpec spec = e.getValue().stream().filter(LoadSpec::isPreferred).findFirst()
						.orElse(e.getValue().isEmpty() ? null : e.getValue().iterator().next());
				if (spec == null) {
					continue;
				}
				for (Option o : e.getKey().getDefaultOptions(provider, spec, null, false, false)) {
					if (o.getArg() == null) {
						continue;
					}
					Class<?> c = o.getValueClass();
					String type = c == Boolean.class ? "bool" : Number.class.isAssignableFrom(c) ? "number" : "text";
					out.add(map("name", o.getName(), "arg", o.getArg(), "type", type,
						"value", o.getValue() != null ? o.getValue().toString() : "", "group", o.getGroup()));
				}
				break;
			}
		}
		return out;
	}

	private static Class<? extends Loader> loaderClass(String source, String name) throws Exception {
		try (ByteProvider provider = FileSystemService.getInstance().getByteProvider(fsrl(source), false, TaskMonitor.DUMMY)) {
			for (Loader l : LoaderService.getAllSupportedLoadSpecs(provider).keySet()) {
				if (l.getName().equals(name)) {
					return l.getClass();
				}
			}
		}
		throw new IllegalArgumentException("Cargador desconocido: " + name);
	}

	/** Imports into the project and returns the saved domain paths (primary first, then libraries). */
	static List<String> importSource(StudioServer server, String source, String folder, String name, String loader,
			String language, String compiler, Map<String, String> loaderArgs) throws Exception {
		MessageLog log = new MessageLog();
		ProgramLoader.Builder b = ProgramLoader.builder()
				.source(fsrl(source))
				.project(server.project().getProject())
				.projectFolderPath(folder == null || folder.isBlank() ? "/" : folder)
				.log(log)
				.monitor(TaskMonitor.DUMMY);
		if (name != null && !name.isBlank()) {
			b = b.name(name);
		}
		if (loader != null) {
			b = b.loaders(loaderClass(source, loader));
		}
		if (language != null) {
			b = b.language(language);
			if (compiler != null) {
				b = b.compiler(compiler);
			}
		}
		for (Map.Entry<String, String> e : loaderArgs.entrySet()) {
			b = b.addLoaderArg(e.getKey(), e.getValue());
		}
		List<String> paths = new ArrayList<>();
		try (LoadResults<Program> results = b.load()) {
			results.save(TaskMonitor.DUMMY);
			DomainFile primary = results.getPrimary().getSavedDomainFile();
			paths.add(primary.getPathname());
			for (Loaded<Program> lib : results.getNonPrimary()) {
				try {
					paths.add(lib.getSavedDomainFile().getPathname());
				}
				catch (Exception ignored) {
					// library not saved
				}
			}
		}
		catch (LoadException e) {
			throw new IllegalArgumentException("Ghidra no reconoce el formato de " + fsrl(source).getName());
		}
		return paths;
	}
}
