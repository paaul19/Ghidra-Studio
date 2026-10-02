package studio;

import static studio.Json.*;

import java.io.File;
import java.nio.file.Files;
import java.util.*;

import ghidra.app.plugin.core.datamgr.DataTypeSyncInfo;
import ghidra.app.plugin.core.navigation.locationreferences.LocationReference;
import ghidra.app.plugin.core.navigation.locationreferences.ReferenceUtils;
import ghidra.app.util.cparser.C.CParserUtils;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.DomainFolder;
import ghidra.program.database.DataTypeArchiveDB;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.*;
import ghidra.program.model.data.Enum;
import ghidra.program.model.lang.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.DumbMemBufferImpl;
import ghidra.program.model.mem.MemBuffer;
import ghidra.program.util.DefaultLanguageService;
import ghidra.util.datastruct.ListAccumulator;
import ghidra.util.task.TaskMonitor;

/**
 * The Data Type Manager beyond the program's own types: categories, archives (.gdt files and
 * project archives) open for editing, source-archive synchronization, uses of a type, previews
 * and the C parser with profiles.
 *
 * Every operation takes a "where": empty for the program, a .gdt path, or "project:/folder/name"
 * for a data type archive stored in the project.
 */
final class TypeTools {
	private TypeTools() {
	}

	interface Action<T> {
		T run(DataTypeManager dtm) throws Exception;
	}

	static boolean isProgram(String where) {
		return where == null || where.isBlank();
	}

	/** Runs an action on a data type manager, inside a transaction (and saving) when it writes. */
	static <T> T with(StudioServer server, Session s, String where, String name, boolean write, Action<T> action)
			throws Exception {
		if (isProgram(where)) {
			if (s == null) {
				throw new IllegalStateException("No hay ningún programa abierto");
			}
			DataTypeManager dtm = s.program.getDataTypeManager();
			if (!write) {
				return action.run(dtm);
			}
			return s.edit(name, () -> action.run(dtm));
		}
		if (where.startsWith("project:")) {
			DomainFile file = projectArchive(server, where);
			Object consumer = new Object();
			DataTypeArchiveDB archive =
				(DataTypeArchiveDB) file.getDomainObject(consumer, true, false, TaskMonitor.DUMMY);
			try {
				DataTypeManager dtm = archive.getDataTypeManager();
				if (!write) {
					return action.run(dtm);
				}
				int tx = archive.startTransaction(name);
				boolean ok = false;
				T result;
				try {
					result = action.run(dtm);
					ok = true;
				}
				finally {
					archive.endTransaction(tx, ok);
				}
				archive.save(name, TaskMonitor.DUMMY);
				return result;
			}
			finally {
				archive.release(consumer);
			}
		}
		File file = new File(where);
		if (!file.isFile()) {
			throw new IllegalArgumentException("No existe el archivo de tipos " + where);
		}
		FileDataTypeManager dtm = FileDataTypeManager.openFileArchive(file, write);
		try {
			if (!write) {
				return action.run(dtm);
			}
			int tx = dtm.startTransaction(name);
			boolean ok = false;
			T result;
			try {
				result = action.run(dtm);
				ok = true;
			}
			finally {
				dtm.endTransaction(tx, ok);
			}
			dtm.save();
			return result;
		}
		finally {
			dtm.close();
		}
	}

	private static DomainFile projectArchive(StudioServer server, String where) {
		if (server.projectOrNull() == null) {
			throw new IllegalStateException("No hay ningún proyecto abierto");
		}
		DomainFile file = server.projectOrNull().getProjectData().getFile(where.substring("project:".length()));
		if (file == null || !DataTypeArchive.class.isAssignableFrom(file.getDomainObjectClass())) {
			throw new IllegalArgumentException("No existe el archivo de tipos " + where);
		}
		return file;
	}

	private static DataTypeConflictHandler handler(String conflict) {
		return switch (conflict == null ? "" : conflict) {
			case "replace" -> DataTypeConflictHandler.REPLACE_HANDLER;
			case "keep" -> DataTypeConflictHandler.KEEP_HANDLER;
			default -> DataTypeConflictHandler.DEFAULT_HANDLER;
		};
	}

