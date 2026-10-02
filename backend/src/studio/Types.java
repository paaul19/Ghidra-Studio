package studio;

import static studio.Json.*;

import java.io.StringWriter;
import java.util.*;

import ghidra.app.services.DataTypeQueryService;
import ghidra.program.model.data.*;
import ghidra.program.model.data.Enum;
import ghidra.program.model.listing.Program;
import ghidra.util.data.DataTypeParser;
import ghidra.util.task.TaskMonitor;

/** Data type manager: browse, inspect, create and edit types. */
final class Types {
	private Types() {
	}

	static DataType parse(Program program, String text) throws Exception {
		DataTypeParser parser = new DataTypeParser(program.getDataTypeManager(),
			BuiltInDataTypeManager.getDataTypeManager(), new QueryService(program),
			DataTypeParser.AllowedDataTypes.ALL);
		DataType dt = parser.parse(text.trim());
		if (dt == null) {
			throw new IllegalArgumentException("Tipo desconocido: " + text);
		}
		return dt;
	}

	/** Minimal lookup service so parsers can resolve names without a GUI tool. */
	static final class QueryService implements DataTypeQueryService {
		private final Program program;

		QueryService(Program program) {
			this.program = program;
		}

		private List<DataType> all() {
			List<DataType> list = new ArrayList<>();
			program.getDataTypeManager().getAllDataTypes(list);
			BuiltInDataTypeManager.getDataTypeManager().getAllDataTypes(list);
			return list;
		}

		@Override
		public List<DataType> getSortedDataTypeList() {
			List<DataType> list = all();
			list.sort(Comparator.comparing(DataType::getName));
			return list;
		}

		@Override
		public List<CategoryPath> getSortedCategoryPathList() {
			return List.of();
		}

		@Override
		public DataType getDataType(String name) {
			List<DataType> found = findDataTypes(name, TaskMonitor.DUMMY);
			return found.isEmpty() ? null : found.get(0);
		}

		@Override
		public DataType promptForDataType(String name) {
			return getDataType(name);
		}

		@Override
		public List<DataType> findDataTypes(String name, TaskMonitor monitor) {
			List<DataType> list = new ArrayList<>();
			program.getDataTypeManager().findDataTypes(name, list);
			if (list.isEmpty()) {
				BuiltInDataTypeManager.getDataTypeManager().findDataTypes(name, list);
			}
			return list;
		}

		@Override
		public List<DataType> getDataTypesByPath(DataTypePath path) {
			DataType dt = program.getDataTypeManager().getDataType(path);
			return dt != null ? List.of(dt) : List.of();
		}

		@Override
		public DataType getProgramDataTypeByPath(DataTypePath path) {
			return program.getDataTypeManager().getDataType(path);
		}
	}

	static String kind(DataType dt) {
		if (dt instanceof Structure) return "struct";
		if (dt instanceof Union) return "union";
		if (dt instanceof Enum) return "enum";
		if (dt instanceof TypeDef) return "typedef";
		if (dt instanceof Pointer) return "pointer";
		if (dt instanceof Array) return "array";
		if (dt instanceof FunctionDefinition) return "function";
		return "builtin";
	}

	static List<Map<String, Object>> list(Program program, String filter, boolean includeBuiltins) {
		List<Map<String, Object>> out = new ArrayList<>();
		String f = filter == null ? "" : filter.toLowerCase();
		List<DataType> all = new ArrayList<>();
		program.getDataTypeManager().getAllDataTypes(all);
		int programCount = all.size();
		if (includeBuiltins) {
			BuiltInDataTypeManager.getDataTypeManager().getAllDataTypes(all);
		}
		for (int i = 0; i < all.size() && out.size() < 5000; i++) {
			DataType dt = all.get(i);
			if (dt instanceof Pointer || dt instanceof Array) {
				continue;
			}
			if (!f.isEmpty() && !dt.getName().toLowerCase().contains(f)) {
				continue;
			}
			out.add(map("path", dt.getPathName(), "name", dt.getName(), "category", dt.getCategoryPath().getPath(),
				"kind", kind(dt), "size", dt.getLength(), "builtin", i >= programCount));
		}
		out.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
		return out;
	}

	static DataType find(Program program, String path) {
		DataTypePath dtp = toPath(path);
		DataType dt = program.getDataTypeManager().getDataType(dtp);
		if (dt == null) {
			dt = BuiltInDataTypeManager.getDataTypeManager().getDataType(dtp);
		}
		if (dt == null) {
			throw new IllegalArgumentException("No existe el tipo " + path);
		}
		return dt;
	}

