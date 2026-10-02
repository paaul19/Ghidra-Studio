package studio;

import static studio.Json.*;

import java.util.*;
import java.util.regex.Pattern;

import ghidra.program.model.address.Address;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.util.task.TaskMonitor;

/** Memory, text and instruction search. */
final class Search {
	private static final int MAX_RESULTS = 2000;
	private static final int MAX_SCAN = 3_000_000;

	private Search() {
	}

	private static Map<String, Object> hit(Program p, Address a, String kind, String text) {
		Function f = p.getFunctionManager().getFunctionContaining(a);
		return map("address", str(a), "kind", kind, "text", text, "function", f != null ? f.getName(true) : null);
	}

	/** Byte pattern like "48 8b ?? 05" ("??" / "." = wildcard). */
	static List<Map<String, Object>> bytes(Session s, String pattern) {
		String[] parts = pattern.trim().split("\\s+");
		if (parts.length == 1 && parts[0].length() > 2) {
			String p = parts[0];
			parts = new String[p.length() / 2];
			for (int i = 0; i < parts.length; i++) {
				parts[i] = p.substring(i * 2, i * 2 + 2);
			}
		}
		byte[] values = new byte[parts.length];
		byte[] masks = new byte[parts.length];
		for (int i = 0; i < parts.length; i++) {
			String t = parts[i].toLowerCase().replace("0x", "");
			if (t.equals("??") || t.equals("?") || t.equals(".")) {
				masks[i] = 0;
			}
			else {
				values[i] = (byte) Integer.parseInt(t, 16);
				masks[i] = (byte) 0xff;
			}
		}
		Memory mem = s.program.getMemory();
		List<Map<String, Object>> out = new ArrayList<>();
		for (MemoryBlock block : mem.getBlocks()) {
			if (!block.isInitialized()) {
				continue;
			}
			Address cur = block.getStart();
			while (cur != null && out.size() < MAX_RESULTS) {
				Address found = mem.findBytes(cur, block.getEnd(), values, masks, true, TaskMonitor.DUMMY);
				if (found == null) {
					break;
				}
				byte[] ctx = new byte[Math.min(16, (int) Math.min(16, block.getEnd().subtract(found) + 1))];
				try {
					mem.getBytes(found, ctx);
				}
				catch (Exception ignored) {
					// partial context is fine
				}
				out.add(hit(s.program, found, block.getName(), hex(ctx, 16)));
				try {
					cur = found.add(1);
				}
				catch (Exception e) {
					break;
				}
				if (cur.compareTo(block.getEnd()) > 0) {
					break;
				}
			}
		}
		return out;
	}

	/** Searches labels, comments, strings and/or instruction text. */
	static List<Map<String, Object>> text(Session s, String query, boolean regex, boolean caseSensitive,
			Set<String> scopes) {
		Program p = s.program;
		Pattern pat = regex ? Pattern.compile(query, caseSensitive ? 0 : Pattern.CASE_INSENSITIVE)
				: Pattern.compile(Pattern.quote(query), caseSensitive ? 0 : Pattern.CASE_INSENSITIVE);
		List<Map<String, Object>> out = new ArrayList<>();

		if (scopes.contains("labels")) {
			SymbolIterator it = p.getSymbolTable().getAllSymbols(true);
			while (it.hasNext() && out.size() < MAX_RESULTS) {
				Symbol sym = it.next();
				if (!sym.isExternal() && pat.matcher(sym.getName()).find()) {
					out.add(hit(p, sym.getAddress(), "Etiqueta", sym.getName(true)));
				}
			}
		}
		if (scopes.contains("strings")) {
			for (Data d : p.getListing().getDefinedData(true)) {
				if (out.size() >= MAX_RESULTS) {
					break;
				}
				if (d.hasStringValue()) {
					String v = StringDataInstance.getStringDataInstance(d).getStringValue();
					if (v != null && pat.matcher(v).find()) {
						out.add(hit(p, d.getAddress(), "Cadena", v));
					}
				}
			}
		}
		boolean comments = scopes.contains("comments");
		boolean instructions = scopes.contains("instructions");
		if (comments || instructions) {
			CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
			CodeUnitIterator it = p.getListing().getCodeUnits(true);
			int scanned = 0;
			while (it.hasNext() && out.size() < MAX_RESULTS && scanned++ < MAX_SCAN) {
				CodeUnit cu = it.next();
				if (comments) {
					for (CommentType type : CommentType.values()) {
						String c = cu.getComment(type);
						if (c != null && pat.matcher(c).find()) {
							out.add(hit(p, cu.getAddress(), "Comentario", c));
						}
					}
				}
				if (instructions && cu instanceof Instruction ins) {
					StringBuilder sb = new StringBuilder(ins.getMnemonicString());
					for (int i = 0; i < ins.getNumOperands(); i++) {
						sb.append(i == 0 ? " " : ", ").append(fmt.getOperandRepresentationString(ins, i));
					}
					String text = sb.toString();
					if (pat.matcher(text).find()) {
						out.add(hit(p, cu.getAddress(), "Instrucción", text));
					}
				}
			}
		}
		return out;
	}

