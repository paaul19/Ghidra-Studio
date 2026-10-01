import AppKit

/// Rendered code for CodeTextView: attributed text plus a line → address map.
struct CodeDocument {
    let id = UUID()
    let text: NSAttributedString
    let lineAddresses: [String?]
    let lineStarts: [Int]
    /// When true, highlight the closest line at or before the selected address (decompiler).
    let fuzzyHighlight: Bool
    /// Keep the top visible line in place when replacing the text (chunked loading).
    var preservesScroll = false
    var isFullListing = false

    func lineIndex(at charIndex: Int) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func range(ofLine i: Int) -> NSRange {
        let start = lineStarts[i]
        let end = i + 1 < lineStarts.count ? lineStarts[i + 1] : text.length
        return NSRange(location: start, length: max(0, end - start))
    }

    func lines(matching address: String) -> [Int] {
        let exact = lineAddresses.indices.filter { lineAddresses[$0] == address }
        if !exact.isEmpty || !fuzzyHighlight { return exact }
        guard let target = addressValue(address) else { return [] }
        var best: (Int, UInt64)?
        for (i, a) in lineAddresses.enumerated() {
            guard let a, let v = addressValue(a), v <= target else { continue }
            if best == nil || v > best!.1 { best = (i, v) }
        }
        guard let best else { return [] }
        return lineAddresses.indices.filter { lineAddresses[$0] == lineAddresses[best.0] }
    }
}

enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    // Palette modeled on Xcode's default light/dark themes
    static let keyword = dynamic(0x9B2393, 0xFF7AB2)
    static let comment = dynamic(0x5D6C79, 0x7F8C98)
    static let type = dynamic(0x0B4F79, 0x6BDFFF)
    static let function = dynamic(0x6C36A9, 0xB281EB)
    static let variable = NSColor.labelColor
    static let constant = dynamic(0x1C00CF, 0xD9C97C)
    static let parameter = dynamic(0x326D74, 0x78C2B3)
    static let global = dynamic(0x0F68A0, 0x4EB0CC)
    static let error = NSColor.systemRed
    static let special = NSColor.systemOrange
    static let address = NSColor.secondaryLabelColor
    static let bytes = NSColor.tertiaryLabelColor
    static let mnemonic = dynamic(0x0B4F79, 0x6BDFFF)
    static let label = dynamic(0x6C36A9, 0xB281EB)
    static let background = dynamic(0xFFFFFF, 0x1F1F24)
    static let lineHighlight = NSColor.controlAccentColor.withAlphaComponent(0.18)
    static let wordHighlight = NSColor.systemYellow.withAlphaComponent(0.35)

    static func color(forSyntax s: Int) -> NSColor {
        switch s {
        case 0: keyword
        case 1: comment
        case 2: type
        case 3: function
        case 4: variable
        case 5: constant
        case 6: parameter
        case 7: global
        case 9: error
        case 10: special
        default: .labelColor
        }
    }
}

extension NSAttributedString.Key {
    /// Name of the decompiler local variable a run of text refers to.
    static let studioVariable = NSAttributedString.Key("studioVariable")
}

final class DocumentBuilder {
    static let linkPrefix = "ghidra:"

    private let text = NSMutableAttributedString()
    private var lineAddresses: [String?] = []
    private var lineStarts: [Int] = []
    private let font: NSFont
    private let boldFont: NSFont
    private let paragraph: NSParagraphStyle
    private var lineOpen = false

    init(fontSize: Double) {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.18
        paragraph = p
    }

    func line(_ address: String?) {
        if lineOpen { end() }
        lineStarts.append(text.length)
        lineAddresses.append(address)
        lineOpen = true
    }

    func add(_ s: String, _ color: NSColor, bold: Bool = false, link: String? = nil, variable: String? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? boldFont : font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let link { attrs[.link] = Self.linkPrefix + link }
        if let variable { attrs[.studioVariable] = variable }
        text.append(NSAttributedString(string: s, attributes: attrs))
    }

    private func end() {
        add("\n", .labelColor)
        lineOpen = false
    }

    func build(fuzzy: Bool = false) -> CodeDocument {
        if lineOpen { end() }
        return CodeDocument(text: text, lineAddresses: lineAddresses, lineStarts: lineStarts, fuzzyHighlight: fuzzy)
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Decompiler

    static func decompiler(_ d: Decompilation, fontSize: Double) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        var lines = d.lines
        while let first = lines.first, first.tokens.isEmpty { lines.removeFirst() }
        for line in lines {
            b.line(line.addr)
            if line.indent > 0 { b.add(String(repeating: " ", count: line.indent * 2), .labelColor) }
            for token in line.tokens {
                let isNavigable = token.k == "func" || token.k == "var" || token.k == "label"
                b.add(token.t, Theme.color(forSyntax: token.s), bold: token.k == "func" && token.target == d.entry,
                      link: isNavigable ? token.target : nil, variable: token.v)
            }
        }
        return b.build(fuzzy: true)
    }

    // MARK: - Listing

    static func listing(_ l: Listing, fontSize: Double) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        let addrWidth = (l.rows.map(\.address.count).max() ?? 8) + 2

