import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// What kind of block a paragraph is, stored on its first character so the
/// layout can draw bullets, checkboxes and quote bars where the hidden
/// Markdown markers used to be.
final class BlockInfo: NSObject {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet
        /// The shown label and where it starts, in points from the container edge.
        case ordered(label: String, x: CGFloat)
        case task(done: Bool)
        case quote
        case rule
        case fence
        case code
    }

    let kind: Kind
    /// Where the paragraph's text starts, in points from the container edge.
    let indent: CGFloat
    /// True on the paragraph the caret is in: markers are shown, nothing is drawn for them.
    let revealed: Bool

    init(kind: Kind, indent: CGFloat, revealed: Bool) {
        self.kind = kind
        self.indent = indent
        self.revealed = revealed
    }

    var wantsDecoration: Bool {
        guard !revealed else { return false }
        switch kind {
        case .bullet, .ordered, .task, .quote, .rule: return true
        default: return false
        }
    }
}

extension NSAttributedString.Key {
    static let ugoBlock = NSAttributedString.Key("app.ugo.block")
    /// The URL of a Markdown link, set on its label.
    static let ugoLink = NSAttributedString.Key("app.ugo.link")
}

/// A `[label](url)` link in the text.
struct MarkdownLink: Equatable {
    /// The whole link, brackets and URL included.
    let range: NSRange
    let label: NSRange
    let url: String
}

/// Fonts, colors and spacing for the editor, built once per font size.
struct MarkdownTheme {
    let fontSize: CGFloat
    let body: PlatformFont
    let code: PlatformFont
    /// Numbered list labels: equal-width digits, so 10, 11 and 12 line up.
    let listNumber: PlatformFont
    let headings: [PlatformFont]
    /// The fixed theme the colours come from, nil for the system colours.
    let palette: ThemePalette?
    let text: PlatformColor
    let heading: PlatformColor
    let marker: PlatformColor
    let accent: PlatformColor
    let onAccent: PlatformColor
    let quoteBar: PlatformColor
    let caret: PlatformColor
    let quote: PlatformColor
    let link: PlatformColor
    /// The thick underline under a link label, a translucent accent.
    let linkUnderline: PlatformColor
    /// The same underline while the pointer is over the link.
    let linkUnderlineHover: PlatformColor
    let codeBackground: PlatformColor
    let checkboxBorder: PlatformColor
    let hairline: PlatformColor
    let paragraph: NSParagraphStyle
    let headingParagraph: NSParagraphStyle
    let hiddenMarker: [NSAttributedString.Key: Any]
    let indentUnit: CGFloat
    let quoteIndent: CGFloat

