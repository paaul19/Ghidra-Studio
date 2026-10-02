import SwiftUI
import UniformTypeIdentifiers

/// Layout for call / reference / data-flow graphs: layered (using node levels when given, otherwise
/// longest-path layering), the same turned sideways, on a circle, or in rings around the center.
struct NodeGraphLayout {
    var rects: [String: CGRect] = [:]
    var edges: [EdgeShape] = []
    var size: CGSize = .zero

    static let nodeHeight: CGFloat = 46
    static let hGap: CGFloat = 26
    static let vGap: CGFloat = 70
    /// Horizontal stretch of the circular and radial layouts.
    static let stretch: CGFloat = 2.6

    private static func width(_ node: GNode) -> CGFloat {
        CGFloat(min(max(node.label.count, node.detail.count), 36)) * 7.6 + 58
    }

    init(_ g: NodeGraphData, style: NodeGraphStyle = .layered, centerID: String? = nil) {
        let ids = g.nodes.map(\.id)
        guard !ids.isEmpty else { return }
        let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
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
        let leveled = g.nodes.allSatisfy({ $0.level != nil })
        if leveled {
            let minLevel = g.nodes.compactMap(\.level).min() ?? 0
            for (i, node) in g.nodes.enumerated() { layer[i] = (node.level ?? 0) - minLevel }
            for a in 0..<n { for b in succ[a] where layer[b] <= layer[a] { back.insert([a, b]) } }
        } else {
            var state = Array(repeating: 0, count: n)
            var order: [Int] = []
            // iterative: data-flow graphs can be thousands of nodes deep
            func dfs(_ root: Int) {
                var stack: [(node: Int, next: Int)] = [(root, 0)]
                state[root] = 1
                while let top = stack.last {
                    if top.next < succ[top.node].count {
                        stack[stack.count - 1].next += 1
                        let v = succ[top.node][top.next]
                        if state[v] == 1 { back.insert([top.node, v]) } else if state[v] == 0 {
                            state[v] = 1
                            stack.append((v, 0))
                        }
                    } else {
                        state[top.node] = 2
                        order.append(top.node)
                        stack.removeLast()
                    }
                }
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
                let keys = Dictionary(uniqueKeysWithValues: rows[l].map { ($0, bary($0)) })
                rows[l].sort { keys[$0]! < keys[$1]! }
                for (i, u) in rows[l].enumerated() { position[u] = Double(i) }
            }
        }

        var raw: [Int: CGRect] = [:]
        switch style {
        case .layered: layered(g, rows: rows, raw: &raw)
        case .horizontal: horizontal(g, rows: rows, raw: &raw)
        case .circular: circular(g, rows: rows, raw: &raw)
        case .radial:
            radial(g, succ: succ, pred: pred, center: centerID.flatMap { index[$0] }, leveled: leveled, raw: &raw)
        case .grid: grid(g, rows: rows, raw: &raw)
        case .force: force(g, succ: succ, pred: pred, rows: rows, raw: &raw)
        }
        for (u, r) in raw { rects[ids[u]] = r }

        for a in 0..<n {
            for b in succ[a] {
                guard let ra = raw[a], let rb = raw[b] else { continue }
                var shape: EdgeShape
                switch style {
                case .layered:
                    let from = CGPoint(x: ra.midX, y: ra.maxY), to = CGPoint(x: rb.midX, y: rb.minY)
                    let isBack = back.contains([a, b]) || rb.minY <= ra.minY
                    var path = Path()
                    path.move(to: from)
                    if isBack {
                        path.addCurve(to: to, control1: CGPoint(x: from.x + 80, y: from.y + 60),
                                      control2: CGPoint(x: to.x + 80, y: to.y - 60))
                    } else {
                        let dy = max(25, (to.y - from.y) / 2)
                        path.addCurve(to: to, control1: CGPoint(x: from.x, y: from.y + dy),
                                      control2: CGPoint(x: to.x, y: to.y - dy))
                    }
                    shape = EdgeShape(path: path, tip: to, angle: isBack ? atan2(60, -80) : .pi / 2, back: isBack)
                case .horizontal:
                    let from = CGPoint(x: ra.maxX, y: ra.midY), to = CGPoint(x: rb.minX, y: rb.midY)
                    let isBack = back.contains([a, b]) || rb.minX <= ra.minX
                    var path = Path()
                    path.move(to: from)
                    if isBack {
                        path.addCurve(to: to, control1: CGPoint(x: from.x + 60, y: from.y - 70),
                                      control2: CGPoint(x: to.x - 60, y: to.y - 70))
                    } else {
                        let dx = max(25, (to.x - from.x) / 2)
                        path.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y),
                                      control2: CGPoint(x: to.x - dx, y: to.y))
                    }
                    shape = EdgeShape(path: path, tip: to, angle: isBack ? atan2(70, 60) : 0, back: isBack)
                case .circular, .radial, .grid, .force:
                    let ca = CGPoint(x: ra.midX, y: ra.midY), cb = CGPoint(x: rb.midX, y: rb.midY)
                    let from = EdgeShape.border(of: ra, toward: cb), to = EdgeShape.border(of: rb, toward: ca)
                    var path = Path()
                    path.move(to: from)
                    path.addLine(to: to)
                    shape = EdgeShape(path: path, tip: to, angle: atan2(to.y - from.y, to.x - from.x))
                }
                shape.fromID = ids[a]
                shape.toID = ids[b]
                edges.append(shape)
            }
        }
    }

    private mutating func layered(_ g: NodeGraphData, rows: [[Int]], raw: inout [Int: CGRect]) {
        let n = g.nodes.count
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
        for row in visualRows {
            var x: CGFloat = 0
            for u in row {
                let w = Self.width(g.nodes[u])
                raw[u] = CGRect(x: x, y: y, width: w, height: Self.nodeHeight)
                x += w + Self.hGap
            }
            let w = max(0, x - Self.hGap)
            rowWidths.append(w)
            maxWidth = max(maxWidth, w)
            y += Self.nodeHeight + Self.vGap
        }
        for (l, row) in visualRows.enumerated() {
            let offset = (maxWidth - rowWidths[l]) / 2 + 40
            for u in row { raw[u]?.origin.x += offset }
        }
        size = CGSize(width: maxWidth + 80, height: y + 20)
    }

    private mutating func horizontal(_ g: NodeGraphData, rows: [[Int]], raw: inout [Int: CGRect]) {
        let n = g.nodes.count
        let perColumn = max(8, Int(Double(n).squareRoot().rounded(.up)) + 4)
        var columns: [[Int]] = []
        for row in rows {
            var i = 0
            while i < row.count {
                columns.append(Array(row[i..<min(i + perColumn, row.count)]))
                i += perColumn
            }
            if row.isEmpty { columns.append([]) }
        }
        var x: CGFloat = 40
        var maxHeight: CGFloat = 0
        var heights: [CGFloat] = []
        for column in columns {
            var y: CGFloat = 0
            var widest: CGFloat = 0
            for u in column {
                let w = Self.width(g.nodes[u])
                raw[u] = CGRect(x: x, y: y, width: w, height: Self.nodeHeight)
                widest = max(widest, w)
                y += Self.nodeHeight + 16
            }
            heights.append(max(0, y - 16))
            maxHeight = max(maxHeight, y - 16)
            x += widest + 90
        }
        for (l, column) in columns.enumerated() {
            let offset = (maxHeight - heights[l]) / 2 + 90
            for u in column { raw[u]?.origin.y += offset }
        }
        size = CGSize(width: x, height: maxHeight + 140)
    }

    /// Nodes in reading order (level by level), in a near-square grid.
    private mutating func grid(_ g: NodeGraphData, rows: [[Int]], raw: inout [Int: CGRect]) {
        let order = rows.flatMap { $0 }
        let columns = max(1, Int(Double(order.count).squareRoot().rounded(.up)))
        let cell = (order.map { Self.width(g.nodes[$0]) }.max() ?? 160) + Self.hGap
        for (i, u) in order.enumerated() {
            let w = Self.width(g.nodes[u])
            raw[u] = CGRect(x: 40 + CGFloat(i % columns) * cell + (cell - Self.hGap - w) / 2,
                            y: 40 + CGFloat(i / columns) * (Self.nodeHeight + Self.vGap), width: w, height: Self.nodeHeight)
        }
        let lines = (order.count + columns - 1) / columns
        size = CGSize(width: 80 + CGFloat(columns) * cell, height: 80 + CGFloat(lines) * (Self.nodeHeight + Self.vGap))
    }

    /// Fruchterman–Reingold: connected nodes pull together, all nodes push apart.
    private mutating func force(_ g: NodeGraphData, succ: [[Int]], pred: [[Int]], rows: [[Int]], raw: inout [Int: CGRect]) {
        let n = g.nodes.count
        guard n <= 500 else { grid(g, rows: rows, raw: &raw); return }
        let side = max(600, Double(n).squareRoot() * 260)
        let k = side / Double(n).squareRoot() * 0.9
        // start from the grid so the result does not depend on chance
        var pos = Array(repeating: CGPoint.zero, count: n)
        let columns = max(1, Int(Double(n).squareRoot().rounded(.up)))
        for (i, u) in rows.flatMap({ $0 }).enumerated() {
            pos[u] = CGPoint(x: Double(i % columns) * side / Double(columns) + Double(i % 3) * 7,
                             y: Double(i / columns) * side / Double(columns) + Double(i % 5) * 5)
        }
        var temperature = side / 8
        for _ in 0..<(n > 250 ? 60 : 120) {
            var disp = Array(repeating: CGPoint.zero, count: n)
            for a in 0..<n {
                for b in (a + 1)..<max(a + 1, n) {
                    var dx = pos[a].x - pos[b].x, dy = (pos[a].y - pos[b].y) * 2.2
                    if dx == 0 && dy == 0 { dx = 0.5; dy = 0.3 }
                    let d = max(1, (dx * dx + dy * dy).squareRoot())
                    let f = k * k / d
                    disp[a].x += dx / d * f; disp[a].y += dy / d * f
                    disp[b].x -= dx / d * f; disp[b].y -= dy / d * f
                }
            }
            for a in 0..<n {
                for b in succ[a] {
                    let dx = pos[a].x - pos[b].x, dy = pos[a].y - pos[b].y
                    let d = max(1, (dx * dx + dy * dy).squareRoot())
                    let f = d * d / k
                    disp[a].x -= dx / d * f; disp[a].y -= dy / d * f
                    disp[b].x += dx / d * f; disp[b].y += dy / d * f
                }
            }
            for a in 0..<n {
                let d = max(1, (disp[a].x * disp[a].x + disp[a].y * disp[a].y).squareRoot())
                pos[a].x += disp[a].x / d * min(d, temperature)
                pos[a].y += disp[a].y / d * min(d, temperature)
            }
            temperature *= 0.96
        }
        let minX = pos.map(\.x).min() ?? 0, minY = pos.map(\.y).min() ?? 0
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for u in 0..<n {
            let w = Self.width(g.nodes[u])
            // boxes are wide: stretch sideways so they do not overlap
            let r = CGRect(x: 40 + (pos[u].x - minX) * 1.7, y: 40 + (pos[u].y - minY), width: w, height: Self.nodeHeight)
            raw[u] = r
            maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
        }
        size = CGSize(width: maxX + 60, height: maxY + 60)
    }

    private mutating func circular(_ g: NodeGraphData, rows: [[Int]], raw: inout [Int: CGRect]) {
        let order = rows.flatMap { $0 }
        let widest = order.map { Self.width(g.nodes[$0]) }.max() ?? 160
        // the boxes are much wider than tall, so the ring is stretched sideways to keep them apart
        let step = (min(widest, 240) + 24) / Self.stretch
        let radius = max(150, CGFloat(order.count) * step / (2 * .pi))
        let c = CGPoint(x: radius * Self.stretch + widest / 2 + 40, y: radius + Self.nodeHeight / 2 + 40)
        for (i, u) in order.enumerated() {
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(max(1, order.count)) - .pi / 2
            let w = Self.width(g.nodes[u])
            raw[u] = CGRect(x: c.x + radius * Self.stretch * cos(angle) - w / 2,
                            y: c.y + radius * sin(angle) - Self.nodeHeight / 2, width: w, height: Self.nodeHeight)
        }
        size = CGSize(width: c.x * 2, height: c.y * 2)
    }

    private mutating func radial(_ g: NodeGraphData, succ: [[Int]], pred: [[Int]], center: Int?, leveled: Bool,
                                 raw: inout [Int: CGRect]) {
        let n = g.nodes.count
        // ring of each node: its level when there is one, otherwise its distance to the center
        var ring = Array(repeating: -1, count: n)
        var upper = Array(repeating: false, count: n)     // callers go above the center, callees below
        if leveled {
            for (i, node) in g.nodes.enumerated() {
                ring[i] = abs(node.level ?? 0)
                upper[i] = (node.level ?? 0) < 0
            }
        } else {
            let root = center ?? (0..<n).first { pred[$0].isEmpty } ?? 0
            ring[root] = 0
            var frontier = [root]
            while !frontier.isEmpty {
                var next: [Int] = []
                for u in frontier {
                    for v in succ[u] + pred[u] where ring[v] == -1 {
                        ring[v] = ring[u] + 1
                        next.append(v)
                    }
                }
                frontier = next
            }
            let last = (ring.max() ?? 0) + 1
            for u in 0..<n where ring[u] == -1 { ring[u] = last }
        }
        let ringCount = (ring.max() ?? 0) + 1
        var members = Array(repeating: [Int](), count: ringCount)
        for u in 0..<n { members[ring[u]].append(u) }

        // A crowded ring is split into several concentric ones, so the graph does not grow with the widest ring.
        var placed: [(node: Int, radius: CGFloat, angle: CGFloat)] = []
        var radius: CGFloat = 0
        func fill(_ list: [Int], from: CGFloat, sweep: CGFloat, start: CGFloat) -> CGFloat {
            var r = start
            var i = 0
            while i < list.count {
                let widest = list[i...].prefix(64).map { Self.width(g.nodes[$0]) }.max() ?? 160
                let capacity = max(1, Int(sweep * r / max(62, (min(widest, 240) + 20) / Self.stretch)))
                let chunk = Array(list[i..<min(i + capacity, list.count)])
                for (j, u) in chunk.enumerated() {
                    placed.append((u, r, from + sweep * (CGFloat(j) + 0.5) / CGFloat(chunk.count)))
                }
                i += chunk.count
                if i < list.count { r += Self.nodeHeight + 22 }
            }
            return r
        }
        for k in 0..<ringCount {
            if k == 0, members[0].count == 1 {
                placed.append((members[0][0], 0, 0))
                continue
            }
            let start = radius + (k == 0 ? 80 : 120)
            if leveled {
                let above = fill(members[k].filter { upper[$0] }, from: .pi, sweep: .pi, start: start)     // upper half
                let below = fill(members[k].filter { !upper[$0] }, from: 0, sweep: .pi, start: start)     // lower half
                radius = max(above, below)
            } else {
                radius = fill(members[k], from: -.pi / 2, sweep: 2 * .pi, start: start)
            }
        }
        let c = CGPoint(x: radius * Self.stretch + 190, y: radius + 80)
        for item in placed {
            let w = Self.width(g.nodes[item.node])
            raw[item.node] = CGRect(x: c.x + item.radius * Self.stretch * cos(item.angle) - w / 2,
                                    y: c.y + item.radius * sin(item.angle) - Self.nodeHeight / 2,
                                    width: w, height: Self.nodeHeight)
        }
        size = CGSize(width: c.x * 2, height: c.y * 2)
    }
}

