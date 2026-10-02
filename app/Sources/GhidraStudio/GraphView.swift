import SwiftUI

/// Layout of a function's control-flow graph: layered (Sugiyama-style, simplified), the same turned
/// sideways, or nested like the code (blocks in program order, indented by how deep they are nested).
struct GraphLayout {
    struct Node {
        var rect: CGRect
        let block: GraphBlock
    }

    var nodes: [Node] = []
    var edges: [EdgeShape] = []
    var size: CGSize = .zero

    /// What identifies a block in the picture: its start, or its group when it stands for several.
    static func key(_ b: GraphBlock) -> String { b.group?.uuidString ?? b.start }

    static let charWidth: CGFloat = 7.0
    static let lineHeight: CGFloat = 15
    static let hGap: CGFloat = 44
    static let vGap: CGFloat = 64

    private static func size(of b: GraphBlock) -> CGSize {
        let longest = max(b.lines.map(\.count).max() ?? 0, (b.label ?? b.start).count + 2)
        return CGSize(width: max(140, CGFloat(min(longest, 70)) * charWidth + 24),
                      height: CGFloat(b.lines.count + 1) * lineHeight + 20)
    }

    init(_ g: FunctionGraphData, style: FunctionGraphStyle = .layered) {
        let n = g.blocks.count
        guard n > 0 else { return }
        var succ = Array(repeating: [Int](), count: n)
        for e in g.edges where e.from < n && e.to < n { succ[e.from].append(e.to) }

        // DFS from the entry to find back edges.
        let entry = g.blocks.firstIndex { $0.entry } ?? 0
        var state = Array(repeating: 0, count: n)   // 0 new, 1 on stack, 2 done
        var backEdges = Set<[Int]>()
        var order: [Int] = []
        func dfs(_ u: Int) {
            state[u] = 1
            for v in succ[u] {
                if state[v] == 1 { backEdges.insert([u, v]) } else if state[v] == 0 { dfs(v) }
            }
            state[u] = 2
            order.append(u)
        }
        dfs(entry)
        for u in 0..<n where state[u] == 0 { dfs(u) }

        if style == .nested {
            nested(g, succ: succ, entry: entry)
            return
        }

        // Longest-path layering over forward edges, in topological order.
        var layer = Array(repeating: 0, count: n)
        for u in order.reversed() {
            for v in succ[u] where !backEdges.contains([u, v]) {
                layer[v] = max(layer[v], layer[u] + 1)
            }
        }
        let layerCount = (layer.max() ?? 0) + 1
        var rows = Array(repeating: [Int](), count: layerCount)
        for u in 0..<n { rows[layer[u]].append(u) }

        // Barycenter ordering, two downward passes.
        var pred = Array(repeating: [Int](), count: n)
        for u in 0..<n { for v in succ[u] where !backEdges.contains([u, v]) { pred[v].append(u) } }
        var position = Array(repeating: 0.0, count: n)
        for (i, u) in rows[0].enumerated() { position[u] = Double(i) }
        for _ in 0..<2 {
            for l in 1..<max(1, layerCount) {
                rows[l].sort { a, b in
                    let pa = pred[a].isEmpty ? position[a] : pred[a].map { position[$0] }.reduce(0, +) / Double(pred[a].count)
                    let pb = pred[b].isEmpty ? position[b] : pred[b].map { position[$0] }.reduce(0, +) / Double(pred[b].count)
                    return pa < pb
                }
                for (i, u) in rows[l].enumerated() { position[u] = Double(i) }
            }
        }

        var rects = Array(repeating: CGRect.zero, count: n)
        var outCount = Array(repeating: 0, count: n)
        var outIndex = Array(repeating: 0, count: n)
        for e in g.edges where e.from < n { outCount[e.from] += 1 }

        if style == .horizontal {
            // layers become columns
            var x: CGFloat = 40
            var maxHeight: CGFloat = 0
            var columnHeights: [CGFloat] = []
            for row in rows {
                let sizes = row.map { Self.size(of: g.blocks[$0]) }
                let height = sizes.map(\.height).reduce(0, +) + CGFloat(max(0, row.count - 1)) * 30
                columnHeights.append(height)
                maxHeight = max(maxHeight, height)
                var y: CGFloat = 0
                for (i, u) in row.enumerated() {
                    rects[u] = CGRect(x: x, y: y, width: sizes[i].width, height: sizes[i].height)
                    y += sizes[i].height + 30
                }
                x += (sizes.map(\.width).max() ?? 0) + 90
            }
            for (l, row) in rows.enumerated() {
                let offset = (maxHeight - columnHeights[l]) / 2 + 60
                for u in row { rects[u].origin.y += offset }
            }
            nodes = (0..<n).map { Node(rect: rects[$0], block: g.blocks[$0]) }
            for e in g.edges where e.from < n && e.to < n {
                let s = rects[e.from], t = rects[e.to]
                let k = outCount[e.from], i = outIndex[e.from]
                outIndex[e.from] += 1
                let from = CGPoint(x: s.maxX, y: s.minY + s.height * CGFloat(i + 1) / CGFloat(k + 1))
                let to = CGPoint(x: t.minX, y: t.midY)
                let back = backEdges.contains([e.from, e.to]) || t.minX <= s.minX
                var path = Path()
                path.move(to: from)
                if back {
                    let lift: CGFloat = 60 + abs(from.x - to.x) * 0.08
                    path.addCurve(to: to, control1: CGPoint(x: from.x + 70, y: min(from.y, to.y) - lift),
                                  control2: CGPoint(x: to.x - 70, y: min(from.y, to.y) - lift))
                } else {
                    let dx = max(30, (to.x - from.x) / 2)
                    path.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y),
                                  control2: CGPoint(x: to.x - dx, y: to.y))
                }
                let lift: CGFloat = 60 + abs(from.x - to.x) * 0.08
                edges.append(EdgeShape(path: path, tip: to, angle: back ? atan2(to.y - min(from.y, to.y) + lift, 70) : 0,
                                       kind: e.kind, back: back, fromID: Self.key(g.blocks[e.from]), toID: Self.key(g.blocks[e.to])))
            }
            self.size = CGSize(width: x + 40, height: maxHeight + 160)
            return
        }

        // Sizes and coordinates.
        var y: CGFloat = 20
        var maxWidth: CGFloat = 0
        var rowWidths: [CGFloat] = []
        for row in rows {
            let sizes = row.map { Self.size(of: g.blocks[$0]) }
            let width = sizes.map(\.width).reduce(0, +) + CGFloat(max(0, row.count - 1)) * Self.hGap
            rowWidths.append(width)
            maxWidth = max(maxWidth, width)
            let height = sizes.map(\.height).max() ?? 0
            var x: CGFloat = 0
            for (i, u) in row.enumerated() {
                rects[u] = CGRect(x: x, y: y, width: sizes[i].width, height: sizes[i].height)
                x += sizes[i].width + Self.hGap
            }
            y += height + Self.vGap
        }
        for (l, row) in rows.enumerated() {
            let offset = (maxWidth - rowWidths[l]) / 2 + 40
            for u in row { rects[u].origin.x += offset }
        }
        nodes = (0..<n).map { Node(rect: rects[$0], block: g.blocks[$0]) }

        // Edges: spread outgoing ports along the bottom of each block.
        for e in g.edges where e.from < n && e.to < n {
            let s = rects[e.from], t = rects[e.to]
            let k = outCount[e.from]
            let i = outIndex[e.from]
            outIndex[e.from] += 1
            let from = CGPoint(x: s.minX + s.width * CGFloat(i + 1) / CGFloat(k + 1), y: s.maxY)
            let to = CGPoint(x: t.midX, y: t.minY)
            let back = backEdges.contains([e.from, e.to]) || t.minY <= s.minY
            var path = Path()
            path.move(to: from)
            if back {
                let dx: CGFloat = 70 + abs(from.y - to.y) * 0.08
                path.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y + 70),
                              control2: CGPoint(x: to.x + dx, y: to.y - 70))
            } else {
                let dy = max(30, (to.y - from.y) / 2)
                path.addCurve(to: to, control1: CGPoint(x: from.x, y: from.y + dy),
                              control2: CGPoint(x: to.x, y: to.y - dy))
            }
            edges.append(EdgeShape(path: path, tip: to,
                                   angle: back ? atan2(70, -(70 + abs(from.y - to.y) * 0.08)) : .pi / 2,
                                   kind: e.kind, back: back, fromID: Self.key(g.blocks[e.from]), toID: Self.key(g.blocks[e.to])))
        }
        self.size = CGSize(width: maxWidth + 80 + 160, height: y + 20)
    }

    /// Blocks in program order, one per row, indented by nesting; jumps run along the sides like in a listing.
    private mutating func nested(_ g: FunctionGraphData, succ: [[Int]], entry: Int) {
        let n = g.blocks.count
        let (idom, rpo) = GraphMath.immediateDominators(count: n, successors: succ, root: entry)
        // post-dominators: dominators of the reversed graph, from a virtual exit that every sink leads to
        var reversed = Array(repeating: [Int](), count: n + 1)
        for u in 0..<n {
            for v in succ[u] { reversed[v].append(u) }
            if succ[u].isEmpty { reversed[n].append(u) }
        }
        let ipdom = GraphMath.immediateDominators(count: n + 1, successors: reversed, root: n).idom
        func postDominates(_ u: Int, _ d: Int) -> Bool {
            var p = ipdom[d]
            var steps = 0
            while p >= 0, p != n, steps <= n {
                if p == u { return true }
                let next = ipdom[p]
                if next == p { break }
                p = next
                steps += 1
            }
            return false
        }
        var indent = Array(repeating: 0, count: n)
        for u in rpo where u != entry {
            let d = idom[u]
            guard d >= 0 else { continue }
            indent[u] = min(12, indent[d] + (postDominates(u, d) ? 0 : 1))
        }

        let rows = (0..<n).sorted { a, b in
            if g.blocks[a].entry != g.blocks[b].entry { return g.blocks[a].entry }
            return (addressValue(g.blocks[a].start) ?? 0) < (addressValue(g.blocks[b].start) ?? 0)
        }
        var rowOf = Array(repeating: 0, count: n)
        for (i, u) in rows.enumerated() { rowOf[u] = i }

        // lanes for the jumps that skip rows: forward ones on the left, backward ones on the right
        struct Jump { let from: Int; let to: Int; let kind: String; var lane = 0 }
        var forward: [Jump] = [], backward: [Jump] = [], adjacent: [Jump] = []
        for e in g.edges where e.from < n && e.to < n {
            let a = rowOf[e.from], b = rowOf[e.to]
            if b == a + 1 { adjacent.append(Jump(from: e.from, to: e.to, kind: e.kind)) }
            else if b > a { forward.append(Jump(from: e.from, to: e.to, kind: e.kind)) }
            else { backward.append(Jump(from: e.from, to: e.to, kind: e.kind)) }
        }
        func assign(_ jumps: inout [Jump]) -> Int {
            var lanes: [[ClosedRange<Int>]] = []
            jumps.sort { abs(rowOf[$0.to] - rowOf[$0.from]) < abs(rowOf[$1.to] - rowOf[$1.from]) }
            for i in jumps.indices {
                let span = min(rowOf[jumps[i].from], rowOf[jumps[i].to])...max(rowOf[jumps[i].from], rowOf[jumps[i].to])
                var lane = lanes.firstIndex { ranges in !ranges.contains { $0.overlaps(span) } } ?? lanes.count
                lane = min(lane, 15)
                if lane == lanes.count { lanes.append([]) }
                lanes[lane].append(span)
                jumps[i].lane = lane
            }
            return lanes.count
        }
        let leftLanes = assign(&forward), rightLanes = assign(&backward)
        let laneGap: CGFloat = 9
        let left = 30 + CGFloat(leftLanes) * laneGap + 16

        var rects = Array(repeating: CGRect.zero, count: n)
        var y: CGFloat = 24
        var maxRight: CGFloat = 0
        for u in rows {
            let s = Self.size(of: g.blocks[u])
            rects[u] = CGRect(x: left + CGFloat(indent[u]) * 46, y: y, width: s.width, height: s.height)
            maxRight = max(maxRight, rects[u].maxX)
            y += s.height + 34
        }
        nodes = (0..<n).map { Node(rect: rects[$0], block: g.blocks[$0]) }

        for j in adjacent {
            let s = rects[j.from], t = rects[j.to]
            let x = max(s.minX, t.minX) + 26
            edges.append(EdgeShape(path: EdgeShape.polyline([CGPoint(x: x, y: s.maxY), CGPoint(x: x, y: t.minY)]),
                                   tip: CGPoint(x: x, y: t.minY), angle: .pi / 2, kind: j.kind,
                                   fromID: Self.key(g.blocks[j.from]), toID: Self.key(g.blocks[j.to])))
        }
        for j in forward {
            let s = rects[j.from], t = rects[j.to]
            let x = left - 16 - CGFloat(j.lane) * laneGap
            let y0 = s.maxY - 10, y1 = t.minY + 10
            let tip = CGPoint(x: t.minX, y: y1)
            edges.append(EdgeShape(path: EdgeShape.polyline([CGPoint(x: s.minX, y: y0), CGPoint(x: x, y: y0),
                                                             CGPoint(x: x, y: y1), tip]),
                                   tip: tip, angle: 0, kind: j.kind, fromID: Self.key(g.blocks[j.from]), toID: Self.key(g.blocks[j.to])))
        }
        for j in backward {
            let s = rects[j.from], t = rects[j.to]
            let x = maxRight + 18 + CGFloat(j.lane) * laneGap
            let y0 = s.midY, y1 = j.from == j.to ? t.minY + 10 : t.midY
            let tip = CGPoint(x: t.maxX, y: y1)
            edges.append(EdgeShape(path: EdgeShape.polyline([CGPoint(x: s.maxX, y: y0), CGPoint(x: x, y: y0),
                                                             CGPoint(x: x, y: y1), tip]),
                                   tip: tip, angle: .pi, kind: j.kind, back: true,
                                   fromID: Self.key(g.blocks[j.from]), toID: Self.key(g.blocks[j.to])))
        }
        size = CGSize(width: maxRight + 18 + CGFloat(rightLanes) * laneGap + 60, height: y + 20)
    }
}