	private static DataType type(DataTypeManager dtm, String path) {
		DataType dt = dtm.getDataType(path);
		if (dt == null) {
			dt = BuiltInDataTypeManager.getDataTypeManager().getDataType(path);
		}
		if (dt == null) {
			throw new IllegalArgumentException("No existe el tipo " + path);
		}
		return dt;
	}

	private static Category category(DataTypeManager dtm, String path) {
		Category c = dtm.getCategory(path == null || path.isBlank() ? CategoryPath.ROOT : new CategoryPath(path));
		if (c == null) {
			throw new IllegalArgumentException("No existe la categoría " + path);
		}
		return c;
	}

	// ---------------------------------------------------------------- archives

	/** Creates an empty .gdt archive. */
	static Object createArchive(String path) throws Exception {
		File file = new File(path.endsWith(".gdt") ? path : path + ".gdt");
		if (file.exists()) {
			throw new IllegalArgumentException("Ya existe " + file.getName());
		}
		FileDataTypeManager dtm = FileDataTypeManager.createFileArchive(file);
		try {
			dtm.save();
		}
		finally {
			dtm.close();
		}
		return map("path", file.getAbsolutePath());
	}

	/** Creates an empty data type archive inside the project (it can be versioned like a program). */
	static Object createProjectArchive(StudioServer server, String folder, String name) throws Exception {
		DomainFolder f = server.folderFor(folder);
		Object consumer = new Object();
		DataTypeArchiveDB archive = new DataTypeArchiveDB(f, name, consumer);
		try {
			DomainFile file = f.getFile(name);
			if (file == null) {
				file = f.createFile(name, archive, TaskMonitor.DUMMY);
			}
			return map("where", "project:" + file.getPathname());
		}
		finally {
			archive.release(consumer);
		}
	}

	/** Data type archives stored in the project. */
	static List<Map<String, Object>> projectArchives(StudioServer server) {
		List<Map<String, Object>> out = new ArrayList<>();
		if (server.projectOrNull() != null) {
			collect(server.projectOrNull().getProjectData().getRootFolder(), out);
		}
		return out;
	}

	private static void collect(DomainFolder folder, List<Map<String, Object>> out) {
		for (DomainFile f : folder.getFiles()) {
			if (DataTypeArchive.class.isAssignableFrom(f.getDomainObjectClass())) {
				out.add(map("where", "project:" + f.getPathname(), "name", f.getName(), "versioned", f.isVersioned()));
			}
		}
		for (DomainFolder sub : folder.getFolders()) {
			collect(sub, out);
		}
	}

	/** Name, counts and architecture of an archive (or of the program's types). */
	static Object info(StudioServer server, Session s, String where) throws Exception {
		return with(server, s, where, "", false, dtm -> {
			String architecture = dtm instanceof StandAloneDataTypeManager sa ? sa.getProgramArchitectureSummary() : null;
			return map("name", dtm.getName(), "types", dtm.getDataTypeCount(true), "categories", dtm.getCategoryCount(),
				"architecture", architecture, "pointerSize", dtm.getDataOrganization().getPointerSize(),
				"updatable", dtm.isUpdatable());
		});
	}

	/** Gives an archive a processor and compiler (so its types get that data organization); empty clears it. */
	static Object setArchitecture(StudioServer server, Session s, String where, String language, String compiler)
			throws Exception {
		if (isProgram(where)) {
			throw new IllegalArgumentException("La arquitectura del programa se cambia con «Cambiar lenguaje»");
		}
		// architecture changes manage their own transaction
		if (where.startsWith("project:")) {
			DomainFile file = projectArchive(server, where);
			Object consumer = new Object();
			DataTypeArchiveDB archive =
				(DataTypeArchiveDB) file.getDomainObject(consumer, true, false, TaskMonitor.DUMMY);
			try {
				apply(archive.getDataTypeManager(), language, compiler);
				archive.save("Arquitectura", TaskMonitor.DUMMY);
				return map("architecture", archive.getDataTypeManager().getProgramArchitectureSummary());
			}
			finally {
				archive.release(consumer);
			}
		}
		FileDataTypeManager dtm = FileDataTypeManager.openFileArchive(new File(where), true);
		try {
			apply(dtm, language, compiler);
			dtm.save();
			return map("architecture", dtm.getProgramArchitectureSummary());
		}
		finally {
			dtm.close();
		}
	}