	private static DataTypePath toPath(String path) {
		int slash = path.lastIndexOf('/');
		String cat = slash <= 0 ? "/" : path.substring(0, slash);
		return new DataTypePath(new CategoryPath(cat), path.substring(slash + 1));
	}

	static Map<String, Object> detail(Program program, String path) throws Exception {
		return describe(program, find(program, path));
	}

	/** What the interface shows of a type; also used for the working copy of the structure editor. */
	static Map<String, Object> describe(Program program, DataType dt) {
		Map<String, Object> m = map("path", dt.getPathName(), "name", dt.getName(), "kind", kind(dt),
			"size", dt.getLength(), "description", dt.getDescription(),
			"editable", dt.getDataTypeManager() == program.getDataTypeManager());
		if (dt instanceof Composite comp) {
			m.put("packed", comp.isPackingEnabled());
			m.put("packValue", comp.hasExplicitPackingValue() ? comp.getExplicitPackingValue() : 0);
			m.put("alignment", comp.getAlignment());
		}
		List<Map<String, Object>> fields = new ArrayList<>();
		if (dt instanceof Composite c) {
			for (DataTypeComponent comp : c.getDefinedComponents()) {
				String type = comp.getDataType().getDisplayName();
				if (comp.isBitFieldComponent() && comp.getDataType() instanceof BitFieldDataType bf) {
					type = bf.getBaseDataType().getDisplayName() + " : " + bf.getDeclaredBitSize();
				}
				fields.add(map("ordinal", comp.getOrdinal(), "offset", comp.getOffset(), "length", comp.getLength(),
					"type", type, "name", comp.getFieldName(), "comment", comp.getComment()));
			}
		}
		else if (dt instanceof Enum e) {
			for (String n : e.getNames()) {
				fields.add(map("name", n, "value", e.getValue(n), "comment", e.getComment(n)));
			}
		}
		else if (dt instanceof TypeDef td) {
			m.put("base", td.getBaseDataType().getDisplayName());
		}
		m.put("fields", fields);
		StringWriter w = new StringWriter();
		try {
			new DataTypeWriter(program.getDataTypeManager(), w).write(List.of(dt), TaskMonitor.DUMMY, false);
			m.put("c", w.toString().trim());
		}
		catch (Exception e) {
			m.put("c", null);
		}
		return m;
	}

	static Object createStruct(Session s, String name, String category, boolean union) throws Exception {
		return s.edit(union ? "Crear unión" : "Crear estructura", () -> {
			CategoryPath cat = new CategoryPath(category == null || category.isBlank() ? "/" : category);
			DataType dt = union ? new UnionDataType(cat, name) : new StructureDataType(cat, name, 0);
			DataType added = s.program.getDataTypeManager().addDataType(dt, DataTypeConflictHandler.DEFAULT_HANDLER);
			return map("path", added.getPathName());
		});
	}

	static Object createEnum(Session s, String name, String category, int size) throws Exception {
		return s.edit("Crear enum", () -> {
			CategoryPath cat = new CategoryPath(category == null || category.isBlank() ? "/" : category);
			DataType added = s.program.getDataTypeManager().addDataType(new EnumDataType(cat, name, size),
				DataTypeConflictHandler.DEFAULT_HANDLER);
			return map("path", added.getPathName());
		});
	}

	static Object createTypedef(Session s, String name, String baseType) throws Exception {
		DataType base = parse(s.program, baseType);
		return s.edit("Crear typedef", () -> {
			DataType added = s.program.getDataTypeManager().addDataType(
				new TypedefDataType(CategoryPath.ROOT, name, base), DataTypeConflictHandler.DEFAULT_HANDLER);
			return map("path", added.getPathName());
		});
	}

	private static Composite composite(Session s, String path) {
		DataType dt = find(s.program, path);
		if (!(dt instanceof Composite c) || dt.getDataTypeManager() != s.program.getDataTypeManager()) {
			throw new IllegalArgumentException("Solo se pueden editar estructuras y uniones del programa");
		}
		return c;
	}

	static Object addField(Session s, String path, String type, String name, String comment) throws Exception {
		Composite c = composite(s, path);
		DataType dt = parse(s.program, type);
		return s.edit("Añadir campo", () -> {
			c.add(dt, dt.getLength() > 0 ? dt.getLength() : 1, name, comment);
			return true;
		});
	}

