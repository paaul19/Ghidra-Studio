import AppKit
import SwiftUI

/// A page of memory as the engine sends it.
struct BytePage: Codable {
    let start: String
    let bytes: [Int]
    let kinds: [Int]
    let pointers: [Bool]
    let pointerSize: Int
    let bigEndian: Bool
    let block: String?
    let blockStart: String?
    let blockEnd: String?
    let min: String?
    let max: String?
}

/// One of the views of the byte viewer, shown as a column.
enum ByteFormat: String, CaseIterable, Identifiable {
    case hex, hex2, hex4, hex8, integer, octal, binary, ascii, address, disassembled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: "Hex"
        case .hex2: tr("Hex de 2 bytes")
        case .hex4: tr("Hex de 4 bytes")
        case .hex8: tr("Hex de 8 bytes")
        case .integer: tr("Enteros")
        case .octal: "Octal"
        case .binary: tr("Binario")
        case .ascii: "ASCII"
        case .address: tr("Direcciones")
        case .disassembled: tr("Desensamblado")
        }
    }
}

/// Ghidra's byte viewer: several formats side by side, a cursor, and editing in place.
struct ByteViewerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("bytesPerLine") private var perLine = 16
    @AppStorage("bytesGroup") private var group = 1
    @AppStorage("bytesOffset") private var offset = 0
    @AppStorage("bytesFormats") private var formatNames = "hex,ascii"
    @AppStorage("bytesIntSize") private var intSize = 4
    @AppStorage("bytesIntSigned") private var intSigned = true
    @State private var page: BytePage?
    @State private var query = ""
    @State private var cursor = 0
    /// Half of the byte the next hex digit goes to (0: high, 1: low).
    @State private var nibble = 0
    @State private var editing = false
    @State private var typingText = false
    @State private var follow = true
    @State private var error: String?
    @FocusState private var focused: Bool

    private static let pageRows = 48

    private var formats: [ByteFormat] { formatNames.split(separator: ",").compactMap { ByteFormat(rawValue: String($0)) } }
    private var pageSize: Int { Self.pageRows * perLine }

    private func hex(_ value: UInt64, like template: String) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: Swift.max(0, template.count - s.count)) + s
    }

    private var startValue: UInt64 { page.flatMap { addressValue($0.start) } ?? 0 }
    private var cursorAddress: String? { page.map { hex(startValue &+ UInt64(cursor), like: $0.start) } }

    var body: some View {
        VStack(spacing: 0) {
            if model.program == nil {
                NoProgramView()
            } else {
                controls
                Divider()
                if let page {
                    header(page)
                    Divider()
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<Swift.max(1, (page.bytes.count + perLine - 1) / perLine), id: \.self) { row in
                                line(page, row)
                            }
                        }
                        .padding(8)
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            // at least as wide as the window, so short rows stay at the left
                            max(length, CGFloat(formats.map { width($0, page) + 4 }.reduce(page.start.count + 4, +)) * 7.3 + 40)
                        }
                    }
                    .background(Color(nsColor: Theme.background))
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress { press in key(press) }
                    .onAppear { focused = true }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                status
            }
        }
        .windowMinSize(760, 460)
        .task(id: "\(model.activeSession ?? "")|\(perLine)|\(offset)") { await load(model.editTarget) }
        .onChange(of: model.selectedAddress) { _, address in
            guard follow, let address, let v = addressValue(address), let page else { return }
            if v >= startValue, v < startValue + UInt64(page.bytes.count) {
                cursor = Int(v - startValue)
                nibble = 0
            } else {
                Task { await load(address) }
            }
        }
        .onChange(of: model.editCount) { _, _ in Task { await reload() } }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button { Task { await move(pages: -1) } } label: { Image(systemName: "chevron.up") }.help(tr("Página anterior"))
                Button { Task { await move(pages: 1) } } label: { Image(systemName: "chevron.down") }.help(tr("Página siguiente"))
            }
            .fixedSize()
            TextField(tr("Dirección"), text: $query).textFieldStyle(.roundedBorder).frame(width: 150).font(.body.monospaced())
                .onSubmit { Task { await go() } }
            Button(tr("Ir")) { Task { await go() } }
            Menu(tr("Vistas")) {
                ForEach(ByteFormat.allCases) { f in
                    Toggle(f.title, isOn: Binding(get: { formats.contains(f) }, set: { on in
                        var list = formats
                        if on { if !list.contains(f) { list.append(f) } } else { list.removeAll { $0 == f } }
                        if list.isEmpty { list = [.hex] }
                        // keep the order of the menu
                        formatNames = ByteFormat.allCases.filter(list.contains).map(\.rawValue).joined(separator: ",")
                    }))
                }
                Divider()
                Picker(tr("Tamaño de los enteros"), selection: $intSize) { ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) } }
                Toggle(tr("Enteros con signo"), isOn: $intSigned)
            }
            .fixedSize()
            Picker(tr("Bytes por línea"), selection: $perLine) { ForEach([8, 16, 24, 32, 48, 64], id: \.self) { Text("\($0)").tag($0) } }
                .fixedSize()
            Picker(tr("Grupo"), selection: $group) { ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
            Stepper(tr("Desplazamiento: %@", "\(offset)"), value: $offset, in: 0...Swift.max(0, perLine - 1)).fixedSize()
                .help(tr("Desplaza el comienzo de las líneas para alinear las columnas con los datos"))
            Spacer()
            Toggle(isOn: $follow) { Image(systemName: "link") }.toggleStyle(.button)
                .help(tr("Seguir el cursor de la ventana principal"))
            Toggle(tr("Editar"), isOn: $editing).toggleStyle(.button)
                .help(tr("Con la edición activa, escribir dígitos hexadecimales (o texto en la vista ASCII) cambia los bytes del programa"))
        }
        .controlSize(.small)
        .padding(8)
    }

    private func width(_ f: ByteFormat, _ page: BytePage) -> Int {
        switch f {
        case .hex: perLine * 2 + perLine / group
        case .hex2: (perLine / 2) * 5
        case .hex4: (perLine / 4) * 9
        case .hex8: (perLine / 8) * 17
        case .integer: (perLine / intSize) * (intSize == 1 ? 5 : intSize == 2 ? 7 : intSize == 4 ? 12 : 21)
        case .octal: perLine * 4
        case .binary: perLine * 9
        case .ascii: perLine
        case .address: (perLine / page.pointerSize) * (page.start.count + 1)
        case .disassembled: perLine
        }
    }

    private func header(_ page: BytePage) -> some View {
        HStack(spacing: 18) {
            Text(tr("Dirección")).frame(width: CGFloat(page.start.count) * 7.3 + 12, alignment: .leading)
            ForEach(formats) { f in
                Text(f.title).frame(width: CGFloat(width(f, page)) * 7.3 + 12, alignment: .leading)
            }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func word(_ page: BytePage, at index: Int, size: Int) -> UInt64? {
        guard index + size <= page.bytes.count else { return nil }
        var v: UInt64 = 0
        for b in 0..<size {
            let x = page.bytes[page.bigEndian ? index + b : index + size - 1 - b]
            if x < 0 { return nil }
            v = (v << 8) | UInt64(x)
        }
        return v
    }

    private func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

    private func text(_ f: ByteFormat, _ page: BytePage, _ range: Range<Int>) -> String {
        func words(_ size: Int, _ render: (UInt64) -> String, missing: String) -> String {
            stride(from: range.lowerBound, to: range.upperBound, by: size).map { i in
                word(page, at: i, size: size).map(render) ?? missing
            }.joined(separator: " ")
        }
        switch f {
        case .hex2: return words(2, { String(format: "%04llx", $0) }, missing: "????")
        case .hex4: return words(4, { String(format: "%08llx", $0) }, missing: "????????")
        case .hex8: return words(8, { String(format: "%016llx", $0) }, missing: String(repeating: "?", count: 16))
        case .integer:
            let w = intSize == 1 ? 4 : intSize == 2 ? 6 : intSize == 4 ? 11 : 20
            return words(intSize, { v in
                if intSigned {
                    let bits = UInt64(intSize * 8)
                    let signed = bits == 64 ? Int64(bitPattern: v) : (v >> (bits - 1)) & 1 == 1 ? Int64(v) - Int64(1 << bits) : Int64(v)
                    return pad(String(signed), w)
                }
                return pad(String(v), w)
            }, missing: pad("?", w))
        case .octal:
            return range.map { page.bytes[$0] < 0 ? "???" : pad(String(page.bytes[$0], radix: 8), 3).replacingOccurrences(of: " ", with: "0") }
                .joined(separator: " ")
        case .binary:
            return range.map { page.bytes[$0] < 0 ? "????????" : pad(String(page.bytes[$0], radix: 2), 8).replacingOccurrences(of: " ", with: "0") }
                .joined(separator: " ")
        case .address:
            let w = page.start.count
            return stride(from: range.lowerBound, to: range.upperBound, by: page.pointerSize).map { i in
                let slot = i / page.pointerSize
                guard i % page.pointerSize == 0, slot < page.pointers.count, page.pointers[slot],
                      let v = word(page, at: i, size: page.pointerSize) else { return String(repeating: "·", count: w) }
                return pad(String(v, radix: 16), w).replacingOccurrences(of: " ", with: "0")
            }.joined(separator: " ")
        case .disassembled:
            return range.map { page.kinds[$0] == 1 ? "■" : page.kinds[$0] == 2 ? "□" : "·" }.joined()
        default:
            return ""
        }
    }

    private func line(_ page: BytePage, _ row: Int) -> some View {
        let lo = row * perLine, hi = Swift.min(page.bytes.count, lo + perLine)
        let range = lo..<hi
        return HStack(spacing: 18) {
            Text(hex(startValue &+ UInt64(lo), like: page.start)).foregroundStyle(.secondary)
                .frame(width: CGFloat(page.start.count) * 7.3 + 12, alignment: .leading)
            ForEach(formats) { f in
                switch f {
                case .hex:
                    HStack(spacing: 0) {
                        ForEach(range, id: \.self) { i in
                            Text(page.bytes[i] < 0 ? "??" : String(format: "%02x", page.bytes[i]))
                                .foregroundStyle(page.kinds[i] == 1 ? Color.primary : page.kinds[i] == 2 ? Color.blue : Color.secondary)
                                .background(i == cursor ? Color.accentColor.opacity(typingText ? 0.25 : 0.55) : Color.clear)
                                .padding(.trailing, (i - lo + 1) % group == 0 ? 7.25 : 0)
                                .onTapGesture { cursor = i; nibble = 0; typingText = false; focused = true; tell() }
                        }
                    }
                    .frame(width: CGFloat(width(f, page)) * 7.3 + 12, alignment: .leading)
                case .ascii:
                    HStack(spacing: 0) {
                        ForEach(range, id: \.self) { i in
                            Text(page.bytes[i] >= 32 && page.bytes[i] < 127 ? String(UnicodeScalar(UInt8(page.bytes[i]))) : "·")
                                .background(i == cursor ? Color.accentColor.opacity(typingText ? 0.55 : 0.25) : Color.clear)
                                .onTapGesture { cursor = i; nibble = 0; typingText = true; focused = true; tell() }
                        }
                    }
                    .frame(width: CGFloat(width(f, page)) * 7.3 + 12, alignment: .leading)
                default:
                    Text(text(f, page, range)).frame(width: CGFloat(width(f, page)) * 7.3 + 12, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .frame(height: 17)
    }

    private var status: some View {
        HStack(spacing: 14) {
            if let page, let address = cursorAddress, cursor < page.bytes.count {
                Text(address).monospaced()
                Text(tr("Bloque: %@", page.block ?? "—"))
                if page.bytes[cursor] >= 0 {
                    Text(String(format: "0x%02x · %d · %@", page.bytes[cursor], page.bytes[cursor],
                                pad(String(page.bytes[cursor], radix: 2), 8).replacingOccurrences(of: " ", with: "0"))).monospaced()
                }
                Button(tr("Ir en el listado")) { model.go(address) }.controlSize(.small)
            }
            Spacer()
            if let error { Text(error).foregroundStyle(.red) }
            Text(editing ? tr("Edición activa: cada cambio se puede deshacer con ⌘Z") : tr("Solo lectura"))
                .foregroundStyle(editing ? Color.orange : Color.secondary)
        }
        .font(.caption)
        .padding(8)
    }

    // MARK: actions

    /// Tells the main window where the cursor is (when following).
    private func tell() {
        guard follow, let address = cursorAddress else { return }
        model.selectLine(address)
    }

    private func load(_ address: String?) async {
        guard model.program != nil else { return }
        let target = address ?? model.program?.entry ?? ""
        guard !target.isEmpty else { return }
        do {
            // start the page a few lines above, aligned to the line length (shifted by the offset)
            let v = addressValue(target) ?? 0
            let base = v >= UInt64(offset) ? (v - UInt64(offset)) / UInt64(perLine) * UInt64(perLine) + UInt64(offset) : v
            let top = base >= UInt64(8 * perLine) ? base - UInt64(8 * perLine) : base
            let loaded: BytePage = try await model.engine.call("byteView", ["address": hex(top, like: target), "length": pageSize, "align": 1])
            page = loaded
            let start = addressValue(loaded.start) ?? 0
            cursor = Int(Swift.min(UInt64(Swift.max(0, loaded.bytes.count - 1)), v >= start ? v - start : 0))
            nibble = 0
            query = target
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func reload() async {
        guard let page else { return }
        if let fresh: BytePage = try? await model.engine.call("byteView", ["address": page.start, "length": pageSize, "align": 1]) {
            self.page = fresh
        }
    }

    private func move(pages: Int) async {
        guard let page else { return }
        let delta = UInt64(pageSize)
        let next = pages > 0 ? startValue &+ delta : (startValue >= delta ? startValue - delta : 0)
        do {
            let loaded: BytePage = try await model.engine.call("byteView", ["address": hex(next, like: page.start), "length": pageSize, "align": 1])
            self.page = loaded
            cursor = Swift.min(cursor, Swift.max(0, loaded.bytes.count - 1))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func go() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            let resolved: Resolved = try await model.engine.call("resolve", ["query": text])
            await load(resolved.address)
        } catch { self.error = error.localizedDescription }
    }

    private func step(_ delta: Int) {
        guard let page else { return }
        let next = cursor + delta
        if next < 0 { Task { await move(pages: -1) }; return }
        if next >= page.bytes.count { Task { await move(pages: 1) }; return }
        cursor = next
        nibble = 0
        tell()
    }

    private func write(_ value: Int, advance: Bool) {
        guard let page, let address = cursorAddress, cursor < page.bytes.count else { return }
        let at = cursor
        Task {
            do {
                _ = try await model.engine.call("patchBytes", ["address": address, "bytes": String(format: "%02x", value)], as: JSONValue.self)
                var bytes = page.bytes
                bytes[at] = value
                self.page = BytePage(start: page.start, bytes: bytes, kinds: page.kinds, pointers: page.pointers,
                                     pointerSize: page.pointerSize, bigEndian: page.bigEndian, block: page.block,
                                     blockStart: page.blockStart, blockEnd: page.blockEnd, min: page.min, max: page.max)
                await model.afterEdit(namesChanged: false)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        if advance { step(1) }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: step(-1); return .handled
        case .rightArrow: step(1); return .handled
        case .upArrow: step(-perLine); return .handled
        case .downArrow: step(perLine); return .handled
        case .tab: typingText.toggle(); nibble = 0; return .handled
        default: break
        }
        guard editing, let page, cursor < page.bytes.count, !press.modifiers.contains(.command),
              let ch = press.characters.first else { return .ignored }
        if typingText {
            guard let ascii = ch.asciiValue, ascii >= 32, ascii < 127 else { return .ignored }
            write(Int(ascii), advance: true)
            return .handled
        }
        guard let digit = ch.hexDigitValue else { return .ignored }
        let current = Swift.max(0, page.bytes[cursor])
        if nibble == 0 {
            write((digit << 4) | (current & 0x0f), advance: false)
            nibble = 1
        } else {
            write((current & 0xf0) | digit, advance: true)
        }
        return .handled
    }
}