/// Collapses groups of blocks into single nodes (Ghidra's "group vertices").
enum GraphGrouping {
    static func apply(_ g: FunctionGraphData, _ groups: [GraphGroup]) -> FunctionGraphData {
        guard !groups.isEmpty else { return g }
        var owner: [String: Int] = [:]
        for (i, group) in groups.enumerated() {
            for member in group.members { owner[member] = i }
        }
        var newIndex = Array(repeating: 0, count: g.blocks.count)
        var blocks: [GraphBlock] = []
        var nodeOfGroup: [Int: Int] = [:]
        for (i, block) in g.blocks.enumerated() {
            guard let gi = owner[block.start] else {
                newIndex[i] = blocks.count
                blocks.append(block)
                continue
            }
            if let node = nodeOfGroup[gi] {
                newIndex[i] = node
                continue
            }
            let members = g.blocks.filter { owner[$0.start] == gi }
            let starts = members.compactMap { addressValue($0.start) }
            let first = members.min { (addressValue($0.start) ?? 0) < (addressValue($1.start) ?? 0) } ?? block
            let last = members.max { (addressValue($0.end) ?? 0) < (addressValue($1.end) ?? 0) } ?? block
            var lines = [tr("%@ bloques · %@ instrucciones", "\(members.count)", "\(members.map(\.lines.count).reduce(0, +))"),
                         "\(first.start) – \(last.end)"]
            lines += members.prefix(4).map { "· " + ($0.label ?? $0.start) }
            if members.count > 4 { lines.append("· …") }
            _ = starts
            nodeOfGroup[gi] = blocks.count
            newIndex[i] = blocks.count
            blocks.append(GraphBlock(id: 1_000_000 + gi, start: first.start, end: last.end, label: groups[gi].name,
                                     lines: lines, entry: members.contains(where: \.entry), group: groups[gi].id))
        }
        var seen = Set<GraphEdge>()
        var edges: [GraphEdge] = []
        for e in g.edges where e.from < newIndex.count && e.to < newIndex.count {
            let edge = GraphEdge(from: newIndex[e.from], to: newIndex[e.to], kind: e.kind)
            // edges inside a group disappear; parallel edges collapse into one
            if owner[g.blocks[e.from].start] != nil, edge.from == edge.to { continue }
            if seen.insert(GraphEdge(from: edge.from, to: edge.to, kind: "")).inserted { edges.append(edge) }
        }
        return FunctionGraphData(function: g.function, entry: g.entry, blocks: blocks, edges: edges, truncated: g.truncated)
    }
}

