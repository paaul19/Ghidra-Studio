import AppKit
import SwiftUI

struct CodeMenuAction {
    let title: String
    let symbol: String
    let action: () -> Void
}

/// What is under the cursor / right-click in a code view.
struct CodeContext {
    var target: String?
    var targetText: String?
    var lineAddress: String?
    var variable: String?
    /// Decompiler token id, struct field ("typePath|offset") and call-site address under the cursor.
    var tokenID: Int?
    var field: String?
    var callSite: String?
    /// First / last address covered by the text selection (when more than one line is selected).
    var selectionStart: String?
    var selectionEnd: String?
    var word: String?
    /// The variable instance under the cursor can be split out as a new variable.
    var canSplit = false
    /// The token under the cursor is a field of a union.
    var isUnionField = false
}

/// Read-only text view that forwards Ghidra-style single-key shortcuts.
final class CodeNSTextView: NSTextView {
    /// The code view currently on screen (for printing).
    static weak var current: CodeNSTextView?
    var keyHandler: ((String) -> Bool)?
    /// What is under the caret (used by menu-bar commands that act on the cursor).
    var contextProvider: (() -> CodeContext)?

    /// Jump arrows drawn in the left margin, the lines of the document and the lines to emphasize.
    var flows: [FlowArrow] = []
    var lineStarts: [Int] = []
    var activeLines = Set<Int>()
    /// Lines with a bookmark, drawn as an icon at the left edge.
    var markerLines = Set<Int>()
    /// Lines with a breakpoint (true = enabled) and the line the debugger is stopped at.
    var breakpointLines: [Int: Bool] = [:]
    var pcLines = Set<Int>()
    /// Called with the character index of the line whose margin was clicked.
    var marginHandler: ((Int) -> Void)?
    /// Called with the character index the mouse has rested on; nil when it moves away.
    var hoverHandler: ((Int?) -> Void)?
    /// Called with the character index clicked with the middle button.
    var middleClickHandler: ((Int) -> Void)?
    /// braceNext, bracePrevious, highlightNext, highlightPrevious.
    var navigator: ((String) -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let middleClickHandler, let lm = layoutManager, let container = textContainer,
              (textStorage?.length ?? 0) > 0 else { super.otherMouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = lm.glyphIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: container)
        middleClickHandler(lm.characterIndexForGlyph(at: glyph))
    }
    private var hoverTimer: Timer?
    private var hoverPoint = NSPoint.zero
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard hoverHandler != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - hoverPoint.x) + abs(point.y - hoverPoint.y) < 3 { return }
        hoverPoint = point
        hoverHandler?(nil)
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let lm = self.layoutManager, let container = self.textContainer,
                      (self.textStorage?.length ?? 0) > 0 else { return }
                let p = NSPoint(x: self.hoverPoint.x - self.textContainerOrigin.x, y: self.hoverPoint.y - self.textContainerOrigin.y)
                var fraction: CGFloat = 0
                let glyph = lm.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
                // only when the mouse is really over the glyph, not past the end of the line
                guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -2).contains(p)
                else { return }
                self.hoverHandler?(lm.characterIndexForGlyph(at: glyph))
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.invalidate()
        hoverHandler?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverHandler?(nil)
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marginHandler, point.x < 15, let lm = layoutManager, let container = textContainer,
           (textStorage?.length ?? 0) > 0 {
            let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: point.y - textContainerOrigin.y), in: container)
            marginHandler(lm.characterIndexForGlyph(at: glyph))
            return
        }
        super.mouseDown(with: event)
    }

    static let baseInset: CGFloat = 14
    static let laneWidth: CGFloat = 7
    static let markerWidth: CGFloat = 8

    static func inset(lanes: Int, markers: Bool = false) -> CGFloat {
        let base = baseInset + (markers ? markerWidth : 0)
        return lanes == 0 ? base : base + CGFloat(lanes) * laneWidth + 12
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        // single-key shortcuts like Ghidra's; which key does what is configurable
        if mods.isEmpty, let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let key = Shortcuts.shared.codeKey(for: chars), keyHandler?(key) == true {
            return
        }
        super.keyDown(with: event)
    }

    private func lineMidY(_ line: Int) -> CGFloat? {
        guard line >= 0, line < lineStarts.count, let lm = layoutManager,
              lineStarts[line] < (textStorage?.length ?? 0) else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: lineStarts[line])
        guard glyph < lm.numberOfGlyphs else { return nil }
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.midY + textContainerOrigin.y
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !flows.isEmpty || !markerLines.isEmpty || !breakpointLines.isEmpty || !pcLines.isEmpty,
              let lm = layoutManager, let container = textContainer else { return }
        // lines currently on screen, to skip the arrows that do not cross them
        let visible = visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -textContainerOrigin.y), in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        func lineIndex(_ char: Int) -> Int {
            var lo = 0, hi = max(0, lineStarts.count - 1)
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= char { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
        let first = lineIndex(chars.location), last = lineIndex(chars.location + chars.length)
        let textX = textContainerOrigin.x
        let tipX = textX - 3

        if !markerLines.isEmpty, first <= last {
            NSColor.systemOrange.setFill()
            for line in first...last where markerLines.contains(line) {
                guard let y = lineMidY(line) else { continue }
                // a small bookmark ribbon
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: 4, y: y - 5))
                mark.line(to: NSPoint(x: 11, y: y - 5))
                mark.line(to: NSPoint(x: 11, y: y + 5))
                mark.line(to: NSPoint(x: 7.5, y: y + 2))
                mark.line(to: NSPoint(x: 4, y: y + 5))
                mark.close()
                mark.fill()
            }
        }

        if first <= last {
            for (line, enabled) in breakpointLines where line >= first && line <= last {
                guard let y = lineMidY(line) else { continue }
                let dot = NSBezierPath(ovalIn: NSRect(x: 3, y: y - 4.5, width: 9, height: 9))
                if enabled {
                    NSColor.systemRed.setFill()
                    dot.fill()
                } else {
                    NSColor.systemRed.setStroke()
                    dot.lineWidth = 1.5
                    dot.stroke()
                }
            }
            for line in pcLines where line >= first && line <= last {
                guard let y = lineMidY(line) else { continue }
                // the arrow that marks where execution is stopped
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: 2, y: y - 3))
                arrow.line(to: NSPoint(x: 7, y: y - 3))
                arrow.line(to: NSPoint(x: 7, y: y - 6))
                arrow.line(to: NSPoint(x: 13.5, y: y))
                arrow.line(to: NSPoint(x: 7, y: y + 6))
                arrow.line(to: NSPoint(x: 7, y: y + 3))
                arrow.line(to: NSPoint(x: 2, y: y + 3))
                arrow.close()
                NSColor.systemGreen.setFill()
                arrow.fill()
            }
        }

        for pass in 0..<2 {     // emphasized arrows on top
            for flow in flows where flow.bottom >= first && flow.top <= last {
                let active = activeLines.contains(flow.from) || activeLines.contains(flow.to)
                if active != (pass == 1) { continue }
                guard let y0 = lineMidY(flow.from), let y1 = lineMidY(flow.to) else { continue }
                let laneX = textX - 10 - CGFloat(flow.lane) * Self.laneWidth
                let path = NSBezierPath()
                path.move(to: NSPoint(x: tipX, y: y0))
                path.line(to: NSPoint(x: laneX, y: y0))
                path.line(to: NSPoint(x: laneX, y: y1))
                path.line(to: NSPoint(x: tipX, y: y1))
                path.lineWidth = active ? 1.8 : 1
                path.lineJoinStyle = .round
                if flow.conditional { path.setLineDash([3, 2], count: 2, phase: 0) }
                let color = active ? NSColor.controlAccentColor
                    : (flow.conditional ? NSColor.secondaryLabelColor : NSColor.systemBlue.withAlphaComponent(0.7))
                color.setStroke()
                path.stroke()
                let head = NSBezierPath()
                head.move(to: NSPoint(x: tipX + 1, y: y1))
                head.line(to: NSPoint(x: tipX - 4, y: y1 - 3))
                head.line(to: NSPoint(x: tipX - 4, y: y1 + 3))
                head.close()
                color.setFill()
                head.fill()
            }
        }
    }
}

