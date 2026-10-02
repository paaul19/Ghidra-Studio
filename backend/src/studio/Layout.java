package studio;

import static studio.Json.*;

import java.util.*;

import ghidra.app.cmd.module.ComplexityDepthModularizationCmd;
import ghidra.app.cmd.module.DominanceModularizationCmd;
import ghidra.program.model.address.*;
import ghidra.program.model.block.*;
import ghidra.program.model.lang.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.util.GroupPath;
import ghidra.program.util.ProgramSelection;
import ghidra.util.task.TaskMonitor;

/** Program trees (folders and fragments), the components of structured data, the entropy bar and the language. */
final class Layout {
	private Layout() {
	}

	// ---------------------------------------------------------------- program tree

	private static Group group(Listing listing, String tree, String name) {
		ProgramModule m = listing.getModule(tree, name);
		if (m != null) {
			return m;
		}
		ProgramFragment f = listing.getFragment(tree, name);
		if (f != null) {
			return f;
		}
		ProgramModule root = listing.getRootModule(tree);
		if (root != null && (name == null || name.isBlank() || name.equals(tree) || name.equals(root.getName()))) {
			return root;
		}
		throw new IllegalArgumentException("No existe «" + name + "» en el árbol " + tree);
	}

	private static ProgramModule module(Listing listing, String tree, String name) {
		if (group(listing, tree, name) instanceof ProgramModule m) {
			return m;
		}
		throw new IllegalArgumentException("«" + name + "» no es una carpeta");
	}

	/**
	 * Edits a program tree. action: createTree, deleteTree, renameTree, createFolder, createFragment, rename,
	 * delete, moveRange (code into a fragment), reparent, reorder, organize (subroutine | dominance | complexity).
	 */
	static Object treeAction(Session s, String action, String tree, String name, String parent, String newName,
			String start, String end, int index, TaskMonitor monitor) throws Exception {
		Program p = s.program;
		Listing listing = p.getListing();
		return s.edit("Árbol del programa", () -> {
			switch (action) {
				case "createTree":
					listing.createRootModule(newName);
					break;
				case "deleteTree":
					if (listing.getTreeNames().length <= 1) {
						throw new IllegalStateException("El programa necesita al menos un árbol");
					}
					listing.removeTree(tree);
					break;
				case "renameTree":
					listing.renameTree(tree, newName);
					break;
				case "createFolder":
					module(listing, tree, parent).createModule(newName);
					break;
				case "createFragment":
					module(listing, tree, parent).createFragment(newName);
					break;
				case "rename":
					group(listing, tree, name).setName(newName);
					break;
				case "delete": {
					ProgramModule owner = module(listing, tree, parent);
					Group g = group(listing, tree, name);
					if (g instanceof ProgramFragment f && !f.isEmpty() && f.getNumParents() <= 1) {
						throw new IllegalStateException("El fragmento tiene código: muévelo a otro antes de borrarlo");
					}
					owner.removeChild(name);
					break;
				}
				case "moveRange": {
					ProgramFragment f = listing.getFragment(tree, name);
					if (f == null) {
						throw new IllegalArgumentException("«" + name + "» no es un fragmento");
					}
					f.move(s.addr(start), s.addr(end));
					break;
				}
				case "reparent":
					module(listing, tree, newName).reparent(name, module(listing, tree, parent));
					break;
				case "reorder":
					module(listing, tree, parent).moveChild(name, index);
					break;
				case "organize":
					organize(p, tree, newName, monitor);
					break;
				default:
					throw new IllegalArgumentException("Acción desconocida: " + action);
			}
			return true;
		});
	}

	/** Reorganizes a tree like Ghidra's modularization algorithms. */
	private static void organize(Program p, String tree, String kind, TaskMonitor monitor) throws Exception {
		Listing listing = p.getListing();
		ProgramModule root = listing.getRootModule(tree);
		if (root == null) {
			throw new IllegalArgumentException("No existe el árbol " + tree);
		}
		if (kind.equals("subroutine")) {
			// one fragment per subroutine, grouped in a folder
			String folder = "Subroutines";
			for (int i = 2; listing.getModule(tree, folder) != null || listing.getFragment(tree, folder) != null; i++) {
				folder = "Subroutines " + i;
			}
			ProgramModule target = root.createModule(folder);
			CodeBlockIterator it = new IsolatedEntrySubModel(p).getCodeBlocks(monitor);
			Set<String> used = new HashSet<>();
			while (it.hasNext()) {
				monitor.checkCancelled();
				CodeBlock b = it.next();
				String name = b.getName();
				for (int i = 2; !used.add(name) || listing.getFragment(tree, name) != null ||
					listing.getModule(tree, name) != null; i++) {
					name = b.getName() + "_" + i;
				}
				ProgramFragment f = target.createFragment(name);
				for (AddressRange r : b) {
					f.move(r.getMinAddress(), r.getMaxAddress());
				}
			}
			return;
		}
		GroupPath path = new GroupPath(root.getName());
		ProgramSelection all = new ProgramSelection(p.getMemory());
		CodeBlockModel model = new MultEntSubModel(p);
		ghidra.framework.cmd.BackgroundCommand<Program> cmd = kind.equals("dominance")
				? new DominanceModularizationCmd(path, tree, all, model)
				: new ComplexityDepthModularizationCmd(path, tree, all, model);
		if (!cmd.applyTo(p, monitor)) {
			throw new IllegalStateException(cmd.getStatusMsg() != null ? cmd.getStatusMsg() : "No se pudo reorganizar");
		}
	}

