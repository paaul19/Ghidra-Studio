import SwiftUI
import UniformTypeIdentifiers

/// Shown in tool windows when no program is open.
struct NoProgramView: View {
    var body: some View {
        ContentUnavailableView(tr("Ningún programa abierto"), systemImage: "cpu",
                               description: Text(tr("Abre o importa un programa en la ventana principal.")))
    }
}

// MARK: - Data types

struct DataTypesView: View {
    @Environment(AppModel.self) private var model
    @State private var types: [DataTypeItem] = []
    @State private var query = ""
    @State private var showBuiltins = false
    @State private var selection: String?
    @State private var detail: DataTypeDetail?
    @State private var fieldSelection: TypeField.ID?
    @State private var newFieldType = "int"
    @State private var newFieldName = ""
    @State private var showCImport = false
    @State private var cSource = "typedef struct {\n    int id;\n    char name[32];\n} Registro;\n"
    @State private var creating: String?
    @State private var newName = ""
    @State private var renaming = false
    @State private var archives: [TypeArchive] = []

    var body: some View {
        Group {
            if model.program == nil {
                NoProgramView()
            } else {
                NavigationSplitView {
                    List(filtered, selection: $selection) { t in
                        HStack(spacing: 8) {
                            Image(systemName: icon(t.kind)).foregroundStyle(color(t.kind)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name).lineLimit(1)
                                Text("\(t.category) · \(t.size > 0 ? "\(t.size) B" : "—")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(t.path)
                    }
                    .searchable(text: $query, placement: .sidebar, prompt: tr("Buscar tipos"))
                    .safeAreaInset(edge: .bottom) {
                        Toggle(tr("Mostrar tipos integrados"), isOn: $showBuiltins)
                            .toggleStyle(.checkbox)
                            .padding(10)
                    }
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                } detail: {
                    if let d = detail {
                        typeDetail(d)
                    } else {
                        ContentUnavailableView(tr("Elige un tipo"), systemImage: "tablecells",
                                               description: Text(tr("Crea estructuras, uniones, enums y typedefs desde la barra de herramientas.")))
                    }
                }
                .toolbar {
                    Menu {
                        Button(tr("Estructura…")) { creating = "struct"; newName = "" }
                        Button(tr("Unión…")) { creating = "union"; newName = "" }
                        Button(tr("Enum…")) { creating = "enum"; newName = "" }
                        Button(tr("Typedef…")) { creating = "typedef"; newName = "" }
                        Divider()
                        Button(tr("Importar declaraciones C…")) { showCImport = true }
                    } label: {
                        Label(tr("Nuevo"), systemImage: "plus")
                    }
                    Menu {
                        ForEach(archives) { a in
                            Button(a.name) { model.applyArchive(a.path) }
                        }
                        Divider()
                        Button(tr("Otro archivo .gdt…")) {
                            let panel = NSOpenPanel()
                            if let gdt = UTType(filenameExtension: "gdt") { panel.allowedContentTypes = [gdt] }
                            if panel.runModal() == .OK, let url = panel.url { model.applyArchive(url.path) }
                        }
                    } label: {
                        Label(tr("Aplicar archivo de tipos"), systemImage: "books.vertical")
                    }
                    .help(tr("Aplica las firmas de funciones de un archivo de tipos (libc, macOS, Windows, Go, Rust…)"))
                    Button { if let addr = model.editTarget, let d = detail { apply(d, at: addr) } } label: {
                        Label(tr("Aplicar en la dirección seleccionada"), systemImage: "arrow.down.to.line.compact")
                    }
                    .disabled(detail == nil || model.editTarget == nil)
                    .help(tr("Definir este tipo en la dirección seleccionada (%@)", "\(model.editTarget ?? "—")"))
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .task(id: "\(showBuiltins)|\(model.activeSession ?? "")") {
            await reload()
            if archives.isEmpty { archives = (try? await model.engine.call("typeArchives")) ?? [] }
        }
        .onChange(of: selection) { _, path in Task { await loadDetail(path) } }
        .sheet(isPresented: $showCImport) { cImportSheet }
        .sheet(item: Binding(get: { creating.map { IdentifiedString(value: $0) } }, set: { creating = $0?.value })) { kind in
            createSheet(kind.value)
        }
    }

    private var filtered: [DataTypeItem] {
        query.isEmpty ? types : types.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "struct": "square.grid.3x1.below.line.grid.1x2"
        case "union": "square.on.square"
        case "enum": "list.number"
        case "typedef": "arrow.right.square"
        case "function": "function"
        default: "textformat"
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "struct", "union": .blue
        case "enum": .orange
        case "typedef": .teal
        case "function": .purple
        default: .secondary
        }
    }

    @ViewBuilder private func typeDetail(_ d: DataTypeDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon(d.kind)).font(.title2).foregroundStyle(color(d.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.title2.weight(.semibold))
                    Text(tr("%@ · %@ bytes · %@", "\(d.kind)", "\(d.size)", "\(d.path)")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if d.editable {
                    Button(tr("Renombrar…")) { newName = d.name; renaming = true }
                    Button(tr("Borrar"), role: .destructive) {
                        guard model.confirm(tr("¿Borrar el tipo «%@»?", "\(d.name)"), tr("Se quitará del programa."), action: tr("Borrar"))
                        else { return }
                        Task { await mutate("deleteType", ["path": d.path]); selection = nil; detail = nil }
                    }
                }
            }
            .padding(16)
            Divider()
            if d.kind == "struct" || d.kind == "union" {
                Table(d.fields, selection: $fieldSelection) {
                    TableColumn("Offset") { f in Text(f.offset.map { String(format: "0x%x", $0) } ?? "").monospaced() }
                        .width(70)
                    TableColumn(tr("Tamaño")) { f in Text("\(f.length ?? 0)").monospacedDigit() }.width(56)
                    TableColumn(tr("Tipo")) { f in Text(f.type ?? "").monospaced() }
                    TableColumn(tr("Nombre")) { f in Text(f.name ?? "—").monospaced() }
                    TableColumn(tr("Comentario")) { f in Text(f.comment ?? "").foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: TypeField.ID.self) { ids in
                    if let id = ids.first, let f = d.fields.first(where: { $0.id == id }), d.editable {
                        Button(tr("Borrar campo"), role: .destructive) {
                            Task { await mutate("deleteField", ["path": d.path, "ordinal": f.ordinal ?? 0]) }
                        }
                    }
                }
                if d.editable {
                    HStack {
                        TextField(tr("Tipo"), text: $newFieldType).frame(width: 160).font(.body.monospaced())
                        TextField(tr("Nombre"), text: $newFieldName).font(.body.monospaced())
                        Button(tr("Añadir campo")) {
                            Task {
                                await mutate("addField", ["path": d.path, "type": newFieldType, "name": newFieldName])
                                newFieldName = ""
                            }
                        }
                        .disabled(newFieldType.isEmpty)
                    }
                    .padding(12)
                }
            } else if d.kind == "enum" {
                Table(d.fields) {
                    TableColumn(tr("Nombre")) { f in Text(f.name ?? "").monospaced() }
                    TableColumn(tr("Valor")) { f in Text("\(f.value ?? 0)").monospacedDigit() }
                }
                if d.editable {
                    HStack {
                        TextField(tr("Nombre"), text: $newFieldName).font(.body.monospaced())
                        TextField(tr("Valor"), text: $newFieldType).frame(width: 120).font(.body.monospaced())
                        Button(tr("Añadir valor")) {
                            Task {
                                await mutate("addEnumValue", ["path": d.path, "name": newFieldName,
                                                              "value": Int64(newFieldType) ?? 0])
                                newFieldName = ""
                            }
                        }
                    }
                    .padding(12)
                }
            }
            if let c = d.c, !c.isEmpty {
                Divider()
                ScrollView {
                    Text(cDeclaration(c, name: d.name))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: Theme.background))
            }
        }
        .alert(tr("Renombrar tipo"), isPresented: $renaming) {
            TextField(tr("Nombre"), text: $newName)
            Button(tr("Renombrar")) { Task { await mutate("renameType", ["path": d.path, "name": newName]); await reload() } }
            Button(tr("Cancelar"), role: .cancel) {}
        }
    }

    /// Keeps only the declaration of the selected type (the writer also emits base typedefs).
    private func cDeclaration(_ c: String, name: String) -> String {
        // The writer emits base typedefs first; show from the type's own declaration on.
        let lines = c.components(separatedBy: "\n")
        let markers = ["struct \(name)", "union \(name)", "enum \(name)", " \(name);", " \(name) "]
        if let start = lines.firstIndex(where: { line in
            !line.hasPrefix("typedef unsigned") && !line.hasPrefix("typedef long") && !line.hasPrefix("typedef int")
                && markers.contains { line.contains($0) }
        }) {
            return lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return c
    }

    private var cImportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Importar declaraciones C")).font(.title3.weight(.semibold))
            Text(tr("Pega structs, unions, enums o typedefs. Se añadirán a los tipos del programa."))
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $cSource)
                .font(.body.monospaced())
                .frame(height: 240)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { showCImport = false }.keyboardShortcut(.cancelAction)
                Button(tr("Importar")) {
                    Task { await mutate("parseC", ["source": cSource]); showCImport = false; await reload() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func createSheet(_ kind: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == "typedef" ? tr("Nuevo typedef") : "Nuevo \(kind == "struct" ? "struct" : kind == "union" ? "union" : "enum")")
                .font(.title3.weight(.semibold))
            TextField(tr("Nombre"), text: $newName).textFieldStyle(.roundedBorder).font(.body.monospaced())
            if kind == "typedef" {
                TextField(tr("Tipo base (p. ej. unsigned int)"), text: $newFieldType)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { creating = nil }.keyboardShortcut(.cancelAction)
                Button(tr("Crear")) {
                    Task {
                        switch kind {
                        case "struct": await create("createStruct", ["name": newName])
                        case "union": await create("createStruct", ["name": newName, "union": true])
                        case "enum": await create("createEnum", ["name": newName])
                        default: await create("createTypedef", ["name": newName, "base": newFieldType])
                        }
                        creating = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(newName.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func reload() async {
        guard model.program != nil else { return }
        types = (try? await model.engine.call("dataTypes", ["builtins": showBuiltins])) ?? []
    }

    private func loadDetail(_ path: String?) async {
        guard let path else { detail = nil; return }
        do {
            detail = try await model.engine.call("dataType", ["path": path])
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func mutate(_ method: String, _ params: [String: Any]) async {
        do {
            _ = try await model.engine.call(method, params, as: AnyCodableIgnored.self)
            await model.refreshUndo()
            await loadDetail(selection)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func create(_ method: String, _ params: [String: Any]) async {
        do {
            let result: PathResult = try await model.engine.call(method, params)
            await model.refreshUndo()
            await reload()
            selection = result.path
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func apply(_ d: DataTypeDetail, at address: String) {
        Task {
            do {
                _ = try await model.engine.call("createData", ["address": address, "type": d.path.hasPrefix("/") ? d.name : d.path],
                                                as: Bool.self)
                await model.refreshUndo()
                model.go(address)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

/// Decodes (and ignores) any JSON result.
struct AnyCodableIgnored: Decodable {
    init(from decoder: Decoder) throws {}
}

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = 0
    @State private var query = ""
    @State private var labels = true
    @State private var comments = true
    @State private var strings = true
    @State private var instructions = false
    @State private var regex = false
    @State private var caseSensitive = false
    @State private var results: [SearchResult] = []
    @State private var selection: SearchResult.ID?
    @State private var searching = false
    @State private var elapsed: Double?

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $mode) {
                        Text(tr("Texto")).tag(0)
                        Text("Bytes").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    HStack {
                        TextField(mode == 0 ? tr("Buscar en etiquetas, comentarios, cadenas o instrucciones")
                                            : tr("Patrón de bytes, p. ej. 48 8b ?? 05 ?? ?? 00"), text: $query)
                            .textFieldStyle(.roundedBorder)
                            .font(mode == 1 ? .body.monospaced() : .body)
                            .onSubmit(run)
                        Button(tr("Buscar"), action: run)
                            .buttonStyle(.glassProminent)
                            .disabled(query.isEmpty || searching)
                    }
                    if mode == 0 {
                        HStack(spacing: 14) {
                            Toggle(tr("Etiquetas"), isOn: $labels)
                            Toggle(tr("Comentarios"), isOn: $comments)
                            Toggle(tr("Cadenas"), isOn: $strings)
                            Toggle(tr("Instrucciones"), isOn: $instructions)
                            Divider().frame(height: 14)
                            Toggle(tr("Expresión regular"), isOn: $regex)
                            Toggle(tr("Mayúsculas"), isOn: $caseSensitive)
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    }
                }
                .padding(14)
                Divider()
                Table(results, selection: $selection) {
                    TableColumn(tr("Dirección")) { r in Text(r.address).monospaced() }.width(min: 90, ideal: 110)
                    TableColumn(tr("Tipo")) { r in Text(tr(r.kind)) }.width(min: 70, ideal: 90)
                    TableColumn(tr("Función")) { r in Text(r.function ?? "—").foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 160)
                    TableColumn(tr("Coincidencia")) { r in Text(r.text).monospaced().lineLimit(1) }
                }
                .contextMenu(forSelectionType: SearchResult.ID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let r = results.first(where: { $0.id == id }) { model.go(r.address) }
                }
                .onChange(of: selection) { _, id in
                    if let id, let r = results.first(where: { $0.id == id }) { model.go(r.address) }
                }
                HStack {
                    if searching { ProgressView().controlSize(.small) }
                    Text(searching ? tr("Buscando…") : tr("%@ resultado%@", "\(results.count)", "\(results.count == 1 ? "" : "s")")
                         + (elapsed.map { String(format: " · %.2f s", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    private func run() {
        guard !query.isEmpty else { return }
        searching = true
        let start = Date()
        Task {
            defer { searching = false; elapsed = Date().timeIntervalSince(start) }
            do {
                if mode == 1 {
                    results = try await model.engine.call("searchBytes", ["pattern": query])
                } else {
                    var scopes: [String] = []
                    if labels { scopes.append("labels") }
                    if comments { scopes.append("comments") }
                    if strings { scopes.append("strings") }
                    if instructions { scopes.append("instructions") }
                    results = try await model.engine.call("searchText", ["query": query, "regex": regex,
                                                                         "caseSensitive": caseSensitive, "scopes": scopes])
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Call tree

struct CallTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var callers = false

    var body: some View {
        VStack(spacing: 0) {
            if let fn = model.functionDetails {
                HStack {
                    Picker("", selection: $callers) {
                        Text(tr("Llama a")).tag(false)
                        Text(tr("Llamada desde")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Spacer()
                    Text(fn.name).font(.headline.monospaced()).lineLimit(1)
                }
                .padding(12)
                Divider()
                List {
                    CallNode(item: CallItem(name: fn.name, address: fn.entry, external: false, hasChildren: true),
                             callers: callers, depth: 0, expanded: true)
                }
                .id("\(fn.entry)|\(callers)")
            } else {
                ContentUnavailableView(tr("Ninguna función seleccionada"), systemImage: "point.3.filled.connected.trianglepath.dotted",
                                       description: Text(tr("Selecciona una función en la ventana principal.")))
            }
        }
        .frame(minWidth: 420, minHeight: 460)
    }
}

private struct CallNode: View {
    @Environment(AppModel.self) private var model
    let item: CallItem
    let callers: Bool
    let depth: Int
    @State var expanded: Bool
    @State private var children: [CallItem]?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let children {
                ForEach(children) { child in
                    if child.hasChildren && depth < 12 {
                        CallNode(item: child, callers: callers, depth: depth + 1, expanded: false)
                    } else {
                        row(child)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            row(item)
        }
        .onChange(of: expanded, initial: true) { _, open in
            guard open, children == nil else { return }
            Task {
                children = (try? await model.engine.call("calls", ["address": item.address, "callers": callers])) ?? []
            }
        }
    }

    private func row(_ c: CallItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.external ? "shippingbox" : "f.cursive")
                .foregroundStyle(c.external ? Color.orange : Color.purple)
            Text(c.name).lineLimit(1)
            Spacer()
            Text(c.address).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !c.external { model.go(c.address) } }
        .help(tr("Doble clic para ir a la función"))
    }
}

// MARK: - Scripts

struct ScriptsView: View {
    @Environment(AppModel.self) private var model
    @State private var scripts: [ScriptItem] = []
    @State private var query = ""
    @State private var selection: String?
    @State private var source = ""
    @State private var name = ""
    @State private var output = ""
    @State private var running = false
    @State private var dirty = false

    static let template = """
    // Describe aquí lo que hace el script.
    // @category Studio
    import ghidra.app.script.GhidraScript;
    import ghidra.program.model.listing.*;

    public class NuevoScript extends GhidraScript {
        @Override
        public void run() throws Exception {
            println("Programa: " + currentProgram.getName());
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                println(f.getEntryPoint() + "  " + f.getName());
            }
        }
    }
    """

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { s in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(s.name).lineLimit(1)
                        if s.user { Image(systemName: "person.fill").font(.caption2).foregroundStyle(.tint) }
                    }
                    Text(s.category.isEmpty ? s.description : "\(s.category) · \(s.description)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(s.path)
            }
            .searchable(text: $query, placement: .sidebar, prompt: tr("Buscar scripts"))
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            VSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField(tr("Nombre del script"), text: $name)
                            .textFieldStyle(.plain)
                            .font(.headline.monospaced())
                        if dirty { Text(tr("modificado")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(10)
                    Divider()
                    TextEditor(text: $source)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: Theme.background))
                        .autocorrectionDisabled()
                        .onChange(of: source) { _, _ in dirty = true }
                }
                .frame(minHeight: 240)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label(tr("Consola"), systemImage: "terminal").font(.caption.weight(.semibold))
                        Spacer()
                        Button(tr("Limpiar")) { output = "" }.buttonStyle(.plain).font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        Text(output.isEmpty ? tr("La salida de println() aparecerá aquí.") : output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .frame(minHeight: 120)
            }
        }
        .toolbar {
            Button { selection = nil; name = "NuevoScript"; source = Self.template; dirty = true } label: {
                Label(tr("Nuevo"), systemImage: "doc.badge.plus")
            }
            Button { Task { await saveScript() } } label: { Label(tr("Guardar"), systemImage: "square.and.arrow.down") }
                .help(tr("Guarda en tu carpeta de scripts (~/ghidra_scripts)"))
                .disabled(name.isEmpty || source.isEmpty)
            Button { Task { await runScript() } } label: { Label(tr("Ejecutar"), systemImage: "play.fill") }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(running || source.isEmpty || model.program == nil)
                .help(model.program == nil ? tr("Abre un programa para ejecutar scripts") : tr("Ejecutar sobre %@ (⌘R)", "\(model.program?.name ?? "")"))
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { scripts = (try? await model.engine.call("scripts")) ?? [] }
        .onChange(of: selection) { _, path in
            guard let path, let s = scripts.first(where: { $0.path == path }) else { return }
            Task {
                source = (try? await model.engine.call("scriptSource", ["path": path], as: String.self)) ?? ""
                name = s.name.replacingOccurrences(of: ".java", with: "")
                dirty = false
            }
        }
    }

    private var filtered: [ScriptItem] {
        query.isEmpty ? scripts : scripts.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// Java requires the public class name to match the file name.
    private func normalizedSource() -> String {
        let className = name.replacingOccurrences(of: ".java", with: "")
        guard let regex = try? NSRegularExpression(pattern: "public\\s+class\\s+(\\w+)") else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "public class \(className)")
    }

    @discardableResult
    private func saveScript() async -> String? {
        do {
            let saved: SavedScript = try await model.engine.call("saveScript", ["name": name, "source": normalizedSource()])
            source = normalizedSource()
            dirty = false
            scripts = (try? await model.engine.call("scripts")) ?? scripts
            selection = saved.path
            return saved.path
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func runScript() async {
        running = true
        defer { running = false }
        var path = selection
        let isUser = scripts.first { $0.path == selection }?.user ?? false
        if dirty || path == nil || (!isUser && dirty) {
            path = await saveScript()
        }
        guard let path else { return }
        output += tr("▶︎ %@ sobre %@\n", "\(name)", "\(model.program?.name ?? "")")
        do {
            var params: [String: Any] = ["path": path]
            if let address = model.editTarget { params["address"] = address }
            let result: ScriptResult = try await model.engine.call("runScript", params)
            output += result.output
            output += result.error.map { tr("✖︎ %@\n", "\($0)") } ?? tr("✔︎ Terminado en %@ ms\n", "\(result.millis)")
            output += "\n"
            await model.refreshUndo()
        } catch {
            output += "✖︎ \(error.localizedDescription)\n\n"
        }
    }
}

// MARK: - Analysis options

struct AnalysisOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options: [AnalyzerOption] = []
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Opciones de análisis")).font(.title3.weight(.semibold))
            Text(tr("Elige qué analizadores de Ghidra se ejecutan sobre %@.", "\(model.program?.name ?? "el programa")"))
                .font(.callout).foregroundStyle(.secondary)
            TextField(tr("Filtrar"), text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach($options) { $opt in
                    if query.isEmpty || opt.name.localizedCaseInsensitiveContains(query) {
                        Toggle(isOn: $opt.enabled) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(opt.name)
                                if let d = opt.description, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 360)
            HStack {
                Button(tr("Todos")) { for i in options.indices { options[i].enabled = true } }
                Button(tr("Ninguno")) { for i in options.indices { options[i].enabled = false } }
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Guardar")) { Task { await save(analyze: false) } }
                Button(tr("Guardar y analizar")) { Task { await save(analyze: true) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 600)
        .task { options = (try? await model.engine.call("analysisOptions")) ?? [] }
    }

    private func save(analyze: Bool) async {
        var values: [String: Bool] = [:]
        for o in options { values[o.name] = o.enabled }
        do {
            _ = try await model.engine.call("setAnalysisOptions", ["options": values], as: Bool.self)
            await model.refreshUndo()
            if analyze { model.analyzeNow() }
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var exporters: [ExporterItem] = []
    @State private var selected: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Exportar %@", "\(model.program?.name ?? "")")).font(.title3.weight(.semibold))
            List(exporters, selection: $selected) { e in
                HStack {
                    Image(systemName: icon(e.name)).frame(width: 18).foregroundStyle(.tint)
                    Text(e.name)
                    Spacer()
                    if !e.extension.isEmpty { Text(".\(e.extension)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                .tag(e.name)
            }
            .frame(height: 260)
            Text(tr("«Original File» exporta el binario con tus parches aplicados."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Exportar…")) { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(selected == nil || working)
            }
        }
        .padding(22)
        .frame(width: 460)
        .task {
            exporters = (try? await model.engine.call("exporters")) ?? []
            selected = exporters.first { $0.name == "C/C++" }?.name ?? exporters.first?.name
        }
    }

    private func icon(_ name: String) -> String {
        switch name {
        case "C/C++": "chevron.left.forwardslash.chevron.right"
        case "Ascii": "doc.plaintext"
        case "HTML": "globe"
        case "XML", "SARIF": "curlybraces.square"
        case "Original File", "Raw Bytes", "Intel Hex": "memorychip"
        case "Ghidra Zip File": "shippingbox"
        default: "square.and.arrow.up"
        }
    }

    private func export() {
        guard let name = selected, let ex = exporters.first(where: { $0.name == name }) else { return }
        let panel = NSSavePanel()
        panel.title = tr("Exportar como %@", "\(name)")
        let base = model.program?.name ?? "programa"
        panel.nameFieldStringValue = ex.extension.isEmpty ? base : "\(base).\(ex.extension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let result: ExportResult = try await model.engine.call("export", ["exporter": name, "path": url.path])
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
                dismiss()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
