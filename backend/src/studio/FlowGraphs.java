package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.program.model.address.*;
import ghidra.program.model.block.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.util.task.TaskMonitor;

/** Ghidra's program graphs (block flow, code flow) and the data graph. */
final class FlowGraphs {
	private FlowGraphs() {
	}

	private static String label(Program p, Address a) {
		Symbol sym = p.getSymbolTable().getPrimarySymbol(a);
		return sym != null ? sym.getName() : str(a);
	}

	private static Map<String, Object> result(Map<String, Map<String, Object>> nodes, Set<List<String>> edges,
			boolean truncated) {
		List<Map<String, Object>> list = new ArrayList<>();
		for (List<String> e : edges) {
			if (nodes.containsKey(e.get(0)) && nodes.containsKey(e.get(1))) {
				list.add(map("from", e.get(0), "to", e.get(1), "kind", e.get(2)));
			}
		}
		return map("nodes", new ArrayList<>(nodes.values()), "edges", list, "truncated", truncated);
	}

	private static String flowKind(FlowType f) {
		return f.isCall() ? "call" : f.isFallthrough() ? "fall" : f.isConditional() ? "conditional"
				: f.isJump() ? "jump" : f.isTerminal() ? "return" : "flow";
	}

	/** Basic blocks of an address set (the whole program when it is empty) and the flow between them. */
	static Map<String, Object> blockFlow(Session s, AddressSet set, int limit, TaskMonitor monitor) throws Exception {
		Program p = s.program;
		BasicBlockModel model = new BasicBlockModel(p);
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		Set<List<String>> edges = new LinkedHashSet<>();
		AddressSetView scope = set.isEmpty() ? p.getMemory().getExecuteSet() : set;
		CodeBlockIterator it = model.getCodeBlocksContaining(scope, monitor);
		boolean truncated = false;
		List<CodeBlock> blocks = new ArrayList<>();
		while (it.hasNext()) {
			if (blocks.size() >= limit) {
				truncated = true;
				break;
			}
			CodeBlock b = it.next();
			blocks.add(b);
			Address start = b.getFirstStartAddress();
			Function f = p.getFunctionManager().getFunctionContaining(start);
			boolean entry = f != null && f.getEntryPoint().equals(start);
			nodes.put(str(start), map("id", str(start), "label", label(p, start),
				"detail", str(start) + " – " + str(b.getMaxAddress()) + (f != null ? " · " + f.getName() : ""),
				"kind", entry ? "func" : "block", "address", str(start), "end", str(b.getMaxAddress())));
		}
		for (CodeBlock b : blocks) {
			monitor.checkCancelled();
			CodeBlockReferenceIterator dest = b.getDestinations(monitor);
			while (dest.hasNext()) {
				CodeBlockReference r = dest.next();
				// calls leave the block and come back: they are not flow between blocks of the graph
				if (r.getFlowType().isCall()) {
					continue;
				}
				edges.add(List.of(str(b.getFirstStartAddress()), str(r.getDestinationAddress()), flowKind(r.getFlowType())));
			}
		}
		return result(nodes, edges, truncated);
	}

	/** One vertex per instruction of the set, with fall-through and jump edges. */
	static Map<String, Object> codeFlow(Session s, AddressSet set, int limit, TaskMonitor monitor) throws Exception {
		Program p = s.program;
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		Set<List<String>> edges = new LinkedHashSet<>();
		AddressSetView scope = set.isEmpty() ? p.getMemory().getExecuteSet() : set;
		boolean truncated = false;
		List<Instruction> all = new ArrayList<>();
		for (Instruction ins : p.getListing().getInstructions(scope, true)) {
			if (all.size() >= limit) {
				truncated = true;
				break;
			}
			all.add(ins);
			Symbol sym = p.getSymbolTable().getPrimarySymbol(ins.getAddress());
			nodes.put(str(ins.getAddress()), map("id", str(ins.getAddress()), "label", ins.toString(),
				"detail", str(ins.getAddress()) + (sym != null ? " · " + sym.getName() : ""),
				"kind", sym != null && sym.getSymbolType() == SymbolType.FUNCTION ? "func" : "op",
				"address", str(ins.getAddress()), "end", str(ins.getMaxAddress())));
		}
		for (Instruction ins : all) {
			monitor.checkCancelled();
			Address fall = ins.getFallThrough();
			if (fall != null) {
				edges.add(List.of(str(ins.getAddress()), str(fall), "fall"));
			}
			if (!ins.getFlowType().isCall()) {
				for (Address flow : ins.getFlows()) {
					edges.add(List.of(str(ins.getAddress()), str(flow), flowKind(ins.getFlowType())));
				}
			}
		}
		return result(nodes, edges, truncated);
	}

