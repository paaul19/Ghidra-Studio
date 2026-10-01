package studio;

import static studio.Json.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

import com.google.gson.*;

import ghidra.GhidraApplicationLayout;
import ghidra.GhidraLaunchable;
import ghidra.app.util.bin.FileByteProvider;
import ghidra.app.util.opinion.*;
import ghidra.base.project.GhidraProject;
import ghidra.framework.Application;
import ghidra.framework.HeadlessGhidraApplicationConfiguration;
import ghidra.framework.model.*;
import ghidra.program.model.lang.*;
import ghidra.program.model.listing.Program;
import ghidra.program.util.DefaultLanguageService;
import ghidra.util.task.TaskMonitor;

/**
 * Headless Ghidra engine for Ghidra Studio.
 * Protocol: one JSON object per line on stdin/stdout.
 *   request  {"id":1,"method":"openProgram","params":{...}}
 *   response {"id":1,"result":...} | {"id":1,"error":"..."}
 *   event    {"event":"analysisProgress","session":"/ls","message":"...","value":0.4}
 * Program methods accept an optional "session" parameter (defaults to the active program).
 */
public class StudioServer implements GhidraLaunchable {

	private final Gson gson = new GsonBuilder().serializeNulls().disableHtmlEscaping().create();
	private PrintStream out;
	private String defaultProjectDir;
	private GhidraProject project;
	private final Map<String, Session> sessions = new LinkedHashMap<>();
	private Session active;

	@Override
	public void launch(GhidraApplicationLayout layout, String[] args) throws Exception {
		// Keep the real stdout for the protocol; everything else (logging) goes to stderr.
		out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
		System.setOut(System.err);

		Application.initializeApplication(layout, new HeadlessGhidraApplicationConfiguration());

		defaultProjectDir = args.length > 0 ? args[0]
				: System.getProperty("user.home") + "/Library/Application Support/Ghidra Studio";
		new File(defaultProjectDir).mkdirs();
		String initial = args.length > 1 ? args[1] : null;
		String startupError = null;
		try {
			if (initial != null && new File(initial).isFile()) {
				openProject(initial);
			}
			else {
				openDefaultProject();
			}
		}
		catch (Exception e) {
			// Never die here (e.g. the project is locked by another Studio / classic Ghidra).
			e.printStackTrace();
			project = null;
			startupError = Msg.t(e instanceof ghidra.framework.store.LockException
					? "El proyecto está abierto en otra aplicación (¿Ghidra clásico?)" : String.valueOf(e.getMessage()));
		}

		send(map("event", "ready", "version", Application.getApplicationVersion(), "project", projectInfo(false),
			"error", startupError));

		BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
		String line;
		while ((line = in.readLine()) != null) {
			if (line.isBlank()) {
				continue;
			}
			JsonObject req = JsonParser.parseString(line).getAsJsonObject();
			long id = req.get("id").getAsLong();
			String method = req.get("method").getAsString();
			JsonObject params = req.has("params") && req.get("params").isJsonObject()
					? req.getAsJsonObject("params") : new JsonObject();
			Map<String, Object> resp = new LinkedHashMap<>();
			resp.put("id", id);
			try {
				resp.put("result", dispatch(method, params));
			}
			catch (Throwable t) {
				t.printStackTrace();
				resp.put("error", Msg.t(t.getMessage() != null ? t.getMessage() : t.getClass().getSimpleName()));
			}
			send(resp);
			if (method.equals("shutdown")) {
				break;
			}
		}
		closeAll();
		if (project != null) {
			project.close();
		}
		System.exit(0);
	}

	synchronized void send(Object obj) {
		out.println(gson.toJson(obj));
	}

	GhidraProject project() {
		if (project == null) {
			throw new IllegalStateException("No hay ningún proyecto abierto");
		}
		return project;
	}

	// ---------------------------------------------------------------- dispatch

