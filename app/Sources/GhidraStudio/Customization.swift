import AppKit
import SwiftUI

// MARK: - Listing columns

/// A field of a listing line. Their order can be changed in Settings ▸ Listing.
enum ListingColumn: String, Codable, CaseIterable, Identifiable {
    case address, bytes, code, comment, bookmark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .address: tr("Dirección")
        case .bytes: "Bytes"
        case .code: tr("Instrucción")
        case .comment: tr("Comentarios")
        case .bookmark: tr("Marcadores")
        }
    }
}

/// One field of a custom listing row: what it shows and how many characters it takes (0 = what it needs).
struct ListingCell: Codable, Hashable, Identifiable {
    var id = UUID()
    var field: String
    var width: Int

    static let fields: [(String, String)] = [
        ("address", "Dirección"), ("bytes", "Bytes"), ("code", "Instrucción"), ("comment", "Comentarios"),
        ("bookmark", "Marcadores"), ("fileOffset", "Offset en el archivo"), ("functionOffset", "Offset dentro de la función"),
        ("source", "Línea de código fuente"), ("refs", "Número de referencias"), ("spacer", "Espaciador"),
    ]

    var title: String { tr(Self.fields.first { $0.0 == field }?.1 ?? field) }

    /// The standard one-row layout, as a starting point for a custom one.
    static var standard: [[ListingCell]] {
        [[ListingCell(field: "address", width: 12), ListingCell(field: "bytes", width: 26),
          ListingCell(field: "code", width: 44), ListingCell(field: "comment", width: 0)]]
    }
}

/// Which fields the disassembly listing shows (the equivalent of Ghidra's field editor).
struct ListingOptions: Codable, Equatable {
    var showAddress = true
    var showBytes = true
    /// Bytes shown per instruction before truncating.
    var byteCount = 8
    var showReferenceCounts = true
    var showComments = true
    var showBookmarks = true
    var showFlowArrows = true
    var mnemonicWidth = 10
    /// Left-to-right order of the fields of a line.
    var columns = ListingColumn.allCases
    /// Bookmark icons in the left margin.
    var showMarkerMargin = true
    /// The bar on the right that stands for the whole program.
    var showOverview = true
    /// Paint the overview bar by what each part of the program contains.
    var overviewColors = true
    /// A second bar with the entropy of each part of the program.
    var showEntropyBar = false
    /// Extra fields of a line.
    var showFileOffset = false
    var showFunctionOffset = false
    var showPcode = false
    var showXrefList = false
    var showSource = false
    /// Count and list the references that reach a function through its thunks.
    var showThunkXrefs = false
    /// Custom rows of fields for each line; empty means the standard single row.
    var layout: [[ListingCell]] = []
    /// Show what a reference points to when the mouse rests on it.
    var hoverPopups = true

    /// Names of the extra fields the engine has to send.
    var engineFields: [String] {
        var out: [String] = []
        let custom = Set(layout.flatMap { $0 }.map(\.field))
        if showFileOffset || custom.contains("fileOffset") { out.append("fileOffset") }
        if showFunctionOffset || custom.contains("functionOffset") { out.append("functionOffset") }
        if showPcode { out.append("pcode") }
        if showXrefList { out.append("xrefs") }
        if showSource || custom.contains("source") { out.append("source") }
        if showThunkXrefs { out.append("thunkXrefs") }
        return out
    }

    init() {}