/// Several nodes shown as one.
struct NodeGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var members: [String]
}

struct NodeGraphView: View {
    @Environment(AppModel.self) private var model
    let graph: NodeGraphData
    var centerID: String?
    var highlight: String = ""
    /// Name used for the exported file.
    var exportName = "grafo"
    /// Marks the node that contains the program's cursor and navigates when a node is chosen.
    var sync = false
    var onOpen: (GNode) -> Void
    var onRecenter: ((GNode) -> Void)?
    /// Adds what the node is connected to (incremental graphs).
    var onExpand: ((GNode) -> Void)?
    @State private var scale: CGFloat = 1
    @State private var picked = Set<String>()
    @State private var hidden = Set<String>()
    @State private var groups: [NodeGroup] = []
    @State private var focusOn: String?
    @State private var focusHops = 1
    @State private var kindsOff = Set<String>()
    @State private var edgeKindsOff = Set<String>()
    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @State private var tracker = ScrollTracker()
    @GestureState private var pinch: CGFloat = 1
    @AppStorage("nodeGraphStyle") private var styleName = NodeGraphStyle.layered.rawValue
    @AppStorage("graphSatellite") private var showSatellite = true

    private var style: NodeGraphStyle { NodeGraphStyle(rawValue: styleName) ?? .layered }