	private static void apply(StandAloneDataTypeManager dtm, String language, String compiler) throws Exception {
		if (language == null || language.isBlank()) {
			dtm.clearProgramArchitecture(TaskMonitor.DUMMY);
			return;
		}
		Language lang = DefaultLanguageService.getLanguageService().getLanguage(new LanguageID(language));
		CompilerSpecID spec = compiler == null || compiler.isBlank() ? lang.getDefaultCompilerSpec().getCompilerSpecID()
				: new CompilerSpecID(compiler);
		dtm.setProgramArchitecture(lang, spec, StandAloneDataTypeManager.LanguageUpdateOption.TRANSLATE,
			TaskMonitor.DUMMY);
	}

	// ---------------------------------------------------------------- browsing

	/** Categories (with counts) and types of one category. */
	static Object browse(StudioServer server, Session s, String where, String categoryPath, String filter)
			throws Exception {
		return with(server, s, where, "", false, dtm -> {
			List<Map<String, Object>> categories = new ArrayList<>();
			walk(dtm.getRootCategory(), 0, categories);
			String f = filter == null ? "" : filter.toLowerCase();
			List<DataType> types = new ArrayList<>();
			if (!f.isEmpty()) {
				dtm.getAllDataTypes(types);
				types.removeIf(dt -> !dt.getName().toLowerCase().contains(f));
			}
			else {
				types.addAll(Arrays.asList(category(dtm, categoryPath).getDataTypes()));
			}
			List<Map<String, Object>> rows = new ArrayList<>();
			for (DataType dt : types) {
				if (rows.size() >= 5000) {
					break;
				}
				if (dt instanceof Array || (dt instanceof Pointer && f.isEmpty() && dt.getCategoryPath().isRoot())) {
					continue;
				}
				SourceArchive source = dt.getSourceArchive();
				boolean local = source == null || source.equals(dtm.getLocalSourceArchive());
				rows.add(map("path", dt.getPathName(), "name", dt.getName(), "category", dt.getCategoryPath().getPath(),
					"kind", Types.kind(dt), "size", dt.getLength(), "favorite", dtm.isFavorite(dt),
					"source", local ? "" : source.getName(), "description", dt.getDescription()));
			}
			rows.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
			return map("categories", categories, "types", rows);
		});
	}

	private static void walk(Category c, int depth, List<Map<String, Object>> out) {
		out.add(map("path", c.getCategoryPath().getPath(), "name", c.isRoot() ? "/" : c.getName(), "depth", depth,
			"types", c.getDataTypes().length));
		Category[] subs = c.getCategories();
		Arrays.sort(subs, Comparator.comparing(x -> x.getName().toLowerCase()));
		for (Category sub : subs) {
			if (out.size() < 20000) {
				walk(sub, depth + 1, out);
			}
		}
	}

	// ---------------------------------------------------------------- categories

	/** action: create (name), rename (name), move (dest), copy (dest), delete. */
	static Object categoryAction(StudioServer server, Session s, String where, String action, String path, String name,
			String dest, String conflict) throws Exception {
		return with(server, s, where, "Categoría de tipos", true, dtm -> {
			Category c = category(dtm, path);
			switch (action) {
				case "create":
					return map("path", c.createCategory(name).getCategoryPath().getPath());
				case "rename":
					c.setName(name);
					return map("path", c.getCategoryPath().getPath());
				case "move":
					category(dtm, dest).moveCategory(c, TaskMonitor.DUMMY);
					return map("path", c.getCategoryPath().getPath());
				case "copy":
					return map("path",
						category(dtm, dest).copyCategory(c, handler(conflict), TaskMonitor.DUMMY).getCategoryPath().getPath());
				case "delete":
					if (c.isRoot()) {
						throw new IllegalArgumentException("La categoría raíz no se puede borrar");
					}
					c.getParent().removeCategory(c.getName(), TaskMonitor.DUMMY);
					return map("path", "/");
				default:
					throw new IllegalArgumentException("Acción desconocida: " + action);
			}
		});
	}