    init(fontSize: CGFloat, palette: ThemePalette? = nil) {
        self.fontSize = fontSize
        self.palette = palette
        body = .systemFont(ofSize: fontSize)
        listNumber = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        code = .monospacedSystemFont(ofSize: (fontSize * 0.92).rounded(), weight: .regular)
        let scales: [CGFloat] = [1.7, 1.45, 1.25, 1.1, 1.0, 1.0]
        headings = scales.map { PlatformFont.boldSystemFont(ofSize: (fontSize * $0).rounded()) }
        if let palette {
            text = PlatformColor(hex: palette.text)
            heading = PlatformColor(hex: palette.heading)
            marker = PlatformColor(hex: palette.muted)
            accent = PlatformColor(hex: palette.accent)
            onAccent = PlatformColor(hex: palette.onAccent)
            quote = PlatformColor(hex: palette.muted)
            link = PlatformColor(hex: palette.link)
            codeBackground = PlatformColor(hex: palette.code)
            checkboxBorder = PlatformColor(hex: palette.checkboxBorder)
            hairline = PlatformColor(hex: palette.hairline)
            quoteBar = PlatformColor(hex: palette.quoteBar)
            caret = PlatformColor(hex: palette.caret)
            linkUnderline = accent.withAlphaComponent(0.35)
            linkUnderlineHover = accent
        } else {
            #if os(macOS)
            text = .labelColor
            marker = .tertiaryLabelColor
            accent = .controlAccentColor
            quote = .secondaryLabelColor
            link = .linkColor
            // withAlphaComponent resolves the label color for the appearance in
            // effect right now; a provider keeps it following light and dark mode.
            codeBackground = NSColor(name: nil) { _ in NSColor.labelColor.withAlphaComponent(0.07) }
            checkboxBorder = NSColor(name: nil) { _ in NSColor.labelColor.withAlphaComponent(0.4) }
            hairline = NSColor(name: nil) { _ in NSColor.labelColor.withAlphaComponent(0.15) }
            linkUnderline = NSColor(name: nil) { _ in NSColor.controlAccentColor.withAlphaComponent(0.4) }
            linkUnderlineHover = .controlAccentColor
            #else
            text = .label
            marker = .tertiaryLabel
            accent = .tintColor
            quote = .secondaryLabel
            link = .link
            codeBackground = UIColor { _ in UIColor.label.withAlphaComponent(0.07) }
            checkboxBorder = UIColor { _ in UIColor.label.withAlphaComponent(0.4) }
            hairline = UIColor { _ in UIColor.label.withAlphaComponent(0.15) }
            linkUnderline = UIColor { _ in UIColor.tintColor.withAlphaComponent(0.4) }
            linkUnderlineHover = .tintColor
            #endif
            heading = text
            onAccent = .white
            quoteBar = hairline
            caret = accent
        }
        let lineHeight = ((body.ascender - body.descender + body.leading) * 1.2).rounded(.up)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.lineSpacing = (fontSize * 0.12).rounded()
        p.paragraphSpacing = (fontSize * 0.4).rounded()
        paragraph = p
        let h = NSMutableParagraphStyle()
        h.minimumLineHeight = lineHeight
        h.paragraphSpacingBefore = (fontSize * 0.8).rounded()
        h.paragraphSpacing = (fontSize * 0.3).rounded()
        headingParagraph = h
        hiddenMarker = [.font: PlatformFont.systemFont(ofSize: 0.5), .foregroundColor: PlatformColor.clear]
        indentUnit = (fontSize * 1.5).rounded()
        quoteIndent = (fontSize * 1.1).rounded()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: text, .paragraphStyle: paragraph]
    }
}

/// Applies Markdown styling to an attributed string in place. Markers are
/// hidden everywhere except in the revealed paragraph, the one holding the
/// caret. Work is scoped to the paragraphs touched by an edit, extending to
/// the end of the document only when a fenced code block could have changed.
@MainActor
final class MarkdownHighlighter {
    private(set) var theme: MarkdownTheme
    /// The caret location. A link shows its brackets and URL only while the caret is inside it.
    var caret: Int?
    /// The note's blocks of columns. Their lines are hidden: the editor lays
    /// the columns over the `::: columns` line, which is made as tall as they are.
    var columnBlocks: [ColumnBlocks.Block] = []
    /// How tall each block's columns are, in the order of `columnBlocks`.
    var columnHeights: [CGFloat] = []
    private var indentStyles: [String: NSParagraphStyle] = [:]

