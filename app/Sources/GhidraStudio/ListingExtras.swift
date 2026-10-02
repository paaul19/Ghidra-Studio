import AppKit
import SwiftUI

// MARK: - Overview bar

/// The bar at the right of the code that stands for the whole program (Ghidra's overview and navigation markers):
/// what each part contains, the cursor, bookmarks, unsaved changes and the selection. Click to go there.
struct OverviewBar: View {
    @Environment(AppModel.self) private var model
    let overview: ProgramOverview

    static let width: CGFloat = 18

    static func color(kind: Int) -> Color {
        switch kind {
        case 0: Color(nsColor: Theme.dynamic(0xC9B8E8, 0x6A4C9C))      // function
        case 1: Color(nsColor: Theme.dynamic(0xF2A6C4, 0xA3476B))      // instruction outside a function
        case 2: Color(nsColor: Theme.dynamic(0x9CCBF0, 0x2F6F9F))      // data
        case 3: Color(nsColor: Theme.dynamic(0xE3E3E6, 0x3A3A40))      // undefined
        case 4: Color(nsColor: Theme.dynamic(0xF4F4F6, 0x2A2A2E))      // uninitialized
        default: Color(nsColor: Theme.dynamic(0xF6D9A8, 0x8A6A2A))     // external
        }
    }

    static let legend: [(Int, String)] = [
        (0, "Función"), (1, "Instrucción fuera de función"), (2, "Datos"), (3, "Sin definir"),
        (4, "Sin inicializar"), (5, "Externo"),
    ]

    var body: some View {
        Canvas { ctx, size in
            let h = size.height, w = size.width
            let n = overview.kinds.count
            guard n > 0, h > 0 else { return }
            if model.listingOptions.overviewColors {
                // merge consecutive slices of the same kind into one rectangle
                var i = 0
                while i < n {
                    var j = i
                    while j + 1 < n, overview.kinds[j + 1] == overview.kinds[i] { j += 1 }
                    let y0 = h * CGFloat(i) / CGFloat(n), y1 = h * CGFloat(j + 1) / CGFloat(n)
                    ctx.fill(Path(CGRect(x: 0, y: y0, width: w, height: max(1, y1 - y0))),
                             with: .color(Self.color(kind: overview.kinds[i])))
                    i = j + 1
                }
            }
            // memory block boundaries
            for r in overview.ranges where r.offset > 0 {
                let y = h * CGFloat(r.offset) / CGFloat(overview.total)
                ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: 0.5)), with: .color(.secondary.opacity(0.6)))
            }
            // unsaved changes, on the left edge
            for change in overview.changes {
                guard let a = overview.fraction(change.start), let b = overview.fraction(change.end) else { continue }
                ctx.fill(Path(CGRect(x: 0, y: h * a, width: 4, height: max(2, h * (b - a)))), with: .color(.green))
            }
            // program selection
            if let selection = model.programSelection {
                for pair in selection.ranges.prefix(2000) where pair.count == 2 {
                    guard let a = overview.fraction(pair[0]), let b = overview.fraction(pair[1]) else { continue }
                    ctx.fill(Path(CGRect(x: 4, y: h * a, width: w - 8, height: max(2, h * (b - a)))),
                             with: .color(Color.green.opacity(0.55)))
                }
            }
            // bookmarks, on the right edge
            for bookmark in model.bookmarks.prefix(3000) {
                guard let f = overview.fraction(bookmark.address) else { continue }
                ctx.fill(Path(CGRect(x: w - 6, y: h * f - 1, width: 6, height: 3)),
                         with: .color(bookmark.isBreakpoint ? .red : .orange))
            }
            // cursor
            if let address = model.selectedAddress ?? model.current?.address, let f = overview.fraction(address) {
                let y = h * f
                ctx.fill(Path(CGRect(x: 0, y: y - 1, width: w, height: 2)), with: .color(.primary))
                var tip = Path()
                tip.move(to: CGPoint(x: 0, y: y - 4))
                tip.addLine(to: CGPoint(x: 5, y: y))
                tip.addLine(to: CGPoint(x: 0, y: y + 4))
                tip.closeSubpath()
                ctx.fill(tip, with: .color(.primary))
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in go(to: location.y / max(1, geo.size.height)) }
                    .gesture(DragGesture(minimumDistance: 2).onEnded { value in
                        go(to: value.location.y / max(1, geo.size.height))
                    })
            }
        }
        .help(helpText)
        .contextMenu {
            Toggle(tr("Colorear según el contenido"), isOn: Binding(get: { model.listingOptions.overviewColors },
                                                                    set: { model.listingOptions.overviewColors = $0 }))
            Button(tr("Ocultar la barra de vista general")) { model.listingOptions.showOverview = false }
        }
        .accessibilityLabel(tr("Vista general del programa"))
    }

    private var helpText: String {
        tr("Vista general del programa. Haz clic para ir a esa parte.") + "\n"
            + Self.legend.map { "■ " + tr($0.1) }.joined(separator: " · ") + "\n"
            + tr("Naranja: marcadores · Verde a la izquierda: cambios sin guardar · Banda verde: selección")
    }

    private func go(to fraction: CGFloat) {
        let n = overview.starts.count
        guard n > 0 else { return }
        let index = min(n - 1, max(0, Int(fraction * CGFloat(n))))
        model.go(overview.starts[index])
    }
}

