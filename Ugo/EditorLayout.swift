import Foundation

/// One open note in a pane. A plain click in the notes list reuses the pane's
/// preview tab; keeping the tab (⌘/, a double click) makes it stay.
struct EditorTab: Identifiable, Hashable, Codable {
    var id = UUID().uuidString
    var noteID: String
    var isPreview = false
    /// The note this preview tab took over from. Opening the tab's own note in
    /// a new tab or split hands that note its tab back.
    var displacedNoteID: String?
}

/// A pane's tabs and which of them is showing.
struct EditorPane: Identifiable, Hashable, Codable {
    var id = UUID().uuidString
    var tabs: [EditorTab] = []
    var activeTabID: String?
    /// The pane's share of its column's height. The column's panes sum to 1.
    var fraction: Double = 1

    var activeIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }
    var activeTab: EditorTab? { activeIndex.map { tabs[$0] } }
    var activeNoteID: String? { activeTab?.noteID }

    func index(of tabID: String) -> Int? { tabs.firstIndex { $0.id == tabID } }
    func tab(for noteID: String) -> EditorTab? { tabs.first { $0.noteID == noteID } }

    /// Puts the tab after the active one, or at the end, and shows it.
    mutating func insert(_ tab: EditorTab) {
        let at = activeIndex.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        activeTabID = tab.id
    }

    /// Removes the tab. A closed active tab hands over to its right-hand neighbour, else the left one.
    mutating func remove(_ tabID: String) {
        guard let i = index(of: tabID) else { return }
        tabs.remove(at: i)
        if activeTabID == tabID {
            activeTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
    }
}

/// Up to two panes, one above the other.
struct EditorColumn: Identifiable, Hashable, Codable {
    var id = UUID().uuidString
    var panes: [EditorPane]
    /// The column's share of the editor width. The columns sum to 1.
    var fraction: Double = 1
}

// Layouts saved before sizes were kept have no fraction; they load as equal shares.
extension EditorPane {
    private enum CodingKeys: String, CodingKey { case id, tabs, activeTabID, fraction }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tabs = try c.decode([EditorTab].self, forKey: .tabs)
        activeTabID = try c.decodeIfPresent(String.self, forKey: .activeTabID)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 1
    }
}

extension EditorColumn {
    private enum CodingKeys: String, CodingKey { case id, panes, fraction }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        panes = try c.decode([EditorPane].self, forKey: .panes)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 1
    }
}

/// Everything open on the editor side: up to three columns of up to two
/// panes each, and the pane that list clicks and keyboard commands act on.
/// A note is open in at most one tab across the whole grid.
struct EditorLayout: Hashable, Codable {
    static let maxColumns = 3
    static let maxRows = 2

    var columns: [EditorColumn] = []
    var focusedPaneID: String?

    // MARK: Reading

    var isEmpty: Bool { columns.isEmpty }
    var panes: [EditorPane] { columns.flatMap(\.panes) }
    var isFull: Bool { panes.count >= Self.maxColumns * Self.maxRows }
    var focusedPane: EditorPane? { focusedPaneID.flatMap { self[$0] } }
    /// The note in the focused pane's active tab: what "the selected note" means to commands.
    var activeNoteID: String? { focusedPane?.activeNoteID }

    /// Where a note is open, if anywhere.
    func location(of noteID: String) -> (paneID: String, tabID: String)? {
        for pane in panes {
            if let tab = pane.tab(for: noteID) { return (pane.id, tab.id) }
        }
        return nil
    }

