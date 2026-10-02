import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model: project actions

extension AppModel {
    /// Unpacks an archived project (.zip of Studio or .gar of Ghidra) into a folder and opens it.
    func restoreProject() {
        let open = NSOpenPanel()
        open.title = tr("Restaurar un proyecto archivado")
        open.allowedContentTypes = [.zip, UTType(filenameExtension: "gar") ?? .data]
        guard open.runModal() == .OK, let archive = open.url else { return }
        let dest = NSOpenPanel()
        dest.title = tr("Carpeta donde restaurar el proyecto")
        dest.canChooseDirectories = true
        dest.canChooseFiles = false
        dest.canCreateDirectories = true
        guard dest.runModal() == .OK, let folder = dest.url else { return }
        Task {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // -n: never overwrite what is already in the folder
            p.arguments = ["-q", "-n", archive.path, "-d", folder.path]
            do {
                try p.run()
                p.waitUntilExit()
                let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0.hasSuffix(".gpr") }
                guard p.terminationStatus == 0, let gpr = found else {
                    errorMessage = tr("Ese archivo no contiene un proyecto de Ghidra.")
                    return
                }
                openProject(folder.appendingPathComponent(gpr).path)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func pasteProjectItem(into folder: String) {
        guard let item = projectClipboard else { return }
        Task {
            do {
                _ = try await engine.call("copyItem", ["path": item.path, "folder": item.folder, "dest": folder], as: JSONValue.self)
                await refreshProject()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func linkProjectItem(path: String, folder: Bool, into dest: String) {
        Task {
            do {
                _ = try await engine.call("linkItem", ["path": path, "folder": folder, "dest": dest, "relative": true], as: JSONValue.self)
                await refreshProject()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setReadOnly(path: String, _ on: Bool) {
        Task {
            do {
                _ = try await engine.call("setReadOnly", ["path": path, "on": on], as: JSONValue.self)
                await refreshProject()
                projectRevision += 1
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func requestSaveAs() {
        guard let program, let session = activeSession else { return }
        formRequest = FormRequest(
            title: tr("Guardar como"),
            message: tr("Guarda el programa con otro nombre en el proyecto y sigue trabajando en la copia."),
            fields: [FormField(key: "name", title: tr("Nombre"), value: program.name + "-copia", mono: false),
                     FormField(key: "folder", title: tr("Carpeta"), kind: .choice(projectFolders.map(\.path)), value: "/")],
            actionTitle: tr("Guardar")) { [self] values in
                let result: JSONRow = try await engine.call("saveAs", ["folder": values["folder"] ?? "/", "name": values["name"] ?? ""])
                await refreshProject()
                if let path = result["path"]?.string {
                    closeTab(session)
                    openProgram(domainPath: path)
                }
            }
    }

    func saveAll() {
        let dirty = dirtyTabs.map(\.id)
        Task {
            for id in dirty { _ = try? await engine.call("save", ["session": id], as: UndoState.self) }
            await refreshUndo()
            statusMessage = tr("%@ programas guardados", "\(dirty.count)")
        }
    }

    func closeOtherPrograms() {
        for tab in tabs where tab.id != activeSession { closeTab(tab.id) }
    }

    /// File ▸ Add To Program: loads a file into the open program.
    func requestAddToProgram() {
        guard program != nil else { return }
        let panel = NSOpenPanel()
        panel.title = tr("Añadir un archivo al programa")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let loaders: [JSONRow] = try await engine.call("addToProgramOptions", ["path": url.path])
                guard let first = loaders.first else {
                    throw EngineError.remote(tr("Ningún cargador puede añadir ese archivo a este programa."))
                }
                let options = first["options"]?.array.map(\.object) ?? []
                var fields = [FormField(key: "__loader", title: tr("Cargador"), kind: .choice(loaders.map { $0["loader"]?.text ?? "" }),
                                        value: first["loader"]?.text ?? "")]
                fields += options.map { o in
                    FormField(key: o["name"]?.text ?? "", title: o["name"]?.text ?? "", kind: o["type"]?.text == "bool" ? .toggle : .text,
                              value: o["value"]?.text ?? "")
                }
                formRequest = FormRequest(title: tr("Añadir %@ al programa", url.lastPathComponent),
                                          message: tr("Se cargan sus bytes como bloques de memoria nuevos."),
                                          fields: fields, actionTitle: tr("Añadir")) { [self] values in
                    var chosen = values
                    let loader = chosen.removeValue(forKey: "__loader") ?? ""
                    _ = try await engine.call("addToProgram", ["path": url.path, "loader": loader, "options": chosen], as: JSONValue.self)
                    segments = (try? await engine.call("segments")) ?? segments
                    await afterEdit(namesChanged: true)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Makes a new program out of the selected bytes.
    func requestImportSelection() {
        guard let selection = programSelection, let program else { return }
        formRequest = FormRequest(
            title: tr("Importar la selección como programa nuevo"),
            message: tr("Crea en el proyecto un programa con los bytes seleccionados, con el mismo procesador."),
            fields: [FormField(key: "name", title: tr("Nombre"), value: program.name + "-seleccion", mono: false),
                     FormField(key: "folder", title: tr("Carpeta"), kind: .choice(projectFolders.map(\.path)), value: "/")],
            actionTitle: tr("Importar")) { [self] values in
                let result: JSONRow = try await engine.call("importSelection", ["ranges": selection.ranges, "folder": values["folder"] ?? "/",
                                                                                "name": values["name"] ?? "seleccion"])
                await refreshProject()
                statusMessage = tr("Creado %@", result["path"]?.text ?? "")
            }
    }
}

// MARK: - Project tools window

struct ProjectToolsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("projectToolsPanel") private var panel = "table"

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { panel }, set: { if let v = $0 { panel = v } })) {
                Label(tr("Tabla del proyecto"), systemImage: "tablecells").tag("table")
                Label(tr("Otros proyectos"), systemImage: "folder.badge.questionmark").tag("other")
                Label(tr("Check-outs del proyecto"), systemImage: "lock.open").tag("checkouts")
                Label(tr("Rutas de bibliotecas"), systemImage: "books.vertical").tag("libraries")
                Label(tr("Sistemas de archivos"), systemImage: "externaldrive").tag("fs")
                Label(tr("Almacenamiento"), systemImage: "internaldrive").tag("storage")
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                switch panel {
                case "other": OtherProjectPanel()
                case "checkouts": CheckoutsPanel()
                case "libraries": LibraryPathsPanel()
                case "fs": FileSystemsPanel()
                case "storage": StoragePanel()
                default: ProjectTablePanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .windowMinSize(1000, 540)
        .sheet(item: model.formBinding("project")) { request in FormSheet(request: request) }
    }
}

private struct ProjectTablePanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [JSONRow] = []

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Todos los archivos del proyecto")) {
                Button(tr("Actualizar")) { Task { await load() } }
            }
            Divider()
            GenericTable(rows: rows,
                         columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 200),
                                   ColumnSpec(key: "folder", title: tr("Carpeta"), width: 140),
                                   ColumnSpec(key: "type", title: tr("Clase"), width: 90),
                                   ColumnSpec(key: "format", title: tr("Formato"), width: 150),
                                   ColumnSpec(key: "processor", title: tr("Procesador"), width: 90),
                                   ColumnSpec(key: "language", title: tr("Lenguaje"), width: 170, mono: true),
                                   ColumnSpec(key: "functions", title: tr("Funciones"), width: 70),
                                   ColumnSpec(key: "modifiedText", title: tr("Modificado"), width: 130),
                                   ColumnSpec(key: "readOnly", title: tr("Solo lectura"), width: 80),
                                   ColumnSpec(key: "link", title: tr("Enlace"), width: 60),
                                   ColumnSpec(key: "versioned", title: tr("Versionado"), width: 80),
                                   ColumnSpec(key: "checkedOut", title: "Check-out", width: 80),
                                   ColumnSpec(key: "md5", title: "MD5", width: 240, mono: true)],
                         storageKey: "projectTable", addressKey: nil,
                         actions: [RowAction(title: tr("Abrir")) { row in open(row) },
                                   RowAction(title: tr("Poner o quitar solo lectura")) { row in
                                       model.setReadOnly(path: row["path"]?.text ?? "", !(row["readOnly"]?.bool ?? false))
                                   },
                                   RowAction(title: tr("Copiar (para pegar en una carpeta)")) { row in
                                       model.projectClipboard = ProjectClip(path: row["path"]?.text ?? "", folder: false)
                                   },
                                   RowAction(title: tr("Mostrar en el proyecto")) { row in open(row) }],
                         onOpen: { row in open(row) })
        }
        .task(id: "\(model.project?.gpr ?? "")|\(model.projectRevision)") { await load() }
    }

    private func open(_ row: JSONRow) {
        if let path = row["path"]?.string, row["type"]?.text == "Program" { model.openProgram(domainPath: path) }
    }

    private func load() async {
        let list: [JSONRow] = (try? await model.engine.call("projectTable")) ?? []
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        rows = list.map { row in
            var r = row
            if let ms = row["modified"]?.int { r["modifiedText"] = .string(formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))) }
            return r
        }
    }
}

private struct OtherProjectPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("viewedProject") private var gpr = ""
    @State private var rows: [JSONRow] = []
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(gpr.isEmpty ? tr("Ver otro proyecto en modo lectura") : (gpr as NSString).lastPathComponent) {
                Button(tr("Elegir proyecto…")) {
                    let panel = NSOpenPanel()
                    if let type = UTType(filenameExtension: "gpr") { panel.allowedContentTypes = [type] }
                    if panel.runModal() == .OK, let url = panel.url { close(); gpr = url.path; load() }
                }
                Button(tr("Cerrar")) { close(); gpr = ""; rows = [] }.disabled(gpr.isEmpty)
            }
            Divider()
            GenericTable(rows: rows,
                         columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 220),
                                   ColumnSpec(key: "folder", title: tr("Carpeta"), width: 160),
                                   ColumnSpec(key: "type", title: tr("Clase"), width: 90),
                                   ColumnSpec(key: "format", title: tr("Formato"), width: 150),
                                   ColumnSpec(key: "processor", title: tr("Procesador"), width: 90),
                                   ColumnSpec(key: "functions", title: tr("Funciones"), width: 70)],
                         storageKey: "otherProject", addressKey: nil,
                         actions: [RowAction(title: tr("Copiar a este proyecto")) { row in copy([row]) }],
                         multiActions: [MultiAction(title: tr("Copiar las elegidas a este proyecto")) { rows in copy(rows) }])
            Divider()
            Text(message ?? tr("El otro proyecto se abre sin poder cambiarlo; copia a tu proyecto lo que necesites."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .task { if !gpr.isEmpty { load() } }
    }

    private func close() {
        guard !gpr.isEmpty else { return }
        let path = gpr
        Task { _ = try? await model.engine.call("closeView", ["path": path], as: JSONValue.self) }
    }

    private func load() {
        Task {
            do {
                let result: JSONRow = try await model.engine.call("viewProject", ["path": gpr])
                rows = result["files"]?.array.map(\.object) ?? []
                message = nil
            } catch {
                rows = []
                message = error.localizedDescription
            }
        }
    }

    private func copy(_ list: [JSONRow]) {
        Task {
            do {
                let created: [String] = try await model.engine.call("copyFromView", ["path": gpr, "files": list.map { $0["path"]?.text ?? "" },
                                                                                     "folder": "/"])
                await model.refreshProject()
                message = tr("%@ archivos copiados a la raíz del proyecto", "\(created.count)")
            } catch { message = error.localizedDescription }
        }
    }
}

private struct CheckoutsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [JSONRow] = []
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Archivos con check-out o que tapan a uno versionado")) {
                Button(tr("Buscar")) { load() }
            }
            Divider()
            GenericTable(rows: rows,
                         columns: [ColumnSpec(key: "path", title: tr("Archivo"), width: 300),
                                   ColumnSpec(key: "checkoutVersion", title: tr("Versión del check-out"), width: 130),
                                   ColumnSpec(key: "version", title: tr("Última versión"), width: 100),
                                   ColumnSpec(key: "exclusive", title: tr("Exclusivo"), width: 70),
                                   ColumnSpec(key: "modifiedSinceCheckout", title: tr("Con cambios"), width: 90),
                                   ColumnSpec(key: "hijacked", title: tr("Tapa a uno versionado"), width: 140)],
                         storageKey: "findCheckouts", addressKey: nil,
                         actions: [RowAction(title: tr("Deshacer el secuestro (guardando una copia)")) { row in undo(row) },
                                   RowAction(title: tr("Abrir")) { row in if let p = row["path"]?.string { model.openProgram(domainPath: p) } }])
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .task { load() }
    }

    private func load() {
        Task {
            do {
                rows = try await model.engine.call("vcFindCheckouts")
                message = tr("%@ archivos", "\(rows.count)")
            } catch { message = error.localizedDescription }
        }
    }

    private func undo(_ row: JSONRow) {
        Task {
            do {
                let result: JSONRow = try await model.engine.call("vcUndoHijack", ["path": row["path"]?.text ?? "", "keep": true])
                await model.refreshProject()
                message = tr("Hecho. Copia guardada en %@", result["kept"]?.text ?? "—")
                load()
            } catch { message = error.localizedDescription }
        }
    }
}

