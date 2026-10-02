import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data type manager

/// Where data types live: the program, a .gdt file or an archive stored in the project.
struct TypeHome: Identifiable, Hashable {
    /// "" for the program, a file path, or "project:/folder/name".
    let id: String
    let name: String

    static var program: TypeHome { TypeHome(id: "", name: tr("Programa")) }
}

/// What the panels of the data type manager share.
@MainActor
@Observable
final class TypeManagerState {
    var files: [String] = UserDefaults.standard.stringArray(forKey: "typeArchiveFiles") ?? [] {
        didSet { UserDefaults.standard.set(files, forKey: "typeArchiveFiles") }
    }
    var projectArchives: [TypeHome] = []
    var home = ""
    /// rename, replace or keep: what happens when a copied type already exists.
    var conflict = "rename"
    /// Bumped after every change so the panels reload.
    var revision = 0
    var usesOf: String?

    var homes: [TypeHome] {
        [.program] + files.filter { FileManager.default.fileExists(atPath: $0) }
            .map { TypeHome(id: $0, name: ($0 as NSString).lastPathComponent) } + projectArchives
    }

    func name(of home: String) -> String { homes.first { $0.id == home }?.name ?? home }

    func add(file: String) {
        if !files.contains(file) { files.append(file) }
        home = file
        revision += 1
    }
}

