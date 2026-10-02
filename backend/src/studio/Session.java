package studio;

import static studio.Json.*;

import java.io.IOException;
import java.util.*;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.function.ApplyFunctionSignatureCmd;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.decompiler.*;
import ghidra.app.decompiler.component.DecompilerUtils;
import ghidra.app.plugin.assembler.Assembler;
import ghidra.app.plugin.assembler.Assemblers;
import ghidra.app.plugin.core.analysis.AutoAnalysisManager;
import ghidra.app.util.parser.FunctionSignatureParser;
import ghidra.framework.model.DomainFile;
import ghidra.framework.options.OptionType;
import ghidra.framework.options.Options;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryAccessException;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.*;
import ghidra.program.model.symbol.*;
import ghidra.program.util.GhidraProgramUtilities;
import ghidra.util.task.TaskMonitor;
import ghidra.util.task.TaskMonitorAdapter;

/** One open program: decompiler, background analysis, queries and edits. */
final class Session {
	static final int MAX_ROWS = 20000;

	final StudioServer server;
	final String id;
	final Program program;
	final String sourcePath;
	/** Consumer that keeps the program open (released on close). */
	private final Object consumer;
	private DecompInterface decompiler;
	private final Map<Address, Map<String, Object>> decompCache = new ConcurrentHashMap<>();
	/** Tokens of each cached decompilation, indexed by the "i" id sent to the UI (for slicing etc.). */
	private final Map<Address, List<ClangToken>> tokenCache = new ConcurrentHashMap<>();
	private final DecompileOptions decompOptions = new DecompileOptions();
	private volatile Thread analysisThread;
	private volatile ProgressMonitor analysisMonitor;
	private long lastProgress;
	final Emulation emulation = new Emulation(this);

	Session(StudioServer server, Program program, Object consumer, String sourcePath) throws IOException {
		this(server, program, consumer, sourcePath, null);
	}

	/** id: what identifies the session when it is not the file's path (an old version of a file). */
	Session(StudioServer server, Program program, Object consumer, String sourcePath, String id) throws IOException {
		this.server = server;
		this.program = program;
		this.consumer = consumer;
		DomainFile df = program.getDomainFile();
		this.id = id != null ? id : df != null ? df.getPathname() : program.getName();
		this.sourcePath = sourcePath != null ? sourcePath : program.getExecutablePath();
		decompiler = new DecompInterface();
		decompOptions.grabFromProgram(program);
		decompiler.setOptions(decompOptions);
		decompiler.toggleCCode(true);
		decompiler.toggleSyntaxTree(true);
		decompiler.setSimplificationStyle("decompile");
		if (!decompiler.openProgram(program)) {
			throw new IOException("No se pudo iniciar el descompilador: " + decompiler.getLastMessage());
		}
	}

	// ---------------------------------------------------------------- lifecycle

	boolean needsAnalysis() {
		return GhidraProgramUtilities.shouldAskToAnalyze(program);
	}

	/** Runs auto-analysis on a worker thread, like the CodeBrowser: the program is usable meanwhile. */
	void startAnalysis() {
		if (isAnalyzing()) {
			return;
		}
		ProgressMonitor monitor = new ProgressMonitor();
		analysisMonitor = monitor;
		Thread t = new Thread(() -> {
			boolean completed = false;
			AutoAnalysisManager mgr = AutoAnalysisManager.getAnalysisManager(program);
			int tx = program.startTransaction("Auto-análisis");
			try {
				mgr.initializeOptions();
				mgr.reAnalyzeAll(null);
				mgr.startAnalysis(monitor);
				completed = !monitor.isCancelled();
				if (completed) {
					GhidraProgramUtilities.markProgramAnalyzed(program);
				}
			}
			catch (Throwable e) {
				e.printStackTrace();
			}
			finally {
				program.endTransaction(tx, true);
			}
			if (completed) {
				try {
					program.save("Auto-análisis", TaskMonitor.DUMMY);
				}
				catch (Throwable e) {
					e.printStackTrace();
				}
			}
			decompCache.clear();
			analysisThread = null;
			analysisMonitor = null;
			server.send(map("event", "analysisDone", "session", id, "completed", completed));
		}, "studio-analysis");
		t.setDaemon(true);
		analysisThread = t;
		server.send(map("event", "analysisStarted", "session", id));
		t.start();
	}

	boolean isAnalyzing() {
		return analysisThread != null;
	}

	void cancelAnalysis() {
		Thread t = analysisThread;
		ProgressMonitor m = analysisMonitor;
		if (t == null) {
			return;
		}
		if (m != null) {
			m.cancel();
		}
		try {
			t.join(30000);
		}
		catch (InterruptedException e) {
			Thread.currentThread().interrupt();
		}
	}

	void save() throws IOException {
		if (!program.canSave()) {
			if (program.isChanged()) {
				throw new IOException("El programa es de solo lectura: haz check-out para poder guardar los cambios");
			}
			return;
		}
		if (!isAnalyzing() && program.isChanged()) {
			try {
				program.save("Ghidra Studio", TaskMonitor.DUMMY);
			}
			catch (ghidra.util.exception.CancelledException e) {
				throw new IOException(e);
			}
		}
	}

	/** Writes a recovery snapshot of the unsaved changes (used to recover after a crash). */
	boolean snapshot() {
		DomainFile df = program.getDomainFile();
		if (df == null || !program.isChanged() || !program.canSave() || isAnalyzing()) {
			return false;
		}
		// DomainFile.takeRecoverySnapshot() does nothing in headless mode, so do what it does by hand:
		// lock out transactions and let the database write its snapshot files.
		if (!(program instanceof ghidra.program.database.ProgramDB db) || !db.lock("Recovery snapshot")) {
			return false;
		}
		try {
			return db.getDBHandle().takeRecoverySnapshot(db.getChangeSet(), TaskMonitor.DUMMY);
		}
		catch (Exception e) {
			e.printStackTrace();
			return false;
		}
		finally {
			db.unlock();
		}
	}

	/** Starts a transaction, waiting a moment if a recovery snapshot holds the lock. */
	private int begin(String name) throws InterruptedException {
		for (int i = 0;; i++) {
			try {
				return program.startTransaction(name);
			}
			catch (ghidra.framework.model.DomainObjectLockedException e) {
				if (i >= 100) {
					throw e;
				}
				Thread.sleep(50);
			}
		}
	}

	/** What else has to be released with the program (the connection a server URL was opened through). */
	Runnable afterClose;

	void close() {
		close(true);
	}

	void close(boolean save) {
		emulation.stop();
		cancelAnalysis();
		invalidate();
		if (decompiler != null) {
			decompiler.dispose();
			decompiler = null;
		}
		try {
			if (save && program.isChanged() && program.canSave()) {
				program.save("Ghidra Studio", TaskMonitor.DUMMY);
			}
		}
		catch (Exception e) {
			e.printStackTrace();
		}
		try {
			program.release(consumer);
		}
		catch (Exception ignored) {
			// already released
		}
		if (afterClose != null) {
			try {
				afterClose.run();
			}
			catch (Exception ignored) {
				// the connection may already be gone
			}
			afterClose = null;
		}
	}

	void invalidate() {
		decompCache.clear();
		tokenCache.clear();
	}

	/** Runs an edit inside a transaction (undoable; saved explicitly like the CodeBrowser). */
	<T> T edit(String name, Callable<T> body) throws Exception {
		int tx = begin(name);
		boolean ok = false;
		T result;
		try {
			result = body.call();
			ok = true;
		}
		finally {
			program.endTransaction(tx, ok);
		}
		invalidate();
		return result;
	}

	Address addr(String s) {
		Address a = program.getAddressFactory().getAddress(s);
		if (a == null) {
			throw new IllegalArgumentException("Dirección inválida: " + s);
		}
		return a;
	}

	// ---------------------------------------------------------------- queries

	Map<String, Object> info() {
		Map<String, Object> m = new LinkedHashMap<>();
		m.put("session", id);
		m.put("name", program.getName());
		m.put("path", sourcePath != null ? sourcePath : id);
		m.put("domainPath", id);
		m.put("format", program.getExecutableFormat());
		m.put("language", program.getLanguageID().getIdAsString());
		m.put("processor", program.getLanguage().getProcessor().toString());
		m.put("compiler", program.getCompilerSpec().getCompilerSpecID().getIdAsString());
		m.put("endian", program.getLanguage().isBigEndian() ? "Big" : "Little");
		m.put("pointerSize", program.getDefaultPointerSize() * 8);
		m.put("imageBase", program.getImageBase().toString());
		m.put("minAddress", str(program.getMinAddress()));
		m.put("maxAddress", str(program.getMaxAddress()));
		m.put("md5", program.getExecutableMD5());
		m.put("sha256", program.getExecutableSHA256());
		m.put("functionCount", program.getFunctionManager().getFunctionCount());
		m.put("created", program.getCreationDate().toString());
		Function entry = firstEntryFunction();
		m.put("entry", entry != null ? str(entry.getEntryPoint()) : null);
		m.put("analyzing", isAnalyzing());
		m.put("readOnly", !program.canSave());
		m.putAll(undoState());
		return m;
	}