struct FunctionGraphView: View {
    @Environment(AppModel.self) private var model
    let graph: FunctionGraphData
    @State private var scale: CGFloat = 1
    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    /// Selection mode for grouping: clicks pick blocks instead of navigating.
    @State private var selecting = false
    @State private var picked = Set<String>()
    @State private var tracker = ScrollTracker()
    @AppStorage("functionGraphStyle") private var styleName = FunctionGraphStyle.layered.rawValue
    @AppStorage("graphSatellite") private var showSatellite = true
    /// off, forward, backward, cycles, fromEntry or between: which paths through the focused block are highlighted.
    @State private var pathMode = "off"
    /// The edge chosen with a click: [from, to].
    @State private var pickedEdge: [String] = []
    @State private var keyMonitor: Any?
    /// Keeps the block groups of different graphs of the same function apart (e.g. the p-code graph).
    var groupNamespace = ""

    private var style: FunctionGraphStyle { FunctionGraphStyle(rawValue: styleName) ?? .layered }
    private var groupKey: String { "\(model.program?.name ?? "")|\(graph.entry)\(groupNamespace)" }
    private var groups: [GraphGroup] { model.graphGroups[groupKey] ?? [] }

    private func key(_ b: GraphBlock) -> String { b.group?.uuidString ?? b.start }

