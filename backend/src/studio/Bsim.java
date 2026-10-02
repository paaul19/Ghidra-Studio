package studio;

import static studio.Json.*;

import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.util.*;

import ghidra.features.bsim.query.*;
import ghidra.features.bsim.query.FunctionDatabase.BSimError;
import ghidra.features.bsim.query.description.*;
import ghidra.features.bsim.query.file.BSimH2FileDBConnectionManager;
import ghidra.features.bsim.query.file.BSimH2FileDBConnectionManager.BSimH2FileDataSource;
import ghidra.features.bsim.query.protocol.*;
import ghidra.framework.model.DomainFile;
import ghidra.framework.protocol.ghidra.GhidraURL;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Program;
import ghidra.util.task.TaskMonitor;

/**
 * BSim: function similarity search against a signature database.
 * A database is either a local H2 file (path ending in .mv.db) or a server URL
 * (postgresql://host/db, elastic://host/db, file:/path).
 */
final class Bsim {
	static final String[] TEMPLATES = { "medium_nosize", "medium_32", "medium_64", "medium_cpool" };

	private Bsim() {
	}

	interface Body<T> {
		T run(FunctionDatabase db) throws Exception;
	}

	private static BSimServerInfo serverInfo(String database) throws Exception {
		if (database.contains("://") || database.startsWith("file:")) {
			return new BSimServerInfo(BSimClientFactory.deriveBSimURL(database));
		}
		return new BSimServerInfo(database);
	}

	static String error(FunctionDatabase db) {
		BSimError e = db.getLastError();
		return e != null ? e.message : "BSim";
	}

	/** Opens the database, runs body and releases the H2 file if nobody else had it open. */
	static <T> T with(String database, boolean initialize, Body<T> body) throws Exception {
		BSimServerInfo info = serverInfo(database);
		boolean isFile = info.getDBType() == BSimServerInfo.DBType.file;
		BSimH2FileDataSource existing = isFile ? BSimH2FileDBConnectionManager.getDataSourceIfExists(info) : null;
		try (FunctionDatabase db = BSimClientFactory.buildClient(info, false)) {
			if (initialize && !db.initialize()) {
				throw new IOException(error(db));
			}
			return body.run(db);
		}
		finally {
			if (isFile && existing == null) {
				BSimH2FileDataSource ds = BSimH2FileDBConnectionManager.getDataSourceIfExists(info);
				if (ds != null) {
					ds.dispose();
				}
			}
		}
	}

	static File home(StudioServer server) {
		File dir = new File(server.supportDir(), "BSim");
		dir.mkdirs();
		return dir;
	}

	/** Local H2 databases kept in the application support folder. */
	static List<Map<String, Object>> databases(StudioServer server) {
		List<Map<String, Object>> out = new ArrayList<>();
		File[] files = home(server).listFiles((d, n) -> n.endsWith(BSimServerInfo.H2_FILE_EXTENSION));
		if (files != null) {
			Arrays.sort(files);
			for (File f : files) {
				String name = f.getName();
				out.add(map("name", name.substring(0, name.length() - BSimServerInfo.H2_FILE_EXTENSION.length()),
					"path", f.getAbsolutePath(), "size", f.length(), "local", true));
			}
		}
		return out;
	}

	static Map<String, Object> create(StudioServer server, String name, String template, String directory)
			throws Exception {
		File dir = directory != null && !directory.isBlank() ? new File(directory) : home(server);
		dir.mkdirs();
		File base = new File(dir, safeName(name));
		File file = new File(base.getPath() + BSimServerInfo.H2_FILE_EXTENSION);
		if (file.exists()) {
			throw new IllegalArgumentException("Ya existe una base de datos BSim con ese nombre");
		}
		with(base.getAbsolutePath(), false, db -> {
			CreateDatabase command = new CreateDatabase();
			command.info = new DatabaseInformation();
			command.info.databasename = name;
			command.config_template = template == null || template.isBlank() ? TEMPLATES[0] : template;
			command.info.trackcallgraph = true;
			if (command.execute(db) == null) {
				throw new IOException(error(db));
			}
			return null;
		});
		return map("name", name, "path", file.getAbsolutePath(), "size", file.length(), "local", true);
	}

	private static Map<String, Object> exe(ExecutableRecord r) {
		Date date = r.getDate();
		return map("name", r.getNameExec(), "md5", r.getMd5(), "architecture", r.getArchitecture(),
			"compiler", r.getNameCompiler(), "date", date != null ? date.getTime() : null,
			"repository", r.getRepository(), "path", r.getPath(), "library", r.isLibrary());
	}

