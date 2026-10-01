import SwiftUI

/// Layered layout of a function's control-flow graph (Sugiyama-style, simplified).
struct GraphLayout {
    struct Node {
        var rect: CGRect
        let block: GraphBlock
    }

    struct Edge {
        let from: CGPoint
        let to: CGPoint
        let kind: String
        let back: Bool
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var size: CGSize = .zero

    static let charWidth: CGFloat = 7.0
    static let lineHeight: CGFloat = 15
    static let hGap: CGFloat = 44
    static let vGap: CGFloat = 64

    init(_ g: FunctionGraphData) {
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

        // Sizes and coordinates.
        func size(of b: GraphBlock) -> CGSize {
            let longest = max(b.lines.map(\.count).max() ?? 0, (b.label ?? b.start).count + 2)
            return CGSize(width: max(140, CGFloat(min(longest, 70)) * Self.charWidth + 24),
                          height: CGFloat(b.lines.count + 1) * Self.lineHeight + 20)
        }
        var rects = Array(repeating: CGRect.zero, count: n)
        var y: CGFloat = 20
        var maxWidth: CGFloat = 0
        var rowWidths: [CGFloat] = []
        for row in rows {
            let sizes = row.map { size(of: g.blocks[$0]) }
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
        var outCount = Array(repeating: 0, count: n)
        var outIndex = Array(repeating: 0, count: n)
        for e in g.edges where e.from < n { outCount[e.from] += 1 }
        for e in g.edges where e.from < n && e.to < n {
            let s = rects[e.from], t = rects[e.to]
            let k = outCount[e.from]
            let i = outIndex[e.from]
            outIndex[e.from] += 1
            let px = s.minX + s.width * CGFloat(i + 1) / CGFloat(k + 1)
            edges.append(Edge(from: CGPoint(x: px, y: s.maxY), to: CGPoint(x: t.midX, y: t.minY),
                              kind: e.kind, back: backEdges.contains([e.from, e.to]) || t.minY <= s.minY))
        }
        self.size = CGSize(width: maxWidth + 80 + 160, height: y + 20)
    }
}

struct FunctionGraphView: View {
    @Environment(AppModel.self) private var model
    let graph: FunctionGraphData
    @State private var scale: CGFloat = 1
    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        let layout = GraphLayout(graph)
        let s = max(0.2, min(3, scale * pinch))
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in layout.edges { draw(e, in: &ctx) }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                ForEach(layout.nodes, id: \.block.id) { node in
                    BlockView(block: node.block, selected: isSelected(node.block))
                        .frame(width: node.rect.width, height: node.rect.height, alignment: .topLeading)
                        .offset(x: node.rect.minX, y: node.rect.minY)
                        .onTapGesture(count: 2) {
                            model.selectedAddress = node.block.start
                            model.scrollRequest = ScrollRequest(address: node.block.start)
                            model.viewMode = .listing
                        }
                        .onTapGesture { model.selectLine(node.block.start) }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: layout.size.width * s, height: layout.size.height * s, alignment: .topLeading)
        }
        .scrollPosition($position)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .onAppear { DispatchQueue.main.async { focusEntry(layout, s) } }
        .onChange(of: graph.entry) { _, _ in DispatchQueue.main.async { focusEntry(layout, s) } }
        .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { scale = max(0.2, min(3, scale * $0.magnification)) })
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Button {
                    scale = max(0.2, min(1, min(viewport.width / layout.size.width, viewport.height / layout.size.height)))
                    position.scrollTo(point: .zero)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(tr("Ajustar a la ventana"))
                Button { focusEntry(layout, s) } label: { Image(systemName: "scope") }
                    .help(tr("Ir al bloque de entrada"))
                Button { scale = max(0.2, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = 1 } label: { Text("\(Int(s * 100)) %").font(.caption.monospacedDigit()) }
                Button { scale = min(3, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.glass)
            .padding(14)
        }
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
                                         y: max(0, entry.rect.minY * s - 24)))
    }

    private func isSelected(_ b: GraphBlock) -> Bool {
        guard let sel = model.selectedAddress.flatMap(addressValue), let lo = addressValue(b.start),
              let hi = addressValue(b.end) else { return false }
        return sel >= lo && sel <= hi
    }

    private func draw(_ e: GraphLayout.Edge, in ctx: inout GraphicsContext) {
        let color: Color = switch e.kind {
        case "cond": .green
        case "false": .red
        case "jump": .blue
        default: .secondary
        }
        var path = Path()
        path.move(to: e.from)
        if e.back {
            let dx: CGFloat = 70 + abs(e.from.y - e.to.y) * 0.08
            path.addCurve(to: e.to, control1: CGPoint(x: e.from.x + dx, y: e.from.y + 70),
                          control2: CGPoint(x: e.to.x + dx, y: e.to.y - 70))
        } else {
            let dy = max(30, (e.to.y - e.from.y) / 2)
            path.addCurve(to: e.to, control1: CGPoint(x: e.from.x, y: e.from.y + dy),
                          control2: CGPoint(x: e.to.x, y: e.to.y - dy))
        }
        ctx.stroke(path, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6, dash: e.back ? [5, 4] : []))
        var arrow = Path()
        arrow.move(to: e.to)
        arrow.addLine(to: CGPoint(x: e.to.x - 5, y: e.to.y - 9))
        arrow.addLine(to: CGPoint(x: e.to.x + 5, y: e.to.y - 9))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(color))
    }
}

private struct BlockView: View {
    let block: GraphBlock
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(block.label ?? block.start)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: Theme.label))
                .frame(height: GraphLayout.lineHeight)
            ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .frame(height: GraphLayout.lineHeight)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : (block.entry ? Color.purple.opacity(0.7) : Color.secondary.opacity(0.35)),
                              lineWidth: selected ? 2.5 : (block.entry ? 2 : 1))
        )
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .help("\(block.start) – \(block.end)\nDoble clic: ver en desensamblado")
    }
}