    init(theme: MarkdownTheme) {
        self.theme = theme
    }

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
        indentStyles = [:]
    }

    // MARK: Patterns

    private static let heading = rx(#"^(#{1,6})[ \t]+"#)
    private static let quote = rx(#"^ {0,3}>[ \t]?"#)
    private static let task = rx(#"^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+|$)"#)
    private static let bullet = rx(#"^([ \t]*)[-*+][ \t]+"#)
    private static let ordered = rx(#"^([ \t]*)(\d{1,9})([.)])[ \t]+"#)
    private static let rule = rx(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let codeSpan = rx(#"`[^`\n]+`"#)
    private static let bold = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = rx(#"(?<![\w*_])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![\w*_])"#)
    private static let strike = rx(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let link = rx(#"\[([^\[\]\n]+)\]\(([^)\s]+)\)"#)

    /// The link the location falls strictly inside, so a caret just before or after it doesn't count.
    static func link(in ns: NSString, at location: Int) -> MarkdownLink? {
        guard location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        for m in link.matches(in: ns as String, range: line) where location > m.range.location && location < NSMaxRange(m.range) {
            return MarkdownLink(range: m.range, label: m.range(at: 1), url: ns.substring(with: m.range(at: 2)))
        }
        return nil
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    // MARK: Entry points

    func highlightAll(_ storage: NSMutableAttributedString, revealed: NSRange?) {
        let length = (storage.string as NSString).length
        guard length > 0 else { return }
        apply(storage, range: NSRange(location: 0, length: length), revealed: revealed)
    }

    /// `editedRange` is the range of the new text after an edit, or any range
    /// inside the paragraphs to restyle. `forceToEnd` when a code fence was removed.
    func highlight(_ storage: NSMutableAttributedString, editedRange: NSRange, forceToEnd: Bool, revealed: NSRange?) {
        let ns = storage.string as NSString
        let length = ns.length
        guard length > 0 else { return }

        var seed = editedRange
        if seed.location > length { seed.location = length }
        if NSMaxRange(seed) > length { seed.length = length - seed.location }
        if seed.length == 0, seed.location > 0 {
            seed = NSRange(location: seed.location - 1, length: 1)
        }
        var range = ns.paragraphRange(for: seed)
        // Numbers below the edit follow from the ones above, so restyle the rest of the list.
        while NSMaxRange(range) < length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            guard ListEditing.isListItem(ns, ListEditing.lineRange(ns, at: next.location)) else { break }
            range.length += next.length
        }

        var inFence = false
        var fenceStart = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: range.location), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            if Self.isFence(ns, lineRange), self.columnBlock(containing: lineRange.location) == nil {
                inFence.toggle()
                if inFence { fenceStart = lineRange.location }
            }
        }
        if inFence {
            range = NSRange(location: fenceStart, length: NSMaxRange(range) - fenceStart)
        }
        if forceToEnd || inFence || Self.containsFence(ns, in: range) {
            range = NSRange(location: range.location, length: length - range.location)
        }
        apply(storage, range: range, revealed: revealed)
    }

    // MARK: Fences

    nonisolated static func isFence(_ ns: NSString, _ lineRange: NSRange) -> Bool {
        var i = lineRange.location
        let end = NSMaxRange(lineRange)
        var spaces = 0
        while i < end, spaces < 3, ns.character(at: i) == 0x20 {
            i += 1
            spaces += 1
        }
        guard i + 3 <= end else { return false }
        let c = ns.character(at: i)
        guard c == 0x60 || c == 0x7E else { return false }
        return ns.character(at: i + 1) == c && ns.character(at: i + 2) == c
    }

    static func containsFence(_ ns: NSString, in range: NSRange) -> Bool {
        var found = false
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            if isFence(ns, lineRange) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Styling

    private func apply(_ storage: NSMutableAttributedString, range: NSRange, revealed: NSRange?) {
        let string = storage.string
        let ns = string as NSString
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: range)
        var inFence = false
        var numbering = listNumbering(ns, before: range.location)
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, enclosingRange, _ in
            if let block = self.columnBlock(containing: lineRange.location) {
                self.hideColumnLine(storage, block: block, lineRange: lineRange, enclosingRange: enclosingRange)
                numbering.reset()
                return
            }
            let isRevealed = revealed.map { NSLocationInRange($0.location, enclosingRange) || ($0.location == NSMaxRange(enclosingRange) && enclosingRange.length == lineRange.length) } ?? false
            self.styleLine(storage, string: string, ns: ns, lineRange: lineRange, revealed: isRevealed, inFence: &inFence, numbering: &numbering)
        }
        storage.endEditing()
    }

    // MARK: Columns

    /// The index of the block of columns whose lines include `location`.
    func columnBlock(containing location: Int) -> Int? {
        guard !columnBlocks.isEmpty else { return nil }
        return columnBlocks.firstIndex { location >= $0.range.location && location <= NSMaxRange($0.range) }
    }

    /// The `::: columns` line stands as tall as the columns laid over it; the
    /// other lines of the block take no room at all.
    private func hideColumnLine(_ storage: NSMutableAttributedString, block: Int, lineRange: NSRange, enclosingRange: NSRange) {
        let style: NSParagraphStyle
        if lineRange.location == columnBlocks[block].opening.location {
            let height = block < columnHeights.count ? columnHeights[block] : theme.paragraph.minimumLineHeight
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = height
            p.maximumLineHeight = height
            p.paragraphSpacing = theme.paragraph.paragraphSpacing
            style = p
        } else {
            style = hiddenLine
        }
        var attributes = theme.hiddenMarker
        attributes[.paragraphStyle] = style
        storage.setAttributes(attributes, range: enclosingRange)
    }

    private lazy var hiddenLine: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.01
        p.maximumLineHeight = 0.01
        return p
    }()

    /// The numbering state at `location`, from the list lines just above it.
    private func listNumbering(_ ns: NSString, before location: Int) -> ListNumbering {
        var lines: [ListEditing.Line] = []
        var start = location
        while start > 0 {
            let line = ListEditing.parse(ns, ListEditing.lineRange(ns, at: start - 1))
            guard line.marker != nil else { break }
            lines.append(line)
            start = ListEditing.lineRange(ns, at: start - 1).location
        }
        var numbering = ListNumbering()
        for line in lines.reversed() {
            if case .ordered(let number, _, _) = line.marker {
                numbering.advance(level: line.level, written: number)
            } else {
                numbering.advance(level: line.level, written: nil)
            }
        }
        return numbering
    }

    private func styleLine(_ storage: NSMutableAttributedString, string: String, ns: NSString, lineRange: NSRange, revealed: Bool, inFence: inout Bool, numbering: inout ListNumbering) {
        var isListItem = false
        defer { if !isListItem { numbering.reset() } }
        if Self.isFence(ns, lineRange) {
            inFence.toggle()
            storage.addAttributes([.font: theme.code, .foregroundColor: theme.marker, .backgroundColor: theme.codeBackground], range: lineRange)
            block(storage, .fence, indent: 0, revealed: revealed, range: lineRange)
            return
        }
        if inFence {
            storage.addAttributes([.font: theme.code, .backgroundColor: theme.codeBackground], range: lineRange)
            block(storage, .code, indent: 0, revealed: revealed, range: lineRange)
            return
        }
        guard lineRange.length > 0 else { return }

        // Heading markers stay hidden on the caret line too, as in Notion: typing
        // "## " turns the line into a heading and the hashes disappear.
        if let m = Self.heading.firstMatch(in: string, range: lineRange) {
            let level = m.range(at: 1).length
            let font = theme.headings[level - 1]
            storage.addAttributes([.font: font, .foregroundColor: theme.heading, .paragraphStyle: theme.headingParagraph], range: lineRange)
            hideListMarker(storage, ns, m.range, font: font)
            block(storage, .heading(level), indent: 0, revealed: revealed, range: lineRange)
            styleInline(storage, string: string, range: rest(of: lineRange, after: m.range), revealed: revealed)
            return
        }
        if Self.rule.firstMatch(in: string, range: lineRange) != nil {
            marker(storage, lineRange, revealed: revealed)
            block(storage, .rule, indent: 0, revealed: revealed, range: lineRange)
            return
        }
        if let m = Self.quote.firstMatch(in: string, range: lineRange) {
            storage.addAttributes([.foregroundColor: theme.quote, .paragraphStyle: indentedParagraph(theme.quoteIndent, key: "quote")], range: lineRange)
            marker(storage, m.range, revealed: revealed)
            block(storage, .quote, indent: theme.quoteIndent, revealed: revealed, range: lineRange)
            styleInline(storage, string: string, range: rest(of: lineRange, after: m.range), revealed: revealed)
            return
        }
        // List markers stay hidden even on the caret line, as in Notion; the
        // editor keeps the caret out of them.
        if let m = Self.task.firstMatch(in: string, range: lineRange) {
            let level = nesting(ns, m.range(at: 1))
            isListItem = true
            numbering.advance(level: level, written: nil)
            let indent = theme.indentUnit * CGFloat(level + 1)
            storage.addAttribute(.paragraphStyle, value: indentedParagraph(indent, key: "list\(level)"), range: lineRange)
            hideListMarker(storage, ns, m.range)
            let done = ns.character(at: m.range(at: 2).location) != 0x20
            let remainder = rest(of: lineRange, after: m.range)
            if done {
                storage.addAttributes([.foregroundColor: theme.quote, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: remainder)
            }
            block(storage, .task(done: done), indent: indent, revealed: false, range: lineRange)
            styleInline(storage, string: string, range: remainder, revealed: revealed)
            return
        }
        if let m = Self.bullet.firstMatch(in: string, range: lineRange) {
            let level = nesting(ns, m.range(at: 1))
            isListItem = true
            numbering.advance(level: level, written: nil)
            let indent = theme.indentUnit * CGFloat(level + 1)
            storage.addAttribute(.paragraphStyle, value: indentedParagraph(indent, key: "list\(level)"), range: lineRange)
            hideListMarker(storage, ns, m.range)
            block(storage, .bullet, indent: indent, revealed: false, range: lineRange)
            styleInline(storage, string: string, range: rest(of: lineRange, after: m.range), revealed: revealed)
            return
        }
        if let m = Self.ordered.firstMatch(in: string, range: lineRange) {
            let level = nesting(ns, m.range(at: 1))
            isListItem = true
            let written = Int(ns.substring(with: m.range(at: 2))) ?? 1
            let number = numbering.advance(level: level, written: written) ?? written
            let label = ListNumbering.label(number, level: level) + ns.substring(with: m.range(at: 3))
            // Numbers sit left-aligned where a bullet would be; a label too wide
            // for that space pushes its own item's text along, as in Notion.
            let base = theme.indentUnit * CGFloat(level)
            let x = base + (theme.fontSize * 0.2).rounded()
            let width = NSAttributedString(string: label, attributes: [.font: theme.listNumber]).size().width
            let indent = max(base + theme.indentUnit, (x + width + theme.fontSize * 0.4).rounded(.up))
            storage.addAttribute(.paragraphStyle, value: indentedParagraph(indent, key: "ordered\(indent)"), range: lineRange)
            hideListMarker(storage, ns, m.range)
            block(storage, .ordered(label: label, x: x), indent: indent, revealed: false, range: lineRange)
            styleInline(storage, string: string, range: rest(of: lineRange, after: m.range), revealed: revealed)
            return
        }
        block(storage, .paragraph, indent: 0, revealed: revealed, range: lineRange)
        styleInline(storage, string: string, range: lineRange, revealed: revealed)
    }

    private func styleInline(_ storage: NSMutableAttributedString, string: String, range: NSRange, revealed: Bool) {
        guard range.length >= 2 else { return }
        var reserved: [NSRange] = []
        for m in Self.codeSpan.matches(in: string, range: range) {
            storage.addAttributes([.font: theme.code, .backgroundColor: theme.codeBackground], range: m.range)
            marker(storage, NSRange(location: m.range.location, length: 1), revealed: revealed)
            marker(storage, NSRange(location: NSMaxRange(m.range) - 1, length: 1), revealed: revealed)
            reserved.append(m.range)
        }
        func isFree(_ r: NSRange) -> Bool {
            !reserved.contains { NSIntersectionRange($0, r).length > 0 }
        }
        for m in Self.bold.matches(in: string, range: range) where isFree(m.range) {
            addTraits(storage, range: m.range(at: 2), bold: true)
            let n = m.range(at: 1).length
            marker(storage, m.range(at: 1), revealed: revealed)
            marker(storage, NSRange(location: NSMaxRange(m.range) - n, length: n), revealed: revealed)
        }
        for m in Self.italic.matches(in: string, range: range) where isFree(m.range) {
            addTraits(storage, range: m.range(at: 2), italic: true)
            marker(storage, m.range(at: 1), revealed: revealed)
            marker(storage, NSRange(location: NSMaxRange(m.range) - 1, length: 1), revealed: revealed)
        }
        for m in Self.strike.matches(in: string, range: range) where isFree(m.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            marker(storage, NSRange(location: m.range.location, length: 2), revealed: revealed)
            marker(storage, NSRange(location: NSMaxRange(m.range) - 2, length: 2), revealed: revealed)
        }
        for m in Self.link.matches(in: string, range: range) where isFree(m.range) {
            let label = m.range(at: 1)
            let url = (string as NSString).substring(with: m.range(at: 2))
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: theme.linkUnderline, .ugoLink: url], range: label)
            storage.enumerateAttribute(.font, in: label, options: []) { value, r, _ in
                let font = (value as? PlatformFont) ?? theme.body
                storage.addAttribute(.font, value: font.medium(), range: r)
            }
            // The URL stays out of the way unless the caret is inside the link.
            let open = caret.map { $0 > m.range.location && $0 < NSMaxRange(m.range) } ?? false
            let tail = NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label))
            marker(storage, NSRange(location: m.range.location, length: 1), revealed: open)
            marker(storage, tail, revealed: open)
            if !open {
                // Even in the tiny hidden font a long URL leaves a gap after the label.
                let width = NSAttributedString(string: (string as NSString).substring(with: tail), attributes: theme.hiddenMarker).size().width
                storage.addAttribute(.kern, value: -width / CGFloat(tail.length), range: tail)
            }
        }
    }

    // MARK: Helpers

    private func block(_ storage: NSMutableAttributedString, _ kind: BlockInfo.Kind, indent: CGFloat, revealed: Bool, range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.ugoBlock, value: BlockInfo(kind: kind, indent: indent, revealed: revealed), range: range)
    }

    private func marker(_ storage: NSMutableAttributedString, _ range: NSRange, revealed: Bool) {
        guard range.length > 0 else { return }
        if revealed {
            storage.addAttribute(.foregroundColor, value: theme.marker, range: range)
        } else {
            storage.addAttributes(theme.hiddenMarker, range: range)
        }
    }

    /// Hides a list or heading marker but keeps its last character, the space,
    /// in the line's font with its width kerned away. A line with no text yet
    /// would otherwise take its height from the tiny hidden font.
    private func hideListMarker(_ storage: NSMutableAttributedString, _ ns: NSString, _ range: NSRange, font: PlatformFont? = nil) {
        let font = font ?? theme.body
        marker(storage, range, revealed: false)
        let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
        let character = ns.substring(with: last)
        guard character != "\t" else { return }
        let width = NSAttributedString(string: character, attributes: [.font: font]).size().width
        storage.addAttributes([.font: font, .kern: -width], range: last)
    }

    private func rest(of line: NSRange, after prefix: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(prefix), length: NSMaxRange(line) - NSMaxRange(prefix))
    }

    /// Two spaces or one tab per nesting level.
    private func nesting(_ ns: NSString, _ whitespace: NSRange) -> Int {
        var width = 0
        for i in 0..<whitespace.length {
            width += ns.character(at: whitespace.location + i) == 0x09 ? 2 : 1
        }
        return min(width / 2, 6)
    }

    private func addTraits(_ storage: NSMutableAttributedString, range: NSRange, bold: Bool = false, italic: Bool = false) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            let font = (value as? PlatformFont) ?? theme.body
            guard font.pointSize > 1 else { return }
            storage.addAttribute(.font, value: font.adding(bold: bold, italic: italic), range: r)
        }
    }

    private func indentedParagraph(_ indent: CGFloat, key: String) -> NSParagraphStyle {
        if let cached = indentStyles[key] { return cached }
        // swiftlint:disable:next force_cast
        let style = theme.paragraph.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacing = (theme.fontSize * 0.15).rounded()
        // A hidden leading tab would still jump to the next tab stop and push the text right.
        style.tabStops = []
        style.defaultTabInterval = 1
        indentStyles[key] = style
        return style
    }
}

