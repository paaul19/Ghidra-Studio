import AppKit
import SwiftUI

// MARK: - Memory scan

/// Ghidra's memory search with its filters and scan mode: search once, then keep the hits whose value
/// stayed, changed, went up or went down.
struct MemoryScanPanel: View {
    @Environment(AppModel.self) private var model
    @State private var kind = "hex"
    @State private var text = ""
    @State private var size = 4
    @State private var encoding = "ascii"
    @State private var blocks = Set<String>()
    @State private var instructions = true
    @State private var data = true
    @State private var undefined = true
    @State private var align = 1
    @State private var selectionOnly = false
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Búsqueda en memoria con filtros y exploración")) {
                Picker("", selection: $kind) {
                    Text(tr("Bytes hex")).tag("hex")
                    Text("Decimal").tag("decimal")
                    Text("Float").tag("float")
                    Text("Double").tag("double")
                    Text(tr("Cadena")).tag("string")
                }
                .labelsHidden().fixedSize()
                TextField(kind == "hex" ? "48 8b ?? 05" : tr("Valor"), text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: 200).font(.body.monospaced())
                    .onSubmit { search() }
                if kind == "decimal" {
                    Picker("", selection: $size) { ForEach([1, 2, 4, 8], id: \.self) { Text(tr("%@ bytes", "\($0)")).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                if kind == "string" {
                    Picker("", selection: $encoding) { ForEach(["ascii", "utf8", "utf16", "utf32"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                Button(tr("Buscar")) { search() }.disabled(text.isEmpty || busy)
            }
            HStack(spacing: 10) {
                Menu(blocks.isEmpty ? tr("Todos los bloques") : tr("%@ bloques", "\(blocks.count)")) {
                    Button(tr("Todos los bloques")) { blocks = [] }
                    Divider()
                    ForEach(model.segments) { seg in
                        Toggle(seg.name, isOn: Binding(get: { blocks.contains(seg.name) }, set: { on in
                            if on { blocks.insert(seg.name) } else { blocks.remove(seg.name) }
                        }))
                    }
                }
                .fixedSize()
                Toggle(tr("Instrucciones"), isOn: $instructions).toggleStyle(.checkbox)
                Toggle(tr("Datos"), isOn: $data).toggleStyle(.checkbox)
                Toggle(tr("Sin definir"), isOn: $undefined).toggleStyle(.checkbox)
                Picker(tr("Alineación"), selection: $align) { ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) } }
                    .fixedSize()
                Toggle(tr("Solo en la selección"), isOn: $selectionOnly).toggleStyle(.checkbox)
                    .disabled(model.programSelection == nil)
                Spacer()
                Text(tr("Explorar:")).foregroundStyle(.secondary)
                Button("=") { rescan("equal") }.help(tr("Conservar los que siguen igual"))
                Button("≠") { rescan("changed") }.help(tr("Conservar los que cambiaron"))
                Button("↑") { rescan("increased") }.help(tr("Conservar los que aumentaron"))
                Button("↓") { rescan("decreased") }.help(tr("Conservar los que disminuyeron"))
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .disabled(busy)
            Divider()
            ZStack {
                GenericTable(rows: rows,
                             columns: [.address(), ColumnSpec(key: "bytes", title: tr("Valor"), width: 200, mono: true),
                                       ColumnSpec(key: "previous", title: tr("Valor anterior"), width: 200, mono: true),
                                       ColumnSpec(key: "block", title: tr("Bloque"), width: 110),
                                       ColumnSpec(key: "kindText", title: tr("Clase"), width: 100),
                                       ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true)],
                             storageKey: "memScan")
                if busy { ProgressView() }
            }
            Divider()
            Text(message ?? tr("Los botones de exploración vuelven a leer la memoria y filtran los resultados: útil tras parchear, emular o depurar."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private static func kindText(_ kind: String) -> String {
        switch kind {
        case "instructions": tr("Instrucción")
        case "data": tr("Dato")
        default: tr("Sin definir")
        }
    }

    private func search() {
        guard !text.isEmpty else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                var pattern = text
                if kind != "hex" {
                    pattern = try await model.engine.call("encodePattern", ["kind": kind, "text": text, "size": size, "encoding": encoding])
                }
                var types: [String] = []
                if instructions { types.append("instructions") }
                if data { types.append("data") }
                if undefined { types.append("undefined") }
                var params: [String: Any] = ["pattern": pattern, "blocks": Array(blocks), "codeTypes": types.count == 3 ? [] : types,
                                             "align": align]
                if selectionOnly, let selection = model.programSelection { params["ranges"] = selection.ranges }
                let found: [JSONRow] = try await model.engine.call("memScan", params)
                rows = found.map { row in
                    var r = row
                    r["kindText"] = .string(Self.kindText(row["kind"]?.text ?? ""))
                    r["previous"] = .string("")
                    return r
                }
                message = tr("%@ resultados · patrón %@", "\(rows.count)", pattern)
            } catch { message = error.localizedDescription }
        }
    }

    private func rescan(_ comparison: String) {
        guard !rows.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let width = max(1, (rows[0]["bytes"]?.text ?? "").split(separator: " ").count)
                let now: [String] = try await model.engine.call("readValues", ["addresses": rows.map { $0["address"]?.text ?? "" },
                                                                               "size": width])
                let big = model.program?.endian.lowercased().contains("big") == true
                func value(_ hex: String) -> UInt64 {
                    var bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                    if !big { bytes.reverse() }
                    return bytes.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
                }
                var kept: [JSONRow] = []
                for (i, row) in rows.enumerated() where i < now.count {
                    let before = row["bytes"]?.text ?? "", after = now[i]
                    let keep: Bool
                    switch comparison {
                    case "equal": keep = before == after
                    case "changed": keep = before != after
                    case "increased": keep = value(after) > value(before)
                    default: keep = value(after) < value(before)
                    }
                    if keep {
                        var r = row
                        r["previous"] = .string(before)
                        r["bytes"] = .string(after)
                        kept.append(r)
                    }
                }
                let total = rows.count
                rows = kept
                message = tr("Quedan %@ de %@", "\(kept.count)", "\(total)")
            } catch { message = error.localizedDescription }
        }
    }
}

// MARK: - Direct references

/// Bytes in memory that are the address of the selection (or of the current function or data), not yet references.
struct DirectReferencesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var align = 1
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Referencias directas a la selección o a la dirección actual")) {
                Picker(tr("Alineación"), selection: $align) { ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
                Button(tr("Buscar")) { search() }.disabled(busy || model.editTarget == nil)
            }
            Divider()
            ZStack {
                GenericTable(rows: rows,
                             columns: [.address(tr("Desde")), .address(tr("Hacia"), key: "to"),
                                       ColumnSpec(key: "label", title: tr("Etiqueta"), width: 200, mono: true),
                                       ColumnSpec(key: "block", title: tr("Bloque"), width: 110),
                                       ColumnSpec(key: "kind", title: tr("Clase"), width: 100),
                                       ColumnSpec(key: "known", title: tr("Ya es referencia"), width: 110)],
                             storageKey: "directRefs",
                             actions: [RowAction(title: tr("Crear puntero aquí")) { row in
                                 model.run("createData", ["address": row["address"]?.text ?? "", "type": "pointer"], namesChanged: false)
                             }, RowAction(title: tr("Crear referencia")) { row in
                                 model.run("addReferenceEx", ["address": row["address"]?.text ?? "", "to": row["to"]?.text ?? "",
                                                              "kind": "memory", "type": "DATA", "operand": 0], namesChanged: false)
                             }])
                if busy { ProgressView() }
            }
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private func search() {
        busy = true
        Task {
            defer { busy = false }
            do {
                var params = model.target
                params["align"] = align
                rows = try await model.engine.call("directReferences", params)
                message = tr("%@ resultados", "\(rows.count)")
            } catch { message = error.localizedDescription }
        }
    }
}

// MARK: - Saved instruction patterns

struct SavedPattern: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var pattern: String
}