/// Read-only, selectable code view (TextKit 1) with clickable navigation links,
/// current-line highlight, word-occurrence highlight, find bar and context menu.
struct CodeTextView: NSViewRepresentable {
    let document: CodeDocument
    let highlightAddress: String?
    let scrollRequest: ScrollRequest?
    var sliceTokens: Set<Int> = []
    /// Program selection (address ranges), painted over the lines it covers.
    var selection: ProgramSelection? = nil
    /// Breakpoints (address → enabled) and the address the debugger is stopped at, both drawn in the margin.
    var breakpoints: [String: Bool] = [:]
    var pcAddress: String? = nil
    /// Clicking the left margin of a line toggles a breakpoint there.
    var onToggleBreakpoint: ((String) -> Void)? = nil
    /// Persistent highlight and background colors of the listing.
    var highlight: ProgramSelection? = nil
    var colors: [ColorRange] = []
    /// Words with a secondary highlight (word → rgb) and addresses selected in another view.
    var secondary: [String: UInt32] = [:]
    var cross: Set<String> = []
    /// What to show when the mouse rests on a reference: (title, lines).
    var hoverProvider: ((String) async -> (String, [String])?)? = nil
    /// The same for a plain word (a register or variable name while debugging).
    var wordHoverProvider: ((String) async -> (String, [String])?)? = nil
    /// False for extra windows: menu-bar commands and printing keep acting on the main code view.
    var isPrimary = true
    var onNavigate: (String) -> Void
    var onSelectLine: (String) -> Void
    var onReachEdge: ((_ top: Bool) -> Void)? = nil
    var onKey: ((String, CodeContext) -> Void)? = nil
    var menuActions: (CodeContext) -> [CodeMenuAction]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background

