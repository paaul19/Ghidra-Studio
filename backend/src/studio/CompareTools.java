package studio;

import static studio.Json.*;

import java.io.File;
import java.io.IOException;
import java.util.*;

import db.*;
import db.buffers.*;
import ghidra.app.cmd.function.ApplyFunctionSignatureCmd;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.signature.DebugSignature;
import ghidra.feature.fid.db.*;
import ghidra.feature.fid.hash.FidHashQuad;
import ghidra.feature.fid.service.FidService;
import ghidra.features.bsim.query.*;
import ghidra.features.bsim.query.description.*;
import ghidra.features.bsim.query.protocol.*;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.DomainFolder;
import ghidra.framework.store.db.PackedDBHandle;
import ghidra.framework.store.db.PackedDatabase;
import ghidra.program.model.address.Address;
import ghidra.program.model.block.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.util.ProgramDiffDetails;
import ghidra.util.task.TaskMonitor;

/** Function comparison options, diff details, BSim overview and features, Function ID debugging. */
final class CompareTools {
	private CompareTools() {
	}

	// ---------------------------------------------------------------- function comparison

	/**
	 * mode: c, asm, bytes or graph (one line per basic block and where it goes).
	 * ignore (asm): none, constants (numbers become #) or operands (mnemonics only).
	 */
	static Map<String, Object> functionText(Session s, String other, String addressText, String mode, String ignore)
			throws Exception {
		if (mode.equals("c") || (mode.equals("asm") && ignore.equals("none"))) {
			return Compare.functionText(s, other, addressText, mode);
		}
		if (other == null || other.isBlank() || other.equals(s.id)) {
			return text(s.program, s.program.getAddressFactory().getAddress(addressText), mode, ignore);
		}
		return Compare.withOther(s, other, b -> text(b, b.getAddressFactory().getAddress(addressText), mode, ignore));
	}

	private static String instruction(Instruction ins, String ignore) {
		StringBuilder sb = new StringBuilder(String.format("%-8s", ins.getMnemonicString()));
		if (ignore.equals("operands")) {
			return sb.toString().trim();
		}
		for (int i = 0; i < ins.getNumOperands(); i++) {
			sb.append(i == 0 ? " " : ", ");
			StringBuilder op = new StringBuilder();
			for (Object o : ins.getDefaultOperandRepresentationList(i)) {
				// constants and addresses differ between builds of the same code
				op.append(ignore.equals("constants") && (o instanceof Scalar || o instanceof Address) ? "#" : o.toString());
			}
			sb.append(op);
		}
		return sb.toString();
	}

	private static Map<String, Object> text(Program p, Address a, String mode, String ignore) {
		Function f = p.getFunctionManager().getFunctionContaining(a);
		if (f == null) {
			throw new IllegalArgumentException("No hay ninguna función en " + a);
		}
		List<String> lines = new ArrayList<>();
		switch (mode) {
			case "bytes":
				for (Instruction ins : p.getListing().getInstructions(f.getBody(), true)) {
					try {
						lines.add(hex(ins.getBytes(), 32));
					}
					catch (Exception e) {
						lines.add("??");
					}
				}
				break;
			case "graph":
				try {
					BasicBlockModel model = new BasicBlockModel(p);
					List<CodeBlock> blocks = new ArrayList<>();
					CodeBlockIterator it = model.getCodeBlocksContaining(f.getBody(), TaskMonitor.DUMMY);
					while (it.hasNext()) {
						blocks.add(it.next());
					}
					Map<Address, Integer> index = new HashMap<>();
					for (int i = 0; i < blocks.size(); i++) {
						index.put(blocks.get(i).getFirstStartAddress(), i);
					}
					for (int i = 0; i < blocks.size(); i++) {
						CodeBlock b = blocks.get(i);
						int count = 0;
						int hash = 17;
						for (Instruction ins : p.getListing().getInstructions(b, true)) {
							count++;
							hash = hash * 31 + ins.getMnemonicString().hashCode();
						}
						List<String> out = new ArrayList<>();
						CodeBlockReferenceIterator dest = b.getDestinations(TaskMonitor.DUMMY);
						while (dest.hasNext()) {
							CodeBlockReference r = dest.next();
							if (r.getFlowType().isCall()) {
								continue;
							}
							Integer to = index.get(r.getDestinationAddress());
							out.add((r.getFlowType().isFallthrough() ? "↓" : r.getFlowType().isConditional() ? "?" : "→")
								+ (to != null ? "B" + to : "fuera"));
						}
						Collections.sort(out);
						lines.add(String.format("B%-3d %3d instr  %08x  %s", i, count, hash, String.join(" ", out)));
					}
				}
				catch (Exception e) {
					throw new IllegalStateException(e.getMessage(), e);
				}
				break;
			default:
				for (Instruction ins : p.getListing().getInstructions(f.getBody(), true)) {
					lines.add(instruction(ins, ignore));
				}
		}
		return map("name", f.getName(true), "entry", str(f.getEntryPoint()), "program", p.getName(), "lines", lines);
	}