	// ---------------------------------------------------------------- types

	/**
	 * action: move (dest category), copy (dest category), rename (name), delete, favorite (name true/false),
	 * pointer, typedef (name), replace (dest = path of the replacement), describe (name = text).
	 */
	static Object typeAction(StudioServer server, Session s, String where, String action, List<String> paths,
			String name, String dest, String conflict) throws Exception {
		return with(server, s, where, "Tipos de datos", true, dtm -> {
			List<String> out = new ArrayList<>();
			for (String path : paths) {
				DataType dt = type(dtm, path);
				switch (action) {
					case "move":
						category(dtm, dest).moveDataType(dt, handler(conflict));
						out.add(dt.getPathName());
						break;
					case "copy": {
						DataType copy = dt.copy(dtm);
						copy.setCategoryPath(category(dtm, dest).getCategoryPath());
						out.add(dtm.addDataType(copy, handler(conflict)).getPathName());
						break;
					}
					case "rename":
						dt.setName(name);
						out.add(dt.getPathName());
						break;
					case "delete":
						dtm.remove(dt, TaskMonitor.DUMMY);
						break;
					case "favorite":
						dtm.setFavorite(dt, Boolean.parseBoolean(name));
						out.add(dt.getPathName());
						break;
					case "pointer":
						out.add(dtm.resolve(new PointerDataType(dt, dtm), handler(conflict)).getPathName());
						break;
					case "typedef": {
						String n = name == null || name.isBlank() ? dt.getName() + "_t" : name;
						out.add(dtm.addDataType(new TypedefDataType(dt.getCategoryPath(), n, dt, dtm), handler(conflict))
								.getPathName());
						break;
					}
					case "replace":
						out.add(dtm.replaceDataType(dt, type(dtm, dest), false).getPathName());
						break;
					case "describe":
						dt.setDescription(name == null ? "" : name);
						out.add(dt.getPathName());
						break;
					default:
						throw new IllegalArgumentException("Acción desconocida: " + action);
				}
			}
			return map("paths", out);
		});
	}

	/** Copies types (with what they depend on) between the program and archives, in any direction. */
	static Object copyTypes(StudioServer server, Session s, String from, String to, List<String> paths, String dest,
			String conflict, boolean associate) throws Exception {
		// program → archive: the program's type becomes a copy of the archive's, so both can be kept in sync
		boolean link = associate && isProgram(from) && !isProgram(to);
		return with(server, s, from, "Asociar tipos", link, source -> with(server, s, to, "Copiar tipos", true, target -> {
			int n = 0;
			for (String path : paths) {
				DataType dt = type(source, path);
				if (link && source.getLocalSourceArchive().equals(dt.getSourceArchive())) {
					source.associateDataTypeWithArchive(dt, target.getLocalSourceArchive());
				}
				DataType resolved = target.resolve(dt, handler(conflict));
				if (dest != null && !dest.isBlank() && !resolved.getCategoryPath().getPath().equals(dest)) {
					Category c = target.createCategory(new CategoryPath(dest));
					try {
						c.moveDataType(resolved, handler(conflict));
					}
					catch (Exception e) {
						// it stays where the source had it
					}
				}
				n++;
			}
			return map("copied", n, "total", target.getDataTypeCount(true));
		}));
	}

	/** A new enum with the values of several. */
	static Object mergeEnums(StudioServer server, Session s, String where, List<String> paths, String name)
			throws Exception {
		return with(server, s, where, "Crear enum a partir de otros", true, dtm -> {
			int size = 1;
			List<Enum> enums = new ArrayList<>();
			for (String path : paths) {
				if (!(type(dtm, path) instanceof Enum e)) {
					throw new IllegalArgumentException(path + " no es un enum");
				}
				enums.add(e);
				size = Math.max(size, e.getLength());
			}
			EnumDataType merged = new EnumDataType(enums.get(0).getCategoryPath(), name, size, dtm);
			int skipped = 0;
			for (Enum e : enums) {
				for (String n : e.getNames()) {
					try {
						merged.add(n, e.getValue(n), e.getComment(n));
					}
					catch (IllegalArgumentException dup) {
						skipped++;
					}
				}
			}
			DataType added = dtm.addDataType(merged, DataTypeConflictHandler.DEFAULT_HANDLER);
			return map("path", added.getPathName(), "values", merged.getCount(), "skipped", skipped);
		});
	}