    /// The graph after hiding, filtering, focusing and collapsing.
    private var shown: NodeGraphData {
        var nodes = graph.nodes.filter { !hidden.contains($0.id) && !kindsOff.contains($0.kind) }
        var edges = graph.edges.filter { !edgeKindsOff.contains($0.kind) }
        if let focusOn, nodes.contains(where: { $0.id == focusOn }) {
            var near: Set<String> = [focusOn]
            var frontier: Set<String> = [focusOn]
            for _ in 0..<focusHops {
                var next = Set<String>()
                for e in edges {
                    if frontier.contains(e.from), near.insert(e.to).inserted { next.insert(e.to) }
                    if frontier.contains(e.to), near.insert(e.from).inserted { next.insert(e.from) }
                }
                frontier = next
            }
            nodes = nodes.filter { near.contains($0.id) }
        }
        var owner: [String: NodeGroup] = [:]
        for g in groups { for m in g.members { owner[m] = g } }
        if !owner.isEmpty {
            var out: [GNode] = []
            var seen = Set<String>()
            for n in nodes {
                if let g = owner[n.id] {
                    if seen.insert(g.id).inserted {
                        out.append(GNode(id: g.id, label: g.name, detail: tr("%@ nodos", "\(g.members.count)"), kind: "group",
                                         level: n.level, address: n.address))
                    }
                } else {
                    out.append(n)
                }
            }
            nodes = out
            var unique = Set<GEdge>()
            edges = edges.compactMap { e in
                let edge = GEdge(from: owner[e.from]?.id ?? e.from, to: owner[e.to]?.id ?? e.to, kind: e.kind)
                return edge.from != edge.to && unique.insert(edge).inserted ? edge : nil
            }
        }
        let ids = Set(nodes.map(\.id))
        return NodeGraphData(nodes: nodes, edges: edges.filter { ids.contains($0.from) && ids.contains($0.to) },
                             truncated: graph.truncated)
    }

