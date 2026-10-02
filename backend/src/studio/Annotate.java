package studio;

import static studio.Json.*;

import java.text.SimpleDateFormat;
import java.util.*;

import ghidra.app.plugin.core.equate.CreateEnumEquateCommand;
import ghidra.app.cmd.function.*;
import ghidra.app.cmd.label.SetLabelPrimaryCmd;
import ghidra.app.plugin.core.clear.*;
import ghidra.docking.settings.*;
import ghidra.program.database.IntRangeMap;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.lang.RegisterValue;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.Varnode;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.*;
import ghidra.program.util.AddressEvaluator;
import ghidra.util.task.TaskMonitor;

/**
 * Program annotation beyond the basics: navigation by kind, clear with options, data settings, equates,
 * label and comment history, the reference editor, function extras, instruction overrides, register values,
 * memory block flags, listing colors, program options and properties.
 */
final class Annotate {
	private Annotate() {
	}

	private static String date(Date d) {
		return d == null ? "" : new SimpleDateFormat("yyyy-MM-dd HH:mm").format(d);
	}

	// ---------------------------------------------------------------- navigation

	/** Next / previous code unit of a kind, skipping the run the cursor is in (like the CodeBrowser's arrows). */
	static Map<String, Object> next(Session s, Address from, String kind, boolean forward) throws Exception {
		Program p = s.program;
		Listing listing = p.getListing();
		Memory mem = p.getMemory();
		Address found = null;
		switch (kind) {
			case "function": {
				FunctionIterator it = p.getFunctionManager().getFunctions(from, forward);
				while (it.hasNext()) {
					Function f = it.next();
					if (!f.getEntryPoint().equals(from) && !f.getBody().contains(from) || !forward) {
						if (!f.getEntryPoint().equals(from)) {
							found = f.getEntryPoint();
							break;
						}
					}
				}
				break;
			}
			case "label": {
				SymbolIterator it = p.getSymbolTable().getSymbolIterator(from, forward);
				while (it.hasNext()) {
					Symbol sym = it.next();
					if (!sym.getAddress().equals(from) && sym.getAddress().isMemoryAddress() && !sym.isDynamic()) {
						found = sym.getAddress();
						break;
					}
				}
				break;
			}
			case "bookmark": {
				Iterator<Bookmark> it = p.getBookmarkManager().getBookmarksIterator(from, forward);
				while (it.hasNext()) {
					Bookmark b = it.next();
					if (!b.getAddress().equals(from) && !Debug.isBreakpoint(b)) {
						found = b.getAddress();
						break;
					}
				}
				break;
			}
			case "byte": {
				// the next address whose byte differs from the one under the cursor
				byte here = mem.contains(from) ? mem.getByte(from) : 0;
				Address a = from;
				for (int i = 0; i < 4_000_000; i++) {
					a = forward ? a.next() : a.previous();
					if (a == null || !mem.contains(a)) {
						AddressSetView rest = forward ? mem.intersectRange(from.next(), mem.getMaxAddress())
								: mem.intersectRange(mem.getMinAddress(), from.previous());
						a = null;
						for (AddressRange r : rest) {
							a = forward ? r.getMinAddress() : r.getMaxAddress();
							if (!forward) {
								continue;
							}
							break;
						}
						break;
					}
					MemoryBlock b = mem.getBlock(a);
					if (b != null && b.isInitialized() && mem.getByte(a) != here) {
						break;
					}
				}
				found = a;
				break;
			}
			default: {
				java.util.function.Predicate<CodeUnit> is = cu -> switch (kind) {
					case "instruction" -> cu instanceof Instruction;
					case "data" -> cu instanceof Data d && d.isDefined();
					case "undefined" -> cu instanceof Data d && !d.isDefined();
					case "nonFunction" -> cu instanceof Instruction
						&& p.getFunctionManager().getFunctionContaining(cu.getMinAddress()) == null;
					default -> throw new IllegalArgumentException("Tipo desconocido: " + kind);
				};
				CodeUnitIterator it = listing.getCodeUnits(from, forward);
				boolean leftRun = false;
				int steps = 0;
				while (it.hasNext() && steps++ < 2_000_000) {
					CodeUnit cu = it.next();
					if (cu.getMinAddress().equals(from) || cu.contains(from)) {
						continue;
					}
					if (!is.test(cu)) {
						leftRun = true;
					}
					else if (leftRun || !is.test(listing.getCodeUnitContaining(from))) {
						found = cu.getMinAddress();
						break;
					}
				}
			}
		}
		if (found == null) {
			throw new IllegalStateException("No hay más en esa dirección");
		}
		Function f = p.getFunctionManager().getFunctionContaining(found);
		return map("address", str(found), "function", f != null ? str(f.getEntryPoint()) : null);
	}

	/** "Go to" for things a plain name or address does not cover: file offsets, expressions, wildcards. */
	static List<Map<String, Object>> goTo(Session s, Address base, String query) {
		Program p = s.program;
		String q = query.trim();
		List<Address> found = new ArrayList<>();
		List<String> names = new ArrayList<>();
		String lower = q.toLowerCase();
		if (lower.startsWith("file(") && q.endsWith(")") || lower.startsWith("file:")) {
			String text = lower.startsWith("file(") ? q.substring(5, q.length() - 1) : q.substring(5);
			long offset = Emulation.parseNumber(text.trim()).longValue();
			for (Address a : p.getMemory().locateAddressesForFileOffset(offset)) {
				found.add(a);
				names.add("file(0x" + Long.toHexString(offset) + ")");
			}
		}
		else if (q.contains("*") || q.contains("?")) {
			SymbolIterator it = p.getSymbolTable().getSymbolIterator(q, false);
			while (it.hasNext() && found.size() < 500) {
				Symbol sym = it.next();
				if (sym.getAddress().isMemoryAddress() || sym.getAddress().isExternalAddress()) {
					found.add(sym.getAddress());
					names.add(sym.getName(true));
				}
			}
		}
		else {
			Address a = base != null ? AddressEvaluator.evaluate(p, base, q) : AddressEvaluator.evaluate(p, q);
			if (a != null) {
				found.add(a);
				names.add(q);
			}
		}
		List<Map<String, Object>> out = new ArrayList<>();
		for (int i = 0; i < found.size(); i++) {
			Function f = p.getFunctionManager().getFunctionContaining(found.get(i));
			out.add(map("address", str(found.get(i)), "name", names.get(i), "function", f != null ? f.getName() : null));
		}
		return out;
	}

	// ---------------------------------------------------------------- clear