private struct LibraryPathsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var paths: [String] = []
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Dónde se buscan las bibliotecas al importar")) {
                Button(tr("Añadir carpeta o archivo…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { save(paths + [url.path]) }
                }
                Button(tr("Subir")) { move(-1) }.disabled(selected == nil)
                Button(tr("Bajar")) { move(1) }.disabled(selected == nil)
                Button(tr("Quitar")) { save(paths.filter { $0 != selected }) }.disabled(selected == nil)
                Button(tr("Restaurar")) { save([]) }
            }
            Divider()
            List(paths, id: \.self, selection: $selected) { p in
                Text(p).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            Divider()
            Text(tr("Se recorren en orden. «.» es la carpeta del programa que se importa."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .task { paths = (try? await model.engine.call("libraryPaths")) ?? [] }
    }

    private func move(_ delta: Int) {
        guard let selected, let i = paths.firstIndex(of: selected), paths.indices.contains(i + delta) else { return }
        var list = paths
        list.swapAt(i, i + delta)
        save(list)
    }

    private func save(_ list: [String]) {
        Task { paths = (try? await model.engine.call("setLibraryPaths", ["paths": list])) ?? paths }
    }
}

private struct FileSystemsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [JSONRow] = []
    @State private var passwords = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Sistemas de archivos abiertos")) {
                Button(tr("Explorar un archivo…")) {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url { model.containerRequest = ContainerRequest(url: url) }
                }
                Button(tr("Cerrar los que no se usan")) { Task { rows = (try? await model.engine.call("fsCloseUnused")) ?? [] } }
                Button(tr("Actualizar")) { Task { rows = (try? await model.engine.call("fsMounted")) ?? [] } }
            }
            Divider()
            GenericTable(rows: rows,
                         columns: [ColumnSpec(key: "container", title: tr("Archivo"), width: 240),
                                   ColumnSpec(key: "type", title: tr("Sistema"), width: 100),
                                   ColumnSpec(key: "fsrl", title: "FSRL", width: 560, mono: true)],
                         storageKey: "fsMounted", addressKey: nil)
            Divider()
            HStack {
                Text(tr("Contraseñas para contenedores cifrados (una por línea)")).font(.caption)
                TextField("", text: $passwords, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                Button(tr("Usar")) {
                    let list = passwords.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    Task { _ = try? await model.engine.call("fsPasswords", ["passwords": list], as: JSONValue.self) }
                }
            }
            .controlSize(.small)
            .padding(8)
        }
        .task { rows = (try? await model.engine.call("fsMounted")) ?? [] }
    }
}