	/**
	 * The data at an address with what its fields point to and what points to it, a few hops out
	 * (Ghidra's Data Graph).
	 */
	static Map<String, Object> dataGraph(Session s, Address address, int depth, int limit) {
		Program p = s.program;
		Map<String, Map<String, Object>> nodes = new LinkedHashMap<>();
		Set<List<String>> edges = new LinkedHashSet<>();
		Deque<Object[]> queue = new ArrayDeque<>();
		Address root = unit(p, address);
		queue.add(new Object[] { root, 0 });
		nodes.put(str(root), dataNode(p, root, 0));
		boolean truncated = false;
		ReferenceManager rm = p.getReferenceManager();
		while (!queue.isEmpty()) {
			Object[] item = queue.poll();
			Address a = (Address) item[0];
			int level = (Integer) item[1];
			if (level >= depth) {
				continue;
			}
			CodeUnit cu = p.getListing().getCodeUnitContaining(a);
			AddressSet span = cu != null ? new AddressSet(cu.getMinAddress(), cu.getMaxAddress()) : new AddressSet(a);
			// what its fields point to
			for (Address from : rm.getReferenceSourceIterator(span, true)) {
				for (Reference r : rm.getReferencesFrom(from)) {
					if (!r.getToAddress().isMemoryAddress()) {
						continue;
					}
					Address to = unit(p, r.getToAddress());
					if (to.equals(a)) {
						continue;
					}
					if (!nodes.containsKey(str(to))) {
						if (nodes.size() >= limit) {
							truncated = true;
							continue;
						}
						nodes.put(str(to), dataNode(p, to, level + 1));
						queue.add(new Object[] { to, level + 1 });
					}
					edges.add(List.of(str(a), str(to), fieldName(cu, from)));
				}
			}
			// what points to it
			AddressIterator targets = rm.getReferenceDestinationIterator(span, true);
			while (targets.hasNext()) {
				Address target = targets.next();
				for (Reference r : rm.getReferencesTo(target)) {
					if (!r.getFromAddress().isMemoryAddress()) {
						continue;
					}
					Address from = unit(p, r.getFromAddress());
					if (from.equals(a)) {
						continue;
					}
					if (!nodes.containsKey(str(from))) {
						if (nodes.size() >= limit) {
							truncated = true;
							continue;
						}
						nodes.put(str(from), dataNode(p, from, -(level + 1)));
						if (p.getListing().getDefinedDataContaining(from) != null) {
							queue.add(new Object[] { from, level + 1 });
						}
					}
					CodeUnit other = p.getListing().getCodeUnitContaining(r.getFromAddress());
					edges.add(List.of(str(from), str(a), fieldName(other, r.getFromAddress())));
				}
			}
		}
		return result(nodes, edges, truncated);
	}

	/** The start of the data or function an address belongs to. */
	private static Address unit(Program p, Address a) {
		Data d = p.getListing().getDefinedDataContaining(a);
		if (d != null) {
			return d.getAddress();
		}
		Function f = p.getFunctionManager().getFunctionContaining(a);
		if (f != null) {
			return f.getEntryPoint();
		}
		CodeUnit cu = p.getListing().getCodeUnitContaining(a);
		return cu != null ? cu.getMinAddress() : a;
	}

	private static String fieldName(CodeUnit cu, Address at) {
		if (cu instanceof Data d && d.getNumComponents() > 0) {
			Data c = d.getComponentContaining((int) at.subtract(d.getAddress()));
			if (c != null && c.getFieldName() != null) {
				return c.getFieldName();
			}
		}
		return "";
	}

	private static Map<String, Object> dataNode(Program p, Address a, int level) {
		Data d = p.getListing().getDefinedDataAt(a);
		Function f = p.getFunctionManager().getFunctionAt(a);
		String label = label(p, a);
		String detail;
		String kind;
		Address end = a;
		if (d != null) {
			kind = "data";
			end = d.getMaxAddress();
			label += " : " + d.getDataType().getDisplayName();
			if (d.getNumComponents() > 0) {
				StringBuilder sb = new StringBuilder();
				for (int i = 0; i < Math.min(d.getNumComponents(), 4); i++) {
					Data c = d.getComponent(i);
					sb.append(c.getFieldName()).append("=").append(c.getDefaultValueRepresentation()).append("  ");
				}
				detail = sb.toString().trim() + (d.getNumComponents() > 4 ? " …" : "");
			}
			else {
				detail = d.getDefaultValueRepresentation();
			}
		}
		else if (f != null) {
			kind = "func";
			end = f.getBody().getMaxAddress();
			detail = f.getPrototypeString(false, false);
		}
		else {
			kind = "op";
			CodeUnit cu = p.getListing().getCodeUnitAt(a);
			detail = cu != null ? cu.toString() : "";
		}
		if (detail != null && detail.length() > 80) {
			detail = detail.substring(0, 80) + "…";
		}
		return map("id", str(a), "label", label, "detail", str(a) + (detail == null || detail.isEmpty() ? "" : " · " + detail),
			"kind", kind, "address", str(a), "end", str(end), "level", level);
	}
}
