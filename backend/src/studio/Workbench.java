package studio;

import static studio.Json.*;

import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

import com.google.gson.*;

import docking.widgets.conditiontestpanel.ConditionResult;
import generic.jar.ResourceFile;
import ghidra.app.plugin.core.analysis.AutoAnalysisManager;
import ghidra.app.plugin.core.analysis.validator.PostAnalysisValidator;
import ghidra.app.plugin.core.osgi.BundleHost;
import ghidra.app.plugin.core.osgi.GhidraBundle;
import ghidra.app.script.GhidraScriptUtil;
import ghidra.app.util.bin.format.dwarf.external.*;
import ghidra.framework.Application;
import ghidra.framework.model.ProjectLocator;
import ghidra.framework.options.*;
import ghidra.framework.protocol.ghidra.GhidraURL;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.Memory;
import ghidra.util.classfinder.ClassSearcher;
import ghidra.util.task.TaskMonitor;
import pdb.PdbPlugin;
import pdb.symbolserver.*;
import pdb.symbolserver.ui.WellKnownSymbolServerLocation;

/** Analysis configurations and validators, debug-file locations, byte patterns, script management, SARIF, URLs. */
final class Workbench {
	private Workbench() {
	}

	// ---------------------------------------------------------------- analysis option configurations

	/** Same folder and file format as Ghidra's analysis options dialog, so both share the saved configurations. */
	private static File configDir() {
		File dir = new File(Application.getUserSettingsDirectory(), "analyzer_options");
		dir.mkdirs();
		return dir;
	}

	static List<String> analysisConfigs() {
		List<String> out = new ArrayList<>();
		File[] files = configDir().listFiles((d, n) -> n.endsWith(".options"));
		if (files != null) {
			for (File f : files) {
				out.add(f.getName().replace(".options", ""));
			}
		}
		Collections.sort(out);
		return out;
	}

	private static void copy(Options from, Options to, boolean onlyKnown) {
		for (String name : from.getOptionNames()) {
			if (onlyKnown && !to.contains(name)) {
				continue;
			}
			OptionType type = from.getType(name);
			try {
				switch (type) {
					case BOOLEAN_TYPE -> to.setBoolean(name, from.getBoolean(name, false));
					case INT_TYPE -> to.setInt(name, from.getInt(name, 0));
					case LONG_TYPE -> to.setLong(name, from.getLong(name, 0));
					case DOUBLE_TYPE -> to.setDouble(name, from.getDouble(name, 0));
					case FLOAT_TYPE -> to.setFloat(name, from.getFloat(name, 0));
					case STRING_TYPE -> to.setString(name, from.getString(name, ""));
					case ENUM_TYPE -> {
						Enum<?> value = from.getEnum(name, null);
						if (value != null) {
							setEnum(to, name, value);
						}
					}
					default -> {
						// custom and file options keep their defaults
					}
				}
			}
			catch (Exception e) {
				// an option whose type changed between versions is skipped
			}
		}
	}

	@SuppressWarnings({ "unchecked", "rawtypes" })
	private static void setEnum(Options o, String name, Enum value) {
		o.setEnum(name, value);
	}

	static Object saveAnalysisConfig(Session s, String name) throws IOException {
		AutoAnalysisManager.getAnalysisManager(s.program).initializeOptions();
		FileOptions file = new FileOptions(name);
		copy(s.program.getOptions(Program.ANALYSIS_PROPERTIES), file, false);
		file.save(new File(configDir(), name + ".options"));
		return analysisConfigs();
	}

	static Object applyAnalysisConfig(Session s, String name) throws Exception {
		File f = new File(configDir(), name + ".options");
		if (!f.isFile()) {
			throw new IllegalArgumentException("No existe la configuración " + name);
		}
		FileOptions file = new FileOptions(f);
		AutoAnalysisManager.getAnalysisManager(s.program).initializeOptions();
		return s.edit("Opciones de análisis", () -> {
			copy(file, s.program.getOptions(Program.ANALYSIS_PROPERTIES), true);
			return true;
		});
	}