struct TypeManagerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("typeManagerPanel") private var panel = "browse"
    @State private var state = TypeManagerState()

    private var panels: [(String, String, String)] {
        [("browse", tr("Categorías y archivos"), "folder.badge.gearshape"),
         ("sync", tr("Sincronizar con el archivo de origen"), "arrow.triangle.2.circlepath"),
         ("favorites", tr("Favoritos"), "star"),
         ("preview", tr("Vista previa en el cursor"), "eye"),
         ("headers", tr("Cabeceras de C"), "doc.text.magnifyingglass")]
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { panel }, set: { if let v = $0 { panel = v } })) {
                ForEach(panels, id: \.0) { item in
                    Label(item.1, systemImage: item.2).tag(item.0)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                switch panel {
                case "sync": TypeSyncPanel(state: state)
                case "favorites": TypeFavoritesPanel(state: state)
                case "preview": TypePreviewPanel()
                case "headers": TypeHeadersPanel(state: state)
                default: TypeBrowsePanel(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .windowMinSize(1040, 560)
        .sheet(item: model.formBinding("types")) { request in FormSheet(request: request) }
        .task(id: "\(model.project?.directory ?? "")|\(state.revision)") {
            let list: [JSONRow] = (try? await model.engine.call("typeProjectArchives")) ?? []
            state.projectArchives = list.map { TypeHome(id: $0["where"]?.text ?? "", name: tr("Proyecto: %@", $0["name"]?.text ?? "")) }
        }
    }
}

/// Picks the program or one of the open archives.
private struct TypeHomePicker: View {
    let state: TypeManagerState
    @Binding var home: String
    var title = ""

    var body: some View {
        Picker(title, selection: $home) {
            ForEach(state.homes) { h in Text(h.name).tag(h.id) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: Browse

private struct TypeBrowsePanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: TypeManagerState
    @State private var categories: [JSONRow] = []
    @State private var types: [JSONRow] = []
    @State private var category = "/"
    @State private var filter = ""
    @State private var info: JSONRow = [:]
    @State private var error: String?
    @State private var uses: [JSONRow] = []
    @State private var searchingUses = false
    @State private var decompileUses = false

    private var isProgram: Bool { state.home.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(header) {
                TypeHomePicker(state: state, home: $state.home)
                Menu(tr("Archivo")) {
                    Button(tr("Abrir un archivo .gdt…")) { openArchive() }
                    Button(tr("Nuevo archivo .gdt…")) { newArchive() }
                    Button(tr("Nuevo archivo en el proyecto…")) { newProjectArchive() }
                    Divider()
                    Button(tr("Arquitectura del archivo…")) { requestArchitecture() }.disabled(isProgram)
                    Button(tr("Cerrar el archivo")) {
                        state.files.removeAll { $0 == state.home }
                        state.home = ""
                    }
                    .disabled(isProgram || state.home.hasPrefix("project:"))
                }
                .fixedSize()
                Picker(tr("Si ya existe"), selection: $state.conflict) {
                    Text(tr("Renombrar el nuevo")).tag("rename")
                    Text(tr("Reemplazar el existente")).tag("replace")
                    Text(tr("Conservar el existente")).tag("keep")
                }
                .fixedSize()
                .help(tr("Qué se hace cuando un tipo copiado o movido ya existe en el destino"))
            }
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: Binding(get: { category }, set: { if let v = $0 { category = v } })) {
                        ForEach(categories, id: \.self) { c in
                            HStack(spacing: 6) {
                                Image(systemName: "folder").foregroundStyle(.blue)
                                Text(c["name"]?.text ?? "").lineLimit(1)
                                Spacer()
                                Text(c["types"]?.text ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.leading, CGFloat(c["depth"]?.int ?? 0) * 12)
                            .tag(c["path"]?.text ?? "/")
                            .contextMenu { categoryMenu(c["path"]?.text ?? "/") }
                        }
                    }
                    Divider()
                    HStack {
                        Menu(tr("Categoría")) { categoryMenu(category) }.fixedSize()
                        Spacer()
                    }
                    .controlSize(.small)
                    .padding(8)
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)
                VSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            TextField(tr("Buscar en todas las categorías"), text: $filter)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await reload() } }
                            Button(tr("Buscar")) { Task { await reload() } }
                            if !filter.isEmpty {
                                Button(tr("Ver la categoría")) { filter = ""; Task { await reload() } }
                            }
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        GenericTable(rows: types,
                                     columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 220, mono: true),
                                               ColumnSpec(key: "kind", title: tr("Clase"), width: 70),
                                               ColumnSpec(key: "size", title: tr("Tamaño"), width: 60),
                                               ColumnSpec(key: "category", title: tr("Categoría"), width: 160),
                                               ColumnSpec(key: "favorite", title: tr("Favorito"), width: 60),
                                               ColumnSpec(key: "source", title: tr("Archivo de origen"), width: 120),
                                               ColumnSpec(key: "description", title: tr("Descripción"), width: 220)],
                                     storageKey: "typeBrowse", addressKey: nil, actions: typeActions)
                    }
                    .frame(minHeight: 220)
                    if state.usesOf != nil {
                        usesPane.frame(minHeight: 160)
                    }
                }
            }
            if let error {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .task(id: "\(state.home)|\(category)|\(state.revision)|\(model.activeSession ?? "")|\(model.editCount)") { await reload() }
        .onChange(of: state.home) { _, _ in category = "/"; filter = "" }
    }

    private var header: String {
        var parts = [state.name(of: state.home)]
        if let n = info["types"]?.int { parts.append(tr("%@ tipos", "\(n)")) }
        if let a = info["architecture"]?.string, !a.isEmpty { parts.append(a) }
        return parts.joined(separator: " · ")
    }

    private var usesPane: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(tr("Usos de %@", state.usesOf ?? "")).font(.caption.weight(.semibold))
                if searchingUses { ProgressView().controlSize(.small) }
                Spacer()
                Toggle(tr("Buscar también en el código descompilado"), isOn: $decompileUses)
                    .toggleStyle(.checkbox)
                    .onChange(of: decompileUses) { _, _ in findUses() }
                Button(tr("Cerrar")) { state.usesOf = nil }
            }
            .controlSize(.small)
            .padding(8)
            GenericTable(rows: uses,
                         columns: [.address(), ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true),
                                   ColumnSpec(key: "context", title: tr("Contexto"), width: 420, mono: true),
                                   ColumnSpec(key: "kind", title: tr("Clase"), width: 90)],
                         storageKey: "typeUses",
                         onOpen: { row in if let a = row["address"]?.string, !a.isEmpty { model.go(a) } })
        }
    }

    @ViewBuilder private func categoryMenu(_ path: String) -> some View {
        Button(tr("Nueva categoría…")) {
            ask(tr("Nueva categoría en %@", path), [FormField(key: "name", title: tr("Nombre"))]) { v in
                try await call("typeCategory", ["action": "create", "path": path, "name": v["name"] ?? ""])
            }
        }
        if path != "/" {
            Button(tr("Renombrar…")) {
                ask(tr("Renombrar la categoría"), [FormField(key: "name", title: tr("Nombre"), value: (path as NSString).lastPathComponent)]) { v in
                    try await call("typeCategory", ["action": "rename", "path": path, "name": v["name"] ?? ""])
                    category = "/"
                }
            }
            Button(tr("Mover a…")) {
                ask(tr("Mover la categoría %@", path), [destinationField()]) { v in
                    try await call("typeCategory", ["action": "move", "path": path, "dest": v["dest"] ?? "/"])
                    category = "/"
                }
            }
            Button(tr("Copiar a…")) {
                ask(tr("Copiar la categoría %@", path), [destinationField()]) { v in
                    try await call("typeCategory", ["action": "copy", "path": path, "dest": v["dest"] ?? "/", "conflict": state.conflict])
                }
            }
            Button(tr("Borrar"), role: .destructive) {
                guard model.confirm(tr("¿Borrar la categoría «%@»?", path), tr("Se borrarán también sus tipos."), action: tr("Borrar"))
                else { return }
                run { try await call("typeCategory", ["action": "delete", "path": path]); category = "/" }
            }
        }
    }

    private func destinationField() -> FormField {
        FormField(key: "dest", title: tr("Categoría de destino"), kind: .choice(categories.map { $0["path"]?.text ?? "/" }), value: "/")
    }

    private var typeActions: [RowAction] {
        var list: [RowAction] = [
            RowAction(title: tr("Renombrar…")) { row in
                ask(tr("Renombrar tipo"), [FormField(key: "name", title: tr("Nombre"), value: row["name"]?.text ?? "")]) { v in
                    try await typeAction("rename", row, ["name": v["name"] ?? ""])
                }
            },
            RowAction(title: tr("Mover a otra categoría…")) { row in
                ask(tr("Mover %@", row["name"]?.text ?? ""), [destinationField()]) { v in
                    try await typeAction("move", row, ["dest": v["dest"] ?? "/"])
                }
            },
            RowAction(title: tr("Copiar a otra categoría…")) { row in
                ask(tr("Copiar %@", row["name"]?.text ?? ""), [destinationField()]) { v in
                    try await typeAction("copy", row, ["dest": v["dest"] ?? "/"])
                }
            },
            RowAction(title: tr("Copiar a otro archivo o al programa…")) { row in
                let homes = state.homes.filter { $0.id != state.home }
                guard !homes.isEmpty else { error = tr("Abre o crea antes un archivo de tipos."); return }
                ask(tr("Copiar %@", row["name"]?.text ?? ""),
                    [FormField(key: "to", title: tr("Destino"), kind: .choice(homes.map(\.name)), value: homes[0].name),
                     FormField(key: "associate", title: tr("Mantenerlo asociado al archivo (para sincronizar después)"),
                               kind: .toggle, value: "true")]) { v in
                    let to = homes.first { $0.name == v["to"] }?.id ?? ""
                    _ = try await model.engine.call("typeCopy", ["from": state.home, "to": to, "paths": [row["path"]?.text ?? ""],
                                                                 "conflict": state.conflict, "associate": v["associate"] == "true"],
                                                    as: JSONValue.self)
                    await changed()
                }
            },
            RowAction(title: tr("Crear puntero")) { row in run { try await typeAction("pointer", row, [:]) } },
            RowAction(title: tr("Crear typedef…")) { row in
                ask(tr("Typedef de %@", row["name"]?.text ?? ""),
                    [FormField(key: "name", title: tr("Nombre"), value: (row["name"]?.text ?? "") + "_t")]) { v in
                    try await typeAction("typedef", row, ["name": v["name"] ?? ""])
                }
            },
            RowAction(title: tr("Poner o quitar de favoritos")) { row in
                run { try await typeAction("favorite", row, ["name": row["favorite"]?.bool == true ? "false" : "true"]) }
            },
            RowAction(title: tr("Descripción…")) { row in
                ask(tr("Descripción de %@", row["name"]?.text ?? ""),
                    [FormField(key: "name", title: tr("Descripción"), value: row["description"]?.text ?? "", mono: false)]) { v in
                    try await typeAction("describe", row, ["name": v["name"] ?? ""])
                }
            },
            RowAction(title: tr("Reemplazar por otro tipo…")) { row in
                ask(tr("Reemplazar %@", row["name"]?.text ?? ""),
                    [FormField(key: "note", title: tr("Todos los usos de este tipo pasan a usar el otro, y este se borra."), kind: .note),
                     FormField(key: "dest", title: tr("Ruta del tipo que lo reemplaza"), placeholder: "/categoria/Tipo")]) { v in
                    try await typeAction("replace", row, ["dest": v["dest"] ?? ""])
                }
            },
            RowAction(title: tr("Unir con otros enums…")) { row in
                ask(tr("Crear un enum a partir de varios"),
                    [FormField(key: "others", title: tr("Otros enums (rutas separadas por comas)")),
                     FormField(key: "name", title: tr("Nombre del enum nuevo"), value: (row["name"]?.text ?? "") + "_union")]) { v in
                    let others = (v["others"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    try await call("typeMergeEnums", ["paths": [row["path"]?.text ?? ""] + others, "name": v["name"] ?? ""])
                }
            },
        ]
        if isProgram {
            list.append(RowAction(title: tr("Buscar usos")) { row in
                state.usesOf = row["path"]?.text
                findUses()
            })
            list.append(RowAction(title: tr("Buscar usos de un campo…")) { row in
                ask(tr("Usos de un campo de %@", row["name"]?.text ?? ""), [FormField(key: "field", title: tr("Nombre del campo"))]) { v in
                    state.usesOf = row["path"]?.text
                    findUses(field: v["field"] ?? "")
                }
            })
            list.append(RowAction(title: tr("Aplicar en el cursor")) { row in
                guard let address = model.editTarget else { return }
                model.run("createData", ["address": address, "type": row["path"]?.text ?? ""], namesChanged: false)
            })
        }
        list.append(RowAction(title: tr("Borrar"), destructive: true) { row in
            guard model.confirm(tr("¿Borrar el tipo «%@»?", row["name"]?.text ?? ""), tr("Se quitará de %@.", state.name(of: state.home)),
                                action: tr("Borrar")) else { return }
            run { try await typeAction("delete", row, [:]) }
        })
        return list
    }

    // MARK: actions

    private func ask(_ title: String, _ fields: [FormField], _ submit: @escaping ([String: String]) async throws -> Void) {
        model.formRequest = FormRequest(title: title, fields: fields, origin: "types", submit: submit)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }

    private func call(_ method: String, _ params: [String: Any]) async throws {
        var p = params
        p["where"] = state.home
        _ = try await model.engine.call(method, p, as: JSONValue.self)
        await changed()
    }

    private func typeAction(_ action: String, _ row: JSONRow, _ extra: [String: Any]) async throws {
        var p: [String: Any] = ["action": action, "paths": [row["path"]?.text ?? ""], "conflict": state.conflict]
        p.merge(extra) { _, new in new }
        try await call("typeAction", p)
    }

    private func changed() async {
        error = nil
        if isProgram { await model.afterEdit(namesChanged: false) }
        state.revision += 1
    }

    private func reload() async {
        guard !isProgram || model.program != nil else { categories = []; types = []; return }
        do {
            let result: JSONRow = try await model.engine.call("typeBrowse", ["where": state.home, "category": category, "filter": filter])
            categories = result["categories"]?.array.map(\.object) ?? []
            types = result["types"]?.array.map(\.object) ?? []
            info = (try? await model.engine.call("typeInfo", ["where": state.home])) ?? [:]
            error = nil
        } catch {
            if category != "/" { category = "/" } else { self.error = error.localizedDescription }
        }
    }

    private func findUses(field: String = "") {
        guard let path = state.usesOf else { return }
        searchingUses = true
        Task {
            defer { searchingUses = false }
            do {
                uses = try await model.engine.call("typeUses", ["path": path, "field": field, "decompile": decompileUses])
            } catch { self.error = error.localizedDescription }
        }
    }

    private func openArchive() {
        let panel = NSOpenPanel()
        if let gdt = UTType(filenameExtension: "gdt") { panel.allowedContentTypes = [gdt] }
        if panel.runModal() == .OK, let url = panel.url { state.add(file: url.path) }
    }

    private func newArchive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tipos.gdt"
        if let gdt = UTType(filenameExtension: "gdt") { panel.allowedContentTypes = [gdt] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            // the save panel already asked before replacing
            try? FileManager.default.removeItem(at: url)
            let result: JSONRow = try await model.engine.call("typeCreateArchive", ["path": url.path])
            state.add(file: result["path"]?.text ?? url.path)
        }
    }

    private func newProjectArchive() {
        ask(tr("Nuevo archivo de tipos en el proyecto"),
            [FormField(key: "name", title: tr("Nombre"), value: "tipos"),
             FormField(key: "folder", title: tr("Carpeta del proyecto"), value: "/")]) { v in
            let result: JSONRow = try await model.engine.call("typeCreateProjectArchive",
                                                              ["name": v["name"] ?? "tipos", "folder": v["folder"] ?? "/"])
            state.revision += 1
            state.home = result["where"]?.text ?? ""
        }
    }

    private func requestArchitecture() {
        ask(tr("Arquitectura del archivo de tipos"),
            [FormField(key: "note", title: tr("Con una arquitectura, los tamaños de puntero, long y alineación son los de ese procesador. Vacío la quita."),
                       kind: .note),
             FormField(key: "language", title: tr("Lenguaje"), value: model.program?.language ?? "", placeholder: "x86:LE:64:default"),
             FormField(key: "compiler", title: tr("Compilador (vacío: el predeterminado)"))]) { v in
            try await call("typeSetArchitecture", ["language": v["language"] ?? "", "compiler": v["compiler"] ?? ""])
        }
    }
}

