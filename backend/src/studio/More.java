package studio;

import static studio.Json.*;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.Adler32;
import java.util.zip.CRC32;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.util.parser.FunctionSignatureParser;
import ghidra.program.database.sourcemap.SourceFile;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.lang.RegisterValue;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.*;
import ghidra.program.model.sourcemap.SourceMapEntry;
import ghidra.program.model.symbol.*;
import ghidra.program.util.ProgramMergeFilter;
import ghidra.program.util.ProgramMergeManager;
import ghidra.util.task.TaskMonitor;

/** Memory map, namespaces, externals, typed memory search, diff apply, stack frames, checksums… */
final class More {
	private More() {
	}

	// ---------------------------------------------------------------- memory map

	/** kind: "initialized" | "uninitialized" | "bit" | "byte" (the last two map onto existing memory at source). */
	static Object addBlock(Session s, String name, Address start, long length, String kind, boolean overlay,
			String source, String comment) throws Exception {
		return s.edit("Añadir bloque", () -> {
			Memory mem = s.program.getMemory();
			MemoryBlock b = switch (kind) {
				case "uninitialized" -> mem.createUninitializedBlock(name, start, length, overlay);
				case "bit" -> mem.createBitMappedBlock(name, start, s.addr(source), length, overlay);
				case "byte" -> mem.createByteMappedBlock(name, start, s.addr(source), length, overlay);
				default -> mem.createInitializedBlock(name, start, length, (byte) 0, TaskMonitor.DUMMY, overlay);
			};
			b.setPermissions(true, true, false);
			if (comment != null && !comment.isBlank()) {
				b.setComment(comment);
			}
			return true;
		});
	}

	static Object setImageBase(Session s, Address base) throws Exception {
		return s.edit("Cambiar dirección base", () -> {
			s.program.setImageBase(base, true);
			return s.info();
		});
	}

	/** Grows a block so that it starts at (up) or ends at (down) the given address. */
	static Object expandBlock(Session s, String name, Address to) throws Exception {
		return s.edit("Expandir bloque", () -> {
			Memory mem = s.program.getMemory();
			MemoryBlock block = mem.getBlock(name);
			if (block == null) {
				throw new IllegalArgumentException("No existe el bloque " + name);
			}
			if (to.compareTo(block.getStart()) < 0) {
				long length = block.getStart().subtract(to);
				MemoryBlock extra = mem.createBlock(block, block.getName() + ".exp", to, length);
				MemoryBlock joined = mem.join(extra, block);
				joined.setName(name);
			}
			else if (to.compareTo(block.getEnd()) > 0) {
				long length = to.subtract(block.getEnd());
				MemoryBlock extra = mem.createBlock(block, block.getName() + ".exp", block.getEnd().add(1), length);
				mem.join(block, extra);
			}
			else {
				throw new IllegalArgumentException("La dirección ya está dentro del bloque");
			}
			return true;
		});
	}

	// ---------------------------------------------------------------- namespaces & externals

	private static Namespace namespace(Session s, long id) {
		if (id == 0) {
			return s.program.getGlobalNamespace();
		}
		Symbol sym = s.program.getSymbolTable().getSymbol(id);
		if (sym == null || !(sym.getObject() instanceof Namespace ns)) {
			throw new IllegalArgumentException("Namespace desconocido");
		}
		return ns;
	}

	static Object createNamespace(Session s, long parent, String name, boolean isClass) throws Exception {
		return s.edit(isClass ? "Crear clase" : "Crear namespace", () -> {
			SymbolTable st = s.program.getSymbolTable();
			Namespace p = namespace(s, parent);
			Namespace ns = isClass ? st.createClass(p, name, SourceType.USER_DEFINED)
					: st.createNameSpace(p, name, SourceType.USER_DEFINED);
			return map("id", ns.getSymbol().getID(), "name", ns.getName(true));
		});
	}

	static Object convertToClass(Session s, long id) throws Exception {
		return s.edit("Convertir en clase", () -> {
			s.program.getSymbolTable().convertNamespaceToClass(namespace(s, id));
			return true;
		});
	}

	/** Moves a symbol (function, label, namespace…) into another namespace. */
	static Object moveSymbol(Session s, long symbolId, long namespaceId) throws Exception {
		return s.edit("Mover símbolo", () -> {
			Symbol sym = s.program.getSymbolTable().getSymbol(symbolId);
			if (sym == null) {
				throw new IllegalArgumentException("Símbolo desconocido");
			}
			sym.setNamespace(namespace(s, namespaceId));
			return true;
		});
	}

