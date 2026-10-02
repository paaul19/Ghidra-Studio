package studio;

import static studio.Json.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

import generic.jar.ResourceFile;
import ghidra.app.script.*;
import ghidra.program.model.address.Address;
import ghidra.program.util.ProgramLocation;
import ghidra.util.task.TaskMonitorAdapter;

/** Script manager: list, read, write and run Ghidra (Java) scripts headlessly. */
final class Scripts {
	private static boolean initialized;

	private Scripts() {
	}

	private static synchronized void init() {
		if (!initialized) {
			GhidraScriptUtil.acquireBundleHostReference();
			List<ResourceFile> dirs = new ArrayList<>(GhidraScriptUtil.getScriptSourceDirectories());
			ResourceFile user = GhidraScriptUtil.getUserScriptDirectory();
			user.getFile(false).mkdirs();
			if (!dirs.contains(user)) {
				dirs.add(user);
			}
			GhidraScriptUtil.getBundleHost().add(dirs, true, false);
			initialized = true;
		}
	}

	static File userDirectory() {
		init();
		File dir = GhidraScriptUtil.getUserScriptDirectory().getFile(false);
		dir.mkdirs();
		return dir;
	}

	static List<Map<String, Object>> list() {
		init();
		List<Map<String, Object>> out = new ArrayList<>();
		Set<String> seen = new HashSet<>();
		List<ResourceFile> dirs = new ArrayList<>(GhidraScriptUtil.getScriptSourceDirectories());
		ResourceFile user = GhidraScriptUtil.getUserScriptDirectory();
		if (!dirs.contains(user)) {
			dirs.add(0, user);
		}
		for (ResourceFile dir : dirs) {
			ResourceFile[] files = dir.listFiles();
			if (files == null) {
				continue;
			}
			for (ResourceFile f : files) {
				String name = f.getName();
				boolean python = name.endsWith(".py");
				if (!(name.endsWith(".java") || python && Python.available()) || !seen.add(name)) {
					continue;
				}
				Map<String, String> meta = header(f);
				out.add(map("name", name, "path", f.getAbsolutePath(), "category", meta.getOrDefault("category", ""),
					"description", meta.getOrDefault("description", ""),
					"language", python ? "python" : "java", "user", dir.equals(user)));
			}
		}
		out.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
		return out;
	}

	/** Reads the @category tag and the descriptive comment (skipping the license header). */
	private static Map<String, String> header(ResourceFile f) {
		Map<String, String> meta = new HashMap<>();
		List<List<String>> blocks = new ArrayList<>();
		List<String> current = null;
		try (BufferedReader r = new BufferedReader(new InputStreamReader(f.getInputStream(), StandardCharsets.UTF_8))) {
			String line;
			int n = 0;
			while ((line = r.readLine()) != null && n++ < 80) {
				String t = line.trim();
				boolean comment = t.startsWith("//") || t.startsWith("/*") || t.startsWith("*") || t.startsWith("#");
				if (!comment) {
					current = null;
					if (!t.isEmpty() && !t.startsWith("import") && !t.startsWith("package")) {
						break;
					}
					continue;
				}
				if (current == null || t.startsWith("/*")) {
					current = new ArrayList<>();
					blocks.add(current);
				}
				t = t.replaceFirst("^(//+|/\\*+|\\*+/?|#+)\\s?", "").trim();
				if (t.startsWith("@category")) {
					meta.put("category", t.substring(9).trim());
				}
				else if (!t.isEmpty() && !t.startsWith("@") && !t.equals("/")) {
					current.add(t);
				}
				if (line.contains("*/")) {
					current = null;
				}
			}
		}
		catch (IOException ignored) {
			// no metadata
		}
		for (List<String> b : blocks) {
			String text = String.join(" ", b).replaceAll("\\s+", " ").trim();
			if (text.isEmpty() || text.contains("Licensed under") || text.contains("License") || text.startsWith("IP:")
					|| text.contains("REVIEWED")) {
				continue;
			}
			meta.put("description", text.length() > 240 ? text.substring(0, 240) + "…" : text);
			break;
		}
		meta.putIfAbsent("description", "");
		return meta;
	}

	static String read(String path) throws IOException {
		return Files.readString(new File(path).toPath(), StandardCharsets.UTF_8);
	}

	static Map<String, Object> save(String name, String source) throws IOException {
		String file = name.endsWith(".java") || name.endsWith(".py") ? name : name + ".java";
		File f = new File(userDirectory(), file);
		Files.writeString(f.toPath(), source, StandardCharsets.UTF_8);
		return map("path", f.getAbsolutePath(), "name", file);
	}

	static Map<String, Object> run(Session s, String path, String address, String[] args,
			ghidra.util.task.TaskMonitor monitor) throws Exception {
		init();
		if (path.endsWith(".py")) {
			Python.require();
		}
		ResourceFile file = new ResourceFile(new File(path));
		ResourceFile parent = file.getParentFile();
		if (GhidraScriptUtil.getBundleHost().getExistingGhidraBundle(parent) == null) {
			GhidraScriptUtil.getBundleHost().add(parent, true, false);
		}
		GhidraScriptProvider provider = GhidraScriptUtil.getProvider(file);
		if (provider == null) {
			throw new IllegalArgumentException("Tipo de script no soportado: " + file.getName());
		}
		StringWriter buffer = new StringWriter();
		PrintWriter writer = new PrintWriter(buffer, true);
		long start = System.currentTimeMillis();
		String error = null;
		try {
			GhidraScript script = provider.getScriptInstance(file, writer);
			if (args != null && args.length > 0) {
				// In headless mode askString/askInt/askFile... consume these in order.
				script.setScriptArgs(args);
			}
			ProgramLocation loc = null;
			if (address != null) {
				Address a = s.addr(address);
				loc = new ProgramLocation(s.program, a);
			}
			GhidraState state = new GhidraState(null, s.server.project().getProject(), s.program, loc, null, null);
			int tx = s.program.startTransaction("Script " + file.getName());
			boolean ok = false;
			try {
				script.execute(state, monitor, writer);
				ok = true;
			}
			finally {
				s.program.endTransaction(tx, ok);
			}
		}
		catch (Throwable t) {
			Throwable root = t;
			while (root.getCause() != null && root.getCause() != root) {
				root = root.getCause();
			}
			if (monitor.isCancelled()) {
				error = "Cancelado";
			}
			else {
				error = root.getClass().getSimpleName() + ": " + root.getMessage();
				t.printStackTrace(writer);
			}
		}
		writer.flush();
		if (error == null && monitor.isCancelled()) {
			error = "Cancelado";
		}
		s.invalidate();
		return map("output", buffer.toString(), "error", error, "millis", System.currentTimeMillis() - start);
	}
}
