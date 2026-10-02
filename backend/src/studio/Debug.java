package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.Symbol;

/**
 * Program-side support for the debugger. Breakpoints are kept the way the classic Ghidra keeps them — as
 * bookmarks of type BreakpointEnabled / BreakpointDisabled — so both applications see the same ones.
 */
final class Debug {
	static final String ENABLED = "BreakpointEnabled";
	static final String DISABLED = "BreakpointDisabled";
	/** Bookmark category of a software execution breakpoint of length 1: "kinds;length". */
	private static final String EXECUTE = "SW_EXECUTE;1";

	private Debug() {
	}

	static boolean isBreakpoint(Bookmark b) {
		String type = b.getTypeString();
		return ENABLED.equals(type) || DISABLED.equals(type);
	}

	/** state: "enabled", "disabled" or "none" (remove). */
	static Object setBreakpoint(Session s, Address address, String state, String name) throws Exception {
		return s.edit("Breakpoint", () -> {
			BookmarkManager bm = s.program.getBookmarkManager();
			String category = EXECUTE;
			String comment = name != null ? name : "";
			for (Bookmark b : bm.getBookmarks(address)) {
				if (isBreakpoint(b)) {
					category = b.getCategory();
					if (name == null) {
						comment = b.getComment();
					}
					bm.removeBookmark(b);
				}
			}
			if ("enabled".equals(state)) {
				bm.setBookmark(address, ENABLED, category, comment);
			}
			else if ("disabled".equals(state)) {
				bm.setBookmark(address, DISABLED, category, comment);
			}
			return true;
		});
	}

	static Object clearBreakpoints(Session s) throws Exception {
		return s.edit("Breakpoint", () -> {
			BookmarkManager bm = s.program.getBookmarkManager();
			List<Bookmark> all = new ArrayList<>();
			for (String type : List.of(ENABLED, DISABLED)) {
				Iterator<Bookmark> it = bm.getBookmarksIterator(type);
				while (it.hasNext()) {
					all.add(it.next());
				}
			}
			for (Bookmark b : all) {
				bm.removeBookmark(b);
			}
			return all.size();
		});
	}

	/** Names for a batch of addresses: the label at each one and the function it belongs to. */
	static List<Map<String, Object>> describe(Session s, List<String> addresses) {
		Program p = s.program;
		List<Map<String, Object>> out = new ArrayList<>();
		for (String text : addresses) {
			Address a;
			try {
				a = s.addr(text);
			}
			catch (Exception e) {
				continue;
			}
			if (!p.getMemory().contains(a)) {
				continue;
			}
			Symbol label = p.getSymbolTable().getPrimarySymbol(a);
			Function f = p.getFunctionManager().getFunctionContaining(a);
			out.add(map("address", str(a), "label", label != null ? label.getName() : null,
				"function", f != null ? f.getName() : null, "entry", f != null ? str(f.getEntryPoint()) : null,
				"offset", f != null ? a.subtract(f.getEntryPoint()) : 0));
		}
		return out;
	}
}