/// Entropy of each part of the program (0: uniform, 8: looks random — compressed or encrypted).
struct EntropyBar: View {
    @Environment(AppModel.self) private var model
    let values: [Double]
    let starts: [String]

    static func color(_ entropy: Double) -> Color {
        if entropy < 0 { return .clear }
        // low: blue; text-like: green; code: yellow; packed: red
        return Color(hue: max(0, 0.66 - 0.66 * entropy / 8), saturation: 0.75, brightness: 0.9)
    }

    var body: some View {
        Canvas { ctx, size in
            let n = values.count
            guard n > 0 else { return }
            for (i, v) in values.enumerated() where v >= 0 {
                let y0 = size.height * CGFloat(i) / CGFloat(n), y1 = size.height * CGFloat(i + 1) / CGFloat(n)
                ctx.fill(Path(CGRect(x: 0, y: y0, width: size.width, height: max(1, y1 - y0))), with: .color(Self.color(v)))
            }
        }
        .frame(width: 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        guard !starts.isEmpty else { return }
                        let i = min(starts.count - 1, max(0, Int(location.y / max(1, geo.size.height) * CGFloat(starts.count))))
                        model.go(starts[i])
                    }
            }
        }
        .help(tr("Entropía del programa. Azul: baja · verde y amarillo: texto y código · rojo: comprimido o cifrado"))
        .accessibilityLabel(tr("Barra de entropía"))
    }
}

// MARK: - Selection bar

