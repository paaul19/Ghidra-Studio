package studio;

import static studio.Json.*;

import java.io.File;
import java.nio.file.Files;
import java.util.*;

import ghidra.program.database.sourcemap.SourceFile;
import ghidra.program.database.sourcemap.UserDataPathTransformer;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.sourcemap.SourcePathTransformRecord;
import ghidra.program.model.sourcemap.SourcePathTransformer;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;
import ghidra.util.task.TaskMonitor;

/** Memory scans, direct references, and the program-wide tables (data, functions, strings, media). */
final class Finder {
	private static final int MAX = 20000;

	private Finder() {
	}

	// ---------------------------------------------------------------- memory scan

	/**
	 * Byte pattern search with Ghidra's memory-search filters: blocks, kind of code unit, alignment and an
	 * address set to stay inside. Each hit carries the bytes found, so a later scan can compare values.
	 */
	static List<Map<String, Object>> scan(Session s, String pattern, List<String> blocks, List<String> codeTypes,
			int align, AddressSet within, TaskMonitor monitor) throws Exception {
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
			if (!(t.equals("??") || t.equals("?") || t.equals("."))) {
				values[i] = (byte) Integer.parseInt(t, 16);
				masks[i] = (byte) 0xff;
			}
		}
		Memory mem = s.program.getMemory();
		Listing listing = s.program.getListing();
		Set<String> kinds = new HashSet<>(codeTypes);
		List<Map<String, Object>> out = new ArrayList<>();
		for (MemoryBlock block : mem.getBlocks()) {
			if (!block.isInitialized() || (!blocks.isEmpty() && !blocks.contains(block.getName()))) {
				continue;
			}
			monitor.checkCancelled();
			monitor.setMessage(block.getName());
			Address cur = block.getStart();
			while (cur != null && out.size() < MAX) {
				Address found = mem.findBytes(cur, block.getEnd(), values, masks, true, monitor);
				if (found == null) {
					break;
				}
				boolean ok = (align <= 1 || found.getOffset() % align == 0) && (within.isEmpty() || within.contains(found));
				String kind = "";
				if (ok) {
					CodeUnit cu = listing.getCodeUnitContaining(found);
					kind = cu instanceof Instruction ? "instructions" : cu instanceof Data d && d.isDefined() ? "data" : "undefined";
					ok = kinds.isEmpty() || kinds.contains(kind);
				}
				if (ok) {
					byte[] got = new byte[values.length];
					mem.getBytes(found, got);
					Function f = s.program.getFunctionManager().getFunctionContaining(found);
					out.add(map("address", str(found), "block", block.getName(), "kind", kind, "bytes", hex(got, got.length),
						"function", f == null ? "" : f.getName()));
				}
				if (found.equals(block.getEnd())) {
					break;
				}
				cur = found.next();
			}
		}
		return out;
	}

	/** The bytes now at each address (for comparing with an earlier scan). */
	static List<String> readValues(Session s, List<String> addresses, int size) {
		Memory mem = s.program.getMemory();
		List<String> out = new ArrayList<>();
		for (String text : addresses) {
			byte[] buf = new byte[Math.max(1, size)];
			try {
				mem.getBytes(s.addr(text), buf);
				out.add(hex(buf, buf.length));
			}
			catch (Exception e) {
				out.add("");
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- direct references

	/** Places in memory whose bytes are the address of something in the target set (pointers nobody defined). */
	static List<Map<String, Object>> directReferences(Session s, AddressSet targets, int align, TaskMonitor monitor)
			throws Exception {
		Program p = s.program;
		Memory mem = p.getMemory();
		int size = p.getDefaultPointerSize();
		boolean big = mem.isBigEndian();
		AddressSpace space = p.getAddressFactory().getDefaultAddressSpace();
		List<Map<String, Object>> out = new ArrayList<>();
		long lo = targets.getMinAddress().getOffset(), hi = targets.getMaxAddress().getOffset();
		int step = Math.max(1, align);
		for (MemoryBlock block : mem.getBlocks()) {
			if (!block.isInitialized()) {
				continue;
			}
			monitor.checkCancelled();
			monitor.setMessage(block.getName());
			long length = block.getSize();
			final int chunk = 1 << 20;
			for (long off = 0; off < length && out.size() < MAX; off += chunk) {
				int n = (int) Math.min(chunk + size - 1, length - off);
				byte[] buf = new byte[n];
				block.getBytes(block.getStart().add(off), buf);
				for (int i = 0; i + size <= n && i < chunk; i += step) {
					long v = 0;
					for (int b = 0; b < size; b++) {
						int x = buf[big ? i + b : i + size - 1 - b] & 0xff;
						v = (v << 8) | x;
					}
					if (Long.compareUnsigned(v, lo) < 0 || Long.compareUnsigned(v, hi) > 0) {
						continue;
					}
					Address to = space.getAddress(v);
					if (!targets.contains(to)) {
						continue;
					}
					Address from = block.getStart().add(off + i);
					boolean known = false;
					for (Reference r : p.getReferenceManager().getReferencesFrom(from)) {
						known |= r.getToAddress().equals(to);
					}
					Symbol sym = p.getSymbolTable().getPrimarySymbol(to);
					CodeUnit cu = p.getListing().getCodeUnitContaining(from);
					out.add(map("address", str(from), "to", str(to), "label", sym == null ? "" : sym.getName(),
						"block", block.getName(), "known", known,
						"kind", cu instanceof Instruction ? "instructions" : cu instanceof Data d && d.isDefined() ? "data" : "undefined"));
				}
			}
		}
		return out;
	}

	// ---------------------------------------------------------------- tables

	/** Ghidra's Defined Data window. */
	static List<Map<String, Object>> dataTable(Session s, String filter) {
		List<Map<String, Object>> out = new ArrayList<>();
		String f = filter == null ? "" : filter.toLowerCase();
		DataIterator it = s.program.getListing().getDefinedData(true);
		while (it.hasNext() && out.size() < MAX) {
			Data d = it.next();
			String type = d.getDataType().getDisplayName();
			if (!f.isEmpty() && !type.toLowerCase().contains(f)) {
				continue;
			}
			Symbol sym = d.getPrimarySymbol();
			String value = d.getDefaultValueRepresentation();
			out.add(map("address", str(d.getAddress()), "label", sym == null ? "" : sym.getName(), "type", type,
				"size", d.getLength(), "value", value != null && value.length() > 200 ? value.substring(0, 200) + "…" : value,
				"block", blockName(s, d.getAddress()), "references", s.program.getReferenceManager().getReferenceCountTo(d.getAddress())));
		}
		return out;
	}

	private static String blockName(Session s, Address a) {
		MemoryBlock b = s.program.getMemory().getBlock(a);
		return b == null ? "" : b.getName();
	}

	/** Ghidra's Functions window. */
	static List<Map<String, Object>> functionTable(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Function f : s.program.getFunctionManager().getFunctions(true)) {
			if (out.size() >= MAX * 5) {
				break;
			}
			List<String> tags = new ArrayList<>();
			f.getTags().forEach(t -> tags.add(t.getName()));
			out.add(map("address", str(f.getEntryPoint()), "name", f.getName(true), "signature", f.getPrototypeString(false, false),
				"size", f.getBody().getNumAddresses(), "convention", f.getCallingConventionName(),
				"callers", s.program.getReferenceManager().getReferenceCountTo(f.getEntryPoint()),
				"thunk", f.isThunk(), "noReturn", f.hasNoReturn(), "inline", f.isInline(), "varargs", f.hasVarArgs(),
				"customStorage", f.hasCustomVariableStorage(), "tags", String.join(", ", tags),
				"block", blockName(s, f.getEntryPoint()), "locals", f.getLocalVariables().length,
				"params", f.getParameterCount()));
		}
		return out;
	}

	// ---------------------------------------------------------------- strings and translation

	/** Defined strings with their translation (Ghidra's string table and translate actions). */
	static List<Map<String, Object>> stringTable(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		DataIterator it = s.program.getListing().getDefinedData(true);
		while (it.hasNext() && out.size() < MAX * 2) {
			Data d = it.next();
			if (!(d.getValue() instanceof String) && !StringDataInstance.isString(d)) {
				continue;
			}
			StringDataInstance sdi = StringDataInstance.getStringDataInstance(d);
			String value = sdi.getStringValue();
			if (value == null) {
				continue;
			}
			String translated = TranslationSettingsDefinition.TRANSLATION.getTranslatedValue(d);
			out.add(map("address", str(d.getAddress()), "value", value, "translation", translated == null ? "" : translated,
				"showTranslated", TranslationSettingsDefinition.TRANSLATION.isShowTranslated(d),
				"type", d.getDataType().getDisplayName(), "length", d.getLength(), "charset", sdi.getCharsetName(),
				"references", s.program.getReferenceManager().getReferenceCountTo(d.getAddress())));
		}
		return out;
	}

	/** Sets (or, with an empty text, clears) the translation of strings, and whether the listing shows it. */
	static Object translate(Session s, Map<String, String> translations, Boolean show) throws Exception {
		return s.edit("Traducir cadenas", () -> {
			int n = 0;
			for (Map.Entry<String, String> e : translations.entrySet()) {
				Data d = s.program.getListing().getDataAt(s.addr(e.getKey()));
				if (d == null) {
					continue;
				}
				String text = e.getValue();
				if (text != null) {
					TranslationSettingsDefinition.TRANSLATION.setTranslatedValue(d, text.isEmpty() ? null : text);
					TranslationSettingsDefinition.TRANSLATION.setShowTranslated(d, !text.isEmpty());
				}
				if (show != null) {
					TranslationSettingsDefinition.TRANSLATION.setShowTranslated(d, show);
				}
				n++;
			}
			return map("done", n);
		});
	}

	// ---------------------------------------------------------------- embedded media

	/** Images and sounds inside the program: the ones defined as data and the ones found by their signature. */
	static List<Map<String, Object>> media(Session s, TaskMonitor monitor) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		Set<Address> seen = new HashSet<>();
		DataIterator it = s.program.getListing().getDefinedData(true);
		while (it.hasNext() && out.size() < 5000) {
			Data d = it.next();
			DataType dt = d.getDataType();
			String n = dt.getName().toLowerCase();
			boolean media = dt instanceof PngDataType || dt instanceof GifDataType || dt instanceof JPEGDataType
					|| dt instanceof WAVEDataType || dt instanceof AIFFDataType || dt instanceof AUDataType
					|| dt instanceof MIDIDataType || n.contains("bitmap") || n.contains("icon") || n.equals("png")
					|| n.equals("gif") || n.equals("jpeg");
			if (media) {
				seen.add(d.getAddress());
				out.add(map("address", str(d.getAddress()), "kind", dt.getName(), "length", d.getLength(), "defined", true,
					"extension", extension(dt.getName())));
			}
		}
		Memory mem = s.program.getMemory();
		Object[][] signatures = { { "PNG", new byte[] { (byte) 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a } },
			{ "GIF", new byte[] { 'G', 'I', 'F', '8' } }, { "JPEG", new byte[] { (byte) 0xff, (byte) 0xd8, (byte) 0xff } },
			{ "WAVE", new byte[] { 'R', 'I', 'F', 'F' } } };
		for (Object[] sig : signatures) {
			byte[] magic = (byte[]) sig[1];
			for (MemoryBlock block : mem.getBlocks()) {
				if (!block.isInitialized()) {
					continue;
				}
				monitor.checkCancelled();
				Address cur = block.getStart();
				while (cur != null && out.size() < 5000) {
					Address found = mem.findBytes(cur, block.getEnd(), magic, null, true, monitor);
					if (found == null) {
						break;
					}
					if (!seen.contains(found)) {
						long length = mediaLength(mem, found, block.getEnd(), (String) sig[0]);
						if (length > 0) {
							out.add(map("address", str(found), "kind", sig[0], "length", length, "defined", false,
								"extension", extension((String) sig[0])));
						}
					}
					if (found.equals(block.getEnd())) {
						break;
					}
					cur = found.next();
				}
			}
		}
		out.sort(Comparator.comparing(o -> (String) o.get("address")));
		return out;
	}

	private static String extension(String kind) {
		String k = kind.toLowerCase();
		return k.contains("png") ? "png" : k.contains("gif") ? "gif" : k.contains("jp") ? "jpg" : k.contains("wav") ? "wav"
				: k.contains("aiff") ? "aiff" : k.contains("midi") ? "mid" : k.contains("au") ? "au"
						: k.contains("icon") ? "ico" : k.contains("bitmap") ? "bmp" : "bin";
	}

	/** Length of the media that starts at an address, from its own format; 0 when it is not really one. */
	private static long mediaLength(Memory mem, Address at, Address end, String kind) {
		try {
			long max = Math.min(end.subtract(at) + 1, 64L << 20);
			switch (kind) {
				case "PNG": {
					long off = 8;
					while (off + 12 <= max) {
						long len = mem.getInt(at.add(off), true) & 0xffffffffL;
						byte[] type = new byte[4];
						mem.getBytes(at.add(off + 4), type);
						off += 12 + len;
						if (new String(type).equals("IEND")) {
							return off <= max ? off : 0;
						}
						if (len > max) {
							return 0;
						}
					}
					return 0;
				}
				case "GIF": {
					byte[] v = new byte[2];
					mem.getBytes(at.add(4), v);
					if (!(v[0] == '7' || v[0] == '9') || v[1] != 'a') {
						return 0;
					}
					// the trailer is 0x3b; take the first one after the header that ends a block
					for (long off = 13; off < max; off++) {
						if (mem.getByte(at.add(off)) == 0x3b && mem.getByte(at.add(off - 1)) == 0) {
							return off + 1;
						}
					}
					return 0;
				}
				case "JPEG": {
					for (long off = 3; off + 1 < max; off++) {
						if (mem.getByte(at.add(off)) == (byte) 0xff && mem.getByte(at.add(off + 1)) == (byte) 0xd9) {
							return off + 2;
						}
					}
					return 0;
				}
				default: {
					byte[] wave = new byte[4];
					mem.getBytes(at.add(8), wave);
					if (!new String(wave).equals("WAVE")) {
						return 0;
					}
					long size = (mem.getInt(at.add(4), false) & 0xffffffffL) + 8;
					return size <= max ? size : 0;
				}
			}
		}
		catch (Exception e) {
			return 0;
		}
	}

	/** Writes bytes of the program to a file (an embedded image, or any range). */
	static Object saveBytes(Session s, Address at, long length, String path) throws Exception {
		if (length <= 0 || length > (256L << 20)) {
			throw new IllegalArgumentException("Tamaño inválido");
		}
		byte[] buf = new byte[(int) length];
		s.program.getMemory().getBytes(at, buf);
		Files.write(new File(path).toPath(), buf);
		return map("path", path, "length", length);
	}

	// ---------------------------------------------------------------- source path transforms

	static List<Map<String, Object>> sourceTransforms(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		SourcePathTransformer t = UserDataPathTransformer.getPathTransformer(s.program);
		for (SourcePathTransformRecord r : t.getTransformRecords()) {
			out.add(map("kind", r.isDirectoryTransform() ? "directory" : "file", "source", r.source(), "target", r.target()));
		}
		return out;
	}

	private static SourceFile sourceFile(Session s, String path) {
		for (SourceFile f : s.program.getSourceFileManager().getAllSourceFiles()) {
			if (f.getPath().equals(path)) {
				return f;
			}
		}
		throw new IllegalArgumentException("No existe el archivo fuente " + path);
	}

	/** Maps a source file or a directory of the build machine to a local path; an empty target removes the mapping. */
	static Object setSourceTransform(Session s, String kind, String source, String target) {
		SourcePathTransformer t = UserDataPathTransformer.getPathTransformer(s.program);
		boolean remove = target == null || target.isBlank();
		if (kind.equals("directory")) {
			if (remove) {
				t.removeDirectoryTransform(source);
			}
			else {
				t.addDirectoryTransform(source, target.endsWith("/") ? target : target + "/");
			}
		}
		else if (remove) {
			t.removeFileTransform(sourceFile(s, source));
		}
		else {
			t.addFileTransform(sourceFile(s, source), target);
		}
		return sourceTransforms(s);
	}

	/** Where a source file is on this machine, after the transforms. */
	static Object localSourcePath(Session s, String path) {
		SourcePathTransformer t = UserDataPathTransformer.getPathTransformer(s.program);
		String local = t.getTransformedPath(sourceFile(s, path), true);
		return map("path", local, "exists", local != null && new File(local).isFile());
	}
}
