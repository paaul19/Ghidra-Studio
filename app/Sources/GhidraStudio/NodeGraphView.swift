import SwiftUI
import UniformTypeIdentifiers

/// Layered layout for call / reference graphs. Uses node levels when given, otherwise longest-path layering.
struct NodeGraphLayout {
    var rects: [String: CGRect] = [:]
    var edges: [(from: CGPoint, to: CGPoint, back: Bool, fromID: String, toID: String)] = []
    var size: CGSize = .zero

    static let nodeHeight: CGFloat = 46
    static let hGap: CGFloat = 26
    static let vGap: CGFloat = 70

    init(_ g: NodeGraphData) {
        let ids = g.nodes.map(\.id)
        guard !ids.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let n = ids.count
        var succ = Array(repeating: [Int](), count: n)
        var pred = Array(repeating: [Int](), count: n)
        for e in g.edges {
            guard let a = index[e.from], let b = index[e.to], a != b else { continue }
            succ[a].append(b)
            pred[b].append(a)
        }

        var layer = Array(repeating: 0, count: n)
        var back = Set<[Int]>()
        if g.nodes.allSatisfy({ $0.level != nil }) {
            let minLevel = g.nodes.compactMap(\.level).min() ?? 0
            for (i, node) in g.nodes.enumerated() { layer[i] = (node.level ?? 0) - minLevel }
            for a in 0..<n { for b in succ[a] where layer[b] <= layer[a] { back.insert([a, b]) } }
        } else {
            var state = Array(repeating: 0, count: n)
            var order: [Int] = []
            func dfs(_ u: Int) {
                state[u] = 1
                for v in succ[u] {
                    if state[v] == 1 { back.insert([u, v]) } else if state[v] == 0 { dfs(v) }
                }
                state[u] = 2
                order.append(u)
            }
            // Roots first (no predecessors), then whatever is left.
            for u in 0..<n where pred[u].isEmpty && state[u] == 0 { dfs(u) }
            for u in 0..<n where state[u] == 0 { dfs(u) }
            for u in order.reversed() {
                for v in succ[u] where !back.contains([u, v]) { layer[v] = max(layer[v], layer[u] + 1) }
            }
        }

        let layerCount = (layer.max() ?? 0) + 1
        var rows = Array(repeating: [Int](), count: layerCount)
        for u in 0..<n { rows[layer[u]].append(u) }
        var position = Array(repeating: 0.0, count: n)
        for l in 0..<layerCount {
            rows[l].sort { g.nodes[$0].label < g.nodes[$1].label }
            for (i, u) in rows[l].enumerated() { position[u] = Double(i) }
        }
        for pass in 0..<4 {
            let range: [Int] = pass % 2 == 0 ? Array(1..<max(1, layerCount)) : Array((0..<max(0, layerCount - 1)).reversed())
            for l in range {
                func bary(_ u: Int) -> Double {
                    let nb = pass % 2 == 0 ? pred[u] : succ[u]
                    let adj = nb.filter { abs(layer[$0] - l) == 1 }
                    return adj.isEmpty ? position[u] : adj.map { position[$0] }.reduce(0, +) / Double(adj.count)
                }
                rows[l].sort { bary($0) < bary($1) }
                for (i, u) in rows[l].enumerated() { position[u] = Double(i) }
            }
        }

        func width(_ node: GNode) -> CGFloat {
            CGFloat(min(max(node.label.count, node.detail.count), 36)) * 7.6 + 58
        }
        // Wide levels wrap into several visual rows so the graph stays readable.
        let perRow = max(6, Int(Double(n).squareRoot().rounded(.up)) + 2)
        var visualRows: [[Int]] = []
        for row in rows {
            var i = 0
            while i < row.count {
                visualRows.append(Array(row[i..<min(i + perRow, row.count)]))
                i += perRow
            }
            if row.isEmpty { visualRows.append([]) }
        }
        var y: CGFloat = 30
        var maxWidth: CGFloat = 0
        var rowWidths: [CGFloat] = []
        var raw: [Int: CGRect] = [:]
        rows = visualRows
        for row in rows {
            var x: CGFloat = 0
            for u in row {
                let w = width(g.nodes[u])
                raw[u] = CGRect(x: x, y: y, width: w, height: Self.nodeHeight)
                x += w + Self.hGap
            }
            let w = max(0, x - Self.hGap)
            rowWidths.append(w)
            maxWidth = max(maxWidth, w)
            y += Self.nodeHeight + Self.vGap
        }
        for (l, row) in rows.enumerated() {
            let offset = (maxWidth - rowWidths[l]) / 2 + 40
            for u in row { raw[u]?.origin.x += offset }
        }
        for (u, r) in raw { rects[ids[u]] = r }
        for a in 0..<n {
            for b in succ[a] {
                guard let ra = raw[a], let rb = raw[b] else { continue }
                let isBack = back.contains([a, b]) || rb.minY <= ra.minY
                edges.append((CGPoint(x: ra.midX, y: ra.maxY), CGPoint(x: rb.midX, y: rb.minY), isBack, ids[a], ids[b]))
            }
        }
        size = CGSize(width: maxWidth + 80, height: y + 20)
    }
}