/// Shown under the code while there is a program selection: what is selected and what can be done with it.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let selection: ProgramSelection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed").foregroundStyle(.green)
            Text(tr("%@ direcciones seleccionadas en %@ rangos", "\(selection.addresses)", "\(selection.rangeCount)")
                 + (selection.truncated ? " " + tr("(se muestran los primeros %@)", "\(selection.ranges.count)") : ""))
                .font(.callout)
                .lineLimit(1)
            Spacer()
            ControlGroup {
                Button { model.goToSelectionRange(next: false) } label: { Image(systemName: "chevron.up") }
                    .help(tr("Rango anterior de la selección"))
                Button { model.goToSelectionRange(next: true) } label: { Image(systemName: "chevron.down") }
                    .help(tr("Rango siguiente de la selección"))
            }
            .fixedSize()
            Button(tr("Desensamblar")) { model.selectionAction("disassemble") }
            Button(tr("Borrar código")) { model.selectionAction("clear") }
            Button(tr("Marcar")) { model.selectionAction("bookmark") }
                .help(tr("Añade un marcador al principio de cada rango"))
            Button(tr("Invertir")) { model.select("complement") }
                .help(tr("Selecciona todo lo que no está seleccionado"))
            Button { model.clearProgramSelection() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("Quitar la selección"))
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The entries of Ghidra's Select menu: (engine kind, title). "-" is a separator.
enum SelectMenu {
    static var items: [(String, String)] {
        [
            ("function", tr("La función")),
            ("subroutine", tr("La subrutina")),
            ("-", ""),
            ("flowFrom", tr("Todo el flujo desde aquí")),
            ("flowTo", tr("Todo el flujo hasta aquí")),
            ("limitedFlowFrom", tr("Flujo desde aquí sin seguir llamadas")),
            ("limitedFlowTo", tr("Flujo hasta aquí sin seguir llamadas")),
            ("-", ""),
            ("forwardRefs", tr("Lo que referencia (referencias hacia delante)")),
            ("backRefs", tr("Quien lo referencia (referencias hacia atrás)")),
            ("-", ""),
            ("instructions", tr("Instrucciones")),
            ("data", tr("Datos definidos")),
            ("undefined", tr("Bytes sin definir")),
            ("deadSubroutines", tr("Subrutinas sin referencias")),
            ("changes", tr("Cambios sin guardar")),
            ("-", ""),
            ("all", tr("Todo el programa")),
            ("complement", tr("Invertir la selección")),
        ]
    }
}

// MARK: - Extra code windows

/// An independent code window (Ghidra's snapshot): its own location, history and view, on the same program.
struct SnapshotView: View {
    @Environment(AppModel.self) private var model
    let spec: SnapshotSpec

    @State private var mode: String
    @State private var location: Location?
    @State private var selected: String?
    @State private var scroll: ScrollRequest?
    @State private var document: CodeDocument?
    @State private var title = ""
    @State private var error: String?
    @State private var back: [Location] = []
    @State private var forward: [Location] = []
    @State private var query = ""
    @State private var loading = false
    @State private var decompiled: Decompilation?
    /// Follow the main window's location instead of keeping its own.
    @State private var follows = false

    /// Shown inside the main window, next to the main view.
    var embedded = false

    init(spec: SnapshotSpec, follows: Bool = false, embedded: Bool = false) {
        self.spec = spec
        self.embedded = embedded
        _mode = State(initialValue: spec.mode)
        _follows = State(initialValue: follows)
    }