private struct StoragePanel: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSONRow = [:]
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Almacenamiento del proyecto")).font(.headline)
            Text(info["directory"]?.text ?? "—").font(.callout.monospaced()).textSelection(.enabled)
            Text(info["indexed"]?.bool == true ? tr("Este proyecto ya usa el almacenamiento indexado (nombres largos, muchas carpetas).")
                 : tr("Este proyecto usa el almacenamiento antiguo."))
            Divider()
            Text(tr("Convertir un proyecto antiguo al almacenamiento indexado")).font(.headline)
            Text(tr("El proyecto debe estar cerrado: elige su archivo .gpr. La conversión no se puede deshacer."))
                .font(.caption).foregroundStyle(.secondary)
            Button(tr("Elegir proyecto y convertir…")) {
                let panel = NSOpenPanel()
                if let type = UTType(filenameExtension: "gpr") { panel.allowedContentTypes = [type] }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                guard url.path != model.project?.gpr else { message = tr("Ese es el proyecto abierto: abre otro antes."); return }
                guard model.confirm(tr("¿Convertir «%@»?", url.lastPathComponent), tr("No se puede deshacer."), action: tr("Convertir")) else { return }
                Task {
                    do {
                        let result: JSONRow = try await model.engine.call("convertStorage", ["path": url.path])
                        message = (result["log"]?.text ?? "") + (result["indexed"]?.bool == true ? tr("Convertido.") : "")
                    } catch { message = error.localizedDescription }
                }
            }
            if let message { Text(message).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: model.project?.gpr) { info = (try? await model.engine.call("projectStorage")) ?? [:] }
    }
}

