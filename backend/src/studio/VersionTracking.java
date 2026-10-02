package studio;

import static studio.Json.*;

import java.io.IOException;
import java.util.*;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import ghidra.feature.vt.api.db.VTSessionContentHandler;
import ghidra.feature.vt.api.db.VTSessionDB;
import ghidra.feature.vt.api.main.*;
import ghidra.feature.vt.api.util.VTOptions;
import ghidra.feature.vt.gui.actions.AutoVersionTrackingTask;
import ghidra.feature.vt.gui.plugin.AddressCorrelatorManager;
import ghidra.feature.vt.gui.task.*;
import ghidra.feature.vt.gui.provider.impliedmatches.VTImpliedMatchInfo;
import ghidra.feature.vt.gui.util.MatchInfo;
import ghidra.feature.vt.gui.util.MatchInfoFactory;
import ghidra.feature.vt.gui.util.VTOptionDefines;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.DomainFolder;
import ghidra.framework.options.OptionType;
import ghidra.framework.options.ToolOptions;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.Symbol;
import ghidra.util.classfinder.ClassSearcher;
import ghidra.util.task.TaskMonitor;

/**
 * Version Tracking: a session links a source program (already reversed) with a destination
 * program; correlators propose matches, which are accepted and whose markup (names, signatures,
 * comments, labels, data types) is applied to the destination. One session open at a time.
 */
final class VersionTracking {
	private static final int MAX_ROWS = 20000;

	private final StudioServer server;
	private final Object consumer = new Object();
	private VTSessionDB session;
	private Program source;
	private boolean ownsSource;
	private MatchInfoFactory matchInfos = new MatchInfoFactory();
	private AddressCorrelatorManager correlators;
	private final ToolOptions applyOptions = new VTOptions("Studio");

	VersionTracking(StudioServer server) {
		this.server = server;
	}

	boolean isOpen() {
		return session != null;
	}

	private VTSessionDB session() {
		if (session == null) {
			throw new IllegalStateException("No hay ninguna sesión de Version Tracking abierta");
		}
		return session;
	}

	// ---------------------------------------------------------------- sessions

	List<Map<String, Object>> sessions() {
		List<Map<String, Object>> out = new ArrayList<>();
		collect(server.project().getRootFolder(), out);
		return out;
	}

	private void collect(DomainFolder folder, List<Map<String, Object>> out) {
		for (DomainFile f : folder.getFiles()) {
			if (VTSessionContentHandler.CONTENT_TYPE.equals(f.getContentType())) {
				out.add(map("name", f.getName(), "path", f.getPathname(), "modified", f.getLastModifiedTime(),
					"open", session != null && session.getDomainFile() != null &&
						f.getPathname().equals(session.getDomainFile().getPathname())));
			}
		}
		for (DomainFolder sub : folder.getFolders()) {
			collect(sub, out);
		}
	}

	Map<String, Object> create(String name, String sourcePath, Session destination, String folderPath)
			throws Exception {
		close(true);
		DomainFile sourceFile = server.project().getProjectData().getFile(sourcePath);
		if (sourceFile == null) {
			throw new IllegalArgumentException("No existe " + sourcePath);
		}
		if (sourcePath.equals(destination.id)) {
			throw new IllegalArgumentException("El programa origen y el destino no pueden ser el mismo");
		}
		DomainFolder folder = server.folderFor(folderPath);
		if (folder.getFile(name) != null) {
			throw new IllegalArgumentException("Ya existe un archivo con ese nombre en la carpeta");
		}
		Session open = server.sessionFor(sourcePath);
		Program src = open != null ? open.program
				: (Program) sourceFile.getDomainObject(consumer, true, false, TaskMonitor.DUMMY);
		boolean owns = open == null;
		try {
			VTSessionDB created = new VTSessionDB(name, src, destination.program, consumer);
			folder.createFile(name, created, TaskMonitor.DUMMY);
			session = created;
			source = src;
			ownsSource = owns;
		}
		catch (Exception e) {
			if (owns) {
				src.release(consumer);
			}
			throw e;
		}
		correlators = new AddressCorrelatorManager(() -> session);
		matchInfos = new MatchInfoFactory();
		return state();
	}

	Map<String, Object> open(String path) throws Exception {
		close(true);
		DomainFile f = server.project().getProjectData().getFile(path);
		if (f == null) {
			throw new IllegalArgumentException("No existe " + path);
		}
		VTSessionDB opened = (VTSessionDB) f.getDomainObject(consumer, true, false, TaskMonitor.DUMMY);
		if (opened.getSourceProgram() == null || opened.getDestinationProgram() == null) {
			opened.release(consumer);
			throw new IOException("No se encontraron los programas de la sesión en el proyecto");
		}
		session = opened;
		source = opened.getSourceProgram();
		ownsSource = false;
		correlators = new AddressCorrelatorManager(() -> session);
		matchInfos = new MatchInfoFactory();
		return state();
	}

