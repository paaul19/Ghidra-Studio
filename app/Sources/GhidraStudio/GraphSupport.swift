import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Layout styles

/// How the control-flow graph of a function is laid out.
enum FunctionGraphStyle: String, CaseIterable, Identifiable {
    case layered, horizontal, nested

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layered: tr("Por niveles, de arriba abajo")
        case .horizontal: tr("Por niveles, de izquierda a derecha")
        case .nested: tr("Código anidado (orden del programa)")
        }
    }

    var icon: String {
        switch self {
        case .layered: "arrow.down.to.line"
        case .horizontal: "arrow.right.to.line"
        case .nested: "list.bullet.indent"
        }
    }
}

/// How call / reference / data-flow graphs are laid out.
enum NodeGraphStyle: String, CaseIterable, Identifiable {
    case layered, horizontal, circular, radial, grid, force

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layered: tr("Por niveles, de arriba abajo")
        case .horizontal: tr("Por niveles, de izquierda a derecha")
        case .circular: tr("En círculo")
        case .radial: tr("Radial, en anillos alrededor del centro")
        case .grid: tr("En cuadrícula compacta")
        case .force: tr("Por fuerzas (los nodos unidos se atraen)")
        }
    }

    var icon: String {
        switch self {
        case .layered: "arrow.down.to.line"
        case .horizontal: "arrow.right.to.line"
        case .circular: "circle.dotted"
        case .radial: "target"
        case .grid: "square.grid.3x3"
        case .force: "atom"
        }
    }
}

/// An edge ready to draw: its line and where the arrow head goes.
struct EdgeShape {
    var path: Path
    var tip: CGPoint
    /// Direction of travel at the tip, in radians.
    var angle: CGFloat
    var kind = ""
    var back = false
    var fromID = ""
    var toID = ""

    func arrowHead(size: CGFloat = 9) -> Path {
        var p = Path()
        let a = angle
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - size * cos(a) + size * 0.55 * sin(a), y: tip.y - size * sin(a) - size * 0.55 * cos(a)))
        p.addLine(to: CGPoint(x: tip.x - size * cos(a) - size * 0.55 * sin(a), y: tip.y - size * sin(a) + size * 0.55 * cos(a)))
        p.closeSubpath()
        return p
    }

    /// A line through `points` with rounded corners.
    static func polyline(_ points: [CGPoint], radius: CGFloat = 7) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for i in 1..<points.count {
            if i + 1 < points.count {
                p.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: radius)
            } else {
                p.addLine(to: points[i])
            }
        }
        return p
    }

    /// The point where the segment from the center of `rect` towards `point` leaves the rectangle.
    static func border(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - c.x, dy = point.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let tx = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let t = min(tx, ty)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }
}

enum GraphMath {
    /// Immediate dominator of every node reachable from `root` (the root is its own; -1 if unreachable).
    static func immediateDominators(count n: Int, successors succ: [[Int]], root: Int) -> (idom: [Int], order: [Int]) {
        var seen = Array(repeating: false, count: n)
        var post: [Int] = []
        var stack: [(node: Int, next: Int)] = [(root, 0)]
        seen[root] = true
        while let top = stack.last {
            if top.next < succ[top.node].count {
                stack[stack.count - 1].next += 1
                let v = succ[top.node][top.next]
                if !seen[v] {
                    seen[v] = true
                    stack.append((v, 0))
                }
            } else {
                post.append(top.node)
                stack.removeLast()
            }
        }
        let rpo = Array(post.reversed())
        var number = Array(repeating: -1, count: n)
        for (i, u) in rpo.enumerated() { number[u] = i }
        var pred = Array(repeating: [Int](), count: n)
        for u in 0..<n where seen[u] { for v in succ[u] { pred[v].append(u) } }
        var idom = Array(repeating: -1, count: n)
        idom[root] = root
        func intersect(_ x: Int, _ y: Int) -> Int {
            var a = x, b = y
            while a != b {
                while number[a] > number[b] { a = idom[a] }
                while number[b] > number[a] { b = idom[b] }
            }
            return a
        }
        var changed = true
        while changed {
            changed = false
            for u in rpo where u != root {
                var best = -1
                for p in pred[u] where idom[p] != -1 { best = best == -1 ? p : intersect(p, best) }
                if best != -1, idom[u] != best {
                    idom[u] = best
                    changed = true
                }
            }
        }
        return (idom, rpo)
    }
}

/// Edges drawn as plain shapes, for exported images (a Canvas does not line up with the nodes in a PDF).
struct EdgeShapesView: View {
    let edges: [EdgeShape]
    let size: CGSize
    let color: (EdgeShape) -> Color
    var lineWidth: CGFloat = 1.4

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(edges.enumerated()), id: \.offset) { _, e in
                e.path.stroke(color(e), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round, dash: e.back ? [5, 4] : []))
                e.arrowHead().fill(color(e))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Satellite view

/// Where a graph is scrolled to. Only the satellite view reads it, so scrolling does not redo the graph layout.
@MainActor
@Observable
final class ScrollTracker {
    var offset: CGPoint = .zero
}

/// A miniature of the whole graph with the visible part framed; click or drag to move around.
struct SatelliteView: View {
    let content: CGSize
    let rects: [CGRect]
    /// Indices of the rectangles to emphasize (selection, entry…).
    var marked = Set<Int>()
    let tracker: ScrollTracker
    /// Size of the scroll view and zoom of the graph.
    let viewport: CGSize
    let scale: CGFloat
    /// Called with the graph point that should become the center of the view.
    let onMove: (CGPoint) -> Void

    static let box = CGSize(width: 190, height: 140)

