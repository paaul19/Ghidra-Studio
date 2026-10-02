import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Color themes

/// One color of the code views that the user can change.
struct ThemeElement: Identifiable {
    let id: String
    let title: String
    let light: UInt32
    let dark: UInt32

    static var all: [ThemeElement] {
        [ThemeElement(id: "background", title: tr("Fondo"), light: 0xFFFFFF, dark: 0x1F1F24),
         ThemeElement(id: "keyword", title: tr("Palabras clave"), light: 0x9B2393, dark: 0xFF7AB2),
         ThemeElement(id: "comment", title: tr("Comentarios"), light: 0x5D6C79, dark: 0x7F8C98),
         ThemeElement(id: "type", title: tr("Tipos"), light: 0x0B4F79, dark: 0x6BDFFF),
         ThemeElement(id: "function", title: tr("Funciones"), light: 0x6C36A9, dark: 0xB281EB),
         ThemeElement(id: "constant", title: tr("Constantes"), light: 0x1C00CF, dark: 0xD9C97C),
         ThemeElement(id: "parameter", title: tr("Parámetros"), light: 0x326D74, dark: 0x78C2B3),
         ThemeElement(id: "global", title: tr("Globales"), light: 0x0F68A0, dark: 0x4EB0CC),
         ThemeElement(id: "mnemonic", title: tr("Mnemónicos"), light: 0x0B4F79, dark: 0x6BDFFF),
         ThemeElement(id: "label", title: tr("Etiquetas"), light: 0x6C36A9, dark: 0xB281EB)]
    }
}

struct ThemePreset: Identifiable {
    let id: String
    let title: String
    /// element → (light, dark)
    let colors: [String: [UInt32]]

    static var all: [ThemePreset] {
        [ThemePreset(id: "default", title: tr("Predeterminado (Xcode)"), colors: [:]),
         ThemePreset(id: "ghidra", title: tr("Ghidra clásico"), colors: [
            "background": [0xFFFFFF, 0x282828], "keyword": [0x0001E6, 0x7EAAFF], "comment": [0x6A6A6A, 0x9E9E9E],
            "type": [0x0033CC, 0x7CC7FF], "function": [0x0000FF, 0x8CA8FF], "constant": [0x008E00, 0x8FE28F],
            "parameter": [0x9B009B, 0xE08BE0], "global": [0x007373, 0x6FD3D3], "mnemonic": [0x000080, 0xA6B8FF],
            "label": [0x000080, 0xA6B8FF]]),
         ThemePreset(id: "solarized", title: "Solarized", colors: [
            "background": [0xFDF6E3, 0x002B36], "keyword": [0x859900, 0x859900], "comment": [0x93A1A1, 0x586E75],
            "type": [0xB58900, 0xB58900], "function": [0x268BD2, 0x268BD2], "constant": [0x2AA198, 0x2AA198],
            "parameter": [0x6C71C4, 0x6C71C4], "global": [0xCB4B16, 0xCB4B16], "mnemonic": [0x268BD2, 0x268BD2],
            "label": [0xD33682, 0xD33682]]),
         ThemePreset(id: "monokai", title: "Monokai", colors: [
            "background": [0xFAFAFA, 0x272822], "keyword": [0xC2185B, 0xF92672], "comment": [0x8A8A7A, 0x75715E],
            "type": [0x00838F, 0x66D9EF], "function": [0x558B2F, 0xA6E22E], "constant": [0x6A1B9A, 0xAE81FF],
            "parameter": [0xE65100, 0xFD971F], "global": [0x00838F, 0x66D9EF], "mnemonic": [0xC2185B, 0xF92672],
            "label": [0x558B2F, 0xA6E22E]]),
         ThemePreset(id: "contrast", title: tr("Alto contraste"), colors: [
            "background": [0xFFFFFF, 0x000000], "keyword": [0x7A0079, 0xFF8AD8], "comment": [0x3D4852, 0xB5C0CC],
            "type": [0x003A63, 0x9BE9FF], "function": [0x4B1D8F, 0xD2B0FF], "constant": [0x1300A8, 0xFFE98A],
            "parameter": [0x1E4F55, 0xA8F0E0], "global": [0x06466F, 0x86D8F5], "mnemonic": [0x003A63, 0x9BE9FF],
            "label": [0x4B1D8F, 0xD2B0FF]])]
    }
}

