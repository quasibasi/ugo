import Foundation

/// Numbers ordered list items the way they are shown: an item right after a
/// numbered sibling (deeper items in between don't count) is that sibling's
/// number plus one, whatever its Markdown says. Any other item keeps the
/// number it was written with, so a list can still start at 5.
struct ListNumbering {
    private var counters: [Int: Int] = [:]

    /// A line that is not a list item ends every list.
    mutating func reset() {
        counters.removeAll()
    }

    /// Feeds one list item; returns the number an ordered item shows.
    @discardableResult
    mutating func advance(level: Int, written: Int?) -> Int? {
        counters = counters.filter { $0.key <= level }
        guard let written else {
            counters[level] = nil
            return nil
        }
        let number = counters[level].map { $0 + 1 } ?? written
        counters[level] = number
        return number
    }

    /// True when the next ordered item at `level` would continue a run.
    func continues(level: Int) -> Bool {
        counters[level] != nil
    }

    /// 1, 2, 3 at the top level, then a, b, c, then i, ii, iii, repeating as in Notion.
    static func label(_ number: Int, level: Int) -> String {
        switch level % 3 {
        case 1: return letters(number)
        case 2: return roman(number) ?? String(number)
        default: return String(number)
        }
    }

    private static func letters(_ number: Int) -> String {
        guard number > 0 else { return String(number) }
        var n = number
        var result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(UInt8(97 + n % 26))) + result
            n /= 26
        }
        return result
    }

    private static func roman(_ number: Int) -> String? {
        guard number > 0, number < 4000 else { return nil }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = number
        var result = ""
        for (value, symbol) in table {
            while n >= value {
                result += symbol
                n -= value
            }
        }
        return result
    }
}

/// Notion-style list keys over plain Markdown. Enter continues a list, or
/// leaves it when the item is empty; Tab and Shift-Tab move an item together
/// with everything nested under it; Backspace at the start of an item turns it
/// into plain text. Numbered items are renumbered after each of these, so the
/// Markdown always says what is shown.
enum ListEditing {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    enum Result: Equatable {
        /// Not a list edit: the text view handles the key as usual.
        case unhandled
        /// A list key with nothing to do, such as Tab on the first item.
        case ignored
        case edit(Edit)
    }

    enum Marker: Equatable {
        /// The marker with the spaces after it, "- " or "- [x] ".
        case bullet(String)
        case task(String)
        case ordered(number: Int, delimiter: String, spacing: String)

        var text: String {
            switch self {
            case .bullet(let raw), .task(let raw): return raw
            case .ordered(let number, let delimiter, let spacing): return "\(number)\(delimiter)\(spacing)"
            }
        }

        /// The marker for a new item below this one: tasks start unticked.
        var fresh: Marker {
            switch self {
            case .bullet: return self
            case .task(let raw): return .task("\(raw.first ?? "-") [ ] ")
            case .ordered(let number, let delimiter, _): return .ordered(number: number, delimiter: delimiter, spacing: " ")
            }
        }
    }

    struct Line {
        var indent: String
        var marker: Marker?
        var content: String
        /// Index in the block before the edit; nil for a line the edit created.
        var id: Int?

        var level: Int { ListEditing.level(ofIndent: indent) }
        var prefixLength: Int { ((indent + (marker?.text ?? "")) as NSString).length }
        var text: String { indent + (marker?.text ?? "") + content }
    }

    // MARK: Parsing

