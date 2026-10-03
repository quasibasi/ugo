import SwiftUI

#if os(macOS)
import AppKit

/// A native NSTextView that renders Markdown in place. Text stays plain;
/// only attributes change, so copy, paste and undo behave like a plain editor.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    /// The fixed theme's colours, nil for the system colours.
    var palette: ThemePalette? = nil
    var columnWidth: CGFloat = 640
    var focusToken: Int = 0
    /// Where a new text view puts its caret, taking focus; nil leaves it at the start, unfocused.
    var initialSelection: Int? = nil
    /// Called with the caret location when Esc is pressed; nil leaves Esc to the text view.
    var onEscape: (@MainActor (Int) -> Void)? = nil
    /// Called when the text view takes keyboard focus, so the pane around it can become the focused one.
    var onFocus: (@MainActor () -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, theme: MarkdownTheme(fontSize: fontSize, palette: palette))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = UgoTextView(frame: .zero)
        textView.columnWidth = columnWidth
        textView.onFocus = onFocus
        textView.onEscape = onEscape
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 24, height: 8)
        textView.font = coordinator.highlighter.theme.body
        textView.textColor = coordinator.highlighter.theme.text
        textView.insertionPointColor = coordinator.highlighter.theme.caret
        textView.typingAttributes = coordinator.highlighter.theme.baseAttributes
        textView.string = text

        coordinator.textView = textView
        coordinator.lastPushed = text
        coordinator.highlightAll()
        if let initialSelection {
            let caret = NSRange(location: min(max(initialSelection, 0), (text as NSString).length), length: 0)
            textView.setSelectedRange(caret)
            // Once the view is in its window.
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.scrollRangeToVisible(caret)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let textView = coordinator.textView else { return }
        textView.columnWidth = columnWidth
        textView.onFocus = onFocus
        textView.onEscape = onEscape

        let theme = coordinator.highlighter.theme
        if theme.fontSize != fontSize || theme.palette != palette {
            coordinator.highlighter.setTheme(MarkdownTheme(fontSize: fontSize, palette: palette))
            textView.typingAttributes = coordinator.highlighter.theme.baseAttributes
            textView.textColor = coordinator.highlighter.theme.text
            textView.insertionPointColor = coordinator.highlighter.theme.caret
            coordinator.highlightAll()
        }
        if text != coordinator.lastPushed {
            coordinator.lastPushed = text
            textView.string = text
            coordinator.highlightAll()
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        var text: Binding<String>
        let highlighter: MarkdownHighlighter
        weak var textView: UgoTextView?
        var lastPushed = ""
        var focusToken = 0
        private var pendingEdit: (range: NSRange, forceToEnd: Bool)?
        private var revealedRange: NSRange?
        /// The link the caret is inside, whose brackets and URL are shown.
        private var revealedLink: NSRange?

        init(text: Binding<String>, theme: MarkdownTheme) {
            self.text = text
            highlighter = MarkdownHighlighter(theme: theme)
        }

        private func caretParagraph() -> NSRange? {
            guard let textView else { return nil }
            let ns = textView.string as NSString
            guard ns.length > 0 else { return nil }
            let caret = min(textView.selectedRange().location, ns.length)
            return ns.paragraphRange(for: NSRange(location: caret, length: 0))
        }

        func highlightAll() {
            guard let storage = textView?.textStorage else { return }
            revealedRange = caretParagraph()
            trackCaret()
            highlighter.highlightAll(storage, revealed: revealedRange)
        }

        /// Hands the caret to the highlighter and returns the link it is inside.
        @discardableResult
        private func trackCaret() -> NSRange? {
            guard let textView else { return nil }
            let caret = textView.selectedRange().location
            highlighter.caret = caret
            revealedLink = MarkdownHighlighter.link(in: textView.string as NSString, at: caret)?.range
            return revealedLink
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let ns = textView.string as NSString
            let oldParagraphs = ns.paragraphRange(for: affectedCharRange)
            let removedFence = MarkdownHighlighter.containsFence(ns, in: oldParagraphs)
            let newLength = (replacementString as NSString?)?.length ?? affectedCharRange.length
            pendingEdit = (NSRange(location: affectedCharRange.location, length: newLength), removedFence)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let string = textView.string
            lastPushed = string
            text.wrappedValue = string
            revealedRange = caretParagraph()
            trackCaret()
            if let storage = textView.textStorage {
                if let edit = pendingEdit {
                    highlighter.highlight(storage, editedRange: edit.range, forceToEnd: edit.forceToEnd, revealed: revealedRange)
                } else {
                    highlighter.highlightAll(storage, revealed: revealedRange)
                }
            }
            pendingEdit = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraph = caretParagraph()
            let previousLink = revealedLink
            let link = trackCaret()
            guard paragraph != revealedRange || link != previousLink else { return }
            let previous = revealedRange
            revealedRange = paragraph
            let length = storage.length
            if let previous, previous.location < length {
                // Restyle the paragraph the caret left, so its markers hide again.
                let stale = NSRange(location: previous.location, length: min(previous.length, length - previous.location))
                highlighter.highlight(storage, editedRange: stale.length > 0 ? stale : NSRange(location: previous.location, length: 1), forceToEnd: false, revealed: paragraph)
            }
            if let paragraph {
                highlighter.highlight(storage, editedRange: paragraph, forceToEnd: false, revealed: paragraph)
            }
            // The caret was placed before the markers changed width, so it would
            // sit over the next letter. Setting the selection again moves it to
            // the relaid text; the guard above makes the repeat a no-op.
            textView.selectedRanges = textView.selectedRanges
        }

        /// Keeps the caret out of a list item's or heading's hidden marker: it
        /// lands at the start of the text, and moving left from there goes to the line above.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            guard new.length == 0 else { return new }
            let ns = textView.string as NSString
            guard new.location <= ns.length else { return new }
            let lineRange = ListEditing.lineRange(ns, at: new.location)
            let contentStart = ListEditing.contentStart(ns, lineRange)
            guard new.location < contentStart else { return new }
            if old.length == 0, old.location == contentStart, lineRange.location > 0 {
                return NSRange(location: lineRange.location - 1, length: 0)
            }
            return NSRange(location: contentStart, length: 0)
        }

        /// Typing right after a hidden marker would pick up its invisible style.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:], toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            if let font = newTypingAttributes[.font] as? NSFont, font.pointSize < 1 {
                return highlighter.theme.baseAttributes
            }
            return newTypingAttributes
        }

        // MARK: NSTextLayoutManagerDelegate

        func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
            if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
               let info = paragraph.attributedString.attribute(.ugoBlock, at: 0, effectiveRange: nil) as? BlockInfo, info.wantsDecoration {
                return DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange, info: info, theme: highlighter.theme)
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }
}

