import AppKit
import SwiftUI

@main
struct GhidraStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Ghidra Studio", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1360, height: 840)
        .windowToolbarStyle(.unified)
        .commands { StudioCommands(model: model) }

        Window(tr("Tipos de datos"), id: "types") {
            DataTypesView().environment(model)
        }
        .defaultSize(width: 980, height: 640)

        Window(tr("Buscar en el programa"), id: "search") {
            SearchView().environment(model)
        }
        .defaultSize(width: 900, height: 560)

        Window(tr("Árbol de llamadas"), id: "calls") {
            CallTreeView().environment(model)
        }
        .defaultSize(width: 480, height: 620)

        Window(tr("Scripts"), id: "scripts") {
            ScriptsView().environment(model)
        }
        .defaultSize(width: 1080, height: 700)

        Window(tr("Grafos"), id: "graphs") {
            GraphsView().environment(model)
        }
        .defaultSize(width: 1100, height: 760)

        Window(tr("Emulador"), id: "emulator") {
            EmulatorView().environment(model)
        }
        .defaultSize(width: 820, height: 600)

        Window(tr("Comparar programas"), id: "compare") {
            CompareView().environment(model)
        }
        .defaultSize(width: 960, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.startEngine() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            if url.pathExtension == "gpr" {
                AppModel.shared.openProject(url.path)
            } else {
                AppModel.shared.open(url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.engine.shutdown() }
    }
}

/// Sends standard text-editing undo to an editable field, otherwise uses the program's undo.
@MainActor
private func textFieldHasFocus() -> Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
}

struct StudioCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("Nuevo proyecto…")) { model.presentNewProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(tr("Abrir proyecto…")) { model.presentOpenProject() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Menu(tr("Proyectos recientes")) {
                ForEach(model.recentProjects, id: \.self) { gpr in
                    Button((gpr as NSString).lastPathComponent) { model.openProject(gpr) }
                }
                Divider()
                Button(tr("Proyecto por defecto")) { model.openDefaultProject() }
            }
            Divider()
            Button(tr("Importar binario…")) { model.presentOpenPanel() }
                .keyboardShortcut("i")
            Button(tr("Abrir binario rápido…")) {
                let panel = NSOpenPanel()
                panel.treatsFilePackagesAsDirectories = true
                if panel.runModal() == .OK, let url = panel.url { model.open(url) }
            }
            .keyboardShortcut("o")
            Menu(tr("Abrir recientes")) {
                ForEach(model.recents, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { model.open(URL(fileURLWithPath: path)) }
                }
                if !model.recents.isEmpty {
                    Divider()
                    Button(tr("Borrar menú")) { model.clearRecents() }
                }
            }
            Button(tr("Importar archivo .gzf…")) { model.presentImportPacked() }
            Divider()
            Button(tr("Exportar…")) { model.showExport = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.program == nil)
            Button(tr("Exportar programa (.gzf)…")) { model.presentExportPacked() }
                .disabled(model.program == nil)
            Divider()
            Button(tr("Cerrar programa")) { model.closeProgram() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.program == nil)
            Divider()
            Button(tr("Abrir proyecto en Ghidra clásico…")) { model.openProjectInClassic() }
                .disabled(model.project?.open != true)
            Button(tr("Abrir Ghidra clásico")) { model.launchClassic() }
        }