	static Object deleteSymbol(Session s, long symbolId) throws Exception {
		return s.edit("Borrar símbolo", () -> {
			Symbol sym = s.program.getSymbolTable().getSymbol(symbolId);
			if (sym == null) {
				throw new IllegalArgumentException("Símbolo desconocido");
			}
			if (!sym.delete()) {
				throw new IllegalStateException("No se puede borrar: el namespace no está vacío o el símbolo es automático");
			}
			return true;
		});
	}

	/** Every namespace and class, for "move to…" pickers. */
	static List<Map<String, Object>> namespaces(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		out.add(map("id", 0L, "name", "Global", "kind", "Global"));
		SymbolTable st = s.program.getSymbolTable();
		for (Symbol sym : st.getDefinedSymbols()) {
			SymbolType t = sym.getSymbolType();
			if ((t == SymbolType.NAMESPACE || t == SymbolType.CLASS) && !sym.isExternal()) {
				out.add(map("id", sym.getID(), "name", sym.getName(true), "kind", t.toString()));
				if (out.size() >= 5000) {
					break;
				}
			}
		}
		out.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
		return out;
	}

	static List<Map<String, Object>> externals(Session s) {
		ExternalManager em = s.program.getExternalManager();
		List<Map<String, Object>> out = new ArrayList<>();
		for (String lib : em.getExternalLibraryNames()) {
			List<Map<String, Object>> locations = new ArrayList<>();
			ExternalLocationIterator it = em.getExternalLocations(lib);
			while (it.hasNext() && locations.size() < 5000) {
				ExternalLocation loc = it.next();
				locations.add(map("id", loc.getSymbol().getID(), "label", loc.getLabel(),
					"original", loc.getOriginalImportedName(), "address", str(loc.getAddress()),
					"function", loc.isFunction(), "space", str(loc.getExternalSpaceAddress())));
			}
			locations.sort(Comparator.comparing(o -> String.valueOf(o.get("label")).toLowerCase()));
			out.add(map("library", lib, "path", em.getExternalLibraryPath(lib), "locations", locations));
		}
		return out;
	}

	/** Links an external library to a program of the project (so "go to" can follow into it). */
	static Object setExternalPath(Session s, String library, String path) throws Exception {
		return s.edit("Enlazar librería externa", () -> {
			s.program.getExternalManager().setExternalPath(library, path == null || path.isBlank() ? null : path, true);
			return externals(s);
		});
	}

	static Object editExternal(Session s, long id, String label, String address) throws Exception {
		return s.edit("Editar ubicación externa", () -> {
			Symbol sym = s.program.getSymbolTable().getSymbol(id);
			ExternalLocation loc = sym != null ? s.program.getExternalManager().getExternalLocation(sym) : null;
			if (loc == null) {
				throw new IllegalArgumentException("Símbolo desconocido");
			}
			Address a = address == null || address.isBlank() ? null : s.addr(address);
			loc.setLocation(label == null || label.isBlank() ? loc.getLabel() : label, a, SourceType.USER_DEFINED);
			return externals(s);
		});
	}

	// ---------------------------------------------------------------- disassembly

	/**
	 * Disassembles with a context register preset (e.g. TMode=1 for Thumb) and/or restricted to
	 * [start, end] so the flow is not followed outside the selection.
	 */
	static Object disassemble(Session s, Address start, Address end, String register, String value,
			boolean restricted) throws Exception {
		return s.edit("Desensamblar", () -> {
			AddressSet set = new AddressSet(start, end != null ? end : start);
			DisassembleCommand cmd = new DisassembleCommand(set, restricted ? set : null, true);
			if (register != null && !register.isBlank()) {
				Register reg = s.program.getProgramContext().getRegister(register);
				if (reg == null) {
					throw new IllegalArgumentException("Registro desconocido: " + register);
				}
				cmd.setInitialContext(new RegisterValue(reg, new java.math.BigInteger(
					value.trim().replaceFirst("^0[xX]", ""), value.trim().toLowerCase().startsWith("0x") ? 16 : 10)));
			}
			if (!cmd.applyTo(s.program, TaskMonitor.DUMMY)) {
				throw new IllegalStateException("No se pudo desensamblar" +
					(cmd.getStatusMsg() != null ? ": " + cmd.getStatusMsg() : ""));
			}
			return map("instructions", cmd.getDisassembledAddressSet().getNumAddresses());
		});
	}

	// ---------------------------------------------------------------- memory search by value