	/**
	 * Like Search > For Instruction Patterns: takes the instructions in [start, end], masks out their
	 * operands (keeping only the opcode bits) and finds every other place with the same shape.
	 */
	static Map<String, Object> instructionPattern(Session s, Address start, Address end, boolean maskOperands) {
		Program p = s.program;
		java.io.ByteArrayOutputStream values = new java.io.ByteArrayOutputStream();
		java.io.ByteArrayOutputStream masks = new java.io.ByteArrayOutputStream();
		StringBuilder shown = new StringBuilder();
		int count = 0;
		for (Instruction ins : p.getListing().getInstructions(new ghidra.program.model.address.AddressSet(start, end), true)) {
			if (count++ >= 16) {
				break;
			}
			try {
				byte[] bytes = ins.getBytes();
				byte[] mask = new byte[bytes.length];
				if (maskOperands) {
					byte[] im = ins.getPrototype().getInstructionMask().getBytes();
					System.arraycopy(im, 0, mask, 0, Math.min(im.length, mask.length));
				}
				else {
					Arrays.fill(mask, (byte) 0xff);
				}
				for (int i = 0; i < bytes.length; i++) {
					values.write(bytes[i] & mask[i]);
					masks.write(mask[i]);
					shown.append(mask[i] == (byte) 0xff ? String.format("%02x ", bytes[i] & 0xff)
							: mask[i] == 0 ? "?? " : String.format("%02x* ", bytes[i] & mask[i] & 0xff));
				}
			}
			catch (Exception e) {
				throw new IllegalStateException("No se pudo leer la instrucción en " + ins.getAddress());
			}
		}
		if (count == 0) {
			throw new IllegalArgumentException("Selecciona una o varias instrucciones");
		}
		byte[] v = values.toByteArray();
		byte[] m = masks.toByteArray();
		Memory mem = p.getMemory();
		CodeUnitFormat fmt = new CodeUnitFormat(new CodeUnitFormatOptions());
		List<Map<String, Object>> out = new ArrayList<>();
		for (MemoryBlock block : mem.getBlocks()) {
			if (!block.isInitialized() || !block.isExecute()) {
				continue;
			}
			Address cur = block.getStart();
			while (cur != null && out.size() < MAX_RESULTS) {
				Address found = mem.findBytes(cur, block.getEnd(), v, m, true, TaskMonitor.DUMMY);
				if (found == null) {
					break;
				}
				Instruction ins = p.getListing().getInstructionAt(found);
				if (ins != null) {
					StringBuilder sb = new StringBuilder(ins.getMnemonicString());
					for (int i = 0; i < ins.getNumOperands(); i++) {
						sb.append(i == 0 ? " " : ", ").append(fmt.getOperandRepresentationString(ins, i));
					}
					out.add(hit(p, found, "Instrucción", sb.toString()));
				}
				try {
					cur = found.add(1);
				}
				catch (Exception e) {
					break;
				}
				if (cur.compareTo(block.getEnd()) > 0) {
					break;
				}
			}
		}
		return map("pattern", shown.toString().trim(), "instructions", count, "results", out);
	}

	/** Search and replace in label names and/or comments. Returns how many items changed. */
	static Object replace(Session s, String query, String replacement, boolean regex, boolean caseSensitive,
			Set<String> scopes) throws Exception {
		Pattern pat = regex ? Pattern.compile(query, caseSensitive ? 0 : Pattern.CASE_INSENSITIVE)
				: Pattern.compile(Pattern.quote(query), caseSensitive ? 0 : Pattern.CASE_INSENSITIVE);
		String repl = regex ? replacement : java.util.regex.Matcher.quoteReplacement(replacement);
		return s.edit("Buscar y reemplazar", () -> {
			Program p = s.program;
			int changed = 0;
			if (scopes.contains("labels")) {
				List<Symbol> targets = new ArrayList<>();
				SymbolIterator it = p.getSymbolTable().getAllSymbols(true);
				while (it.hasNext()) {
					Symbol sym = it.next();
					if (!sym.isExternal() && !sym.isDynamic() && pat.matcher(sym.getName()).find()) {
						targets.add(sym);
					}
				}
				for (Symbol sym : targets) {
					String name = pat.matcher(sym.getName()).replaceAll(repl);
					if (!name.isBlank() && !name.equals(sym.getName())) {
						try {
							sym.setName(name, ghidra.program.model.symbol.SourceType.USER_DEFINED);
							changed++;
						}
						catch (Exception ignored) {
							// duplicate or invalid name: skip
						}
					}
				}
			}
			if (scopes.contains("comments")) {
				Listing listing = p.getListing();
				for (CommentType type : CommentType.values()) {
					List<Address> addrs = new ArrayList<>();
					for (Address a : listing.getCommentAddressIterator(type, p.getMemory(), true)) {
						addrs.add(a);
					}
					for (Address a : addrs) {
						String c = listing.getComment(type, a);
						if (c != null && pat.matcher(c).find()) {
							listing.setComment(a, type, pat.matcher(c).replaceAll(repl));
							changed++;
						}
					}
				}
			}
			return map("applied", changed);
		});
	}
}
