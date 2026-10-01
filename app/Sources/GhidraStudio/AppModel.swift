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
    private var fullAtStart = false
    private var fullAtEnd = false
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
        case "terminated":
            engineReady = false
            engineStatus = tr("El motor se ha detenido")
            if phase != .welcome {
                errorMessage = EngineError.terminated.localizedDescription
            }
            resetAll()
            phase = .welcome
        default:
            break
        }
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
        } catch {
            errorMessage = error.localizedDescription
        }
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
                runClassic(arguments: [gpr])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func launchClassic() { runClassic(arguments: []) }

    private func runClassic(arguments: [String]) {
        let script = Bundle.main.resourceURL!.appendingPathComponent("launcher.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + arguments
        do { try p.run() } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Opening programs

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = tr("Importar binario")
        panel.message = tr("Elige un ejecutable, librería o firmware para analizar")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            importRequest = ImportRequest(url: Self.resolveBundleExecutable(url))
        }
    }

    /// Quick open (Finder, drag & drop, recents): import once into the project root, then reopen.
    func open(_ url: URL, reanalyze: Bool = false) {
        let target = Self.resolveBundleExecutable(url)
        Task {
            await openWith(message: tr("Preparando…")) {
                try await self.engine.call("open", ["path": target.path, "reanalyze": reanalyze], as: ProgramInfo.self)
            }
            addRecent(target.path)
        }
    }

    func importFile(_ url: URL, folder: String, spec: LoadSpecItem?, language: String?, compiler: String?,
                    analyze: Bool) {
        var params: [String: Any] = ["path": url.path, "folder": folder, "analyze": analyze]
        if let spec {
            params["loader"] = spec.loader
            if let l = spec.language { params["language"] = l }
            if let c = spec.compiler { params["compiler"] = c }
        }
        if let language { params["language"] = language }
        if let compiler { params["compiler"] = compiler }
        Task {
            await openWith(message: tr("Importando %@…", "\(url.lastPathComponent)")) {
                try await self.engine.call("importFile", params, as: ProgramInfo.self)
            }
            addRecent(url.path)
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

    private func openWith(message: String, _ action: @escaping () async throws -> ProgramInfo) async {
        let previousPhase = phase
        stashActive()
        phase = .loading(message: engineReady ? message : tr("Esperando al motor de Ghidra…"), progress: nil)
        do {
            let info = try await action()
            await adopt(info)
        } catch {
            errorMessage = error.localizedDescription
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
        functions = try await engine.call("functions")
        imports = try await engine.call("imports")
        exports = try await engine.call("exports")
        strings = try await engine.call("strings")
        segments = try await engine.call("segments")
        bookmarks = try await engine.call("bookmarks")
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

    func closeTab(_ session: String) {
        Task {
            do {
                let result: ActiveResult = try await engine.call("closeProgram", ["session": session])
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
        fullRows = []; fullAtStart = false; fullAtEnd = false
        contentError = nil; functionDetails = nil; locationXrefs = []
        decompCache = [:]; listingCache = [:]
        sidebarSelection = nil; filter = ""
        undo = nil
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
                if fullContains(location.address) {
                    if document?.isFullListing != true {
                        document = DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: false)
                    }
                    return
                }
                async let before: ListingSpan = engine.call("listingSpan", [
                    "address": location.address, "direction": "backward", "count": 300, "inclusive": false])
                async let after: ListingSpan = engine.call("listingSpan", [
                    "address": location.address, "direction": "forward", "count": Self.fullChunk])
                let (b, a) = try await (before, after)
                guard token == navToken else { return }
                fullRows = b.rows + a.rows
                fullAtStart = b.atEdge
                fullAtEnd = a.atEdge
                document = DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: false)
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
        case .listing: document = listing.map { DocumentBuilder.listing($0, fontSize: fontSize) }
        case .program:
            document = fullRows.isEmpty ? nil
                : DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: true)
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
                    "count": Self.fullChunk, "inclusive": false])
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
                document = DocumentBuilder.fullListing(fullRows, fontSize: fontSize, preservesScroll: true)
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

    private func afterEdit(namesChanged: Bool) async {
        invalidateCaches()
        graph = nil
        if namesChanged {
            functions = (try? await engine.call("functions")) ?? functions
        }
        bookmarks = (try? await engine.call("bookmarks")) ?? bookmarks
        await reloadCurrent()
        await refreshUndo()
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
                case .retypeVariable(let fn, let name):
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("retypeVariable", ["address": fn, "name": name, "type": value],
                                              as: Bool.self)
                case .signature:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("setSignature", ["address": request.address, "signature": value],
                                              as: Bool.self)
                    namesChanged = true
                case .createData:
                    guard !value.isEmpty else { return }
                    _ = try await engine.call("createData", ["address": request.address, "type": value], as: Bool.self)
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
            if let v = context.variable { requestRenameVariable(v) }
            else if let t = context.target { requestRename(address: t, currentName: context.targetText) }
            else { requestRename() }
        case ";": requestComment(address: address)
        case "d": if let address { perform("disassemble", address: address, namesChanged: false) }
        case "f": requestCreateFunction(address: address)
        case "c": if let address, viewMode.isListingLike { perform("clear", address: address, namesChanged: false) }
        case "t":
            if let v = context.variable { requestRetypeVariable(v) } else { requestCreateData(address: address) }
        case "b": requestBookmark(address: address)
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
