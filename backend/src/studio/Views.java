package studio;

import static studio.Json.*;

import java.util.*;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.program.model.address.*;
import ghidra.program.model.block.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.*;
import ghidra.program.model.symbol.*;
import ghidra.util.task.TaskMonitor;

/** Program overview bar, selections by flow and the decompiler's p-code graphs. */
final class Views {
	private static final int MAX_RANGES = 5000;
	private static final int MAX_GRAPH_NODES = 1500;

	private Views() {
	}

	// ---------------------------------------------------------------- overview

	/**
	 * What the whole program looks like, in {@code buckets} slices: 0 function, 1 instruction outside a function,
	 * 2 data, 3 undefined, 4 uninitialized, 5 external.
	 */
	static Map<String, Object> overview(Session s, int buckets) {
		Program p = s.program;
		List<Map<String, Object>> ranges = new ArrayList<>();
		List<AddressRange> list = new ArrayList<>();
		long offset = 0;
		for (MemoryBlock block : p.getMemory().getBlocks()) {
			ranges.add(map("start", str(block.getStart()), "end", str(block.getEnd()), "offset", offset,
				"size", block.getSize(), "name", block.getName()));
			list.add(new AddressRangeImpl(block.getStart(), block.getEnd()));
			offset += block.getSize();
		}
		long total = offset;
		if (list.isEmpty()) {
			return map("total", 0, "ranges", ranges, "kinds", new int[0], "starts", new String[0], "changes", List.of());
		}
		int n = (int) Math.max(1, Math.min(Math.min(buckets, 4000), total));
		int[] kinds = new int[n];
		String[] starts = new String[n];
		Listing listing = p.getListing();
		FunctionManager fm = p.getFunctionManager();
		int ri = 0;
		long base = 0;
		for (int i = 0; i < n; i++) {
			long at = (long) ((double) i * total / n);
			while (ri < list.size() - 1 && at >= base + list.get(ri).getLength()) {
				base += list.get(ri).getLength();
				ri++;
			}
			Address a = list.get(ri).getMinAddress().add(at - base);
			starts[i] = str(a);
			kinds[i] = kind(p, listing, fm, a);
		}
		List<Map<String, Object>> changes = new ArrayList<>();
		for (AddressRange r : p.getChanges().getAddressSet()) {
			if (changes.size() >= 2000) {
				break;
			}
			changes.add(map("start", str(r.getMinAddress()), "end", str(r.getMaxAddress())));
		}
		return map("total", total, "ranges", ranges, "kinds", kinds, "starts", starts, "changes", changes);
	}

	private static int kind(Program p, Listing listing, FunctionManager fm, Address a) {
		MemoryBlock block = p.getMemory().getBlock(a);
		if (block != null && block.isExternalBlock()) {
			return 5;
		}
		CodeUnit cu = listing.getCodeUnitContaining(a);
		if (cu instanceof Instruction) {
			return fm.getFunctionContaining(a) != null ? 0 : 1;
		}
		if (cu instanceof Data d && d.isDefined()) {
			return 2;
		}
		return block != null && !block.isInitialized() ? 4 : 3;
	}

	// ---------------------------------------------------------------- selections

	static AddressSet ranges(Session s, JsonElement e) {
		AddressSet set = new AddressSet();
		if (e == null || !e.isJsonArray()) {
			return set;
		}
		for (JsonElement item : (JsonArray) e) {
			JsonArray pair = item.getAsJsonArray();
			set.add(s.addr(pair.get(0).getAsString()), s.addr(pair.get(1).getAsString()));
		}
		return set;
	}

	private static Map<String, Object> result(AddressSetView set) {
		List<List<String>> out = new ArrayList<>();
		for (AddressRange r : set) {
			if (out.size() >= MAX_RANGES) {
				break;
			}
			out.add(List.of(str(r.getMinAddress()), str(r.getMaxAddress())));
		}
		return map("ranges", out, "rangeCount", set.getNumAddressRanges(), "addresses", set.getNumAddresses(),
			"truncated", set.getNumAddressRanges() > out.size(), "first", str(set.getMinAddress()));
	}

