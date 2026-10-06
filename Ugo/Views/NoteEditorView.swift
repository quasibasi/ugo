import SwiftUI
#if os(macOS)
import AppKit
import Combine
#endif

/// Edits one note as a centred reading column. Keystrokes go to local state
/// and reach the file after a short pause, so typing never waits on disk.
struct NoteEditorView: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    @AppStorage("editorFontSize") private var fontSize: Double = 15
    @AppStorage(TitleFont.familyKey) private var titleFamily = TitleFont.defaultFamily
    @AppStorage(TitleFont.weightKey) private var titleWeight = TitleFont.defaultWeight
    @Environment(\.palette) private var palette

    static let columnWidth: CGFloat = 640
    /// The margin left and right of a full-width note.
    static let fullWidthMargin: CGFloat = 72

    let note: NoteItem
    /// The pane this editor sits in; focus requests are only for the focused pane's editor.
    let paneID: String
    @State private var title: String
    @State private var content: String
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var editorFocusToken = 0
    /// In section zen, the part of `content` the editor shows; nil for the whole note.
    @State private var section: NSRange?
    /// Bumped to build the text view anew, for a new section or the whole note again.
    @State private var editorGeneration = 0
    /// Where the next text view puts its caret.
    @State private var initialCaret: Int?
    /// Whether the shown section is an empty `##` this editor added, taken out
    /// again if it is still empty when section zen ends.
    @State private var addedHeading = false
    @FocusState private var titleFocused: Bool
    @State private var paneWidth: CGFloat = 0

    init(note: NoteItem, paneID: String, initialContent: String) {
        self.note = note
        self.paneID = paneID
        _title = State(initialValue: note.title)
        _content = State(initialValue: initialContent)
    }

    private var isInFocusedPane: Bool { appState.layout.focusedPaneID == paneID }

    /// How wide the title and text run: the reading column, or for a
    /// full-width note the pane less its margins, never narrower than the column.
    private var textWidth: CGFloat {
        guard note.fullWidth else { return Self.columnWidth }
        return max(Self.columnWidth, paneWidth - 2 * Self.fullWidthMargin)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(TitleFont.font(family: titleFamily, weight: titleWeight, size: fontSize * 2.25))
                    .foregroundStyle(palette.map { Color(hex: $0.heading) } ?? Color.primary)
                    .focused($titleFocused)
                    .onSubmit {
                        commitTitle()
                        editorFocusToken += 1
                    }
                    .padding(.bottom, 14)
                    .overlay(alignment: .bottom) {
                        // The rule under the title, as wide as the text column.
                        Rectangle()
                            .fill(palette.map { Color(hex: $0.hairline) } ?? Color.primary.opacity(0.15))
                            .frame(height: 1)
                    }
                    .frame(maxWidth: textWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 14)
            MarkdownEditor(text: editorText, fontSize: fontSize, palette: palette, columnWidth: textWidth, focusToken: editorFocusToken, initialSelection: initialCaret, onEscape: leaveSectionOnEscape) {
                appState.focusPane(paneID)
            }
            .id(editorGeneration)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        .onChange(of: content) {
            dirty = true
            scheduleSave()
        }
        .onChange(of: titleFocused) {
            if titleFocused {
                appState.focusPane(paneID)
            } else {
                commitTitle()
            }
        }
        // Renamed from elsewhere, as when a move numbers a clashing title.
        .onChange(of: note.title) {
            if !titleFocused { title = note.title }
        }
        .onChange(of: appState.titleFocusRequest) {
            guard isInFocusedPane else { return }
            focus(.title)
        }
        .onChange(of: appState.editorFocusRequest) {
            guard isInFocusedPane else { return }
            focus(.body)
        }
        .onChange(of: appState.sectionRequest) { handleSectionRequest() }
        .onAppear {
            if let pending = appState.pendingCaret, pending.noteID == note.id {
                appState.pendingCaret = nil
                rebuildEditor(caret: pending.location)
            }
            handleSectionRequest()
            if let pending = appState.pendingFocus, pending.noteID == note.id {
                focus(pending.field)
            } else if note.title == "Untitled" && content.isEmpty {
                titleFocused = true
            }
        }
        .onDisappear {
            flush()
            // Another note took the pane: zen mode stays, showing all of that one.
            if section != nil { appState.sectionZen = false }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flush()
        }
        #endif
    }

    /// Puts the cursor in the field and settles any request waiting for this editor.
    private func focus(_ field: AppState.EditorField) {
        if appState.pendingFocus?.noteID == note.id { appState.pendingFocus = nil }
        switch field {
        case .title: titleFocused = true
        case .body: editorFocusToken += 1
        }
    }

    /// What the editor edits: the section in section zen, else the whole note.
    /// A section's edits go straight into the note around it.
    private var editorText: Binding<String> {
        Binding(
            get: {
                guard let section else { return content }
                let ns = content as NSString
                let start = min(section.location, ns.length)
                return ns.substring(with: NSRange(location: start, length: min(section.length, ns.length - start)))
            },
            set: { text in
                guard let section else {
                    content = text
                    return
                }
                content = (content as NSString).replacingCharacters(in: section, with: text)
                self.section = NSRange(location: section.location, length: (text as NSString).length)
            })
    }

    /// In section zen, Esc shows the whole note again, like ⇧⌘↩.
    private var leaveSectionOnEscape: (@MainActor (Int) -> Void)? {
        guard section != nil else { return nil }
        return { caret in appState.sectionRequest = .leave(caret: caret, closeZen: !appState.zenBeforeSection) }
    }

    private func handleSectionRequest() {
        guard isInFocusedPane, let request = appState.sectionRequest else { return }
        switch request {
        case .enter(let noteID, let caret):
            guard noteID == note.id else { return }
            appState.sectionRequest = nil
            let ranges = NoteSections.ranges(in: content)
            let range = ranges.last { $0.location <= caret } ?? ranges[0]
            show(range, caret: caret - range.location)
            appState.sectionZen = true
        case .newSection(let noteID):
            guard noteID == note.id else { return }
            appState.sectionRequest = nil
            content = content.isEmpty ? Self.newHeading : Self.newHeading + "\n\n" + content
            let heading = (Self.newHeading as NSString).length
            section = NSRange(location: 0, length: heading)
            addedHeading = true
            rebuildEditor(caret: heading)
            appState.sectionZen = true
        case .step(let offset):
            appState.sectionRequest = nil
            guard let current = section else { return }
            addedHeading = false
            let ranges = NoteSections.ranges(in: content)
            // Measured from the shown text, so a heading typed into it doesn't count.
            let target = offset > 0
                ? ranges.first { $0.location >= NSMaxRange(current) }
                : ranges.last { $0.location < current.location }
            guard let target else {
                #if os(macOS)
                NSSound.beep()
                #endif
                return
            }
            show(target, caret: 0)
        case .leave(let caret, let closeZen):
            appState.sectionRequest = nil
            var location = min((section?.location ?? 0) + caret, (content as NSString).length)
            if addedHeading, let section, editorText.wrappedValue.trimmingCharacters(in: .whitespaces) == "##" {
                // Never written in: take it out with the blank line put after it.
                let ns = content as NSString
                let after = ns.substring(from: NSMaxRange(section))
                let gap = after.hasPrefix("\n\n") ? 2 : 0
                content = ns.replacingCharacters(in: NSRange(location: section.location, length: section.length + gap), with: "")
                location = section.location
            }
            addedHeading = false
            appState.sectionZen = false
            if closeZen {
                // Leaving zen mode builds a new editor from the store.
                flush()
                section = nil
                appState.pendingCaret = (note.id, location)
                appState.zenMode = false
            } else {
                section = nil
                rebuildEditor(caret: location)
            }
        }
    }

    private static let newHeading = "## "

    private func show(_ range: NSRange, caret: Int) {
        let shown = NoteSections.editableRange(range, in: content)
        section = shown
        rebuildEditor(caret: min(max(caret, 0), shown.length))
    }

    private func rebuildEditor(caret: Int) {
        initialCaret = caret
        editorGeneration += 1
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        commit()
    }

    private func commit() {
        guard dirty else { return }
        store.save(note.id, content: content)
        dirty = false
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = note.title
            return
        }
        guard trimmed != note.title else { return }
        flush()
        if store.rename(note.id, to: trimmed) == nil {
            title = note.title
        }
    }
}
