import SwiftUI

// MARK: - Emulator

struct EmulatorView: View {
    @Environment(AppModel.self) private var model
    @State private var state: EmuState?
    @State private var busy = false
    @State private var editing: EmuRegister?
    @State private var editValue = ""
    @State private var follow = true
    @State private var memAddress = ""
    @State private var memBytes = ""
    @State private var memDump = ""
    @State private var newWatch = ""
    @AppStorage("emuWatches") private var storedWatches = ""

    private var watchList: [String] { storedWatches.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                toolbarRow
                Divider()
                HSplitView {
                    registersPanel.frame(minWidth: 260)
                    VStack(spacing: 0) {
                        breakpointsPanel
                        Divider()
                        writesPanel
                    }
                    .frame(minWidth: 300)
                    VStack(spacing: 0) {
                        pcodePanel
                        Divider()
                        watchesPanel
                        Divider()
                        threadsPanel
                    }
                    .frame(minWidth: 300)
                }
            }
        }
        .windowMinSize(1060, 520)
        .task(id: "\(model.activeSession ?? "")|\(model.emulatorRevision)") {
            state = try? await model.engine.call("emuWatches", ["expressions": watchList])
        }
        .alert(tr("Valor de %@", "\(editing?.name ?? "")"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("0x…", text: $editValue)
            Button(tr("Escribir")) {
                if let r = editing { call("emuSetRegister", ["name": r.name, "value": editValue]) }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        }
    }

    private var pcodePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("P-code de la instrucción")).font(.caption.weight(.semibold)).padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array((state?.pcode?.ops ?? []).enumerated()), id: \.offset) { i, op in
                        HStack(spacing: 6) {
                            Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                                .opacity(state?.pcode?.active == true && state?.pcode?.index == i ? 1 : 0)
                                .foregroundStyle(.orange)
                            Text(op).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(state?.pcode?.active == true && i < (state?.pcode?.index ?? 0) ? .secondary : .primary)
                        }
                    }
                    ForEach(state?.pcode?.uniques ?? [], id: \.self) { u in
                        Text("\(u.name) = \(u.value)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.teal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
            }
        }
        .frame(minHeight: 140)
    }

    private var watchesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Expresiones vigiladas")).font(.caption.weight(.semibold))
                TextField("x0, sp+8, *:4 (sp+0xc)", text: $newWatch).textFieldStyle(.roundedBorder).font(.caption.monospaced())
                    .onSubmit(addWatch)
                Button(tr("Añadir"), action: addWatch).disabled(newWatch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(8)
            List(state?.watches ?? watchList.map { EmuWatch(expression: $0, value: "") }, id: \.self) { w in
                HStack {
                    Text(w.expression).font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Text(w.value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button {
                        storedWatches = watchList.filter { $0 != w.expression }.joined(separator: "\n")
                        call("emuWatches", ["expressions": watchList])
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
        .frame(minHeight: 120)
    }

    private func addWatch() {
        let text = newWatch.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !watchList.contains(text) else { return }
        storedWatches = (watchList + [text]).joined(separator: "\n")
        newWatch = ""
        call("emuWatches", ["expressions": watchList])
    }

    private var threadsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Hilos")).font(.caption.weight(.semibold))
                Spacer()
                Button(tr("Nuevo hilo en el cursor")) {
                    if let a = model.editTarget { call("emuNewThread", ["address": a]) }
                }
                .disabled(state?.running != true || model.editTarget == nil)
                .help(tr("Otro hilo con sus registros y su pila; la memoria es la misma"))
            }
            .controlSize(.small)
            .padding(8)
            List(state?.threads ?? []) { t in
                HStack {
                    Image(systemName: t.current ? "play.fill" : "pause").foregroundStyle(t.current ? Color.accentColor : Color.secondary)
                    Text(tr("Hilo %@", "\(t.index)"))
                    Spacer()
                    Text(t.pc).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { call("emuSwitchThread", ["index": t.index]) }
            }
            .listStyle(.plain)
        }
        .frame(minHeight: 90)
    }

    private var toolbarRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if let a = model.editTarget { call("emuStart", ["address": a]) }
                } label: { Label(tr("Iniciar aquí"), systemImage: "play.circle") }
                    .help(tr("Inicia la emulación en la dirección seleccionada (%@)", "\(model.editTarget ?? "—")"))
                    .disabled(model.editTarget == nil)
                Button { call("emuStep", ["count": 1]) } label: { Label(tr("Paso"), systemImage: "arrow.down.to.line") }
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(state?.running != true)
                Button { call("emuStep", ["count": 10]) } label: { Label("×10", systemImage: "forward.frame") }
                    .disabled(state?.running != true)
                Button { call("emuPcodeStep", ["count": 1]) } label: { Label(tr("Paso p-code"), systemImage: "arrow.down.right") }
                    .keyboardShortcut("p", modifiers: [])
                    .disabled(state?.running != true)
                    .help(tr("Ejecuta una sola operación de p-code de la instrucción actual"))
                Button { call("emuRun", [:]) } label: { Label(tr("Continuar"), systemImage: "forward.fill") }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(state?.running != true)
                Button { call("emuStop", [:]) } label: { Label(tr("Detener"), systemImage: "stop.fill") }
                    .disabled(state?.running != true)
                Spacer()
                Toggle(tr("Saltar llamadas externas"), isOn: Binding(get: { state?.skipExternal ?? true }, set: { on in
                    call("emuSkipExternal", ["on": on])
                }))
                .toggleStyle(.checkbox)
                .help(tr("Al llegar a una función importada (printf, malloc…), vuelve al llamador en lugar de emular código que no está"))
                Toggle(tr("Seguir en el código"), isOn: $follow).toggleStyle(.checkbox)
                if busy { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.glass)
            HStack(spacing: 10) {
                Image(systemName: state?.running == true ? "cpu.fill" : "cpu")
                    .foregroundStyle(state?.running == true ? Color.green : Color.secondary)
                Text(state?.status ?? tr("Detenido")).font(.callout.weight(.medium))
                if let pc = state?.pc {
                    Text("PC \(pc)").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                if let ins = state?.instruction {
                    Text(ins).font(.callout.monospaced()).foregroundStyle(Color(nsColor: Theme.mnemonic))
                }
                if let f = state?.function { Text(tr("en %@", "\(f)")).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Text(tr("%@ pasos", "\(state?.steps ?? 0)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var registersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Registros")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
            Table(state?.registers ?? []) {
                TableColumn(tr("Registro de CPU")) { r in Text(r.name).monospaced() }.width(70)
                TableColumn(tr("Valor")) { r in
                    Text(r.value).monospaced()
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = r; editValue = r.value }
                }
            }
            Text(tr("Doble clic en un valor para cambiarlo (p. ej. argumentos en x0…x7 o rdi, rsi…)."))
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private var breakpointsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("Puntos de ruptura")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Añadir en %@", "\(model.editTarget ?? "—")")) {
                    if let a = model.editTarget { call("emuBreakpoint", ["address": a, "on": true]) }
                }
                .disabled(model.editTarget == nil)
            }
            if state?.breakpoints.isEmpty ?? true {
                Text(tr("Ninguno. Selecciona una línea en el código y pulsa Añadir.")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(state?.breakpoints ?? [], id: \.self) { bp in
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(.red).font(.caption)
                    Button(bp) { model.go(bp) }.buttonStyle(.plain).font(.callout.monospaced())
                    Spacer()
                    Button { call("emuBreakpoint", ["address": bp, "on": false]) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
    }

    private var writesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Memoria escrita por la emulación")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            List(state?.writes ?? []) { w in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(w.address) · \(w.length) bytes").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(w.bytes).font(.callout.monospaced())
                }
            }
            if let log = state?.log, !log.isEmpty {
                Text(tr("Llamadas externas saltadas: ") + log.suffix(8).joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            if !memDump.isEmpty {
                Text(memDump).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField(tr("Dirección"), text: $memAddress).frame(width: 130).font(.body.monospaced())
                TextField(tr("Bytes (hex)"), text: $memBytes).font(.body.monospaced())
                Button(tr("Leer")) { readMemory() }
                    .disabled(memAddress.isEmpty || state?.running != true)
                Button(tr("Escribir")) { call("emuWriteMemory", ["address": memAddress, "bytes": memBytes]) }
                    .disabled(memAddress.isEmpty || memBytes.isEmpty || state?.running != true)
            }
        }
        .padding(10)
    }

    private func readMemory() {
        Task {
            do {
                let dump: HexDump = try await model.engine.call("emuReadMemory", ["address": memAddress, "length": 64])
                var out = ""
                for (i, chunk) in stride(from: 0, to: dump.bytes.count, by: 16).enumerated() {
                    let row = dump.bytes[chunk..<min(chunk + 16, dump.bytes.count)]
                    out += String(format: "+%02x  ", i * 16) + row.map { String(format: "%02x", $0) }.joined(separator: " ") + "\n"
                }
                memDump = out.trimmingCharacters(in: .newlines)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func call(_ method: String, _ params: [String: Any]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                state = try await model.engine.call(method, params)
                if follow, let pc = state?.pc, state?.running == true {
                    await model.navigate(to: pc, recordHistory: false)
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Program comparison (Diff + function correlation)

struct CompareView: View {
    @Environment(AppModel.self) private var model
    @State private var other: String?
    @State private var mode = 0
    @State private var diff: DiffResult?
    @State private var matches: [FunctionMatch] = []
    @State private var method = "instructions"
    @State private var minSize = 10
    @State private var selection = Set<FunctionMatch.ID>()
    @State private var diffSelection: DiffRow.ID?
    @State private var busy = false
    @State private var onlyNamed = true
    /// Diff: limit to the program selection, rows set aside, details of the chosen row and how each kind is applied.
    @State private var selectionOnly = false
    @State private var ignored = Set<String>()
    @State private var details = ""
    @State private var settings: [String: String] = [:]

    private var shownDifferences: [DiffRow] { (diff?.differences ?? []).filter { !ignored.contains($0.id) } }

    private var candidates: [ProjectFile] {
        (model.project?.tree?.allFolders ?? []).flatMap(\.files).filter { $0.program && $0.path != model.activeSession }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                HStack(spacing: 12) {
                    Text(tr("Comparar %@ con", "\(model.program?.name ?? "")")).font(.callout)
                    Picker("", selection: $other) {
                        Text(tr("Elige un programa…")).tag(String?.none)
                        ForEach(candidates) { f in Text(f.path).tag(Optional(f.path)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Picker("", selection: $mode) {
                        Text(tr("Diferencias")).tag(0)
                        Text(tr("Correlación de funciones")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(12)
                Divider()
                if mode == 0 { diffPanel } else { matchPanel }
            }
        }
        .windowMinSize(860, 540)
    }

    private var diffPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button(tr("Calcular diferencias")) { runDiff() }
                    .buttonStyle(.glassProminent)
                    .disabled(other == nil || busy)
                Toggle(tr("Solo en la selección"), isOn: $selectionOnly).toggleStyle(.checkbox)
                    .disabled(model.programSelection == nil)
                    .help(tr("Compara solo las direcciones de la selección del programa"))
                Menu(tr("Cómo aplicar")) {
                    ForEach(["Bytes", "Código/datos", "Símbolos", "Funciones", "Comentarios", "Referencias", "Equates", "Marcadores",
                             "Contexto"], id: \.self) { kind in
                        Picker(tr(kind), selection: Binding(get: { settings[kind] ?? "replace" }, set: { settings[kind] = $0 })) {
                            Text(tr("Reemplazar")).tag("replace")
                            if kind == "Comentarios" || kind == "Símbolos" { Text(tr("Fusionar")).tag("merge") }
                            Text(tr("No aplicar")).tag("ignore")
                        }
                    }
                }
                .fixedSize()
                .help(tr("Qué se hace con cada clase de diferencia al aplicar"))
                Spacer()
                Text(tr("Mismo procesador y espacio de direcciones.")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Table(shownDifferences, selection: $diffSelection) {
                TableColumn(tr("Dirección")) { d in Text(d.address).monospaced() }.width(min: 90, ideal: 110)
                TableColumn(tr("Tipo")) { d in Text(tr(d.kind)) }.width(min: 80, ideal: 110)
                TableColumn("Bytes") { d in Text("\(d.length)").monospacedDigit() }.width(60)
                TableColumn(tr("Función")) { d in Text(d.function ?? "—").foregroundStyle(.secondary) }
            }
            .onChange(of: diffSelection) { _, id in
                if let id, let d = diff?.differences.first(where: { $0.id == id }) {
                    model.go(d.address)
                    loadDetails(d.address)
                }
            }
            if !details.isEmpty {
                ScrollView {
                    Text(details).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 130)
                .background(Color(nsColor: Theme.background))
            }
            if let diff {
                HStack(alignment: .top, spacing: 20) {
                    Text("\(shownDifferences.count) diferencias\(diff.truncated ? " (truncado)" : "")")
                    Button(tr("Ignorar la seleccionada")) {
                        guard let id = diffSelection else { return }
                        // go on to the next one, like "Ignore and go to next"
                        let list = shownDifferences
                        let next = list.firstIndex { $0.id == id }.flatMap { $0 + 1 < list.count ? list[$0 + 1].id : nil }
                        ignored.insert(id)
                        diffSelection = next
                    }
                    .disabled(diffSelection == nil)
                    if !ignored.isEmpty { Button(tr("Recuperar ignoradas (%@)", "\(ignored.count)")) { ignored = [] } }
                    if !diff.onlyInThis.isEmpty { Text(tr("Solo en este: %@", "\(diff.onlyInThis.prefix(3).joined(separator: ", "))")) }
                    if !diff.onlyInOther.isEmpty { Text(tr("Solo en el otro: %@", "\(diff.onlyInOther.prefix(3).joined(separator: ", "))")) }
                    Spacer()
                    Button(tr("Aplicar la seleccionada")) {
                        if let d = diff.differences.first(where: { $0.id == diffSelection }) { applyDiff([d]) }
                    }
                    .disabled(diffSelection == nil || busy)
                    Button(tr("Aplicar todas a este programa")) { applyDiff(shownDifferences) }
                        .disabled(shownDifferences.isEmpty || busy)
                        .help(tr("Copia del otro programa bytes, código, símbolos, funciones, comentarios… en esas direcciones"))
                }
                .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
    }

    private var matchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(tr("Método"), selection: $method) {
                    Text(tr("Instrucciones exactas")).tag("instructions")
                    Text(tr("Mnemónicos exactos")).tag("mnemonics")
                    Text(tr("Bytes exactos")).tag("bytes")
                }
                .fixedSize()
                Stepper(tr("Tamaño mínimo: %@", "\(minSize)"), value: $minSize, in: 1...200, step: 4).fixedSize()
                Button(tr("Buscar coincidencias")) { runMatch() }
                    .buttonStyle(.glassProminent)
                    .disabled(other == nil || busy)
                Spacer()
                Toggle(tr("Solo con nombre en el otro"), isOn: $onlyNamed).toggleStyle(.checkbox)
            }
            .padding(10)
            let rows = matches.filter { !onlyNamed || ($0.otherNamed && !$0.sameName) }
            Table(rows, selection: $selection) {
                TableColumn(tr("Este programa")) { m in
                    VStack(alignment: .leading) {
                        Text(m.name).monospaced()
                        Text(m.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                TableColumn("") { m in Image(systemName: m.sameName ? "equal" : "arrow.left").foregroundStyle(.secondary) }
                    .width(24)
                TableColumn(tr("Otro programa")) { m in
                    VStack(alignment: .leading) {
                        Text(m.otherName).monospaced().foregroundStyle(m.otherNamed ? .primary : .secondary)
                        Text(m.otherAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                TableColumn(tr("Tamaño")) { m in Text("\(m.size)").monospacedDigit() }.width(60)
            }
            .contextMenu(forSelectionType: FunctionMatch.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let m = matches.first(where: { $0.id == id }) { model.go(m.address) }
            }
            HStack {
                Text(tr("%@ coincidencias · %@ seleccionadas", "\(rows.count)", "\(selection.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Seleccionar todas")) { selection = Set(rows.map(\.id)) }
                Button(tr("Aplicar nombres del otro programa")) { applyNames(rows.filter { selection.contains($0.id) }) }
                    .buttonStyle(.glassProminent)
                    .disabled(selection.isEmpty || busy)
            }
            .padding(10)
        }
    }

    private func applyDiff(_ rows: [DiffRow]) {
        guard let other, !rows.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let ranges = rows.map { ["address": $0.address, "end": $0.end] }
                let kinds = Array(Set(rows.map(\.kind)))
                let r: DiffApplyResult = try await model.engine.call("applyDiff", ["other": other, "ranges": ranges,
                                                                                  "kinds": rows.count == 1 ? kinds : [],
                                                                                  "settings": settings])
                await model.refreshAfterEdits()
                diff = try await model.engine.call("diff", diffParams(other))
                if let e = r.error, !e.isEmpty { model.errorMessage = e }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func runDiff() {
        guard let other else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                diff = try await model.engine.call("diff", diffParams(other))
                ignored = []
                details = ""
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func diffParams(_ other: String) -> [String: Any] {
        var params: [String: Any] = ["other": other]
        if selectionOnly, let selection = model.programSelection { params["ranges"] = selection.ranges }
        return params
    }

    private func loadDetails(_ address: String) {
        guard let other else { return }
        Task {
            let result: JSONRow? = try? await model.engine.call("diffDetails", ["other": other, "address": address])
            details = result?["details"]?.text ?? ""
        }
    }

    private func runMatch() {
        guard let other else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                matches = try await model.engine.call("matchFunctions", ["other": other, "method": method, "minSize": minSize])
                selection = []
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyNames(_ rows: [FunctionMatch]) {
        guard let other else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let pairs = rows.map { ["address": $0.address, "otherAddress": $0.otherAddress] }
                let result: AppliedResult = try await model.engine.call("applyNames", ["other": other, "pairs": pairs])
                model.errorMessage = tr("Se aplicaron %@ nombres. Guarda con ⌘S para conservarlos.", "\(result.applied)")
                await model.refreshAfterEdits()
                runMatch()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Symbol tree (sidebar)

struct SymbolTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var roots: [NamespaceNode]?

    var body: some View {
        List {
            if let roots {
                ForEach(roots) { node in SymbolNodeRow(node: node) }
            } else {
                ProgressView()
            }
        }
        .listStyle(.sidebar)
        .task(id: "\(model.activeSession ?? "")|\(model.functions.count)") {
            roots = (try? await model.engine.call("namespaceChildren", ["id": 0])) ?? []
        }
    }
}

private struct SymbolNodeRow: View {
    @Environment(AppModel.self) private var model
    let node: NamespaceNode
    @State private var expanded = false
    @State private var children: [NamespaceNode]?

    var body: some View {
        if node.container {
            DisclosureGroup(isExpanded: $expanded) {
                if let children {
                    ForEach(children) { SymbolNodeRow(node: $0) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: { label }
            .onChange(of: expanded) { _, open in
                guard open, children == nil else { return }
                Task { children = (try? await model.engine.call("namespaceChildren", ["id": node.id])) ?? [] }
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let a = node.address { Text(a).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let a = node.address { model.go(a) } }
    }

    private var icon: String {
        switch node.kind {
        case "Function": "f.cursive"
        case "Class": "c.square"
        case "Namespace": "curlybraces"
        case "Library": "building.columns"
        case "Label": "tag"
        case "Parameter", "Local Var": "x.squareroot"
        default: "circle.dashed"
        }
    }

    private var tint: Color {
        switch node.kind {
        case "Function": .purple
        case "Class": .teal
        case "Library": .orange
        case "Label": .blue
        default: .secondary
        }
    }
}

// MARK: - Memory block sheet

struct AddBlockSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "nuevo_bloque"
    @State private var start = ""
    @State private var length = "0x1000"
    @State private var kind = "initialized"
    @State private var overlay = false
    @State private var source = ""

    private var mapped: Bool { kind == "bit" || kind == "byte" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Añadir bloque de memoria")).font(.title3.weight(.semibold))
            Form {
                TextField(tr("Nombre"), text: $name)
                TextField(tr("Dirección inicial"), text: $start).font(.body.monospaced())
                TextField(tr("Tamaño"), text: $length).font(.body.monospaced())
                Picker(tr("Tipo"), selection: $kind) {
                    Text(tr("Inicializado (ceros)")).tag("initialized")
                    Text(tr("Sin inicializar")).tag("uninitialized")
                    Text(tr("Mapeado por bytes")).tag("byte")
                    Text(tr("Mapeado por bits")).tag("bit")
                }
                .pickerStyle(.segmented)
                if mapped {
                    TextField(tr("Dirección de origen que refleja"), text: $source).font(.body.monospaced())
                }
                Toggle(tr("Overlay: espacio de direcciones propio, puede solaparse con otros bloques"), isOn: $overlay)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Añadir")) {
                    var params: [String: Any] = ["name": name, "address": start, "length": length, "kind": kind,
                                                 "overlay": overlay]
                    if mapped { params["source"] = source }
                    model.memoryAction("addBlockEx", params)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(name.isEmpty || start.isEmpty || length.isEmpty || (mapped && source.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            if let last = model.segments.last, let end = addressValue(last.end) {
                start = String((end + 0x1000) & ~0xfff, radix: 16)
            }
        }
    }
}
