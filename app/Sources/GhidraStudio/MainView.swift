import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
        } detail: {
            DetailView()
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 310, max: 460)
        }
        .navigationTitle(model.program?.name ?? "Ghidra Studio")
        .navigationSubtitle(model.project?.name.map { "\($0) · \(model.currentTitle)" } ?? model.currentTitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Label(tr("Atrás"), systemImage: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .help(tr("Atrás (⌘[)"))
                Button { model.goForward() } label: { Label(tr("Adelante"), systemImage: "chevron.forward") }
                    .disabled(!model.canGoForward)
                    .help(tr("Adelante (⌘])"))
            }
            ToolbarItem(placement: .principal) {
                Picker(tr("Vista"), selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showQuickOpen = true } label: {
                    Label(tr("Abrir rápidamente"), systemImage: "magnifyingglass")
                }
                .help(tr("Buscar función, símbolo o dirección (⇧⌘O)"))
                Button { model.performUndo() } label: { Label(tr("Deshacer"), systemImage: "arrow.uturn.backward") }
                    .disabled(model.undo?.canUndo != true)
                    .help(model.undo?.undoName.map { tr("Deshacer «%@»", "\($0)") } ?? tr("Deshacer"))
                Button { model.save() } label: {
                    Label(tr("Guardar"), systemImage: model.isDirty ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                }
                .disabled(!model.isDirty)
                .help(tr("Guardar cambios (⌘S)"))
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(tr("Mostrar u ocultar el inspector (⌥⌘0)"))
            }
        }
        .background(WindowDirtyMarker(isDirty: model.isDirty))
        .sheet(isPresented: $model.showQuickOpen) { QuickOpenView() }
        .sheet(isPresented: $model.showAnalysisOptions) { AnalysisOptionsSheet() }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showAddBlock) { AddBlockSheet() }
    }
}

/// Shows the "unsaved changes" dot in the window's close button.
struct WindowDirtyMarker: NSViewRepresentable {
    let isDirty: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.isDocumentEdited = isDirty }
    }
}

// MARK: - Tabs