extension PlatformFont {
    /// The medium weight of the font, unless it is bold already. Keeps italic.
    func medium() -> PlatformFont {
        #if os(macOS)
        let traits = fontDescriptor.symbolicTraits
        guard !traits.contains(.bold) else { return self }
        let font = NSFont.systemFont(ofSize: pointSize, weight: .medium)
        return traits.contains(.italic) ? font.adding(bold: false, italic: true) : font
        #else
        let traits = fontDescriptor.symbolicTraits
        guard !traits.contains(.traitBold) else { return self }
        let font = UIFont.systemFont(ofSize: pointSize, weight: .medium)
        return traits.contains(.traitItalic) ? font.adding(bold: false, italic: true) : font
        #endif
    }

    func adding(bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

/// A TextKit 2 layout fragment that draws the bullet, checkbox, number,
/// quote bar or rule a paragraph's hidden markers stand for.
final class DecoratedLayoutFragment: NSTextLayoutFragment {
    let info: BlockInfo
    let theme: MarkdownTheme

    init(textElement: NSTextElement, range: NSTextRange?, info: BlockInfo, theme: MarkdownTheme) {
        self.info = info
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// The fragment's origin is where the text starts, so the decoration lands
    /// in the paragraph's indent, left of it. The text view clips each fragment
    /// to this rectangle, which by default reaches only a few points past the
    /// text: widen it to the container edge or the decoration is cut off.
    override var renderingSurfaceBounds: CGRect {
        let surface = super.renderingSurfaceBounds
        let left = min(surface.minX, -(info.indent + theme.indentUnit))
        return CGRect(x: left, y: surface.minY, width: surface.maxX - left, height: surface.height)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first else { return }
        let bounds = line.typographicBounds
        let textStartX = point.x + bounds.minX
        let edgeX = textStartX - info.indent
        let midY = point.y + bounds.midY
        let gap = theme.indentUnit * 0.62
        context.saveGState()
        defer { context.restoreGState() }

        switch info.kind {
        case .bullet:
            let r = max(2, theme.fontSize * 0.17)
            context.setFillColor(theme.text.cgColor)
            context.fillEllipse(in: CGRect(x: textStartX - gap - r, y: midY - r, width: 2 * r, height: 2 * r))
        case .task(let done):
            let s = (theme.fontSize * 0.95).rounded()
            let rect = CGRect(x: (textStartX - gap - s / 2).rounded(), y: (midY - s / 2).rounded(), width: s, height: s)
            let path = CGPath(roundedRect: rect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            if done {
                context.setFillColor(theme.accent.cgColor)
                context.addPath(path)
                context.fillPath()
                context.setStrokeColor(theme.onAccent.cgColor)
                context.setLineWidth(1.8)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: rect.minX + s * 0.25, y: rect.midY))
                context.addLine(to: CGPoint(x: rect.minX + s * 0.43, y: rect.minY + s * 0.7))
                context.addLine(to: CGPoint(x: rect.maxX - s * 0.22, y: rect.minY + s * 0.3))
                context.strokePath()
            } else {
                context.setStrokeColor(theme.checkboxBorder.cgColor)
                context.setLineWidth(1.5)
                context.addPath(path)
                context.strokePath()
            }
        case .ordered(let label, let x):
            let string = NSAttributedString(string: label, attributes: [.font: theme.listNumber, .foregroundColor: theme.text])
            // Without .usesLineFragmentOrigin the rectangle's origin is the baseline.
            let baseline = point.y + bounds.minY + line.glyphOrigin.y
            string.draw(with: CGRect(x: edgeX + x, y: baseline, width: 0, height: 0), options: [], context: nil)
        case .quote:
            context.setFillColor(theme.quoteBar.cgColor)
            context.fill(CGRect(x: edgeX + 3, y: point.y + 2, width: 3, height: layoutFragmentFrame.height - 4))
        case .rule:
            context.setFillColor(theme.hairline.cgColor)
            context.fill(CGRect(x: point.x, y: midY.rounded(), width: layoutFragmentFrame.width, height: 1))
        default:
            break
        }
    }
}
