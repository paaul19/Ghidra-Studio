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

        Window(tr("Gestor de tipos de datos"), id: "typemanager") {
            TypeManagerView().environment(model)
        }
        .defaultSize(width: 1120, height: 660)

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

        Window(tr("Tablas"), id: "tables") {
            TablesView().environment(model)
        }
        .defaultSize(width: 980, height: 620)

        Window(tr("Comparar funciones"), id: "funccompare") {
            FunctionCompareView().environment(model)
        }
        .defaultSize(width: 1180, height: 720)

        Window(tr("Version Tracking"), id: "vt") {
            VersionTrackingView().environment(model)
        }
        .defaultSize(width: 1240, height: 780)

        Window("BSim", id: "bsim") {
            BSimView().environment(model)
        }
        .defaultSize(width: 1100, height: 680)

        Window(tr("Ghidra Server y control de versiones"), id: "server") {
            ServerView().environment(model)
        }
        .defaultSize(width: 940, height: 660)

        Window(tr("Intérprete de Python"), id: "python") {
            PythonConsoleView().environment(model)
        }
        .defaultSize(width: 760, height: 560)

        Window(tr("Extensiones"), id: "extensions") {
            ExtensionsView().environment(model)
        }
        .defaultSize(width: 760, height: 520)

        Window(tr("Herramientas del proyecto"), id: "projecttools") {
            ProjectToolsView().environment(model)
        }
        .defaultSize(width: 1100, height: 620)

        Window(tr("Ayuda"), id: "help") {
            HelpView()
        }
        .defaultSize(width: 720, height: 600)

        Window(tr("Visor de bytes"), id: "bytes") {
            ByteViewerView().environment(model)
        }
        .defaultSize(width: 980, height: 640)

        Window(tr("Herramientas del programa"), id: "program") {
            ProgramToolsView().environment(model)
        }
        .defaultSize(width: 980, height: 640)

        WindowGroup(tr("Vista adicional"), id: "snapshot", for: SnapshotSpec.self) { $spec in
            if let spec {
                SnapshotView(spec: spec).environment(model)
            }
        }
        .defaultSize(width: 860, height: 620)

        Window(tr("Depurador"), id: "debugger") {
            DebuggerView().environment(model)
        }
        .defaultSize(width: 1280, height: 800)

        Window("Function ID", id: "fid") {
            FunctionIDView().environment(model)
        }
        .defaultSize(width: 860, height: 600)

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
            if url.scheme == "ghidra" {
                // GhidraGo: a ghidra: link opens its project and program
                AppModel.shared.openGhidraURL(url.absoluteString)
            } else if url.pathExtension == "gpr" {
                AppModel.shared.openProject(url.path)
            } else if url.pathExtension == "studiotrace" {
                // a recorded debug trace: show it in the debugger, against the program that is open
                do {
                    try AppModel.shared.debugger.loadTrace(from: url)
                    AppModel.shared.windowRequest = "debugger"
                } catch {
                    AppModel.shared.errorMessage = tr("No se pudo abrir la traza: %@", error.localizedDescription)
                }
            } else {
                AppModel.shared.open(url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Ask about unsaved changes before quitting (Save / Don't Save / Cancel), like the CodeBrowser.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = MainActor.assumeIsolated { AppModel.shared }
        let hasTabs = MainActor.assumeIsolated { !model.tabs.isEmpty }
        guard hasTabs else { return .terminateNow }
        Task { @MainActor in
            let proceed = await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.debugger.terminate()
            AppModel.shared.engine.shutdown()
        }
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
    private var keys: Shortcuts { Shortcuts.shared }

    /// Opens a tool window, or shows it where it is docked.
    private func show(_ id: String) {
        if !model.dock.reveal(window: id) { openWindow(id: id) }
    }

    private func listingOption(_ path: WritableKeyPath<ListingOptions, Bool>) -> Binding<Bool> {
        Binding(get: { model.listingOptions[keyPath: path] }, set: { model.listingOptions[keyPath: path] = $0 })
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("Nuevo proyecto…")) { model.presentNewProject() }
                .keyboardShortcut(keys.shortcut(.newProject))
            Button(tr("Abrir proyecto…")) { model.presentOpenProject() }
                .keyboardShortcut(keys.shortcut(.openProject))
            Menu(tr("Proyectos recientes")) {
                ForEach(model.recentProjects, id: \.self) { gpr in
                    Button((gpr as NSString).lastPathComponent) { model.openProject(gpr) }
                }
                Divider()
                Button(tr("Proyecto por defecto")) { model.openDefaultProject() }
            }
            Divider()
            Button(tr("Importar binario…")) { model.presentOpenPanel() }
                .keyboardShortcut(keys.shortcut(.importBinary))
            Button(tr("Abrir binario rápido…")) {
                let panel = NSOpenPanel()
                panel.treatsFilePackagesAsDirectories = true
                if panel.runModal() == .OK, let url = panel.url { model.open(url) }
            }
            .keyboardShortcut(keys.shortcut(.quickOpenBinary))
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
                .keyboardShortcut(keys.shortcut(.export))
                .disabled(model.program == nil)
            Button(tr("Exportar programa (.gzf)…")) { model.presentExportPacked() }
                .disabled(model.program == nil)
            Button(tr("Archivar proyecto (.zip)…")) { model.archiveProject() }
                .disabled(model.project?.open != true)
            Divider()
            Button(tr("Imprimir…")) { model.printCurrentView() }
                .keyboardShortcut(keys.shortcut(.print))
                .disabled(model.program == nil)
            Divider()
            Button(tr("Cerrar programa")) { model.closeProgram() }
                .keyboardShortcut(keys.shortcut(.closeProgram))
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

        CommandGroup(after: .newItem) {
            Button(tr("Abrir una URL de Ghidra…")) { model.requestOpenGhidraURL() }
            Button(tr("Copiar la URL de Ghidra del programa")) { model.copyGhidraURL() }
                .disabled(model.program == nil)
            Divider()
            Button(tr("Guardar")) { model.save() }
                .disabled(!model.isDirty)
            Button(tr("Guardar como…")) { model.requestSaveAs() }
                .disabled(model.program == nil)
            Button(tr("Guardar todo")) { model.saveAll() }
                .disabled(model.dirtyTabs.isEmpty)
            Button(tr("Cerrar los demás programas")) { model.closeOtherPrograms() }
                .disabled(model.tabs.count < 2)
            Divider()
            Button(tr("Añadir un archivo al programa…")) { model.requestAddToProgram() }
                .disabled(model.program == nil)
            Button(tr("Importar la selección como programa nuevo…")) { model.requestImportSelection() }
                .disabled(model.programSelection == nil)
            Button(tr("Restaurar un proyecto archivado…")) { model.restoreProject() }
            Button(tr("Herramientas del proyecto")) { show("projecttools") }
                .disabled(model.project?.open != true)
        }

        CommandGroup(replacing: .saveItem) {
            Button(tr("Guardar")) { model.save() }
                .keyboardShortcut(keys.shortcut(.save))
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

        CommandGroup(after: .pasteboard) {
            Menu(tr("Copiar especial")) {
                ForEach(CopyFormats.all, id: \.0) { format in
                    Button(format.1) { model.copySpecial(format.0) }
                }
            }
            .disabled(model.current == nil)
        }

        CommandGroup(after: .toolbar) {
            Picker(tr("Vista"), selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .disabled(model.program == nil)
            Button(tr("Descompilado")) { model.viewMode = .decompiler }.keyboardShortcut(keys.shortcut(.viewDecompiler))
            Button(tr("Desensamblado")) { model.viewMode = .listing }.keyboardShortcut(keys.shortcut(.viewListing))
            Button(tr("Listado completo")) { model.viewMode = .program }.keyboardShortcut(keys.shortcut(.viewProgram))
            Button(tr("Grafo de la función")) { model.viewMode = .graph }.keyboardShortcut(keys.shortcut(.viewGraph))
            Button("Hex") { model.viewMode = .hex }.keyboardShortcut(keys.shortcut(.viewHex))
            Divider()
            Button(model.listingOptions.showFlowArrows ? tr("Ocultar flechas de flujo") : tr("Mostrar flechas de flujo")) {
                model.listingOptions.showFlowArrows.toggle()
            }
            Button(model.listingOptions.showOverview ? tr("Ocultar la barra de vista general") : tr("Mostrar la barra de vista general")) {
                model.listingOptions.showOverview.toggle()
            }
            Button(model.listingOptions.showEntropyBar ? tr("Ocultar la barra de entropía") : tr("Mostrar la barra de entropía")) {
                model.listingOptions.showEntropyBar.toggle()
            }
            Menu(tr("Plegar funciones")) {
                Button(tr("Plegar o desplegar la función")) { model.foldCurrentFunction() }
                    .keyboardShortcut(keys.shortcut(.foldFunction))
                Button(tr("Plegar todas")) { model.foldAllFunctions(true) }
                Button(tr("Desplegar todas")) { model.foldAllFunctions(false) }
            }
            .disabled(model.current == nil)
            Menu(tr("Campos del listado")) {
                Toggle(tr("Offset de archivo"), isOn: listingOption(\.showFileOffset))
                Toggle(tr("Offset dentro de la función"), isOn: listingOption(\.showFunctionOffset))
                Toggle(tr("Lista de XREFs"), isOn: listingOption(\.showXrefList))
                Toggle(tr("XREFs a través de thunks"), isOn: listingOption(\.showThunkXrefs))
                Toggle("P-code", isOn: listingOption(\.showPcode))
                Toggle(tr("Línea de código fuente"), isOn: listingOption(\.showSource))
                Toggle(tr("Ventanas emergentes al pasar el ratón"), isOn: listingOption(\.hoverPopups))
            }
            DockCommands(model: model)
            Menu(tr("Vista dividida")) {
                Button((model.splitMode == nil ? "✓ " : "") + tr("Una sola vista")) { model.splitMode = nil }
                Button((model.splitMode == "decompiler" ? "✓ " : "") + tr("Con el descompilado al lado")) { model.splitMode = "decompiler" }
                Button((model.splitMode == "listing" ? "✓ " : "") + tr("Con el desensamblado al lado")) { model.splitMode = "listing" }
            }
            Button(tr("Nueva ventana de listado")) { model.openSnapshot(mode: "listing") }
                .keyboardShortcut(keys.shortcut(.newListingWindow))
                .disabled(model.current == nil)
            Button(tr("Nueva ventana del descompilador")) { model.openSnapshot(mode: "decompiler") }
                .disabled(model.current == nil)
            Button(model.showInspector ? tr("Ocultar inspector") : tr("Mostrar inspector")) { model.showInspector.toggle() }
                .keyboardShortcut(keys.shortcut(.toggleInspector))
            Divider()
            Button(tr("Aumentar tamaño de letra")) { model.fontSize = min(28, model.fontSize + 1) }
                .keyboardShortcut(keys.shortcut(.fontBigger))
            Button(tr("Reducir tamaño de letra")) { model.fontSize = max(9, model.fontSize - 1) }
                .keyboardShortcut(keys.shortcut(.fontSmaller))
            Button(tr("Tamaño de letra normal")) { model.fontSize = 13 }
                .keyboardShortcut(keys.shortcut(.fontNormal))
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button(tr("Ayuda de esta ventana")) {
                if !HelpCenter.openForFrontWindow() { show("help") }
            }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: [])
            Button(tr("Temas de ayuda de Ghidra")) { show("help") }
                .keyboardShortcut("?", modifiers: [.command])
            Button(tr("Información de ejecución y procesadores")) { model.showTools("runtime") }
            Divider()
            Button(tr("Chuleta de atajos de Ghidra")) { openDoc("CheatSheet.html") }
            Button(tr("Novedades de Ghidra")) { openDoc("WhatsNew.html") }
            Button(tr("Curso de Ghidra (GhidraClass)")) { openDoc("GhidraClass") }
            Button(tr("Documentación de la API (Javadoc)")) { openDoc("GhidraAPI_javadoc.zip") }
            Divider()
            Button(tr("Registro del motor")) { NSWorkspace.shared.open(Engine.logFile) }
        }

        CommandMenu(tr("Navegar")) {
            Button(tr("Abrir rápidamente…")) { model.showQuickOpen = true }
                .keyboardShortcut(keys.shortcut(.quickOpen))
                .disabled(model.program == nil)
            Button(tr("Ir a dirección…")) { model.showQuickOpen = true }
                .keyboardShortcut(keys.shortcut(.goToAddress))
                .disabled(model.program == nil)
            Button(tr("Ir a expresión, offset de archivo o comodín…")) { model.requestGoToExpression() }
            Button(tr("Ir al código fuente del símbolo (Eclipse)")) { model.lookupSourceInEclipse() }
                .disabled(model.current == nil)
                .disabled(model.program == nil)
            Divider()
            Menu(tr("Siguiente")) {
                ForEach(NavigationKinds.all, id: \.0) { kind in
                    Button(kind.1) { model.goNext(kind.0, forward: true) }
                }
            }
            .disabled(model.current == nil)
            Menu(tr("Anterior")) {
                ForEach(NavigationKinds.all, id: \.0) { kind in
                    Button(kind.1) { model.goNext(kind.0, forward: false) }
                }
            }
            .disabled(model.current == nil)
            Button(tr("Siguiente función")) { model.goNext("function", forward: true) }
                .keyboardShortcut(keys.shortcut(.nextFunction))
                .disabled(model.current == nil)
            Button(tr("Función anterior")) { model.goNext("function", forward: false) }
                .keyboardShortcut(keys.shortcut(.previousFunction))
                .disabled(model.current == nil)
            Menu(tr("Descompilador")) {
                Button(tr("Ir a la llave de cierre")) { CodeNSTextView.current?.navigator?("braceNext") }
                    .keyboardShortcut(keys.shortcut(.braceNext))
                Button(tr("Ir a la llave de apertura")) { CodeNSTextView.current?.navigator?("bracePrevious") }
                    .keyboardShortcut(keys.shortcut(.bracePrevious))
                Button(tr("Resaltado siguiente")) { CodeNSTextView.current?.navigator?("highlightNext") }
                    .keyboardShortcut(keys.shortcut(.highlightNext))
                Button(tr("Resaltado anterior")) { CodeNSTextView.current?.navigator?("highlightPrevious") }
                    .keyboardShortcut(keys.shortcut(.highlightPrevious))
            }
            .disabled(model.current == nil)
            Divider()
            Button(tr("Atrás")) { model.goBack() }
                .keyboardShortcut(keys.shortcut(.back))
                .disabled(!model.canGoBack)
            Button(tr("Adelante")) { model.goForward() }
                .keyboardShortcut(keys.shortcut(.forward))
                .disabled(!model.canGoForward)
            Divider()
            Button(tr("Ir al punto de entrada")) {
                if let entry = model.program?.entry { model.go(entry) }
            }
            .keyboardShortcut(keys.shortcut(.goEntry))
            .disabled(model.program?.entry == nil)
            Divider()
            ForEach(model.tabs) { tab in
                Button(tab.name) { model.activate(tab.id) }
            }
        }

        CommandMenu(tr("Selección")) {
            ForEach(Array(SelectMenu.items.enumerated()), id: \.offset) { _, item in
                if item.0 == "-" {
                    Divider()
                } else if item.0 == "function" {
                    Button(item.1) { model.select(item.0) }
                        .keyboardShortcut(keys.shortcut(.selectFunction))
                        .disabled(model.current == nil)
                } else if item.0 == "flowFrom" {
                    Button(item.1) { model.select(item.0) }
                        .keyboardShortcut(keys.shortcut(.selectFlowFrom))
                        .disabled(model.current == nil)
                } else {
                    Button(item.1) { model.select(item.0) }
                        .disabled(model.current == nil || (item.0 == "complement" && model.programSelection == nil))
                }
            }
            Divider()
            Button(tr("Quitar la selección")) { model.clearProgramSelection() }
                .keyboardShortcut(keys.shortcut(.clearSelection))
                .disabled(model.programSelection == nil)
            Button(tr("Rango siguiente de la selección")) { model.goToSelectionRange(next: true) }
                .disabled(model.programSelection == nil)
            Button(tr("Rango anterior de la selección")) { model.goToSelectionRange(next: false) }
                .disabled(model.programSelection == nil)
            Divider()
            Button(tr("Seleccionar bytes…")) { model.requestSelectBytes() }
                .disabled(model.current == nil)
            Menu(tr("Resaltado")) {
                Button(tr("Resaltar la selección")) { model.highlightAction("set") }
                    .disabled(model.programSelection == nil)
                Button(tr("Añadir la selección al resaltado")) { model.highlightAction("add") }
                    .disabled(model.programSelection == nil)
                Button(tr("Quitar la selección del resaltado")) { model.highlightAction("subtract") }
                    .disabled(model.programSelection == nil || model.highlight == nil)
                Button(tr("Seleccionar lo resaltado")) { model.highlightAction("select") }
                    .disabled(model.highlight == nil)
                Button(tr("Quitar el resaltado")) { model.highlightAction("clear") }
                    .disabled(model.highlight == nil)
            }
            Menu(tr("Color de fondo")) {
                ForEach(ListingColors.all, id: \.1) { color in
                    Button(color.0) { model.setColor(color.1) }
                }
                Divider()
                Button(tr("Quitar el color")) { model.setColor(nil) }
                Button(tr("Quitar todos los colores")) { model.clearAllColors() }
                    .disabled(model.colorRanges.isEmpty)
            }
            .disabled(model.current == nil)
            Divider()
            Button(tr("Desensamblar la selección")) { model.selectionAction("disassemble") }
                .disabled(model.programSelection == nil)
            Button(tr("Borrar el código y los datos de la selección")) { model.selectionAction("clear") }
                .disabled(model.programSelection == nil)
            Button(tr("Añadir un marcador en cada rango")) { model.selectionAction("bookmark") }
                .disabled(model.programSelection == nil)
        }

        CommandMenu(tr("Análisis")) {
            Button(tr("Renombrar función…")) { model.requestRename() }
                .keyboardShortcut(keys.shortcut(.renameFunction))
                .disabled(model.functionDetails == nil)
            Button(tr("Editar firma…")) { model.requestSignature() }
                .keyboardShortcut(keys.shortcut(.editSignature))
                .disabled(model.functionDetails == nil)
            Button(tr("Comentario…")) { model.requestComment() }
                .keyboardShortcut(keys.shortcut(.comment))
                .disabled(model.current == nil)
            Button(tr("Añadir etiqueta…")) { model.requestLabel() }
                .disabled(model.current == nil)
            Button(tr("Añadir marcador…")) { model.requestBookmark() }
                .keyboardShortcut(keys.shortcut(.bookmark))
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
            Button(tr("Escribir texto…")) { model.requestPatchText() }
                .disabled(model.current == nil)
            Button(tr("Escribir entero…")) { model.requestPatchInt() }
                .disabled(model.current == nil)
            Button(tr("Desensamblar con opciones…")) { model.requestDisassembleOptions() }
                .disabled(model.current == nil)
            Menu(tr("Borrar")) {
                Button(tr("Borrar con opciones…")) { model.requestClearWithOptions() }
                Button(tr("Borrar flujo y reparar…")) { model.requestClearFlow() }
            }
            .disabled(model.current == nil)
            Menu(tr("Datos")) {
                Button(tr("Ciclo byte → word → dword → qword")) { model.cycleData("byte") }
                    .keyboardShortcut(keys.shortcut(.cycleInteger))
                Button(tr("Ciclo float → double")) { model.cycleData("float") }
                    .keyboardShortcut(keys.shortcut(.cycleFloat))
                Button(tr("Ciclo char → string → unicode")) { model.cycleData("string") }
                    .keyboardShortcut(keys.shortcut(.cycleChar))
                Divider()
                Menu(tr("Tipos recientes")) {
                    let _ = model.recentTypesVersion
                    if model.recentTypes.isEmpty { Text(tr("Ninguno todavía")) }
                    ForEach(model.recentTypes, id: \.self) { type in
                        Button(type) { model.applyType(type) }
                    }
                }
                Button(tr("Aplicar el último tipo usado  (Y)")) { model.applyLastType() }
                Button(tr("Editar el campo de la estructura…")) { model.requestEditField() }
                Divider()
                Button(tr("Parchear dato…")) { model.requestPatchData() }
                Button(tr("Abrir o cerrar la estructura o el array")) { if let a = model.editTarget { model.toggleData(a) } }
                Button(tr("Ajustes del dato…")) { model.showTools("data") }
            }
            .disabled(model.current == nil)
            Menu(tr("Convertir constante")) {
                ForEach(ConvertFormats.all, id: \.0) { format in
                    Button(format.1) { model.convert(format.0) }
                }
                Divider()
                Button(tr("Aplicar enum…")) { model.requestApplyEnum() }
                Button(tr("Tabla de equates")) { model.showTools("equates") }
            }
            .disabled(model.current == nil)
            Menu(tr("Función")) {
                Button(tr("Recrear la función")) { if let a = model.editTarget { model.run("recreateFunction", ["address": a]) } }
                Button(tr("Crear funciones en la selección")) { model.run("createFunctions", model.target) }
                Button(tr("Función thunk…")) { model.requestThunk() }
                Button(tr("Crear función externa…")) { model.requestExternalFunction() }
                Button(tr("Cambio de profundidad de pila…")) { model.requestStackDepthChange() }
                Button(tr("Purge, call-fixup y almacenamiento…")) { model.showTools("function") }
                Button(tr("Etiquetas de función")) { model.showTools("tags") }
            }
            .disabled(model.current == nil)
            Menu(tr("Instrucción")) {
                Button(tr("Modificar flujo, longitud y fallthrough…")) { model.requestInstructionOverrides() }
                Button(tr("Información de la instrucción")) { model.showTools("instruction") }
                Button(tr("Valores de registros")) { model.showTools("registers") }
            }
            .disabled(model.current == nil)
            Menu(tr("Etiquetas y referencias")) {
                Button(tr("Etiquetas e historial")) { model.showTools("labels") }
                Button(tr("Punto de entrada externo")) { if let a = model.editTarget { model.run("setEntryPoint", ["address": a, "on": true]) } }
                Button(tr("Quitar punto de entrada externo")) { if let a = model.editTarget { model.run("setEntryPoint", ["address": a, "on": false]) } }
                Button(tr("Editor de referencias")) { model.showTools("references") }
                Button(tr("Ventana de comentarios")) { model.showTools("comments") }
            }
            .disabled(model.current == nil)
            Divider()
            Button(tr("Editar función…")) { model.showFunctionEditor = true }
                .keyboardShortcut(keys.shortcut(.editFunction))
                .disabled(model.functionDetails == nil)
            Button(tr("Dividir como variable nueva…")) { model.splitVariableAtCursor() }
                .disabled(model.functionDetails == nil || model.viewMode != .decompiler)
            Button(tr("Forzar campo de unión…")) { model.forceUnionAtCursor() }
                .disabled(model.functionDetails == nil || model.viewMode != .decompiler)
            Button(tr("Fijar parámetros y retorno del descompilador")) { model.commitDecompiler("commitParams") }
                .disabled(model.functionDetails == nil)
            Button(tr("Fijar nombres de variables locales")) { model.commitDecompiler("commitLocals") }
                .disabled(model.functionDetails == nil)
            Button(tr("Crear array…")) { model.requestArray() }
                .disabled(model.current == nil)
            Button(tr("Fijar valor de registro…")) {
                if let a = model.editTarget { model.requestSetRegister(start: a, end: nil) }
            }
            .disabled(model.current == nil)
            Divider()
            Button(tr("Opciones del descompilador…")) { model.showDecompilerOptions = true }
                .disabled(model.program == nil)
            Button(tr("Cargar símbolos PDB…")) { model.presentLoadPDB() }
                .disabled(model.program == nil || model.analysis != nil)
            Button(tr("Descargar PDB de un servidor de símbolos…")) { model.requestPdbDownload() }
                .disabled(model.program == nil || model.analysis != nil)
            Button(tr("Cambiar dirección base…")) { model.requestImageBase() }
                .disabled(model.program == nil)
            Button(tr("Opciones de análisis…")) { model.showAnalysisOptions = true }
                .disabled(model.program == nil)
            Button(tr("Analizar ahora")) { model.analyzeNow() }
                .keyboardShortcut(keys.shortcut(.analyzeNow))
                .disabled(model.program == nil || model.analysis != nil)
            Button(tr("Analizar todos los programas abiertos")) { model.analyzeAllOpen() }
                .disabled(model.tabs.count < 2 || model.analysis != nil)
            Menu(tr("Configuraciones de análisis")) {
                Button(tr("Guardar la configuración actual…")) { model.requestSaveAnalysisConfig() }
                if !model.analysisConfigs.isEmpty {
                    Divider()
                    ForEach(model.analysisConfigs, id: \.self) { name in
                        Button(tr("Aplicar «%@»", name)) { model.applyAnalysisConfig(name) }
                    }
                    Divider()
                    Menu(tr("Borrar")) {
                        ForEach(model.analysisConfigs, id: \.self) { name in
                            Button(name, role: .destructive) { model.deleteAnalysisConfig(name) }
                        }
                    }
                }
            }
            .disabled(model.program == nil)
            Button(tr("Validar el programa")) { model.showTools("validate") }
                .disabled(model.program == nil)
            Button(tr("Archivos de depuración (DWARF y servidores PDB)")) { model.showTools("debugFiles") }
                .disabled(model.program == nil)
            Button(tr("Patrones de inicio de función")) { model.showTools("fnPatterns") }
                .disabled(model.program == nil)
            Button(tr("Reimportar y reanalizar desde cero")) { model.reanalyze() }
                .disabled(model.program == nil)
        }

        CommandMenu(tr("Depurar")) {
            Button(tr("Depurador")) { show("debugger") }
                .keyboardShortcut(keys.shortcut(.debugger))
            Divider()
            Button(model.debugger.isActive ? tr("Continuar") : tr("Iniciar depuración")) {
                if model.debugger.isActive {
                    model.debugger.resumeExecution()
                } else {
                    show("debugger")
                    model.debugger.loadConfig()
                    if FileManager.default.isExecutableFile(atPath: model.debugger.config.program),
                       model.debugger.config.mode == .launch {
                        model.debugger.start()
                    }
                }
            }
            .keyboardShortcut(keys.shortcut(.debugContinue))
            .disabled(model.debugger.phase == .running || model.debugger.phase == .starting)
            Button(tr("Pausar")) { model.debugger.pause() }
                .keyboardShortcut(keys.shortcut(.debugPause))
                .disabled(model.debugger.phase != .running)
            Button(tr("Paso entrando en llamadas")) { model.debugger.stepInto() }
                .keyboardShortcut(keys.shortcut(.debugStepInto))
                .disabled(!model.debugger.isStopped)
            Button(tr("Paso sin entrar en llamadas")) { model.debugger.stepOver() }
                .keyboardShortcut(keys.shortcut(.debugStepOver))
                .disabled(!model.debugger.isStopped)
            Button(tr("Salir de la función")) { model.debugger.stepOut() }
                .keyboardShortcut(keys.shortcut(.debugStepOut))
                .disabled(!model.debugger.isStopped)
            Button(tr("Ejecutar hasta el cursor")) {
                if let a = model.editTarget { model.debugger.run(toStatic: a) }
            }
            .disabled(!model.debugger.isStopped || model.current == nil)
            Button(tr("Detener la depuración")) { model.debugger.stop() }
                .disabled(!model.debugger.isActive)
            Divider()
            Button(tr("Poner o quitar breakpoint")) { model.toggleBreakpoint() }
                .keyboardShortcut(keys.shortcut(.toggleBreakpoint))
                .disabled(model.current == nil)
            Button(tr("Quitar todos los breakpoints")) { model.clearBreakpoints() }
                .disabled(model.breakpoints.isEmpty)
            Divider()
            Button(tr("Depurador de Ghidra clásico…")) { model.openDebugger() }
                .disabled(model.project?.open != true)
        }

        CommandMenu(tr("Herramientas")) {
            Button(tr("Tipos de datos")) { show("types") }
                .keyboardShortcut(keys.shortcut(.types))
            Button(tr("Gestor de tipos: categorías, archivos, sincronización, cabeceras")) { show("typemanager") }
            Button(tr("Buscar en el programa…")) { show("search") }
                .keyboardShortcut(keys.shortcut(.search))
            Button(tr("Árbol de llamadas")) { show("calls") }
                .keyboardShortcut(keys.shortcut(.calls))
            Button(tr("Scripts")) { show("scripts") }
                .keyboardShortcut(keys.shortcut(.scripts))
            Button(tr("Integración con Eclipse…")) { model.requestEclipseSettings() }
            Button(tr("Ejecutar el último script")) { if let path = model.lastScript { model.runScript(path: path) } }
                .keyboardShortcut(keys.shortcut(.runLastScript))
                .disabled(model.program == nil || model.lastScript == nil)
            Menu(tr("Scripts con atajo")) {
                let _ = model.scriptShortcutsRevision
                ForEach(model.scriptShortcuts.keys.sorted(), id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { model.runScript(path: path) }
                        .keyboardShortcut(Shortcuts.parse(model.scriptShortcuts[path] ?? ""))
                }
            }
            .disabled(model.program == nil || model.scriptShortcuts.isEmpty)
            Button(tr("Importar resultados SARIF")) { model.showTools("sarif") }
                .disabled(model.program == nil)
            Divider()
            Button(tr("Grafos (llamadas, programa, referencias)")) { show("graphs") }
                .keyboardShortcut(keys.shortcut(.graphs))
            Button(tr("Emulador")) { show("emulator") }
                .keyboardShortcut(keys.shortcut(.emulator))
            Button(tr("Comparar programas (Diff y correlación rápida)")) { show("compare") }
                .keyboardShortcut(keys.shortcut(.compare))
            Button(tr("Comparar funciones lado a lado")) { show("funccompare") }
                .keyboardShortcut(keys.shortcut(.funcCompare))
            Button(tr("Tablas (símbolos, cadenas, constantes, relocaciones)")) { show("tables") }
                .keyboardShortcut(keys.shortcut(.tables))
            Divider()
            Button(tr("Version Tracking")) { show("vt") }
                .keyboardShortcut(keys.shortcut(.versionTracking))
            Button("BSim") { show("bsim") }
                .keyboardShortcut(keys.shortcut(.bsim))
            Button(tr("Ghidra Server y control de versiones")) { show("server") }
                .keyboardShortcut(keys.shortcut(.server))
            Button(tr("Intérprete de Python")) { show("python") }
                .keyboardShortcut(keys.shortcut(.python))
            Button(tr("Extensiones")) { show("extensions") }
            Button(tr("Visor de bytes (formatos y edición)")) { show("bytes") }
            Button(tr("Namespaces, externos, pila, checksums…")) { show("program") }
            Button(tr("Buscar en todo el código descompilado")) { model.showTools("decompSearch") }
                .disabled(model.program == nil)
            Button(tr("Extensiones de especificación (call-fixups, convenciones)")) { model.showTools("specext") }
                .disabled(model.program == nil)
            Button("Taint") { model.showTools("taint") }
                .disabled(model.program == nil)
            Button(tr("Opciones y propiedades del programa")) { model.showTools("options") }
                .disabled(model.program == nil)
            Button(tr("Árbol del programa")) { model.showTools("tree") }
                .disabled(model.program == nil)
            Button(tr("Cambiar el lenguaje del programa…")) { model.requestSetLanguage() }
                .disabled(model.program == nil)
            Button("Function ID") { show("fid") }
                .keyboardShortcut(keys.shortcut(.functionID))
        }
    }
}

/// The things "next" and "previous" can look for.
enum NavigationKinds {
    static var all: [(String, String)] {
        [("instruction", tr("Instrucción")), ("data", tr("Dato")), ("undefined", tr("Indefinido")), ("label", tr("Etiqueta")),
         ("function", tr("Función")), ("nonFunction", tr("Código fuera de funciones")), ("bookmark", tr("Marcador")),
         ("byte", tr("Byte distinto"))]
    }
}

enum ConvertFormats {
    static var all: [(String, String)] {
        [("unsignedHex", tr("Hexadecimal sin signo")), ("signedHex", tr("Hexadecimal con signo")), ("unsignedDecimal", tr("Decimal sin signo")), ("signedDecimal", tr("Decimal con signo")),
         ("octal", tr("Octal")), ("binary", tr("Binario")), ("char", tr("Carácter")), ("float", "Float"), ("double", "Double")]
    }
}

enum CopyFormats {
    static var all: [(String, String)] {
        [("hex", tr("Bytes en hexadecimal")), ("hexSpaced", tr("Bytes en hexadecimal con espacios")), ("c", tr("Array de C")),
         ("python", tr("Bytes de Python")), ("string", tr("Cadena")), ("address", tr("Dirección")),
         ("addressOffset", tr("Etiqueta + offset")), ("fileOffset", tr("Offset de archivo")), ("label", tr("Etiqueta")),
         ("listing", tr("Texto del listado"))]
    }
}

enum ListingColors {
    static var all: [(String, String)] {
        [(tr("Amarillo"), "ffd60a"), (tr("Naranja"), "ff9f0a"), (tr("Rojo"), "ff453a"), (tr("Rosa"), "ff375f"),
         (tr("Morado"), "bf5af2"), (tr("Azul"), "0a84ff"), (tr("Turquesa"), "64d2ff"), (tr("Verde"), "30d158"),
         (tr("Gris"), "8e8e93")]
    }
}

/// Opens one of the documents bundled with Ghidra (docs folder).
private func openDoc(_ name: String) {
    let url = Bundle.main.resourceURL!.appendingPathComponent("ghidra/docs/\(name)")
    NSWorkspace.shared.open(url)
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab(tr("General"), systemImage: "gearshape") { general }
            Tab(tr("Listado"), systemImage: "list.bullet.indent") { ListingSettingsView() }
            Tab(tr("Atajos"), systemImage: "keyboard") { ShortcutsSettingsView() }
            Tab(tr("Tema"), systemImage: "paintpalette") { ThemeSettingsView() }
        }
        .frame(width: 560, height: 620)
    }

    private var general: some View {
        @Bindable var model = model
        return Form {
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
            Section(tr("Copias de recuperación")) {
                Stepper(model.recoveryMinutes == 0 ? tr("Desactivadas")
                        : tr("Cada %@ minutos", "\(model.recoveryMinutes)"),
                        value: $model.recoveryMinutes, in: 0...60)
                Text(tr("Guarda aparte los cambios sin guardar de los programas abiertos. Si la app se cierra de golpe, al volver a abrir el programa podrás recuperarlos."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("Motor")) {
                LabeledContent(tr("Estado"), value: model.engineStatus)
                LabeledContent("Python", value: model.pythonVersion.map { "\($0) (PyGhidra)" } ?? tr("No disponible"))
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
        }
        .formStyle(.grouped)
    }
}
