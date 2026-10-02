package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.app.plugin.assembler.AssemblySelector;
import ghidra.app.plugin.assembler.sleigh.parse.AssemblyParseResult;
import ghidra.app.plugin.assembler.sleigh.sem.*;
import ghidra.app.plugin.processors.sleigh.SleighLanguage;
import ghidra.asm.wild.*;
import ghidra.asm.wild.sem.WildAssemblyResolvedPatterns;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.util.task.TaskMonitor;

/** Editing extras: the structure field under the cursor, and the assembler with wildcards. */
final class EditExtras {
	private EditExtras() {
	}

	// ---------------------------------------------------------------- field under the cursor

	/**
	 * The structure or union field laid out at an address: which type it belongs to and its ordinal, so the
	 * listing can edit its name, type and comment without opening the structure editor.
	 */
	static Map<String, Object> fieldAt(Session s, Address a) {
		Data top = s.program.getListing().getDataContaining(a);
		if (top == null) {
			throw new IllegalArgumentException("No hay ningún dato en " + a);
		}
		Data parent = top;
		Data comp = null;
		for (int depth = 0; depth < 32; depth++) {
			int offset = (int) a.subtract(parent.getMinAddress());
			Data child = parent.getComponentContaining(offset);
			if (child == null) {
				break;
			}
			DataType base = parent.getBaseDataType();
			if (base instanceof Composite) {
				comp = child;
				break;
			}
			parent = child;       // an array: go into the element
		}
		if (comp == null || !(parent.getBaseDataType() instanceof Composite composite)) {
			throw new IllegalArgumentException("No hay ningún campo de una estructura o unión en " + a);
		}
		DataTypeComponent c = composite.getComponent(comp.getComponentIndex());
		return map("type", composite.getPathName(), "typeName", composite.getName(), "ordinal", comp.getComponentIndex(),
			"offset", c.getOffset(), "length", c.getLength(), "name", c.getFieldName() == null ? "" : c.getFieldName(),
			"fieldType", c.getDataType().getDisplayName(), "comment", c.getComment() == null ? "" : c.getComment(),
			"address", String.valueOf(comp.getMinAddress()), "union", composite instanceof Union);
	}

	// ---------------------------------------------------------------- assembler with wildcards

	private static String bitsOf(AssemblyPatternBlock block) {
		byte[] vals = block.getVals();
		byte[] mask = block.getMask();
		StringBuilder sb = new StringBuilder();
		for (int i = 0; i < vals.length; i++) {
			if (i > 0) {
				sb.append(' ');
			}
			int m = mask[i] & 0xff;
			if (m == 0xff) {
				sb.append(String.format("%02x", vals[i] & 0xff));
			}
			else if (m == 0) {
				sb.append("..");
			}
			else {
				// partly fixed: bit by bit
				sb.append('[');
				for (int bit = 7; bit >= 0; bit--) {
					sb.append((m >> bit & 1) == 0 ? '.' : (vals[i] >> bit & 1) == 1 ? '1' : '0');
				}
				sb.append(']');
			}
		}
		return sb.toString();
	}

	private static AssemblyPatternBlock reduced(WildAssemblyResolvedPatterns p) {
		AssemblyPatternBlock block = p.getInstruction();
		for (WildOperandInfo info : p.getOperandInfo()) {
			block = block.maskOut(info.location());
		}
		return block;
	}