	Object save() throws Exception {
		VTSessionDB s = session();
		Program dest = s.getDestinationProgram();
		Session open = destinationSession();
		if (open != null) {
			open.save();
		}
		else if (dest.isChanged()) {
			dest.save("Version Tracking", TaskMonitor.DUMMY);
		}
		s.save();
		return state();
	}

	Object close(boolean save) {
		if (session == null) {
			return map("open", false);
		}
		try {
			if (save) {
				save();
			}
		}
		catch (Exception e) {
			e.printStackTrace();
		}
		try {
			session.release(consumer);
		}
		catch (Exception e) {
			e.printStackTrace();
		}
		if (ownsSource && source != null) {
			try {
				source.release(consumer);
			}
			catch (Exception ignored) {
				// already released
			}
		}
		session = null;
		source = null;
		return map("open", false);
	}

	private Session destinationSession() {
		DomainFile df = session().getDestinationProgram().getDomainFile();
		return df != null ? server.sessionFor(df.getPathname()) : null;
	}

	String destinationPath() {
		DomainFile df = session().getDestinationProgram().getDomainFile();
		return df != null ? df.getPathname() : null;
	}

	Map<String, Object> state() {
		if (session == null) {
			return map("open", false);
		}
		Program dest = session.getDestinationProgram();
		List<Map<String, Object>> sets = new ArrayList<>();
		int total = 0;
		for (VTMatchSet set : session.getMatchSets()) {
			sets.add(map("id", set.getID(), "correlator", set.getProgramCorrelatorInfo().getName(),
				"matches", set.getMatchCount()));
			total += set.getMatchCount();
		}
		int accepted = 0;
		for (VTAssociation a : session.getAssociationManager().getAssociations()) {
			if (a.getStatus() == VTAssociationStatus.ACCEPTED) {
				accepted++;
			}
		}
		DomainFile sf = source.getDomainFile();
		DomainFile vf = session.getDomainFile();
		return map("open", true, "name", session.getName(), "path", vf != null ? vf.getPathname() : null,
			"source", source.getName(), "sourcePath", sf != null ? sf.getPathname() : null,
			"destination", dest.getName(), "destinationPath", destinationPath(),
			"matchSets", sets, "matches", total,
			"associations", session.getAssociationManager().getAssociationCount(), "accepted", accepted,
			"changed", session.isChanged() || dest.isChanged());
	}

	// ---------------------------------------------------------------- correlators

	private static List<VTProgramCorrelatorFactory> factories() {
		List<VTProgramCorrelatorFactory> list =
			new ArrayList<>(ClassSearcher.getInstances(VTProgramCorrelatorFactory.class));
		list.sort(Comparator.comparingInt(VTProgramCorrelatorFactory::getPriority));
		return list;
	}

	private static List<Map<String, Object>> describe(ToolOptions options, Map<String, String> labels) {
		List<Map<String, Object>> out = new ArrayList<>();
		List<String> names = new ArrayList<>(options.getOptionNames());
		Collections.sort(names);
		for (String name : names) {
			OptionType type = options.getType(name);
			Object value = options.getObject(name, null);
			String kind = type == OptionType.BOOLEAN_TYPE ? "bool"
					: type == OptionType.INT_TYPE || type == OptionType.LONG_TYPE ? "int"
							: type == OptionType.DOUBLE_TYPE || type == OptionType.FLOAT_TYPE ? "double"
									: type == OptionType.STRING_TYPE ? "string"
											: type == OptionType.ENUM_TYPE ? "enum" : null;
			if (kind == null || value == null) {
				continue;
			}
			List<String> choices = new ArrayList<>();
			if (value instanceof Enum<?> e) {
				for (Object c : e.getDeclaringClass().getEnumConstants()) {
					choices.add(((Enum<?>) c).name());
				}
			}
			out.add(map("name", name, "label", labels != null ? labels.getOrDefault(name, name) : name,
				"type", kind, "value", value instanceof Enum<?> e ? e.name() : String.valueOf(value),
				"choices", choices, "description", options.getDescription(name)));
		}
		return out;
	}

	@SuppressWarnings({ "unchecked", "rawtypes" })
	private static void applyValues(ToolOptions options, JsonObject values) {
		if (values == null) {
			return;
		}
		for (Map.Entry<String, JsonElement> e : values.entrySet()) {
			String name = e.getKey();
			if (!options.contains(name)) {
				continue;
			}
			String v = e.getValue().getAsString();
			Object current = options.getObject(name, null);
			if (current instanceof Boolean) {
				options.setBoolean(name, Boolean.parseBoolean(v));
			}
			else if (current instanceof Integer) {
				options.setInt(name, Integer.parseInt(v.trim()));
			}
			else if (current instanceof Long) {
				options.setLong(name, Long.parseLong(v.trim()));
			}
			else if (current instanceof Double) {
				options.setDouble(name, Double.parseDouble(v.trim()));
			}
			else if (current instanceof Float) {
				options.setFloat(name, Float.parseFloat(v.trim()));
			}
			else if (current instanceof Enum en) {
				options.setEnum(name, Enum.valueOf(en.getDeclaringClass(), v));
			}
			else if (current instanceof String) {
				options.setString(name, v);
			}
		}
	}