    // every field is optional so that options saved by an older version still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAddress = try c.decodeIfPresent(Bool.self, forKey: .showAddress) ?? true
        showBytes = try c.decodeIfPresent(Bool.self, forKey: .showBytes) ?? true
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 8
        showReferenceCounts = try c.decodeIfPresent(Bool.self, forKey: .showReferenceCounts) ?? true
        showComments = try c.decodeIfPresent(Bool.self, forKey: .showComments) ?? true
        showBookmarks = try c.decodeIfPresent(Bool.self, forKey: .showBookmarks) ?? true
        showFlowArrows = try c.decodeIfPresent(Bool.self, forKey: .showFlowArrows) ?? true
        mnemonicWidth = try c.decodeIfPresent(Int.self, forKey: .mnemonicWidth) ?? 10
        showMarkerMargin = try c.decodeIfPresent(Bool.self, forKey: .showMarkerMargin) ?? true
        showOverview = try c.decodeIfPresent(Bool.self, forKey: .showOverview) ?? true
        overviewColors = try c.decodeIfPresent(Bool.self, forKey: .overviewColors) ?? true
        showEntropyBar = try c.decodeIfPresent(Bool.self, forKey: .showEntropyBar) ?? false
        showFileOffset = try c.decodeIfPresent(Bool.self, forKey: .showFileOffset) ?? false
        showFunctionOffset = try c.decodeIfPresent(Bool.self, forKey: .showFunctionOffset) ?? false
        showPcode = try c.decodeIfPresent(Bool.self, forKey: .showPcode) ?? false
        showXrefList = try c.decodeIfPresent(Bool.self, forKey: .showXrefList) ?? false
        showSource = try c.decodeIfPresent(Bool.self, forKey: .showSource) ?? false
        hoverPopups = try c.decodeIfPresent(Bool.self, forKey: .hoverPopups) ?? true
        showThunkXrefs = try c.decodeIfPresent(Bool.self, forKey: .showThunkXrefs) ?? false
        layout = try c.decodeIfPresent([[ListingCell]].self, forKey: .layout) ?? []
        var order = try c.decodeIfPresent([ListingColumn].self, forKey: .columns) ?? ListingColumn.allCases
        for column in ListingColumn.allCases where !order.contains(column) { order.append(column) }
        columns = order
    }

    func isVisible(_ column: ListingColumn) -> Bool {
        switch column {
        case .address: showAddress
        case .bytes: showBytes
        case .code: true
        case .comment: showComments
        case .bookmark: showBookmarks
        }
    }

    mutating func move(_ column: ListingColumn, by delta: Int) {
        guard let i = columns.firstIndex(of: column) else { return }
        let j = i + delta
        guard columns.indices.contains(j) else { return }
        columns.swapAt(i, j)
    }

    static func load() -> ListingOptions {
        guard let data = UserDefaults.standard.data(forKey: "listingOptions"),
              let value = try? JSONDecoder().decode(ListingOptions.self, from: data) else { return ListingOptions() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "listingOptions") }
    }
}

/// A jump drawn in the listing margin, between two lines of the document.
struct FlowArrow: Equatable {
    let from: Int
    let to: Int
    let conditional: Bool
    var lane = 0

    var top: Int { min(from, to) }
    var bottom: Int { max(from, to) }

    static let maxLanes = 8

    /// Gives each arrow a lane so that nested jumps do not overlap (shortest jumps innermost).
    static func assignLanes(_ arrows: [FlowArrow]) -> [FlowArrow] {
        var result: [FlowArrow] = []
        var lanes: [[ClosedRange<Int>]] = []
        for var arrow in arrows.sorted(by: { ($0.bottom - $0.top) < ($1.bottom - $1.top) }) {
            let span = arrow.top...arrow.bottom
            var lane = lanes.firstIndex { ranges in !ranges.contains { $0.overlaps(span) } } ?? lanes.count
            lane = min(lane, maxLanes - 1)
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append(span)
            arrow.lane = lane
            result.append(arrow)
        }
        return result
    }
}

// MARK: - Keyboard shortcuts

