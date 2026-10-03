import SwiftUI
#if os(macOS)
import AppKit
#endif

/// ⌘P: find a note or a checklist line by name, or create a note with the typed name.
struct QuickOpenView: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var results: [QuickOpenResult] = []
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool
    #if os(macOS)
    @State private var keys = KeyInterceptor()
    #endif

    private var rows: [QuickOpenResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return results }
        let folderName = store.folder(withID: appState.selectedFolderID)?.name ?? "Notes"
        let create = QuickOpenResult(
            id: "create", kind: .createNote, noteID: "", title: "New note “\(trimmed)”", subtitle: "in \(folderName)", score: -1)
        return results + [create]
    }

    @ViewBuilder private var surface: some View {
        if let palette {
            Color(hex: palette.list)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    private var hairline: Color {
        palette.map { Color(hex: $0.hairline) } ?? Color.secondary.opacity(0.25)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .light))
                    .focused($focused)
                    .onSubmit { open(rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil) }
                    #if os(macOS)
                    .onExitCommand(perform: dismiss)
                    #endif
                    .padding(EdgeInsets(top: 20, leading: 22, bottom: 16, trailing: 22))
                if !rows.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                            ResultRow(result: result, query: query, selected: index == selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { open(result) }
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                }
                Rectangle().fill(hairline).frame(height: 1)
                HStack(spacing: 16) {
                    LegendItem(keys: "↩", label: "open")
                    LegendItem(keys: "⇧↩", label: "zen with a new ##")
                    LegendItem(keys: "⌘↩", label: "new note")
                    LegendItem(keys: "esc", label: "close")
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 10, leading: 22, bottom: 12, trailing: 22))
            }
            .frame(width: 660)
            .background { surface }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hairline))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
            .padding(.top, 130)
        }
        .onAppear {
            refresh()
            #if os(macOS)
            keys.start { event in
                switch event.keyCode {
                case 126: move(-1); return true            // up arrow
                case 125: move(1); return true             // down arrow
                case 53: dismiss(); return true            // escape
                case 36 where event.modifierFlags.contains(.shift):
                    openInSectionZen(); return true        // ⇧ return
                case 36 where event.modifierFlags.contains(.command):
                    createNote(); return true              // ⌘ return
                default: return false
                }
            }
            #endif
        }
        .task {
            // Focus asked for in onAppear is dropped: the field isn't in the window yet
            // and the note editor still holds the keyboard. Ask again until it sticks.
            for _ in 0..<10 where !focused {
                focused = true
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        #if os(macOS)
        .onDisappear { keys.stop() }
        #else
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.shift) {
                openInSectionZen()
                return .handled
            }
            guard press.modifiers.contains(.command) else { return .ignored }
            createNote()
            return .handled
        }
        #endif
        .onChange(of: query) { refresh() }
    }

    private func refresh() {
        results = store.search(query)
        selectedIndex = 0
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    }

    private func open(_ result: QuickOpenResult?) {
        guard let result else { return }
        if case .createNote = result.kind {
            createNote()
            return
        }
        guard let note = store.notes[result.noteID] else { return }
        appState.selectedFolderID = note.folderID.isEmpty ? nil : note.folderID
        appState.show(note.id)
        dismiss()
    }

    @discardableResult
    private func createNote() -> String? {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard let note = store.createNote(in: appState.selectedFolderID, title: name.isEmpty ? nil : name) else { return nil }
        appState.openInNewTab(note.id)
        dismiss()
        return note.id
    }

    /// Opens the highlighted note, or creates the typed one, in section zen
    /// on a new empty `##` at its top.
    private func openInSectionZen() {
        guard rows.indices.contains(selectedIndex) else { return }
        let result = rows[selectedIndex]
        let noteID: String
        if case .createNote = result.kind {
            guard let id = createNote() else { return }
            noteID = id
        } else {
            guard let note = store.notes[result.noteID] else { return }
            open(result)
            noteID = note.id
        }
        if !appState.sectionZen { appState.zenBeforeSection = appState.zenMode }
        appState.zenMode = true
        // Asked once the zen editor for the note is on screen; the one there now would take it.
        DispatchQueue.main.async { appState.sectionRequest = .newSection(noteID: noteID) }
    }

    private func dismiss() {
        appState.quickOpenPresented = false
    }
}

private struct LegendItem: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys).foregroundStyle(.primary.opacity(0.75)).fontWeight(.medium)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

/// A result in A's look: no icon for a plain note, the folder or note it sits in
/// right after the title, the whole row in the accent colour when highlighted.
private struct ResultRow: View {
    @Environment(\.palette) private var palette
    let result: QuickOpenResult
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 15)
            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)
            if !result.subtitle.isEmpty {
                Text(result.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AnyShapeStyle(onAccent.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(onAccent.opacity(0.85))
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(selected ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }

    private var accent: Color { palette.map { Color(hex: $0.accent) } ?? .accentColor }
    private var onAccent: Color { palette.map { Color(hex: $0.onAccent) } ?? .white }
    private var matchColor: Color { palette.map { Color(hex: $0.link) } ?? .accentColor }

    /// The title with the typed text picked out: bold, and in the link colour unless the row is highlighted.
    private var title: AttributedString {
        var text = AttributedString(result.title)
        let needle = query.trimmingCharacters(in: .whitespaces)
        if case .createNote = result.kind { return text }
        guard !needle.isEmpty, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return text }
        text[range].font = .system(size: 14, weight: .semibold)
        if !selected { text[range].foregroundColor = matchColor }
        return text
    }

    private var hint: String {
        if case .createNote = result.kind { return "⌘↩" }
        return "↩"
    }

    @ViewBuilder private var icon: some View {
        switch result.kind {
        case .note:
            Color.clear
        case .checklistLine(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? AnyShapeStyle(onAccent) : done ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
        case .createNote:
            Image(systemName: "plus").foregroundStyle(selected ? AnyShapeStyle(onAccent) : AnyShapeStyle(.secondary))
        }
    }
}

#if os(macOS)
/// Sees key presses before the focused text field does, for as long as it is started.
@MainActor
final class KeyInterceptor {
    private var monitor: Any?

    /// The handler returns true when it consumed the key.
    func start(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { handler(event) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