struct NodeGraphView: View {
    let graph: NodeGraphData
    var centerID: String?
    var highlight: String = ""
    var onOpen: (GNode) -> Void
    var onRecenter: ((GNode) -> Void)?
    @State private var scale: CGFloat = 1
    @State private var selected: String?
    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        let layout = NodeGraphLayout(graph)
        let s = max(0.15, min(3, scale * pinch))
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in layout.edges {
                        let active = selected != nil && (e.fromID == selected || e.toID == selected)
                        var path = Path()
                        path.move(to: e.from)
                        if e.back {
                            path.addCurve(to: e.to, control1: CGPoint(x: e.from.x + 80, y: e.from.y + 60),
                                          control2: CGPoint(x: e.to.x + 80, y: e.to.y - 60))
                        } else {
                            let dy = max(25, (e.to.y - e.from.y) / 2)
                            path.addCurve(to: e.to, control1: CGPoint(x: e.from.x, y: e.from.y + dy),
                                          control2: CGPoint(x: e.to.x, y: e.to.y - dy))
                        }
                        let color: Color = active ? .accentColor : .secondary.opacity(selected == nil ? 0.6 : 0.25)
                        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: active ? 2.2 : 1.2,
                                                                                 dash: e.back ? [5, 4] : []))
                        var arrow = Path()
                        arrow.move(to: e.to)
                        arrow.addLine(to: CGPoint(x: e.to.x - 4.5, y: e.to.y - 8))
                        arrow.addLine(to: CGPoint(x: e.to.x + 4.5, y: e.to.y - 8))
                        arrow.closeSubpath()
                        ctx.fill(arrow, with: .color(color))
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                ForEach(graph.nodes) { node in
                    if let r = layout.rects[node.id] {
                        NodeBox(node: node, isCenter: node.id == centerID, isSelected: node.id == selected,
                                isMatch: !highlight.isEmpty && node.label.localizedCaseInsensitiveContains(highlight))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture(count: 2) {
                                if let onRecenter, node.kind != "external" { onRecenter(node) } else { onOpen(node) }
                            }
                            .onTapGesture { selected = node.id == selected ? nil : node.id }
                            .contextMenu {
                                if node.address != nil {
                                    Button(tr("Ir a %@", "\(node.label)")) { onOpen(node) }
                                }
                                if let onRecenter, node.kind != "external" {
                                    Button(tr("Centrar el grafo aquí")) { onRecenter(node) }
                                }
                            }
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: layout.size.width * s, height: layout.size.height * s, alignment: .topLeading)
        }
        .scrollPosition($position)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .onAppear { DispatchQueue.main.async { focus(layout, s) } }
        .onChange(of: graph.nodes.count) { _, _ in DispatchQueue.main.async { focus(layout, s) } }
        .onChange(of: centerID) { _, _ in DispatchQueue.main.async { focus(layout, s) } }
        .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { scale = max(0.15, min(3, scale * $0.magnification)) })
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Button {
                    scale = max(0.15, min(1, min(viewport.width / layout.size.width, viewport.height / layout.size.height)))
                    position.scrollTo(point: .zero)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(tr("Ajustar a la ventana"))
                Button { scale = max(0.15, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = 1 } label: { Text("\(Int(s * 100)) %").font(.caption.monospacedDigit()) }
                Button { scale = min(3, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.glass)
            .padding(14)
        }
    }
}

extension NodeGraphView {
    /// Centers the view on the center node (or the middle of the first row).
    fileprivate func focus(_ layout: NodeGraphLayout, _ s: CGFloat) {
        let rect = centerID.flatMap { layout.rects[$0] } ?? layout.rects.values.min { $0.minY < $1.minY }
        guard let rect else { return }
        position.scrollTo(point: CGPoint(x: max(0, rect.midX * s - viewport.width / 2),
                                         y: max(0, rect.midY * s - viewport.height / 2)))
    }
}

private struct NodeBox: View {
    let node: GNode
    let isCenter: Bool
    let isSelected: Bool
    let isMatch: Bool