	static List<Map<String, Object>> correlators() {
		List<Map<String, Object>> out = new ArrayList<>();
		for (VTProgramCorrelatorFactory f : factories()) {
			VTOptions options = f.createDefaultOptions();
			out.add(map("name", f.getName(), "description", f.getDescription(), "priority", f.getPriority(),
				"options", options != null ? describe(options, null) : List.of()));
		}
		return out;
	}

	/** Runs the named correlators; each one adds a match set to the session. */
	Map<String, Object> run(List<String> names, JsonObject optionValues, boolean excludeAccepted,
			TaskMonitor monitor) throws Exception {
		return run(names, optionValues, excludeAccepted, List.of(), List.of(), monitor);
	}

	private static AddressSet limit(Program p, List<String> ranges) {
		AddressSet all = new AddressSet(p.getMemory());
		if (ranges.isEmpty()) {
			return all;
		}
		AddressSet set = new AddressSet();
		for (String r : ranges) {
			String[] parts = r.split("\\s*[-–]\\s*");
			Address lo = address(p, parts[0].trim());
			Address hi = parts.length > 1 ? address(p, parts[1].trim()) : lo;
			set.add(lo, hi);
		}
		return all.intersect(set);
	}

	/** sourceRanges / destRanges ("start-end") limit where the correlators look, like the wizard's address-set page. */
	Map<String, Object> run(List<String> names, JsonObject optionValues, boolean excludeAccepted,
			List<String> sourceRanges, List<String> destRanges, TaskMonitor monitor) throws Exception {
		VTSessionDB s = session();
		Program dest = s.getDestinationProgram();
		AddressSet srcSet = limit(source, sourceRanges);
		AddressSet dstSet = limit(dest, destRanges);
		if (excludeAccepted) {
			for (VTAssociation a : s.getAssociationManager().getAssociations()) {
				if (a.getStatus() == VTAssociationStatus.ACCEPTED) {
					srcSet.delete(body(source, a.getSourceAddress()));
					dstSet.delete(body(dest, a.getDestinationAddress()));
				}
			}
		}
		List<Map<String, Object>> results = new ArrayList<>();
		int tx = s.startTransaction("Correlate");
		boolean ok = false;
		try {
			for (VTProgramCorrelatorFactory f : factories()) {
				if (!names.contains(f.getName())) {
					continue;
				}
				monitor.checkCancelled();
				monitor.setMessage(f.getName());
				VTOptions options = f.createDefaultOptions();
				if (options != null && optionValues != null && optionValues.has(f.getName())) {
					applyValues(options, optionValues.getAsJsonObject(f.getName()));
				}
				VTProgramCorrelator c = f.createCorrelator(source, srcSet, dest, dstSet, options);
				VTMatchSet set = c.correlate(s, monitor);
				results.add(map("correlator", f.getName(), "matches", set != null ? set.getMatchCount() : 0));
			}
			ok = true;
		}
		finally {
			s.endTransaction(tx, ok);
		}
		matchInfos.clearCache();
		return map("results", results, "state", state());
	}

	private static AddressSetView body(Program p, Address a) {
		Function f = p.getFunctionManager().getFunctionAt(a);
		if (f != null) {
			return f.getBody();
		}
		Data d = p.getListing().getDataAt(a);
		return d != null ? new AddressSet(d.getMinAddress(), d.getMaxAddress()) : new AddressSet(a);
	}

	// ---------------------------------------------------------------- auto version tracking