	private static byte[] number(String text, int size, boolean bigEndian) {
		ByteBuffer buf = ByteBuffer.allocate(8).order(bigEndian ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN);
		String t = text.trim();
		java.math.BigInteger v = t.toLowerCase().startsWith("0x") ? new java.math.BigInteger(t.substring(2), 16)
				: new java.math.BigInteger(t);
		buf.putLong(v.longValue());
		byte[] all = buf.array();
		return bigEndian ? Arrays.copyOfRange(all, 8 - size, 8) : Arrays.copyOfRange(all, 0, size);
	}

	/** Turns a typed value into the bytes to look for. kind: decimal | float | double | string. */
	static byte[] encode(Session s, String kind, String text, int size, String encoding) throws Exception {
		boolean big = s.program.getLanguage().isBigEndian();
		ByteArrayOutputStream out = new ByteArrayOutputStream();
		switch (kind) {
			case "decimal":
				for (String part : text.trim().split("[\\s,]+")) {
					out.write(number(part, Math.max(1, Math.min(8, size)), big));
				}
				break;
			case "float":
				for (String part : text.trim().split("[\\s,]+")) {
					out.write(ByteBuffer.allocate(4).order(big ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN)
							.putFloat(Float.parseFloat(part)).array());
				}
				break;
			case "double":
				for (String part : text.trim().split("[\\s,]+")) {
					out.write(ByteBuffer.allocate(8).order(big ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN)
							.putDouble(Double.parseDouble(part)).array());
				}
				break;
			case "string": {
				Charset cs = switch (encoding == null ? "ascii" : encoding) {
					case "utf8" -> StandardCharsets.UTF_8;
					case "utf16" -> big ? StandardCharsets.UTF_16BE : StandardCharsets.UTF_16LE;
					case "utf32" -> Charset.forName(big ? "UTF-32BE" : "UTF-32LE");
					default -> StandardCharsets.US_ASCII;
				};
				String unescaped = text.replace("\\n", "\n").replace("\\t", "\t").replace("\\0", "\0").replace("\\\\", "\\");
				out.write(unescaped.getBytes(cs));
				break;
			}
			default:
				throw new IllegalArgumentException("Tipo desconocido: " + kind);
		}
		return out.toByteArray();
	}

	static Map<String, Object> searchValue(Session s, String kind, String text, int size, String encoding)
			throws Exception {
		byte[] bytes = encode(s, kind, text, size, encoding);
		if (bytes.length == 0) {
			throw new IllegalArgumentException("Bytes hexadecimales inválidos: " + text);
		}
		String pattern = hex(bytes, 64);
		return map("pattern", pattern, "results", Search.bytes(s, hex(bytes, bytes.length)));
	}

	/** Regular expression over the raw bytes of memory (each byte is one character, ISO-8859-1). */
	static List<Map<String, Object>> searchRegex(Session s, String regex) throws Exception {
		Pattern p = Pattern.compile(regex, Pattern.DOTALL);
		Memory mem = s.program.getMemory();
		FunctionManager fm = s.program.getFunctionManager();
		List<Map<String, Object>> out = new ArrayList<>();
		final int chunk = 1 << 20, overlap = 512;
		for (MemoryBlock block : mem.getBlocks()) {
			if (!block.isInitialized()) {
				continue;
			}
			long size = block.getSize();
			for (long off = 0; off < size && out.size() < 2000; off += chunk) {
				int len = (int) Math.min(chunk + overlap, size - off);
				byte[] buf = new byte[len];
				block.getBytes(block.getStart().add(off), buf);
				Matcher m = p.matcher(new String(buf, StandardCharsets.ISO_8859_1));
				while (m.find() && out.size() < 2000) {
					if (m.start() >= chunk || m.end() == m.start()) {
						if (m.end() == m.start() && m.end() >= len) {
							break;
						}
						if (m.start() >= chunk) {
							break; // belongs to the next chunk
						}
						continue;
					}
					Address a = block.getStart().add(off + m.start());
					Function f = fm.getFunctionContaining(a);
					byte[] found = Arrays.copyOfRange(buf, m.start(), Math.min(m.end(), m.start() + 48));
					out.add(map("address", str(a), "kind", block.getName(),
						"text", printable(found) + "   " + hex(found, 16), "function", f != null ? f.getName(true) : null));
				}
			}
		}
		return out;
	}

	private static String printable(byte[] bytes) {
		StringBuilder sb = new StringBuilder();
		for (byte b : bytes) {
			int c = b & 0xff;
			sb.append(c >= 0x20 && c < 0x7f ? (char) c : '·');
		}
		return sb.toString();
	}