    private var tint: Color {
        switch node.kind {
        case "external": .orange
        case "thunk": .gray
        case "data": .blue
        default: .purple
        }
    }

    private var icon: String {
        switch node.kind {
        case "external": "shippingbox"
        case "thunk": "arrow.turn.down.right"
        case "data": "tablecells"
        default: "f.cursive"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.label).font(.system(size: 12, weight: isCenter ? .bold : .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text(node.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isMatch ? Color.yellow.opacity(0.3) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isSelected ? Color.accentColor : (isCenter ? tint : tint.opacity(0.35)),
                          lineWidth: isSelected || isCenter ? 2.2 : 1))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        .help("\(node.label)\n\(node.detail)\nDoble clic: \(node.kind == "external" ? "ir" : "centrar / abrir")")
    }
}

// MARK: - Graphs window

struct GraphsView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = 0
    @State private var up = 1
    @State private var down = 2
    @State private var depth = 1
    @State private var externals = false
    @State private var limit = 600
    @State private var center: String?
    @State private var graph: NodeGraphData?
    @State private var loading = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                controls
                Divider()
                ZStack {
                    Color(nsColor: Theme.background)
                    if let graph {
                        if graph.nodes.count <= 1 && graph.edges.isEmpty {
                            ContentUnavailableView(tr("Sin relaciones"), systemImage: "point.3.connected.trianglepath.dotted",
                                                   description: Text(mode == 2 ? tr("Nada referencia esta dirección ni ella referencia a nada.")
                                                                                : tr("Esta función no llama ni es llamada por ninguna otra.")))
                        } else {
                            NodeGraphView(graph: graph, centerID: mode == 1 ? nil : center, highlight: query,
                                          onOpen: { node in if let a = node.address { model.go(a) } },
                                          onRecenter: mode == 1 ? nil : { node in
                                              center = node.address
                                              Task { await load() }
                                          })
                        }
                    } else if loading {
                        ProgressView()
                    }
                }
                .overlay(alignment: .topLeading) {
                    if graph?.truncated == true {
                        Label(tr("Grafo truncado por tamaño"), systemImage: "exclamationmark.triangle")
                            .font(.caption).padding(8).glassEffect(.regular, in: .capsule).padding(12)
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onChange(of: mode) { _, _ in center = nil }
        .task(id: "\(mode)|\(up)|\(down)|\(depth)|\(externals)|\(limit)|\(model.activeSession ?? "")") { await load() }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("", selection: $mode) {
                Text(tr("Llamadas de la función")).tag(0)
                Text(tr("Llamadas del programa")).tag(1)
                Text(tr("Referencias")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch mode {
            case 0:
                Stepper(tr("Llamadores: %@", "\(up)"), value: $up, in: 0...5).fixedSize()
                Stepper(tr("Llamados: %@", "\(down)"), value: $down, in: 0...5).fixedSize()
            case 1:
                Toggle(tr("Funciones externas"), isOn: $externals).toggleStyle(.checkbox)
                Picker(tr("Máx."), selection: $limit) {
                    Text("300").tag(300); Text("600").tag(600); Text("1500").tag(1500); Text("3000").tag(3000)
                }
                .fixedSize()
            default:
                Stepper(tr("Profundidad: %@", "\(depth)"), value: $depth, in: 1...4).fixedSize()
            }
            Spacer()
            TextField(tr("Resaltar"), text: $query).textFieldStyle(.roundedBorder).frame(width: 140)
            if mode != 1 {
                Button { center = nil; Task { await load() } } label: { Image(systemName: "scope") }
                    .help(tr("Centrar en la selección de la ventana principal"))
            }
            Button { exportDot() } label: { Image(systemName: "square.and.arrow.up") }
                .help(tr("Exportar como Graphviz (.dot)"))
                .disabled(graph == nil)
        }
        .padding(12)
    }

    private func load() async {
        guard model.program != nil else { return }
        loading = true
        defer { loading = false }
        do {
            switch mode {
            case 0:
                guard let address = center ?? model.current?.function ?? model.functionDetails?.entry else {
                    graph = nil
                    return
                }
                center = address
                graph = try await model.engine.call("callGraph", ["address": address, "up": up, "down": down])
            case 1:
                graph = try await model.engine.call("programCallGraph", ["external": externals, "limit": limit])
            default:
                guard let address = center ?? model.editTarget else { graph = nil; return }
                center = address
                graph = try await model.engine.call("referenceGraph", ["address": address, "depth": depth])
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func exportDot() {
        guard let graph else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "grafo.dot"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? graph.dot.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