	static Map<String, Object> info(String database) throws Exception {
		return with(database, true, db -> {
			DatabaseInformation i = db.getInfo();
			QueryExeInfo q = new QueryExeInfo();
			q.limit = 2000;
			ResponseExe r = q.execute(db);
			List<Map<String, Object>> exes = new ArrayList<>();
			if (r != null) {
				for (ExecutableRecord rec : r.records) {
					exes.add(exe(rec));
				}
			}
			return map("name", i.databasename, "owner", i.owner, "description", i.description,
				"version", i.major + "." + i.minor, "layout", i.layout_version, "readOnly", i.readonly,
				"callGraph", i.trackcallgraph, "url", db.getURLString(), "categories", i.execats,
				"tags", i.functionTags, "executables", exes, "count", r != null ? r.recordCount : 0);
		});
	}

	/** Generates signatures for every function of the program and stores them in the database. */
	static Map<String, Object> addProgram(Session s, String database, TaskMonitor monitor) throws Exception {
		Program program = s.program;
		return with(database, true, db -> {
			DatabaseInformation dbInfo = db.getInfo();
			GenSignatures gensig = new GenSignatures(dbInfo.trackcallgraph);
			try {
				gensig.setVectorFactory(db.getLSHVectorFactory());
				gensig.addExecutableCategories(dbInfo.execats);
				gensig.addFunctionTags(dbInfo.functionTags);
				gensig.addDateColumnName(dbInfo.dateColumnName);

				String repo = null;
				String path = null;
				DomainFile df = program.getDomainFile();
				URL url = df.getSharedProjectURL(null);
				if (url == null) {
					url = df.getLocalProjectURL(null);
				}
				if (url != null) {
					path = GhidraURL.getProjectPathname(url);
					int slash = path.lastIndexOf('/');
					path = slash <= 0 ? "/" : path.substring(0, slash);
					repo = GhidraURL.getProjectURL(url).toExternalForm();
				}
				gensig.openProgram(program, null, null, null, repo, path);
				FunctionManager fm = program.getFunctionManager();
				gensig.scanFunctions(fm.getFunctions(true), fm.getFunctionCount(), monitor);
				DescriptionManager manager = gensig.getDescriptionManager();
				if (manager.numFunctions() == 0) {
					throw new IllegalStateException("El programa no tiene funciones con cuerpo");
				}
				manager.listAllFunctions().forEachRemaining(fd -> fd.sortCallgraph());
				InsertRequest insert = new InsertRequest();
				insert.manage = manager;
				ResponseInsert resp = insert.execute(db);
				if (resp == null) {
					throw new IOException(error(db));
				}
				ResponseExe count = new QueryExeCount().execute(db);
				return map("executables", resp.numexe, "functions", resp.numfunc,
					"total", count != null ? count.recordCount : null);
			}
			finally {
				gensig.dispose();
			}
		});
	}

	static Object removeExecutable(String database, String md5) throws Exception {
		return with(database, true, db -> {
			ExeSpecifier spec = new ExeSpecifier();
			spec.exemd5 = md5;
			QueryDelete q = new QueryDelete();
			q.addSpecifier(spec);
			ResponseDelete r = q.execute(db);
			if (r == null) {
				throw new IOException(error(db));
			}
			return map("deleted", r.reslist.size(), "missed", r.missedlist.size());
		});
	}

	/**
	 * Finds functions similar to one function (address) or to every function of the program.
	 * One row per match, best matches first within each queried function.
	 */
	/** filters: kind -> value, with kind one of exe / notExe / arch / notArch / compiler / notCompiler / md5 / path. */
	private static ghidra.features.bsim.query.protocol.BSimFilter filter(Map<String, String> filters) {
		ghidra.features.bsim.query.protocol.BSimFilter f = new ghidra.features.bsim.query.protocol.BSimFilter();
		if (filters == null) {
			return f;
		}
		for (Map.Entry<String, String> e : filters.entrySet()) {
			if (e.getValue() == null || e.getValue().isBlank()) {
				continue;
			}
			ghidra.features.bsim.gui.filters.BSimFilterType type = switch (e.getKey()) {
				case "exe" -> new ghidra.features.bsim.gui.filters.ExecutableNameBSimFilterType();
				case "notExe" -> new ghidra.features.bsim.gui.filters.NotExecutableNameBSimFilterType();
				case "arch" -> new ghidra.features.bsim.gui.filters.ArchitectureBSimFilterType();
				case "notArch" -> new ghidra.features.bsim.gui.filters.NotArchitectureBSimFilterType();
				case "compiler" -> new ghidra.features.bsim.gui.filters.CompilerBSimFilterType();
				case "notCompiler" -> new ghidra.features.bsim.gui.filters.NotCompilerBSimFilterType();
				case "md5" -> new ghidra.features.bsim.gui.filters.Md5BSimFilterType();
				case "path" -> new ghidra.features.bsim.gui.filters.PathStartsBSimFilterType();
				default -> null;
			};
			if (type != null) {
				for (String value : e.getValue().split(",")) {
					if (!value.isBlank()) {
						f.addAtom(type, value.trim());
					}
				}
			}
		}
		return f;
	}