	private static final String[][] AUTO_OPTIONS = {
		{ VTOptionDefines.RUN_EXACT_SYMBOL_OPTION, VTOptionDefines.RUN_EXACT_SYMBOL_OPTION_TEXT, "true" },
		{ VTOptionDefines.RUN_EXACT_DATA_OPTION, VTOptionDefines.RUN_EXACT_DATA_OPTION_TEXT, "true" },
		{ VTOptionDefines.RUN_EXACT_FUNCTION_BYTES_OPTION, VTOptionDefines.RUN_EXACT_FUNCTION_BYTES_OPTION_TEXT, "true" },
		{ VTOptionDefines.RUN_EXACT_FUNCTION_INST_OPTION, VTOptionDefines.RUN_EXACT_FUNCTION_INST_OPTION_TEXT, "true" },
		{ VTOptionDefines.RUN_DUPE_FUNCTION_OPTION, VTOptionDefines.RUN_DUPE_FUNCTION_OPTION_TEXT, "true" },
		{ VTOptionDefines.RUN_REF_CORRELATORS_OPTION, VTOptionDefines.RUN_REF_CORRELATORS_OPTION_TEXT, "true" },
		{ VTOptionDefines.CREATE_IMPLIED_MATCHES_OPTION, VTOptionDefines.CREATE_IMPLIED_MATCHES_OPTION_TEXT, "true" },
		{ VTOptionDefines.APPLY_IMPLIED_MATCHES_OPTION, VTOptionDefines.APPLY_IMPLIED_MATCHES_OPTION_TEXT, "true" },
		{ VTOptionDefines.MIN_VOTES_OPTION, VTOptionDefines.MIN_VOTES_OPTION_TEXT, "2" },
		{ VTOptionDefines.MAX_CONFLICTS_OPTION, VTOptionDefines.MAX_CONFLICTS_OPTION_TEXT, "0" },
		{ VTOptionDefines.DATA_CORRELATOR_MIN_LEN_OPTION, VTOptionDefines.DATA_CORRELATOR_MIN_LEN_OPTION_TEXT, "5" },
		{ VTOptionDefines.SYMBOL_CORRELATOR_MIN_LEN_OPTION, VTOptionDefines.SYMBOL_CORRELATOR_MIN_LEN_OPTION_TEXT, "3" },
		{ VTOptionDefines.FUNCTION_CORRELATOR_MIN_LEN_OPTION, VTOptionDefines.FUNCTION_CORRELATOR_MIN_LEN_OPTION_TEXT, "10" },
		{ VTOptionDefines.DUPE_FUNCTION_CORRELATOR_MIN_LEN_OPTION, VTOptionDefines.DUPE_FUNCTION_CORRELATOR_MIN_LEN_OPTION_TEXT, "10" },
		{ VTOptionDefines.REF_CORRELATOR_MIN_SCORE_OPTION, VTOptionDefines.REF_CORRELATOR_MIN_SCORE_OPTION_TEXT, "0.95" },
		{ VTOptionDefines.REF_CORRELATOR_MIN_CONF_OPTION, VTOptionDefines.REF_CORRELATOR_MIN_CONF_OPTION_TEXT, "10.0" },
	};

	private static ToolOptions autoDefaults() {
		ToolOptions o = new VTOptions("Auto");
		for (String[] opt : AUTO_OPTIONS) {
			String v = opt[2];
			if (v.equals("true") || v.equals("false")) {
				o.setBoolean(opt[0], Boolean.parseBoolean(v));
			}
			else if (v.contains(".")) {
				o.setDouble(opt[0], Double.parseDouble(v));
			}
			else {
				o.setInt(opt[0], Integer.parseInt(v));
			}
		}
		return o;
	}

	static List<Map<String, Object>> autoOptions() {
		List<Map<String, Object>> out = new ArrayList<>();
		for (String[] opt : AUTO_OPTIONS) {
			String v = opt[2];
			out.add(map("name", opt[0], "label", opt[1], "value", v, "choices", List.of(), "description", null,
				"type", v.equals("true") || v.equals("false") ? "bool" : v.contains(".") ? "double" : "int"));
		}
		return out;
	}

	/** Auto Version Tracking: runs the exact, duplicate and reference correlators and applies the good matches. */
	Map<String, Object> auto(JsonObject values, TaskMonitor monitor) throws Exception {
		VTSessionDB s = session();
		ToolOptions options = autoDefaults();
		applyValues(options, values);
		AutoVersionTrackingTask task = new AutoVersionTrackingTask(s, options);
		task.run(monitor);
		matchInfos.clearCache();
		invalidateDestination();
		return map("message", task.getStatusMsg(), "state", state());
	}

	// ---------------------------------------------------------------- matches

	private static String key(VTMatch m) {
		return m.getMatchSet().getID() + ":" + m.getSourceAddress() + ":" + m.getDestinationAddress();
	}

	private VTMatch match(String key) {
		// addresses may contain "space:offset", so match against the rendered key instead of parsing
		int id = Integer.parseInt(key.substring(0, key.indexOf(':')));
		for (VTMatchSet set : session().getMatchSets()) {
			if (set.getID() != id) {
				continue;
			}
			for (VTMatch m : set.getMatches()) {
				if (key.equals(key(m))) {
					return m;
				}
			}
		}
		throw new IllegalArgumentException("No se encontró la coincidencia " + key);
	}

	private List<VTMatch> matches(List<String> keys) {
		Set<String> wanted = new HashSet<>(keys);
		List<VTMatch> out = new ArrayList<>();
		for (VTMatchSet set : session().getMatchSets()) {
			for (VTMatch m : set.getMatches()) {
				if (wanted.contains(key(m))) {
					out.add(m);
				}
			}
		}
		return out;
	}

	private static String label(Program p, Address a) {
		Function f = p.getFunctionManager().getFunctionAt(a);
		if (f != null) {
			return f.getName(true);
		}
		Symbol sym = p.getSymbolTable().getPrimarySymbol(a);
		return sym != null ? sym.getName(true) : a.toString();
	}

