import AppKit
import SwiftUI

// MARK: - Dock-aware window size

private struct DockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for a view shown inside a dock of the main window instead of its own window.
    var isDocked: Bool {
        get { self[DockedKey.self] }
        set { self[DockedKey.self] = newValue }
    }
}

private struct WindowMinSize: ViewModifier {
    @Environment(\.isDocked) private var docked
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        if docked {
            // a docked panel takes the size of its dock
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(minWidth: width, minHeight: height)
        }
    }
}

extension View {
    /// The minimum size of a window's content; it does not apply when the view is docked.
    func windowMinSize(_ width: CGFloat, _ height: CGFloat) -> some View {
        modifier(WindowMinSize(width: width, height: height))
    }
}

// MARK: - What can be docked

/// Where a panel is docked in the main window.
enum DockArea: String, Codable, CaseIterable, Identifiable {
    case left, right, bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: tr("A la izquierda")
        case .right: tr("A la derecha")
        case .bottom: tr("Abajo")
        }
    }

    var symbol: String {
        switch self {
        case .left: "sidebar.left"
        case .right: "sidebar.right"
        case .bottom: "rectangle.bottomthird.inset.filled"
        }
    }
}

/// A tool that can live in its own window or in a dock: a whole window, or one panel of the program tools.
struct DockPanel: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    /// The window to open when it is not docked, and for tool panels the panel to show in it.
    let window: String
    var tool: String? = nil

    static var windows: [DockPanel] {
        [
            DockPanel(id: "bytes", title: tr("Visor de bytes"), symbol: "number.square", window: "bytes"),
            DockPanel(id: "search", title: tr("Buscar en el programa"), symbol: "magnifyingglass", window: "search"),
            DockPanel(id: "tables", title: tr("Tablas"), symbol: "tablecells", window: "tables"),
            DockPanel(id: "calls", title: tr("Árbol de llamadas"), symbol: "arrow.triangle.branch", window: "calls"),
            DockPanel(id: "types", title: tr("Tipos de datos"), symbol: "square.grid.3x1.below.line.grid.1x2", window: "types"),
            DockPanel(id: "typemanager", title: tr("Gestor de tipos de datos"), symbol: "books.vertical", window: "typemanager"),
            DockPanel(id: "scripts", title: "Scripts", symbol: "scroll", window: "scripts"),
            DockPanel(id: "python", title: tr("Intérprete de Python"), symbol: "terminal", window: "python"),
            DockPanel(id: "graphs", title: tr("Grafos"), symbol: "point.3.connected.trianglepath.dotted", window: "graphs"),
            DockPanel(id: "emulator", title: tr("Emulador"), symbol: "cpu", window: "emulator"),
            DockPanel(id: "funccompare", title: tr("Comparar funciones"), symbol: "rectangle.split.2x1", window: "funccompare"),
            DockPanel(id: "compare", title: tr("Comparar programas"), symbol: "doc.on.doc", window: "compare"),
            DockPanel(id: "vt", title: "Version Tracking", symbol: "arrow.left.arrow.right", window: "vt"),
            DockPanel(id: "bsim", title: "BSim", symbol: "square.stack.3d.up", window: "bsim"),
            DockPanel(id: "fid", title: "Function ID", symbol: "touchid", window: "fid"),
            DockPanel(id: "server", title: tr("Ghidra Server y control de versiones"), symbol: "server.rack", window: "server"),
            DockPanel(id: "projecttools", title: tr("Herramientas del proyecto"), symbol: "folder.badge.gearshape", window: "projecttools"),
            DockPanel(id: "program", title: tr("Herramientas del programa"), symbol: "wrench.and.screwdriver", window: "program"),
        ]
    }

    static var tools: [DockPanel] {
        ToolPanel.all.map { DockPanel(id: "tool:" + $0.id, title: $0.title, symbol: $0.symbol, window: "program", tool: $0.id) }
    }

    static var all: [DockPanel] { windows + tools }

    static func find(_ id: String) -> DockPanel? { all.first { $0.id == id } }

    /// The panel's content, the same view its window shows.
    @ViewBuilder static func content(_ id: String) -> some View {
        switch id {
        case "bytes": ByteViewerView()
        case "search": SearchView()
        case "tables": TablesView()
        case "calls": CallTreeView()
        case "types": DataTypesView()
        case "typemanager": TypeManagerView()
        case "scripts": ScriptsView()
        case "python": PythonConsoleView()
        case "graphs": GraphsView()
        case "emulator": EmulatorView()
        case "funccompare": FunctionCompareView()
        case "compare": CompareView()
        case "vt": VersionTrackingView()
        case "bsim": BSimView()
        case "fid": FunctionIDView()
        case "server": ServerView()
        case "projecttools": ProjectToolsView()
        case "program": ProgramToolsView()
        default:
            if id.hasPrefix("tool:") {
                DockedToolPanel(panel: String(id.dropFirst(5)))
            } else {
                Text(id).foregroundStyle(.secondary)
            }
        }
    }
}