	Map<String, Object> undoState() {
		return map("changed", program.isChanged(),
			"canUndo", program.canUndo() && !isAnalyzing(), "canRedo", program.canRedo() && !isAnalyzing(),
			"undoName", program.canUndo() ? Msg.t(program.getUndoName()) : null,
			"redoName", program.canRedo() ? Msg.t(program.getRedoName()) : null);
	}

	private Function firstEntryFunction() {
		FunctionManager fm = program.getFunctionManager();
		for (String n : List.of("main", "_main", "entry", "_start", "start", "WinMain", "wWinMain")) {
			for (Function f : program.getListing().getGlobalFunctions(n)) {
				return f;
			}
		}
		AddressIterator it = program.getSymbolTable().getExternalEntryPointIterator();
		while (it.hasNext()) {
			Function f = fm.getFunctionAt(it.next());
			if (f != null) {
				return f;
			}
		}
		FunctionIterator fi = fm.getFunctions(true);
		return fi.hasNext() ? fi.next() : null;
	}

	List<Map<String, Object>> functions() {
		List<Map<String, Object>> list = new ArrayList<>();
		for (Function f : program.getFunctionManager().getFunctions(true)) {
			list.add(map("address", str(f.getEntryPoint()), "name", f.getName(true),
				"size", f.getBody().getNumAddresses(), "thunk", f.isThunk(),
				"signature", f.getPrototypeString(false, false)));
		}
		return list;
	}

	List<Map<String, Object>> imports() {
		List<Map<String, Object>> list = new ArrayList<>();
		SymbolIterator it = program.getSymbolTable().getExternalSymbols();
		while (it.hasNext()) {
			Symbol s = it.next();
			String target = null;
			if (s.getObject() instanceof Function f) {
				Address[] thunks = f.getFunctionThunkAddresses(true);
				if (thunks != null && thunks.length > 0) {
					target = str(thunks[0]);
				}
			}
			if (target == null) {
				Reference[] refs = s.getReferences();
				if (refs.length > 0) {
					target = str(refs[0].getFromAddress());
				}
			}
			list.add(map("name", s.getName(), "library", s.getParentNamespace().getName(), "address", target));
		}
		list.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
		return list;
	}

	List<Map<String, Object>> exports() {
		List<Map<String, Object>> list = new ArrayList<>();
		SymbolTable st = program.getSymbolTable();
		AddressIterator it = st.getExternalEntryPointIterator();
		while (it.hasNext()) {
			Address a = it.next();
			Symbol s = st.getPrimarySymbol(a);
			list.add(map("address", str(a), "name", s != null ? s.getName(true) : str(a),
				"isFunction", program.getFunctionManager().getFunctionAt(a) != null));
		}
		return list;
	}

	List<Map<String, Object>> strings() {
		List<Map<String, Object>> list = new ArrayList<>();
		for (Data d : program.getListing().getDefinedData(true)) {
			if (list.size() >= MAX_ROWS) {
				break;
			}
			if (!d.hasStringValue()) {
				continue;
			}
			String value = StringDataInstance.getStringDataInstance(d).getStringValue();
			if (value == null) {
				continue;
			}
			list.add(map("address", str(d.getAddress()), "value", value, "length", d.getLength(),
				"type", d.getDataType().getName(),
				"xrefs", program.getReferenceManager().getReferenceCountTo(d.getAddress())));
		}
		return list;
	}

	List<Map<String, Object>> segments() {
		List<Map<String, Object>> list = new ArrayList<>();
		for (MemoryBlock b : program.getMemory().getBlocks()) {
			list.add(map("name", b.getName(), "start", str(b.getStart()), "end", str(b.getEnd()),
				"size", b.getSize(), "perms", perms(b), "initialized", b.isInitialized(), "comment", b.getComment(),
				"volatile", b.isVolatile(), "artificial", b.isArtificial(), "overlay", b.isOverlay()));
		}
		return list;
	}

	static String perms(MemoryBlock b) {
		return (b.isRead() ? "r" : "-") + (b.isWrite() ? "w" : "-") + (b.isExecute() ? "x" : "-");
	}

	List<Map<String, Object>> symbolSearch(String query) {
		String q = query.toLowerCase();
		List<Map<String, Object>> list = new ArrayList<>();
		SymbolIterator it = program.getSymbolTable().getAllSymbols(true);
		while (it.hasNext() && list.size() < 300) {
			Symbol s = it.next();
			if (s.isExternal() || !s.getName().toLowerCase().contains(q)) {
				continue;
			}
			list.add(map("address", str(s.getAddress()), "name", s.getName(true), "kind", s.getSymbolType().toString()));
		}
		return list;
	}

	List<Map<String, Object>> bookmarks() {
		List<Map<String, Object>> list = new ArrayList<>();
		// breakpoints first, so that a program full of analysis bookmarks never crowds them out
		for (String type : List.of(Debug.ENABLED, Debug.DISABLED)) {
			Iterator<Bookmark> marks = program.getBookmarkManager().getBookmarksIterator(type);
			while (marks.hasNext()) {
				Bookmark b = marks.next();
				list.add(map("address", str(b.getAddress()), "type", b.getTypeString(), "category", b.getCategory(),
					"comment", b.getComment()));
			}
		}
		Iterator<Bookmark> it = program.getBookmarkManager().getBookmarksIterator();
		while (it.hasNext() && list.size() < 5000) {
			Bookmark b = it.next();
			if (Debug.isBreakpoint(b)) {
				continue;
			}
			list.add(map("address", str(b.getAddress()), "type", b.getTypeString(), "category", b.getCategory(),
				"comment", b.getComment()));
		}
		return list;
	}

	// ---------------------------------------------------------------- decompiler

	DecompileResults decompileRaw(Function f) {
		DecompileResults res = decompiler.decompileFunction(f, 60, TaskMonitor.DUMMY);
		if (!res.decompileCompleted()) {
			throw new IllegalStateException("Error al descompilar: " + res.getErrorMessage());
		}
		return res;
	}

	Function functionContaining(Address a) {
		Function f = program.getFunctionManager().getFunctionContaining(a);
		if (f == null) {
			throw new IllegalArgumentException("No hay ninguna función en " + a);
		}
		return f;
	}

	Map<String, Object> decompile(Address address) {
		Function f = functionContaining(address);
		Map<String, Object> cached = decompCache.get(f.getEntryPoint());
		if (cached != null) {
			return cached;
		}
		DecompileResults res = decompileRaw(f);
		List<Map<String, Object>> lines = new ArrayList<>();
		List<ClangToken> all = new ArrayList<>();
		for (ClangLine line : DecompilerUtils.toLines(res.getCCodeMarkup())) {
			List<Map<String, Object>> tokens = new ArrayList<>();
			Address lineAddr = null;
			Set<String> lineAddrs = new LinkedHashSet<>();
			for (ClangToken t : line.getAllTokens()) {
				String text = t.getText();
				if (text == null || text.isEmpty()) {
					continue;
				}
				Map<String, Object> tm = new LinkedHashMap<>();
				tm.put("t", text);
				tm.put("s", t.getSyntaxType());
				tm.put("k", tokenKind(t));
				Address target = tokenTarget(t);
				if (target != null) {
					tm.put("target", str(target));
				}
				String var = localVariable(t);
				if (var != null) {
					tm.put("v", var);
				}
				tm.put("i", all.size());
				all.add(t);
				if (canSplit(t)) {
					tm.put("sp", true);
				}
				if (More.isUnionField(t)) {
					tm.put("un", true);
				}
				if (t instanceof ClangFieldToken ft && ft.getDataType() != null) {
					DataType owner = ft.getDataType();
					if (owner instanceof TypeDef td) {
						owner = td.getBaseDataType();
					}
					tm.put("ft", owner.getPathName());
					tm.put("fo", ft.getOffset());
				}
				if (t instanceof ClangFuncNameToken fn && fn.getPcodeOp() != null
						&& (fn.getPcodeOp().getOpcode() == PcodeOp.CALL || fn.getPcodeOp().getOpcode() == PcodeOp.CALLIND)) {
					tm.put("call", str(fn.getPcodeOp().getSeqnum().getTarget()));
				}
				tokens.add(tm);
				Address min = t.getMinAddress();
				if (min != null && (lineAddr == null || min.compareTo(lineAddr) < 0)) {
					lineAddr = min;
				}
				if (min != null && lineAddrs.size() < 24) {
					lineAddrs.add(str(min));
				}
			}
			Map<String, Object> lm = map("indent", line.getIndent(), "tokens", tokens, "addr", lineAddr != null ? str(lineAddr) : null);
			if (lineAddrs.size() > 1) {
				lm.put("addrs", new ArrayList<>(lineAddrs));
			}
			lines.add(lm);
		}
		Map<String, Object> m = map("function", f.getName(true), "entry", str(f.getEntryPoint()),
			"signature", f.getPrototypeString(false, false), "lines", lines);
		decompCache.put(f.getEntryPoint(), m);
		tokenCache.put(f.getEntryPoint(), all);
		return m;
	}

