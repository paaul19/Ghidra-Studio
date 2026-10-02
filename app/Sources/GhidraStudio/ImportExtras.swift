import AppKit
import SwiftUI

/// Several files, folders or containers to import in one go.
struct BatchRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Batch import

/// The classic's batch importer: what was found (grouped by loader), which language each group gets,
/// how deep containers are opened and how project paths are built.
struct BatchImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: BatchRequest
    @State private var batch: JSONRow?
    @State private var depth = 2
    @State private var folder = "/"
    @State private var stripLeading = true
    @State private var stripContainers = false
    @State private var mirror = false
    @State private var choices: [Int: String] = [:]
    @State private var disabled: Set<Int> = []
    @State private var busy = false
    @State private var message: String?
    @State private var shownGroup: Int?

    private var groups: [JSONRow] { batch?["groups"]?.array.map(\.object) ?? [] }
    private var sources: [JSONRow] { batch?["sources"]?.array.map(\.object) ?? [] }
    private var batchID: String { batch?["id"]?.text ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.down.right.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Importar por lotes")).font(.title3.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            GroupBox(tr("Orígenes")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sources, id: \.self) { s in
                        HStack {
                            Text(s["path"]?.text ?? "").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(tr("%@ archivos · %@ contenedores", s["files"]?.text ?? "0", s["containers"]?.text ?? "0"))
                                .font(.caption).foregroundStyle(.secondary)
                            Button { remove(s["fsrl"]?.text ?? "") } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help(tr("Quitar este origen"))
                        }
                    }
                    HStack {
                        Button(tr("Añadir archivos o carpetas…")) { addSources() }
                        Spacer()
                        Stepper(tr("Profundidad en contenedores: %@", "\(depth)"), value: $depth, in: 0...10)
                            .onChange(of: depth) { _, _ in scan([]) }
                            .help(tr("Cuántos contenedores anidados (zip dentro de zip, imágenes…) se abren para buscar programas"))
                    }
                }
                .padding(4)
            }
            GroupBox(tr("Qué se importa")) {
                if groups.isEmpty {
                    Text(busy ? tr("Explorando…") : tr("No se ha encontrado ningún programa que Ghidra sepa cargar"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(groups, id: \.self) { g in groupRow(g) }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 220)
                }
            }
            GroupBox(tr("Destino")) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(tr("Carpeta del proyecto"), selection: $folder) {
                        Text("/").tag("/")
                        ForEach(model.projectFolders.filter { $0.path != "/" }, id: \.path) { f in Text(f.path).tag(f.path) }
                    }
                    Toggle(tr("Quitar la ruta inicial (las rutas empiezan en el origen elegido)"), isOn: $stripLeading)
                    Toggle(tr("Quitar las rutas de los contenedores (zip, imágenes…)"), isOn: $stripContainers)
                    Toggle(tr("Replicar el sistema de archivos (enlaces incluidos)"), isOn: $mirror)
                }
                .padding(4)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(4) }
            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button(tr("Importar")) { importAll() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                    .disabled(busy || groups.isEmpty || disabled.count == groups.count)
            }
        }
        .padding(22)
        .frame(width: 700)
        .task { scan(request.urls.map(\.path)) }
    }

    private var summary: String {
        guard let batch else { return tr("Explorando…") }
        var text = tr("%@ programas en %@ grupos", batch["total"]?.text ?? "0", "\(groups.count)")
        if batch["truncated"]?.bool == true { text += " · " + tr("hay contenedores más profundos sin abrir") }
        return text
    }

    @ViewBuilder
    private func groupRow(_ g: JSONRow) -> some View {
        let index = g["index"]?.int ?? 0
        let specs = g["specs"]?.array.map(\.text) ?? []
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle("", isOn: Binding(get: { !disabled.contains(index) },
                                         set: { if $0 { disabled.remove(index) } else { disabled.insert(index) } }))
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 0) {
                    Text(g["loader"]?.text ?? "").font(.callout.weight(.medium))
                    Text(tr("%@ archivos", g["count"]?.text ?? "0") + ((g["extension"]?.text ?? "").isEmpty ? "" : " · ." + (g["extension"]?.text ?? "")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 190, alignment: .leading)
                Picker("", selection: Binding(get: { choices[index] ?? g["selected"]?.text ?? "" }, set: { choices[index] = $0 })) {
                    ForEach(specs, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Button { shownGroup = shownGroup == index ? nil : index } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.borderless).help(tr("Ver los archivos del grupo"))
            }
            if shownGroup == index {
                ForEach(g["files"]?.array.map(\.text) ?? [], id: \.self) { f in
                    Text(f).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .padding(.leading, 28)
                }
            }
        }
    }

    private func scan(_ paths: [String]) {
        busy = true
        message = nil
        Task {
            do {
                var params: [String: Any] = ["sources": paths, "depth": depth]
                if !batchID.isEmpty { params["id"] = batchID }
                batch = try await model.engine.call("batchScan", params)
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func remove(_ fsrl: String) {
        Task {
            do { batch = try await model.engine.call("batchRemove", ["id": batchID, "fsrl": fsrl]) }
            catch { message = error.localizedDescription }
        }
    }

    private func addSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        scan(panel.urls.map(\.path))
    }

    private func close() {
        let id = batchID
        if !id.isEmpty { Task { _ = try? await model.engine.call("batchClose", ["id": id], as: Bool.self) } }
        dismiss()
    }

    private func importAll() {
        busy = true
        var chosen: [String: String] = [:]
        for g in groups {
            let index = g["index"]?.int ?? 0
            chosen["\(index)"] = disabled.contains(index) ? "off" : (choices[index] ?? g["selected"]?.text ?? "")
        }
        Task {
            do {
                let result: JSONRow = try await model.engine.call("batchImport", [
                    "id": batchID, "folder": folder, "groups": chosen, "stripLeading": stripLeading,
                    "stripContainers": stripContainers, "mirror": mirror,
                ])
                await model.refreshProject()
                model.sidebarTab = .project
                let errors = result["errors"]?.array.map(\.text) ?? []
                let count = result["imported"]?.array.count ?? 0
                model.errorMessage = errors.isEmpty
                    ? tr("Se importaron %@ archivos al proyecto. Ábrelos desde la pestaña Proyecto.", "\(count)")
                    : tr("Importados: %@. No se pudieron importar: %@", "\(count)", errors.joined(separator: "\n"))
                dismiss()
            } catch {
                message = error.localizedDescription
                busy = false
            }
        }
    }
}

// MARK: - Format actions of the container browser

extension AppModel {
    /// The Java decompiler used for JARs and APKs (JAD's executable or a CFR jar); asks for it the first time.
    func javaDecompiler(ask: Bool) -> String? {
        let saved = UserDefaults.standard.string(forKey: "javaDecompiler") ?? ""
        if !ask, FileManager.default.fileExists(atPath: saved) { return saved }
        let panel = NSOpenPanel()
        panel.title = tr("Descompilador de Java")
        panel.message = tr("Elige el ejecutable de JAD o el .jar de CFR. Ghidra no trae ninguno.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: "javaDecompiler")
        return url.path
    }

    private func chooseOutput(_ title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Runs one of the container actions and reports what it produced.
    private func containerAction(_ method: String, _ params: [String: Any], reveal: Bool, done: @escaping (JSONRow) -> String) {
        Task {
            do {
                let result: JSONRow = try await engine.call(method, params)
                await refreshProject()
                errorMessage = done(result)
                if reveal, let path = result["path"]?.string {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func createKeyTemplate(_ source: String, overwrite: Bool = false) {
        Task {
            do {
                let result: JSONRow = try await engine.call("keyTemplate", ["path": source, "overwrite": overwrite])
                let path = result["path"]?.text ?? ""
                if result["exists"]?.bool == true {
                    let alert = NSAlert()
                    alert.messageText = tr("El archivo de claves ya existe")
                    alert.informativeText = tr("¿Sustituirlo por una plantilla vacía? Se perderán las claves que tenga.")
                    alert.addButton(withTitle: tr("Sustituir"))
                    alert.addButton(withTitle: tr("Abrir el que hay"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        createKeyTemplate(source, overwrite: true)
                        return
                    }
                }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                if result["exists"]?.bool != true {
                    errorMessage = tr("Plantilla creada con %@ entradas. Rellena KEY e IV de cada archivo cifrado y vuelve a abrir el contenedor.", result["entries"]?.text ?? "0")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func loadIOSKernel(_ source: String) {
        let alert = NSAlert()
        alert.messageText = tr("¿Cargar el kernel de iOS?")
        alert.informativeText = tr("Se importará al proyecto el kernel con todas sus extensiones (KEXT). Puede tardar.")
        alert.addButton(withTitle: tr("Cargar"))
        alert.addButton(withTitle: tr("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        containerAction("loadKernel", ["path": source, "folder": "/"], reveal: false) { result in
            let errors = result["errors"]?.array.map(\.text) ?? []
            return tr("Se importaron %@ extensiones del kernel.", "\(result["imported"]?.array.count ?? 0)")
                + (errors.isEmpty ? "" : "\n" + errors.prefix(8).joined(separator: "\n"))
        }
    }

    func decompileJar(_ source: String, name: String) {
        guard let tool = javaDecompiler(ask: false),
              let output = chooseOutput(tr("Carpeta para el código descompilado"), name: name + "-src") else { return }
        containerAction("decompileJar", ["path": source, "output": output.path, "tool": tool], reveal: true) { result in
            let log = result["log"]?.array.map(\.text) ?? []
            return tr("%@ archivos de código Java.", result["sources"]?.text ?? "0") + (log.isEmpty ? "" : "\n" + log.prefix(8).joined(separator: "\n"))
        }
    }

    func exportEclipseProject(_ source: String, name: String) {
        guard let output = chooseOutput(tr("Carpeta del proyecto de Eclipse"), name: name + "-eclipse") else { return }
        // the decompiler is optional here: without it the project has the classes, not their source
        let saved = UserDefaults.standard.string(forKey: "javaDecompiler") ?? ""
        let tool = FileManager.default.fileExists(atPath: saved) ? saved : ""
        containerAction("eclipseProject", ["path": source, "output": output.path, "tool": tool], reveal: true) { result in
            let log = result["log"]?.array.map(\.text) ?? []
            return tr("Proyecto de Eclipse creado con %@ archivos de código Java.", result["sources"]?.text ?? "0")
                + (tool.isEmpty ? "\n" + tr("Sin descompilador de Java: las clases se han dejado sin descompilar.") : "")
                + (log.isEmpty ? "" : "\n" + log.prefix(8).joined(separator: "\n"))
        }
    }
}

/// The menu with the format actions, for a container or a file inside one.
struct ContainerActionsMenu: View {
    @Environment(AppModel.self) private var model
    /// Path or FSRL of the container itself.
    let container: String
    let containerName: String
    /// The selected file inside it, if any.
    let entry: FSEntry?

    var body: some View {
        Menu(tr("Formatos")) {
            Button(tr("Crear plantilla de claves…")) { model.createKeyTemplate(container) }
            Button(tr("Cargar kernel de iOS")) { model.loadIOSKernel(container) }
            Divider()
            Button(tr("Descompilar JAR…")) { model.decompileJar(target, name: targetName) }
            Button(tr("Exportar proyecto de Eclipse (APK)…")) { model.exportEclipseProject(target, name: targetName) }
            Divider()
            Button(tr("Elegir descompilador de Java…")) { _ = model.javaDecompiler(ask: true) }
        }
        .fixedSize()
    }

    private var target: String { entry.map { $0.directory ? container : $0.fsrl } ?? container }
    private var targetName: String { entry.map { $0.directory ? containerName : $0.name } ?? containerName }
}