/// One panel of the program tools on its own, with what the tools window gives it (the no-program notice).
private struct DockedToolPanel: View {
    @Environment(AppModel.self) private var model
    let panel: String

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                ToolPanelContent(panel: panel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Layout

/// Which panels are docked where, the tab shown in each dock and the size of each dock.
struct DockLayout: Codable, Equatable {
    var tabs: [String: [String]] = [:]
    var selected: [String: String] = [:]
    var sizes: [String: Double] = ["left": 340, "right": 400, "bottom": 280]
    var collapsed: [String] = []
}

@MainActor
@Observable
final class DockStore {
    var layout: DockLayout {
        didSet {
            guard layout != oldValue else { return }
            if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "dockLayout") }
        }
    }
    /// The panel being dragged, while the drop zones are shown.
    var dragging: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: "dockLayout"),
           let saved = try? JSONDecoder().decode(DockLayout.self, from: data) {
            // panels of an older version that no longer exist are dropped
            var clean = saved
            for (area, ids) in saved.tabs { clean.tabs[area] = ids.filter { DockPanel.find($0) != nil } }
            layout = clean
        } else {
            layout = DockLayout()
        }
    }

    func tabs(_ area: DockArea) -> [String] { layout.tabs[area.rawValue] ?? [] }

    func area(of id: String) -> DockArea? {
        DockArea.allCases.first { tabs($0).contains(id) }
    }

    func isDocked(_ id: String) -> Bool { area(of: id) != nil }

    var isEmpty: Bool { DockArea.allCases.allSatisfy { tabs($0).isEmpty } }

    func selected(_ area: DockArea) -> String? {
        let ids = tabs(area)
        if let chosen = layout.selected[area.rawValue], ids.contains(chosen) { return chosen }
        return ids.first
    }

    func isCollapsed(_ area: DockArea) -> Bool { layout.collapsed.contains(area.rawValue) }

    func setCollapsed(_ area: DockArea, _ collapsed: Bool) {
        layout.collapsed.removeAll { $0 == area.rawValue }
        if collapsed { layout.collapsed.append(area.rawValue) }
    }

    func size(_ area: DockArea) -> CGFloat { CGFloat(layout.sizes[area.rawValue] ?? 320) }

    func setSize(_ area: DockArea, _ value: CGFloat) {
        layout.sizes[area.rawValue] = Double(max(160, min(value, area == .bottom ? 900 : 1100)))
    }

    /// Docks a panel (moving it if it was docked elsewhere), before another tab or at the end.
    func dock(_ id: String, to area: DockArea, before other: String? = nil) {
        guard DockPanel.find(id) != nil, id != other else { return }
        var next = layout
        for a in DockArea.allCases { next.tabs[a.rawValue]?.removeAll { $0 == id } }
        var ids = next.tabs[area.rawValue] ?? []
        if let other, let index = ids.firstIndex(of: other) { ids.insert(id, at: index) } else { ids.append(id) }
        next.tabs[area.rawValue] = ids
        next.selected[area.rawValue] = id
        next.collapsed.removeAll { $0 == area.rawValue }
        layout = next
        closeWindow(of: id)
    }

    func undock(_ id: String) {
        var next = layout
        for a in DockArea.allCases { next.tabs[a.rawValue]?.removeAll { $0 == id } }
        layout = next
    }

    func undockAll() {
        layout.tabs = [:]
    }

    func select(_ id: String) {
        guard let area = area(of: id) else { return }
        layout.selected[area.rawValue] = id
        setCollapsed(area, false)
    }

    /// Shows a docked panel instead of opening its window. False when it is not docked.
    func reveal(window: String, tool: String? = nil) -> Bool {
        if let tool, isDocked("tool:" + tool) {
            select("tool:" + tool)
            return true
        }
        if isDocked(window) {
            select(window)
            return true
        }
        return false
    }

    /// The scene id of the window in front, when it is one that can be docked.
    func frontWindowPanel() -> String? {
        guard let raw = NSApp.keyWindow?.identifier?.rawValue else { return nil }
        return DockPanel.windows.map(\.id).sorted { $0.count > $1.count }.first { raw.hasPrefix($0) }
    }

    /// A panel is in one place: docking it closes its window.
    private func closeWindow(of id: String) {
        guard DockPanel.windows.contains(where: { $0.id == id }) else { return }
        let longer = DockPanel.windows.map(\.id).filter { $0 != id && $0.hasPrefix(id) }
        for window in NSApp.windows {
            guard let raw = window.identifier?.rawValue, raw.hasPrefix(id), !longer.contains(where: { raw.hasPrefix($0) }) else { continue }
            window.close()
        }
    }
}

