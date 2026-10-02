package studio;

import static studio.Json.*;

import java.io.File;
import java.util.*;
import java.util.regex.Pattern;

import generic.stl.Pair;
import ghidra.app.decompiler.*;
import ghidra.app.decompiler.component.DecompilerUtils;
import ghidra.program.database.SpecExtension;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.*;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.*;
import ghidra.util.task.TaskMonitor;

/** Decompiler actions on tokens, program-wide decompiled text search, spec extensions and taint. */
final class Decomp {
	private Decomp() {
	}

	// ---------------------------------------------------------------- tokens

	/** What a token is, so the interface knows which actions to offer. */
	static Map<String, Object> tokenInfo(Session s, Address fn, int tokenId) {
		ClangToken t = s.token(fn, tokenId);
		Map<String, Object> m = map("text", t.getText(), "kind", t.getClass().getSimpleName());
		PcodeOp op = t.getPcodeOp();
		if (op != null && op.getSeqnum() != null) {
			m.put("address", str(op.getSeqnum().getTarget()));
		}
		if (t instanceof ClangVariableToken vt) {
			Scalar sc = vt.getScalar();
			if (sc != null) {
				m.put("scalar", map("value", sc.getValue(), "unsigned", sc.getUnsignedValue(), "bits", sc.bitLength()));
				m.put("equates", equatesOf(s, vt));
			}
			HighVariable hv = vt.getHighVariable();
			if (hv != null && hv.getDataType() != null) {
				m.put("type", hv.getDataType().getPathName());
				m.put("typeName", hv.getDataType().getDisplayName());
				m.put("variable", hv.getName());
				DataType base = hv.getDataType();
				if (base instanceof TypeDef td) {
					base = td.getBaseDataType();
				}
				m.put("pointer", base instanceof Pointer);
			}
		}
		if (t instanceof ClangTypeToken tt && tt.getDataType() != null) {
			m.put("type", tt.getDataType().getPathName());
			m.put("typeName", tt.getDataType().getDisplayName());
			m.put("returnType", t.Parent() instanceof ClangReturnType);
		}
		if (t instanceof ClangFieldToken ft && ft.getDataType() != null) {
			DataType owner = ft.getDataType();
			if (owner instanceof TypeDef td) {
				owner = td.getBaseDataType();
			}
			m.put("fieldOwner", owner.getPathName());
			m.put("fieldOffset", ft.getOffset());
			if (owner instanceof Composite c) {
				DataTypeComponent comp = c instanceof Structure st ? st.getComponentContaining(ft.getOffset()) : null;
				if (comp != null) {
					m.put("type", comp.getDataType().getPathName());
					m.put("typeName", comp.getDataType().getDisplayName());
				}
			}
		}
		if (t instanceof ClangLabelToken lt) {
			Address a = lt.getMinAddress();
			if (a != null) {
				m.put("label", str(a));
			}
		}
		if (t instanceof ClangFuncNameToken) {
			Address target = s.tokenTarget(t);
			if (target != null) {
				m.put("function", str(target));
			}
		}
		return m;
	}

	private static List<String> equatesOf(Session s, ClangVariableToken vt) {
		List<String> out = new ArrayList<>();
		PcodeOp op = vt.getPcodeOp();
		if (op == null) {
			return out;
		}
		Address a = op.getSeqnum().getTarget();
		long value = vt.getScalar().getValue();
		for (Equate e : s.program.getEquateTable().getEquates(a)) {
			if (e.getValue() == value || e.getValue() == vt.getScalar().getUnsignedValue()) {
				out.add(e.getName());
			}
		}
		return out;
	}

	private static ClangVariableToken constant(Session s, Address fn, int tokenId) {
		if (!(s.token(fn, tokenId) instanceof ClangVariableToken vt) || vt.getScalar() == null || vt.getPcodeOp() == null) {
			throw new IllegalArgumentException("Coloca el cursor sobre una constante");
		}
		return vt;
	}

