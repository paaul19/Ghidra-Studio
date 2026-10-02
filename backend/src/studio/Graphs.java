package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.block.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.symbol.FlowType;
import ghidra.program.model.symbol.Symbol;
import ghidra.util.task.TaskMonitor;

/** Control-flow graph of a function and call relationships. */
final class Graphs {
	private static final int MAX_BLOCKS = 2500;
	private static final int MAX_LINES = 60;

	private Graphs() {
	}

	static Map<String, Object> functionGraph(Session s, Address address) throws Exception {
		Program program = s.program;
		Function f = s.functionContaining(address);
		BasicBlockModel model = new BasicBlockModel(program);
		CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
		Listing listing = program.getListing();

		List<Map<String, Object>> blocks = new ArrayList<>();
		List<Map<String, Object>> edges = new ArrayList<>();
		Map<Address, Integer> index = new HashMap<>();
		List<CodeBlock> ordered = new ArrayList<>();

		CodeBlockIterator it = model.getCodeBlocksContaining(f.getBody(), TaskMonitor.DUMMY);
		while (it.hasNext() && ordered.size() < MAX_BLOCKS) {
			CodeBlock b = it.next();
			index.put(b.getFirstStartAddress(), ordered.size());
			ordered.add(b);
		}

		for (int i = 0; i < ordered.size(); i++) {
			CodeBlock b = ordered.get(i);
			List<String> lines = new ArrayList<>();
			// the address of each line, so that a line of a block can be edited like one of the listing
			List<String> addresses = new ArrayList<>();
			int total = 0;
			InstructionIterator ins = listing.getInstructions(b, true);
			while (ins.hasNext()) {
				Instruction in = ins.next();
				total++;
				if (lines.size() < MAX_LINES) {
					StringBuilder sb = new StringBuilder();
					sb.append(in.getMnemonicString());
					for (int op = 0; op < in.getNumOperands(); op++) {
						sb.append(op == 0 ? " " : ", ").append(fmt.getOperandRepresentationString(in, op));
					}
					String comment = in.getComment(CommentType.EOL);
					if (comment == null) {
						comment = in.getComment(CommentType.PRE);
					}
					if (comment != null && !comment.isBlank()) {
						String one = comment.replace('\n', ' ').strip();
						sb.append("  ; ").append(one.length() > 40 ? one.substring(0, 39) + "…" : one);
					}
					lines.add(sb.toString());
					addresses.add(str(in.getAddress()));
				}
			}
			if (total > lines.size()) {
				lines.add(Msg.t("… (" + (total - lines.size()) + " más)"));
			}
			Symbol label = program.getSymbolTable().getPrimarySymbol(b.getFirstStartAddress());
			blocks.add(map("id", i, "start", str(b.getFirstStartAddress()), "end", str(b.getMaxAddress()),
				"label", label != null ? label.getName() : null, "lines", lines, "addresses", addresses,
				"entry", b.getFirstStartAddress().equals(f.getEntryPoint())));

			CodeBlockReferenceIterator dests = b.getDestinations(TaskMonitor.DUMMY);
			while (dests.hasNext()) {
				CodeBlockReference ref = dests.next();
				FlowType ft = ref.getFlowType();
				if (ft.isCall()) {
					continue;
				}
				Integer to = index.get(ref.getDestinationAddress());
				if (to == null) {
					continue;
				}
				String kind = ft.isFallthrough() ? "fall" : ft.isConditional() ? "cond" : "jump";
				edges.add(map("from", i, "to", to, "kind", kind));
			}
		}
		// A conditional block's fall-through edge is the "false" branch of its conditional jump.
		Set<Integer> conditional = new HashSet<>();
		for (Map<String, Object> e : edges) {
			if ("cond".equals(e.get("kind"))) {
				conditional.add((Integer) e.get("from"));
			}
		}
		for (Map<String, Object> e : edges) {
			if ("fall".equals(e.get("kind")) && conditional.contains(e.get("from"))) {
				e.put("kind", "false");
			}
		}
		return map("function", f.getName(true), "entry", str(f.getEntryPoint()), "blocks", blocks, "edges", edges,
			"truncated", it.hasNext());
	}