/// The colors and font of the code views: the defaults, a preset, or values changed one by one.
enum ThemeStore {
    private static var cache: [String: NSColor] = [:]
    private(set) static var overrides: [String: [UInt32]] = load()
    private(set) static var fontName: String = UserDefaults.standard.string(forKey: "codeFont") ?? ""

    private static func load() -> [String: [UInt32]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "themeColors") as? [String: [Int]] else { return [:] }
        return raw.mapValues { $0.map { UInt32(truncatingIfNeeded: $0) } }
    }

    private static func save() {
        UserDefaults.standard.set(overrides.mapValues { $0.map(Int.init) }, forKey: "themeColors")
        cache = [:]
    }

    static func color(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        if let c = cache[name] { return c }
        let pair = overrides[name]
        let c = Theme.dynamic(pair?.first ?? light, pair?.last ?? dark)
        cache[name] = c
        return c
    }

    static func value(_ element: ThemeElement, dark: Bool) -> UInt32 {
        let pair = overrides[element.id]
        return dark ? (pair?.last ?? element.dark) : (pair?.first ?? element.light)
    }

    static func set(_ element: ThemeElement, dark: Bool, _ rgb: UInt32) {
        var pair = overrides[element.id] ?? [element.light, element.dark]
        if dark { pair[1] = rgb } else { pair[0] = rgb }
        overrides[element.id] = pair
        save()
    }

    static func apply(_ preset: ThemePreset) {
        overrides = preset.colors
        save()
    }

    static func setFont(_ name: String) {
        fontName = name
        UserDefaults.standard.set(name, forKey: "codeFont")
    }

    static func font(size: Double, bold: Bool) -> NSFont {
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        }
        return .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// Theme as a file: colors and font, to share or keep.
    static func export() -> Data? {
        try? JSONSerialization.data(withJSONObject: ["colors": overrides.mapValues { $0.map { String(format: "%06x", $0) } },
                                                     "font": fontName], options: [.prettyPrinted, .sortedKeys])
    }

    static func importTheme(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = object["colors"] as? [String: [String]] else { return false }
        overrides = colors.compactMapValues { pair in
            let values = pair.compactMap { UInt32($0, radix: 16) }
            return values.count == 2 ? values : nil
        }
        save()
        setFont(object["font"] as? String ?? "")
        return true
    }
}