        CommandGroup(after: .appSettings) {
            Menu(tr("Idioma")) {
                ForEach(AppLanguage.allCases) { lang in
                    Button((AppLanguage.current == lang ? "✓ " : "") + lang.title) { AppLanguage.select(lang) }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button(tr("Guardar")) { model.save() }
                .keyboardShortcut("s")
                .disabled(!model.isDirty)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(model.undo?.undoName.map { tr("Deshacer «%@»", "\($0)") } ?? tr("Deshacer")) {
                if textFieldHasFocus() {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    model.performUndo()
                }
            }
            .keyboardShortcut("z")
            Button(model.undo?.redoName.map { tr("Rehacer «%@»", "\($0)") } ?? tr("Rehacer")) {
                if textFieldHasFocus() {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else {
                    model.performRedo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Picker(tr("Vista"), selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .disabled(model.program == nil)
            Button(tr("Descompilado")) { model.viewMode = .decompiler }.keyboardShortcut("1")
            Button(tr("Desensamblado")) { model.viewMode = .listing }.keyboardShortcut("2")
            Button(tr("Listado completo")) { model.viewMode = .program }.keyboardShortcut("3")
            Button(tr("Grafo de la función")) { model.viewMode = .graph }.keyboardShortcut("4")
            Button("Hex") { model.viewMode = .hex }.keyboardShortcut("5")
            Divider()
            Button(model.showInspector ? tr("Ocultar inspector") : tr("Mostrar inspector")) { model.showInspector.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button(tr("Aumentar tamaño de letra")) { model.fontSize = min(28, model.fontSize + 1) }
                .keyboardShortcut("+")
            Button(tr("Reducir tamaño de letra")) { model.fontSize = max(9, model.fontSize - 1) }
                .keyboardShortcut("-")
            Button(tr("Tamaño de letra normal")) { model.fontSize = 13 }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu(tr("Navegar")) {
            Button(tr("Abrir rápidamente…")) { model.showQuickOpen = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.program == nil)
            Button(tr("Ir a dirección…")) { model.showQuickOpen = true }
                .keyboardShortcut("l")
                .disabled(model.program == nil)
            Divider()
            Button(tr("Atrás")) { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button(tr("Adelante")) { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Divider()
            Button(tr("Ir al punto de entrada")) {
                if let entry = model.program?.entry { model.go(entry) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.program?.entry == nil)
            Divider()
            ForEach(model.tabs) { tab in
                Button(tab.name) { model.activate(tab.id) }
            }
        }

        CommandMenu(tr("Análisis")) {
            Button(tr("Renombrar función…")) { model.requestRename() }
                .keyboardShortcut("r")
                .disabled(model.functionDetails == nil)
            Button(tr("Editar firma…")) { model.requestSignature() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.functionDetails == nil)
            Button(tr("Comentario…")) { model.requestComment() }
                .keyboardShortcut(";")
                .disabled(model.current == nil)
            Button(tr("Añadir etiqueta…")) { model.requestLabel() }
                .disabled(model.current == nil)
            Button(tr("Añadir marcador…")) { model.requestBookmark() }
                .keyboardShortcut("d")
                .disabled(model.current == nil)
            Divider()
            Button(tr("Desensamblar aquí")) { if let a = model.editTarget { model.perform("disassemble", address: a, namesChanged: false) } }
                .disabled(model.current == nil)
            Button(tr("Crear función aquí…")) { model.requestCreateFunction() }
                .disabled(model.current == nil)
            Button(tr("Definir dato…")) { model.requestCreateData() }
                .disabled(model.current == nil)
            Button(tr("Ensamblar instrucción…")) { model.requestAssemble() }
                .disabled(model.current == nil)
            Button(tr("Parchear bytes…")) { model.requestPatch() }
                .disabled(model.current == nil)
            Divider()
            Button(tr("Opciones de análisis…")) { model.showAnalysisOptions = true }
                .disabled(model.program == nil)
            Button(tr("Analizar ahora")) { model.analyzeNow() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.program == nil || model.analysis != nil)
            Button(tr("Reimportar y reanalizar desde cero")) { model.reanalyze() }
                .disabled(model.program == nil)
        }

        CommandMenu(tr("Herramientas")) {
            Button(tr("Tipos de datos")) { openWindow(id: "types") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(tr("Buscar en el programa…")) { openWindow(id: "search") }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(tr("Árbol de llamadas")) { openWindow(id: "calls") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button(tr("Scripts")) { openWindow(id: "scripts") }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button(tr("Grafos (llamadas, programa, referencias)")) { openWindow(id: "graphs") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button(tr("Emulador")) { openWindow(id: "emulator") }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button(tr("Comparar programas (Diff / Version Tracking)")) { openWindow(id: "compare") }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            Button(tr("Depurador, BSim, Ghidra Server… (Ghidra clásico)")) { model.openProjectInClassic() }
                .disabled(model.project?.open != true)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(tr("Interfaz")) {
                Picker(tr("Idioma"), selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.select($0) })) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Editor") {
                Slider(value: $model.fontSize, in: 9...28, step: 1) {
                    Text(tr("Tamaño de letra"))
                } minimumValueLabel: {
                    Text("A").font(.caption)
                } maximumValueLabel: {
                    Text("A").font(.title3)
                }
                Text("\(Int(model.fontSize)) pt · SF Mono")
                    .foregroundStyle(.secondary)
            }
            Section(tr("Motor")) {
                LabeledContent(tr("Estado"), value: model.engineStatus)
                LabeledContent(tr("Proyecto"), value: model.project?.name ?? "—")
                LabeledContent(tr("Proyecto por defecto")) {
                    Button(tr("Mostrar en Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Engine.supportDirectory])
                    }
                }
                LabeledContent(tr("Registro")) {
                    Button(tr("Abrir registro")) { NSWorkspace.shared.open(Engine.logFile) }
                }
            }
            Section(tr("Atajos en el código (como en Ghidra)")) {
                LabeledContent("L", value: tr("Renombrar"))
                LabeledContent(";", value: tr("Comentario"))
                LabeledContent("D", value: tr("Desensamblar"))
                LabeledContent("F", value: tr("Crear función"))
                LabeledContent("C", value: tr("Borrar código/dato"))
                LabeledContent("T", value: tr("Definir dato / cambiar tipo"))
                LabeledContent("B", value: tr("Marcador"))
                LabeledContent("G", value: tr("Ir a…"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
