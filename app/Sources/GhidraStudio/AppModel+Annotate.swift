import AppKit
import SwiftUI

/// A range of the listing with a background color.
struct ColorRange: Equatable {
    let range: ClosedRange<UInt64>
    let rgb: UInt32
}

/// One field of a structure (or element of an array) shown under its data in the listing.
struct DataComponent: Codable, Equatable {
    let index: Int
    let address: String
    let offset: Int
    let name: String?
    let type: String
    let value: String
    let length: Int
    let components: Int
    let bytes: String
    let comment: String?
}

struct DataComponents: Codable {
    let address: String
    let type: String
    let count: Int
    let components: [DataComponent]
}

struct EntropyOverview: Codable {
    let values: [Double]
}

struct GoToHit: Codable, Identifiable {
    let address: String
    let name: String
    let function: String?
    var id: String { address + name }
}

extension AppModel {
    // MARK: Plumbing

    /// The form request, seen only by the window it was made for.
    func formBinding(_ origin: String) -> Binding<FormRequest?> {
        Binding(get: { self.formRequest?.origin == origin ? self.formRequest : nil },
                set: { if $0 == nil, self.formRequest?.origin == origin { self.formRequest = nil } })
    }

    /// Runs an engine edit and refreshes what the program shows.
    func edit(_ method: String, _ params: [String: Any], namesChanged: Bool = true) async throws {
        _ = try await engine.call(method, params, as: JSONValue.self)
        if method == "createData", let type = params["type"] as? String { noteType(type) }
        await afterEdit(namesChanged: namesChanged)
    }

    /// Same, for menu commands: errors go to the alert.
    func run(_ method: String, _ params: [String: Any], namesChanged: Bool = true) {
        Task {
            do { try await edit(method, params, namesChanged: namesChanged) } catch { errorMessage = error.localizedDescription }
        }
    }

    /// What a command acts on: the program selection, the lines selected with the mouse, or the cursor.
    var target: [String: Any] {
        if let selection = programSelection { return ["ranges": selection.ranges] }
        if let ctx = CodeNSTextView.current?.contextProvider?(), let start = ctx.selectionStart, let end = ctx.selectionEnd,
           start != end {
            return ["address": start, "end": end]
        }
        return ["address": editTarget ?? ""]
    }

    private func merged(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] { a.merging(b) { _, new in new } }

    // MARK: Navigation