	/** Copies the name, the signature or both from a function of the other program (or of this one). */
	static Object applyFunction(Session s, String other, Address address, String otherAddress, String what) throws Exception {
		Function target = s.functionContaining(address);
		java.util.function.Function<Program, Object[]> read = b -> {
			Function f = b.getFunctionManager().getFunctionContaining(b.getAddressFactory().getAddress(otherAddress));
			if (f == null) {
				throw new IllegalArgumentException("No hay ninguna función en " + otherAddress);
			}
			return new Object[] { f.getName(), f.getSignature(), f.getComment(), f.getSymbol().getSource() != SourceType.DEFAULT };
		};
		Object[] info = other == null || other.isBlank() || other.equals(s.id) ? read.apply(s.program)
				: Compare.withOther(s, other, read);
		return s.edit("Aplicar de la otra función", () -> {
			if ((what.equals("name") || what.equals("both")) && (Boolean) info[3]) {
				target.setName((String) info[0], SourceType.USER_DEFINED);
			}
			if (what.equals("signature") || what.equals("both")) {
				ApplyFunctionSignatureCmd cmd = new ApplyFunctionSignatureCmd(target.getEntryPoint(),
					(ghidra.program.model.listing.FunctionSignature) info[1], SourceType.USER_DEFINED, true,
					ghidra.app.cmd.function.FunctionRenameOption.NO_CHANGE);
				if (!cmd.applyTo(s.program)) {
					throw new IllegalStateException(cmd.getStatusMsg());
				}
			}
			if (what.equals("comment") && info[2] != null) {
				target.setComment((String) info[2]);
			}
			return map("name", target.getName(), "signature", target.getPrototypeString(false, false));
		});
	}

	// ---------------------------------------------------------------- decompiler diff with matched tokens

	private static ghidra.app.decompiler.DecompileResults decompile(Program p, Function f, TaskMonitor monitor) {
		ghidra.app.decompiler.DecompInterface d = new ghidra.app.decompiler.DecompInterface();
		try {
			d.toggleSyntaxTree(true);
			d.toggleCCode(true);
			d.setSimplificationStyle("decompile");
			d.openProgram(p);
			ghidra.app.decompiler.DecompileResults r = d.decompileFunction(f, 90, monitor);
			if (!r.decompileCompleted() || r.getHighFunction() == null) {
				throw new IllegalStateException("Error al descompilar " + f.getName() + ": " + r.getErrorMessage());
			}
			return r;
		}
		finally {
			d.dispose();
		}
	}