/// Instruction patterns kept between sessions, searched in one or in every open program.
struct InstructionPatternsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var patterns: [SavedPattern] = []
    @State private var selected: SavedPattern.ID?
    @State private var count = 3
    @State private var maskOperands = true
    @State private var everywhere = false
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Patrones de instrucciones guardados")) {
                Stepper(tr("%@ instrucciones", "\(count)"), value: $count, in: 1...16).fixedSize()
                Toggle(tr("Ignorar operandos"), isOn: $maskOperands).toggleStyle(.checkbox)
                Button(tr("Guardar el patrón del cursor…")) { capture() }.disabled(model.editTarget == nil)
            }
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(patterns, selection: $selected) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.pattern).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(p.id)
                        .contextMenu {
                            Button(tr("Borrar"), role: .destructive) { patterns.removeAll { $0.id == p.id }; save() }
                        }
                    }
                    Divider()
                    HStack {
                        Toggle(tr("En todos los programas abiertos"), isOn: $everywhere).toggleStyle(.checkbox)
                        Spacer()
                        Button(tr("Buscar")) { search() }.disabled(selected == nil || busy)
                    }
                    .controlSize(.small)
                    .padding(8)
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                ZStack {
                    GenericTable(rows: rows,
                                 columns: [ColumnSpec(key: "program", title: tr("Programa"), width: 140), .address(),
                                           ColumnSpec(key: "bytes", title: "Bytes", width: 260, mono: true),
                                           ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true)],
                                 storageKey: "savedPatterns", addressKey: nil,
                                 onOpen: { row in
                                     if let session = row["session"]?.string, session != model.activeSession { model.activate(session) }
                                     if let address = row["address"]?.string { model.go(address) }
                                 })
                    if busy { ProgressView() }
                }
            }
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: "instructionPatterns"),
               let list = try? JSONDecoder().decode([SavedPattern].self, from: data) { patterns = list }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(patterns) { UserDefaults.standard.set(data, forKey: "instructionPatterns") }
    }

    private func capture() {
        guard let address = model.editTarget else { return }
        Task {
            do {
                let result: JSONRow = try await model.engine.call("instructionPattern", ["address": address, "count": count,
                                                                                         "maskOperands": maskOperands])
                let pattern = result["pattern"]?.text ?? ""
                model.formRequest = FormRequest(
                    title: tr("Guardar patrón"),
                    message: pattern,
                    fields: [FormField(key: "name", title: tr("Nombre"), value: model.functionDetails?.name ?? address, mono: false)],
                    actionTitle: tr("Guardar"), origin: "tools") { values in
                        let item = SavedPattern(name: values["name"] ?? address, pattern: pattern)
                        patterns.append(item)
                        selected = item.id
                        save()
                    }
            } catch { message = error.localizedDescription }
        }
    }

    private func search() {
        guard let p = patterns.first(where: { $0.id == selected }) else { return }
        busy = true
        Task {
            defer { busy = false }
            var all: [JSONRow] = []
            let sessions = everywhere ? model.tabs.map { ($0.id, $0.name) }
                : model.tabs.filter { $0.id == model.activeSession }.map { ($0.id, $0.name) }
            for (id, name) in sessions {
                // patterns are stored with "." for masked nibbles: whole bytes become wildcards
                let pattern = p.pattern.split(separator: " ").map { $0.contains(".") || $0.contains("?") ? "??" : String($0) }
                    .joined(separator: " ")
                let found: [JSONRow] = (try? await model.engine.call("memScan", ["pattern": pattern, "session": id,
                                                                                 "codeTypes": ["instructions"]])) ?? []
                all += found.map { row in
                    var r = row
                    r["program"] = .string(name)
                    r["session"] = .string(id)
                    return r
                }
            }
            rows = all
            message = tr("%@ resultados en %@ programas", "\(all.count)", "\(sessions.count)")
        }
    }
}

