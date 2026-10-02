import SwiftUI

// MARK: - Function editor

struct FunctionEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var props: FunctionProperties?
    @State private var convention = ""
    @State private var noReturn = false
    @State private var inline = false
    @State private var varArgs = false
    @State private var customStorage = false
    @State private var newTag = ""
    @State private var editing: FunctionVariable?
    @State private var editName = ""
    @State private var editType = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Editar función")).font(.title3.weight(.semibold))
            if let p = props {
                Text(p.signature).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                Form {
                    Section(tr("Atributos")) {
                        Picker(tr("Convención de llamada"), selection: $convention) {
                            ForEach(p.conventions, id: \.self) { Text($0).tag($0) }
                            if !p.conventions.contains(convention) { Text(convention).tag(convention) }
                        }
                        Toggle(tr("No retorna"), isOn: $noReturn)
                        Toggle("Inline", isOn: $inline)
                        Toggle(tr("Argumentos variables (…)"), isOn: $varArgs)
                        Toggle(tr("Almacenamiento personalizado de variables"), isOn: $customStorage)
                        LabeledContent(tr("Pila"), value: tr("%@ bytes (locales %@, parámetros %@)", "\(p.stackSize)", "\(p.localSize)", "\(p.paramSize)"))
                    }
                    Section(tr("Variables y pila")) {
                        ForEach(p.variables) { v in
                            HStack {
                                Image(systemName: v.parameter ? "arrow.right.to.line" : "square.stack")
                                    .foregroundStyle(v.parameter ? Color.teal : Color.secondary)
                                Text(v.name).monospaced()
                                Spacer()
                                Text(v.type).monospaced().foregroundStyle(.secondary)
                                Text(v.storage).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                Button { editing = v; editName = v.name; editType = v.type } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if p.variables.isEmpty { Text(tr("Sin variables")).foregroundStyle(.secondary) }
                    }
                    Section(tr("Etiquetas de función")) {
                        ForEach(p.tags, id: \.self) { tag in
                            HStack {
                                Label(tag, systemImage: "tag.fill")
                                Spacer()
                                Button { setTag(tag, on: false) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField(tr("Nueva etiqueta"), text: $newTag)
                            Button(tr("Añadir")) { setTag(newTag, on: true); newTag = "" }
                                .disabled(newTag.isEmpty)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: 440)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                Button(tr("Editar firma…")) { dismiss(); model.requestSignature() }
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Guardar")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(props == nil)
            }
        }
        .padding(22)
        .frame(width: 600)
        .task { await load() }
        .alert(tr("Editar variable"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(tr("Nombre"), text: $editName)
            TextField(tr("Tipo"), text: $editType)
            Button(tr("Guardar")) {
                guard let v = editing, let entry = props?.entry else { return }
                Task {
                    do {
                        _ = try await model.engine.call("editVariable", ["address": entry, "name": v.name,
                                                                         "newName": editName,
                                                                         "type": editType == v.type ? "" : editType],
                                                        as: Bool.self)
                        await load()
                        await model.refreshAfterEdits()
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        }
    }

    private func load() async {
        guard let entry = model.functionDetails?.entry else { return }
        do {
            let p: FunctionProperties = try await model.engine.call("functionProperties", ["address": entry])
            props = p
            convention = p.callingConvention ?? "unknown"
            noReturn = p.noReturn
            inline = p.inline
            varArgs = p.varArgs
            customStorage = p.customStorage
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func setTag(_ tag: String, on: Bool) {
        guard let entry = props?.entry else { return }
        Task {
            _ = try? await model.engine.call("setFunctionTag", ["address": entry, "tag": tag, "on": on], as: Bool.self)
            await load()
            await model.refreshUndo()
        }
    }

    private func save() {
        guard let p = props else { return }
        var params: [String: Any] = ["address": p.entry]
        if convention != p.callingConvention { params["callingConvention"] = convention }
        if noReturn != p.noReturn { params["noReturn"] = noReturn }
        if inline != p.inline { params["inline"] = inline }
        if varArgs != p.varArgs { params["varArgs"] = varArgs }
        if customStorage != p.customStorage { params["customStorage"] = customStorage }
        Task {
            do {
                if params.count > 1 {
                    _ = try await model.engine.call("editFunction", params, as: Bool.self)
                    await model.refreshAfterEdits()
                }
                dismiss()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Typed option rows (decompiler options, analyzer sub-options)

struct TypedOptionRow: View {
    let option: TypedOption
    let onChange: (String) -> Void
    @State private var text = ""

    var body: some View {
        switch option.type {
        case "bool":
            Toggle(option.label, isOn: Binding(get: { option.value == "true" }, set: { onChange($0 ? "true" : "false") }))
                .help(option.description ?? "")
        case "enum":
            Picker(option.label, selection: Binding(get: { option.value }, set: { onChange($0) })) {
                ForEach(option.choices ?? [], id: \.self) { Text($0).tag($0) }
            }
            .help(option.description ?? "")
        default:
            LabeledContent(option.label) {
                TextField("", text: $text)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 160)
                    .onSubmit { onChange(text) }
            }
            .onAppear { text = option.value }
            .help(option.description ?? "")
        }
    }
}

struct DecompilerOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options: [TypedOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Opciones del descompilador")).font(.title3.weight(.semibold))
            Form {
                ForEach(options) { opt in
                    TypedOptionRow(option: opt) { value in set(opt, value) }
                }
            }
            .formStyle(.grouped)
            .frame(height: 460)
            HStack {
                Text(tr("Los campos de texto se aplican al pulsar Intro.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { options = (try? await model.engine.call("decompilerOptions")) ?? [] }
    }

    private func set(_ opt: TypedOption, _ value: String) {
        Task {
            do {
                _ = try await model.engine.call("setDecompilerOption", ["key": opt.key ?? "", "value": value], as: Bool.self)
                options = (try? await model.engine.call("decompilerOptions")) ?? options
                await model.refreshAfterEdits()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Tables (symbols, relocations, strings, equates, scalars)

struct TablesView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var filter = ""
    @State private var userOnly = false
    @State private var symbols: [SymbolRow] = []
    @State private var relocations: [RelocationRow] = []
    @State private var strings: [FoundStringRow] = []
    @State private var equates: [EquateRow] = []
    @State private var scalars: [SearchResult] = []
    @State private var minLength = 5
    @State private var undefinedOnly = true
    @State private var scalar = ""
    @State private var busy = false
    @State private var symbolSelection: SymbolRow.ID?
    @State private var stringSelection = Set<FoundStringRow.ID>()
    @State private var relocSelection: RelocationRow.ID?
    @State private var scalarSelection: SearchResult.ID?

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                HStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        Text(tr("Símbolos")).tag(0)
                        Text(tr("Cadenas")).tag(1)
                        Text(tr("Constantes")).tag(2)
                        Text(tr("Relocaciones")).tag(3)
                        Text(tr("Equates")).tag(4)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(12)
                Divider()
                switch tab {
                case 0: symbolsPanel
                case 1: stringsPanel
                case 2: scalarsPanel
                case 3: relocationsPanel
                default: equatesPanel
                }
            }
        }
        .windowMinSize(860, 520)
        .task(id: "\(tab)|\(model.activeSession ?? "")") { await load() }
    }

    private var symbolsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Filtrar por nombre"), text: $filter).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
                Toggle(tr("Solo definidos por el usuario"), isOn: $userOnly).toggleStyle(.checkbox)
                    .onChange(of: userOnly) { _, _ in Task { await load() } }
                Button(tr("Buscar")) { Task { await load() } }
            }
            .padding(10)
            Table(symbols, selection: $symbolSelection) {
                TableColumn(tr("Nombre")) { r in Text(r.name).monospaced().lineLimit(1) }
                TableColumn(tr("Dirección")) { r in Text(r.address ?? tr("externo")).monospaced() }.width(min: 90, ideal: 110)
                TableColumn(tr("Tipo")) { r in Text(tr(r.kind)) }.width(min: 70, ideal: 90)
                TableColumn("Namespace") { r in Text(r.namespace).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn(tr("Origen")) { r in Text(r.source.capitalized).foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                TableColumn("Refs") { r in Text("\(r.references)").monospacedDigit() }.width(50)
            }
            .onChange(of: symbolSelection) { _, id in
                if let id, let r = symbols.first(where: { $0.id == id }), let a = r.address { model.go(a) }
            }
            footer(tr("%@ símbolos%@", "\(symbols.count)", "\(symbols.count >= 5000 ? " (máximo 5000; usa el filtro)" : "")"))
        }
    }

    private var stringsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Stepper(tr("Longitud mínima: %@", "\(minLength)"), value: $minLength, in: 3...64).fixedSize()
                Toggle(tr("Solo sin definir"), isOn: $undefinedOnly).toggleStyle(.checkbox)
                Button(tr("Buscar cadenas")) { Task { await load() } }.buttonStyle(.glassProminent)
                Spacer()
                Button(tr("Definir seleccionadas")) { defineSelected() }.disabled(stringSelection.isEmpty)
            }
            .padding(10)
            Table(strings, selection: $stringSelection) {
                TableColumn(tr("Dirección")) { r in Text(r.address).monospaced() }.width(min: 90, ideal: 110)
                TableColumn(tr("Long.")) { r in Text("\(r.length)").monospacedDigit() }.width(50)
                TableColumn(tr("Estado")) { r in Text(r.defined ? tr("Definida") : tr("Sin definir")).foregroundStyle(r.defined ? .secondary : .primary) }
                    .width(min: 70, ideal: 90)
                TableColumn(tr("Cadena")) { r in Text(r.value).monospaced().lineLimit(1) }
            }
            .contextMenu(forSelectionType: FoundStringRow.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { model.go(id) }
            }
            footer(tr("%@ cadenas · doble clic para ir", "\(strings.count)"))
        }
    }

    private var scalarsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Valor, p. ej. 0x1000 o 4096"), text: $scalar).textFieldStyle(.roundedBorder)
                    .font(.body.monospaced()).onSubmit { Task { await load() } }
                Button(tr("Buscar constante")) { Task { await load() } }.buttonStyle(.glassProminent).disabled(scalar.isEmpty)
            }
            .padding(10)
            Table(scalars, selection: $scalarSelection) {
                TableColumn(tr("Dirección")) { r in Text(r.address).monospaced() }.width(min: 90, ideal: 110)
                TableColumn(tr("Función")) { r in Text(r.function ?? "—").foregroundStyle(.secondary) }
                TableColumn(tr("Instrucción")) { r in Text(r.text).monospaced() }
            }
            .onChange(of: scalarSelection) { _, id in
                if let id, let r = scalars.first(where: { $0.id == id }) { model.go(r.address) }
            }
            footer("\(scalars.count) usos")
        }
    }

    private var relocationsPanel: some View {
        VStack(spacing: 0) {
            Table(relocations, selection: $relocSelection) {
                TableColumn(tr("Dirección")) { r in Text(r.address).monospaced() }.width(min: 90, ideal: 110)
                TableColumn(tr("Tipo")) { r in Text(r.type).monospaced() }.width(60)
                TableColumn(tr("Estado")) { r in Text(r.status.capitalized) }.width(min: 70, ideal: 90)
                TableColumn(tr("Símbolo")) { r in Text(r.symbol ?? "—").monospaced().lineLimit(1) }
                TableColumn(tr("Valores")) { r in Text(r.values).monospaced().foregroundStyle(.secondary) }
                TableColumn(tr("Bytes originales")) { r in Text(r.bytes).monospaced().foregroundStyle(.secondary) }
            }
            .onChange(of: relocSelection) { _, id in
                if let id, let r = relocations.first(where: { $0.id == id }) { model.go(r.address) }
            }
            footer("\(relocations.count) relocaciones")
        }
    }

    private var equatesPanel: some View {
        VStack(spacing: 0) {
            Table(equates) {
                TableColumn(tr("Nombre")) { r in Text(r.name).monospaced() }
                TableColumn(tr("Valor")) { r in Text(String(format: "0x%llx (%lld)", r.value, r.value)).monospaced() }
                TableColumn(tr("Usos")) { r in Text("\(r.references)").monospacedDigit() }.width(60)
            }
            footer(tr("%@ equates · se crean con clic derecho ▸ Nombre para constante", "\(equates.count)"))
        }
    }

    private func footer(_ text: String) -> some View {
        HStack { Text(text).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(10)
    }

    private func load() async {
        guard model.program != nil else { return }
        busy = true
        defer { busy = false }
        do {
            switch tab {
            case 0: symbols = try await model.engine.call("symbolTable", ["filter": filter, "userOnly": userOnly])
            case 1: strings = try await model.engine.call("findStrings", ["minLength": minLength, "undefinedOnly": undefinedOnly])
            case 2: if !scalar.isEmpty { scalars = try await model.engine.call("searchScalar", ["value": scalar]) }
            case 3: relocations = try await model.engine.call("relocations")
            default: equates = try await model.engine.call("equates")
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func defineSelected() {
        let rows = strings.filter { stringSelection.contains($0.id) && !$0.defined }
        Task {
            for r in rows {
                _ = try? await model.engine.call("defineString", ["address": r.address, "length": r.length], as: Bool.self)
            }
            await model.refreshAfterEdits()
            await load()
        }
    }
}

// MARK: - Side-by-side function comparison

struct FunctionCompareView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = "c"
    @State private var otherProgram: String?
    @State private var otherFunctions: [FunctionItem] = []
    @State private var otherAddress: String?
    @State private var query = ""
    @State private var left: FunctionText?
    @State private var right: FunctionText?
    @State private var busy = false
    @State private var showFunctionList = false
    /// none, constants or operands: what the disassembly comparison leaves out.
    @State private var ignore = "none"
    /// Functions sent by another window: the first one against each of the others.
    @State private var queue: [String] = []
    @State private var queueIndex = 1
    /// Decompiler mode: pair the tokens of both functions (the classic's decompiler diff) instead of comparing lines.
    @AppStorage("compareTokens") private var pairTokens = true
    @AppStorage("compareExactConstants") private var exactConstants = false
    @State private var tokens: TokenMatch?
    @State private var pickedPair: Int?
    @State private var tokenError: String?

    private var programs: [ProjectFile] {
        (model.project?.tree?.allFolders ?? []).flatMap(\.files).filter(\.program)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                HStack(spacing: 10) {
                    Picker("", selection: $mode) {
                        Text(tr("Descompilado")).tag("c")
                        Text(tr("Desensamblado")).tag("asm")
                        Text("Bytes").tag("bytes")
                        Text(tr("Grafo")).tag("graph")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if mode == "asm" {
                        Picker("", selection: $ignore) {
                            Text(tr("Comparar todo")).tag("none")
                            Text(tr("Ignorar constantes")).tag("constants")
                            Text(tr("Ignorar operandos")).tag("operands")
                        }
                        .labelsHidden().fixedSize()
                    }
                    if mode == "c" {
                        Toggle(tr("Emparejar tokens"), isOn: $pairTokens).toggleStyle(.checkbox)
                            .help(tr("Empareja cada variable, operación y constante con la equivalente de la otra función, como la comparación del descompilador de Ghidra. Sin marcar, se comparan las líneas de texto."))
                        if pairTokens {
                            Toggle(tr("Constantes exactas"), isOn: $exactConstants).toggleStyle(.checkbox)
                        }
                    }
                    if queue.count > 2 {
                        ControlGroup {
                            Button { step(-1) } label: { Image(systemName: "chevron.backward") }.disabled(queueIndex <= 1)
                            Button { step(1) } label: { Image(systemName: "chevron.forward") }.disabled(queueIndex >= queue.count - 1)
                        }
                        .fixedSize()
                        .help(tr("Función %@ de %@ elegidas", "\(queueIndex)", "\(queue.count - 1)"))
                    }
                    Text(tr("Comparar con")).font(.callout)
                    Picker("", selection: $otherProgram) {
                        Text(tr("Este programa")).tag(String?.none)
                        ForEach(programs.filter { $0.path != model.activeSession }) { f in Text(f.path).tag(Optional(f.path)) }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                    Button {
                        showFunctionList.toggle()
                    } label: {
                        Label(right?.name ?? tr("Elegir función…"), systemImage: "f.cursive")
                            .lineLimit(1)
                            .frame(maxWidth: 260)
                    }
                    .popover(isPresented: $showFunctionList, arrowEdge: .bottom) {
                        VStack(spacing: 0) {
                            TextField(tr("Buscar función"), text: $query)
                                .textFieldStyle(.roundedBorder)
                                .padding(8)
                            List(filteredFunctions.prefix(500)) { f in
                                Button {
                                    otherAddress = f.address
                                    showFunctionList = false
                                } label: {
                                    HStack {
                                        Text(f.name).monospaced().lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(f.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 420, height: 380)
                    }
                    Spacer()
                    Menu(tr("Aplicar al de la izquierda")) {
                        Button(tr("Nombre")) { apply("name") }
                        Button(tr("Firma")) { apply("signature") }
                        Button(tr("Nombre y firma")) { apply("both") }
                        Button(tr("Comentario")) { apply("comment") }
                    }
                    .fixedSize()
                    .disabled(left == nil || right == nil)
                    .help(tr("Copia a la función de la izquierda el nombre o la firma de la de la derecha"))
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(12)
                Divider()
                let diff = DiffLines(left?.lines ?? [], right?.lines ?? [])
                if mode == "c", pairTokens, let tokens {
                    HStack(spacing: 0) {
                        TokenPane(side: tokens.left, other: tokens.right, isLeft: true, picked: $pickedPair, apply: applyToken)
                        Divider()
                        TokenPane(side: tokens.right, other: tokens.left, isLeft: false, picked: $pickedPair, apply: applyToken)
                    }
                    HStack {
                        Text(tr("%@ parejas de tokens · sin pareja: %@ a la izquierda, %@ a la derecha. Haz clic en un token para ver su pareja; con el botón derecho se aplica su nombre o su tipo al de la izquierda.",
                                "\(tokens.pairs)", "\(tokens.unmatchedLeft)", "\(tokens.unmatchedRight)"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(8)
                } else {
                HStack(spacing: 0) {
                    pane(title: left.map { "\($0.name) · \($0.program)" } ?? tr("Función actual"),
                         lines: left?.lines ?? [], changed: diff.leftOnly, tint: .red)
                    Divider()
                    pane(title: right.map { "\($0.name) · \($0.program)" } ?? tr("Elige la función a comparar"),
                         lines: right?.lines ?? [], changed: diff.rightOnly, tint: .green)
                }
                HStack {
                    Text(tokenError ?? (right == nil ? tr("Elige arriba la otra función.")
                         : tr("%@ líneas solo a la izquierda · %@ solo a la derecha", "\(diff.leftOnly.count)", "\(diff.rightOnly.count)")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
                .padding(8)
                }
            }
        }
        .windowMinSize(980, 600)
        .task(id: "\(model.functionDetails?.entry ?? "")|\(mode)|\(ignore)|\(model.activeSession ?? "")|\(queue.first ?? "")|\(model.editCount)") {
            await loadLeft()
        }
        .task(id: "\(otherProgram ?? "")") { await loadFunctions() }
        .task(id: "\(otherAddress ?? "")|\(mode)|\(ignore)|\(otherProgram ?? "")") { await loadRight() }
        .task(id: "\(left?.entry ?? "")|\(right?.entry ?? "")|\(otherProgram ?? "")|\(mode)|\(pairTokens)|\(exactConstants)|\(model.editCount)") {
            await loadTokens()
        }
        .onAppear { takeRequest() }
        .onChange(of: model.compareRequest) { _, _ in takeRequest() }
    }

    /// Pairs the tokens of the two decompiled functions.
    private func loadTokens() async {
        tokenError = nil
        guard mode == "c", pairTokens, let left, let right else { tokens = nil; return }
        busy = true
        defer { busy = false }
        var params: [String: Any] = ["address": left.entry, "otherAddress": right.entry, "exactConstants": exactConstants]
        if let other = otherProgram { params["other"] = other }
        do {
            tokens = try await model.engine.call("tokenMatch", params)
            pickedPair = nil
        } catch {
            tokens = nil
            tokenError = tr("No se pudieron emparejar los tokens (%@); se comparan las líneas.", error.localizedDescription)
        }
    }

    /// Applies the name or the type of a token of the right function to its pair on the left.
    private func applyToken(_ mine: MatchToken, _ theirs: MatchToken, _ what: String) {
        guard let left else { return }
        Task {
            do {
                switch (what, mine.k) {
                case ("name", "var"):
                    try await model.edit("renameVariable", ["address": left.entry, "name": mine.v ?? mine.t, "newName": theirs.t])
                case ("name", _):
                    guard let target = mine.target else { return }
                    try await model.edit("rename", ["address": target, "name": theirs.t])
                case ("type", "var"):
                    try await model.edit("retypeVariable", ["address": left.entry, "name": mine.v ?? mine.t, "type": theirs.ty ?? ""])
                case ("type", _):
                    guard let target = mine.target else { return }
                    try await model.edit("createData", ["address": target, "type": theirs.ty ?? ""])
                default: break
                }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private var filteredFunctions: [FunctionItem] {
        let list = otherProgram == nil ? model.functions : otherFunctions
        return query.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func pane(title: String, lines: [String], changed: Set<Int>, tint: Color) -> some View {
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

    private func loadLeft() async {
        guard let entry = queue.first ?? model.functionDetails?.entry else { left = nil; return }
        left = try? await model.engine.call("functionTextEx", ["address": entry, "mode": mode, "ignore": ignore])
    }

    /// Functions chosen in another window (the functions table): the first against the rest.
    private func takeRequest() {
        guard model.compareRequest.count >= 2 else { return }
        queue = model.compareRequest
        model.compareRequest = []
        queueIndex = 1
        otherProgram = nil
        otherAddress = queue[1]
    }

    private func step(_ delta: Int) {
        queueIndex = max(1, min(queue.count - 1, queueIndex + delta))
        otherAddress = queue[queueIndex]
    }

    private func apply(_ what: String) {
        guard let left, let right else { return }
        Task {
            do {
                var params: [String: Any] = ["address": left.entry, "otherAddress": right.entry, "what": what]
                if let other = otherProgram { params["other"] = other }
                try await model.edit("applyFunction", params)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func loadFunctions() async {
        otherAddress = nil
        right = nil
        guard let other = otherProgram else { otherFunctions = []; return }
        busy = true
        defer { busy = false }
        otherFunctions = (try? await model.engine.call("functionsOf", ["other": other])) ?? []
    }

    private func loadRight() async {
        guard let address = otherAddress else { right = nil; return }
        busy = true
        defer { busy = false }
        var params: [String: Any] = ["address": address, "mode": mode, "ignore": ignore]
        if let other = otherProgram { params["other"] = other }
        do { right = try await model.engine.call("functionTextEx", params) } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Matched tokens of two decompiled functions

struct MatchToken: Codable, Hashable {
    let t: String
    let s: Int
    /// Pair number shared with the equivalent tokens of the other function; -1 when it has no pair.
    var p: Int? = nil
    /// "var", "global" or "func", with the variable name, its type and the address it stands for.
    var k: String? = nil
    var v: String? = nil
    var ty: String? = nil
    var target: String? = nil
}

struct MatchLine: Codable, Hashable {
    let indent: Int
    let tokens: [MatchToken]
}

struct MatchSide: Codable {
    let name: String
    let entry: String
    let program: String
    let lines: [MatchLine]
}

struct TokenMatch: Codable {
    let left: MatchSide
    let right: MatchSide
    let pairs: Int
    let unmatchedLeft: Int
    let unmatchedRight: Int
}

/// One side of the decompiler diff: tokens without a pair are tinted, and the picked pair is marked on both sides.
private struct TokenPane: View {
    let side: MatchSide
    let other: MatchSide
    let isLeft: Bool
    @Binding var picked: Int?
    let apply: (MatchToken, MatchToken, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(side.name) · \(side.program)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(8)
            Divider()
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(side.lines.enumerated()), id: \.offset) { i, line in
                                HStack(spacing: 0) {
                                    Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                        .frame(width: 34, alignment: .trailing).padding(.trailing, 8)
                                    Text(String(repeating: " ", count: line.indent * 2)).font(.system(size: 12, design: .monospaced))
                                        .fixedSize()
                                    ForEach(Array(line.tokens.enumerated()), id: \.offset) { _, token in
                                        tokenView(token)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 1)
                                .id(i)
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                    .onChange(of: picked) { _, pair in
                        // bring the pair into view on this side too
                        guard let pair, pair >= 0,
                              let line = side.lines.firstIndex(where: { $0.tokens.contains { $0.p == pair } }) else { return }
                        withAnimation { proxy.scrollTo(line, anchor: .center) }
                    }
                }
            }
            .background(Color(nsColor: Theme.background))
        }
        .frame(maxWidth: .infinity)
    }

    private func counterpart(_ token: MatchToken) -> MatchToken? {
        guard let pair = token.p, pair >= 0 else { return nil }
        return other.lines.lazy.flatMap(\.tokens).first { $0.p == pair }
    }

    @ViewBuilder private func tokenView(_ token: MatchToken) -> some View {
        let unmatched = token.p == -1
        let marked = token.p != nil && token.p != -1 && token.p == picked
        Text(token.t)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color(nsColor: Theme.color(forSyntax: token.s)))
            .background(marked ? Color.accentColor.opacity(0.45)
                        : unmatched ? (isLeft ? Color.red : Color.green).opacity(0.28) : Color.clear)
            .onTapGesture { if let pair = token.p, pair >= 0 { picked = pair } else { picked = nil } }
            .contextMenu {
                if isLeft, let theirs = counterpart(token) {
                    if token.k == "var" || token.target != nil, theirs.t != token.t {
                        Button(tr("Aplicar el nombre «%@»", theirs.t)) { apply(token, theirs, "name") }
                    }
                    if token.k == "var" || token.k == "global", let type = theirs.ty, type != token.ty {
                        Button(tr("Aplicar el tipo «%@»", type)) { apply(token, theirs, "type") }
                    }
                }
                Button(tr("Copiar")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token.t, forType: .string)
                }
            }
    }
}

/// Line-level diff (longest common subsequence via CollectionDifference).
struct DiffLines {
    var leftOnly = Set<Int>()
    var rightOnly = Set<Int>()

    init(_ a: [String], _ b: [String]) {
        guard !a.isEmpty, !b.isEmpty else { return }
        let norm: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        for change in b.map(norm).difference(from: a.map(norm)) {
            switch change {
            case .remove(let offset, _, _): leftOnly.insert(offset)
            case .insert(let offset, _, _): rightOnly.insert(offset)
            }
        }
    }
}
