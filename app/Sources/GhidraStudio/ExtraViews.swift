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
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task(id: model.activeSession) { state = try? await model.engine.call("emuState") }
        .alert(tr("Valor de %@", "\(editing?.name ?? "")"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("0x…", text: $editValue)
            Button(tr("Escribir")) {
                if let r = editing { call("emuSetRegister", ["name": r.name, "value": editValue]) }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        }
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
                Button { call("emuRun", [:]) } label: { Label(tr("Continuar"), systemImage: "forward.fill") }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(state?.running != true)
                Button { call("emuStop", [:]) } label: { Label(tr("Detener"), systemImage: "stop.fill") }
                    .disabled(state?.running != true)
                Spacer()
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
            HStack {
                TextField(tr("Dirección"), text: $memAddress).frame(width: 130).font(.body.monospaced())
                TextField(tr("Bytes (hex)"), text: $memBytes).font(.body.monospaced())
                Button(tr("Escribir")) { call("emuWriteMemory", ["address": memAddress, "bytes": memBytes]) }
                    .disabled(memAddress.isEmpty || memBytes.isEmpty || state?.running != true)
            }
        }
        .padding(10)
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
        .frame(minWidth: 860, minHeight: 540)
    }

    private var diffPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button(tr("Calcular diferencias")) { runDiff() }
                    .buttonStyle(.glassProminent)
                    .disabled(other == nil || busy)
                Text(tr("Requiere programas con el mismo procesador y espacio de direcciones (dos versiones del mismo binario)."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            Table(diff?.differences ?? [], selection: $diffSelection) {
                TableColumn(tr("Dirección")) { d in Text(d.address).monospaced() }.width(min: 90, ideal: 110)
                TableColumn(tr("Tipo")) { d in Text(tr(d.kind)) }.width(min: 80, ideal: 110)
                TableColumn("Bytes") { d in Text("\(d.length)").monospacedDigit() }.width(60)
                TableColumn(tr("Función")) { d in Text(d.function ?? "—").foregroundStyle(.secondary) }
            }
            .onChange(of: diffSelection) { _, id in
                if let id, let d = diff?.differences.first(where: { $0.id == id }) { model.go(d.address) }
            }
            if let diff {
                HStack(alignment: .top, spacing: 20) {
                    Text("\(diff.differences.count) diferencias\(diff.truncated ? " (truncado)" : "")")
                    if !diff.onlyInThis.isEmpty { Text(tr("Solo en este: %@", "\(diff.onlyInThis.prefix(3).joined(separator: ", "))")) }
                    if !diff.onlyInOther.isEmpty { Text(tr("Solo en el otro: %@", "\(diff.onlyInOther.prefix(3).joined(separator: ", "))")) }
                    Spacer()
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

    private func runDiff() {
        guard let other else { return }
        busy = true
        Task {
            defer { busy = false }
            do { diff = try await model.engine.call("diff", ["other": other]) } catch {
                model.errorMessage = error.localizedDescription
            }
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
    @State private var initialized = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Añadir bloque de memoria")).font(.title3.weight(.semibold))
            Form {
                TextField(tr("Nombre"), text: $name)
                TextField(tr("Dirección inicial"), text: $start).font(.body.monospaced())
                TextField(tr("Tamaño"), text: $length).font(.body.monospaced())
                Toggle(tr("Inicializado (rellenado con ceros)"), isOn: $initialized)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Añadir")) {
                    model.memoryAction("addBlock", ["name": name, "address": start, "length": length,
                                                    "initialized": initialized])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(name.isEmpty || start.isEmpty || length.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            if let last = model.segments.last, let end = addressValue(last.end) {
                start = String((end + 0x1000) & ~0xfff, radix: 16)
            }
        }
    }
}
