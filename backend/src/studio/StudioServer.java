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
	private final Map<String, Session> sessions = Collections.synchronizedMap(new LinkedHashMap<>());
	private Session active;
	private final VersionTracking vt = new VersionTracking(this);
	/** Long operations run here so the UI can keep navigating; their response is sent when they finish. */
	private final java.util.concurrent.ExecutorService worker = java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
		Thread t = new Thread(r, "studio-worker");
		t.setDaemon(true);
		return t;
	});
	private volatile Progress currentTask;
	/** Minutes between recovery snapshots of unsaved changes (0 = off), like the classic Ghidra's option. */
	private volatile int recoveryMinutes = 5;

	/** Thrown when a file has a recovery snapshot and the UI has not said what to do with it. */
	private static final class RecoverableException extends RuntimeException {
		RecoverableException(String path) {
			super("@recover:" + path);
		}
	}

	private void startRecoveryTimer() {
		Thread t = new Thread(() -> {
			long last = System.currentTimeMillis();
			while (true) {
				try {
					Thread.sleep(15_000);
				}
				catch (InterruptedException e) {
					return;
				}
				int minutes = recoveryMinutes;
				if (minutes <= 0 || System.currentTimeMillis() - last < minutes * 60_000L) {
					continue;
				}
				last = System.currentTimeMillis();
				snapshotAll();
			}
		}, "studio-recovery");
		t.setDaemon(true);
		t.start();
	}

	private int snapshotAll() {
		int taken = 0;
		List<Session> open;
		synchronized (sessions) {
			open = new ArrayList<>(sessions.values());
		}
		for (Session s : open) {
			if (s.snapshot()) {
				taken++;
			}
		}
		return taken;
	}
	private static final Set<String> SLOW = Set.of("tokenMatch", "ctadlIndex", "ctadlQuery", "wildAssemble", "batchScan", "batchImport", "keyTemplate", "loadKernel", "decompileJar", "eclipseProject", "copyFromView", "copyItem", "saveAs", "addToProgram", "fsExtract", "validate", "functionPatterns", "blockFlowGraph", "codeFlowGraph", "memScan", "directReferences", "mediaTable", "decompSearch", "taint", "typeUses", "typeParseHeaders", "select", "treeAction", "setLanguage", "bsimAddProgram", "bsimQuery", "vtRun", "vtAuto", "vtApply",
		"vtAccept", "vtReject", "vtClear", "serverConnect", "serverReconnect", "vcAdd", "vcCheckout", "vcCheckin",
		"vcUpdate", "vcExtract", "fidPopulate", "runScript", "pyEval", "bsimCompare", "serverConvert", "vtImplied",
		"vtCreateImplied", "pdbDownload");

	@Override
	public void launch(GhidraApplicationLayout layout, String[] args) throws Exception {
		// Keep the real stdout for the protocol; everything else (logging) goes to stderr.
		out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
		System.setOut(System.err);

		Application.initializeApplication(layout, new HeadlessGhidraApplicationConfiguration());
		run(args);
	}

	/**
	 * Entry point when the engine is hosted by Python (engine.py): PyGhidra has already started
	 * the JVM and initialized Ghidra, and passes the descriptor that carries the protocol.
	 */
	public static void serve(String[] args) throws Exception {
		StudioServer server = new StudioServer();
		String fd = System.getProperty("studio.protocol.fd");
		server.out = new PrintStream(fd != null ? new FileOutputStream("/dev/fd/" + fd)
				: new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
		System.setOut(System.err);
		server.run(args);
	}

	private void run(String[] args) throws Exception {

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

		startRecoveryTimer();
		send(map("event", "ready", "version", Application.getApplicationVersion(), "project", projectInfo(false),
			"error", startupError, "python", Python.version()));

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
			if (SLOW.contains(method)) {
				worker.submit(() -> send(respond(id, method, params)));
				continue;
			}
			send(respond(id, method, params));
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

	private Map<String, Object> respond(long id, String method, JsonObject params) {
		Map<String, Object> resp = new LinkedHashMap<>();
		resp.put("id", id);
		try {
			resp.put("result", dispatch(method, params));
		}
		catch (Throwable t) {
			t.printStackTrace();
			Throwable root = t;
			while (root.getMessage() == null && root.getCause() != null && root.getCause() != root) {
				root = root.getCause();
			}
			resp.put("error", Msg.t(root.getMessage() != null ? root.getMessage() : root.getClass().getSimpleName()));
			if (t instanceof RecoverableException) {
				resp.put("error", t.getMessage());
			}
		}
		return resp;
	}

	/** Monitor for a long operation: streams "task" events and can be cancelled with cancelTask. */
	private Progress task(String name) {
		Progress p = new Progress(this, name);
		currentTask = p;
		return p;
	}

	String supportDir() {
		return defaultProjectDir;
	}

	Project projectOrNull() {
		return project != null ? project.getProject() : null;
	}

	DomainFolder folderFor(String path) throws Exception {
		return folder(path == null || path.isBlank() ? "/" : path, true);
	}

	private static List<String> strings(JsonObject p, String key) {
		List<String> out = new ArrayList<>();
		if (p.has(key) && p.get(key).isJsonArray()) {
			for (JsonElement e : p.getAsJsonArray(key)) {
				out.add(e.getAsString());
			}
		}
		return out;
	}

	private static JsonObject object(JsonObject p, String key) {
		return p.has(key) && p.get(key).isJsonObject() ? p.getAsJsonObject(key) : null;
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
			case "loadSpecs": return Importer.loadSpecs(reqStr(p, "path"));
			case "loaderOptions": return Importer.loaderOptions(reqStr(p, "path"), optStr(p, "loader", null));
			case "fsList": ImportExtras.loadKeys(this); return Importer.list(reqStr(p, "path"));
			case "batchScan": return vc("import", t -> ImportExtras.batchScan(optStr(p, "id", ""), strings(p, "sources"),
				optInt(p, "depth", 2), t));
			case "batchRemove": return ImportExtras.batchRemove(reqStr(p, "id"), reqStr(p, "fsrl"));
			case "batchClose": return ImportExtras.batchClose(reqStr(p, "id"));
			case "batchImport": {
				Map<String, String> choices = new LinkedHashMap<>();
				if (p.has("groups")) {
					for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("groups").entrySet()) {
						choices.put(e.getKey(), e.getValue().getAsString());
					}
				}
				return vc("import", t -> ImportExtras.batchImport(this, reqStr(p, "id"), optStr(p, "folder", "/"), choices,
					optBool(p, "stripLeading", true), optBool(p, "stripContainers", false), optBool(p, "mirror", false), t));
			}
			case "keyFiles": return ImportExtras.keyFiles(this);
			case "keyReload": return ImportExtras.loadKeys(this);
			case "keyTemplate": return vc("import", t -> ImportExtras.keyTemplate(this, reqStr(p, "path"),
				optBool(p, "overwrite", false), t));
			case "loadKernel": return vc("import", t -> ImportExtras.loadKernel(this, reqStr(p, "path"), optStr(p, "folder", "/"), t));
			case "decompileJar": return vc("import", t -> ImportExtras.decompileJar(reqStr(p, "path"), reqStr(p, "output"),
				optStr(p, "tool", ""), t));
			case "eclipseProject": return vc("import", t -> ImportExtras.eclipseProject(reqStr(p, "path"), reqStr(p, "output"),
				optStr(p, "tool", ""), t));

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
			case "openProgram": return openProgram(reqStr(p, "path"), optBool(p, "analyze", true), null,
				p.has("recover") && !p.get("recover").isJsonNull() ? p.get("recover").getAsBoolean() : null);
			case "canRecover": return file(reqStr(p, "path")).canRecover();
			case "recoverySnapshot": return snapshotAll();
			case "setRecoveryInterval": recoveryMinutes = Math.max(0, optInt(p, "minutes", 5)); return recoveryMinutes;

			// Function ID
			case "fidFiles": return Fid.list(this);
			case "fidCreate": return Fid.create(this, reqStr(p, "name"));
			case "fidAttach": return Fid.attach(this, reqStr(p, "path"));
			case "fidDetach": return Fid.detach(this, reqStr(p, "path"));
			case "fidSetActive": return Fid.setActive(this, reqStr(p, "path"), optBool(p, "active", true));
			case "fidFunctions": return Fid.functions(reqStr(p, "path"), optStr(p, "query", ""));
			case "fidSetFlag": return Fid.setFunctionFlag(reqStr(p, "path"), p.get("id").getAsLong(),
				optStr(p, "flag", "fail"), optBool(p, "on", true));
			case "fidPopulate": return vc("fid", t -> Fid.populate(this, reqStr(p, "path"), reqStr(p, "family"),
				optStr(p, "version", "1.0"), optStr(p, "variant", "default"), strings(p, "programs"), t));
			case "sessions": return sessionList();
			case "activate": {
				Session s = session(p);
				active = s;
				return s.info();
			}
			case "close": case "closeProgram": return closeSession(session(p), optBool(p, "save", true));
			case "exporters": return Exports.list(sessions.isEmpty() ? null : session(p));
			case "analysisConfigs": return Workbench.analysisConfigs();
			case "saveAnalysisConfig": return Workbench.saveAnalysisConfig(session(p), reqStr(p, "name"));
			case "applyAnalysisConfig": return Workbench.applyAnalysisConfig(session(p), reqStr(p, "name"));
			case "deleteAnalysisConfig": return Workbench.deleteAnalysisConfig(reqStr(p, "name"));
			case "analyzeAllOpen": {
				Session from = session(p);
				List<String> started = new ArrayList<>();
				for (Session other : sessions.values()) {
					if (other != from && Boolean.TRUE.equals(Workbench.copyAnalysisOptions(from, other))) {
						other.startAnalysis();
						started.add(other.id);
					}
				}
				from.startAnalysis();
				started.add(from.id);
				return started;
			}
			case "validate": return vc("analysis", t -> Workbench.validate(session(p), t));
			case "dwarfLocations": return Workbench.dwarfLocations(sessionOrNull(p));
			case "setDwarfLocations": return Workbench.setDwarfLocations(sessionOrNull(p), optStr(p, "storage", ""),
				strings(p, "locations"));
			case "pdbServers": return Workbench.pdbServers(sessionOrNull(p));
			case "setPdbServers": return Workbench.setPdbServers(sessionOrNull(p), optStr(p, "storage", ""),
				strings(p, "locations"));
			case "functionPatterns": return vc("analysis", t -> Workbench.functionPatterns(session(p), optInt(p, "first", 8),
				optInt(p, "pre", 4), optInt(p, "instructions", 3), t));
			case "scriptDelete": return Workbench.scriptDelete(reqStr(p, "path"));
			case "scriptRename": return Workbench.scriptRename(reqStr(p, "path"), reqStr(p, "name"));
			case "scriptSearch": return Workbench.scriptSearch(reqStr(p, "query"));
			case "scriptDirs": return Workbench.scriptDirs(this);
			case "scriptDirAction": return Workbench.scriptDirAction(this, reqStr(p, "action"), reqStr(p, "path"));
			case "sarif": return Workbench.sarif(sessionOrNull(p), reqStr(p, "path"));
			case "resolveURL": return Workbench.resolveURL(reqStr(p, "url"));
			case "programURL": return Workbench.programURL(session(p));
			case "pyComplete": return Python.complete(this, sessionOrNull(p), reqStr(p, "text"));
			case "pyReset": return Python.reset();
			case "runtimeInfo": return Workbench.runtimeInfo();
			case "dbTables": return Workbench.dbTables(session(p));
			case "dbRecords": return Workbench.dbRecords(session(p), reqStr(p, "table"), optInt(p, "limit", 500));
			case "scripts": return Scripts.list();
			case "scriptSource": return Scripts.read(reqStr(p, "path"));
			case "saveScript": return Scripts.save(reqStr(p, "name"), reqStr(p, "source"));
			case "cancelTask": {
				Progress t = currentTask;
				if (t != null) {
					t.cancel();
				}
				Python.interrupt();
				return true;
			}

			// python
			case "pythonInfo": return map("available", Python.available(), "version", Python.version());
			case "pyEval": return Python.eval(this, sessions.isEmpty() ? null : session(p), optStr(p, "address", null),
				reqStr(p, "source"));

			// extensions
			case "extensions": return Extensions.list();
			case "installExtension": return Extensions.install(reqStr(p, "path"));
			case "uninstallExtension": return Extensions.uninstall(reqStr(p, "name"), optBool(p, "undo", false));

			// BSim
			case "bsimDatabases": return map("databases", Bsim.databases(this), "templates", List.of(Bsim.TEMPLATES),
				"directory", Bsim.home(this).getAbsolutePath());
			case "bsimCreate": return Bsim.create(this, reqStr(p, "name"), optStr(p, "template", null),
				optStr(p, "directory", null));
			case "bsimInfo": return Bsim.info(reqStr(p, "database"));
			case "bsimRemoveExecutable": return Bsim.removeExecutable(reqStr(p, "database"), reqStr(p, "md5"));
			case "bsimAddProgram": return vc("bsim", t -> Bsim.addProgram(session(p), reqStr(p, "database"), t));
			case "bsimQuery": {
				Map<String, String> filters = new LinkedHashMap<>();
				JsonObject fo = object(p, "filters");
				if (fo != null) {
					for (Map.Entry<String, JsonElement> e : fo.entrySet()) {
						filters.put(e.getKey(), e.getValue().getAsString());
					}
				}
				return vc("bsim", t -> Bsim.query(session(p), reqStr(p, "database"),
					optStr(p, "address", null), optInt(p, "max", 10),
					p.has("similarity") ? p.get("similarity").getAsDouble() : 0.7,
					p.has("confidence") ? p.get("confidence").getAsDouble() : 0.0, optBool(p, "skipSelf", true),
					filters, t));
			}
			case "bsimCompare": return vc("bsim", t -> Bsim.compareExecutables(reqStr(p, "database"), reqStr(p, "md5"), t));

			// Ghidra Server and version control
			case "serverConnect": return Repo.connect(reqStr(p, "host"), optInt(p, "port", 13100),
				optStr(p, "user", null), optStr(p, "password", ""));
			case "serverSetPassword": return Repo.setPassword(reqStr(p, "host"), optInt(p, "port", 13100),
				reqStr(p, "password"));
			case "serverCreateRepository": return Repo.createRepository(reqStr(p, "host"), optInt(p, "port", 13100),
				reqStr(p, "name"));
			case "serverRepositoryUsers": return Repo.repositoryUsers(reqStr(p, "host"), optInt(p, "port", 13100),
				reqStr(p, "name"));
			case "serverSetUser": return Repo.setRepositoryUser(reqStr(p, "host"), optInt(p, "port", 13100),
				reqStr(p, "name"), reqStr(p, "user"), optStr(p, "access", "write"));
			case "serverCreateProject": {
				String gpr = Repo.createSharedProject(reqStr(p, "host"), optInt(p, "port", 13100),
					reqStr(p, "repository"), reqStr(p, "directory"), reqStr(p, "name"));
				return openProject(gpr);
			}
			case "serverKeyFile": Repo.keyFile(optStr(p, "path", "")); return true;
			case "openURL": return openURL(reqStr(p, "url"), optStr(p, "user", null), optStr(p, "password", null));
			case "openVersion": return openVersion(reqStr(p, "path"), optInt(p, "version", 1));
			case "viewProject": return ProjectTools.viewProject(reqStr(p, "path"));
			case "closeView": return ProjectTools.closeView(reqStr(p, "path"));
			case "copyFromView": return vc("project", t -> ProjectTools.copyFromView(this, reqStr(p, "path"), strings(p, "files"),
				optStr(p, "folder", "/"), t));
			case "projectTable": return ProjectTools.table(this);
			case "copyItem": return vc("project", t -> ProjectTools.copy(this, reqStr(p, "path"), optBool(p, "folder", false),
				optStr(p, "dest", "/"), t));
			case "linkItem": return ProjectTools.link(this, reqStr(p, "path"), optBool(p, "folder", false),
				optStr(p, "dest", "/"), optBool(p, "relative", true));
			case "setReadOnly": return ProjectTools.setReadOnly(this, reqStr(p, "path"), optBool(p, "on", true));
			case "saveAs": return vc("project", t -> ProjectTools.saveAs(this, session(p), optStr(p, "folder", "/"),
				reqStr(p, "name"), t));
			case "projectStorage": return ProjectTools.storage(this);
			case "convertStorage": return ProjectTools.convertStorage(reqStr(p, "path"));
			case "vcFindCheckouts": return ProjectTools.findCheckouts(this);
			case "vcUndoHijack": return vc("vc", t -> ProjectTools.undoHijack(this, reqStr(p, "path"), optBool(p, "keep", true), t));
			case "addToProgramOptions": return ProjectTools.addToProgramOptions(session(p), reqStr(p, "path"));
			case "addToProgram": {
				Map<String, String> values = new LinkedHashMap<>();
				if (p.has("options")) {
					for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("options").entrySet()) {
						values.put(e.getKey(), e.getValue().getAsString());
					}
				}
				Session target = session(p);
				return vc("import", t -> ProjectTools.addToProgram(this, target, reqStr(p, "path"), optStr(p, "loader", null),
					values, t));
			}
			case "importSelection": {
				Session source = session(p);
				ghidra.program.model.address.AddressSet chosen = Views.ranges(source, p.get("ranges"));
				return ProjectTools.importSelection(this, source, chosen, optStr(p, "folder", "/"), reqStr(p, "name"));
			}
			case "libraryPaths": return ProjectTools.libraryPaths();
			case "setLibraryPaths": return ProjectTools.setLibraryPaths(strings(p, "paths"));
			case "fsPasswords": return ProjectTools.setPasswords(strings(p, "passwords"));
			case "fsMounted": return ProjectTools.mounted();
			case "fsCloseUnused": return ProjectTools.closeUnused();
			case "fsInfo": return ProjectTools.fileInfo(reqStr(p, "path"));
			case "fsRead": return ProjectTools.readFile(reqStr(p, "path"), optInt(p, "max", 1 << 20));
			case "fsExtract": return vc("import", t -> ProjectTools.extract(reqStr(p, "path"), reqStr(p, "output"), t));
			case "serverStatus": return Repo.status(project().getProject());
			case "serverReconnect": return Repo.reconnect(project().getProject(), optStr(p, "user", null),
				optStr(p, "password", ""));
			case "vcFiles": return map("files", Repo.files(this), "server", Repo.status(project().getProject()));
			case "vcHistory": return Repo.history(this, reqStr(p, "path"));
			case "vcCheckouts": return Repo.checkouts(this, reqStr(p, "path"));
			case "vcTerminate": return Repo.terminateCheckout(this, reqStr(p, "path"), p.get("id").getAsLong());
			case "serverConvert": {
				ProjectLocator loc = project().getProject().getProjectLocator();
				String gpr = loc.getMarkerFile().getAbsolutePath();
				closeAll();
				vc("vc", t -> {
					Repo.convertToShared(project().getProject(), reqStr(p, "host"), optInt(p, "port", 13100),
						reqStr(p, "repository"), t);
					return null;
				});
				// the conversion only takes effect when the project is opened again
				closeProject();
				return openProject(gpr);
			}
			case "vcUndoCheckout": return Repo.undoCheckout(this, reqStr(p, "path"), optBool(p, "keep", false));
			case "vcAdd": return vc("vc", t -> Repo.add(this, reqStr(p, "path"), optStr(p, "comment", ""),
				optBool(p, "keepCheckedOut", true), t));
			case "vcCheckout": return vc("vc", t -> Repo.checkout(this, reqStr(p, "path"),
				optBool(p, "exclusive", false), t));
			case "vcCheckin": return vc("vc", t -> Repo.checkin(this, reqStr(p, "path"),
				optStr(p, "comment", ""), optBool(p, "keepCheckedOut", false), t));
			case "vcUpdate": return vc("vc", t -> Repo.update(this, reqStr(p, "path"), t));
			case "vcExtract": return vc("vc", t -> Repo.extractVersion(this, reqStr(p, "path"),
				optInt(p, "version", 1), t));

			// Version Tracking
			case "vtSessions": return vt.sessions();
			case "vtCorrelators": return map("correlators", VersionTracking.correlators(),
				"auto", VersionTracking.autoOptions());
			case "vtState": return vt.state();
			case "vtCreate": return vt.create(reqStr(p, "name"), reqStr(p, "source"), session(p),
				optStr(p, "folder", "/"));
			case "vtOpen": {
				Map<String, Object> st = vt.open(reqStr(p, "path"));
				String dest = vt.destinationPath();
				if (dest != null && !sessions.containsKey(dest)) {
					openProgram(dest, false);
				}
				return st;
			}
			case "vtSave": return vt.save();
			case "vtClose": return vt.close(optBool(p, "save", true));
			case "vtMatches": return vt.matchList(optStr(p, "filter", ""), optStr(p, "status", null),
				optInt(p, "set", -1));
			case "vtMarkup": return vt.markup(reqStr(p, "key"));
			case "vtApplyOptions": return vt.applyOptionList();
			case "vtSetApplyOptions": return vt.setApplyOptions(object(p, "options"));
			case "vtRemove": return vt.remove(strings(p, "keys"), TaskMonitor.DUMMY);
			case "vtTags": return vt.tags();
			case "vtSetTag": return vt.setTag(strings(p, "keys"), optStr(p, "tag", ""));
			case "vtDeleteTag": return vt.deleteTag(reqStr(p, "tag"));
			case "vtImplied": return vc("vt", t -> vt.implied(reqStr(p, "key"), t));
			case "vtCreateImplied": return vc("vt", t -> vt.createImplied(reqStr(p, "key"), strings(p, "pairs"), t));
			case "vtManualMatch": return vt.manualMatch(reqStr(p, "source"), reqStr(p, "destination"),
				TaskMonitor.DUMMY);
			case "vtApplyMarkup": {
				List<Integer> indices = new ArrayList<>();
				for (JsonElement e : p.getAsJsonArray("indices")) {
					indices.add(e.getAsInt());
				}
				return vt.applyMarkup(reqStr(p, "key"), indices, optBool(p, "apply", true), TaskMonitor.DUMMY);
			}
			case "vtRun": return vc("vt", t -> vt.run(strings(p, "correlators"), object(p, "options"),
				optBool(p, "excludeAccepted", true), strings(p, "sourceRanges"), strings(p, "destinationRanges"), t));
			case "vtFunctions": return vt.functions();
			case "vtSetMarkupAddress": return vt.setMarkupAddress(reqStr(p, "key"), optInt(p, "index", -1),
				optStr(p, "address", ""));
			case "fidHash": return CompareTools.fidHash(session(p), a(session(p), p));
			case "fidSearch": return CompareTools.fidSearch(reqStr(p, "kind"), reqStr(p, "value"));
			case "fidReadOnly": return CompareTools.fidReadOnly(reqStr(p, "path"), reqStr(p, "output"));
			case "fidRepack": return CompareTools.fidRepack(reqStr(p, "path"), reqStr(p, "output"));
			case "fidStatistics": return CompareTools.fidStatistics(reqStr(p, "path"));
			case "bsimOverview": return vc("bsim", t -> CompareTools.bsimOverview(session(p), reqStr(p, "database"),
				p.has("similarity") ? p.get("similarity").getAsDouble() : 0.7,
				p.has("confidence") ? p.get("confidence").getAsDouble() : 0.0, t));
			case "bsimFeatures": return CompareTools.bsimFeatures(session(p), a(session(p), p));
			case "bsimCreateServer": return CompareTools.bsimCreateServer(reqStr(p, "url"), optStr(p, "template", null),
				optStr(p, "name", ""));
			case "projectFind": return CompareTools.projectFind(this, optStr(p, "md5", ""), optStr(p, "name", ""));
			case "vtAuto": return vc("vt", t -> vt.auto(object(p, "options"), t));
			case "vtAccept": return vc("vt", t -> vt.accept(strings(p, "keys"), t));
			case "vtApply": return vc("vt", t -> vt.apply(strings(p, "keys"), t));
			case "vtReject": return vc("vt", t -> vt.reject(strings(p, "keys"), t));
			case "vtClear": return vc("vt", t -> vt.clear(strings(p, "keys"), t));
			// data type manager: the program's types, .gdt files and project archives ("where")
			case "typeCreateArchive": return TypeTools.createArchive(reqStr(p, "path"));
			case "typeCreateProjectArchive":
				return TypeTools.createProjectArchive(this, optStr(p, "folder", "/"), reqStr(p, "name"));
			case "typeProjectArchives": return TypeTools.projectArchives(this);
			case "typeInfo": return TypeTools.info(this, sessionOrNull(p), optStr(p, "where", ""));
			case "typeSetArchitecture": return TypeTools.setArchitecture(this, sessionOrNull(p), optStr(p, "where", ""),
				optStr(p, "language", ""), optStr(p, "compiler", ""));
			case "typeBrowse": return TypeTools.browse(this, sessionOrNull(p), optStr(p, "where", ""),
				optStr(p, "category", "/"), optStr(p, "filter", ""));
			case "typeCategory": return TypeTools.categoryAction(this, sessionOrNull(p), optStr(p, "where", ""),
				reqStr(p, "action"), optStr(p, "path", "/"), optStr(p, "name", ""), optStr(p, "dest", "/"),
				optStr(p, "conflict", ""));
			case "typeAction": return TypeTools.typeAction(this, sessionOrNull(p), optStr(p, "where", ""),
				reqStr(p, "action"), strings(p, "paths"), optStr(p, "name", ""), optStr(p, "dest", "/"),
				optStr(p, "conflict", ""));
			case "typeCopy": return TypeTools.copyTypes(this, sessionOrNull(p), optStr(p, "from", ""), optStr(p, "to", ""),
				strings(p, "paths"), optStr(p, "dest", ""), optStr(p, "conflict", ""), optBool(p, "associate", true));
			case "typeMergeEnums": return TypeTools.mergeEnums(this, sessionOrNull(p), optStr(p, "where", ""),
				strings(p, "paths"), reqStr(p, "name"));
			case "typeDuplicateField": return TypeTools.duplicateField(this, sessionOrNull(p), optStr(p, "where", ""),
				reqStr(p, "path"), optInt(p, "ordinal", 0), optInt(p, "count", 1));
			case "typeUnpackField": return TypeTools.unpackField(this, sessionOrNull(p), optStr(p, "where", ""),
				reqStr(p, "path"), optInt(p, "ordinal", 0));
			case "typeFlexArray": return TypeTools.addFlexArray(this, sessionOrNull(p), optStr(p, "where", ""),
				reqStr(p, "path"), reqStr(p, "type"), optStr(p, "name", null));
			case "typeProfiles": return TypeTools.cProfiles();
			case "typeParseHeaders": return vc("types", t -> TypeTools.parseHeaders(this, sessionOrNull(p),
				optStr(p, "where", ""), strings(p, "files"), strings(p, "includes"), strings(p, "options"), t));
			case "typeFavorites": return TypeTools.favorites(session(p));
			case "typeSources": return TypeTools.sourceArchives(session(p));
			case "typeSyncList": return TypeTools.syncList(this, session(p), reqStr(p, "archive"));
			case "typeSync": return TypeTools.syncAction(this, session(p), reqStr(p, "archive"), strings(p, "paths"),
				reqStr(p, "action"));
			case "typeUses": return vc("types", t -> TypeTools.findUses(session(p), reqStr(p, "path"),
				optStr(p, "field", ""), optBool(p, "decompile", false), t));
			case "typePreview": {
				Session ts = session(p);
				return TypeTools.preview(ts, a(ts, p), strings(p, "types"));
			}
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
				optBool(p, "inclusive", true), new HashSet<>(strings(p, "collapsed")));
			case "hex": return s.hexDump(a(s, p), optInt(p, "length", 4096));
			case "byteView": return s.byteView(a(s, p), optInt(p, "length", 1024), optInt(p, "align", 16));
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
			case "typeEditBegin": return TypeEdit.begin(s, reqStr(p, "path"));
			case "typeEditState": return TypeEdit.current(s, reqStr(p, "id"));
			case "typeEditOp": return TypeEdit.op(s, reqStr(p, "id"), reqStr(p, "op"), p);
			case "typeEditUndo": return TypeEdit.undo(s, reqStr(p, "id"));
			case "typeEditRedo": return TypeEdit.redo(s, reqStr(p, "id"));
			case "typeEditApply": return TypeEdit.apply(s, reqStr(p, "id"));
			case "typeEditRevert": return TypeEdit.revert(s, reqStr(p, "id"));
			case "typeEditClose": return TypeEdit.close(reqStr(p, "id"));
			case "createStruct": return Types.createStruct(s, reqStr(p, "name"), optStr(p, "category", "/"),
				optBool(p, "union", false));
			case "createEnum": return Types.createEnum(s, reqStr(p, "name"), optStr(p, "category", "/"),
				optInt(p, "size", 4));
			case "createTypedef": return Types.createTypedef(s, reqStr(p, "name"), reqStr(p, "base"));
			case "addField": return Types.addField(s, reqStr(p, "path"), reqStr(p, "type"), optStr(p, "name", null),
				optStr(p, "comment", null));
			case "fieldAt": return EditExtras.fieldAt(s, a(s, p));
			case "wildAssemble": return vc("search", t -> EditExtras.wildAssemble(s, a(s, p), reqStr(p, "instruction"),
				optBool(p, "search", false), p.has("ranges") ? Views.ranges(s, p.get("ranges")) : null, optInt(p, "max", 500), t));
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
			case "referenceGraph": return Graphs.referenceGraph(s, a(s, p), optInt(p, "depth", 1), optStr(p, "direction", "both"));
			case "blockFlowGraph": return vc("graph", t -> FlowGraphs.blockFlow(s, set(s, p), optInt(p, "limit", 1500), t));
			case "codeFlowGraph": return vc("graph", t -> FlowGraphs.codeFlow(s, set(s, p), optInt(p, "limit", 1500), t));
			case "dataGraph": return FlowGraphs.dataGraph(s, a(s, p), optInt(p, "depth", 1), optInt(p, "limit", 400));
			case "dataFlowGraph": return Views.dataFlowGraph(s, a(s, p));
			case "pcodeFlowGraph": return Views.pcodeFlowGraph(s, a(s, p));
			case "overview": return Views.overview(s, optInt(p, "buckets", 600));
			// navigation, clear, data settings, equates, labels, comments, references, function extras
			case "goNext": return Annotate.next(s, a(s, p), reqStr(p, "kind"), optBool(p, "forward", true));
			case "goTo": return Annotate.goTo(s, p.has("address") ? a(s, p) : null, reqStr(p, "query"));
			case "clearTypes": return Annotate.clearTypes();
			case "clearWith": return Annotate.clearWith(s, set(s, p), strings(p, "what"));
			case "clearFlow": return Annotate.clearFlow(s, set(s, p), optBool(p, "data", false), optBool(p, "symbols", false),
				optBool(p, "repair", true));
			case "dataSettings": return Annotate.dataSettings(s, a(s, p));
			case "setDataSetting": return Annotate.setDataSetting(s, a(s, p), reqStr(p, "name"), optStr(p, "value", ""),
				optBool(p, "default", false));
			case "cycleData": return Annotate.cycleData(s, a(s, p), reqStr(p, "group"));
			case "patchData": return Annotate.patchData(s, a(s, p), reqStr(p, "value"));
			case "equateTable": return Annotate.equateTable(s);
			case "renameEquate": return Annotate.renameEquate(s, reqStr(p, "name"), reqStr(p, "newName"));
			case "removeEquate": return Annotate.removeEquate(s, reqStr(p, "name"), p.has("address") ? a(s, p) : null);
			case "applyEnum": return Annotate.applyEnum(s, set(s, p), reqStr(p, "enum"), optBool(p, "subOperands", false));
			case "scalars": return Annotate.scalars(s, a(s, p));
			case "convert": return Annotate.convert(s, a(s, p), optInt(p, "operand", 0), p.get("value").getAsLong(),
				optInt(p, "bits", 64), reqStr(p, "format"));
			case "labelsAt": return Annotate.labelsAt(s, a(s, p));
			case "labelHistory": return Annotate.labelHistory(s, p.has("address") ? a(s, p) : null);
			case "setPrimaryLabel": return Annotate.setPrimaryLabel(s, a(s, p), reqStr(p, "name"));
			case "setPinned": return Annotate.setPinned(s, a(s, p), optStr(p, "name", null), optBool(p, "pinned", true));
			case "setEntryPoint": return Annotate.setEntryPoint(s, a(s, p), optBool(p, "on", true));
			case "commentTable": return Annotate.commentTable(s);
			case "commentHistory": return Annotate.commentHistory(s, a(s, p));
			case "referencesOf": return Annotate.referencesOf(s, a(s, p));
			case "addReferenceEx": return Annotate.addReference(s, a(s, p), optInt(p, "operand", -1), reqStr(p, "kind"),
				optStr(p, "to", null), optStr(p, "type", null), p.has("offset") ? p.get("offset").getAsLong() : 0,
				optStr(p, "register", null), optStr(p, "library", null), optStr(p, "label", null), optBool(p, "primary", false));
			case "editReference": return Annotate.editReference(s, a(s, p), reqStr(p, "to"), optInt(p, "operand", -1),
				optStr(p, "type", null), p.has("primary") ? p.get("primary").getAsBoolean() : null, optBool(p, "delete", false));
			case "setReferenceLabel": return Annotate.setReferenceLabel(s, a(s, p), reqStr(p, "to"), optInt(p, "operand", -1),
				reqStr(p, "label"));
			case "recreateFunction": return Annotate.recreateFunction(s, a(s, p));
			case "createFunctions": return Annotate.createFunctions(s, set(s, p));
			case "setThunk": return Annotate.setThunk(s, a(s, p), optStr(p, "target", ""));
			case "createExternalFunction": return Annotate.createExternalFunction(s, reqStr(p, "library"), reqStr(p, "name"),
				optStr(p, "target", null));
			case "functionExtras": return Annotate.functionExtras(s, a(s, p));
			case "setFunctionExtras": return Annotate.setFunctionExtras(s, a(s, p), optStr(p, "purge", null),
				optStr(p, "callFixup", null));
			case "setParameterStorage": return Annotate.setParameterStorage(s, a(s, p), optInt(p, "ordinal", -1),
				reqStr(p, "storage"));
			case "stackDepthChange": return Annotate.stackDepthChange(s, a(s, p), optStr(p, "value", ""));
			case "functionTags": return Annotate.functionTags(s);
			case "editFunctionTag": return Annotate.editFunctionTag(s, reqStr(p, "name"), optStr(p, "newName", null),
				optStr(p, "comment", null), optBool(p, "delete", false));
			case "functionsWithTag": return Annotate.functionsWithTag(s, reqStr(p, "name"));
			case "instructionInfo": return Annotate.instructionInfo(s, a(s, p));
			case "setFlowOverride": return Annotate.setFlowOverride(s, a(s, p), reqStr(p, "flow"));
			case "setLengthOverride": return Annotate.setLengthOverride(s, a(s, p), optInt(p, "length", 0));
			case "setFallthrough": return Annotate.setFallthrough(s, a(s, p), optStr(p, "to", ""));
			case "registerValues": return Annotate.registerValues(s, optStr(p, "register", null));
			case "clearRegisterValue": return Annotate.clearRegisterValue(s, reqStr(p, "register"), a(s, p),
				s.addr(optStr(p, "end", reqStr(p, "address"))));
			case "setBlockFlag": return Annotate.setBlockFlag(s, reqStr(p, "name"), reqStr(p, "flag"), optStr(p, "value", ""));
			case "renameOverlay": return Annotate.renameOverlay(s, reqStr(p, "name"), reqStr(p, "newName"));
			case "setColor": return Annotate.setColor(s, set(s, p), optStr(p, "color", ""));
			case "colors": return Annotate.colors(s);
			case "optionLists": return Annotate.optionLists(s);
			case "programOptions": return Annotate.options(s, reqStr(p, "list"));
			case "setProgramOption": return Annotate.setOption(s, reqStr(p, "list"), reqStr(p, "name"), optStr(p, "value", ""));
			case "properties": return Annotate.properties(s, optStr(p, "name", null));
			case "copySpecial": return Annotate.copySpecial(s, a(s, p), s.addr(optStr(p, "end", reqStr(p, "address"))),
				reqStr(p, "format"));
			case "preview": return Annotate.preview(s, a(s, p));
			case "pseudoDisassemble": return Annotate.pseudoDisassemble(s, a(s, p), optInt(p, "count", 40));
			case "treeAction": return vc("tree", t -> Layout.treeAction(s, reqStr(p, "action"), optStr(p, "tree", ""),
				optStr(p, "name", null), optStr(p, "parent", null), optStr(p, "newName", null), optStr(p, "start", null),
				optStr(p, "end", null), optInt(p, "index", 0), t));
			case "dataComponents": {
				List<Integer> path = new ArrayList<>();
				if (p.has("path")) {
					for (JsonElement e : p.getAsJsonArray("path")) {
						path.add(e.getAsInt());
					}
				}
				return Layout.dataComponents(s, a(s, p), path);
			}
			case "entropyOverview": return Layout.entropyOverview(s, optInt(p, "buckets", 600));
			case "setLanguage": return vc("language", t -> Layout.setLanguage(s, reqStr(p, "language"),
				optStr(p, "compiler", null), t));
			case "setListingFields": s.listingFields = new HashSet<>(strings(p, "fields")); return true;
			case "setBreakpoint": return Debug.setBreakpoint(s, a(s, p), optStr(p, "state", "enabled"), optStr(p, "name", null));
			case "clearBreakpoints": return Debug.clearBreakpoints(s);
			case "describeAddresses": return Debug.describe(s, strings(p, "addresses"));
			case "select": return vc("select", t -> Views.select(s, reqStr(p, "kind"), a(s, p),
				Views.ranges(s, p.get("ranges")), t));
			case "selectionAction": return Views.selectionAction(s, reqStr(p, "action"), Views.ranges(s, p.get("ranges")));
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
			case "runScript": {
				List<String> args = new ArrayList<>();
				if (p.has("args")) {
					for (JsonElement e : p.getAsJsonArray("args")) {
						args.add(e.getAsString());
					}
				}
				return vc("script", t -> Scripts.run(s, reqStr(p, "path"), optStr(p, "address", null),
					args.toArray(new String[0]), t));
			}
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

			// decompiler extras
			// memory map, namespaces, externals
			case "addBlockEx": return More.addBlock(s, reqStr(p, "name"), a(s, p), Long.decode(reqStr(p, "length")),
				optStr(p, "kind", "initialized"), optBool(p, "overlay", false), optStr(p, "source", null),
				optStr(p, "comment", null));
			case "setImageBase": return More.setImageBase(s, a(s, p));
			case "expandBlock": return More.expandBlock(s, reqStr(p, "name"), a(s, p));
			case "createNamespace": return More.createNamespace(s, p.has("parent") ? p.get("parent").getAsLong() : 0,
				reqStr(p, "name"), optBool(p, "class", false));
			case "convertToClass": return More.convertToClass(s, p.get("id").getAsLong());
			case "moveSymbol": return More.moveSymbol(s, p.get("id").getAsLong(), p.get("namespace").getAsLong());
			case "deleteSymbol": return More.deleteSymbol(s, p.get("id").getAsLong());
			case "namespaces": return More.namespaces(s);
			case "externals": return More.externals(s);
			case "setExternalPath": return More.setExternalPath(s, reqStr(p, "library"), optStr(p, "path", null));
			case "editExternal": return More.editExternal(s, p.get("id").getAsLong(), optStr(p, "label", null),
				optStr(p, "target", null));

			// disassembly, search, diff
			case "disassembleEx": return More.disassemble(s, a(s, p), p.has("end") ? s.addr(reqStr(p, "end")) : null,
				optStr(p, "register", null), optStr(p, "value", "0"), optBool(p, "restricted", false));
			case "searchValue": return More.searchValue(s, reqStr(p, "kind"), reqStr(p, "text"), optInt(p, "size", 4),
				optStr(p, "encoding", "ascii"));
			case "searchRegex": return More.searchRegex(s, reqStr(p, "regex"));
			case "addressTables": return More.addressTables(s, optInt(p, "minLength", 3));
			case "applyDiff": {
				List<String[]> ranges = new ArrayList<>();
				for (JsonElement e : p.getAsJsonArray("ranges")) {
					JsonObject o = e.getAsJsonObject();
					ranges.add(new String[] { o.get("address").getAsString(), o.get("end").getAsString() });
				}
				Map<String, String> settings = new HashMap<>();
				if (p.has("settings")) {
					for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("settings").entrySet()) {
						settings.put(e.getKey(), e.getValue().getAsString());
					}
				}
				return Compare.applyDiff(s, reqStr(p, "other"), ranges, new HashSet<>(strings(p, "kinds")), settings);
			}

			// decompiler, stack frame
			case "commitParams": return More.commitParams(s, s.highFunction(a(s, p)));
			case "commitLocals": return More.commitLocals(s, s.highFunction(a(s, p)));
			case "unionFields": return More.unionFields(s.token(a(s, p), optInt(p, "token", -1)));
			case "forceUnion": {
				ghidra.program.model.address.Address fa = a(s, p);
				ghidra.app.decompiler.ClangToken token = s.token(fa, optInt(p, "token", -1));
				return More.forceUnion(s, s.functionContaining(fa), token.getClangFunction().getHighFunction(), token,
					optInt(p, "field", -1));
			}
			case "stackFrame": return More.stackFrame(s, a(s, p));
			case "stackDefine": return More.stackDefine(s, a(s, p), optInt(p, "offset", 0), optStr(p, "name", null),
				reqStr(p, "type"));
			case "stackClear": return More.stackClear(s, a(s, p), optInt(p, "offset", 0));
			case "stackSizes": return More.stackSizes(s, a(s, p),
				p.has("localSize") ? p.get("localSize").getAsInt() : null,
				p.has("returnOffset") ? p.get("returnOffset").getAsInt() : null);

			// types, checksums, entropy, source files
			case "exportTypes": return More.exportTypes(s, reqStr(p, "path"), strings(p, "types"));
			case "functionDefinition": return More.functionDefinition(s, reqStr(p, "signature"), optStr(p, "category", "/"));
			case "checksums": return More.checksums(s, p.has("address") ? a(s, p) : null,
				p.has("end") ? s.addr(reqStr(p, "end")) : null);
			case "entropy": return More.entropy(s, optInt(p, "chunk", 256));
			case "pdbInfo": return More.pdbInfo(s);
			case "pdbDownload": return vc("pdb", t -> {
				java.io.File pdb = More.pdbDownload(s, new java.io.File(supportDir(), "Symbols"),
					optStr(p, "server", "https://msdl.microsoft.com/download/symbols/"), t);
				s.loadPdb(pdb.getAbsolutePath());
				return map("path", pdb.getAbsolutePath());
			});
			case "sourceFiles": return More.sourceFiles(s);
			case "sourceLines": return More.sourceLines(s, reqStr(p, "path"));

			case "splitVariable": return s.splitVariable(a(s, p), optInt(p, "token", -1), reqStr(p, "name"));
			case "tokenInfo": return Decomp.tokenInfo(s, a(s, p), optInt(p, "token", -1));
			case "decompEquate": return Decomp.setEquate(s, a(s, p), optInt(p, "token", -1), optStr(p, "format", "unsignedHex"),
				optStr(p, "name", null));
			case "retypeReturn": return Decomp.retypeReturn(s, a(s, p), reqStr(p, "type"));
			case "retypeField": return Decomp.retypeField(s, reqStr(p, "type"), optInt(p, "offset", 0), reqStr(p, "newType"));
			case "adjustPointerOffset": return Decomp.adjustPointerOffset(s, a(s, p), reqStr(p, "name"), reqStr(p, "type"),
				Long.decode(optStr(p, "offset", "0")));
			case "decompSearch": return vc("search", t -> Decomp.search(s, reqStr(p, "query"), optBool(p, "regex", false),
				optBool(p, "caseSensitive", false), optInt(p, "limit", 2000), t));
			case "decompDebug": return Decomp.debug(s, a(s, p), reqStr(p, "path"));
			case "specExtensions": return Decomp.specExtensions(s);
			case "addSpecExtension": return Decomp.addSpecExtension(s, reqStr(p, "xml"));
			case "removeSpecExtension": return Decomp.removeSpecExtension(s, reqStr(p, "key"));
			case "ctadlStatus": return Ctadl.status(this, s, optStr(p, "engine", ""));
			case "ctadlIndex": return vc("taint", t -> Ctadl.index(this, s, optStr(p, "engine", ""), t));
			case "ctadlQuery": return vc("taint", t -> Ctadl.query(this, s, optStr(p, "engine", ""), a(s, p),
				strings(p, "sources"), strings(p, "sinks"), optStr(p, "direction", ""), optStr(p, "format", "sarif+all"),
				optBool(p, "allAccess", false), optStr(p, "custom", ""), t));
			case "taint": return vc("taint", t -> Decomp.taint(s, a(s, p), strings(p, "sources"), strings(p, "sinks"),
				optInt(p, "depth", 3), t));
			case "slice": return s.slice(a(s, p), optInt(p, "token", -1), optBool(p, "forward", true));
			case "renameField": return s.renameField(reqStr(p, "type"), optInt(p, "offset", 0), reqStr(p, "name"));
			case "overrideSignature": return s.overrideSignature(a(s, p), s.addr(reqStr(p, "callSite")),
				reqStr(p, "signature"));
			case "decompilerOptions": return s.decompilerOptions();
			case "setDecompilerOption": return s.setDecompilerOption(reqStr(p, "key"), reqStr(p, "value"));

			// analysis extras
			case "analyzerOptions": return s.analyzerOptions(reqStr(p, "analyzer"));
			case "setAnalyzerOption": return s.setAnalyzerOption(reqStr(p, "name"), reqStr(p, "value"));
			case "runAnalyzer": s.runAnalyzer(reqStr(p, "name")); return true;
			case "loadPdb": return s.loadPdb(reqStr(p, "path"));

			// listing ranges, registers, data, functions
			case "disassembleRange": return Edits.disassembleRange(s, a(s, p), s.addr(reqStr(p, "end")));
			case "clearRange": return Edits.clearRange(s, a(s, p), s.addr(reqStr(p, "end")));
			case "createArray": return Edits.createArray(s, a(s, p), reqStr(p, "type"), optInt(p, "count", 1));
			case "structFromRange": return Edits.structFromRange(s, a(s, p), s.addr(reqStr(p, "end")),
				optStr(p, "name", null));
			case "defineString": return Edits.defineString(s, a(s, p), optInt(p, "length", -1),
				optBool(p, "unicode", false));
			case "contextRegisters": return Edits.contextRegisters(s, a(s, p));
			case "setRegister": return Edits.setRegister(s, a(s, p), s.addr(optStr(p, "end", reqStr(p, "address"))),
				reqStr(p, "register"), optStr(p, "value", null));
			case "setDataFormat": return Edits.setDataFormat(s, a(s, p), reqStr(p, "format"));
			case "functionProperties": return Edits.functionProperties(s, a(s, p));
			case "editFunction": return Edits.editFunction(s, a(s, p), optStr(p, "callingConvention", null),
				p.has("noReturn") ? p.get("noReturn").getAsBoolean() : null,
				p.has("inline") ? p.get("inline").getAsBoolean() : null,
				p.has("varArgs") ? p.get("varArgs").getAsBoolean() : null,
				p.has("customStorage") ? p.get("customStorage").getAsBoolean() : null);
			case "editVariable": return Edits.editVariable(s, a(s, p), reqStr(p, "name"), optStr(p, "newName", null),
				optStr(p, "type", null));
			case "setFunctionTag": return Edits.setTag(s, a(s, p), reqStr(p, "tag"), optBool(p, "on", true));
			case "splitBlock": return Edits.splitBlock(s, reqStr(p, "name"), a(s, p));
			case "joinBlocks": return Edits.joinBlocks(s, reqStr(p, "name"), reqStr(p, "other"));
			case "moveBlock": return Edits.moveBlock(s, reqStr(p, "name"), a(s, p));

			// tables
			case "symbolTable": {
				Set<String> kinds = new HashSet<>();
				if (p.has("kinds")) {
					for (JsonElement e : p.getAsJsonArray("kinds")) {
						kinds.add(e.getAsString());
					}
				}
				return Tables.symbols(s, optStr(p, "filter", ""), kinds, optBool(p, "userOnly", false));
			}
			case "relocations": return Tables.relocations(s);
			case "programTree": return Tables.programTree(s);
			case "instructionPattern": {
				ghidra.program.model.address.Address start = a(s, p);
				ghidra.program.model.address.Address end = s.addr(optStr(p, "end", reqStr(p, "address")));
				if (p.has("count")) {
					int n = 0;
					for (ghidra.program.model.listing.Instruction ins : s.program.getListing().getInstructions(start, true)) {
						end = ins.getMaxAddress();
						if (++n >= p.get("count").getAsInt()) {
							break;
						}
					}
				}
				return Search.instructionPattern(s, start, end, optBool(p, "maskOperands", true));
			}
			case "replaceText": {
				Set<String> scopes = new HashSet<>();
				for (JsonElement e : p.getAsJsonArray("scopes")) {
					scopes.add(e.getAsString());
				}
				return Search.replace(s, reqStr(p, "query"), optStr(p, "replacement", ""), optBool(p, "regex", false),
					optBool(p, "caseSensitive", false), scopes);
			}
			case "findStrings": return Tables.findStrings(s, optInt(p, "minLength", 5), optBool(p, "nullTerminated", true),
				optBool(p, "undefinedOnly", true));
			case "memScan": return vc("search", t -> Finder.scan(s, reqStr(p, "pattern"), strings(p, "blocks"),
				strings(p, "codeTypes"), optInt(p, "align", 1), Views.ranges(s, p.get("ranges")), t));
			case "encodePattern": return hex(More.encode(s, reqStr(p, "kind"), reqStr(p, "text"), optInt(p, "size", 4),
				optStr(p, "encoding", "ascii")), 4096);
			case "readValues": return Finder.readValues(s, strings(p, "addresses"), optInt(p, "size", 1));
			case "directReferences": return vc("search", t -> Finder.directReferences(s, set(s, p), optInt(p, "align", 1), t));
			case "dataTable": return Finder.dataTable(s, optStr(p, "filter", ""));
			case "functionTable": return Finder.functionTable(s);
			case "stringTable": return Finder.stringTable(s);
			case "translate": {
				Map<String, String> translations = new LinkedHashMap<>();
				for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("translations").entrySet()) {
					translations.put(e.getKey(), e.getValue().isJsonNull() ? null : e.getValue().getAsString());
				}
				return Finder.translate(s, translations, p.has("show") ? p.get("show").getAsBoolean() : null);
			}
			case "mediaTable": return vc("search", t -> Finder.media(s, t));
			case "saveBytes": return Finder.saveBytes(s, a(s, p), p.get("length").getAsLong(), reqStr(p, "path"));
			case "sourceTransforms": return Finder.sourceTransforms(s);
			case "setSourceTransform": return Finder.setSourceTransform(s, optStr(p, "kind", "file"), reqStr(p, "source"),
				optStr(p, "target", ""));
			case "localSourcePath": return Finder.localSourcePath(s, reqStr(p, "path"));
			case "searchScalar": return Tables.searchScalar(s, reqStr(p, "value"));

			// struct editor & archives
			case "insertField": return Types.insertField(s, reqStr(p, "path"), optInt(p, "offset", 0), reqStr(p, "type"),
				optStr(p, "name", null), optStr(p, "comment", null));
			case "moveField": return Types.moveField(s, reqStr(p, "path"), optInt(p, "ordinal", 0), optInt(p, "delta", 1));
			case "addBitField": return Types.addBitField(s, reqStr(p, "path"), reqStr(p, "type"), optInt(p, "bits", 1),
				optStr(p, "name", null));
			case "setPacking": return Types.setPacking(s, reqStr(p, "path"), optBool(p, "enabled", true),
				optInt(p, "value", 0));
			case "setAlignment": return Types.setAlignment(s, reqStr(p, "path"), optInt(p, "value", 0));
			case "setStructSize": return Types.setStructSize(s, reqStr(p, "path"), optInt(p, "size", 0));
			case "removeEnumValue": return Types.removeEnumValue(s, reqStr(p, "path"), reqStr(p, "name"));
			case "archiveTypes": return Types.archiveTypes(reqStr(p, "path"), optStr(p, "filter", ""));
			case "importArchiveTypes": {
				List<String> names = new ArrayList<>();
				for (JsonElement e : p.getAsJsonArray("types")) {
					names.add(e.getAsString());
				}
				return Types.importArchiveTypes(s, reqStr(p, "path"), names);
			}

			// function comparison
			case "functionText": return Compare.functionText(s, optStr(p, "other", null), reqStr(p, "address"),
				optStr(p, "mode", "c"));
			case "functionsOf": return Compare.functionsOf(s, reqStr(p, "other"));
			case "emuSkipExternal": s.emulation.setSkipExternal(optBool(p, "on", true)); return s.emulation.state();

			// emulator
			case "emuState": return s.emulation.state();
			case "emuStart": return s.emulation.start(a(s, p));
			case "emuStartFrom": {
				Map<String, String> registers = new LinkedHashMap<>();
				if (p.has("registers")) {
					for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("registers").entrySet()) {
						registers.put(e.getKey(), e.getValue().getAsString());
					}
				}
				List<String[]> memory = new ArrayList<>();
				if (p.has("memory")) {
					for (JsonElement e : p.getAsJsonArray("memory")) {
						memory.add(new String[] { e.getAsJsonArray().get(0).getAsString(), e.getAsJsonArray().get(1).getAsString() });
					}
				}
				return s.emulation.startFrom(a(s, p), registers, memory);
			}
			case "emuStep": return s.emulation.step(optInt(p, "count", 1));
			case "emuRun": return s.emulation.run();
			case "emuPcodeStep": return s.emulation.pcodeStep(optInt(p, "count", 1));
			case "emuWatches": return s.emulation.setWatches(strings(p, "expressions"));
			case "emuNewThread": return s.emulation.newThread(a(s, p));
			case "emuSwitchThread": return s.emulation.switchThread(optInt(p, "index", 0));
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
				return Compare.diff(s, reqStr(p, "other"), kinds, Views.ranges(s, p.get("ranges")));
			}
			case "diffDetails": return CompareTools.diffDetails(s, reqStr(p, "other"), a(s, p));
			case "functionTextEx": return CompareTools.functionText(s, optStr(p, "other", null), reqStr(p, "address"),
				optStr(p, "mode", "c"), optStr(p, "ignore", "none"));
			case "tokenMatch": return vc("compare", t -> CompareTools.tokenMatch(s, optStr(p, "other", null), a(s, p),
				reqStr(p, "otherAddress"), optBool(p, "exactConstants", false), t));
			case "applyFunction": return CompareTools.applyFunction(s, optStr(p, "other", null), a(s, p),
				reqStr(p, "otherAddress"), optStr(p, "what", "name"));
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

	private interface Monitored {
		Object run(Progress monitor) throws Exception;
	}

	private Object vc(String name, Monitored body) throws Exception {
		Progress t = task(name);
		try {
			return body.run(t);
		}
		finally {
			t.done();
		}
	}

	/** The address set a request acts on: "ranges" ([[start, end], …]) or "address" [+ "end"]. */
	private static ghidra.program.model.address.AddressSet set(Session s, JsonObject p) {
		ghidra.program.model.address.AddressSet set = Views.ranges(s, p.get("ranges"));
		if (set.isEmpty() && p.has("address") && !p.get("address").isJsonNull()) {
			ghidra.program.model.address.Address start = s.addr(reqStr(p, "address"));
			set.add(start, s.addr(optStr(p, "end", reqStr(p, "address"))));
		}
		return set;
	}

	private static ghidra.program.model.address.Address a(Session s, JsonObject p) {
		return s.addr(reqStr(p, "address"));
	}

	Session sessionFor(String domainPath) {
		return sessions.get(domainPath);
	}

	private Session sessionOrNull(JsonObject p) {
		return optStr(p, "session", null) == null && active == null ? null : session(p);
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
		m.put("server", Repo.status(project.getProject()));
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
				"versioned", f.isVersioned(), "checkedOut", f.isCheckedOut(),
				"version", f.isVersioned() ? f.getVersion() : null,
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
		String source = reqStr(p, "path");
		String folderPath = optStr(p, "folder", "/");
		boolean analyze = optBool(p, "analyze", true);
		boolean openIt = optBool(p, "open", true);
		Map<String, String> loaderArgs = new LinkedHashMap<>();
		if (p.has("loaderArgs") && p.get("loaderArgs").isJsonObject()) {
			for (Map.Entry<String, JsonElement> e : p.getAsJsonObject("loaderArgs").entrySet()) {
				loaderArgs.put(e.getKey(), e.getValue().getAsString());
			}
		}
		String display = Importer.fsrl(source).getName();
		progress("Importando " + display + "…");
		folder(folderPath, true);
		List<String> paths = Importer.importSource(this, source, folderPath, optStr(p, "name", null),
			optStr(p, "loader", null), optStr(p, "language", null), optStr(p, "compiler", null), loaderArgs);
		if (!openIt) {
			return map("path", paths.get(0), "imported", paths);
		}
		File local = new File(source);
		Map<String, Object> info = openProgram(paths.get(0), false, local.isFile() ? local.getAbsolutePath() : null);
		info.put("imported", paths);
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

	/** Opens an older version of a versioned file, read-only, next to whatever else is open. */
	private Map<String, Object> openVersion(String domainPath, int version) throws Exception {
		String id = domainPath + "@" + version;
		Session existing = sessions.get(id);
		if (existing != null) {
			active = existing;
			return existing.info();
		}
		DomainFile df = file(domainPath);
		Object consumer = new Object();
		Program program = (Program) df.getReadOnlyDomainObject(consumer, version, TaskMonitor.DUMMY);
		try {
			return register(new Session(this, program, consumer, null, id)).info();
		}
		catch (Exception e) {
			program.release(consumer);
			throw e;
		}
	}

	/**
	 * Opens the program a server URL points to (ghidra://host/repository/folder/program), read-only and
	 * without the shared project, the way the classic's GhidraGo does.
	 */
	private Map<String, Object> openURL(String text, String user, String password) throws Exception {
		java.net.URL url = ghidra.framework.protocol.ghidra.GhidraURL.toURL(text);
		// the same program is the same session whatever place inside it the URL names
		int hash = text.indexOf('#');
		String id = "url:" + ghidra.framework.protocol.ghidra.GhidraURL.getDisplayString(
			ghidra.framework.protocol.ghidra.GhidraURL.toURL(hash < 0 ? text : text.substring(0, hash)));
		Session existing = sessions.get(id);
		if (existing != null) {
			active = existing;
			return existing.info();
		}
		if ((user != null && !user.isBlank()) || (password != null && !password.isEmpty())) {
			Repo.credentials(user, password);
		}
		else {
			Repo.credentials(null, null);     // makes sure Studio's authenticator is the one asked
		}
		ghidra.framework.protocol.ghidra.Handler.registerHandler();
		ghidra.framework.protocol.ghidra.GhidraURLConnection c =
			new ghidra.framework.protocol.ghidra.GhidraURLConnection(url);
		c.setReadOnly(true);
		Object content;
		try {
			content = c.getContent();
		}
		catch (java.io.IOException e) {
			throw new IllegalStateException("@auth:No se pudo conectar con el servidor: " + e.getMessage());
		}
		ghidra.framework.protocol.ghidra.GhidraURLConnection.StatusCode status = c.getStatusCode();
		if (status == ghidra.framework.protocol.ghidra.GhidraURLConnection.StatusCode.UNAUTHORIZED) {
			throw new IllegalStateException("@auth:El servidor pide usuario y contraseña para esa URL");
		}
		if (!(content instanceof ghidra.framework.protocol.ghidra.GhidraURLWrappedContent wrapped)) {
			throw new IllegalArgumentException("La URL no lleva a ningún archivo (" + status + ")");
		}
		Object holder = new Object();
		Object target = wrapped.getContent(holder);
		boolean keep = false;
		try {
			if (!(target instanceof DomainFile df)) {
				throw new IllegalArgumentException("La URL lleva a una carpeta, no a un programa");
			}
			if (!Program.class.isAssignableFrom(df.getDomainObjectClass())) {
				throw new IllegalArgumentException("El archivo de la URL no es un programa: " + df.getContentType());
			}
			Object consumer = new Object();
			Program program = (Program) df.getReadOnlyDomainObject(consumer, DomainFile.DEFAULT_VERSION, TaskMonitor.DUMMY);
			try {
				Session s = new Session(this, program, consumer, null, id);
				s.afterClose = () -> wrapped.release(target, holder);
				keep = true;
				Map<String, Object> info = register(s).info();
				if (url.getRef() != null) {
					info.put("reference", url.getRef());
				}
				return info;
			}
			catch (Exception e) {
				program.release(consumer);
				throw e;
			}
		}
		finally {
			if (!keep) {
				wrapped.release(target, holder);
			}
		}
	}

	private Map<String, Object> openProgram(String domainPath, boolean analyze) throws Exception {
		return openProgram(domainPath, analyze, null);
	}

	private Map<String, Object> openProgram(String domainPath, boolean analyze, String sourcePath) throws Exception {
		return openProgram(domainPath, analyze, sourcePath, null);
	}

	/** recover: null = ask the UI when a recovery snapshot exists, true = use it, false = discard it. */
	private Map<String, Object> openProgram(String domainPath, boolean analyze, String sourcePath, Boolean recover)
			throws Exception {
		Session existing = sessions.get(domainPath);
		if (existing != null) {
			active = existing;
			return existing.info();
		}
		DomainFile df = file(domainPath);
		if (recover == null && df.canRecover()) {
			throw new RecoverableException(domainPath);
		}
		progress("Abriendo " + df.getName() + "…");
		// Open through the project API (not GhidraProject) so undo/redo history works.
		Object consumer = new Object();
		// A versioned file that is not checked out can only be looked at (like the classic Ghidra).
		boolean readOnly = df.isVersioned() && !df.isCheckedOut();
		Program program = readOnly
				? (Program) df.getReadOnlyDomainObject(consumer, DomainFile.DEFAULT_VERSION, TaskMonitor.DUMMY)
				: (Program) df.getDomainObject(consumer, true, Boolean.TRUE.equals(recover), TaskMonitor.DUMMY);
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
		return closeSession(s, true);
	}

	private Object closeSession(Session s, boolean save) {
		s.close(save);
		sessions.remove(s.id);
		if (active == s) {
			active = sessions.isEmpty() ? null : sessions.values().iterator().next();
		}
		return map("active", active != null ? active.id : null);
	}

	private void closeAll() {
		vt.close(true);
		for (Session s : new ArrayList<>(sessions.values())) {
			closeSession(s);
		}
	}

	private void progress(String message) {
		send(map("event", "progress", "message", Msg.t(message), "value", -1.0));
	}
}
