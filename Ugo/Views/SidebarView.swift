import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// A row of the sidebar: a folder, or a note shown inside its open folder.
enum SidebarItem: Hashable {
    case folder(String)
    case note(String)
}

/// The one column beside the editor: the folder tree, each open folder
/// listing its subfolders and then its notes, newest first. The note open
/// in the focused pane is highlighted. A click on a note shows it in the
/// pane's preview tab; the arrow keys only move the highlight and Return opens.
/// Notes and folders are dragged onto a folder to move them into it, or onto
/// empty space to move them to the top level.
struct SidebarView: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    /// The row the arrow keys act on.
    @State private var cursor: SidebarItem?
    /// The row being dragged, if the drag started here.
    @State private var dragged: SidebarItem?
    /// Where a drag is hovering: the row under the pointer (nil for empty space)
    /// and the folder a drop there would move into ("" for the top level).
    @State private var dropHover: DropHover?

    struct DropHover: Equatable {
        let row: SidebarItem?
        let folderID: String
    }

    static let dragType = UTType(exportedAs: "app.ugo.sidebar-item")

    private struct Row: Identifiable {
        enum Kind {
            case folder(FolderItem)
            case note(NoteItem)
        }
        let kind: Kind
        /// For a folder its depth in the tree, for a note the depth of its folder (-1 at the top level).
        let depth: Int
        /// The folder holding this row, nil at the top level.
        let parentID: String?

        var id: SidebarItem {
            switch kind {
            case .folder(let folder): .folder(folder.id)
            case .note(let note): .note(note.id)
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        func add(_ folder: FolderItem, depth: Int, parent: String?) {
            rows.append(Row(kind: .folder(folder), depth: depth, parentID: parent))
            guard appState.expandedFolderIDs.contains(folder.id) else { return }
            for child in folder.children ?? [] {
                add(child, depth: depth + 1, parent: folder.id)
            }
            for note in store.notes(in: folder.id) {
                rows.append(Row(kind: .note(note), depth: depth, parentID: folder.id))
            }
        }
        for folder in store.root?.children ?? [] {
            add(folder, depth: 0, parent: nil)
        }
        for note in store.notes(in: nil) {
            rows.append(Row(kind: .note(note), depth: -1, parentID: nil))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .scrollContentBackground(.hidden)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("New Folder") { appState.createFolder(in: nil, store: store) }
                }
                .onDrop(of: [Self.dragType], delegate: dropDelegate(row: nil, folderID: ""))
                .overlay {
                    if dropHover?.folderID == "" {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(dropColor, lineWidth: 1.5)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onChange(of: focused) {
                    appState.sidebarFocused = focused
                    if focused, cursor == nil {
                        cursor = appState.listSelection.map { .note($0) } ?? rows.first?.id
                    }
                }
                .onChange(of: appState.sidebarFocused) { focused = appState.sidebarFocused }
                .onChange(of: cursor) {
                    guard let cursor else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(cursor) }
                }
                .onKeyPress(.upArrow) { move(by: -1, in: rows) }
                .onKeyPress(.downArrow) { move(by: 1, in: rows) }
                .onKeyPress(.rightArrow) { right(in: rows) }
                .onKeyPress(.leftArrow) { left(in: rows) }
                .onKeyPress(.return) { open() }
                #if os(macOS)
                .onDeleteCommand { trashCursor() }
                #endif
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Notes Here", systemImage: "note.text", description: Text("Press ⌘N to write one."))
                }
            }
            #if os(macOS)
            footer
            #endif
        }
        .background { sidebarBackground }
        // The open note follows the focused pane: show it, opening the folders above it.
        .onChange(of: appState.layout.activeNoteID, initial: true) {
            guard let id = appState.layout.activeNoteID, let note = store.notes[id] else { return }
            reveal(folder: note.folderID)
            cursor = .note(id)
        }
        // A folder just made is up for renaming; keep the arrow keys on it.
        .onChange(of: appState.renamingFolderID) {
            if let id = appState.renamingFolderID { cursor = .folder(id) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            PaneButton(systemImage: "plus", help: "New Note") { appState.newNote(store: store) }
        }
        .frame(height: 40)
        .padding(.horizontal, 12)
        #if os(macOS)
        .padding(.top, 6)
        #endif
    }

    #if os(macOS)
    private var footer: some View {
        let count = store.root?.noteCount ?? 0
        return HStack(spacing: 10) {
            UgoBadge()
            Text("Ugo")
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            Text(count == 1 ? "1 note" : "\(count) notes")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(hairline).frame(height: 1)
        }
    }
    #endif

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case .folder(let folder):
            FolderRow(
                folder: folder,
                depth: row.depth,
                isExpanded: appState.expandedFolderIDs.contains(folder.id),
                hasContents: folder.noteCount > 0 || folder.children != nil)
                .background(cursor == row.id && focused || dropHover?.folderID == folder.id ? subtleFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if dropHover?.folderID == folder.id {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(dropColor, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    cursor = row.id
                    appState.selectedFolderID = folder.id
                    appState.toggleExpanded(folder.id)
                    focused = true
                }
                .onDrag { dragProvider(for: row.id) }
                .onDrop(of: [Self.dragType], delegate: dropDelegate(row: row.id, folderID: folder.id))
                .contextMenu {
                    Button("New Note") {
                        appState.selectedFolderID = folder.id
                        appState.newNote(store: store)
                    }
                    Button("New Folder Inside") { appState.createFolder(in: folder.id, store: store) }
                    Button("Rename") { appState.startRenaming(folder.id) }
                    moveMenu(for: row.id)
                    Divider()
                    Button("Move to Trash", role: .destructive) { appState.requestTrashFolder(folder.id, store: store) }
                }
        case .note(let note):
            let isOpen = appState.listSelection == note.id
            HStack(spacing: 8) {
                Text(note.title)
                    .fontWeight(isOpen ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(RelativeDate.text(for: note.modifiedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(isOpen ? AnyShapeStyle(highlightText.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isOpen ? AnyShapeStyle(highlightText) : AnyShapeStyle(.primary))
            .padding(.leading, Self.noteLeading(folderDepth: row.depth))
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(isOpen ? highlightFill : (cursor == row.id && focused ? subtleFill : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
                select(row)
                appState.show(note.id)
                focused = true
            }
            .onDrag { dragProvider(for: row.id) }
            .onDrop(of: [Self.dragType], delegate: dropDelegate(row: row.id, folderID: note.folderID))
            .contextMenu {
                Button("Open in New Tab") { appState.openInNewTab(note.id) }
                Button("Open in Split") { appState.openInSplit(note.id) }
                Divider()
                Button("Rename") {
                    appState.show(note.id)
                    appState.requestFocus(.title, in: note.id)
                }
                moveMenu(for: row.id)
                Divider()
                Button("Move to Trash", role: .destructive) { trash(note.id) }
            }
        }
    }

    /// Where a note's title starts: under its folder's name.
    static func noteLeading(folderDepth: Int) -> CGFloat {
        folderDepth < 0 ? 8 : FolderRow.nameLeading(depth: folderDepth)
    }

    // MARK: Moving

    /// Whether the item can go into the folder ("" for the top level).
    private func canMove(_ item: SidebarItem?, into folderID: String) -> Bool {
        switch item {
        case .folder(let id): store.canMoveFolder(id, into: folderID.isEmpty ? nil : folderID)
        case .note(let id): store.notes[id].map { $0.folderID != folderID && (folderID.isEmpty || store.folder(withID: folderID) != nil) } ?? false
        case nil: false
        }
    }

    /// Moves the item into the folder and opens that folder so it stays in sight.
    @discardableResult
    private func move(_ item: SidebarItem, into folderID: String) -> Bool {
        let destination = folderID.isEmpty ? nil : folderID
        let moved = switch item {
        case .folder(let id): store.moveFolder(id, into: destination)
        case .note(let id): store.moveNote(id, to: destination)
        }
        guard moved else { return false }
        reveal(folder: folderID)
        cursor = item
        return true
    }

    private func dragProvider(for item: SidebarItem) -> NSItemProvider {
        dragged = item
        let id: String = switch item {
        case .folder(let id): id
        case .note(let id): id
        }
        return NSItemProvider(item: id as NSString, typeIdentifier: Self.dragType.identifier)
    }

    private func dropDelegate(row: SidebarItem?, folderID: String) -> SidebarDrop {
        SidebarDrop(
            canDrop: { canMove(dragged, into: folderID) },
            hover: { inside in
                let here = DropHover(row: row, folderID: folderID)
                if inside {
                    // Only where a drop would do something; a note over its own folder shows nothing.
                    guard canMove(dragged, into: folderID) else { dropHover = nil; return }
                    dropHover = here
                    openWhileHovering(folderID, row: row)
                } else if dropHover == here {
                    dropHover = nil
                }
            },
            perform: {
                dropHover = nil
                defer { dragged = nil }
                guard let item = dragged else { return false }
                return move(item, into: folderID)
            })
    }

    /// A closed folder held under a drag for a moment opens, so the drag can go deeper.
    private func openWhileHovering(_ folderID: String, row: SidebarItem?) {
        guard row == .folder(folderID), !appState.expandedFolderIDs.contains(folderID) else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if dropHover?.row == row { appState.expandedFolderIDs.insert(folderID) }
        }
    }

    /// The right-click menu's Move To: the top level and every folder, the ones the item cannot go to dimmed.
    @ViewBuilder private func moveMenu(for item: SidebarItem) -> some View {
        Menu("Move To") {
            Button("Top Level") { move(item, into: "") }
                .disabled(!canMove(item, into: ""))
            Divider()
            ForEach(allFolders(), id: \.folder.id) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) { move(item, into: entry.folder.id) }
                    .disabled(!canMove(item, into: entry.folder.id))
            }
        }
    }

    /// Every folder in tree order, with its depth.
    private func allFolders() -> [(folder: FolderItem, depth: Int)] {
        var list: [(folder: FolderItem, depth: Int)] = []
        func add(_ folder: FolderItem, depth: Int) {
            list.append((folder, depth))
            for child in folder.children ?? [] { add(child, depth: depth + 1) }
        }
        for folder in store.root?.children ?? [] { add(folder, depth: 0) }
        return list
    }

    // MARK: Colours

    private var dropColor: Color {
        palette.map { Color(hex: $0.accent) } ?? .accentColor
    }

    private var highlightFill: Color {
        if let palette { return Color(hex: palette.highlight) }
        #if os(macOS)
        return Color(nsColor: .selectedContentBackgroundColor)
        #else
        return .accentColor
        #endif
    }

    private var highlightText: Color {
        palette.map { Color(hex: $0.heading) } ?? .white
    }

    private var subtleFill: Color {
        palette.map { Color(hex: $0.selection) } ?? Color.primary.opacity(0.08)
    }

    private var hairline: Color {
        palette.map { Color(hex: $0.hairline) } ?? Color.primary.opacity(0.1)
    }

    @ViewBuilder private var sidebarBackground: some View {
        if let palette {
            Color(hex: palette.side)
        } else {
            #if os(macOS)
            SidebarMaterial().ignoresSafeArea()
            #else
            Color(uiColor: .secondarySystemBackground)
            #endif
        }
    }

    // MARK: Keys

    private func select(_ row: Row) {
        cursor = row.id
        switch row.kind {
        case .folder(let folder):
            appState.selectedFolderID = folder.id
        case .note(let note):
            appState.listSelection = note.id
            appState.selectedFolderID = note.folderID.isEmpty ? nil : note.folderID
        }
    }

    private func index(of item: SidebarItem?, in rows: [Row]) -> Int? {
        guard let item else { return nil }
        return rows.firstIndex { $0.id == item }
    }

    private func move(by step: Int, in rows: [Row]) -> KeyPress.Result {
        guard appState.renamingFolderID == nil, !rows.isEmpty else { return .ignored }
        let target: Int
        if let current = index(of: cursor, in: rows) {
            target = min(max(current + step, 0), rows.count - 1)
        } else {
            target = step > 0 ? 0 : rows.count - 1
        }
        select(rows[target])
        return .handled
    }

    /// Opens a closed folder, or steps into an open one.
    private func right(in rows: [Row]) -> KeyPress.Result {
        guard appState.renamingFolderID == nil, case .folder(let id)? = cursor else { return .ignored }
        if !appState.expandedFolderIDs.contains(id) {
            appState.expandedFolderIDs.insert(id)
            return .handled
        }
        return move(by: 1, in: rows)
    }

    /// Closes an open folder, or steps out to the folder holding the row.
    private func left(in rows: [Row]) -> KeyPress.Result {
        guard appState.renamingFolderID == nil, let i = index(of: cursor, in: rows) else { return .ignored }
        let row = rows[i]
        if case .folder(let id) = row.id, appState.expandedFolderIDs.contains(id) {
            appState.expandedFolderIDs.remove(id)
            return .handled
        }
        guard let parent = row.parentID, let target = rows.first(where: { $0.id == .folder(parent) }) else { return .ignored }
        select(target)
        return .handled
    }

    /// Return opens or closes a folder, and opens a note with the cursor in it.
    private func open() -> KeyPress.Result {
        guard appState.renamingFolderID == nil, let cursor else { return .ignored }
        switch cursor {
        case .folder(let id):
            appState.toggleExpanded(id)
        case .note(let id):
            guard store.notes[id] != nil else { return .ignored }
            appState.show(id)
            appState.requestFocus(.body, in: id)
        }
        return .handled
    }

    private func trashCursor() {
        guard appState.renamingFolderID == nil, let cursor else { return }
        switch cursor {
        case .folder(let id): appState.requestTrashFolder(id, store: store)
        case .note(let id): trash(id)
        }
    }

    private func trash(_ id: String) {
        appState.forget(id)
        store.trash(id)
        if cursor == .note(id) { cursor = nil }
    }

    /// Opens the folder and every folder above it.
    private func reveal(folder id: String) {
        var current: String? = id.isEmpty ? nil : id
        while let folderID = current {
            if !appState.expandedFolderIDs.contains(folderID) { appState.expandedFolderIDs.insert(folderID) }
            current = store.parentID(ofFolder: folderID)
        }
    }
}

/// A drop target in the sidebar: a folder row, a note row (its folder), or empty space (the top level).
private struct SidebarDrop: DropDelegate {
    let canDrop: () -> Bool
    let hover: (Bool) -> Void
    let perform: () -> Bool

    func dropEntered(info: DropInfo) { hover(true) }
    func dropExited(info: DropInfo) { hover(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: canDrop() ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        canDrop() && perform()
    }
}

/// A folder's line: disclosure arrow, icon, name and how many notes it holds.
private struct FolderRow: View {
    @Environment(AppState.self) private var appState
    let folder: FolderItem
    let depth: Int
    let isExpanded: Bool
    /// Whether there is anything to open; an empty folder shows no arrow.
    let hasContents: Bool

    static let arrowWidth: CGFloat = 10
    static let iconWidth: CGFloat = 16
    static let spacing: CGFloat = 7

    static func leading(depth: Int) -> CGFloat { 8 + 18 * CGFloat(depth) }
    static func nameLeading(depth: Int) -> CGFloat { leading(depth: depth) + arrowWidth + iconWidth + 2 * spacing }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.arrowWidth)
                .opacity(hasContents ? 1 : 0)
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: Self.iconWidth)
            if appState.renamingFolderID == folder.id {
                FolderNameField(folder: folder)
            } else {
                Text(folder.name)
                    .fontWeight(depth == 0 ? .semibold : .regular)
                    .foregroundStyle(depth == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(folder.noteCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, Self.leading(depth: depth))
        .padding(.trailing, 8)
        .frame(height: 26)
    }
}

/// The folder's name as a text field. Return or clicking away keeps the new
/// name, Escape keeps the old one. A name another folder beside it already
/// has is refused with a beep and the field stays open.
private struct FolderNameField: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    let folder: FolderItem
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Folder Name", text: $name)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                name = folder.name
                // The row may still be appearing in the list; focus on the next pass.
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit {
                if store.renameFolder(folder.id, to: name) {
                    finish(refocusSidebar: true)
                } else {
                    #if os(macOS)
                    NSSound.beep()
                    #endif
                    focused = true
                }
            }
            .onExitCommand { finish(refocusSidebar: true) }
            .onChange(of: focused) {
                // Clicking elsewhere keeps a valid name and drops an invalid one.
                guard !focused, appState.renamingFolderID == folder.id else { return }
                store.renameFolder(folder.id, to: name)
                finish()
            }
    }

    /// Clicking away leaves focus where the click put it; Return and Escape hand it back to the sidebar.
    private func finish(refocusSidebar: Bool = false) {
        if appState.renamingFolderID == folder.id { appState.renamingFolderID = nil }
        guard refocusSidebar else { return }
        // The sidebar may still read as focused from before the edit; change it so it notices.
        appState.sidebarFocused = false
        DispatchQueue.main.async { appState.sidebarFocused = true }
    }
}

#if os(macOS)
/// The app's face in the corner, like a profile picture. A click turns it upside down.
private struct UgoBadge: View {
    @State private var flipped = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .rotationEffect(.degrees(flipped ? 180 : 0))
            .contentShape(Circle())
            .onTapGesture {
                withAnimation(.spring(duration: 0.4)) { flipped.toggle() }
            }
            .accessibilityLabel("Ugo")
    }
}

/// The translucent sidebar material macOS gives source lists, for the System theme.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif

enum RelativeDate {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    static func text(for date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "yesterday" }
        if seconds < 7 * 86400 { return dayFormatter.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDayFormatter.string(from: date)
        }
        return fullFormatter.string(from: date)
    }
}
