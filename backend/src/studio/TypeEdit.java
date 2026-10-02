package studio;

import static studio.Json.*;

import java.util.*;

import com.google.gson.JsonObject;

import ghidra.program.model.data.*;

/**
 * Structure editor sessions, like the classic's: edits go to a working copy with its own undo and redo,
 * and reach the program only when applied (as one program transaction).
 */
final class TypeEdit {
	private TypeEdit() {
	}

	private static final class Editor {
		String id;
		Composite original;
		Composite working;
		final Deque<Composite> undo = new ArrayDeque<>();
		final Deque<Composite> redo = new ArrayDeque<>();
	}

	private static final Map<String, Editor> EDITORS = new LinkedHashMap<>();

	private static Editor editor(String id) {
		Editor e = EDITORS.get(id);
		if (e == null) {
			throw new IllegalArgumentException("La edición de la estructura ya no existe");
		}
		return e;
	}

	private static Composite copy(Session s, Composite c) {
		return (Composite) c.copy(s.program.getDataTypeManager());
	}

	private static Map<String, Object> state(Session s, Editor e) {
		Map<String, Object> m = Types.describe(s.program, e.working);
		m.put("path", e.original.getPathName());
		m.put("editable", true);
		m.put("editor", e.id);
		m.put("canUndo", !e.undo.isEmpty());
		m.put("canRedo", !e.redo.isEmpty());
		m.put("dirty", !e.working.isEquivalent(e.original) || !Objects.equals(e.working.getDescription(),
			e.original.getDescription()) || !e.working.getName().equals(e.original.getName()));
		return m;
	}

	static Map<String, Object> begin(Session s, String path) {
		DataType dt = Types.find(s.program, path);
		if (!(dt instanceof Composite c) || dt.getDataTypeManager() != s.program.getDataTypeManager()) {
			throw new IllegalArgumentException("Solo se pueden editar estructuras y uniones del programa");
		}
		Editor e = new Editor();
		e.id = UUID.randomUUID().toString();
		e.original = c;
		e.working = copy(s, c);
		EDITORS.put(e.id, e);
		return state(s, e);
	}

	static Map<String, Object> current(Session s, String id) {
		return state(s, editor(id));
	}

	private static Structure structure(Composite c) {
		if (c instanceof Structure st) {
			return st;
		}
		throw new IllegalArgumentException("Solo disponible para estructuras");
	}

	private static String str(JsonObject p, String key) {
		return p.has(key) && !p.get(key).isJsonNull() ? p.get(key).getAsString() : null;
	}

	private static int num(JsonObject p, String key, int fallback) {
		return p.has(key) && !p.get(key).isJsonNull() ? p.get(key).getAsInt() : fallback;
	}

	private static int length(DataType dt) {
		return dt.getLength() > 0 ? dt.getLength() : 1;
	}

	/** One edit of the working copy; the previous state goes to the undo stack. */
	static Map<String, Object> op(Session s, String id, String op, JsonObject p) throws Exception {
		Editor e = editor(id);
		Composite before = copy(s, e.working);
		Composite c = e.working;
		int ordinal = num(p, "ordinal", 0);
		String type = str(p, "type");
		String name = str(p, "name");
		String comment = str(p, "comment");
		try {
			switch (op) {
				case "addField": {
					DataType dt = Types.parse(s.program, type);
					c.add(dt, length(dt), name, comment);
					break;
				}
				case "editField": {
					DataTypeComponent comp = c.getComponent(ordinal);
					DataType dt = type != null && !type.isBlank() ? Types.parse(s.program, type) : null;
					if (dt != null && !dt.isEquivalent(comp.getDataType())) {
						if (c instanceof Structure st) {
							st.replace(ordinal, dt, dt.getLength() > 0 ? dt.getLength() : comp.getLength(),
								name != null ? name : comp.getFieldName(), comment != null ? comment : comp.getComment());
						}
						else {
							c.delete(ordinal);
							c.insert(ordinal, dt, dt.getLength(), name, comment);
						}
						break;
					}
					if (name != null) {
						comp.setFieldName(name.isBlank() ? null : name);
					}
					if (comment != null) {
						comp.setComment(comment.isBlank() ? null : comment);
					}
					break;
				}
				case "deleteField":
					c.delete(ordinal);
					break;
				case "insertField": {
					Structure st = structure(c);
					DataType dt = Types.parse(s.program, type);
					int offset = num(p, "offset", 0);
					if (st.isPackingEnabled() || offset >= st.getLength()) {
						st.insertAtOffset(offset, dt, length(dt), name, comment);
					}
					else {
						st.replaceAtOffset(offset, dt, length(dt), name, comment);
					}
					break;
				}
				case "moveField": {
					int target = ordinal + num(p, "delta", 0);
					if (target < 0 || target >= c.getNumComponents()) {
						throw new IllegalArgumentException("El campo ya está en el extremo");
					}
					DataTypeComponent comp = c.getComponent(ordinal);
					DataType dt = comp.getDataType();
					int len = comp.getLength();
					String n = comp.getFieldName();
					String cm = comp.getComment();
					c.delete(ordinal);
					c.insert(target, dt, len, n, cm);
					break;
				}
				case "addBitField":
					c.addBitField(Types.parse(s.program, type), num(p, "bits", 1), name, null);
					break;
				case "setPacking": {
					boolean enabled = p.has("enabled") && p.get("enabled").getAsBoolean();
					int value = num(p, "value", 0);
					if (!enabled) {
						c.setPackingEnabled(false);
					}
					else if (value > 0) {
						c.setExplicitPackingValue(value);
					}
					else {
						c.setToDefaultPacking();
					}
					break;
				}
				case "setAlignment": {
					int value = num(p, "value", 0);
					if (value > 0) {
						c.setExplicitMinimumAlignment(value);
					}
					else {
						c.setToDefaultAligned();
					}
					break;
				}
				case "setStructSize":
					structure(c).setLength(num(p, "size", c.getLength()));
					break;
				case "typeDuplicateField": {
					Structure st = structure(c);
					DataTypeComponent comp = st.getComponent(ordinal);
					int count = Math.max(1, num(p, "count", 1));
					for (int i = 0; i < count; i++) {
						String n = comp.getFieldName() == null ? null : comp.getFieldName() + "_" + (i + 2);
						if (st.isPackingEnabled()) {
							st.insert(ordinal + 1 + i, comp.getDataType(), comp.getLength(), n, comp.getComment());
						}
						else {
							st.insertAtOffset(comp.getOffset() + comp.getLength() * (i + 1), comp.getDataType(),
								comp.getLength(), n, comp.getComment());
						}
					}
					break;
				}
				case "typeUnpackField":
					unpack(structure(c), ordinal);
					break;
				case "typeFlexArray": {
					DataType element = Types.parse(s.program, type);
					structure(c).add(new ArrayDataType(element, 0, element.getLength(), s.program.getDataTypeManager()), 0,
						name, null);
					break;
				}
				case "describe":
					c.setDescription(str(p, "description"));
					break;
				default:
					throw new IllegalArgumentException("Operación desconocida: " + op);
			}
		}
		catch (Exception ex) {
			e.working = before;       // a failed edit may have left the copy half changed
			throw ex;
		}
		e.undo.push(before);
		e.redo.clear();
		while (e.undo.size() > 200) {
			e.undo.removeLast();
		}
		return state(s, e);
	}