struct ThemeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var revision = 0
    @State private var font = ThemeStore.fontName

    private var monospaced: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch == true
        }
    }

    var body: some View {
        Form {
            Section(tr("Tema")) {
                HStack {
                    Menu(tr("Aplicar un tema")) {
                        ForEach(ThemePreset.all) { preset in
                            Button(preset.title) { ThemeStore.apply(preset); changed() }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button(tr("Exportar…")) { export() }
                    Button(tr("Importar…")) { importTheme() }
                }
            }
            Section(tr("Colores (claro · oscuro)")) {
                ForEach(ThemeElement.all) { element in
                    HStack {
                        Text(element.title)
                        Spacer()
                        ColorPicker("", selection: binding(element, dark: false), supportsOpacity: false).labelsHidden()
                        ColorPicker("", selection: binding(element, dark: true), supportsOpacity: false).labelsHidden()
                    }
                }
            }
            Section(tr("Letra del código")) {
                Picker(tr("Tipo de letra"), selection: $font) {
                    Text("SF Mono").tag("")
                    ForEach(monospaced, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: font) { _, name in ThemeStore.setFont(name); changed() }
                Text(tr("El tamaño se cambia en General o con ⌘+ y ⌘−."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(revision)
    }

    private func binding(_ element: ThemeElement, dark: Bool) -> Binding<Color> {
        Binding(get: { Color(nsColor: Theme.rgb(ThemeStore.value(element, dark: dark))) }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let rgb = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
            ThemeStore.set(element, dark: dark, rgb)
            model.themeChanged()
        })
    }

    private func changed() {
        revision += 1
        model.themeChanged()
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tema-ghidra-studio.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = ThemeStore.export() else { return }
        try? data.write(to: url)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if ThemeStore.importTheme(data) {
            font = ThemeStore.fontName
            changed()
        } else {
            model.errorMessage = tr("Ese archivo no es un tema de Ghidra Studio.")
        }
    }
}

extension AppModel {
    /// Redraws the code with the new colors or font.
    func themeChanged() {
        themeRevision += 1
        rebuildDocument()
    }
}

// MARK: - Key bindings as a file

extension Shortcuts {
    func exportBindings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "atajos-ghidra-studio.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // every action with its current shortcut, so the file documents itself
        var all: [String: String] = [:]
        for action in ShortcutAction.allCases { all[action.rawValue] = spec(action) }
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    /// Returns how many shortcuts were taken from the file (nil: not a shortcuts file).
    func importBindings() -> Int? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        var count = 0
        for action in ShortcutAction.allCases {
            guard let spec = object[action.rawValue] else { continue }
            set(action, spec)
            count += 1
        }
        return count
    }
}

// MARK: - Help

/// The help pages that come inside Ghidra's modules, opened in the browser.
@MainActor
enum HelpCenter {
    struct Page: Identifiable, Hashable {
        let module: String
        let jar: String
        /// Path inside the jar, like help/topics/CodeBrowserPlugin/CodeBrowser.htm
        let path: String
        var id: String { jar + "|" + path }
        var topic: String { path.split(separator: "/").dropFirst(2).first.map(String.init) ?? "" }
        var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ") }
    }

    private static var cached: [Page]?

    /// Help topic of each window of Studio.
    static let topics: [String: String] = [
        "main": "CodeBrowserPlugin", "types": "DataTypeManagerPlugin", "typemanager": "DataTypeManagerPlugin",
        "search": "Search", "calls": "CallTreePlugin", "scripts": "GhidraScriptMgrPlugin", "graphs": "FunctionCallGraphPlugin",
        "emulator": "Emulation", "compare": "Diff", "funccompare": "FunctionComparison", "tables": "SymbolTablePlugin",
        "vt": "VersionTrackingPlugin", "bsim": "BSim", "server": "VersionControl", "python": "PyGhidra",
        "program": "ProgramManagerPlugin", "fid": "FunctionID", "debugger": "Debugger", "bytes": "ByteViewerPlugin",
        "projecttools": "FrontEndPlugin", "snapshot": "CodeBrowserPlugin",
    ]

    static func pages() -> [Page] {
        if let cached { return cached }
        var out: [Page] = []
        let root = Bundle.main.resourceURL!.appendingPathComponent("ghidra/Ghidra")
        let fm = FileManager.default
        for group in ["Features", "Framework", "Debug", "Processors"] {
            let dir = root.appendingPathComponent(group)
            for module in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let jar = dir.appendingPathComponent("\(module)/lib/\(module).jar")
                guard fm.fileExists(atPath: jar.path) else { continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-Z1", jar.path, "help/topics/*.htm*"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { continue }
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                for line in text.split(separator: "\n") where line.hasPrefix("help/topics/") {
                    out.append(Page(module: module, jar: jar.path, path: String(line)))
                }
            }
        }
        cached = out
        return out
    }

    /// Unpacks the help of the page's module (once) and opens the page.
    static func open(_ page: Page) {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.ghidra.GhidraStudio/help/\(page.module)")
        if !FileManager.default.fileExists(atPath: cache.appendingPathComponent(page.path).path) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", page.jar, "help/*", "-d", cache.path]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
        }
        NSWorkspace.shared.open(cache.appendingPathComponent(page.path))
    }

    /// F1: the help of the window in front.
    static func openForFrontWindow() -> Bool {
        let id = NSApp.keyWindow?.identifier?.rawValue ?? "main"
        let key = topics.keys.first { id.hasPrefix($0) } ?? "main"
        guard let topic = topics[key] else { return false }
        let found = pages().filter { $0.topic == topic }
        guard let page = found.first(where: { $0.name.lowercased().contains(topic.lowercased().replacingOccurrences(of: "plugin", with: "")) })
                ?? found.first else { return false }
        open(page)
        return true
    }
}

struct HelpView: View {
    @State private var pages: [HelpCenter.Page] = []
    @State private var query = ""
    @State private var loading = true

    private var shown: [HelpCenter.Page] {
        query.isEmpty ? pages : pages.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.topic.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Buscar en los temas de ayuda"), text: $query).textFieldStyle(.roundedBorder)
                if loading { ProgressView().controlSize(.small) }
                Text("\(shown.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            List(shown) { page in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(page.name)
                        Text("\(page.module) · \(page.topic)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Abrir")) { HelpCenter.open(page) }.controlSize(.small)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { HelpCenter.open(page) }
            }
            Divider()
            Text(tr("Es la ayuda de Ghidra: describe cada función tal como la hace el motor. F1 abre el tema de la ventana que tengas delante."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .windowMinSize(620, 480)
        .task {
            pages = HelpCenter.pages().sorted { ($0.topic, $0.name) < ($1.topic, $1.name) }
            loading = false
        }
    }
}

// MARK: - Runtime information and database viewer

struct RuntimePanel: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSONRow = [:]
    @State private var tab = "properties"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Información de ejecución")) {
                Picker("", selection: $tab) {
                    Text(tr("Propiedades")).tag("properties")
                    Text(tr("Procesadores instalados")).tag("processors")
                    Text(tr("Módulos")).tag("modules")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Divider()
            GenericTable(rows: info[tab]?.array.map(\.object) ?? [],
                         columns: tab == "properties"
                             ? [ColumnSpec(key: "name", title: tr("Propiedad"), width: 200), ColumnSpec(key: "value", title: tr("Valor"), width: 620, mono: true)]
                             : tab == "processors"
                             ? [ColumnSpec(key: "processor", title: tr("Procesador"), width: 240), ColumnSpec(key: "languages", title: tr("Lenguajes"), width: 100)]
                             : [ColumnSpec(key: "name", title: tr("Módulo"), width: 220), ColumnSpec(key: "path", title: tr("Ruta"), width: 620, mono: true)],
                         storageKey: "runtime-" + tab, addressKey: nil)
        }
        .task { info = (try? await model.engine.call("runtimeInfo")) ?? [:] }
    }
}

struct DatabasePanel: View {
    @Environment(AppModel.self) private var model
    @State private var tables: [JSONRow] = []
    @State private var selected: String?
    @State private var columns: [String] = []
    @State private var rows: [JSONRow] = []
    @State private var total = 0

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(selected.map { tr("Tabla %@ · %@ registros", $0, "\(total)") } ?? tr("Base de datos del programa")) {
                if selected != nil { Button(tr("Volver a las tablas")) { selected = nil } }
            }
            Divider()
            if selected == nil {
                GenericTable(rows: tables,
                             columns: [ColumnSpec(key: "name", title: tr("Tabla"), width: 260, mono: true),
                                       ColumnSpec(key: "records", title: tr("Registros"), width: 90),
                                       ColumnSpec(key: "key", title: tr("Clave"), width: 110),
                                       ColumnSpec(key: "indexes", title: tr("Índices"), width: 60),
                                       ColumnSpec(key: "version", title: tr("Versión"), width: 60),
                                       ColumnSpec(key: "columns", title: tr("Columnas"), width: 520)],
                             storageKey: "dbTables", addressKey: nil,
                             actions: [RowAction(title: tr("Ver los registros")) { row in open(row["name"]?.text ?? "") }],
                             onOpen: { row in open(row["name"]?.text ?? "") })
            } else {
                GenericTable(rows: rows,
                             columns: [ColumnSpec(key: "key", title: tr("Clave"), width: 120, mono: true)]
                                 + columns.enumerated().map { ColumnSpec(key: "c\($0.offset)", title: $0.element, width: 160, mono: true) },
                             storageKey: "dbRecords", addressKey: nil)
            }
        }
        .task(id: "\(model.activeSession ?? "")|\(model.editCount)") { tables = (try? await model.engine.call("dbTables")) ?? [] }
    }

    private func open(_ name: String) {
        Task {
            guard let result: JSONRow = try? await model.engine.call("dbRecords", ["table": name, "limit": 1000]) else { return }
            columns = result["columns"]?.array.map(\.text) ?? []
            rows = result["rows"]?.array.map(\.object) ?? []
            total = result["total"]?.int ?? rows.count
            selected = name
        }
    }
}
