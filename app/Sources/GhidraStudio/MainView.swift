import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
        } detail: {
            DockedDetail { DetailView() }
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
        .sheet(isPresented: $model.showFunctionEditor) { FunctionEditorSheet() }
        .sheet(isPresented: $model.showDecompilerOptions) { DecompilerOptionsSheet() }
        .sheet(item: $model.disassembleRequest) { DisassembleSheet(start: $0.start, end: $0.end) }
        .sheet(item: $model.unionRequest) { UnionFieldSheet(function: $0.function, token: $0.token) }
        .onChange(of: model.snapshotRequest) { _, spec in
            guard let spec else { return }
            openWindow(id: "snapshot", value: spec)
            model.snapshotRequest = nil
        }
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
                    case .segments:
                        segmentsSection
                        programTreeSection
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
                    Menu(tr("Marcas")) {
                        Button((seg.volatile == true ? "✓ " : "") + tr("Volátil")) {
                            model.memoryFlag(seg.name, "volatile", seg.volatile == true ? "false" : "true")
                        }
                        Button((seg.artificial == true ? "✓ " : "") + tr("Artificial")) {
                            model.memoryFlag(seg.name, "artificial", seg.artificial == true ? "false" : "true")
                        }
                        Button(seg.initialized ? tr("Quitar los bytes (sin inicializar)") : tr("Inicializar con ceros")) {
                            model.memoryFlag(seg.name, "initialized", seg.initialized ? "false" : "true")
                        }
                    }
                    Button(tr("Comentario del bloque…")) { model.requestBlockComment(seg) }
                    if seg.overlay == true {
                        Button(tr("Renombrar el espacio overlay…")) { model.requestRenameOverlay(seg) }
                    }
                    Button(tr("Añadir bloque…")) { model.showAddBlock = true }
                    Button(tr("Dividir en…")) {
                        model.editRequest = EditRequest(kind: .splitBlock(name: seg.name), address: seg.start,
                                                        title: tr("Dividir bloque"), prompt: tr("Dirección donde empieza el segundo bloque"),
                                                        initialText: seg.start)
                    }
                    Button(tr("Expandir hasta…")) { model.requestExpandBlock(name: seg.name, start: seg.start) }
                    Button(tr("Mover a…")) {
                        model.editRequest = EditRequest(kind: .moveBlock(name: seg.name), address: seg.start,
                                                        title: tr("Mover bloque"), prompt: tr("Nueva dirección inicial"),
                                                        initialText: seg.start)
                    }
                    if let next = model.segments.drop(while: { $0.id != seg.id }).dropFirst().first {
                        Button(tr("Unir con «%@»", "\(next.name)")) {
                            model.memoryAction("joinBlocks", ["name": seg.name, "other": next.name])
                        }
                    }
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

    private func flattenTree(_ groups: [TreeGroup], depth: Int = 0) -> [(TreeGroup, Int)] {
        groups.flatMap { [($0, depth)] + flattenTree($0.children, depth: depth + 1) }
    }

    private func setPerms(_ seg: SegmentItem, r: Bool, w: Bool, x: Bool) {
        model.memoryAction("setBlockPerms", ["name": seg.name, "read": r, "write": w, "execute": x])
    }

    @ViewBuilder private var programTreeSection: some View {
        if !model.programTree.isEmpty {
            Section(tr("Árbol del programa")) {
                ForEach(flattenTree(model.programTree), id: \.0.id) { group, depth in
                    HStack(spacing: 6) {
                        Image(systemName: group.module ? "folder" : "doc.text")
                            .foregroundStyle(group.module ? Color.accentColor : Color.secondary)
                        Text(group.name).lineLimit(1)
                        Spacer()
                        if let start = group.start {
                            Text(start).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, CGFloat(depth) * 12)
                    .contentShape(Rectangle())
                    .onTapGesture { if let start = group.start { model.go(start) } }
                }
            }
        }
    }

    @ViewBuilder private var bookmarksSection: some View {
        let items = model.bookmarks.filter { !$0.isBreakpoint && (matches($0.comment) || matches($0.category) || matches($0.address)) }
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
            HStack(spacing: 0) {
                ZStack {
                    Color(nsColor: Theme.background)
                    content
                }
                .id(model.themeRevision)
                if let split = model.splitMode, let session = model.activeSession, let address = model.current?.address {
                    Divider()
                    // a second view that follows the main one (listing next to the decompiler, or the reverse)
                    SnapshotView(spec: SnapshotSpec(session: session, address: address, mode: split), follows: true, embedded: true)
                        .id("\(session)|\(split)|\(model.themeRevision)")
                        .frame(minWidth: 320, idealWidth: 520)
                }
                if model.listingOptions.showOverview, model.viewMode != .graph, model.document != nil,
                   let overview = model.overview {
                    OverviewBar(overview: overview)
                    if model.listingOptions.showEntropyBar, !model.entropyBar.isEmpty {
                        EntropyBar(values: model.entropyBar, starts: overview.starts)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let analysis = model.analysis {
                    AnalysisPill(status: analysis) { model.cancelAnalysis() }
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: model.analysis == nil)
            if let selection = model.programSelection {
                Divider()
                SelectionBar(selection: selection)
            }
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
                sliceTokens: model.viewMode == .decompiler ? model.sliceTokens : [],
                selection: model.programSelection,
                breakpoints: model.breakpointMap,
                pcAddress: model.debugPC,
                onToggleBreakpoint: model.viewMode == .hex ? nil : { model.toggleBreakpoint(address: $0) },
                highlight: model.highlight,
                colors: model.viewMode.isListingLike ? model.colorRanges : [],
                secondary: model.viewMode == .decompiler ? model.secondaryHighlights : [:],
                cross: model.crossHighlight,
                hoverProvider: model.listingOptions.hoverPopups ? { await model.preview($0) } : nil,
                wordHoverProvider: model.debugger.hasState ? { await model.debugHover($0) } : nil,
                onNavigate: { target in
                    if target.hasPrefix(DocumentBuilder.foldPrefix) {
                        model.toggleFold(String(target.dropFirst(DocumentBuilder.foldPrefix.count)))
                    } else {
                        model.go(target)
                    }
                },
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
            if ctx.canSplit, let token = ctx.tokenID {
                a.append(.init(title: tr("Dividir como variable nueva…"), symbol: "arrow.triangle.branch") {
                    model.requestSplitVariable(token: token, name: v)
                })
            }
            a.append(.init(title: tr("Crear estructura automáticamente para «%@»", "\(v)"), symbol: "square.grid.3x1.below.line.grid.1x2") {
                model.autoStructure(v)
            })
            a.append(sep)
        }
        if ctx.isUnionField, let token = ctx.tokenID, let fn = model.current?.function {
            a.append(.init(title: tr("Forzar campo de unión…"), symbol: "square.on.square.dashed") {
                model.unionRequest = UnionRequest(function: fn, token: token)
            })
        }
        if let field = ctx.field {
            a.append(.init(title: tr("Renombrar campo «%@»…  (L)", "\(ctx.word ?? "")"), symbol: "pencil") {
                model.requestRenameField(field, currentName: ctx.word)
            })
            a.append(sep)
        }
        if model.viewMode == .decompiler, let token = ctx.tokenID, ctx.variable != nil || ctx.target != nil {
            a.append(.init(title: tr("Resaltar de dónde viene (slice hacia atrás)"), symbol: "arrow.up.backward") {
                model.slice(token, forward: false)
            })
            a.append(.init(title: tr("Resaltar a dónde va (slice hacia delante)"), symbol: "arrow.down.forward") {
                model.slice(token, forward: true)
            })
            if !model.sliceTokens.isEmpty {
                a.append(.init(title: tr("Quitar resaltado"), symbol: "xmark.circle") { model.sliceTokens = [] })
            }
            a.append(sep)
        }
        if model.viewMode == .decompiler {
            if let token = ctx.tokenID {
                a.append(.init(title: tr("Convertir constante…"), symbol: "number") { model.requestConvertConstant(token) })
                a.append(.init(title: tr("Asignar o quitar equate…"), symbol: "number.circle") { model.requestEquateToken(token) })
                a.append(.init(title: tr("Editar el tipo de dato"), symbol: "tablecells") { model.editTypeOfToken(token) })
                a.append(.init(title: tr("Buscar usos del tipo"), symbol: "magnifyingglass") { model.usesOfTokenType(token) })
                a.append(.init(title: tr("Quitar etiqueta"), symbol: "tag.slash") { model.removeLabelOfToken(token) })
            }
            if let field = ctx.field {
                a.append(.init(title: tr("Cambiar tipo del campo «%@»…", "\(ctx.word ?? "")"), symbol: "textformat") {
                    model.requestRetypeField(field)
                })
            }
            if let v = ctx.variable {
                a.append(.init(title: tr("Ajustar offset del puntero «%@»…", v), symbol: "arrow.left.and.right") {
                    model.requestAdjustPointer(v)
                })
                a.append(.init(title: model.taintSources.contains(v) ? tr("Taint: «%@» deja de ser fuente", v) : tr("Taint: marcar «%@» como fuente", v),
                               symbol: "drop") { model.toggleTaint(v, source: true) })
                a.append(.init(title: model.taintSinks.contains(v) ? tr("Taint: «%@» deja de ser sumidero", v) : tr("Taint: marcar «%@» como sumidero", v),
                               symbol: "drop.fill") { model.toggleTaint(v, source: false) })
            } else if ctx.callSite != nil, let name = ctx.targetText {
                a.append(.init(title: model.taintSinks.contains(name) ? tr("Taint: «%@» deja de ser sumidero", name) : tr("Taint: marcar «%@» como sumidero", name),
                               symbol: "drop.fill") { model.toggleTaint(name, source: false) })
            }
            if !model.taintSources.isEmpty {
                a.append(.init(title: tr("Taint: ejecutar la consulta"), symbol: "play") { model.runTaint() })
                a.append(.init(title: tr("Taint: borrar marcas"), symbol: "xmark.circle") { model.clearTaint() })
            }
            if let word = ctx.word ?? ctx.variable {
                a.append(.init(title: model.secondaryHighlights[word] == nil ? tr("Resaltado secundario de «%@»", word)
                               : tr("Quitar el resaltado secundario de «%@»", word), symbol: "highlighter") {
                    model.toggleSecondary(word)
                })
            }
            if !model.secondaryHighlights.isEmpty {
                a.append(.init(title: tr("Quitar todos los resaltados secundarios"), symbol: "xmark.circle") {
                    model.secondaryHighlights = [:]
                })
            }
            a.append(.init(title: tr("Cambiar tipo de retorno…"), symbol: "arrow.uturn.left") { model.requestRetypeReturn() })
            a.append(.init(title: tr("Exportar esta función a C…"), symbol: "square.and.arrow.up") { model.exportFunctionC() })
            a.append(.init(title: tr("Depurar la descompilación de esta función…"), symbol: "ant") { model.debugDecompile() })
            a.append(sep)
        }
        if let call = ctx.callSite {
            a.append(.init(title: tr("Forzar firma en esta llamada…"), symbol: "function") {
                model.requestOverrideSignature(callSite: call, name: ctx.targetText)
            })
        }
        if let target = ctx.target {
            let name = ctx.targetText ?? target
            if model.viewMode == .decompiler, ctx.callSite == nil, ctx.variable == nil,
               !model.functions.contains(where: { $0.address == target }) {
                a.append(.init(title: tr("Cambiar tipo del global «%@»…", "\(name)"), symbol: "textformat") {
                    model.requestRetypeGlobal(address: target, name: name)
                })
            }
            a.append(.init(title: tr("Ir a %@", "\(name)"), symbol: "arrow.right.circle") { model.go(target) })
            a.append(.init(title: tr("Renombrar «%@»…", "\(name)"), symbol: "pencil") {
                model.requestRename(address: target, currentName: name)
            })
            a.append(.init(title: tr("Copiar dirección %@", "\(target)"), symbol: "number") { model.copyToPasteboard(target) })
            a.append(sep)
        }
        if model.viewMode == .decompiler, model.functionDetails != nil {
            a.append(.init(title: tr("Editar función (convención, pila, etiquetas)…"), symbol: "slider.horizontal.3") {
                model.showFunctionEditor = true
            })
            a.append(.init(title: tr("Editar firma de la función…"), symbol: "function") { model.requestSignature() })
            a.append(.init(title: tr("Comentario de la función…"), symbol: "text.bubble") { model.requestFunctionComment() })
        }
        guard let line = ctx.lineAddress else { return a }
        if model.viewMode.isListingLike, let start = ctx.selectionStart, let end = ctx.selectionEnd, start != end {
            a.append(.init(title: tr("Desensamblar la selección (%@ – %@)", "\(start)", "\(end)"), symbol: "cpu") {
                model.rangeAction("disassembleRange", start: start, end: end)
            })
            a.append(.init(title: tr("Borrar código/datos de la selección"), symbol: "eraser") {
                model.rangeAction("clearRange", start: start, end: end)
            })
            a.append(.init(title: tr("Crear estructura desde la selección…"), symbol: "square.grid.3x1.below.line.grid.1x2") {
                model.requestStructFromRange(start: start, end: end)
            })
            a.append(.init(title: tr("Definir cadena en la selección"), symbol: "textformat.abc") {
                model.defineString(address: start, end: end)
            })
            a.append(.init(title: tr("Fijar registro en la selección…"), symbol: "memorychip") {
                model.requestSetRegister(start: start, end: end)
            })
            a.append(sep)
        }
        if model.viewMode.isListingLike || model.viewMode == .hex {
            if model.viewMode.isListingLike {
                a.append(.init(title: tr("Desensamblar  (D)"), symbol: "cpu") {
                    model.perform("disassemble", address: line, namesChanged: false)
                })
                a.append(.init(title: tr("Desensamblar con opciones…"), symbol: "cpu") {
                    model.requestDisassembleOptions(start: ctx.selectionStart ?? line, end: ctx.selectionEnd)
                })
                a.append(.init(title: tr("Crear función aquí…  (F)"), symbol: "f.cursive") { model.requestCreateFunction(address: line) })
                a.append(.init(title: tr("Definir dato…  (T)"), symbol: "tablecells") { model.requestCreateData(address: line) })
                a.append(.init(title: tr("Borrar código/dato  (C)"), symbol: "eraser") {
                    model.perform("clear", address: line, namesChanged: false)
                })
                a.append(sep)
                a.append(.init(title: tr("Ensamblar instrucción…"), symbol: "hammer") { model.requestAssemble(address: line) })
                a.append(.init(title: tr("Ensamblador con comodines…"), symbol: "asterisk.circle") {
                    model.selectLine(line)
                    model.showTools("wildAsm")
                })
                a.append(.init(title: tr("Nombre para constante (equate)…"), symbol: "number.circle") { model.requestEquate(address: line) })
                a.append(.init(title: tr("Añadir referencia…"), symbol: "arrow.turn.down.right") { model.requestAddReference(address: line) })
                a.append(.init(title: tr("Crear array…"), symbol: "square.grid.3x3") { model.requestArray(address: line) })
                a.append(.init(title: tr("Definir cadena aquí"), symbol: "textformat.abc") { model.defineString(address: line, end: nil) })
                a.append(.init(title: tr("Fijar valor de registro (p. ej. modo Thumb)…"), symbol: "memorychip") {
                    model.requestSetRegister(start: line, end: nil)
                })
                a.append(.init(title: tr("Abrir o cerrar la estructura o el array"), symbol: "chevron.down.square") {
                    model.toggleData(line)
                })
                a.append(.init(title: tr("Editar el campo de la estructura…"), symbol: "rectangle.and.pencil.and.ellipsis") {
                    model.requestEditField(address: line)
                })
                if let last = model.recentTypes.first {
                    a.append(.init(title: tr("Aplicar el tipo %@  (Y)", last), symbol: "clock.arrow.circlepath") {
                        model.applyType(last, address: line)
                    })
                }
                a.append(.init(title: tr("Plegar o desplegar la función"), symbol: "chevron.right.square") {
                    model.foldCurrentFunction()
                })
                a.append(.init(title: tr("Referencias de esta línea…"), symbol: "arrow.turn.down.right") {
                    model.selectLine(line)
                    model.showTools("references")
                })
                a.append(.init(title: tr("Etiquetas e historial…"), symbol: "tag") {
                    model.selectLine(line)
                    model.showTools("labels")
                })
                a.append(.init(title: tr("Información de la instrucción…"), symbol: "info.circle") {
                    model.selectLine(line)
                    model.showTools("instruction")
                })
                a.append(.init(title: tr("Ajustes del dato…"), symbol: "slider.horizontal.3") {
                    model.selectLine(line)
                    model.showTools("data")
                })
                a.append(.init(title: tr("Borrar con opciones…"), symbol: "eraser.line.dashed") { model.requestClearWithOptions() })
                for (title, format) in [("hexadecimal", "hex"), ("decimal", "decimal"), (tr("binario"), "binary"), (tr("carácter"), "char")] {
                    a.append(.init(title: tr("Mostrar el dato en %@", "\(title)"), symbol: "number") { model.setDataFormat(format, address: line) })
                }
            }
            a.append(.init(title: tr("Parchear bytes…"), symbol: "bandage") { model.requestPatch(address: line) })
            a.append(.init(title: tr("Escribir texto…"), symbol: "character.cursor.ibeam") { model.requestPatchText(address: line) })
            a.append(.init(title: tr("Escribir entero…"), symbol: "number") { model.requestPatchInt(address: line) })
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
        if model.viewMode != .hex {
            if let enabled = model.breakpointMap[line] {
                a.append(.init(title: tr("Quitar breakpoint  (K)"), symbol: "circle.slash") {
                    model.setBreakpoint(address: line, state: "none")
                })
                a.append(.init(title: enabled ? tr("Desactivar breakpoint") : tr("Activar breakpoint"), symbol: "circle.dotted") {
                    model.setBreakpoint(address: line, state: enabled ? "disabled" : "enabled")
                })
            } else {
                a.append(.init(title: tr("Poner breakpoint  (K)"), symbol: "circle.fill") {
                    model.setBreakpoint(address: line, state: "enabled")
                })
            }
            if model.debugger.isStopped {
                a.append(.init(title: tr("Ejecutar hasta aquí"), symbol: "arrow.right.to.line") {
                    model.debugger.run(toStatic: line)
                })
            }
            a.append(sep)
        }
        if let start = ctx.selectionStart, let end = ctx.selectionEnd, start != end {
            a.append(.init(title: tr("Seleccionar estas líneas"), symbol: "rectangle.dashed") {
                model.selectLines(start: start, end: end)
            })
        }
        a.append(.init(title: tr("Seleccionar la función"), symbol: "rectangle.dashed") { model.select("function") })
        a.append(.init(title: tr("Seleccionar todo el flujo desde aquí"), symbol: "arrow.down.right") { model.select("flowFrom") })
        a.append(.init(title: tr("Seleccionar todo el flujo hasta aquí"), symbol: "arrow.up.left") { model.select("flowTo") })
        if model.programSelection != nil {
            a.append(.init(title: tr("Quitar la selección"), symbol: "xmark.circle") { model.clearProgramSelection() })
        }
        a.append(.init(title: tr("Abrir en una ventana nueva"), symbol: "macwindow.badge.plus") {
            model.snapshotRequest = SnapshotSpec(session: model.activeSession ?? "", address: line,
                                                 mode: model.viewMode == .decompiler ? "decompiler" : "listing")
        })
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