    func goNext(_ kind: String, forward: Bool) {
        guard let address = editTarget else { return }
        Task {
            do {
                let found: Resolved = try await engine.call("goNext", ["address": address, "kind": kind, "forward": forward])
                await navigate(to: found.address)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Go to a file offset, an expression or a name with wildcards.
    func requestGoToExpression() {
        formRequest = FormRequest(
            title: tr("Ir a expresión, offset de archivo o comodín"),
            message: tr("Ejemplos: main+0x20 · file(0x1a40) · _str*"),
            fields: [FormField(key: "query", title: tr("Ir a"))],
            actionTitle: tr("Ir")) { [self] values in
                var params: [String: Any] = ["query": values["query"] ?? ""]
                if let address = editTarget { params["address"] = address }
                let hits: [GoToHit] = try await engine.call("goTo", params)
                guard let first = hits.first else { throw EngineError.remote(tr("No se encontró nada.")) }
                await navigate(to: first.address)
                if hits.count > 1 {
                    // the rest become a selection, to walk through them
                    setSelection(ranges: hits.map { [$0.address, $0.address] })
                }
            }
    }

    // MARK: Selection and highlight

    func setSelection(ranges: [[String]]) {
        guard !ranges.isEmpty else { programSelection = nil; return }
        programSelection = ProgramSelection(SelectionResult(ranges: ranges, rangeCount: ranges.count,
                                                            addresses: Int64(ranges.count), truncated: false,
                                                            first: ranges.first?.first))
    }

    func requestSelectBytes() {
        guard let address = editTarget, let value = addressValue(address) else { return }
        formRequest = FormRequest(
            title: tr("Seleccionar bytes"),
            fields: [FormField(key: "length", title: tr("Número de bytes"), value: "0x10"),
                     FormField(key: "direction", title: tr("Sentido"),
                               kind: .choice([tr("Hacia delante"), tr("Hacia atrás"), tr("Hasta la dirección")]), value: tr("Hacia delante")),
                     FormField(key: "to", title: tr("Dirección final (para «Hasta la dirección»)"))],
            actionTitle: tr("Seleccionar")) { [self] values in
                let width = address.count
                func hex(_ v: UInt64) -> String {
                    let s = String(v, radix: 16)
                    return String(repeating: "0", count: max(0, width - s.count)) + s
                }
                let text = values["length"] ?? "1"
                let length = UInt64(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: text.hasPrefix("0x") ? 16 : 10) ?? 1
                switch values["direction"] {
                case tr("Hacia atrás"): selectLines(start: hex(value &- (length - 1)), end: address)
                case tr("Hasta la dirección"):
                    guard let to = values["to"], let end = addressValue(to) else { throw EngineError.remote(tr("Dirección inválida")) }
                    selectLines(start: hex(min(value, end)), end: hex(max(value, end)))
                default: selectLines(start: address, end: hex(value &+ (length - 1)))
                }
            }
    }

    /// set, clear, add, subtract (highlight from the selection) or select (selection from the highlight).
    func highlightAction(_ action: String) {
        switch action {
        case "set": highlight = programSelection
        case "clear": highlight = nil
        case "select": programSelection = highlight
        default:
            guard let selection = programSelection else { return }
            var ranges = highlight?.ranges ?? []
            if action == "add" {
                ranges += selection.ranges
            } else {
                // subtract: keep the highlighted ranges that the selection does not touch
                ranges = ranges.filter { pair in
                    guard pair.count == 2, let lo = addressValue(pair[0]), let hi = addressValue(pair[1]) else { return false }
                    return !selection.bounds.contains { $0.overlaps(lo...hi) }
                }
            }
            highlight = ranges.isEmpty ? nil : ProgramSelection(SelectionResult(ranges: ranges, rangeCount: ranges.count,
                                                                             addresses: Int64(ranges.count), truncated: false,
                                                                             first: ranges.first?.first))
        }
    }

    // MARK: Colors

    func refreshColors() async {
        let list: [[String]] = (try? await engine.call("colors")) ?? []
        colorRanges = list.compactMap { item in
            guard item.count == 3, let lo = addressValue(item[0]), let hi = addressValue(item[1]),
                  let rgb = UInt32(item[2], radix: 16), lo <= hi else { return nil }
            return ColorRange(range: lo...hi, rgb: rgb)
        }
    }

    /// Paints (or, with nil, clears) the background of the selection or the current line.
    func setColor(_ rgb: String?) {
        Task {
            do {
                _ = try await engine.call("setColor", merged(target, ["color": rgb ?? ""]), as: JSONValue.self)
                await refreshColors()
                await refreshUndo()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Paints (or clears) the background of an address range.
    func setColor(_ rgb: String?, start: String, end: String) {
        Task {
            do {
                _ = try await engine.call("setColor", ["address": start, "end": end, "color": rgb ?? ""], as: JSONValue.self)
                await refreshColors()
                await refreshUndo()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func clearAllColors() {
        Task {
            _ = try? await engine.call("setColor", ["color": "", "ranges": [[String]]()], as: JSONValue.self)
            await refreshColors()
            await refreshUndo()
        }
    }

    // MARK: Clear

    func requestClearWithOptions() {
        Task {
            let types: [String] = (try? await engine.call("clearTypes")) ?? []
            let defaults: Set<String> = ["INSTRUCTIONS", "DATA"]
            formRequest = FormRequest(
                title: tr("Borrar con opciones"),
                message: tr("Elige qué se borra en la selección (o en la línea actual)."),
                fields: types.map { FormField(key: $0, title: Self.clearTitle($0), kind: .toggle, value: defaults.contains($0) ? "true" : "false") },
                actionTitle: tr("Borrar")) { [self] values in
                    let what = types.filter { values[$0] == "true" }
                    try await edit("clearWith", merged(target, ["what": what]))
                }
        }
    }

    private static func clearTitle(_ type: String) -> String {
        switch type {
        case "INSTRUCTIONS": tr("Instrucciones")
        case "DATA": tr("Datos")
        case "SYMBOLS": tr("Símbolos")
        case "COMMENTS": tr("Comentarios")
        case "PROPERTIES": tr("Propiedades")
        case "FUNCTIONS": tr("Funciones")
        case "REGISTERS": tr("Registros")
        case "EQUATES": "Equates"
        case "USER_REFERENCES": tr("Referencias del usuario")
        case "ANALYSIS_REFERENCES": tr("Referencias del análisis")
        case "IMPORT_REFERENCES": tr("Referencias de la importación")
        case "DEFAULT_REFERENCES": tr("Referencias por defecto")
        case "BOOKMARKS": tr("Marcadores")
        default: type
        }
    }

    func requestClearFlow() {
        formRequest = FormRequest(
            title: tr("Borrar flujo y reparar"),
            message: tr("Borra el código al que se llega desde aquí y vuelve a desensamblar lo que quedaba conectado."),
            fields: [FormField(key: "symbols", title: tr("Borrar también los símbolos"), kind: .toggle, value: "false"),
                     FormField(key: "data", title: tr("Borrar también los datos"), kind: .toggle, value: "false"),
                     FormField(key: "repair", title: tr("Reparar el flujo"), kind: .toggle, value: "true")],
            actionTitle: tr("Borrar")) { [self] values in
                try await edit("clearFlow", merged(target, ["symbols": values["symbols"] == "true",
                                                           "data": values["data"] == "true", "repair": values["repair"] == "true"]))
            }
    }

    // MARK: Data

    func cycleData(_ group: String) {
        guard let address = editTarget else { return }
        run("cycleData", ["address": address, "group": group], namesChanged: false)
    }

    func requestPatchData() {
        guard let address = editTarget else { return }
        formRequest = FormRequest(
            title: tr("Parchear dato"),
            message: tr("Escribe un valor del tipo del dato en %@: 0x1234, -3, 1.5 o \"texto\".", address),
            fields: [FormField(key: "value", title: tr("Valor"))],
            actionTitle: tr("Escribir")) { [self] values in
                try await edit("patchData", ["address": address, "value": values["value"] ?? ""], namesChanged: false)
            }
    }

    /// Shows the scalar under the cursor in another form.
    func convert(_ format: String) {
        guard let address = editTarget else { return }
        Task {
            do {
                let scalars: [JSONRow] = try await engine.call("scalars", ["address": address])
                guard let scalar = scalars.last else {
                    // a data value: its format is a setting of the data
                    let name = ["signedDecimal": "decimal", "unsignedDecimal": "decimal", "octal": "octal", "binary": "binary",
                                "char": "char"][format] ?? "hex"
                    try await edit("setDataSetting", ["address": address, "name": "Format", "value": name], namesChanged: false)
                    return
                }
                try await edit("convert", ["address": address, "operand": scalar["operand"]?.int ?? 0,
                                           "value": scalar["value"]?.int ?? 0, "bits": scalar["bits"]?.int ?? 64,
                                           "format": format], namesChanged: false)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func requestApplyEnum() {
        formRequest = FormRequest(
            title: tr("Aplicar enum"),
            message: tr("Da nombre a las constantes de la selección que coincidan con valores del enum."),
            fields: [FormField(key: "enum", title: tr("Enum (ruta o nombre)"), placeholder: "/MiEnum"),
                     FormField(key: "sub", title: tr("También en suboperandos"), kind: .toggle, value: "false")],
            actionTitle: tr("Aplicar")) { [self] values in
                var path = values["enum"] ?? ""
                if !path.hasPrefix("/") { path = "/" + path }
                try await edit("applyEnum", merged(target, ["enum": path, "subOperands": values["sub"] == "true"]), namesChanged: false)
            }
    }

    // MARK: Functions

    func requestThunk() {
        guard let address = editTarget else { return }
        formRequest = FormRequest(
            title: tr("Función thunk"),
            message: tr("La función en %@ pasa a ser un thunk de otra. Déjalo vacío para que deje de serlo.", address),
            fields: [FormField(key: "target", title: tr("Función de destino (nombre o dirección)"))],
            actionTitle: tr("Aplicar")) { [self] values in
                try await edit("setThunk", ["address": address, "target": values["target"] ?? ""])
            }
    }

    func requestExternalFunction() {
        formRequest = FormRequest(
            title: tr("Crear función externa"),
            fields: [FormField(key: "library", title: tr("Biblioteca"), placeholder: "libfoo.dylib"),
                     FormField(key: "name", title: tr("Nombre")),
                     FormField(key: "target", title: tr("Dirección en la biblioteca (opcional)"))],
            actionTitle: tr("Crear")) { [self] values in
                try await edit("createExternalFunction", ["library": values["library"] ?? "", "name": values["name"] ?? "",
                                                          "target": values["target"] ?? ""])
            }
    }

    func requestStackDepthChange() {
        guard let address = editTarget else { return }
        formRequest = FormRequest(
            title: tr("Cambio de profundidad de pila"),
            message: tr("Cuánto cambia la pila en la llamada de %@. Vacío quita el ajuste.", address),
            fields: [FormField(key: "value", title: tr("Bytes"), placeholder: "0x10")],
            actionTitle: tr("Aplicar")) { [self] values in
                try await edit("stackDepthChange", ["address": address, "value": values["value"] ?? ""], namesChanged: false)
            }
    }

    // MARK: Instruction overrides

    func requestInstructionOverrides() {
        guard let address = editTarget else { return }
        Task {
            do {
                let info: JSONRow = try await engine.call("instructionInfo", ["address": address])
                let flows = info["flowOverrides"]?.array.map(\.text) ?? []
                formRequest = FormRequest(
                    title: tr("Modificar la instrucción"),
                    message: "\(info["address"]?.text ?? address)  \(info["text"]?.text ?? "")",
                    fields: [FormField(key: "flow", title: tr("Flujo"), kind: .choice(flows), value: info["flowOverride"]?.text ?? "NONE"),
                             FormField(key: "fallthrough", title: tr("Fallthrough (vacío: el normal; none: ninguno)"),
                                       value: info["fallthroughOverridden"]?.bool == true ? (info["fallthrough"]?.text ?? "none") : ""),
                             FormField(key: "length", title: tr("Longitud (0: la normal)"),
                                       value: info["lengthOverridden"]?.bool == true ? (info["length"]?.text ?? "0") : "0")],
                    actionTitle: tr("Aplicar")) { [self] values in
                        _ = try await engine.call("setFlowOverride", ["address": address, "flow": values["flow"] ?? "NONE"], as: JSONValue.self)
                        _ = try await engine.call("setFallthrough", ["address": address, "to": values["fallthrough"] ?? ""], as: JSONValue.self)
                        try await edit("setLengthOverride", ["address": address, "length": Int(values["length"] ?? "0") ?? 0],
                                       namesChanged: false)
                    }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Copy special

    func copySpecial(_ format: String) {
        var params = target
        if let ranges = params["ranges"] as? [[String]], let first = ranges.first, first.count == 2 {
            params = ["address": first[0], "end": first[1]]
        }
        params["format"] = format
        Task {
            do {
                let text: String = try await engine.call("copySpecial", params)
                copyToPasteboard(text)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// What the pop-up shows about the address the mouse is resting on.
    func preview(_ target: String) async -> (String, [String])? {
        guard let info: JSONRow = try? await engine.call("preview", ["address": target]) else { return nil }
        var lines = info["lines"]?.array.map(\.text) ?? []
        var where_: [String] = []
        if let block = info["block"]?.string { where_.append(block) }
        if let fn = info["function"]?.string { where_.append(fn) }
        if !where_.isEmpty { lines.append(where_.joined(separator: " · ")) }
        return ("\(info["title"]?.text ?? target)  \(info["address"]?.text ?? "")", lines)
    }

    // MARK: Structured data in the listing

    /// Opens or closes the structure or array at an address in the listing.
    func toggleData(_ address: String) {
        if expandedData[address] != nil {
            expandedData[address] = nil
            rebuildDocument()
            return
        }
        Task {
            do {
                let data: DataComponents = try await engine.call("dataComponents", ["address": address])
                expandedData[data.address] = data.components
                rebuildDocument()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Folding functions

    private var foldKey: String { "foldedFunctions|" + (activeSession ?? "") }

    /// Functions folded in the listing of the active program (remembered between launches).
    var foldedFunctions: Set<String> {
        let session = activeSession ?? ""
        if let known = foldedBySession[session] { return known }
        return Set(UserDefaults.standard.stringArray(forKey: foldKey) ?? [])
    }

    func setFolded(_ entries: Set<String>) {
        foldedBySession[activeSession ?? ""] = entries
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: foldKey)
        } else {
            UserDefaults.standard.set(Array(entries), forKey: foldKey)
        }
    }

    /// Reloads the whole-program listing around the current place, after folding changes.
    private func reloadFolding() {
        fullRows = []
        fullAtStart = false
        fullAtEnd = false
        guard viewMode == .program, let current else { return }
        go(current.address)
    }

    /// Folds or unfolds a function in the listing; only its header stays when folded.
    func toggleFold(_ entry: String) {
        var folded = foldedFunctions
        if folded.contains(entry) { folded.remove(entry) } else { folded.insert(entry) }
        setFolded(folded)
        if viewMode != .program { viewMode = .program }
        if folded.contains(entry) {
            // stay on the header of the function that has just been folded
            fullRows = []
            go(entry)
        } else {
            reloadFolding()
        }
    }

    func foldCurrentFunction() {
        guard let entry = current?.function else {
            errorMessage = tr("El cursor no está en ninguna función.")
            return
        }
        toggleFold(entry)
    }

    func foldAllFunctions(_ fold: Bool) {
        setFolded(fold ? Set(functions.map(\.address)) : [])
        if fold, let entry = current?.function {
            fullRows = []
            go(entry)
        } else {
            reloadFolding()
        }
    }

    /// Tells the engine which optional listing fields to send.
    func sendListingFields() async {
        _ = try? await engine.call("setListingFields", ["fields": listingOptions.engineFields], as: JSONValue.self)
    }

    // MARK: Memory blocks

    func memoryFlag(_ block: String, _ flag: String, _ value: String) {
        Task {
            do {
                _ = try await engine.call("setBlockFlag", ["name": block, "flag": flag, "value": value], as: JSONValue.self)
                segments = try await engine.call("segments")
                await afterEdit(namesChanged: false)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func requestBlockComment(_ seg: SegmentItem) {
        formRequest = FormRequest(
            title: tr("Comentario del bloque «%@»", seg.name),
            fields: [FormField(key: "text", title: tr("Comentario"), value: seg.comment ?? "", mono: false)],
            actionTitle: tr("Guardar")) { [self] values in
                _ = try await engine.call("setBlockFlag", ["name": seg.name, "flag": "comment", "value": values["text"] ?? ""],
                                          as: JSONValue.self)
                segments = try await engine.call("segments")
                await afterEdit(namesChanged: false)
            }
    }

    func requestRenameOverlay(_ seg: SegmentItem) {
        let space = seg.start.split(separator: ":").first.map(String.init) ?? seg.name
        formRequest = FormRequest(
            title: tr("Renombrar el espacio overlay"),
            fields: [FormField(key: "name", title: tr("Nuevo nombre"), value: space)],
            actionTitle: tr("Renombrar")) { [self] values in
                _ = try await engine.call("renameOverlay", ["name": space, "newName": values["name"] ?? ""], as: JSONValue.self)
                segments = try await engine.call("segments")
                await afterEdit(namesChanged: true)
            }
    }

    // MARK: Language

    func requestSetLanguage() {
        guard let program else { return }
        formRequest = FormRequest(
            title: tr("Cambiar el lenguaje del programa"),
            message: tr("Ghidra vuelve a interpretar las instrucciones con el procesador nuevo. Actual: %@", program.language),
            fields: [FormField(key: "language", title: tr("Lenguaje"), value: program.language, placeholder: "x86:LE:64:default"),
                     FormField(key: "compiler", title: tr("Compilador (vacío: el predeterminado)"))],
            actionTitle: tr("Cambiar")) { [self] values in
                _ = try await engine.call("setLanguage", ["language": values["language"] ?? "", "compiler": values["compiler"] ?? ""],
                                          as: JSONValue.self)
                self.program = try await engine.call("info")
                await afterEdit(namesChanged: true)
            }
    }

    /// Opens the program tools window on one of its panels.
    func showTools(_ panel: String) {
        // a docked panel is shown where it is docked
        if dock.reveal(window: "", tool: panel) { return }
        toolsPanel = panel
        if dock.reveal(window: "program") { return }
        windowRequest = "program"
    }

    /// Forms asked for by a tool panel docked on its own, when no tools window is there to show them.
    var dockedFormBinding: Binding<FormRequest?> {
        Binding(get: { self.toolsHosts == 0 && self.formRequest?.origin == "tools" ? self.formRequest : nil },
                set: { if $0 == nil, self.formRequest?.origin == "tools" { self.formRequest = nil } })
    }
}