	/** Names the constant under the cursor: with a converted value (format) or with an equate (name). */
	static Object setEquate(Session s, Address fn, int tokenId, String format, String name) throws Exception {
		ClangVariableToken vt = constant(s, fn, tokenId);
		HighFunction hf = s.highFunction(fn);
		Scalar sc = vt.getScalar();
		Address a = vt.getPcodeOp().getSeqnum().getTarget();
		long value = sc.getValue();
		// an empty name removes the equate
		String equateName = name != null ? name.trim() : Annotate.convertedName(value, sc.bitLength(), format);
		// like Ghidra: an operand reference when the instruction shows the same scalar, else a dynamic hash
		Instruction ins = s.program.getListing().getInstructionAt(a);
		int operand = -1;
		if (ins != null) {
			for (int i = 0; i < ins.getNumOperands() && operand < 0; i++) {
				for (Object o : ins.getOpObjects(i)) {
					if (o instanceof Scalar x && (x.getValue() == value || x.getUnsignedValue() == sc.getUnsignedValue())) {
						operand = i;
						break;
					}
				}
			}
		}
		int op = operand;
		Varnode vn = vt.getVarnode();
		long hash = 0;
		if (op < 0) {
			DynamicHash dh = new DynamicHash(vn, 0);
			hash = dh.getHash();
			if (hash == 0) {
				throw new IllegalStateException("Esa constante no se puede identificar de forma estable");
			}
			a = dh.getAddress();
		}
		long h = hash;
		Address at = a;
		return s.edit("Equate", () -> {
			EquateTable table = s.program.getEquateTable();
			for (Equate old : table.getEquates(at)) {
				if (old.getValue() != value) {
					continue;
				}
				if (op >= 0) {
					old.removeReference(at, op);
				}
				else {
					old.removeReference(h, at);
				}
				if (old.getReferenceCount() == 0) {
					table.removeEquate(old.getName());
				}
			}
			if (equateName.isEmpty()) {
				return "";
			}
			Equate e = table.getEquate(equateName);
			if (e == null) {
				e = table.createEquate(equateName, value);
			}
			else if (e.getValue() != value) {
				throw new IllegalArgumentException("Ya existe un equate «" + equateName + "» con otro valor");
			}
			if (op >= 0) {
				e.addReference(at, op);
			}
			else {
				e.addReference(h, at);
			}
			return equateName;
		});
	}

	static Object retypeReturn(Session s, Address fn, String type) throws Exception {
		Function f = s.functionContaining(fn);
		DataType dt = Types.parse(s.program, type);
		return s.edit("Cambiar tipo de retorno", () -> {
			f.setReturnType(dt, SourceType.USER_DEFINED);
			return true;
		});
	}

	static Object retypeField(Session s, String typePath, int offset, String type) throws Exception {
		DataType owner = Types.find(s.program, typePath);
		DataType dt = Types.parse(s.program, type);
		return s.edit("Cambiar tipo del campo", () -> {
			if (owner instanceof Structure st) {
				DataTypeComponent c = st.getComponentContaining(offset);
				String name = c == null ? null : c.getFieldName();
				String comment = c == null ? null : c.getComment();
				st.replaceAtOffset(offset, dt, dt.getLength(), name, comment);
			}
			else if (owner instanceof Union u) {
				for (DataTypeComponent c : u.getComponents()) {
					if (c.getOrdinal() == offset) {
						String name = c.getFieldName();
						String comment = c.getComment();
						u.delete(c.getOrdinal());
						u.insert(c.getOrdinal(), dt, dt.getLength(), name, comment);
						break;
					}
				}
			}
			else {
				throw new IllegalArgumentException(typePath + " no es una estructura");
			}
			return true;
		});
	}

	/** Makes a pointer variable point inside a structure: a pointer typedef with a component offset. */
	static Object adjustPointerOffset(Session s, Address fn, String variable, String structPath, long offset)
			throws Exception {
		DataType base = Types.parse(s.program, structPath);
		DataTypeManager dtm = s.program.getDataTypeManager();
		PointerTypedef typedef = new PointerTypedef(null, base, -1, dtm, offset);
		HighFunction hf = s.highFunction(fn);
		HighSymbol sym = s.findLocal(hf, variable);
		return s.edit("Ajustar offset del puntero", () -> {
			DataType resolved = dtm.resolve(typedef, DataTypeConflictHandler.DEFAULT_HANDLER);
			if (sym.isParameter()) {
				HighFunctionDBUtil.commitParamsToDatabase(hf, true, HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT,
					SourceType.USER_DEFINED);
			}
			HighFunctionDBUtil.updateDBVariable(sym, null, resolved, SourceType.USER_DEFINED);
			return resolved.getDisplayName();
		});
	}

	// ---------------------------------------------------------------- program-wide text search