	/** How much of an executable of the database also appears in each of the others. */
	static List<Map<String, Object>> compareExecutables(String database, String md5, TaskMonitor monitor)
			throws Exception {
		return with(database, true, db -> {
			ghidra.features.bsim.query.client.ExecutableComparison cmp =
				new ghidra.features.bsim.query.client.ExecutableComparison(db, 1000000, md5, null, monitor);
			cmp.addAllExecutables(5000);
			ghidra.features.bsim.query.client.ExecutableScorer scorer = cmp.getScorer();
			if (!cmp.isConfigured()) {
				cmp.resetThresholds(0.7, 10.0);
			}
			cmp.fillinSelfScores();
			cmp.performScoring();
			List<Map<String, Object>> out = new ArrayList<>();
			for (int i = 1; i <= scorer.numExecutables(); i++) {
				ExecutableRecord other = scorer.getExecutable(i);
				if (other.getMd5().equals(md5) || scorer.getScore(i) == 0.0f) {
					continue;
				}
				out.add(map("name", other.getNameExec(), "md5", other.getMd5(), "architecture", other.getArchitecture(),
					"library", num(scorer.getNormalizedScore(i, true)), "total", num(scorer.getNormalizedScore(i, false))));
			}
			out.sort((a, b) -> Double.compare((Double) b.get("library"), (Double) a.get("library")));
			return out;
		});
	}

	static Map<String, Object> query(Session s, String database, String address, int max, double similarity,
			double confidence, boolean skipSelf, TaskMonitor monitor) throws Exception {
		return query(s, database, address, max, similarity, confidence, skipSelf, null, monitor);
	}

	static Map<String, Object> query(Session s, String database, String address, int max, double similarity,
			double confidence, boolean skipSelf, Map<String, String> filters, TaskMonitor monitor) throws Exception {
		Program program = s.program;
		return with(database, true, db -> {
			GenSignatures gensig = new GenSignatures(false);
			try {
				gensig.setVectorFactory(db.getLSHVectorFactory());
				gensig.openProgram(program, null, null, null, null, null);
				FunctionManager fm = program.getFunctionManager();
				if (address != null && !address.isBlank()) {
					Function f = fm.getFunctionContaining(s.addr(address));
					if (f == null) {
						throw new IllegalArgumentException("No hay ninguna función en " + address);
					}
					gensig.scanFunction(f);
				}
				else {
					gensig.scanFunctions(fm.getFunctionsNoStubs(true), fm.getFunctionCount(), monitor);
				}
				QueryNearest query = new QueryNearest();
				query.manage = gensig.getDescriptionManager();
				query.max = Math.max(1, max);
				query.thresh = similarity;
				query.signifthresh = confidence;
				ghidra.features.bsim.query.protocol.BSimFilter bf = filter(filters);
				if (!bf.isEmpty()) {
					query.bsimFilter = bf;
				}
				monitor.setMessage("Consultando la base de datos…");
				ResponseNearest response = query.execute(db);
				if (response == null) {
					throw new IOException(error(db));
				}
				String ownMd5 = program.getExecutableMD5();
				List<Map<String, Object>> rows = new ArrayList<>();
				for (SimilarityResult sim : response.result) {
					FunctionDescription base = sim.getBase();
					Address a = program.getAddressFactory().getDefaultAddressSpace().getAddress(base.getAddress());
					Function f = fm.getFunctionAt(a);
					for (SimilarityNote note : sim) {
						FunctionDescription fd = note.getFunctionDescription();
						ExecutableRecord er = fd.getExecutableRecord();
						if (skipSelf && ownMd5 != null && ownMd5.equals(er.getMd5())) {
							continue;
						}
						rows.add(map("address", str(a), "name", f != null ? f.getName(true) : base.getFunctionName(),
							"matchName", fd.getFunctionName(), "matchAddress", Long.toHexString(fd.getAddress()),
							"executable", er.getNameExec(), "md5", er.getMd5(), "architecture", er.getArchitecture(),
							"compiler", er.getNameCompiler(), "similarity", num(note.getSimilarity()),
							"confidence", num(note.getSignificance()),
							"defaultName", f != null && f.getSymbol().getSource() == ghidra.program.model.symbol.SourceType.DEFAULT));
					}
				}
				return map("queried", response.totalfunc, "matched", response.totalmatch, "rows", rows);
			}
			finally {
				gensig.dispose();
			}
		});
	}
}