    /// The node the program's cursor is in.
    private func cursorNode(_ g: NodeGraphData) -> String? {
        guard sync, let v = model.selectedAddress.flatMap(addressValue) else { return nil }
        return g.nodes.first { n in
            guard let lo = n.address.flatMap(addressValue) else { return false }
            return v >= lo && v <= (n.end.flatMap(addressValue) ?? lo)
        }?.id
    }

    var body: some View {
        let shown = shown
        let layout = NodeGraphLayout(shown, style: style, centerID: centerID)
        let s = max(0.03, min(3, scale * pinch))
        let cursor = cursorNode(shown)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in layout.edges { Self.draw(e, picked: picked, in: &ctx) }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                ForEach(shown.nodes) { node in
                    if let r = layout.rects[node.id] {
                        NodeBox(node: node, isCenter: node.id == centerID || node.id == cursor, isSelected: picked.contains(node.id),
                                isMatch: !highlight.isEmpty && node.label.localizedCaseInsensitiveContains(highlight))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture(count: 2) {
                                if let onRecenter, node.kind != "external", node.kind != "group" { onRecenter(node) } else { onOpen(node) }
                            }
                            .onTapGesture { pick(node) }
                            .contextMenu { nodeMenu(node) }
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: layout.size.width * s, height: layout.size.height * s, alignment: .topLeading)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { [tracker] _, new in tracker.offset = new }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .onAppear { DispatchQueue.main.async { focus(layout, s) } }
        .onChange(of: graph.nodes.count) { _, _ in DispatchQueue.main.async { focus(layout, s) } }
        .onChange(of: centerID) { _, _ in DispatchQueue.main.async { focus(layout, s) } }
        .onChange(of: styleName) { _, _ in
            DispatchQueue.main.async { focus(NodeGraphLayout(shown, style: style, centerID: centerID), s) }
        }
        .onChange(of: cursor) { _, id in
            // position sync: keep the node of the cursor in view
            if let id, let r = layout.rects[id] {
                position.scrollTo(point: CGPoint(x: max(0, r.midX * s - viewport.width / 2), y: max(0, r.midY * s - viewport.height / 2)))
            }
        }
        .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { scale = max(0.03, min(3, scale * $0.magnification)) })
        .overlay(alignment: .bottomLeading) {
            if showSatellite, shown.nodes.count > 1 {
                let ordered = shown.nodes.compactMap { node in layout.rects[node.id].map { (node.id, $0) } }
                SatelliteView(content: layout.size, rects: ordered.map(\.1),
                              marked: Set(ordered.indices.filter { picked.contains(ordered[$0].0) || ordered[$0].0 == centerID }),
                              tracker: tracker, viewport: viewport, scale: s) { center in
                    position.scrollTo(point: CGPoint(x: max(0, center.x * s - viewport.width / 2),
                                                     y: max(0, center.y * s - viewport.height / 2)))
                }
                .padding(14)
            }
        }
        .overlay(alignment: .topTrailing) { viewMenu(shown).padding(14) }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Picker(tr("Distribución"), selection: $styleName) {
                    ForEach(NodeGraphStyle.allCases) { item in
                        Image(systemName: item.icon).help(item.title).accessibilityLabel(item.title).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(tr("Distribución del grafo: por niveles, de izquierda a derecha, en círculo, radial, en cuadrícula o por fuerzas"))
                Button { showSatellite.toggle() } label: { Image(systemName: showSatellite ? "map.fill" : "map") }
                    .help(tr("Mostrar u ocultar la vista satélite"))
                    .accessibilityLabel(tr("Vista satélite"))
                Button { export(layout, shown) } label: { Image(systemName: "square.and.arrow.up") }
                    .help(tr("Exportar el grafo (PNG, PDF, DOT, GraphML, JSON, CSV)"))
                    .accessibilityLabel(tr("Exportar…"))
                Button {
                    scale = max(0.03, min(1, min(viewport.width / layout.size.width, viewport.height / layout.size.height)))
                    position.scrollTo(point: .zero)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(tr("Ajustar a la ventana"))
                    .accessibilityLabel(tr("Ajustar a la ventana"))
                Button { scale = max(0.03, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = 1 } label: { Text("\(Int(s * 100)) %").font(.caption.monospacedDigit()) }
                Button { scale = min(3, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.glass)
            .padding(14)
        }
    }

    /// Click chooses one node; with ⌘ it adds to (or removes from) the choice.
    private func pick(_ node: GNode) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if picked.contains(node.id) { picked.remove(node.id) } else { picked.insert(node.id) }
        } else {
            picked = picked == [node.id] ? [] : [node.id]
            if sync, picked.contains(node.id), node.kind != "group" { onOpen(node) }
        }
    }

    private func members(of ids: Set<String>) -> [String] {
        ids.flatMap { id in groups.first { $0.id == id }?.members ?? [id] }
    }

    @ViewBuilder private func nodeMenu(_ node: GNode) -> some View {
        if node.address != nil, node.kind != "group" {
            Button(tr("Ir a %@", "\(node.label)")) { onOpen(node) }
        }
        if let onRecenter, node.kind != "external", node.kind != "group" {
            Button(tr("Centrar el grafo aquí")) { onRecenter(node) }
        }
        if let onExpand, node.kind != "group" {
            Button(tr("Expandir: añadir lo que conecta con este nodo")) { onExpand(node) }
        }
        Divider()
        Button(tr("Ocultar")) {
            hidden.formUnion(members(of: picked.contains(node.id) ? picked : [node.id]))
            picked = []
        }
        Button(tr("Enfocar: solo este nodo y sus vecinos")) { focusOn = node.id }
        if let group = groups.first(where: { $0.id == node.id }) {
            Button(tr("Deshacer el grupo")) { groups.removeAll { $0.id == group.id } }
        } else if picked.count > 1, picked.contains(node.id) {
            Button(tr("Colapsar los %@ elegidos en un grupo", "\(picked.count)")) { collapsePicked() }
        }
    }

    private func collapsePicked() {
        let all = members(of: picked)
        guard all.count > 1 else { return }
        groups.removeAll { picked.contains($0.id) }
        groups.append(NodeGroup(id: "group-" + UUID().uuidString, name: tr("Grupo %@", "\(groups.count + 1)"), members: all))
        picked = []
    }

    private static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "func": tr("Funciones")
        case "external": tr("Externas")
        case "thunk": "Thunks"
        case "data": tr("Datos")
        case "block": tr("Bloques")
        case "op": tr("Instrucciones y operaciones")
        case "const": tr("Constantes")
        case "input": tr("Entradas")
        case "var", "tied": tr("Variables")
        case "call": tr("Llamadas")
        case "fall": tr("Continuación")
        case "jump": tr("Saltos")
        case "conditional": tr("Saltos condicionales")
        case "": tr("Sin clase")
        default: kind
        }
    }