// MARK: - Program tables

/// Ghidra's Defined Data window.
struct DataTablePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EngineTable(method: "dataTable",
                    columns: [.address(), ColumnSpec(key: "label", title: tr("Etiqueta"), width: 200, mono: true),
                              ColumnSpec(key: "type", title: tr("Tipo"), width: 160, mono: true),
                              ColumnSpec(key: "size", title: tr("Tamaño"), width: 60),
                              ColumnSpec(key: "value", title: tr("Valor"), width: 300, mono: true),
                              ColumnSpec(key: "block", title: tr("Bloque"), width: 110),
                              ColumnSpec(key: "references", title: tr("Referencias"), width: 80)],
                    actions: [RowAction(title: tr("Borrar el dato"), destructive: true) { row in
                        model.run("clear", ["address": row["address"]?.text ?? ""], namesChanged: false)
                    }])
    }
}

/// Ghidra's Functions window, with "compare selected".
struct FunctionTablePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EngineTable(method: "functionTable",
                    columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 220, mono: true), .address(),
                              ColumnSpec(key: "signature", title: tr("Firma"), width: 320, mono: true),
                              ColumnSpec(key: "size", title: tr("Tamaño"), width: 60),
                              ColumnSpec(key: "callers", title: tr("Referencias"), width: 80),
                              ColumnSpec(key: "params", title: tr("Parámetros"), width: 80),
                              ColumnSpec(key: "locals", title: tr("Locales"), width: 60),
                              ColumnSpec(key: "convention", title: tr("Convención"), width: 100),
                              ColumnSpec(key: "tags", title: tr("Etiquetas"), width: 140),
                              ColumnSpec(key: "thunk", title: "Thunk", width: 50),
                              ColumnSpec(key: "noReturn", title: tr("No retorna"), width: 70),
                              ColumnSpec(key: "inline", title: "Inline", width: 50),
                              ColumnSpec(key: "varargs", title: "Varargs", width: 60),
                              ColumnSpec(key: "customStorage", title: tr("Almacenamiento propio"), width: 120),
                              ColumnSpec(key: "block", title: tr("Bloque"), width: 100)],
                    multiActions: [MultiAction(title: tr("Comparar las elegidas"), minimum: 2) { rows in
                        model.compareRequest = rows.compactMap { $0["address"]?.string }
                        model.windowRequest = "funccompare"
                    }])
    }
}