	static List<Map<String, Object>> calls(Session s, Address address, boolean callers) {
		Function f = s.functionContaining(address);
		Set<Function> fs = callers ? f.getCallingFunctions(TaskMonitor.DUMMY) : f.getCalledFunctions(TaskMonitor.DUMMY);
		List<Map<String, Object>> list = Session.fnRefs(fs);
		for (Map<String, Object> m : list) {
			Function g = s.program.getFunctionManager().getFunctionAt(s.addr((String) m.get("address")));
			boolean more = g != null && !g.isExternal() && !(callers ? g.getCallingFunctions(TaskMonitor.DUMMY)
					: g.getCalledFunctions(TaskMonitor.DUMMY)).isEmpty();
			m.put("hasChildren", more);
		}
		return list;
	}

	// ---------------------------------------------------------------- node graphs (calls, references)

	private static final int MAX_NODES = 400;

	private static Map<String, Object> fnNode(Function f, int level) {
		return map("id", f.isExternal() ? "ext:" + f.getName(true) : str(f.getEntryPoint()), "label", f.getName(true),
			"detail", f.isExternal() ? f.getParentNamespace().getName() : str(f.getEntryPoint()),
			"kind", f.isExternal() ? "external" : f.isThunk() ? "thunk" : "function", "level", level,
			"address", f.isExternal() ? null : str(f.getEntryPoint()));
	}

	/** Callers (negative levels) and callees (positive levels) around one function. */
	static Map<String, Object> callGraph(Session s, Address address, int up, int down) {
		Function center = s.functionContaining(address);
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		Set<List<String>> edges = new LinkedHashSet<>();
		Map<String, Object> c = fnNode(center, 0);
		nodes.put((String) c.get("id"), c);
		expand(center, true, up, nodes, edges);
		expand(center, false, down, nodes, edges);
		return graphResult(nodes, edges, "call", nodes.size() >= MAX_NODES);
	}

	private static void expand(Function center, boolean callers, int depth, Map<String, Map<String, Object>> nodes,
			Set<List<String>> edges) {
		List<Function> frontier = List.of(center);
		for (int level = 1; level <= depth && !frontier.isEmpty(); level++) {
			List<Function> next = new ArrayList<>();
			for (Function f : frontier) {
				String fid = (String) fnNode(f, 0).get("id");
				Set<Function> rel = callers ? f.getCallingFunctions(TaskMonitor.DUMMY) : f.getCalledFunctions(TaskMonitor.DUMMY);
				for (Function g : rel) {
					Map<String, Object> n = fnNode(g, callers ? -level : level);
					String gid = (String) n.get("id");
					if (!nodes.containsKey(gid)) {
						if (nodes.size() >= MAX_NODES) {
							return;
						}
						nodes.put(gid, n);
						if (!g.isExternal()) {
							next.add(g);
						}
					}
					edges.add(callers ? List.of(gid, fid) : List.of(fid, gid));
				}
			}
			frontier = next;
		}
	}

	/** Call graph of the whole program (like Graph > Calls). */
	static Map<String, Object> programCallGraph(Session s, boolean includeExternal, int limit) {
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		Set<List<String>> edges = new LinkedHashSet<>();
		int max = Math.max(10, Math.min(limit, 3000));
		boolean truncated = false;
		for (Function f : s.program.getFunctionManager().getFunctions(true)) {
			Set<Function> callees = f.getCalledFunctions(TaskMonitor.DUMMY);
			Map<String, Object> fn = fnNode(f, 0);
			String fid = (String) fn.get("id");
			for (Function g : callees) {
				if (g.isExternal() && !includeExternal) {
					continue;
				}
				Map<String, Object> gn = fnNode(g, 0);
				String gid = (String) gn.get("id");
				if (nodes.size() >= max && (!nodes.containsKey(fid) || !nodes.containsKey(gid))) {
					truncated = true;
					continue;
				}
				nodes.putIfAbsent(fid, fn);
				nodes.putIfAbsent(gid, gn);
				edges.add(List.of(fid, gid));
			}
		}
		for (Map<String, Object> n : nodes.values()) {
			n.remove("level");
		}
		return graphResult(nodes, edges, "call", truncated);
	}