    private static let task = rx(#"^([ \t]*)([-*+][ \t]+\[[ xX]\](?:[ \t]+|$))"#)
    private static let bullet = rx(#"^([ \t]*)([-*+][ \t]+)"#)
    private static let ordered = rx(#"^([ \t]*)(\d{1,9})([.)])([ \t]+)"#)
    private static let checkboxOpening = rx(#"^([ \t]*)(?:([-*+])[ \t]+)?\[ ?$"#)
    private static let rule = rx(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let heading = rx(#"^#{1,6}[ \t]+"#)
    private static let fence = rx(#"^ {0,3}(```|~~~)"#)

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Two spaces or one tab per nesting level.
    static func level(ofIndent indent: String) -> Int {
        let width = indent.unicodeScalars.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return min(width / 2, 6)
    }

    /// The line without its terminator.
    static func lineRange(_ ns: NSString, at location: Int) -> NSRange {
        var start = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    static func parse(_ ns: NSString, _ range: NSRange) -> Line {
        let line = ns.substring(with: range)
        let lns = line as NSString
        let whole = NSRange(location: 0, length: lns.length)
        if rule.firstMatch(in: line, range: whole) == nil {
            if let m = task.firstMatch(in: line, range: whole) {
                return Line(indent: lns.substring(with: m.range(at: 1)), marker: .task(lns.substring(with: m.range(at: 2))),
                            content: lns.substring(from: NSMaxRange(m.range)))
            }
            if let m = bullet.firstMatch(in: line, range: whole) {
                return Line(indent: lns.substring(with: m.range(at: 1)), marker: .bullet(lns.substring(with: m.range(at: 2))),
                            content: lns.substring(from: NSMaxRange(m.range)))
            }
            if let m = ordered.firstMatch(in: line, range: whole), let number = Int(lns.substring(with: m.range(at: 2))) {
                let marker = Marker.ordered(number: number, delimiter: lns.substring(with: m.range(at: 3)), spacing: lns.substring(with: m.range(at: 4)))
                return Line(indent: lns.substring(with: m.range(at: 1)), marker: marker, content: lns.substring(from: NSMaxRange(m.range)))
            }
        }
        return Line(indent: "", marker: nil, content: line)
    }

    static func isListItem(_ ns: NSString, _ range: NSRange) -> Bool {
        parse(ns, range).marker != nil
    }

    /// The length of a heading's hidden "## ", 0 when the line isn't a heading.
    /// A "# comment" inside a code block is not one.
    static func headingPrefixLength(_ ns: NSString, _ range: NSRange) -> Int {
        let line = ns.substring(with: range)
        guard let m = heading.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) else { return 0 }
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: range.location), options: .byLines) { text, _, _, _ in
            guard let text else { return }
            if fence.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil { inFence.toggle() }
        }
        return inFence ? 0 : m.range.length
    }

    /// Where the text of a list item or heading starts, after its hidden marker.
    static func contentStart(_ ns: NSString, _ range: NSRange) -> Int {
        let line = parse(ns, range)
        return range.location + (line.marker != nil ? line.prefixLength : headingPrefixLength(ns, range))
    }

    // MARK: Keys

    static func newline(_ ns: NSString, selection: NSRange) -> Result {
        if let edit = headingNewline(ns, selection: selection) { return edit }
        return run(ns, selection: selection) { lines, start, end in
            guard start.line == end.line, let marker = lines[start.line].marker else { return nil }
            let c = start.line
            let prefix = lines[c].prefixLength
            // A selection reaching into the marker is left to the text view.
            if start.column < prefix, end.column > start.column { return nil }
            var content = lines[c].content as NSString
            let from = max(0, start.column - prefix)
            let to = max(from, end.column - prefix)
            content = content.replacingCharacters(in: NSRange(location: from, length: to - from), with: "") as NSString

            if (content as String).trimmingCharacters(in: .whitespaces).isEmpty {
                // Enter on an empty item leaves the list one level at a time.
                if lines[c].level > 0 {
                    lines[c].content = content as String
                    outdent(&lines, targets: subtree(lines, of: [c]))
                } else {
                    lines[c] = Line(indent: "", marker: nil, content: "", id: lines[c].id)
                }
                return [(c, 0), (c, 0)]
            }
            if from == 0 {
                // At the start of the text: a new empty item above, the caret stays with the text.
                lines[c].content = content as String
                lines.insert(Line(indent: lines[c].indent, marker: marker.fresh, content: ""), at: c)
                return [(c + 1, 0), (c + 1, 0)]
            }
            let head = content.substring(to: from)
            let tail = content.substring(from: from)
            lines[c].content = head
            var next = Line(indent: lines[c].indent, marker: marker.fresh, content: tail)
            // At the end of an item that has children, the new item becomes the first child.
            if tail.isEmpty, c + 1 < lines.count, lines[c + 1].level > lines[c].level, let child = lines[c + 1].marker {
                next = Line(indent: lines[c + 1].indent, marker: child.fresh, content: "")
            }
            lines.insert(next, at: c + 1)
            return [(c + 1, 0), (c + 1, 0)]
        }
    }

    static func indent(_ ns: NSString, selection: NSRange) -> Result {
        run(ns, selection: selection) { lines, start, end in
            guard lines[start.line].marker != nil else { return nil }
            let targets = subtree(lines, of: selectedLines(start, end))
            let first = targets[0]
            let level = lines[first].level
            // Only an item with a sibling above it can be nested under that sibling.
            var j = first - 1
            while j >= 0, lines[j].level > level { j -= 1 }
            guard j >= 0, lines[j].level == level else { return [] }
            let caret = contentOffsets(lines, start, end)
            for i in targets { lines[i].indent = "\t" + lines[i].indent }
            return caret
        }
    }

    static func outdent(_ ns: NSString, selection: NSRange) -> Result {
        run(ns, selection: selection) { lines, start, end in
            guard lines[start.line].marker != nil else { return nil }
            let targets = subtree(lines, of: selectedLines(start, end))
            guard lines[targets[0]].level > 0 else { return [] }
            let caret = contentOffsets(lines, start, end)
            outdent(&lines, targets: targets)
            return caret
        }
    }

    /// Typing "]" to close "[" or "[ " at the start of a line, or right after a
    /// bullet, turns the line into an unticked task, as "[]" does in Notion.
    static func checkboxShortcut(_ ns: NSString, selection: NSRange) -> Result {
        guard selection.length == 0, selection.location <= ns.length else { return .unhandled }
        let line = lineRange(ns, at: selection.location)
        let head = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let hns = head as NSString
        guard let m = checkboxOpening.firstMatch(in: head, range: NSRange(location: 0, length: hns.length)) else { return .unhandled }
        let bullet = m.range(at: 2).location == NSNotFound ? "-" : hns.substring(with: m.range(at: 2))
        let replacement = hns.substring(with: m.range(at: 1)) + bullet + " [ ] "
        let caret = line.location + (replacement as NSString).length
        return .edit(Edit(range: NSRange(location: line.location, length: hns.length), replacement: replacement,
                          selection: NSRange(location: caret, length: 0)))
    }

    static func deleteBackward(_ ns: NSString, selection: NSRange) -> Result {
        guard selection.length == 0, selection.location <= ns.length else { return .unhandled }
        // Backspace at the start of a heading's text turns it into plain text.
        let line = lineRange(ns, at: selection.location)
        let heading = headingPrefixLength(ns, line)
        if heading > 0, selection.location == line.location + heading {
            return .edit(Edit(range: NSRange(location: line.location, length: heading), replacement: "",
                              selection: NSRange(location: line.location, length: 0)))
        }
        return run(ns, selection: selection) { lines, start, _ in
            let c = start.line
            guard lines[c].marker != nil, start.column == lines[c].prefixLength else { return nil }
            lines[c] = Line(indent: "", marker: nil, content: lines[c].content, id: lines[c].id)
            return [(c, 0), (c, 0)]
        }
    }

    /// Enter at the start of a heading's text opens an empty line above it
    /// rather than splitting the text from its hidden hashes.
    private static func headingNewline(_ ns: NSString, selection: NSRange) -> Result? {
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let line = lineRange(ns, at: selection.location)
        let heading = headingPrefixLength(ns, line)
        guard heading > 0, selection.location == line.location + heading, line.length > heading else { return nil }
        return .edit(Edit(range: NSRange(location: line.location, length: 0), replacement: "\n",
                          selection: NSRange(location: selection.location + 1, length: 0)))
    }

    // MARK: Machinery

    typealias Position = (line: Int, column: Int)

    /// Loads the list block around the selection, lets `change` rewrite its
    /// lines, renumbers them and returns the smallest edit that gets there.
    /// `change` returns nil when the key isn't a list edit, an empty array when
    /// it is but nothing should happen, or else the new selection's start and
    /// end as a line and an offset into that line's text after its marker.
    private static func run(_ ns: NSString, selection: NSRange,
                            _ change: (inout [Line], Position, Position) -> [(Int, Int)]?) -> Result {
        guard selection.location <= ns.length, NSMaxRange(selection) <= ns.length else { return .unhandled }
        let caretLine = lineRange(ns, at: selection.location)
        guard isListItem(ns, caretLine) else { return .unhandled }

        var ranges = [caretLine]
        while let first = ranges.first, first.location > 0 {
            let previous = lineRange(ns, at: first.location - 1)
            guard isListItem(ns, previous) else { break }
            ranges.insert(previous, at: 0)
        }
        while let last = ranges.last {
            let after = NSMaxRange(ns.paragraphRange(for: last))
            guard after > NSMaxRange(last), after < ns.length else { break }
            let next = lineRange(ns, at: after)
            guard isListItem(ns, next) else { break }
            ranges.append(next)
        }
        let blockRange = NSRange(location: ranges[0].location, length: NSMaxRange(ranges[ranges.count - 1]) - ranges[0].location)
        let oldBlock = ns.substring(with: blockRange)
        guard !oldBlock.contains("\r") else { return .unhandled }
        guard NSMaxRange(selection) <= NSMaxRange(blockRange) else { return .unhandled }

        func position(_ location: Int) -> Position {
            let i = ranges.lastIndex { $0.location <= location } ?? 0
            return (i, location - ranges[i].location)
        }
        var lines = ranges.enumerated().map { i, range -> Line in
            var line = parse(ns, range)
            line.id = i
            return line
        }
        let before = runStarts(lines)
        guard let caret = change(&lines, position(selection.location), position(NSMaxRange(selection))) else { return .unhandled }
        guard caret.count == 2 else { return .ignored }
        renumber(&lines, startedBefore: before)

        let newBlock = lines.map(\.text).joined(separator: "\n")
        guard newBlock != oldBlock else { return .ignored }
        var offsets: [Int] = []
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += (line.text as NSString).length + 1
        }
        func location(_ p: (Int, Int)) -> Int {
            let line = lines[p.0]
            return blockRange.location + offsets[p.0] + line.prefixLength + min(p.1, (line.content as NSString).length)
        }
        let selStart = location(caret[0])
        let selEnd = location(caret[1])

        let old = oldBlock as NSString
        let new = newBlock as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: blockRange.location + prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        return .edit(Edit(range: range, replacement: replacement, selection: NSRange(location: selStart, length: selEnd - selStart)))
    }

    /// The lines a selection touches; one ending at the very start of a line leaves that line out.
    private static func selectedLines(_ start: Position, _ end: Position) -> [Int] {
        let last = end.line > start.line && end.column == 0 ? end.line - 1 : end.line
        return Array(start.line...max(start.line, last))
    }

    /// The given lines plus everything nested under each, in order.
    private static func subtree(_ lines: [Line], of indices: [Int]) -> [Int] {
        var result = Set<Int>()
        for i in indices {
            result.insert(i)
            var j = i + 1
            while j < lines.count, lines[j].level > lines[i].level {
                result.insert(j)
                j += 1
            }
        }
        return result.sorted()
    }

    private static func outdent(_ lines: inout [Line], targets: [Int]) {
        for i in targets where lines[i].level > 0 {
            var indent = Substring(lines[i].indent)
            if indent.first == "\t" {
                indent = indent.dropFirst()
            } else {
                indent = indent.dropFirst(indent.prefix(2).allSatisfy { $0 == " " } ? 2 : 1)
            }
            lines[i].indent = String(indent)
        }
    }

    /// The selection as offsets into the content, so it stays on the same text when a prefix changes.
    private static func contentOffsets(_ lines: [Line], _ start: Position, _ end: Position) -> [(Int, Int)] {
        [start, end].map { ($0.line, max(0, $0.column - lines[$0.line].prefixLength)) }
    }

    private static func runStarts(_ lines: [Line]) -> [Int: Bool] {
        var numbering = ListNumbering()
        var starts: [Int: Bool] = [:]
        for line in lines {
            guard let marker = line.marker else {
                numbering.reset()
                continue
            }
            if case .ordered(let number, _, _) = marker {
                if let id = line.id { starts[id] = !numbering.continues(level: line.level) }
                numbering.advance(level: line.level, written: number)
            } else {
                numbering.advance(level: line.level, written: nil)
            }
        }
        return starts
    }

    /// Writes the shown numbers into the Markdown. An item that starts a list
    /// only because of this edit starts it at 1, as a fresh list does in Notion.
    private static func renumber(_ lines: inout [Line], startedBefore: [Int: Bool]) {
        var numbering = ListNumbering()
        for i in lines.indices {
            guard let marker = lines[i].marker else {
                numbering.reset()
                continue
            }
            let level = lines[i].level
            guard case .ordered(var number, let delimiter, let spacing) = marker else {
                numbering.advance(level: level, written: nil)
                continue
            }
            if !numbering.continues(level: level), let id = lines[i].id, startedBefore[id] == false {
                number = 1
            }
            number = numbering.advance(level: level, written: number) ?? number
            lines[i].marker = .ordered(number: number, delimiter: delimiter, spacing: spacing)
        }
    }
}
