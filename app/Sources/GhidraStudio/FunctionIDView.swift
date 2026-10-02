import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Function ID: databases of function hashes that name library code in stripped binaries.
struct FunctionIDView: View {
    @Environment(AppModel.self) private var model
    @State private var list: FidFileList?
    @State private var selected: String?
    @State private var newName = ""
    @State private var family = ""
    @State private var version = "1.0"
    @State private var variant = "default"
    @State private var programs = Set<String>()
    @State private var functionQuery = ""
    @State private var functions: [FidFunction] = []
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var showDebug = false

    private var files: [FidFileItem] { list?.files ?? [] }
    private var current: FidFileItem? { files.first { $0.path == selected } }

    private var candidates: [ProjectFile] {
        (model.project?.tree?.allFolders ?? []).flatMap(\.files).filter(\.program)
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 260, idealWidth: 290, maxWidth: 380, maxHeight: .infinity)
            detail.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .windowMinSize(800, 540)
        .task(id: model.engineReady) { await reload() }
        .onChange(of: selected) { _, _ in functions = [] }
        .sheet(isPresented: $showDebug) { FidDebugSheet(database: selected) }
        .toolbar {
            Button { showDebug = true } label: { Label(tr("Depurar y buscar"), systemImage: "ladybug") }
                .help(tr("Hash de la función actual, búsqueda por nombre o hash, estadísticas, reempaquetar y copias de solo lectura"))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section(tr("Tus bases de datos"), files.filter { !$0.installed })
                    section(tr("Incluidas con Ghidra"), files.filter(\.installed))
                }
                .padding(8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Nueva base de datos")).font(.caption.weight(.semibold))
                HStack {
                    TextField(tr("Nombre"), text: $newName).textFieldStyle(.roundedBorder)
                    Button(tr("Crear")) { create() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                Button(tr("Adjuntar un .fidb existente…")) { attach() }
            }
            .padding(10)
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [FidFileItem]) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
        if items.isEmpty {
            Text(tr("Ninguna todavía")).font(.caption).foregroundStyle(.tertiary)
        }
        ForEach(items) { f in
            HStack(spacing: 6) {
                Button { selected = f.path } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selected == f.path ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == f.path ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(f.name).lineLimit(1)
                            Text(tr("%@ bibliotecas", "\(f.libraries.count)")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Toggle("", isOn: Binding(get: { f.active }, set: { setActive(f, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help(tr("Usarla al analizar"))
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let db = current {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(db.name).font(.headline)
                            Text(db.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if !db.installed {
                            Button(tr("Quitar de la lista")) { run("fidDetach", ["path": db.path]) }
                                .help(tr("Deja de usarla; el archivo no se borra"))
                        }
                    }
                    if db.libraries.isEmpty {
                        Text(tr("Todavía no contiene ninguna biblioteca.")).foregroundStyle(.secondary)
                    }
                    ForEach(db.libraries, id: \.self) { lib in
                        HStack {
                            Image(systemName: "books.vertical").foregroundStyle(.tint)
                            Text("\(lib.family) \(lib.version)")
                            Text(lib.variant).foregroundStyle(.secondary)
                            Spacer()
                            Text(lib.language).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                Divider()
                if db.installed {
                    Text(tr("Las bases de datos incluidas con Ghidra son de solo lectura. Crea una propia para añadir tus bibliotecas."))
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                } else {
                    populateForm(db)
                }
                Divider()
                functionsSection(db)
            } else {
                ContentUnavailableView("Function ID", systemImage: "books.vertical",
                                       description: Text(tr("Guarda las funciones de programas ya analizados y con nombres en una base de datos. Al analizar otro binario que contenga el mismo código, Ghidra les pone el nombre automáticamente.")))
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if model.tasks["fid"] != nil { TaskProgressBar(task: "fid") } else { StatusLine(text: message, isError: failed) }
                Spacer()
                Button(tr("Aplicar Function ID a «%@»", model.program?.name ?? "—")) {
                    model.runAnalyzer("Function ID")
                    report(tr("Analizador Function ID lanzado sobre el programa activo."))
                }
                .buttonStyle(.glassProminent)
                .disabled(model.program == nil || model.analysis != nil)
                .help(tr("Ejecuta el analizador Function ID con las bases de datos activas"))
            }
            .padding(10)
        }
    }

    /// Search the functions stored in a database; in your own databases they can be excluded from matching.
    private func functionsSection(_ db: FidFileItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Funciones de la base de datos")).font(.callout.weight(.semibold))
            HStack {
                TextField(tr("Buscar por nombre"), text: $functionQuery).textFieldStyle(.roundedBorder)
                    .onSubmit { searchFunctions(db) }
                Button(tr("Buscar")) { searchFunctions(db) }.disabled(busy)
            }
            if !functions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(functions) { f in
                            HStack {
                                Text(f.name).monospaced().lineLimit(1).strikethrough(f.excluded)
                                Text(f.library).font(.caption).foregroundStyle(.secondary)
                                Text(tr("%@ instr.", "\(f.size)")).font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                                if !db.installed {
                                    Button(f.excluded ? tr("Volver a usar") : tr("Excluir")) { setExcluded(db, f, !f.excluded) }
                                        .controlSize(.small)
                                        .help(tr("Function ID no borra funciones: una excluida deja de usarse para nombrar"))
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(14)
    }

    private func populateForm(_ db: FidFileItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Añadir una biblioteca desde programas del proyecto")).font(.callout.weight(.semibold))
            HStack {
                TextField(tr("Nombre de la biblioteca"), text: $family).textFieldStyle(.roundedBorder)
                TextField(tr("Versión"), text: $version).textFieldStyle(.roundedBorder).frame(width: 90)
                TextField(tr("Variante"), text: $variant).textFieldStyle(.roundedBorder).frame(width: 110)
                    .help(tr("Por ejemplo el compilador u opciones: gcc-O2, debug…"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { f in
                        Button {
                            if programs.contains(f.path) { programs.remove(f.path) } else { programs.insert(f.path) }
                        } label: {
                            HStack {
                                Image(systemName: programs.contains(f.path) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(programs.contains(f.path) ? Color.accentColor : Color.secondary)
                                Text(f.path)
                                Spacer()
                                Text(f.processor ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                    if candidates.isEmpty {
                        Text(tr("El proyecto no tiene programas.")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 180)
            HStack {
                Button(tr("Añadir biblioteca")) { populate(db) }
                    .buttonStyle(.glassProminent)
                    .disabled(family.trimmingCharacters(in: .whitespaces).isEmpty || programs.isEmpty || busy)
                Text(tr("Los programas deben estar analizados y ser del mismo procesador."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func report(_ text: String?, error: Bool = false) {
        message = text
        failed = error
    }

    private func reload() async {
        guard model.engineReady else { return }
        do {
            let result: FidFileList = try await model.engine.call("fidFiles")
            list = result
            if current == nil { selected = result.files.first { !$0.installed }?.path }
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func run(_ method: String, _ params: [String: Any]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                list = try await model.engine.call(method, params)
                report(nil)
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        busy = true
        Task {
            defer { busy = false }
            do {
                let before = Set(files.map(\.path))
                let result: FidFileList = try await model.engine.call("fidCreate", ["name": name])
                list = result
                selected = result.files.first { !before.contains($0.path) }?.path ?? selected
                newName = ""
                report(nil)
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.title = tr("Adjuntar base de datos Function ID")
        if let fidb = UTType(filenameExtension: "fidb") { panel.allowedContentTypes = [fidb] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("fidAttach", ["path": url.path])
    }

    private func setActive(_ f: FidFileItem, _ active: Bool) {
        run("fidSetActive", ["path": f.path, "active": active])
    }

    private func searchFunctions(_ db: FidFileItem) {
        busy = true
        Task {
            defer { busy = false }
            do {
                functions = try await model.engine.call("fidFunctions", ["path": db.path, "query": functionQuery])
                report(functions.isEmpty ? tr("Ninguna función con ese nombre.") : nil)
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func setExcluded(_ db: FidFileItem, _ f: FidFunction, _ on: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.engine.call("fidSetFlag", ["path": db.path, "id": f.id, "flag": "fail", "on": on], as: Bool.self)
                functions = try await model.engine.call("fidFunctions", ["path": db.path, "query": functionQuery])
                report(nil)
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func populate(_ db: FidFileItem) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result: FidPopulateResult = try await model.engine.call("fidPopulate", [
                    "path": db.path, "family": family.trimmingCharacters(in: .whitespaces), "version": version,
                    "variant": variant, "programs": Array(programs),
                ])
                report(tr("%@ funciones añadidas · %@ descartadas por ser demasiado pequeñas o comunes",
                          "\(result.added)", "\(result.excluded)"))
                list = try? await model.engine.call("fidFiles")
                programs = []
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }
}
