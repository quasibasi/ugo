import Observation
import SwiftUI

/// Cross-view UI state: what is open and selected, which panes are shown, and one-shot focus requests.
@Observable @MainActor
final class AppState {
    /// nil is the vault root.
    var selectedFolderID: String?

    /// The open notes: tabs in panes in columns. Saved so a relaunch shows the same notes.
    var layout = EditorLayout.load() {
        didSet {
            layout.save()
            if layout.isEmpty { zenMode = false }
            // The list highlight follows whatever the focused pane shows.
            if let id = layout.activeNoteID, id != oldValue.activeNoteID { listSelection = id }
        }
    }

    /// The note highlighted in the sidebar. Arrow keys move it without
    /// opening anything; Return, a click, ⌘/ and ⌘. act on it.
    var listSelection: String?

    /// The note commands act on: the list highlight, else the note the focused pane shows.
    var selectedNoteID: String? { listSelection ?? layout.activeNoteID }

    init() {
        listSelection = layout.activeNoteID
    }

    /// Whether the sidebar is shown.
    var showPanes: Bool = UserDefaults.standard.object(forKey: "showPanes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPanes, forKey: "showPanes") }
    }

    /// Zen mode: the focused pane's note alone fills the window, no side panels,
    /// other panes or tabs. Leaves showPanes and the layout as they were.
    var zenMode = false {
        didSet { if !zenMode { sectionZen = false } }
    }

    /// Section zen: zen mode with the editor showing only the `#` or `##`
    /// section the caret was in. The editor turns it on once it shows one.
    var sectionZen = false
    /// Whether zen mode was on before section zen began; leaving section zen goes back to it.
    var zenBeforeSection = false
    /// A section zen step waiting for the focused pane's editor, which clears it once done.
    var sectionRequest: SectionRequest?

    enum SectionRequest: Equatable {
        /// Show the section holding `caret`, a location in the whole note.
        case enter(noteID: String, caret: Int)
        /// Put an empty `##` at the top of the note and show it, the caret on it.
        case newSection(noteID: String)
        /// Show the next section (1) or the previous one (-1).
        case step(Int)
        /// Show the whole note again, the caret at `caret` in the section's
        /// text, and leave zen mode as well when `closeZen` is set.
        case leave(caret: Int, closeZen: Bool)
    }

    /// Where to put the caret in the note's editor about to appear. Turning
    /// zen mode on or off builds the editor anew, which would lose it.
    var pendingCaret: (noteID: String, location: Int)?

    /// Whether the sidebar is on screen right now.
    var panesVisible: Bool { showPanes && !zenMode }

    /// The sidebar's width as last dragged; a narrow window may show it narrower.
    var sidebarWidth: Double = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? Double(SidePanelLayout.defaultWidth) {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
    }

    /// Folders shown open in the tree.
    var expandedFolderIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "expandedFolderIDs") ?? []) {
        didSet { UserDefaults.standard.set(Array(expandedFolderIDs), forKey: "expandedFolderIDs") }
    }

    /// Whether the sidebar has keyboard focus. Setting it moves the focus there.
    var sidebarFocused = false

    var quickOpenPresented = false
    /// Bumped to ask the focused pane's editor to put the cursor in the title field.
    var titleFocusRequest = 0
    /// Bumped to ask the focused pane's editor to put the cursor in the note body.
    var editorFocusRequest = 0

    enum EditorField {
        case title
        case body
    }

    /// A cursor placement waiting for the note's editor to exist: the change
    /// that asked for it may be the one creating the editor.
    var pendingFocus: (noteID: String, field: EditorField)?

    /// Puts the cursor in the field of the note's editor in the focused pane, now or as soon as it appears.
    func requestFocus(_ field: EditorField, in noteID: String) {
        pendingFocus = (noteID, field)
        switch field {
        case .title: titleFocusRequest += 1
        case .body: editorFocusRequest += 1
        }
    }

    // MARK: Opening notes

    /// Shows the note in the focused pane, reusing its preview tab.
    func show(_ noteID: String) {
        layout.show(noteID)
    }

    /// Gives the note a tab that stays, in the focused pane.
    func openInNewTab(_ noteID: String) {
        layout.openInNewTab(noteID)
    }

    /// Makes a note in the selected folder and puts the cursor in its title.
    func newNote(store: NotesStore) {
        guard let note = store.createNote(in: selectedFolderID) else { return }
        openInNewTab(note.id)
        requestFocus(.title, in: note.id)
    }

    /// Opens the note in a pane of its own.
    func openInSplit(_ noteID: String) {
        zenMode = false
        layout.openInSplit(noteID)
    }

    /// For a note going to the trash: closes its tab wherever it is open and drops the highlight.
    func forget(_ noteID: String) {
        if listSelection == noteID { listSelection = nil }
        if pendingFocus?.noteID == noteID { pendingFocus = nil }
        if pendingCaret?.noteID == noteID { pendingCaret = nil }
        guard layout.location(of: noteID) != nil || layout.panes.contains(where: { $0.tabs.contains { $0.displacedNoteID == noteID } }) else { return }
        layout.closeTabs(for: noteID)
    }

    /// Makes the pane the one that commands and list clicks act on.
    func focusPane(_ paneID: String) {
        guard layout.focusedPaneID != paneID else { return }
        layout.focus(paneID)
    }

    // MARK: Folders

    /// The folder whose name is being edited in the folder pane.
    var renamingFolderID: String?

    /// Makes a folder inside `parentID` (nil for the top level), selects it and puts its name up for editing.
    func createFolder(in parentID: String?, store: NotesStore) {
        guard let folder = store.createFolder(in: parentID) else { return }
        if let parentID { expandedFolderIDs.insert(parentID) }
        selectedFolderID = folder.id
        startRenaming(folder.id)
    }

    /// Shows the sidebar if it is hidden and turns the folder's name into a text field.
    func startRenaming(_ folderID: String) {
        zenMode = false
        showPanes = true
        renamingFolderID = folderID
    }

    /// The folder waiting for the user to confirm it goes to the trash with its notes.
    var folderPendingTrash: String?

    /// An empty folder goes to the trash right away; one holding notes asks first.
    func requestTrashFolder(_ folderID: String, store: NotesStore) {
        if (store.folder(withID: folderID)?.noteCount ?? 0) == 0 {
            trashFolder(folderID, store: store)
        } else {
            folderPendingTrash = folderID
        }
    }

    /// Trashes the folder's notes, closes their tabs and selects the parent if the selection went with it.
    func trashFolder(_ folderID: String, store: NotesStore) {
        let parent = store.parentID(ofFolder: folderID)
        for noteID in store.trashFolder(folderID) {
            forget(noteID)
        }
        folderPendingTrash = nil
        if let selected = selectedFolderID, store.folder(withID: selected) == nil { selectedFolderID = parent }
        if let renaming = renamingFolderID, store.folder(withID: renaming) == nil { renamingFolderID = nil }
        expandedFolderIDs = expandedFolderIDs.filter { store.folder(withID: $0) != nil }
    }

    func toggleExpanded(_ folderID: String) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }
}