struct ProgramTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    let active = tab.id == model.activeSession
                    HStack(spacing: 6) {
                        if tab.analysis != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(tab.name).font(.callout.weight(active ? .semibold : .regular)).lineLimit(1)
                        if active && model.isDirty {
                            Circle().fill(.secondary).frame(width: 6, height: 6)
                        }
                        Button { model.closeTab(tab.id) } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(tr("Cerrar programa"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(active ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { model.activate(tab.id) }
                    .help(tab.id)
                }
                Button { model.presentOpenPanel() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .help(tr("Importar otro binario (⌘I)"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker(tr("Sección"), selection: $model.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.icon)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if model.sidebarTab == .project {
                ProjectTreeView()
            } else if model.sidebarTab == .symbols {
                SymbolTreeView()
            } else {
                List(selection: $model.sidebarSelection) {
                    switch model.sidebarTab {
                    case .functions: functionsSection
                    case .symbols: EmptyView()
                    case .imports: importsSection
                    case .exports: exportsSection
                    case .strings: stringsSection
                    case .segments: segmentsSection
                    case .bookmarks: bookmarksSection
                    case .project: EmptyView()
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $model.filter, placement: .sidebar,
                            prompt: tr("Filtrar %@", "\(model.sidebarTab.title.lowercased())"))
            }
        }
        .onChange(of: model.sidebarSelection) { _, id in
            guard let id, let address = address(for: id) else { return }
            model.go(address)
        }
        .onChange(of: model.sidebarTab) { _, _ in
            model.sidebarSelection = nil
        }
    }

    private func matches(_ s: String) -> Bool {
        model.filter.isEmpty || s.localizedCaseInsensitiveContains(model.filter)
    }

    private func address(for id: String) -> String? {
        switch model.sidebarTab {
        case .functions: id
        case .imports: model.imports.first { $0.id == id }?.address
        case .exports: model.exports.first { $0.id == id }?.address
        case .strings: id
        case .segments: model.segments.first { $0.id == id }?.start
        case .bookmarks: model.bookmarks.first { $0.id == id }?.address
        case .project, .symbols: nil
        }
    }

    @ViewBuilder private var functionsSection: some View {
        let items = model.functions.filter { matches($0.name) || matches($0.address) }
        Section(tr("%@ funciones", "\(items.count)")) {
            ForEach(items) { f in
                HStack(spacing: 8) {
                    Image(systemName: f.thunk ? "arrow.turn.down.right" : "f.cursive")
                        .foregroundStyle(f.thunk ? Color.secondary : Color.purple)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        Text(f.address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(f.id)
                .help(f.signature)
                .contextMenu {
                    Button(tr("Renombrar…")) { model.requestRename(address: f.address, currentName: f.name) }
                    Button(tr("Editar firma…")) { model.go(f.address); model.requestSignature(address: f.address) }
                    Button(tr("Copiar dirección")) { model.copyToPasteboard(f.address) }
                    Divider()
                    Button(tr("Borrar función"), role: .destructive) { model.perform("deleteFunction", address: f.address) }
                }
            }
        }
    }

    @ViewBuilder private var importsSection: some View {
        let items = model.imports.filter { matches($0.name) || matches($0.library) }
        let libraries = Dictionary(grouping: items, by: \.library).sorted { $0.key < $1.key }
        ForEach(libraries, id: \.key) { library, symbols in
            Section(library) {
                ForEach(symbols) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(item.address == nil ? .secondary : .primary)
                    .tag(item.id)
                }
            }
        }
    }

    @ViewBuilder private var exportsSection: some View {
        let items = model.exports.filter { matches($0.name) || matches($0.address) }
        Section(tr("%@ exportaciones", "\(items.count)")) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isFunction ? "f.cursive" : "tag")
                        .foregroundStyle(item.isFunction ? Color.purple : Color.blue)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(item.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
            }
        }
    }

    @ViewBuilder private var stringsSection: some View {
        let items = model.strings.filter { matches($0.value) || matches($0.address) }
        Section(tr("%@ cadenas", "\(items.count)")) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.value)
                        .font(.callout.monospaced())
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.address).font(.caption.monospaced())
                        if item.xrefs > 0 {
                            Text(tr("%@ ref%@", "\(item.xrefs)", "\(item.xrefs == 1 ? "" : "s")"))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
                .tag(item.id)
            }
        }
    }

    @ViewBuilder private var segmentsSection: some View {
        let items = model.segments.filter { matches($0.name) }
        Section(tr("%@ segmentos", "\(items.count)")) {
            ForEach(items) { seg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(seg.name).font(.body.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(seg.perms)
                            .font(.caption.monospaced().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(seg.perms.contains("x") ? Color.red.opacity(0.18) : Color.secondary.opacity(0.15),
                                        in: Capsule())
                    }
                    Text("\(seg.start) – \(seg.end)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: seg.size, countStyle: .memory))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .tag(seg.id)
                .contextMenu {
                    Button(tr("Renombrar…")) {
                        model.editRequest = EditRequest(kind: .renameBlock(name: seg.name), address: seg.start,
                                                        title: tr("Renombrar bloque"), prompt: tr("Nuevo nombre"),
                                                        initialText: seg.name)
                    }
                    Menu(tr("Permisos")) {
                        let r = seg.perms.contains("r"), w = seg.perms.contains("w"), x = seg.perms.contains("x")
                        Button((r ? "✓ " : "") + tr("Lectura")) { setPerms(seg, r: !r, w: w, x: x) }
                        Button((w ? "✓ " : "") + tr("Escritura")) { setPerms(seg, r: r, w: !w, x: x) }
                        Button((x ? "✓ " : "") + tr("Ejecución")) { setPerms(seg, r: r, w: w, x: !x) }
                    }
                    Button(tr("Añadir bloque…")) { model.showAddBlock = true }
                    Divider()
                    Button(tr("Borrar bloque"), role: .destructive) {
                        if model.confirm(tr("¿Borrar el bloque «%@»?", "\(seg.name)"), tr("Se quitará su memoria y lo que contenga."),
                                         action: tr("Borrar")) {
                            model.memoryAction("deleteBlock", ["name": seg.name])
                        }
                    }
                }
            }
        }
    }

    private func setPerms(_ seg: SegmentItem, r: Bool, w: Bool, x: Bool) {
        model.memoryAction("setBlockPerms", ["name": seg.name, "read": r, "write": w, "execute": x])
    }

    @ViewBuilder private var bookmarksSection: some View {
        let items = model.bookmarks.filter { matches($0.comment) || matches($0.category) || matches($0.address) }
        Section(tr("%@ marcadores", "\(items.count)")) {
            if items.isEmpty {
                Text(tr("Pulsa B en el código para añadir un marcador"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { b in
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(b.type == "Note" ? Color.orange : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.comment.isEmpty ? b.category : b.comment).lineLimit(2)
                        Text("\(b.address) · \(b.category)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .tag(b.id)
                .contextMenu {
                    Button(tr("Quitar marcador"), role: .destructive) {
                        model.perform("deleteBookmark", address: b.address, namesChanged: false)
                    }
                }
            }
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.tabs.count > 0 {
                ProgramTabBar()
                Divider()
            }
            header
            Divider()
            ZStack {
                Color(nsColor: Theme.background)
                content
            }
            .overlay(alignment: .bottom) {
                if let analysis = model.analysis {
                    AnalysisPill(status: analysis) { model.cancelAnalysis() }
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: model.analysis == nil)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.viewMode.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSignature ?? model.currentTitle)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let address = model.current?.address {
                        Text(address).font(.caption.monospaced())
                    }
                    if let program = model.program {
                        Text("·")
                        Text("\(program.processor) \(program.pointerSize)-bit \(program.endian == "Big" ? "BE" : "LE")")
                            .font(.caption)
                    }
                    if model.viewMode == .hex, let block = model.hexDump?.block {
                        Text("·")
                        Text(block).font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isContentLoading {
                ProgressView().controlSize(.small)
            }
            if model.viewMode == .hex {
                ControlGroup {
                    Button { model.hexPage(-4096) } label: { Image(systemName: "chevron.up") }
                        .help(tr("Página anterior"))
                    Button { model.hexPage(4096) } label: { Image(systemName: "chevron.down") }
                        .help(tr("Página siguiente"))
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if let error = model.contentError {
            ContentUnavailableView {
                Label(model.viewMode == .decompiler || model.viewMode == .graph ? tr("Sin función") : tr("No disponible"),
                      systemImage: model.viewMode.icon)
            } description: {
                Text(error)
            } actions: {
                if model.viewMode == .decompiler || model.viewMode == .graph {
                    Button(tr("Ver en el listado")) { model.viewMode = .program }
                    Button(tr("Crear función aquí")) { model.requestCreateFunction(address: model.current?.address) }
                }
            }
        } else if model.viewMode == .graph {
            if let graph = model.graph {
                FunctionGraphView(graph: graph)
            } else {
                ProgressView()
            }
        } else if let document = model.document {
            CodeTextView(
                document: document,
                highlightAddress: model.selectedAddress,
                scrollRequest: model.scrollRequest,
                onNavigate: { model.go($0) },
                onSelectLine: { model.selectLine($0) },
                onReachEdge: model.viewMode == .program ? { model.loadMoreFull(atTop: $0) } : nil,
                onKey: { key, ctx in model.handleKey(key, context: ctx) },
                menuActions: { ctx in menuActions(ctx) }
            )
        } else if model.current == nil {
            ContentUnavailableView(tr("Selecciona una función"), systemImage: "sidebar.left",
                                   description: Text(tr("Elige un elemento en la barra lateral o pulsa ⇧⌘O para buscar.")))
        } else {
            ProgressView()
        }
    }

    private func menuActions(_ ctx: CodeContext) -> [CodeMenuAction] {
        var a: [CodeMenuAction] = []
        let sep = CodeMenuAction(title: "-", symbol: "", action: {})
        if let v = ctx.variable {
            a.append(.init(title: tr("Renombrar variable «%@»…  (L)", "\(v)"), symbol: "pencil") { model.requestRenameVariable(v) })
            a.append(.init(title: tr("Cambiar tipo de «%@»…  (T)", "\(v)"), symbol: "textformat") { model.requestRetypeVariable(v) })
            a.append(.init(title: tr("Crear estructura automáticamente para «%@»", "\(v)"), symbol: "square.grid.3x1.below.line.grid.1x2") {
                model.autoStructure(v)
            })
            a.append(sep)
        }
        if let target = ctx.target {
            let name = ctx.targetText ?? target
            a.append(.init(title: tr("Ir a %@", "\(name)"), symbol: "arrow.right.circle") { model.go(target) })
            a.append(.init(title: tr("Renombrar «%@»…", "\(name)"), symbol: "pencil") {
                model.requestRename(address: target, currentName: name)
            })
            a.append(.init(title: tr("Copiar dirección %@", "\(target)"), symbol: "number") { model.copyToPasteboard(target) })
            a.append(sep)
        }
        if model.viewMode == .decompiler, model.functionDetails != nil {
            a.append(.init(title: tr("Editar firma de la función…"), symbol: "function") { model.requestSignature() })
            a.append(.init(title: tr("Comentario de la función…"), symbol: "text.bubble") { model.requestFunctionComment() })
        }
        guard let line = ctx.lineAddress else { return a }
        if model.viewMode.isListingLike || model.viewMode == .hex {
            if model.viewMode.isListingLike {
                a.append(.init(title: tr("Desensamblar  (D)"), symbol: "cpu") {
                    model.perform("disassemble", address: line, namesChanged: false)
                })
                a.append(.init(title: tr("Crear función aquí…  (F)"), symbol: "f.cursive") { model.requestCreateFunction(address: line) })
                a.append(.init(title: tr("Definir dato…  (T)"), symbol: "tablecells") { model.requestCreateData(address: line) })
                a.append(.init(title: tr("Borrar código/dato  (C)"), symbol: "eraser") {
                    model.perform("clear", address: line, namesChanged: false)
                })
                a.append(sep)
                a.append(.init(title: tr("Ensamblar instrucción…"), symbol: "hammer") { model.requestAssemble(address: line) })
                a.append(.init(title: tr("Nombre para constante (equate)…"), symbol: "number.circle") { model.requestEquate(address: line) })
                a.append(.init(title: tr("Añadir referencia…"), symbol: "arrow.turn.down.right") { model.requestAddReference(address: line) })
            }
            a.append(.init(title: tr("Parchear bytes…"), symbol: "bandage") { model.requestPatch(address: line) })
            a.append(sep)
        }
        a.append(.init(title: tr("Añadir etiqueta en %@…", "\(line)"), symbol: "tag") { model.requestLabel(address: line) })
        a.append(.init(title: tr("Comentario…  (;)"), symbol: "text.bubble") { model.requestComment(address: line) })
        a.append(.init(title: tr("Comentario previo…"), symbol: "text.line.first.and.arrowtriangle.forward") {
            model.requestComment(address: line, kind: "pre")
        })
        a.append(.init(title: tr("Comentario de cabecera…"), symbol: "rectangle.topthird.inset.filled") {
            model.requestComment(address: line, kind: "plate")
        })
        a.append(.init(title: tr("Añadir marcador…  (B)"), symbol: "bookmark") { model.requestBookmark(address: line) })
        a.append(sep)
        if ctx.target == nil {
            a.append(.init(title: tr("Copiar dirección %@", "\(line)"), symbol: "number") { model.copyToPasteboard(line) })
        }
        if model.viewMode != .program {
            a.append(.init(title: tr("Ver en el listado completo"), symbol: "doc.plaintext") {
                model.selectedAddress = line
                model.scrollRequest = ScrollRequest(address: line)
                model.go(line)
                model.viewMode = .program
            })
        }
        if model.viewMode != .hex {
            a.append(.init(title: tr("Ver en hex"), symbol: "number.square") {
                model.go(line)
                model.viewMode = .hex
            })
        }
        return a
    }
}

struct AnalysisPill: View {
    let status: AnalysisStatus
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let progress = status.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Analizando en segundo plano"))
                    .font(.callout.weight(.semibold))
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            if let progress = status.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(tr("Detener el análisis"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }
}
