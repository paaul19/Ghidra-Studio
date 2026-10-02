package studio;

import static studio.Json.*;

import java.util.*;
import java.util.function.BiFunction;

import ghidra.app.script.GhidraState;
import ghidra.program.model.address.Address;
import ghidra.program.util.ProgramLocation;

/**
 * Python support (PyGhidra). It only exists when the engine is hosted by the bundled CPython
 * (engine.py), which starts the JVM in-process through JPype and registers the evaluator below.
 */
public final class Python {
	/** Set from engine.py: (GhidraState, source) -> text printed by the code. Keeps its variables between calls. */
	public static volatile BiFunction<Object, String, String> evaluator;
	/** Set from engine.py: raises KeyboardInterrupt in the Python code that is running. */
	public static volatile Runnable interrupter;

	static void interrupt() {
		Runnable r = interrupter;
		if (r != null) {
			try {
				r.run();
			}
			catch (Throwable t) {
				t.printStackTrace();
			}
		}
	}

	private Python() {
	}

	static boolean available() {
		return evaluator != null;
	}

	static String version() {
		return System.getProperty("studio.python");
	}

	static void require() {
		if (!available()) {
			throw new IllegalStateException("Python no está disponible: el motor no se inició con PyGhidra");
		}
	}

	/** Names that complete a partial expression in the interpreter's namespace. */
	static List<String> complete(StudioServer server, Session s, String text) {
		require();
		// with the program in scope, currentProgram and the flat API complete too
		GhidraState state = new GhidraState(null, server.projectOrNull(), s != null ? s.program : null, null, null, null);
		String out = evaluator.apply(state, "\u0000complete:" + text);
		List<String> list = new ArrayList<>();
		for (String line : out.split("\n")) {
			if (!line.isBlank()) {
				list.add(line.trim());
			}
		}
		return list;
	}

	/** Forgets the interpreter's variables and imports. */
	static Object reset() {
		require();
		evaluator.apply(null, "\u0000reset");
		return true;
	}

	/** Runs a snippet in the interactive interpreter with currentProgram / currentAddress set. */
	static Map<String, Object> eval(StudioServer server, Session s, String address, String source) {
		require();
		long start = System.currentTimeMillis();
		ProgramLocation loc = null;
		if (s != null && address != null && !address.isBlank()) {
			Address a = s.addr(address);
			loc = new ProgramLocation(s.program, a);
		}
		GhidraState state = new GhidraState(null, server.projectOrNull(), s != null ? s.program : null, loc, null, null);
		int tx = s != null ? s.program.startTransaction("Python") : -1;
		String output;
		try {
			output = evaluator.apply(state, source);
		}
		finally {
			if (s != null) {
				s.program.endTransaction(tx, true);
				s.invalidate();
			}
		}
		return map("output", output, "millis", System.currentTimeMillis() - start);
	}
}