	List<Map<String, Object>> matchList(String filter, String status, int setId) {
		VTSessionDB s = session();
		Program dest = s.getDestinationProgram();
		String needle = filter == null ? "" : filter.toLowerCase();
		List<Map<String, Object>> out = new ArrayList<>();
		for (VTMatchSet set : s.getMatchSets()) {
			if (setId >= 0 && set.getID() != setId) {
				continue;
			}
			String correlator = set.getProgramCorrelatorInfo().getName();
			for (VTMatch m : set.getMatches()) {
				if (out.size() >= MAX_ROWS) {
					return out;
				}
				VTAssociation a = m.getAssociation();
				String st = a.getStatus().name();
				if (status != null && !status.isBlank() && !status.equalsIgnoreCase(st)) {
					continue;
				}
				String srcName = label(source, m.getSourceAddress());
				String dstName = label(dest, m.getDestinationAddress());
				if (!needle.isEmpty() && !srcName.toLowerCase().contains(needle) &&
					!dstName.toLowerCase().contains(needle) &&
					!m.getSourceAddress().toString().contains(needle) &&
					!m.getDestinationAddress().toString().contains(needle)) {
					continue;
				}
				VTMatchTag tag = m.getTag();
				out.add(map("key", key(m), "set", set.getID(), "correlator", correlator,
					"type", a.getType().name(), "status", st, "markup", a.getMarkupStatus().getDescription(),
					"score", num(m.getSimilarityScore().getScore()),
					"confidence", num(m.getConfidenceScore().getLog10Score()),
					"votes", a.getVoteCount(), "sourceAddress", str(m.getSourceAddress()), "sourceName", srcName,
					"sourceLength", m.getSourceLength(), "destinationAddress", str(m.getDestinationAddress()),
					"destinationName", dstName, "destinationLength", m.getDestinationLength(),
					"tag", tag != null ? tag.getName() : ""));
			}
		}
		return out;
	}

	private void invalidateDestination() {
		Session d = destinationSession();
		if (d != null) {
			d.invalidate();
		}
	}

	private interface Work {
		void run() throws Exception;
	}

	private Map<String, Object> transact(String name, Work work) throws Exception {
		VTSessionDB s = session();
		int tx = s.startTransaction(name);
		boolean ok = false;
		try {
			work.run();
			ok = true;
		}
		finally {
			s.endTransaction(tx, ok);
		}
		invalidateDestination();
		return state();
	}

	private static void check(VtTask task) {
		if (task.hasErrors()) {
			throw new IllegalStateException(task.getErrorDetails());
		}
	}

	/** Accepts matches and applies the function / data name, like the Accept action. */
	Map<String, Object> accept(List<String> keys, TaskMonitor monitor) throws Exception {
		List<VTMatch> list = matches(keys);
		return transact("Accept Matches", () -> {
			for (VTMatch m : list) {
				VTAssociation a = m.getAssociation();
				if (a.getStatus() != VTAssociationStatus.AVAILABLE) {
					continue;
				}
				a.setAccepted();
				for (VTMarkupItem item : items(m, monitor)) {
					String type = item.getMarkupType().getDisplayName();
					boolean isName = a.getType() == VTAssociationType.FUNCTION ? type.equals("Function Name")
							: type.equals("Label") && a.getSourceAddress().equals(item.getSourceAddress());
					if (isName && item.canApply()) {
						if (item.getDestinationAddress() == null) {
							item.setDestinationAddress(a.getDestinationAddress());
						}
						try {
							item.apply(VTMarkupItemApplyActionType.REPLACE, applyOptions);
						}
						catch (Exception e) {
							// leave the name unapplied
						}
					}
				}
			}
		});
	}

	/** Accepts matches and applies all their markup, like the Apply action. */
	Map<String, Object> apply(List<String> keys, TaskMonitor monitor) throws Exception {
		List<VTMatch> list = matches(keys);
		return transact("Apply Matches", () -> {
			for (VTMatch m : list) {
				monitor.checkCancelled();
				VTAssociation a = m.getAssociation();
				if (!a.getStatus().canApply()) {
					continue;
				}
				if (a.getStatus() != VTAssociationStatus.ACCEPTED) {
					a.setAccepted();
				}
				Collection<VTMarkupItem> items = items(m, monitor);
				if (items != null && !items.isEmpty()) {
					ApplyMarkupItemTask task = new ApplyMarkupItemTask(session, items, applyOptions);
					task.run(monitor);
					check(task);
				}
			}
		});
	}

	Map<String, Object> reject(List<String> keys, TaskMonitor monitor) throws Exception {
		List<VTMatch> list = matches(keys);
		return transact("Reject Matches", () -> {
			RejectMatchTask task = new RejectMatchTask(session, list);
			task.run(monitor);
			check(task);
		});
	}

