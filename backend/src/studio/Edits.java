package studio;

import static studio.Json.*;

import java.math.BigInteger;
import java.util.*;

import ghidra.app.cmd.data.CreateArrayCmd;
import ghidra.app.cmd.data.CreateStructureCmd;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.register.SetRegisterCmd;
import ghidra.program.model.address.*;
import ghidra.docking.settings.FormatSettingsDefinition;
import ghidra.program.model.data.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;
import ghidra.util.task.TaskMonitor;

/** Range operations on the listing, register context, data formats, function editor, stack and tags. */
final class Edits {
	private Edits() {
	}

	// ---------------------------------------------------------------- ranges

	static Object disassembleRange(Session s, Address start, Address end) throws Exception {
		return s.edit("Desensamblar", () -> {
			DisassembleCommand cmd = new DisassembleCommand(new AddressSet(start, end), null, true);
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException(cmd.getStatusMsg() != null ? cmd.getStatusMsg() : "No se pudo desensamblar");
			}
			return true;
		});
	}

	static Object clearRange(Session s, Address start, Address end) throws Exception {
		return s.edit("Borrar código", () -> {
			Listing l = s.program.getListing();
			CodeUnit first = l.getCodeUnitContaining(start);
			CodeUnit last = l.getCodeUnitContaining(end);
			l.clearCodeUnits(first != null ? first.getMinAddress() : start, last != null ? last.getMaxAddress() : end, false);
			return true;
		});
	}

	static Object createArray(Session s, Address address, String typeText, int count) throws Exception {
		DataType dt = Types.parse(s.program, typeText);
		return s.edit("Crear array", () -> {
			int len = Math.max(1, dt.getLength());
			Address end = address.add((long) len * count - 1);
			s.program.getListing().clearCodeUnits(address, end, false);
			CreateArrayCmd cmd = new CreateArrayCmd(address, count, dt, len);
			if (!cmd.applyTo(s.program)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	static Object structFromRange(Session s, Address start, Address end, String name) throws Exception {
		return s.edit("Crear estructura", () -> {
			int length = (int) (end.subtract(start) + 1);
			CreateStructureCmd cmd = name == null || name.isBlank() ? new CreateStructureCmd(start, length)
					: new CreateStructureCmd(name, start, length);
			if (!cmd.applyTo(s.program)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			Data d = s.program.getListing().getDataAt(start);
			return map("path", d != null ? d.getDataType().getPathName() : null);
		});
	}

	static Object defineString(Session s, Address address, int length, boolean unicode) throws Exception {
		return s.edit("Definir cadena", () -> {
			DataType dt = unicode ? new UnicodeDataType() : new StringDataType();
			DataUtilities.createData(s.program, address, dt, length, DataUtilities.ClearDataMode.CLEAR_ALL_CONFLICT_DATA);
			return true;
		});
	}

	// ---------------------------------------------------------------- register context

	static List<Map<String, Object>> contextRegisters(Session s, Address address) {
		List<Map<String, Object>> out = new ArrayList<>();
		ProgramContext ctx = s.program.getProgramContext();
		Register base = ctx.getBaseContextRegister();
		Set<Register> seen = new LinkedHashSet<>();
		if (base != null) {
			seen.addAll(base.getChildRegisters());
		}
		for (Register r : ctx.getRegistersWithValues()) {
			if (r.isBaseRegister() || r.isProcessorContext()) {
				seen.add(r);
			}
		}
		for (Register r : seen) {
			if (r.isHidden()) {
				continue;
			}
			BigInteger v = ctx.getValue(r, address, false);
			out.add(map("name", r.getName(), "bits", r.getBitLength(), "value", v != null ? "0x" + v.toString(16) : null,
				"context", r.isProcessorContext()));
		}
		out.sort(Comparator.comparing(o -> (String) o.get("name")));
		return out;
	}

	static Object setRegister(Session s, Address start, Address end, String name, String value) throws Exception {
		Register r = s.program.getLanguage().getRegister(name);
		if (r == null) {
			throw new IllegalArgumentException("Registro desconocido: " + name);
		}
		BigInteger v = value == null || value.isBlank() ? null : Emulation.parseNumber(value);
		return s.edit("Valor de registro", () -> {
			SetRegisterCmd cmd = new SetRegisterCmd(r, start, end, v);
			if (!cmd.applyTo(s.program)) {
				throw new IllegalStateException(cmd.getStatusMsg());
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- data format

	static Object setDataFormat(Session s, Address address, String format) throws Exception {
		Data d = s.program.getListing().getDataContaining(address);
		if (d == null) {
			throw new IllegalArgumentException("No hay ningún dato en " + address);
		}
		int choice = switch (format) {
			case "decimal" -> FormatSettingsDefinition.DECIMAL;
			case "binary" -> FormatSettingsDefinition.BINARY;
			case "octal" -> FormatSettingsDefinition.OCTAL;
			case "char" -> FormatSettingsDefinition.CHAR;
			default -> FormatSettingsDefinition.HEX;
		};
		return s.edit("Formato de dato", () -> {
			FormatSettingsDefinition.DEF.setChoice(d, choice);
			return true;
		});
	}

	// ---------------------------------------------------------------- function editor

	static Map<String, Object> functionProperties(Session s, Address address) {
		Function f = s.functionContaining(address);
		List<String> conventions = new ArrayList<>(s.program.getFunctionManager().getCallingConventionNames());
		List<Map<String, Object>> vars = new ArrayList<>();
		for (Variable v : f.getAllVariables()) {
			vars.add(map("name", v.getName(), "type", v.getDataType().getDisplayName(), "storage", v.getVariableStorage().toString(),
				"size", v.getLength(), "parameter", v instanceof Parameter,
				"stackOffset", v.isStackVariable() ? v.getStackOffset() : null, "comment", v.getComment()));
		}
		List<String> tags = new ArrayList<>();
		for (FunctionTag t : f.getTags()) {
			tags.add(t.getName());
		}
		List<String> allTags = new ArrayList<>();
		for (FunctionTag t : s.program.getFunctionManager().getFunctionTagManager().getAllFunctionTags()) {
			allTags.add(t.getName());
		}
		Collections.sort(allTags);
		return map("name", f.getName(), "entry", str(f.getEntryPoint()), "signature", f.getPrototypeString(false, false),
			"callingConvention", f.getCallingConventionName(), "conventions", conventions,
			"noReturn", f.hasNoReturn(), "inline", f.isInline(), "varArgs", f.hasVarArgs(),
			"customStorage", f.hasCustomVariableStorage(), "thunk", f.isThunk(),
			"stackSize", f.getStackFrame().getFrameSize(), "localSize", f.getStackFrame().getLocalSize(),
			"paramSize", f.getStackFrame().getParameterSize(), "variables", vars, "tags", tags, "allTags", allTags,
			"callFixup", f.getCallFixup());
	}

	static Object editFunction(Session s, Address address, String convention, Boolean noReturn, Boolean inline,
			Boolean varArgs, Boolean customStorage) throws Exception {
		Function f = s.functionContaining(address);
		return s.edit("Editar función", () -> {
			if (convention != null && !convention.equals(f.getCallingConventionName())) {
				f.setCallingConvention(convention);
			}
			if (noReturn != null) {
				f.setNoReturn(noReturn);
			}
			if (inline != null) {
				f.setInline(inline);
			}
			if (varArgs != null) {
				f.setVarArgs(varArgs);
			}
			if (customStorage != null) {
				f.setCustomVariableStorage(customStorage);
			}
			return true;
		});
	}

	static Object editVariable(Session s, Address address, String name, String newName, String typeText) throws Exception {
		Function f = s.functionContaining(address);
		Variable target = null;
		for (Variable v : f.getAllVariables()) {
			if (v.getName().equals(name)) {
				target = v;
			}
		}
		if (target == null) {
			throw new IllegalArgumentException("No se encontró la variable «" + name + "»");
		}
		Variable v = target;
		DataType dt = typeText != null && !typeText.isBlank() ? Types.parse(s.program, typeText) : null;
		return s.edit("Editar variable", () -> {
			if (dt != null) {
				v.setDataType(dt, SourceType.USER_DEFINED);
			}
			if (newName != null && !newName.isBlank() && !newName.equals(name)) {
				v.setName(newName, SourceType.USER_DEFINED);
			}
			return true;
		});
	}

	static Object setTag(Session s, Address address, String tag, boolean on) throws Exception {
		Function f = s.functionContaining(address);
		return s.edit(on ? "Añadir etiqueta de función" : "Quitar etiqueta de función", () -> {
			if (on) {
				f.addTag(tag);
			}
			else {
				f.removeTag(tag);
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- memory blocks

	private static MemoryBlock block(Session s, String name) {
		MemoryBlock b = s.program.getMemory().getBlock(name);
		if (b == null) {
			throw new IllegalArgumentException("No existe el bloque " + name);
		}
		return b;
	}

	static Object splitBlock(Session s, String name, Address at) throws Exception {
		MemoryBlock b = block(s, name);
		return s.edit("Dividir bloque", () -> {
			s.program.getMemory().split(b, at);
			return true;
		});
	}

	static Object joinBlocks(Session s, String first, String second) throws Exception {
		MemoryBlock a = block(s, first);
		MemoryBlock b = block(s, second);
		return s.edit("Unir bloques", () -> {
			s.program.getMemory().join(a, b);
			return true;
		});
	}

	static Object moveBlock(Session s, String name, Address to) throws Exception {
		MemoryBlock b = block(s, name);
		return s.edit("Mover bloque", () -> {
			s.program.getMemory().moveBlock(b, to, TaskMonitor.DUMMY);
			return true;
		});
	}

}