        let tv = CodeNSTextView(usingTextLayoutManager: false)
        let coordinator = context.coordinator
        tv.keyHandler = { [weak coordinator] key in
            guard let coordinator, let handler = coordinator.parent.onKey, let tv = coordinator.textView else {
                return false
            }
            handler(key, coordinator.context(at: tv.selectedRange().location))
            return true
        }
        tv.contextProvider = { [weak coordinator] in
            guard let coordinator, let tv = coordinator.textView else { return CodeContext() }
            // the caret may sit right after the token the user means
            let location = tv.selectedRange().location
            func useful(_ c: CodeContext) -> Bool {
                c.variable != nil || c.isUnionField || c.canSplit || c.target != nil || c.field != nil
            }
            let here = coordinator.context(at: location)
            if useful(here) || location == 0 { return here }
            let before = coordinator.context(at: location - 1)
            return useful(before) ? before : here
        }
        tv.marginHandler = { [weak coordinator] index in
            guard let coordinator, let handler = coordinator.parent.onToggleBreakpoint,
                  let address = coordinator.context(at: index).lineAddress else { return }
            handler(address)
        }
        tv.hoverHandler = { [weak coordinator] index in coordinator?.hover(index) }
        tv.middleClickHandler = { [weak coordinator] index in coordinator?.highlightWord(at: index) }
        tv.navigator = { [weak coordinator] what in coordinator?.navigate(what) }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = Theme.background
        tv.textContainerInset = NSSize(width: CodeNSTextView.baseInset, height: 12)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        tv.delegate = context.coordinator
        scroll.documentView = tv
        context.coordinator.textView = tv
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        var docChanged = false
        var preserved = false
        if c.documentID != document.id {
            let anchor = document.preservesScroll ? c.topAnchor() : nil
            c.documentID = document.id
            c.document = document
            c.currentWord = nil
            c.lineValues = nil
            c.suppressSelection = true
            if let code = tv as? CodeNSTextView {
                code.flows = document.flows
                code.lineStarts = document.lineStarts
                code.markerLines = document.hasMarkerMargin ? document.markers : []
                let inset = CodeNSTextView.inset(lanes: document.flowLanes, markers: document.hasMarkerMargin)
                if code.textContainerInset.width != inset {
                    code.textContainerInset = NSSize(width: inset, height: 12)
                }
            }
            tv.textStorage?.setAttributedString(document.text)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.suppressSelection = false
            if let anchor {
                c.restore(anchor)
                preserved = true
            }
            docChanged = true
        }
        var pcChanged = false
        if docChanged || c.breakpoints != breakpoints || c.pcAddress != pcAddress {
            pcChanged = docChanged || c.pcAddress != pcAddress
            c.breakpoints = breakpoints
            c.pcAddress = pcAddress
            c.refreshMarkers(pcChanged: pcChanged, pc: pcAddress)
        }
        if docChanged || pcChanged || c.highlightAddress != highlightAddress || c.sliceTokens != sliceTokens
            || c.selection?.id != selection?.id || c.highlight?.id != highlight?.id || c.colors != colors
            || c.secondary != secondary || c.cross != cross {
            c.secondary = secondary
            c.cross = cross
            c.highlight = highlight
            c.colors = colors
            c.highlightAddress = highlightAddress
            c.sliceTokens = sliceTokens
            c.selection = selection
            c.refreshHighlights()
        }
        if isPrimary { CodeNSTextView.current = tv as? CodeNSTextView }
        if preserved {
            c.scrollID = scrollRequest?.id
        } else if docChanged || c.scrollID != scrollRequest?.id {
            c.scrollID = scrollRequest?.id
            DispatchQueue.main.async { c.scroll(to: scrollRequest?.address, resetIfMissing: docChanged) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: NSTextView?
        var document: CodeDocument?
        var documentID: UUID?
        var highlightAddress: String?
        var scrollID: UUID?
        var currentWord: String?
        var sliceTokens: Set<Int> = []
        var selection: ProgramSelection?
        var highlight: ProgramSelection?
        var colors: [ColorRange] = []
        var secondary: [String: UInt32] = [:]
        var cross: Set<String> = []

        /// Middle click: highlights every occurrence of the word under the mouse.
        func highlightWord(at index: Int) {
            guard let doc = document, index < doc.text.length else { return }
            let ns = doc.text.string as NSString
            func isIdent(_ c: unichar) -> Bool {
                guard let s = UnicodeScalar(c) else { return false }
                return CharacterSet.alphanumerics.contains(s) || c == 95
            }
            var start = index, end = index
            guard isIdent(ns.character(at: index)) else { currentWord = nil; refreshHighlights(); return }
            while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
            while end + 1 < ns.length, isIdent(ns.character(at: end + 1)) { end += 1 }
            let word = ns.substring(with: NSRange(location: start, length: end - start + 1))
            currentWord = word == currentWord ? nil : word
            refreshHighlights()
        }

        private func occurrences(of word: String) -> [NSRange] {
            guard let doc = document else { return [] }
            let ns = doc.text.string as NSString
            var out: [NSRange] = []
            var search = NSRange(location: 0, length: ns.length)
            while out.count < 2000 {
                let r = ns.range(of: word, options: [.literal], range: search)
                if r.location == NSNotFound { break }
                if isWordBoundary(ns, r) { out.append(r) }
                let next = r.location + r.length
                search = NSRange(location: next, length: ns.length - next)
            }
            return out
        }

        /// Moves the caret to the enclosing brace or to the next highlighted place.
        func navigate(_ what: String) {
            guard let tv = textView, let doc = document else { return }
            let ns = doc.text.string as NSString
            let pos = min(tv.selectedRange().location, max(0, ns.length - 1))
            var target: Int?
            let open = unichar(123), close = unichar(125)
            switch what {
            case "braceNext":
                var depth = 0
                var i = pos + 1
                while i < ns.length {
                    let c = ns.character(at: i)
                    if c == open { depth += 1 } else if c == close {
                        if depth == 0 { target = i; break }
                        depth -= 1
                    }
                    i += 1
                }
                // outside any block: the next opening brace
                if target == nil {
                    let r = ns.range(of: "{", options: [], range: NSRange(location: min(pos + 1, ns.length), length: max(0, ns.length - pos - 1)))
                    if r.location != NSNotFound { target = r.location }
                }
            case "bracePrevious":
                var depth = 0
                var i = pos - 1
                while i >= 0 {
                    let c = ns.character(at: i)
                    if c == close { depth += 1 } else if c == open {
                        if depth == 0 { target = i; break }
                        depth -= 1
                    }
                    i -= 1
                }
            default:
                var ranges: [NSRange] = []
                if let word = currentWord { ranges += occurrences(of: word) }
                ranges += sliceTokens.compactMap { doc.tokenRanges[$0] }
                for word in secondary.keys { ranges += occurrences(of: word) }
                ranges.sort { $0.location < $1.location }
                guard !ranges.isEmpty else { return }
                if what == "highlightNext" {
                    target = (ranges.first { $0.location > pos } ?? ranges.first)?.location
                } else {
                    target = (ranges.last { $0.location < pos } ?? ranges.last)?.location
                }
            }
            guard let target else { return }
            // keep the highlighted word: moving the caret would clear it
            suppressSelection = true
            tv.setSelectedRange(NSRange(location: target, length: 0))
            tv.scrollRangeToVisible(NSRange(location: target, length: 1))
            suppressSelection = false
            if let i = doc.lineIndex(at: target), let address = doc.lineAddresses[i] {
                let handler = parent.onSelectLine
                DispatchQueue.main.async { handler(address) }
            }
        }
        private var popover: NSPopover?
        private var hoverToken = 0

        /// Shows (or, with nil, hides) the pop-up for the reference under the mouse.
        func hover(_ index: Int?) {
            hoverToken += 1
            popover?.close()
            popover = nil
            guard let index, let doc = document, let tv = textView, index < doc.text.length else { return }
            var range = NSRange()
            var lookup: (() async -> (String, [String])?)?
            if let link = doc.text.attribute(.link, at: index, effectiveRange: &range) as? String,
               link.hasPrefix(DocumentBuilder.linkPrefix), let provider = parent.hoverProvider {
                let target = String(link.dropFirst(DocumentBuilder.linkPrefix.count))
                lookup = { await provider(target) }
            } else if let provider = parent.wordHoverProvider {
                // a word that is not a link: a register or a variable
                let ns = doc.text.string as NSString
                func isIdent(_ c: unichar) -> Bool {
                    guard let s = UnicodeScalar(c) else { return false }
                    return CharacterSet.alphanumerics.contains(s) || c == 95
                }
                guard isIdent(ns.character(at: index)) else { return }
                var start = index, end = index
                while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
                while end + 1 < ns.length, isIdent(ns.character(at: end + 1)) { end += 1 }
                range = NSRange(location: start, length: end - start + 1)
                let word = ns.substring(with: range)
                lookup = { await provider(word) }
            }
            guard let lookup else { return }
            let token = hoverToken
            Task { @MainActor in
                guard let (title, lines) = await lookup(), token == hoverToken, let lm = tv.layoutManager,
                      let container = tv.textContainer, tv.window != nil else { return }
                let text = NSMutableAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
                text.append(NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
                let label = NSTextField(labelWithAttributedString: text)
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 12
                let size = label.sizeThatFits(NSSize(width: 620, height: 400))
                let controller = NSViewController()
                controller.view = NSView(frame: NSRect(x: 0, y: 0, width: min(640, size.width + 24), height: size.height + 20))
                label.frame = NSRect(x: 12, y: 10, width: controller.view.frame.width - 24, height: size.height)
                controller.view.addSubview(label)
                let pop = NSPopover()
                pop.contentViewController = controller
                pop.contentSize = controller.view.frame.size
                pop.behavior = .applicationDefined
                pop.animates = false
                var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                rect.origin.x += tv.textContainerOrigin.x
                rect.origin.y += tv.textContainerOrigin.y
                pop.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
                popover = pop
            }
        }

        var breakpoints: [String: Bool] = [:]
        var pcAddress: String?
        var pcLines: [Int] = []

        /// Works out which lines carry a breakpoint or the program counter.
        func refreshMarkers(pcChanged: Bool, pc: String?) {
            guard let code = textView as? CodeNSTextView, let doc = document else { return }
            // a fuzzy document (the decompiler) only shows what falls inside the code it covers
            var low = UInt64.max, high = UInt64.min
            if doc.fuzzyHighlight {
                for a in doc.lineAddresses {
                    guard let a, let v = addressValue(a) else { continue }
                    low = min(low, v)
                    high = max(high, v)
                }
            }
            let entry = doc.entryAddress.flatMap(addressValue)
            func lines(_ address: String) -> [Int] {
                if doc.fuzzyHighlight {
                    guard let v = addressValue(address) else { return [] }
                    // the prologue has no line of its own: it belongs to the first line of code
                    if let entry, v >= entry, v < low, low != .max {
                        return doc.lineAddresses.indices.filter { doc.lineAddresses[$0].flatMap(addressValue) == low }
                    }
                    guard v >= low, v <= high &+ 15 else { return [] }
                }
                return doc.lines(matching: address)
            }
            var marks: [Int: Bool] = [:]
            for (address, enabled) in breakpoints {
                let found = lines(address)
                if let line = doc.fuzzyHighlight ? found.first : found.last { marks[line] = enabled }
            }
            code.breakpointLines = marks
            if pcChanged {
                let found = pc.map(lines) ?? []
                pcLines = found
                code.pcLines = (doc.fuzzyHighlight ? found.first : found.last).map { [$0] } ?? []
            }
            code.needsDisplay = true
        }

        /// Numeric address of each line, computed when a program selection has to be painted.
        var lineValues: [UInt64?]?
        var suppressSelection = false

        init(_ parent: CodeTextView) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        struct Anchor { let address: String; let offset: CGFloat }

        private func lineRect(_ line: Int) -> NSRect? {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
                  let doc = document else { return nil }
            let glyphs = lm.glyphRange(forCharacterRange: doc.range(ofLine: line), actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += tv.textContainerOrigin.y
            return rect
        }

        /// Address of the first visible line and its distance from the top of the viewport.
        func topAnchor() -> Anchor? {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
                  let doc = document, let clip = tv.enclosingScrollView?.contentView else { return nil }
            let y = clip.bounds.minY
            let point = NSPoint(x: 0, y: max(0, y - tv.textContainerOrigin.y))
            let glyph = lm.glyphIndex(for: point, in: container)
            let char = lm.characterIndexForGlyph(at: glyph)
            guard let line = doc.lineIndex(at: char), let address = doc.lineAddresses[line],
                  let rect = lineRect(line) else { return nil }
            return Anchor(address: address, offset: rect.minY - y)
        }

        func restore(_ anchor: Anchor) {
            guard let tv = textView, let doc = document, let clip = tv.enclosingScrollView?.contentView,
                  let line = doc.lineAddresses.firstIndex(where: { $0 == anchor.address }) else { return }
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            tv.sizeToFit()
            guard let rect = lineRect(line) else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, rect.minY - anchor.offset)))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        @objc func boundsChanged(_ note: Notification) {
            guard let handler = parent.onReachEdge, let tv = textView,
                  let clip = tv.enclosingScrollView?.contentView else { return }
            let visible = clip.bounds
            let threshold = max(600, visible.height)
            if visible.minY < threshold {
                DispatchQueue.main.async { handler(true) }
            } else if tv.frame.height - visible.maxY < threshold {
                DispatchQueue.main.async { handler(false) }
            }
        }

        func refreshHighlights() {
            guard let tv = textView, let lm = tv.layoutManager, let doc = document else { return }
            let full = NSRange(location: 0, length: doc.text.length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            if let code = tv as? CodeNSTextView, !doc.flows.isEmpty {
                code.activeLines = Set(highlightAddress.map { doc.lines(matching: $0) } ?? [])
                code.needsDisplay = true
            }
            if !colors.isEmpty || highlight != nil {
                if lineValues == nil { lineValues = doc.lineAddresses.map { $0.flatMap(addressValue) } }
                let values = lineValues ?? []
                for i in values.indices {
                    guard let v = values[i] else { continue }
                    if let c = colors.first(where: { $0.range.contains(v) }) {
                        lm.addTemporaryAttribute(.backgroundColor, value: Theme.rgb(c.rgb).withAlphaComponent(0.4),
                                                 forCharacterRange: doc.range(ofLine: i))
                    }
                    if let highlight, highlight.contains(v) {
                        lm.addTemporaryAttribute(.backgroundColor, value: Theme.persistentHighlight,
                                                 forCharacterRange: doc.range(ofLine: i))
                    }
                }
            }
            if let selection, !selection.bounds.isEmpty {
                if lineValues == nil { lineValues = doc.lineAddresses.map { $0.flatMap(addressValue) } }
                let values = lineValues ?? []
                var run: Int?
                for i in 0...values.count {
                    let inside = i < values.count && values[i].map(selection.contains) == true
                    if inside, run == nil { run = i }
                    if !inside, let start = run {
                        let from = doc.lineStarts[start]
                        let to = i < doc.lineStarts.count ? doc.lineStarts[i] : doc.text.length
                        lm.addTemporaryAttribute(.backgroundColor, value: Theme.programSelection,
                                                 forCharacterRange: NSRange(location: from, length: max(0, to - from)))
                        run = nil
                    }
                }
            }
            if !cross.isEmpty {
                for i in doc.lineAddresses.indices {
                    let hit = doc.lineAddresses[i].map(cross.contains) == true
                        || doc.lineExtra[i]?.contains(where: cross.contains) == true
                    if hit {
                        lm.addTemporaryAttribute(.backgroundColor, value: Theme.crossHighlight, forCharacterRange: doc.range(ofLine: i))
                    }
                }
            }
            for i in pcLines where i < doc.lineStarts.count {
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.pcHighlight, forCharacterRange: doc.range(ofLine: i))
            }
            if let address = highlightAddress {
                for i in doc.lines(matching: address) where !pcLines.contains(i) || pcAddress == nil {
                    lm.addTemporaryAttribute(.backgroundColor, value: Theme.lineHighlight,
                                             forCharacterRange: doc.range(ofLine: i))
                }
            }
            for id in sliceTokens {
                if let r = doc.tokenRanges[id], r.location + r.length <= doc.text.length {
                    lm.addTemporaryAttribute(.backgroundColor, value: Theme.sliceHighlight, forCharacterRange: r)
                }
            }
            for (word, rgb) in secondary {
                for r in occurrences(of: word) {
                    lm.addTemporaryAttribute(.backgroundColor, value: Theme.rgb(rgb).withAlphaComponent(0.45), forCharacterRange: r)
                }
            }
            if let word = currentWord {
                let ns = doc.text.string as NSString
                var search = NSRange(location: 0, length: ns.length)
                var count = 0
                while count < 2000 {
                    let r = ns.range(of: word, options: [.literal], range: search)
                    if r.location == NSNotFound { break }
                    if isWordBoundary(ns, r) {
                        lm.addTemporaryAttribute(.backgroundColor, value: Theme.wordHighlight, forCharacterRange: r)
                        count += 1
                    }
                    let next = r.location + r.length
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
        }

        private func isWordBoundary(_ ns: NSString, _ r: NSRange) -> Bool {
            func isIdent(_ c: unichar) -> Bool {
                guard let s = UnicodeScalar(c) else { return false }
                return CharacterSet.alphanumerics.contains(s) || c == 95
            }
            if r.location > 0 && isIdent(ns.character(at: r.location - 1)) { return false }
            let end = r.location + r.length
            if end < ns.length && isIdent(ns.character(at: end)) { return false }
            return true
        }

        func scroll(to address: String?, resetIfMissing: Bool) {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
                  let doc = document else { return }
            lm.ensureLayout(for: container)
            tv.sizeToFit()
            if let address, let line = doc.lines(matching: address).first {
                let glyphs = lm.glyphRange(forCharacterRange: doc.range(ofLine: line), actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.y += tv.textContainerOrigin.y
                if let clip = tv.enclosingScrollView?.contentView {
                    let visible = clip.bounds
                    if !visible.contains(rect) || resetIfMissing {
                        let y = max(0, rect.midY - visible.height / 3)
                        clip.scroll(to: NSPoint(x: 0, y: y))
                        tv.enclosingScrollView?.reflectScrolledClipView(clip)
                    }
                }
            } else if resetIfMissing {
                tv.scroll(NSPoint(x: 0, y: 0))
            }
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let value = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
            guard value.hasPrefix(DocumentBuilder.linkPrefix) else { return false }
            parent.onNavigate(String(value.dropFirst(DocumentBuilder.linkPrefix.count)))
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppressSelection, let tv = textView, let doc = document else { return }
            let sel = tv.selectedRange()
            let ns = doc.text.string as NSString
            var word: String?
            if sel.length > 0, sel.length < 200, sel.location + sel.length <= ns.length {
                let s = ns.substring(with: sel)
                if s.range(of: "^[A-Za-z_][A-Za-z0-9_.:]*$", options: .regularExpression) != nil { word = s }
            }
            if word != currentWord {
                currentWord = word
                refreshHighlights()
            }
            if sel.length == 0, let i = doc.lineIndex(at: sel.location), let address = doc.lineAddresses[i] {
                let handler = parent.onSelectLine
                DispatchQueue.main.async { handler(address) }
            }
        }

        func context(at charIndex: Int) -> CodeContext {
            var ctx = CodeContext()
            guard let doc = document else { return ctx }
            let index = min(max(0, charIndex), max(0, doc.text.length - 1))
            if doc.text.length > 0 {
                var range = NSRange()
                if let link = doc.text.attribute(.link, at: index, effectiveRange: &range) as? String,
                   link.hasPrefix(DocumentBuilder.linkPrefix) {
                    ctx.target = String(link.dropFirst(DocumentBuilder.linkPrefix.count))
                    ctx.targetText = (doc.text.string as NSString).substring(with: range)
                }
                ctx.variable = doc.text.attribute(.studioVariable, at: index, effectiveRange: nil) as? String
                ctx.tokenID = doc.text.attribute(.studioToken, at: index, effectiveRange: nil) as? Int
                ctx.field = doc.text.attribute(.studioField, at: index, effectiveRange: nil) as? String
                ctx.callSite = doc.text.attribute(.studioCall, at: index, effectiveRange: nil) as? String
                ctx.canSplit = doc.text.attribute(.studioSplit, at: index, effectiveRange: nil) != nil
                ctx.isUnionField = doc.text.attribute(.studioUnion, at: index, effectiveRange: nil) != nil
                var tokenRange = NSRange()
                if doc.text.attribute(.studioToken, at: index, effectiveRange: &tokenRange) != nil {
                    ctx.word = (doc.text.string as NSString).substring(with: tokenRange)
                }
            }
            ctx.lineAddress = doc.lineIndex(at: index).flatMap { doc.lineAddresses[$0] }
            if let tv = textView {
                let sel = tv.selectedRange()
                if sel.length > 0, let first = doc.lineIndex(at: sel.location),
                   let last = doc.lineIndex(at: max(sel.location, sel.location + sel.length - 1)), last > first {
                    ctx.selectionStart = (first...last).compactMap { doc.lineAddresses[$0] }.first
                    ctx.selectionEnd = (first...last).compactMap { doc.lineAddresses[$0] }.last
                    ctx.lineAddress = ctx.selectionStart ?? ctx.lineAddress
                }
            }
            return ctx
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard document != nil else { return menu }
            let sel = view.selectedRange()
            let insideSelection = sel.length > 0 && charIndex >= sel.location && charIndex <= sel.location + sel.length
            if charIndex >= 0, charIndex < (view.textStorage?.length ?? 0), !insideSelection {
                view.setSelectedRange(NSRange(location: charIndex, length: 0))
            }
            let actions = parent.menuActions(context(at: charIndex))
            let result = NSMenu()
            for a in actions {
                if a.title == "-" {
                    result.addItem(.separator())
                    continue
                }
                let item = ClosureMenuItem(title: a.title, action: a.action)
                item.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
                result.addItem(item)
            }
            if !actions.isEmpty { result.addItem(.separator()) }
            let copy = NSMenuItem(title: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            result.addItem(copy)
            let selectAll = NSMenuItem(title: tr("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
            result.addItem(selectAll)
            return result
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
