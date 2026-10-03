#if os(macOS)
import AppKit
import SwiftUI

/// Lays each block of columns in a note over the block's hidden lines: a row
/// of small text views, one per column, each editing its slice of the note.
/// The note's text view keeps the whole Markdown, so saving, section zen,
/// quick open and find see the columns as ordinary text. A note without
/// columns never gets past the first check in each entry point.
@MainActor
final class ColumnsController {
    private unowned let owner: MarkdownEditor.Coordinator
    private(set) var blocks: [ColumnBlocks.Block] = []
    private var overlays: [ColumnsOverlay] = []
    /// A column to put the caret in once the note's text view takes focus,
    /// for a caret placed in a column before the text view was in its window.
    private var deferredFocus: (block: Int, column: Int, selection: NSRange, at: Date)?
    /// The column whose edit is going into the note right now. Its text view
    /// is never replaced or rewritten during that edit, only after it.
    private weak var editingColumn: ColumnEditor?
    private var heightsDirty = false
    private var heightsScheduled = false
    private var syncScheduled = false
    private var measuredWidth: CGFloat = 0
    /// Text views taken out of a block, kept until the event that removed them is over.
    private var retired: [ColumnEditor] = []
    /// Set while ↑ or ↓ moves the note's caret, which lands on a hidden line
    /// wherever the layout happens to put it; the column then goes by the caret's x.
    var verticalMove = false

    init(owner: MarkdownEditor.Coordinator) {
        self.owner = owner
    }

    private var textView: UgoTextView? { owner.textView }

    /// The note's text without a copy. `textView.string as NSString` is a
    /// bridged Swift string, and searching one is many times slower.
    private var text: NSString { owner.textView?.textStorage?.mutableString ?? "" }

    // MARK: Following the text

    /// Reads the blocks again after a change, before the highlighter runs.
    /// `edited` is the changed text, nil to read everything. Returns ranges
    /// whose lines may have joined or left a block and need restyling.
    func parse(edited: NSRange? = nil, removedFence: Bool = false) -> [NSRange] {
        guard textView != nil else { return [] }
        let ns = text
        // A note without columns gets one only from a marker line typed or
        // pasted, or from a fence taken away from around one; anything else
        // can skip reading the whole note.
        if blocks.isEmpty, let edited, !removedFence {
            let location = min(edited.location, ns.length)
            let lines = ns.paragraphRange(for: NSRange(location: location, length: min(edited.length, ns.length - location)))
            if ns.range(of: ":::", options: .literal, range: lines).location == NSNotFound { return [] }
        }
        let old = blocks
        let new = ColumnBlocks.blocks(in: ns)
        guard !(old.isEmpty && new.isEmpty) else { return [] }
        blocks = new
        owner.highlighter.columnBlocks = new
        var heights = owner.highlighter.columnHeights
        if heights.count > new.count { heights.removeLast(heights.count - new.count) }
        let estimate = owner.highlighter.theme.paragraph.minimumLineHeight
        while heights.count < new.count { heights.append(estimate) }
        owner.highlighter.columnHeights = heights

        var changed: [NSRange] = []
        if old.count != new.count {
            changed = old.map(\.range) + new.map(\.range)
        } else {
            for (o, n) in zip(old, new) where o.range.length != n.range.length || o.columns.count != n.columns.count {
                changed.append(NSUnionRange(o.range, n.range))
            }
        }
        // Old ranges may reach past the shortened text.
        return changed.compactMap { range in
            guard range.location < ns.length else { return nil }
            return NSRange(location: range.location, length: min(range.length, ns.length - range.location))
        }
    }

    /// Brings the column text views in line with the blocks, after the highlighter ran.
    func syncOverlays() {
        guard let textView, !(blocks.isEmpty && overlays.isEmpty) else { return }
        let ns = text
        let texts = blocks.map { block in block.columns.map { ns.substring(with: $0.range) } }
        if let editing = editingColumn, !matches(texts, keeping: editing) {
            // The edit changed the blocks themselves, say a `+++` typed in a
            // column. Rebuild once the column's text view is done with it.
            scheduleSync(refocus: caretLocation(of: editing))
            return
        }
        while overlays.count > blocks.count {
            let overlay = overlays.removeLast()
            retire(overlay.editors)
            overlay.removeFromSuperview()
        }
        let theme = owner.highlighter.theme
        for (i, columnTexts) in texts.enumerated() {
            if i == overlays.count {
                let overlay = ColumnsOverlay()
                textView.addSubview(overlay)
                overlays.append(overlay)
            }
            let overlay = overlays[i]
            overlay.theme = theme
            if overlay.editors.count != columnTexts.count {
                retire(overlay.editors)
                overlay.setEditors(columnTexts.map { makeEditor(text: $0, theme: theme, overlay: overlay) })
                heightsDirty = true
            } else {
                for (editor, text) in zip(overlay.editors, columnTexts) where editor.set(text: text, theme: theme) {
                    heightsDirty = true
                }
            }
        }
        updateCallbacks()
        if heightsDirty { measureHeights() }
        positionOverlays()
    }