	static Object deleteAnalysisConfig(String name) {
		new File(configDir(), name + ".options").delete();
		return analysisConfigs();
	}

	/** Gives the other open programs of the same processor this program's analysis options. */
	static Object copyAnalysisOptions(Session from, Session to) throws Exception {
		if (!from.program.getLanguageID().equals(to.program.getLanguageID())) {
			return false;
		}
		AutoAnalysisManager.getAnalysisManager(from.program).initializeOptions();
		AutoAnalysisManager.getAnalysisManager(to.program).initializeOptions();
		to.edit("Opciones de análisis", () -> {
			copy(from.program.getOptions(Program.ANALYSIS_PROPERTIES), to.program.getOptions(Program.ANALYSIS_PROPERTIES), true);
			return true;
		});
		return true;
	}

	// ---------------------------------------------------------------- validators

	/** Runs Ghidra's post-analysis validators (offcut references, percent analyzed, red flags…). */
	static List<Map<String, Object>> validate(Session s, TaskMonitor monitor) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Class<? extends PostAnalysisValidator> c : ClassSearcher.getClasses(PostAnalysisValidator.class)) {
			monitor.checkCancelled();
			try {
				PostAnalysisValidator v = c.getConstructor(Program.class).newInstance(s.program);
				monitor.setMessage(v.getName());
				ConditionResult r = v.run(monitor);
				out.add(map("name", v.getName(), "description", v.getDescription(), "status", r.getStatus().name(),
					"message", r.getMessage() == null ? "" : r.getMessage().trim()));
			}
			catch (ReflectiveOperationException e) {
				out.add(map("name", c.getSimpleName(), "description", "", "status", "Error", "message", String.valueOf(e)));
			}
		}
		out.sort(Comparator.comparing(o -> (String) o.get("name")));
		return out;
	}

	// ---------------------------------------------------------------- external DWARF debug files

	static Map<String, Object> dwarfLocations(Session s) {
		DebugInfoProviderCreatorContext ctx = DebugInfoProviderRegistry.getInstance().newContext(s == null ? null : s.program);
		ExternalDebugFilesService service = ExternalDebugFilesService.fromPrefs(ctx);
		List<Map<String, Object>> providers = new ArrayList<>();
		for (DebugInfoProvider p : service.getProviders()) {
			String status;
			try {
				status = p.getStatus(TaskMonitor.DUMMY).name();
			}
			catch (Exception e) {
				status = "UNKNOWN";
			}
			providers.add(map("name", p.getName(), "description", p.getDescriptiveName(), "status", status));
		}
		DebugFileStorage storage = service.getStorage();
		return map("storage", storage == null ? "" : storage.getName(), "providers", providers);
	}

	/**
	 * Sets where separate debug files are looked for: directories, "build-id://dir" trees,
	 * "debuglink://dir" and debuginfod URLs, in order. storage is the local folder downloads are kept in.
	 */
	static Object setDwarfLocations(Session s, String storage, List<String> locations) {
		DebugInfoProviderRegistry registry = DebugInfoProviderRegistry.getInstance();
		DebugInfoProviderCreatorContext ctx = registry.newContext(s == null ? null : s.program);
		ExternalDebugFilesService current = ExternalDebugFilesService.fromPrefs(ctx);
		DebugFileStorage store = current.getStorage();
		if (storage != null && !storage.isBlank()) {
			new File(storage).mkdirs();
			DebugInfoProvider p = registry.create(storage.contains("://") ? storage : "debuginfod-dir://" + storage, ctx);
			if (p instanceof DebugFileStorage dfs) {
				store = dfs;
			}
		}
		List<DebugInfoProvider> providers = new ArrayList<>();
		for (String loc : locations) {
			// a plain folder is searched by the .gnu_debuglink name of the program
			DebugInfoProvider p = registry.create(loc.startsWith("/") ? "debuglink://" + loc : loc, ctx);
			if (p == null) {
				throw new IllegalArgumentException("Ubicación no reconocida: " + loc);
			}
			providers.add(p);
		}
		ExternalDebugFilesService.saveToPrefs(new ExternalDebugFilesService(store, providers));
		ghidra.framework.preferences.Preferences.store();
		return dwarfLocations(s);
	}

	// ---------------------------------------------------------------- PDB symbol servers

	static Map<String, Object> pdbServers(Session s) {
		SymbolServerInstanceCreatorContext ctx = s == null ? SymbolServerInstanceCreatorRegistry.getInstance().getContext()
				: SymbolServerInstanceCreatorRegistry.getInstance().getContext(s.program);
		SymbolServerService service = PdbPlugin.getSymbolServerService(ctx);
		List<Map<String, Object>> servers = new ArrayList<>();
		for (SymbolServer server : service.getSymbolServers()) {
			servers.add(map("name", server.getName(), "description", server.getDescriptiveName(), "trusted", server.isTrusted()));
		}
		List<Map<String, Object>> known = new ArrayList<>();
		for (WellKnownSymbolServerLocation w : WellKnownSymbolServerLocation.loadAll()) {
			known.add(map("location", w.location(), "category", w.locationCategory(), "warning", w.warning()));
		}
		SymbolStore store = service.getSymbolStore();
		return map("storage", store == null ? "" : store.getName(), "servers", servers, "known", known);
	}

	static Object setPdbServers(Session s, String storage, List<String> locations) {
		SymbolServerInstanceCreatorRegistry registry = SymbolServerInstanceCreatorRegistry.getInstance();
		SymbolServerInstanceCreatorContext ctx = s == null ? registry.getContext() : registry.getContext(s.program);
		SymbolServerService current = PdbPlugin.getSymbolServerService(ctx);
		SymbolStore store = current.getSymbolStore();
		if (storage != null && !storage.isBlank()) {
			new File(storage).mkdirs();
			SymbolStore created = registry.newSymbolServer(storage, ctx, SymbolStore.class);
			if (created == null) {
				throw new IllegalArgumentException("La carpeta local de símbolos no es válida: " + storage);
			}
			store = created;
		}
		List<SymbolServer> servers = registry.createSymbolServersFromPathList(locations, ctx);
		PdbPlugin.saveSymbolServerServiceConfig(new SymbolServerService(store, servers));
		ghidra.framework.preferences.Preferences.store();
		return pdbServers(s);
	}

	// ---------------------------------------------------------------- function byte patterns

	/**
	 * How functions start in this program: the most common first bytes, the bytes right before them and
	 * the first instructions, with how many functions share each (the Function Bit Patterns Explorer).
	 */
	static Map<String, Object> functionPatterns(Session s, int firstBytes, int preBytes, int instructions,
			TaskMonitor monitor) throws Exception {
		Program p = s.program;
		Memory mem = p.getMemory();
		Map<String, Integer> first = new HashMap<>(), pre = new HashMap<>(), ins = new HashMap<>(), ret = new HashMap<>();
		List<byte[]> firsts = new ArrayList<>();
		int total = 0;
		for (Function f : p.getFunctionManager().getFunctions(true)) {
			monitor.checkCancelled();
			if (f.isExternal() || f.isThunk()) {
				continue;
			}
			total++;
			Address entry = f.getEntryPoint();
			try {
				byte[] b = new byte[firstBytes];
				mem.getBytes(entry, b);
				firsts.add(b);
				first.merge(hex(b, b.length), 1, Integer::sum);
			}
			catch (Exception e) {
				// function at the end of a block
			}
			try {
				byte[] b = new byte[preBytes];
				mem.getBytes(entry.subtract(preBytes), b);
				pre.merge(hex(b, b.length), 1, Integer::sum);
			}
			catch (Exception e) {
				// nothing before the first function
			}
			StringBuilder seq = new StringBuilder();
			int n = 0;
			Instruction last = null;
			for (Instruction i : p.getListing().getInstructions(f.getBody(), true)) {
				if (n < instructions) {
					seq.append(n == 0 ? "" : " ; ").append(i.getMnemonicString());
				}
				n++;
				last = i;
			}
			if (n > 0) {
				ins.merge(seq.toString(), 1, Integer::sum);
			}
			if (last != null) {
				ret.merge(last.getMnemonicString(), 1, Integer::sum);
			}
		}
		// bits that every function start agrees on, as a searchable pattern with wildcards
		StringBuilder consensus = new StringBuilder();
		if (!firsts.isEmpty()) {
			for (int i = 0; i < firstBytes; i++) {
				int and = 0xff, or = 0;
				for (byte[] b : firsts) {
					and &= b[i] & 0xff;
					or |= b[i] & 0xff;
				}
				consensus.append(and == or ? String.format("%02x ", and) : "?? ");
			}
		}
		return map("functions", total, "first", top(first, total), "pre", top(pre, total), "instructions", top(ins, total),
			"endings", top(ret, total), "consensus", consensus.toString().trim());
	}

	private static List<Map<String, Object>> top(Map<String, Integer> counts, int total) {
		List<Map<String, Object>> out = new ArrayList<>();
		counts.entrySet().stream().sorted((a, b) -> b.getValue() - a.getValue()).limit(200).forEach(
			e -> out.add(map("pattern", e.getKey(), "count", e.getValue(),
				"percent", total == 0 ? 0 : Math.round(e.getValue() * 1000.0 / total) / 10.0)));
		return out;
	}

	// ---------------------------------------------------------------- scripts

	private static File userScript(String path) {
		File f = new File(path);
		if (!f.isFile() || !f.getParentFile().equals(Scripts.userDirectory())) {
			throw new IllegalArgumentException("Solo se pueden cambiar los scripts de tu carpeta de scripts");
		}
		return f;
	}

	static Object scriptDelete(String path) {
		File f = userScript(path);
		if (!f.delete()) {
			throw new IllegalStateException("No se pudo borrar " + f.getName());
		}
		return true;
	}

	static Object scriptRename(String path, String newName) {
		File f = userScript(path);
		String ext = f.getName().substring(f.getName().lastIndexOf('.'));
		String name = newName.endsWith(ext) ? newName : newName + ext;
		File target = new File(f.getParentFile(), name);
		if (target.exists()) {
			throw new IllegalArgumentException("Ya existe " + name);
		}
		// a Java script is a class named like its file
		if (ext.equals(".java")) {
			try {
				String oldClass = f.getName().replace(".java", ""), newClass = name.replace(".java", "");
				String source = Files.readString(f.toPath(), StandardCharsets.UTF_8)
						.replaceAll("\\bclass\\s+" + java.util.regex.Pattern.quote(oldClass) + "\\b", "class " + newClass);
				Files.writeString(target.toPath(), source, StandardCharsets.UTF_8);
				f.delete();
			}
			catch (IOException e) {
				throw new IllegalStateException(e.getMessage(), e);
			}
		}
		else if (!f.renameTo(target)) {
			throw new IllegalStateException("No se pudo renombrar " + f.getName());
		}
		return map("path", target.getAbsolutePath(), "name", name);
	}

	/** Lines of the scripts that contain a text. */
	static List<Map<String, Object>> scriptSearch(String query) {
		List<Map<String, Object>> out = new ArrayList<>();
		String q = query.toLowerCase();
		for (Map<String, Object> script : Scripts.list()) {
			try {
				List<String> lines = Files.readAllLines(new File((String) script.get("path")).toPath(), StandardCharsets.UTF_8);
				for (int i = 0; i < lines.size() && out.size() < 3000; i++) {
					if (lines.get(i).toLowerCase().contains(q)) {
						out.add(map("name", script.get("name"), "path", script.get("path"), "line", i + 1, "text", lines.get(i).trim()));
					}
				}
			}
			catch (IOException e) {
				// unreadable script
			}
		}
		return out;
	}

	private static File dirsFile(StudioServer server) {
		return new File(server.supportDir(), "script-directories.json");
	}

	private static List<String> extraDirs(StudioServer server) {
		List<String> out = new ArrayList<>();
		try {
			for (JsonElement e : JsonParser.parseString(Files.readString(dirsFile(server).toPath())).getAsJsonArray()) {
				out.add(e.getAsString());
			}
		}
		catch (Exception e) {
			// no extra directories yet
		}
		return out;
	}

	/** Adds the user's extra script directories to the bundle host (once per engine run). */
	static void restoreScriptDirs(StudioServer server) {
		Scripts.userDirectory();
		BundleHost host = GhidraScriptUtil.getBundleHost();
		for (String dir : extraDirs(server)) {
			File f = new File(dir);
			if (f.isDirectory() && host.getExistingGhidraBundle(new ResourceFile(f)) == null) {
				host.add(new ResourceFile(f), true, false);
			}
		}
	}

	/** Script directories and bundles: where they are, whether they are enabled and built. */
	static List<Map<String, Object>> scriptDirs(StudioServer server) {
		restoreScriptDirs(server);
		List<Map<String, Object>> out = new ArrayList<>();
		for (GhidraBundle b : GhidraScriptUtil.getBundleHost().getGhidraBundles()) {
			File f = b.getFile().getFile(false);
			out.add(map("path", b.getFile().getAbsolutePath(), "enabled", b.isEnabled(), "system", b.isSystemBundle(),
				"active", b.isActive(), "kind", f != null && f.isDirectory() ? "directory" : "bundle",
				"exists", b.getFile().exists()));
		}
		out.sort(Comparator.comparing(o -> (String) o.get("path")));
		return out;
	}

	/** action: add, remove, enable, disable. */
	static Object scriptDirAction(StudioServer server, String action, String path) throws IOException {
		restoreScriptDirs(server);
		BundleHost host = GhidraScriptUtil.getBundleHost();
		ResourceFile file = new ResourceFile(new File(path));
		List<String> extra = extraDirs(server);
		switch (action) {
			case "add":
				if (!file.exists()) {
					throw new IllegalArgumentException("No existe " + path);
				}
				host.add(file, true, false);
				if (!extra.contains(path)) {
					extra.add(path);
				}
				break;
			case "remove": {
				GhidraBundle b = host.getExistingGhidraBundle(file);
				if (b != null && b.isSystemBundle()) {
					throw new IllegalArgumentException("Los directorios de Ghidra no se pueden quitar; desactívalo");
				}
				host.remove(file);
				extra.remove(path);
				break;
			}
			case "enable":
				host.enable(file);
				break;
			case "disable": {
				GhidraBundle b = host.getExistingGhidraBundle(file);
				if (b != null) {
					host.disable(b);
				}
				break;
			}
			default:
				throw new IllegalArgumentException("Acción desconocida: " + action);
		}
		Files.writeString(dirsFile(server).toPath(), new Gson().toJson(extra));
		return scriptDirs(server);
	}

	// ---------------------------------------------------------------- SARIF

	/** Results of a SARIF file as rows: rule, level, message and the address when the location has one. */
	static List<Map<String, Object>> sarif(Session s, String path) throws IOException {
		JsonObject root = JsonParser.parseString(Files.readString(new File(path).toPath(), StandardCharsets.UTF_8)).getAsJsonObject();
		List<Map<String, Object>> out = new ArrayList<>();
		if (!root.has("runs")) {
			throw new IllegalArgumentException("No es un archivo SARIF: falta «runs»");
		}
		for (JsonElement runElement : root.getAsJsonArray("runs")) {
			JsonObject run = runElement.getAsJsonObject();
			String tool = "";
			try {
				tool = run.getAsJsonObject("tool").getAsJsonObject("driver").get("name").getAsString();
			}
			catch (Exception e) {
				// no tool name
			}
			if (!run.has("results")) {
				continue;
			}
			for (JsonElement resultElement : run.getAsJsonArray("results")) {
				if (out.size() >= 20000) {
					break;
				}
				JsonObject r = resultElement.getAsJsonObject();
				String message = "";
				if (r.has("message") && r.getAsJsonObject("message").has("text")) {
					message = r.getAsJsonObject("message").get("text").getAsString();
				}
				String address = "";
				String location = "";
				if (r.has("locations")) {
					for (JsonElement le : r.getAsJsonArray("locations")) {
						JsonObject l = le.getAsJsonObject();
						JsonObject physical = l.has("physicalLocation") ? l.getAsJsonObject("physicalLocation") : null;
						if (physical != null && physical.has("address")) {
							JsonObject a = physical.getAsJsonObject("address");
							if (a.has("absoluteAddress")) {
								long value = a.get("absoluteAddress").getAsLong();
								if (s != null) {
									address = str(s.program.getAddressFactory().getDefaultAddressSpace().getAddress(value));
								}
								else {
									address = Long.toHexString(value);
								}
							}
						}
						if (physical != null && physical.has("artifactLocation")) {
							JsonObject art = physical.getAsJsonObject("artifactLocation");
							location = art.has("uri") ? art.get("uri").getAsString() : "";
							if (physical.has("region") && physical.getAsJsonObject("region").has("startLine")) {
								location += ":" + physical.getAsJsonObject("region").get("startLine").getAsInt();
							}
						}
						if (l.has("logicalLocations") && address.isEmpty() && s != null) {
							for (JsonElement ll : l.getAsJsonArray("logicalLocations")) {
								JsonObject logical = ll.getAsJsonObject();
								String name = logical.has("name") ? logical.get("name").getAsString() : "";
								for (ghidra.program.model.symbol.Symbol sym : s.program.getSymbolTable().getGlobalSymbols(name)) {
									address = str(sym.getAddress());
									break;
								}
								if (location.isEmpty()) {
									location = name;
								}
							}
						}
						if (!address.isEmpty()) {
							break;
						}
					}
				}
				out.add(map("address", address, "rule", r.has("ruleId") ? r.get("ruleId").getAsString() : "",
					"level", r.has("level") ? r.get("level").getAsString() : "", "kind", r.has("kind") ? r.get("kind").getAsString() : "",
					"message", message, "location", location, "tool", tool));
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- runtime information and database viewer

	/** Versions, memory, paths and the installed processors. */
	static Map<String, Object> runtimeInfo() {
		Runtime rt = Runtime.getRuntime();
		List<Map<String, Object>> properties = new ArrayList<>();
		for (String key : List.of("java.version", "java.vendor", "java.home", "os.name", "os.version", "os.arch",
			"user.name", "user.dir", "java.io.tmpdir", "file.encoding")) {
			properties.add(map("name", key, "value", System.getProperty(key, "")));
		}
		properties.add(map("name", "Ghidra", "value", Application.getApplicationVersion() + " " + Application.getApplicationReleaseName()
			+ " · " + Application.getBuildDate()));
		properties.add(map("name", "Installation", "value", String.valueOf(Application.getInstallationDirectory())));
		properties.add(map("name", "User settings", "value", String.valueOf(Application.getUserSettingsDirectory())));
		properties.add(map("name", "Processors", "value", String.valueOf(rt.availableProcessors())));
		properties.add(map("name", "Memory used (MB)", "value", String.valueOf((rt.totalMemory() - rt.freeMemory()) >> 20)));
		properties.add(map("name", "Memory max (MB)", "value", String.valueOf(rt.maxMemory() >> 20)));
		Map<String, int[]> byProcessor = new TreeMap<>();
		for (ghidra.program.model.lang.LanguageDescription d : ghidra.program.util.DefaultLanguageService.getLanguageService()
				.getLanguageDescriptions(false)) {
			byProcessor.computeIfAbsent(d.getProcessor().toString(), k -> new int[1])[0]++;
		}
		List<Map<String, Object>> processors = new ArrayList<>();
		byProcessor.forEach((name, n) -> processors.add(map("processor", name, "languages", n[0])));
		List<Map<String, Object>> modules = new ArrayList<>();
		for (generic.jar.ResourceFile root : Application.getApplicationRootDirectories()) {
			modules.add(map("name", "Root", "path", root.getAbsolutePath()));
		}
		for (ghidra.framework.GModule m : Application.getApplicationLayout().getModules().values()) {
			modules.add(map("name", m.getName(), "path", m.getModuleRoot().getAbsolutePath()));
		}
		return map("properties", properties, "processors", processors, "modules", modules);
	}

	/** The tables of the program's database (the DB viewer). */
	static List<Map<String, Object>> dbTables(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		db.DBHandle handle = ((ghidra.program.database.ProgramDB) s.program).getDBHandle();
		for (db.Table t : handle.getTables()) {
			db.Schema schema = t.getSchema();
			out.add(map("name", t.getName(), "records", t.getRecordCount(), "key", schema.getKeyName(),
				"columns", String.join(", ", schema.getFieldNames()), "version", schema.getVersion(),
				"indexes", t.getIndexedColumns().length));
		}
		out.sort(Comparator.comparing(o -> (String) o.get("name")));
		return out;
	}

	static Map<String, Object> dbRecords(Session s, String table, int limit) throws IOException {
		db.DBHandle handle = ((ghidra.program.database.ProgramDB) s.program).getDBHandle();
		db.Table t = handle.getTable(table);
		if (t == null) {
			throw new IllegalArgumentException("No existe la tabla " + table);
		}
		db.Schema schema = t.getSchema();
		String[] names = schema.getFieldNames();
		List<Map<String, Object>> rows = new ArrayList<>();
		db.RecordIterator it = t.iterator();
		while (it.hasNext() && rows.size() < limit) {
			db.DBRecord r = it.next();
			Map<String, Object> row = new LinkedHashMap<>();
			row.put("key", r.getKeyField().getValueAsString());
			for (int i = 0; i < names.length; i++) {
				String v = r.getFieldValue(i).getValueAsString();
				row.put("c" + i, v != null && v.length() > 200 ? v.substring(0, 200) + "…" : v);
			}
			rows.add(row);
		}
		return map("columns", Arrays.asList(names), "key", schema.getKeyName(), "rows", rows, "total", t.getRecordCount());
	}

	// ---------------------------------------------------------------- Ghidra URLs

	/** Breaks a ghidra:// URL into what the interface needs to open it. */
	static Map<String, Object> resolveURL(String text) throws Exception {
		if (!GhidraURL.isGhidraURL(text)) {
			throw new IllegalArgumentException("No es una URL de Ghidra: " + text);
		}
		URL url = GhidraURL.toURL(text);
		String path = GhidraURL.getProjectPathname(url);
		if (GhidraURL.isLocalURL(url)) {
			ProjectLocator locator = GhidraURL.getProjectStorageLocator(url);
			return map("local", true, "gpr", locator.getMarkerFile().getAbsolutePath(), "exists", locator.exists(),
				"path", path == null ? "/" : path, "reference", url.getRef());
		}
		return map("local", false, "host", url.getHost(), "port", url.getPort(), "repository", GhidraURL.getRepositoryName(url),
			"path", path == null ? "/" : path, "reference", url.getRef());
	}

	/** The ghidra:// URL of the open program (what "Copy Ghidra URL" gives). */
	static String programURL(Session s) {
		URL url = s.program.getDomainFile().getSharedProjectURL(null);
		if (url == null) {
			url = s.program.getDomainFile().getLocalProjectURL(null);
		}
		return url == null ? "" : url.toExternalForm();
	}
}