/// Every command whose shortcut can be changed in Settings ▸ Shortcuts.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newProject, openProject, importBinary, quickOpenBinary, export, print, closeProgram, save
    case viewDecompiler, viewListing, viewProgram, viewGraph, viewHex, toggleInspector
    case fontBigger, fontSmaller, fontNormal
    case quickOpen, goToAddress, back, forward, goEntry
    case renameFunction, editSignature, comment, bookmark, editFunction, analyzeNow
    case types, search, calls, scripts, graphs, emulator, compare, funcCompare, tables
    case versionTracking, bsim, server, python, functionID
    case newListingWindow, selectFunction, selectFlowFrom, clearSelection
    case nextFunction, previousFunction, cycleInteger, cycleFloat, cycleChar
    case braceNext, bracePrevious, highlightNext, highlightPrevious
    case runLastScript, foldFunction
    case debugger, debugContinue, debugPause, debugStepInto, debugStepOver, debugStepOut, toggleBreakpoint
    // single keys inside the code view, like Ghidra's
    case codeRename, codeComment, codeDisassemble, codeFunction, codeClear, codeType, codeBookmark, codeGoto
    case codeBreakpoint, codeLastType

    var id: String { rawValue }

    var isCodeKey: Bool { rawValue.hasPrefix("code") }

    /// Default shortcut: "cmd+shift+n", or a bare key for the code-view shortcuts.
    var defaultSpec: String {
        switch self {
        case .newProject: "cmd+shift+n"
        case .openProject: "cmd+opt+o"
        case .importBinary: "cmd+i"
        case .quickOpenBinary: "cmd+o"
        case .export: "cmd+opt+e"
        case .print: "cmd+p"
        case .closeProgram: "cmd+shift+w"
        case .save: "cmd+s"
        case .viewDecompiler: "cmd+1"
        case .viewListing: "cmd+2"
        case .viewProgram: "cmd+3"
        case .viewGraph: "cmd+4"
        case .viewHex: "cmd+5"
        case .toggleInspector: "cmd+opt+0"
        case .fontBigger: "cmd++"
        case .fontSmaller: "cmd+-"
        case .fontNormal: "cmd+0"
        case .quickOpen: "cmd+shift+o"
        case .goToAddress: "cmd+l"
        case .back: "cmd+["
        case .forward: "cmd+]"
        case .goEntry: "cmd+shift+e"
        case .renameFunction: "cmd+r"
        case .editSignature: "cmd+shift+r"
        case .comment: "cmd+;"
        case .bookmark: "cmd+d"
        case .editFunction: "cmd+opt+shift+e"
        case .analyzeNow: "cmd+shift+a"
        case .types: "cmd+shift+t"
        case .search: "cmd+shift+f"
        case .calls: "cmd+shift+k"
        case .scripts: "cmd+shift+j"
        case .graphs: "cmd+shift+g"
        case .emulator: "cmd+opt+m"
        case .compare: "cmd+opt+d"
        case .funcCompare: "cmd+opt+f"
        case .tables: "cmd+shift+y"
        case .versionTracking: "cmd+opt+t"
        case .bsim: "cmd+opt+b"
        case .server: "cmd+opt+s"
        case .python: "cmd+opt+p"
        case .functionID: ""
        case .newListingWindow: "cmd+opt+n"
        case .nextFunction: "cmd+opt+."
        case .previousFunction: "cmd+opt+,"
        case .cycleInteger, .cycleFloat, .cycleChar: ""
        case .runLastScript: "cmd+opt+r"
        case .braceNext: "cmd+opt+]"
        case .bracePrevious: "cmd+opt+["
        case .highlightNext: "cmd+ctrl+."
        case .highlightPrevious: "cmd+ctrl+,"
        case .foldFunction: "cmd+ctrl+-"
        case .selectFunction: "cmd+opt+a"
        case .selectFlowFrom: ""
        case .clearSelection: "cmd+opt+k"
        case .debugger: "cmd+shift+d"
        case .debugContinue: "cmd+ctrl+y"
        case .debugPause: "cmd+ctrl+p"
        case .debugStepInto: "cmd+ctrl+i"
        case .debugStepOver: "cmd+ctrl+o"
        case .debugStepOut: "cmd+ctrl+u"
        case .toggleBreakpoint: "cmd+\\"
        case .codeBreakpoint: "k"
        case .codeRename: "l"
        case .codeComment: ";"
        case .codeDisassemble: "d"
        case .codeFunction: "f"
        case .codeClear: "c"
        case .codeType: "t"
        case .codeLastType: "y"
        case .codeBookmark: "b"
        case .codeGoto: "g"
        }
    }

    /// The key AppModel.handleKey expects for a code-view action.
    var codeKey: String { isCodeKey ? defaultSpec : "" }

    var title: String {
        switch self {
        case .newProject: tr("Nuevo proyecto…")
        case .openProject: tr("Abrir proyecto…")
        case .importBinary: tr("Importar binario…")
        case .quickOpenBinary: tr("Abrir binario rápido…")
        case .export: tr("Exportar…")
        case .print: tr("Imprimir…")
        case .closeProgram: tr("Cerrar programa")
        case .save: tr("Guardar")
        case .viewDecompiler: tr("Descompilado")
        case .viewListing: tr("Desensamblado")
        case .viewProgram: tr("Listado completo")
        case .viewGraph: tr("Grafo de la función")
        case .viewHex: "Hex"
        case .toggleInspector: tr("Mostrar inspector")
        case .fontBigger: tr("Aumentar tamaño de letra")
        case .fontSmaller: tr("Reducir tamaño de letra")
        case .fontNormal: tr("Tamaño de letra normal")
        case .quickOpen: tr("Abrir rápidamente…")
        case .goToAddress: tr("Ir a dirección…")
        case .back: tr("Atrás")
        case .forward: tr("Adelante")
        case .goEntry: tr("Ir al punto de entrada")
        case .renameFunction: tr("Renombrar función…")
        case .editSignature: tr("Editar firma…")
        case .comment: tr("Comentario…")
        case .bookmark: tr("Añadir marcador…")
        case .editFunction: tr("Editar función…")
        case .analyzeNow: tr("Analizar ahora")
        case .types: tr("Tipos de datos")
        case .search: tr("Buscar en el programa…")
        case .calls: tr("Árbol de llamadas")
        case .scripts: tr("Scripts")
        case .graphs: tr("Grafos")
        case .emulator: tr("Emulador")
        case .compare: tr("Comparar programas")
        case .funcCompare: tr("Comparar funciones")
        case .tables: tr("Tablas")
        case .versionTracking: tr("Version Tracking")
        case .bsim: "BSim"
        case .server: tr("Ghidra Server y control de versiones")
        case .python: tr("Intérprete de Python")
        case .functionID: "Function ID"
        case .newListingWindow: tr("Nueva ventana de listado")
        case .nextFunction: tr("Siguiente función")
        case .previousFunction: tr("Función anterior")
        case .cycleInteger: tr("Ciclo byte → word → dword → qword")
        case .cycleFloat: tr("Ciclo float → double")
        case .cycleChar: tr("Ciclo char → string → unicode")
        case .runLastScript: tr("Ejecutar el último script")
        case .braceNext: tr("Ir a la llave de cierre")
        case .bracePrevious: tr("Ir a la llave de apertura")
        case .highlightNext: tr("Resaltado siguiente")
        case .highlightPrevious: tr("Resaltado anterior")
        case .foldFunction: tr("Plegar o desplegar la función")
        case .selectFunction: tr("Seleccionar la función")
        case .selectFlowFrom: tr("Seleccionar todo el flujo desde aquí")
        case .clearSelection: tr("Quitar la selección")
        case .debugger: tr("Depurador")
        case .debugContinue: tr("Iniciar depuración o continuar")
        case .debugPause: tr("Pausar")
        case .debugStepInto: tr("Paso entrando en llamadas")
        case .debugStepOver: tr("Paso sin entrar en llamadas")
        case .debugStepOut: tr("Salir de la función")
        case .toggleBreakpoint: tr("Poner o quitar breakpoint")
        case .codeBreakpoint: "Breakpoint"
        case .codeRename: tr("Renombrar")
        case .codeComment: tr("Comentario")
        case .codeDisassemble: tr("Desensamblar")
        case .codeFunction: tr("Crear función")
        case .codeClear: tr("Borrar código/dato")
        case .codeType: tr("Definir dato / cambiar tipo")
        case .codeLastType: tr("Aplicar el último tipo usado")
        case .codeBookmark: tr("Marcador")
        case .codeGoto: tr("Ir a…")
        }
    }

    var group: String {
        switch self {
        case .newProject, .openProject, .importBinary, .quickOpenBinary, .export, .print, .closeProgram, .save:
            tr("Archivo")
        case .viewDecompiler, .viewListing, .viewProgram, .viewGraph, .viewHex, .toggleInspector, .fontBigger,
             .fontSmaller, .fontNormal:
            tr("Vista")
        case .quickOpen, .goToAddress, .back, .forward, .goEntry:
            tr("Navegar")
        case .renameFunction, .editSignature, .comment, .bookmark, .editFunction, .analyzeNow:
            tr("Análisis")
        case .codeRename, .codeComment, .codeDisassemble, .codeFunction, .codeClear, .codeType, .codeBookmark, .codeGoto,
             .codeBreakpoint, .codeLastType:
            tr("Teclas en el código")
        case .debugger, .debugContinue, .debugPause, .debugStepInto, .debugStepOver, .debugStepOut, .toggleBreakpoint:
            tr("Depurar")
        case .selectFunction, .selectFlowFrom, .clearSelection:
            tr("Selección")
        case .newListingWindow, .foldFunction:
            tr("Vista")
        case .nextFunction, .previousFunction, .braceNext, .bracePrevious, .highlightNext, .highlightPrevious:
            tr("Navegar")
        case .cycleInteger, .cycleFloat, .cycleChar:
            tr("Análisis")
        default:
            tr("Herramientas")
        }
    }
}