	ClangToken token(Address fnAddr, int tokenId) {
		Function f = functionContaining(fnAddr);
		decompile(f.getEntryPoint());
		List<ClangToken> all = tokenCache.get(f.getEntryPoint());
		if (all == null || tokenId < 0 || tokenId >= all.size()) {
			throw new IllegalArgumentException("Token desconocido");
		}
		return all.get(tokenId);
	}

	HighFunction highFunction(Address fnAddr) {
		HighFunction hf = decompileRaw(functionContaining(fnAddr)).getHighFunction();
		if (hf == null) {
			throw new IllegalStateException("Error al descompilar: " + fnAddr);
		}
		return hf;
	}

	/** Same test as the decompiler's "Split Out As New Variable": the variable merges several storage groups. */
	private static boolean canSplit(ClangToken t) {
		if (!(t instanceof ClangVariableToken)) {
			return false;
		}
		HighVariable variable = t.getHighVariable();
		if (!(variable instanceof HighLocal) || variable.getSymbol() == null || variable.getSymbol().isIsolated()) {
			return false;
		}
		Varnode vn = t.getVarnode();
		if (vn == null) {
			return false;
		}
		short group = vn.getMergeGroup();
		for (Varnode v : variable.getInstances()) {
			if (v.getMergeGroup() != group) {
				return true;
			}
		}
		return false;
	}

	/** Splits the instance under the cursor out of a merged variable into its own, newly named, variable. */
	Object splitVariable(Address fnAddr, int tokenId, String newName) throws Exception {
		Function f = functionContaining(fnAddr);
		decompile(f.getEntryPoint());
		List<ClangToken> all = tokenCache.get(f.getEntryPoint());
		if (all == null || tokenId < 0 || tokenId >= all.size()) {
			throw new IllegalArgumentException("Token desconocido");
		}
		ClangToken t = all.get(tokenId);
		if (!canSplit(t)) {
			throw new IllegalArgumentException("Esta variable no se puede dividir: no agrupa varios usos distintos");
		}
		Varnode vn = t.getVarnode();
		HighFunction hf = t.getHighVariable().getSymbol().getHighFunction();
		for (Symbol sym : program.getSymbolTable().getSymbols(f)) {
			if (sym.getName().equals(newName)) {
				throw new IllegalArgumentException("Ya existe una variable con ese nombre en la función");
			}
		}
		edit("Dividir variable", () -> {
			HighVariable split = hf.splitOutMergeGroup(vn.getHigh(), vn);
			HighSymbol sym = split.getSymbol();
			DataType dt = sym.getDataType();
			if (Undefined.isUndefined(dt)) {
				// the new variable has to be type-locked, and an undefined type cannot be
				dt = AbstractIntegerDataType.getUnsignedDataType(dt.getLength(), program.getDataTypeManager());
			}
			HighFunctionDBUtil.updateDBVariable(sym, newName, dt, SourceType.USER_DEFINED);
			return null;
		});
		return undoState();
	}

	/** Forward / backward data-flow slice from a token: returns the ids of the tokens to highlight. */
	List<Integer> slice(Address fnAddr, int tokenId, boolean forward) {
		Function f = functionContaining(fnAddr);
		decompile(f.getEntryPoint());
		List<ClangToken> all = tokenCache.get(f.getEntryPoint());
		if (all == null || tokenId < 0 || tokenId >= all.size()) {
			throw new IllegalArgumentException("Token desconocido");
		}
		Varnode vn = DecompilerUtils.getVarnodeRef(all.get(tokenId));
		if (vn == null) {
			throw new IllegalArgumentException("Coloca el cursor sobre una variable");
		}
		Set<PcodeOp> ops = forward ? DecompilerUtils.getForwardSliceToPCodeOps(vn)
				: DecompilerUtils.getBackwardSliceToPCodeOps(vn);
		Set<Varnode> vars = forward ? DecompilerUtils.getForwardSlice(vn) : DecompilerUtils.getBackwardSlice(vn);
		List<Integer> out = new ArrayList<>();
		for (int i = 0; i < all.size(); i++) {
			ClangToken t = all.get(i);
			if (!(t instanceof ClangVariableToken) && !(t instanceof ClangOpToken) && !(t instanceof ClangFuncNameToken)) {
				continue;
			}
			Varnode v = DecompilerUtils.getVarnodeRef(t);
			PcodeOp op = t.getPcodeOp();
			if ((v != null && vars.contains(v)) || (op != null && ops.contains(op))) {
				out.add(i);
			}
		}
		return out;
	}

	Object renameField(String typePath, int offset, String name) throws Exception {
		DataType dt = Types.find(program, typePath);
		if (dt instanceof Pointer ptr) {
			dt = ptr.getDataType();
		}
		if (!(dt instanceof Composite c)) {
			throw new IllegalArgumentException("No es una estructura: " + typePath);
		}
		return edit("Renombrar campo", () -> {
			DataTypeComponent comp = c instanceof Structure st ? st.getComponentContaining(offset) : c.getComponent(offset);
			if (comp == null) {
				throw new IllegalArgumentException("No hay ningún campo en el offset " + offset);
			}
			if (comp.getDataType() == DataType.DEFAULT && c instanceof Structure st) {
				st.replaceAtOffset(offset, Undefined1DataType.dataType, 1, name, null);
			}
			else {
				comp.setFieldName(name);
			}
			return true;
		});
	}

	/** Like "Override Signature": forces the prototype used at one call site. */
	Object overrideSignature(Address fnAddr, Address callSite, String signature) throws Exception {
		Function f = functionContaining(fnAddr);
		FunctionSignatureParser parser = new FunctionSignatureParser(program.getDataTypeManager(),
			new Types.QueryService(program));
		FunctionDefinitionDataType def = parser.parse(null, signature);
		return edit("Forzar firma", () -> {
			HighFunctionDBUtil.writeOverride(f, callSite, def);
			return true;
		});
	}

	// ---------------------------------------------------------------- decompiler options

	private static final String[][] DECOMP_OPTIONS = {
		{ "MaxWidth", "int", "Ancho máximo de línea" },
		{ "IndentWidth", "int", "Ancho de sangría" },
		{ "EliminateUnreachable", "bool", "Eliminar código inalcanzable" },
		{ "SimplifyDoublePrecision", "bool", "Simplificar aritmética de doble precisión" },
		{ "NoCastPrint", "bool", "Ocultar conversiones de tipo (casts)" },
		{ "ConventionPrint", "bool", "Mostrar la convención de llamada" },
		{ "InferConstantPointers", "bool", "Inferir punteros a partir de constantes" },
		{ "AnalyzeForLoops", "bool", "Reconstruir bucles for" },
		{ "RespectReadOnly", "bool", "Respetar memoria de solo lectura" },
		{ "PRECommentIncluded", "bool", "Mostrar comentarios previos" },
		{ "PLATECommentIncluded", "bool", "Mostrar comentarios de cabecera" },
		{ "EOLCommentIncluded", "bool", "Mostrar comentarios de fin de línea" },
		{ "POSTCommentIncluded", "bool", "Mostrar comentarios posteriores" },
		{ "WARNCommentIncluded", "bool", "Mostrar avisos del descompilador" },
		{ "HeadCommentIncluded", "bool", "Mostrar comentario de la función" },
		{ "IntegerFormat", "enum", "Formato de los enteros" },
		{ "NamespaceStrategy", "enum", "Mostrar namespaces" },
		{ "CommentStyle", "enum", "Estilo de los comentarios" },
	};