	/** The code units covering a set (a caret selects the whole instruction, like the CodeBrowser). */
	private static AddressSet codeUnits(Program p, AddressSetView set) {
		AddressSet out = new AddressSet(set);
		for (AddressRange r : set) {
			CodeUnit first = p.getListing().getCodeUnitContaining(r.getMinAddress());
			CodeUnit last = p.getListing().getCodeUnitContaining(r.getMaxAddress());
			if (first != null) {
				out.add(first.getMinAddress(), first.getMaxAddress());
			}
			if (last != null) {
				out.add(last.getMinAddress(), last.getMaxAddress());
			}
		}
		return out;
	}

	/** Ghidra's Select menu. {@code current} is the selection so far (may be empty), {@code at} the cursor. */
	static Map<String, Object> select(Session s, String kind, Address at, AddressSet current, TaskMonitor monitor)
			throws Exception {
		Program p = s.program;
		AddressSetView memory = p.getMemory();
		AddressSet seed = current.isEmpty() ? new AddressSet(at) : current;
		seed = codeUnits(p, seed);
		// "all in scope" kinds use the selection when there is one, otherwise the whole program
		AddressSetView scope = current.isEmpty() ? memory : current;
		Listing listing = p.getListing();
		AddressSet out = new AddressSet();
		switch (kind) {
			case "all":
				out.add(memory);
				break;
			case "complement":
				out.add(memory);
				out.delete(current);
				break;
			case "changes":
				out.add(p.getChanges().getAddressSet().intersect(memory));
				break;
			case "flowFrom":
				out.add(new FollowFlow(p, seed, new FlowType[0]).getFlowAddressSet(monitor));
				break;
			case "flowTo":
				out.add(new FollowFlow(p, seed, new FlowType[0]).getFlowToAddressSet(monitor));
				break;
			case "limitedFlowFrom":
				out.add(new FollowFlow(p, seed, limited()).getFlowAddressSet(monitor));
				break;
			case "limitedFlowTo":
				out.add(new FollowFlow(p, seed, limited()).getFlowToAddressSet(monitor));
				break;
			case "subroutine": {
				CodeBlockModel model = new IsolatedEntrySubModel(p);
				CodeBlockIterator it = model.getCodeBlocksContaining(seed, monitor);
				while (it.hasNext()) {
					out.add(it.next());
				}
				break;
			}
			case "deadSubroutines": {
				CodeBlockModel model = new IsolatedEntrySubModel(p);
				CodeBlockIterator it = model.getCodeBlocksContaining(scope, monitor);
				SymbolTable st = p.getSymbolTable();
				while (it.hasNext()) {
					monitor.checkCancelled();
					CodeBlock b = it.next();
					Address entry = b.getFirstStartAddress();
					if (b.getNumSources(monitor) == 0 && !st.isExternalEntryPoint(entry)) {
						out.add(b);
					}
				}
				break;
			}
			case "function": {
				for (AddressRange r : seed) {
					Function f = p.getFunctionManager().getFunctionContaining(r.getMinAddress());
					if (f != null) {
						out.add(f.getBody());
					}
					Iterator<Function> it = p.getFunctionManager().getFunctions(new AddressSet(r), true);
					while (it.hasNext()) {
						out.add(it.next().getBody());
					}
				}
				break;
			}
			case "forwardRefs": {
				ReferenceManager rm = p.getReferenceManager();
				for (Address from : rm.getReferenceSourceIterator(seed, true)) {
					monitor.checkCancelled();
					for (Reference r : rm.getReferencesFrom(from)) {
						if (r.getToAddress().isMemoryAddress() && memory.contains(r.getToAddress())) {
							out.add(unit(listing, r.getToAddress()));
						}
					}
				}
				break;
			}
			case "backRefs": {
				ReferenceManager rm = p.getReferenceManager();
				for (Address to : rm.getReferenceDestinationIterator(seed, true)) {
					monitor.checkCancelled();
					ReferenceIterator it = rm.getReferencesTo(to);
					while (it.hasNext()) {
						Address from = it.next().getFromAddress();
						if (from.isMemoryAddress() && memory.contains(from)) {
							out.add(unit(listing, from));
						}
					}
				}
				break;
			}
			case "instructions":
				for (Instruction in : listing.getInstructions(scope, true)) {
					monitor.checkCancelled();
					out.add(in.getMinAddress(), in.getMaxAddress());
				}
				break;
			case "data":
				for (Data d : listing.getDefinedData(scope, true)) {
					monitor.checkCancelled();
					out.add(d.getMinAddress(), d.getMaxAddress());
				}
				break;
			case "undefined":
				out.add(listing.getUndefinedRanges(scope, true, monitor));
				break;
			default:
				throw new IllegalArgumentException("Selección desconocida: " + kind);
		}
		return result(out);
	}

