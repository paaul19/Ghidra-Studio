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
}

/// Read-only text view that forwards Ghidra-style single-key shortcuts.
final class CodeNSTextView: NSTextView {
    var keyHandler: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let chars = event.charactersIgnoringModifiers, chars.count == 1,
           "lLdDfFcCtTbBgG;".contains(chars), keyHandler?(chars) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Read-only, selectable code view (TextKit 1) with clickable navigation links,
/// current-line highlight, word-occurrence highlight, find bar and context menu.
struct CodeTextView: NSViewRepresentable {
    let document: CodeDocument
    let highlightAddress: String?
    let scrollRequest: ScrollRequest?
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
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = Theme.background
        tv.textContainerInset = NSSize(width: 14, height: 12)
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
            c.suppressSelection = true
            tv.textStorage?.setAttributedString(document.text)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.suppressSelection = false
            if let anchor {
                c.restore(anchor)
                preserved = true
            }
            docChanged = true
        }
        if docChanged || c.highlightAddress != highlightAddress {
            c.highlightAddress = highlightAddress
            c.refreshHighlights()
        }
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
            if let address = highlightAddress {
                for i in doc.lines(matching: address) {
                    lm.addTemporaryAttribute(.backgroundColor, value: Theme.lineHighlight,
                                             forCharacterRange: doc.range(ofLine: i))
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
            }
            ctx.lineAddress = doc.lineIndex(at: index).flatMap { doc.lineAddresses[$0] }
            return ctx
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard document != nil else { return menu }
            if charIndex >= 0, charIndex < (view.textStorage?.length ?? 0), view.selectedRange().length == 0 {
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
