import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Loose JSON

/// A JSON value of any shape, for engine results that are shown as generic tables.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object((try? c.decode([String: JSONValue].self)) ?? [:]) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// What a table cell shows.
    var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): b ? "✓" : ""
        case .array(let a): a.map(\.text).joined(separator: ", ")
        case .object(let o): o.keys.sorted().map { "\($0): \(o[$0]!.text)" }.joined(separator: ", ")
        case .null: ""
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var bool: Bool { if case .bool(let b) = self { b } else { false } }
    var int: Int? { if case .number(let n) = self { Int(n) } else { nil } }
    var array: [JSONValue] { if case .array(let a) = self { a } else { [] } }
    var object: [String: JSONValue] { if case .object(let o) = self { o } else { [:] } }

    /// Order for sorting a column: numbers by value, addresses by value, the rest as text.
    func precedes(_ other: JSONValue) -> Bool {
        if case .number(let a) = self, case .number(let b) = other { return a < b }
        let x = text, y = other.text
        if let a = UInt64(x, radix: 16), let b = UInt64(y, radix: 16), x.count >= 4, y.count >= 4 { return a < b }
        return x.localizedStandardCompare(y) == .orderedAscending
    }
}

typealias JSONRow = [String: JSONValue]

// MARK: - Generic table

struct ColumnSpec: Identifiable, Hashable {
    let key: String
    let title: String
    var width: CGFloat = 150
    var mono = false
    var id: String { key }

    static func address(_ title: String = tr("Dirección"), key: String = "address") -> ColumnSpec {
        ColumnSpec(key: key, title: title, width: 110, mono: true)
    }
}

/// A row action offered in the context menu and as a button for the selected row.
struct RowAction {
    let title: String
    var symbol = "circle"
    var destructive = false
    let run: (JSONRow) -> Void
}

/// An action on the selected rows of a table (all of them at once).
struct MultiAction {
    let title: String
    var minimum = 1
    let run: ([JSONRow]) -> Void
}

/// The filter of tables and trees: terms separated by spaces must all match; "!term" must not;
/// "*" and "?" are wildcards; "column:term" looks only in that column.
struct TableFilter {
    struct Term {
        let key: String?
        let negated: Bool
        let regex: NSRegularExpression?
        let text: String
    }

    let terms: [Term]