	/** Back to "available": unapplies any applied markup first. */
	Map<String, Object> clear(List<String> keys, TaskMonitor monitor) throws Exception {
		List<VTMatch> list = matches(keys);
		return transact("Clear Matches", () -> {
			for (VTMatch m : list) {
				VTAssociation a = m.getAssociation();
				VTAssociationStatus st = a.getStatus();
				if (st == VTAssociationStatus.BLOCKED || st == VTAssociationStatus.AVAILABLE) {
					continue;
				}
				for (VTMarkupItem item : items(m, monitor)) {
					if (item.canUnapply()) {
						item.unapply();
					}
					VTMarkupItemStatus is = item.getStatus();
					if (!is.isDefault() && !is.isUnappliable()) {
						item.setConsidered(VTMarkupItemConsideredStatus.UNCONSIDERED);
					}
				}
				a.clearStatus();
			}
		});
	}

	Map<String, Object> remove(List<String> keys, TaskMonitor monitor) throws Exception {
		List<VTMatch> list = matches(keys);
		Map<String, Object> st = transact("Remove Matches", () -> {
			RemoveMatchTask task = new RemoveMatchTask(session, list);
			task.run(monitor);
		});
		matchInfos.clearCache();
		return st;
	}

	Map<String, Object> manualMatch(String sourceAddress, String destinationAddress, TaskMonitor monitor)
			throws Exception {
		Program dest = session().getDestinationProgram();
		Function sf = source.getFunctionManager().getFunctionContaining(address(source, sourceAddress));
		Function df = dest.getFunctionManager().getFunctionContaining(address(dest, destinationAddress));
		if (sf == null || df == null) {
			throw new IllegalArgumentException("Hace falta una función en el origen y otra en el destino");
		}
		String[] created = new String[1];
		Map<String, Object> st = transact("Create Manual Match", () -> {
			CreateManualMatchTask task = new CreateManualMatchTask(session, sf, df);
			task.run(monitor);
			check(task);
			if (task.getNewMatch() != null) {
				created[0] = key(task.getNewMatch());
			}
		});
		st.put("key", created[0]);
		return st;
	}

	private static Address address(Program p, String text) {
		Address a = p.getAddressFactory().getAddress(text);
		if (a == null) {
			throw new IllegalArgumentException("Dirección inválida: " + text);
		}
		return a;
	}

	// ---------------------------------------------------------------- tags & implied matches

	List<String> tags() {
		List<String> out = new ArrayList<>();
		for (VTMatchTag t : session().getMatchTags()) {
			out.add(t.getName());
		}
		Collections.sort(out);
		return out;
	}

	/** Tags the matches (an empty name removes the tag); the tag is created if it does not exist. */
	Map<String, Object> setTag(List<String> keys, String name) throws Exception {
		List<VTMatch> list = matches(keys);
		return transact("Tag Matches", () -> {
			VTMatchTag tag = null;
			if (name != null && !name.isBlank()) {
				for (VTMatchTag t : session.getMatchTags()) {
					if (t.getName().equals(name)) {
						tag = t;
					}
				}
				if (tag == null) {
					tag = session.createMatchTag(name);
				}
			}
			for (VTMatch m : list) {
				m.setTag(tag);
			}
		});
	}

	Object deleteTag(String name) throws Exception {
		transact("Delete Tag", () -> {
			for (VTMatchTag t : new ArrayList<>(session.getMatchTags())) {
				if (t.getName().equals(name)) {
					session.deleteMatchTag(t);
				}
			}
		});
		return tags();
	}

	/**
	 * Matches implied by a function match: what the source function references paired with what
	 * the destination function references at the corresponding place.
	 */
	List<Map<String, Object>> implied(String key, TaskMonitor monitor) throws Exception {
		VTMatch m = match(key);
		Program dest = session().getDestinationProgram();
		Function sf = source.getFunctionManager().getFunctionAt(m.getSourceAddress());
		Function df = dest.getFunctionManager().getFunctionAt(m.getDestinationAddress());
		List<Map<String, Object>> out = new ArrayList<>();
		if (sf == null || df == null) {
			return out;
		}
		for (VTImpliedMatchInfo info : ghidra.feature.vt.gui.util.ImpliedMatchUtils.findImpliedMatches(sf, df, session,
			correlators, monitor)) {
			VTAssociation existing = session.getAssociationManager().getAssociation(info.getSourceAddress(),
				info.getDestinationAddress());
			out.add(map("sourceAddress", str(info.getSourceAddress()), "sourceName", label(source, info.getSourceAddress()),
				"destinationAddress", str(info.getDestinationAddress()),
				"destinationName", label(dest, info.getDestinationAddress()),
				"type", info.getAssociationType().name(),
				"status", existing != null ? existing.getStatus().name() : null,
				"sourceReference", str(info.getSourceReferenceAddress()),
				"destinationReference", str(info.getDestinationReferenceAddress())));
		}
		out.sort(Comparator.comparing(o -> (String) o.get("sourceAddress")));
		return out;
	}