/// User-editable shortcuts. A spec is "cmd+shift+k" (or a bare key for the code view); "" means none.
@MainActor
@Observable
final class Shortcuts {
    static let shared = Shortcuts()

    private(set) var overrides: [String: String]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
    }

    func spec(_ action: ShortcutAction) -> String {
        overrides[action.rawValue] ?? action.defaultSpec
    }

    func isCustom(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    func set(_ action: ShortcutAction, _ spec: String?) {
        if let spec, spec != action.defaultSpec {
            overrides[action.rawValue] = spec
        } else {
            overrides.removeValue(forKey: action.rawValue)
        }
        UserDefaults.standard.set(overrides, forKey: "shortcuts")
    }

    func resetAll() {
        overrides = [:]
        UserDefaults.standard.removeObject(forKey: "shortcuts")
    }

    /// Other actions of the same kind that use the same shortcut.
    func conflicts(_ action: ShortcutAction) -> [ShortcutAction] {
        let mine = spec(action)
        guard !mine.isEmpty else { return [] }
        return ShortcutAction.allCases.filter { $0 != action && $0.isCodeKey == action.isCodeKey && spec($0) == mine }
    }

    /// Menu shortcut for a command (nil when the user removed it).
    func shortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        Self.parse(spec(action))
    }

    /// Translates a key typed in the code view to the key the action is known by ("l", ";", "d"…).
    func codeKey(for typed: String) -> String? {
        let key = typed.lowercased()
        return ShortcutAction.allCases.first { $0.isCodeKey && spec($0) == key }?.codeKey
    }

    static func parse(_ spec: String) -> KeyboardShortcut? {
        guard !spec.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        var key = spec
        // the key itself may be "+", so peel known modifier prefixes instead of splitting
        while true {
            if key.hasPrefix("cmd+") { modifiers.insert(.command); key.removeFirst(4) }
            else if key.hasPrefix("shift+") { modifiers.insert(.shift); key.removeFirst(6) }
            else if key.hasPrefix("opt+") { modifiers.insert(.option); key.removeFirst(4) }
            else if key.hasPrefix("ctrl+") { modifiers.insert(.control); key.removeFirst(5) }
            else { break }
        }
        guard let character = key.first, key.count == 1 else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }

    static func display(_ spec: String) -> String {
        guard !spec.isEmpty else { return "—" }
        var out = ""
        var key = spec
        while true {
            if key.hasPrefix("ctrl+") { out += "⌃"; key.removeFirst(5) }
            else if key.hasPrefix("opt+") { out += "⌥"; key.removeFirst(4) }
            else if key.hasPrefix("shift+") { out += "⇧"; key.removeFirst(6) }
            else if key.hasPrefix("cmd+") { out += "⌘"; key.removeFirst(4) }
            else { break }
        }
        return out + key.uppercased()
    }

    /// Builds a spec from a key event; nil if it is not usable (no character, or a menu shortcut without ⌘/⌃/⌥).
    static func spec(from event: NSEvent, codeKey: Bool) -> String? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
              let scalar = chars.unicodeScalars.first, scalar.value > 32, scalar.value < 0xF700 else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if codeKey {
            return flags.subtracting(.shift).isEmpty ? chars : nil
        }
        guard !flags.subtracting(.shift).isEmpty else { return nil }
        // canonical order: cmd, opt, ctrl, shift
        var spec = ""
        if flags.contains(.command) { spec += "cmd+" }
        if flags.contains(.option) { spec += "opt+" }
        if flags.contains(.control) { spec += "ctrl+" }
        if flags.contains(.shift) { spec += "shift+" }
        return spec + chars
    }
}