// MARK: Sync

private struct TypeSyncPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: TypeManagerState
    @State private var sources: [JSONRow] = []
    @State private var archive = ""
    @State private var rows: [JSONRow] = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Tipos del programa que vienen de un archivo")) {
                Picker("", selection: $archive) {
                    Text(tr("Elige un archivo")).tag("")
                    ForEach(candidates, id: \.0) { c in Text(c.1).tag(c.0) }
                }
                .labelsHidden()
                .fixedSize()
                Button(tr("Otro .gdt…")) {
                    let panel = NSOpenPanel()
                    if let gdt = UTType(filenameExtension: "gdt") { panel.allowedContentTypes = [gdt] }
                    if panel.runModal() == .OK, let url = panel.url { state.add(file: url.path); archive = url.path }
                }
                Button(tr("Actualizar todos")) { all("update", flag: "canUpdate") }.disabled(rows.isEmpty)
                    .help(tr("Trae al programa los cambios del archivo"))
                Button(tr("Confirmar todos")) { all("commit", flag: "canCommit") }.disabled(rows.isEmpty)
                    .help(tr("Lleva al archivo los cambios hechos en el programa"))
            }
            Divider()
            if model.program == nil {
                NoProgramView()
            } else {
                GenericTable(rows: rows,
                             columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 200, mono: true),
                                       ColumnSpec(key: "stateText", title: tr("Estado"), width: 190),
                                       ColumnSpec(key: "path", title: tr("En el programa"), width: 200, mono: true),
                                       ColumnSpec(key: "sourcePath", title: tr("En el archivo"), width: 200, mono: true),
                                       ColumnSpec(key: "changed", title: tr("Cambio en el programa"), width: 150),
                                       ColumnSpec(key: "sourceChanged", title: tr("Cambio en el archivo"), width: 150)],
                             storageKey: "typeSync", addressKey: nil,
                             actions: [RowAction(title: tr("Confirmar en el archivo")) { act("commit", [$0]) },
                                       RowAction(title: tr("Actualizar desde el archivo")) { act("update", [$0]) },
                                       RowAction(title: tr("Revertir")) { act("revert", [$0]) },
                                       RowAction(title: tr("Desasociar")) { act("disassociate", [$0]) }])
            }
            Divider()
            Text(error ?? tr("Archivos de origen del programa: %@", sources.map { "\($0["name"]?.text ?? "") (\($0["types"]?.text ?? "0"))" }.joined(separator: ", ")))
                .font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .task(id: "\(model.activeSession ?? "")|\(state.revision)|\(model.editCount)") { await loadSources() }
        .task(id: "\(archive)|\(state.revision)|\(model.editCount)") { await load() }
    }

    /// Archives that can be compared: the ones the program names (when their file is known) and the open ones.
    private var candidates: [(String, String)] {
        var out: [(String, String)] = []
        for s in sources {
            if let path = s["path"]?.string, !path.isEmpty { out.append((path, s["name"]?.text ?? path)) }
        }
        for h in state.homes where !h.id.isEmpty && !out.contains(where: { $0.0 == h.id }) { out.append((h.id, h.name)) }
        return out
    }

    private static func stateText(_ state: String) -> String {
        switch state {
        case "IN_SYNC": tr("Sincronizado")
        case "UPDATE": tr("El archivo tiene cambios")
        case "COMMIT": tr("El programa tiene cambios")
        case "CONFLICT": tr("Cambios en los dos (conflicto)")
        case "ORPHAN": tr("Ya no está en el archivo")
        default: tr("Desconocido")
        }
    }

    private func loadSources() async {
        guard model.program != nil else { sources = []; return }
        sources = (try? await model.engine.call("typeSources")) ?? []
    }

    private func load() async {
        guard !archive.isEmpty, model.program != nil else { rows = []; return }
        do {
            let list: [JSONRow] = try await model.engine.call("typeSyncList", ["archive": archive])
            rows = list.map { row in
                var r = row
                r["stateText"] = .string(Self.stateText(row["state"]?.text ?? ""))
                return r
            }
            error = nil
        } catch {
            rows = []
            self.error = error.localizedDescription
        }
    }

    private func all(_ action: String, flag: String) {
        act(action, rows.filter { $0[flag]?.bool == true && $0["state"]?.text != "IN_SYNC" })
    }

    private func act(_ action: String, _ list: [JSONRow]) {
        guard !list.isEmpty else { return }
        Task {
            do {
                _ = try await model.engine.call("typeSync", ["archive": archive, "paths": list.map { $0["path"]?.text ?? "" },
                                                             "action": action], as: JSONValue.self)
                await model.afterEdit(namesChanged: false)
                state.revision += 1
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Favorites

private struct TypeFavoritesPanel: View {
    @Environment(AppModel.self) private var model
    let state: TypeManagerState

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Tipos favoritos")) {
                Text(tr("Se marcan desde «Categorías y archivos»")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if model.program == nil {
                NoProgramView()
            } else {
                EngineTable(method: "typeFavorites",
                            columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 220, mono: true),
                                      ColumnSpec(key: "kind", title: tr("Clase"), width: 80),
                                      ColumnSpec(key: "size", title: tr("Tamaño"), width: 60),
                                      ColumnSpec(key: "path", title: tr("Ruta"), width: 260, mono: true)],
                            addressKey: nil,
                            actions: [RowAction(title: tr("Aplicar en el cursor")) { row in
                                guard let address = model.editTarget else { return }
                                model.run("createData", ["address": address, "type": row["path"]?.text ?? ""], namesChanged: false)
                            }, RowAction(title: tr("Quitar de favoritos")) { row in
                                Task {
                                    _ = try? await model.engine.call("typeAction", ["action": "favorite", "paths": [row["path"]?.text ?? ""],
                                                                                    "name": "false"], as: JSONValue.self)
                                    await model.afterEdit(namesChanged: false)
                                }
                            }],
                            reloadKey: "\(state.revision)")
            }
        }
    }
}