	private Object dispatch(String m, JsonObject p) throws Exception {
		switch (m) {
			case "ping": return "pong";
			case "shutdown": return true;

			// project
			case "projectInfo": return projectInfo(true);
			case "createProject": return createProject(reqStr(p, "directory"), reqStr(p, "name"));
			case "openProject": return openProject(reqStr(p, "path"));
			case "openDefaultProject": return openDefaultProject();
			case "releaseProject": return releaseProject();
			case "createFolder": return createFolder(reqStr(p, "parent"), reqStr(p, "name"));
			case "renameItem": return renameItem(reqStr(p, "path"), reqStr(p, "name"), optBool(p, "folder", false));
			case "deleteItem": return deleteItem(reqStr(p, "path"), optBool(p, "folder", false));
			case "moveItem": return moveItem(reqStr(p, "path"), reqStr(p, "folder"), optBool(p, "folder_item", false));
			case "loadSpecs": return loadSpecs(reqStr(p, "path"));
			case "languages": return languages();
			case "importFile": return importFile(p);
			case "importPacked": return importPacked(reqStr(p, "path"), optStr(p, "folder", "/"));
			case "exportPacked": {
				Session s = session(p);
				s.save();
				File packed = new File(reqStr(p, "path"));
				packed.delete();
				s.program.saveToPackedFile(packed, TaskMonitor.DUMMY);
				return true;
			}

			// sessions
			case "open": return quickOpen(reqStr(p, "path"), optBool(p, "reanalyze", false));
			case "openProgram": return openProgram(reqStr(p, "path"), optBool(p, "analyze", true));
			case "sessions": return sessionList();
			case "activate": {
				Session s = session(p);
				active = s;
				return s.info();
			}
			case "close": case "closeProgram": return closeSession(session(p));
			case "exporters": return Exports.list(sessions.isEmpty() ? null : session(p));
			case "scripts": return Scripts.list();
			case "scriptSource": return Scripts.read(reqStr(p, "path"));
			case "saveScript": return Scripts.save(reqStr(p, "name"), reqStr(p, "source"));
			default: return programMethod(m, session(p), p);
		}
	}

