import AppKit
import SwiftUI

// MARK: - Program tools window

/// One entry of the program tools window.
struct ToolPanel: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let group: String

    static var all: [ToolPanel] {
        [
            ToolPanel(id: "labels", title: tr("Etiquetas e historial"), symbol: "tag", group: tr("En el cursor")),
            ToolPanel(id: "references", title: tr("Referencias"), symbol: "arrow.turn.down.right", group: tr("En el cursor")),
            ToolPanel(id: "instruction", title: tr("Instrucción"), symbol: "cpu", group: tr("En el cursor")),
            ToolPanel(id: "data", title: tr("Ajustes del dato"), symbol: "tablecells", group: tr("En el cursor")),
            ToolPanel(id: "function", title: tr("Extras de la función"), symbol: "f.cursive", group: tr("En el cursor")),
            ToolPanel(id: "stack", title: tr("Marco de pila"), symbol: "square.stack.3d.up", group: tr("En el cursor")),
            ToolPanel(id: "namespaces", title: "Namespaces", symbol: "folder", group: tr("Programa")),
            ToolPanel(id: "externals", title: tr("Externos"), symbol: "shippingbox", group: tr("Programa")),
            ToolPanel(id: "tree", title: tr("Árbol del programa"), symbol: "list.bullet.indent", group: tr("Programa")),
            ToolPanel(id: "options", title: tr("Opciones y propiedades"), symbol: "slider.horizontal.3", group: tr("Programa")),
            ToolPanel(id: "equates", title: "Equates", symbol: "number.circle", group: tr("Tablas")),
            ToolPanel(id: "comments", title: tr("Comentarios"), symbol: "text.bubble", group: tr("Tablas")),
            ToolPanel(id: "bookmarks", title: tr("Marcadores"), symbol: "bookmark", group: tr("Tablas")),
            ToolPanel(id: "registers", title: tr("Valores de registros"), symbol: "memorychip", group: tr("Tablas")),
            ToolPanel(id: "tags", title: tr("Etiquetas de función"), symbol: "tag.circle", group: tr("Tablas")),
            ToolPanel(id: "sources", title: tr("Ficheros fuente"), symbol: "doc.text", group: tr("Tablas")),
            ToolPanel(id: "dataTable", title: tr("Datos definidos"), symbol: "tablecells", group: tr("Tablas")),
            ToolPanel(id: "functionTable", title: tr("Funciones"), symbol: "f.cursive", group: tr("Tablas")),
            ToolPanel(id: "strings", title: tr("Cadenas y traducción"), symbol: "character.bubble", group: tr("Tablas")),
            ToolPanel(id: "media", title: tr("Imágenes y sonidos"), symbol: "photo", group: tr("Tablas")),
            ToolPanel(id: "sarif", title: tr("Resultados SARIF"), symbol: "doc.text.magnifyingglass", group: tr("Tablas")),
            ToolPanel(id: "validate", title: tr("Validar el programa"), symbol: "checkmark.seal", group: tr("Análisis")),
            ToolPanel(id: "fnPatterns", title: tr("Patrones de inicio de función"), symbol: "barcode", group: tr("Análisis")),
            ToolPanel(id: "debugFiles", title: tr("Archivos de depuración"), symbol: "ladybug", group: tr("Análisis")),
            ToolPanel(id: "memScan", title: tr("Memoria: filtros y exploración"), symbol: "memorychip", group: tr("Buscar")),
            ToolPanel(id: "directRefs", title: tr("Referencias directas"), symbol: "arrow.down.right.circle", group: tr("Buscar")),
            ToolPanel(id: "patterns", title: tr("Patrones de instrucciones"), symbol: "rectangle.and.text.magnifyingglass", group: tr("Buscar")),
            ToolPanel(id: "wildAsm", title: tr("Ensamblador con comodines"), symbol: "asterisk.circle", group: tr("Buscar")),
            ToolPanel(id: "decompSearch", title: tr("Buscar en el descompilado"), symbol: "text.magnifyingglass", group: tr("Descompilador")),
            ToolPanel(id: "specext", title: tr("Extensiones de especificación"), symbol: "puzzlepiece.extension", group: tr("Descompilador")),
            ToolPanel(id: "taint", title: "Taint", symbol: "drop", group: tr("Descompilador")),
            ToolPanel(id: "checksums", title: "Checksums", symbol: "sum", group: tr("Bytes")),
            ToolPanel(id: "database", title: tr("Base de datos"), symbol: "cylinder", group: tr("Sistema")),
            ToolPanel(id: "runtime", title: tr("Información de ejecución"), symbol: "info.circle", group: tr("Sistema")),
            ToolPanel(id: "entropy", title: tr("Entropía"), symbol: "waveform", group: tr("Bytes")),
        ]
    }
}