    private var pickedGroup: GraphGroup? {
        guard picked.count == 1, let id = picked.first else { return nil }
        return groups.first { $0.id.uuidString == id }
    }

    /// Blocks covered by the current pick (picked groups count as their members).
    private var pickedMembers: [String] {
        var members: [String] = []
        for id in picked {
            if let group = groups.first(where: { $0.id.uuidString == id }) { members += group.members } else { members.append(id) }
        }
        return members
    }

    private func groupPicked() {
        let members = pickedMembers
        guard members.count >= 2 else { return }
        var list = groups.filter { !picked.contains($0.id.uuidString) }
        list.append(GraphGroup(name: tr("Grupo %@", "\(list.count + 1)"), members: members))
        model.graphGroups[groupKey] = list
        picked = []
    }

    private func ungroup(_ group: GraphGroup) {
        model.graphGroups[groupKey] = groups.filter { $0.id != group.id }
        picked = []
    }

    private func rename(_ group: GraphGroup, _ name: String) {
        var list = groups
        if let i = list.firstIndex(where: { $0.id == group.id }) {
            list[i].name = name
            model.graphGroups[groupKey] = list
        }
    }

    var body: some View {
        let shown = GraphGrouping.apply(graph, groups)
        let layout = GraphLayout(shown, style: style)
        let s = max(0.05, min(3, scale * pinch))
        let path = pathBlocks(shown)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in layout.edges { draw(e, path: path, in: &ctx) }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { point in
                    // double click on an edge: go to the block it leads to
                    if let e = edge(at: point, layout), let target = layout.nodes.first(where: { key($0.block) == e.toID }) {
                        model.selectLine(target.block.start)
                        center(on: target.rect, s)
                    }
                }
                .onTapGesture { point in
                    if let e = edge(at: point, layout) { pickedEdge = [e.fromID, e.toID] } else { pickedEdge = [] }
                }
                ForEach(layout.nodes, id: \.block.id) { node in
                    BlockView(block: node.block, selected: isSelected(node.block), picked: picked.contains(key(node.block)),
                              onPath: path.contains(key(node.block)) || pickedEdge.contains(key(node.block)),
                              tint: tint(of: node.block), breakpoint: breakpoint(in: node.block),
                              selectedLine: model.selectedAddress,
                              onLine: { address in
                                  if selecting {
                                      let id = key(node.block)
                                      if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                                  } else {
                                      // a click on a line of code selects that line; anywhere else, the block
                                      model.selectLine(address ?? node.block.start)
                                  }
                              },
                              lineMenu: { address in AnyView(lineMenu(address, node.block)) })
                        .frame(width: node.rect.width, height: node.rect.height, alignment: .topLeading)
                        .offset(x: node.rect.minX, y: node.rect.minY)
                        .contextMenu { blockMenu(node, s) }
                        .onTapGesture(count: 2) {
                            guard !selecting else { return }
                            model.selectedAddress = node.block.start
                            model.scrollRequest = ScrollRequest(address: node.block.start)
                            model.viewMode = .listing
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
        .onAppear {
            DispatchQueue.main.async { restoreView(layout, s) }
            installKeys()
        }
        .onDisappear {
            saveView()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: graph.entry) { old, _ in
            pickedEdge = []
            DispatchQueue.main.async { restoreView(layout, s) }
        }
        .onChange(of: styleName) { _, _ in
            DispatchQueue.main.async { focusEntry(GraphLayout(GraphGrouping.apply(graph, groups), style: style), s) }
        }
        .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { scale = max(0.05, min(3, scale * $0.magnification)) })
        .overlay(alignment: .bottomLeading) {
            if showSatellite, layout.nodes.count > 1 {
                SatelliteView(content: layout.size, rects: layout.nodes.map(\.rect),
                              marked: Set(layout.nodes.indices.filter { isSelected(layout.nodes[$0].block) }),
                              tracker: tracker, viewport: viewport, scale: s) { center in
                    position.scrollTo(point: CGPoint(x: max(0, center.x * s - viewport.width / 2),
                                                     y: max(0, center.y * s - viewport.height / 2)))
                }
                .padding(14)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Picker(tr("Distribución"), selection: $styleName) {
                    ForEach(FunctionGraphStyle.allCases) { item in
                        Image(systemName: item.icon).help(item.title).accessibilityLabel(item.title).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(tr("Distribución del grafo: por niveles, de izquierda a derecha o código anidado"))
                Button { showSatellite.toggle() } label: { Image(systemName: showSatellite ? "map.fill" : "map") }
                    .help(tr("Mostrar u ocultar la vista satélite"))
                    .accessibilityLabel(tr("Vista satélite"))
                Button { export(layout) } label: { Image(systemName: "square.and.arrow.up") }
                    .help(tr("Exportar el grafo (PNG, PDF, DOT, GraphML, JSON, CSV)"))
                    .accessibilityLabel(tr("Exportar…"))
                Button {
                    scale = max(0.05, min(1, min(viewport.width / layout.size.width, viewport.height / layout.size.height)))
                    position.scrollTo(point: .zero)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(tr("Ajustar a la ventana"))
                    .accessibilityLabel(tr("Ajustar a la ventana"))
                Button { focusEntry(layout, s) } label: { Image(systemName: "scope") }
                    .help(tr("Ir al bloque de entrada"))
                Button { scale = max(0.05, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = 1 } label: { Text("\(Int(s * 100)) %").font(.caption.monospacedDigit()) }
                Button { scale = min(3, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.glass)
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if let group = pickedGroup {
                    TextField(tr("Nombre del grupo"), text: Binding(get: { group.name }, set: { rename(group, $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Button(tr("Desagrupar")) { ungroup(group) }
                }
                if pickedMembers.count >= 2 && pickedGroup == nil {
                    Button(tr("Agrupar %@ bloques", "\(pickedMembers.count)")) { groupPicked() }
                        .buttonStyle(.glassProminent)
                }
                if !groups.isEmpty && picked.isEmpty {
                    Button(tr("Desagrupar todo")) { model.graphGroups[groupKey] = nil }
                }
                Button(selecting ? tr("Terminar selección") : tr("Seleccionar bloques")) {
                    selecting.toggle()
                    if !selecting { picked = [] }
                }
                .help(tr("Elige varios bloques para agruparlos en uno solo, o un grupo para deshacerlo"))
            }
            .buttonStyle(.glass)
            .padding(14)
        }
        .onChange(of: graph.entry) { _, _ in picked = [] }
        .overlay(alignment: .top) { pathControls(shown, path) }
        .overlay(alignment: .topLeading) {
            if graph.truncated {
                Label(tr("Grafo truncado: la función tiene demasiados bloques"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
        }
    }

    /// Scrolls so the entry block is centered horizontally at the top.
    private func focusEntry(_ layout: GraphLayout, _ s: CGFloat) {
        guard let entry = layout.nodes.first(where: { $0.block.entry }) ?? layout.nodes.first else { return }
        position.scrollTo(point: CGPoint(x: max(0, entry.rect.midX * s - viewport.width / 2),
                                         y: style == .horizontal ? max(0, entry.rect.midY * s - viewport.height / 2)
                                             : max(0, entry.rect.minY * s - 24)))
    }

    private func isSelected(_ b: GraphBlock) -> Bool {
        guard let sel = model.selectedAddress.flatMap(addressValue), let lo = addressValue(b.start),
              let hi = addressValue(b.end) else { return false }
        return sel >= lo && sel <= hi
    }

    private func draw(_ e: EdgeShape, path: Set<String>, in ctx: inout GraphicsContext) {
        let chosen = pickedEdge.count == 2 && e.fromID == pickedEdge[0] && e.toID == pickedEdge[1]
        let onPath = path.contains(e.fromID) && path.contains(e.toID)
        if chosen || onPath {
            let color: Color = chosen ? .orange : .accentColor
            ctx.stroke(e.path, with: .color(color), style: StrokeStyle(lineWidth: 3.2, lineJoin: .round, dash: e.back ? [7, 4] : []))
            ctx.fill(e.arrowHead(size: 12), with: .color(color))
        } else if pathMode != "off" && !path.isEmpty {
            let color = Self.color(of: e).opacity(0.25)
            ctx.stroke(e.path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round, dash: e.back ? [5, 4] : []))
            ctx.fill(e.arrowHead(), with: .color(color))
        } else {
            Self.draw(e, in: &ctx)
        }
    }

    /// The edge under a point of the canvas, with some slack.
    private func edge(at point: CGPoint, _ layout: GraphLayout) -> EdgeShape? {
        layout.edges.first { $0.path.strokedPath(StrokeStyle(lineWidth: 12)).contains(point) }
    }

    /// The block the cursor of the listing is in.
    private func focusKey(_ shown: FunctionGraphData) -> String? {
        shown.blocks.first(where: isSelected).map(key)
    }

    /// Blocks on the highlighted paths.
    private func pathBlocks(_ shown: FunctionGraphData) -> Set<String> {
        guard pathMode != "off" else { return [] }
        let keys = shown.blocks.map(key)
        var succ: [String: [String]] = [:], pred: [String: [String]] = [:]
        for e in shown.edges where e.from < keys.count && e.to < keys.count {
            succ[keys[e.from], default: []].append(keys[e.to])
            pred[keys[e.to], default: []].append(keys[e.from])
        }
        func reach(_ start: String, _ next: [String: [String]]) -> Set<String> {
            var seen: Set<String> = [start]
            var stack = [start]
            while let u = stack.popLast() {
                for v in next[u] ?? [] where seen.insert(v).inserted { stack.append(v) }
            }
            return seen
        }
        if pathMode == "between" {
            let two = Array(picked)
            guard two.count == 2 else { return [] }
            let a = reach(two[0], succ).intersection(reach(two[1], pred))
            return a.isEmpty ? reach(two[1], succ).intersection(reach(two[0], pred)) : a
        }
        guard let focus = focusKey(shown) else { return [] }
        switch pathMode {
        case "forward": return reach(focus, succ)
        case "backward": return reach(focus, pred)
        case "cycles":
            // blocks on a loop through the focused one
            var inLoop = Set<String>()
            for v in succ[focus] ?? [] {
                let back = reach(v, succ)
                if back.contains(focus) { inLoop.formUnion(back.intersection(reach(focus, pred))) }
            }
            return inLoop
        default:
            guard let entry = shown.blocks.first(where: \.entry).map(key) else { return [] }
            return reach(entry, succ).intersection(reach(focus, pred))
        }
    }

    @ViewBuilder private func pathControls(_ shown: FunctionGraphData, _ path: Set<String>) -> some View {
        HStack(spacing: 6) {
            Menu {
                Picker(tr("Caminos"), selection: $pathMode) {
                    Text(tr("Sin resaltar caminos")).tag("off")
                    Text(tr("Desde el bloque del cursor hacia delante")).tag("forward")
                    Text(tr("Hasta el bloque del cursor")).tag("backward")
                    Text(tr("De la entrada al bloque del cursor")).tag("fromEntry")
                    Text(tr("Bucles que pasan por el bloque del cursor")).tag("cycles")
                    Text(tr("Entre los dos bloques elegidos")).tag("between")
                }
                .pickerStyle(.inline)
            } label: {
                Label(pathMode == "off" ? tr("Caminos") : tr("Caminos: %@ bloques", "\(path.count)"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .fixedSize()
            if !path.isEmpty {
                Button(tr("Seleccionar el camino")) {
                    model.setSelection(ranges: shown.blocks.filter { path.contains(key($0)) }.map { [$0.start, $0.end] })
                }
                .help(tr("Crea una selección del programa con los bloques del camino"))
            }
            if pickedEdge.count == 2 {
                Button(tr("Arista: %@ → %@", label(pickedEdge[0], shown), label(pickedEdge[1], shown))) {
                    if let b = shown.blocks.first(where: { key($0) == pickedEdge[1] }) { model.selectLine(b.start) }
                }
                .help(tr("Ir al bloque de destino de la arista elegida"))
            }
        }
        .buttonStyle(.glass)
        .padding(14)
    }

    private func label(_ id: String, _ shown: FunctionGraphData) -> String {
        shown.blocks.first { key($0) == id }.map { $0.label ?? $0.start } ?? id
    }

    /// The background color the listing has at the block, if any.
    private func tint(of b: GraphBlock) -> Color? {
        guard !model.colorRanges.isEmpty, let v = addressValue(b.start),
              let c = model.colorRanges.first(where: { $0.range.contains(v) }) else { return nil }
        return Color(nsColor: Theme.rgb(c.rgb))
    }

    /// The listing's editing actions for one instruction of a block.
    @ViewBuilder private func lineMenu(_ address: String, _ b: GraphBlock) -> some View {
        Text(address)
        Button(tr("Comentario…  (;)")) { model.requestComment(address: address) }
        Button(tr("Renombrar o poner etiqueta…  (L)")) {
            model.requestRename(address: address, currentName: address == b.start ? b.label : nil)
        }
        Button(tr("Ensamblar instrucción…")) { model.selectLine(address); model.requestAssemble(address: address) }
        Button(tr("Parchear bytes…")) { model.selectLine(address); model.requestPatch(address: address) }
        Button(tr("Marcador…  (B)")) { model.requestBookmark(address: address) }
        Button(tr("Poner o quitar breakpoint  (K)")) { model.toggleBreakpoint(address: address) }
        Divider()
        Button(tr("Nombre para constante (equate)…")) { model.requestEquate(address: address) }
        Button(tr("Añadir referencia…")) { model.requestAddReference(address: address) }
        Button(tr("Referencias de esta línea…")) { model.selectLine(address); model.showTools("references") }
        Button(tr("Información de la instrucción…")) { model.selectLine(address); model.showTools("instruction") }
        Divider()
        Button(tr("Borrar código  (C)")) { model.perform("clear", address: address, namesChanged: false) }
        Button(tr("Ver en el desensamblado")) {
            model.selectedAddress = address
            model.scrollRequest = ScrollRequest(address: address)
            model.viewMode = .listing
        }
        Button(tr("Copiar la línea")) {
            if let i = b.addresses?.firstIndex(of: address), b.lines.indices.contains(i) { model.copyToPasteboard(address + "  " + b.lines[i]) }
        }
    }

    /// The listing's single keys (; L B K C…) act on the selected line of the graph.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard model.viewMode == .graph, let window = event.window, window.attachedSheet == nil,
                  window.identifier?.rawValue.hasPrefix("main") == true,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(window.firstResponder is NSText),
                  let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let key = Shortcuts.shared.codeKey(for: characters), let address = model.selectedAddress else { return event }
            var context = CodeContext()
            context.lineAddress = address
            model.handleKey(key, context: context)
            return nil
        }
    }

    @ViewBuilder private func blockMenu(_ node: GraphLayout.Node, _ s: CGFloat) -> some View {
        let b = node.block
        Button(tr("Ver en el desensamblado")) {
            model.selectedAddress = b.start
            model.scrollRequest = ScrollRequest(address: b.start)
            model.viewMode = .listing
        }
        Button(tr("Ver este bloque a tamaño real")) {
            scale = 1
            DispatchQueue.main.async { center(on: node.rect, 1) }
        }
        Button(tr("Seleccionar el bloque en el programa")) { model.setSelection(ranges: [[b.start, b.end]]) }
        Divider()
        Button(tr("Comentario…")) { model.requestComment(address: b.start) }
        Button(tr("Renombrar o poner etiqueta…")) { model.requestRename(address: b.start, currentName: b.label) }
        Menu(tr("Color de fondo")) {
            ForEach(ListingColors.all, id: \.1) { color in
                Button(color.0) { model.setColor(color.1, start: b.start, end: b.end) }
            }
            Divider()
            Button(tr("Quitar el color")) { model.setColor(nil, start: b.start, end: b.end) }
        }
        Button(breakpoint(in: b) == nil ? tr("Poner breakpoint en el bloque") : tr("Quitar el breakpoint del bloque")) {
            if let existing = breakpointAddress(in: b) { model.setBreakpoint(address: existing, state: "none") }
            else { model.setBreakpoint(address: b.start, state: "enabled") }
        }
        Divider()
        Button(tr("Caminos desde este bloque")) { model.selectLine(b.start); pathMode = "forward" }
        Button(tr("Caminos hasta este bloque")) { model.selectLine(b.start); pathMode = "backward" }
        Button(tr("Bucles por este bloque")) { model.selectLine(b.start); pathMode = "cycles" }
    }

    private func breakpointAddress(in b: GraphBlock) -> String? {
        guard let lo = addressValue(b.start), let hi = addressValue(b.end) else { return nil }
        return model.breakpointMap.keys.first { addressValue($0).map { $0 >= lo && $0 <= hi } == true }
    }

    /// true: enabled breakpoint in the block; false: disabled; nil: none.
    private func breakpoint(in b: GraphBlock) -> Bool? {
        breakpointAddress(in: b).flatMap { model.breakpointMap[$0] }
    }

    private func center(on rect: CGRect, _ s: CGFloat) {
        position.scrollTo(point: CGPoint(x: max(0, rect.midX * s - viewport.width / 2),
                                         y: max(0, rect.midY * s - viewport.height / 2)))
    }

    // MARK: saved view

    private func saveView() {
        var all = UserDefaults.standard.dictionary(forKey: "graphViews") as? [String: [Double]] ?? [:]
        if all.count > 300 { all.removeAll() }
        all[groupKey] = [Double(scale), Double(tracker.offset.x), Double(tracker.offset.y)]
        UserDefaults.standard.set(all, forKey: "graphViews")
    }

    /// Comes back to the zoom and place the function's graph was left at; the entry block the first time.
    private func restoreView(_ layout: GraphLayout, _ s: CGFloat) {
        let all = UserDefaults.standard.dictionary(forKey: "graphViews") as? [String: [Double]] ?? [:]
        if let v = all[groupKey], v.count == 3 {
            scale = max(0.05, min(3, CGFloat(v[0])))
            DispatchQueue.main.async { position.scrollTo(point: CGPoint(x: v[1], y: v[2])) }
        } else {
            focusEntry(layout, s)
        }
    }

    static func color(of e: EdgeShape) -> Color {
        switch e.kind {
        case "cond": .green
        case "false": .red
        case "jump": .blue
        default: .secondary
        }
    }

    static func draw(_ e: EdgeShape, in ctx: inout GraphicsContext) {
        let color = color(of: e)
        ctx.stroke(e.path, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round,
                                                                                dash: e.back ? [5, 4] : []))
        ctx.fill(e.arrowHead(), with: .color(color))
    }

    private func export(_ layout: GraphLayout) {
        var data = GraphExportData()
        for node in layout.nodes {
            let b = node.block
            data.nodes.append((b.group?.uuidString ?? b.start, ([b.label ?? b.start] + b.lines).joined(separator: "\n")))
        }
        let shown = GraphGrouping.apply(graph, groups)
        for e in shown.edges where e.from < shown.blocks.count && e.to < shown.blocks.count {
            let from = shown.blocks[e.from], to = shown.blocks[e.to]
            data.edges.append((from.group?.uuidString ?? from.start, to.group?.uuidString ?? to.start, e.kind))
        }
        GraphExporter.export(name: graph.function.replacingOccurrences(of: "/", with: "_"), data: data, size: layout.size) {
            ZStack(alignment: .topLeading) {
                EdgeShapesView(edges: layout.edges, size: layout.size, color: { Self.color(of: $0) }, lineWidth: 1.6)
                ForEach(layout.nodes, id: \.block.id) { node in
                    BlockView(block: node.block, selected: false)
                        .frame(width: node.rect.width, height: node.rect.height, alignment: .topLeading)
                        .offset(x: node.rect.minX, y: node.rect.minY)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .background(Color(nsColor: Theme.background))
        }
    }
}

private struct BlockView: View {
    let block: GraphBlock
    let selected: Bool
    var picked = false
    var onPath = false
    var tint: Color? = nil
    var breakpoint: Bool? = nil
    /// The line of the listing that is selected, to mark it inside the block.
    var selectedLine: String? = nil
    /// A click in the block: the address of the line under it, or nil for the title and the margins.
    var onLine: ((String?) -> Void)? = nil
    var lineMenu: ((String) -> AnyView)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((block.group != nil ? "⧉ " : "") + (block.label ?? block.start))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: Theme.label))
                .frame(height: GraphLayout.lineHeight)
            ForEach(Array(block.lines.enumerated()), id: \.offset) { index, line in
                let address = block.group == nil && (block.addresses?.indices.contains(index) ?? false) ? block.addresses?[index] : nil
                if let address, let lineMenu {
                    // a line of code: it can be selected and edited like in the listing
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: GraphLayout.lineHeight)
                        .background(selectedLine == address ? Color.accentColor.opacity(0.28) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                        .contextMenu { lineMenu(address) }
                } else {
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .frame(height: GraphLayout.lineHeight)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill((tint ?? .accentColor).opacity(tint != nil ? 0.38 : onPath ? 0.16 : 0)))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(picked ? Color.orange
                              : selected ? Color.accentColor
                              : (block.entry ? Color.purple.opacity(0.7) : Color.secondary.opacity(block.group != nil ? 0.8 : 0.35)),
                              style: StrokeStyle(lineWidth: picked ? 3 : selected ? 2.5 : (block.entry || block.group != nil ? 2 : 1),
                                                 dash: block.group != nil ? [6, 4] : []))
        )
        .overlay(alignment: .topTrailing) {
            if let breakpoint {
                Circle().fill(breakpoint ? Color.red : Color.gray).frame(width: 10, height: 10).padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(coordinateSpace: .local) { point in
            // which line was clicked comes from where the click fell: 10 points of padding, then the title, then the lines
            let index = Int(((point.y - 10) / GraphLayout.lineHeight).rounded(.down)) - 1
            let address = block.group == nil && index >= 0 && (block.addresses?.indices.contains(index) ?? false)
                ? block.addresses?[index] : nil
            onLine?(address)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .help(tr("%@ – %@\nDoble clic: ver en desensamblado", "\(block.start)", "\(block.end)"))
    }
}