// MARK: - Views

/// The main view with its docks around it.
struct DockedDetail<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: () -> Content

    var body: some View {
        let dock = model.dock
        // the docks never ask the window for more room than it has: they are sized inside what there is
        GeometryReader { geo in
            let sides = (dock.tabs(.left).isEmpty ? 0 : 1) + (dock.tabs(.right).isEmpty ? 0 : 1)
            let widest = max(160, (geo.size.width - 320) / CGFloat(max(1, sides)))
            let tallest = max(120, geo.size.height - 220)
            HStack(spacing: 0) {
                if !dock.tabs(.left).isEmpty {
                    DockAreaView(area: .left, limit: widest)
                    DockHandle(area: .left)
                }
                VStack(spacing: 0) {
                    content()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                    if !dock.tabs(.bottom).isEmpty {
                        DockHandle(area: .bottom)
                        DockAreaView(area: .bottom, limit: tallest)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                if !dock.tabs(.right).isEmpty {
                    DockHandle(area: .right)
                    DockAreaView(area: .right, limit: widest)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .overlay {
            if dock.dragging != nil { DropZones() }
        }
        // forms asked for by a docked tool panel, when the tools window is not there to show them
        .sheet(item: model.dockedFormBinding) { request in FormSheet(request: request) }
    }
}

/// The edges of the main view, shown while a tab is dragged: dropping on one docks the panel there.
private struct DropZones: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // a click anywhere ends a drag that was abandoned
                Color.black.opacity(0.001).onTapGesture { model.dock.dragging = nil }
                zone(.left).frame(width: geo.size.width * 0.22).frame(maxWidth: .infinity, alignment: .leading)
                zone(.right).frame(width: geo.size.width * 0.22).frame(maxWidth: .infinity, alignment: .trailing)
                zone(.bottom).frame(width: geo.size.width * 0.5, height: geo.size.height * 0.28)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task {
            // a drag that ended outside any zone leaves nothing behind: the zones go when the button is released
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled, model.dock.dragging != nil {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    try? await Task.sleep(for: .milliseconds(300))      // let a drop that is being delivered finish
                    model.dock.dragging = nil
                    break
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func zone(_ area: DockArea) -> some View {
        DropZone(area: area)
    }
}

private struct DropZone: View {
    @Environment(AppModel.self) private var model
    let area: DockArea
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(targeted ? 0.35 : 0.12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay(Label(area.title, systemImage: area.symbol).font(.callout.weight(.medium)))
            .padding(10)
            .dropDestination(for: String.self) { items, _ in
                defer { model.dock.dragging = nil }
                guard let id = items.first, DockPanel.find(id) != nil else { return false }
                model.dock.dock(id, to: area)
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// The bar between a dock and the main view: drag it to resize the dock.
private struct DockHandle: View {
    @Environment(AppModel.self) private var model
    let area: DockArea
    @State private var start: CGFloat?

    var body: some View {
        let vertical = area != .bottom
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = start ?? model.dock.size(area)
                            if start == nil { start = base }
                            let delta: CGFloat
                            switch area {
                            case .left: delta = value.translation.width
                            case .right: delta = -value.translation.width
                            case .bottom: delta = -value.translation.height
                            }
                            model.dock.setSize(area, base + delta)
                        }
                        .onEnded { _ in start = nil })
            }
            .zIndex(1)
    }
}

/// One dock: the tabs of its panels and the panel that is selected.
struct DockAreaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let area: DockArea
    /// The most the dock may take of the window in its direction.
    var limit: CGFloat = .infinity

    var body: some View {
        let dock = model.dock
        let ids = dock.tabs(area)
        let collapsed = dock.isCollapsed(area)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(ids, id: \.self) { id in
                            if let panel = DockPanel.find(id) { tab(panel, selected: dock.selected(area) == id) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                Menu {
                    panelMenu
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(tr("Acoplar otro panel aquí"))
                Button { dock.setCollapsed(area, !collapsed) } label: {
                    Image(systemName: collapsed ? "chevron.up.chevron.down" : "minus")
                }
                .buttonStyle(.borderless)
                .help(collapsed ? tr("Mostrar el panel") : tr("Dejar solo las pestañas"))
                .padding(.trailing, 6)
            }
            .frame(height: 28)
            .background(.bar)
            .dropDestination(for: String.self) { items, _ in
                defer { dock.dragging = nil }
                guard let id = items.first, DockPanel.find(id) != nil else { return false }
                dock.dock(id, to: area)
                return true
            }
            if !collapsed, let selected = dock.selected(area) {
                Divider()
                DockPanel.content(selected)
                    .environment(\.isDocked, true)
                    .id(selected)
                    // a panel wider than its dock keeps its left edge in view
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        }
        .frame(width: area == .bottom ? nil : min(limit, collapsed ? 220 : dock.size(area)),
               height: area == .bottom ? (collapsed ? 28 : min(limit, dock.size(area))) : nil)
        .frame(maxHeight: area == .bottom ? nil : .infinity, alignment: .top)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var panelMenu: some View {
        Menu(tr("Ventanas")) {
            ForEach(DockPanel.windows) { panel in
                Button { model.dock.dock(panel.id, to: area) } label: { Label(panel.title, systemImage: panel.symbol) }
            }
        }
        Menu(tr("Herramientas del programa")) {
            ForEach(DockPanel.tools) { panel in
                Button { model.dock.dock(panel.id, to: area) } label: { Label(panel.title, systemImage: panel.symbol) }
            }
        }
    }

    private func tab(_ panel: DockPanel, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: panel.symbol).font(.caption)
            Text(panel.title).font(.callout).lineLimit(1)
            Button { model.dock.undock(panel.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .help(tr("Quitar del acoplamiento"))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.dock.select(panel.id) }
        .onDrag {
            model.dock.dragging = panel.id
            return NSItemProvider(object: panel.id as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            defer { model.dock.dragging = nil }
            guard let id = items.first, DockPanel.find(id) != nil else { return false }
            model.dock.dock(id, to: area, before: panel.id)
            return true
        }
        .contextMenu {
            ForEach(DockArea.allCases.filter { $0 != area }) { other in
                Button { model.dock.dock(panel.id, to: other) } label: { Label(tr("Mover: %@", other.title.lowercased()), systemImage: other.symbol) }
            }
            Button(tr("Abrir en su ventana")) {
                model.dock.undock(panel.id)
                if let tool = panel.tool { model.toolsPanel = tool }
                openWindow(id: panel.window)
            }
            Button(tr("Quitar del acoplamiento")) { model.dock.undock(panel.id) }
        }
    }
}

// MARK: - Menu

/// View ▸ Docked Panels: docks any window or tool panel, by menu (dragging the tabs also works).
struct DockCommands: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Menu(tr("Paneles acoplados")) {
            Menu(tr("Acoplar la ventana que está delante")) {
                ForEach(DockArea.allCases) { area in
                    Button(area.title) {
                        if let id = model.dock.frontWindowPanel() {
                            model.dock.dock(id, to: area)
                        } else {
                            model.errorMessage = tr("La ventana que está delante no se puede acoplar. Elige el panel en «Acoplar una ventana».")
                        }
                    }
                }
            }
            Menu(tr("Acoplar una ventana")) {
                ForEach(DockPanel.windows) { panel in areaMenu(panel) }
            }
            Menu(tr("Acoplar una herramienta del programa")) {
                ForEach(DockPanel.tools) { panel in areaMenu(panel) }
            }
            Divider()
            ForEach(DockArea.allCases) { area in
                let ids = model.dock.tabs(area)
                if !ids.isEmpty {
                    Button((model.dock.isCollapsed(area) ? tr("Mostrar el acoplamiento: %@", area.title.lowercased())
                            : tr("Plegar el acoplamiento: %@", area.title.lowercased()))) {
                        model.dock.setCollapsed(area, !model.dock.isCollapsed(area))
                    }
                }
            }
            Button(tr("Desacoplar todo")) { model.dock.undockAll() }.disabled(model.dock.isEmpty)
        }
    }

    private func areaMenu(_ panel: DockPanel) -> some View {
        Menu(panel.title) {
            ForEach(DockArea.allCases) { area in
                Button((model.dock.area(of: panel.id) == area ? "✓ " : "") + area.title) { model.dock.dock(panel.id, to: area) }
            }
            if model.dock.isDocked(panel.id) {
                Divider()
                Button(tr("Abrir en su ventana")) {
                    model.dock.undock(panel.id)
                    if let tool = panel.tool { model.toolsPanel = tool }
                    openWindow(id: panel.window)
                }
            }
        }
    }
}
