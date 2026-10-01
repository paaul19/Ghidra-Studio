package studio;

import static studio.Json.*;

import java.io.File;
import java.util.*;

import ghidra.app.util.exporter.Exporter;
import ghidra.util.classfinder.ClassSearcher;
import ghidra.util.task.TaskMonitor;

/** Program exporters (C/C++, ASCII, binary, XML, Intel Hex, ...). */
final class Exports {
	private Exports() {
	}

	private static List<Exporter> exporters() {
		List<Exporter> list = new ArrayList<>(ClassSearcher.getInstances(Exporter.class));
		list.sort(Comparator.comparing(Exporter::getName));
		return list;
	}

	static List<Map<String, Object>> list(Session s) {
		List<Map<String, Object>> out = new ArrayList<>();
		for (Exporter e : exporters()) {
			if (s == null || e.canExportDomainObject(s.program)) {
				out.add(map("name", e.getName(), "extension", e.getDefaultFileExtension()));
			}
		}
		return out;
	}

	static Object export(Session s, String name, String path) throws Exception {
		for (Exporter e : exporters()) {
			if (e.getName().equals(name)) {
				File f = new File(path);
				e.setOptions(e.getOptions(() -> s.program));
				if (!e.export(f, s.program, null, TaskMonitor.DUMMY)) {
					throw new IllegalStateException("La exportación falló: " + e.getMessageLog());
				}
				return map("path", f.getAbsolutePath(), "size", f.length());
			}
		}
		throw new IllegalArgumentException("Exportador desconocido: " + name);
	}
}