	static Object editField(Session s, String path, int ordinal, String type, String name, String comment)
			throws Exception {
		Composite c = composite(s, path);
		DataType dt = type != null && !type.isBlank() ? parse(s.program, type) : null;
		return s.edit("Editar campo", () -> {
			DataTypeComponent comp = c.getComponent(ordinal);
			if (dt != null && !dt.isEquivalent(comp.getDataType())) {
				if (c instanceof Structure st) {
					st.replace(ordinal, dt, dt.getLength() > 0 ? dt.getLength() : comp.getLength(),
						name != null ? name : comp.getFieldName(), comment != null ? comment : comp.getComment());
					return true;
				}
				c.delete(ordinal);
				c.insert(ordinal, dt, dt.getLength(), name, comment);
				return true;
			}
			if (name != null) {
				comp.setFieldName(name.isBlank() ? null : name);
			}
			if (comment != null) {
				comp.setComment(comment.isBlank() ? null : comment);
			}
			return true;
		});
	}

	static Object deleteField(Session s, String path, int ordinal) throws Exception {
		Composite c = composite(s, path);
		return s.edit("Borrar campo", () -> {
			c.delete(ordinal);
			return true;
		});
	}

	static Object addEnumValue(Session s, String path, String name, long value) throws Exception {
		DataType dt = find(s.program, path);
		if (!(dt instanceof Enum e)) {
			throw new IllegalArgumentException("No es un enum");
		}
		return s.edit("Añadir valor", () -> {
			e.add(name, value);
			return true;
		});
	}

	private static Structure structure(Session s, String path) {
		if (composite(s, path) instanceof Structure st) {
			return st;
		}
		throw new IllegalArgumentException("Solo disponible para estructuras");
	}

	static Object insertField(Session s, String path, int offset, String type, String name, String comment)
			throws Exception {
		Structure st = structure(s, path);
		DataType dt = parse(s.program, type);
		return s.edit("Insertar campo", () -> {
			int len = dt.getLength() > 0 ? dt.getLength() : 1;
			if (st.isPackingEnabled() || offset >= st.getLength()) {
				st.insertAtOffset(offset, dt, len, name, comment);
			}
			else {
				st.replaceAtOffset(offset, dt, len, name, comment);
			}
			return true;
		});
	}

	static Object moveField(Session s, String path, int ordinal, int delta) throws Exception {
		Composite c = composite(s, path);
		return s.edit("Mover campo", () -> {
			int target = ordinal + delta;
			if (target < 0 || target >= c.getNumComponents()) {
				return false;
			}
			DataTypeComponent comp = c.getComponent(ordinal);
			DataType dt = comp.getDataType();
			int len = comp.getLength();
			String name = comp.getFieldName();
			String comment = comp.getComment();
			c.delete(ordinal);
			c.insert(target, dt, len, name, comment);
			return true;
		});
	}

	static Object addBitField(Session s, String path, String baseType, int bits, String name) throws Exception {
		Composite c = composite(s, path);
		DataType dt = parse(s.program, baseType);
		return s.edit("Añadir campo de bits", () -> {
			c.addBitField(dt, bits, name, null);
			return true;
		});
	}

	static Object setPacking(Session s, String path, boolean enabled, int value) throws Exception {
		Composite c = composite(s, path);
		return s.edit("Empaquetado", () -> {
			if (!enabled) {
				c.setPackingEnabled(false);
			}
			else if (value > 0) {
				c.setExplicitPackingValue(value);
			}
			else {
				c.setToDefaultPacking();
			}
			return true;
		});
	}

	static Object setAlignment(Session s, String path, int value) throws Exception {
		Composite c = composite(s, path);
		return s.edit("Alineación", () -> {
			if (value > 0) {
				c.setExplicitMinimumAlignment(value);
			}
			else {
				c.setToDefaultAligned();
			}
			return true;
		});
	}

	static Object setStructSize(Session s, String path, int size) throws Exception {
		Structure st = structure(s, path);
		return s.edit("Tamaño de estructura", () -> {
			st.setLength(size);
			return true;
		});
	}

	static Object removeEnumValue(Session s, String path, String name) throws Exception {
		DataType dt = find(s.program, path);
		if (!(dt instanceof Enum e)) {
			throw new IllegalArgumentException("No es un enum");
		}
		return s.edit("Quitar valor", () -> {
			e.remove(name);
			return true;
		});
	}