// MARK: Preview

/// Ghidra's Data Type Preview: the bytes at the cursor read as each of a list of types.
private struct TypePreviewPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("typePreviewTypes") private var stored = "byte\nword\ndword\nqword\nfloat\ndouble\nchar[16]\npointer\nstring\nunicode"
    @State private var newType = ""
    @State private var rows: [JSONRow] = []

    private var types: [String] { stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Vista previa en %@", model.editTarget ?? "—")) {
                TextField(tr("Tipo (p. ej. int[4] o MiEstructura)"), text: $newType)
                    .textFieldStyle(.roundedBorder).frame(width: 240).font(.body.monospaced())
                    .onSubmit(add)
                Button(tr("Añadir"), action: add).disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            if model.program == nil {
                NoProgramView()
            } else {
                GenericTable(rows: rows,
                             columns: [ColumnSpec(key: "type", title: tr("Tipo"), width: 180, mono: true),
                                       ColumnSpec(key: "size", title: tr("Tamaño"), width: 60),
                                       ColumnSpec(key: "value", title: tr("Valor"), width: 520, mono: true)],
                             storageKey: "typePreview", addressKey: nil,
                             actions: [RowAction(title: tr("Aplicar en el cursor")) { row in
                                 guard let address = model.editTarget else { return }
                                 model.run("createData", ["address": address, "type": row["type"]?.text ?? ""], namesChanged: false)
                             }, RowAction(title: tr("Quitar de la lista"), destructive: true) { row in
                                 stored = types.filter { $0 != row["type"]?.text }.joined(separator: "\n")
                             }])
            }
        }
        .task(id: "\(model.editTarget ?? "")|\(stored)|\(model.editCount)|\(model.activeSession ?? "")") {
            guard model.program != nil, let address = model.editTarget else { rows = []; return }
            rows = (try? await model.engine.call("typePreview", ["address": address, "types": types])) ?? []
        }
    }

    private func add() {
        let t = newType.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !types.contains(t) else { return }
        stored = (types + [t]).joined(separator: "\n")
        newType = ""
    }
}

