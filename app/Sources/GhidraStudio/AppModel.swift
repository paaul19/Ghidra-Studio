import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Phase: Equatable {
    case welcome
    case loading(message: String, progress: Double?)
    case open
    /// The project was handed over to the classic Ghidra.
    case classic(gpr: String)
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case project, functions, symbols, imports, exports, strings, segments, bookmarks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: tr("Proyecto")
        case .functions: tr("Funciones")
        case .symbols: tr("Símbolos")
        case .imports: tr("Importaciones")
        case .exports: tr("Exportaciones")
        case .strings: tr("Cadenas")
        case .segments: tr("Segmentos")
        case .bookmarks: tr("Marcadores")
        }
    }

    var icon: String {
        switch self {
        case .project: "folder"
        case .functions: "function"
        case .symbols: "list.bullet.indent"
        case .imports: "arrow.down.to.line"
        case .exports: "arrow.up.to.line"
        case .strings: "textformat.abc"
        case .segments: "square.stack.3d.up"
        case .bookmarks: "bookmark"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case decompiler, listing, program, graph, hex
    var id: String { rawValue }

    var title: String {
        switch self {
        case .decompiler: tr("Descompilado")
        case .listing: tr("Desensamblado")
        case .program: tr("Listado")
        case .graph: tr("Grafo")
        case .hex: "Hex"
        }
    }

    var icon: String {
        switch self {
        case .decompiler: "curlybraces"
        case .listing: "list.bullet.indent"
        case .program: "doc.plaintext"
        case .graph: "point.3.filled.connected.trianglepath.dotted"
        case .hex: "number"
        }
    }

    var isListingLike: Bool { self == .listing || self == .program }
}

struct Location: Equatable {
    let address: String
    let function: String?
}

struct AnalysisStatus: Equatable {
    var message: String
    var progress: Double?
}

struct ScrollRequest: Equatable {
    let id = UUID()
    let address: String
}

struct OpenTab: Identifiable, Equatable {
    let id: String
    var name: String
    var analysis: AnalysisStatus?
}

/// A request for a small text-input sheet (rename, comment, patch, ...).
struct EditRequest: Identifiable {
    enum Kind: Equatable {
        case rename, comment, functionComment, label, bookmark
        case renameVariable(function: String, name: String), retypeVariable(function: String, name: String), signature
        case createData, createFunction, patch, assemble, equate, addReference, renameBlock(name: String)
        case renameField(type: String, offset: Int), overrideSignature(callSite: String), retypeGlobal
        case splitVariable(token: Int)
        case imageBase, expandBlock(name: String), patchText, patchInt, functionDefinition, pdbServer
        case createArray, structFromRange(end: String), setRegister(end: String)
        case splitBlock(name: String), moveBlock(name: String)
        case newFolder(parent: String), renameItem(path: String, folder: Bool)
    }

    let id = UUID()
    let kind: Kind
    let address: String
    var title: String
    var prompt: String
    var initialText: String = ""
    var commentKind: String = "eol"
    var monospaced = true
    var multiline = false
}

struct ImportRequest: Identifiable {
    let id = UUID()
    /// A local path or a Ghidra FSRL (file inside a container).
    let source: String
    let name: String
    var isLocalFile: Bool { !source.hasPrefix("file://") }

    init(url: URL) {
        source = url.path
        name = url.lastPathComponent
    }

    init(entry: FSEntry) {
        source = entry.fsrl
        name = entry.name
    }
}

/// Disassemble-with-options sheet: where to start and, with a selection, where to stop.
struct DisassembleRequest: Identifiable {
    let id = UUID()
    let start: String
    let end: String?
}

/// Force-union-field sheet: the function and the decompiler token of the field.
struct UnionRequest: Identifiable {
    let id = UUID()
    let function: String
    let token: Int
}

/// A container (zip, firmware, disk image…) being browsed before importing.
struct ContainerRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// Everything the UI shows for one open program, kept while another tab is active.
private struct SessionSnapshot {
    var program: ProgramInfo?
    var functions: [FunctionItem]
    var imports: [ImportItem]
    var exports: [ExportItem]
    var strings: [StringItem]
    var segments: [SegmentItem]
    var bookmarks: [BookmarkItem]
    var current: Location?
    var backStack: [Location]
    var forwardStack: [Location]
    var selectedAddress: String?
    var undo: UndoState?
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine = Engine()

    var phase: Phase = .welcome
    var engineStatus: String = tr("Iniciando motor de Ghidra…")
    var engineReady = false
    var errorMessage: String?
    /// Version of the bundled CPython when the engine is hosted by PyGhidra (nil = plain Java engine).
    var pythonVersion: String?
    /// Progress of long engine operations, by task name ("bsim", "vt", "vc").
    var tasks: [String: TaskStatus] = [:]
    private var engineRestarting = false

    // Project & tabs
    var project: ProjectInfo?
    var tabs: [OpenTab] = []
    var activeSession: String?
    private var snapshots: [String: SessionSnapshot] = [:]

    // Active program
    var program: ProgramInfo?
    var functions: [FunctionItem] = []
    var imports: [ImportItem] = []
    var exports: [ExportItem] = []
    var strings: [StringItem] = []
    var segments: [SegmentItem] = []
    var bookmarks: [BookmarkItem] = []
    var programTree: [TreeGroup] = []
    var undo: UndoState?

    var sidebarTab: SidebarTab = .functions
    var sidebarSelection: String?
    var filter = ""

    var viewMode: ViewMode = .decompiler {
        didSet { if oldValue != viewMode { Task { await loadContent() } } }
    }
    var current: Location?
    var selectedAddress: String?
    var scrollRequest: ScrollRequest?
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []

    var decompilation: Decompilation?
    var listing: Listing?
    var fullRows: [ListingRow] = []
    var fullAtStart = false
    var fullAtEnd = false
    private var fullLoading = false
    private static let fullChunk = 1500
    private static let fullMaxRows = 12000
    var hexDump: HexDump?
    var graph: FunctionGraphData?
    var document: CodeDocument?
    var contentError: String?
    var isContentLoading = false

    var functionDetails: FunctionDetails?
    var locationXrefs: [XRef] = []

    // Presentation
    var showInspector = true
    var showQuickOpen = false
    var showAnalysisOptions = false
    var showExport = false
    var showAddBlock = false
    var disassembleRequest: DisassembleRequest?
    var unionRequest: UnionRequest?
    var showFunctionEditor = false
    var showDecompilerOptions = false
    var containerRequest: ContainerRequest?
    /// Entry addresses of the functions folded in the listing, by program.
    var foldedBySession: [String: Set<String>] = [:]
    var batchRequest: BatchRequest?
    /// Panels docked in the main window.
    let dock = DockStore()
    /// How many views that show the forms of the program tools are on screen (its window, or the whole window docked).
    var toolsHosts = 0
    /// Bumped when the list of recently used types changes, so menus redraw.
    var recentTypesVersion = 0
    var sliceTokens: Set<Int> = []
    /// Address ranges selected in the program (Select menu), and the data behind the overview bar.
    var programSelection: ProgramSelection?
    var overview: ProgramOverview?
    /// The debugger (one session at a time), mapped onto one of the open programs.
    let debugger = DebugSession()
    /// Entropy of the program in slices, for the entropy bar.
    var entropyBar: [Double] = []
    /// A multi-field form shown as a sheet.
    var formRequest: FormRequest?
    /// Bumped after every edit, so tables that show program data reload.
    var editCount = 0
    /// Persistent highlight (a second, independent address set) and the listing's background colors.
    var highlight: ProgramSelection?
    var colorRanges: [ColorRange] = []
    /// Structures and arrays opened in the listing: address → its components.
    var expandedData: [String: [DataComponent]] = [:]
    /// Which panel the program tools window should show (set by menu commands).
    var toolsPanel: String?
    /// Decompiler: secondary highlights (word → rgb), what is selected in another view, taint marks and results.
    var secondaryHighlights: [String: UInt32] = [:]
    var crossHighlight: Set<String> = []
    var taintSources = Set<String>()
    var taintSinks = Set<String>()
    var taintReached: [JSONRow] = []
    var mainTypeUses: TypeUsesRequest?
    var typeToShow: String?
    /// Functions another window asked the comparison window to show.
    var compareRequest: [String] = []
    var analysisConfigs: [String] = []
    var themeRevision = 0
    /// decompiler or listing: a second view next to the main one, following it.
    var splitMode: String? = UserDefaults.standard.string(forKey: "splitMode") {
        didSet { UserDefaults.standard.set(splitMode, forKey: "splitMode") }
    }
    /// A file or folder of the project copied to paste elsewhere, and a counter that reloads project tables.
    var projectClipboard: ProjectClip?
    var projectRevision = 0
    var scriptShortcutsRevision = 0
    /// A short note shown for a few seconds at the bottom of the main window.
    var statusMessage: String? {
        didSet {
            guard let message = statusMessage else { return }
            Task {
                try? await Task.sleep(for: .seconds(4))
                if statusMessage == message { statusMessage = nil }
            }
        }
    }
    var typeUsesRequest: TypeUsesRequest?
    /// Set to open one of the tool windows from code that has no view (the main window observes it).
    var windowRequest: String?
    /// Bumped when the emulator was started from elsewhere, so its window reloads.
    var emulatorRevision = 0
    /// Set to open an extra code window; the main window observes it (only views can open windows).
    var snapshotRequest: SnapshotSpec?
    private var overviewTask: Task<Void, Never>?
    var lineRefs: [RefFrom] = []
    private var lineRefsTask: Task<Void, Never>?
    var editRequest: EditRequest?
    var importRequest: ImportRequest?

    var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 13 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            rebuildDocument()
        }
    }

    /// Which fields the listing shows, and whether the jump arrows are drawn.
    var listingOptions = ListingOptions.load() {
        didSet {
            guard oldValue != listingOptions else { return }
            listingOptions.save()
            if oldValue.engineFields != listingOptions.engineFields {
                // the engine has to send other fields: fetch the listing again
                Task {
                    await sendListingFields()
                    invalidateCaches()
                    await loadContent()
                }
            } else {
                rebuildDocument()
            }
            if listingOptions.showOverview, overview == nil { refreshOverview() }
            if listingOptions.showEntropyBar, entropyBar.isEmpty { refreshOverview() }
        }
    }

    /// Minutes between recovery snapshots of unsaved changes (0 = off).
    var recoveryMinutes: Int = UserDefaults.standard.object(forKey: "recoveryMinutes") as? Int ?? 5 {
        didSet {
            UserDefaults.standard.set(recoveryMinutes, forKey: "recoveryMinutes")
            sendRecoveryInterval()
        }
    }

    /// Collapsed groups of blocks in function graphs, by "program|function entry".
    var graphGroups: [String: [GraphGroup]] = {
        guard let data = UserDefaults.standard.data(forKey: "graphGroups"),
              let value = try? JSONDecoder().decode([String: [GraphGroup]].self, from: data) else { return [:] }
        return value
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(graphGroups) { UserDefaults.standard.set(data, forKey: "graphGroups") }
        }
    }

    var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? [] {
        didSet { UserDefaults.standard.set(recents, forKey: "recents") }
    }

    var recentProjects: [String] = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] {
        didSet { UserDefaults.standard.set(recentProjects, forKey: "recentProjects") }
    }

    private var decompCache: [String: Decompilation] = [:]
    private var listingCache: [String: Listing] = [:]
    private var navToken = 0

    var analysis: AnalysisStatus? {
        tabs.first { $0.id == activeSession }?.analysis
    }

    var isDirty: Bool { undo?.changed ?? false }

    // MARK: - Engine

    func startEngine() {
        engine.onEvent = { [weak self] event, payload in
            self?.handleEvent(event, payload)
        }
        do {
            try engine.start()
        } catch {
            engineStatus = tr("No se pudo iniciar el motor: %@", "\(error.localizedDescription)")
        }
    }

    private func handleEvent(_ event: String, _ payload: [String: Any]) {
        let session = payload["session"] as? String
        switch event {
        case "ready":
            engineReady = true
            engineStatus = tr("Motor Ghidra %@ listo", "\(engine.version ?? "")")
            pythonVersion = payload["python"] as? String
            sendRecoveryInterval()
            if let error = payload["error"] as? String {
                errorMessage = error
            }
            Task { await refreshProject() }
        case "progress":
            guard case .loading = phase else { return }
            let message = payload["message"] as? String ?? tr("Cargando…")
            phase = .loading(message: message, progress: nil)
        case "analysisStarted":
            setAnalysis(session, AnalysisStatus(message: tr("Analizando…"), progress: nil))
        case "analysisProgress":
            guard let session, tabs.contains(where: { $0.id == session && $0.analysis != nil }) else { return }
            let value = payload["value"] as? Double ?? -1
            setAnalysis(session, AnalysisStatus(message: payload["message"] as? String ?? tr("Analizando…"),
                                                progress: value >= 0 ? value : nil))
        case "analysisDone":
            setAnalysis(session, nil)
            if session == nil || session == activeSession {
                Task { await refreshAfterAnalysis() }
            } else if let session {
                snapshots.removeValue(forKey: session)
            }
        case "task":
            guard let name = payload["task"] as? String else { return }
            if payload["done"] as? Bool == true {
                tasks.removeValue(forKey: name)
            } else {
                let value = payload["value"] as? Double ?? -1
                tasks[name] = TaskStatus(message: payload["message"] as? String ?? "", progress: value >= 0 ? value : nil)
            }
        case "terminated":
            engineReady = false
            engineStatus = tr("El motor se ha detenido")
            tasks = [:]
            if phase != .welcome && !engineRestarting {
                errorMessage = EngineError.terminated.localizedDescription
            }
            resetAll()
            phase = .welcome
        default:
            break
        }
    }

    /// Stops and starts the engine again (needed to load or unload extensions).
    func restartEngine() {
        Task {
            guard await prepareToQuit() else { return }
            // the engine always starts on the default project: go back to the one that was open
            let reopen = project?.isDefault == true ? nil : project?.gpr
            engineRestarting = true
            engineStatus = tr("Reiniciando el motor…")
            engine.shutdown()
            for _ in 0..<100 where engine.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            engineRestarting = false
            startEngine()
            if let reopen, (try? await engine.waitUntilReady()) != nil {
                openProject(reopen)
            }
        }
    }

    private func sendRecoveryInterval() {
        guard engineReady else { return }
        let minutes = recoveryMinutes
        Task { _ = try? await engine.call("setRecoveryInterval", ["minutes": minutes], as: Int.self) }
    }

    func cancelTask() {
        Task { _ = try? await engine.call("cancelTask", as: Bool.self) }
    }

    private func setAnalysis(_ session: String?, _ status: AnalysisStatus?) {
        guard let id = session ?? activeSession, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].analysis = status
    }

    // MARK: - Projects

    func refreshProject() async {
        do {
            project = try await engine.call("projectInfo")
            if let gpr = project?.gpr, project?.isDefault != true { addRecentProject(gpr) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var projectFolders: [ProjectFolder] { project?.tree?.allFolders ?? [] }

    func presentNewProject() {
        let panel = NSSavePanel()
        panel.title = tr("Nuevo proyecto")
        panel.message = tr("Elige dónde guardar el proyecto de Ghidra")
        panel.nameFieldStringValue = "MiProyecto"
        panel.prompt = tr("Crear")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await switchProject {
                try await self.engine.call("createProject", ["directory": url.deletingLastPathComponent().path,
                                                             "name": url.lastPathComponent], as: ProjectInfo.self)
            }
        }
    }

    func presentOpenProject() {
        let panel = NSOpenPanel()
        panel.title = tr("Abrir proyecto")
        panel.message = tr("Elige un proyecto de Ghidra (.gpr)")
        panel.canChooseDirectories = false
        if let gpr = UTType(filenameExtension: "gpr") { panel.allowedContentTypes = [gpr] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url.path)
    }

    func openProject(_ path: String) {
        Task {
            await switchProject { try await self.engine.call("openProject", ["path": path], as: ProjectInfo.self) }
        }
    }

    func openDefaultProject() {
        Task { await switchProject { try await self.engine.call("openDefaultProject", as: ProjectInfo.self) } }
    }

    private func switchProject(_ action: @escaping () async throws -> ProjectInfo) async {
        do {
            let info = try await action()
            resetAll()
            project = info
            if let gpr = info.gpr, info.isDefault != true { addRecentProject(gpr) }
            phase = .welcome
            sidebarTab = .project
            // back from the classic Ghidra: reopen the program that was handed over
            if let reopen = programToReopen {
                programToReopen = nil
                openProgram(domainPath: reopen)
            }
        } catch {
            programToReopen = nil
            errorMessage = error.localizedDescription
        }
    }

    /// A project created by the engine (e.g. a shared project bound to a server repository) becomes the open one.
    func adoptProject(_ info: ProjectInfo) {
        resetAll()
        project = info
        if let gpr = info.gpr, info.isDefault != true { addRecentProject(gpr) }
        phase = .welcome
        sidebarTab = .project
    }

    private func addRecentProject(_ gpr: String) {
        recentProjects.removeAll { $0 == gpr }
        recentProjects.insert(gpr, at: 0)
        if recentProjects.count > 10 { recentProjects = Array(recentProjects.prefix(10)) }
    }

    func projectAction(_ method: String, _ params: [String: Any]) {
        Task {
            do {
                project = try await engine.call(method, params)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteProjectItem(path: String, name: String, folder: Bool) {
        guard confirm(tr("¿Borrar «%@»?", "\(name)"),
                      folder ? tr("Se borrará la carpeta con todo su contenido. No se puede deshacer.")
                             : tr("Se borrará el programa y su análisis del proyecto. No se puede deshacer."),
                      action: tr("Borrar")) else { return }
        projectAction("deleteItem", ["path": path, "folder": folder])
    }

    func presentImportPacked() {
        let panel = NSOpenPanel()
        panel.title = tr("Importar archivo .gzf")
        if let gzf = UTType(filenameExtension: "gzf") { panel.allowedContentTypes = [gzf] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectAction("importPacked", ["path": url.path, "folder": "/"])
    }

    func presentExportPacked() {
        guard let program else { return }
        let panel = NSSavePanel()
        panel.title = tr("Exportar programa (.gzf)")
        panel.nameFieldStringValue = program.name + ".gzf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await engine.call("exportPacked", ["path": url.path], as: Bool.self)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Hands the project to the classic Ghidra (for the debugger, emulator, Version Tracking...).
    func openProjectInClassic() {
        guard confirm(tr("¿Abrir el proyecto en Ghidra clásico?"),
                      tr("Ghidra Studio guardará y cerrará el proyecto mientras lo usas en el Ghidra clásico. Cuando termines, cierra el clásico y vuelve a abrirlo aquí."),
                      action: tr("Abrir en el clásico")) else { return }
        Task {
            do {
                let info: ProjectInfo = try await engine.call("releaseProject")
                resetAll()
                project = nil
                guard let gpr = info.gpr else { return }
                phase = .classic(gpr: gpr)
                runClassic(arguments: [gpr], returnTo: gpr)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Program to open again when the project comes back from the classic Ghidra.
    private var programToReopen: String?

    /// The program to open as soon as the project that is being opened is ready.
    func programAfterProject(_ path: String) { programToReopen = path }

    /// Opens the current program in the Debugger of the classic Ghidra, and comes back when it is closed.
    func openDebugger() {
        guard confirm(tr("¿Abrir el Depurador de Ghidra clásico?"),
                      tr("Ghidra Studio guardará y cerrará el proyecto, y abrirá el programa actual en el Depurador del Ghidra clásico. Al cerrar el clásico, el proyecto vuelve a abrirse aquí."),
                      action: tr("Abrir el Depurador")) else { return }
        let path = program?.domainPath ?? activeSession ?? ""
        let address = editTarget ?? ""
        Task {
            do {
                let info: ProjectInfo = try await engine.call("releaseProject")
                resetAll()
                project = nil
                guard let gpr = info.gpr else { return }
                phase = .classic(gpr: gpr)
                runClassic(arguments: [gpr, path, address], mainClass: "studio.ClassicDebugger", returnTo: gpr,
                           reopen: path.isEmpty ? nil : path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func launchClassic() { runClassic(arguments: []) }

    /// `returnTo`: project to reopen in Studio when the classic Ghidra quits.
    private func runClassic(arguments: [String], mainClass: String? = nil, returnTo: String? = nil,
                            reopen: String? = nil) {
        let script = Bundle.main.resourceURL!.appendingPathComponent("launcher.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + arguments
        if let mainClass {
            var environment = ProcessInfo.processInfo.environment
            environment["GHIDRA_MAIN_CLASS"] = mainClass
            p.environment = environment
        }
        if let returnTo {
            p.terminationHandler = { _ in
                Task { @MainActor in
                    let model = AppModel.shared
                    if case .classic(let gpr) = model.phase, gpr == returnTo {
                        model.programToReopen = reopen
                        model.openProject(gpr)
                    }
                }
            }
        }
        do { try p.run() } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Opening programs

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = tr("Importar binario")
        panel.message = tr("Elige uno o varios ejecutables, librerías, firmwares o contenedores (zip, dmg, ipa…)")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls.map(Self.resolveBundleExecutable)
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isFolder)
        if urls.count > 1 || isFolder.boolValue {
            // several files or a folder: the batch importer, with its options
            batchRequest = BatchRequest(urls: urls)
        } else {
            beginImport(urls[0])
        }
    }

    /// True when Ghidra can open the file as a file system and no real loader recognizes it as a program.
    private func isContainer(_ url: URL) async -> Bool {
        let specs: [LoadSpecItem] = (try? await engine.call("loadSpecs", ["path": url.path])) ?? []
        guard specs.allSatisfy({ $0.loader.contains("Raw") }) else { return false }
        let listing: FSListing? = try? await engine.call("fsList", ["path": url.path])
        return listing?.container == true && !(listing?.entries.isEmpty ?? true)
    }

    /// Containers open the file-system browser; plain binaries go straight to the import sheet.
    func beginImport(_ url: URL) {
        Task {
            if await isContainer(url) {
                containerRequest = ContainerRequest(url: url)
            } else {
                importRequest = ImportRequest(url: url)
            }
        }
    }

    /// Imports several files with default options, without opening them.
    func batchImport(_ urls: [URL]) {
        Task {
            let previous = phase
            var failed: [String] = []
            for (i, url) in urls.enumerated() {
                phase = .loading(message: tr("Importando %@ (%@ de %@)…", "\(url.lastPathComponent)", "\(i + 1)", "\(urls.count)"), progress: Double(i) / Double(urls.count))
                do {
                    _ = try await engine.call("importFile", ["path": url.path, "folder": "/", "open": false],
                                              as: ImportedInfo.self)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            phase = previous
            await refreshProject()
            sidebarTab = .project
            errorMessage = failed.isEmpty
                ? tr("Se importaron %@ archivos al proyecto. Ábrelos desde la pestaña Proyecto.", "\(urls.count)")
                : tr("No se pudieron importar: %@", "\(failed.joined(separator: ", "))")
        }
    }

    /// Quick open (Finder, drag & drop, recents): import once into the project root, then reopen.
    func open(_ url: URL, reanalyze: Bool = false) {
        let target = Self.resolveBundleExecutable(url)
        Task {
            // Containers (zip, firmware, disk images…) go to the file-system browser instead.
            if !reanalyze, await isContainer(target) {
                containerRequest = ContainerRequest(url: target)
                return
            }
            await openWith(message: tr("Preparando…")) {
                try await self.engine.call("open", ["path": target.path, "reanalyze": reanalyze], as: ProgramInfo.self)
            }
            addRecent(target.path)
        }
    }

    func importFile(_ request: ImportRequest, folder: String, spec: LoadSpecItem?, language: String?,
                    compiler: String?, analyze: Bool, loaderArgs: [String: String] = [:]) {
        var params: [String: Any] = ["path": request.source, "folder": folder, "analyze": analyze]
        if let spec {
            params["loader"] = spec.loader
            if let l = spec.language { params["language"] = l }
            if let c = spec.compiler { params["compiler"] = c }
        }
        if let language { params["language"] = language }
        if let compiler { params["compiler"] = compiler }
        if !loaderArgs.isEmpty { params["loaderArgs"] = loaderArgs }
        Task {
            await openWith(message: tr("Importando %@…", "\(request.name)")) {
                try await self.engine.call("importFile", params, as: ProgramInfo.self)
            }
            if request.isLocalFile { addRecent(request.source) }
        }
    }

    func openProgram(domainPath: String) {
        if tabs.contains(where: { $0.id == domainPath }) {
            activate(domainPath)
            return
        }
        Task {
            await openWith(message: tr("Abriendo…")) {
                try await self.engine.call("openProgram", ["path": domainPath], as: ProgramInfo.self)
            }
        }
    }

    /// Opens a program of a Ghidra Server by its URL, read-only, without the shared project.
    func openServerURL(_ text: String, user: String?, password: String?) {
        Task {
            var params: [String: Any] = ["url": text]
            if let user { params["user"] = user }
            if let password { params["password"] = password }
            // what is on screen stays as it is until the server answers: asking for the password must not lose it
            statusMessage = tr("Abriendo desde el servidor…")
            do {
                let info: ProgramInfo = try await engine.call("openURL", params)
                stashActive()
                await adopt(info)
                if let hash = text.firstIndex(of: "#") {
                    // the part after # is a symbol or an address inside the program
                    let reference = String(text[text.index(after: hash)...]).removingPercentEncoding ?? ""
                    let hits: [GoToHit] = (try? await engine.call("goTo", ["query": reference])) ?? []
                    if let first = hits.first { await navigate(to: first.address) }
                }
            } catch {
                if case EngineError.remote(let message) = error, message.hasPrefix("@auth:") {
                    // the server wants to know who is asking
                    formRequest = FormRequest(
                        title: tr("Entrar en el servidor de Ghidra"),
                        message: String(message.dropFirst("@auth:".count)),
                        fields: [FormField(key: "user", title: tr("Usuario"), value: user ?? NSUserName()),
                                 FormField(key: "password", title: tr("Contraseña"), kind: .secure)],
                        actionTitle: tr("Abrir")) { [self] values in
                            openServerURL(text, user: values["user"] ?? "", password: values["password"] ?? "")
                        }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Opens an older version of a versioned file, read-only, as one more tab.
    func openVersion(path: String, version: Int) {
        let id = "\(path)@\(version)"
        if tabs.contains(where: { $0.id == id }) {
            activate(id)
            return
        }
        Task {
            await openWith(message: tr("Abriendo la versión %@…", "\(version)")) {
                try await self.engine.call("openVersion", ["path": path, "version": version], as: ProgramInfo.self)
            }
        }
    }

    private func openWith(message: String, _ action: @escaping () async throws -> ProgramInfo) async {
        let previousPhase = phase
        stashActive()
        phase = .loading(message: engineReady ? message : tr("Esperando al motor de Ghidra…"), progress: nil)
        do {
            let info = try await action()
            await adopt(info)
        } catch {
            // The file has a recovery snapshot from a session that did not close properly.
            if case EngineError.remote(let message) = error, message.hasPrefix("@recover:") {
                let path = String(message.dropFirst("@recover:".count))
                if let recover = askToRecover((path as NSString).lastPathComponent) {
                    await openWith(message: tr("Abriendo…")) {
                        try await self.engine.call("openProgram", ["path": path, "recover": recover], as: ProgramInfo.self)
                    }
                    return
                }
            } else {
                errorMessage = error.localizedDescription
            }
            if let active = activeSession, let snap = snapshots[active] {
                restore(snap)
                phase = .open
            } else {
                phase = previousPhase == .open ? .welcome : previousPhase
            }
        }
    }

    /// Makes a freshly opened program the active tab.
    private func adopt(_ info: ProgramInfo) async {
        let id = info.session ?? info.domainPath ?? info.name
        if !tabs.contains(where: { $0.id == id }) {
            tabs.append(OpenTab(id: id, name: info.name,
                                analysis: info.analyzing == true ? AnalysisStatus(message: tr("Analizando…"), progress: nil) : nil))
        }
        activeSession = id
        resetProgramState()
        program = info
        undo = UndoState(changed: info.changed ?? false, canUndo: info.canUndo ?? false,
                         canRedo: info.canRedo ?? false, undoName: info.undoName, redoName: info.redoName)
        do {
            phase = .loading(message: tr("Cargando símbolos…"), progress: nil)
            try await loadSymbols()
            phase = .open
            if sidebarTab == .project { sidebarTab = .functions }
            if let entry = info.entry { await navigate(to: entry) }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshProject()
    }

    private func loadSymbols() async throws {
        loadAnalysisConfigs()
        functions = try await engine.call("functions")
        imports = try await engine.call("imports")
        exports = try await engine.call("exports")
        strings = try await engine.call("strings")
        segments = try await engine.call("segments")
        bookmarks = try await engine.call("bookmarks")
        programTree = (try? await engine.call("programTree")) ?? []
        await sendListingFields()
        await refreshColors()
        refreshOverview()
    }

    func activate(_ session: String) {
        guard session != activeSession else { return }
        stashActive()
        Task {
            do {
                let info: ProgramInfo = try await engine.call("activate", ["session": session])
                activeSession = session
                if let snap = snapshots[session] {
                    restore(snap)
                    program = info
                    refreshOverview()
                    await loadContent()
                    await loadInspector()
                } else {
                    resetProgramState()
                    program = info
                    try await loadSymbols()
                    if let entry = info.entry { await navigate(to: entry) }
                }
                await refreshUndo()
                phase = .open
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Whether a tab has unsaved changes (the active one, or one stashed in the background).
    func isDirty(_ session: String) -> Bool {
        session == activeSession ? isDirty : (snapshots[session]?.undo?.changed ?? false)
    }

    var dirtyTabs: [OpenTab] { tabs.filter { isDirty($0.id) } }

    /// Asks Save / Don't Save / Cancel. Returns nil when cancelled, else whether to save.
    func askToSave(_ names: [String]) -> Bool? {
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? tr("¿Guardar los cambios de «%@»?", "\(names[0])")
                                             : tr("¿Guardar los cambios de %@ programas?", "\(names.count)")
        alert.informativeText = tr("Si no guardas, se perderán los cambios hechos desde la última vez que guardaste.")
        alert.addButton(withTitle: tr("Guardar"))
        alert.addButton(withTitle: tr("No guardar"))
        alert.addButton(withTitle: tr("Cancelar"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    /// Recover / Discard / Cancel for a program with unsaved changes left by a crash. nil = cancelled.
    private func askToRecover(_ name: String) -> Bool? {
        let alert = NSAlert()
        alert.messageText = tr("¿Recuperar los cambios sin guardar de «%@»?", name)
        alert.informativeText = tr("La última vez no se cerró correctamente y hay una copia de recuperación con los cambios que no llegaste a guardar.")
        alert.addButton(withTitle: tr("Recuperar"))
        alert.addButton(withTitle: tr("Descartar"))
        alert.addButton(withTitle: tr("Cancelar"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    func closeTab(_ session: String) {
        var save = true
        if isDirty(session) {
            let name = tabs.first { $0.id == session }?.name ?? session
            guard let choice = askToSave([name]) else { return }
            save = choice
        }
        Task {
            do {
                let result: ActiveResult = try await engine.call("closeProgram", ["session": session, "save": save])
                tabs.removeAll { $0.id == session }
                snapshots.removeValue(forKey: session)
                if session == activeSession {
                    activeSession = nil
                    resetProgramState()
                    if let next = result.active ?? tabs.first?.id {
                        activate(next)
                    } else {
                        phase = .welcome
                    }
                }
                await refreshProject()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Called on quit: closes every program honoring the user's save choice. Returns false if cancelled.
    func prepareToQuit() async -> Bool {
        let dirty = dirtyTabs
        var save = true
        if !dirty.isEmpty {
            guard let choice = askToSave(dirty.map(\.name)) else { return false }
            save = choice
        }
        for tab in tabs {
            _ = try? await engine.call("closeProgram", ["session": tab.id, "save": save], as: ActiveResult.self)
        }
        return true
    }

    func closeProgram() {
        if let activeSession { closeTab(activeSession) }
    }

    private func stashActive() {
        guard let id = activeSession, program != nil else { return }
        snapshots[id] = SessionSnapshot(program: program, functions: functions, imports: imports, exports: exports,
                                        strings: strings, segments: segments, bookmarks: bookmarks, current: current,
                                        backStack: backStack, forwardStack: forwardStack,
                                        selectedAddress: selectedAddress, undo: undo)
    }

    private func restore(_ s: SessionSnapshot) {
        resetProgramState()
        program = s.program
        functions = s.functions; imports = s.imports; exports = s.exports
        strings = s.strings; segments = s.segments; bookmarks = s.bookmarks
        current = s.current; backStack = s.backStack; forwardStack = s.forwardStack
        selectedAddress = s.selectedAddress ?? s.current?.address
        scrollRequest = s.current.map { ScrollRequest(address: $0.address) }
        undo = s.undo
    }

    /// Background analysis finished: reload everything that analysis may have changed.
    private func refreshAfterAnalysis() async {
        guard phase == .open else { return }
        do {
            program = try await engine.call("info")
            try await loadSymbols()
            invalidateCaches()
            if current == nil, let entry = program?.entry {
                await navigate(to: entry)
            } else {
                await reloadCurrent()
            }
            await refreshUndo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelAnalysis() {
        Task { _ = try? await engine.call("cancelAnalysis", as: Bool.self) }
    }

    func analyzeNow() {
        Task {
            do {
                _ = try await engine.call("analyze", as: Bool.self)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Opening an .app bundle analyzes its main executable.
    static func resolveBundleExecutable(_ url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           let exe = Bundle(url: url)?.executableURL {
            return exe
        }
        return url
    }

    func reanalyze() {
        guard let path = program?.path, FileManager.default.fileExists(atPath: path) else {
            analyzeNow()
            return
        }
        open(URL(fileURLWithPath: path), reanalyze: true)
    }

    private func resetProgramState() {
        program = nil
        functions = []; imports = []; exports = []; strings = []; segments = []; bookmarks = []
        current = nil; selectedAddress = nil; scrollRequest = nil
        backStack = []; forwardStack = []
        decompilation = nil; listing = nil; hexDump = nil; graph = nil; document = nil
        sliceTokens = []
        fullRows = []; fullAtStart = false; fullAtEnd = false
        contentError = nil; functionDetails = nil; locationXrefs = []
        decompCache = [:]; listingCache = [:]
        sidebarSelection = nil; filter = ""
        undo = nil
        programSelection = nil; overview = nil
        highlight = nil; colorRanges = []; expandedData = [:]
        entropyBar = []
    }

    private func resetAll() {
        resetProgramState()
        tabs = []
        snapshots = [:]
        activeSession = nil
    }

    private func invalidateCaches() {
        decompCache = [:]
        listingCache = [:]
        fullRows = []
    }

    private func addRecent(_ path: String) {
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
    }

    func clearRecents() { recents = [] }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(_ query: String) {
        Task { await navigate(to: query) }
    }

    func navigate(to query: String, recordHistory: Bool = true) async {
        guard program != nil else { return }
        do {
            let resolved: Resolved = try await engine.call("resolve", ["query": query])
            let location = Location(address: resolved.address, function: resolved.function)
            if recordHistory, let current, current != location {
                backStack.append(current)
                forwardStack.removeAll()
            }
            await show(location)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current { forwardStack.append(current) }
        Task { await show(previous) }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current { backStack.append(current) }
        Task { await show(next) }
    }

    private func show(_ location: Location) async {
        if location.function != current?.function { sliceTokens = [] }
        current = location
        selectedAddress = location.address
        scrollRequest = ScrollRequest(address: location.address)
        async let content: Void = loadContent()
        async let inspector: Void = loadInspector()
        _ = await (content, inspector)
    }

    /// Re-resolves the current location (its function may have changed) and reloads views.
    private func reloadCurrent() async {
        guard let current else { return }
        if let resolved: Resolved = try? await engine.call("resolve", ["query": current.address]) {
            self.current = Location(address: resolved.address, function: resolved.function)
        }
        await loadContent()
        await loadInspector()
    }

    func selectLine(_ address: String) {
        selectedAddress = address
        crossSelect(address, lines: viewMode == .decompiler ? decompilation?.lines : nil)
        lineRefsTask?.cancel()
        lineRefsTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            lineRefs = (try? await engine.call("referencesFrom", ["address": address])) ?? []
        }
    }

    // MARK: - Content

    func loadContent() async {
        guard let location = current else { return }
        navToken += 1
        let token = navToken
        isContentLoading = true
        contentError = nil
        defer { if token == navToken { isContentLoading = false } }
        do {
            switch viewMode {
            case .decompiler:
                guard let entry = location.function else {
                    decompilation = nil
                    document = nil
                    contentError = tr("La dirección %@ no pertenece a ninguna función.", "\(location.address)")
                    return
                }
                let result: Decompilation
                if let cached = decompCache[entry] {
                    result = cached
                } else {
                    result = try await engine.call("decompile", ["address": entry])
                    decompCache[entry] = result
                }
                guard token == navToken else { return }
                decompilation = result
            case .listing:
                let key = location.function ?? location.address
                let result: Listing
                if let cached = listingCache[key] {
                    result = cached
                } else {
                    result = try await engine.call("listing", ["address": location.address, "count": 600])
                    listingCache[key] = result
                }
                guard token == navToken else { return }
                listing = result
            case .program:
                if let fn = location.function, foldedFunctions.contains(fn), location.address != fn {
                    // going inside a folded function opens it
                    setFolded(foldedFunctions.subtracting([fn]))
                    fullRows = []
                }
                if fullContains(location.address) {
                    if document?.isFullListing != true {
                        document = DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: false, options: listingOptions, expanded: expandedData)
                    }
                    return
                }
                async let before: ListingSpan = engine.call("listingSpan", [
                    "address": location.address, "direction": "backward", "count": 300, "inclusive": false,
                    "collapsed": Array(foldedFunctions)])
                async let after: ListingSpan = engine.call("listingSpan", [
                    "address": location.address, "direction": "forward", "count": Self.fullChunk,
                    "collapsed": Array(foldedFunctions)])
                let (b, a) = try await (before, after)
                guard token == navToken else { return }
                fullRows = b.rows + a.rows
                fullAtStart = b.atEdge
                fullAtEnd = a.atEdge
                document = DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: false, options: listingOptions, expanded: expandedData)
                return
            case .graph:
                guard let entry = location.function else {
                    graph = nil
                    contentError = tr("La dirección %@ no pertenece a ninguna función.", "\(location.address)")
                    return
                }
                if graph?.entry != entry {
                    let result: FunctionGraphData = try await engine.call("functionGraph", ["address": entry])
                    guard token == navToken else { return }
                    graph = result
                }
                return
            case .hex:
                let result: HexDump = try await engine.call("hex", ["address": location.address, "length": 4096])
                guard token == navToken else { return }
                hexDump = result
            }
            rebuildDocument()
        } catch {
            guard token == navToken else { return }
            document = nil
            contentError = error.localizedDescription
        }
    }

    func rebuildDocument() {
        switch viewMode {
        case .decompiler: document = decompilation.map { DocumentBuilder.decompiler($0, fontSize: fontSize) }
        case .listing: document = listing.map { DocumentBuilder.listing($0, fontSize: fontSize, options: listingOptions, expanded: expandedData) }
        case .program:
            document = fullRows.isEmpty ? nil
                : DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: true, options: listingOptions, expanded: expandedData)
        case .hex: document = hexDump.map { DocumentBuilder.hex($0, fontSize: fontSize) }
        case .graph: break
        }
    }

    private func fullContains(_ address: String) -> Bool {
        guard let first = fullRows.first.flatMap({ addressValue($0.address) }),
              let last = fullRows.last.flatMap({ addressValue($0.address) }),
              let v = addressValue(address) else { return false }
        return v >= first && v <= last
    }

    /// Infinite scrolling for the whole-program listing.
    func loadMoreFull(atTop: Bool) {
        guard viewMode == .program, !fullLoading, !fullRows.isEmpty else { return }
        if atTop ? fullAtStart : fullAtEnd { return }
        fullLoading = true
        let anchor = atTop ? fullRows.first!.address : fullRows.last!.address
        Task {
            defer { fullLoading = false }
            do {
                let span: ListingSpan = try await engine.call("listingSpan", [
                    "address": anchor, "direction": atTop ? "backward" : "forward",
                    "count": Self.fullChunk, "inclusive": false, "collapsed": Array(foldedFunctions)])
                guard viewMode == .program else { return }
                if atTop {
                    fullRows = span.rows + fullRows
                    fullAtStart = span.atEdge
                    if fullRows.count > Self.fullMaxRows {
                        fullRows.removeLast(fullRows.count - Self.fullMaxRows)
                        fullAtEnd = false
                    }
                } else {
                    fullRows += span.rows
                    fullAtEnd = span.atEdge
                    if fullRows.count > Self.fullMaxRows {
                        fullRows.removeFirst(fullRows.count - Self.fullMaxRows)
                        fullAtStart = false
                    }
                }
                document = DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: true, options: listingOptions, expanded: expandedData)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func hexPage(_ delta: Int64) {
        guard let dump = hexDump, let base = addressValue(dump.start) else { return }
        let next = delta < 0 ? base &- UInt64(-delta) : base &+ UInt64(delta)
        let width = dump.start.count
        let text = String(next, radix: 16)
        let padded = String(repeating: "0", count: max(0, width - text.count)) + text
        Task { await navigate(to: padded) }
    }

    private func loadInspector() async {
        guard let location = current else { return }
        do {
            if location.function != nil {
                let details: FunctionDetails? = try await engine.call("functionInfo", ["address": location.address])
                functionDetails = details
                locationXrefs = []
            } else {
                functionDetails = nil
                locationXrefs = try await engine.call("xrefs", ["address": location.address])
            }
        } catch {
            functionDetails = nil
            locationXrefs = []
        }
    }

    // MARK: - Undo / save

    func refreshUndo() async {
        undo = try? await engine.call("undoState")
    }

    func performUndo() { undoRedo("undo") }
    func performRedo() { undoRedo("redo") }

    private func undoRedo(_ method: String) {
        Task {
            do {
                undo = try await engine.call(method)
                await afterEdit(namesChanged: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func save() {
        guard program != nil else { return }
        Task {
            do {
                undo = try await engine.call("save")
                refreshOverview()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshAfterEdits() async {
        await afterEdit(namesChanged: true)
    }

    /// Memory-map edits: reload segments as well.
    func memoryAction(_ method: String, _ params: [String: Any]) {
        Task {
            do {
                _ = try await engine.call(method, params, as: Bool.self)
                segments = try await engine.call("segments")
                await afterEdit(namesChanged: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteReference(from: String, to: String) {
        Task {
            do {
                _ = try await engine.call("deleteReference", ["address": from, "to": to], as: Bool.self)
                lineRefs = (try? await engine.call("referencesFrom", ["address": from])) ?? []
                await afterEdit(namesChanged: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func autoStructure(_ variable: String) {
        guard let fn = current?.function else { return }
        Task {
            do {
                let r: PathResult = try await engine.call("autoStructure", ["address": fn, "name": variable])
                await afterEdit(namesChanged: true)
                errorMessage = tr("Estructura creada: %@. Puedes editarla en Herramientas ▸ Tipos de datos.", "\(r.path)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyArchive(_ path: String) {
        Task {
            do {
                let r: AppliedResult = try await engine.call("applyArchive", ["path": path])
                await afterEdit(namesChanged: true)
                errorMessage = tr("Firmas aplicadas a %@ funciones.", "\(r.applied)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestEquate(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .equate, address: target, title: tr("Nombre para una constante (equate)"),
                                  prompt: tr("Nombre, p. ej. BUFFER_SIZE (se aplica a la primera constante de la instrucción)"))
    }

    func requestAddReference(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .addReference, address: target, title: tr("Añadir referencia"),
                                  prompt: tr("Dirección o símbolo de destino"))
    }

    func afterEdit(namesChanged: Bool) async {
        editCount += 1
        expandedData = [:]
        invalidateCaches()
        sliceTokens = []
        graph = nil
        if namesChanged {
            functions = (try? await engine.call("functions")) ?? functions
        }
        bookmarks = (try? await engine.call("bookmarks")) ?? bookmarks
        await refreshColors()
        await reloadCurrent()
        await refreshUndo()
        refreshOverview()
        debugger.breakpointsChanged()
    }

    // MARK: - Edits

    var editTarget: String? { selectedAddress ?? current?.address }

    func requestRename(address: String? = nil, currentName: String? = nil) {
        if let address {
            editRequest = EditRequest(kind: .rename, address: address, title: tr("Renombrar"),
                                      prompt: tr("Nuevo nombre"), initialText: currentName ?? "")
        } else if let details = functionDetails {
            editRequest = EditRequest(kind: .rename, address: details.entry, title: tr("Renombrar función"),
                                      prompt: tr("Nuevo nombre"), initialText: details.name)
        }
    }

    func requestComment(address: String? = nil, kind: String = "eol") {
        guard let target = address ?? editTarget else { return }
        let row = listing?.rows.first { $0.address == target } ?? fullRows.first { $0.address == target }
        let existing: String? = switch kind {
        case "pre": row?.pre
        case "plate": row?.plate
        case "post": row?.post
        case "repeatable": row?.repeatable
        default: row?.eol
        }
        editRequest = EditRequest(kind: .comment, address: target, title: tr("Comentario"), prompt: tr("Texto"),
                                  initialText: existing ?? "", commentKind: kind, monospaced: false, multiline: true)
    }

    func requestFunctionComment() {
        guard let d = functionDetails else { return }
        editRequest = EditRequest(kind: .functionComment, address: d.entry, title: tr("Comentario de función"),
                                  prompt: tr("Texto"), initialText: d.comment ?? "", monospaced: false, multiline: true)
    }

    func requestSignature(address: String? = nil) {
        let target = address ?? functionDetails?.entry
        guard let target else { return }
        let initial = target == functionDetails?.entry ? (functionDetails?.signature ?? "") : ""
        editRequest = EditRequest(kind: .signature, address: target, title: tr("Editar firma"),
                                  prompt: tr("Prototipo en C, p. ej. int main(int argc, char **argv)"), initialText: initial)
    }

    func requestRenameVariable(_ name: String) {
        guard let fn = current?.function else { return }
        editRequest = EditRequest(kind: .renameVariable(function: fn, name: name), address: fn, title: tr("Renombrar variable"),
                                  prompt: tr("Nuevo nombre para «%@»", "\(name)"), initialText: name)
    }

    /// "Split Out As New Variable": gives the instance under the cursor its own variable.
    func requestSplitVariable(token: Int, name: String?) {
        guard let fn = current?.function else { return }
        editRequest = EditRequest(kind: .splitVariable(token: token), address: fn, title: tr("Dividir como variable nueva"),
                                  prompt: tr("Nombre de la variable nueva"), initialText: (name ?? "var") + "_2")
    }

    // MARK: Direct edits added with the program tools

    func requestImageBase() {
        guard let base = program?.imageBase else { return }
        editRequest = EditRequest(kind: .imageBase, address: base, title: tr("Cambiar dirección base"),
                                  prompt: tr("Nueva dirección base de la imagen"), initialText: base)
    }

    func requestExpandBlock(name: String, start: String) {
        editRequest = EditRequest(kind: .expandBlock(name: name), address: start, title: tr("Expandir bloque «%@»", name),
                                  prompt: tr("Dirección hasta la que debe llegar (antes del inicio o después del final)"),
                                  initialText: start)
    }

    func requestPatchText(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .patchText, address: target, title: tr("Escribir texto"),
                                  prompt: tr("Texto que se escribirá como bytes (\\0 para un cero final)"),
                                  monospaced: true)
    }

    func requestPatchInt(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .patchInt, address: target, title: tr("Escribir entero"),
                                  prompt: tr("Valor y tamaño en bytes, p. ej.: 1234 4   ó   0xdeadbeef 4"),
                                  initialText: "0 4")
    }

    func requestFunctionDefinition() {
        editRequest = EditRequest(kind: .functionDefinition, address: "", title: tr("Definición de función"),
                                  prompt: tr("Prototipo en C, p. ej.: int callback(void *ctx, int code)"),
                                  initialText: "int callback(void *ctx, int code)")
    }

    func requestPdbDownload() {
        editRequest = EditRequest(kind: .pdbServer, address: "", title: tr("Descargar PDB de un servidor de símbolos"),
                                  prompt: tr("URL del servidor de símbolos"),
                                  initialText: "https://msdl.microsoft.com/download/symbols/", monospaced: false)
    }

    func requestDisassembleOptions(start: String? = nil, end: String? = nil) {
        guard let address = start ?? editTarget else { return }
        disassembleRequest = DisassembleRequest(start: address, end: end)
    }

    /// Decompiler "commit": writes the parameters / return type, or the local names, it has inferred to the program.
    func commitDecompiler(_ method: String) {
        guard let entry = functionDetails?.entry else { return }
        perform(method, address: entry)
    }

    /// Menu-bar version of "force field": acts on the union field under the caret.
    func forceUnionAtCursor() {
        guard viewMode == .decompiler, let fn = current?.function,
              let ctx = CodeNSTextView.current?.contextProvider?(), ctx.isUnionField, let token = ctx.tokenID else {
            errorMessage = tr("Coloca el cursor en el descompilador sobre un campo de una unión.")
            return
        }
        unionRequest = UnionRequest(function: fn, token: token)
    }

    /// Bytes of a typed integer, in the program's byte order.
    private func integerBytes(_ text: String) -> String? {
        let parts = text.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        let size = parts.count > 1 ? Int(parts[1]) ?? 4 : 4
        guard (1...8).contains(size) else { return nil }
        let lower = first.lowercased()
        let value: UInt64?
        if lower.hasPrefix("0x") {
            value = UInt64(lower.dropFirst(2), radix: 16)
        } else if lower.hasPrefix("-") {
            value = Int64(lower).map { UInt64(bitPattern: $0) }
        } else {
            value = UInt64(lower)
        }
        guard let value else { return nil }
        var bytes = (0..<size).map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
        if program?.endian == "Big" { bytes.reverse() }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Menu-bar version of "split out as new variable": acts on the variable under the caret.
    func splitVariableAtCursor() {
        guard viewMode == .decompiler, let ctx = CodeNSTextView.current?.contextProvider?(), ctx.canSplit,
              let token = ctx.tokenID else {
            errorMessage = tr("Coloca el cursor en el descompilador sobre una variable que el descompilador haya reutilizado para varias cosas.")
            return
        }
        requestSplitVariable(token: token, name: ctx.variable)
    }

    func requestRetypeVariable(_ name: String) {
        guard let fn = current?.function else { return }
        editRequest = EditRequest(kind: .retypeVariable(function: fn, name: name), address: fn, title: tr("Cambiar tipo"),
                                  prompt: tr("Nuevo tipo para «%@» (p. ej. char *, uint32_t, MiStruct *)", "\(name)"))
    }

    func requestLabel(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .label, address: target, title: tr("Añadir etiqueta"), prompt: tr("Nombre"))
    }

    func requestBookmark(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .bookmark, address: target, title: tr("Añadir marcador"),
                                  prompt: tr("Nota"), monospaced: false)
    }

    func requestCreateData(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .createData, address: target, title: tr("Definir dato"),
                                  prompt: tr("Tipo (p. ej. dword, char[16], pointer, MiStruct)"))
    }

    func requestCreateFunction(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .createFunction, address: target, title: tr("Crear función"),
                                  prompt: tr("Nombre (opcional)"))
    }

    func requestPatch(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        let row = listing?.rows.first { $0.address == target } ?? fullRows.first { $0.address == target }
        editRequest = EditRequest(kind: .patch, address: target, title: tr("Parchear bytes"),
                                  prompt: tr("Bytes en hexadecimal (p. ej. 1f 20 03 d5)"),
                                  initialText: row?.bytes.replacingOccurrences(of: "…", with: "") ?? "")
    }

    func requestAssemble(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        let row = listing?.rows.first { $0.address == target } ?? fullRows.first { $0.address == target }
        let text = row.map { r in ([r.mnemonic] + [r.operands.map(\.text).joined(separator: ", ")]).joined(separator: " ") }
        editRequest = EditRequest(kind: .assemble, address: target, title: tr("Ensamblar instrucción"),
                                  prompt: tr("Instrucción (p. ej. mov x0, #0x1)"), initialText: text ?? "")
    }

    func requestNewFolder(parent: String) {
        editRequest = EditRequest(kind: .newFolder(parent: parent), address: parent, title: tr("Nueva carpeta"),
                                  prompt: tr("Nombre"), monospaced: false)
    }

    func requestRenameItem(path: String, name: String, folder: Bool) {
        editRequest = EditRequest(kind: .renameItem(path: path, folder: folder), address: path,
                                  title: folder ? tr("Renombrar carpeta") : tr("Renombrar programa"),
                                  prompt: tr("Nuevo nombre"), initialText: name, monospaced: false)
    }

    // MARK: - Decompiler extras

    func slice(_ token: Int, forward: Bool) {
        guard let fn = current?.function else { return }
        Task {
            do {
                let ids: [Int] = try await engine.call("slice", ["address": fn, "token": token, "forward": forward])
                sliceTokens = Set(ids)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestRenameField(_ field: String, currentName: String?) {
        let parts = field.split(separator: "|")
        guard parts.count == 2, let offset = Int(parts[1]) else { return }
        editRequest = EditRequest(kind: .renameField(type: String(parts[0]), offset: offset), address: String(parts[0]),
                                  title: tr("Renombrar campo"), prompt: tr("Nuevo nombre del campo (offset %@)", "\(offset)"),
                                  initialText: currentName ?? "")
    }

    func requestOverrideSignature(callSite: String, name: String?) {
        guard let fn = current?.function else { return }
        editRequest = EditRequest(kind: .overrideSignature(callSite: callSite), address: fn,
                                  title: tr("Forzar firma en esta llamada"),
                                  prompt: tr("Prototipo solo para la llamada en %@, p. ej. int %@(char *s, int n)", "\(callSite)", "\(name ?? "f")"),
                                  initialText: "")
    }

    func requestRetypeGlobal(address: String, name: String?) {
        editRequest = EditRequest(kind: .retypeGlobal, address: address, title: tr("Cambiar tipo del global"),
                                  prompt: tr("Tipo para «%@» (p. ej. int, char[32], MiStruct)", "\(name ?? address)"))
    }

    /// Opens the current location in an extra, independent window.
    func openSnapshot(mode: String? = nil) {
        guard let session = activeSession, let address = editTarget else { return }
        snapshotRequest = SnapshotSpec(session: session, address: address,
                                       mode: mode ?? (viewMode == .decompiler ? "decompiler" : "listing"))
    }

    // MARK: - Breakpoints

    /// Breakpoints are bookmarks of the program, the same ones the classic Ghidra uses.
    var breakpoints: [BookmarkItem] { bookmarks.filter(\.isBreakpoint) }

    /// Address → enabled.
    var breakpointMap: [String: Bool] {
        Dictionary(breakpoints.map { ($0.address, $0.type == BookmarkItem.breakpointEnabled) }, uniquingKeysWith: { a, _ in a })
    }

    /// Program counter of the debugger, as an address of the active program.
    var debugPC: String? { debugger.mappedSession == activeSession ? debugger.staticPC : nil }

    /// state: "enabled", "disabled" or "none".
    func setBreakpoint(address: String, state: String) {
        Task {
            do {
                _ = try await engine.call("setBreakpoint", ["address": address, "state": state], as: Bool.self)
                bookmarks = (try? await engine.call("bookmarks")) ?? bookmarks
                await refreshUndo()
                debugger.breakpointsChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Sets a breakpoint where there is none, removes it where there is one.
    func toggleBreakpoint(address: String? = nil) {
        guard let address = address ?? editTarget else { return }
        setBreakpoint(address: address, state: breakpointMap[address] == nil ? "enabled" : "none")
    }

    func clearBreakpoints() {
        guard !breakpoints.isEmpty else { return }
        Task {
            _ = try? await engine.call("clearBreakpoints", as: Int.self)
            bookmarks = (try? await engine.call("bookmarks")) ?? bookmarks
            await refreshUndo()
            debugger.breakpointsChanged()
        }
    }

    // MARK: - Overview bar

    /// Reloads what the overview bar shows (after opening, editing or saving).
    func refreshOverview() {
        overviewTask?.cancel()
        guard program != nil, listingOptions.showOverview else { return }
        let session = activeSession
        overviewTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result: ProgramOverview? = try? await engine.call("overview", ["buckets": 800])
            guard !Task.isCancelled, session == activeSession else { return }
            overview = result
            if listingOptions.showEntropyBar {
                let entropy: EntropyOverview? = try? await engine.call("entropyOverview", ["buckets": 800])
                guard !Task.isCancelled, session == activeSession else { return }
                entropyBar = entropy?.values ?? []
            }
        }
    }

    // MARK: - Program selection

    /// Ghidra's Select menu: builds a selection from the cursor, the selected lines or the selection so far.
    func select(_ kind: String) {
        guard program != nil else { return }
        var ranges = programSelection?.ranges ?? []
        var address = editTarget
        if ranges.isEmpty, let ctx = CodeNSTextView.current?.contextProvider?() {
            // the caret stays where it was after a jump, so it only counts when lines are selected
            if let start = ctx.selectionStart, let end = ctx.selectionEnd, start != end {
                ranges = [[start, end]]
                address = start
            }
        }
        guard let address else { return }
        Task {
            do {
                let result: SelectionResult = try await engine.call("select", ["kind": kind, "address": address, "ranges": ranges])
                if result.ranges.isEmpty {
                    programSelection = nil
                    errorMessage = tr("La selección está vacía.")
                } else {
                    programSelection = ProgramSelection(result)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Selects the lines chosen with the mouse as a program selection.
    func selectLines(start: String, end: String) {
        programSelection = ProgramSelection(SelectionResult(ranges: [[start, end]], rangeCount: 1,
                                                            addresses: Int64((addressValue(end) ?? 0) &- (addressValue(start) ?? 0)) + 1,
                                                            truncated: false, first: start))
    }

    func clearProgramSelection() { programSelection = nil }

    /// Jumps to the next / previous range of the selection.
    func goToSelectionRange(next: Bool) {
        guard let selection = programSelection, !selection.bounds.isEmpty else { return }
        let here = editTarget.flatMap(addressValue) ?? 0
        let ordered = selection.ranges.filter { $0.count == 2 }.sorted { (addressValue($0[0]) ?? 0) < (addressValue($1[0]) ?? 0) }
        let target = next
            ? ordered.first { (addressValue($0[0]) ?? 0) > here } ?? ordered.first
            : ordered.last { (addressValue($0[1]) ?? 0) < here } ?? ordered.last
        if let target { go(target[0]) }
    }

    /// Clears, disassembles or bookmarks everything in the selection, as one undoable step.
    func selectionAction(_ action: String) {
        guard let selection = programSelection else { return }
        if action == "clear", !confirm(tr("¿Borrar el código y los datos de la selección?"),
                                       tr("Se borrarán %@ direcciones en %@ rangos. Puedes deshacerlo.",
                                          "\(selection.addresses)", "\(selection.rangeCount)"),
                                       action: tr("Borrar")) { return }
        Task {
            do {
                _ = try await engine.call("selectionAction", ["action": action, "ranges": selection.ranges], as: Bool.self)
                await afterEdit(namesChanged: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Ranges

    func rangeAction(_ method: String, start: String, end: String) {
        Task {
            do {
                _ = try await engine.call(method, ["address": start, "end": end], as: AnyCodableIgnored.self)
                await afterEdit(namesChanged: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestArray(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        editRequest = EditRequest(kind: .createArray, address: target, title: tr("Crear array"),
                                  prompt: tr("Tipo y número de elementos, p. ej. dword 16 o char 64"), initialText: "byte 16")
    }

    func requestStructFromRange(start: String, end: String) {
        editRequest = EditRequest(kind: .structFromRange(end: end), address: start,
                                  title: tr("Crear estructura desde la selección"),
                                  prompt: tr("Nombre de la estructura (%@ – %@)", "\(start)", "\(end)"), initialText: "")
    }

    func requestSetRegister(start: String, end: String?) {
        editRequest = EditRequest(kind: .setRegister(end: end ?? start), address: start,
                                  title: tr("Fijar valor de registro"),
                                  prompt: tr("registro=valor, p. ej. TMode=1 (vacío tras = para borrar)"), initialText: "")
    }

    func setDataFormat(_ format: String, address: String) {
        Task {
            do {
                _ = try await engine.call("setDataFormat", ["address": address, "format": format], as: Bool.self)
                await afterEdit(namesChanged: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func defineString(address: String, end: String?) {
        var params: [String: Any] = ["address": address]
        if let end, let a = addressValue(address), let b = addressValue(end), b > a { params["length"] = Int(b - a + 1) }
        Task {
            do {
                _ = try await engine.call("defineString", params, as: Bool.self)
                await afterEdit(namesChanged: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Project extras

    func presentLoadPDB() {
        let panel = NSOpenPanel()
        panel.title = tr("Cargar símbolos PDB")
        if let pdb = UTType(filenameExtension: "pdb") { panel.allowedContentTypes = [pdb] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { _ = try await engine.call("loadPdb", ["path": url.path], as: Bool.self) } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func runAnalyzer(_ name: String) {
        Task {
            do { _ = try await engine.call("runAnalyzer", ["name": name], as: Bool.self) } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Zips the project (.gpr + .rep) so it can be backed up or moved to another machine.
    func archiveProject() {
        guard let project, let dir = project.directory, let name = project.name else { return }
        let panel = NSSavePanel()
        panel.title = tr("Archivar proyecto")
        panel.nameFieldStringValue = "\(name).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dirty = dirtyTabs.map(\.id)
        Task {
            for id in dirty { _ = try? await engine.call("save", ["session": id], as: UndoState.self) }
            await refreshUndo()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            p.arguments = ["-r", "-q", url.path, "\(name).gpr", "\(name).rep", "-x", "*.lock", "*.lock~"]
            try? FileManager.default.removeItem(at: url)
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    errorMessage = tr("No se pudo archivar el proyecto (zip devolvió %@).", "\(p.terminationStatus)")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func printCurrentView() {
        guard let view = CodeNSTextView.current else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        NSPrintOperation(view: view, printInfo: info).run()
    }

    func commit(_ request: EditRequest, text: String, commentKind: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                var namesChanged = false
                switch request.kind {
                case .rename:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("rename", ["address": request.address, "name": value], as: Bool.self)
                    namesChanged = true
                case .comment:
                    _ = try await engine.call("comment", ["address": request.address, "kind": commentKind,
                                                          "text": text], as: Bool.self)
                case .functionComment:
                    _ = try await engine.call("functionComment", ["address": request.address, "text": text], as: Bool.self)
                case .label:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("createLabel", ["address": request.address, "name": value], as: Bool.self)
                    namesChanged = true
                case .bookmark:
                    _ = try await engine.call("addBookmark", ["address": request.address, "category": "Studio",
                                                              "comment": value], as: Bool.self)
                case .renameVariable(let fn, let name):
                    guard !value.isEmpty, value != name else { return }
                    _ = try await engine.call("renameVariable", ["address": fn, "name": name, "newName": value],
                                              as: Bool.self)
                case .splitVariable(let token):
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("splitVariable", ["address": request.address, "token": token, "name": value],
                                              as: UndoState.self)
                case .retypeVariable(let fn, let name):
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("retypeVariable", ["address": fn, "name": name, "type": value],
                                              as: Bool.self)
                    noteType(value)
                case .signature:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("setSignature", ["address": request.address, "signature": value],
                                              as: Bool.self)
                    namesChanged = true
                case .createData:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("createData", ["address": request.address, "type": value], as: Bool.self)
                    noteType(value)
                case .createFunction:
                    _ = try await engine.call("createFunction", ["address": request.address, "name": value],
                                              as: Bool.self)
                    namesChanged = true
                case .patch:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("patchBytes", ["address": request.address, "bytes": value], as: Bool.self)
                case .assemble:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("assemble", ["address": request.address, "instruction": value],
                                              as: AssembleResult.self)
                case .renameField(let type, let offset):
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("renameField", ["type": type, "offset": offset, "name": value],
                                              as: Bool.self)
                case .overrideSignature(let callSite):
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("overrideSignature", ["address": request.address, "callSite": callSite,
                                                                    "signature": value], as: Bool.self)
                case .retypeGlobal:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("createData", ["address": request.address, "type": value], as: Bool.self)
                    noteType(value)
                case .createArray:
                    let parts = value.split(separator: " ")
                    guard parts.count >= 2, let count = Int(parts.last!) else {
                        errorMessage = tr("Escribe el tipo y el número de elementos, por ejemplo: dword 16")
                        return
                    }
                    _ = try await engine.call("createArray", ["address": request.address,
                                                              "type": parts.dropLast().joined(separator: " "),
                                                              "count": count], as: Bool.self)
                case .structFromRange(let end):
                    _ = try await engine.call("structFromRange", ["address": request.address, "end": end, "name": value],
                                              as: AnyCodableIgnored.self)
                case .setRegister(let end):
                    let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, !parts[0].isEmpty else {
                        errorMessage = tr("Usa el formato registro=valor, por ejemplo TMode=1")
                        return
                    }
                    _ = try await engine.call("setRegister", ["address": request.address, "end": end,
                                                              "register": String(parts[0]).trimmingCharacters(in: .whitespaces),
                                                              "value": String(parts[1])], as: Bool.self)
                case .imageBase:
                    guard !value.isEmpty else { return }
                    program = try await engine.call("setImageBase", ["address": value])
                    segments = try await engine.call("segments")
                    current = nil
                    await afterEdit(namesChanged: true)
                    if let entry = program?.entry { await navigate(to: entry) }
                    return
                case .expandBlock(let name):
                    guard !value.isEmpty else { return }
                    memoryAction("expandBlock", ["name": name, "address": value])
                    return
                case .patchText:
                    guard !value.isEmpty else { return }
                    let text = value.replacingOccurrences(of: "\\0", with: "\0").replacingOccurrences(of: "\\n", with: "\n")
                    let hex = Array(text.utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
                    _ = try await engine.call("patchBytes", ["address": request.address, "bytes": hex], as: Bool.self)
                case .patchInt:
                    guard let hex = integerBytes(value) else {
                        errorMessage = tr("Escribe el valor y el tamaño en bytes (1 a 8), por ejemplo: 1234 4")
                        return
                    }
                    _ = try await engine.call("patchBytes", ["address": request.address, "bytes": hex], as: Bool.self)
                case .functionDefinition:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("functionDefinition", ["signature": value], as: CreatedType.self)
                case .pdbServer:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("pdbDownload", ["server": value], as: PdbDownload.self)
                case .splitBlock(let name):
                    guard !value.isEmpty else { return }
                    memoryAction("splitBlock", ["name": name, "address": value])
                    return
                case .moveBlock(let name):
                    guard !value.isEmpty else { return }
                    memoryAction("moveBlock", ["name": name, "address": value])
                    return
                case .renameBlock(let name):
                    guard !value.isEmpty, value != name else { return }
                    memoryAction("renameBlock", ["name": name, "newName": value])
                    return
                case .equate:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("setEquate", ["address": request.address, "name": value],
                                              as: AnyCodableIgnored.self)
                case .addReference:
                    guard !value.isEmpty else { return }
                    let target: Resolved = try await engine.call("resolve", ["query": value])
                    _ = try await engine.call("addReference", ["address": request.address, "to": target.address,
                                                               "type": "data"], as: Bool.self)
                    lineRefs = (try? await engine.call("referencesFrom", ["address": request.address])) ?? []
                case .newFolder(let parent):
                    guard !value.isEmpty else { return }
                    project = try await engine.call("createFolder", ["parent": parent, "name": value])
                    return
                case .renameItem(let path, let folder):
                    guard !value.isEmpty else { return }
                    project = try await engine.call("renameItem", ["path": path, "name": value, "folder": folder])
                    return
                }
                await afterEdit(namesChanged: namesChanged)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Single-action edits (no input needed).
    func perform(_ method: String, address: String, namesChanged: Bool = true) {
        Task {
            do {
                _ = try await engine.call(method, ["address": address], as: Bool.self)
                await afterEdit(namesChanged: namesChanged)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Ghidra-style single-key shortcuts inside the code views.
    func handleKey(_ key: String, context: CodeContext) {
        let address = context.lineAddress ?? editTarget
        switch key.lowercased() {
        case "l":
            if let field = context.field { requestRenameField(field, currentName: context.word) }
            else if let v = context.variable { requestRenameVariable(v) }
            else if let t = context.target { requestRename(address: t, currentName: context.targetText) }
            else { requestRename() }
        case ";": requestComment(address: address)
        case "d":
            if let start = context.selectionStart, let end = context.selectionEnd, start != end {
                rangeAction("disassembleRange", start: start, end: end)
            } else if let address { perform("disassemble", address: address, namesChanged: false) }
        case "f": requestCreateFunction(address: address)
        case "c":
            guard viewMode.isListingLike else { break }
            if let start = context.selectionStart, let end = context.selectionEnd, start != end {
                rangeAction("clearRange", start: start, end: end)
            } else if let address { perform("clear", address: address, namesChanged: false) }
        case "t":
            if let v = context.variable { requestRetypeVariable(v) } else { requestCreateData(address: address) }
        case "y": applyLastType(address: address)
        case "b": requestBookmark(address: address)
        case "k": toggleBreakpoint(address: address)
        case "g": showQuickOpen = true
        default: break
        }
    }

    func search(_ query: String) async -> [SearchHit] {
        (try? await engine.call("search", ["query": query])) ?? []
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: tr("Cancelar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Derived

    var currentTitle: String {
        if let d = decompilation, viewMode == .decompiler, d.entry == current?.function { return d.function }
        if let details = functionDetails { return details.name }
        return current.map { tr("Dirección %@", "\($0.address)") } ?? ""
    }

    var currentSignature: String? {
        functionDetails?.signature
    }
}
