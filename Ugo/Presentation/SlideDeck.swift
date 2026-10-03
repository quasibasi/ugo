import Foundation

/// A note cut into slides: every `#` and `##` heading starts one. Deeper
/// headings stay inside the slide, text before the first heading is left out,
/// and a note with no such heading at all is one slide. Columns show one
/// after another.
struct SlideDeck {
    struct Slide {
        /// The slide's Markdown, from its heading line to the next slide's.
        let markdown: String
        /// Where the slide starts in the note, in UTF-16 units: its heading line.
        let location: Int
        /// A heading with nothing under it, shown centred on its own.
        let isSection: Bool
    }

    let slides: [Slide]

    init(markdown: String) {
        let ns = markdown as NSString
        let starts = NoteSections.headingStarts(in: markdown)
        if starts.isEmpty {
            let whole = ColumnBlocks.flattened(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
            slides = whole.isEmpty ? [] : [Slide(markdown: whole, location: 0, isSection: false)]
            return
        }
        slides = starts.indices.map { i in
            let start = starts[i]
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            let text = ColumnBlocks.flattened(ns.substring(with: NSRange(location: start, length: end - start)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? ""
            return Slide(markdown: text, location: start, isSection: body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The slide holding the character at `location`; the first slide when it sits before them all.
    func index(containing location: Int) -> Int {
        slides.lastIndex { $0.location <= location } ?? 0
    }
}