	private static List<Map<String, Object>> tokenLines(Session s, ghidra.app.decompiler.ClangTokenGroup markup,
			Map<ghidra.app.decompiler.ClangToken, Integer> pairs) {
		List<Map<String, Object>> lines = new ArrayList<>();
		for (ghidra.app.decompiler.ClangLine line : ghidra.app.decompiler.component.DecompilerUtils.toLines(markup)) {
			List<Map<String, Object>> tokens = new ArrayList<>();
			for (ghidra.app.decompiler.ClangToken t : line.getAllTokens()) {
				String text = t.getText();
				if (text == null || text.isEmpty()) {
					continue;
				}
				Map<String, Object> tm = new LinkedHashMap<>();
				tm.put("t", text);
				tm.put("s", t.getSyntaxType());
				Integer pair = pairs.get(t);
				if (pair != null) {
					tm.put("p", pair);
				}
				if (t instanceof ghidra.app.decompiler.ClangVariableToken) {
					ghidra.program.model.pcode.HighVariable hv = t.getHighVariable();
					if (hv != null) {
						boolean global = hv instanceof ghidra.program.model.pcode.HighGlobal;
						tm.put("k", global ? "global" : "var");
						if (hv.getDataType() != null) {
							tm.put("ty", hv.getDataType().getDisplayName());
						}
						ghidra.program.model.pcode.HighSymbol sym = hv.getSymbol();
						if (sym != null) {
							tm.put("v", sym.getName());
							if (global && sym.getStorage().isMemoryStorage()) {
								tm.put("target", str(sym.getStorage().getMinAddress()));
							}
						}
					}
				}
				else if (t instanceof ghidra.app.decompiler.ClangFuncNameToken fn) {
					tm.put("k", "func");
					ghidra.program.model.pcode.PcodeOp op = fn.getPcodeOp();
					if (op != null && op.getOpcode() == ghidra.program.model.pcode.PcodeOp.CALL && op.getInput(0) != null) {
						tm.put("target", str(op.getInput(0).getAddress()));
					}
				}
				tokens.add(tm);
			}
			lines.add(map("indent", line.getIndent(), "tokens", tokens));
		}
		return lines;
	}

	/**
	 * The decompiled code of two functions with their tokens paired, as the classic's decompiler diff does:
	 * tokens that mean the same get the same pair number; a token with pair -1 has no counterpart.
	 */
	static Map<String, Object> tokenMatch(Session s, String other, Address address, String otherAddress, boolean exactConstants,
			TaskMonitor monitor) throws Exception {
		Function left = s.functionContaining(address);
		ghidra.app.decompiler.DecompileResults leftResults = decompile(s.program, left, monitor);
		java.util.function.Function<Program, Map<String, Object>> body = b -> {
			Function right = b.getFunctionManager().getFunctionContaining(b.getAddressFactory().getAddress(otherAddress));
			if (right == null) {
				throw new IllegalArgumentException("No hay ninguna función en " + otherAddress);
			}
			try {
				ghidra.app.decompiler.DecompileResults rightResults = decompile(b, right, monitor);
				boolean sizeCollapse = s.program.getLanguage().getLanguageDescription().getSize()
					!= b.getLanguage().getLanguageDescription().getSize();
				ghidra.features.codecompare.graphanalysis.Pinning pin = ghidra.features.codecompare.graphanalysis.Pinning
						.makePinning(leftResults.getHighFunction(), rightResults.getHighFunction(), exactConstants,
							sizeCollapse, true, monitor);
				List<ghidra.features.codecompare.graphanalysis.TokenBin> bins =
					pin.buildTokenMap(leftResults.getCCodeMarkup(), rightResults.getCCodeMarkup());
				Map<ghidra.features.codecompare.graphanalysis.TokenBin, Integer> ids = new IdentityHashMap<>();
				Map<ghidra.app.decompiler.ClangToken, Integer> pairs = new IdentityHashMap<>();
				int next = 0;
				int unmatchedLeft = 0;
				int unmatchedRight = 0;
				for (ghidra.features.codecompare.graphanalysis.TokenBin bin : bins) {
					int id = -1;
					ghidra.features.codecompare.graphanalysis.TokenBin match = bin.getMatch();
					if (match != null) {
						Integer known = ids.get(match);
						id = known != null ? known : next++;
						ids.put(bin, id);
					}
					else if (bin.getHighFunction() == leftResults.getHighFunction()) {
						unmatchedLeft += bin.size();
					}
					else {
						unmatchedRight += bin.size();
					}
					for (ghidra.app.decompiler.ClangToken t : bin) {
						pairs.put(t, id);
					}
				}
				return map("left", map("name", left.getName(true), "entry", str(left.getEntryPoint()), "program",
					s.program.getName(), "lines", tokenLines(s, leftResults.getCCodeMarkup(), pairs)),
					"right", map("name", right.getName(true), "entry", str(right.getEntryPoint()), "program", b.getName(),
						"lines", tokenLines(s, rightResults.getCCodeMarkup(), pairs)),
					"pairs", next, "unmatchedLeft", unmatchedLeft, "unmatchedRight", unmatchedRight);
			}
			catch (ghidra.util.exception.CancelledException e) {
				throw new IllegalStateException("Cancelado");
			}
		};
		return other == null || other.isBlank() || other.equals(s.id) ? body.apply(s.program) : Compare.withOther(s, other, body);
	}