    init(_ text: String, columns: [ColumnSpec]) {
        terms = text.split(separator: " ").compactMap { raw in
            var t = String(raw)
            var negated = false
            if t.hasPrefix("!"), t.count > 1 { negated = true; t.removeFirst() }
            var key: String?
            if let colon = t.firstIndex(of: ":"),
               let column = columns.first(where: { $0.title.localizedCaseInsensitiveCompare(t[..<colon]) == .orderedSame }) {
                key = column.key
                t = String(t[t.index(after: colon)...])
            }
            guard !t.isEmpty else { return nil }
            var regex: NSRegularExpression?
            if t.contains("*") || t.contains("?") {
                let pattern = NSRegularExpression.escapedPattern(for: t)
                    .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
                regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            }
            return Term(key: key, negated: negated, regex: regex, text: t)
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(_ row: JSONRow, keys: [String]) -> Bool {
        for term in terms {
            let hit = (term.key.map { [$0] } ?? keys).contains { key in
                guard let value = row[key]?.text else { return false }
                if let regex = term.regex {
                    return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                }
                return value.localizedCaseInsensitiveContains(term.text)
            }
            if hit == term.negated { return false }
        }
        return true
    }
}

/// A sortable, filterable table over engine rows: choose columns, copy, export to CSV, select in the program.
struct GenericTable: View {
    @Environment(AppModel.self) private var model
    let rows: [JSONRow]
    let columns: [ColumnSpec]
    /// Remembers which columns are hidden, per kind of table.
    let storageKey: String
    var addressKey: String? = "address"
    var endKey: String? = nil
    var actions: [RowAction] = []
    var multiActions: [MultiAction] = []
    var onOpen: ((JSONRow) -> Void)? = nil

    /// Rows taken out of the table by hand (they come back when the table is reloaded).
    @State private var removed = Set<Int>()
    @State private var filter = ""
    @State private var sortKey: String?
    @State private var ascending = true
    @State private var hidden = Set<String>()
    @State private var selection = Set<Int>()

    private var visibleColumns: [ColumnSpec] { columns.filter { !hidden.contains($0.key) } }

    /// Indices into `rows`, filtered and sorted.
    private var order: [Int] {
        var list = removed.isEmpty ? Array(rows.indices) : rows.indices.filter { !removed.contains($0) }
        let parsed = TableFilter(filter, columns: columns)
        if !parsed.isEmpty {
            let keys = visibleColumns.map(\.key)
            list = list.filter { parsed.matches(rows[$0], keys: keys) }
        }
        if let sortKey {
            list.sort { a, b in
                let x = rows[a][sortKey] ?? .null, y = rows[b][sortKey] ?? .null
                return ascending ? x.precedes(y) : y.precedes(x)
            }
        }
        return list
    }

    var body: some View {
        let order = order
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(tr("Filtrar (o columna:texto)"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Text(verbatim: order.count == rows.count ? "\(rows.count)" : "\(order.count) / \(rows.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let action = actions.first, selection.count == 1, let i = selection.first, rows.indices.contains(i) {
                    if actions.count > 3 {
                        // too many for buttons: one menu
                        Menu(tr("Acciones")) {
                            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                                Button(a.title, role: a.destructive ? .destructive : nil) { a.run(rows[i]) }
                            }
                        }
                        .fixedSize()
                    } else {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                            Button(a.title) { a.run(rows[i]) }
                        }
                    }
                    let _ = action
                }
                ForEach(Array(multiActions.enumerated()), id: \.offset) { _, a in
                    Button(a.title) { a.run(order.filter(selection.contains).map { rows[$0] }) }
                        .disabled(selection.count < a.minimum)
                }
                if !selection.isEmpty {
                    Button(tr("Quitar filas")) {
                        removed.formUnion(selection)
                        selection = []
                    }
                    .help(tr("Quita de la tabla las filas elegidas (no cambia el programa)"))
                }
                if addressKey != nil {
                    Button(tr("Seleccionar en el programa")) { makeSelection(order) }
                        .disabled(order.isEmpty)
                        .help(tr("Crea una selección del programa con las filas elegidas (o con todas)"))
                }
                Button(tr("Copiar")) { copy(order) }.disabled(order.isEmpty)
                Button("CSV…") { exportCSV(order) }.disabled(order.isEmpty)
                Menu {
                    ForEach(columns) { column in
                        Toggle(column.title, isOn: Binding(get: { !hidden.contains(column.key) }, set: { on in
                            if on { hidden.remove(column.key) } else { hidden.insert(column.key) }
                            UserDefaults.standard.set(Array(hidden), forKey: "columns|" + storageKey)
                        }))
                    }
                } label: { Image(systemName: "rectangle.split.3x1") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(tr("Elegir columnas"))
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(visibleColumns) { column in
                            Button {
                                if sortKey == column.key { ascending.toggle() } else { sortKey = column.key; ascending = true }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(column.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    if sortKey == column.key {
                                        Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(width: column.width, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.leading, 10)
                    .foregroundStyle(.secondary)
                    Divider()
                    List(order, id: \.self, selection: $selection) { i in
                        HStack(spacing: 0) {
                            ForEach(visibleColumns) { column in
                                Text(rows[i][column.key]?.text ?? "")
                                    .font(column.mono ? .system(.callout, design: .monospaced) : .callout)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(width: column.width, alignment: .leading)
                                    .padding(.horizontal, 6)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: Int.self) { ids in
                        if let i = ids.first, rows.indices.contains(i) {
                            if let address = addressKey.flatMap({ rows[i][$0]?.string }) {
                                Button(tr("Ir a %@", address)) { model.go(address) }
                            }
                            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                                Button(a.title, role: a.destructive ? .destructive : nil) { a.run(rows[i]) }
                            }
                            Divider()
                            Button(tr("Copiar")) { copy(Array(ids).sorted()) }
                        }
                    } primaryAction: { ids in
                        guard let i = ids.first, rows.indices.contains(i) else { return }
                        if let onOpen { onOpen(rows[i]) }
                        else if let address = addressKey.flatMap({ rows[i][$0]?.string }) { model.go(address) }
                    }
                    .frame(minWidth: visibleColumns.map { $0.width + 12 }.reduce(20, +))
                }
            }
        }
        .onAppear { hidden = Set(UserDefaults.standard.stringArray(forKey: "columns|" + storageKey) ?? []) }
        .onChange(of: rows) { _, _ in removed = []; selection = [] }
    }

    private func chosen(_ order: [Int]) -> [Int] {
        selection.isEmpty ? order : order.filter(selection.contains)
    }

    private func text(_ order: [Int], separator: String, quote: Bool) -> String {
        func cell(_ s: String) -> String {
            quote ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s.replacingOccurrences(of: "\n", with: " ")
        }
        var out = visibleColumns.map { cell($0.title) }.joined(separator: separator) + "\n"
        for i in chosen(order) {
            out += visibleColumns.map { cell(rows[i][$0.key]?.text ?? "") }.joined(separator: separator) + "\n"
        }
        return out
    }

    private func copy(_ order: [Int]) {
        model.copyToPasteboard(text(order, separator: "\t", quote: false))
    }

    private func exportCSV(_ order: [Int]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = storageKey + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text(order, separator: ",", quote: true).write(to: url, atomically: true, encoding: .utf8) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func makeSelection(_ order: [Int]) {
        guard let addressKey else { return }
        let ranges: [[String]] = chosen(order).compactMap { i in
            guard let start = rows[i][addressKey]?.string, !start.isEmpty else { return nil }
            let end = endKey.flatMap { rows[i][$0]?.string } ?? start
            return [start, end]
        }
        model.setSelection(ranges: ranges)
    }
}

// MARK: - Generic form

struct FormField: Identifiable {
    enum Kind {
        case text
        case multiline
        case choice([String])
        case toggle
        /// A password: typed by the user, never shown.
        case secure
        /// Explanatory text, not an input.
        case note
    }

    let key: String
    let title: String
    var kind = Kind.text
    var value = ""
    var placeholder = ""
    var mono = true
    var id: String { key }
}

/// A small form shown as a sheet: several fields and one action.
struct FormRequest: Identifiable {
    let id = UUID()
    let title: String
    var message: String? = nil
    var fields: [FormField]
    var actionTitle = tr("Aceptar")
    /// Which window shows the sheet: "main" or "tools".
    var origin = "main"
    /// Receives the values by key (toggles as "true" / "false").
    let submit: ([String: String]) async throws -> Void
}

struct FormSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FormRequest
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title3.weight(.semibold))
            if let message = request.message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(request.fields) { field in
                switch field.kind {
                case .note:
                    Text(field.title).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .toggle:
                    Toggle(field.title, isOn: Binding(get: { values[field.key] == "true" },
                                                      set: { values[field.key] = $0 ? "true" : "false" }))
                case .choice(let options):
                    Picker(field.title, selection: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })) {
                        ForEach(options, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                    }
                case .multiline:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.title).font(.callout)
                        TextEditor(text: binding(field.key))
                            .font(field.mono ? .body.monospaced() : .body)
                            .frame(height: 84)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                case .secure:
                    LabeledContent(field.title) {
                        SecureField(field.placeholder, text: binding(field.key))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 240)
                    }
                case .text:
                    LabeledContent(field.title) {
                        TextField(field.placeholder, text: binding(field.key))
                            .textFieldStyle(.roundedBorder)
                            .font(field.mono ? .body.monospaced() : .body)
                            .frame(minWidth: 240)
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.actionTitle) { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            for field in request.fields { values[field.key] = field.value }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func run() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await request.submit(values)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - A table fed by one engine call

/// Loads rows with an engine method and shows them in a GenericTable; reloads when the program changes.
struct EngineTable: View {
    @Environment(AppModel.self) private var model
    let method: String
    var params: [String: Any] = [:]
    let columns: [ColumnSpec]
    var addressKey: String? = "address"
    var endKey: String? = nil
    var actions: [RowAction] = []
    var multiActions: [MultiAction] = []
    var onOpen: ((JSONRow) -> Void)? = nil
    /// Changing this reloads the table (for tables that depend on the cursor).
    var reloadKey: String = ""

    @State private var rows: [JSONRow] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            GenericTable(rows: rows, columns: columns, storageKey: method, addressKey: addressKey, endKey: endKey,
                         actions: actions, multiActions: multiActions, onOpen: onOpen)
            if loading { ProgressView() }
            if let error, rows.isEmpty {
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .task(id: "\(model.activeSession ?? "")|\(model.undo?.undoName ?? "")|\(model.undo?.canUndo == true)|\(model.editCount)|\(reloadKey)") {
            await load()
        }
    }

    private func load() async {
        guard model.program != nil else { rows = []; return }
        loading = true
        defer { loading = false }
        do {
            rows = try await model.engine.call(method, params)
            error = nil
        } catch {
            rows = []
            self.error = error.localizedDescription
        }
    }
}
