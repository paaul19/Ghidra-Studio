package studio;

import static studio.Json.*;

import java.io.File;
import java.util.*;

import ghidra.framework.Application;
import ghidra.util.extensions.ExtensionDetails;
import ghidra.util.extensions.ExtensionUtils;
import ghidra.util.task.TaskMonitor;

/**
 * Ghidra extensions: the same install folder and format as the classic Ghidra, so an extension
 * installed here is also installed there. Changes take effect when the engine restarts.
 */
final class Extensions {
	private Extensions() {
	}

	private static Map<String, Object> describe(ExtensionDetails e, boolean installed) {
		String version = e.getVersion();
		String app = Application.getApplicationVersion();
		return map("name", e.getName(), "description", e.getDescription(), "author", e.getAuthor(),
			"created", e.getCreatedOn(), "version", version, "installed", installed,
			"pendingUninstall", installed && e.isPendingUninstall(),
			"bundled", installed && e.isInstalledInInstallationFolder(),
			"compatible", version == null || version.isBlank() || version.equals(app),
			"installPath", e.getInstallPath(), "archivePath", e.getArchivePath());
	}

	static Map<String, Object> list() {
		ExtensionUtils.reload();
		List<Map<String, Object>> out = new ArrayList<>();
		Set<String> names = new HashSet<>();
		for (ExtensionDetails e : ExtensionUtils.getInstalledExtensions()) {
			out.add(describe(e, true));
			names.add(e.getName());
		}
		for (ExtensionDetails e : ExtensionUtils.getArchiveExtensions()) {
			if (names.add(e.getName())) {
				out.add(describe(e, false));
			}
		}
		out.sort(Comparator.comparing(o -> ((String) o.get("name")).toLowerCase()));
		File dir = Application.getApplicationLayout().getExtensionInstallationDirs().get(0).getFile(false);
		return map("extensions", out, "directory", dir.getAbsolutePath(),
			"ghidraVersion", Application.getApplicationVersion());
	}

	/** Installs from a .zip (or an unpacked extension folder). */
	static Map<String, Object> install(String path) {
		File file = new File(path);
		ExtensionDetails details = ExtensionUtils.getExtension(file, true);
		if (details == null) {
			throw new IllegalArgumentException("No es una extensión de Ghidra: " + file.getName());
		}
		for (ExtensionDetails e : ExtensionUtils.getInstalledExtensions()) {
			if (e.getName().equals(details.getName())) {
				if (e.isPendingUninstall()) {
					e.clearMarkForUninstall();
					return list();
				}
				throw new IllegalStateException("La extensión «" + details.getName() + "» ya está instalada");
			}
		}
		if (!ExtensionUtils.install(details, file, TaskMonitor.DUMMY)) {
			throw new IllegalStateException("No se pudo instalar la extensión «" + details.getName() + "»");
		}
		return list();
	}

	static Map<String, Object> uninstall(String name, boolean undo) {
		for (ExtensionDetails e : ExtensionUtils.getInstalledExtensions()) {
			if (e.getName().equals(name)) {
				if (e.isInstalledInInstallationFolder()) {
					throw new IllegalStateException("Esta extensión viene con Ghidra y no se puede desinstalar");
				}
				boolean ok = undo ? e.clearMarkForUninstall() : e.markForUninstall();
				if (!ok) {
					throw new IllegalStateException("No se pudo cambiar el estado de la extensión");
				}
				return list();
			}
		}
		throw new IllegalArgumentException("No existe la extensión " + name);
	}
}
