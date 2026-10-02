package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.reloc.Relocation;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.*;
import ghidra.program.util.string.FoundString;
import ghidra.program.util.string.StringSearcher;
import ghidra.util.task.TaskMonitor;

/** Table-style views: symbol table, relocations, string search, scalar search. */
final class Tables {
	private static final int MAX = 5000;

	private Tables() {
	}

	static List<Map<String, Object>> symbols(Session s, String filter, Set<String> kinds, boolean userOnly) {
		String f = filter == null ? "" : filter.toLowerCase();
		List<Map<String, Object>> out = new ArrayList<>();
		ReferenceManager rm = s.program.getReferenceManager();
		SymbolIterator it = s.program.getSymbolTable().getAllSymbols(true);
		while (it.hasNext() && out.size() < MAX) {
			Symbol sym = it.next();
			String kind = sym.getSymbolType().toString();
			if (!kinds.isEmpty() && !kinds.contains(kind)) {
				continue;
			}
			if (userOnly && sym.getSource() != SourceType.USER_DEFINED) {
				continue;
			}
			if (!f.isEmpty() && !sym.getName().toLowerCase().contains(f)) {
				continue;
			}
			out.add(map("name", sym.getName(), "address", sym.isExternal() ? null : str(sym.getAddress()), "kind", kind,
				"namespace", sym.getParentNamespace().getName(true), "source", sym.getSource().toString(),
				"references", sym.isExternal() ? sym.getReferenceCount() : rm.getReferenceCountTo(sym.getAddress()),
				"primary", sym.isPrimary()));
		}
		return out;
	}

	static List<Map<String, Object>> relocations(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		Iterator<Relocation> it = s.program.getRelocationTable().getRelocations();
		while (it.hasNext() && out.size() < MAX) {
			Relocation r = it.next();
			long[] values = r.getValues();
			StringBuilder vs = new StringBuilder();
			if (values != null) {
				for (long v : values) {
					vs.append(vs.length() > 0 ? ", " : "").append("0x").append(Long.toHexString(v));
				}
			}
			out.add(map("address", str(r.getAddress()), "type", "0x" + Integer.toHexString(r.getType()),
				"status", r.getStatus().toString(), "symbol", r.getSymbolName(), "values", vs.toString(),
				"bytes", r.getBytes() != null ? hex(r.getBytes(), 16) : ""));
		}
		return out;
	}

	/** Like Search > For Strings: finds strings in memory, defined or not. */
	static List<Map<String, Object>> findStrings(Session s, int minLength, boolean nullTerminated, boolean undefinedOnly) {
		List<Map<String, Object>> out = new ArrayList<>();
		StringSearcher searcher = new StringSearcher(s.program, Math.max(3, minLength), 1, false, nullTerminated);
		searcher.search(null, (FoundString found) -> {
			if (out.size() >= MAX || (undefinedOnly && found.isDefined())) {
				return;
			}
			String value = found.getString(s.program.getMemory());
			if (value == null) {
				return;
			}
			out.add(map("address", str(found.getAddress()), "length", found.getLength(), "value", value,
				"defined", found.isDefined()));
		}, true, TaskMonitor.DUMMY);
		return out;
	}

	/** Instructions (and data) that use a given constant. */
	static List<Map<String, Object>> searchScalar(Session s, String valueText) {
		long value = Emulation.parseNumber(valueText).longValue();
		List<Map<String, Object>> out = new ArrayList<>();
		CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
		for (Instruction ins : s.program.getListing().getInstructions(true)) {
			if (out.size() >= MAX) {
				break;
			}
			for (int i = 0; i < ins.getNumOperands(); i++) {
				boolean hit = false;
				for (Object o : ins.getOpObjects(i)) {
					if (o instanceof Scalar sc && (sc.getSignedValue() == value || sc.getUnsignedValue() == value)) {
						hit = true;
					}
				}
				if (hit) {
					StringBuilder sb = new StringBuilder(ins.getMnemonicString());
					for (int k = 0; k < ins.getNumOperands(); k++) {
						sb.append(k == 0 ? " " : ", ").append(fmt.getOperandRepresentationString(ins, k));
					}
					Function f = s.program.getFunctionManager().getFunctionContaining(ins.getAddress());
					out.add(map("address", str(ins.getAddress()), "kind", "Instrucción", "text", sb.toString(),
						"function", f != null ? f.getName(true) : null));
					break;
				}
			}
		}
		return out;
	}


	/** The program tree(s): modules and fragments with their address ranges. */
	static List<Map<String, Object>> programTree(Session s) {
		List<Map<String, Object>> trees = new ArrayList<>();
		Listing listing = s.program.getListing();
		for (String name : listing.getTreeNames()) {
			ProgramModule root = listing.getRootModule(name);
			if (root != null) {
				trees.add(group(root, name));
			}
		}
		return trees;
	}

	private static Map<String, Object> group(Group g, String displayName) {
		List<Map<String, Object>> children = new ArrayList<>();
		String start = null;
		String end = null;
		if (g instanceof ProgramModule m) {
			for (Group child : m.getChildren()) {
				children.add(group(child, child.getName()));
			}
			if (m.getMinAddress() != null) {
				start = str(m.getMinAddress());
				end = str(m.getMaxAddress());
			}
		}
		else if (g instanceof ProgramFragment f && !f.isEmpty()) {
			start = str(f.getMinAddress());
			end = str(f.getMaxAddress());
		}
		return map("name", displayName, "module", g instanceof ProgramModule, "start", start, "end", end,
			"children", children);
	}
}