	/** Runs of consecutive pointers into the program (jump tables, vtables, pointer arrays). */
	static List<Map<String, Object>> addressTables(Session s, int minLength) throws Exception {
		Program p = s.program;
		Memory mem = p.getMemory();
		int ptr = p.getDefaultPointerSize();
		boolean big = p.getLanguage().isBigEndian();
		AddressSpace space = p.getAddressFactory().getDefaultAddressSpace();
		List<Map<String, Object>> out = new ArrayList<>();
		for (MemoryBlock block : mem.getBlocks()) {
			if (!block.isInitialized() || block.isExecute() && block.getSize() > 64 << 20) {
				continue;
			}
			long size = block.getSize();
			if (size > 256 << 20) {
				continue;
			}
			byte[] buf = new byte[(int) size];
			block.getBytes(block.getStart(), buf);
			ByteBuffer bb = ByteBuffer.wrap(buf).order(big ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN);
			int run = 0;
			int runStart = 0;
			for (int i = 0; i + ptr <= buf.length + ptr; i += ptr) {
				boolean valid = false;
				if (i + ptr <= buf.length) {
					long v = ptr == 8 ? bb.getLong(i) : ptr == 4 ? bb.getInt(i) & 0xffffffffL : bb.getShort(i) & 0xffffL;
					if (v != 0) {
						try {
							valid = mem.contains(space.getAddress(v));
						}
						catch (Exception e) {
							valid = false;
						}
					}
				}
				if (valid) {
					if (run == 0) {
						runStart = i;
					}
					run++;
				}
				else {
					if (run >= minLength) {
						Address a = block.getStart().add(runStart);
						long first = ptr == 8 ? bb.getLong(runStart) : bb.getInt(runStart) & 0xffffffffL;
						Address target = space.getAddress(first);
						Function f = p.getFunctionManager().getFunctionAt(target);
						out.add(map("address", str(a), "kind", block.getName(), "length", run,
							"text", run + " × " + (f != null ? f.getName() : target.toString()) + "…",
							"function", null, "code", f != null));
						if (out.size() >= 2000) {
							return out;
						}
					}
					run = 0;
				}
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- diff apply

	private static final Object[][] MERGE = {
		{ "Bytes", ProgramMergeFilter.BYTES, ProgramMergeFilter.REPLACE },
		{ "Código/datos", ProgramMergeFilter.CODE_UNITS, ProgramMergeFilter.REPLACE },
		{ "Símbolos", ProgramMergeFilter.SYMBOLS, ProgramMergeFilter.REPLACE },
		{ "Funciones", ProgramMergeFilter.FUNCTIONS, ProgramMergeFilter.REPLACE },
		{ "Comentarios", ProgramMergeFilter.COMMENTS, ProgramMergeFilter.REPLACE },
		{ "Referencias", ProgramMergeFilter.REFERENCES, ProgramMergeFilter.REPLACE },
		{ "Equates", ProgramMergeFilter.EQUATES, ProgramMergeFilter.REPLACE },
		{ "Marcadores", ProgramMergeFilter.BOOKMARKS, ProgramMergeFilter.REPLACE },
		{ "Contexto", ProgramMergeFilter.PROGRAM_CONTEXT, ProgramMergeFilter.REPLACE },
	};

	/** Copies the chosen kinds of differences from the other program onto this one, for the given ranges. */
	static Object applyDiff(Session s, Program other, List<String[]> ranges, Set<String> kinds,
			Map<String, String> settings) throws Exception {
		AddressSet set = new AddressSet();
		for (String[] r : ranges) {
			set.add(s.addr(r[0]), s.addr(r[1]));
		}
		return s.edit("Aplicar diferencias", () -> {
			ProgramMergeManager mgr = new ProgramMergeManager(s.program, other);
			ProgramMergeFilter filter = new ProgramMergeFilter();
			for (Object[] m : MERGE) {
				if (kinds.isEmpty() || kinds.contains(m[0])) {
					String how = settings.getOrDefault((String) m[0], "replace");
					int type = (Integer) m[1];
					// only comments and symbols can be merged; the rest replace
					boolean mergeable = type == ProgramMergeFilter.COMMENTS || type == ProgramMergeFilter.SYMBOLS;
					filter.setFilter(type, how.equals("ignore") ? ProgramMergeFilter.IGNORE
							: how.equals("merge") && mergeable ? ProgramMergeFilter.MERGE : (Integer) m[2]);
				}
			}
			mgr.merge(set, filter, TaskMonitor.DUMMY);
			return map("applied", set.getNumAddresses(), "error", mgr.getErrorMessage(), "info", mgr.getInfoMessage());
		});
	}

	// ---------------------------------------------------------------- decompiler

	static Object commitParams(Session s, HighFunction hf) throws Exception {
		return s.edit("Fijar parámetros y retorno", () -> {
			HighFunctionDBUtil.commitParamsToDatabase(hf, true, HighFunctionDBUtil.ReturnCommitOption.COMMIT,
				SourceType.USER_DEFINED);
			return true;
		});
	}

	static Object commitLocals(Session s, HighFunction hf) throws Exception {
		return s.edit("Fijar nombres de variables locales", () -> {
			HighFunctionDBUtil.commitLocalNamesToDatabase(hf, SourceType.USER_DEFINED);
			return true;
		});
	}

	/** The union access behind a field token: which p-code op / slot reads the union, as Ghidra's Force Field does. */
	private static final class Facet {
		Union union;
		DataType parent;
		PcodeOp op;
		Varnode vn;
		int slot;
	}

	private static DataType unionRelated(Varnode vn, Union union) {
		if (vn == null || vn.getHigh() == null) {
			return null;
		}
		HighVariable high = vn.getHigh();
		DataType dt = high.getDataType();
		if (dt instanceof TypeDef td) {
			dt = td.getBaseDataType();
		}
		DataType inner = dt;
		if (inner instanceof Pointer ptr) {
			inner = ptr.getDataType();
		}
		else if (inner instanceof PartialUnion pu) {
			inner = pu.getParent();
			if (inner instanceof TypeDef td) {
				inner = td.getBaseDataType();
			}
		}
		if (inner == union) {
			return dt;
		}
		HighSymbol symbol = high.getSymbol();
		if (symbol == null) {
			return null;
		}
		dt = symbol.getDataType();
		if (dt instanceof TypeDef td) {
			dt = td.getBaseDataType();
		}
		return dt == union ? dt : null;
	}

	private static Facet facet(ghidra.app.decompiler.ClangToken token) {
		if (!(token instanceof ghidra.app.decompiler.ClangFieldToken field)) {
			return null;
		}
		DataType owner = field.getDataType();
		if (owner instanceof TypeDef td) {
			owner = td.getBaseDataType();
		}
		if (!(owner instanceof Union union)) {
			return null;
		}
		Facet f = new Facet();
		f.union = union;
		f.op = token.getPcodeOp();
		if (f.op == null) {
			return null;
		}
		int opcode = f.op.getOpcode();
		if (opcode == PcodeOp.PTRSUB) {
			f.parent = unionRelated(f.op.getInput(0), union);
			if (f.parent != null) {
				f.vn = f.op.getInput(0);
				f.slot = 0;
				if (f.op.getInput(1).getOffset() == 0) {
					do {
						Varnode out = f.op.getOutput();
						PcodeOp next = out.getLoneDescend();
						if (next == null) {
							break;
						}
						f.op = next;
						f.vn = out;
						f.slot = f.op.getSlot(f.vn);
					}
					while (f.op.getOpcode() == PcodeOp.PTRSUB && f.op.getInput(1).getOffset() == 0);
				}
				return f;
			}
		}
		else {
			for (f.slot = 0; f.slot < f.op.getNumInputs(); ++f.slot) {
				f.vn = f.op.getInput(f.slot);
				f.parent = unionRelated(f.vn, union);
				if (f.parent != null) {
					break;
				}
			}
			if (f.parent != null) {
				if (opcode == PcodeOp.SUBPIECE && f.slot == 0 && !(f.parent instanceof Pointer)) {
					f.slot = -1;
					f.vn = f.op.getOutput();
				}
				return f;
			}
		}
		f.slot = -1;
		f.vn = f.op.getOutput();
		if (f.vn != null) {
			f.parent = unionRelated(f.vn, union);
			if (f.parent != null) {
				return f;
			}
		}
		return null;
	}

	static boolean isUnionField(ghidra.app.decompiler.ClangToken token) {
		return token instanceof ghidra.app.decompiler.ClangFieldToken field &&
			(field.getDataType() instanceof Union ||
				field.getDataType() instanceof TypeDef td && td.getBaseDataType() instanceof Union);
	}

	/** Fields of the union that could be used at this access; index -1 = let the decompiler choose. */
	static Map<String, Object> unionFields(ghidra.app.decompiler.ClangToken token) {
		Facet f = facet(token);
		if (f == null) {
			throw new IllegalArgumentException("Coloca el cursor sobre un campo de una unión");
		}
		int size = f.parent instanceof Pointer ? 0 : f.vn.getSize();
		int startOff = 0;
		boolean exact = true;
		if (f.parent instanceof PartialUnion pu) {
			startOff = pu.getOffset();
			exact = false;
		}
		int endOff = startOff + size;
		List<Map<String, Object>> choices = new ArrayList<>();
		if (size == 0 || !exact || size == f.parent.getLength()) {
			choices.add(map("index", -1, "name", "(sin campo)", "type", ""));
		}
		DataTypeComponent[] comps = f.union.getDefinedComponents();
		for (int i = 0; i < comps.length; i++) {
			DataTypeComponent c = comps[i];
			String name = c.getFieldName() == null || c.getFieldName().isEmpty() ? c.getDefaultFieldName() : c.getFieldName();
			int cs = c.getOffset();
			int ce = cs + c.getLength();
			if (size == 0 || exact && startOff == cs && endOff == ce || !exact && startOff >= cs && endOff <= ce) {
				choices.add(map("index", i, "name", name, "type", c.getDataType().getDisplayName()));
			}
		}
		return map("union", f.union.getName(), "current", token.getText(), "choices", choices);
	}

	static Object forceUnion(Session s, Function fn, HighFunction hf, ghidra.app.decompiler.ClangToken token,
			int fieldIndex) throws Exception {
		Facet f = facet(token);
		if (f == null) {
			throw new IllegalArgumentException("Coloca el cursor sobre un campo de una unión");
		}
		DynamicHash hash = new DynamicHash(f.op, f.slot, hf);
		Address pc = hash.getAddress();
		if (pc == null || pc == Address.NO_ADDRESS) {
			throw new IllegalStateException("No se pudo identificar la operación de forma única");
		}
		return s.edit("Forzar campo de unión", () -> {
			HighFunctionDBUtil.writeUnionFacet(fn, f.parent, fieldIndex, pc, hash.getHash(), SourceType.USER_DEFINED);
			return true;
		});
	}

	// ---------------------------------------------------------------- stack frame

	static Map<String, Object> stackFrame(Session s, Address address) {
		Function fn = s.functionContaining(address);
		StackFrame frame = fn.getStackFrame();
		List<Map<String, Object>> vars = new ArrayList<>();
		for (Variable v : frame.getStackVariables()) {
			vars.add(map("offset", v.getStackOffset(), "length", v.getLength(), "name", v.getName(),
				"type", v.getDataType().getDisplayName(), "parameter", v instanceof Parameter,
				"comment", v.getComment()));
		}
		vars.sort(Comparator.comparingInt(o -> (Integer) o.get("offset")));
		return map("function", fn.getName(), "entry", str(fn.getEntryPoint()), "frameSize", frame.getFrameSize(),
			"localSize", frame.getLocalSize(), "parameterSize", frame.getParameterSize(),
			"parameterOffset", frame.getParameterOffset(), "returnAddressOffset", frame.getReturnAddressOffset(),
			"growsNegative", frame.growsNegative(), "variables", vars);
	}

	static Object stackDefine(Session s, Address address, int offset, String name, String type) throws Exception {
		Function fn = s.functionContaining(address);
		DataType dt = Types.parse(s.program, type);
		s.edit("Definir variable de pila", () -> {
			StackFrame frame = fn.getStackFrame();
			Variable existing = frame.getVariableContaining(offset);
			if (existing != null && existing.getStackOffset() == offset) {
				if (name != null && !name.isBlank() && !name.equals(existing.getName())) {
					existing.setName(name, SourceType.USER_DEFINED);
				}
				existing.setDataType(dt, true, true, SourceType.USER_DEFINED);
			}
			else {
				frame.createVariable(name == null || name.isBlank() ? null : name, offset, dt, SourceType.USER_DEFINED);
			}
			return null;
		});
		return stackFrame(s, address);
	}

	static Object stackClear(Session s, Address address, int offset) throws Exception {
		Function fn = s.functionContaining(address);
		s.edit("Borrar variable de pila", () -> {
			fn.getStackFrame().clearVariable(offset);
			return null;
		});
		return stackFrame(s, address);
	}

	static Object stackSizes(Session s, Address address, Integer localSize, Integer returnOffset) throws Exception {
		Function fn = s.functionContaining(address);
		s.edit("Tamaño del marco de pila", () -> {
			if (localSize != null) {
				fn.getStackFrame().setLocalSize(localSize);
			}
			if (returnOffset != null) {
				fn.getStackFrame().setReturnAddressOffset(returnOffset);
			}
			return null;
		});
		return stackFrame(s, address);
	}

	// ---------------------------------------------------------------- data types

	/** Writes the given program types (with everything they depend on) into a .gdt archive, creating it if needed. */
	static Object exportTypes(Session s, String path, List<String> typePaths) throws Exception {
		File file = new File(path.endsWith(".gdt") ? path : path + ".gdt");
		FileDataTypeManager archive = file.exists() ? FileDataTypeManager.openFileArchive(file, true)
				: FileDataTypeManager.createFileArchive(file);
		try {
			int tx = archive.startTransaction("Ghidra Studio");
			int added = 0;
			try {
				DataTypeManager dtm = s.program.getDataTypeManager();
				for (String p : typePaths) {
					DataType dt = dtm.getDataType(p);
					if (dt == null) {
						throw new IllegalArgumentException("No existe el tipo " + p);
					}
					archive.addDataType(dt, DataTypeConflictHandler.REPLACE_HANDLER);
					added++;
				}
			}
			finally {
				archive.endTransaction(tx, true);
			}
			archive.save();
			return map("path", file.getAbsolutePath(), "added", added, "total", archive.getDataTypeCount(true));
		}
		finally {
			archive.close();
		}
	}

	/** Creates or replaces a function-definition data type from a C prototype. */
	static Object functionDefinition(Session s, String signature, String category) throws Exception {
		return s.edit("Definición de función", () -> {
			DataTypeManager dtm = s.program.getDataTypeManager();
			FunctionSignatureParser parser = new FunctionSignatureParser(dtm, null);
			FunctionDefinitionDataType def = parser.parse(null, signature);
			CategoryPath cat = category == null || category.isBlank() || category.equals("/") ? CategoryPath.ROOT
					: new CategoryPath(category);
			def.setCategoryPath(cat);
			DataType resolved = dtm.addDataType(def, DataTypeConflictHandler.REPLACE_HANDLER);
			return map("path", resolved.getPathName(), "name", resolved.getName());
		});
	}

	// ---------------------------------------------------------------- checksums, entropy, source files

	private static String digest(String algorithm, byte[] data) throws Exception {
		StringBuilder sb = new StringBuilder();
		for (byte b : MessageDigest.getInstance(algorithm).digest(data)) {
			sb.append(String.format("%02x", b & 0xff));
		}
		return sb.toString();
	}

	/** Checksums of [start, end], or of all initialized memory when no range is given. */
	static Map<String, Object> checksums(Session s, Address start, Address end) throws Exception {
		Memory mem = s.program.getMemory();
		AddressSetView set = start != null ? mem.getLoadedAndInitializedAddressSet().intersectRange(start, end)
				: mem.getLoadedAndInitializedAddressSet();
		long total = set.getNumAddresses();
		if (total > 512L << 20) {
			throw new IllegalArgumentException("El rango es demasiado grande");
		}
		ByteArrayOutputStream out = new ByteArrayOutputStream((int) total);
		for (AddressRange r : set) {
			byte[] buf = new byte[(int) r.getLength()];
			mem.getBytes(r.getMinAddress(), buf);
			out.write(buf);
		}
		byte[] data = out.toByteArray();
		long sum8 = 0, sum16 = 0, sum32 = 0;
		boolean big = s.program.getLanguage().isBigEndian();
		for (int i = 0; i < data.length; i++) {
			sum8 += data[i] & 0xff;
			int shift16 = big ? (1 - i % 2) * 8 : (i % 2) * 8;
			sum16 += (long) (data[i] & 0xff) << shift16;
			int shift32 = big ? (3 - i % 4) * 8 : (i % 4) * 8;
			sum32 += (long) (data[i] & 0xff) << shift32;
		}
		CRC32 crc = new CRC32();
		crc.update(data);
		Adler32 adler = new Adler32();
		adler.update(data);
		List<Map<String, Object>> rows = new ArrayList<>();
		rows.add(map("name", "Checksum-8", "value", String.format("%02x", sum8 & 0xff)));
		rows.add(map("name", "Checksum-16", "value", String.format("%04x", sum16 & 0xffff)));
		rows.add(map("name", "Checksum-32", "value", String.format("%08x", sum32 & 0xffffffffL)));
		rows.add(map("name", "CRC-32", "value", String.format("%08x", crc.getValue())));
		rows.add(map("name", "Adler-32", "value", String.format("%08x", adler.getValue())));
		rows.add(map("name", "MD5", "value", digest("MD5", data)));
		rows.add(map("name", "SHA-1", "value", digest("SHA-1", data)));
		rows.add(map("name", "SHA-256", "value", digest("SHA-256", data)));
		return map("bytes", data.length, "checksums", rows,
			"range", start != null ? start + " – " + end : null);
	}

	/** Shannon entropy (0–8 bits per byte) of each chunk of every initialized block. */
	static List<Map<String, Object>> entropy(Session s, int chunk) throws Exception {
		int size = Math.max(64, chunk);
		List<Map<String, Object>> out = new ArrayList<>();
		for (MemoryBlock block : s.program.getMemory().getBlocks()) {
			if (!block.isInitialized() || block.getSize() > 256L << 20) {
				continue;
			}
			// keep each block to a manageable number of points
			int step = size;
			while (block.getSize() / step > 4000) {
				step *= 2;
			}
			List<Double> values = new ArrayList<>();
			byte[] buf = new byte[step];
			for (long off = 0; off < block.getSize(); off += step) {
				int len = (int) Math.min(step, block.getSize() - off);
				block.getBytes(block.getStart().add(off), buf, 0, len);
				int[] counts = new int[256];
				for (int i = 0; i < len; i++) {
					counts[buf[i] & 0xff]++;
				}
				double h = 0;
				for (int c : counts) {
					if (c > 0) {
						double p = (double) c / len;
						h -= p * Math.log(p) / Math.log(2);
					}
				}
				values.add(Math.round(h * 100) / 100.0);
			}
			double avg = values.stream().mapToDouble(Double::doubleValue).average().orElse(0);
			out.add(map("block", block.getName(), "start", str(block.getStart()), "size", block.getSize(),
				"chunk", step, "average", Math.round(avg * 100) / 100.0, "values", values));
		}
		return out;
	}

	// ---------------------------------------------------------------- PDB from a symbol server

	/** The PDB a Windows program was built with (name + GUID/age), or null when it has none. */
	static Map<String, Object> pdbInfo(Session s) {
		pdb.symbolserver.SymbolFileInfo info = pdb.symbolserver.SymbolFileInfo.fromProgramInfo(s.program);
		if (info == null) {
			return map("available", false);
		}
		return map("available", true, "name", info.getName(), "id", info.getUniqifierString(),
			"description", info.getDescription());
	}

	/** Looks the program's PDB up in a symbol server, stores it locally and returns the downloaded file. */
	static File pdbDownload(Session s, File storeDir, String serverUrl, TaskMonitor monitor) throws Exception {
		pdb.symbolserver.SymbolFileInfo info = pdb.symbolserver.SymbolFileInfo.fromProgramInfo(s.program);
		if (info == null) {
			throw new IllegalStateException("El programa no indica qué PDB le corresponde");
		}
		if (!pdb.symbolserver.LocalSymbolStore.isLocalSymbolStoreLocation(storeDir.getPath()) || !storeDir.isDirectory()) {
			storeDir.mkdirs();
			pdb.symbolserver.LocalSymbolStore.create(storeDir, 1);
		}
		pdb.symbolserver.LocalSymbolStore store = new pdb.symbolserver.LocalSymbolStore(storeDir);
		pdb.symbolserver.SymbolServerService service = new pdb.symbolserver.SymbolServerService(store,
			List.of(new pdb.symbolserver.HttpSymbolServer(java.net.URI.create(serverUrl.endsWith("/") ? serverUrl : serverUrl + "/"))));
		List<pdb.symbolserver.SymbolFileLocation> found = service.find(info,
			pdb.symbolserver.FindOption.of(pdb.symbolserver.FindOption.ALLOW_UNTRUSTED), monitor);
		if (found.isEmpty()) {
			throw new java.io.FileNotFoundException("El servidor de símbolos no tiene " + info.getName());
		}
		return service.getSymbolFile(found.get(0), monitor);
	}

	static List<Map<String, Object>> sourceFiles(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		ghidra.program.model.sourcemap.SourceFileManager mgr = s.program.getSourceFileManager();
		for (SourceFile f : mgr.getAllSourceFiles()) {
			List<SourceMapEntry> entries = mgr.getSourceMapEntries(f);
			Address first = null;
			for (SourceMapEntry e : entries) {
				if (first == null || e.getBaseAddress().compareTo(first) < 0) {
					first = e.getBaseAddress();
				}
			}
			out.add(map("path", f.getPath(), "name", f.getFilename(), "entries", entries.size(),
				"address", str(first)));
		}
		out.sort(Comparator.comparing(o -> (String) o.get("path")));
		return out;
	}

	static List<Map<String, Object>> sourceLines(Session s, String path) {
		ghidra.program.model.sourcemap.SourceFileManager mgr = s.program.getSourceFileManager();
		List<Map<String, Object>> out = new ArrayList<>();
		for (SourceFile f : mgr.getAllSourceFiles()) {
			if (!f.getPath().equals(path)) {
				continue;
			}
			for (SourceMapEntry e : mgr.getSourceMapEntries(f)) {
				out.add(map("line", e.getLineNumber(), "address", str(e.getBaseAddress()), "length", e.getLength()));
				if (out.size() >= 20000) {
					break;
				}
			}
		}
		out.sort(Comparator.comparingInt(o -> (Integer) o.get("line")));
		return out;
	}
}
