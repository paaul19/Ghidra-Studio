import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model: analysis configurations, scripts with shortcuts, Ghidra URLs

extension AppModel {
    func loadAnalysisConfigs() {
        Task { analysisConfigs = (try? await engine.call("analysisConfigs")) ?? [] }
    }

    func requestSaveAnalysisConfig() {
        formRequest = FormRequest(
            title: tr("Guardar la configuración de análisis"),
            message: tr("Guarda qué analizadores están activos y sus opciones, para aplicarlos a otros programas. Ghidra clásico ve las mismas configuraciones."),
            fields: [FormField(key: "name", title: tr("Nombre"), mono: false)],
            actionTitle: tr("Guardar")) { [self] values in
                let name = (values["name"] ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw EngineError.remote(tr("Escribe un nombre.")) }
                analysisConfigs = try await engine.call("saveAnalysisConfig", ["name": name])
            }
    }

    func applyAnalysisConfig(_ name: String) {
        Task {
            do {
                _ = try await engine.call("applyAnalysisConfig", ["name": name], as: JSONValue.self)
                await refreshUndo()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteAnalysisConfig(_ name: String) {
        Task { analysisConfigs = (try? await engine.call("deleteAnalysisConfig", ["name": name])) ?? [] }
    }

    /// Analyzes every open program of the same processor with this program's options.
    func analyzeAllOpen() {
        Task {
            do {
                let started: [String] = try await engine.call("analyzeAllOpen")
                statusMessage = tr("Analizando %@ programas", "\(started.count)")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: scripts

    /// Script path → shortcut spec ("cmd+opt+1").
    var scriptShortcuts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "scriptShortcuts") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "scriptShortcuts"); scriptShortcutsRevision += 1 }
    }

    var lastScript: String? {
        get { UserDefaults.standard.string(forKey: "lastScript") }
        set { UserDefaults.standard.set(newValue, forKey: "lastScript") }
    }

    /// Runs a script by path on the open program (from a menu or a shortcut); the output goes to an alert.
    func runScript(path: String) {
        guard program != nil else { return }
        lastScript = path
        Task {
            do {
                var params: [String: Any] = ["path": path]
                if let address = editTarget { params["address"] = address }
                let result: ScriptResult = try await engine.call("runScript", params)
                await afterEdit(namesChanged: true)
                let name = (path as NSString).lastPathComponent
                if let error = result.error {
                    errorMessage = "\(name): \(error)"
                } else if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = "\(name)\n\n\(String(result.output.suffix(1500)))"
                } else {
                    statusMessage = tr("%@ terminó en %@ ms", name, "\(result.millis)")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Ghidra URLs

    /// Opens ghidra:/path/to/project?/folder/program (and tells what to do for server URLs).
    func openGhidraURL(_ text: String) {
        Task {
            do {
                let info: JSONRow = try await engine.call("resolveURL", ["url": text])
                let path = info["path"]?.text ?? "/"
                if info["local"]?.bool == true {
                    guard info["exists"]?.bool == true, let gpr = info["gpr"]?.string else {
                        throw EngineError.remote(tr("El proyecto de esa URL no existe en este Mac."))
                    }
                    if project?.gpr == gpr {
                        if path != "/" { openProgram(domainPath: path) }
                    } else {
                        if path != "/" { programAfterProject(path) }
                        openProject(gpr)
                    }
                } else {
                    if project?.server?.repository == info["repository"]?.text, path != "/" {
                        // the open project is connected to that repository: the file opens through it
                        openProgram(domainPath: path)
                    } else if path == "/" {
                        errorMessage = tr("Esa URL es del repositorio «%@» en %@, no de un programa. Para ver el repositorio abre su proyecto compartido (Herramientas ▸ Ghidra Server).",
                                          info["repository"]?.text ?? "", info["host"]?.text ?? "")
                    } else {
                        // any other shared repository: straight from the server, read-only, like GhidraGo
                        openServerURL(text, user: nil, password: nil)
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func requestOpenGhidraURL() {
        formRequest = FormRequest(
            title: tr("Abrir una URL de Ghidra"),
            message: tr("Por ejemplo ghidra:/Users/yo/proyectos/MiProyecto?/carpeta/programa"),
            fields: [FormField(key: "url", title: "URL", value: NSPasteboard.general.string(forType: .string).flatMap { $0.hasPrefix("ghidra:") ? $0 : nil } ?? "")],
            actionTitle: tr("Abrir")) { [self] values in
                openGhidraURL(values["url"] ?? "")
            }
    }

    func copyGhidraURL() {
        Task {
            do {
                let url: String = try await engine.call("programURL")
                copyToPasteboard(url)
                statusMessage = tr("URL copiada")
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Validators

struct ValidatorPanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [JSONRow] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Validar el programa después del análisis")) {
                if busy { ProgressView().controlSize(.small) }
                Button(tr("Ejecutar los validadores")) { run() }.disabled(busy)
            }
            Divider()
            GenericTable(rows: rows,
                         columns: [ColumnSpec(key: "name", title: tr("Validador"), width: 260),
                                   ColumnSpec(key: "statusText", title: tr("Resultado"), width: 110),
                                   ColumnSpec(key: "message", title: tr("Mensaje"), width: 520),
                                   ColumnSpec(key: "description", title: tr("Qué comprueba"), width: 420)],
                         storageKey: "validators", addressKey: nil)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
    }

    private func run() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let list: [JSONRow] = try await model.engine.call("validate")
                rows = list.map { row in
                    var r = row
                    switch row["status"]?.text {
                    case "Passed": r["statusText"] = .string(tr("Correcto"))
                    case "Warning": r["statusText"] = .string(tr("Aviso"))
                    case "Error": r["statusText"] = .string(tr("Error"))
                    case "Cancelled": r["statusText"] = .string(tr("Cancelado"))
                    default: r["statusText"] = .string(row["status"]?.text ?? "")
                    }
                    return r
                }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Debug file locations (DWARF and PDB)

struct DebugFilesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var dwarfStorage = ""
    @State private var dwarfLocations = ""
    @State private var dwarfStatus: [JSONRow] = []
    @State private var pdbStorage = ""
    @State private var pdbLocations = ""
    @State private var known: [JSONRow] = []
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Archivos de depuración DWARF externos")).font(.headline)
                Text(tr("Dónde busca Ghidra el archivo .debug o .dSYM que acompaña a un programa: carpetas, árboles build-id://carpeta, debuglink://carpeta y servidores debuginfod (https://…). Una ubicación por línea."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                field(tr("Carpeta local donde se guardan las descargas"), $dwarfStorage)
                editor($dwarfLocations)
                if !dwarfStatus.isEmpty {
                    ForEach(dwarfStatus, id: \.self) { p in
                        Text("\(p["status"]?.text ?? "")  \(p["description"]?.text ?? p["name"]?.text ?? "")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Button(tr("Guardar")) { saveDwarf() }
                    Button(tr("Añadir carpeta…")) {
                        if let path = chooseFolder() { dwarfLocations = (lines(dwarfLocations) + [path]).joined(separator: "\n") }
                    }
                }
                Divider()
                Text(tr("Servidores de símbolos PDB")).font(.headline)
                Text(tr("Lista de servidores y carpetas donde se buscan los .pdb, en orden. La primera carpeta local es donde se guardan."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                field(tr("Carpeta local de símbolos"), $pdbStorage)
                editor($pdbLocations)
                HStack {
                    Button(tr("Guardar")) { savePdb() }
                    Menu(tr("Añadir un servidor conocido")) {
                        ForEach(known, id: \.self) { k in
                            Button("\(k["location"]?.text ?? "") (\(k["category"]?.text ?? ""))") {
                                pdbLocations = (lines(pdbLocations) + [k["location"]?.text ?? ""]).joined(separator: "\n")
                            }
                        }
                    }
                    .fixedSize()
                    Button(tr("Elegir carpeta local…")) { if let path = chooseFolder() { pdbStorage = path } }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.activeSession) { await load() }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.caption)
            TextField("", text: text).textFieldStyle(.roundedBorder).font(.callout.monospaced())
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.callout.monospaced())
            .frame(height: 90)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func show(dwarf: JSONRow) {
        dwarfStorage = dwarf["storage"]?.text ?? ""
        dwarfStatus = dwarf["providers"]?.array.map(\.object) ?? []
        dwarfLocations = dwarfStatus.map { $0["name"]?.text ?? "" }.joined(separator: "\n")
    }

    private func show(pdb: JSONRow) {
        pdbStorage = pdb["storage"]?.text ?? ""
        pdbLocations = (pdb["servers"]?.array.map(\.object) ?? []).map { $0["name"]?.text ?? "" }.joined(separator: "\n")
        known = pdb["known"]?.array.map(\.object) ?? []
    }

    private func load() async {
        if let d: JSONRow = try? await model.engine.call("dwarfLocations") { show(dwarf: d) }
        if let p: JSONRow = try? await model.engine.call("pdbServers") { show(pdb: p) }
    }

    private func saveDwarf() {
        Task {
            do {
                // the stored storage keeps its scheme; a plain path is a new folder
                let storage = dwarfStorage.contains("$") ? "" : dwarfStorage
                show(dwarf: try await model.engine.call("setDwarfLocations", ["storage": storage, "locations": lines(dwarfLocations)]))
                message = tr("Ubicaciones DWARF guardadas")
                failed = false
            } catch { message = error.localizedDescription; failed = true }
        }
    }

    private func savePdb() {
        Task {
            do {
                show(pdb: try await model.engine.call("setPdbServers", ["storage": pdbStorage == "." ? "" : pdbStorage,
                                                                         "locations": lines(pdbLocations)]))
                message = tr("Servidores PDB guardados")
                failed = false
            } catch { message = error.localizedDescription; failed = true }
        }
    }
}

// MARK: - Function byte patterns

struct FunctionPatternsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var first = 8
    @State private var pre = 4
    @State private var instructions = 3
    @State private var result: JSONRow = [:]
    @State private var which = "first"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Cómo empiezan las funciones de este programa")) {
                Stepper(tr("%@ primeros bytes", "\(first)"), value: $first, in: 1...32).fixedSize()
                Stepper(tr("%@ bytes anteriores", "\(pre)"), value: $pre, in: 1...32).fixedSize()
                Stepper(tr("%@ instrucciones", "\(instructions)"), value: $instructions, in: 1...8).fixedSize()
                Button(tr("Analizar")) { run() }.disabled(busy)
            }
            HStack {
                Picker("", selection: $which) {
                    Text(tr("Primeros bytes")).tag("first")
                    Text(tr("Bytes anteriores")).tag("pre")
                    Text(tr("Primeras instrucciones")).tag("instructions")
                    Text(tr("Última instrucción")).tag("endings")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if let consensus = result["consensus"]?.string, !consensus.isEmpty {
                    Text(tr("Común a todas: %@", consensus)).font(.callout.monospaced()).textSelection(.enabled)
                    Button(tr("Copiar")) { model.copyToPasteboard(consensus) }
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            GenericTable(rows: result[which]?.array.map(\.object) ?? [],
                         columns: [ColumnSpec(key: "pattern", title: tr("Patrón"), width: 420, mono: true),
                                   ColumnSpec(key: "count", title: tr("Funciones"), width: 90),
                                   ColumnSpec(key: "percent", title: "%", width: 70)],
                         storageKey: "functionPatterns", addressKey: nil,
                         actions: [RowAction(title: tr("Copiar el patrón")) { row in model.copyToPasteboard(row["pattern"]?.text ?? "") }])
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
    }

    private func run() {
        busy = true
        Task {
            defer { busy = false }
            do {
                result = try await model.engine.call("functionPatterns", ["first": first, "pre": pre, "instructions": instructions])
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - SARIF

struct SarifPanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [JSONRow] = []
    @State private var file = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(file.isEmpty ? tr("Resultados SARIF") : (file as NSString).lastPathComponent) {
                Button(tr("Abrir un archivo SARIF…")) { open() }
            }
            Divider()
            GenericTable(rows: rows,
                         columns: [.address(), ColumnSpec(key: "rule", title: tr("Regla"), width: 150, mono: true),
                                   ColumnSpec(key: "level", title: tr("Nivel"), width: 80),
                                   ColumnSpec(key: "message", title: tr("Mensaje"), width: 420),
                                   ColumnSpec(key: "location", title: tr("Ubicación"), width: 220, mono: true),
                                   ColumnSpec(key: "tool", title: tr("Herramienta"), width: 120)],
                         storageKey: "sarif",
                         actions: [RowAction(title: tr("Añadir marcador")) { row in bookmark([row]) }],
                         multiActions: [MultiAction(title: tr("Marcadores para las elegidas")) { rows in bookmark(rows) }])
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sarif") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                rows = try await model.engine.call("sarif", ["path": url.path])
                file = url.path
                message = tr("%@ resultados, %@ con dirección en este programa", "\(rows.count)",
                             "\(rows.filter { !($0["address"]?.text ?? "").isEmpty }.count)")
            } catch { message = error.localizedDescription }
        }
    }

    private func bookmark(_ list: [JSONRow]) {
        Task {
            var done = 0
            for row in list {
                guard let address = row["address"]?.string, !address.isEmpty else { continue }
                let text = "\(row["rule"]?.text ?? "") \(row["message"]?.text ?? "")".trimmingCharacters(in: .whitespaces)
                if (try? await model.engine.call("addBookmark", ["address": address, "category": "SARIF", "comment": text],
                                                 as: JSONValue.self)) != nil { done += 1 }
            }
            await model.afterEdit(namesChanged: false)
            message = tr("%@ marcadores añadidos", "\(done)")
        }
    }
}

// MARK: - Script directories and search

struct ScriptDirsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [JSONRow] = []
    @State private var error: String?
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Directorios de scripts y bundles")).font(.headline)
                Spacer()
                Button(tr("Añadir carpeta o .jar…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url { act("add", url.path) }
                }
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            GenericTable(rows: rows.map { row in
                var r = row
                r["kindText"] = .string(row["kind"]?.text == "directory" ? tr("Carpeta de scripts") : "Bundle")
                r["origin"] = .string(row["system"]?.bool == true ? "Ghidra" : tr("Tuyo"))
                return r
            }, columns: [ColumnSpec(key: "path", title: tr("Ruta"), width: 520, mono: true),
                         ColumnSpec(key: "enabled", title: tr("Activo"), width: 60),
                         ColumnSpec(key: "kindText", title: tr("Clase"), width: 130),
                         ColumnSpec(key: "origin", title: tr("Origen"), width: 70)],
                         storageKey: "scriptDirs", addressKey: nil,
                         actions: [RowAction(title: tr("Activar o desactivar")) { row in
                             act(row["enabled"]?.bool == true ? "disable" : "enable", row["path"]?.text ?? "")
                         }, RowAction(title: tr("Quitar"), destructive: true) { row in act("remove", row["path"]?.text ?? "") }])
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .frame(width: 880, height: 480)
        .task { rows = (try? await model.engine.call("scriptDirs")) ?? [] }
    }

    private func act(_ action: String, _ path: String) {
        Task {
            do {
                rows = try await model.engine.call("scriptDirAction", ["action": action, "path": path])
                error = nil
                onChange()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ScriptSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [JSONRow] = []
    let onOpen: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Texto a buscar en el código de los scripts"), text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(tr("Buscar"), action: search).disabled(query.isEmpty)
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            GenericTable(rows: rows,
                         columns: [ColumnSpec(key: "name", title: "Script", width: 240, mono: true),
                                   ColumnSpec(key: "line", title: tr("Línea"), width: 60),
                                   ColumnSpec(key: "text", title: tr("Código"), width: 520, mono: true)],
                         storageKey: "scriptSearch", addressKey: nil,
                         onOpen: { row in
                             if let path = row["path"]?.string { onOpen(path); dismiss() }
                         })
        }
        .frame(width: 900, height: 480)
    }

    private func search() {
        guard !query.isEmpty else { return }
        Task { rows = (try? await model.engine.call("scriptSearch", ["query": query])) ?? [] }
    }
}
