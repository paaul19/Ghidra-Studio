import AppKit
import SwiftUI

/// Version Tracking: carry names, signatures, comments and types from an already
/// reversed program (source) over to a new version of it (destination).
struct VersionTrackingView: View {
    @Environment(AppModel.self) private var model
    @State private var state: VTState?
    @State private var sessions: [VTSessionFile] = []
    @State private var catalog: VTCorrelators?
    @State private var matches: [VTMatch] = []
    @State private var selection = Set<VTMatch.ID>()
    @State private var filter = ""
    @State private var statusFilter = ""
    @State private var onlyFunctions = false
    @State private var markup: [VTMarkupItem] = []
    @State private var markupSelection = Set<VTMarkupItem.ID>()
    @State private var showFunctions = false
    /// Address ranges ("start-end", one per line) the correlators are limited to.
    @State private var sourceRanges = ""
    @State private var destinationRanges = ""
    @State private var lower = 0
    @State private var leftText: FunctionText?
    @State private var rightText: FunctionText?
    @State private var implied: [VTImpliedMatch] = []
    @State private var tagName = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var sheet: Sheet?

    // new session
    @State private var newName = ""
    @State private var sourcePath: String?

    enum Sheet: String, Identifiable {
        case correlators, auto, applyOptions, manual
        var id: String { rawValue }
    }

    private var isOpen: Bool { state?.open == true }

    var body: some View {
        VStack(spacing: 0) {
            if isOpen { sessionView } else { startView }
        }
        .windowMinSize(1040, 640)
        .task(id: model.project?.gpr) { await reloadAll() }
        .sheet(item: model.formBinding("vt")) { request in FormSheet(request: request) }
        .sheet(isPresented: $showFunctions) {
            VTFunctionsSheet { source, destination in
                run {
                    _ = try await model.engine.call("vtManualMatch", ["source": source, "destination": destination], as: JSONValue.self)
                    await reloadAll()
                }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .correlators:
                VTCorrelatorSheet(correlators: catalog?.correlators ?? []) { names, options, exclude in
                    runCorrelators(names, options, exclude)
                }
            case .auto:
                VTOptionsSheet(title: tr("Auto Version Tracking"),
                               subtitle: tr("Ejecuta los correladores exactos, de duplicados y de referencias, acepta las coincidencias buenas y aplica su marcado."),
                               options: catalog?.auto ?? [], action: tr("Ejecutar")) { values in runAuto(values) }
            case .applyOptions:
                VTApplyOptionsSheet()
            case .manual:
                VTManualSheet(source: state?.source ?? "", destination: state?.destination ?? "") { src, dst in
                    manualMatch(src, dst)
                }
            }
        }
    }

    // MARK: start

    private var programs: [ProjectFile] {
        (model.project?.tree?.allFolders ?? []).flatMap(\.files).filter(\.program)
    }