	/** Types contained in a .gdt archive. */
	static List<Map<String, Object>> archiveTypes(String path, String filter) throws Exception {
		FileDataTypeManager dtm = FileDataTypeManager.openFileArchive(new java.io.File(path), false);
		try {
			String f = filter == null ? "" : filter.toLowerCase();
			List<DataType> all = new ArrayList<>();
			dtm.getAllDataTypes(all);
			List<Map<String, Object>> out = new ArrayList<>();
			for (DataType dt : all) {
				if (out.size() >= 3000) {
					break;
				}
				if (dt instanceof Pointer || dt instanceof Array || (!f.isEmpty() && !dt.getName().toLowerCase().contains(f))) {
					continue;
				}
				out.add(map("path", dt.getPathName(), "name", dt.getName(), "category", dt.getCategoryPath().getPath(),
					"kind", kind(dt), "size", dt.getLength(), "builtin", false));
			}
			out.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
			return out;
		}
		finally {
			dtm.close();
		}
	}

	/** Copies types (with their dependencies) from a .gdt archive into the program. */
	static Object importArchiveTypes(Session s, String path, List<String> typePaths) throws Exception {
		FileDataTypeManager dtm = FileDataTypeManager.openFileArchive(new java.io.File(path), false);
		try {
			return s.edit("Importar tipos", () -> {
				int n = 0;
				for (String tp : typePaths) {
					DataType dt = dtm.getDataType(toPath(tp));
					if (dt != null) {
						s.program.getDataTypeManager().resolve(dt, DataTypeConflictHandler.DEFAULT_HANDLER);
						n++;
					}
				}
				return map("applied", n);
			});
		}
		finally {
			dtm.close();
		}
	}

	static Object renameType(Session s, String path, String newName) throws Exception {
		DataType dt = find(s.program, path);
		return s.edit("Renombrar tipo", () -> {
			dt.setName(newName);
			return map("path", dt.getPathName());
		});
	}

	static Object deleteType(Session s, String path) throws Exception {
		DataType dt = find(s.program, path);
		return s.edit("Borrar tipo", () -> s.program.getDataTypeManager().remove(dt));
	}

	/** Bundled Ghidra type archives (.gdt): libc, macOS, Windows, Go, Rust... */
	static List<Map<String, Object>> archives() throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		java.io.File base = ghidra.framework.Application.getModuleDataSubDirectory("Base", "typeinfo").getFile(false);
		collect(base, base, out);
		out.sort(Comparator.comparing(o -> (String) o.get("name")));
		return out;
	}

	private static void collect(java.io.File root, java.io.File dir, List<Map<String, Object>> out) {
		java.io.File[] files = dir.listFiles();
		if (files == null) {
			return;
		}
		for (java.io.File f : files) {
			if (f.isDirectory()) {
				collect(root, f, out);
			}
			else if (f.getName().endsWith(".gdt")) {
				out.add(map("name", root.toPath().relativize(f.toPath()).toString(), "path", f.getAbsolutePath()));
			}
		}
	}

	/** Applies the function signatures of an archive to matching functions (like "Apply Function Data Types"). */
	static Object applyArchive(Session s, String path) throws Exception {
		FileDataTypeManager dtm = FileDataTypeManager.openFileArchive(new java.io.File(path), false);
		try {
			return s.edit("Aplicar archivo de tipos", () -> {
				int before = countTyped(s);
				ghidra.app.cmd.function.ApplyFunctionDataTypesCmd cmd =
					new ghidra.app.cmd.function.ApplyFunctionDataTypesCmd(List.of(dtm), null,
						ghidra.program.model.symbol.SourceType.IMPORTED, false, false);
				cmd.applyTo(s.program, TaskMonitor.DUMMY);
				return map("applied", Math.max(0, countTyped(s) - before));
			});
		}
		finally {
			dtm.close();
		}
	}

	private static int countTyped(Session s) {
		int n = 0;
		for (ghidra.program.model.listing.Function f : s.program.getFunctionManager().getFunctions(true)) {
			if (f.getSignatureSource() != ghidra.program.model.symbol.SourceType.DEFAULT) {
				n++;
			}
		}
		return n;
	}

	/** Parses C declarations (struct/enum/typedef...) into the program's type manager. */
	static Object parseC(Session s, String source) throws Exception {
		return s.edit("Importar C", () -> {
			ghidra.app.util.cparser.C.CParser parser = new ghidra.app.util.cparser.C.CParser(
				s.program.getDataTypeManager(), true, null);
			parser.parse(source);
			return map("types", parser.getComposites().size() + parser.getTypes().size() + parser.getEnums().size());
		});
	}
}
