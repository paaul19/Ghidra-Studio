package studio;

import static studio.Json.*;

import java.io.File;
import java.io.InputStream;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

import ghidra.app.decompiler.*;
import ghidra.app.plugin.core.decompiler.taint.TaintState;
import ghidra.framework.Application;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.pcode.HighVariable;
import ghidra.util.task.TaskMonitor;

/**
 * Taint analysis with CTADL, the external engine the classic uses: the program's p-code is exported as facts
 * (with Ghidra's own script), CTADL indexes them, and each query is a Datalog file made from the marked
 * sources and sinks whose answer comes back as SARIF.
 */
final class Ctadl {
	private Ctadl() {
	}

	private static File base(StudioServer server, Session s) {
		String name = s.program.getDomainFile().getPathname().replaceAll("[^A-Za-z0-9._-]", "_");
		File dir = new File(new File(server.supportDir(), "ctadl"), name);
		dir.mkdirs();
		return dir;
	}

	private static void checkEngine(String engine) {
		File f = new File(engine == null ? "" : engine);
		if (!f.isFile() || !f.canExecute()) {
			throw new IllegalArgumentException("No se encuentra el ejecutable de CTADL. Instálalo (pip install ctadl) "
				+ "y elige dónde está.");
		}
	}

	private static File exportScript() throws Exception {
		for (generic.jar.ResourceFile dir : Application.findModuleSubDirectories("ghidra_scripts")) {
			generic.jar.ResourceFile f = new generic.jar.ResourceFile(dir, "ExportPCodeForCTADL.java");
			if (f.exists()) {
				return f.getFile(false);
			}
		}
		throw new IllegalStateException("Falta el script ExportPCodeForCTADL.java de Ghidra");
	}

	static Map<String, Object> status(StudioServer server, Session s, String engine) {
		File dir = base(server, s);
		File facts = new File(dir, "facts");
		File index = new File(new File(dir, "index"), "ctadlir.db");
		String[] factFiles = facts.list((d, n) -> n.endsWith(".facts"));
		File e = new File(engine == null ? "" : engine);
		return map("engine", e.isFile() && e.canExecute(), "facts", factFiles == null ? 0 : factFiles.length, "indexed",
			index.exists(), "directory", dir.getPath(), "query", new File(new File(dir, "index"), "taintquery.dl").getPath());
	}

	private static String runProcess(List<String> cmd, File dir, TaskMonitor monitor, StringBuilder errors)
			throws Exception {
		Process p = new ProcessBuilder(cmd).directory(dir).start();
		monitor.addCancelledListener(p::destroyForcibly);
		Thread drain = new Thread(() -> {
			try (InputStream in = p.getErrorStream()) {
				String text = new String(in.readAllBytes(), StandardCharsets.UTF_8);
				synchronized (errors) {
					errors.append(text);
				}
			}
			catch (Exception e) {
				// the process ended
			}
		});
		drain.start();
		String out;
		try (InputStream in = p.getInputStream()) {
			out = new String(in.readAllBytes(), StandardCharsets.UTF_8);
		}
		int code = p.waitFor();
		drain.join(2000);
		monitor.checkCancelled();
		if (code != 0) {
			String detail;
			synchronized (errors) {
				detail = errors.toString().strip();
			}
			String last = detail.isEmpty() ? "" : detail.substring(Math.max(0, detail.length() - 600));
			throw new IllegalStateException("CTADL terminó con error " + code + (last.isEmpty() ? "" : ": " + last));
		}
		return out;
	}

	/** Exports the facts of the whole program and builds CTADL's index from them. */
	static Map<String, Object> index(StudioServer server, Session s, String engine, TaskMonitor monitor) throws Exception {
		checkEngine(engine);
		File dir = base(server, s);
		File facts = new File(dir, "facts");
		File index = new File(dir, "index");
		facts.mkdirs();
		index.mkdirs();
		monitor.setMessage("Exportando el p-code");
		Map<String, Object> ran = Scripts.run(s, exportScript().getPath(), null, new String[] { facts.getPath() }, monitor);
		Object error = ran.get("error");
		if (error != null) {
			throw new IllegalStateException("No se pudo exportar el p-code: " + error);
		}
		monitor.setMessage("Indexando con CTADL");
		StringBuilder errors = new StringBuilder();
		runProcess(List.of(engine, "--directory", index.getPath(), "index", "-j8", "-f", facts.getPath()), facts, monitor,
			errors);
		return status(server, s, engine);
	}

	private static ClangToken token(ClangNode node, String name) {
		if (node instanceof ClangToken t) {
			return (t instanceof ClangVariableToken || t instanceof ClangFuncNameToken) && t.getText().equals(name) ? t : null;
		}
		for (int i = 0; i < node.numChildren(); i++) {
			ClangToken found = token(node.Child(i), name);
			if (found != null) {
				return found;
			}
		}
		return null;
	}