    var body: some View {
        let k = min(Self.box.width / max(1, content.width), Self.box.height / max(1, content.height))
        let size = CGSize(width: max(20, content.width * k), height: max(20, content.height * k))
        // visible part of the graph, in graph coordinates
        let visible = CGRect(x: tracker.offset.x / scale, y: tracker.offset.y / scale, width: viewport.width / scale,
                             height: viewport.height / scale)
        Canvas { ctx, _ in
            for (i, r) in rects.enumerated() {
                let m = CGRect(x: r.minX * k, y: r.minY * k, width: max(1.5, r.width * k), height: max(1.5, r.height * k))
                ctx.fill(Path(m), with: .color(marked.contains(i) ? Color.accentColor : Color.secondary.opacity(0.55)))
            }
            let v = CGRect(x: visible.minX * k, y: visible.minY * k, width: visible.width * k, height: visible.height * k)
                .intersection(CGRect(origin: .zero, size: size))
            if !v.isNull {
                ctx.fill(Path(v), with: .color(Color.accentColor.opacity(0.12)))
                ctx.stroke(Path(v), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture { location in onMove(CGPoint(x: location.x / k, y: location.y / k)) }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in onMove(CGPoint(x: value.location.x / k, y: value.location.y / k)) })
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .help(tr("Vista satélite: haz clic o arrastra para moverte por el grafo"))
        .accessibilityLabel(tr("Vista satélite"))
    }
}

// MARK: - Export

/// A graph as plain nodes and edges, to write it in the formats Ghidra exports.
struct GraphExportData {
    var nodes: [(id: String, label: String)] = []
    var edges: [(from: String, to: String, kind: String)] = []

    private func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    var dot: String {
        var out = "digraph G {\n  node [shape=box, style=rounded, fontname=\"Menlo\"];\n"
        for n in nodes { out += "  \(q(n.id)) [label=\(q(n.label))];\n" }
        for e in edges { out += "  \(q(e.from)) -> \(q(e.to))" + (e.kind.isEmpty ? "" : " [label=\(q(e.kind))]") + ";\n" }
        return out + "}\n"
    }

    var graphml: String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<graphml xmlns=\"http://graphml.graphdrawing.org/xmlns\">\n"
        out += "  <key id=\"label\" for=\"node\" attr.name=\"label\" attr.type=\"string\"/>\n"
        out += "  <key id=\"kind\" for=\"edge\" attr.name=\"kind\" attr.type=\"string\"/>\n"
        out += "  <graph id=\"G\" edgedefault=\"directed\">\n"
        for n in nodes { out += "    <node id=\"\(xml(n.id))\"><data key=\"label\">\(xml(n.label))</data></node>\n" }
        for (i, e) in edges.enumerated() {
            out += "    <edge id=\"e\(i)\" source=\"\(xml(e.from))\" target=\"\(xml(e.to))\"><data key=\"kind\">\(xml(e.kind))</data></edge>\n"
        }
        return out + "  </graph>\n</graphml>\n"
    }

    var json: String {
        let object: [String: Any] = [
            "nodes": nodes.map { ["id": $0.id, "label": $0.label] },
            "edges": edges.map { ["from": $0.from, "to": $0.to, "kind": $0.kind] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    var csv: String {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "from,to,kind\n"
        for e in edges { out += "\(cell(e.from)),\(cell(e.to)),\(cell(e.kind))\n" }
        return out
    }
}

@MainActor
enum GraphExporter {
    static let formats: [(ext: String, title: String)] = [
        ("png", "PNG"), ("pdf", "PDF"), ("dot", "Graphviz (.dot)"), ("graphml", "GraphML"), ("json", "JSON"),
        ("csv", "CSV"),
    ]

    /// Asks where to save and writes the graph as an image or as text, depending on the format chosen.
    static func export<V: View>(name: String, data: GraphExportData, size: CGSize, @ViewBuilder content: () -> V) {
        let panel = NSSavePanel()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        let label = NSTextField(labelWithString: tr("Formato:"))
        let row = NSStackView(views: [label, popup])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        // start where the last graph was exported (Downloads the first time), not wherever a binary was opened from
        let last = UserDefaults.standard.string(forKey: "graphExportDirectory")
        panel.directoryURL = last.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, var url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "graphExportDirectory")
        // the extension typed wins; otherwise the format of the pop-up
        let typed = url.pathExtension.lowercased()
        let ext = formats.contains { $0.ext == typed } ? typed : formats[max(0, popup.indexOfSelectedItem)].ext
        if typed != ext { url = url.appendingPathExtension(ext) }
        do {
            switch ext {
            case "png": try png(size: size, content: content()).write(to: url)
            case "pdf": try pdf(size: size, content: content(), to: url)
            case "dot": try data.dot.write(to: url, atomically: true, encoding: .utf8)
            case "graphml": try data.graphml.write(to: url, atomically: true, encoding: .utf8)
            case "json": try data.json.write(to: url, atomically: true, encoding: .utf8)
            default: try data.csv.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            AppModel.shared.errorMessage = error.localizedDescription
        }
    }

    static func png<V: View>(size: CGSize, content: V) throws -> Data {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        // keep very large graphs under a size every viewer can open
        renderer.scale = min(2, max(0.1, 12000 / max(size.width, size.height)))
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    static func pdf<V: View>(size: CGSize, content: V, to url: URL) throws {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        var failed = true
        renderer.render { rendered, draw in
            var box = CGRect(origin: .zero, size: rendered)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            failed = false
        }
        if failed { throw CocoaError(.fileWriteUnknown) }
    }
}