	private java.lang.reflect.Method getter(String name) throws NoSuchMethodException {
		for (String prefix : new String[] { "get", "is" }) {
			try {
				return DecompileOptions.class.getMethod(prefix + name);
			}
			catch (NoSuchMethodException ignored) {
				// try next
			}
		}
		throw new NoSuchMethodException(name);
	}

	List<Map<String, Object>> decompilerOptions() {
		List<Map<String, Object>> out = new ArrayList<>();
		for (String[] o : DECOMP_OPTIONS) {
			try {
				Object value = getter(o[0]).invoke(decompOptions);
				Map<String, Object> m = map("key", o[0], "type", o[1], "label", Msg.t(o[2]), "value", String.valueOf(value));
				if (value != null && value.getClass().isEnum()) {
					List<String> choices = new ArrayList<>();
					for (Object c : value.getClass().getEnumConstants()) {
						choices.add(((java.lang.Enum<?>) c).name());
					}
					m.put("choices", choices);
					m.put("value", ((java.lang.Enum<?>) value).name());
				}
				out.add(m);
			}
			catch (Exception ignored) {
				// option not available in this Ghidra version
			}
		}
		return out;
	}

	@SuppressWarnings({ "unchecked", "rawtypes" })
	Object setDecompilerOption(String key, String value) throws Exception {
		Class<?> type = getter(key).getReturnType();
		Object arg = type == int.class ? (Object) Integer.parseInt(value.trim())
				: type == boolean.class ? (Object) Boolean.parseBoolean(value)
				: type.isEnum() ? java.lang.Enum.valueOf((Class) type, value) : value;
		DecompileOptions.class.getMethod("set" + key, type).invoke(decompOptions, arg);
		decompiler.setOptions(decompOptions);
		invalidate();
		return true;
	}

	private static String tokenKind(ClangToken t) {
		if (t instanceof ClangFuncNameToken) return "func";
		if (t instanceof ClangVariableToken) return "var";
		if (t instanceof ClangTypeToken) return "type";
		if (t instanceof ClangCommentToken) return "comment";
		if (t instanceof ClangLabelToken) return "label";
		if (t instanceof ClangFieldToken) return "field";
		if (t instanceof ClangOpToken) return "op";
		return "syntax";
	}

	/** Name of the local variable / parameter a token refers to (for rename / retype). */
	private static String localVariable(ClangToken t) {
		if (!(t instanceof ClangVariableToken)) {
			return null;
		}
		HighVariable hv = t.getHighVariable();
		if (hv == null || hv instanceof HighGlobal) {
			return null;
		}
		HighSymbol hs = hv.getSymbol();
		return hs != null ? hs.getName() : null;
	}

	Address tokenTarget(ClangToken t) {
		if (t instanceof ClangFuncNameToken fn) {
			PcodeOp op = fn.getPcodeOp();
			if (op != null && op.getOpcode() == PcodeOp.CALL && op.getInput(0) != null) {
				return op.getInput(0).getAddress();
			}
			List<Function> fs = program.getListing().getGlobalFunctions(t.getText());
			if (!fs.isEmpty()) {
				return fs.get(0).getEntryPoint();
			}
			HighFunction hf = fn.getHighFunction();
			return hf != null ? hf.getFunction().getEntryPoint() : null;
		}
		if (t instanceof ClangVariableToken || t instanceof ClangLabelToken) {
			HighVariable hv = t.getHighVariable();
			if (hv instanceof HighGlobal) {
				HighSymbol hs = hv.getSymbol();
				if (hs != null && hs.getStorage().isMemoryStorage()) {
					return hs.getStorage().getMinAddress();
				}
			}
			if (t instanceof ClangLabelToken) {
				return t.getMinAddress();
			}
		}
		return null;
	}

	// ---------------------------------------------------------------- listing / hex

	Map<String, Object> listing(Address address, int count) {
		Listing listing = program.getListing();
		Function f = program.getFunctionManager().getFunctionContaining(address);
		CodeUnitIterator it;
		int limit;
		if (f != null) {
			it = listing.getCodeUnits(f.getBody(), true);
			limit = MAX_ROWS;
		}
		else {
			CodeUnit cu = listing.getCodeUnitContaining(address);
			it = listing.getCodeUnits(cu != null ? cu.getAddress() : address, true);
			limit = Math.min(count, MAX_ROWS);
		}
		RowContext ctx = new RowContext();
		List<Map<String, Object>> rows = new ArrayList<>();
		while (it.hasNext() && rows.size() < limit) {
			rows.add(row(it.next(), ctx, false));
		}
		return map("function", f != null ? f.getName(true) : null, "entry", f != null ? str(f.getEntryPoint()) : null,
			"signature", f != null ? f.getPrototypeString(false, false) : null, "rows", rows);
	}

	/**
	 * A contiguous slice of the whole-program listing, used for infinite scrolling. Functions whose entry
	 * is in {@code collapsed} are folded: only their first line is sent, with how much is hidden.
	 */
	Map<String, Object> listingSpan(Address address, String direction, int count, boolean inclusive,
			Set<String> collapsed) {
		count = Math.max(1, Math.min(count, 5000));
		Listing listing = program.getListing();
		CodeUnit containing = listing.getCodeUnitContaining(address);
		Address start = containing != null ? containing.getAddress() : address;
		boolean forward = !direction.equals("backward");
		CodeUnitIterator it = listing.getCodeUnits(start, forward);
		RowContext ctx = new RowContext();
		List<Map<String, Object>> rows = new ArrayList<>();
		int jumps = 0;
		while (it.hasNext() && rows.size() < count) {
			CodeUnit cu = it.next();
			Address a = cu.getAddress();
			if (!inclusive && a.equals(start)) {
				continue;
			}
			Function folded = null;
			if (!collapsed.isEmpty()) {
				Function f = ctx.fm.getFunctionContaining(a);
				if (f != null && collapsed.contains(str(f.getEntryPoint()))) {
					folded = f;
				}
			}
			if (folded != null && !a.equals(folded.getEntryPoint())) {
				// inside a folded function: jump over this piece of its body
				ghidra.program.model.address.AddressRange range = folded.getBody().getRangeContaining(a);
				Address next = null;
				if (range != null && jumps++ < 100000) {
					if (forward) {
						next = range.getMaxAddress().next();
					}
					else {
						next = range.contains(folded.getEntryPoint()) ? folded.getEntryPoint()
								: range.getMinAddress().previous();
					}
				}
				if (next != null) {
					it = listing.getCodeUnits(next, forward);
				}
				continue;
			}
			Map<String, Object> r = row(cu, ctx, true);
			if (folded != null) {
				r.put("folded", folded.getBody().getNumAddresses());
			}
			rows.add(r);
		}
		boolean atEdge = !it.hasNext();
		if (!forward) {
			Collections.reverse(rows);
		}
		return map("rows", rows, "atEdge", atEdge);
	}

	/** Optional listing fields the interface asked for: fileOffset, functionOffset, pcode, xrefs, source. */
	volatile Set<String> listingFields = Set.of();

	private void extraFields(CodeUnit cu, Address a, RowContext ctx, Map<String, Object> r) {
		Set<String> fields = listingFields;
		if (fields.contains("fileOffset")) {
			ghidra.program.database.mem.AddressSourceInfo info = program.getMemory().getAddressSourceInfo(a);
			if (info != null && info.getFileOffset() >= 0) {
				r.put("fileOffset", Long.toHexString(info.getFileOffset()));
			}
		}
		if (fields.contains("functionOffset")) {
			Function f = ctx.fm.getFunctionContaining(a);
			if (f != null) {
				r.put("functionOffset", f.getName() + "+0x" + Long.toHexString(a.subtract(f.getEntryPoint())));
			}
		}
		if (fields.contains("pcode") && cu instanceof Instruction ins) {
			List<String> ops = new ArrayList<>();
			for (ghidra.program.model.pcode.PcodeOp op : ins.getPcode()) {
				ops.add(op.toString());
			}
			r.put("pcode", ops);
		}
		if (fields.contains("xrefs")) {
			List<String> list = new ArrayList<>();
			ReferenceIterator it = ctx.rm.getReferencesTo(a);
			while (it.hasNext() && list.size() < 6) {
				Reference ref = it.next();
				list.add(str(ref.getFromAddress()) + "(" + ref.getReferenceType().getDisplayString() + ")");
			}
			if (fields.contains("thunkXrefs")) {
				int extra = 0;
				for (Address thunk : thunksOf(a)) {
					ReferenceIterator ti = ctx.rm.getReferencesTo(thunk);
					while (ti.hasNext()) {
						Reference ref = ti.next();
						extra++;
						if (list.size() < 6) {
							list.add(str(ref.getFromAddress()) + "(" + ref.getReferenceType().getDisplayString() + " thunk)");
						}
					}
				}
				if (extra > 0) {
					r.put("thunkXrefs", extra);
				}
			}
			if (!list.isEmpty()) {
				r.put("xrefList", list);
			}
		}
		if (fields.contains("source")) {
			List<ghidra.program.model.sourcemap.SourceMapEntry> entries =
				program.getSourceFileManager().getSourceMapEntries(a);
			if (!entries.isEmpty()) {
				ghidra.program.model.sourcemap.SourceMapEntry e = entries.get(0);
				r.put("source", e.getSourceFile().getFilename() + ":" + e.getLineNumber());
			}
		}
	}