// MARK: - Strings and translation

struct StringsPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libreTranslateURL") private var server = "http://localhost:5000"
    @AppStorage("libreTranslateTarget") private var target = "es"
    @AppStorage("libreTranslateKey") private var apiKey = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Cadenas y su traducción")) {
                Text("LibreTranslate").font(.caption).foregroundStyle(.secondary)
                TextField("http://localhost:5000", text: $server).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField(tr("idioma"), text: $target).textFieldStyle(.roundedBorder).frame(width: 46)
                    .help(tr("Código del idioma de destino: es, en, fr…"))
                if busy { ProgressView().controlSize(.small) }
            }
            Divider()
            EngineTable(method: "stringTable",
                        columns: [.address(), ColumnSpec(key: "value", title: tr("Cadena"), width: 320, mono: true),
                                  ColumnSpec(key: "translation", title: tr("Traducción"), width: 280),
                                  ColumnSpec(key: "showTranslated", title: tr("Se muestra"), width: 80),
                                  ColumnSpec(key: "type", title: tr("Tipo"), width: 90),
                                  ColumnSpec(key: "charset", title: "Charset", width: 90),
                                  ColumnSpec(key: "length", title: tr("Tamaño"), width: 60),
                                  ColumnSpec(key: "references", title: tr("Referencias"), width: 80)],
                        actions: [RowAction(title: tr("Traducir a mano…")) { row in manual(row) },
                                  RowAction(title: tr("Mostrar u ocultar la traducción")) { row in
                                      apply([row["address"]?.text ?? "": NSNull()], show: !(row["showTranslated"]?.bool ?? false))
                                  },
                                  RowAction(title: tr("Quitar la traducción"), destructive: true) { row in
                                      apply([row["address"]?.text ?? "": ""], show: nil)
                                  },
                                  RowAction(title: tr("Ajustes de la cadena (charset…)")) { row in
                                      if let a = row["address"]?.string { model.go(a) }
                                      model.showTools("data")
                                  }],
                        multiActions: [MultiAction(title: tr("Traducir con LibreTranslate")) { rows in translate(rows) }])
            Divider()
            Text(message ?? tr("LibreTranslate es un servidor de traducción que instalas tú; las cadenas elegidas se envían a la dirección indicada."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func manual(_ row: JSONRow) {
        let address = row["address"]?.text ?? ""
        model.formRequest = FormRequest(
            title: tr("Traducción de la cadena en %@", address),
            message: row["value"]?.text,
            fields: [FormField(key: "text", title: tr("Traducción (vacío la quita)"), value: row["translation"]?.text ?? "", mono: false)],
            actionTitle: tr("Guardar"), origin: "tools") { values in
                try await model.edit("translate", ["translations": [address: values["text"] ?? ""]], namesChanged: false)
            }
    }

    private func apply(_ translations: [String: Any], show: Bool?) {
        var params: [String: Any] = ["translations": translations]
        if let show { params["show"] = show }
        model.run("translate", params, namesChanged: false)
    }

    /// Sends the chosen strings to the LibreTranslate server the user configured.
    private func translate(_ rows: [JSONRow]) {
        guard let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/translate") else {
            message = tr("Dirección del servidor inválida")
            return
        }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            var done: [String: Any] = [:]
            for row in rows.prefix(500) {
                guard let address = row["address"]?.string, let text = row["value"]?.string, !text.isEmpty else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = ["q": text, "source": "auto", "target": target, "format": "text"]
                if !apiKey.isEmpty { body["api_key"] = apiKey }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let translated = object["translatedText"] as? String { done[address] = translated }
                        else if let error = object["error"] as? String { message = error; break }
                    }
                } catch {
                    message = tr("No se pudo conectar con LibreTranslate: %@", error.localizedDescription)
                    break
                }
            }
            if !done.isEmpty {
                apply(done, show: nil)
                if message == nil { message = tr("%@ cadenas traducidas", "\(done.count)") }
            }
        }
    }
}