    private func position(of paneID: String) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.panes.firstIndex(where: { $0.id == paneID }) { return (c, r) }
        }
        return nil
    }

    subscript(paneID: String) -> EditorPane? {
        get { position(of: paneID).map { columns[$0.column].panes[$0.row] } }
        set {
            guard let newValue, let p = position(of: paneID) else { return }
            columns[p.column].panes[p.row] = newValue
        }
    }

    // MARK: Focus

    mutating func focus(_ paneID: String) {
        guard focusedPaneID != paneID, self[paneID] != nil else { return }
        focusedPaneID = paneID
    }

    /// Keeps the focus on a pane that exists.
    private mutating func normalizeFocus() {
        if let focusedPaneID, self[focusedPaneID] != nil { return }
        focusedPaneID = panes.first?.id
    }

    // MARK: Opening

    /// A plain click: the note shows in the focused pane's preview tab, or in
    /// a new preview tab next to the active one when every tab is kept.
    mutating func show(_ noteID: String) {
        if let (paneID, tabID) = location(of: noteID) {
            self[paneID]?.activeTabID = tabID
            focus(paneID)
            return
        }
        guard var pane = focusedPane ?? panes.first else {
            addPane(with: EditorTab(noteID: noteID, isPreview: true))
            return
        }
        if let i = pane.tabs.firstIndex(where: \.isPreview) {
            let previous = pane.tabs[i].noteID
            pane.tabs[i].noteID = noteID
            pane.tabs[i].displacedNoteID = previous
            pane.activeTabID = pane.tabs[i].id
        } else {
            pane.insert(EditorTab(noteID: noteID, isPreview: true))
        }
        self[pane.id] = pane
        focus(pane.id)
    }

    /// ⌘/: the note gets a tab that stays. Already open, its tab is kept and shown.
    mutating func openInNewTab(_ noteID: String) {
        if let (paneID, tabID) = location(of: noteID) {
            keep(tabID, in: paneID)
            self[paneID]?.activeTabID = tabID
            focus(paneID)
            return
        }
        guard var pane = focusedPane ?? panes.first else {
            addPane(with: EditorTab(noteID: noteID))
            return
        }
        pane.insert(EditorTab(noteID: noteID))
        self[pane.id] = pane
        focus(pane.id)
    }

    /// Turns a preview tab into one that stays. The note it took over from
    /// gets its own tab back, in front of it, unless it is open elsewhere.
    mutating func keep(_ tabID: String, in paneID: String) {
        guard var pane = self[paneID], let i = pane.index(of: tabID), pane.tabs[i].isPreview else { return }
        pane.tabs[i].isPreview = false
        if let displaced = pane.tabs[i].displacedNoteID {
            pane.tabs[i].displacedNoteID = nil
            if location(of: displaced) == nil {
                pane.tabs.insert(EditorTab(noteID: displaced), at: i)
            }
        }
        self[paneID] = pane
    }

    /// ⌘.: the note opens in a pane of its own: a new column while there are
    /// fewer than three, then below the first column with room. Already open,
    /// its tab moves out into the new pane; alone in its pane, it stays put.
    /// With every slot taken, a note that is not open yet gets a tab instead.
    mutating func openInSplit(_ noteID: String) {
        guard let (paneID, tabID) = location(of: noteID) else {
            if isFull {
                openInNewTab(noteID)
            } else {
                addPane(with: EditorTab(noteID: noteID))
            }
            return
        }
        guard var pane = self[paneID], let i = pane.index(of: tabID) else { return }
        var tab = pane.tabs[i]
        let restored: EditorTab? = tab.displacedNoteID.flatMap { location(of: $0) == nil ? EditorTab(noteID: $0) : nil }
        let leftover = pane.tabs.count - 1 + (restored == nil ? 0 : 1)
        guard leftover > 0, !isFull else {
            pane.activeTabID = tabID
            self[paneID] = pane
            focus(paneID)
            return
        }
        tab.isPreview = false
        tab.displacedNoteID = nil
        pane.remove(tabID)
        if let restored {
            pane.tabs.insert(restored, at: min(i, pane.tabs.count))
            pane.activeTabID = restored.id
        }
        self[paneID] = pane
        addPane(with: tab)
    }

    /// Adds a pane holding the tab and focuses it. False when the grid is full.
    @discardableResult
    private mutating func addPane(with tab: EditorTab) -> Bool {
        var pane = EditorPane(tabs: [tab], activeTabID: tab.id)
        if columns.count < Self.maxColumns {
            // The new column takes an equal share; the others shrink to make room.
            let n = Double(columns.count)
            for c in columns.indices { columns[c].fraction *= n / (n + 1) }
            columns.append(EditorColumn(panes: [pane], fraction: 1 / (n + 1)))
        } else if let c = columns.firstIndex(where: { $0.panes.count < Self.maxRows }) {
            let n = Double(columns[c].panes.count)
            for r in columns[c].panes.indices { columns[c].panes[r].fraction *= n / (n + 1) }
            pane.fraction = 1 / (n + 1)
            columns[c].panes.append(pane)
        } else {
            return false
        }
        focusedPaneID = pane.id
        return true
    }

    // MARK: Sizes

    /// Columns' shares of the width, in order; from a divider drag.
    mutating func setColumnFractions(_ fractions: [Double]) {
        guard fractions.count == columns.count else { return }
        for c in columns.indices { columns[c].fraction = fractions[c] }
        normalizeFractions()
    }

    /// A column's panes' shares of its height, in order; from a divider drag.
    mutating func setPaneFractions(_ fractions: [Double], in columnID: String) {
        guard let c = columns.firstIndex(where: { $0.id == columnID }), fractions.count == columns[c].panes.count else { return }
        for r in columns[c].panes.indices { columns[c].panes[r].fraction = fractions[r] }
        normalizeFractions()
    }

    /// Makes the columns' shares sum to 1, and each column's panes' shares too.
    private mutating func normalizeFractions() {
        func scaled(_ values: [Double]) -> [Double] {
            let sum = values.reduce(0, +)
            guard sum > 0, values.allSatisfy({ $0 >= 0 }) else { return Array(repeating: 1 / Double(max(values.count, 1)), count: values.count) }
            return values.map { $0 / sum }
        }
        let widths = scaled(columns.map(\.fraction))
        for c in columns.indices {
            columns[c].fraction = widths[c]
            let heights = scaled(columns[c].panes.map(\.fraction))
            for r in columns[c].panes.indices { columns[c].panes[r].fraction = heights[r] }
        }
    }

    // MARK: Switching and closing

    mutating func activate(_ tabID: String, in paneID: String) {
        guard self[paneID]?.index(of: tabID) != nil else { return }
        self[paneID]?.activeTabID = tabID
        focus(paneID)
    }

    /// Moves the focused pane's active tab by `offset`, wrapping around.
    mutating func selectTab(offset: Int) {
        guard var pane = focusedPane, let i = pane.activeIndex, pane.tabs.count > 1 else { return }
        let n = pane.tabs.count
        pane.activeTabID = pane.tabs[((i + offset) % n + n) % n].id
        self[pane.id] = pane
    }

    mutating func close(_ tabID: String, in paneID: String) {
        guard var pane = self[paneID] else { return }
        pane.remove(tabID)
        if pane.tabs.isEmpty {
            removePane(paneID)
        } else {
            self[paneID] = pane
        }
    }

    mutating func closeActiveTab() {
        guard let pane = focusedPane, let tabID = pane.activeTabID else { return }
        close(tabID, in: pane.id)
    }

    mutating func closeOtherTabs(than tabID: String, in paneID: String) {
        guard var pane = self[paneID], let tab = pane.tabs.first(where: { $0.id == tabID }) else { return }
        pane.tabs = [tab]
        pane.activeTabID = tab.id
        self[paneID] = pane
    }

    /// Closes the note's tab wherever it is, and forgets it as a displaced note. For a trashed note.
    mutating func closeTabs(for noteID: String) {
        prune { $0 != noteID }
    }

    /// Drops tabs whose notes cannot be opened, then any pane and column left empty.
    mutating func prune(keeping isOpenable: (String) -> Bool) {
        for c in columns.indices {
            for r in columns[c].panes.indices {
                var pane = columns[c].panes[r]
                for t in pane.tabs.indices {
                    if let displaced = pane.tabs[t].displacedNoteID, !isOpenable(displaced) {
                        pane.tabs[t].displacedNoteID = nil
                    }
                }
                for tab in pane.tabs where !isOpenable(tab.noteID) {
                    pane.remove(tab.id)
                }
                columns[c].panes[r] = pane
            }
            columns[c].panes.removeAll { $0.tabs.isEmpty }
        }
        columns.removeAll { $0.panes.isEmpty }
        normalizeFractions()
        normalizeFocus()
    }

    /// Removes the pane; an emptied column goes with it. Focus moves to the
    /// pane before it in reading order, else the one after.
    private mutating func removePane(_ paneID: String) {
        guard let p = position(of: paneID) else { return }
        let index = panes.firstIndex { $0.id == paneID } ?? 0
        columns[p.column].panes.remove(at: p.row)
        if columns[p.column].panes.isEmpty { columns.remove(at: p.column) }
        normalizeFractions()
        if focusedPaneID == paneID {
            let remaining = panes
            focusedPaneID = remaining.isEmpty ? nil : remaining[max(min(index - 1, remaining.count - 1), 0)].id
        }
    }

    // MARK: Saving

    private static let defaultsKey = "editorLayout"

    static func load() -> EditorLayout {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var layout = try? JSONDecoder().decode(EditorLayout.self, from: data) else { return EditorLayout() }
        layout.normalizeFractions()
        return layout
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