    /// True when the blocks still have the shape the overlays show and the
    /// column being edited already holds its new text.
    private func matches(_ texts: [[String]], keeping editing: ColumnEditor) -> Bool {
        guard texts.count == overlays.count else { return false }
        for (overlay, columnTexts) in zip(overlays, texts) {
            guard overlay.editors.count == columnTexts.count else { return false }
            if let c = overlay.editors.firstIndex(where: { $0 === editing }), editing.textView.string != columnTexts[c] { return false }
        }
        return true
    }

    private func scheduleSync(refocus: Int?) {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncOverlays()
            if let refocus { self.focus(location: refocus) }
        }
    }

    private func retire(_ editors: [ColumnEditor]) {
        guard !editors.isEmpty else { return }
        retired += editors
        DispatchQueue.main.async { [weak self] in self?.retired.removeAll() }
    }

    private func makeEditor(text: String, theme: MarkdownTheme, overlay: ColumnsOverlay) -> ColumnEditor {
        let editor = ColumnEditor(text: text, theme: theme)
        editor.onChange = { [weak self, weak overlay, weak editor] text in
            guard let self, let overlay, let editor else { return }
            self.columnEdited(editor, in: overlay, text: text)
        }
        editor.textView.onEdge = { [weak self, weak overlay, weak editor] edge in
            guard let self, let overlay, let editor else { return false }
            return self.handle(edge, from: editor, in: overlay)
        }
        return editor
    }

    /// Focus, Esc and find in a column act for the whole note.
    func updateCallbacks() {
        guard !overlays.isEmpty, let textView else { return }
        let escape = textView.onEscape
        for overlay in overlays {
            for editor in overlay.editors {
                editor.textView.onFocus = textView.onFocus
                editor.textView.findTarget = textView
                if let escape {
                    editor.textView.onEscape = { [weak self, weak editor] caret in
                        guard let self, let editor else { return }
                        escape(self.caretLocation(of: editor, caret: caret) ?? 0)
                    }
                } else {
                    editor.textView.onEscape = nil
                }
            }
        }
    }

    // MARK: Edits in a column

    private func columnEdited(_ editor: ColumnEditor, in overlay: ColumnsOverlay, text: String) {
        guard let (b, c) = indices(of: editor, in: overlay), b < blocks.count, c < blocks[b].columns.count else { return }
        let column = blocks[b].columns[c]
        editingColumn = editor
        owner.applyColumnEdit(column.range, with: column.hasLine ? text : text + "\n")
        editingColumn = nil
        // The column restyles its text after this returns; measure it then.
        heightsDirty = true
        scheduleHeights()
    }

    private func scheduleHeights() {
        guard !heightsScheduled else { return }
        heightsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightsScheduled = false
            self.measureHeights()
            self.positionOverlays()
        }
    }

    /// Makes each block's `::: columns` line as tall as its tallest column.
    private func measureHeights() {
        guard let textView, let container = textView.textContainer else { return }
        heightsDirty = false
        let width = container.size.width
        measuredWidth = width
        var heights = owner.highlighter.columnHeights
        let minimum = owner.highlighter.theme.paragraph.minimumLineHeight
        var changed: [Int] = []
        for (i, overlay) in overlays.enumerated() where i < heights.count {
            overlay.arrange(width: width, height: heights[i])
            let height = max(minimum, overlay.contentHeight()).rounded(.up)
            if abs(height - heights[i]) >= 0.5 {
                heights[i] = height
                changed.append(i)
            }
        }
        guard !changed.isEmpty else { return }
        owner.highlighter.columnHeights = heights
        for i in changed {
            owner.restyle(blocks[i].opening)
            overlays[i].arrange(width: width, height: heights[i])
        }
    }

    /// Puts each block's columns where its `::: columns` line was laid out.
    func positionOverlays() {
        guard !overlays.isEmpty, let textView, let layout = textView.textLayoutManager,
              let content = layout.textContentManager, let container = textView.textContainer else { return }
        if abs(container.size.width - measuredWidth) >= 0.5 {
            // Never restyle in the middle of a layout pass.
            heightsDirty = true
            scheduleHeights()
        }
        let origin = textView.textContainerOrigin
        let heights = owner.highlighter.columnHeights
        for (i, overlay) in overlays.enumerated() where i < blocks.count && i < heights.count {
            guard let location = content.location(content.documentRange.location, offsetBy: blocks[i].opening.location) else { continue }
            var fragment = layout.textLayoutFragment(for: location)
            if fragment == nil || fragment?.state != .layoutAvailable {
                layout.ensureLayout(for: NSTextRange(location: location))
                fragment = layout.textLayoutFragment(for: location)
            }
            guard let fragment else { continue }
            let frame = NSRect(x: origin.x, y: origin.y + fragment.layoutFragmentFrame.minY, width: container.size.width, height: heights[i])
            if overlay.frame != frame {
                overlay.frame = frame
                overlay.arrange(width: frame.width, height: frame.height)
            }
        }
    }

    // MARK: The caret between the note and its columns

    private func blockIndex(containing location: Int) -> Int? {
        blocks.firstIndex { location >= $0.range.location && location <= NSMaxRange($0.range) }
    }

    /// Keeps the note's caret out of a block's hidden lines. A caret headed
    /// into a block goes to the column instead. Nil leaves the change alone.
    func redirect(from old: NSRange, to new: NSRange) -> NSRange? {
        guard !blocks.isEmpty, let textView else { return nil }
        if new.length > 0 {
            // A selection inside one column, such as a match the find bar
            // found: shown in the column, and kept in the note so the next
            // search goes on from it.
            guard let (b, c) = ColumnBlocks.column(at: new.location, in: blocks), b < overlays.count, c < overlays[b].editors.count else { return nil }
            let column = blocks[b].columns[c].range
            guard NSMaxRange(new) <= NSMaxRange(column) else { return nil }
            let inColumn = NSRange(location: new.location - column.location, length: new.length)
            let target = overlays[b].editors[c].textView
            if NSMaxRange(inColumn) <= (target.string as NSString).length {
                target.setSelectedRange(inColumn)
            }
            if textView.window?.firstResponder === textView { requestFocus(block: b, column: c, selection: inColumn) }
            return new
        }
        guard let b = blockIndex(containing: new.location) else { return nil }
        let block = blocks[b]
        if !verticalMove, let (hitBlock, c) = ColumnBlocks.column(at: new.location, in: blocks), hitBlock == b {
            requestFocus(block: b, column: c, selection: NSRange(location: new.location - block.columns[c].range.location, length: 0))
        } else {
            // An arrow key from the line above or below: the column under the caret.
            let fromAbove = old.location < block.range.location
            let c = b < overlays.count ? overlays[b].column(atX: caretX(old, in: textView)) : 0
            requestFocus(block: b, column: c, selection: fromAbove ? NSRange(location: 0, length: 0) : nil)
        }
        return safeSelection(old)
    }

    /// Moves the caret into a column when the note's text view has it. One
    /// placed before the text view is in a window waits for it to take focus;
    /// any other selection change, such as one made while the text changes, doesn't move it.
    private func requestFocus(block b: Int, column c: Int, selection: NSRange?) {
        guard let textView else { return }
        if textView.window?.firstResponder === textView {
            DispatchQueue.main.async { [weak self] in self?.focus(block: b, column: c, selection: selection) }
        } else if textView.window == nil {
            let length = b < overlays.count && c < overlays[b].editors.count ? (overlays[b].editors[c].textView.string as NSString).length : 0
            deferredFocus = (b, c, selection ?? NSRange(location: length, length: 0), Date())
        }
    }

    /// The note's text view took focus: hand it on to a column it was meant
    /// for, and never leave its caret on a hidden line.
    func textViewDidFocus() {
        guard !blocks.isEmpty, let textView else { return }
        if let deferred = deferredFocus {
            deferredFocus = nil
            if Date().timeIntervalSince(deferred.at) < 1 {
                DispatchQueue.main.async { [weak self] in self?.focus(block: deferred.block, column: deferred.column, selection: deferred.selection) }
                return
            }
        }
        guard let b = blockIndex(containing: textView.selectedRange().location) else { return }
        if let location = safeLocation(near: b) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
        } else {
            DispatchQueue.main.async { [weak self] in self?.focus(block: b, column: 0, selection: NSRange(location: 0, length: 0)) }
        }
    }

    private func safeSelection(_ old: NSRange) -> NSRange {
        guard let b = blockIndex(containing: old.location) else { return old }
        return NSRange(location: safeLocation(near: b) ?? old.location, length: 0)
    }

    /// The start of the line after the block, or the end of the line before it.
    private func safeLocation(near b: Int) -> Int? {
        guard let textView else { return nil }
        let length = (textView.string as NSString).length
        let after = NSMaxRange(blocks[b].range) + 1
        if after <= length, blockIndex(containing: after) == nil { return after }
        let before = blocks[b].range.location - 1
        if before >= 0, blockIndex(containing: before) == nil { return before }
        return nil
    }

    private func caretX(_ range: NSRange, in textView: NSTextView) -> CGFloat {
        guard let window = textView.window else { return 0 }
        let screen = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        return textView.convert(window.convertFromScreen(screen), from: nil).minX
    }

    func focus(block b: Int, column c: Int, selection: NSRange?) {
        guard b < overlays.count, c < overlays[b].editors.count else { return }
        let target = overlays[b].editors[c].textView
        let length = (target.string as NSString).length
        var range = selection ?? NSRange(location: length, length: 0)
        range.location = min(range.location, length)
        range.length = min(range.length, length - range.location)
        target.window?.makeFirstResponder(target)
        target.setSelectedRange(range)
        target.scrollRangeToVisible(range)
    }

    /// The caret at a location of the note: in the column holding it, or in the note's text view.
    private func focus(location: Int) {
        guard let textView else { return }
        if let (b, c) = ColumnBlocks.column(at: location, in: blocks) {
            focus(block: b, column: c, selection: NSRange(location: location - blocks[b].columns[c].range.location, length: 0))
            return
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
    }

    private func indices(of editor: ColumnEditor, in overlay: ColumnsOverlay) -> (Int, Int)? {
        guard let b = overlays.firstIndex(where: { $0 === overlay }),
              let c = overlay.editors.firstIndex(where: { $0 === editor }) else { return nil }
        return (b, c)
    }

    /// Where a column's caret is in the whole note.
    private func caretLocation(of editor: ColumnEditor, caret: Int? = nil) -> Int? {
        for (b, overlay) in overlays.enumerated() where b < blocks.count {
            if let c = overlay.editors.firstIndex(where: { $0 === editor }), c < blocks[b].columns.count {
                return blocks[b].columns[c].range.location + (caret ?? editor.textView.selectedRange().location)
            }
        }
        return nil
    }

    // MARK: Keys

    /// Arrow keys and Backspace at the edge of a column's text.
    private func handle(_ edge: UgoTextView.Edge, from editor: ColumnEditor, in overlay: ColumnsOverlay) -> Bool {
        guard let (b, c) = indices(of: editor, in: overlay), b < blocks.count else { return false }
        let count = overlay.editors.count
        switch edge {
        case .left:
            if c > 0 { focus(block: b, column: c - 1, selection: nil) } else { leave(block: b, downward: false) }
        case .right:
            if c + 1 < count { focus(block: b, column: c + 1, selection: NSRange(location: 0, length: 0)) } else { leave(block: b, downward: true) }
        case .up:
            leave(block: b, downward: false)
        case .down:
            leave(block: b, downward: true)
        case .deleteBackward:
            if editor.textView.string.isEmpty {
                // Takes the column out; the text view the key went to goes with it, so not now.
                let start = blocks[b].range.location
                DispatchQueue.main.async { [weak self] in self?.removeColumn(c, ofBlockAt: start) }
            } else if c > 0 {
                focus(block: b, column: c - 1, selection: nil)
            } else {
                leave(block: b, downward: false)
            }
        }
        return true
    }

    /// Back in the note's text, on the line above the block or below it, making one if there is none.
    private func leave(block b: Int, downward: Bool) {
        guard let textView else { return }
        let block = blocks[b]
        let length = (textView.string as NSString).length
        let location: Int
        if downward {
            if NSMaxRange(block.range) >= length {
                textView.replace(NSRange(location: length, length: 0), with: "\n", select: NSRange(location: length + 1, length: 0))
                location = length + 1
            } else {
                location = NSMaxRange(block.range) + 1
            }
        } else if block.range.location == 0 {
            textView.replace(NSRange(location: 0, length: 0), with: "\n", select: NSRange(location: 0, length: 0))
            location = 0
        } else {
            location = block.range.location - 1
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// Backspace in an empty column takes it out. With one column left the
    /// block goes and its text stays as ordinary text.
    private func removeColumn(_ c: Int, ofBlockAt start: Int) {
        guard let textView, let b = blocks.firstIndex(where: { $0.range.location == start }), c < blocks[b].columns.count else { return }
        let block = blocks[b]
        let ns = textView.string as NSString
        var texts = block.columns.map { ns.substring(with: $0.range) }
        texts.remove(at: c)
        if texts.count == 1 {
            let text = texts[0]
            let caret = NSRange(location: start + (text as NSString).length, length: 0)
            textView.window?.makeFirstResponder(textView)
            textView.replace(block.range, with: text, select: caret)
            return
        }
        let replacement = ColumnBlocks.block(texts)
        let after = min(start + (replacement as NSString).length + 1, ns.length - block.range.length + (replacement as NSString).length)
        textView.replace(block.range, with: replacement, select: NSRange(location: after, length: 0))
        if let nb = blocks.firstIndex(where: { $0.range.location == start }) {
            focus(block: nb, column: max(c - 1, 0), selection: c > 0 ? nil : NSRange(location: 0, length: 0))
        }
    }

    /// `/columns 3` and the like, then Return: the line becomes a block of empty columns.
    func insertBlockForSlashCommand() -> Bool {
        guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let ns = storage.string as NSString
        var start = 0
        var contentsEnd = 0
        ns.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        guard selection.location == contentsEnd, contentsEnd > start,
              let count = ColumnBlocks.slashCommand(ns.substring(with: NSRange(location: start, length: contentsEnd - start))) else { return false }
        if let info = storage.attribute(.ugoBlock, at: start, effectiveRange: nil) as? BlockInfo, info.kind == .code { return false }
        let atEnd = contentsEnd == ns.length
        let block = ColumnBlocks.emptyBlock(columns: count) + (atEnd ? "\n" : "")
        let after = start + (block as NSString).length + (atEnd ? 0 : 1)
        textView.replace(NSRange(location: start, length: contentsEnd - start), with: block, select: NSRange(location: after, length: 0))
        if let b = blocks.firstIndex(where: { $0.range.location == start }) {
            focus(block: b, column: 0, selection: NSRange(location: 0, length: 0))
        }
        return true
    }

    /// Backspace at the start of the line under a block would join that line
    /// onto the closing `:::`. The caret goes up into the last column instead;
    /// an empty line is simply removed.
    func deleteBackward() -> Bool {
        guard !blocks.isEmpty, let textView else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0, let b = blocks.firstIndex(where: { NSMaxRange($0.range) + 1 == selection.location }) else { return false }
        let ns = textView.string as NSString
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: selection)
        guard contentsEnd > selection.location, b < overlays.count else { return false }
        focus(block: b, column: overlays[b].editors.count - 1, selection: nil)
        return true
    }

    /// Delete at the end of the line above a block would join the `::: columns` line onto it.
    func deleteForward() -> Bool {
        guard !blocks.isEmpty, let textView else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0, blocks.contains(where: { $0.range.location - 1 == selection.location }) else { return false }
        let ns = textView.string as NSString
        let line = ns.lineRange(for: selection)
        // An empty line just goes.
        guard line.location < selection.location else { return false }
        NSSound.beep()
        return true
    }
}

/// One column's text view, with the coordinator that styles it.
@MainActor
final class ColumnEditor {
    let textView: UgoTextView
    let coordinator: MarkdownEditor.Coordinator
    var onChange: ((String) -> Void)?
    /// Shown while the column is empty, so it can be found. A label, since
    /// overriding the text view's drawing would turn TextKit 2 off.
    private let placeholder = NSTextField(labelWithString: "Empty column")

    init(text: String, theme: MarkdownTheme) {
        let relay = Relay()
        coordinator = MarkdownEditor.Coordinator(text: Binding(get: { "" }, set: { relay.send($0) }), theme: theme, allowsColumns: false)
        textView = UgoTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        MarkdownEditor.configure(textView, coordinator: coordinator, text: text)
        textView.usesFindBar = false
        textView.fixedInset = .zero
        placeholder.isSelectable = false
        placeholder.refusesFirstResponder = true
        textView.addSubview(placeholder)
        stylePlaceholder(theme)
        relay.target = self
    }

    private func stylePlaceholder(_ theme: MarkdownTheme) {
        placeholder.font = theme.body
        placeholder.textColor = theme.marker
        placeholder.sizeToFit()
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        // At the foot of the first line, where the paragraph style puts the text.
        let y = (theme.paragraph.minimumLineHeight - placeholder.frame.height).rounded()
        placeholder.setFrameOrigin(NSPoint(x: padding - 2, y: max(0, y)))
        updatePlaceholder()
    }

    func updatePlaceholder() {
        placeholder.isHidden = !textView.string.isEmpty
    }


    /// Takes text and theme from the note. Returns true when either changed, so the height may have.
    func set(text: String, theme: MarkdownTheme) -> Bool {
        let current = coordinator.highlighter.theme
        let themeChanged = current.fontSize != theme.fontSize || current.palette != theme.palette
        if themeChanged {
            coordinator.highlighter.setTheme(theme)
            textView.typingAttributes = theme.baseAttributes
            textView.textColor = theme.text
            textView.insertionPointColor = theme.caret
            coordinator.highlightAll()
            stylePlaceholder(theme)
        }
        guard textView.string != text else { return themeChanged }
        let selection = textView.selectedRange()
        coordinator.lastPushed = text
        textView.string = text
        coordinator.highlightAll()
        coordinator.clearUndo()
        updatePlaceholder()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        return true
    }

    func contentHeight() -> CGFloat {
        guard let layout = textView.textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.height + textView.textContainerInset.height * 2
    }

    @MainActor
    private final class Relay {
        weak var target: ColumnEditor?
        func send(_ text: String) {
            target?.updatePlaceholder()
            target?.onChange?(text)
        }
    }
}

/// The row of a block's column text views, laid over its `::: columns` line.
final class ColumnsOverlay: NSView {
    private(set) var editors: [ColumnEditor] = []
    var theme: MarkdownTheme? {
        didSet { if oldValue?.fontSize != theme?.fontSize || oldValue?.palette != theme?.palette { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    private var gap: CGFloat { ((theme?.fontSize ?? 15) * 2).rounded() }

    func setEditors(_ new: [ColumnEditor]) {
        for editor in editors { editor.textView.removeFromSuperview() }
        editors = new
        for editor in new { addSubview(editor.textView) }
        arrange(width: bounds.width, height: bounds.height)
        needsDisplay = true
    }

    func arrange(width: CGFloat, height: CGFloat) {
        guard !editors.isEmpty else { return }
        let n = CGFloat(editors.count)
        let columnWidth = max(20, ((width - gap * (n - 1)) / n).rounded(.down))
        for (i, editor) in editors.enumerated() {
            let frame = NSRect(x: CGFloat(i) * (columnWidth + gap), y: 0, width: columnWidth, height: height)
            if editor.textView.frame != frame { editor.textView.frame = frame }
        }
        needsDisplay = true
    }

    func contentHeight() -> CGFloat {
        editors.map { $0.contentHeight() }.max() ?? 0
    }

    /// The column under an x in the note's text view, or the nearest one.
    func column(atX x: CGFloat) -> Int {
        let local = x - frame.minX
        guard let i = editors.firstIndex(where: { local < $0.textView.frame.maxX + gap / 2 }) else { return max(editors.count - 1, 0) }
        return i
    }

    /// A faint rule down the middle of each gap, so empty columns still show where they are.
    override func draw(_ dirtyRect: NSRect) {
        guard let theme, editors.count > 1 else { return }
        theme.hairline.setFill()
        for editor in editors.dropFirst() {
            let x = (editor.textView.frame.minX - gap / 2).rounded()
            NSRect(x: x, y: 2, width: 1, height: max(0, bounds.height - 4)).fill()
        }
    }

    /// A click in a gap goes to the end of the nearest column.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nearest = editors.min(by: { abs($0.textView.frame.midX - point.x) < abs($1.textView.frame.midX - point.x) }) else { return }
        let textView = nearest.textView
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }
}
#endif