	static Object clearWith(Session s, AddressSet set, List<String> what) throws Exception {
		ClearOptions options = new ClearOptions(false);
		for (String name : what) {
			options.setShouldClear(ClearOptions.ClearType.valueOf(name), true);
		}
		return s.edit("Borrar con opciones", () -> {
			ClearCmd cmd = new ClearCmd(set, options);
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	static List<String> clearTypes() {
		List<String> out = new ArrayList<>();
		for (ClearOptions.ClearType t : ClearOptions.ClearType.values()) {
			out.add(t.name());
		}
		return out;
	}

	static Object clearFlow(Session s, AddressSet set, boolean data, boolean symbols, boolean repair) throws Exception {
		return s.edit("Borrar flujo y reparar", () -> {
			ClearFlowAndRepairCmd cmd = new ClearFlowAndRepairCmd(set, data, symbols, repair);
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- data settings

	private static Data dataAt(Session s, Address a) {
		Data d = s.program.getListing().getDataContaining(a);
		if (d == null || !d.isDefined()) {
			throw new IllegalArgumentException("No hay un dato definido en " + a);
		}
		Data inner = d.getPrimitiveAt((int) a.subtract(d.getMinAddress()));
		return inner != null ? inner : d;
	}

	/** The settings of the data at an address (format, signedness, charset, mutability…) with their choices. */
	static Map<String, Object> dataSettings(Session s, Address a) {
		Data d = dataAt(s, a);
		List<Map<String, Object>> list = new ArrayList<>();
		DataType dt = d.getDataType();
		for (SettingsDefinition def : dt.getSettingsDefinitions()) {
			Map<String, Object> m = map("name", def.getName(), "description", def.getDescription());
			if (def instanceof EnumSettingsDefinition e) {
				m.put("type", "choice");
				m.put("choices", Arrays.asList(e.getDisplayChoices(d)));
				m.put("value", e.getDisplayChoice(e.getChoice(d), d));
			}
			else if (def instanceof BooleanSettingsDefinition b) {
				m.put("type", "boolean");
				m.put("value", String.valueOf(b.getValue(d)));
			}
			else if (def instanceof NumberSettingsDefinition n) {
				m.put("type", "number");
				m.put("value", String.valueOf(n.getValue(d)));
			}
			else if (def instanceof StringSettingsDefinition str) {
				m.put("type", "text");
				m.put("value", str.getValue(d));
				String[] suggested = str.getSuggestedValues(d);
				if (suggested != null && suggested.length > 0) {
					m.put("choices", Arrays.asList(suggested));
				}
			}
			else {
				continue;
			}
			list.add(m);
		}
		return map("address", str(d.getMinAddress()), "type", dt.getDisplayName(), "value", d.getDefaultValueRepresentation(),
			"settings", list);
	}

	/** Changes one setting, on this data only or (asDefault) on every use of its type. */
	static Object setDataSetting(Session s, Address a, String name, String value, boolean asDefault) throws Exception {
		Data d = dataAt(s, a);
		return s.edit("Ajustes del dato", () -> {
			DataType dt = d.getDataType();
			Settings target = asDefault ? dt.getDefaultSettings() : d;
			for (SettingsDefinition def : dt.getSettingsDefinitions()) {
				if (!def.getName().equals(name)) {
					continue;
				}
				if (def instanceof EnumSettingsDefinition e) {
					String[] choices = e.getDisplayChoices(target);
					for (int i = 0; i < choices.length; i++) {
						if (choices[i].equals(value)) {
							e.setChoice(target, i);
						}
					}
				}
				else if (def instanceof BooleanSettingsDefinition b) {
					b.setValue(target, Boolean.parseBoolean(value));
				}
				else if (def instanceof NumberSettingsDefinition n) {
					n.setValue(target, Emulation.parseNumber(value).longValue());
				}
				else if (def instanceof StringSettingsDefinition str) {
					str.setValue(target, value);
				}
				return true;
			}
			throw new IllegalArgumentException("Ajuste desconocido: " + name);
		});
	}

	/** Cycles the data at an address through a group: byte→word→dword→qword, float→double, char→string→unicode. */
	static Object cycleData(Session s, Address a, String group) throws Exception {
		CycleGroup cycle = switch (group) {
			case "byte" -> CycleGroup.BYTE_CYCLE_GROUP;
			case "float" -> CycleGroup.FLOAT_CYCLE_GROUP;
			case "string" -> CycleGroup.STRING_CYCLE_GROUP;
			default -> throw new IllegalArgumentException("Grupo desconocido: " + group);
		};
		return s.edit("Definir dato", () -> {
			Listing listing = s.program.getListing();
			Data current = listing.getDataAt(a);
			DataType next = cycle.getNextDataType(current != null && current.isDefined() ? current.getDataType() : null, true);
			if (next == null) {
				next = cycle.getDataTypes()[0];
			}
			int length = Math.max(1, next.getLength());
			listing.clearCodeUnits(a, a.add(length - 1), false);
			Data d = listing.createData(a, next);
			return map("type", d.getDataType().getDisplayName(), "length", d.getLength());
		});
	}

	/** Writes a typed value over the data at an address ("Patch Data"): 0x10, -3, 1.5, "text". */
	static Object patchData(Session s, Address a, String text) throws Exception {
		Data d = dataAt(s, a);
		return s.edit("Parchear dato", () -> {
			DataType dt = d.getDataType();
			byte[] bytes = null;
			try {
				bytes = dt.encodeRepresentation(text, d, d, d.getLength());
			}
			catch (Exception e) {
				// not in the format the data is shown in: accept any way of writing a number
			}
			if (bytes == null && dt instanceof AbstractIntegerDataType) {
				java.math.BigInteger v = Emulation.parseNumber(text);
				bytes = new byte[d.getLength()];
				boolean big = s.program.getMemory().isBigEndian();
				for (int i = 0; i < bytes.length; i++) {
					bytes[big ? bytes.length - 1 - i : i] = v.shiftRight(8 * i).byteValue();
				}
			}
			if (bytes == null) {
				throw new IllegalArgumentException("Ese tipo de dato no se puede escribir así");
			}
			s.program.getMemory().setBytes(d.getMinAddress(), bytes);
			return bytes.length;
		});
	}

	// ---------------------------------------------------------------- equates

	static List<Map<String, Object>> equateTable(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		Iterator<Equate> it = s.program.getEquateTable().getEquates();
		while (it.hasNext() && out.size() < 20000) {
			Equate e = it.next();
			EquateReference[] refs = e.getReferences();
			out.add(map("name", e.getDisplayName(), "value", "0x" + Long.toHexString(e.getValue()), "decimal", e.getValue(),
				"references", refs.length, "address", refs.length > 0 ? str(refs[0].getAddress()) : null,
				"enumBased", e.isEnumBased()));
		}
		return out;
	}

	static Object renameEquate(Session s, String name, String newName) throws Exception {
		return s.edit("Renombrar equate", () -> {
			Equate e = s.program.getEquateTable().getEquate(name);
			if (e == null) {
				throw new IllegalArgumentException("No existe el equate " + name);
			}
			e.renameEquate(newName);
			return true;
		});
	}

	/** Removes an equate everywhere, or only its use at one address. */
	static Object removeEquate(Session s, String name, Address at) throws Exception {
		return s.edit("Quitar equate", () -> {
			EquateTable table = s.program.getEquateTable();
			if (at == null) {
				return table.removeEquate(name);
			}
			Equate e = table.getEquate(name);
			if (e == null) {
				throw new IllegalArgumentException("No existe el equate " + name);
			}
			for (EquateReference r : e.getReferences(at)) {
				e.removeReference(at, r.getOpIndex());
			}
			if (e.getReferenceCount() == 0) {
				table.removeEquate(name);
			}
			return true;
		});
	}

	/** Names every scalar of a range that matches a value of the enum. */
	static Object applyEnum(Session s, AddressSet set, String enumPath, boolean subOperands) throws Exception {
		DataType dt = Types.find(s.program, enumPath);
		if (!(dt instanceof ghidra.program.model.data.Enum e)) {
			throw new IllegalArgumentException(enumPath + " no es un enum");
		}
		return s.edit("Aplicar enum", () -> {
			CreateEnumEquateCommand cmd = new CreateEnumEquateCommand(set, e, subOperands);
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	/** The scalars of the instruction at an address, to convert or name them. */
	static List<Map<String, Object>> scalars(Session s, Address a) {
		List<Map<String, Object>> out = new ArrayList<>();
		CodeUnit cu = s.program.getListing().getCodeUnitAt(a);
		if (cu instanceof Instruction ins) {
			for (int op = 0; op < ins.getNumOperands(); op++) {
				for (Object o : ins.getOpObjects(op)) {
					if (o instanceof Scalar sc) {
						List<String> names = new ArrayList<>();
						for (Equate e : s.program.getEquateTable().getEquates(a, op)) {
							names.add(e.getDisplayName());
						}
						out.add(map("operand", op, "value", sc.getValue(), "unsigned", sc.getUnsignedValue(),
							"bits", sc.bitLength(), "equates", names));
					}
				}
			}
		}
		return out;
	}

	/** Shows a scalar in another form: Ghidra does it with an equate whose name is the converted value. */
	static Object convert(Session s, Address a, int operand, long value, int bits, String format) throws Exception {
		String name = convertedName(value, bits, format);
		return s.edit("Convertir", () -> {
			EquateTable table = s.program.getEquateTable();
			for (Equate old : table.getEquates(a, operand)) {
				old.removeReference(a, operand);
				if (old.getReferenceCount() == 0) {
					table.removeEquate(old.getName());
				}
			}
			Equate e = table.getEquate(name);
			if (e == null) {
				e = table.createEquate(name, value);
			}
			e.addReference(a, operand);
			return name;
		});
	}

	/** The equate name Ghidra uses to show a value in another form. */
	static String convertedName(long value, int bits, String format) {
		long mask = bits >= 64 ? -1L : (1L << bits) - 1;
		long unsigned = value & mask;
		long signed = bits >= 64 || (unsigned & (1L << (bits - 1))) == 0 ? unsigned : unsigned - (1L << bits);
		String name = switch (format) {
			case "signedDecimal" -> Long.toString(signed);
			case "unsignedDecimal" -> Long.toUnsignedString(unsigned);
			case "octal" -> Long.toOctalString(unsigned) + "o";
			case "signedHex" -> (signed < 0 ? "-0x" + Long.toHexString(-signed) : "0x" + Long.toHexString(signed));
			case "unsignedHex" -> "0x" + Long.toHexString(unsigned);
			case "binary" -> Long.toBinaryString(unsigned) + "b";
			case "char" -> charSequence(unsigned, bits);
			case "float" -> Float.toString(Float.intBitsToFloat((int) unsigned));
			case "double" -> Double.toString(Double.longBitsToDouble(unsigned));
			default -> throw new IllegalArgumentException("Formato desconocido: " + format);
		};
		return name;
	}

	private static String charSequence(long value, int bits) {
		StringBuilder sb = new StringBuilder("'");
		for (int shift = Math.max(0, bits - 8); shift >= 0; shift -= 8) {
			int c = (int) ((value >> shift) & 0xff);
			if (c == 0 && sb.length() == 1 && shift > 0) {
				continue;
			}
			sb.append(c >= 0x20 && c < 0x7f ? String.valueOf((char) c) : String.format("\\x%02x", c));
		}
		return sb.append("'").toString();
	}

	// ---------------------------------------------------------------- labels

	static List<Map<String, Object>> labelsAt(Session s, Address a) {
		SymbolTable st = s.program.getSymbolTable();
		List<Map<String, Object>> out = new ArrayList<>();
		for (Symbol sym : st.getSymbols(a)) {
			out.add(map("name", sym.getName(), "qualified", sym.getName(true), "namespace", sym.getParentNamespace().getName(true),
				"primary", sym.isPrimary(), "source", sym.getSource().getDisplayString(), "type", sym.getSymbolType().toString(),
				"pinned", sym.isPinned(), "dynamic", sym.isDynamic(), "entry", st.isExternalEntryPoint(a)));
		}
		return out;
	}

	static List<Map<String, Object>> labelHistory(Session s, Address a) {
		SymbolTable st = s.program.getSymbolTable();
		List<Map<String, Object>> out = new ArrayList<>();
		LabelHistory[] list;
		if (a != null) {
			list = st.getLabelHistory(a);
		}
		else {
			List<LabelHistory> all = new ArrayList<>();
			Iterator<LabelHistory> it = st.getLabelHistory();
			while (it.hasNext() && all.size() < 20000) {
				all.add(it.next());
			}
			list = all.toArray(new LabelHistory[0]);
		}
		for (LabelHistory h : list) {
			String action = h.getActionID() == LabelHistory.ADD ? "Añadida"
					: h.getActionID() == LabelHistory.REMOVE ? "Quitada" : "Renombrada";
			out.add(map("address", str(h.getAddress()), "label", h.getLabelString(), "action", Msg.t(action),
				"user", h.getUserName(), "date", date(h.getModificationDate())));
		}
		return out;
	}

	private static Symbol symbol(Session s, Address a, String name) {
		for (Symbol sym : s.program.getSymbolTable().getSymbols(a)) {
			if (name == null || sym.getName().equals(name) || sym.getName(true).equals(name)) {
				return sym;
			}
		}
		throw new IllegalArgumentException("No hay ninguna etiqueta «" + name + "» en " + a);
	}

	static Object setPrimaryLabel(Session s, Address a, String name) throws Exception {
		Symbol sym = symbol(s, a, name);
		return s.edit("Etiqueta primaria", () -> {
			SetLabelPrimaryCmd cmd = new SetLabelPrimaryCmd(a, sym.getName(), sym.getParentNamespace());
			if (!cmd.applyTo(s.program)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	static Object setPinned(Session s, Address a, String name, boolean pinned) throws Exception {
		Symbol sym = symbol(s, a, name);
		return s.edit("Fijar etiqueta", () -> {
			sym.setPinned(pinned);
			return true;
		});
	}

	static Object setEntryPoint(Session s, Address a, boolean on) throws Exception {
		return s.edit("Punto de entrada", () -> {
			SymbolTable st = s.program.getSymbolTable();
			if (on) {
				st.addExternalEntryPoint(a);
			}
			else {
				st.removeExternalEntryPoint(a);
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- comments

	private static final CommentType[] COMMENT_TYPES = { CommentType.EOL, CommentType.PRE, CommentType.POST,
		CommentType.PLATE, CommentType.REPEATABLE };

	private static String commentName(CommentType t) {
		return switch (t) {
			case EOL -> "eol";
			case PRE -> "pre";
			case POST -> "post";
			case PLATE -> "plate";
			default -> "repeatable";
		};
	}

	static List<Map<String, Object>> commentTable(Session s) {
		Listing listing = s.program.getListing();
		List<Map<String, Object>> out = new ArrayList<>();
		AddressIterator it = listing.getCommentAddressIterator(s.program.getMemory(), true);
		while (it.hasNext() && out.size() < 50000) {
			Address a = it.next();
			for (CommentType t : COMMENT_TYPES) {
				String text = listing.getComment(t, a);
				if (text != null && !text.isEmpty()) {
					Function f = s.program.getFunctionManager().getFunctionContaining(a);
					out.add(map("address", str(a), "kind", commentName(t), "comment", text,
						"function", f != null ? f.getName() : null));
				}
			}
		}
		return out;
	}

	static List<Map<String, Object>> commentHistory(Session s, Address a) {
		Listing listing = s.program.getListing();
		List<Map<String, Object>> out = new ArrayList<>();
		for (CommentType t : COMMENT_TYPES) {
			for (CommentHistory h : listing.getCommentHistory(a, t)) {
				out.add(map("address", str(a), "kind", commentName(t), "comment", h.getComments(), "user", h.getUserName(),
					"date", date(h.getModificationDate())));
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- references

	private static String refKind(Reference r) {
		return r.isStackReference() ? "stack" : r.isRegisterReference() ? "register" : r.isExternalReference() ? "external"
				: r.isOffsetReference() ? "offset" : r.isShiftedReference() ? "shifted" : "memory";
	}

	/** Every reference from the code unit at an address, as the reference editor shows them. */
	static Map<String, Object> referencesOf(Session s, Address a) {
		Program p = s.program;
		CodeUnit cu = p.getListing().getCodeUnitContaining(a);
		Address from = cu != null ? cu.getMinAddress() : a;
		List<Map<String, Object>> list = new ArrayList<>();
		for (Reference r : p.getReferenceManager().getReferencesFrom(from)) {
			String target;
			String label = null;
			if (r.isExternalReference()) {
				ExternalLocation loc = ((ExternalReference) r).getExternalLocation();
				target = loc.getLibraryName() + "::" + loc.getLabel();
			}
			else if (r.isStackReference()) {
				int off = ((StackReference) r).getStackOffset();
				target = "Stack[" + (off < 0 ? "-0x" + Integer.toHexString(-off) : "0x" + Integer.toHexString(off)) + "]";
			}
			else {
				target = str(r.getToAddress());
				Symbol sym = p.getSymbolTable().getPrimarySymbol(r.getToAddress());
				label = sym != null ? sym.getName(true) : null;
			}
			list.add(map("from", str(r.getFromAddress()), "to", str(r.getToAddress()), "target", target, "label", label,
				"operand", r.getOperandIndex(), "type", r.getReferenceType().getName(), "kind", refKind(r),
				"primary", r.isPrimary(), "source", r.getSource().getDisplayString(),
				"offset", r.isOffsetReference() ? ((OffsetReference) r).getOffset() : null));
		}
		List<String> operands = new ArrayList<>();
		if (cu instanceof Instruction ins) {
			CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
			for (int i = 0; i < ins.getNumOperands(); i++) {
				operands.add(fmt.getOperandRepresentationString(ins, i));
			}
		}
		List<String> registers = new ArrayList<>();
		for (Register r : p.getLanguage().getRegisters()) {
			if (!r.isHidden() && !r.isProcessorContext()) {
				registers.add(r.getName());
			}
		}
		return map("address", str(from), "mnemonic", cu != null ? cu.getMnemonicString() : "", "operands", operands,
			"references", list, "memoryTypes", names(RefTypeFactory.getMemoryRefTypes()),
			"dataTypes", names(RefTypeFactory.getDataRefTypes()), "stackTypes", names(RefTypeFactory.getStackRefTypes()),
			"externalTypes", names(RefTypeFactory.getExternalRefTypes()), "registers", registers);
	}

	private static List<String> names(RefType[] types) {
		List<String> out = new ArrayList<>();
		for (RefType t : types) {
			out.add(t.getName());
		}
		return out;
	}

	private static RefType refType(String name, RefType fallback) {
		if (name == null || name.isBlank()) {
			return fallback;
		}
		for (RefType[] group : new RefType[][] { RefTypeFactory.getMemoryRefTypes(), RefTypeFactory.getDataRefTypes(),
			RefTypeFactory.getStackRefTypes(), RefTypeFactory.getExternalRefTypes() }) {
			for (RefType t : group) {
				if (t.getName().equalsIgnoreCase(name)) {
					return t;
				}
			}
		}
		throw new IllegalArgumentException("Tipo de referencia desconocido: " + name);
	}

	/**
	 * Adds a reference of any kind. kind: memory (to), offset (to + offset), stack (stackOffset),
	 * register (register) or external (library + label [+ to]).
	 */
	static Object addReference(Session s, Address from, int operand, String kind, String to, String type, long offset,
			String register, String library, String label, boolean primary) throws Exception {
		Program p = s.program;
		return s.edit("Añadir referencia", () -> {
			ReferenceManager rm = p.getReferenceManager();
			CodeUnit cu = p.getListing().getCodeUnitContaining(from);
			Address src = cu != null ? cu.getMinAddress() : from;
			Reference r;
			switch (kind) {
				case "memory":
					r = rm.addMemoryReference(src, s.addr(to), refType(type, RefType.DATA), SourceType.USER_DEFINED, operand);
					break;
				case "offset":
					r = rm.addOffsetMemReference(src, s.addr(to), false, offset, refType(type, RefType.DATA),
						SourceType.USER_DEFINED, operand);
					break;
				case "stack":
					r = rm.addStackReference(src, operand, (int) offset, refType(type, RefType.DATA), SourceType.USER_DEFINED);
					break;
				case "register": {
					Register reg = p.getLanguage().getRegister(register);
					if (reg == null) {
						throw new IllegalArgumentException("Registro desconocido: " + register);
					}
					r = rm.addRegisterReference(src, operand, reg, refType(type, RefType.DATA), SourceType.USER_DEFINED);
					break;
				}
				case "external":
					r = rm.addExternalReference(src, library, label, to == null || to.isBlank() ? null : s.addr(to),
						SourceType.USER_DEFINED, operand, refType(type, RefType.DATA));
					break;
				default:
					throw new IllegalArgumentException("Clase de referencia desconocida: " + kind);
			}
			if (primary && r != null) {
				rm.setPrimary(r, true);
			}
			return true;
		});
	}

	private static Reference reference(Session s, Address from, String to, int operand) {
		ReferenceManager rm = s.program.getReferenceManager();
		for (Reference r : rm.getReferencesFrom(from)) {
			if (r.getOperandIndex() == operand && str(r.getToAddress()).equals(to)) {
				return r;
			}
		}
		throw new IllegalArgumentException("No existe esa referencia");
	}

	/** Changes the type of a reference, makes it primary, or deletes it. */
	static Object editReference(Session s, Address from, String to, int operand, String type, Boolean primary,
			boolean delete) throws Exception {
		return s.edit(delete ? "Borrar referencia" : "Editar referencia", () -> {
			ReferenceManager rm = s.program.getReferenceManager();
			Reference r = reference(s, from, to, operand);
			if (delete) {
				rm.delete(r);
				return true;
			}
			if (type != null && !type.isBlank()) {
				r = rm.updateRefType(r, refType(type, r.getReferenceType()));
			}
			if (primary != null) {
				rm.setPrimary(r, primary);
			}
			return true;
		});
	}

	/** Chooses which label of the destination an operand shows. */
	static Object setReferenceLabel(Session s, Address from, String to, int operand, String label) throws Exception {
		return s.edit("Etiqueta del operando", () -> {
			Reference r = reference(s, from, to, operand);
			s.program.getReferenceManager().setAssociation(symbol(s, r.getToAddress(), label), r);
			return true;
		});
	}

	// ---------------------------------------------------------------- functions

	static Object recreateFunction(Session s, Address a) throws Exception {
		Function f = s.functionContaining(a);
		return s.edit("Recrear función", () -> {
			CreateFunctionCmd cmd = new CreateFunctionCmd(null, f.getEntryPoint(), null, SourceType.USER_DEFINED, false, true);
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	static Object createFunctions(Session s, AddressSet set) throws Exception {
		return s.edit("Crear funciones", () -> {
			int before = s.program.getFunctionManager().getFunctionCount();
			CreateMultipleFunctionsCmd cmd = new CreateMultipleFunctionsCmd(set, SourceType.USER_DEFINED);
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg() != null ? cmd.getStatusMsg() : "No se creó ninguna función");
			}
			return s.program.getFunctionManager().getFunctionCount() - before;
		});
	}

	/** Makes the function at an address a thunk of another (target empty: stop being a thunk). */
	static Object setThunk(Session s, Address a, String target) throws Exception {
		return s.edit("Función thunk", () -> {
			FunctionManager fm = s.program.getFunctionManager();
			Function f = fm.getFunctionAt(a);
			if (target == null || target.isBlank()) {
				if (f == null) {
					throw new IllegalArgumentException("No hay función en " + a);
				}
				f.setThunkedFunction(null);
				return true;
			}
			Address to = s.addr((String) s.resolve(target).get("address"));
			if (f == null) {
				CreateThunkFunctionCmd cmd = new CreateThunkFunctionCmd(a, null, to);
				if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
					throw new IllegalStateException(cmd.getStatusMsg());
				}
				return true;
			}
			Function thunked = fm.getFunctionAt(to);
			if (thunked == null) {
				throw new IllegalArgumentException("No hay función en " + to);
			}
			f.setThunkedFunction(thunked);
			return true;
		});
	}

	static Object createExternalFunction(Session s, String library, String name, String address) throws Exception {
		return s.edit("Crear función externa", () -> {
			CreateExternalFunctionCmd cmd = new CreateExternalFunctionCmd(library, name,
				address == null || address.isBlank() ? null : s.addr(address), SourceType.USER_DEFINED);
			if (!cmd.applyTo(s.program)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	/** Extra function attributes: stack purge, call fixup. */
	static Map<String, Object> functionExtras(Session s, Address a) {
		Function f = s.functionContaining(a);
		List<String> fixups = new ArrayList<>(Arrays.asList(
			s.program.getCompilerSpec().getPcodeInjectLibrary().getCallFixupNames()));
		Function thunked = f.getThunkedFunction(false);
		List<Map<String, Object>> params = new ArrayList<>();
		for (Parameter prm : f.getParameters()) {
			params.add(map("name", prm.getName(), "type", prm.getDataType().getDisplayName(), "ordinal", prm.getOrdinal(),
				"storage", prm.getVariableStorage().toString()));
		}
		Parameter ret = f.getReturn();
		return map("entry", str(f.getEntryPoint()), "name", f.getName(),
			"purge", f.isStackPurgeSizeValid() ? f.getStackPurgeSize() : null, "callFixup", f.getCallFixup(),
			"callFixups", fixups, "thunk", thunked != null ? thunked.getName(true) : null,
			"customStorage", f.hasCustomVariableStorage(), "parameters", params,
			"returnStorage", ret != null ? ret.getVariableStorage().toString() : null,
			"repeatable", f.getRepeatableComment());
	}

	static Object setFunctionExtras(Session s, Address a, String purge, String callFixup) throws Exception {
		Function f = s.functionContaining(a);
		return s.edit("Editar función", () -> {
			if (purge != null) {
				f.setStackPurgeSize(purge.isBlank() ? Function.UNKNOWN_STACK_DEPTH_CHANGE : Emulation.parseNumber(purge).intValue());
			}
			if (callFixup != null) {
				f.setCallFixup(callFixup.isBlank() ? null : callFixup);
			}
			return true;
		});
	}

	/** Storage of one parameter, written like Ghidra shows it: "x0:8", "Stack[0x10]:4", "x0:4,x1:4". */
	static VariableStorage storage(Program p, String text) throws Exception {
		List<Varnode> parts = new ArrayList<>();
		for (String piece : text.split(",")) {
			String t = piece.trim();
			int colon = t.lastIndexOf(':');
			if (colon < 0) {
				throw new IllegalArgumentException("Almacenamiento inválido: " + t + " (ejemplos: x0:8, Stack[0x10]:4)");
			}
			int size = Emulation.parseNumber(t.substring(colon + 1)).intValue();
			String where = t.substring(0, colon).trim();
			if (where.toLowerCase().startsWith("stack[")) {
				long off = Emulation.parseNumber(where.substring(6, where.length() - 1).trim()).longValue();
				parts.add(new Varnode(p.getAddressFactory().getStackSpace().getAddress(off), size));
			}
			else {
				Register r = p.getLanguage().getRegister(where);
				if (r == null) {
					r = p.getLanguage().getRegister(where.toUpperCase());
				}
				if (r != null) {
					Address ra = r.getAddress();
					if (size < r.getMinimumByteSize() && p.getLanguage().isBigEndian()) {
						ra = ra.add(r.getMinimumByteSize() - size);
					}
					parts.add(new Varnode(ra, size));
				}
				else {
					parts.add(new Varnode(p.getAddressFactory().getAddress(where), size));
				}
			}
		}
		return new VariableStorage(p, parts.toArray(new Varnode[0]));
	}

	/** Sets where a parameter (ordinal -1: the return value) lives; turns custom storage on. */
	static Object setParameterStorage(Session s, Address a, int ordinal, String text) throws Exception {
		Function f = s.functionContaining(a);
		return s.edit("Almacenamiento del parámetro", () -> {
			f.setCustomVariableStorage(true);
			Parameter prm = ordinal < 0 ? f.getReturn() : f.getParameter(ordinal);
			if (prm == null) {
				throw new IllegalArgumentException("No existe ese parámetro");
			}
			prm.setDataType(prm.getDataType(), storage(s.program, text), true, SourceType.USER_DEFINED);
			return true;
		});
	}

	static Object stackDepthChange(Session s, Address a, String value) throws Exception {
		return s.edit("Cambio de profundidad de pila", () -> {
			if (value == null || value.isBlank()) {
				return CallDepthChangeInfo.removeStackDepthChange(s.program, a);
			}
			CallDepthChangeInfo.setStackDepthChange(s.program, a, Emulation.parseNumber(value).intValue());
			return true;
		});
	}

	// function tags

	static List<Map<String, Object>> functionTags(Session s) {
		FunctionTagManager tm = s.program.getFunctionManager().getFunctionTagManager();
		List<Map<String, Object>> out = new ArrayList<>();
		for (FunctionTag t : tm.getAllFunctionTags()) {
			out.add(map("name", t.getName(), "comment", t.getComment(), "uses", tm.getUseCount(t)));
		}
		out.sort(Comparator.comparing(m -> String.valueOf(m.get("name")).toLowerCase()));
		return out;
	}

	static Object editFunctionTag(Session s, String name, String newName, String comment, boolean delete) throws Exception {
		return s.edit("Etiquetas de función", () -> {
			FunctionTagManager tm = s.program.getFunctionManager().getFunctionTagManager();
			FunctionTag t = tm.getFunctionTag(name);
			if (t == null) {
				if (delete) {
					return false;
				}
				t = tm.createFunctionTag(name, comment != null ? comment : "");
				return true;
			}
			if (delete) {
				t.delete();
				return true;
			}
			if (newName != null && !newName.isBlank() && !newName.equals(name)) {
				t.setName(newName);
			}
			if (comment != null) {
				t.setComment(comment);
			}
			return true;
		});
	}

	static List<Map<String, Object>> functionsWithTag(Session s, String name) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Function f : s.program.getFunctionManager().getFunctions(true)) {
			for (FunctionTag t : f.getTags()) {
				if (t.getName().equals(name)) {
					out.add(map("address", str(f.getEntryPoint()), "name", f.getName()));
					break;
				}
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- instruction overrides

	static Map<String, Object> instructionInfo(Session s, Address a) {
		Instruction ins = s.program.getListing().getInstructionContaining(a);
		if (ins == null) {
			throw new IllegalArgumentException("No hay una instrucción en " + a);
		}
		List<String> flows = new ArrayList<>();
		for (FlowOverride f : FlowOverride.values()) {
			flows.add(f.name());
		}
		List<String> pcode = new ArrayList<>();
		for (ghidra.program.model.pcode.PcodeOp op : ins.getPcode()) {
			pcode.add(op.toString());
		}
		List<Map<String, Object>> operands = new ArrayList<>();
		for (int i = 0; i < ins.getNumOperands(); i++) {
			List<String> objects = new ArrayList<>();
			for (Object o : ins.getOpObjects(i)) {
				objects.add(o.getClass().getSimpleName() + " " + o);
			}
			operands.add(map("index", i, "text", ins.getDefaultOperandRepresentation(i),
				"type", ghidra.program.model.lang.OperandType.toString(ins.getOperandType(i)), "objects", objects));
		}
		List<String> inputs = new ArrayList<>(), results = new ArrayList<>();
		for (Object o : ins.getInputObjects()) {
			inputs.add(String.valueOf(o));
		}
		for (Object o : ins.getResultObjects()) {
			results.add(String.valueOf(o));
		}
		return map("address", str(ins.getMinAddress()), "text", ins.toString(), "length", ins.getLength(),
			"parsedLength", ins.getParsedLength(), "lengthOverridden", ins.isLengthOverridden(),
			"flowOverride", ins.getFlowOverride().name(), "flowOverrides", flows, "flowType", ins.getFlowType().getName(),
			"fallthrough", str(ins.getFallThrough()), "defaultFallthrough", str(ins.getDefaultFallThrough()),
			"fallthroughOverridden", ins.isFallThroughOverridden(), "delaySlots", ins.getDelaySlotDepth(),
			"prototype", ins.getPrototype().toString(), "pcode", pcode, "operands", operands, "inputs", inputs,
			"results", results);
	}

	static Object setFlowOverride(Session s, Address a, String flow) throws Exception {
		Instruction ins = s.program.getListing().getInstructionContaining(a);
		if (ins == null) {
			throw new IllegalArgumentException("No hay una instrucción en " + a);
		}
		return s.edit("Modificar flujo de la instrucción", () -> {
			ins.setFlowOverride(FlowOverride.valueOf(flow));
			return true;
		});
	}

	static Object setLengthOverride(Session s, Address a, int length) throws Exception {
		Instruction ins = s.program.getListing().getInstructionContaining(a);
		if (ins == null) {
			throw new IllegalArgumentException("No hay una instrucción en " + a);
		}
		return s.edit("Longitud de la instrucción", () -> {
			ins.setLengthOverride(length);
			return true;
		});
	}

	/** Fallthrough override: an address, "" to clear the override, "none" for no fallthrough at all. */
	static Object setFallthrough(Session s, Address a, String to) throws Exception {
		Instruction ins = s.program.getListing().getInstructionContaining(a);
		if (ins == null) {
			throw new IllegalArgumentException("No hay una instrucción en " + a);
		}
		return s.edit("Fallthrough", () -> {
			if (to == null || to.isBlank()) {
				ins.clearFallThroughOverride();
			}
			else if (to.equals("none")) {
				ins.setFallThrough(null);
			}
			else {
				ins.setFallThrough(s.addr(to));
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- register values

	/** Every range where a register has a value set (the Register Manager). */
	static List<Map<String, Object>> registerValues(Session s, String only) {
		ProgramContext ctx = s.program.getProgramContext();
		List<Map<String, Object>> out = new ArrayList<>();
		for (Register r : ctx.getRegistersWithValues()) {
			if (only != null && !only.isBlank() && !r.getName().equalsIgnoreCase(only)) {
				continue;
			}
			AddressRangeIterator it = ctx.getRegisterValueAddressRanges(r);
			while (it.hasNext() && out.size() < 20000) {
				AddressRange range = it.next();
				RegisterValue v = ctx.getRegisterValue(r, range.getMinAddress());
				out.add(map("register", r.getName(), "address", str(range.getMinAddress()), "end", str(range.getMaxAddress()),
					"value", v != null && v.hasValue() ? "0x" + v.getUnsignedValue().toString(16) : "",
					"context", r.isProcessorContext()));
			}
		}
		return out;
	}

	static Object clearRegisterValue(Session s, String register, Address start, Address end) throws Exception {
		Register r = s.program.getLanguage().getRegister(register);
		if (r == null) {
			throw new IllegalArgumentException("Registro desconocido: " + register);
		}
		return s.edit("Quitar valor de registro", () -> {
			s.program.getProgramContext().remove(start, end, r);
			return true;
		});
	}

	// ---------------------------------------------------------------- memory blocks

	/** flag: volatile, artificial, initialized (value true/false), or comment (text). */
	static Object setBlockFlag(Session s, String block, String flag, String value) throws Exception {
		Memory mem = s.program.getMemory();
		MemoryBlock b = mem.getBlock(block);
		if (b == null) {
			throw new IllegalArgumentException("No existe el bloque " + block);
		}
		return s.edit("Editar bloque de memoria", () -> {
			boolean on = Boolean.parseBoolean(value);
			switch (flag) {
				case "volatile" -> b.setVolatile(on);
				case "artificial" -> b.setArtificial(on);
				case "comment" -> b.setComment(value);
				case "initialized" -> {
					if (on) {
						mem.convertToInitialized(b, (byte) 0);
					}
					else {
						mem.convertToUninitialized(b);
					}
				}
				default -> throw new IllegalArgumentException("Ajuste desconocido: " + flag);
			}
			return true;
		});
	}

	static Object renameOverlay(Session s, String name, String newName) throws Exception {
		return s.edit("Renombrar espacio overlay", () -> {
			s.program.renameOverlaySpace(name, newName);
			return true;
		});
	}

	// ---------------------------------------------------------------- listing colors

	/** Ghidra keeps listing background colors in this range map of the program. */
	private static final String COLORS = "LISTING_COLOR";

	static Object setColor(Session s, AddressSet set, String rgb) throws Exception {
		return s.edit("Color de fondo", () -> {
			IntRangeMap colors = s.program.getIntRangeMap(COLORS);
			if (rgb == null || rgb.isBlank()) {
				if (colors != null) {
					if (set.isEmpty()) {
						colors.clearAll();
					}
					else {
						colors.clearValue(set);
					}
				}
				return true;
			}
			if (colors == null) {
				colors = s.program.createIntRangeMap(COLORS);
			}
			colors.setValue(set, 0xff000000 | Integer.parseInt(rgb.replace("#", ""), 16));
			return true;
		});
	}

	/** Colored ranges: [[start, end, "rrggbb"], …]. */
	static List<List<String>> colors(Session s) {
		List<List<String>> out = new ArrayList<>();
		IntRangeMap colors = s.program.getIntRangeMap(COLORS);
		if (colors == null) {
			return out;
		}
		for (AddressRange r : colors.getAddressSet()) {
			// a range may hold several colors: split it where the value changes
			Address start = r.getMinAddress();
			Integer current = colors.getValue(start);
			Address a = start;
			while (a != null && r.contains(a) && out.size() < 5000) {
				Address next = a.equals(r.getMaxAddress()) ? null : a.next();
				Integer v = next != null ? colors.getValue(next) : null;
				if (next == null || !Objects.equals(v, current)) {
					if (current != null) {
						out.add(List.of(str(start), str(a), String.format("%06x", current & 0xffffff)));
					}
					start = next;
					current = v;
				}
				a = next;
				if (r.getLength() > 200_000) {
					// very large uniform ranges: do not walk byte by byte
					out.add(List.of(str(r.getMinAddress()), str(r.getMaxAddress()),
						String.format("%06x", colors.getValue(r.getMinAddress()) & 0xffffff)));
					break;
				}
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- program options and properties

	static List<String> optionLists(Session s) {
		return new ArrayList<>(s.program.getOptionsNames());
	}

	static List<Map<String, Object>> options(Session s, String list) {
		ghidra.framework.options.Options options = s.program.getOptions(list);
		List<Map<String, Object>> out = new ArrayList<>();
		for (String name : options.getOptionNames()) {
			ghidra.framework.options.OptionType type = options.getType(name);
			Object value;
			try {
				value = options.getObject(name, null);
			}
			catch (Exception e) {
				value = null;
			}
			String kind = switch (type) {
				case BOOLEAN_TYPE -> "boolean";
				case INT_TYPE, LONG_TYPE, DOUBLE_TYPE, FLOAT_TYPE -> "number";
				case STRING_TYPE -> "text";
				default -> "readonly";
			};
			out.add(map("name", name, "type", kind,
				"value", value instanceof Date d ? date(d) : value != null ? String.valueOf(value) : "",
				"description", options.getDescription(name)));
		}
		out.sort(Comparator.comparing(m -> String.valueOf(m.get("name"))));
		return out;
	}

	static Object setOption(Session s, String list, String name, String value) throws Exception {
		return s.edit("Opciones del programa", () -> {
			ghidra.framework.options.Options options = s.program.getOptions(list);
			switch (options.getType(name)) {
				case BOOLEAN_TYPE -> options.setBoolean(name, Boolean.parseBoolean(value));
				case INT_TYPE -> options.setInt(name, Emulation.parseNumber(value).intValue());
				case LONG_TYPE -> options.setLong(name, Emulation.parseNumber(value).longValue());
				case DOUBLE_TYPE -> options.setDouble(name, Double.parseDouble(value));
				case FLOAT_TYPE -> options.setFloat(name, Float.parseFloat(value));
				case STRING_TYPE -> options.setString(name, value);
				default -> throw new IllegalArgumentException("Esa opción no se puede cambiar desde aquí");
			}
			return true;
		});
	}

	/** User-defined property maps of the program and where they have values. */
	static List<Map<String, Object>> properties(Session s, String name) {
		ghidra.program.model.util.PropertyMapManager pm = s.program.getUsrPropertyManager();
		List<Map<String, Object>> out = new ArrayList<>();
		Iterator<String> names = pm.propertyManagers();
		while (names.hasNext()) {
			String n = names.next();
			ghidra.program.model.util.PropertyMap<?> pmap = pm.getPropertyMap(n);
			if (name == null || name.isBlank()) {
				out.add(map("name", n, "count", pmap.getSize(), "address", str(pmap.getFirstPropertyAddress())));
			}
			else if (n.equals(name)) {
				AddressIterator it = pmap.getPropertyIterator();
				while (it.hasNext() && out.size() < 20000) {
					Address a = it.next();
					out.add(map("name", n, "address", str(a), "value", String.valueOf(pmap.get(a))));
				}
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- copy special

	/** Text for the clipboard from a range: bytes in several notations, addresses, labels… */
	static String copySpecial(Session s, Address start, Address end, String format) throws Exception {
		Program p = s.program;
		int length = (int) Math.min(end.subtract(start) + 1, 1 << 20);
		byte[] bytes = new byte[length];
		int read = p.getMemory().getBytes(start, bytes);
		StringBuilder sb = new StringBuilder();
		switch (format) {
			case "hex":
				for (int i = 0; i < read; i++) {
					sb.append(String.format("%02x", bytes[i] & 0xff));
				}
				break;
			case "hexSpaced":
				for (int i = 0; i < read; i++) {
					sb.append(i > 0 ? " " : "").append(String.format("%02x", bytes[i] & 0xff));
				}
				break;
			case "c":
				sb.append("unsigned char data[").append(read).append("] = {");
				for (int i = 0; i < read; i++) {
					sb.append(i % 12 == 0 ? "\n    " : " ").append(String.format("0x%02x,", bytes[i] & 0xff));
				}
				sb.append("\n};\n");
				break;
			case "python":
				sb.append("data = b\"");
				for (int i = 0; i < read; i++) {
					sb.append(String.format("\\x%02x", bytes[i] & 0xff));
				}
				sb.append("\"");
				break;
			case "string":
				sb.append(new String(bytes, 0, read, java.nio.charset.StandardCharsets.ISO_8859_1));
				break;
			case "address":
				sb.append(str(start));
				break;
			case "addressOffset": {
				Function f = p.getFunctionManager().getFunctionContaining(start);
				sb.append(f != null ? f.getName() + "+0x" + Long.toHexString(start.subtract(f.getEntryPoint())) : str(start));
				break;
			}
			case "fileOffset": {
				ghidra.program.database.mem.AddressSourceInfo info = p.getMemory().getAddressSourceInfo(start);
				sb.append(info != null && info.getFileOffset() >= 0 ? "0x" + Long.toHexString(info.getFileOffset()) : "");
				break;
			}
			case "label": {
				Symbol sym = p.getSymbolTable().getPrimarySymbol(start);
				sb.append(sym != null ? sym.getName(true) : str(start));
				break;
			}
			case "listing": {
				CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
				CodeUnitIterator it = p.getListing().getCodeUnits(new AddressSet(start, end), true);
				int n = 0;
				while (it.hasNext() && n++ < 20000) {
					CodeUnit cu = it.next();
					sb.append(str(cu.getMinAddress())).append("  ").append(fmt.getRepresentationString(cu));
					String eol = cu.getComment(CommentType.EOL);
					if (eol != null) {
						sb.append("    ; ").append(eol.replace("\n", " "));
					}
					sb.append("\n");
				}
				break;
			}
			default:
				throw new IllegalArgumentException("Formato desconocido: " + format);
		}
		return sb.toString();
	}

	/** What a pop-up shows about an address: its label, the function, the data value or a few instructions. */
	static Map<String, Object> preview(Session s, Address a) {
		Program p = s.program;
		Listing listing = p.getListing();
		List<String> lines = new ArrayList<>();
		Symbol sym = p.getSymbolTable().getPrimarySymbol(a);
		Function f = p.getFunctionManager().getFunctionContaining(a);
		String title = sym != null ? sym.getName(true) : str(a);
		if (a.isExternalAddress()) {
			return map("title", title, "lines", List.of(Msg.t("Símbolo externo")), "address", str(a));
		}
		if (f != null && f.getEntryPoint().equals(a)) {
			lines.add(f.getPrototypeString(true, false));
		}
		CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
		CodeUnit cu = listing.getCodeUnitContaining(a);
		if (cu instanceof Data d && d.isDefined()) {
			lines.add(d.getDataType().getDisplayName() + "  " + d.getDefaultValueRepresentation());
		}
		else if (cu != null) {
			CodeUnitIterator it = listing.getCodeUnits(cu.getMinAddress(), true);
			for (int i = 0; i < 8 && it.hasNext(); i++) {
				CodeUnit next = it.next();
				lines.add(str(next.getMinAddress()) + "  " + fmt.getRepresentationString(next));
			}
		}
		MemoryBlock block = p.getMemory().getBlock(a);
		return map("title", title, "lines", lines, "address", str(a), "block", block != null ? block.getName() : null,
			"function", f != null ? f.getName() : null);
	}

	/** Disassembles what is at an address without changing the program (the Disassembled View). */
	static List<Map<String, Object>> pseudoDisassemble(Session s, Address a, int count) {
		Program p = s.program;
		ghidra.app.util.PseudoDisassembler dis = new ghidra.app.util.PseudoDisassembler(p);
		List<Map<String, Object>> out = new ArrayList<>();
		Address at = a;
		for (int i = 0; i < Math.min(count, 400) && at != null && p.getMemory().contains(at); i++) {
			try {
				ghidra.app.util.PseudoInstruction ins = dis.disassemble(at);
				if (ins == null) {
					break;
				}
				out.add(map("address", str(at), "bytes", hex(ins.getBytes(), 8), "text", ins.toString()));
				at = at.add(ins.getLength());
			}
			catch (Exception e) {
				out.add(map("address", str(at), "bytes", "", "text", "??"));
				break;
			}
		}
		return out;
	}
}