	/** Entry points of the thunks that end in the function at this address. */
	List<Address> thunksOf(Address a) {
		Function f = program.getFunctionManager().getFunctionAt(a);
		Address[] thunks = f == null ? null : f.getFunctionThunkAddresses(true);
		return thunks == null ? List.of() : Arrays.asList(thunks);
	}

	private class RowContext {
		final CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
		final SymbolTable st = program.getSymbolTable();
		final ReferenceManager rm = program.getReferenceManager();
		final FunctionManager fm = program.getFunctionManager();
		final BookmarkManager bm = program.getBookmarkManager();
	}

	private Map<String, Object> row(CodeUnit cu, RowContext ctx, boolean headers) {
		Map<String, Object> r = new LinkedHashMap<>();
		Address a = cu.getAddress();
		r.put("address", str(a));
		try {
			r.put("bytes", hex(cu.getBytes(), 8));
		}
		catch (MemoryAccessException e) {
			r.put("bytes", "??");
		}
		Symbol primary = ctx.st.getPrimarySymbol(a);
		r.put("label", primary != null && !primary.isDynamic() ? primary.getName(true)
				: (primary != null && ctx.rm.hasReferencesTo(a) ? primary.getName() : null));
		r.put("mnemonic", cu.getMnemonicString());

		List<Map<String, Object>> ops = new ArrayList<>();
		if (cu instanceof Instruction ins) {
			r.put("kind", "code");
			for (int i = 0; i < ins.getNumOperands(); i++) {
				Map<String, Object> om = new LinkedHashMap<>();
				om.put("text", ctx.fmt.getOperandRepresentationString(cu, i));
				for (Reference ref : ins.getOperandReferences(i)) {
					if (ref.getToAddress().isMemoryAddress() || ref.getToAddress().isExternalAddress()) {
						om.put("target", str(ref.getToAddress()));
						break;
					}
				}
				ops.add(om);
			}
			r.put("flow", ins.getFlowType().isCall() ? "call"
					: ins.getFlowType().isTerminal() ? "return"
					: ins.getFlowType().isJump() ? "jump" : null);
			if (ins.getFlowType().isJump()) {
				List<String> jumps = new ArrayList<>();
				for (Address target : ins.getFlows()) {
					jumps.add(str(target));
				}
				if (!jumps.isEmpty()) {
					r.put("jumps", jumps);
					r.put("conditional", ins.getFlowType().isConditional());
				}
			}
		}
		else if (cu instanceof Data d) {
			r.put("kind", d.isDefined() ? "data" : "undefined");
			Map<String, Object> om = new LinkedHashMap<>();
			om.put("text", d.getDefaultValueRepresentation());
			Reference[] refs = d.getReferencesFrom();
			if (refs.length > 0) {
				om.put("target", str(refs[0].getToAddress()));
			}
			ops.add(om);
		}
		r.put("operands", ops);
		r.put("eol", cu.getComment(CommentType.EOL));
		r.put("pre", cu.getComment(CommentType.PRE));
		r.put("plate", cu.getComment(CommentType.PLATE));
		r.put("post", cu.getComment(CommentType.POST));
		r.put("repeatable", cu.getComment(CommentType.REPEATABLE));
		r.put("xrefs", ctx.rm.getReferenceCountTo(a));
		for (Bookmark mark : ctx.bm.getBookmarks(a)) {
			if (Debug.isBreakpoint(mark)) {
				continue;       // breakpoints are drawn in the margin, not as bookmarks
			}
			r.put("bookmark", mark.getCategory() + (mark.getComment().isEmpty() ? "" : ": " + mark.getComment()));
			break;
		}
		if (cu instanceof Data dd && dd.getNumComponents() > 0) {
			r.put("components", dd.getNumComponents());
		}
		if (!listingFields.isEmpty()) {
			extraFields(cu, a, ctx, r);
		}
		if (headers) {
			Function f = ctx.fm.getFunctionAt(a);
			if (f != null) {
				r.put("fnStart", f.getPrototypeString(false, false));
			}
			MemoryBlock block = program.getMemory().getBlock(a);
			if (block != null && block.getStart().equals(a)) {
				r.put("blockStart", block.getName() + "  " + perms(block));
			}
		}
		return r;
	}

	Map<String, Object> hexDump(Address address, int length) {
		length = Math.max(16, Math.min(length, 65536));
		Address base = address.getNewAddress(address.getOffset() & ~0xfL);
		List<Integer> bytes = new ArrayList<>(length);
		for (int i = 0; i < length; i++) {
			Address a;
			try {
				a = base.add(i);
			}
			catch (AddressOutOfBoundsException e) {
				break;
			}
			try {
				bytes.add(program.getMemory().getByte(a) & 0xff);
			}
			catch (MemoryAccessException e) {
				bytes.add(-1);
			}
		}
		MemoryBlock block = program.getMemory().getBlock(address);
		return map("start", str(base), "bytes", bytes, "block", block != null ? block.getName() : null);
	}

	/**
	 * A page of memory for the byte viewer: bytes (-1 where there are none), what each byte is
	 * (0 undefined, 1 instruction, 2 data) and, for every pointer-sized group, whether its value is an address.
	 */
	Map<String, Object> byteView(Address address, int length, int align) {
		length = Math.max(16, Math.min(length, 65536));
		int step = Math.max(1, align);
		Address base = address.getNewAddress(address.getOffset() - Long.remainderUnsigned(address.getOffset(), step));
		ghidra.program.model.mem.Memory mem = program.getMemory();
		Listing listing = program.getListing();
		List<Integer> bytes = new ArrayList<>(length);
		List<Integer> kinds = new ArrayList<>(length);
		for (int i = 0; i < length; i++) {
			Address a;
			try {
				a = base.add(i);
			}
			catch (AddressOutOfBoundsException e) {
				break;
			}
			try {
				bytes.add(mem.getByte(a) & 0xff);
			}
			catch (MemoryAccessException e) {
				bytes.add(-1);
			}
			CodeUnit cu = listing.getCodeUnitContaining(a);
			kinds.add(cu instanceof Instruction ? 1 : cu instanceof Data d && d.isDefined() ? 2 : 0);
		}
		int ptr = program.getDefaultPointerSize();
		boolean big = mem.isBigEndian();
		List<Boolean> pointers = new ArrayList<>();
		for (int i = 0; i + ptr <= bytes.size(); i += ptr) {
			long v = 0;
			boolean ok = true;
			for (int b = 0; b < ptr; b++) {
				int x = bytes.get(big ? i + b : i + ptr - 1 - b);
				if (x < 0) {
					ok = false;
					break;
				}
				v = (v << 8) | x;
			}
			boolean valid = false;
			if (ok && v != 0) {
				try {
					valid = mem.contains(base.getNewAddress(v));
				}
				catch (Exception e) {
					valid = false;
				}
			}
			pointers.add(valid);
		}
		MemoryBlock block = mem.getBlock(address);
		return map("start", str(base), "bytes", bytes, "kinds", kinds, "pointers", pointers, "pointerSize", ptr,
			"bigEndian", big, "block", block != null ? block.getName() : null,
			"blockStart", block != null ? str(block.getStart()) : null, "blockEnd", block != null ? str(block.getEnd()) : null,
			"min", str(mem.getMinAddress()), "max", str(mem.getMaxAddress()));
	}

	// ---------------------------------------------------------------- xrefs / function info