	// ---------------------------------------------------------------- structured data

	/** The fields of a structure or the elements of an array laid out in memory (one level; path goes deeper). */
	static Map<String, Object> dataComponents(Session s, Address a, List<Integer> path) {
		Data d = s.program.getListing().getDataContaining(a);
		if (d == null || !d.isDefined()) {
			throw new IllegalArgumentException("No hay un dato definido en " + a);
		}
		for (int index : path) {
			d = d.getComponent(index);
			if (d == null) {
				throw new IllegalArgumentException("Componente inexistente");
			}
		}
		List<Map<String, Object>> list = new ArrayList<>();
		int n = d.getNumComponents();
		for (int i = 0; i < Math.min(n, 4000); i++) {
			Data c = d.getComponent(i);
			if (c == null) {
				continue;
			}
			String bytes;
			try {
				bytes = hex(c.getBytes(), 8);
			}
			catch (Exception e) {
				bytes = "??";
			}
			list.add(map("index", i, "address", str(c.getMinAddress()), "offset", c.getParentOffset(),
				"name", c.getFieldName(), "type", c.getDataType().getDisplayName(), "value", c.getDefaultValueRepresentation(),
				"length", c.getLength(), "components", c.getNumComponents(), "bytes", bytes,
				"comment", c.getComment(CommentType.EOL)));
		}
		return map("address", str(d.getMinAddress()), "type", d.getDataType().getDisplayName(), "count", n, "components", list);
	}

	// ---------------------------------------------------------------- entropy bar

	/** Entropy (0–8 bits per byte) of the program in slices, for the entropy overview bar. */
	static Map<String, Object> entropyOverview(Session s, int buckets) {
		Program p = s.program;
		long total = 0;
		List<MemoryBlock> blocks = new ArrayList<>();
		for (MemoryBlock b : p.getMemory().getBlocks()) {
			blocks.add(b);
			total += b.getSize();
		}
		int n = (int) Math.max(1, Math.min(Math.min(buckets, 4000), total));
		double[] values = new double[n];
		int bi = 0;
		long base = 0;
		byte[] chunk = new byte[1024];
		for (int i = 0; i < n && !blocks.isEmpty(); i++) {
			long at = (long) ((double) i * total / n);
			while (bi < blocks.size() - 1 && at >= base + blocks.get(bi).getSize()) {
				base += blocks.get(bi).getSize();
				bi++;
			}
			MemoryBlock b = blocks.get(bi);
			values[i] = -1;
			if (!b.isInitialized()) {
				continue;
			}
			try {
				Address a = b.getStart().add(at - base);
				int want = (int) Math.min(chunk.length, b.getEnd().subtract(a) + 1);
				int read = b.getBytes(a, chunk, 0, want);
				if (read > 0) {
					int[] counts = new int[256];
					for (int k = 0; k < read; k++) {
						counts[chunk[k] & 0xff]++;
					}
					double h = 0;
					for (int c : counts) {
						if (c > 0) {
							double q = (double) c / read;
							h -= q * Math.log(q) / Math.log(2);
						}
					}
					values[i] = Math.round(h * 100) / 100.0;
				}
			}
			catch (Exception e) {
				// unreadable chunk
			}
		}
		return map("values", values);
	}

	// ---------------------------------------------------------------- language

	/** Changes the processor language of the program (Ghidra re-disassembles it). */
	static Object setLanguage(Session s, String languageId, String compilerId, TaskMonitor monitor) throws Exception {
		Program p = s.program;
		LanguageService service = ghidra.program.util.DefaultLanguageService.getLanguageService();
		Language language = service.getLanguage(new LanguageID(languageId));
		CompilerSpecID spec = compilerId == null || compilerId.isBlank() ? language.getDefaultCompilerSpec().getCompilerSpecID()
				: new CompilerSpecID(compilerId);
		return s.edit("Cambiar lenguaje", () -> {
			p.setLanguage(language, spec, false, monitor);
			return map("language", p.getLanguageID().getIdAsString(), "compiler", p.getCompilerSpec().getCompilerSpecID().getIdAsString());
		});
	}
}