	/**
	 * Assembles an instruction that has wildcards (`Q1`, `Q1/regex`, `Q2[..]`): every way of encoding it,
	 * with the bits each wildcard takes, and optionally where those encodings appear in memory.
	 */
	static Map<String, Object> wildAssemble(Session s, Address at, String text, boolean search, AddressSetView within,
			int max, TaskMonitor monitor) throws Exception {
		if (!(s.program.getLanguage() instanceof SleighLanguage language)) {
			throw new IllegalArgumentException("El lenguaje del programa no es de Sleigh");
		}
		WildSleighAssembler assembler =
			new WildSleighAssemblerBuilder(language).getAssembler(new AssemblySelector(), s.program);
		List<WildAssemblyResolvedPatterns> valid = new ArrayList<>();
		List<String> errors = new ArrayList<>();
		for (AssemblyParseResult parse : assembler.parseLine(text)) {
			monitor.checkCancelled();
			if (parse.isError()) {
				errors.add(parse.toString());
				continue;
			}
			for (AssemblyResolution r : assembler.resolveTree(parse, at)) {
				if (r instanceof WildAssemblyResolvedPatterns w) {
					valid.add(w);
				}
			}
		}
		if (valid.isEmpty()) {
			throw new IllegalArgumentException("No se puede ensamblar «" + text + "»"
				+ (errors.isEmpty() ? "" : ": " + errors.get(0).lines().findFirst().orElse("")));
		}
		// one entry per distinct encoding once the wildcard bits are masked out
		Map<AssemblyPatternBlock, Map<String, Set<String>>> encodings = new LinkedHashMap<>();
		for (WildAssemblyResolvedPatterns p : valid) {
			Map<String, Set<String>> choices = encodings.computeIfAbsent(reduced(p), k -> new TreeMap<>());
			for (WildOperandInfo info : p.getOperandInfo()) {
				choices.computeIfAbsent(info.wildcard(), k -> new LinkedHashSet<>())
						.add(info.choice() == null ? "(valor)" : String.valueOf(info.choice()));
			}
		}
		List<Map<String, Object>> rows = new ArrayList<>();
		for (Map.Entry<AssemblyPatternBlock, Map<String, Set<String>>> e : encodings.entrySet()) {
			List<String> wild = new ArrayList<>();
			for (Map.Entry<String, Set<String>> w : e.getValue().entrySet()) {
				List<String> values = new ArrayList<>(w.getValue());
				String shown = String.join(", ", values.subList(0, Math.min(12, values.size())))
					+ (values.size() > 12 ? ", … (" + values.size() + ")" : "");
				wild.add(w.getKey() + " = " + shown);
			}
			rows.add(map("pattern", bitsOf(e.getKey()), "length", e.getKey().length(), "wildcards",
				String.join("  ·  ", wild)));
			if (rows.size() >= 500) {
				break;
			}
		}
		List<Map<String, Object>> hits = new ArrayList<>();
		if (search) {
			Memory memory = s.program.getMemory();
			Listing listing = s.program.getListing();
			FunctionManager fm = s.program.getFunctionManager();
			int limit = Math.max(1, max);
			search: for (AssemblyPatternBlock encoding : encodings.keySet()) {
				for (MemoryBlock block : memory.getBlocks()) {
					if (!block.isInitialized()) {
						continue;
					}
					Address from = block.getStart();
					while (from != null && from.compareTo(block.getEnd()) <= 0) {
						monitor.checkCancelled();
						Address hit = memory.findBytes(from, block.getEnd(), encoding.getVals(), encoding.getMask(), true,
							monitor);
						if (hit == null) {
							break;
						}
						if (within == null || within.isEmpty() || within.contains(hit)) {
							byte[] found = new byte[encoding.length()];
							memory.getBytes(hit, found);
							// the masked encoding also matches operands the wildcards do not allow: keep the hit
							// only when one of the complete encodings is what is in memory
							List<String> values = null;
							for (WildAssemblyResolvedPatterns p : valid) {
								AssemblyPatternBlock ins = p.getInstruction();
								if (ins.length() <= found.length && ins.getMaskedValue(found).equals(ins)) {
									values = new ArrayList<>();
									for (WildOperandInfo info : p.getOperandInfo()) {
										values.add(info.wildcard() + " = " + info.choice());
									}
									break;
								}
							}
							if (values == null) {
								from = hit.equals(block.getEnd()) ? null : hit.next();
								continue;
							}
							CodeUnit cu = listing.getCodeUnitAt(hit);
							Function f = fm.getFunctionContaining(hit);
							hits.add(map("address", String.valueOf(hit), "bytes", hex(found, 16), "code",
								cu instanceof Instruction ? cu.toString() : "", "wildcards", String.join("  ·  ", values),
								"function", f == null ? "" : f.getName()));
							if (hits.size() >= limit) {
								break search;
							}
						}
						from = hit.equals(block.getEnd()) ? null : hit.next();
					}
				}
			}
		}
		return map("encodings", rows, "total", valid.size(), "hits", hits);
	}
}