// MARK: - Embedded media

struct MediaPanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var preview: NSImage?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Imágenes y sonidos dentro del programa")) {
                Button(tr("Buscar")) { load() }.disabled(busy)
            }
            Divider()
            HSplitView {
                ZStack {
                    GenericTable(rows: rows,
                                 columns: [.address(), ColumnSpec(key: "kind", title: tr("Clase"), width: 120),
                                           ColumnSpec(key: "length", title: tr("Tamaño"), width: 80),
                                           ColumnSpec(key: "defined", title: tr("Definido como dato"), width: 120)],
                                 storageKey: "media",
                                 actions: [RowAction(title: tr("Ver")) { row in show(row) },
                                           RowAction(title: tr("Guardar…")) { row in saveAs(row) }],
                                 onOpen: { row in show(row); if let a = row["address"]?.string { model.go(a) } })
                    if busy { ProgressView() }
                }
                .frame(minWidth: 380)
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.none).aspectRatio(contentMode: .fit).padding(16)
                    } else {
                        Text(tr("Elige una imagen para verla")).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 240)
            }
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .task(id: model.activeSession) { load() }
    }

    private func load() {
        busy = true
        Task {
            defer { busy = false }
            do {
                rows = try await model.engine.call("mediaTable")
                message = tr("%@ encontrados", "\(rows.count)")
            } catch { message = error.localizedDescription }
        }
    }

    private func write(_ row: JSONRow, to path: String) async throws {
        _ = try await model.engine.call("saveBytes", ["address": row["address"]?.text ?? "", "length": row["length"]?.int ?? 0,
                                                      "path": path], as: JSONValue.self)
    }

    private func show(_ row: JSONRow) {
        let path = NSTemporaryDirectory() + "studio-media-\(UUID().uuidString).\(row["extension"]?.text ?? "bin")"
        Task {
            do {
                try await write(row, to: path)
                preview = NSImage(contentsOfFile: path)
                try? FileManager.default.removeItem(atPath: path)
                if preview == nil { message = tr("No es una imagen que se pueda mostrar; puedes guardarla.") }
            } catch { message = error.localizedDescription }
        }
    }

    private func saveAs(_ row: JSONRow) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(row["address"]?.text ?? "media").\(row["extension"]?.text ?? "bin")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await write(row, to: url.path) } catch { message = error.localizedDescription }
        }
    }
}