    private var isOpen: Bool { model.tabs.contains { $0.id == spec.session } }
    private var programName: String { model.tabs.first { $0.id == spec.session }?.name ?? spec.session }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ControlGroup {
                    Button { step(back: true) } label: { Image(systemName: "chevron.backward") }
                        .disabled(back.isEmpty)
                    Button { step(back: false) } label: { Image(systemName: "chevron.forward") }
                        .disabled(forward.isEmpty)
                }
                .fixedSize()
                Picker("", selection: $mode) {
                    Text(tr("Descompilado")).tag("decompiler")
                    Text(tr("Desensamblado")).tag("listing")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField(tr("Dirección o símbolo"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 120, maxWidth: 240)
                    .onSubmit { navigate(query) }
                Text(title).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Toggle(isOn: $follows) { Image(systemName: "link") }
                    .toggleStyle(.button)
                    .help(tr("Seguir la posición de la ventana principal"))
                Button { showInMain() } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(tr("Mostrar esta posición en la ventana principal"))
                    .disabled(location == nil)
            }
            .padding(8)
            Divider()
            ZStack {
                Color(nsColor: Theme.background)
                if !isOpen {
                    ContentUnavailableView(tr("Programa cerrado"), systemImage: "xmark.rectangle",
                                           description: Text(tr("«%@» ya no está abierto.", programName)))
                } else if let error {
                    ContentUnavailableView(tr("No disponible"), systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let document {
                    codeView(document)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(minWidth: embedded ? 280 : 560, minHeight: embedded ? 200 : 360)
        .sheet(item: model.formBinding(origin)) { request in FormSheet(request: request) }
        .modifier(SnapshotTitle(title: embedded ? nil : tr("%@ · vista adicional", programName)))
        .task { await show(Location(address: spec.address, function: nil), resolve: true) }
        // a window restored before its program was reopened starts when the program comes back
        .onChange(of: isOpen) { _, open in
            if open, location == nil { Task { await show(Location(address: spec.address, function: nil), resolve: true) } }
        }
        .onChange(of: mode) { _, _ in Task { await reload() } }
        .onChange(of: model.fontSize) { _, _ in Task { await reload() } }
        .onChange(of: model.listingOptions) { _, _ in Task { await reload() } }
        // edits made anywhere change the undo state: refresh what this window shows
        .onChange(of: model.undo) { _, _ in Task { await reload() } }
        .onChange(of: model.selectedAddress) { _, address in
            guard follows, model.activeSession == spec.session, let address else { return }
            Task { await show(Location(address: address, function: nil), resolve: true, record: false) }
        }
    }

    private func codeView(_ document: CodeDocument) -> some View {
        let active = model.activeSession == spec.session
        return CodeTextView(document: document, highlightAddress: selected, scrollRequest: scroll,
                                 selection: active ? model.programSelection : nil,
                                 breakpoints: active ? model.breakpointMap : [:],
                                 pcAddress: active ? model.debugPC : nil,
                                 secondary: mode == "decompiler" ? model.secondaryHighlights : [:],
                                 cross: active ? model.crossHighlight : [],
                                 isPrimary: false,
                                 onNavigate: { navigate($0) },
                                 onSelectLine: { address in
                                     selected = address
                                     if model.activeSession == spec.session {
                                         model.crossSelect(address, lines: mode == "decompiler" ? decompiled?.lines : nil)
                                     }
                                 },
                                 menuActions: { ctx in menu(ctx) })
    }

    private var origin: String { "snapshot:\(spec.id.uuidString)" }

    /// An edit made from this window, on this window's program.
    private func edit(_ method: String, _ params: [String: Any], namesChanged: Bool = false) {
        Task {
            do {
                let _: JSONValue = try await call(method, params)
                if model.activeSession == spec.session { await model.afterEdit(namesChanged: namesChanged) }
                await reload()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func ask(_ title: String, field: String, value: String = "", multiline: Bool = false,
                     _ submit: @escaping (String) -> (String, [String: Any])) {
        model.formRequest = FormRequest(
            title: title,
            fields: [FormField(key: "v", title: field, kind: multiline ? .multiline : .text, value: value)],
            origin: origin) { values in
                let (method, params) = submit(values["v"] ?? "")
                var p = params
                p["session"] = spec.session
                _ = try await model.engine.call(method, p, as: JSONValue.self)
                if model.activeSession == spec.session { await model.afterEdit(namesChanged: true) }
                await reload()
            }
    }

    private func call<T: Decodable>(_ method: String, _ params: [String: Any]) async throws -> T {
        var p = params
        p["session"] = spec.session
        return try await model.engine.call(method, p)
    }

    private func navigate(_ text: String) {
        let target = text.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        Task { await show(Location(address: target, function: nil), resolve: true) }
    }

    private func step(back goBack: Bool) {
        guard let target = goBack ? back.popLast() : forward.popLast() else { return }
        if let location {
            if goBack { forward.append(location) } else { back.append(location) }
        }
        Task { await show(target, resolve: false, record: false) }
    }

    private func show(_ target: Location, resolve: Bool, record: Bool = true) async {
        guard isOpen else { return }
        var next = target
        if resolve {
            do {
                let r: Resolved = try await call("resolve", ["query": target.address])
                next = Location(address: r.address, function: r.function)
            } catch {
                // keep what is on screen; only a window with nothing to show turns into an error page
                if location == nil { self.error = error.localizedDescription } else {
                    model.errorMessage = error.localizedDescription
                    query = location?.address ?? ""
                }
                return
            }
        }
        if record, let location, location != next {
            back.append(location)
            forward.removeAll()
        }
        location = next
        selected = next.address
        query = next.address
        await reload()
        scroll = ScrollRequest(address: next.address)
    }

    private func reload() async {
        guard isOpen, let location else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            if mode == "decompiler" {
                guard let entry = location.function else {
                    document = nil
                    error = tr("La dirección %@ no pertenece a ninguna función.", "\(location.address)")
                    title = location.address
                    return
                }
                let result: Decompilation = try await call("decompile", ["address": entry])
                decompiled = result
                document = DocumentBuilder.decompiler(result, fontSize: model.fontSize)
            } else {
                let result: Listing = try await call("listing", ["address": location.address, "count": 600])
                document = DocumentBuilder.listing(result, fontSize: model.fontSize, options: model.listingOptions)
                title = result.signature ?? location.address
            }
            if mode == "decompiler", let entry = location.function {
                title = model.activeSession == spec.session
                    ? (model.functions.first { $0.address == entry }?.name ?? entry) : entry
            }
        } catch {
            document = nil
            self.error = error.localizedDescription
        }
    }

    private func showInMain() {
        guard let address = selected ?? location?.address else { return }
        if model.activeSession != spec.session { model.activate(spec.session) }
        model.go(address)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }

    private func menu(_ ctx: CodeContext) -> [CodeMenuAction] {
        var a: [CodeMenuAction] = []
        if let target = ctx.target {
            a.append(.init(title: tr("Ir a %@", "\(ctx.targetText ?? target)"), symbol: "arrow.right.circle") { navigate(target) })
        }
        if let line = ctx.lineAddress {
            a.append(.init(title: tr("Mostrar en la ventana principal"), symbol: "arrow.up.forward.app") {
                selected = line
                showInMain()
            })
            a.append(.init(title: tr("Copiar dirección %@", "\(line)"), symbol: "number") { model.copyToPasteboard(line) })
            a.append(.init(title: tr("Comentario…"), symbol: "text.bubble") {
                ask(tr("Comentario en %@", line), field: tr("Texto (vacío lo quita)"), multiline: true) {
                    ("comment", ["address": line, "kind": "eol", "text": $0])
                }
            })
            a.append(.init(title: tr("Renombrar o poner etiqueta…"), symbol: "tag") {
                ask(tr("Nombre en %@", line), field: tr("Nombre")) { ("rename", ["address": line, "name": $0]) }
            })
            a.append(.init(title: tr("Añadir marcador…"), symbol: "bookmark") {
                ask(tr("Marcador en %@", line), field: tr("Descripción")) { ("addBookmark", ["address": line, "comment": $0]) }
            })
            if mode == "listing" {
                a.append(.init(title: tr("Desensamblar aquí"), symbol: "cpu") { edit("disassemble", ["address": line]) })
                a.append(.init(title: tr("Crear función aquí"), symbol: "function") {
                    edit("createFunction", ["address": line], namesChanged: true)
                })
                a.append(.init(title: tr("Definir dato…"), symbol: "square.stack.3d.up") {
                    ask(tr("Dato en %@", line), field: tr("Tipo"), value: "int") { ("createData", ["address": line, "type": $0]) }
                })
                a.append(.init(title: tr("Borrar código o dato"), symbol: "eraser") { edit("clear", ["address": line]) })
            }
        }
        return a
    }
}

/// The window title of an extra view; nothing when the view is embedded in the main window.
private struct SnapshotTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title { content.navigationTitle(title) } else { content }
    }
}