/// Centres the text in a column and turns clicks on drawn checkboxes into edits.
final class UgoTextView: NSTextView {
    var columnWidth: CGFloat = 640 {
        didSet { updateInsets() }
    }
    var onFocus: (@MainActor () -> Void)?
    var onEscape: (@MainActor (Int) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let onFocus {
            // After the responder change settles, so state updates never land mid-layout.
            DispatchQueue.main.async { onFocus() }
        }
        return accepted
    }

    /// Esc, which would otherwise offer word completions.
    override func cancelOperation(_ sender: Any?) {
        guard let onEscape, !hasMarkedText() else { return super.cancelOperation(sender) }
        onEscape(selectedRange().location)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let side = max(24, ((bounds.width - columnWidth) / 2).rounded(.down))
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: 8)
        }
    }

    // MARK: List keys

    override func insertNewline(_ sender: Any?) {
        if !applyListEdit(ListEditing.newline) { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        if !applyListEdit(ListEditing.indent) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !applyListEdit(ListEditing.outdent) { super.insertBacktab(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if !applyListEdit(ListEditing.deleteBackward) { super.deleteBackward(sender) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        if typed == "]", replacementRange.location == NSNotFound, applyListEdit(ListEditing.checkboxShortcut) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Returns false when the key isn't a list edit and should do what it normally does.
    private func applyListEdit(_ edit: (NSString, NSRange) -> ListEditing.Result) -> Bool {
        guard !hasMarkedText(), let storage = textStorage else { return false }
        switch edit(storage.string as NSString, selectedRange()) {
        case .unhandled:
            return false
        case .ignored:
            return true
        case .edit(let change):
            replace(change.range, with: change.replacement, select: change.selection)
            return true
        }
    }

    /// One undoable edit, then the selection.
    private func replace(_ range: NSRange, with replacement: String, select selection: NSRange) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let link = link(at: point) {
            Self.open(link.url)
            return
        }
        if toggleCheckbox(at: point) { return }
        super.mouseDown(with: event)
    }

    // MARK: Links

    private var linkPopover: LinkPopover?
    private var hoveredLink: NSRange?

    /// Pasting a URL over selected text turns the text into a link.
    override func paste(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        guard selection.length > 0, !hasMarkedText(),
              let url = NSPasteboard.general.string(forType: .string).flatMap(Self.linkURL),
              let label = Self.linkLabel(ns.substring(with: selection)) else { return super.paste(sender) }
        let markdown = "[\(label)](\(url))"
        replace(selection, with: markdown, select: NSRange(location: selection.location + (markdown as NSString).length, length: 0))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.charactersIgnoringModifiers == "k" {
            editLink()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘K: asks for a URL and links the selection, or changes the link the caret is in.
    /// An empty URL on an existing link removes the link and keeps its text.
    func editLink() {
        guard !hasMarkedText() else { return }
        let ns = string as NSString
        let selection = selectedRange()
        let existing = MarkdownHighlighter.link(in: ns, at: selection.location)
            ?? (selection.length > 0 ? MarkdownHighlighter.link(in: ns, at: NSMaxRange(selection)) : nil)
        if existing == nil, selection.length > 0, Self.linkLabel(ns.substring(with: selection)) == nil { return NSSound.beep() }
        let clipboard = NSPasteboard.general.string(forType: .string).flatMap(Self.linkURL)
        let anchor = existing?.label ?? selection
        var rect = firstRect(forCharacterRange: anchor, actualRange: nil)
        if let window {
            rect = convert(window.convertFromScreen(rect), from: nil)
        }
        if rect.width < 1 { rect.size.width = 1 }
        let popover = LinkPopover(url: existing?.url ?? clipboard ?? "", editing: existing != nil)
        popover.onCommit = { [weak self] typed in
            guard let self else { return }
            let current = self.string as NSString
            if let existing {
                // The text may have changed under the popover; only touch the link if it is still there.
                guard NSMaxRange(existing.range) <= current.length,
                      current.substring(with: existing.range) == ns.substring(with: existing.range) else { return }
                let label = current.substring(with: existing.label)
                let replacement = typed.isEmpty ? label : "[\(label)](\(Self.linkURL(typed) ?? typed))"
                self.replace(existing.range, with: replacement, select: NSRange(location: existing.range.location + (replacement as NSString).length, length: 0))
            } else {
                guard !typed.isEmpty, NSMaxRange(selection) <= current.length else { return }
                let url = Self.linkURL(typed) ?? typed
                let label = selection.length > 0 ? current.substring(with: selection) : url
                let markdown = "[\(label)](\(url))"
                self.replace(selection, with: markdown, select: NSRange(location: selection.location + (markdown as NSString).length, length: 0))
            }
        }
        popover.onClose = { [weak self] in
            guard let self else { return }
            self.linkPopover = nil
            self.window?.makeFirstResponder(self)
        }
        linkPopover = popover
        popover.show(relativeTo: rect, of: self)
    }

    /// A URL to link to, or nil when the text isn't one. Bare `www.` addresses get https.
    static func linkURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        var url = trimmed
        if url.lowercased().hasPrefix("www.") { url = "https://" + url }
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "file"].contains(scheme) || url.contains("://") else { return nil }
        return url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    /// Selected text that can sit inside `[...]`: one line, no brackets.
    private static func linkLabel(_ text: String) -> String? {
        guard !text.isEmpty, text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]\n\r")) == nil else { return nil }
        return text
    }

    static func open(_ url: String) {
        let full = url.contains(":") ? url : "https://" + url
        guard let target = URL(string: full) else { return NSSound.beep() }
        NSWorkspace.shared.open(target)
    }

    /// The link whose label is drawn under the point, in view coordinates.
    private func link(at point: NSPoint) -> (label: NSRange, url: String)? {
        guard let storage = textStorage, storage.length > 0,
              let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let index = characterIndexForInsertion(at: point)
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for i in [index, index - 1] where i >= 0 && i < storage.length {
            var label = NSRange()
            let line = (storage.string as NSString).lineRange(for: NSRange(location: i, length: 0))
            guard let url = storage.attribute(.ugoLink, at: i, longestEffectiveRange: &label, in: line) as? String,
                  let start = content.location(content.documentRange.location, offsetBy: label.location),
                  let end = content.location(start, offsetBy: label.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            var hit = false
            layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                hit = frame.contains(inContainer)
                return !hit
            }
            if hit { return (label, url) }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.userInfo?["ugoLinks"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["ugoLinks": true]))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil), command: event.modifierFlags.contains(.command))
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), command: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil)
    }

    /// Darkens the underline of the link under the pointer; with ⌘ held the pointer becomes a hand.
    private func updateHover(at point: NSPoint, command: Bool) {
        let link = link(at: point)
        setHoveredLink(link?.label)
        if link != nil, command { NSCursor.pointingHand.set() }
    }

    private func setHoveredLink(_ range: NSRange?) {
        guard range != hoveredLink, let layout = textLayoutManager, let content = layout.textContentManager else { return }
        func textRange(_ r: NSRange) -> NSTextRange? {
            guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                  let end = content.location(start, offsetBy: r.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }
        if let old = hoveredLink, NSMaxRange(old) <= (string as NSString).length, let r = textRange(old) {
            layout.removeRenderingAttribute(.underlineColor, for: r)
        }
        hoveredLink = range
        if let range, let r = textRange(range), let theme = (delegate as? MarkdownEditor.Coordinator)?.highlighter.theme {
            layout.addRenderingAttribute(.underlineColor, value: theme.linkUnderlineHover, for: r)
        }
    }

    private func toggleCheckbox(at point: NSPoint) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        guard let info = storage.attribute(.ugoBlock, at: index, effectiveRange: nil) as? BlockInfo,
              case .task(let done) = info.kind, !info.revealed else { return false }
        guard point.x < textContainerOrigin.x + info.indent + 2 else { return false }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: paragraph)
        guard let open = line.range(of: "[", options: []), let close = line.range(of: "]", options: [], range: open.upperBound..<line.endIndex) else { return false }
        let innerStart = paragraph.location + line.distance(from: line.startIndex, to: open.upperBound)
        let innerLength = line.distance(from: open.upperBound, to: close.lowerBound)
        guard innerLength == 1 else { return false }
        let inner = NSRange(location: innerStart, length: 1)
        insertText(done ? " " : "x", replacementRange: inner)
        return true
    }
}