	List<Map<String, Object>> xrefs(Address address) {
		List<Map<String, Object>> list = new ArrayList<>();
		FunctionManager fm = program.getFunctionManager();
		for (Reference ref : program.getReferenceManager().getReferencesTo(address)) {
			if (list.size() >= 2000) {
				break;
			}
			Function f = fm.getFunctionContaining(ref.getFromAddress());
			list.add(map("from", str(ref.getFromAddress()), "type", ref.getReferenceType().getName(),
				"function", f != null ? f.getName(true) : null));
		}
		if (listingFields.contains("thunkXrefs")) {
			// references that reach the function through its thunks
			for (Address thunk : thunksOf(address)) {
				Function t = fm.getFunctionAt(thunk);
				for (Reference ref : program.getReferenceManager().getReferencesTo(thunk)) {
					if (list.size() >= 2000) {
						break;
					}
					Function f = fm.getFunctionContaining(ref.getFromAddress());
					list.add(map("from", str(ref.getFromAddress()), "type", ref.getReferenceType().getName(),
						"function", f != null ? f.getName(true) : null, "via", t != null ? t.getName() : str(thunk)));
				}
			}
		}
		return list;
	}

	Map<String, Object> functionInfo(Address address) {
		Function f = program.getFunctionManager().getFunctionContaining(address);
		if (f == null) {
			return null;
		}
		Map<String, Object> m = new LinkedHashMap<>();
		m.put("name", f.getName(true));
		m.put("entry", str(f.getEntryPoint()));
		m.put("signature", f.getPrototypeString(false, false));
		m.put("callingConvention", f.getCallingConventionName());
		m.put("returnType", f.getReturnType().getDisplayName());
		m.put("size", f.getBody().getNumAddresses());
		m.put("thunk", f.isThunk());
		m.put("thunkTarget", f.isThunk() && f.getThunkedFunction(true) != null
				? f.getThunkedFunction(true).getName(true) : null);
		m.put("comment", f.getComment());
		List<Map<String, Object>> params = new ArrayList<>();
		for (Parameter prm : f.getParameters()) {
			params.add(map("name", prm.getName(), "type", prm.getDataType().getDisplayName(),
				"storage", prm.getVariableStorage().toString()));
		}
		m.put("parameters", params);
		m.put("localCount", f.getLocalVariables().length);
		m.put("callers", fnRefs(f.getCallingFunctions(TaskMonitor.DUMMY)));
		m.put("callees", fnRefs(f.getCalledFunctions(TaskMonitor.DUMMY)));
		m.put("xrefs", xrefs(f.getEntryPoint()));
		return m;
	}

	static List<Map<String, Object>> fnRefs(Set<Function> fs) {
		List<Map<String, Object>> list = new ArrayList<>();
		for (Function f : fs) {
			list.add(map("name", f.getName(true), "address", str(f.getEntryPoint()), "external", f.isExternal()));
		}
		list.sort(Comparator.comparing(o -> (String) o.get("name")));
		return list;
	}

	Map<String, Object> resolve(String query) {
		String q = query.trim();
		Address a = null;
		for (Function f : program.getListing().getGlobalFunctions(q)) {
			a = f.getEntryPoint();
			break;
		}
		if (a == null) {
			SymbolIterator it = program.getSymbolTable().getSymbols(q);
			if (it.hasNext()) {
				a = it.next().getAddress();
			}
		}
		if (a == null) {
			String hexStr = q.toLowerCase().startsWith("0x") ? q.substring(2) : q;
			Address[] parsed = program.parseAddress(hexStr);
			if (parsed != null && parsed.length > 0) {
				a = parsed[0];
			}
		}
		if (a == null) {
			throw new IllegalArgumentException("No se encontró «" + q + "»");
		}
		Function f = program.getFunctionManager().getFunctionContaining(a);
		return map("address", str(a), "function", f != null ? str(f.getEntryPoint()) : null);
	}

	// ---------------------------------------------------------------- edits: names & comments

	Object rename(Address address, String name) throws Exception {
		return edit("Renombrar", () -> {
			Function f = program.getFunctionManager().getFunctionAt(address);
			if (f != null) {
				f.setName(name, SourceType.USER_DEFINED);
			}
			else {
				Symbol s = program.getSymbolTable().getPrimarySymbol(address);
				if (s != null && !s.isDynamic()) {
					s.setName(name, SourceType.USER_DEFINED);
				}
				else {
					program.getSymbolTable().createLabel(address, name, SourceType.USER_DEFINED);
				}
			}
			return true;
		});
	}

	Object createLabel(Address address, String name) throws Exception {
		return edit("Crear etiqueta", () -> {
			Symbol s = program.getSymbolTable().createLabel(address, name, SourceType.USER_DEFINED);
			s.setPrimary();
			return true;
		});
	}

	Object deleteLabel(Address address, String name) throws Exception {
		return edit("Borrar etiqueta", () -> {
			for (Symbol s : program.getSymbolTable().getSymbols(address)) {
				if ((name == null || s.getName().equals(name)) && s.getSymbolType() == SymbolType.LABEL) {
					s.delete();
				}
			}
			return true;
		});
	}

	Object comment(Address address, String kind, String text) throws Exception {
		CommentType type = switch (kind) {
			case "pre" -> CommentType.PRE;
			case "plate" -> CommentType.PLATE;
			case "post" -> CommentType.POST;
			case "repeatable" -> CommentType.REPEATABLE;
			default -> CommentType.EOL;
		};
		return edit("Comentario", () -> {
			program.getListing().setComment(address, type, text.isEmpty() ? null : text);
			return true;
		});
	}

	Object addBookmark(Address address, String category, String comment) throws Exception {
		return edit("Marcador", () -> {
			program.getBookmarkManager().setBookmark(address, BookmarkType.NOTE,
				category == null || category.isBlank() ? "Studio" : category, comment == null ? "" : comment);
			return true;
		});
	}

