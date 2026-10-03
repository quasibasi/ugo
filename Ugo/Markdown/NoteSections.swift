import Foundation

/// A note cut at its `#` and `##` headings, the way slides and section zen
/// see it. Deeper headings stay inside a section, and headings in fenced code don't count.
enum NoteSections {
    /// Where each `#` or `##` heading line starts, in UTF-16 units.
    static func headingStarts(in markdown: String) -> [Int] {
        let ns = markdown as NSString
        var starts: [Int] = []
        var inFence = false
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence, isSectionHeading(line) {
                starts.append(lineRange.location)
            }
            location = NSMaxRange(lineRange)
        }
        return starts
    }

    /// The note's sections back to back, from its start to its end. Text before
    /// the first heading is a section of its own unless it is only blank lines,
    /// which then go with the first heading. A note with no headings is one section.
    static func ranges(in markdown: String) -> [NSRange] {
        let ns = markdown as NSString
        var starts = headingStarts(in: markdown)
        if let first = starts.first, first > 0 {
            let preamble = ns.substring(to: first).trimmingCharacters(in: .whitespacesAndNewlines)
            if preamble.isEmpty { starts[0] = 0 } else { starts.insert(0, at: 0) }
        } else if starts.isEmpty {
            starts = [0]
        }
        return starts.indices.map { i in
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            return NSRange(location: starts[i], length: end - starts[i])
        }
    }

    /// The part of a section that section zen edits: all of it but the line
    /// break before the next heading, so deleting at the end can never pull
    /// that heading up onto the section's last line.
    static func editableRange(_ section: NSRange, in markdown: String) -> NSRange {
        let ns = markdown as NSString
        let end = NSMaxRange(section)
        guard section.length > 0, end < ns.length, ns.character(at: end - 1) == 0x0A else { return section }
        return NSRange(location: section.location, length: section.length - 1)
    }

    /// `# Title` or `## Title` with some text after the marker, at most three spaces in.
    private static func isSectionHeading(_ line: String) -> Bool {
        var rest = Substring(line)
        var spaces = 0
        while rest.first == " ", spaces < 3 { rest = rest.dropFirst(); spaces += 1 }
        var level = 0
        while rest.first == "#" { rest = rest.dropFirst(); level += 1 }
        guard level == 1 || level == 2, let gap = rest.first, gap == " " || gap == "\t" else { return false }
        return !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