	/** Favorites of the program and of the built-in types. */
	static List<Map<String, Object>> favorites(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		List<DataType> all = new ArrayList<>(s.program.getDataTypeManager().getFavorites());
		all.addAll(BuiltInDataTypeManager.getDataTypeManager().getFavorites());
		for (DataType dt : all) {
			out.add(map("path", dt.getPathName(), "name", dt.getName(), "kind", Types.kind(dt), "size", dt.getLength()));
		}
		return out;
	}

	// ---------------------------------------------------------------- structures

	private static Structure structure(DataTypeManager dtm, String path) {
		if (!(type(dtm, path) instanceof Structure st)) {
			throw new IllegalArgumentException(path + " no es una estructura");
		}
		return st;
	}

	/** Repeats a component right after itself. */
	static Object duplicateField(StudioServer server, Session s, String where, String path, int ordinal, int count)
			throws Exception {
		return with(server, s, where, "Duplicar campo", true, dtm -> {
			Structure st = structure(dtm, path);
			DataTypeComponent c = st.getComponent(ordinal);
			if (c == null) {
				throw new IllegalArgumentException("Componente inexistente");
			}
			for (int i = 0; i < Math.max(1, count); i++) {
				String name = c.getFieldName() == null ? null : c.getFieldName() + "_" + (i + 2);
				if (st.isPackingEnabled()) {
					st.insert(ordinal + 1 + i, c.getDataType(), c.getLength(), name, c.getComment());
				}
				else {
					st.insertAtOffset(c.getOffset() + c.getLength() * (i + 1), c.getDataType(), c.getLength(), name,
						c.getComment());
				}
			}
			return map("size", st.getLength(), "components", st.getNumComponents());
		});
	}