	// ---------------------------------------------------------------- diff

	/** Everything that differs at one address, as Ghidra's Diff Details window words it. */
	static Object diffDetails(Session s, String other, Address a) throws Exception {
		return Compare.withOther(s, other, b -> map("address", str(a), "details", ProgramDiffDetails.getDiffDetails(s.program, b, a)));
	}

	// ---------------------------------------------------------------- BSim

	/** For every function of the program, how many functions of the database look like it. */
	static Map<String, Object> bsimOverview(Session s, String database, double similarity, double confidence,
			TaskMonitor monitor) throws Exception {
		Program program = s.program;
		return Bsim.with(database, true, db -> {
			GenSignatures gensig = new GenSignatures(false);
			try {
				gensig.setVectorFactory(db.getLSHVectorFactory());
				gensig.openProgram(program, null, null, null, null, null);
				FunctionManager fm = program.getFunctionManager();
				gensig.scanFunctions(fm.getFunctionsNoStubs(true), fm.getFunctionCount(), monitor);
				QueryNearestVector query = new QueryNearestVector();
				query.manage = gensig.getDescriptionManager();
				query.thresh = similarity;
				query.signifthresh = confidence;
				monitor.setMessage("Consultando la base de datos…");
				ResponseNearestVector response = query.execute(db);
				if (response == null) {
					throw new IOException(Bsim.error(db));
				}
				List<Map<String, Object>> rows = new ArrayList<>();
				for (SimilarityVectorResult r : response.result) {
					FunctionDescription base = r.getBase();
					Address a = program.getAddressFactory().getDefaultAddressSpace().getAddress(base.getAddress());
					Function f = fm.getFunctionAt(a);
					double self = base.getSignatureRecord() != null
							? db.getLSHVectorFactory().getSelfSignificance(base.getSignatureRecord().getLSHVector()) : 0;
					rows.add(map("address", str(a), "name", f != null ? f.getName(true) : base.getFunctionName(),
						"hits", r.getTotalCount(), "selfSignificance", num(self)));
				}
				rows.sort((x, y) -> Integer.compare((Integer) y.get("hits"), (Integer) x.get("hits")));
				return map("queried", response.totalvec, "withMatches", response.totalmatch, "rows", rows);
			}
			finally {
				gensig.dispose();
			}
		});
	}

	/** The features BSim extracts from a function (what its vector is made of). */
	static List<Map<String, Object>> bsimFeatures(Session s, Address address) throws Exception {
		Function f = s.functionContaining(address);
		DecompInterface ifc = new DecompInterface();
		ifc.setOptions(new DecompileOptions());
		ifc.setSignatureSettings(0x4d);
		ifc.openProgram(s.program);
		try {
			List<DebugSignature> signatures = ifc.debugSignatures(f, 60, TaskMonitor.DUMMY);
			List<Map<String, Object>> out = new ArrayList<>();
			if (signatures == null) {
				throw new IllegalStateException("El descompilador no devolvió características: " + ifc.getLastMessage());
			}
			for (DebugSignature sig : signatures) {
				StringBuffer text = new StringBuffer();
				sig.printRaw(s.program.getLanguage(), text);
				String kind = sig.getClass().getSimpleName().replace("Signature", "");
				out.add(map("hash", String.format("%08x", sig.hash), "kind", kind, "text", text.toString().trim()));
			}
			return out;
		}
		finally {
			ifc.dispose();
		}
	}