/// Captures the next key press while it is on screen (used to record a new shortcut).
private struct KeyCapture: NSViewRepresentable {
    let onKey: (NSEvent) -> Void

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
        }
        override func keyDown(with event: NSEvent) { onKey?(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            onKey?(event)
            return true
        }
    }

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) { view.onKey = onKey }
}

struct ShortcutsSettingsView: View {
    @State private var keys = Shortcuts.shared
    @State private var recording: ShortcutAction?
    @State private var query = ""

    private var groups: [(String, [ShortcutAction])] {
        var order: [String] = []
        var byGroup: [String: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases
        where query.isEmpty || action.title.localizedCaseInsensitiveContains(query) {
            if byGroup[action.group] == nil { order.append(action.group) }
            byGroup[action.group, default: []].append(action)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Buscar acción"), text: $query).textFieldStyle(.roundedBorder)
                Button(tr("Exportar…")) { keys.exportBindings() }
                Button(tr("Importar…")) {
                    recording = nil
                    _ = keys.importBindings()
                }
                Button(tr("Restablecer todos")) {
                    recording = nil
                    keys.resetAll()
                }
                .disabled(keys.overrides.isEmpty)
            }
            .padding(12)
            Divider()
            List {
                ForEach(groups, id: \.0) { group, actions in
                    Section(group) {
                        ForEach(actions) { action in row(action) }
                    }
                }
            }
            Divider()
            Text(recording == nil
                 ? tr("Pulsa «Cambiar» y luego la combinación nueva. Las teclas del código son una sola tecla, sin ⌘.")
                 : tr("Pulsa la combinación nueva · Esc cancela · ⌫ deja la acción sin atajo"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let conflicts = keys.conflicts(action)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                if !conflicts.isEmpty {
                    Text(tr("Mismo atajo que «%@»", conflicts[0].title)).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if recording == action {
                Text(tr("Pulsa las teclas…")).font(.callout).foregroundStyle(.tint)
                    .background(KeyCapture { event in capture(event, for: action) }.frame(width: 1, height: 1))
            } else {
                Text(Shortcuts.display(keys.spec(action)))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(keys.isCustom(action) ? Color.accentColor : Color.primary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            Button(recording == action ? tr("Cancelar") : tr("Cambiar")) {
                recording = recording == action ? nil : action
            }
            .controlSize(.small)
            Button { keys.set(action, nil) } label: { Image(systemName: "arrow.uturn.backward") }
                .controlSize(.small)
                .help(tr("Volver al atajo original"))
                .disabled(!keys.isCustom(action))
        }
    }

    private func capture(_ event: NSEvent, for action: ShortcutAction) {
        if event.keyCode == 53 {            // escape
            recording = nil
        } else if event.keyCode == 51 {     // delete: no shortcut
            keys.set(action, "")
            recording = nil
        } else if let spec = Shortcuts.spec(from: event, codeKey: action.isCodeKey) {
            keys.set(action, spec)
            recording = nil
        }
    }
}

struct ListingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(tr("Columnas del listado")) {
                Toggle(tr("Dirección"), isOn: $model.listingOptions.showAddress)
                Toggle("Bytes", isOn: $model.listingOptions.showBytes)
                Stepper(tr("Bytes por instrucción: %@", "\(model.listingOptions.byteCount)"),
                        value: $model.listingOptions.byteCount, in: 2...8)
                    .disabled(!model.listingOptions.showBytes)
                Stepper(tr("Ancho del mnemónico: %@", "\(model.listingOptions.mnemonicWidth)"),
                        value: $model.listingOptions.mnemonicWidth, in: 6...16)
                Toggle(tr("Número de referencias junto a las etiquetas"), isOn: $model.listingOptions.showReferenceCounts)
                Toggle(tr("Comentarios"), isOn: $model.listingOptions.showComments)
                Toggle(tr("Marcadores"), isOn: $model.listingOptions.showBookmarks)
            }
            Section(tr("Campos adicionales")) {
                Toggle(tr("Offset en el archivo"), isOn: $model.listingOptions.showFileOffset)
                Toggle(tr("Offset dentro de la función"), isOn: $model.listingOptions.showFunctionOffset)
                Toggle(tr("Lista de referencias (XREF) bajo las etiquetas"), isOn: $model.listingOptions.showXrefList)
                Toggle(tr("Incluir las referencias a los thunks de la función"), isOn: $model.listingOptions.showThunkXrefs)
                Toggle(tr("P-code de cada instrucción"), isOn: $model.listingOptions.showPcode)
                Toggle(tr("Archivo y línea del código fuente"), isOn: $model.listingOptions.showSource)
                Toggle(tr("Ventana emergente al dejar el ratón sobre una referencia"), isOn: $model.listingOptions.hoverPopups)
            }
            Section(tr("Orden de las columnas")) {
                ForEach(Array(model.listingOptions.columns.enumerated()), id: \.element) { index, column in
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(column.title)
                            .foregroundStyle(model.listingOptions.isVisible(column) ? .primary : .tertiary)
                        Spacer()
                        Button { model.listingOptions.move(column, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help(tr("Mover a la izquierda"))
                        Button { model.listingOptions.move(column, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == model.listingOptions.columns.count - 1)
                            .help(tr("Mover a la derecha"))
                    }
                    .controlSize(.small)
                }
                Button(tr("Orden original")) { model.listingOptions.columns = ListingColumn.allCases }
                    .disabled(model.listingOptions.columns == ListingColumn.allCases)
            }
            Section(tr("Filas a medida")) {
                Toggle(tr("Usar filas de campos a medida"), isOn: Binding(
                    get: { !model.listingOptions.layout.isEmpty },
                    set: { model.listingOptions.layout = $0 ? ListingCell.standard : [] }))
                if !model.listingOptions.layout.isEmpty {
                    ListingLayoutEditor(layout: $model.listingOptions.layout)
                    Text(tr("Cada línea del listado se dibuja con estas filas, de arriba abajo. El ancho va en caracteres; 0 es «lo que ocupe». Las filas que quedarían vacías no se dibujan."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(tr("Margen")) {
                Toggle(tr("Flechas de flujo de los saltos"), isOn: $model.listingOptions.showFlowArrows)
                Text(tr("Línea continua: salto incondicional. Discontinua: condicional. Se resaltan las del lugar donde está el cursor."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("Iconos de marcadores en el margen"), isOn: $model.listingOptions.showMarkerMargin)
            }
            Section(tr("Vista general del programa")) {
                Toggle(tr("Barra de vista general a la derecha"), isOn: $model.listingOptions.showOverview)
                Toggle(tr("Colorear según el contenido"), isOn: $model.listingOptions.overviewColors)
                    .disabled(!model.listingOptions.showOverview)
                Toggle(tr("Barra de entropía"), isOn: $model.listingOptions.showEntropyBar)
                Text(tr("La barra representa todo el programa: muestra dónde está el cursor, los marcadores, los cambios sin guardar y la selección. Haz clic en ella para ir a esa parte."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The rows of a custom listing layout: fields and spacers with their widths.
struct ListingLayoutEditor: View {
    @Binding var layout: [[ListingCell]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(layout.enumerated()), id: \.offset) { rowIndex, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tr("Fila %@", "\(rowIndex + 1)")).font(.caption.weight(.semibold))
                        Spacer()
                        Menu(tr("Añadir campo")) {
                            ForEach(ListingCell.fields, id: \.0) { field in
                                Button(tr(field.1)) {
                                    layout[rowIndex].append(ListingCell(field: field.0, width: field.0 == "spacer" ? 4 : 0))
                                }
                            }
                        }
                        .fixedSize()
                        Button { layout.remove(at: rowIndex) } label: { Image(systemName: "trash") }
                            .disabled(layout.count == 1).help(tr("Quitar la fila"))
                    }
                    ForEach(Array(row.enumerated()), id: \.element.id) { cellIndex, cell in
                        HStack(spacing: 6) {
                            Text(cell.title).frame(width: 190, alignment: .leading)
                            Stepper(tr("Ancho: %@", "\(cell.width)"), value: Binding(
                                get: { layout[rowIndex][cellIndex].width },
                                set: { layout[rowIndex][cellIndex].width = $0 }), in: 0...120)
                            Spacer()
                            Button { layout[rowIndex].swapAt(cellIndex, cellIndex - 1) } label: { Image(systemName: "chevron.up") }
                                .disabled(cellIndex == 0).help(tr("Mover a la izquierda"))
                            Button { layout[rowIndex].swapAt(cellIndex, cellIndex + 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(cellIndex == row.count - 1).help(tr("Mover a la derecha"))
                            Button { layout[rowIndex].remove(at: cellIndex) } label: { Image(systemName: "minus.circle") }
                                .help(tr("Quitar el campo"))
                        }
                        .controlSize(.small)
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button(tr("Añadir fila")) { layout.append([ListingCell(field: "spacer", width: 12)]) }
                Button(tr("Distribución estándar")) { layout = ListingCell.standard }
            }
        }
    }
}