	private static AddressSet unit(Listing listing, Address a) {
		CodeUnit cu = listing.getCodeUnitContaining(a);
		return cu != null ? new AddressSet(cu.getMinAddress(), cu.getMaxAddress()) : new AddressSet(a);
	}

	private static FlowType[] limited() {
		return new FlowType[] { RefType.COMPUTED_CALL, RefType.CONDITIONAL_CALL, RefType.UNCONDITIONAL_CALL,
			RefType.INDIRECTION };
	}

	/** Runs one edit over every range of the selection, as a single undoable step. */
	static Object selectionAction(Session s, String action, AddressSet set) throws Exception {
		if (set.isEmpty()) {
			throw new IllegalArgumentException("No hay nada seleccionado");
		}
		Program p = s.program;
		switch (action) {
			case "clear":
				return s.edit("Borrar código", () -> {
					for (AddressRange r : codeUnits(p, set)) {
						p.getListing().clearCodeUnits(r.getMinAddress(), r.getMaxAddress(), false);
					}
					return true;
				});
			case "disassemble":
				return s.edit("Desensamblar", () -> {
					DisassembleCommand cmd = new DisassembleCommand(set, set, true);
					if (!cmd.applyTo(p, TaskMonitor.DUMMY)) {
						throw new IllegalStateException(
							cmd.getStatusMsg() != null ? cmd.getStatusMsg() : "No se pudo desensamblar");
					}
					return true;
				});
			case "bookmark":
				return s.edit("Añadir marcador", () -> {
					BookmarkManager bm = p.getBookmarkManager();
					int n = 0;
					for (AddressRange r : set) {
						if (n++ >= 1000) {
							break;
						}
						bm.setBookmark(r.getMinAddress(), BookmarkType.NOTE, "Selección", "");
					}
					return true;
				});
			default:
				throw new IllegalArgumentException("Acción desconocida: " + action);
		}
	}

	// ---------------------------------------------------------------- p-code graphs

	private static String name(Program p, Varnode vn) {
		if (vn == null) {
			return "?";
		}
		Address a = vn.getAddress();
		if (vn.isConstant()) {
			return "#0x" + Long.toHexString(vn.getOffset());
		}
		if (vn.isRegister()) {
			Register r = p.getRegister(a, vn.getSize());
			return r != null ? r.getName() : "reg_" + a.toString(false) + ":" + vn.getSize();
		}
		if (vn.isUnique()) {
			return "u_" + Long.toHexString(vn.getOffset()) + ":" + vn.getSize();
		}
		if (a.isStackAddress()) {
			long off = a.getOffset();
			return "stack[" + (off < 0 ? "-0x" + Long.toHexString(-off) : "0x" + Long.toHexString(off)) + "]:" +
				vn.getSize();
		}
		if (a.isMemoryAddress()) {
			Symbol sym = p.getSymbolTable().getPrimarySymbol(a);
			return sym != null ? sym.getName() : a.toString() + ":" + vn.getSize();
		}
		return a.toString() + ":" + vn.getSize();
	}

	private static boolean hidden(PcodeOp op, int input) {
		int code = op.getOpcode();
		// the space id of LOAD / STORE and the op pointer of INDIRECT are not data
		return ((code == PcodeOp.LOAD || code == PcodeOp.STORE) && input == 0) ||
			(code == PcodeOp.INDIRECT && input == 1);
	}

	private static String text(Program p, PcodeOp op) {
		StringBuilder sb = new StringBuilder();
		if (op.getOutput() != null) {
			sb.append(name(p, op.getOutput())).append(" = ");
		}
		sb.append(op.getMnemonic());
		boolean first = true;
		for (int i = 0; i < op.getNumInputs(); i++) {
			if (hidden(op, i)) {
				continue;
			}
			sb.append(first ? " " : ", ").append(name(p, op.getInput(i)));
			first = false;
		}
		return sb.toString();
	}