	/** Creates a BSim database on a server (postgresql://host/name, elastic://host/name) or a file: URL. */
	static Object bsimCreateServer(String url, String template, String name) throws Exception {
		return Bsim.with(url, false, db -> {
			CreateDatabase command = new CreateDatabase();
			command.info = new DatabaseInformation();
			command.info.databasename = name == null || name.isBlank() ? url.substring(url.lastIndexOf('/') + 1) : name;
			command.config_template = template == null || template.isBlank() ? Bsim.TEMPLATES[0] : template;
			command.info.trackcallgraph = true;
			if (command.execute(db) == null) {
				throw new IOException(Bsim.error(db));
			}
			return map("url", url, "name", command.info.databasename);
		});
	}

	/** The program of the project with a given executable MD5 (or name), to open a BSim result. */
	static List<Map<String, Object>> projectFind(StudioServer server, String md5, String name) {
		List<Map<String, Object>> out = new ArrayList<>();
		if (server.projectOrNull() != null) {
			find(server.projectOrNull().getProjectData().getRootFolder(), md5, name, out);
		}
		return out;
	}

	private static void find(DomainFolder folder, String md5, String name, List<Map<String, Object>> out) {
		for (DomainFile f : folder.getFiles()) {
			if (!Program.class.isAssignableFrom(f.getDomainObjectClass())) {
				continue;
			}
			Map<String, String> meta = f.getMetadata();
			String fileMd5 = meta == null ? null : meta.get("Executable MD5");
			boolean hit = !md5.isEmpty() && md5.equalsIgnoreCase(fileMd5);
			if (hit || (!name.isEmpty() && f.getName().equals(name))) {
				out.add(map("path", f.getPathname(), "name", f.getName(), "md5", fileMd5, "exact", hit));
			}
		}
		for (DomainFolder sub : folder.getFolders()) {
			find(sub, md5, name, out);
		}
	}

	// ---------------------------------------------------------------- Function ID

	private static Map<String, Object> record(FidDB db, FidFile file, FunctionRecord r) {
		LibraryRecord lib = db.getLibraryForFunction(r);
		return map("id", r.getID(), "name", r.getName(), "database", file.getName(), "path", file.getPath(),
			"library", lib != null ? lib.getLibraryFamilyName() + " " + lib.getLibraryVersion() + " " + lib.getLibraryVariant() : "",
			"size", r.getCodeUnitSize(), "fullHash", Long.toHexString(r.getFullHash()),
			"specificHash", Long.toHexString(r.getSpecificHash()), "specificSize", r.getSpecificHashAdditionalSize(),
			"domainPath", r.getDomainPath(), "entry", Long.toHexString(r.getEntryPoint()),
			"excluded", r.autoFail(), "forced", r.autoPass(), "forceSpecific", r.isForceSpecific(),
			"forceRelation", r.isForceRelation(), "terminator", r.hasTerminator());
	}

	/** The FID hashes of the function at an address and the records of every database with the same full hash. */
	static Map<String, Object> fidHash(Session s, Address address) throws Exception {
		Function f = s.functionContaining(address);
		FidHashQuad quad = new FidService().hashFunction(f);
		if (quad == null) {
			throw new IllegalArgumentException("La función es demasiado pequeña para Function ID");
		}
		List<Map<String, Object>> matches = new ArrayList<>();
		for (FidFile file : FidFileManager.getInstance().getFidFiles()) {
			try (FidDB db = file.getFidDB(false)) {
				for (FunctionRecord r : db.findFunctionsByFullHash(quad.getFullHash())) {
					Map<String, Object> m = record(db, file, r);
					m.put("specificMatch", r.getSpecificHash() == quad.getSpecificHash());
					matches.add(m);
				}
			}
			catch (Exception e) {
				// unreadable database
			}
		}
		return map("function", f.getName(), "address", str(f.getEntryPoint()), "codeUnits", quad.getCodeUnitSize(),
			"fullHash", Long.toHexString(quad.getFullHash()), "specificHash", Long.toHexString(quad.getSpecificHash()),
			"specificSize", quad.getSpecificHashAdditionalSize(), "matches", matches);
	}

