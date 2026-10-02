import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// Progress of a long engine operation ("bsim", "vt", "vc"), with a cancel button.
struct TaskProgressBar: View {
    @Environment(AppModel.self) private var model
    let task: String

    var body: some View {
        if let status = model.tasks[task] {
            HStack(spacing: 8) {
                if let progress = status.progress {
                    ProgressView(value: progress).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(status.message).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(tr("Cancelar")) { model.cancelTask() }.controlSize(.small).fixedSize()
            }
        }
    }
}

/// One-line result / error message at the bottom of a tool window.
struct StatusLine: View {
    let text: String?
    var isError = false

    var body: some View {
        if let text, !text.isEmpty {
            Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Python interpreter

struct PythonConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var transcript = ""
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var running = false
    @State private var completions: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if let version = model.pythonVersion {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(transcript.isEmpty ? banner(version) : transcript)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color(nsColor: Theme.background))
                    .onChange(of: transcript) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    Text(">>>").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    TextEditor(text: $input)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .frame(minHeight: 40, maxHeight: 150)
                        .fixedSize(horizontal: false, vertical: true)
                        .onKeyPress(.tab) {
                            complete()
                            return .handled
                        }
                        .popover(isPresented: Binding(get: { completions.count > 1 }, set: { if !$0 { completions = [] } }),
                                 arrowEdge: .top) {
                            List(completions, id: \.self) { item in
                                Button(item) { accept(item) }.buttonStyle(.plain).font(.system(size: 12, design: .monospaced))
                            }
                            .frame(width: 360, height: min(320, CGFloat(completions.count) * 24 + 16))
                        }
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Button { recall(-1) } label: { Image(systemName: "chevron.up") }
                                .help(tr("Entrada anterior"))
                                .disabled(history.isEmpty)
                            Button { recall(1) } label: { Image(systemName: "chevron.down") }
                                .help(tr("Entrada siguiente"))
                                .disabled(historyIndex == nil)
                        }
                        .controlSize(.small)
                        Button(tr("Ejecutar")) { run() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(running || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(10)
                Divider()
                HStack {
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                        Button(tr("Detener")) { model.cancelTask() }.controlSize(.small)
                    }
                    Button(tr("Completar (Tab)")) { complete() }.buttonStyle(.plain).font(.caption)
                    Button(tr("Reiniciar")) { reset() }.buttonStyle(.plain).font(.caption)
                        .help(tr("Olvida las variables y los imports del intérprete"))
                    Button(tr("Limpiar")) { transcript = "" }.buttonStyle(.plain).font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                ContentUnavailableView(tr("Python no disponible"), systemImage: "exclamationmark.triangle",
                                       description: Text(tr("El motor se inició sin PyGhidra. Reconstruye la app con ./build-studio.sh para incluir Python.")))
            }
        }
        .windowMinSize(620, 420)
    }

    private func banner(_ version: String) -> String {
        tr("Python %@ (PyGhidra) dentro del motor de Ghidra.\nTienes la API de GhidraScript: currentProgram, currentAddress, getFunctionContaining(), toAddr()…\nLas variables se conservan entre ejecuciones. ⌘↩ ejecuta.", version)
    }

    private var context: String {
        guard let program = model.program else { return tr("Sin programa abierto: currentProgram es None") }
        return "currentProgram = \(program.name)" + (model.editTarget.map { " · currentAddress = \($0)" } ?? "")
    }

    /// Tab: completes the name or attribute being typed, or lists the candidates.
    private func complete() {
        guard !input.isEmpty else { return }
        Task {
            let found: [String] = (try? await model.engine.call("pyComplete", ["text": input])) ?? []
            if found.count == 1 { accept(found[0]) } else { completions = found }
        }
    }

    private func accept(_ item: String) {
        // replace the expression at the end of the input with the completed one
        if let range = input.range(of: "[A-Za-z_][A-Za-z0-9_.]*$", options: .regularExpression) {
            input.replaceSubrange(range, with: item)
        }
        completions = []
    }