        if let signature = l.signature, let entry = l.entry {
            b.line(entry)
            b.add("// ", Theme.comment)
            b.add(signature, Theme.function, bold: true)
            b.line(entry)
        }

        for row in l.rows {
            b.row(row, addrWidth: addrWidth)
        }
        return b.build()
    }

    static func fullListing(_ rows: [ListingRow], fontSize: Double, preservesScroll: Bool) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        let addrWidth = (rows.map(\.address.count).max() ?? 8) + 2
        let rule = String(repeating: "─", count: 72)
        for row in rows {
            if let block = row.blockStart {
                b.line(row.address)
                b.line(row.address)
                b.add("// ═══ Segmento \(block) ", Theme.special, bold: true)
                b.add(String(repeating: "═", count: 40), Theme.special)
                b.line(row.address)
            }
            if let signature = row.fnStart {
                b.line(row.address)
                b.line(row.address)
                b.add("// " + rule, Theme.comment)
                b.line(row.address)
                b.add("// ƒ  ", Theme.comment)
                b.add(signature, Theme.function, bold: true)
                b.line(row.address)
                b.add("// " + rule, Theme.comment)
            }
            b.row(row, addrWidth: addrWidth)
        }
        var doc = b.build()
        doc.preservesScroll = preservesScroll
        doc.isFullListing = true
        return doc
    }

    private func row(_ row: ListingRow, addrWidth: Int) {
        let b = self
        let pad = Self.pad
        do {
            if let plate = row.plate, !plate.isEmpty {
                for text in plate.split(separator: "\n", omittingEmptySubsequences: false) {
                    b.line(row.address)
                    b.add(pad("", addrWidth) + "/* \(text) */", Theme.comment)
                }
            }
            if let label = row.label {
                b.line(row.address)
                b.add(pad("", addrWidth), .labelColor)
                b.add(label + ":", Theme.label, bold: true)
                if row.xrefs > 0 { b.add("    ← \(row.xrefs) ref\(row.xrefs == 1 ? "" : "s")", Theme.bytes) }
            }
            if let pre = row.pre, !pre.isEmpty {
                for text in pre.split(separator: "\n") {
                    b.line(row.address)
                    b.add(pad("", addrWidth) + "; \(text)", Theme.comment)
                }
            }

            b.line(row.address)
            b.add(pad(row.address, addrWidth), Theme.address)
            b.add(pad(row.bytes, 26), Theme.bytes)
            let mnemonicColor: NSColor = row.kind == "code" ? Theme.mnemonic : (row.kind == "data" ? Theme.type : Theme.bytes)
            b.add(pad(row.mnemonic, 10), mnemonicColor, bold: row.flow == "call" || row.flow == "return")
            for (i, op) in row.operands.enumerated() {
                if i > 0 { b.add(", ", .labelColor) }
                if let target = op.target {
                    b.add(op.text, Theme.global, link: target)
                } else {
                    b.add(op.text, op.text.hasPrefix("#") || op.text.hasPrefix("0x") ? Theme.constant : .labelColor)
                }
            }
            if let eol = row.eol, !eol.isEmpty {
                b.add("    ; " + eol.replacingOccurrences(of: "\n", with: " "), Theme.comment)
            }
            if let rep = row.repeatable, !rep.isEmpty {
                b.add("    ; " + rep.replacingOccurrences(of: "\n", with: " "), Theme.comment)
            }
            if let mark = row.bookmark {
                b.add("    ⚑ " + mark, Theme.special)
            }

            if let post = row.post, !post.isEmpty {
                for text in post.split(separator: "\n") {
                    b.line(row.address)
                    b.add(pad("", addrWidth) + "; \(text)", Theme.comment)
                }
            }
            if row.flow == "return" {
                b.line(row.address)
            }
        }
    }

    // MARK: - Hex

    static func hex(_ h: HexDump, fontSize: Double) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        let base = addressValue(h.start) ?? 0
        let width = max(h.start.count, 8)
        func fmt(_ v: UInt64) -> String {
            let s = String(v, radix: 16)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        var offset = 0
        while offset < h.bytes.count {
            let chunk = h.bytes[offset..<min(offset + 16, h.bytes.count)]
            let lineAddr = fmt(base &+ UInt64(offset))
            b.line(lineAddr)
            b.add(lineAddr + "   ", Theme.address)
            var ascii = ""
            for (i, v) in chunk.enumerated() {
                if i == 8 { b.add(" ", .labelColor) }
                if v < 0 {
                    b.add("?? ", Theme.bytes)
                    ascii += " "
                } else {
                    b.add(String(format: "%02x ", v), v == 0 ? Theme.bytes : .labelColor)
                    ascii += (0x20..<0x7f).contains(v) ? String(UnicodeScalar(UInt8(v))) : "·"
                }
            }
            if chunk.count < 16 {
                b.add(String(repeating: "   ", count: 16 - chunk.count) + (chunk.count <= 8 ? " " : ""), .labelColor)
            }
            b.add("  " + ascii, Theme.constant)
            offset += 16
        }
        return b.build(fuzzy: true)
    }
}