	/** kind: name, regex, path, fullHash or specificHash — over every attached database. */
	static List<Map<String, Object>> fidSearch(String kind, String value) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (FidFile file : FidFileManager.getInstance().getFidFiles()) {
			try (FidDB db = file.getFidDB(false)) {
				List<FunctionRecord> found = switch (kind) {
					case "regex" -> db.findFunctionsByNameRegex(value);
					case "path" -> db.findFunctionsByDomainPathSubstring(value);
					case "fullHash" -> db.findFunctionsByFullHash(Long.parseUnsignedLong(value.replace("0x", ""), 16));
					case "specificHash" -> db.findFunctionsBySpecificHash(Long.parseUnsignedLong(value.replace("0x", ""), 16));
					default -> db.findFunctionsByNameSubstring(value);
				};
				for (FunctionRecord r : found) {
					if (out.size() >= 5000) {
						return out;
					}
					out.add(record(db, file, r));
				}
			}
			catch (NumberFormatException e) {
				throw new IllegalArgumentException("Hash hexadecimal inválido: " + value);
			}
			catch (Exception e) {
				// unreadable database
			}
		}
		return out;
	}

	/** Saves a database in the raw read-only form (.fidbf) that Ghidra ships. */
	static Object fidReadOnly(String path, String output) throws Exception {
		File out = new File(output.endsWith(".fidbf") ? output : output + ".fidbf");
		try (FidDB db = Fid.find(path).getFidDB(false)) {
			db.saveRawDatabaseFile(out, TaskMonitor.DUMMY);
		}
		return map("path", out.getAbsolutePath(), "size", out.length());
	}

	/** Copies a database table by table into a new packed file, which removes the slack left by edits. */
	static Object fidRepack(String path, String output) throws Exception {
		File in = new File(path);
		File out = new File(output.endsWith(".fidb") ? output : output + ".fidb");
		if (out.exists()) {
			throw new IllegalArgumentException("Ya existe " + out.getName());
		}
		PackedDatabase pdb = PackedDatabase.getPackedDatabase(in, false, TaskMonitor.DUMMY);
		DBHandle handle = pdb.open(TaskMonitor.DUMMY);
		try {
			PackedDBHandle copy = new PackedDBHandle(pdb.getContentType());
			for (Table table : handle.getTables()) {
				long tx = copy.startTransaction();
				Table t = copy.createTable(table.getName(), table.getSchema(), table.getIndexedColumns());
				RecordIterator it = table.iterator();
				while (it.hasNext()) {
					t.putRecord(it.next());
				}
				copy.endTransaction(tx, true);
			}
			copy.saveAs(pdb.getContentType(), out.getParentFile(), out.getName(), TaskMonitor.DUMMY);
			copy.close();
		}
		finally {
			handle.close();
		}
		return map("path", out.getAbsolutePath(), "before", in.length(), "after", out.length());
	}

	/** Libraries of a database with how many functions each has, and totals. */
	static Map<String, Object> fidStatistics(String path) throws Exception {
		try (FidDB db = Fid.find(path).getFidDB(false)) {
			Map<Long, int[]> counts = new HashMap<>();
			Set<Long> full = new HashSet<>();
			int total = 0, excluded = 0, forced = 0;
			Table table = db.getDBHandle().getTable("Functions Table");
			if (table != null) {
				RecordIterator it = table.iterator();
				while (it.hasNext()) {
					FunctionRecord r = db.getFunctionByID(it.next().getKey());
					if (r == null) {
						continue;
					}
					total++;
					counts.computeIfAbsent(r.getLibraryID(), k -> new int[1])[0]++;
					full.add(r.getFullHash());
					excluded += r.autoFail() ? 1 : 0;
					forced += r.autoPass() ? 1 : 0;
				}
			}
			List<Map<String, Object>> libraries = new ArrayList<>();
			for (LibraryRecord lib : db.getAllLibraries()) {
				int[] n = counts.get(lib.getLibraryID());
				libraries.add(map("family", lib.getLibraryFamilyName(), "version", lib.getLibraryVersion(),
					"variant", lib.getLibraryVariant(), "language", lib.getGhidraLanguageID().getIdAsString(),
					"compiler", lib.getGhidraCompilerSpecID().getIdAsString(), "ghidra", lib.getGhidraVersion(),
					"functions", n == null ? 0 : n[0]));
			}
			return map("functions", total, "distinctHashes", full.size(), "excluded", excluded, "forced", forced,
				"libraries", libraries, "size", new File(path).length());
		}
	}
}
