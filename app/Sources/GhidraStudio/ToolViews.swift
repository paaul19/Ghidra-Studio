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
    @State private var editingField: TypeField?
    @State private var editFieldType = ""
    @State private var editFieldName = ""
    @State private var editFieldComment = ""
    @State private var showInsert = false
    @State private var insertOffset = ""
    @State private var showBitField = false
    @State private var bitCount = "1"
    @State private var showResize = false
    @State private var newSize = ""
    @State private var archiveBrowser: TypeArchive?
    @State private var archives: [TypeArchive] = []
    @State private var fieldFilter = ""
    @State private var usesRows: [JSONRow] = []
    @Environment(\.openWindow) private var openWindow

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
                        Button(tr("Definición de función…")) { model.requestFunctionDefinition() }
                        Divider()
                        Button(tr("Guardar el tipo seleccionado en un archivo .gdt…")) { exportSelected() }
                            .disabled(selection == nil)
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
                        Divider()
                        Menu(tr("Importar tipos de…")) {
                            ForEach(archives) { a in
                                Button(a.name) { archiveBrowser = a }
                            }
                        }
                    } label: {
                        Label(tr("Aplicar archivo de tipos"), systemImage: "books.vertical")
                    }
                    .help(tr("Aplica las firmas de funciones de un archivo de tipos (libc, macOS, Windows, Go, Rust…)"))
                    Button { openWindow(id: "typemanager") } label: {
                        Label(tr("Gestor de tipos"), systemImage: "folder.badge.gearshape")
                    }
                    .help(tr("Categorías, archivos .gdt, sincronización, favoritos, vista previa y cabeceras de C"))
                    Button { if let d = detail { model.typeUsesRequest = TypeUsesRequest(path: d.path, field: "") } } label: {
                        Label(tr("Buscar usos"), systemImage: "magnifyingglass")
                    }
                    .disabled(detail == nil)
                    Button { if let addr = model.editTarget, let d = detail { apply(d, at: addr) } } label: {
                        Label(tr("Aplicar en la dirección seleccionada"), systemImage: "arrow.down.to.line.compact")
                    }
                    .disabled(detail == nil || model.editTarget == nil)
                    .help(tr("Definir este tipo en la dirección seleccionada (%@)", "\(model.editTarget ?? "—")"))
                }
            }
        }
        .windowMinSize(820, 520)
        .task(id: "\(showBuiltins)|\(model.activeSession ?? "")") {
            await reload()
            if archives.isEmpty { archives = (try? await model.engine.call("typeArchives")) ?? [] }
        }
        .onChange(of: selection) { _, path in Task { await loadDetail(path) } }
        .onAppear { showRequestedType() }
        .onDisappear { Task { await leaveEditor() } }
        .onChange(of: model.typeToShow) { _, _ in showRequestedType() }
        .sheet(isPresented: $showCImport) { cImportSheet }
        .sheet(item: Binding(get: { model.typeUsesRequest }, set: { model.typeUsesRequest = $0 })) { request in
            TypeUsesSheet(request: request)
        }
        .sheet(item: $archiveBrowser) { archive in
            ArchiveTypesSheet(archive: archive) { Task { await reload() } }
        }
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
                if d.editor != nil {
                    editorBar(d)
                    Divider()
                }
                TextField(tr("Buscar campo"), text: $fieldFilter)
                    .textFieldStyle(.roundedBorder).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
                Table(d.fields.filter { f in
                    fieldFilter.isEmpty || (f.name ?? "").localizedCaseInsensitiveContains(fieldFilter)
                        || (f.type ?? "").localizedCaseInsensitiveContains(fieldFilter)
                }, selection: $fieldSelection) {
                    TableColumn("Offset") { f in Text(f.offset.map { String(format: "0x%x", $0) } ?? "").monospaced() }
                        .width(70)
                    TableColumn(tr("Tamaño")) { f in Text("\(f.length ?? 0)").monospacedDigit() }.width(56)
                    TableColumn(tr("Tipo")) { f in Text(f.type ?? "").monospaced() }
                    TableColumn(tr("Nombre")) { f in Text(f.name ?? "—").monospaced() }
                    TableColumn(tr("Comentario")) { f in Text(f.comment ?? "").foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: TypeField.ID.self) { ids in
                    if let id = ids.first, let f = d.fields.first(where: { $0.id == id }), d.editable {
                        Button(tr("Editar campo…")) {
                            editingField = f
                            editFieldType = f.type ?? ""
                            editFieldName = f.name ?? ""
                            editFieldComment = f.comment ?? ""
                        }
                        Button(tr("Duplicar")) { Task { await mutate("typeDuplicateField", ["path": d.path, "ordinal": f.ordinal ?? 0, "count": 1]) } }
                        Button(tr("Desempaquetar (array o estructura)")) {
                            Task { await mutate("typeUnpackField", ["path": d.path, "ordinal": f.ordinal ?? 0]) }
                        }
                        Button(tr("Buscar usos de este campo")) {
                            model.typeUsesRequest = TypeUsesRequest(path: d.path, field: f.name ?? "")
                        }
                        Button(tr("Subir")) { Task { await mutate("moveField", ["path": d.path, "ordinal": f.ordinal ?? 0, "delta": -1]) } }
                        Button(tr("Bajar")) { Task { await mutate("moveField", ["path": d.path, "ordinal": f.ordinal ?? 0, "delta": 1]) } }
                        Divider()
                        Button(tr("Borrar campo"), role: .destructive) {
                            Task { await mutate("deleteField", ["path": d.path, "ordinal": f.ordinal ?? 0]) }
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let f = d.fields.first(where: { $0.id == id }), d.editable {
                        editingField = f
                        editFieldType = f.type ?? ""
                        editFieldName = f.name ?? ""
                        editFieldComment = f.comment ?? ""
                    }
                }
                .alert(tr("Editar campo"), isPresented: Binding(get: { editingField != nil }, set: { if !$0 { editingField = nil } })) {
                    TextField(tr("Tipo"), text: $editFieldType)
                    TextField(tr("Nombre"), text: $editFieldName)
                    TextField(tr("Comentario"), text: $editFieldComment)
                    Button(tr("Guardar")) {
                        if let f = editingField {
                            Task {
                                await mutate("editField", ["path": d.path, "ordinal": f.ordinal ?? 0,
                                                           "type": editFieldType.contains(":") ? "" : editFieldType,
                                                           "name": editFieldName, "comment": editFieldComment])
                            }
                        }
                    }
                    Button(tr("Cancelar"), role: .cancel) {}
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
                        Menu {
                            Button(tr("Insertar en un offset…")) { insertOffset = ""; showInsert = true }
                            Button(tr("Añadir campo de bits…")) { bitCount = "1"; showBitField = true }
                            Button(tr("Añadir array flexible al final")) {
                                Task { await mutate("typeFlexArray", ["path": d.path, "type": newFieldType, "name": newFieldName]) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(tr("Usa el tipo y el nombre escritos a la izquierda"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    HStack(spacing: 14) {
                        Toggle(tr("Empaquetada"), isOn: Binding(get: { d.packed ?? false }, set: { on in
                            Task { await mutate("setPacking", ["path": d.path, "enabled": on, "value": 0]) }
                        }))
                        .toggleStyle(.checkbox)
                        .help(tr("Con empaquetado, Ghidra coloca y alinea los campos solo, como un compilador"))
                        Menu("pack(\(d.packValue ?? 0 > 0 ? "\(d.packValue ?? 0)" : "por defecto"))") {
                            ForEach([0, 1, 2, 4, 8, 16], id: \.self) { v in
                                Button(v == 0 ? tr("Por defecto") : "\(v)") {
                                    Task { await mutate("setPacking", ["path": d.path, "enabled": true, "value": v]) }
                                }
                            }
                        }
                        .fixedSize()
                        .disabled(d.packed != true)
                        Menu(tr("Alineación: %@", "\(d.alignment ?? 1)")) {
                            ForEach([0, 1, 2, 4, 8, 16], id: \.self) { v in
                                Button(v == 0 ? tr("Por defecto") : "\(v)") {
                                    Task { await mutate("setAlignment", ["path": d.path, "value": v]) }
                                }
                            }
                        }
                        .fixedSize()
                        Spacer()
                        if d.kind == "struct", d.packed != true {
                            Button(tr("Cambiar tamaño…")) { newSize = "\(d.size)"; showResize = true }
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .alert(tr("Insertar campo en un offset"), isPresented: $showInsert) {
                        TextField(tr("Offset (p. ej. 0x10)"), text: $insertOffset)
                        Button(tr("Insertar")) {
                            let off = Int(insertOffset.replacingOccurrences(of: "0x", with: ""), radix: insertOffset.hasPrefix("0x") ? 16 : 10) ?? 0
                            Task { await mutate("insertField", ["path": d.path, "offset": off, "type": newFieldType, "name": newFieldName]) }
                        }
                        Button(tr("Cancelar"), role: .cancel) {}
                    }
                    .alert(tr("Añadir campo de bits"), isPresented: $showBitField) {
                        TextField(tr("Número de bits"), text: $bitCount)
                        Button(tr("Añadir")) {
                            Task { await mutate("addBitField", ["path": d.path, "type": newFieldType, "bits": Int(bitCount) ?? 1, "name": newFieldName]) }
                        }
                        Button(tr("Cancelar"), role: .cancel) {}
                    }
                    .alert(tr("Tamaño de la estructura"), isPresented: $showResize) {
                        TextField("Bytes", text: $newSize)
                        Button(tr("Aplicar")) { Task { await mutate("setStructSize", ["path": d.path, "size": Int(newSize) ?? d.size]) } }
                        Button(tr("Cancelar"), role: .cancel) {}
                    }
                }
            } else if d.kind == "enum" {
                Table(d.fields, selection: $fieldSelection) {
                    TableColumn(tr("Nombre")) { f in Text(f.name ?? "").monospaced() }
                    TableColumn(tr("Valor")) { f in Text("\(f.value ?? 0)").monospacedDigit() }
                }
                .contextMenu(forSelectionType: TypeField.ID.self) { ids in
                    if let id = ids.first, let f = d.fields.first(where: { $0.id == id }), d.editable {
                        Button(tr("Quitar valor"), role: .destructive) {
                            Task { await mutate("removeEnumValue", ["path": d.path, "name": f.name ?? ""]) }
                        }
                    }
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

    /// Opens the type another window asked to edit.
    private func showRequestedType() {
        guard let path = model.typeToShow else { return }
        model.typeToShow = nil
        query = ""
        selection = path
        Task { await loadDetail(path) }
    }

    private func loadDetail(_ path: String?) async {
        await leaveEditor()
        guard let path else { detail = nil; return }
        do {
            let loaded: DataTypeDetail = try await model.engine.call("dataType", ["path": path])
            detail = loaded
            if loaded.editable, loaded.kind == "struct" || loaded.kind == "union",
               let working: DataTypeDetail = try? await model.engine.call("typeEditBegin", ["path": path]) {
                // structures are edited on a working copy with its own undo, like the classic's editor
                detail = working
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// The edits of a structure that go to its working copy instead of straight to the program.
    private static let editorOps: Set<String> = [
        "addField", "editField", "deleteField", "insertField", "moveField", "addBitField", "setPacking", "setAlignment",
        "setStructSize", "typeDuplicateField", "typeUnpackField", "typeFlexArray",
    ]

    /// Closes the structure editor of the type being left, offering to apply what was not applied.
    private func leaveEditor() async {
        guard let d = detail, let id = d.editor else { return }
        detail?.editor = nil
        if d.dirty == true,
           model.confirm(tr("¿Aplicar los cambios de «%@»?", d.name),
                         tr("La estructura tiene cambios que todavía no se han aplicado al programa."), action: tr("Aplicar")) {
            _ = try? await model.engine.call("typeEditApply", ["id": id], as: DataTypeDetail.self)
            await model.refreshUndo()
        }
        _ = try? await model.engine.call("typeEditClose", ["id": id], as: Bool.self)
    }

    private func editorCommand(_ method: String) async {
        guard let id = detail?.editor else { return }
        do {
            detail = try await model.engine.call(method, ["id": id])
            if method == "typeEditApply" {
                await model.refreshUndo()
                await reload()
                model.rebuildDocument()
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder private func editorBar(_ d: DataTypeDetail) -> some View {
        HStack(spacing: 8) {
            Button { Task { await editorCommand("typeEditUndo") } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(d.canUndo != true).help(tr("Deshacer el último cambio de la estructura"))
            Button { Task { await editorCommand("typeEditRedo") } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(d.canRedo != true).help(tr("Rehacer"))
            Text(d.dirty == true ? tr("Cambios sin aplicar") : tr("Sin cambios pendientes"))
                .font(.caption).foregroundStyle(d.dirty == true ? Color.orange : Color.secondary)
            Spacer()
            Button(tr("Descartar")) { Task { await editorCommand("typeEditRevert") } }.disabled(d.dirty != true)
            Button(tr("Aplicar")) { Task { await editorCommand("typeEditApply") } }
                .disabled(d.dirty != true).buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func mutate(_ method: String, _ params: [String: Any]) async {
        if let id = detail?.editor, Self.editorOps.contains(method) {
            var p = params
            p["id"] = id
            p["op"] = method
            do { detail = try await model.engine.call("typeEditOp", p) }
            catch { model.errorMessage = error.localizedDescription }
            return
        }
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

extension DataTypesView {
    /// Saves the selected type (and what it depends on) into a .gdt archive, creating it if needed.
    func exportSelected() {
        guard let path = selection else { return }
        let panel = NSSavePanel()
        panel.title = tr("Guardar tipos en un archivo")
        panel.nameFieldStringValue = "tipos.gdt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let r: ExportedTypes = try await model.engine.call("exportTypes", ["path": url.path, "types": [path]])
                model.errorMessage = tr("Guardado en %@ (%@ tipos en el archivo).", (r.path as NSString).lastPathComponent, "\(r.total)")
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

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
    @State private var patternCount = 2
    @State private var maskOperands = true
    @State private var patternShown = ""
    @State private var replacement = ""
    @State private var valueKind = "decimal"
    @State private var valueSize = 4
    @State private var encoding = "ascii"
    @State private var tableLength = 3

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $mode) {
                        Text(tr("Texto")).tag(0)
                        Text("Bytes").tag(1)
                        Text(tr("Patrón de instrucciones")).tag(2)
                        Text(tr("Valor")).tag(3)
                        Text(tr("Regex de bytes")).tag(4)
                        Text(tr("Tablas de direcciones")).tag(5)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if mode == 2 {
                        HStack(spacing: 12) {
                            Stepper(tr("Instrucciones: %@", "\(patternCount)"), value: $patternCount, in: 1...16).fixedSize()
                            Toggle(tr("Ignorar operandos"), isOn: $maskOperands).toggleStyle(.checkbox)
                            Button(tr("Buscar desde %@", "\(model.editTarget ?? "—")"), action: run)
                                .buttonStyle(.glassProminent)
                                .disabled(model.editTarget == nil || searching)
                            Spacer()
                        }
                        Text(patternShown.isEmpty
                             ? tr("Busca otros sitios con las mismas instrucciones que la línea seleccionada en la ventana principal. Con «Ignorar operandos» coinciden aunque cambien registros, constantes o direcciones.")
                             : tr("Patrón: %@   (?? = cualquier byte, * = solo algunos bits)", "\(patternShown)"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if mode == 5 {
                        HStack(spacing: 12) {
                            Stepper(tr("Mínimo %@ punteros seguidos", "\(tableLength)"), value: $tableLength, in: 2...64).fixedSize()
                            Button(tr("Buscar"), action: run).buttonStyle(.glassProminent).disabled(searching)
                            Spacer()
                        }
                        Text(tr("Busca series de punteros consecutivos a direcciones del programa: tablas de saltos, vtables o arrays de punteros."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    if mode == 3 {
                        HStack(spacing: 12) {
                            Picker("", selection: $valueKind) {
                                Text(tr("Entero")).tag("decimal")
                                Text("Float").tag("float")
                                Text("Double").tag("double")
                                Text(tr("Cadena")).tag("string")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            if valueKind == "decimal" {
                                Picker(tr("Tamaño"), selection: $valueSize) {
                                    Text("1").tag(1); Text("2").tag(2); Text("4").tag(4); Text("8").tag(8)
                                }
                                .pickerStyle(.segmented).fixedSize()
                            }
                            if valueKind == "string" {
                                Picker(tr("Codificación"), selection: $encoding) {
                                    Text("ASCII").tag("ascii"); Text("UTF-8").tag("utf8")
                                    Text("UTF-16").tag("utf16"); Text("UTF-32").tag("utf32")
                                }
                                .pickerStyle(.segmented).fixedSize()
                            }
                            Spacer()
                        }
                        if !patternShown.isEmpty {
                            Text(tr("Bytes buscados: %@", patternShown)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField(mode == 0 ? tr("Buscar en etiquetas, comentarios, cadenas o instrucciones")
                                  : mode == 3 ? tr("Valor a buscar (varios enteros separados por espacios)")
                                  : mode == 4 ? tr("Expresión regular sobre los bytes, p. ej. https?://[\\x21-\\x7e]+")
                                            : tr("Patrón de bytes, p. ej. 48 8b ?? 05 ?? ?? 00"), text: $query)
                            .textFieldStyle(.roundedBorder)
                            .font(mode == 1 ? .body.monospaced() : .body)
                            .onSubmit(run)
                        Button(tr("Buscar"), action: run)
                            .buttonStyle(.glassProminent)
                            .disabled(query.isEmpty || searching)
                    }
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
                        HStack {
                            TextField(tr("Reemplazar por…"), text: $replacement).textFieldStyle(.roundedBorder)
                            Button(tr("Reemplazar todo")) { replaceAll() }
                                .disabled(query.isEmpty || searching || !(labels || comments))
                                .help(tr("Reemplaza en nombres de etiquetas y en comentarios (se puede deshacer con ⌘Z)"))
                        }
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
        .windowMinSize(760, 440)
    }

    private func replaceAll() {
        var scopes: [String] = []
        if labels { scopes.append("labels") }
        if comments { scopes.append("comments") }
        let where_ = scopes.count == 2 ? tr("etiquetas y comentarios") : labels ? tr("etiquetas") : tr("comentarios")
        guard model.confirm(tr("¿Reemplazar «%@» por «%@»?", "\(query)", "\(replacement)"),
                            tr("Se cambiará en %@. Puedes deshacerlo con ⌘Z.", "\(where_)"),
                            action: tr("Reemplazar")) else { return }
        searching = true
        Task {
            defer { searching = false }
            do {
                let r: AppliedResult = try await model.engine.call("replaceText", [
                    "query": query, "replacement": replacement, "regex": regex, "caseSensitive": caseSensitive,
                    "scopes": scopes])
                await model.refreshAfterEdits()
                model.errorMessage = tr("Se reemplazó en %@ sitios.", "\(r.applied)")
                run()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func run() {
        guard !query.isEmpty || mode == 2 || mode == 5 else { return }
        searching = true
        let start = Date()
        Task {
            defer { searching = false; elapsed = Date().timeIntervalSince(start) }
            do {
                if mode == 2 {
                    guard let address = model.editTarget else { return }
                    let r: PatternResult = try await model.engine.call("instructionPattern", [
                        "address": address, "count": patternCount, "maskOperands": maskOperands])
                    patternShown = r.pattern
                    results = r.results
                } else if mode == 3 {
                    let r: ValueSearchResult = try await model.engine.call("searchValue", [
                        "kind": valueKind, "text": query, "size": valueSize, "encoding": encoding])
                    patternShown = r.pattern
                    results = r.results
                } else if mode == 4 {
                    results = try await model.engine.call("searchRegex", ["regex": query])
                } else if mode == 5 {
                    results = try await model.engine.call("addressTables", ["minLength": tableLength])
                } else if mode == 1 {
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
        .windowMinSize(420, 460)
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
    @State private var arguments = ""
    @State private var isPython = false
    @State private var showDirs = false
    @State private var showSearch = false
    @Environment(\.openWindow) private var openWindow

    private var selectedScript: ScriptItem? { scripts.first { $0.path == selection } }

    private func reloadScripts() async { scripts = (try? await model.engine.call("scripts")) ?? scripts }

    private func renameSelected() {
        guard let s = selectedScript else { return }
        model.formRequest = FormRequest(
            title: tr("Renombrar el script"),
            fields: [FormField(key: "name", title: tr("Nombre"), value: (s.name as NSString).deletingPathExtension)],
            actionTitle: tr("Renombrar"), origin: "scripts") { values in
                let result: JSONRow = try await model.engine.call("scriptRename", ["path": s.path, "name": values["name"] ?? ""])
                // the shortcut follows the script
                var shortcuts = model.scriptShortcuts
                if let spec = shortcuts.removeValue(forKey: s.path), let path = result["path"]?.string { shortcuts[path] = spec }
                model.scriptShortcuts = shortcuts
                await reloadScripts()
                selection = result["path"]?.string
            }
    }

    private func deleteSelected() {
        guard let s = selectedScript,
              model.confirm(tr("¿Borrar el script «%@»?", s.name), tr("Se borra el archivo de tu carpeta de scripts."), action: tr("Borrar"))
        else { return }
        Task {
            do {
                _ = try await model.engine.call("scriptDelete", ["path": s.path], as: JSONValue.self)
                var shortcuts = model.scriptShortcuts
                shortcuts.removeValue(forKey: s.path)
                model.scriptShortcuts = shortcuts
                selection = nil
                source = ""
                await reloadScripts()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func bindSelected() {
        guard let s = selectedScript else { return }
        model.formRequest = FormRequest(
            title: tr("Atajo de teclado para %@", s.name),
            message: tr("Escribe la combinación como cmd+opt+1 o cmd+shift+k. Vacío quita el atajo. El script aparece en Herramientas ▸ Scripts con atajo."),
            fields: [FormField(key: "spec", title: tr("Atajo"), value: model.scriptShortcuts[s.path] ?? "", placeholder: "cmd+opt+1")],
            actionTitle: tr("Guardar"), origin: "scripts") { values in
                let spec = (values["spec"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                var shortcuts = model.scriptShortcuts
                if spec.isEmpty {
                    shortcuts.removeValue(forKey: s.path)
                } else {
                    guard Shortcuts.parse(spec) != nil, spec.contains("cmd+") || spec.contains("ctrl+") || spec.contains("opt+") else {
                        throw EngineError.remote(tr("Ese atajo no es válido. Usa cmd, opt, ctrl o shift y una tecla."))
                    }
                    shortcuts[s.path] = spec
                }
                model.scriptShortcuts = shortcuts
            }
    }

    private func openExternally(app: String?) {
        guard let s = selectedScript else { return }
        let url = URL(fileURLWithPath: s.path)
        if let app, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else if app != nil {
            model.errorMessage = tr("Esa aplicación no está instalada.")
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static let pythonTemplate = """
    # Describe aquí lo que hace el script.
    # @category Studio
    print("Programa:", currentProgram.getName())
    for f in currentProgram.getFunctionManager().getFunctions(True):
        print(f.getEntryPoint(), f.getName())

    """

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
                        if s.isPython {
                            Text("py").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        }
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
                        Text(isPython ? ".py" : ".java").font(.caption.monospaced()).foregroundStyle(.secondary)
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
                        TextField(tr("Argumentos para askString/askInt… separados por comas"), text: $arguments)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .help(tr("Los scripts que piden datos (askString, askInt, askFile…) los reciben de aquí, en orden"))
                        Spacer()
                        Button(tr("Limpiar")) { output = "" }.buttonStyle(.plain).font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        Text(output.isEmpty ? tr("La salida de println() / print() aparecerá aquí.") : output)
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
            Button { selection = nil; isPython = false; name = "NuevoScript"; source = Self.template; dirty = true } label: {
                Label(tr("Nuevo"), systemImage: "doc.badge.plus")
            }
            .help(tr("Nuevo script en Java"))
            if model.pythonVersion != nil {
                Button { selection = nil; isPython = true; name = "nuevo_script"; source = Self.pythonTemplate; dirty = true } label: {
                    Label(tr("Nuevo en Python"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help(tr("Nuevo script en Python (PyGhidra)"))
                Button { openWindow(id: "python") } label: { Label(tr("Intérprete"), systemImage: "terminal") }
                    .help(tr("Abrir el intérprete de Python"))
            }
            Menu {
                Button(tr("Renombrar…")) { renameSelected() }.disabled(selectedScript?.user != true)
                Button(tr("Borrar"), role: .destructive) { deleteSelected() }.disabled(selectedScript?.user != true)
                Button(tr("Atajo de teclado…")) { bindSelected() }.disabled(selectedScript == nil)
                Divider()
                Button(tr("Abrir en el editor predeterminado")) { openExternally(app: nil) }.disabled(selectedScript == nil)
                Button(tr("Abrir en Visual Studio Code")) { openExternally(app: "com.microsoft.VSCode") }.disabled(selectedScript == nil)
                Button(tr("Abrir en Xcode")) { openExternally(app: "com.apple.dt.Xcode") }.disabled(selectedScript == nil)
                Button(tr("Editar en Eclipse")) { if let s = selectedScript { model.editInEclipse(s.path) } }
                    .disabled(selectedScript == nil)
                Button(tr("Mostrar en el Finder")) {
                    if let s = selectedScript { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) }
                }
                .disabled(selectedScript == nil)
                Divider()
                Button(tr("Buscar en el código de los scripts…")) { showSearch = true }
                Button(tr("Directorios de scripts y bundles…")) { showDirs = true }
                Button(tr("Volver a leer la lista")) { Task { await reloadScripts() } }
            } label: {
                Label(tr("Más"), systemImage: "ellipsis.circle")
            }
            Button { Task { await saveScript() } } label: { Label(tr("Guardar"), systemImage: "square.and.arrow.down") }
                .help(tr("Guarda en tu carpeta de scripts (~/ghidra_scripts)"))
                .disabled(name.isEmpty || source.isEmpty)
            if running {
                Button { model.cancelTask() } label: { Label(tr("Detener"), systemImage: "stop.fill") }
                    .help(tr("Cancela el script en marcha"))
            }
            Button { Task { await runScript() } } label: { Label(tr("Ejecutar"), systemImage: "play.fill") }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(running || source.isEmpty || model.program == nil)
                .help(model.program == nil ? tr("Abre un programa para ejecutar scripts") : tr("Ejecutar sobre %@ (⌘R)", "\(model.program?.name ?? "")"))
        }
        .windowMinSize(900, 560)
        .sheet(item: model.formBinding("scripts")) { request in FormSheet(request: request) }
        .sheet(isPresented: $showDirs) { ScriptDirsSheet { Task { await reloadScripts() } } }
        .sheet(isPresented: $showSearch) { ScriptSearchSheet { path in selection = path } }
        .task(id: model.engineReady) { scripts = (try? await model.engine.call("scripts")) ?? [] }
        .onChange(of: selection) { _, path in
            guard let path, let s = scripts.first(where: { $0.path == path }) else { return }
            Task {
                source = (try? await model.engine.call("scriptSource", ["path": path], as: String.self)) ?? ""
                isPython = s.isPython
                name = s.name.replacingOccurrences(of: ".java", with: "").replacingOccurrences(of: ".py", with: "")
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
        if isPython { return source }
        let className = name.replacingOccurrences(of: ".java", with: "")
        guard let regex = try? NSRegularExpression(pattern: "public\\s+class\\s+(\\w+)") else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "public class \(className)")
    }

    @discardableResult
    private func saveScript() async -> String? {
        do {
            let file = name.replacingOccurrences(of: ".java", with: "").replacingOccurrences(of: ".py", with: "")
                + (isPython ? ".py" : ".java")
            let saved: SavedScript = try await model.engine.call("saveScript", ["name": file, "source": normalizedSource()])
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
            let args = arguments.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !args.isEmpty { params["args"] = args }
            model.lastScript = path
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
    @State private var expanded: String?
    @State private var subOptions: [TypedOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Opciones de análisis")).font(.title3.weight(.semibold))
            Text(tr("Elige qué analizadores de Ghidra se ejecutan sobre %@.", "\(model.program?.name ?? "el programa")"))
                .font(.callout).foregroundStyle(.secondary)
            TextField(tr("Filtrar"), text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach($options) { $opt in
                    if query.isEmpty || opt.name.localizedCaseInsensitiveContains(query) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Toggle(isOn: $opt.enabled) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(opt.name)
                                        if let d = opt.description, !d.isEmpty {
                                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                Button { toggle(opt.name) } label: { Image(systemName: "slider.horizontal.3") }
                                    .buttonStyle(.plain)
                                    .help(tr("Opciones de este analizador"))
                                Button { model.runAnalyzer(opt.name); dismiss() } label: { Image(systemName: "play.circle") }
                                    .buttonStyle(.plain)
                                    .help(tr("Ejecutar solo este analizador ahora"))
                                    .disabled(model.analysis != nil)
                            }
                            if expanded == opt.name {
                                if subOptions.isEmpty {
                                    Text(tr("Este analizador no tiene opciones propias.")).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(subOptions) { sub in
                                    TypedOptionRow(option: sub) { value in setSub(sub, value) }
                                        .font(.callout)
                                        .padding(.leading, 22)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 400)
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
        .frame(width: 640)
        .task { options = (try? await model.engine.call("analysisOptions")) ?? [] }
    }

    private func toggle(_ name: String) {
        if expanded == name { expanded = nil; return }
        expanded = name
        subOptions = []
        Task { subOptions = (try? await model.engine.call("analyzerOptions", ["analyzer": name])) ?? [] }
    }

    private func setSub(_ sub: TypedOption, _ value: String) {
        guard let name = sub.name, let analyzer = expanded else { return }
        Task {
            do {
                _ = try await model.engine.call("setAnalyzerOption", ["name": name, "value": value], as: Bool.self)
                subOptions = (try? await model.engine.call("analyzerOptions", ["analyzer": analyzer])) ?? subOptions
                await model.refreshUndo()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
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

/// Pick types from a .gdt archive and copy them into the program.
struct ArchiveTypesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let archive: TypeArchive
    let onDone: () -> Void
    @State private var types: [DataTypeItem] = []
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Importar tipos de %@", "\(archive.name)")).font(.title3.weight(.semibold))
            HStack {
                TextField(tr("Buscar tipos"), text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
                Button(tr("Buscar")) { Task { await load() } }
            }
            List(types, selection: $selection) { t in
                HStack {
                    Text(t.name).monospaced().lineLimit(1)
                    Spacer()
                    Text("\(t.kind) · \(t.size > 0 ? "\(t.size) B" : "—")").font(.caption).foregroundStyle(.secondary)
                }
                .tag(t.path)
            }
            .frame(height: 340)
            .overlay { if loading { ProgressView() } }
            HStack {
                Text(tr("%@ tipos%@ · %@ seleccionados", "\(types.count)", "\(types.count >= 3000 ? " (máximo 3000; usa la búsqueda)" : "")", "\(selection.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Importar")) {
                    Task {
                        do {
                            let r: AppliedResult = try await model.engine.call("importArchiveTypes", [
                                "path": archive.path, "types": Array(selection)])
                            await model.refreshUndo()
                            model.errorMessage = tr("Se importaron %@ tipos (con sus dependencias).", "\(r.applied)")
                            onDone()
                            dismiss()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selection.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        types = (try? await model.engine.call("archiveTypes", ["path": archive.path, "filter": query])) ?? []
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