// MARK: - File inside a container: information, preview, extraction

struct FSFileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: FSEntry
    @State private var info: [JSONRow] = []
    @State private var text: String?
    @State private var image: NSImage?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.name).font(.headline).lineLimit(1)
                Spacer()
                Button(tr("Extraer…")) { extract() }
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            HSplitView {
                List(info, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row["name"]?.text ?? "").font(.caption).foregroundStyle(.secondary)
                        Text(row["value"]?.text ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    }
                }
                .frame(minWidth: 260)
                ZStack {
                    Color(nsColor: Theme.background)
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(12)
                    } else if let text {
                        ScrollView {
                            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    } else {
                        Text(message ?? tr("Sin vista previa")).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 360)
            }
        }
        .frame(width: 820, height: 480)
        .task {
            info = (try? await model.engine.call("fsInfo", ["path": entry.fsrl])) ?? []
            guard !entry.directory else { return }
            do {
                let result: JSONRow = try await model.engine.call("fsRead", ["path": entry.fsrl, "max": 2 << 20])
                guard let data = Data(base64Encoded: result["base64"]?.text ?? "") else { return }
                if let picture = NSImage(data: data) {
                    image = picture
                } else if let string = String(data: data.prefix(200_000), encoding: .utf8), !string.contains("\u{0}") {
                    text = string
                } else {
                    // not text: a hex dump of the beginning
                    text = stride(from: 0, to: min(data.count, 4096), by: 16).map { row in
                        String(format: "%08x  ", row) + data[row..<min(row + 16, data.count)].map { String(format: "%02x", $0) }.joined(separator: " ")
                    }.joined(separator: "\n")
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func extract() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let result: JSONRow = try await model.engine.call("fsExtract", ["path": entry.fsrl, "output": url.path])
                message = tr("%@ archivos extraídos", result["files"]?.text ?? "0")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}