    private var startView: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Nueva sesión")).font(.title3.weight(.semibold))
                Text(tr("El programa de origen es el que ya tienes analizado y con nombres. El de destino es el programa activo, que recibirá los nombres, firmas, comentarios y tipos."))
                    .font(.callout).foregroundStyle(.secondary)
                Form {
                    TextField(tr("Nombre de la sesión"), text: $newName)
                    LabeledContent(tr("Destino (programa activo)")) {
                        Text(model.program?.name ?? tr("Ninguno: abre el programa de destino")).foregroundStyle(model.program == nil ? .orange : .primary)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 130)
                Text(tr("Origen")).font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(programs.filter { $0.path != model.activeSession }) { f in
                            Button { sourcePath = f.path } label: {
                                HStack {
                                    Image(systemName: sourcePath == f.path ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(sourcePath == f.path ? Color.accentColor : Color.secondary)
                                    Text(f.path)
                                    Spacer()
                                    Text(f.processor ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                        if programs.count < 2 {
                            Text(tr("Hacen falta dos programas en el proyecto.")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 180)
                HStack {
                    Button(tr("Crear sesión")) { create() }
                        .buttonStyle(.glassProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || sourcePath == nil
                                  || model.program == nil || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                StatusLine(text: message, isError: failed)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Sesiones del proyecto")).font(.title3.weight(.semibold))
                if sessions.isEmpty {
                    Text(tr("Todavía no hay ninguna sesión de Version Tracking en este proyecto."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sessions) { s in
                    HStack {
                        Image(systemName: "arrow.left.arrow.right.square").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(s.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("Abrir")) { open(s.path) }.disabled(busy)
                    }
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 380, alignment: .leading)
        }
    }

    // MARK: session

    private var filtered: [VTMatch] {
        matches.filter { m in
            (statusFilter.isEmpty || m.status == statusFilter) && (!onlyFunctions || m.type == "FUNCTION")
                && (filter.isEmpty || m.sourceName.localizedCaseInsensitiveContains(filter)
                    || m.destinationName.localizedCaseInsensitiveContains(filter)
                    || m.sourceAddress.contains(filter) || m.destinationAddress.contains(filter)
                    || m.correlator.localizedCaseInsensitiveContains(filter))
        }
    }

    private var chosen: [VTMatch] { matches.filter { selection.contains($0.id) } }
    private var single: VTMatch? { selection.count == 1 ? chosen.first : nil }

    private var sessionView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(state?.name ?? "").font(.headline)
                        if state?.changed == true { Circle().fill(.secondary).frame(width: 6, height: 6) }
                    }
                    Text("\(state?.source ?? "")  →  \(state?.destination ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy && model.tasks["vt"] == nil { ProgressView().controlSize(.small) }
                Button(tr("Funciones…")) { showFunctions = true }.disabled(busy)
                    .help(tr("Funciones del origen y del destino, con o sin coincidencia"))
                Button(sourceRanges.isEmpty && destinationRanges.isEmpty ? tr("Rangos…") : tr("Rangos ✓")) { requestRanges() }
                    .disabled(busy)
                    .help(tr("Limita los correladores a rangos de direcciones del origen y del destino"))
                Button(tr("Correladores…")) { sheet = .correlators }.disabled(busy)
                Button(tr("Auto Version Tracking…")) { sheet = .auto }.disabled(busy)
                Button(tr("Coincidencia manual…")) { sheet = .manual }.disabled(busy)
                Button(tr("Opciones de aplicación…")) { sheet = .applyOptions }
                Button(tr("Guardar")) { save() }.disabled(busy || state?.changed != true)
                Button(tr("Cerrar sesión")) { close() }.disabled(busy)
            }
            .padding(10)
            Divider()
            HStack(spacing: 12) {
                TextField(tr("Filtrar por nombre, dirección o correlador"), text: $filter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Picker("", selection: $statusFilter) {
                    Text(tr("Todas")).tag("")
                    Text(tr("Disponibles")).tag("AVAILABLE")
                    Text(tr("Aceptadas")).tag("ACCEPTED")
                    Text(tr("Bloqueadas")).tag("BLOCKED")
                    Text(tr("Rechazadas")).tag("REJECTED")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(tr("Solo funciones"), isOn: $onlyFunctions).toggleStyle(.checkbox)
                Spacer()
                Text(tr("%@ de %@ coincidencias · %@ aceptadas", "\(filtered.count)", "\(matches.count)", "\(state?.accepted ?? 0)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            VSplitView {
                matchTable.frame(minHeight: 200)
                lowerPane.frame(minHeight: 170)
            }
            Divider()
            HStack(spacing: 8) {
                if model.tasks["vt"] != nil {
                    TaskProgressBar(task: "vt")
                } else {
                    StatusLine(text: message, isError: failed)
                }
                Spacer()
                TextField(tr("Etiqueta de coincidencia"), text: $tagName).textFieldStyle(.roundedBorder).frame(width: 110)
                Button(tr("Etiquetar")) { setTag() }.disabled(selection.isEmpty || busy)
                    .help(tr("Pone esta etiqueta a las coincidencias seleccionadas (vacía = quitarla)"))
                Button(tr("Seleccionar visibles")) { selection = Set(filtered.map(\.id)) }
                Button(tr("Aceptar coincidencia")) { act("vtAccept") }.disabled(selection.isEmpty || busy)
                    .help(tr("Marca la coincidencia como buena y aplica el nombre de la función o del dato"))
                Button(tr("Aplicar marcado")) { act("vtApply") }
                    .buttonStyle(.glassProminent)
                    .disabled(selection.isEmpty || busy)
                    .help(tr("Acepta y aplica todo el marcado: nombre, firma, comentarios, etiquetas y tipos"))
                Button(tr("Rechazar")) { act("vtReject") }.disabled(selection.isEmpty || busy)
                Button(tr("Limpiar")) { act("vtClear") }.disabled(selection.isEmpty || busy)
                    .help(tr("Vuelve a «disponible» y deshace el marcado aplicado"))
                Button(tr("Quitar")) { act("vtRemove") }.disabled(selection.isEmpty || busy)
            }
            .padding(10)
        }
        .onChange(of: selection) { _, _ in Task { await loadDetail() } }
        .onChange(of: lower) { _, _ in Task { await loadDetail() } }
    }

    private var matchTable: some View {
        Table(filtered, selection: $selection) {
            TableColumn("") { m in
                Image(systemName: statusIcon(m.status)).foregroundStyle(statusTint(m.status)).help(statusTitle(m.status))
            }
            .width(22)
            TableColumn(tr("Tipo")) { m in Text(m.type == "FUNCTION" ? tr("Función") : tr("Dato")).font(.caption) }
                .width(54)
            TableColumn(tr("Puntuación")) { m in Text(String(format: "%.3f", m.score)).monospacedDigit() }.width(70)
            TableColumn(tr("Confianza")) { m in Text(String(format: "%.2f", m.confidence)).monospacedDigit() }.width(64)
            TableColumn(tr("Origen")) { m in
                VStack(alignment: .leading) {
                    Text(m.sourceName).monospaced().lineLimit(1)
                    Text(m.sourceAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            TableColumn(tr("Destino")) { m in
                VStack(alignment: .leading) {
                    Text(m.destinationName).monospaced().lineLimit(1)
                    Text(m.destinationAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            TableColumn(tr("Marcado")) { m in Text(m.markup ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn(tr("Etiqueta de coincidencia")) { m in Text(m.tag ?? "").font(.caption).foregroundStyle(.tint).lineLimit(1) }
                .width(min: 50, ideal: 80)
            TableColumn(tr("Correlador")) { m in Text(m.correlator).font(.caption).lineLimit(1) }
                .width(min: 110, ideal: 170)
        }
        .contextMenu(forSelectionType: VTMatch.ID.self) { _ in
            Button(tr("Aceptar coincidencia")) { act("vtAccept") }
            Button(tr("Aplicar marcado")) { act("vtApply") }
            Button(tr("Rechazar")) { act("vtReject") }
            Button(tr("Limpiar")) { act("vtClear") }
        } primaryAction: { ids in
            if let id = ids.first, let m = matches.first(where: { $0.id == id }) { goDestination(m) }
        }
    }

    private var lowerPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $lower) {
                    Text(tr("Marcado")).tag(0)
                    Text(tr("Código lado a lado")).tag(1)
                    Text(tr("Ensamblador lado a lado")).tag(2)
                    Text(tr("Implícitas")).tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if let m = single {
                    Button(tr("Ir al destino")) { goDestination(m) }.controlSize(.small)
                    if lower == 3 {
                        Button(tr("Crear estas coincidencias")) { createImplied(m) }.controlSize(.small)
                            .disabled(implied.isEmpty || busy)
                            .help(tr("Las añade al conjunto «Implied Match» para poder aceptarlas y aplicarlas"))
                    }
                    if lower == 0 {
                        Button(tr("Aplicar seleccionado")) { applyMarkup(true) }.controlSize(.small)
                            .disabled(markupSelection.isEmpty || busy)
                        Button(tr("Deshacer seleccionado")) { applyMarkup(false) }.controlSize(.small)
                            .disabled(markupSelection.isEmpty || busy)
                        Button(tr("Dirección de destino…")) { requestMarkupAddress(m) }.controlSize(.small)
                            .disabled(markupSelection.count != 1 || busy)
                            .help(tr("Cambia dónde se aplicará este elemento en el programa de destino"))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if single == nil {
                ContentUnavailableView(tr("Selecciona una coincidencia"), systemImage: "arrow.left.arrow.right",
                                       description: Text(tr("Aquí verás qué se puede copiar del origen al destino.")))
            } else if lower == 0 {
                Table(markup, selection: $markupSelection) {
                    TableColumn(tr("Estado")) { i in
                        Text(i.statusText ?? i.status).font(.caption)
                            .foregroundStyle(i.status == "UNAPPLIED" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn(tr("Tipo")) { i in Text(i.type) }.width(min: 110, ideal: 140)
                    TableColumn(tr("Valor en el origen")) { i in
                        VStack(alignment: .leading) {
                            Text(i.sourceValue ?? "").monospaced().lineLimit(2)
                            Text(i.sourceAddress ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn(tr("Valor en el destino")) { i in
                        VStack(alignment: .leading) {
                            Text(i.destinationValue ?? "").monospaced().lineLimit(2)
                            Text(i.destinationAddress ?? tr("sin dirección")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if lower == 3 {
                Table(implied) {
                    TableColumn(tr("Tipo")) { i in Text(i.type == "FUNCTION" ? tr("Función") : tr("Dato")).font(.caption) }.width(60)
                    TableColumn(tr("Origen")) { i in
                        VStack(alignment: .leading) {
                            Text(i.sourceName).monospaced().lineLimit(1)
                            Text(i.sourceAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn(tr("Destino")) { i in
                        VStack(alignment: .leading) {
                            Text(i.destinationName).monospaced().lineLimit(1)
                            Text(i.destinationAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn(tr("Estado")) { i in
                        Text(i.status.map { statusTitle($0) } ?? tr("sin coincidencia todavía")).font(.caption)
                            .foregroundStyle(i.status == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 150)
                }
            } else {
                let diff = DiffLines(leftText?.lines ?? [], rightText?.lines ?? [])
                HStack(spacing: 0) {
                    DiffPane(title: tr("Origen · %@", leftText?.name ?? ""), lines: leftText?.lines ?? [],
                             changed: diff.leftOnly, tint: .red)
                    Divider()
                    DiffPane(title: tr("Destino · %@", rightText?.name ?? ""), lines: rightText?.lines ?? [],
                             changed: diff.rightOnly, tint: .green)
                }
            }
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "ACCEPTED": "checkmark.circle.fill"
        case "REJECTED": "xmark.circle.fill"
        case "BLOCKED": "lock.circle"
        default: "circle"
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "ACCEPTED": .green
        case "REJECTED": .red
        case "BLOCKED": .orange
        default: .secondary
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "ACCEPTED": tr("Aceptada")
        case "REJECTED": tr("Rechazada")
        case "BLOCKED": tr("Bloqueada por otra coincidencia aceptada")
        default: tr("Disponible")
        }
    }

    // MARK: actions

    private func report(_ text: String?, error: Bool = false) {
        message = text
        failed = error
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func reloadAll() async {
        guard model.project?.open == true else { return }
        state = try? await model.engine.call("vtState")
        sessions = (try? await model.engine.call("vtSessions")) ?? []
        if catalog == nil { catalog = try? await model.engine.call("vtCorrelators") }
        if isOpen { await reloadMatches() }
    }

    private func reloadMatches() async {
        matches = (try? await model.engine.call("vtMatches")) ?? []
        selection = selection.filter { id in matches.contains { $0.id == id } }
        await loadDetail()
    }

    /// The destination program changed: refresh the main window if it is showing it.
    private func destinationChanged() async {
        if let dest = state?.destinationPath, dest == model.activeSession {
            await model.refreshAfterEdits()
        }
    }

    private func create() {
        guard let sourcePath else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        run {
            state = try await model.engine.call("vtCreate", ["name": name, "source": sourcePath])
            newName = ""
            await model.refreshProject()
            await reloadAll()
            report(tr("Sesión creada. Ejecuta los correladores o Auto Version Tracking para buscar coincidencias."))
        }
    }

    private func open(_ path: String) {
        run {
            let opened: VTState = try await model.engine.call("vtOpen", ["path": path])
            state = opened
            if let dest = opened.destinationPath { model.openProgram(domainPath: dest) }
            await reloadAll()
            report(nil)
        }
    }

    private func save() {
        run {
            state = try await model.engine.call("vtSave")
            await model.refreshUndo()
            report(tr("Sesión y programa de destino guardados."))
        }
    }

    private func close() {
        var save = true
        if state?.changed == true {
            guard let choice = model.askToSave([state?.name ?? ""]) else { return }
            save = choice
        }
        run {
            state = try await model.engine.call("vtClose", ["save": save])
            matches = []
            markup = []
            selection = []
            sessions = (try? await model.engine.call("vtSessions")) ?? []
            await model.refreshUndo()
            report(nil)
        }
    }

    private func requestRanges() {
        model.formRequest = FormRequest(
            title: tr("Rangos de direcciones para los correladores"),
            message: tr("Un rango por línea, como 100000460-1000004ff. Vacío: todo el programa."),
            fields: [FormField(key: "source", title: tr("Programa de origen"), kind: .multiline, value: sourceRanges),
                     FormField(key: "destination", title: tr("Programa de destino"), kind: .multiline, value: destinationRanges)],
            actionTitle: tr("Guardar"), origin: "vt") { values in
                sourceRanges = values["source"] ?? ""
                destinationRanges = values["destination"] ?? ""
            }
    }

    private func requestMarkupAddress(_ match: VTMatch) {
        guard let index = markupSelection.first, let item = markup.first(where: { $0.id == index }) else { return }
        model.formRequest = FormRequest(
            title: tr("Dirección de destino de «%@»", item.type),
            message: tr("Dónde se aplicará en el programa de destino. Vacío quita la dirección."),
            fields: [FormField(key: "address", title: tr("Dirección"), value: item.destinationAddress ?? "")],
            actionTitle: tr("Cambiar"), origin: "vt") { values in
                let result: JSONRow = try await model.engine.call("vtSetMarkupAddress", ["key": match.key, "index": item.index,
                                                                                         "address": values["address"] ?? ""])
                _ = result
                markup = (try? await model.engine.call("vtMarkup", ["key": match.key])) ?? []
            }
    }

    private func runCorrelators(_ names: [String], _ options: [String: [String: String]], _ exclude: Bool) {
        run {
            func lines(_ text: String) -> [String] {
                text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let result: VTRunResult = try await model.engine.call("vtRun", ["correlators": names, "options": options,
                                                                           "excludeAccepted": exclude,
                                                                           "sourceRanges": lines(sourceRanges),
                                                                           "destinationRanges": lines(destinationRanges)])
            state = result.state
            await reloadMatches()
            report(result.results.map { "\($0.correlator): \($0.matches)" }.joined(separator: " · "))
        }
    }

    private func runAuto(_ values: [String: String]) {
        run {
            let result: VTAutoResult = try await model.engine.call("vtAuto", ["options": values])
            state = result.state
            await reloadMatches()
            await destinationChanged()
            report(result.message)
        }
    }

    private func act(_ method: String) {
        let keys = chosen.map(\.key)
        guard !keys.isEmpty else { return }
        run {
            state = try await model.engine.call(method, ["keys": keys])
            await reloadMatches()
            await destinationChanged()
            report(nil)
        }
    }

    private func manualMatch(_ source: String, _ destination: String) {
        run {
            let result: VTManualResult = try await model.engine.call("vtManualMatch", ["source": source, "destination": destination])
            state = try await model.engine.call("vtState")
            await reloadMatches()
            if let key = result.key { selection = [key] }
            report(tr("Coincidencia manual creada."))
        }
    }

    private func applyMarkup(_ apply: Bool) {
        guard let m = single else { return }
        let indices = Array(markupSelection)
        run {
            let result: VTMarkupApplied = try await model.engine.call("vtApplyMarkup",
                                                                     ["key": m.key, "indices": indices, "apply": apply])
            markup = result.markup
            state = try await model.engine.call("vtState")
            matches = (try? await model.engine.call("vtMatches")) ?? matches
            await destinationChanged()
            report(nil)
        }
    }

    private func setTag() {
        let keys = chosen.map(\.key)
        guard !keys.isEmpty else { return }
        let name = tagName.trimmingCharacters(in: .whitespaces)
        run {
            state = try await model.engine.call("vtSetTag", ["keys": keys, "tag": name])
            await reloadMatches()
            report(nil)
        }
    }

    private func createImplied(_ m: VTMatch) {
        run {
            state = try await model.engine.call("vtCreateImplied", ["key": m.key, "pairs": [String]()])
            await reloadMatches()
            report(tr("Coincidencias implícitas creadas: fíltralas por el correlador «Implied Match»."))
        }
    }

    private func goDestination(_ m: VTMatch) {
        guard let dest = state?.destinationPath else { return }
        if dest != model.activeSession { model.activate(dest) }
        model.go(m.destinationAddress)
    }

    private func loadDetail() async {
        guard let m = single else {
            markup = []
            leftText = nil
            rightText = nil
            return
        }
        if lower == 3 {
            implied = m.type == "FUNCTION" ? ((try? await model.engine.call("vtImplied", ["key": m.key])) ?? []) : []
        } else if lower == 0 {
            markup = (try? await model.engine.call("vtMarkup", ["key": m.key])) ?? []
            markupSelection = []
        } else if m.type == "FUNCTION", let src = state?.sourcePath, let dst = state?.destinationPath {
            let mode = lower == 1 ? "c" : "asm"
            leftText = try? await model.engine.call("functionText", ["session": dst, "other": src,
                                                                    "address": m.sourceAddress, "mode": mode])
            rightText = try? await model.engine.call("functionText", ["session": dst, "address": m.destinationAddress,
                                                                     "mode": mode])
        } else {
            leftText = nil
            rightText = nil
        }
    }
}

/// One side of a side-by-side comparison, with the differing lines tinted.
struct DiffPane: View {
    let title: String
    let lines: [String]
    let changed: Set<Int>
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(8)
            Divider()
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            HStack(spacing: 8) {
                                Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 1)
                            .background(changed.contains(i) ? tint.opacity(0.22) : Color.clear)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: Theme.background))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sheets

/// Pick which correlators to run and tune their options.
private struct VTCorrelatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let correlators: [VTCorrelator]
    let onRun: ([String], [String: [String: String]], Bool) -> Void
    @State private var enabled = Set<String>()
    @State private var values: [String: [String: String]] = [:]
    @State private var expanded: String?
    @State private var excludeAccepted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Correladores")).font(.title3.weight(.semibold))
            Text(tr("Cada correlador propone coincidencias entre el origen y el destino con un criterio distinto. Empieza por los exactos y sigue con los de referencias."))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(correlators) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Toggle(c.name, isOn: Binding(get: { enabled.contains(c.name) }, set: { on in
                                    if on { enabled.insert(c.name) } else { enabled.remove(c.name) }
                                }))
                                .toggleStyle(.checkbox)
                                Spacer()
                                if !c.options.isEmpty {
                                    Button(expanded == c.name ? tr("Ocultar opciones") : tr("Opciones")) {
                                        expanded = expanded == c.name ? nil : c.name
                                    }
                                    .controlSize(.small)
                                }
                            }
                            Text(c.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            if expanded == c.name {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(c.options) { opt in
                                        TypedOptionRow(option: opt.with(values[c.name]?[opt.name ?? opt.label])) { v in
                                            values[c.name, default: [:]][opt.name ?? opt.label] = v
                                        }
                                    }
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(height: 380)
            Toggle(tr("No volver a comparar lo que ya tiene una coincidencia aceptada"), isOn: $excludeAccepted)
                .toggleStyle(.checkbox)
            HStack {
                Button(tr("Exactos")) {
                    enabled = Set(correlators.map(\.name).filter { $0.hasPrefix("Exact") })
                }
                Button(tr("Ninguno")) { enabled = [] }
                Spacer()
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Ejecutar")) {
                    let names = correlators.map(\.name).filter { enabled.contains($0) }
                    dismiss()
                    onRun(names, values, excludeAccepted)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(enabled.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            if enabled.isEmpty { enabled = Set(correlators.map(\.name).filter { $0.hasPrefix("Exact") }) }
        }
    }
}

/// Generic typed-option sheet (used for Auto Version Tracking).
private struct VTOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let options: [TypedOption]
    let action: String
    let onRun: ([String: String]) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            Form {
                ForEach(options) { opt in
                    TypedOptionRow(option: opt.with(values[opt.name ?? opt.label])) { v in values[opt.name ?? opt.label] = v }
                }
            }
            .formStyle(.grouped)
            .frame(height: 420)
            HStack {
                Text(tr("Los campos de texto se aplican al pulsar Intro.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    dismiss()
                    onRun(values)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

/// What "apply markup" does with each kind of item (replace, add, exclude…).
private struct VTApplyOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options: [TypedOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Opciones de aplicación")).font(.title3.weight(.semibold))
            Text(tr("Qué se hace con cada tipo de marcado al aplicar una coincidencia. Valen para esta sesión de trabajo."))
                .font(.callout).foregroundStyle(.secondary)
            Form {
                ForEach(options) { opt in
                    TypedOptionRow(option: opt) { v in set(opt, v) }
                }
            }
            .formStyle(.grouped)
            .frame(height: 460)
            HStack {
                Spacer()
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { options = (try? await model.engine.call("vtApplyOptions")) ?? [] }
    }

    private func set(_ opt: TypedOption, _ value: String) {
        Task {
            options = (try? await model.engine.call("vtSetApplyOptions", ["options": [opt.name ?? opt.label: value]])) ?? options
        }
    }
}

private struct VTManualSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: String
    let destination: String
    let onCreate: (String, String) -> Void
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Coincidencia manual")).font(.title3.weight(.semibold))
            Text(tr("Empareja a mano una función del origen con una del destino cuando ningún correlador la encuentra."))
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField(tr("Dirección en %@ (origen)", source), text: $sourceAddress)
                TextField(tr("Dirección en %@ (destino)", destination), text: $destinationAddress)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Crear")) {
                    dismiss()
                    onCreate(sourceAddress.trimmingCharacters(in: .whitespaces),
                             destinationAddress.trimmingCharacters(in: .whitespaces))
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sourceAddress.isEmpty || destinationAddress.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { destinationAddress = model.functionDetails?.entry ?? "" }
    }
}

private extension TypedOption {
    /// Copy with the value the user has typed so far, if any.
    func with(_ value: String?) -> TypedOption {
        var copy = self
        if let value { copy.value = value }
        return copy
    }
}