	private Object programMethod(String m, Session s, JsonObject p) throws Exception {
		switch (m) {
			case "info": return s.info();
			case "functions": return s.functions();
			case "imports": return s.imports();
			case "exports": return s.exports();
			case "strings": return s.strings();
			case "segments": return s.segments();
			case "bookmarks": return s.bookmarks();
			case "search": return s.symbolSearch(reqStr(p, "query"));
			case "decompile": return s.decompile(a(s, p));
			case "listing": return s.listing(a(s, p), optInt(p, "count", 400));
			case "listingSpan": return s.listingSpan(a(s, p), reqStr(p, "direction"), optInt(p, "count", 1500),
				optBool(p, "inclusive", true));
			case "hex": return s.hexDump(a(s, p), optInt(p, "length", 4096));
			case "xrefs": return s.xrefs(a(s, p));
			case "functionInfo": return s.functionInfo(a(s, p));
			case "resolve": return s.resolve(reqStr(p, "query"));
			case "save": s.save(); return s.undoState();
			case "undoState": return s.undoState();
			case "undo": return s.undo();
			case "redo": return s.redo();
			case "analyze": s.startAnalysis(); return true;
			case "cancelAnalysis": s.cancelAnalysis(); return true;
			case "analysisOptions": return s.analysisOptions();
			case "setAnalysisOptions": {
				Map<String, Boolean> values = new LinkedHashMap<>();
				for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("options").entrySet()) {
					values.put(e.getKey(), e.getValue().getAsBoolean());
				}
				return s.setAnalysisOptions(values);
			}

			// edits
			case "rename": return s.rename(a(s, p), reqStr(p, "name"));
			case "createLabel": return s.createLabel(a(s, p), reqStr(p, "name"));
			case "deleteLabel": return s.deleteLabel(a(s, p), optStr(p, "name", null));
			case "comment": return s.comment(a(s, p), optStr(p, "kind", "eol"), optStr(p, "text", ""));
			case "functionComment": return s.setFunctionComment(a(s, p), optStr(p, "text", ""));
			case "addBookmark": return s.addBookmark(a(s, p), optStr(p, "category", null), optStr(p, "comment", ""));
			case "deleteBookmark": return s.deleteBookmark(a(s, p));
			case "renameVariable": return s.renameVariable(a(s, p), reqStr(p, "name"), reqStr(p, "newName"));
			case "retypeVariable": return s.retypeVariable(a(s, p), reqStr(p, "name"), reqStr(p, "type"));
			case "setSignature": return s.setSignature(a(s, p), reqStr(p, "signature"));
			case "disassemble": return s.disassemble(a(s, p));
			case "createFunction": return s.createFunction(a(s, p), optStr(p, "name", null));
			case "deleteFunction": return s.deleteFunction(a(s, p));
			case "clear": return s.clear(a(s, p));
			case "createData": return s.createData(a(s, p), reqStr(p, "type"));
			case "patchBytes": return s.patchBytes(a(s, p), reqStr(p, "bytes"));
			case "assemble": return s.assemble(a(s, p), reqStr(p, "instruction"));

			// types
			case "dataTypes": return Types.list(s.program, optStr(p, "filter", ""), optBool(p, "builtins", true));
			case "dataType": return Types.detail(s.program, reqStr(p, "path"));
			case "createStruct": return Types.createStruct(s, reqStr(p, "name"), optStr(p, "category", "/"),
				optBool(p, "union", false));
			case "createEnum": return Types.createEnum(s, reqStr(p, "name"), optStr(p, "category", "/"),
				optInt(p, "size", 4));
			case "createTypedef": return Types.createTypedef(s, reqStr(p, "name"), reqStr(p, "base"));
			case "addField": return Types.addField(s, reqStr(p, "path"), reqStr(p, "type"), optStr(p, "name", null),
				optStr(p, "comment", null));
			case "editField": return Types.editField(s, reqStr(p, "path"), optInt(p, "ordinal", 0),
				optStr(p, "type", null), optStr(p, "name", null), optStr(p, "comment", null));
			case "deleteField": return Types.deleteField(s, reqStr(p, "path"), optInt(p, "ordinal", 0));
			case "addEnumValue": return Types.addEnumValue(s, reqStr(p, "path"), reqStr(p, "name"),
				p.get("value").getAsLong());
			case "renameType": return Types.renameType(s, reqStr(p, "path"), reqStr(p, "name"));
			case "deleteType": return Types.deleteType(s, reqStr(p, "path"));
			case "parseC": return Types.parseC(s, reqStr(p, "source"));

			// graphs, search, scripts, export
			case "functionGraph": return Graphs.functionGraph(s, a(s, p));
			case "calls": return Graphs.calls(s, a(s, p), optBool(p, "callers", false));
			case "callGraph": return Graphs.callGraph(s, a(s, p), optInt(p, "up", 1), optInt(p, "down", 2));
			case "programCallGraph": return Graphs.programCallGraph(s, optBool(p, "external", false), optInt(p, "limit", 800));
			case "referenceGraph": return Graphs.referenceGraph(s, a(s, p), optInt(p, "depth", 1));
			case "searchBytes": return Search.bytes(s, reqStr(p, "pattern"));
			case "searchText": {
				Set<String> scopes = new HashSet<>();
				if (p.has("scopes")) {
					for (JsonElement e : p.getAsJsonArray("scopes")) {
						scopes.add(e.getAsString());
					}
				}
				else {
					scopes.addAll(List.of("labels", "comments", "strings", "instructions"));
				}
				return Search.text(s, reqStr(p, "query"), optBool(p, "regex", false),
					optBool(p, "caseSensitive", false), scopes);
			}
			case "runScript": return Scripts.run(s, reqStr(p, "path"), optStr(p, "address", null));
			case "export": return Exports.export(s, reqStr(p, "exporter"), reqStr(p, "path"));

			// symbol tree, memory map, references, equates, structures, archives
			case "namespaceChildren": return s.namespaceChildren(p.has("id") ? p.get("id").getAsLong() : 0);
			case "renameBlock": return s.renameBlock(reqStr(p, "name"), reqStr(p, "newName"));
			case "setBlockPerms": return s.setBlockPerms(reqStr(p, "name"), optBool(p, "read", true),
				optBool(p, "write", false), optBool(p, "execute", false));
			case "addBlock": return s.addBlock(reqStr(p, "name"), a(s, p), Long.decode(reqStr(p, "length")),
				optBool(p, "initialized", true), optStr(p, "comment", null));
			case "deleteBlock": return s.deleteBlock(reqStr(p, "name"));
			case "referencesFrom": return s.referencesFrom(a(s, p));
			case "addReference": return s.addReference(a(s, p), s.addr(reqStr(p, "to")), optInt(p, "operand", 0),
				optStr(p, "type", "data"));
			case "deleteReference": return s.deleteReference(a(s, p), s.addr(reqStr(p, "to")));
			case "setEquate": return s.setEquate(a(s, p), reqStr(p, "name"), optStr(p, "value", null));
			case "equates": return s.equates();
			case "autoStructure": return s.autoStructure(a(s, p), reqStr(p, "name"));
			case "typeArchives": return Types.archives();
			case "applyArchive": return Types.applyArchive(s, reqStr(p, "path"));

			// emulator
			case "emuState": return s.emulation.state();
			case "emuStart": return s.emulation.start(a(s, p));
			case "emuStep": return s.emulation.step(optInt(p, "count", 1));
			case "emuRun": return s.emulation.run();
			case "emuStop": s.emulation.stop(); return s.emulation.state();
			case "emuSetRegister": return s.emulation.setRegister(reqStr(p, "name"), reqStr(p, "value"));
			case "emuWriteMemory": return s.emulation.writeMemory(a(s, p), reqStr(p, "bytes"));
			case "emuReadMemory": return s.emulation.readMemory(a(s, p), optInt(p, "length", 256));
			case "emuBreakpoint": return s.emulation.breakpoint(a(s, p), optBool(p, "on", true));

			// program comparison
			case "diff": {
				Set<String> kinds = new HashSet<>();
				if (p.has("kinds")) {
					for (JsonElement e : p.getAsJsonArray("kinds")) {
						kinds.add(e.getAsString());
					}
				}
				return Compare.diff(s, reqStr(p, "other"), kinds);
			}
			case "matchFunctions": return Compare.matchFunctions(s, reqStr(p, "other"), optStr(p, "method", "instructions"),
				optInt(p, "minSize", 10));
			case "applyNames": {
				List<String[]> pairs = new ArrayList<>();
				for (JsonElement e : p.getAsJsonArray("pairs")) {
					JsonObject o = e.getAsJsonObject();
					pairs.add(new String[] { o.get("address").getAsString(), o.get("otherAddress").getAsString() });
				}
				return Compare.applyNames(s, reqStr(p, "other"), pairs, optBool(p, "comments", true));
			}
			default: throw new IllegalArgumentException("Método desconocido: " + m);
		}
	}

	private static ghidra.program.model.address.Address a(Session s, JsonObject p) {
		return s.addr(reqStr(p, "address"));
	}

	Session sessionFor(String domainPath) {
		return sessions.get(domainPath);
	}

	private Session session(JsonObject p) {
		String id = optStr(p, "session", null);
		if (id != null) {
			Session s = sessions.get(id);
			if (s == null) {
				throw new IllegalArgumentException("El programa " + id + " no está abierto");
			}
			return s;
		}
		if (active == null) {
			throw new IllegalStateException("No hay ningún programa abierto");
		}
		return active;
	}

	// ---------------------------------------------------------------- projects

	private Map<String, Object> openDefaultProject() throws Exception {
		closeProject();
		File gpr = new File(defaultProjectDir, "Studio.gpr");
		try {
			project = gpr.exists() ? GhidraProject.openProject(defaultProjectDir, "Studio", true)
					: GhidraProject.createProject(defaultProjectDir, "Studio", false);
		}
		catch (ghidra.framework.store.LockException e) {
			throw new IllegalStateException("El proyecto está abierto en otra aplicación (¿Ghidra clásico?)");
		}
		return projectInfo(true);
	}

	private Map<String, Object> openProject(String path) throws Exception {
		File f = new File(path);
		if (f.isDirectory()) {
			File[] gprs = f.listFiles((d, n) -> n.endsWith(".gpr"));
			if (gprs == null || gprs.length == 0) {
				throw new FileNotFoundException("No hay ningún proyecto .gpr en " + path);
			}
			f = gprs[0];
		}
		if (!f.getName().endsWith(".gpr") || !f.exists()) {
			throw new FileNotFoundException("No es un proyecto de Ghidra: " + path);
		}
		String name = f.getName().substring(0, f.getName().length() - 4);
		GhidraProject opened;
		try {
			opened = GhidraProject.openProject(f.getParent(), name, true);
		}
		catch (ghidra.framework.store.LockException e) {
			throw new IllegalStateException("El proyecto está abierto en otra aplicación (¿Ghidra clásico?)");
		}
		closeProject();
		project = opened;
		return projectInfo(true);
	}

	private Map<String, Object> createProject(String dir, String name) throws Exception {
		File d = new File(dir);
		d.mkdirs();
		if (new File(d, name + ".gpr").exists()) {
			throw new IllegalArgumentException("Ya existe un proyecto «" + name + "» en esa carpeta");
		}
		closeProject();
		project = GhidraProject.createProject(d.getAbsolutePath(), name, false);
		return projectInfo(true);
	}

	/** Closes everything so the classic Ghidra can open the same project. */
	private Map<String, Object> releaseProject() {
		Map<String, Object> info = projectInfo(false);
		closeProject();
		return info;
	}

	private void closeProject() {
		closeAll();
		if (project != null) {
			try {
				project.close();
			}
			catch (Exception e) {
				e.printStackTrace();
			}
			project = null;
		}
	}

	private Map<String, Object> projectInfo(boolean withTree) {
		if (project == null) {
			return map("open", false);
		}
		ProjectLocator loc = project.getProject().getProjectLocator();
		Map<String, Object> m = map("open", true, "name", loc.getName(), "directory", loc.getLocation(),
			"gpr", loc.getMarkerFile().getAbsolutePath(),
			"isDefault", new File(loc.getLocation()).getAbsoluteFile().equals(new File(defaultProjectDir).getAbsoluteFile())
					&& loc.getName().equals("Studio"));
		if (withTree) {
			m.put("tree", folderTree(project.getRootFolder()));
		}
		return m;
	}

	private Map<String, Object> folderTree(DomainFolder folder) {
		List<Map<String, Object>> folders = new ArrayList<>();
		for (DomainFolder sub : folder.getFolders()) {
			folders.add(folderTree(sub));
		}
		List<Map<String, Object>> files = new ArrayList<>();
		for (DomainFile f : folder.getFiles()) {
			Map<String, String> meta = f.getMetadata();
			files.add(map("name", f.getName(), "path", f.getPathname(), "contentType", f.getContentType(),
				"format", meta.get("Executable Format"), "processor", meta.get("Processor"),
				"language", meta.get("Language ID"), "modified", f.getLastModifiedTime(),
				"open", sessions.containsKey(f.getPathname()),
				"program", Program.class.isAssignableFrom(f.getDomainObjectClass())));
		}
		return map("name", folder.getName(), "path", folder.getPathname(), "folders", folders, "files", files);
	}

	private DomainFolder folder(String path, boolean create) throws Exception {
		DomainFolder f = project().getRootFolder();
		for (String part : path.split("/")) {
			if (part.isEmpty()) {
				continue;
			}
			DomainFolder next = f.getFolder(part);
			if (next == null) {
				if (!create) {
					throw new FileNotFoundException("No existe la carpeta " + path);
				}
				next = f.createFolder(part);
			}
			f = next;
		}
		return f;
	}

	private DomainFile file(String path) {
		DomainFile f = project().getProjectData().getFile(path);
		if (f == null) {
			throw new IllegalArgumentException("No existe " + path);
		}
		return f;
	}

	private Object createFolder(String parent, String name) throws Exception {
		folder(parent, false).createFolder(name);
		return projectInfo(true);
	}

	private Object renameItem(String path, String name, boolean isFolder) throws Exception {
		if (isFolder) {
			folder(path, false).setName(name);
		}
		else {
			if (sessions.containsKey(path)) {
				throw new IllegalStateException("Cierra el programa antes de renombrarlo");
			}
			file(path).setName(name);
		}
		return projectInfo(true);
	}

	private Object deleteItem(String path, boolean isFolder) throws Exception {
		if (isFolder) {
			DomainFolder f = folder(path, false);
			for (String open : sessions.keySet()) {
				if (open.startsWith(f.getPathname())) {
					throw new IllegalStateException("Hay programas abiertos en esa carpeta");
				}
			}
			deleteRecursive(f);
		}
		else {
			if (sessions.containsKey(path)) {
				throw new IllegalStateException("Cierra el programa antes de borrarlo");
			}
			file(path).delete();
		}
		return projectInfo(true);
	}

	private void deleteRecursive(DomainFolder f) throws IOException {
		for (DomainFolder sub : f.getFolders()) {
			deleteRecursive(sub);
		}
		for (DomainFile file : f.getFiles()) {
			file.delete();
		}
		f.delete();
	}

	private Object moveItem(String path, String target, boolean isFolder) throws Exception {
		DomainFolder dest = folder(target, true);
		if (isFolder) {
			folder(path, false).moveTo(dest);
		}
		else {
			if (sessions.containsKey(path)) {
				throw new IllegalStateException("Cierra el programa antes de moverlo");
			}
			file(path).moveTo(dest);
		}
		return projectInfo(true);
	}

	// ---------------------------------------------------------------- import

	private List<Map<String, Object>> loadSpecs(String path) throws Exception {
		File f = new File(path);
		List<Map<String, Object>> out = new ArrayList<>();
		try (FileByteProvider provider = new FileByteProvider(f, null, java.nio.file.AccessMode.READ)) {
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

	private List<Map<String, Object>> languages() {
		List<Map<String, Object>> out = new ArrayList<>();
		for (LanguageDescription d : DefaultLanguageService.getLanguageService().getLanguageDescriptions(false)) {
			List<String> compilers = new ArrayList<>();
			for (CompilerSpecDescription c : d.getCompatibleCompilerSpecDescriptions()) {
				compilers.add(c.getCompilerSpecID().getIdAsString());
			}
			out.add(map("id", d.getLanguageID().getIdAsString(), "processor", d.getProcessor().toString(),
				"endian", d.getEndian().toString(), "size", d.getSize(), "variant", d.getVariant(),
				"description", d.getDescription(), "compilers", compilers));
		}
		out.sort(Comparator.comparing(o -> (String) o.get("id")));
		return out;
	}

	private Map<String, Object> importFile(JsonObject p) throws Exception {
		File file = new File(reqStr(p, "path"));
		if (!file.isFile()) {
			throw new FileNotFoundException("No existe: " + file);
		}
		String folderPath = optStr(p, "folder", "/");
		String loaderName = optStr(p, "loader", null);
		String languageId = optStr(p, "language", null);
		String compilerId = optStr(p, "compiler", null);
		boolean analyze = optBool(p, "analyze", true);
		boolean openIt = optBool(p, "open", true);

		progress("Importando " + file.getName() + "…");
		Program program;
		if (loaderName != null || languageId != null) {
			Class<? extends Loader> loaderClass = null;
			if (loaderName != null) {
				try (FileByteProvider provider = new FileByteProvider(file, null, java.nio.file.AccessMode.READ)) {
					for (Loader l : LoaderService.getAllSupportedLoadSpecs(provider).keySet()) {
						if (l.getName().equals(loaderName)) {
							loaderClass = l.getClass();
						}
					}
				}
			}
			Language lang = null;
			CompilerSpec cspec = null;
			if (languageId != null) {
				lang = DefaultLanguageService.getLanguageService().getLanguage(new LanguageID(languageId));
				cspec = compilerId != null ? lang.getCompilerSpecByID(new CompilerSpecID(compilerId))
						: lang.getDefaultCompilerSpec();
			}
			if (loaderClass != null && lang != null) {
				program = project().importProgram(file, loaderClass, lang, cspec);
			}
			else if (loaderClass != null) {
				program = project().importProgram(file, loaderClass);
			}
			else {
				program = project().importProgram(file, lang, cspec);
			}
		}
		else {
			program = project().importProgram(file);
		}
		if (program == null) {
			throw new IOException("Ghidra no reconoce el formato de " + file.getName());
		}
		DomainFolder folder = folder(folderPath, true);
		String name = uniqueName(folder, safeName(file.getName()));
		try {
			project().saveAs(program, folder.getPathname(), name, false);
		}
		catch (Exception e) {
			try {
				project().close(program);
			}
			catch (Exception ignored) {
				// ignore
			}
			throw e;
		}
		project().close(program);
		String domainPath = folder.getPathname().replaceAll("/$", "") + "/" + name;
		if (!openIt) {
			return map("path", domainPath);
		}
		Map<String, Object> info = openProgram(domainPath, false, file.getAbsolutePath());
		if (analyze) {
			active.startAnalysis();
			info.put("analyzing", true);
		}
		return info;
	}

	private static String uniqueName(DomainFolder folder, String base) {
		String name = base;
		int i = 1;
		while (folder.getFile(name) != null) {
			name = base + "_" + i++;
		}
		return name;
	}

	private Object importPacked(String path, String folderPath) throws Exception {
		File f = new File(path);
		DomainFolder folder = folder(folderPath, true);
		String base = f.getName().replaceAll("\\.gzf$", "");
		folder.createFile(uniqueName(folder, safeName(base)), f, TaskMonitor.DUMMY);
		return projectInfo(true);
	}

	// ---------------------------------------------------------------- sessions

	private Session register(Session s) {
		sessions.put(s.id, s);
		active = s;
		return s;
	}

	private Map<String, Object> openProgram(String domainPath, boolean analyze) throws Exception {
		return openProgram(domainPath, analyze, null);
	}

	private Map<String, Object> openProgram(String domainPath, boolean analyze, String sourcePath) throws Exception {
		Session existing = sessions.get(domainPath);
		if (existing != null) {
			active = existing;
			return existing.info();
		}
		DomainFile df = file(domainPath);
		progress("Abriendo " + df.getName() + "…");
		// Open through the project API (not GhidraProject) so undo/redo history works.
		Object consumer = new Object();
		Program program = (Program) df.getDomainObject(consumer, true, false, TaskMonitor.DUMMY);
		Session s;
		try {
			s = register(new Session(this, program, consumer, sourcePath));
		}
		catch (Exception e) {
			program.release(consumer);
			throw e;
		}
		if (analyze && s.needsAnalysis()) {
			s.startAnalysis();
		}
		return s.info();
	}

	/** Legacy "open a file": imports it into the project root once, then reopens it. */
	private Map<String, Object> quickOpen(String path, boolean reanalyze) throws Exception {
		File file = new File(path);
		if (!file.isFile()) {
			throw new FileNotFoundException("No existe: " + path);
		}
		String name = safeName(file.getName()) + "_" + shortHash(file.getAbsolutePath());
		DomainFile existing = project().getRootFolder().getFile(name);
		if (existing != null) {
			Session open = sessions.get(existing.getPathname());
			if (open != null && !reanalyze) {
				active = open;
				return open.info();
			}
			if (open != null) {
				closeSession(open);
			}
			if (!reanalyze) {
				Map<String, Object> info = openProgram(existing.getPathname(), true);
				return info;
			}
			existing.delete();
		}
		progress("Importando " + file.getName() + "…");
		Program program = project().importProgram(file);
		if (program == null) {
			throw new IOException("Ghidra no reconoce el formato de " + file.getName());
		}
		try {
			project().saveAs(program, "/", name, true);
		}
		catch (Exception e) {
			try {
				project().close(program);
			}
			catch (Exception ignored) {
				// ignore
			}
			throw e;
		}
		project().close(program);
		Map<String, Object> info = openProgram("/" + name, false, file.getAbsolutePath());
		active.startAnalysis();
		info.put("analyzing", true);
		return info;
	}

	private List<Map<String, Object>> sessionList() {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Session s : sessions.values()) {
			out.add(map("session", s.id, "name", s.program.getName(), "active", s == active,
				"analyzing", s.isAnalyzing()));
		}
		return out;
	}

	private Object closeSession(Session s) {
		s.close();
		sessions.remove(s.id);
		if (active == s) {
			active = sessions.isEmpty() ? null : sessions.values().iterator().next();
		}
		return map("active", active != null ? active.id : null);
	}

	private void closeAll() {
		for (Session s : new ArrayList<>(sessions.values())) {
			closeSession(s);
		}
	}

	private void progress(String message) {
		send(map("event", "progress", "message", Msg.t(message), "value", -1.0));
	}
}
