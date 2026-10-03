import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AppCommands: Commands {
    let appState: AppState
    let store: NotesStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { appState.newNote(store: store) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Folder") { appState.createFolder(in: appState.selectedFolderID, store: store) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { appState.layout.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
            #if os(macOS)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            #endif
        }
        CommandGroup(replacing: .printItem) {
            Button("Quick Open…") { appState.quickOpenPresented = true }
                .keyboardShortcut("p", modifiers: .command)
        }
        CommandGroup(replacing: .sidebar) {
            Button(appState.panesVisible ? "Hide Sidebar" : "Show Sidebar") {
                if appState.zenMode {
                    appState.zenMode = false
                    appState.showPanes = true
                } else {
                    appState.showPanes.toggle()
                }
            }
            .keyboardShortcut("\\", modifiers: .command)
            #if os(macOS)
            Button(appState.zenMode ? "Exit Zen Mode" : "Zen Mode") { toggleZen() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!appState.zenMode && appState.layout.focusedPane?.activeNoteID == nil)
            Button(appState.sectionZen ? "Exit Section Zen" : "Zen Mode for Section") { toggleSectionZen() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!appState.sectionZen && appState.layout.focusedPane?.activeNoteID == nil)
            Button("Next Section") { appState.sectionRequest = .step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!appState.sectionZen)
            Button("Previous Section") { appState.sectionRequest = .step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!appState.sectionZen)
            #else
            Button(appState.zenMode ? "Exit Zen Mode" : "Zen Mode") { appState.zenMode.toggle() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!appState.zenMode && appState.layout.focusedPane?.activeNoteID == nil)
            #endif
            #if os(macOS)
            Button("Present") { Presentation.start(appState: appState, store: store) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(appState.layout.activeNoteID == nil)
            #endif
            Divider()
            Button("Open in New Tab") {
                guard let id = appState.selectedNoteID else { return }
                appState.openInNewTab(id)
            }
            .keyboardShortcut("/", modifiers: .command)
            Button("Open in Split") {
                guard let id = appState.selectedNoteID else { return }
                appState.openInSplit(id)
            }
            .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Next Tab") { appState.layout.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { appState.layout.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { n in
                Button("Tab \(n)") { appState.layout.selectTab(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .option)
            }
        }
        CommandMenu("Favourites") {
            let favorites = store.favorites
            if favorites.isEmpty {
                Button("No Favourites") {}.disabled(true)
            }
            ForEach(Array(favorites.enumerated()), id: \.element.id) { index, note in
                Button(note.title) { open(note) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
            }
            #if os(macOS)
            Divider()
            SettingsLink { Text("Edit Favourites…") }
            #endif
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename Note") {
                guard let id = appState.selectedNoteID else { return }
                appState.show(id)
                appState.requestFocus(.title, in: id)
            }
            Button("Rename Folder") {
                guard let id = appState.selectedFolderID else { return }
                appState.startRenaming(id)
            }
            .disabled(appState.selectedFolderID == nil)
            Button("Move Folder to Trash") {
                guard let id = appState.selectedFolderID else { return }
                appState.requestTrashFolder(id, store: store)
            }
            .disabled(appState.selectedFolderID == nil)
            Button("Move Note to Trash") {
                guard let id = appState.selectedNoteID else { return }
                appState.forget(id)
                store.trash(id)
            }
        }
    }

    private func open(_ note: NoteItem) {
        appState.selectedFolderID = note.folderID.isEmpty ? nil : note.folderID
        appState.show(note.id)
    }

    #if os(macOS)
    /// The note editor with keyboard focus, if any.
    private var focusedEditor: UgoTextView? {
        NSApp.keyWindow?.firstResponder as? UgoTextView
    }

    /// Zen mode builds the focused pane's editor anew. Saves what the editor
    /// shows, so the new one doesn't start from an older copy, and keeps its caret.
    private func handOverEditor(of noteID: String) -> Int? {
        guard let editor = focusedEditor else { return nil }
        if editor.string != store.content(of: noteID) { store.save(noteID, content: editor.string) }
        return editor.selectedRange().location
    }

    private func toggleZen() {
        if appState.sectionZen {
            appState.sectionRequest = .leave(caret: focusedEditor?.selectedRange().location ?? 0, closeZen: true)
            return
        }
        if let id = appState.layout.focusedPane?.activeNoteID, let caret = handOverEditor(of: id) {
            appState.pendingCaret = (id, caret)
        }
        appState.zenMode.toggle()
    }

    /// Shows only the section the caret is in, or the whole note again.
    private func toggleSectionZen() {
        if appState.sectionZen {
            let caret = focusedEditor?.selectedRange().location ?? 0
            appState.sectionRequest = .leave(caret: caret, closeZen: !appState.zenBeforeSection)
            return
        }
        guard let id = appState.layout.focusedPane?.activeNoteID else { return }
        // Without the caret in the note, the section is the note's first.
        let caret = appState.zenMode ? focusedEditor?.selectedRange().location ?? 0 : handOverEditor(of: id) ?? 0
        appState.zenBeforeSection = appState.zenMode
        if appState.zenMode {
            appState.sectionRequest = .enter(noteID: id, caret: caret)
        } else {
            // Ask once the zen editor has replaced the one on screen, which would take it with it.
            appState.zenMode = true
            DispatchQueue.main.async { appState.sectionRequest = .enter(noteID: id, caret: caret) }
        }
    }
    #endif
}
