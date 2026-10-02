package studio;

import java.io.File;
import java.util.List;

import ghidra.GhidraApplicationLayout;
import ghidra.GhidraLaunchable;
import ghidra.GhidraRun;
import ghidra.app.services.GoToService;
import ghidra.app.services.ProgramManager;
import ghidra.framework.main.AppInfo;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.Project;
import ghidra.framework.model.ToolServices;
import ghidra.framework.plugintool.PluginTool;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Program;
import ghidra.util.Swing;

/**
 * Starts the classic Ghidra on a project and opens its Debugger tool on one program, so Studio can hand the
 * current program straight to the debugger. Arguments: project .gpr, program path in the project, address.
 */
public class ClassicDebugger implements GhidraLaunchable {
	private static final String TOOL = "Debugger";

	@Override
	public void launch(GhidraApplicationLayout layout, String[] args) throws Exception {
		String gpr = args.length > 0 ? args[0] : null;
		String path = args.length > 1 && !args[1].isEmpty() ? args[1] : null;
		String address = args.length > 2 && !args[2].isEmpty() ? args[2] : null;
		new GhidraRun().launch(layout, gpr != null ? new String[] { gpr } : new String[0]);
		if (gpr == null) {
			return;
		}
		Thread t = new Thread(() -> {
			try {
				open(new File(gpr), path, address);
			}
			catch (Throwable e) {
				e.printStackTrace();
			}
		}, "Studio debugger hand-off");
		t.setDaemon(true);
		t.start();
	}

	private static void open(File gpr, String path, String address) throws Exception {
		Project project = null;
		for (int i = 0; i < 1200 && project == null; i++) {      // the project opens after the splash screen
			Thread.sleep(250);
			Project active = AppInfo.getActiveProject();
			if (active != null && active.getProjectLocator().getMarkerFile().getCanonicalFile()
					.equals(gpr.getCanonicalFile())) {
				project = active;
			}
		}
		if (project == null) {
			System.err.println("Studio: project did not open: " + gpr);
			return;
		}
		Project opened = project;
		PluginTool[] tool = new PluginTool[1];
		Swing.runNow(() -> {
			DomainFile file = path != null ? opened.getProjectData().getFile(path) : null;
			List<DomainFile> files = file != null ? List.of(file) : List.of();
			ToolServices services = opened.getToolServices();
			if (services.getToolChest().getToolTemplate(TOOL) != null) {
				tool[0] = services.launchTool(TOOL, files);
			}
			if (tool[0] == null && file != null) {
				tool[0] = services.launchDefaultTool(files);
			}
			System.err.println("Studio: launched " + (tool[0] != null ? tool[0].getName() : "nothing") + " on " + path);
		});
		if (tool[0] == null || address == null) {
			return;
		}
		for (int i = 0; i < 240; i++) {                            // the program opens in a background task
			Thread.sleep(250);
			boolean[] done = new boolean[1];
			Swing.runNow(() -> {
				ProgramManager pm = tool[0].getService(ProgramManager.class);
				GoToService go = tool[0].getService(GoToService.class);
				Program program = pm != null ? pm.getCurrentProgram() : null;
				if (program == null || go == null) {
					return;
				}
				Address a = program.getAddressFactory().getAddress(address);
				done[0] = a == null || go.goTo(a);
			});
			if (done[0]) {
				return;
			}
		}
	}
}