	/** Turns implied matches of a function match into real matches of the "Implied Match" set. */
	Map<String, Object> createImplied(String key, List<String> pairs, TaskMonitor monitor) throws Exception {
		VTMatch m = match(key);
		Program dest = session().getDestinationProgram();
		Function sf = source.getFunctionManager().getFunctionAt(m.getSourceAddress());
		Function df = dest.getFunctionManager().getFunctionAt(m.getDestinationAddress());
		Set<String> wanted = new HashSet<>(pairs);
		Set<VTImpliedMatchInfo> infos = ghidra.feature.vt.gui.util.ImpliedMatchUtils.findImpliedMatches(sf, df, session,
			correlators, monitor);
		return transact("Create Implied Matches", () -> {
			VTMatchSet set = session.getImpliedMatchSet();
			for (VTImpliedMatchInfo info : infos) {
				if (wanted.isEmpty() || wanted.contains(info.getSourceAddress() + ">" + info.getDestinationAddress())) {
					if (set.getMatches(info.getSourceAddress(), info.getDestinationAddress()).isEmpty()) {
						set.addMatch(info);
					}
				}
			}
		});
	}

	// ---------------------------------------------------------------- markup

	private Collection<VTMarkupItem> items(VTMatch m, TaskMonitor monitor) {
		MatchInfo info = matchInfos.getMatchInfo(m, correlators);
		Collection<VTMarkupItem> items = info.getAppliableMarkupItems(monitor);
		return items != null ? items : List.of();
	}

	private List<VTMarkupItem> ordered(VTMatch m) {
		List<VTMarkupItem> list = new ArrayList<>(items(m, TaskMonitor.DUMMY));
		list.sort(Comparator.comparing((VTMarkupItem i) -> i.getSourceAddress())
				.thenComparing(i -> i.getMarkupType().getDisplayName()));
		return list;
	}

	private static String value(ghidra.feature.vt.api.util.Stringable s) {
		return s != null ? s.getDisplayString() : null;
	}

	/** Functions of both programs and whether each already has an accepted match (the VT functions table). */
	Map<String, Object> functions() {
		VTSessionDB s = session();
		Program dest = s.getDestinationProgram();
		Set<Address> sourceMatched = new HashSet<>(), destMatched = new HashSet<>();
		Set<Address> sourceAny = new HashSet<>(), destAny = new HashSet<>();
		for (VTAssociation a : s.getAssociationManager().getAssociations()) {
			sourceAny.add(a.getSourceAddress());
			destAny.add(a.getDestinationAddress());
			if (a.getStatus() == VTAssociationStatus.ACCEPTED) {
				sourceMatched.add(a.getSourceAddress());
				destMatched.add(a.getDestinationAddress());
			}
		}
		return map("source", functionRows(source, sourceMatched, sourceAny),
			"destination", functionRows(dest, destMatched, destAny));
	}