/// Everything about the program that is not the code itself: annotations at the cursor, tables, memory tools.
struct ProgramToolsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("toolsPanel") private var panel = "labels"

    var body: some View {
        let panels = ToolPanel.all
        let groups = panels.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        HStack(spacing: 0) {
            List(selection: Binding(get: { panel }, set: { if let v = $0 { panel = v } })) {
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(panels.filter { $0.group == group }) { item in
                            Label(item.title, systemImage: item.symbol).tag(item.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                if model.program == nil {
                    NoProgramView()
                } else {
                    ToolPanelContent(panel: panel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .windowMinSize(1040, 560)
        .sheet(item: model.formBinding("tools")) { request in FormSheet(request: request) }
        .onAppear {
            model.toolsHosts += 1
            if let wanted = model.toolsPanel { panel = wanted; model.toolsPanel = nil }
        }
        .onDisappear { model.toolsHosts = max(0, model.toolsHosts - 1) }
        .onChange(of: model.toolsPanel) { _, wanted in
            if let wanted { panel = wanted; model.toolsPanel = nil }
        }
    }
}

/// The view of one panel of the program tools, wherever it is shown (the tools window or a dock of the main window).
struct ToolPanelContent: View {
    let panel: String

    var body: some View {
        switch panel {
        case "labels": LabelsPanel()
        case "references": ReferencesPanel()
        case "instruction": InstructionPanel()
        case "data": DataSettingsPanel()
        case "function": FunctionExtrasPanel()
        case "stack": StackFramePanel()
        case "namespaces": NamespacesPanel()
        case "externals": ExternalsPanel()
        case "tree": ProgramTreePanel()
        case "options": ProgramOptionsPanel()
        case "equates": EquatesPanel()
        case "comments": CommentsPanel()
        case "bookmarks": BookmarksPanel()
        case "registers": RegisterValuesPanel()
        case "tags": FunctionTagsPanel()
        case "sources": SourceFilesPanel()
        case "sarif": SarifPanel()
        case "validate": ValidatorPanel()
        case "fnPatterns": FunctionPatternsPanel()
        case "debugFiles": DebugFilesPanel()
        case "dataTable": DataTablePanel()
        case "functionTable": FunctionTablePanel()
        case "strings": StringsPanel()
        case "media": MediaPanel()
        case "memScan": MemoryScanPanel()
        case "directRefs": DirectReferencesPanel()
        case "patterns": InstructionPatternsPanel()
        case "wildAsm": WildAssemblerPanel()
        case "decompSearch": DecompSearchPanel()
        case "specext": SpecExtensionsPanel()
        case "taint": TaintPanel()
        case "checksums": ChecksumsPanel()
        case "database": DatabasePanel()
        case "runtime": RuntimePanel()
        default: EntropyPanel()
        }
    }
}

/// Small helper shared by the panels: run an engine call and show the error at the bottom.
@MainActor
@Observable
private final class PanelStatus {
    var message: String?
    var failed = false
    var busy = false

    func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch {
                message = error.localizedDescription
                failed = true
            }
        }
    }

    func say(_ text: String?) {
        message = text
        failed = false
    }
}

private struct PanelFooter: View {
    let status: PanelStatus

    var body: some View {
        HStack {
            StatusLine(text: status.message, isError: status.failed)
            Spacer()
            if status.busy { ProgressView().controlSize(.small) }
        }
        .padding(10)
    }
}

// MARK: Namespaces

private struct NamespacesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var namespaces: [NamespaceItem] = []
    @State private var selected: Int64 = 0
    @State private var children: [NamespaceNode] = []
    @State private var newName = ""
    @State private var moving: NamespaceNode?
    @State private var status = PanelStatus()

    private var current: NamespaceItem? { namespaces.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(namespaces) { ns in
                                HStack(spacing: 6) {
                                    Button { selected = ns.id } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: ns.kind == "Class" ? "c.square" : ns.kind == "Global" ? "globe" : "curlybraces")
                                                .foregroundStyle(ns.kind == "Class" ? Color.teal : Color.secondary)
                                                .frame(width: 16)
                                            Text(ns.name).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 3).padding(.horizontal, 6)
                                        .background(selected == ns.id ? Color.accentColor.opacity(0.25) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if let moving, moving.id != ns.id {
                                        Button(tr("Mover aquí")) { move(moving, to: ns) }.controlSize(.small)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Crear dentro de «%@»", current?.name ?? "Global")).font(.caption.weight(.semibold))
                        TextField(tr("Nombre"), text: $newName).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Namespace") { create(isClass: false) }
                            Button(tr("Clase")) { create(isClass: true) }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || status.busy)
                    }
                    .padding(10)
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(current?.name ?? "Global").font(.headline)
                        Text(current?.kind ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let ns = current, ns.kind == "Namespace" {
                            Button(tr("Convertir en clase")) {
                                status.run {
                                    _ = try await model.engine.call("convertToClass", ["id": ns.id], as: Bool.self)
                                    await reload()
                                }
                            }
                        }
                        if let ns = current, ns.id != 0 {
                            Button(tr("Borrar")) {
                                status.run {
                                    _ = try await model.engine.call("deleteSymbol", ["id": ns.id], as: Bool.self)
                                    selected = 0
                                    await reload()
                                }
                            }
                            .help(tr("Solo se puede borrar si está vacío"))
                        }
                    }
                    .padding(10)
                    if let moving {
                        HStack {
                            Label(tr("Moviendo «%@»: pulsa «Mover aquí» en el namespace de destino.", moving.name),
                                  systemImage: "arrow.right.arrow.left")
                                .font(.callout)
                            Spacer()
                            Button(tr("Cancelar")) { self.moving = nil }.controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    Divider()
                    List(children) { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.kind == "Function" ? "f.cursive" : node.container ? "curlybraces" : "tag")
                                .foregroundStyle(node.kind == "Function" ? Color.purple : Color.secondary).frame(width: 16)
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                            Text(node.kind).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            if let a = node.address {
                                Button(a) { model.go(a) }.buttonStyle(.link).font(.caption.monospaced())
                            }
                            if !node.external {
                                Button(tr("Mover…")) { moving = node }.controlSize(.small)
                            }
                        }
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PanelFooter(status: status)
        }
        .task(id: "\(model.activeSession ?? "")|\(model.functions.count)") { await reload() }
        .onChange(of: selected) { _, _ in Task { await loadChildren() } }
    }

    private func reload() async {
        namespaces = (try? await model.engine.call("namespaces")) ?? []
        if !namespaces.contains(where: { $0.id == selected }) { selected = 0 }
        await loadChildren()
    }

    private func loadChildren() async {
        children = (try? await model.engine.call("namespaceChildren", ["id": selected])) ?? []
    }

    private func create(isClass: Bool) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        status.run {
            let created: CreatedNamespace = try await model.engine.call("createNamespace",
                                                                       ["parent": selected, "name": name, "class": isClass])
            newName = ""
            await reload()
            selected = created.id
            status.say(nil)
            await model.refreshUndo()
        }
    }

    private func move(_ node: NamespaceNode, to ns: NamespaceItem) {
        status.run {
            _ = try await model.engine.call("moveSymbol", ["id": node.id, "namespace": ns.id], as: Bool.self)
            moving = nil
            await reload()
            await model.refreshAfterEdits()
            status.say(tr("«%@» movido a %@.", node.name, ns.name))
        }
    }
}

// MARK: Externals

private struct ExternalsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var libraries: [ExternalLibrary] = []
    @State private var selected: String?
    @State private var path = ""
    @State private var editing: ExternalLocationItem?
    @State private var label = ""
    @State private var status = PanelStatus()

    private var current: ExternalLibrary? { libraries.first { $0.library == selected } }
    private var programs: [ProjectFile] {
        (model.project?.tree?.allFolders ?? []).flatMap(\.files).filter(\.program)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(libraries) { lib in
                            Button {
                                selected = lib.library
                                path = lib.path ?? ""
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lib.library).lineLimit(1).truncationMode(.middle)
                                    Text(lib.path.map { tr("→ %@", $0) } ?? tr("%@ símbolos · sin enlazar", "\(lib.locations.count)"))
                                        .font(.caption).foregroundStyle(lib.path == nil ? .secondary : Color.green)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(selected == lib.library ? Color.accentColor.opacity(0.25) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if libraries.isEmpty {
                            Text(tr("El programa no importa nada de librerías externas.")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    if let lib = current {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lib.library).font(.headline)
                            Text(tr("Enlázala con un programa del proyecto para poder saltar a sus funciones."))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField(tr("Ruta en el proyecto, p. ej. /libc.so"), text: $path).textFieldStyle(.roundedBorder)
                                Button(tr("Enlazar")) { link(lib, path) }.disabled(status.busy)
                                Button(tr("Quitar enlace")) { link(lib, "") }.disabled(lib.path == nil || status.busy)
                            }
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(programs) { f in
                                        Button(f.path) { path = f.path }.controlSize(.small)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        Divider()
                        List(lib.locations) { loc in
                            HStack {
                                Image(systemName: loc.function ? "f.cursive" : "tag").foregroundStyle(.secondary).frame(width: 16)
                                if editing?.id == loc.id {
                                    TextField(tr("Nombre"), text: $label).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                                    Button(tr("Guardar")) { rename(loc) }.controlSize(.small)
                                    Button(tr("Cancelar")) { editing = nil }.controlSize(.small)
                                } else {
                                    Text(loc.label ?? "—").monospaced()
                                    if let original = loc.original, original != loc.label {
                                        Text(original).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let a = loc.address { Text(a).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                if editing?.id != loc.id {
                                    Button(tr("Renombrar")) {
                                        editing = loc
                                        label = loc.label ?? ""
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(tr("Elige una librería"), systemImage: "building.columns")
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PanelFooter(status: status)
        }
        .task(id: model.activeSession) {
            libraries = (try? await model.engine.call("externals")) ?? []
            if selected == nil { selected = libraries.first { !$0.locations.isEmpty }?.library }
            path = current?.path ?? ""
        }
    }

    private func link(_ lib: ExternalLibrary, _ value: String) {
        status.run {
            libraries = try await model.engine.call("setExternalPath", ["library": lib.library, "path": value])
            status.say(nil)
            await model.refreshUndo()
        }
    }

    private func rename(_ loc: ExternalLocationItem) {
        let name = label.trimmingCharacters(in: .whitespaces)
        status.run {
            libraries = try await model.engine.call("editExternal", ["id": loc.id, "label": name])
            editing = nil
            status.say(nil)
            await model.refreshAfterEdits()
        }
    }
}

// MARK: Stack frame

private struct StackFramePanel: View {
    @Environment(AppModel.self) private var model
    @State private var frame: StackFrameInfo?
    @State private var offset = ""
    @State private var name = ""
    @State private var type = "int"
    @State private var status = PanelStatus()

    var body: some View {
        VStack(spacing: 0) {
            if let frame {
                HStack(spacing: 16) {
                    Text(frame.function).font(.headline)
                    Text(tr("Marco: %@ bytes", "\(frame.frameSize)"))
                    Text(tr("Locales: %@", "\(frame.localSize)"))
                    Text(tr("Parámetros: %@ (desde %@)", "\(frame.parameterSize)", "\(frame.parameterOffset)"))
                    Text(frame.growsNegative ? tr("crece hacia abajo") : tr("crece hacia arriba")).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .padding(10)
                Divider()
                List(frame.variables) { v in
                    HStack {
                        Text(String(format: "%@0x%x", v.offset < 0 ? "-" : "+", abs(v.offset)))
                            .font(.callout.monospaced()).frame(width: 80, alignment: .leading)
                        Text(v.name).monospaced().frame(width: 180, alignment: .leading).lineLimit(1)
                        Text(v.type).foregroundStyle(Color(nsColor: Theme.type)).lineLimit(1)
                        Text(tr("%@ bytes", "\(v.length)")).font(.caption).foregroundStyle(.secondary)
                        if v.parameter { Text(tr("parámetro")).font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
                        Spacer()
                        Button(tr("Editar")) {
                            offset = String(v.offset)
                            name = v.name
                            type = v.type
                        }
                        .controlSize(.small)
                        Button(tr("Borrar")) { clear(v) }.controlSize(.small)
                    }
                }
                Divider()
                HStack {
                    TextField(tr("Offset (p. ej. -0x20)"), text: $offset).textFieldStyle(.roundedBorder).frame(width: 150)
                        .font(.body.monospaced())
                    TextField(tr("Nombre"), text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    TextField(tr("Tipo (int, char[16], MiStruct *)"), text: $type).textFieldStyle(.roundedBorder)
                    Button(tr("Definir variable")) { define() }
                        .buttonStyle(.glassProminent)
                        .disabled(parsedOffset == nil || type.isEmpty || status.busy)
                }
                .padding(10)
            } else {
                ContentUnavailableView(tr("Sin función"), systemImage: "square.stack.3d.down.right",
                                       description: Text(tr("Coloca el cursor en una función en la ventana principal.")))
            }
            Divider()
            PanelFooter(status: status)
        }
        .task(id: "\(model.functionDetails?.entry ?? "")|\(model.undo?.undoName ?? "")") { await reload() }
    }

    private var parsedOffset: Int? {
        var text = offset.trimmingCharacters(in: .whitespaces).lowercased()
        var sign = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16).map { $0 * sign } }
        return Int(text).map { $0 * sign }
    }

    private func reload() async {
        guard let entry = model.functionDetails?.entry else { frame = nil; return }
        frame = try? await model.engine.call("stackFrame", ["address": entry])
    }

    private func define() {
        guard let entry = model.functionDetails?.entry, let off = parsedOffset else { return }
        status.run {
            frame = try await model.engine.call("stackDefine", ["address": entry, "offset": off, "name": name, "type": type])
            status.say(nil)
            await model.refreshAfterEdits()
        }
    }

    private func clear(_ v: StackVariable) {
        guard let entry = model.functionDetails?.entry else { return }
        status.run {
            frame = try await model.engine.call("stackClear", ["address": entry, "offset": v.offset])
            status.say(nil)
            await model.refreshAfterEdits()
        }
    }
}

// MARK: Checksums

private struct ChecksumsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var result: ChecksumResult?
    @State private var start = ""
    @State private var end = ""
    @State private var status = PanelStatus()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Desde (vacío = todo el programa)"), text: $start).textFieldStyle(.roundedBorder)
                    .font(.body.monospaced()).frame(width: 240)
                TextField(tr("Hasta"), text: $end).textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 180)
                Button(tr("Función actual")) {
                    if let f = model.functions.first(where: { $0.address == model.functionDetails?.entry }),
                       let a = addressValue(f.address) {
                        start = f.address
                        end = String(a + UInt64(max(1, f.size)) - 1, radix: 16)
                    }
                }
                .disabled(model.functionDetails == nil)
                Button(tr("Calcular")) { compute() }.buttonStyle(.glassProminent).disabled(status.busy)
                Spacer()
            }
            .padding(10)
            Divider()
            if let result {
                List(result.checksums) { row in
                    HStack {
                        Text(row.name).frame(width: 120, alignment: .leading)
                        Text(row.value).monospaced().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(tr("Copiar")) { model.copyToPasteboard(row.value) }.controlSize(.small)
                    }
                }
                Divider()
                HStack {
                    Text(tr("%@ bytes · %@", "\(result.bytes)", result.range ?? tr("toda la memoria inicializada")))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.top, 8)
            } else {
                Spacer()
            }
            PanelFooter(status: status)
        }
        .task(id: model.activeSession) { compute() }
    }

    private func compute() {
        status.run {
            var params: [String: Any] = [:]
            let s = start.trimmingCharacters(in: .whitespaces), e = end.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty {
                params["address"] = s
                params["end"] = e.isEmpty ? s : e
            }
            result = try await model.engine.call("checksums", params)
            status.say(nil)
        }
    }
}

// MARK: Entropy

private struct EntropyPanel: View {
    @Environment(AppModel.self) private var model
    @State private var blocks: [EntropyBlock] = []
    @State private var status = PanelStatus()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tr("Entropía por tramos (0 = datos repetidos, 8 = aleatorio). Valores cercanos a 8 suelen indicar datos comprimidos o cifrados. Haz clic en la gráfica para ir a esa zona."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(blocks) { block in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(block.block).font(.callout.weight(.semibold))
                                Text(block.start).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text(tr("media %@ · %@ bytes", String(format: "%.2f", block.average), "\(block.size)"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            EntropyChart(block: block) { address in model.go(address) }
                                .frame(height: 54)
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            PanelFooter(status: status)
        }
        .task(id: model.activeSession) {
            status.run { blocks = try await model.engine.call("entropy") }
        }
    }
}

private struct EntropyChart: View {
    let block: EntropyBlock
    let onPick: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = max(1, block.values.count)
                let w = size.width / CGFloat(n)
                for (i, v) in block.values.enumerated() {
                    let h = size.height * CGFloat(v / 8)
                    let rect = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(1, w - (w > 3 ? 1 : 0)), height: h)
                    let color: Color = v > 7.2 ? .red : v > 6 ? .orange : v > 3 ? .blue : .gray
                    ctx.fill(Path(rect), with: .color(color.opacity(0.85)))
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard let base = addressValue(block.start), geo.size.width > 0 else { return }
                let index = min(block.values.count - 1, max(0, Int(point.x / geo.size.width * CGFloat(block.values.count))))
                onPick(String(base + UInt64(index * block.chunk), radix: 16))
            }
        }
    }
}

// MARK: Source files

private struct SourceFilesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var files: [SourceFileItem] = []
    @State private var selected: String?
    @State private var lines: [SourceLine] = []
    @State private var shownLine: Int?

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView(tr("Sin información de ficheros fuente"), systemImage: "doc.text",
                                   description: Text(tr("El programa no tiene mapa de líneas. Aparece al importar binarios con DWARF o PDB que lo incluyan.")))
                .task(id: model.activeSession) { files = (try? await model.engine.call("sourceFiles")) ?? [] }
        } else {
            HSplitView {
                List(files) { f in
                    Button { selected = f.path } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name)
                            Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected == f.path ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                .frame(minWidth: 280, maxWidth: 420)
                List(lines) { l in
                    HStack {
                        Button(tr("línea %@", "\(l.line)")) { shownLine = l.line }.buttonStyle(.link)
                            .frame(width: 90, alignment: .leading)
                        Button(l.address) { model.go(l.address) }.buttonStyle(.link).font(.callout.monospaced())
                        Text(tr("%@ bytes", "\(l.length)")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .frame(minWidth: 220, maxWidth: 320)
                SourceTransformsView(file: selected, line: shownLine).frame(minWidth: 320)
            }
            .task(id: selected) {
                guard let selected else { lines = []; return }
                lines = (try? await model.engine.call("sourceLines", ["path": selected])) ?? []
            }
        }
    }
}

// MARK: - Sheets

/// Disassemble with a context-register preset (ARM/Thumb…) and/or restricted to the selection.
struct DisassembleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let start: String
    let end: String?
    @State private var registers: [ContextRegister] = []
    @State private var register = ""
    @State private var value = "1"
    @State private var restricted = false
    @State private var lastAddress = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Desensamblar con opciones")).font(.title3.weight(.semibold))
            Form {
                LabeledContent(tr("Desde"), value: start)
                TextField(tr("Hasta (opcional)"), text: $lastAddress).font(.body.monospaced())
                Toggle(tr("Restringido: no seguir el flujo fuera de este rango"), isOn: $restricted)
                TextField(tr("Registro de contexto (p. ej. TMode)"), text: $register).font(.body.monospaced())
                TextField(tr("Valor"), text: $value).font(.body.monospaced())
            }
            .formStyle(.grouped)
            if !registers.isEmpty {
                Text(tr("Registros de contexto de este procesador:")).font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(registers.filter(\.context).prefix(24)) { r in
                            Button(r.name) { register = r.name }.controlSize(.small)
                        }
                    }
                }
            }
            if let error { StatusLine(text: error, isError: true) }
            HStack {
                Spacer()
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Desensamblar")) { run() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            lastAddress = end ?? ""
            restricted = end != nil
            registers = (try? await model.engine.call("contextRegisters", ["address": start])) ?? []
        }
    }

    private func run() {
        Task {
            do {
                var params: [String: Any] = ["address": start, "restricted": restricted]
                let last = lastAddress.trimmingCharacters(in: .whitespaces)
                if !last.isEmpty { params["end"] = last }
                let reg = register.trimmingCharacters(in: .whitespaces)
                if !reg.isEmpty {
                    params["register"] = reg
                    params["value"] = value
                }
                _ = try await model.engine.call("disassembleEx", params, as: DisassembleResult.self)
                await model.refreshAfterEdits()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Pick which field of a union the decompiler should use at one access ("Force Field").
struct UnionFieldSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let function: String
    let token: Int
    @State private var choices: UnionChoices?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Forzar campo de unión")).font(.title3.weight(.semibold))
            if let choices {
                Text(tr("Unión %@ · ahora se muestra como «%@». Elige el campo que debe usar el descompilador aquí.",
                        choices.union, choices.current))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(choices.choices) { c in
                    Button { apply(c) } label: {
                        HStack {
                            Text(c.index < 0 ? tr("(que decida el descompilador)") : c.name).monospaced()
                            Spacer()
                            Text(c.type).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(c.name == choices.current)
                }
            } else if error == nil {
                ProgressView()
            }
            if let error { StatusLine(text: error, isError: true) }
            HStack {
                Spacer()
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .task {
            do {
                choices = try await model.engine.call("unionFields", ["address": function, "token": token])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ choice: UnionChoice) {
        Task {
            do {
                _ = try await model.engine.call("forceUnion", ["address": function, "token": token, "field": choice.index],
                                                as: Bool.self)
                await model.refreshAfterEdits()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