	/** Replaces an array or structure component with its elements. */
	static Object unpackField(StudioServer server, Session s, String where, String path, int ordinal) throws Exception {
		return with(server, s, where, "Desempaquetar campo", true, dtm -> {
			Structure st = structure(dtm, path);
			DataTypeComponent c = st.getComponent(ordinal);
			if (c == null) {
				throw new IllegalArgumentException("Componente inexistente");
			}
			DataType dt = c.getDataType();
			List<Object[]> parts = new ArrayList<>();
			String base = c.getFieldName() == null ? "field" : c.getFieldName();
			if (dt instanceof Array array) {
				for (int i = 0; i < array.getNumElements(); i++) {
					parts.add(new Object[] { array.getDataType(), array.getElementLength(), base + "_" + i, null });
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
			}
			else {
				st.clearComponent(ordinal);
				int running = offset;
				for (Object[] part : parts) {
					int at = part.length > 4 ? offset + (Integer) part[4] : running;
					st.replaceAtOffset(at, (DataType) part[0], (Integer) part[1], (String) part[2], (String) part[3]);
					running = at + (Integer) part[1];
				}
			}
			return map("size", st.getLength(), "components", st.getNumComponents());
		});
	}

	/** A trailing flexible array (type name[0]). */
	static Object addFlexArray(StudioServer server, Session s, String where, String path, String elementType,
			String name) throws Exception {
		return with(server, s, where, "Array flexible", true, dtm -> {
			Structure st = structure(dtm, path);
			DataType element = isProgram(where) ? Types.parse(s.program, elementType) : type(dtm, elementType);
			st.add(new ArrayDataType(element, 0, element.getLength(), dtm), 0, name, null);
			return map("size", st.getLength(), "components", st.getNumComponents());
		});
	}

	// ---------------------------------------------------------------- source archives

	/** The archives the program took types from, and how many of its types came from each. */
	static List<Map<String, Object>> sourceArchives(Session s) throws Exception {
		DataTypeManager dtm = s.program.getDataTypeManager();
		List<Map<String, Object>> known = Types.archives();
		List<Map<String, Object>> out = new ArrayList<>();
		for (SourceArchive a : dtm.getSourceArchives()) {
			if (a.equals(dtm.getLocalSourceArchive()) || a.getArchiveType() == ArchiveType.BUILT_IN) {
				continue;
			}
			String guess = null;
			for (Map<String, Object> k : known) {
				String n = new File(String.valueOf(k.get("path"))).getName();
				if (n.equals(a.getName()) || n.equals(a.getName() + ".gdt")) {
					guess = String.valueOf(k.get("path"));
				}
			}
			out.add(map("name", a.getName(), "id", a.getSourceArchiveID().toString(), "kind", a.getArchiveType().name(),
				"types", dtm.getDataTypes(a).size(), "path", guess, "lastSync", a.getLastSyncTime()));
		}
		return out;
	}

	private static SourceArchive sourceOf(DataTypeManager program, DataTypeManager archive) {
		SourceArchive a = program.getSourceArchive(archive.getUniversalID());
		if (a == null) {
			throw new IllegalArgumentException("El programa no tiene tipos de ese archivo");
		}
		return a;
	}

	/** State of each program type that came from the archive: IN_SYNC, UPDATE, COMMIT, CONFLICT or ORPHAN. */
	static Object syncList(StudioServer server, Session s, String archive) throws Exception {
		return with(server, s, archive, "", false, source -> {
			DataTypeManager dtm = s.program.getDataTypeManager();
			List<Map<String, Object>> rows = new ArrayList<>();
			for (DataType dt : dtm.getDataTypes(sourceOf(dtm, source))) {
				DataTypeSyncInfo info = new DataTypeSyncInfo(dt, source);
				rows.add(map("path", dt.getPathName(), "name", dt.getName(), "state", info.getSyncState().name(),
					"sourcePath", info.getSourceDtPath(), "changed", info.getLastChangeTimeString(false),
					"sourceChanged", info.getLastChangeTimeString(true), "canCommit", info.canCommit(),
					"canUpdate", info.canUpdate(), "canRevert", info.canRevert()));
			}
			rows.sort(Comparator.comparing(o -> (String) o.get("name")));
			return rows;
		});
	}

	/** action: commit (program → archive), update (archive → program), revert, disassociate. */
	static Object syncAction(StudioServer server, Session s, String archive, List<String> paths, String action)
			throws Exception {
		boolean writesArchive = action.equals("commit");
		return with(server, s, archive, "Sincronizar tipos", writesArchive, source -> s.edit("Sincronizar tipos", () -> {
			DataTypeManager dtm = s.program.getDataTypeManager();
			int done = 0;
			for (String path : paths) {
				DataTypeSyncInfo info = new DataTypeSyncInfo(type(dtm, path), source);
				switch (action) {
					case "commit":
						info.commit();
						break;
					case "update":
						info.update();
						break;
					case "revert":
						info.revert();
						break;
					case "disassociate":
						info.disassociate();
						break;
					default:
						throw new IllegalArgumentException("Acción desconocida: " + action);
				}
				done++;
			}
			return map("done", done);
		}));
	}

	// ---------------------------------------------------------------- uses and preview

	/** Where a type (or one of its fields) is used: data, variables, parameters, returns and decompiled code. */
	static List<Map<String, Object>> findUses(Session s, String path, String field, boolean decompile,
			TaskMonitor monitor) throws Exception {
		DataType dt = Types.find(s.program, path);
		ListAccumulator<LocationReference> found = new ListAccumulator<>();
		ReferenceUtils.findDataTypeReferences(found, dt, field == null || field.isBlank() ? null : field, s.program,
			decompile, monitor);
		List<Map<String, Object>> out = new ArrayList<>();
		for (LocationReference r : found.asList()) {
			if (out.size() >= 5000) {
				break;
			}
			Address a = r.getLocationOfUse();
			Function f = s.program.getFunctionManager().getFunctionContaining(a);
			String context = r.getContext() == null ? "" : r.getContext().getPlainText();
			out.add(map("address", str(a), "function", f == null ? "" : f.getName(), "context", context,
				"kind", r.getRefTypeString()));
		}
		// structures that contain it
		for (DataType parent : dt.getParents()) {
			out.add(map("address", "", "function", "", "context", parent.getPathName(), "kind", "TYPE"));
		}
		return out;
	}

	/** How the bytes at an address read as each of several types (Data Type Preview). */
	static List<Map<String, Object>> preview(Session s, Address address, List<String> types) {
		List<Map<String, Object>> out = new ArrayList<>();
		MemBuffer buffer = new DumbMemBufferImpl(s.program.getMemory(), address);
		for (String text : types) {
			String value;
			int length = 0;
			String name = text;
			try {
				DataType dt = Types.parse(s.program, text);
				name = dt.getName();
				length = dt.getLength();
				if (dt instanceof Composite composite) {
					StringBuilder sb = new StringBuilder();
					for (DataTypeComponent c : composite.getDefinedComponents()) {
						MemBuffer sub = new DumbMemBufferImpl(s.program.getMemory(), address.add(c.getOffset()));
						sb.append(c.getFieldName() == null ? "field_" + c.getOffset() : c.getFieldName()).append(" = ")
								.append(c.getDataType().getRepresentation(sub, c.getDefaultSettings(), c.getLength()))
								.append("; ");
						if (sb.length() > 400) {
							sb.append("…");
							break;
						}
					}
					value = sb.toString();
				}
				else {
					int len = length > 0 ? length : dt instanceof Dynamic dyn ? dyn.getLength(buffer, -1) : 1;
					length = len;
					value = dt.getRepresentation(buffer, dt.getDefaultSettings(), len);
				}
			}
			catch (Exception e) {
				value = "—";
			}
			out.add(map("type", text, "name", name, "size", length, "value", value));
		}
		return out;
	}

	// ---------------------------------------------------------------- C parser

	/** The parser profiles shipped with Ghidra (.prf): header list, options and include paths. */
	static List<Map<String, Object>> cProfiles() throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		File dir = new File(ghidra.framework.Application.getInstallationDirectory().getFile(false),
			"Ghidra/Features/Base/data/parserprofiles");
		File[] files = dir.listFiles((d, n) -> n.endsWith(".prf"));
		if (files == null) {
			return out;
		}
		Arrays.sort(files);
		for (File f : files) {
			// sections separated by blank lines: headers, options, include paths, language, compiler
			List<List<String>> sections = new ArrayList<>();
			sections.add(new ArrayList<>());
			for (String line : Files.readAllLines(f.toPath())) {
				if (line.isBlank()) {
					sections.add(new ArrayList<>());
				}
				else {
					sections.get(sections.size() - 1).add(line.trim());
				}
			}
			while (sections.size() < 5) {
				sections.add(new ArrayList<>());
			}
			out.add(map("name", f.getName().replace(".prf", ""), "headers", sections.get(0), "options", sections.get(1),
				"includes", sections.get(2), "language", String.join("", sections.get(3)),
				"compiler", String.join("", sections.get(4))));
		}
		return out;
	}

	/** Parses header files into the program or into an archive. */
	static Object parseHeaders(StudioServer server, Session s, String where, List<String> files, List<String> includes,
			List<String> options, TaskMonitor monitor) throws Exception {
		return with(server, s, where, "Leer cabeceras de C", true, dtm -> {
			int before = dtm.getDataTypeCount(true);
			DataTypeManager[] open = isProgram(where) ? new DataTypeManager[0]
					: s != null ? new DataTypeManager[] { s.program.getDataTypeManager() } : new DataTypeManager[0];
			CParserUtils.CParseResults results = CParserUtils.parseHeaderFiles(open, files.toArray(new String[0]),
				includes.toArray(new String[0]), options.toArray(new String[0]), dtm, monitor);
			String messages = results == null ? "" : results.getFormattedParseMessage(null);
			return map("added", dtm.getDataTypeCount(true) - before, "total", dtm.getDataTypeCount(true),
				"ok", results != null && results.successful(), "messages", messages);
		});
	}
}