	private static List<Map<String, Object>> functionRows(Program p, Set<Address> accepted, Set<Address> any) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Function f : p.getFunctionManager().getFunctions(true)) {
			if (out.size() >= 50000) {
				break;
			}
			Address a = f.getEntryPoint();
			out.add(map("address", str(a), "name", f.getName(true), "size", f.getBody().getNumAddresses(),
				"signature", f.getPrototypeString(false, false),
				"state", accepted.contains(a) ? "accepted" : any.contains(a) ? "candidate" : "unmatched",
				"thunk", f.isThunk()));
		}
		return out;
	}

	/** Changes where one markup item will be applied in the destination program. */
	Map<String, Object> setMarkupAddress(String key, int index, String addressText) throws Exception {
		VTMatch m = match(key);
		List<VTMarkupItem> all = ordered(m);
		if (index < 0 || index >= all.size()) {
			throw new IllegalArgumentException("Elemento desconocido");
		}
		VTMarkupItem item = all.get(index);
		Address a = addressText == null || addressText.isBlank() ? null
				: address(session().getDestinationProgram(), addressText);
		Map<String, Object> st = transact("Set Markup Destination", () -> item.setDestinationAddress(a));
		st.put("markup", markup(key));
		return st;
	}

	List<Map<String, Object>> markup(String key) {
		VTMatch m = match(key);
		List<Map<String, Object>> out = new ArrayList<>();
		int i = 0;
		for (VTMarkupItem item : ordered(m)) {
			out.add(map("index", i++, "type", item.getMarkupType().getDisplayName(),
				"status", item.getStatus().name(), "statusText", item.getStatus().getDescription(),
				"detail", item.getStatusDescription(), "sourceAddress", str(item.getSourceAddress()),
				"sourceValue", value(item.getSourceValue()), "destinationAddress", str(item.getDestinationAddress()),
				"destinationValue", value(item.getCurrentDestinationValue()),
				"originalValue", value(item.getOriginalDestinationValue()),
				"canApply", item.canApply(), "canUnapply", item.canUnapply()));
		}
		return out;
	}

	Map<String, Object> applyMarkup(String key, List<Integer> indices, boolean apply, TaskMonitor monitor)
			throws Exception {
		VTMatch m = match(key);
		List<VTMarkupItem> all = ordered(m);
		List<VTMarkupItem> chosen = new ArrayList<>();
		for (int i : indices) {
			if (i >= 0 && i < all.size()) {
				chosen.add(all.get(i));
			}
		}
		Map<String, Object> st = transact(apply ? "Apply Markup" : "Unapply Markup", () -> {
			if (apply) {
				VTAssociation a = m.getAssociation();
				if (a.getStatus() == VTAssociationStatus.AVAILABLE) {
					a.setAccepted();
				}
				ApplyMarkupItemTask task = new ApplyMarkupItemTask(session, chosen, applyOptions);
				task.run(monitor);
				check(task);
			}
			else {
				for (VTMarkupItem item : chosen) {
					if (item.canUnapply()) {
						item.unapply();
					}
				}
			}
		});
		st.put("markup", markup(key));
		return st;
	}

	/** Options that decide what "apply" does with each kind of markup (replace, add, exclude…). */
	List<Map<String, Object>> applyOptionList() {
		ToolOptions o = applyOptions;
		// register the defaults so they can be listed and edited
		Object[][] defaults = {
			{ VTOptionDefines.FUNCTION_NAME, VTOptionDefines.DEFAULT_OPTION_FOR_FUNCTION_NAME },
			{ VTOptionDefines.FUNCTION_SIGNATURE, VTOptionDefines.DEFAULT_OPTION_FOR_FUNCTION_SIGNATURE },
			{ VTOptionDefines.FUNCTION_RETURN_TYPE, VTOptionDefines.DEFAULT_OPTION_FOR_FUNCTION_RETURN_TYPE },
			{ VTOptionDefines.PARAMETER_DATA_TYPES, VTOptionDefines.DEFAULT_OPTION_FOR_PARAMETER_DATA_TYPES },
			{ VTOptionDefines.PARAMETER_NAMES, VTOptionDefines.DEFAULT_OPTION_FOR_PARAMETER_NAMES },
			{ VTOptionDefines.PARAMETER_COMMENTS, VTOptionDefines.DEFAULT_OPTION_FOR_PARAMETER_COMMENTS },
			{ VTOptionDefines.CALLING_CONVENTION, VTOptionDefines.DEFAULT_OPTION_FOR_CALLING_CONVENTION },
			{ VTOptionDefines.INLINE, VTOptionDefines.DEFAULT_OPTION_FOR_INLINE },
			{ VTOptionDefines.NO_RETURN, VTOptionDefines.DEFAULT_OPTION_FOR_NO_RETURN },
			{ VTOptionDefines.VAR_ARGS, VTOptionDefines.DEFAULT_OPTION_FOR_VAR_ARGS },
			{ VTOptionDefines.CALL_FIXUP, VTOptionDefines.DEFAULT_OPTION_FOR_CALL_FIXUP },
			{ VTOptionDefines.LABELS, VTOptionDefines.DEFAULT_OPTION_FOR_LABELS },
			{ VTOptionDefines.DATA_MATCH_DATA_TYPE, VTOptionDefines.DEFAULT_OPTION_FOR_DATA_MATCH_DATA_TYPE },
			{ VTOptionDefines.PLATE_COMMENT, VTOptionDefines.DEFAULT_OPTION_FOR_PLATE_COMMENTS },
			{ VTOptionDefines.PRE_COMMENT, VTOptionDefines.DEFAULT_OPTION_FOR_PRE_COMMENTS },
			{ VTOptionDefines.END_OF_LINE_COMMENT, VTOptionDefines.DEFAULT_OPTION_FOR_EOL_COMMENTS },
			{ VTOptionDefines.REPEATABLE_COMMENT, VTOptionDefines.DEFAULT_OPTION_FOR_REPEATABLE_COMMENTS },
			{ VTOptionDefines.POST_COMMENT, VTOptionDefines.DEFAULT_OPTION_FOR_POST_COMMENTS },
		};
		Map<String, String> labels = new HashMap<>();
		for (Object[] d : defaults) {
			String name = (String) d[0];
			if (!o.contains(name)) {
				setEnum(o, name, (Enum<?>) d[1]);
			}
			labels.put(name, name.substring(name.lastIndexOf('.') + 1));
		}
		return describe(o, labels);
	}

	@SuppressWarnings({ "unchecked", "rawtypes" })
	private static void setEnum(ToolOptions o, String name, Enum value) {
		o.setEnum(name, value);
	}

	Object setApplyOptions(JsonObject values) {
		applyOptionList();
		applyValues(applyOptions, values);
		return applyOptionList();
	}
}