	/** Finds text in the decompiled code of every function. */
	static List<Map<String, Object>> search(Session s, String query, boolean regex, boolean caseSensitive, int limit,
			TaskMonitor monitor) throws Exception {
		Pattern pattern = Pattern.compile(regex ? query : Pattern.quote(query), caseSensitive ? 0 : Pattern.CASE_INSENSITIVE);
		List<Map<String, Object>> out = new ArrayList<>();
		FunctionManager fm = s.program.getFunctionManager();
		monitor.initialize(fm.getFunctionCount());
		DecompInterface ifc = new DecompInterface();
		ifc.toggleCCode(true);
		ifc.toggleSyntaxTree(false);
		ifc.openProgram(s.program);
		try {
			for (Function f : fm.getFunctions(true)) {
				monitor.checkCancelled();
				monitor.incrementProgress(1);
				monitor.setMessage(f.getName());
				if (f.isExternal() || f.isThunk()) {
					continue;
				}
				DecompileResults res = ifc.decompileFunction(f, 30, monitor);
				if (!res.decompileCompleted() || res.getCCodeMarkup() == null) {
					continue;
				}
				int n = 0;
				for (ClangLine line : DecompilerUtils.toLines(res.getCCodeMarkup())) {
					n++;
					StringBuilder sb = new StringBuilder();
					Address at = null;
					for (ClangToken t : line.getAllTokens()) {
						if (t.getText() != null) {
							sb.append(t.getText());
						}
						if (at == null && t.getMinAddress() != null) {
							at = t.getMinAddress();
						}
					}
					if (pattern.matcher(sb).find()) {
						out.add(map("address", str(at != null ? at : f.getEntryPoint()), "function", f.getName(),
							"entry", str(f.getEntryPoint()), "line", n, "text", sb.toString().trim()));
						if (out.size() >= limit) {
							return out;
						}
					}
				}
			}
		}
		finally {
			ifc.dispose();
		}
		return out;
	}

	/** Writes the decompiler's debug file for a function (what Ghidra's "Debug Function Decompilation" saves). */
	static Object debug(Session s, Address fn, String path) throws Exception {
		Function f = s.functionContaining(fn);
		File file = new File(path.endsWith(".xml") ? path : path + ".xml");
		DecompInterface ifc = new DecompInterface();
		ifc.setOptions(new DecompileOptions());
		ifc.openProgram(s.program);
		try {
			ifc.enableDebug(file);
			DecompileResults res = ifc.decompileFunction(f, 120, TaskMonitor.DUMMY);
			return map("path", file.getAbsolutePath(), "ok", res.decompileCompleted(), "size", file.length());
		}
		finally {
			ifc.dispose();
		}
	}

	// ---------------------------------------------------------------- specification extensions