	private static void unpack(Structure st, int ordinal) {
		DataTypeComponent c = st.getComponent(ordinal);
		if (c == null) {
			throw new IllegalArgumentException("Componente inexistente");
		}
		DataType dt = c.getDataType();
		String base = c.getFieldName() == null ? "field" : c.getFieldName();
		List<Object[]> parts = new ArrayList<>();
		if (dt instanceof Array array) {
			for (int i = 0; i < array.getNumElements(); i++) {
				parts.add(new Object[] { array.getDataType(), array.getElementLength(), base + "_" + i, null, null });
			}
		}
		else if (dt instanceof Structure inner) {
			for (DataTypeComponent ic : inner.getDefinedComponents()) {
				parts.add(new Object[] { ic.getDataType(), ic.getLength(),
					ic.getFieldName() == null ? null : base + "_" + ic.getFieldName(), ic.getComment(), ic.getOffset() });
			}
		}
		else {
			throw new IllegalArgumentException("Solo se desempaquetan arrays y estructuras");
		}
		int offset = c.getOffset();
		if (st.isPackingEnabled()) {
			st.delete(ordinal);
			int at = ordinal;
			for (Object[] part : parts) {
				st.insert(at++, (DataType) part[0], (Integer) part[1], (String) part[2], (String) part[3]);
			}
			return;
		}
		st.clearComponent(ordinal);
		int running = offset;
		for (Object[] part : parts) {
			int at = part[4] != null ? offset + (Integer) part[4] : running;
			st.replaceAtOffset(at, (DataType) part[0], (Integer) part[1], (String) part[2], (String) part[3]);
			running = at + (Integer) part[1];
		}
	}

	static Map<String, Object> undo(Session s, String id) {
		Editor e = editor(id);
		if (!e.undo.isEmpty()) {
			e.redo.push(e.working);
			e.working = e.undo.pop();
		}
		return state(s, e);
	}

	static Map<String, Object> redo(Session s, String id) {
		Editor e = editor(id);
		if (!e.redo.isEmpty()) {
			e.undo.push(e.working);
			e.working = e.redo.pop();
		}
		return state(s, e);
	}

	/** Writes the working copy over the program's type; the editor stays open with its history. */
	static Map<String, Object> apply(Session s, String id) throws Exception {
		Editor e = editor(id);
		s.edit("Editar " + e.original.getName(), () -> {
			e.original.replaceWith(e.working);
			e.original.setDescription(e.working.getDescription());
			return true;
		});
		return state(s, e);
	}

	/** Throws the unapplied edits away and starts again from the program's type. */
	static Map<String, Object> revert(Session s, String id) {
		Editor e = editor(id);
		e.undo.push(e.working);
		e.redo.clear();
		e.working = copy(s, e.original);
		return state(s, e);
	}

	static Object close(String id) {
		EDITORS.remove(id);
		return true;
	}
}
