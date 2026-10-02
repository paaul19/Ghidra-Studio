package studio;

import static studio.Json.*;

import java.io.File;
import java.util.*;

import ghidra.feature.fid.db.*;
import ghidra.feature.fid.service.FidPopulateResult;
import ghidra.feature.fid.service.FidService;
import ghidra.framework.model.DomainFile;
import ghidra.program.model.lang.LanguageID;
import ghidra.util.task.TaskMonitor;

/**
 * Function ID databases: the ones shipped with Ghidra plus the user's own (.fidb), which can be
 * created, attached and populated from analyzed programs. Shared with the classic Ghidra.
 */
final class Fid {
	private Fid() {
	}

	private static File home(StudioServer server) {
		File dir = new File(server.supportDir(), "FunctionID");
		dir.mkdirs();
		return dir;
	}

	static FidFile find(String path) {
		for (FidFile f : FidFileManager.getInstance().getFidFiles()) {
			if (f.getPath().equals(path)) {
				return f;
			}
		}
		throw new IllegalArgumentException("No existe " + path);
	}

	/** The list of user databases lives in Ghidra's preferences; write it now, not only on a clean exit. */
	private static void persist() {
		ghidra.framework.preferences.Preferences.store();
	}

	static Map<String, Object> list(StudioServer server) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (FidFile f : FidFileManager.getInstance().getFidFiles()) {
			List<Map<String, Object>> libraries = new ArrayList<>();
			try (FidDB db = f.getFidDB(false)) {
				for (LibraryRecord lib : db.getAllLibraries()) {
					libraries.add(map("family", lib.getLibraryFamilyName(), "version", lib.getLibraryVersion(),
						"variant", lib.getLibraryVariant(), "language", lib.getGhidraLanguageID().getIdAsString()));
				}
			}
			catch (Exception e) {
				// unreadable database: listed without libraries
			}
			out.add(map("name", f.getName(), "path", f.getPath(), "installed", f.isInstalled(),
				"active", f.isActive(), "libraries", libraries));
		}
		return map("files", out, "directory", home(server).getAbsolutePath());
	}

	static Map<String, Object> create(StudioServer server, String name) throws Exception {
		String base = safeName(name).replaceAll("\\.fidb$", "");
		File file = new File(home(server), base + FidFile.FID_PACKED_DATABASE_FILE_EXTENSION);
		if (file.exists()) {
			throw new IllegalArgumentException("Ya existe una base de datos Function ID con ese nombre");
		}
		FidFileManager.getInstance().createNewFidDatabase(file);
		persist();
		return list(server);
	}

	static Map<String, Object> attach(StudioServer server, String path) {
		File file = new File(path);
		if (!file.isFile()) {
			throw new IllegalArgumentException("No existe " + path);
		}
		if (FidFileManager.getInstance().addUserFidFile(file) == null) {
			throw new IllegalArgumentException("No es una base de datos Function ID válida: " + file.getName());
		}
		persist();
		return list(server);
	}

	static Map<String, Object> detach(StudioServer server, String path) {
		FidFile f = find(path);
		if (f.isInstalled()) {
			throw new IllegalStateException("Las bases de datos incluidas con Ghidra no se pueden quitar");
		}
		FidFileManager.getInstance().removeUserFile(f);
		persist();
		return list(server);
	}

	static Map<String, Object> setActive(StudioServer server, String path, boolean active) {
		find(path).setActive(active);
		persist();
		return list(server);
	}

	/** Functions of a database whose name contains the text. */
	static List<Map<String, Object>> functions(String path, String query) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		try (FidDB db = find(path).getFidDB(false)) {
			for (FunctionRecord r : db.findFunctionsByNameSubstring(query)) {
				LibraryRecord lib = db.getLibraryForFunction(r);
				out.add(map("id", r.getID(), "name", r.getName(), "library",
					lib != null ? lib.getLibraryFamilyName() + " " + lib.getLibraryVersion() : "",
					"size", r.getCodeUnitSize(), "hash", Long.toHexString(r.getFullHash()),
					"domainPath", r.getDomainPath(), "excluded", r.autoFail(), "forced", r.autoPass()));
				if (out.size() >= 2000) {
					break;
				}
			}
		}
		out.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
		return out;
	}

	/**
	 * Function ID has no "delete function": a function is taken out of the matching with its
	 * auto-fail flag, or always accepted with auto-pass.
	 */
	static Object setFunctionFlag(String path, long id, String flag, boolean on) throws Exception {
		FidFile f = find(path);
		if (f.isInstalled()) {
			throw new IllegalStateException("Las bases de datos incluidas con Ghidra son de solo lectura");
		}
		try (FidDB db = f.getFidDB(true)) {
			FunctionRecord r = db.getFunctionByID(id);
			if (r == null) {
				throw new IllegalArgumentException("Función desconocida");
			}
			if ("pass".equals(flag)) {
				db.setAutoPassOnFunction(r, on);
			}
			else {
				db.setAutoFailOnFunction(r, on);
			}
			db.saveDatabase("Ghidra Studio", TaskMonitor.DUMMY);
		}
		return true;
	}

	/** Adds a library (family / version / variant) built from the functions of the given programs. */
	static Map<String, Object> populate(StudioServer server, String path, String family, String version,
			String variant, List<String> programs, TaskMonitor monitor) throws Exception {
		FidFile f = find(path);
		if (f.isInstalled()) {
			throw new IllegalStateException("Las bases de datos incluidas con Ghidra son de solo lectura");
		}
		if (programs.isEmpty()) {
			throw new IllegalArgumentException("Elige al menos un programa");
		}
		List<DomainFile> files = new ArrayList<>();
		LanguageID language = null;
		for (String p : programs) {
			DomainFile df = server.project().getProjectData().getFile(p);
			if (df == null) {
				throw new IllegalArgumentException("No existe " + p);
			}
			Session open = server.sessionFor(p);
			if (open != null) {
				open.save();
			}
			String id = df.getMetadata().get("Language ID");
			// metadata is "AARCH64:LE:64:AppleSilicon (1.5)"
			LanguageID lang = id != null ? new LanguageID(id.replaceAll("\\s*\\(.*\\)$", "")) : null;
			if (language == null) {
				language = lang;
			}
			else if (lang != null && !lang.equals(language)) {
				throw new IllegalArgumentException("Todos los programas deben tener el mismo procesador");
			}
			files.add(df);
		}
		try (FidDB db = f.getFidDB(true)) {
			FidPopulateResult result = new FidService().createNewLibraryFromPrograms(db, family, version, variant,
				files, null, language, null, null, monitor);
			db.saveDatabase("Ghidra Studio", monitor);
			return map("added", result != null ? result.getTotalAdded() : 0,
				"excluded", result != null ? result.getTotalExcluded() : 0,
				"attempted", result != null ? result.getTotalAttempted() : 0);
		}
	}
}