	private static Map<String, Object> refNode(Program p, Address a, int level) {
		Function f = p.getFunctionManager().getFunctionContaining(a);
		if (f != null && p.getListing().getDefinedDataContaining(a) == null) {
			return fnNode(f, level);
		}
		Symbol sym = p.getSymbolTable().getPrimarySymbol(a);
		Data d = p.getListing().getDefinedDataContaining(a);
		String label = sym != null ? sym.getName(true) : str(a);
		String detail = d != null ? d.getDataType().getName() : str(a);
		if (d != null && d.hasStringValue()) {
			String v = String.valueOf(d.getValue());
			detail = "\"" + (v.length() > 40 ? v.substring(0, 40) + "…" : v) + "\"";
		}
		return map("id", str(a), "label", label, "detail", detail, "kind", "data", "level", level, "address", str(a));
	}

	/** References graph around an address (like the Data Graph): who points to it and what it points to. */
	static Map<String, Object> referenceGraph(Session s, Address address, int depth) {
		return referenceGraph(s, address, depth, "both");
	}

	/** direction: "to" (what refers to the address), "from" (what it refers to) or "both". */
	static Map<String, Object> referenceGraph(Session s, Address address, int depth, String direction) {
		int depthIn = direction.equals("from") ? 0 : depth;
		int depthOut = direction.equals("to") ? 0 : depth;
		Program p = s.program;
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		Set<List<String>> edges = new LinkedHashSet<>();
		Map<String, Object> c = refNode(p, address, 0);
		nodes.put((String) c.get("id"), c);
		ReferenceManager rm = p.getReferenceManager();
		// incoming
		List<Address> frontier = List.of(address);
		for (int level = 1; level <= depthIn && !frontier.isEmpty(); level++) {
			List<Address> next = new ArrayList<>();
			for (Address a : frontier) {
				String aid = (String) refNode(p, a, 0).get("id");
				for (Reference r : rm.getReferencesTo(a)) {
					if (nodes.size() >= MAX_NODES) {
						break;
					}
					Map<String, Object> n = refNode(p, r.getFromAddress(), -level);
					String nid = (String) n.get("id");
					if (nid.equals(aid)) {
						continue;
					}
					if (nodes.putIfAbsent(nid, n) == null && "data".equals(n.get("kind"))) {
						next.add(r.getFromAddress());
					}
					edges.add(List.of(nid, aid));
				}
			}
			frontier = next;
		}
		// outgoing (from the code unit / data at the address, and its components)
		frontier = List.of(address);
		for (int level = 1; level <= depthOut && !frontier.isEmpty(); level++) {
			List<Address> next = new ArrayList<>();
			for (Address a : frontier) {
				String aid = (String) refNode(p, a, 0).get("id");
				CodeUnit cu = p.getListing().getCodeUnitContaining(a);
				AddressSet span = cu != null ? new AddressSet(cu.getMinAddress(), cu.getMaxAddress()) : new AddressSet(a);
				for (Address from : rm.getReferenceSourceIterator(span, true)) {
					for (Reference r : rm.getReferencesFrom(from)) {
						if (!r.getToAddress().isMemoryAddress() || nodes.size() >= MAX_NODES) {
							continue;
						}
						Map<String, Object> n = refNode(p, r.getToAddress(), level);
						String nid = (String) n.get("id");
						if (nid.equals(aid)) {
							continue;
						}
						if (nodes.putIfAbsent(nid, n) == null && "data".equals(n.get("kind"))) {
							next.add(r.getToAddress());
						}
						edges.add(List.of(aid, nid));
					}
				}
			}
			frontier = next;
		}
		return graphResult(nodes, edges, "ref", nodes.size() >= MAX_NODES);
	}

	private static Map<String, Object> graphResult(Map<String, Map<String, Object>> nodes, Set<List<String>> edges,
			String kind, boolean truncated) {
		List<Map<String, Object>> e = new ArrayList<>();
		for (List<String> pair : edges) {
			if (nodes.containsKey(pair.get(0)) && nodes.containsKey(pair.get(1))) {
				e.add(map("from", pair.get(0), "to", pair.get(1), "kind", kind));
			}
		}
		return map("nodes", new ArrayList<>(nodes.values()), "edges", e, "truncated", truncated);
	}
}
