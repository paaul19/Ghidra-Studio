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
    /// Character range of each decompiler token id.
    var tokenRanges: [Int: NSRange] = [:]
    /// Jump arrows for the listing margin.
    var flows: [FlowArrow] = []
    var flowLanes: Int { flows.isEmpty ? 0 : (flows.map(\.lane).max() ?? 0) + 1 }
    /// Lines that carry a bookmark, for the marker margin.
    var markers = Set<Int>()
    /// Whether the left margin reserves room for marker icons.
    var hasMarkerMargin = false
    /// Entry of the function a decompiler document shows: its first instructions have no line of their own.
    var entryAddress: String?
    /// Decompiler lines that come from several addresses.
    var lineExtra: [Int: [String]] = [:]

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
    static var keyword: NSColor { ThemeStore.color("keyword", 0x9B2393, 0xFF7AB2) }
    static var comment: NSColor { ThemeStore.color("comment", 0x5D6C79, 0x7F8C98) }
    static var type: NSColor { ThemeStore.color("type", 0x0B4F79, 0x6BDFFF) }
    static var function: NSColor { ThemeStore.color("function", 0x6C36A9, 0xB281EB) }
    static let variable = NSColor.labelColor
    static var constant: NSColor { ThemeStore.color("constant", 0x1C00CF, 0xD9C97C) }
    static var parameter: NSColor { ThemeStore.color("parameter", 0x326D74, 0x78C2B3) }
    static var global: NSColor { ThemeStore.color("global", 0x0F68A0, 0x4EB0CC) }
    static let error = NSColor.systemRed
    static let special = NSColor.systemOrange
    static let address = NSColor.secondaryLabelColor
    static let bytes = NSColor.tertiaryLabelColor
    static var mnemonic: NSColor { ThemeStore.color("mnemonic", 0x0B4F79, 0x6BDFFF) }
    static var label: NSColor { ThemeStore.color("label", 0x6C36A9, 0xB281EB) }
    static var background: NSColor { ThemeStore.color("background", 0xFFFFFF, 0x1F1F24) }
    static let lineHighlight = NSColor.controlAccentColor.withAlphaComponent(0.18)
    static let wordHighlight = NSColor.systemYellow.withAlphaComponent(0.35)
    static let sliceHighlight = NSColor.systemGreen.withAlphaComponent(0.38)
    /// The lines that match what is selected in another view (listing ↔ decompiler).
    static let crossHighlight = NSColor.systemTeal.withAlphaComponent(0.16)
    static let programSelection = NSColor.systemGreen.withAlphaComponent(0.2)
    static let pcHighlight = NSColor.systemGreen.withAlphaComponent(0.32)
    static let persistentHighlight = NSColor.systemYellow.withAlphaComponent(0.28)

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
    /// Decompiler token id (for data-flow slices).
    static let studioToken = NSAttributedString.Key("studioToken")
    /// "typePath|offset" of a structure field token.
    static let studioField = NSAttributedString.Key("studioField")
    /// Address of the call instruction behind a function-name token.
    static let studioCall = NSAttributedString.Key("studioCall")
    /// Set on variable tokens that can be split out as a new variable.
    static let studioSplit = NSAttributedString.Key("studioSplit")
    /// Set on tokens that are a field of a union.
    static let studioUnion = NSAttributedString.Key("studioUnion")
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
    private var options = ListingOptions()
    /// Structures and arrays opened in the listing.
    private var expanded: [String: [DataComponent]] = [:]
    /// Line of each instruction and the jumps found, to build the margin arrows.
    private var instructionLine: [String: Int] = [:]
    private var jumps: [(line: Int, targets: [String], conditional: Bool)] = []
    private var markers = Set<Int>()

    init(fontSize: Double) {
        font = ThemeStore.font(size: fontSize, bold: false)
        boldFont = ThemeStore.font(size: fontSize, bold: true)
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

    private var tokenRanges: [Int: NSRange] = [:]

    func add(_ s: String, _ color: NSColor, bold: Bool = false, link: String? = nil, variable: String? = nil,
             token: DecompToken? = nil, url: String? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? boldFont : font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let link { attrs[.link] = Self.linkPrefix + link }
        if let url { attrs[.link] = url }
        if let variable { attrs[.studioVariable] = variable }
        if let token {
            if let id = token.i {
                attrs[.studioToken] = id
                tokenRanges[id] = NSRange(location: text.length, length: (s as NSString).length)
            }
            if let type = token.ft, let offset = token.fo { attrs[.studioField] = "\(type)|\(offset)" }
            if let call = token.call { attrs[.studioCall] = call }
            if token.sp == true { attrs[.studioSplit] = true }
            if token.un == true { attrs[.studioUnion] = true }
        }
        text.append(NSAttributedString(string: s, attributes: attrs))
    }

    private func end() {
        add("\n", .labelColor)
        lineOpen = false
    }

    func build(fuzzy: Bool = false) -> CodeDocument {
        if lineOpen { end() }
        var doc = CodeDocument(text: text, lineAddresses: lineAddresses, lineStarts: lineStarts, fuzzyHighlight: fuzzy)
        doc.tokenRanges = tokenRanges
        doc.markers = markers
        if options.showFlowArrows, !jumps.isEmpty {
            var arrows: [FlowArrow] = []
            for jump in jumps {
                for target in jump.targets {
                    if let to = instructionLine[target], to != jump.line {
                        arrows.append(FlowArrow(from: jump.line, to: to, conditional: jump.conditional))
                    }
                }
            }
            doc.flows = FlowArrow.assignLanes(arrows)
        }
        return doc
    }

    /// Adds comment text, turning Ghidra's annotations ({@symbol name}, {@address 1000}, {@url …}) into links.
    private func addComment(_ text: String) {
        let ns = text as NSString
        guard text.contains("{@"), let regex = try? NSRegularExpression(pattern: #"\{@(\w+)\s+([^}]*)\}"#) else {
            add(text, Theme.comment)
            return
        }
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                add(ns.substring(with: NSRange(location: last, length: m.range.location - last)), Theme.comment)
            }
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            var body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            // {@kind target "text shown"}
            var shown: String?
            if let quote = body.range(of: " \"") {
                shown = String(body[quote.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                body = String(body[..<quote.lowerBound])
            }
            let target = body.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            switch kind {
            case "symbol", "sym", "address", "addr":
                add(shown ?? target, Theme.global, link: target)
            case "url", "hyperlink", "href", "link":
                add(shown ?? target, Theme.global, url: target)
            default:
                add(shown ?? target, Theme.special)
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { add(ns.substring(from: last), Theme.comment) }
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
                      link: isNavigable ? token.target : nil, variable: token.v, token: token)
            }
        }
        var doc = b.build(fuzzy: true)
        doc.entryAddress = d.entry
        for (i, line) in lines.enumerated() {
            if let addrs = line.addrs { doc.lineExtra[i] = addrs }
        }
        return doc
    }

    // MARK: - Listing

    static func listing(_ l: Listing, fontSize: Double, options: ListingOptions = ListingOptions(),
                        expanded: [String: [DataComponent]] = [:]) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        b.options = options
        b.expanded = expanded
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
        var doc = b.build()
        doc.hasMarkerMargin = options.showMarkerMargin
        return doc
    }

    /// Links that fold or unfold a function instead of navigating: the prefix, then its entry address.
    static let foldPrefix = "fold:"

    static func fullListing(_ rows: [ListingRow], fontSize: Double, preservesScroll: Bool,
                            options: ListingOptions = ListingOptions(),
                            expanded: [String: [DataComponent]] = [:]) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        b.options = options
        b.expanded = expanded
        let addrWidth = (rows.map(\.address.count).max() ?? 8) + 2
        let rule = String(repeating: "─", count: 72)
        for row in rows {
            if let block = row.blockStart {
                b.line(row.address)
                b.line(row.address)
                b.add(tr("// ═══ Segmento %@ ", "\(block)"), Theme.special, bold: true)
                b.add(String(repeating: "═", count: 40), Theme.special)
                b.line(row.address)
            }
            if let signature = row.fnStart {
                b.line(row.address)
                b.line(row.address)
                b.add("// " + rule, Theme.comment)
                b.line(row.address)
                // the mark folds or unfolds the function
                b.add(row.folded != nil ? "▸ " : "▾ ", Theme.special, link: foldPrefix + row.address)
                b.add("ƒ  ", Theme.comment)
                b.add(signature, Theme.function, bold: true)
                b.line(row.address)
                b.add("// " + rule, Theme.comment)
            }
            if let hidden = row.folded {
                b.line(row.address)
                b.add(pad("", 2) + pad(row.address, addrWidth), Theme.address)
                b.add(tr("… función plegada · %@ bytes", "\(hidden)"), Theme.comment, link: foldPrefix + row.address)
                continue
            }
            b.row(row, addrWidth: addrWidth)
        }
        var doc = b.build()
        doc.preservesScroll = preservesScroll
        doc.isFullListing = true
        doc.hasMarkerMargin = options.showMarkerMargin
        return doc
    }

    private func width(of column: ListingColumn, addrWidth: Int) -> Int {
        switch column {
        case .address: addrWidth
        case .bytes: options.byteCount * 3 + 2
        case .code: options.mnemonicWidth + 34
        case .comment: 36
        case .bookmark: 20
        }
    }

    private func row(_ row: ListingRow, addrWidth: Int) {
        let b = self
        let pad = Self.pad
        let o = options
        let columns = o.columns.filter { o.isVisible($0) }
        // comment and label lines are indented to where the instruction text starts
        let lead = columns.first == .address ? 0 : 2
        let custom = o.layout.filter { !$0.isEmpty }
        func natural(_ cell: ListingCell) -> Int {
            if cell.width > 0 { return cell.width }
            switch cell.field {
            case "address": return addrWidth
            case "bytes": return o.byteCount * 3 + 2
            default: return 0
            }
        }
        let indent: Int
        if let codeRow = custom.first(where: { $0.contains { $0.field == "code" } }) {
            indent = max(2, codeRow.prefix { $0.field != "code" }.map(natural).reduce(0, +))
        } else {
            indent = max(2, lead + columns.prefix { $0 != .code }.map { width(of: $0, addrWidth: addrWidth) }.reduce(0, +))
        }
        let comments = o.showComments
        if comments, let plate = row.plate, !plate.isEmpty {
            for text in plate.split(separator: "\n", omittingEmptySubsequences: false) {
                b.line(row.address)
                b.add(pad("", indent) + "/* ", Theme.comment)
                b.addComment(String(text))
                b.add(" */", Theme.comment)
            }
        }
        if let label = row.label {
            b.line(row.address)
            b.add(pad("", indent), .labelColor)
            b.add(label + ":", Theme.label, bold: true)
            if o.showReferenceCounts, row.xrefs > 0 {
                b.add("    ← \(row.xrefs) ref\(row.xrefs == 1 ? "" : "s")", Theme.bytes)
            }
        }
        if o.showXrefList, let list = row.xrefList, !list.isEmpty {
            b.line(row.address)
            b.add(pad("", indent) + "XREF[\(row.xrefs)" + (row.thunkXrefs.map { " + \($0) thunk" } ?? "") + "]: ", Theme.bytes)
            for (i, item) in list.enumerated() {
                if i > 0 { b.add(", ", Theme.bytes) }
                // "100000648(Call)" → link on the address
                let address = item.split(separator: "(").first.map(String.init) ?? item
                if addressValue(address) != nil {
                    b.add(address, Theme.global, link: address)
                    b.add(String(item.dropFirst(address.count)), Theme.bytes)
                } else {
                    b.add(item, Theme.bytes)
                }
            }
            if row.xrefs + (row.thunkXrefs ?? 0) > list.count { b.add(", …", Theme.bytes) }
        }
        if comments, let pre = row.pre, !pre.isEmpty {
            for text in pre.split(separator: "\n") {
                b.line(row.address)
                b.add(pad("", indent) + "; ", Theme.comment)
                b.addComment(String(text))
            }
        }

        b.line(row.address)
        instructionLine[row.address] = lineStarts.count - 1
        var jumpIndex: Int?
        if let targets = row.jumps, !targets.isEmpty {
            jumps.append((lineStarts.count - 1, targets, row.conditional ?? false))
            jumpIndex = jumps.count - 1
        }
        if row.bookmark != nil { markers.insert(lineStarts.count - 1) }

        if !custom.isEmpty {
            customRows(row, layout: custom, natural: natural, jumpIndex: jumpIndex)
            finish(row, indent: indent)
            return
        }

        // fields in the order the user chose; a field is only padded when something follows it
        var used = 0
        var edge = lead
        func put(_ s: String, _ color: NSColor, bold: Bool = false, link: String? = nil) {
            b.add(s, color, bold: bold, link: link)
            used += s.count
        }
        func align() {
            if used < edge {
                put(String(repeating: " ", count: edge - used), .labelColor)
            } else if used > 0 {
                put(used > edge ? "    " : "", .labelColor)
            }
        }
        for column in columns {
            switch column {
            case .address:
                align()
                put(row.address, Theme.address)
            case .bytes:
                align()
                // the engine sends up to 8 bytes as "aa bb cc …"
                let parts = row.bytes.split(separator: " ")
                put(parts.count > o.byteCount ? parts.prefix(o.byteCount).joined(separator: " ") + " …" : row.bytes, Theme.bytes)
            case .code:
                align()
                let mnemonicColor: NSColor = row.kind == "code" ? Theme.mnemonic : (row.kind == "data" ? Theme.type : Theme.bytes)
                if row.components != nil {
                    // a structure or an array: the mark says whether it is open
                    put(expanded[row.address] != nil ? "▾ " : "▸ ", Theme.special)
                }
                put(row.operands.isEmpty ? row.mnemonic : pad(row.mnemonic, o.mnemonicWidth), mnemonicColor,
                    bold: row.flow == "call" || row.flow == "return")
                for (i, op) in row.operands.enumerated() {
                    if i > 0 { put(", ", .labelColor) }
                    if let target = op.target {
                        put(op.text, Theme.global, link: target)
                    } else {
                        put(op.text, op.text.hasPrefix("#") || op.text.hasPrefix("0x") ? Theme.constant : .labelColor)
                    }
                }
            case .comment:
                let parts = [row.eol, row.repeatable].compactMap { $0 }.filter { !$0.isEmpty }
                    .map { $0.replacingOccurrences(of: "\n", with: " ") }
                if !parts.isEmpty {
                    align()
                    b.add("; ", Theme.comment)
                    used += 2
                    let text = parts.joined(separator: " ; ")
                    b.addComment(text)
                    used += text.count
                }
            case .bookmark:
                if let mark = row.bookmark {
                    align()
                    put("⚑ " + mark, Theme.special)
                }
            }
            edge += width(of: column, addrWidth: addrWidth)
        }
        // extra fields: where the line is in the file, in its function and in the source
        var extras: [String] = []
        if o.showFileOffset, let file = row.fileOffset { extras.append("file+0x" + file) }
        if o.showFunctionOffset, let fn = row.functionOffset { extras.append(fn) }
        if o.showSource, let source = row.source { extras.append(source) }
        if !extras.isEmpty { b.add("    ⟨" + extras.joined(separator: " · ") + "⟩", Theme.bytes) }
        finish(row, indent: indent)
    }

    /// The contents of one field of a custom row, as pieces of text with their color and link.
    private func pieces(_ field: String, _ row: ListingRow) -> [(String, NSColor, Bool, String?)] {
        let o = options
        switch field {
        case "address": return [(row.address, Theme.address, false, nil)]
        case "bytes":
            let parts = row.bytes.split(separator: " ")
            return [(parts.count > o.byteCount ? parts.prefix(o.byteCount).joined(separator: " ") + " …" : row.bytes, Theme.bytes, false, nil)]
        case "code":
            var out: [(String, NSColor, Bool, String?)] = []
            let mnemonicColor: NSColor = row.kind == "code" ? Theme.mnemonic : (row.kind == "data" ? Theme.type : Theme.bytes)
            if row.components != nil { out.append((expanded[row.address] != nil ? "▾ " : "▸ ", Theme.special, false, nil)) }
            out.append((row.operands.isEmpty ? row.mnemonic : Self.pad(row.mnemonic, o.mnemonicWidth), mnemonicColor,
                        row.flow == "call" || row.flow == "return", nil))
            for (i, op) in row.operands.enumerated() {
                if i > 0 { out.append((", ", .labelColor, false, nil)) }
                if let target = op.target {
                    out.append((op.text, Theme.global, false, target))
                } else {
                    out.append((op.text, op.text.hasPrefix("#") || op.text.hasPrefix("0x") ? Theme.constant : .labelColor, false, nil))
                }
            }
            return out
        case "comment":
            let parts = [row.eol, row.repeatable].compactMap { $0 }.filter { !$0.isEmpty }
                .map { $0.replacingOccurrences(of: "\n", with: " ") }
            return parts.isEmpty ? [] : [("; " + parts.joined(separator: " ; "), Theme.comment, false, nil)]
        case "bookmark": return row.bookmark.map { [("⚑ " + $0, Theme.special, false, nil)] } ?? []
        case "fileOffset": return row.fileOffset.map { [("file+0x" + $0, Theme.bytes, false, nil)] } ?? []
        case "functionOffset": return row.functionOffset.map { [($0, Theme.bytes, false, nil)] } ?? []
        case "source": return row.source.map { [($0, Theme.bytes, false, nil)] } ?? []
        case "refs": return row.xrefs > 0 ? [("← \(row.xrefs) ref\(row.xrefs == 1 ? "" : "s")", Theme.bytes, false, nil)] : []
        default: return []
        }
    }

    /// Draws a line of the listing with the user's own rows of fields.
    private func customRows(_ row: ListingRow, layout: [[ListingCell]], natural: (ListingCell) -> Int, jumpIndex: Int?) {
        var first = true
        for cells in layout {
            let contents = cells.map { pieces($0.field, row) }
            // a row with nothing but spacers and empty fields is not drawn
            guard contents.contains(where: { !$0.isEmpty }) else { continue }
            if !first { line(row.address) }
            first = false
            if cells.contains(where: { $0.field == "code" }) {
                let index = lineStarts.count - 1
                instructionLine[row.address] = index
                if let jumpIndex { jumps[jumpIndex].0 = index }
            }
            for (i, cell) in cells.enumerated() {
                var used = 0
                for piece in contents[i] {
                    add(piece.0, piece.1, bold: piece.2, link: piece.3)
                    used += piece.0.count
                }
                let width = natural(cell)
                let isLast = i == cells.count - 1
                if used < width {
                    if !isLast || cell.field == "spacer" { add(String(repeating: " ", count: width - used), .labelColor) }
                } else if !isLast, used > 0 {
                    add("  ", .labelColor)
                }
            }
        }
    }

    /// What follows the fields of a line: p-code, the open structure, post comments and the blank line after a return.
    private func finish(_ row: ListingRow, indent: Int) {
        let b = self
        let pad = Self.pad
        let o = options
        let comments = o.showComments
        if o.showPcode, let pcode = row.pcode {
            for op in pcode {
                b.line(row.address)
                b.add(pad("", indent + 4) + op, Theme.comment)
            }
        }
        if let components = expanded[row.address] {
            for c in components {
                b.line(c.address)
                b.add(pad("", indent + 2), .labelColor)
                b.add(pad("+0x" + String(c.offset, radix: 16), 8), Theme.address)
                b.add(pad(c.type, 18), Theme.type)
                b.add(pad(c.name ?? "", 18), Theme.label)
                b.add(c.value, Theme.constant)
                if c.components > 0 { b.add("  ▸ \(c.components)", Theme.special) }
                if let comment = c.comment, !comment.isEmpty { b.add("    ; " + comment, Theme.comment) }
            }
        }

        if comments, let post = row.post, !post.isEmpty {
            for text in post.split(separator: "\n") {
                b.line(row.address)
                b.add(pad("", indent) + "; \(text)", Theme.comment)
            }
        }
        if row.flow == "return" {
            b.line(row.address)
        }
    }

    // MARK: - Debugger

    /// Disassembly of the process being debugged; line addresses are the dynamic ones, in hexadecimal.
    static func dynamic(_ instructions: [DebugInstruction], fontSize: Double) -> CodeDocument {
        let b = DocumentBuilder(fontSize: fontSize)
        let width = (instructions.map { String($0.address, radix: 16).count }.max() ?? 9) + 2
        for i in instructions {
            let address = String(i.address, radix: 16)
            if let label = i.label {
                b.line(address)
                b.add(pad("", width), .labelColor)
                b.add(label + ":", Theme.label, bold: true)
            }
            b.line(address)
            b.add(pad(address, width), Theme.address)
            b.add(pad(i.bytes, 14), Theme.bytes)
            // "mnemonic operands ; comment"
            var text = i.text
            var comment = ""
            if let semi = text.range(of: ";") {
                comment = String(text[semi.lowerBound...])
                text = String(text[..<semi.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            b.add(pad(parts.first.map(String.init) ?? "", 10), Theme.mnemonic)
            if parts.count > 1 { b.add(parts[1].trimmingCharacters(in: .whitespaces), .labelColor) }
            if !comment.isEmpty { b.add("    " + comment, Theme.comment) }
        }
        var doc = b.build()
        doc.hasMarkerMargin = true
        return doc
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