    private func reset() {
        Task {
            _ = try? await model.engine.call("pyReset", as: JSONValue.self)
            transcript += tr("— intérprete reiniciado —\n")
        }
    }

    private func recall(_ delta: Int) {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) + delta
        if next >= history.count {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = max(0, next)
            input = history[max(0, next)]
        }
    }

    private func run() {
        let source = input.trimmingCharacters(in: .newlines)
        guard !source.isEmpty else { return }
        history.append(source)
        historyIndex = nil
        input = ""
        running = true
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        transcript += ">>> " + lines.joined(separator: "\n... ") + "\n"
        Task {
            defer { running = false }
            do {
                var params: [String: Any] = ["source": source]
                if model.program != nil, let address = model.editTarget { params["address"] = address }
                let result: PyResult = try await model.engine.call("pyEval", params)
                transcript += result.output
                if !result.output.isEmpty && !result.output.hasSuffix("\n") { transcript += "\n" }
                if model.program != nil { await model.refreshAfterEdits() }
            } catch {
                transcript += "✖︎ \(error.localizedDescription)\n"
            }
        }
    }
}

// MARK: - BSim

struct BSimView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("bsimServers") private var serverList = ""
    @State private var data: BsimDatabases?
    @State private var selected: String?
    @State private var info: BsimInfo?
    @State private var rows: [BsimRow] = []
    @State private var selection = Set<BsimRow.ID>()
    @State private var wholeProgram = false
    @State private var similarity = 0.7
    @State private var confidence = 0.0
    @State private var maxMatches = 10
    @State private var skipSelf = true
    @State private var busy = false
    @State private var newName = ""
    @State private var template = "medium_nosize"
    @State private var newURL = ""
    @State private var message: String?
    @State private var failed = false
    @State private var showExecutables = false
    @State private var onlyExe = ""
    @State private var notExe = ""
    @State private var arch = ""
    @State private var comparison: [BsimCompareRow] = []
    @State private var comparedName = ""
    @State private var showExtras = false
    @State private var extraExecutables: [JSONRow] = []

    private var servers: [String] {
        serverList.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 230, idealWidth: 260, maxWidth: 340, maxHeight: .infinity)
            detail.frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .windowMinSize(920, 560)
        .task { await reload() }
        .onChange(of: selected) { _, _ in Task { await loadInfo() } }
        .sheet(isPresented: $showExtras) {
            BSimExtrasSheet(database: selected ?? "", executables: extraExecutables)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selected) {
                Section(tr("Bases de datos locales")) {
                    ForEach(data?.databases ?? []) { db in
                        Label(db.name, systemImage: "cylinder.split.1x2").tag(Optional(db.path))
                    }
                    if data?.databases.isEmpty ?? true {
                        Text(tr("Ninguna todavía")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(tr("Servidores")) {
                    ForEach(servers, id: \.self) { url in
                        Label(url, systemImage: "server.rack").lineLimit(1).truncationMode(.middle).tag(Optional(url))
                    }
                    if servers.isEmpty {
                        Text(tr("Ninguno")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Nueva base de datos local")).font(.caption.weight(.semibold))
                TextField(tr("Nombre"), text: $newName).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("", selection: $template) {
                        ForEach(data?.templates ?? ["medium_nosize"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .help(tr("Plantilla de firmas: nosize sirve para cualquier arquitectura; 32/64 afinan por tamaño de puntero"))
                    Button(tr("Crear")) { create() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                Text(tr("Añadir servidor (PostgreSQL / Elasticsearch)")).font(.caption.weight(.semibold)).padding(.top, 4)
                HStack {
                    TextField("postgresql://host:5432/bsim", text: $newURL).textFieldStyle(.roundedBorder)
                    Button(tr("Añadir")) { addServer() }.disabled(!newURL.contains("://"))
                }
                if let sel = selected, servers.contains(sel) {
                    Button(tr("Quitar servidor seleccionado")) {
                        serverList = servers.filter { $0 != sel }.joined(separator: "\n")
                        selected = nil
                    }
                    .font(.caption)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var detail: some View {
        if selected == nil {
            ContentUnavailableView(tr("BSim"), systemImage: "square.stack.3d.up",
                                   description: Text(tr("Busca funciones parecidas a las de tu programa en una base de datos de firmas. Crea una base de datos local, añade programas ya analizados y consulta desde cualquier otro.")))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                queryBar
                Divider()
                Table(rows, selection: $selection) {
                    TableColumn(tr("Función")) { r in
                        VStack(alignment: .leading) {
                            Text(r.name).monospaced().foregroundStyle(r.defaultName ? .secondary : .primary)
                            Text(r.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn(tr("Similitud")) { r in Text(String(format: "%.3f", r.similarity)).monospacedDigit() }
                        .width(70)
                    TableColumn(tr("Confianza")) { r in Text(String(format: "%.1f", r.confidence)).monospacedDigit() }
                        .width(70)
                    TableColumn(tr("Coincide con")) { r in
                        VStack(alignment: .leading) {
                            Text(r.matchName).monospaced()
                            Text(r.matchAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn(tr("Ejecutable")) { r in
                        VStack(alignment: .leading) {
                            Text(r.executable)
                            Text(r.architecture ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu(forSelectionType: BsimRow.ID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let r = rows.first(where: { $0.id == id }) { model.go(r.address) }
                }
                Divider()
                HStack {
                    StatusLine(text: message, isError: failed)
                    Spacer()
                    TaskProgressBar(task: "bsim")
                    Button(tr("Ir a la función")) {
                        if let id = selection.first, let r = rows.first(where: { $0.id == id }) { model.go(r.address) }
                    }
                    .disabled(selection.count != 1)
                    Button(tr("Aplicar nombre de la coincidencia")) { applyNames() }
                        .buttonStyle(.glassProminent)
                        .disabled(selection.isEmpty || busy)
                        .help(tr("Renombra cada función seleccionada con el nombre que tiene en la base de datos"))
                }
                .padding(10)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.name ?? (selected as NSString?)?.lastPathComponent ?? "").font(.headline)
                    if let info {
                        Text(tr("%@ ejecutables · firmas v%@%@", "\(info.count)", info.version,
                                info.readOnly ? tr(" · solo lectura") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(tr("Vista general y características…")) {
                    Task {
                        let raw: JSONRow = (try? await model.engine.call("bsimInfo", ["database": selected ?? ""])) ?? [:]
                        extraExecutables = raw["executables"]?.array.map(\.object) ?? []
                        showExtras = true
                    }
                }
                .disabled(selected == nil)
                .help(tr("Consulta de vista general, características de la función actual y abrir los ejecutables de la base"))
                Button(showExecutables ? tr("Ocultar ejecutables") : tr("Ver ejecutables")) { showExecutables.toggle() }
                    .disabled(info?.executables.isEmpty ?? true)
                Button(tr("Añadir «%@» a la base de datos", model.program?.name ?? "—")) { addProgram() }
                    .disabled(model.program == nil || busy || info == nil)
                    .help(tr("Genera las firmas de todas las funciones del programa activo y las guarda"))
            }
            if showExecutables, let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(info.executables) { exe in
                            HStack {
                                Image(systemName: "cpu").foregroundStyle(.secondary)
                                Text(exe.name)
                                Text(exe.architecture ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(exe.md5.prefix(12)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                Spacer()
                                Button(tr("Comparar con el resto")) { compare(exe) }.controlSize(.small).disabled(busy)
                                Button(tr("Quitar")) { removeExecutable(exe) }.controlSize(.small).disabled(busy)
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
                if !comparedName.isEmpty {
                    Text(comparison.isEmpty ? tr("«%@» no comparte funciones poco comunes con los demás ejecutables.", comparedName)
                         : tr("Parecido de «%@» con: ", comparedName)
                           + comparison.prefix(6).map { "\($0.name) \(String(format: "%.0f %%", $0.library * 100))" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(12)
    }

    private var queryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Picker("", selection: $wholeProgram) {
                    Text(tr("Función actual")).tag(false)
                    Text(tr("Todo el programa")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(tr("Omitir este programa"), isOn: $skipSelf).toggleStyle(.checkbox).fixedSize()
                Spacer()
                Button(tr("Buscar similares")) { query() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.program == nil || busy || info == nil)
            }
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Text(tr("Similitud ≥ %@", String(format: "%.2f", similarity))).font(.callout).monospacedDigit().fixedSize()
                    Slider(value: $similarity, in: 0...1, step: 0.05).frame(width: 130)
                }
                Stepper(tr("Confianza ≥ %@", String(format: "%.0f", confidence)), value: $confidence, in: 0...100, step: 5)
                    .fixedSize()
                Stepper(tr("Máx. %@ por función", "\(maxMatches)"), value: $maxMatches, in: 1...100).fixedSize()
                Spacer()
            }
            HStack(spacing: 8) {
                Text(tr("Filtros:")).font(.callout).foregroundStyle(.secondary)
                TextField(tr("Solo el ejecutable…"), text: $onlyExe).textFieldStyle(.roundedBorder).frame(width: 170)
                TextField(tr("Excluir el ejecutable…"), text: $notExe).textFieldStyle(.roundedBorder).frame(width: 170)
                TextField(tr("Arquitectura, p. ej. x86:LE:64:default"), text: $arch).textFieldStyle(.roundedBorder).frame(width: 240)
                Spacer()
            }
        }
        .padding(10)
    }

    private func report(_ text: String?, error: Bool = false) {
        message = text
        failed = error
    }

    private func reload() async {
        do {
            data = try await model.engine.call("bsimDatabases")
            if selected == nil { selected = data?.databases.first?.path }
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func loadInfo() async {
        info = nil
        rows = []
        selection = []
        guard let selected else { return }
        do {
            info = try await model.engine.call("bsimInfo", ["database": selected])
            report(nil)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func create() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let db: BsimDatabase = try await model.engine.call("bsimCreate", ["name": newName, "template": template])
                newName = ""
                await reload()
                selected = db.path
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func addServer() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        if !servers.contains(url) { serverList = (servers + [url]).joined(separator: "\n") }
        newURL = ""
        selected = url
    }

    private func addProgram() {
        guard let selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let r: BsimAddResult = try await model.engine.call("bsimAddProgram", ["database": selected])
                report(tr("Añadidas %@ funciones de «%@».", "\(r.functions)", model.program?.name ?? ""))
                info = try? await model.engine.call("bsimInfo", ["database": selected])
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func removeExecutable(_ exe: BsimExecutable) {
        guard let selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.engine.call("bsimRemoveExecutable", ["database": selected, "md5": exe.md5], as: [String: Int].self)
                info = try? await model.engine.call("bsimInfo", ["database": selected])
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func compare(_ exe: BsimExecutable) {
        guard let selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                comparison = try await model.engine.call("bsimCompare", ["database": selected, "md5": exe.md5])
                comparedName = exe.name
                report(nil)
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func query() {
        guard let selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var params: [String: Any] = ["database": selected, "max": maxMatches, "similarity": similarity,
                                             "confidence": confidence, "skipSelf": skipSelf]
                var filters: [String: String] = [:]
                if !onlyExe.trimmingCharacters(in: .whitespaces).isEmpty { filters["exe"] = onlyExe }
                if !notExe.trimmingCharacters(in: .whitespaces).isEmpty { filters["notExe"] = notExe }
                if !arch.trimmingCharacters(in: .whitespaces).isEmpty { filters["arch"] = arch }
                if !filters.isEmpty { params["filters"] = filters }
                if !wholeProgram {
                    guard let address = model.functionDetails?.entry ?? model.editTarget else {
                        report(tr("Coloca el cursor en una función."), error: true)
                        return
                    }
                    params["address"] = address
                }
                let result: BsimQueryResult = try await model.engine.call("bsimQuery", params)
                rows = result.rows
                selection = []
                report(tr("%@ funciones consultadas · %@ coincidencias", "\(result.queried)", "\(result.rows.count)"))
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func applyNames() {
        // one name per function: the best match among the selected rows
        var best: [String: BsimRow] = [:]
        for row in rows where selection.contains(row.id) {
            if let current = best[row.address], current.similarity >= row.similarity { continue }
            best[row.address] = row
        }
        busy = true
        Task {
            defer { busy = false }
            var applied = 0
            for (address, row) in best {
                do {
                    _ = try await model.engine.call("rename", ["address": address, "name": row.matchName], as: Bool.self)
                    applied += 1
                } catch {
                    report(error.localizedDescription, error: true)
                }
            }
            await model.refreshAfterEdits()
            if applied > 0 { report(tr("%@ funciones renombradas.", "\(applied)")) }
        }
    }
}

// MARK: - Extensions

struct ExtensionsView: View {
    @Environment(AppModel.self) private var model
    @State private var list: ExtensionList?
    @State private var needsRestart = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Extensiones de Ghidra")).font(.headline)
                    Text(tr("Se comparten con Ghidra clásico. Studio carga sus analizadores, cargadores, procesadores y scripts; las que solo añaden ventanas propias solo se ven en el clásico."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("Instalar desde archivo…")) { pick() }
            }
            .padding(12)
            Divider()
            List(list?.extensions ?? []) { ext in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ext.installed ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                        .foregroundStyle(ext.installed && !ext.pendingUninstall ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ext.name).font(.body.weight(.medium))
                            if let v = ext.version, !v.isEmpty {
                                Text(v).font(.caption).foregroundStyle(ext.compatible ? .secondary : Color.orange)
                            }
                            if !ext.compatible {
                                Text(tr("otra versión de Ghidra")).font(.caption2).foregroundStyle(.orange)
                            }
                            if ext.pendingUninstall {
                                Text(tr("se quitará al reiniciar")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            } else if ext.installed {
                                Text(tr("instalada")).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        Text(ext.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let author = ext.author, !author.isEmpty {
                            Text(author).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if ext.pendingUninstall {
                        Button(tr("Conservar")) { change("uninstallExtension", ["name": ext.name, "undo": true]) }
                    } else if ext.installed {
                        Button(tr("Desinstalar")) { change("uninstallExtension", ["name": ext.name]) }
                            .disabled(ext.bundled)
                    } else if let archive = ext.archivePath {
                        Button(tr("Instalar")) { change("installExtension", ["path": archive]) }
                    }
                }
                .padding(.vertical, 3)
            }
            Divider()
            HStack {
                if needsRestart {
                    Label(tr("Los cambios se aplican al reiniciar el motor."), systemImage: "arrow.clockwise.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    StatusLine(text: message ?? list.map { tr("Carpeta: %@", $0.directory) }, isError: failed)
                }
                Spacer()
                Button(tr("Reiniciar motor")) {
                    needsRestart = false
                    model.restartEngine()
                }
                .buttonStyle(.glassProminent)
                .disabled(!needsRestart)
                .help(tr("Cierra los programas abiertos (preguntando si hay cambios) y vuelve a arrancar el motor"))
            }
            .padding(10)
        }
        .windowMinSize(680, 440)
        .task(id: model.engineReady) { await reload() }
    }

    private func reload() async {
        guard model.engineReady else { return }
        list = try? await model.engine.call("extensions")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.title = tr("Instalar extensión")
        panel.message = tr("Elige el .zip de la extensión (o su carpeta descomprimida)")
        panel.canChooseDirectories = true
        if let zip = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zip, .folder] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change("installExtension", ["path": url.path])
    }

    private func change(_ method: String, _ params: [String: Any]) {
        Task {
            do {
                list = try await model.engine.call(method, params)
                needsRestart = true
                message = nil
                failed = false
            } catch {
                message = error.localizedDescription
                failed = true
            }
        }
    }
}