	/** The rule the classic writes for a mark: a function (its return value) or a variable of the function. */
	private static void rule(PrintWriter w, Session s, Function f, ClangTokenGroup markup, String name, boolean source,
			boolean allAccess) {
		String method = source ? "TaintSource" : "LeakingSink";
		ClangToken token = markup == null ? null : token(markup, name);
		boolean isFunction = token instanceof ClangFuncNameToken
			|| (token == null && !s.program.getListing().getGlobalFunctions(name).isEmpty());
		if (isFunction) {
			w.println(method + "Vertex(\"" + name + "\", vn, p) :-");
			w.println("\tHFUNC_NAME(f, \"" + name + "\"),");
			w.println("\tCFunction_FormalParam(f, n, vn),");
			w.println("\tCReturnParameter(n),");
			w.println("\tVertex(vn, p).");
			return;
		}
		HighVariable hv = token == null ? null : token.getHighVariable();
		String var = token == null ? name : TaintState.varName(token, false);
		w.println(method + "Vertex(\"" + name + "\", vn, p) :-");
		w.println("\t((HFUNC_NAME(m, \"" + f.getName() + "\"),");
		w.println("\tCVar_InFunction(vn, m)) ; CVar_isGlobal(vn)),");
		if (hv != null) {
			w.println("\tCVar_SourceInfo(vn, SOURCE_INFO_NAME_KEY, \"" + var + "\"),");
		}
		else {
			w.println("\t(CVar_SourceInfo(vn, SOURCE_INFO_NAME_KEY, \"" + var + "\");");
			w.println("\tSYMBOL_NAME(sym, \"" + name + "\"), SYMBOL_HVAR(sym, hv), VNODE_HVAR(vn, hv)),");
		}
		if (!allAccess) {
			w.println("\tp = \"\",");
		}
		w.println("\tVertex(vn, p).");
	}

	/**
	 * Runs a source/sink query (or a Datalog file of the user's) and returns the SARIF results as rows.
	 * {@code direction} is "", "fwd", "bwd" or "all".
	 */
	static Map<String, Object> query(StudioServer server, Session s, String engine, Address fn, List<String> sources,
			List<String> sinks, String direction, String format, boolean allAccess, String custom, TaskMonitor monitor)
			throws Exception {
		checkEngine(engine);
		File dir = base(server, s);
		File index = new File(dir, "index");
		if (!new File(index, "ctadlir.db").exists()) {
			throw new IllegalStateException("Este programa todavía no tiene índice de CTADL: créalo primero");
		}
		File queryFile;
		if (custom != null && !custom.isBlank()) {
			queryFile = new File(custom);
			if (!queryFile.isFile()) {
				throw new IllegalArgumentException("No existe el archivo de consulta " + custom);
			}
		}
		else {
			if (sources.isEmpty() && sinks.isEmpty()) {
				throw new IllegalArgumentException("Marca al menos una fuente o un sumidero");
			}
			Function f = s.functionContaining(fn);
			ClangTokenGroup markup = s.decompileRaw(f).getCCodeMarkup();
			queryFile = new File(index, "taintquery.dl");
			try (PrintWriter w = new PrintWriter(queryFile, StandardCharsets.UTF_8)) {
				w.println("#include \"pcode/taintquery.dl\"");
				for (String name : sources) {
					if (!name.startsWith("#")) {
						rule(w, s, f, markup, name, true, allAccess);
					}
				}
				for (String name : sinks) {
					rule(w, s, f, markup, name, false, allAccess);
				}
			}
		}
		List<String> cmd = new ArrayList<>(List.of(engine, "--directory", index.getPath(), "query"));
		if (direction != null && !direction.isBlank()) {
			cmd.add("--compute-slices");
			cmd.add(direction);
		}
		cmd.add("--no-compile-analysis");
		cmd.add("-j8");
		cmd.add("--format=" + (format == null || format.isBlank() ? "sarif+all" : format));
		cmd.add(queryFile.getAbsolutePath());
		monitor.setMessage("Consultando con CTADL");
		StringBuilder errors = new StringBuilder();
		String sarif = runProcess(cmd, index, monitor, errors);
		File results = new File(dir, "results.sarif");
		Files.writeString(results.toPath(), sarif, StandardCharsets.UTF_8);
		List<Map<String, Object>> rows = sarif.isBlank() ? List.of() : Workbench.sarif(s, results.getPath());
		return map("rows", rows, "sarif", results.getPath(), "query", queryFile.getPath());
	}
}