// MARK: C headers

private struct TypeHeadersPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: TypeManagerState
    @State private var profiles: [JSONRow] = []
    @State private var profile = ""
    @State private var files = ""
    @State private var includes = ""
    @State private var options = ""
    @State private var destination = ""
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Leer cabeceras de C")) {
                Picker(tr("Perfil"), selection: $profile) {
                    Text(tr("Sin perfil")).tag("")
                    ForEach(profiles, id: \.self) { p in Text(p["name"]?.text ?? "").tag(p["name"]?.text ?? "") }
                }
                .fixedSize()
                .onChange(of: profile) { _, name in apply(profile: name) }
                Text(tr("Destino")).font(.caption).foregroundStyle(.secondary)
                TypeHomePicker(state: state, home: $destination)
                Button(tr("Leer")) { parse() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || lines(files).isEmpty || (destination.isEmpty && model.program == nil))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(tr("Archivos de cabecera (uno por línea)")).font(.caption.weight(.semibold))
                        Spacer()
                        Button(tr("Añadir archivos…")) {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = true
                            if panel.runModal() == .OK {
                                files = (lines(files) + panel.urls.map(\.path)).joined(separator: "\n")
                            }
                        }
                        .controlSize(.small)
                    }
                    editor($files, height: 130)
                    HStack {
                        Text(tr("Carpetas de inclusión (una por línea)")).font(.caption.weight(.semibold))
                        Spacer()
                        Button(tr("Añadir carpeta…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                includes = (lines(includes) + [url.path]).joined(separator: "\n")
                            }
                        }
                        .controlSize(.small)
                    }
                    editor($includes, height: 80)
                    Text(tr("Opciones del preprocesador (-D, -I…; una por línea)")).font(.caption.weight(.semibold))
                    editor($options, height: 110)
                    if busy { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result).font(.callout.monospaced()).foregroundStyle(failed ? Color.red : Color.primary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .task { profiles = (try? await model.engine.call("typeProfiles")) ?? [] }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.callout.monospaced())
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func apply(profile name: String) {
        guard let p = profiles.first(where: { $0["name"]?.text == name }) else { return }
        files = (p["headers"]?.array.map(\.text) ?? []).joined(separator: "\n")
        options = (p["options"]?.array.map(\.text) ?? []).joined(separator: "\n")
        includes = (p["includes"]?.array.map(\.text) ?? []).joined(separator: "\n")
    }

    private func parse() {
        busy = true
        result = nil
        Task {
            defer { busy = false }
            do {
                let r: JSONRow = try await model.engine.call("typeParseHeaders", ["where": destination, "files": lines(files),
                                                                                  "includes": lines(includes), "options": lines(options)])
                failed = r["ok"]?.bool != true
                result = tr("%@ tipos añadidos (%@ en total).", r["added"]?.text ?? "0", r["total"]?.text ?? "0")
                    + ((r["messages"]?.text ?? "").isEmpty ? "" : "\n\n" + (r["messages"]?.text ?? ""))
                if destination.isEmpty { await model.afterEdit(namesChanged: false) }
                state.revision += 1
            } catch {
                failed = true
                result = error.localizedDescription
            }
        }
    }
}

