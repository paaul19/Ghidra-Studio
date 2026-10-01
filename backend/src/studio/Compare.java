package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.app.plugin.match.*;
import ghidra.framework.model.DomainFile;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.util.ProgramDiff;
import ghidra.program.util.ProgramDiffFilter;
import ghidra.util.task.TaskMonitor;

/** Program Diff and function correlation (the core of Version Tracking). */
final class Compare {
	private static final int MAX_DIFFS = 3000;

	private Compare() {
	}

	/** Runs body with the other program opened read-only (or the already open session). */
	private static <T> T withOther(Session s, String domainPath, java.util.function.Function<Program, T> body)
			throws Exception {
		Session open = s.server.sessionFor(domainPath);
		if (open != null) {
			return body.apply(open.program);
		}
		DomainFile df = s.server.project().getProjectData().getFile(domainPath);
		if (df == null) {
			throw new IllegalArgumentException("No existe " + domainPath);
		}
		Object consumer = new Object();
		Program other = (Program) df.getReadOnlyDomainObject(consumer, DomainFile.DEFAULT_VERSION, TaskMonitor.DUMMY);
		try {
			return body.apply(other);
		}
		finally {
			other.release(consumer);
		}
	}

	private static final Object[][] TYPES = {
		{ ProgramDiffFilter.BYTE_DIFFS, "Bytes" },
		{ ProgramDiffFilter.CODE_UNIT_DIFFS, "Código/datos" },
		{ ProgramDiffFilter.SYMBOL_DIFFS, "Símbolos" },
		{ ProgramDiffFilter.FUNCTION_DIFFS, "Funciones" },
		{ ProgramDiffFilter.COMMENT_DIFFS, "Comentarios" },
		{ ProgramDiffFilter.REFERENCE_DIFFS, "Referencias" },
		{ ProgramDiffFilter.EQUATE_DIFFS, "Equates" },
		{ ProgramDiffFilter.BOOKMARK_DIFFS, "Marcadores" },
		{ ProgramDiffFilter.PROGRAM_CONTEXT_DIFFS, "Contexto" },
	};

	static Map<String, Object> diff(Session s, String other, Set<String> kinds) throws Exception {
		return withOther(s, other, b -> {
			try {
				ProgramDiff diff = new ProgramDiff(s.program, b);
				List<Map<String, Object>> rows = new ArrayList<>();
				AddressSetView common = diff.getAddressesInCommon();
				FunctionManager fm = s.program.getFunctionManager();
				for (Object[] t : TYPES) {
					String label = (String) t[1];
					if (!kinds.isEmpty() && !kinds.contains(label)) {
						continue;
					}
					AddressSetView set = diff.getTypeDiffs((Integer) t[0], common, TaskMonitor.DUMMY);
					for (AddressRange r : set) {
						if (rows.size() >= MAX_DIFFS) {
							break;
						}
						Function f = fm.getFunctionContaining(r.getMinAddress());
						rows.add(map("address", str(r.getMinAddress()), "end", str(r.getMaxAddress()), "kind", label,
							"length", r.getLength(), "function", f != null ? f.getName(true) : null));
					}
				}
				rows.sort(Comparator.comparing(o -> (String) o.get("address")));
				return map("differences", rows, "onlyInThis", ranges(diff.getAddressesOnlyInOne()),
					"onlyInOther", ranges(diff.getAddressesOnlyInTwo()), "warnings", diff.getWarnings(),
					"truncated", rows.size() >= MAX_DIFFS);
			}
			catch (ghidra.program.util.ProgramConflictException e) {
				throw new IllegalArgumentException("No se pueden comparar: " + e.getMessage());
			}
			catch (Exception e) {
				throw new IllegalStateException(e.getMessage(), e);
			}
		});
	}

	private static List<String> ranges(AddressSetView set) {
		List<String> list = new ArrayList<>();
		for (AddressRange r : set) {
			if (list.size() >= 200) {
				break;
			}
			list.add(r.getMinAddress() + " – " + r.getMaxAddress());
		}
		return list;
	}

	private static FunctionHasher hasher(String method) {
		return switch (method) {
			case "bytes" -> ExactBytesFunctionHasher.INSTANCE;
			case "mnemonics" -> ExactMnemonicsFunctionHasher.INSTANCE;
			default -> ExactInstructionsFunctionHasher.INSTANCE;
		};
	}

	/** Matches functions of this program (A) against another (B). */
	static List<Map<String, Object>> matchFunctions(Session s, String other, String method, int minSize)
			throws Exception {
		return withOther(s, other, b -> {
			try {
				List<MatchFunctions.MatchedFunctions> matches = MatchFunctions.matchFunctions(s.program,
					s.program.getMemory(), b, b.getMemory(), Math.max(1, minSize), true, false, hasher(method),
					TaskMonitor.DUMMY);
				FunctionManager fa = s.program.getFunctionManager();
				FunctionManager fb = b.getFunctionManager();
				List<Map<String, Object>> out = new ArrayList<>();
				for (MatchFunctions.MatchedFunctions m : matches) {
					Function a = fa.getFunctionAt(m.getAFunctionAddress());
					Function o = fb.getFunctionAt(m.getBFunctionAddress());
					if (a == null || o == null) {
						continue;
					}
					boolean otherNamed = o.getSymbol().getSource() != SourceType.DEFAULT;
					out.add(map("address", str(a.getEntryPoint()), "name", a.getName(true),
						"otherAddress", str(o.getEntryPoint()), "otherName", o.getName(true),
						"sameName", a.getName().equals(o.getName()), "otherNamed", otherNamed,
						"size", a.getBody().getNumAddresses()));
				}
				out.sort(Comparator.comparing(o -> (String) o.get("address")));
				return out;
			}
			catch (Exception e) {
				throw new IllegalStateException(e.getMessage(), e);
			}
		});
	}

	/** Copies function names (and plate comments) from the other program onto matched functions here. */
	static Object applyNames(Session s, String other, List<String[]> pairs, boolean comments) throws Exception {
		Map<Address, String[]> names = withOther(s, other, b -> {
			Map<Address, String[]> m = new LinkedHashMap<>();
			for (String[] pair : pairs) {
				Function o = b.getFunctionManager().getFunctionAt(b.getAddressFactory().getAddress(pair[1]));
				if (o != null && o.getSymbol().getSource() != SourceType.DEFAULT) {
					m.put(s.addr(pair[0]), new String[] { o.getName(), o.getComment() });
				}
			}
			return m;
		});
		return s.edit("Aplicar nombres", () -> {
			int applied = 0;
			for (Map.Entry<Address, String[]> e : names.entrySet()) {
				Function f = s.program.getFunctionManager().getFunctionAt(e.getKey());
				if (f == null) {
					continue;
				}
				try {
					f.setName(e.getValue()[0], SourceType.IMPORTED);
					if (comments && e.getValue()[1] != null) {
						f.setComment(e.getValue()[1]);
					}
					applied++;
				}
				catch (Exception ignored) {
					// duplicate names: skip
				}
			}
			return map("applied", applied);
		});
	}
}