// MARK: - Source path transforms and viewer

/// Maps the build machine's source paths to local ones, and shows a source file at a line.
struct SourceTransformsView: View {
    @Environment(AppModel.self) private var model
    /// Path (as recorded in the program) of the file to show.
    let file: String?
    let line: Int?
    @State private var transforms: [JSONRow] = []
    @State private var text: [String] = []
    @State private var localPath = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Rutas de fuentes: %@ transformaciones", "\(transforms.count)")).font(.caption.weight(.semibold))
                Spacer()
                Button(tr("Carpeta → carpeta local…")) { addDirectory() }
                if let file {
                    Button(tr("Este archivo → archivo local…")) { addFile(file) }
                }
            }
            .controlSize(.small)
            .padding(8)
            if !transforms.isEmpty {
                ForEach(transforms, id: \.self) { t in
                    HStack {
                        Image(systemName: t["kind"]?.text == "directory" ? "folder" : "doc")
                        Text("\(t["source"]?.text ?? "")  →  \(t["target"]?.text ?? "")").font(.caption.monospaced()).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(tr("Quitar")) {
                            set(kind: t["kind"]?.text ?? "file", source: t["source"]?.text ?? "", target: "")
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 2)
                }
            }
            Divider()
            if text.isEmpty {
                Text(message ?? tr("Elige un archivo fuente para verlo aquí."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(text.enumerated()), id: \.offset) { i, content in
                                HStack(spacing: 8) {
                                    Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                        .frame(width: 40, alignment: .trailing)
                                    Text(content.isEmpty ? " " : content).font(.system(size: 12, design: .monospaced))
                                    Spacer(minLength: 0)
                                }
                                .background(i + 1 == line ? Color.accentColor.opacity(0.25) : Color.clear)
                                .id(i + 1)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: line) { _, l in if let l { proxy.scrollTo(l, anchor: .center) } }
                    .onAppear { if let line { proxy.scrollTo(line, anchor: .center) } }
                }
                .background(Color(nsColor: Theme.background))
            }
        }
        .task(id: "\(file ?? "")|\(model.activeSession ?? "")") { await reload() }
    }

    private func reload() async {
        transforms = (try? await model.engine.call("sourceTransforms")) ?? []
        text = []
        guard let file else { return }
        do {
            let info: JSONRow = try await model.engine.call("localSourcePath", ["path": file])
            localPath = info["path"]?.text ?? file
            if info["exists"]?.bool == true, let content = try? String(contentsOfFile: localPath, encoding: .utf8) {
                text = content.components(separatedBy: "\n")
                message = nil
            } else {
                message = tr("No existe %@ en este Mac. Añade una transformación de ruta para indicar dónde está.", localPath)
            }
        } catch { message = error.localizedDescription }
    }

    private func set(kind: String, source: String, target: String) {
        Task {
            do {
                transforms = try await model.engine.call("setSourceTransform", ["kind": kind, "source": source, "target": target])
                await reload()
            } catch { message = error.localizedDescription }
        }
    }

    private func addDirectory() {
        let start = file.map { ($0 as NSString).deletingLastPathComponent + "/" } ?? "/"
        model.formRequest = FormRequest(
            title: tr("Transformar una carpeta de fuentes"),
            message: tr("Todo lo que esté bajo la carpeta original se buscará bajo la carpeta local."),
            fields: [FormField(key: "source", title: tr("Carpeta original (acaba en /)"), value: start),
                     FormField(key: "target", title: tr("Carpeta local"), placeholder: "/Users/yo/src/")],
            actionTitle: tr("Añadir"), origin: "tools") { values in
                var source = values["source"] ?? "/"
                if !source.hasSuffix("/") { source += "/" }
                transforms = try await model.engine.call("setSourceTransform", ["kind": "directory", "source": source,
                                                                                "target": values["target"] ?? ""])
                await reload()
            }
    }

    private func addFile(_ file: String) {
        let panel = NSOpenPanel()
        panel.message = tr("Elige el archivo local que corresponde a %@", (file as NSString).lastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(kind: "file", source: file, target: url.path)
    }
}
