#if os(macOS)
import AppKit

/// Presents a note full screen, one slide at a time. Runs on the external
/// display when one is connected, else over the window's own screen. Esc
/// ends it and leaves the caret at the heading of the slide it ended on.
@MainActor
final class Presentation {
    private static var current: Presentation?

    private let deck: SlideDeck
    private let window: PresentationWindow
    private let stage: SlideStageView
    private weak var returnTextView: NSTextView?
    private weak var returnWindow: NSWindow?
    private let savedOptions: NSApplication.PresentationOptions
    private var index: Int

    /// Starts on the slide the caret is in when the note's editor has focus,
    /// else on the first slide of the note the focused pane shows.
    static func start(appState: AppState, store: NotesStore) {
        guard current == nil else { return }
        let keyWindow = NSApp.keyWindow
        let markdown: String
        var caret = 0
        var textView: NSTextView?
        if let editor = keyWindow?.firstResponder as? UgoTextView {
            markdown = editor.string
            caret = editor.selectedRange().location
            textView = editor
        } else if let id = appState.layout.activeNoteID {
            markdown = store.content(of: id)
        } else {
            NSSound.beep()
            return
        }
        let deck = SlideDeck(markdown: markdown)
        guard !deck.slides.isEmpty else {
            NSSound.beep()
            return
        }
        current = Presentation(deck: deck, index: deck.index(containing: caret), textView: textView, from: keyWindow)
    }

    private init(deck: SlideDeck, index: Int, textView: NSTextView?, from origin: NSWindow?) {
        self.deck = deck
        self.index = index
        returnTextView = textView
        returnWindow = origin
        savedOptions = NSApp.presentationOptions

        let originScreen = origin?.screen ?? NSScreen.main
        let screen = NSScreen.screens.first { $0 != originScreen } ?? originScreen ?? NSScreen.screens[0]
        let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "") ?? .system

        window = PresentationWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        stage = SlideStageView(frame: NSRect(origin: .zero, size: screen.frame.size), palette: theme.palette)
        window.setFrame(screen.frame, display: false)
        window.contentView = stage
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.appearance = NSApp.appearance
        window.onKey = { [weak self] in self?.handle($0) }

        // Covering the window's own screen hides the menu bar and the Dock there;
        // an external display has neither in the way once the window sits above them.
        if screen == originScreen {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.level = .mainMenu + 1
        show()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func show() {
        stage.show(deck.slides[index], number: index + 1, of: deck.slides.count)
    }

    private func go(to newIndex: Int) {
        let clamped = min(max(newIndex, 0), deck.slides.count - 1)
        guard clamped != index else { return }
        index = clamped
        show()
    }

    private func handle(_ key: PresentationWindow.Key) {
        switch key {
        case .next: go(to: index + 1)
        case .previous: go(to: index - 1)
        case .first: go(to: 0)
        case .last: go(to: deck.slides.count - 1)
        case .end: end()
        }
    }

    private func end() {
        window.orderOut(nil)
        NSApp.presentationOptions = savedOptions
        if let returnWindow {
            returnWindow.makeKeyAndOrderFront(nil)
            if let textView = returnTextView {
                let location = min(deck.slides[index].location, (textView.string as NSString).length)
                returnWindow.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            }
        }
        Presentation.current = nil
    }
}

/// A borderless window that can take keys and turns them into slide moves.
final class PresentationWindow: NSWindow {
    enum Key {
        case next, previous, first, last, end
    }

    var onKey: ((Key) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key: Key? = switch event.keyCode {
        case 124, 125, 49, 121, 36, 76: .next // → ↓ space ⇟ ↩ enter
        case 123, 126, 116, 51: .previous // ← ↑ ⇞ ⌫
        case 115: .first // home
        case 119: .last // end
        case 53: .end // esc
        default: nil
        }
        if let key { onKey?(key) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onKey?(.end)
    }

    override func mouseDown(with event: NSEvent) {
        onKey?(.next)
    }

    override func rightMouseDown(with event: NSEvent) {
        onKey?(.previous)
    }
}

/// Paints the theme's background and lays one slide out in it: the text as
/// large as fits, down to a floor under which the slide scrolls instead.
final class SlideStageView: NSView, @preconcurrency NSTextLayoutManagerDelegate {
    private let palette: ThemePalette?
    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let counter = NSTextField(labelWithString: "")
    private let highlighter: MarkdownHighlighter
    private var slide: SlideDeck.Slide?

    init(frame: NSRect, palette: ThemePalette?) {
        self.palette = palette
        highlighter = MarkdownHighlighter(theme: MarkdownTheme(fontSize: 40, palette: palette))
        textView = NSTextView(usingTextLayoutManager: true)
        super.init(frame: frame)
        wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textLayoutManager?.delegate = self

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        counter.textColor = palette.map { NSColor(hex: $0.muted) } ?? .tertiaryLabelColor
        counter.alignment = .right
        addSubview(counter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (palette.map { NSColor(hex: $0.editor) } ?? .textBackgroundColor).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func show(_ slide: SlideDeck.Slide, number: Int, of count: Int) {
        self.slide = slide
        counter.stringValue = "\(number) / \(count)"
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        counter.frame = NSRect(x: size.width - 140, y: size.height - 36, width: 116, height: 18)
        guard let slide, let storage = textView.textStorage else { return }

        let margin = NSSize(width: (size.width * 0.08).rounded(), height: (size.height * 0.09).rounded())
        let area = NSSize(width: size.width - 2 * margin.width, height: size.height - 2 * margin.height)
        textView.textContainer?.size = NSSize(width: area.width, height: .greatestFiniteMagnitude)
        textView.frame.size.width = area.width

        // Largest body size whose text fits the area, stepping down to the floor.
        let ceiling = (size.height / 24).rounded()
        let floor = max(14, (size.height / 60).rounded())
        var fontSize = ceiling
        var height = typeset(slide, fontSize: fontSize, into: storage)
        while height > area.height, fontSize > floor {
            fontSize = max(floor, (fontSize * 0.9).rounded(.down))
            height = typeset(slide, fontSize: fontSize, into: storage)
        }

        let shown = min(height, area.height)
        let top = slide.isSection ? ((size.height - shown) / 2).rounded() : margin.height
        scrollView.frame = NSRect(x: margin.width, y: top, width: area.width, height: shown)
        textView.frame = NSRect(x: 0, y: 0, width: area.width, height: height)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Styles the slide at the font size and returns the height its text takes.
    private func typeset(_ slide: SlideDeck.Slide, fontSize: CGFloat, into storage: NSTextStorage) -> CGFloat {
        highlighter.setTheme(MarkdownTheme(fontSize: fontSize, palette: palette))
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: slide.markdown, attributes: highlighter.theme.baseAttributes))
        highlighter.highlightAll(storage, revealed: nil)
        if slide.isSection {
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.alignment = .center
                style.paragraphSpacingBefore = 0
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        storage.endEditing()
        guard let layoutManager = textView.textLayoutManager else { return 0 }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return ceil(layoutManager.usageBoundsForTextContainer.height)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let info = paragraph.attributedString.attribute(.ugoBlock, at: 0, effectiveRange: nil) as? BlockInfo, info.wantsDecoration {
            return DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange, info: info, theme: highlighter.theme)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
#endif