	static List<Map<String, Object>> specExtensions(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Pair<String, String> p : SpecExtension.getCompilerSpecExtensions(s.program)) {
			String key = p.first;
			// option names look like "callfixup_name"
			int cut = key.indexOf('_');
			out.add(map("key", key, "type", cut > 0 ? key.substring(0, cut) : key, "name", cut > 0 ? key.substring(cut + 1) : key,
				"xml", p.second, "source", "program"));
		}
		ghidra.program.model.lang.CompilerSpec spec = s.program.getCompilerSpec();
		for (ghidra.program.model.lang.PrototypeModel model : spec.getAllModels()) {
			if (!model.isProgramExtension()) {
				out.add(map("key", "", "type", "prototype", "name", model.getName(), "xml", "", "source", "compiler"));
			}
		}
		ghidra.program.model.lang.PcodeInjectLibrary lib = spec.getPcodeInjectLibrary();
		for (String name : lib.getCallFixupNames()) {
			if (out.stream().noneMatch(m -> name.equals(m.get("name")))) {
				out.add(map("key", "", "type", "callfixup", "name", name, "xml", "", "source", "compiler"));
			}
		}
		return out;
	}

	/** Adds or replaces a call-fixup, callother-fixup or prototype model given as its XML. */
	static Object addSpecExtension(Session s, String xml) throws Exception {
		SpecExtension ext = new SpecExtension(s.program);
		ext.testExtensionDocument(xml);
		return s.edit("Extensión de especificación", () -> {
			ext.addReplaceCompilerSpecExtension(xml, TaskMonitor.DUMMY);
			return true;
		});
	}

	static Object removeSpecExtension(Session s, String key) throws Exception {
		SpecExtension ext = new SpecExtension(s.program);
		return s.edit("Quitar extensión de especificación", () -> {
			ext.removeCompilerSpecExtension(key, TaskMonitor.DUMMY);
			return true;
		});
	}

	// ---------------------------------------------------------------- taint

	/**
	 * Follows data from source variables: which tokens of the function they reach, which of the sink
	 * variables, and which calls receive them (followed into the callee, a few levels deep).
	 */
	static Map<String, Object> taint(Session s, Address fn, List<String> sources, List<String> sinks, int depth,
			TaskMonitor monitor) throws Exception {
		List<Map<String, Object>> reached = new ArrayList<>();
		Set<String> visited = new HashSet<>();
		List<Integer> tokens = follow(s, s.functionContaining(fn), new LinkedHashSet<>(sources), new HashSet<>(sinks),
			Math.max(0, depth), reached, visited, monitor, true);
		return map("tokens", tokens, "reached", reached);
	}

	private static List<Integer> follow(Session s, Function f, Set<String> sources, Set<String> sinks, int depth,
			List<Map<String, Object>> reached, Set<String> visited, TaskMonitor monitor, boolean top) throws Exception {
		List<Integer> tokenIds = new ArrayList<>();
		if (!visited.add(f.getEntryPoint() + "|" + sources) || reached.size() > 2000) {
			return tokenIds;
		}
		monitor.checkCancelled();
		monitor.setMessage(f.getName());
		HighFunction hf = s.decompileRaw(f).getHighFunction();
		if (hf == null) {
			return tokenIds;
		}
		Set<Varnode> vars = new HashSet<>();
		Set<PcodeOp> ops = new HashSet<>();
		Iterator<HighSymbol> symbols = hf.getLocalSymbolMap().getSymbols();
		List<HighSymbol> all = new ArrayList<>();
		symbols.forEachRemaining(all::add);
		hf.getGlobalSymbolMap().getSymbols().forEachRemaining(all::add);
		for (HighSymbol sym : all) {
			// "#n" is the n-th parameter, whatever its name
			boolean source = sources.contains(sym.getName())
					|| (sym.isParameter() && sources.contains("#" + sym.getCategoryIndex()));
			if (!source || sym.getHighVariable() == null) {
				continue;
			}
			for (Varnode vn : sym.getHighVariable().getInstances()) {
				vars.addAll(DecompilerUtils.getForwardSlice(vn));
				ops.addAll(DecompilerUtils.getForwardSliceToPCodeOps(vn));
				vars.add(vn);
			}
		}
		if (vars.isEmpty()) {
			return tokenIds;
		}
		// sinks reached in this function
		for (HighSymbol sym : all) {
			if (sym.getHighVariable() == null || sources.contains(sym.getName())) {
				continue;
			}
			boolean hit = false;
			for (Varnode vn : sym.getHighVariable().getInstances()) {
				if (vars.contains(vn)) {
					hit = true;
					break;
				}
			}
			if (hit && sinks.contains(sym.getName())) {
				reached.add(map("function", f.getName(), "address", str(f.getEntryPoint()), "kind", "sink",
					"what", sym.getName()));
			}
		}
		// calls that receive tainted data, and returns
		Iterator<PcodeOpAST> it = hf.getPcodeOps();
		while (it.hasNext()) {
			PcodeOp op = it.next();
			int code = op.getOpcode();
			if (code == PcodeOp.RETURN) {
				for (int i = 1; i < op.getNumInputs(); i++) {
					if (vars.contains(op.getInput(i))) {
						reached.add(map("function", f.getName(), "address", str(op.getSeqnum().getTarget()), "kind", "return",
							"what", f.getName()));
					}
				}
				continue;
			}
			if (code != PcodeOp.CALL && code != PcodeOp.CALLIND) {
				continue;
			}
			Function callee = code == PcodeOp.CALL
					? s.program.getFunctionManager().getFunctionAt(op.getInput(0).getAddress()) : null;
			if (callee != null && callee.isThunk()) {
				callee = callee.getThunkedFunction(true);
			}
			for (int i = 1; i < op.getNumInputs(); i++) {
				if (!vars.contains(op.getInput(i))) {
					continue;
				}
				String name = callee != null ? callee.getName() : "(indirecta)";
				boolean sink = callee != null && sinks.contains(callee.getName());
				reached.add(map("function", f.getName(), "address", str(op.getSeqnum().getTarget()),
					"kind", sink ? "sink" : "call", "what", name + " · arg " + i));
				if (callee != null && !callee.isExternal() && depth > 0) {
					Set<String> inner = new LinkedHashSet<>();
					inner.add("#" + (i - 1));
					follow(s, callee, inner, sinks, depth - 1, reached, visited, monitor, false);
				}
			}
		}
		if (top) {
			s.decompile(f.getEntryPoint());
			for (int i = 0;; i++) {
				ClangToken t;
				try {
					t = s.token(f.getEntryPoint(), i);
				}
				catch (IllegalArgumentException end) {
					break;
				}
				if (!(t instanceof ClangVariableToken) && !(t instanceof ClangOpToken) && !(t instanceof ClangFuncNameToken)) {
					continue;
				}
				Varnode v = DecompilerUtils.getVarnodeRef(t);
				PcodeOp op = t.getPcodeOp();
				if ((v != null && vars.contains(v)) || (op != null && ops.contains(op))) {
					tokenIds.add(i);
				}
			}
		}
		return tokenIds;
	}
}