/// The URL field ⌘K opens under the selection. Return links, Esc or a click away cancels.
@MainActor
final class LinkPopover: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    var onCommit: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let popover = NSPopover()
    private let field = NSTextField()

    init(url: String, editing: Bool) {
        super.init()
        field.stringValue = url
        field.placeholderString = "Paste or type a link"
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: editing ? "↩ to save, empty to remove the link" : "↩ to link, esc to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = onCommit
            onCommit = nil
            popover.close()
            commit?(typed)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCommit = nil
            popover.close()
            return true
        default:
            return false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        onClose?()
    }
}

#else
import UIKit

/// UIKit counterpart of the macOS editor; shares the highlighter and decorations.
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    /// The fixed theme's colours, nil for the system colours.
    var palette: ThemePalette? = nil
    var columnWidth: CGFloat = 640
    var focusToken: Int = 0
    /// Where a new text view puts its caret, taking focus; nil leaves it at the start, unfocused.
    var initialSelection: Int? = nil
    /// Called with the caret location when Esc is pressed; nil leaves Esc to the text view.
    var onEscape: (@MainActor (Int) -> Void)? = nil
    /// Called when the text view takes keyboard focus, so the pane around it can become the focused one.
    var onFocus: (@MainActor () -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, theme: MarkdownTheme(fontSize: fontSize, palette: palette))
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.autocorrectionType = .default
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        textView.font = coordinator.highlighter.theme.body
        textView.textColor = coordinator.highlighter.theme.text
        textView.tintColor = coordinator.highlighter.theme.caret
        textView.typingAttributes = coordinator.highlighter.theme.baseAttributes
        textView.text = text

        coordinator.textView = textView
        coordinator.lastPushed = text
        coordinator.highlightAll()
        if let initialSelection {
            textView.selectedRange = NSRange(location: min(max(initialSelection, 0), (text as NSString).length), length: 0)
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.onFocus = onFocus
        let theme = coordinator.highlighter.theme
        if theme.fontSize != fontSize || theme.palette != palette {
            coordinator.highlighter.setTheme(MarkdownTheme(fontSize: fontSize, palette: palette))
            textView.typingAttributes = coordinator.highlighter.theme.baseAttributes
            textView.textColor = coordinator.highlighter.theme.text
            textView.tintColor = coordinator.highlighter.theme.caret
            coordinator.highlightAll()
        }
        if text != coordinator.lastPushed {
            coordinator.lastPushed = text
            textView.text = text
            coordinator.highlightAll()
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            textView.becomeFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        var text: Binding<String>
        let highlighter: MarkdownHighlighter
        weak var textView: UITextView?
        var lastPushed = ""
        var focusToken = 0
        var onFocus: (@MainActor () -> Void)?
        private var pendingEdit: (range: NSRange, forceToEnd: Bool)?
        private var revealedRange: NSRange?
        /// The link the caret is inside, whose brackets and URL are shown.
        private var revealedLink: NSRange?

        init(text: Binding<String>, theme: MarkdownTheme) {
            self.text = text
            highlighter = MarkdownHighlighter(theme: theme)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onFocus?()
        }

        private func caretParagraph() -> NSRange? {
            guard let textView else { return nil }
            let ns = (textView.text ?? "") as NSString
            guard ns.length > 0 else { return nil }
            let caret = min(textView.selectedRange.location, ns.length)
            return ns.paragraphRange(for: NSRange(location: caret, length: 0))
        }

        func highlightAll() {
            guard let textView else { return }
            revealedRange = caretParagraph()
            trackCaret()
            highlighter.highlightAll(textView.textStorage, revealed: revealedRange)
        }

        /// Hands the caret to the highlighter and returns the link it is inside.
        @discardableResult
        private func trackCaret() -> NSRange? {
            guard let textView else { return nil }
            let caret = textView.selectedRange.location
            highlighter.caret = caret
            revealedLink = MarkdownHighlighter.link(in: (textView.text ?? "") as NSString, at: caret)?.range
            return revealedLink
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            let ns = (textView.text ?? "") as NSString
            let oldParagraphs = ns.paragraphRange(for: range)
            let removedFence = MarkdownHighlighter.containsFence(ns, in: oldParagraphs)
            pendingEdit = (NSRange(location: range.location, length: (replacement as NSString).length), removedFence)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            let string = textView.text ?? ""
            lastPushed = string
            text.wrappedValue = string
            revealedRange = caretParagraph()
            trackCaret()
            if let edit = pendingEdit {
                highlighter.highlight(textView.textStorage, editedRange: edit.range, forceToEnd: edit.forceToEnd, revealed: revealedRange)
            } else {
                highlighter.highlightAll(textView.textStorage, revealed: revealedRange)
            }
            pendingEdit = nil
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let paragraph = caretParagraph()
            let previousLink = revealedLink
            let link = trackCaret()
            guard paragraph != revealedRange || link != previousLink else { return }
            let previous = revealedRange
            revealedRange = paragraph
            let storage = textView.textStorage
            if let previous, previous.location < storage.length {
                let stale = NSRange(location: previous.location, length: min(previous.length, storage.length - previous.location))
                highlighter.highlight(storage, editedRange: stale.length > 0 ? stale : NSRange(location: previous.location, length: 1), forceToEnd: false, revealed: paragraph)
            }
            if let paragraph {
                highlighter.highlight(storage, editedRange: paragraph, forceToEnd: false, revealed: paragraph)
            }
        }

        func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
            if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
               let info = paragraph.attributedString.attribute(.ugoBlock, at: 0, effectiveRange: nil) as? BlockInfo, info.wantsDecoration {
                return DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange, info: info, theme: highlighter.theme)
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }
}
#endif