// MARK: - Uses of a type

struct TypeUsesRequest: Identifiable {
    let id = UUID()
    let path: String
    let field: String
}

/// Where a type (or one field) is used; double click goes there.
struct TypeUsesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TypeUsesRequest
    @State private var rows: [JSONRow] = []
    @State private var busy = true
    @State private var decompile = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(request.field.isEmpty ? tr("Usos de %@", request.path) : tr("Usos de %@", "\(request.path).\(request.field)"))
                    .font(.headline)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Toggle(tr("Buscar también en el código descompilado"), isOn: $decompile).toggleStyle(.checkbox)
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            GenericTable(rows: rows,
                         columns: [.address(), ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true),
                                   ColumnSpec(key: "context", title: tr("Contexto"), width: 420, mono: true),
                                   ColumnSpec(key: "kind", title: tr("Clase"), width: 90)],
                         storageKey: "typeUses",
                         onOpen: { row in if let a = row["address"]?.string, !a.isEmpty { model.go(a) } })
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .frame(width: 860, height: 460)
        .task(id: decompile) {
            busy = true
            defer { busy = false }
            do {
                rows = try await model.engine.call("typeUses", ["path": request.path, "field": request.field, "decompile": decompile])
            } catch { self.error = error.localizedDescription }
        }
    }
}