	Object deleteBookmark(Address address) throws Exception {
		return edit("Quitar marcador", () -> {
			for (Bookmark b : program.getBookmarkManager().getBookmarks(address)) {
				if (Debug.isBreakpoint(b)) {
					continue;
				}
				program.getBookmarkManager().removeBookmark(b);
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- edits: decompiler variables & signatures

	HighSymbol findLocal(HighFunction hf, String name) {
		Iterator<HighSymbol> it = hf.getLocalSymbolMap().getSymbols();
		while (it.hasNext()) {
			HighSymbol s = it.next();
			if (s.getName().equals(name)) {
				return s;
			}
		}
		throw new IllegalArgumentException("No se encontró la variable «" + name + "»");
	}

	Object renameVariable(Address fnAddr, String oldName, String newName) throws Exception {
		Function f = functionContaining(fnAddr);
		HighFunction hf = decompileRaw(f).getHighFunction();
		HighSymbol sym = findLocal(hf, oldName);
		return edit("Renombrar variable", () -> {
			if (sym.isParameter()) {
				HighFunctionDBUtil.commitParamsToDatabase(hf, false,
					HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.USER_DEFINED);
			}
			HighFunctionDBUtil.updateDBVariable(sym, newName, null, SourceType.USER_DEFINED);
			return true;
		});
	}

	Object retypeVariable(Address fnAddr, String name, String typeText) throws Exception {
		Function f = functionContaining(fnAddr);
		DataType dt = Types.parse(program, typeText);
		HighFunction hf = decompileRaw(f).getHighFunction();
		HighSymbol sym = findLocal(hf, name);
		return edit("Cambiar tipo", () -> {
			if (sym.isParameter()) {
				HighFunctionDBUtil.commitParamsToDatabase(hf, true,
					HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.USER_DEFINED);
			}
			HighFunctionDBUtil.updateDBVariable(sym, null, dt, SourceType.USER_DEFINED);
			return true;
		});
	}

	Object setSignature(Address fnAddr, String signature) throws Exception {
		Function f = functionContaining(fnAddr);
		FunctionSignatureParser parser = new FunctionSignatureParser(program.getDataTypeManager(),
			new Types.QueryService(program));
		FunctionDefinitionDataType def = parser.parse(f.getSignature(), signature);
		return edit("Editar firma", () -> {
			ApplyFunctionSignatureCmd cmd = new ApplyFunctionSignatureCmd(f.getEntryPoint(), def, SourceType.USER_DEFINED);
			if (!cmd.applyTo(program)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	Object setFunctionComment(Address fnAddr, String text) throws Exception {
		Function f = functionContaining(fnAddr);
		return edit("Comentario de función", () -> {
			f.setComment(text.isEmpty() ? null : text);
			return true;
		});
	}

	// ---------------------------------------------------------------- edits: code, data, patches

	Object disassemble(Address address) throws Exception {
		return edit("Desensamblar", () -> {
			DisassembleCommand cmd = new DisassembleCommand(address, null, true);
			if (!cmd.applyTo(program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg() != null ? cmd.getStatusMsg() : "No se pudo desensamblar");
			}
			return true;
		});
	}

	Object createFunction(Address address, String name) throws Exception {
		return edit("Crear función", () -> {
			CreateFunctionCmd cmd = new CreateFunctionCmd(address);
			if (!cmd.applyTo(program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg() != null ? cmd.getStatusMsg() : "No se pudo crear la función");
			}
			if (name != null && !name.isBlank()) {
				program.getFunctionManager().getFunctionAt(address).setName(name, SourceType.USER_DEFINED);
			}
			return true;
		});
	}

	Object deleteFunction(Address address) throws Exception {
		Function f = functionContaining(address);
		return edit("Borrar función", () -> program.getFunctionManager().removeFunction(f.getEntryPoint()));
	}

	Object clear(Address address) throws Exception {
		return edit("Borrar código", () -> {
			CodeUnit cu = program.getListing().getCodeUnitContaining(address);
			Address end = cu != null ? cu.getMaxAddress() : address;
			program.getListing().clearCodeUnits(cu != null ? cu.getAddress() : address, end, false);
			return true;
		});
	}

	Object createData(Address address, String typeText) throws Exception {
		DataType dt = Types.parse(program, typeText);
		return edit("Definir dato", () -> {
			DataUtilities.createData(program, address, dt, -1, DataUtilities.ClearDataMode.CLEAR_ALL_CONFLICT_DATA);
			return true;
		});
	}

	Object patchBytes(Address address, String hexText) throws Exception {
		byte[] bytes = parseHex(hexText);
		return edit("Parchear bytes", () -> {
			Listing listing = program.getListing();
			Address end = address.add(bytes.length - 1);
			boolean wasCode = listing.getInstructionContaining(address) != null;
			CodeUnit first = listing.getCodeUnitContaining(address);
			CodeUnit last = listing.getCodeUnitContaining(end);
			listing.clearCodeUnits(first != null ? first.getAddress() : address,
				last != null ? last.getMaxAddress() : end, false);
			program.getMemory().setBytes(address, bytes);
			if (wasCode) {
				new DisassembleCommand(address, null, true).applyTo(program, TaskMonitor.DUMMY);
			}
			return true;
		});
	}

	Object assemble(Address address, String instruction) throws Exception {
		return edit("Ensamblar", () -> {
			Assembler asm = Assemblers.getAssembler(program);
			byte[] bytes = asm.assembleLine(address, instruction);
			asm.assemble(address, instruction);
			return map("bytes", hex(bytes, 32));
		});
	}

	// ---------------------------------------------------------------- symbol tree

	/** Children of a namespace (0 = global): sub-namespaces/classes first, then symbols. */
	List<Map<String, Object>> namespaceChildren(long id) {
		SymbolTable st = program.getSymbolTable();
		Symbol parent = id == 0 ? program.getGlobalNamespace().getSymbol() : st.getSymbol(id);
		if (parent == null) {
			throw new IllegalArgumentException("Namespace desconocido");
		}
		List<Map<String, Object>> spaces = new ArrayList<>();
		List<Map<String, Object>> symbols = new ArrayList<>();
		SymbolIterator it = st.getChildren(parent);
		while (it.hasNext() && spaces.size() + symbols.size() < 5000) {
			Symbol sym = it.next();
			SymbolType t = sym.getSymbolType();
			boolean container = t == SymbolType.NAMESPACE || t == SymbolType.CLASS || t == SymbolType.LIBRARY;
			Map<String, Object> m = map("id", sym.getID(), "name", sym.getName(), "kind", t.toString(),
				"address", sym.isExternal() || container ? null : str(sym.getAddress()),
				"container", container || t == SymbolType.FUNCTION && st.getChildren(sym).hasNext(),
				"external", sym.isExternal());
			(container ? spaces : symbols).add(m);
		}
		Comparator<Map<String, Object>> byName = Comparator.comparing(o -> ((String) o.get("name")).toLowerCase());
		spaces.sort(byName);
		symbols.sort(byName);
		spaces.addAll(symbols);
		return spaces;
	}

	// ---------------------------------------------------------------- memory map

	private MemoryBlock block(String name) {
		MemoryBlock b = program.getMemory().getBlock(name);
		if (b == null) {
			throw new IllegalArgumentException("No existe el bloque " + name);
		}
		return b;
	}

	Object renameBlock(String name, String newName) throws Exception {
		MemoryBlock b = block(name);
		return edit("Renombrar bloque", () -> {
			b.setName(newName);
			return true;
		});
	}

	Object setBlockPerms(String name, boolean r, boolean w, boolean x) throws Exception {
		MemoryBlock b = block(name);
		return edit("Permisos de bloque", () -> {
			b.setPermissions(r, w, x);
			return true;
		});
	}

	Object addBlock(String name, Address start, long length, boolean initialized, String comment) throws Exception {
		return edit("Añadir bloque", () -> {
			MemoryBlock b = initialized
					? program.getMemory().createInitializedBlock(name, start, length, (byte) 0, TaskMonitor.DUMMY, false)
					: program.getMemory().createUninitializedBlock(name, start, length, false);
			b.setPermissions(true, true, false);
			if (comment != null) {
				b.setComment(comment);
			}
			return true;
		});
	}

	Object deleteBlock(String name) throws Exception {
		MemoryBlock b = block(name);
		return edit("Borrar bloque", () -> {
			program.getMemory().removeBlock(b, TaskMonitor.DUMMY);
			return true;
		});
	}

	// ---------------------------------------------------------------- references & equates

	List<Map<String, Object>> referencesFrom(Address a) {
		List<Map<String, Object>> list = new ArrayList<>();
		for (Reference r : program.getReferenceManager().getReferencesFrom(a)) {
			Function f = program.getFunctionManager().getFunctionContaining(r.getToAddress());
			list.add(map("to", str(r.getToAddress()), "type", r.getReferenceType().getName(),
				"operand", r.getOperandIndex(), "source", r.getSource().toString(), "primary", r.isPrimary(),
				"function", f != null ? f.getName(true) : null));
		}
		return list;
	}

	Object addReference(Address from, Address to, int opIndex, String type) throws Exception {
		RefType rt = switch (type) {
			case "read" -> RefType.READ;
			case "write" -> RefType.WRITE;
			case "call" -> RefType.UNCONDITIONAL_CALL;
			case "jump" -> RefType.UNCONDITIONAL_JUMP;
			default -> RefType.DATA;
		};
		return edit("Añadir referencia", () -> {
			program.getReferenceManager().addMemoryReference(from, to, rt, SourceType.USER_DEFINED, opIndex);
			return true;
		});
	}

	Object deleteReference(Address from, Address to) throws Exception {
		return edit("Quitar referencia", () -> {
			for (Reference r : program.getReferenceManager().getReferencesFrom(from)) {
				if (r.getToAddress().equals(to)) {
					program.getReferenceManager().delete(r);
				}
			}
			return true;
		});
	}

	/** Names the first scalar operand at an instruction (or the one with the given value). */
	Object setEquate(Address a, String name, String value) throws Exception {
		Instruction ins = program.getListing().getInstructionAt(a);
		if (ins == null) {
			throw new IllegalArgumentException("No hay ninguna instrucción en " + a);
		}
		Long wanted = value == null || value.isBlank() ? null : Emulation.parseNumber(value).longValue();
		int opIndex = -1;
		long scalar = 0;
		for (int i = 0; i < ins.getNumOperands(); i++) {
			ghidra.program.model.scalar.Scalar sc = ins.getScalar(i);
			if (sc != null && (wanted == null || sc.getValue() == wanted || sc.getUnsignedValue() == wanted)) {
				opIndex = i;
				scalar = sc.getValue();
				break;
			}
		}
		if (opIndex < 0) {
			throw new IllegalArgumentException("La instrucción no tiene ninguna constante" + (wanted != null ? " con ese valor" : ""));
		}
		int op = opIndex;
		long v = scalar;
		return edit("Equate", () -> {
			EquateTable et = program.getEquateTable();
			Equate e = et.getEquate(name);
			if (e == null) {
				e = et.createEquate(name, v);
			}
			else if (e.getValue() != v) {
				throw new IllegalArgumentException("El equate «" + name + "» ya existe con otro valor");
			}
			e.addReference(a, op);
			return map("operand", op, "value", v);
		});
	}

	List<Map<String, Object>> equates() {
		List<Map<String, Object>> list = new ArrayList<>();
		Iterator<Equate> it = program.getEquateTable().getEquates();
		while (it.hasNext()) {
			Equate e = it.next();
			list.add(map("name", e.getName(), "value", e.getValue(), "references", e.getReferenceCount()));
		}
		return list;
	}

	// ---------------------------------------------------------------- auto structure

	/** Like the decompiler's "Auto Create Structure": infers a struct from how a pointer variable is used. */
	Object autoStructure(Address fnAddr, String varName) throws Exception {
		Function f = functionContaining(fnAddr);
		HighFunction hf = decompileRaw(f).getHighFunction();
		HighSymbol sym = findLocal(hf, varName);
		HighVariable hv = sym.getHighVariable();
		if (hv == null) {
			throw new IllegalArgumentException("La variable no tiene uso en el código");
		}
		return edit("Crear estructura", () -> {
			ghidra.app.decompiler.util.FillOutStructureHelper helper =
				new ghidra.app.decompiler.util.FillOutStructureHelper(program, TaskMonitor.DUMMY);
			Structure st = helper.processStructure(hv, f, false, true, decompiler);
			if (st == null) {
				throw new IllegalStateException("No se pudo inferir ninguna estructura para «" + varName + "»");
			}
			DataType added = program.getDataTypeManager().addDataType(st, DataTypeConflictHandler.DEFAULT_HANDLER);
			if (sym.isParameter()) {
				HighFunctionDBUtil.commitParamsToDatabase(hf, true,
					HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.USER_DEFINED);
			}
			HighFunctionDBUtil.updateDBVariable(sym, null, new PointerDataType(added), SourceType.USER_DEFINED);
			return map("path", added.getPathName(), "size", added.getLength());
		});
	}

	// ---------------------------------------------------------------- undo / redo

	Object undo() throws IOException {
		if (isAnalyzing()) {
			throw new IllegalStateException("Espera a que termine el análisis para deshacer");
		}
		if (program.canUndo()) {
			program.undo();
		}
		invalidate();
		return undoState();
	}

	Object redo() throws IOException {
		if (isAnalyzing()) {
			throw new IllegalStateException("Espera a que termine el análisis para rehacer");
		}
		if (program.canRedo()) {
			program.redo();
		}
		invalidate();
		return undoState();
	}

	// ---------------------------------------------------------------- analysis options

	List<Map<String, Object>> analysisOptions() {
		AutoAnalysisManager.getAnalysisManager(program).initializeOptions();
		Options opts = program.getOptions(Program.ANALYSIS_PROPERTIES);
		List<Map<String, Object>> list = new ArrayList<>();
		for (String name : opts.getOptionNames()) {
			if (name.contains(".") || opts.getType(name) != OptionType.BOOLEAN_TYPE) {
				continue;
			}
			list.add(map("name", name, "enabled", opts.getBoolean(name, false), "description", opts.getDescription(name)));
		}
		list.sort(Comparator.comparing(o -> (String) o.get("name")));
		return list;
	}

	/** Sub-options of one analyzer ("Analyzer.Option name"), typed. */
	List<Map<String, Object>> analyzerOptions(String analyzer) {
		Options opts = program.getOptions(Program.ANALYSIS_PROPERTIES);
		List<Map<String, Object>> list = new ArrayList<>();
		String prefix = analyzer + ".";
		for (String name : opts.getOptionNames()) {
			if (!name.startsWith(prefix)) {
				continue;
			}
			OptionType t = opts.getType(name);
			String type = t == OptionType.BOOLEAN_TYPE ? "bool"
					: t == OptionType.INT_TYPE || t == OptionType.LONG_TYPE || t == OptionType.DOUBLE_TYPE ? "number"
					: t == OptionType.ENUM_TYPE ? "enum" : t == OptionType.STRING_TYPE ? "text" : null;
			if (type == null) {
				continue;
			}
			Object value = opts.getObject(name, null);
			Map<String, Object> m = map("name", name, "label", name.substring(prefix.length()), "type", type,
				"value", value != null ? (value instanceof java.lang.Enum<?> e ? e.name() : value.toString()) : "",
				"description", opts.getDescription(name));
			if (value instanceof java.lang.Enum<?> e) {
				List<String> choices = new ArrayList<>();
				for (Object c : e.getDeclaringClass().getEnumConstants()) {
					choices.add(((java.lang.Enum<?>) c).name());
				}
				m.put("choices", choices);
			}
			list.add(m);
		}
		return list;
	}

	@SuppressWarnings({ "unchecked", "rawtypes" })
	Object setAnalyzerOption(String name, String value) throws Exception {
		return edit("Opciones de análisis", () -> {
			Options opts = program.getOptions(Program.ANALYSIS_PROPERTIES);
			OptionType t = opts.getType(name);
			if (t == OptionType.BOOLEAN_TYPE) {
				opts.setBoolean(name, Boolean.parseBoolean(value));
			}
			else if (t == OptionType.INT_TYPE) {
				opts.setInt(name, Integer.parseInt(value.trim()));
			}
			else if (t == OptionType.LONG_TYPE) {
				opts.setLong(name, Long.parseLong(value.trim()));
			}
			else if (t == OptionType.DOUBLE_TYPE) {
				opts.setDouble(name, Double.parseDouble(value.trim()));
			}
			else if (t == OptionType.ENUM_TYPE) {
				java.lang.Enum<?> current = (java.lang.Enum<?>) opts.getObject(name, null);
				opts.setEnum(name, java.lang.Enum.valueOf((Class) current.getDeclaringClass(), value));
			}
			else {
				opts.setString(name, value);
			}
			return true;
		});
	}

	/** Runs a single analyzer once over the whole program, in the background (One Shot analysis). */
	void runAnalyzer(String name) {
		if (isAnalyzing()) {
			throw new IllegalStateException("Ya hay un análisis en marcha");
		}
		AutoAnalysisManager mgr = AutoAnalysisManager.getAnalysisManager(program);
		mgr.initializeOptions();
		ghidra.app.services.Analyzer analyzer = mgr.getAnalyzer(name);
		if (analyzer == null) {
			throw new IllegalArgumentException("Analizador desconocido: " + name);
		}
		ProgressMonitor monitor = new ProgressMonitor();
		analysisMonitor = monitor;
		Thread t = new Thread(() -> {
			int tx = program.startTransaction(name);
			try {
				mgr.scheduleOneTimeAnalysis(analyzer, program.getMemory());
				mgr.startAnalysis(monitor);
			}
			catch (Throwable e) {
				e.printStackTrace();
			}
			finally {
				program.endTransaction(tx, true);
			}
			invalidate();
			analysisThread = null;
			analysisMonitor = null;
			server.send(map("event", "analysisDone", "session", id, "completed", !monitor.isCancelled()));
		}, "studio-oneshot");
		t.setDaemon(true);
		analysisThread = t;
		server.send(map("event", "analysisStarted", "session", id));
		t.start();
	}

	Object loadPdb(String path) throws Exception {
		java.io.File file = new java.io.File(path);
		if (!file.isFile()) {
			throw new java.io.FileNotFoundException("No existe: " + path);
		}
		edit("Cargar PDB", () -> {
			ghidra.app.plugin.core.analysis.PdbUniversalAnalyzer.setPdbFileOption(program, file);
			return true;
		});
		runAnalyzer("PDB Universal");
		return true;
	}

	Object setAnalysisOptions(Map<String, Boolean> values) throws Exception {
		return edit("Opciones de análisis", () -> {
			Options opts = program.getOptions(Program.ANALYSIS_PROPERTIES);
			for (Map.Entry<String, Boolean> e : values.entrySet()) {
				opts.setBoolean(e.getKey(), e.getValue());
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- progress

	/** Streams analysis progress to the UI, throttled. */
	private class ProgressMonitor extends TaskMonitorAdapter {
		private String message = "Analizando…";
		private long max = 0;
		private long value = 0;

		ProgressMonitor() {
			super(true);
		}

		@Override
		public void setMessage(String msg) {
			if (msg != null && !msg.isBlank()) {
				message = msg;
			}
			emit(false);
		}

		@Override
		public void initialize(long maximum) {
			max = maximum;
			value = 0;
			emit(true);
		}

		@Override
		public void setMaximum(long maximum) {
			max = maximum;
		}

		@Override
		public void setProgress(long v) {
			value = v;
			emit(false);
		}

		@Override
		public void incrementProgress(long inc) {
			value += inc;
			emit(false);
		}

		private void emit(boolean force) {
			long now = System.currentTimeMillis();
			if (!force && now - lastProgress < 150) {
				return;
			}
			lastProgress = now;
			server.send(map("event", "analysisProgress", "session", id, "message", message,
				"value", max > 0 ? Math.min(1.0, (double) value / max) : -1.0));
		}
	}
}