    private func viewMenu(_ shown: NodeGraphData) -> some View {
        let nodeKinds = Array(Set(graph.nodes.map(\.kind))).sorted()
        let edgeKinds = Array(Set(graph.edges.map(\.kind))).sorted()
        return HStack(spacing: 6) {
            if !picked.isEmpty {
                Button(tr("Seleccionar en el programa")) {
                    let chosen = Set(members(of: picked))
                    let ranges = graph.nodes.filter { chosen.contains($0.id) }.compactMap { n -> [String]? in
                        n.address.map { [$0, n.end ?? $0] }
                    }
                    model.setSelection(ranges: ranges)
                }
                .help(tr("Crea una selección del programa con los nodos elegidos"))
            }
            Menu {
                Text(tr("%@ de %@ nodos", "\(shown.nodes.count)", "\(graph.nodes.count)"))
                Button(tr("Ocultar los elegidos")) { hidden.formUnion(members(of: picked)); picked = [] }.disabled(picked.isEmpty)
                Button(tr("Mostrar solo los elegidos")) {
                    let keep = Set(members(of: picked))
                    hidden = Set(graph.nodes.map(\.id)).subtracting(keep)
                    picked = []
                }
                .disabled(picked.isEmpty)
                Button(tr("Mostrar todos")) { hidden = []; focusOn = nil }.disabled(hidden.isEmpty && focusOn == nil)
                Divider()
                Button(tr("Enfocar el elegido y sus vecinos")) { focusOn = picked.first }.disabled(picked.count != 1)
                Picker(tr("Saltos del enfoque"), selection: $focusHops) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                Button(tr("Quitar el enfoque")) { focusOn = nil }.disabled(focusOn == nil)
                Divider()
                Button(tr("Colapsar los elegidos en un grupo")) { collapsePicked() }.disabled(picked.count < 2)
                Button(tr("Deshacer todos los grupos")) { groups = [] }.disabled(groups.isEmpty)
                if nodeKinds.count > 1 {
                    Divider()
                    ForEach(nodeKinds, id: \.self) { kind in
                        Toggle(Self.kindTitle(kind), isOn: Binding(get: { !kindsOff.contains(kind) }, set: { on in
                            if on { kindsOff.remove(kind) } else { kindsOff.insert(kind) }
                        }))
                    }
                }
                if edgeKinds.count > 1 {
                    Divider()
                    ForEach(edgeKinds, id: \.self) { kind in
                        Toggle(tr("Aristas: %@", Self.kindTitle(kind)), isOn: Binding(get: { !edgeKindsOff.contains(kind) }, set: { on in
                            if on { edgeKindsOff.remove(kind) } else { edgeKindsOff.insert(kind) }
                        }))
                    }
                }
            } label: {
                Label(tr("Vértices"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
        }
        .buttonStyle(.glass)
    }

    static func draw(_ e: EdgeShape, picked: Set<String>, in ctx: inout GraphicsContext) {
        let active = picked.contains(e.fromID) || picked.contains(e.toID)
        let color: Color = active ? .accentColor : .secondary.opacity(picked.isEmpty ? 0.6 : 0.25)
        ctx.stroke(e.path, with: .color(color), style: StrokeStyle(lineWidth: active ? 2.2 : 1.2,
                                                                   dash: e.back ? [5, 4] : []))
        ctx.fill(e.arrowHead(size: 8), with: .color(color))
    }

    private func export(_ layout: NodeGraphLayout, _ shown: NodeGraphData) {
        var data = GraphExportData()
        data.nodes = shown.nodes.map { ($0.id, $0.detail.isEmpty ? $0.label : $0.label + "\n" + $0.detail) }
        data.edges = shown.edges.map { ($0.from, $0.to, $0.kind) }
        let nodes = shown.nodes, center = centerID
        GraphExporter.export(name: exportName, data: data, size: layout.size) {
            ZStack(alignment: .topLeading) {
                EdgeShapesView(edges: layout.edges, size: layout.size, color: { _ in Color.secondary.opacity(0.7) },
                               lineWidth: 1.2)
                ForEach(nodes) { node in
                    if let r = layout.rects[node.id] {
                        NodeBox(node: node, isCenter: node.id == center, isSelected: false, isMatch: false)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .background(Color(nsColor: Theme.background))
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
        case "external", "input": .orange
        case "thunk", "const": .gray
        case "data", "var": .blue
        case "tied": .teal
        case "block": .indigo
        case "group": .pink
        default: .purple
        }
    }

    private var icon: String {
        switch node.kind {
        case "external": "shippingbox"
        case "thunk": "arrow.turn.down.right"
        case "data": "tablecells"
        case "op": "gearshape"
        case "const": "number"
        case "input": "arrow.down.to.line"
        case "var", "tied": "shippingbox"
        case "block": "rectangle.split.1x2"
        case "group": "square.stack.3d.up"
        default: "f.cursive"
        }
    }

    /// Shape by kind: data and blocks square, operations as pills, the rest rounded.
    private var radius: CGFloat {
        switch node.kind {
        case "data", "block", "const": 3
        case "op", "var", "tied", "input": 23
        default: 10
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: radius)
            .fill(isMatch ? Color.yellow.opacity(0.3) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(isSelected ? Color.accentColor : (isCenter ? tint : tint.opacity(node.kind == "group" ? 0.9 : 0.35)),
                          style: StrokeStyle(lineWidth: isSelected || isCenter ? 2.2 : (node.kind == "group" ? 2 : 1),
                                             dash: node.kind == "group" ? [6, 4] : [])))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        .help("\(node.label)\n\(node.detail)")
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
    /// P-code control-flow graph (mode 4), shown with the block view of the function graph.
    @State private var blockGraph: FunctionGraphData?
    /// to, from or both: which references the reference graph follows.
    @State private var direction = "both"
    /// New graphs are added to the one on screen instead of replacing it.
    @State private var accumulate = false
    @State private var sync = true

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                controls
                Divider()
                ZStack {
                    Color(nsColor: Theme.background)
                    if mode == 4 {
                        if let blockGraph {
                            FunctionGraphView(graph: blockGraph, groupNamespace: "|pcode")
                        } else if loading {
                            ProgressView()
                        }
                    } else if let graph {
                        if graph.nodes.count <= 1 && graph.edges.isEmpty {
                            ContentUnavailableView(tr("Sin relaciones"), systemImage: "point.3.connected.trianglepath.dotted",
                                                   description: Text(mode == 2 ? tr("Nada referencia esta dirección ni ella referencia a nada.")
                                                                                : tr("Esta función no llama ni es llamada por ninguna otra.")))
                        } else {
                            NodeGraphView(graph: graph, centerID: [1, 3, 5, 6].contains(mode) ? nil : center, highlight: query,
                                          exportName: ["llamadas", "programa", "referencias", "flujo-de-datos", "pcode", "bloques",
                                                       "codigo", "datos"][min(mode, 7)],
                                          sync: sync,
                                          onOpen: { node in if let a = node.address { model.go(a) } },
                                          onRecenter: [1, 3, 5, 6].contains(mode) ? nil : { node in
                                              center = node.address
                                              Task { await load() }
                                          },
                                          onExpand: [0, 2, 7].contains(mode) ? { node in
                                              Task { await expand(node) }
                                          } : nil)
                        }
                    } else if loading {
                        ProgressView()
                    }
                }
                .overlay(alignment: .topLeading) {
                    if mode != 4, graph?.truncated == true {
                        Label(tr("Grafo truncado por tamaño"), systemImage: "exclamationmark.triangle")
                            .font(.caption).padding(8).glassEffect(.regular, in: .capsule).padding(12)
                    }
                }
            }
        }
        .windowMinSize(1000, 560)
        .onChange(of: mode) { _, _ in center = nil }
        .task(id: "\(mode)|\(up)|\(down)|\(depth)|\(externals)|\(limit)|\(direction)|\(model.activeSession ?? "")") { await load() }
        // opened before the program had a location: load as soon as there is one
        .onChange(of: model.current?.address) { _, _ in
            if graph == nil, blockGraph == nil, !loading { Task { await load() } }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("", selection: $mode) {
                Text(tr("Llamadas de la función")).tag(0)
                Text(tr("Llamadas del programa")).tag(1)
                Text(tr("Referencias")).tag(2)
                Text(tr("Flujo de datos")).tag(3)
                Text("P-code").tag(4)
                Divider()
                Text(tr("Flujo de bloques")).tag(5)
                Text(tr("Flujo de código")).tag(6)
                Text(tr("Grafo de datos")).tag(7)
            }
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
            case 2:
                Stepper(tr("Profundidad: %@", "\(depth)"), value: $depth, in: 1...4).fixedSize()
                Picker("", selection: $direction) {
                    Text(tr("Hacia y desde")).tag("both")
                    Text(tr("Lo que la referencia")).tag("to")
                    Text(tr("Lo que referencia")).tag("from")
                }
                .labelsHidden().fixedSize()
            case 5, 6:
                Text(model.programSelection != nil ? tr("De la selección del programa") : tr("De la función actual (o selecciona un rango)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Picker(tr("Máx."), selection: $limit) {
                    Text("300").tag(300); Text("600").tag(600); Text("1500").tag(1500); Text("3000").tag(3000)
                }
                .fixedSize()
                Button(tr("Todo el programa")) { Task { await load(whole: true) } }
            case 7:
                Stepper(tr("Profundidad: %@", "\(depth)"), value: $depth, in: 1...4).fixedSize()
            case 3:
                Text(tr("Operaciones y valores del descompilador para la función actual"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            default:
                Text(tr("Bloques de p-code del descompilador y el flujo entre ellos"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if mode != 4 {
                Toggle(tr("Añadir"), isOn: $accumulate).toggleStyle(.checkbox)
                    .help(tr("Los grafos nuevos se añaden al que está en pantalla en lugar de reemplazarlo"))
                Toggle(tr("Sincronizar"), isOn: $sync).toggleStyle(.checkbox)
                    .help(tr("Marca el nodo donde está el cursor del programa y va al programa al elegir un nodo"))
                TextField(tr("Resaltar"), text: $query).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            if mode != 1 {
                Button { center = nil; Task { await load() } } label: { Image(systemName: "scope") }
                    .help(tr("Centrar en la selección de la ventana principal"))
            }
        }
        .padding(12)
    }

    /// Shows a new graph, or adds it to the one on screen.
    private func show(_ new: NodeGraphData) {
        guard accumulate, let old = graph else { graph = new; return }
        var ids = Set(old.nodes.map(\.id))
        var edges = Set(old.edges)
        graph = NodeGraphData(nodes: old.nodes + new.nodes.filter { ids.insert($0.id).inserted },
                              edges: old.edges + new.edges.filter { edges.insert($0).inserted },
                              truncated: old.truncated || new.truncated)
    }

    /// Adds the neighbors of one node (incremental exploration).
    private func expand(_ node: GNode) async {
        guard let address = node.address, let old = graph else { return }
        do {
            let more: NodeGraphData
            switch mode {
            case 0: more = try await model.engine.call("callGraph", ["address": address, "up": 1, "down": 1])
            case 7: more = try await model.engine.call("dataGraph", ["address": address, "depth": 1])
            default: more = try await model.engine.call("referenceGraph", ["address": address, "depth": 1, "direction": direction])
            }
            var ids = Set(old.nodes.map(\.id))
            var edges = Set(old.edges)
            // keep the levels of the graph on screen: new nodes hang one level away from the expanded one
            let base = node.level ?? 0
            let fresh = more.nodes.filter { ids.insert($0.id).inserted }.map { n -> GNode in
                var copy = n
                if let l = n.level { copy.level = base + l }
                return copy
            }
            graph = NodeGraphData(nodes: old.nodes + fresh, edges: old.edges + more.edges.filter { edges.insert($0).inserted },
                                  truncated: old.truncated || more.truncated)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func load(whole: Bool = false) async {
        guard model.program != nil else { return }
        loading = true
        defer { loading = false }
        do {
            switch mode {
            case 5, 6:
                var params: [String: Any] = ["limit": limit]
                if !whole {
                    if let selection = model.programSelection {
                        params["ranges"] = selection.ranges
                    } else if let details = model.functionDetails, let lo = addressValue(details.entry) {
                        let width = details.entry.count
                        let hex = String(lo + UInt64(max(1, details.size)) - 1, radix: 16)
                        params["address"] = details.entry
                        params["end"] = String(repeating: "0", count: max(0, width - hex.count)) + hex
                    }
                }
                show(try await model.engine.call(mode == 5 ? "blockFlowGraph" : "codeFlowGraph", params))
            case 7:
                guard let address = center ?? model.editTarget else { graph = nil; return }
                center = address
                show(try await model.engine.call("dataGraph", ["address": address, "depth": depth]))
            case 0:
                guard let address = center ?? model.current?.function ?? model.functionDetails?.entry else {
                    graph = nil
                    return
                }
                center = address
                show(try await model.engine.call("callGraph", ["address": address, "up": up, "down": down]))
            case 1:
                show(try await model.engine.call("programCallGraph", ["external": externals, "limit": limit]))
            case 2:
                guard let address = center ?? model.editTarget else { graph = nil; return }
                center = address
                show(try await model.engine.call("referenceGraph", ["address": address, "depth": depth, "direction": direction]))
            case 3:
                guard let address = center ?? model.current?.function ?? model.functionDetails?.entry else {
                    graph = nil
                    return
                }
                center = address
                show(try await model.engine.call("dataFlowGraph", ["address": address]))
            default:
                guard let address = center ?? model.current?.function ?? model.functionDetails?.entry else {
                    blockGraph = nil
                    return
                }
                center = address
                blockGraph = try await model.engine.call("pcodeFlowGraph", ["address": address])
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

}
