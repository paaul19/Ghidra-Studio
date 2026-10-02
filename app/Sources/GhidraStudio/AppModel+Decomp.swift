import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Decompiler actions on the token under the cursor, secondary highlights and taint.
extension AppModel {
    private func tokenInfo(_ token: Int) async throws -> JSONRow {
        guard let fn = current?.function else { throw EngineError.remote(tr("Selecciona una función")) }
        return try await engine.call("tokenInfo", ["address": fn, "token": token])
    }

    /// What is selected in one view, so the others can mark the matching lines.
    func crossSelect(_ address: String, lines: [DecompLine]?) {
        if let lines {
            let all = lines.filter { $0.addr == address }.flatMap { $0.addrs ?? [address] }
            crossHighlight = Set(all.isEmpty ? [address] : all)
        } else {
            crossHighlight = [address]
        }
    }

    // MARK: Constants

    func requestConvertConstant(_ token: Int) {
        guard let fn = current?.function else { return }
        Task {
            do {
                let info = try await tokenInfo(token)
                guard info["scalar"] != nil else { throw EngineError.remote(tr("Coloca el cursor sobre una constante.")) }
                let formats = ConvertFormats.all
                formRequest = FormRequest(
                    title: tr("Convertir la constante %@", info["text"]?.text ?? ""),
                    fields: [FormField(key: "format", title: tr("Mostrar como"), kind: .choice(formats.map(\.1)), value: formats[0].1)],
                    actionTitle: tr("Convertir")) { [self] values in
                        let format = formats.first { $0.1 == values["format"] }?.0 ?? "unsignedHex"
                        try await edit("decompEquate", ["address": fn, "token": token, "format": format], namesChanged: false)
                    }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func requestEquateToken(_ token: Int) {
        guard let fn = current?.function else { return }
        Task {
            do {
                let info = try await tokenInfo(token)
                guard info["scalar"] != nil else { throw EngineError.remote(tr("Coloca el cursor sobre una constante.")) }
                formRequest = FormRequest(
                    title: tr("Equate para %@", info["text"]?.text ?? ""),
                    message: tr("Un nombre para este valor. Déjalo vacío para quitar el equate."),
                    fields: [FormField(key: "name", title: tr("Nombre"), value: info["equates"]?.array.first?.text ?? "")],
                    actionTitle: tr("Aplicar")) { [self] values in
                        try await edit("decompEquate", ["address": fn, "token": token, "name": values["name"] ?? ""], namesChanged: false)
                    }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Types

    func requestRetypeField(_ field: String) {
        let parts = field.split(separator: "|")
        guard parts.count == 2, let offset = Int(parts[1]) else { return }
        let owner = String(parts[0])
        formRequest = FormRequest(
            title: tr("Cambiar tipo del campo"),
            message: tr("Campo en el offset %@ de %@", String(format: "0x%x", offset), owner),
            fields: [FormField(key: "type", title: tr("Tipo nuevo"), placeholder: "int")],
            actionTitle: tr("Cambiar")) { [self] values in
                try await edit("retypeField", ["type": owner, "offset": offset, "newType": values["type"] ?? ""], namesChanged: false)
            }
    }

    func requestRetypeReturn() {
        guard let fn = current?.function else { return }
        formRequest = FormRequest(
            title: tr("Cambiar tipo de retorno"),
            fields: [FormField(key: "type", title: tr("Tipo"), value: functionDetails?.returnType ?? "", placeholder: "int")],
            actionTitle: tr("Cambiar")) { [self] values in
                try await edit("retypeReturn", ["address": fn, "type": values["type"] ?? ""], namesChanged: false)
            }
    }

    func requestAdjustPointer(_ variable: String) {
        guard let fn = current?.function else { return }
        formRequest = FormRequest(
            title: tr("Ajustar offset del puntero «%@»", variable),
            message: tr("Para un puntero que apunta dentro de una estructura: el descompilador mostrará los accesos como campos de ella."),
            fields: [FormField(key: "type", title: tr("Estructura"), placeholder: "MiEstructura"),
                     FormField(key: "offset", title: tr("Offset dentro de la estructura"), value: "0x0")],
            actionTitle: tr("Aplicar")) { [self] values in
                try await edit("adjustPointerOffset", ["address": fn, "name": variable, "type": values["type"] ?? "",
                                                       "offset": values["offset"] ?? "0"], namesChanged: false)
            }
    }

    func editTypeOfToken(_ token: Int) {
        Task {
            do {
                let info = try await tokenInfo(token)
                guard let path = info["fieldOwner"]?.string ?? info["type"]?.string else {
                    throw EngineError.remote(tr("Ese elemento no tiene un tipo de dato."))
                }
                typeToShow = path
                windowRequest = "types"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func usesOfTokenType(_ token: Int) {
        Task {
            do {
                let info = try await tokenInfo(token)
                if let owner = info["fieldOwner"]?.string {
                    mainTypeUses = TypeUsesRequest(path: owner, field: info["text"]?.text ?? "")
                } else if let path = info["type"]?.string {
                    mainTypeUses = TypeUsesRequest(path: path, field: "")
                } else {
                    throw EngineError.remote(tr("Ese elemento no tiene un tipo de dato."))
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeLabelOfToken(_ token: Int) {
        Task {
            do {
                let info = try await tokenInfo(token)
                guard let address = info["label"]?.string else { throw EngineError.remote(tr("Coloca el cursor sobre una etiqueta.")) }
                try await edit("deleteLabel", ["address": address, "name": info["text"]?.text ?? ""])
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Secondary highlight

    private static let secondaryPalette: [UInt32] = [0xff9f0a, 0xbf5af2, 0x64d2ff, 0xff375f, 0x30d158, 0x0a84ff, 0xffd60a]

    func toggleSecondary(_ word: String) {
        if secondaryHighlights[word] != nil {
            secondaryHighlights[word] = nil
        } else {
            let used = Set(secondaryHighlights.values)
            secondaryHighlights[word] = Self.secondaryPalette.first { !used.contains($0) }
                ?? Self.secondaryPalette[secondaryHighlights.count % Self.secondaryPalette.count]
        }
    }

    // MARK: Export and debug

    func exportFunctionC() {
        guard let d = decompilation else { return }
        let text = d.lines.map { String(repeating: "  ", count: $0.indent) + $0.tokens.map(\.t).joined() }.joined(separator: "\n") + "\n"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = d.function.replacingOccurrences(of: "::", with: "_") + ".c"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { errorMessage = error.localizedDescription }
    }

    func debugDecompile() {
        guard let fn = current?.function else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "decompile_debug_\(fn).xml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let _: JSONRow = try await engine.call("decompDebug", ["address": fn, "path": url.path])
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Taint

    func toggleTaint(_ name: String, source: Bool) {
        if source {
            if taintSources.contains(name) { taintSources.remove(name) } else { taintSources.insert(name) }
        } else {
            if taintSinks.contains(name) { taintSinks.remove(name) } else { taintSinks.insert(name) }
        }
    }

    func clearTaint() {
        taintSources = []
        taintSinks = []
        taintReached = []
        sliceTokens = []
    }

    func runTaint() {
        guard let fn = current?.function else { return }
        Task {
            do {
                let result: JSONRow = try await engine.call("taint", ["address": fn, "sources": Array(taintSources),
                                                                     "sinks": Array(taintSinks), "depth": 4])
                sliceTokens = Set(result["tokens"]?.array.compactMap(\.int) ?? [])
                taintReached = result["reached"]?.array.map(\.object) ?? []
                if taintReached.isEmpty && sliceTokens.isEmpty {
                    errorMessage = tr("Las fuentes marcadas no llegan a ningún sitio en esta función.")
                } else {
                    showTools("taint")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Tool panels

/// Text search over the decompiled code of every function.
struct DecompSearchPanel: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var regex = false
    @State private var caseSensitive = false
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Buscar en el código descompilado de todo el programa")) {
                TextField(tr("Texto"), text: $query).textFieldStyle(.roundedBorder).frame(width: 240).font(.body.monospaced())
                    .onSubmit(search)
                Toggle(tr("Expresión regular"), isOn: $regex).toggleStyle(.checkbox)
                Toggle(tr("Mayúsculas"), isOn: $caseSensitive).toggleStyle(.checkbox)
                Button(tr("Buscar"), action: search).disabled(query.isEmpty || busy)
            }
            Divider()
            ZStack {
                GenericTable(rows: rows,
                             columns: [.address(), ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true),
                                       ColumnSpec(key: "line", title: tr("Línea"), width: 50),
                                       ColumnSpec(key: "text", title: tr("Código"), width: 560, mono: true)],
                             storageKey: "decompSearch", actions: [RowAction(title: tr("Ir")) { row in open(row) }],
                             onOpen: { row in open(row) })
                if busy { ProgressView(tr("Descompilando las funciones…")) }
            }
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private func open(_ row: JSONRow) {
        guard let address = row["address"]?.string else { return }
        model.viewMode = .decompiler
        model.go(address)
    }

    private func search() {
        guard !query.isEmpty else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                rows = try await model.engine.call("decompSearch", ["query": query, "regex": regex, "caseSensitive": caseSensitive])
                message = tr("%@ coincidencias", "\(rows.count)")
            } catch { message = error.localizedDescription }
        }
    }
}

/// Call-fixups, callother-fixups and calling conventions added to the program's compiler specification.
struct SpecExtensionsPanel: View {
    @Environment(AppModel.self) private var model

    private static let example = """
        <callfixup name="mi_fixup">
          <target name="__alloca_probe"/>
          <pcode>
            <body><![CDATA[
              RSP = RSP - RAX;
            ]]></body>
          </pcode>
        </callfixup>
        """

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Extensiones de la especificación del compilador")) {
                Button(tr("Añadir o reemplazar…")) { add(xml: Self.example) }
                Button(tr("Importar un XML…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.xml]
                    if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
                        add(xml: text)
                    }
                }
            }
            Divider()
            EngineTable(method: "specExtensions",
                        columns: [ColumnSpec(key: "type", title: tr("Clase"), width: 110),
                                  ColumnSpec(key: "name", title: tr("Nombre"), width: 220, mono: true),
                                  ColumnSpec(key: "source", title: tr("Origen"), width: 90),
                                  ColumnSpec(key: "xml", title: "XML", width: 520, mono: true)],
                        addressKey: nil,
                        actions: [RowAction(title: tr("Editar…")) { row in
                            guard row["source"]?.text == "program" else {
                                model.errorMessage = tr("Las que trae el compilador no se pueden cambiar; añade una con el mismo nombre.")
                                return
                            }
                            add(xml: row["xml"]?.text ?? "")
                        }, RowAction(title: tr("Exportar…")) { row in
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = (row["name"]?.text ?? "extension") + ".xml"
                            if panel.runModal() == .OK, let url = panel.url {
                                try? (row["xml"]?.text ?? "").write(to: url, atomically: true, encoding: .utf8)
                            }
                        }, RowAction(title: tr("Quitar"), destructive: true) { row in
                            guard row["source"]?.text == "program" else {
                                model.errorMessage = tr("Solo se pueden quitar las extensiones añadidas al programa.")
                                return
                            }
                            model.run("removeSpecExtension", ["key": row["key"]?.text ?? ""], namesChanged: false)
                        }])
        }
    }

    private func add(xml: String) {
        model.formRequest = FormRequest(
            title: tr("Extensión de especificación"),
            message: tr("XML de un callfixup, callotherfixup, prototype o resolveprototype. Ghidra lo valida antes de guardarlo."),
            fields: [FormField(key: "xml", title: "XML", kind: .multiline, value: xml)],
            actionTitle: tr("Guardar"), origin: "tools") { values in
                try await model.edit("addSpecExtension", ["xml": values["xml"] ?? ""], namesChanged: false)
            }
    }
}

/// Taint marks and what the last query reached.
struct TaintPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("taintEngine") private var engineKind = "studio"
    @AppStorage("ctadlPath") private var ctadlPath = ""
    @AppStorage("ctadlDirection") private var direction = ""
    @AppStorage("ctadlAllAccess") private var allAccess = false
    @State private var status: JSONRow?
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Taint") {
                if busy { ProgressView().controlSize(.small) }
                Picker("", selection: $engineKind) {
                    Text(tr("Descompilador (integrado)")).tag("studio")
                    Text("CTADL").tag("ctadl")
                }
                .labelsHidden().fixedSize()
                if engineKind == "ctadl" {
                    Button(tr("Ejecutar la consulta")) { query(custom: nil) }
                        .disabled(busy || (model.taintSources.isEmpty && model.taintSinks.isEmpty))
                } else {
                    Button(tr("Ejecutar la consulta")) { model.runTaint() }.disabled(model.taintSources.isEmpty)
                }
                Button(tr("Borrar marcas")) { model.clearTaint(); rows = [] }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Fuentes: %@", model.taintSources.isEmpty ? "—" : model.taintSources.sorted().joined(separator: ", ")))
                Text(tr("Sumideros: %@", model.taintSinks.isEmpty ? "—" : model.taintSinks.sorted().joined(separator: ", ")))
                if engineKind == "ctadl" {
                    ctadlControls
                } else {
                    Text(tr("Marca variables como fuente y variables o funciones llamadas como sumidero desde el menú contextual del descompilador. La consulta sigue el dato dentro de la función y por las llamadas, hasta cuatro niveles."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(5).textSelection(.enabled) }
            }
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            Divider()
            if engineKind == "ctadl" {
                GenericTable(rows: rows, columns: [
                    .address(), ColumnSpec(key: "rule", title: tr("Regla"), width: 110, mono: true),
                    ColumnSpec(key: "kind", title: tr("Clase"), width: 80), ColumnSpec(key: "level", title: tr("Nivel"), width: 80),
                    ColumnSpec(key: "message", title: tr("Mensaje"), width: 380), ColumnSpec(key: "location", title: tr("Lugar"), width: 160),
                ], storageKey: "taintCtadl",
                             onOpen: { row in if let a = row["address"]?.string, !a.isEmpty { model.viewMode = .decompiler; model.go(a) } })
            } else {
                GenericTable(rows: model.taintReached.map { row in
                    var r = row
                    r["kindText"] = .string(Self.kind(row["kind"]?.text ?? ""))
                    return r
                }, columns: [.address(), ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true),
                             ColumnSpec(key: "kindText", title: tr("Clase"), width: 140),
                             ColumnSpec(key: "what", title: tr("Llega a"), width: 320, mono: true)],
                             storageKey: "taint",
                             onOpen: { row in if let a = row["address"]?.string { model.viewMode = .decompiler; model.go(a) } })
            }
        }
        .task(id: "\(engineKind)|\(ctadlPath)|\(model.activeSession ?? "")") { await refreshStatus() }
    }

    @ViewBuilder private var ctadlControls: some View {
        HStack(spacing: 8) {
            Text(ctadlPath.isEmpty ? tr("Sin ejecutable de CTADL") : ctadlPath)
                .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                .foregroundStyle(status?["engine"]?.bool == true ? Color.primary : Color.orange)
            Button(tr("Elegir CTADL…")) { chooseEngine() }
            Button(tr("Crear índice")) { index() }.disabled(busy || ctadlPath.isEmpty)
                .help(tr("Exporta el p-code de todo el programa y lo indexa con CTADL. Hay que repetirlo cuando cambie el análisis."))
        }
        .controlSize(.small)
        HStack(spacing: 8) {
            Picker(tr("Dirección"), selection: $direction) {
                Text(tr("Por defecto")).tag("")
                Text(tr("Hacia delante")).tag("fwd")
                Text(tr("Hacia atrás")).tag("bwd")
                Text(tr("Ambas")).tag("all")
            }
            .fixedSize()
            Toggle(tr("Todos los accesos (campos y punteros)"), isOn: $allAccess).toggleStyle(.checkbox)
            Button(tr("Consulta propia (.dl)…")) { chooseQuery() }.disabled(busy || status?["indexed"]?.bool != true)
            if let sarif = status?["directory"]?.string {
                Button(tr("Mostrar archivos")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sarif)]) }
            }
        }
        .controlSize(.small)
        Text(statusText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        guard let status else { return "" }
        let facts = status["facts"]?.int ?? 0
        let indexed = status["indexed"]?.bool == true
        return (indexed ? tr("Índice creado (%@ archivos de hechos).", "\(facts)") : tr("Este programa todavía no tiene índice."))
            + " " + tr("CTADL es el motor externo que usa Ghidra clásico; se instala aparte (pip install ctadl).")
    }

    private func refreshStatus() async {
        guard engineKind == "ctadl", model.program != nil else { return }
        status = try? await model.engine.call("ctadlStatus", ["engine": ctadlPath])
    }

    private func chooseEngine() {
        let panel = NSOpenPanel()
        panel.title = tr("Ejecutable de CTADL")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { ctadlPath = url.path }
    }

    private func chooseQuery() {
        let panel = NSOpenPanel()
        panel.title = tr("Consulta de Datalog")
        if let path = status?["query"]?.string { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { query(custom: url.path) }
    }

    private func index() {
        busy = true
        message = nil
        Task {
            do { status = try await model.engine.call("ctadlIndex", ["engine": ctadlPath]) }
            catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func query(custom: String?) {
        guard let fn = model.current?.function ?? model.current?.address else { return }
        busy = true
        message = nil
        Task {
            do {
                let result: JSONRow = try await model.engine.call("ctadlQuery", [
                    "engine": ctadlPath, "address": fn, "sources": Array(model.taintSources), "sinks": Array(model.taintSinks),
                    "direction": direction, "allAccess": allAccess, "custom": custom ?? "",
                ])
                rows = result["rows"]?.array.map(\.object) ?? []
                // paint the lines the results fall on, like the slices of the built-in engine
                let found = rows.compactMap { $0["address"]?.string }.filter { !$0.isEmpty }
                model.setSelection(ranges: found.map { [$0, $0] })
                if rows.isEmpty { message = tr("La consulta no ha dado resultados.") }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private static func kind(_ kind: String) -> String {
        switch kind {
        case "sink": tr("Sumidero alcanzado")
        case "return": tr("Valor devuelto")
        default: tr("Argumento de llamada")
        }
    }
}
