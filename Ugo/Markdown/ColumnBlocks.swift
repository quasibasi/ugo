import Foundation

/// Side-by-side columns written in plain Markdown:
///
///     ::: columns
///     First column
///     +++
///     Second column
///     :::
///
/// A block counts only once it is closed; until then its lines are ordinary
/// text. Inside a block only the three marker lines mean anything, so a
/// column can hold any Markdown but not another block of columns.
enum ColumnBlocks {
    struct Column: Equatable {
        /// The column's text: its lines without the line break before the next marker.
        let range: NSRange
        /// False when two markers sit on consecutive lines. `range` is then
        /// empty at the start of the next marker, and text put there needs a
        /// line break after it.
        let hasLine: Bool
    }

    struct Block: Equatable {
        /// From the start of the `::: columns` line to the end of the closing
        /// `:::`, without the line break after it.
        let range: NSRange
        /// The `::: columns` line, without its line break.
        let opening: NSRange
        let columns: [Column]
    }

    static func blocks(in ns: NSString) -> [Block] {
        // One copy of the characters, then a plain scan: asking the string
        // for each line costs far more in a long note.
        let length = ns.length
        var chars = [unichar](repeating: 0, count: length)
        ns.getCharacters(&chars, range: NSRange(location: 0, length: length))
        var blocks: [Block] = []
        var inFence = false
        // The open block: where it starts, its opening line, and where the current column starts.
        var open: (start: Int, opening: NSRange, columnStart: Int, columns: [Column])?
        var location = 0
        while location < length {
            var contentsEnd = location
            while contentsEnd < length, chars[contentsEnd] != 0x0A, chars[contentsEnd] != 0x0D { contentsEnd += 1 }
            var lineEnd = contentsEnd
            if lineEnd < length {
                lineEnd += (chars[lineEnd] == 0x0D && lineEnd + 1 < length && chars[lineEnd + 1] == 0x0A) ? 2 : 1
            }
            let line = NSRange(location: location, length: contentsEnd - location)
            if var current = open {
                if let kind = marker(chars, line), kind != .opening {
                    current.columns.append(column(from: current.columnStart, toMarkerAt: location))
                    if kind == .closing {
                        blocks.append(Block(range: NSRange(location: current.start, length: NSMaxRange(line) - current.start),
                                            opening: current.opening, columns: current.columns))
                        open = nil
                    } else {
                        current.columnStart = lineEnd
                        open = current
                    }
                }
            } else if isFence(chars, line) {
                inFence.toggle()
            } else if !inFence, marker(chars, line) == .opening {
                open = (location, line, lineEnd, [])
            }
            location = lineEnd
        }
        return blocks
    }

    /// The Markdown with each block's columns one after another, for places
    /// that show text in a single column, such as slides.
    static func flattened(_ markdown: String) -> String {
        let ns = markdown as NSString
        let found = blocks(in: ns)
        guard !found.isEmpty else { return markdown }
        let result = NSMutableString(string: markdown)
        for block in found.reversed() {
            let texts = block.columns.map { ns.substring(with: $0.range) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            result.replaceCharacters(in: block.range, with: texts.joined(separator: "\n\n"))
        }
        return result as String
    }

    /// The text of a block of `count` empty columns.
    static func emptyBlock(columns count: Int) -> String {
        "::: columns\n" + Array(repeating: "", count: count).joined(separator: "\n+++\n") + "\n:::"
    }

    /// The Markdown of a block with these column texts.
    static func block(_ columns: [String]) -> String {
        "::: columns\n" + columns.joined(separator: "\n+++\n") + "\n:::"
    }

    /// The block and column holding `location`, which may sit at a column's very end.
    static func column(at location: Int, in blocks: [Block]) -> (block: Int, column: Int)? {
        for (b, block) in blocks.enumerated() where NSLocationInRange(location, block.range) || location == NSMaxRange(block.range) {
            for (c, column) in block.columns.enumerated() where column.hasLine && location >= column.range.location && location <= NSMaxRange(column.range) {
                return (b, c)
            }
            return nil
        }
        return nil
    }

    // MARK: Lines

    enum Marker: Equatable {
        case opening, separator, closing
    }

    /// `::: columns`, `+++` or `:::`, with spaces allowed around them.
    private static func marker(_ chars: [unichar], _ line: NSRange) -> Marker? {
        var i = line.location
        var end = NSMaxRange(line)
        while i < end, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        while end > i, chars[end - 1] == 0x20 || chars[end - 1] == 0x09 { end -= 1 }
        guard end - i >= 3 else { return nil }
        let c = chars[i]
        guard (c == 0x3A || c == 0x2B), chars[i + 1] == c, chars[i + 2] == c else { return nil }
        if end - i == 3 { return c == 0x2B ? .separator : .closing }
        guard c == 0x3A else { return nil }
        i += 3
        while i < end, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        let word = Array("columns".utf16)
        guard end - i == word.count else { return nil }
        for (k, w) in word.enumerated() where chars[i + k] | 0x20 != w { return nil }
        return .opening
    }

    /// A line opening or closing fenced code: three backticks or tildes, at most three spaces in.
    private static func isFence(_ chars: [unichar], _ line: NSRange) -> Bool {
        var i = line.location
        let end = NSMaxRange(line)
        var spaces = 0
        while i < end, spaces < 3, chars[i] == 0x20 { i += 1; spaces += 1 }
        guard i + 3 <= end else { return false }
        let c = chars[i]
        return (c == 0x60 || c == 0x7E) && chars[i + 1] == c && chars[i + 2] == c
    }

    private static func column(from start: Int, toMarkerAt markerStart: Int) -> Column {
        guard markerStart > start else { return Column(range: NSRange(location: markerStart, length: 0), hasLine: false) }
        // Everything up to the line break that ends the column's last line.
        return Column(range: NSRange(location: start, length: markerStart - 1 - start), hasLine: true)
    }

    // MARK: Typing a block

    /// `/columns`, `/columns 3`, `/3 columns`, `/3col` and the like on a line of their own:
    /// the number of columns asked for, 2 when none is given.
    static func slashCommand(_ line: String) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("/") else { return nil }
        let pattern = #"^/(?:(\d)\s*(?:col|cols|column|columns)|(?:col|cols|column|columns)\s*(\d)?)$"#
        guard let match = text.range(of: pattern, options: .regularExpression), match == text.startIndex..<text.endIndex else { return nil }
        let digits = text.filter(\.isNumber)
        let count = Int(digits) ?? 2
        return (2...6).contains(count) ? count : nil
    }
}