	/** Data-flow graph of the decompiled function (Ghidra's "Graph AST Data Flow"). */
	static Map<String, Object> dataFlowGraph(Session s, Address fnAddr) {
		Program p = s.program;
		HighFunction hf = s.highFunction(fnAddr);
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		List<Map<String, Object>> edges = new ArrayList<>();
		Map<Object, String> ids = new IdentityHashMap<>();
		boolean truncated = false;
		Iterator<PcodeOpAST> ops = hf.getPcodeOps();
		while (ops.hasNext()) {
			PcodeOpAST op = ops.next();
			if (nodes.size() >= MAX_GRAPH_NODES) {
				truncated = true;
				break;
			}
			String target = str(op.getSeqnum().getTarget());
			String oid = "o" + nodes.size();
			nodes.put(oid, map("id", oid, "label", op.getMnemonic(), "detail", target, "kind", "op", "address", target));
			for (int i = 0; i < op.getNumInputs(); i++) {
				Varnode in = op.getInput(i);
				if (in == null || hidden(op, i)) {
					continue;
				}
				edges.add(map("from", varnode(p, in, nodes, ids), "to", oid, "kind", "flow"));
			}
			if (op.getOutput() != null) {
				edges.add(map("from", oid, "to", varnode(p, op.getOutput(), nodes, ids), "kind", "flow"));
			}
		}
		return map("nodes", new ArrayList<>(nodes.values()), "edges", edges, "truncated", truncated);
	}

	private static String varnode(Program p, Varnode vn, Map<String, Map<String, Object>> nodes, Map<Object, String> ids) {
		String id = ids.get(vn);
		if (id != null) {
			return id;
		}
		id = "v" + nodes.size();
		ids.put(vn, id);
		String detail = "";
		HighVariable high = vn.getHigh();
		if (high != null && high.getName() != null && !"UNNAMED".equals(high.getName())) {
			detail = high.getName();
			if (high.getDataType() != null) {
				detail += " : " + high.getDataType().getName();
			}
		}
		String kind = vn.isConstant() ? "const" : vn.isInput() ? "input" : vn.isAddrTied() ? "tied" : "var";
		Address pc = vn.getPCAddress();
		nodes.put(id, map("id", id, "label", name(p, vn), "detail", detail, "kind", kind,
			"address", pc != null && pc.isMemoryAddress() ? str(pc) : null));
		return id;
	}

	/** Control-flow graph of the decompiler's p-code blocks (Ghidra's "Graph AST Control Flow"). */
	static Map<String, Object> pcodeFlowGraph(Session s, Address fnAddr) {
		Program p = s.program;
		Function f = s.functionContaining(fnAddr);
		HighFunction hf = s.highFunction(fnAddr);
		List<PcodeBlockBasic> basic = hf.getBasicBlocks();
		List<Map<String, Object>> blocks = new ArrayList<>();
		List<Map<String, Object>> edges = new ArrayList<>();
		Map<PcodeBlock, Integer> index = new IdentityHashMap<>();
		for (PcodeBlockBasic b : basic) {
			index.put(b, index.size());
		}
		for (PcodeBlockBasic b : basic) {
			int i = index.get(b);
			List<String> lines = new ArrayList<>();
			int total = 0;
			Iterator<PcodeOp> it = b.getIterator();
			while (it.hasNext()) {
				PcodeOp op = it.next();
				total++;
				if (lines.size() < 60) {
					lines.add(text(p, op));
				}
			}
			if (total > lines.size()) {
				lines.add(Msg.t("… (" + (total - lines.size()) + " más)"));
			}
			blocks.add(map("id", i, "start", str(b.getStart()), "end", str(b.getStop()), "label", null, "lines", lines,
				"entry", i == 0));
			if (b.getOutSize() == 2) {
				edge(edges, index, i, b.getTrueOut(), "cond");
				edge(edges, index, i, b.getFalseOut(), "false");
			}
			else {
				for (int k = 0; k < b.getOutSize(); k++) {
					edge(edges, index, i, b.getOut(k), b.getOutSize() == 1 ? "fall" : "jump");
				}
			}
		}
		return map("function", f.getName(true), "entry", str(f.getEntryPoint()), "blocks", blocks, "edges", edges,
			"truncated", false);
	}

	private static void edge(List<Map<String, Object>> edges, Map<PcodeBlock, Integer> index, int from, PcodeBlock to,
			String kind) {
		Integer t = to != null ? index.get(to) : null;
		if (t != null) {
			edges.add(map("from", from, "to", t, "kind", kind));
		}
	}
}
