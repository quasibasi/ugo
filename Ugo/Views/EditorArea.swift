import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The editor side of the window: every open pane in its place in the grid,
/// or a placeholder while nothing is open. Columns sit side by side, and a
/// column's second pane sits under its first.
struct EditorArea: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // A note swap or a tab change happens at once, never as a fade.
        area.transaction { $0.animation = nil }
    }

    @ViewBuilder private var area: some View {
        let layout = appState.layout
        if layout.isEmpty {
            EmptyEditorPane()
        } else if appState.zenMode, let pane = layout.focusedPane ?? layout.panes.first {
            EditorPaneView(pane: pane, isFocused: true, isLeadingCorner: true)
        } else {
            #if os(macOS)
            ProportionalSplit(axis: .horizontal, items: layout.columns, fractions: columnFractions, minimum: 240) { columnIndex, column in
                ProportionalSplit(axis: .vertical, items: column.panes, fractions: paneFractions(in: column.id), minimum: 160) { rowIndex, pane in
                    EditorPaneView(pane: pane, isFocused: pane.id == layout.focusedPaneID, isLeadingCorner: columnIndex == 0 && rowIndex == 0)
                }
            }
            #else
            if let pane = layout.focusedPane ?? layout.panes.first {
                EditorPaneView(pane: pane, isFocused: true, isLeadingCorner: true)
            }
            #endif
        }
    }

    /// The columns' width shares; a divider drag writes them back into the layout.
    private var columnFractions: Binding<[Double]> {
        Binding(
            get: { appState.layout.columns.map(\.fraction) },
            set: { appState.layout.setColumnFractions($0) })
    }

    private func paneFractions(in columnID: String) -> Binding<[Double]> {
        Binding(
            get: { appState.layout.columns.first { $0.id == columnID }?.panes.map(\.fraction) ?? [] },
            set: { appState.layout.setPaneFractions($0, in: columnID) })
    }
}

/// One pane: its tabs in the header strip, the active note below.
struct EditorPaneView: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    let pane: EditorPane
    let isFocused: Bool
    /// The top-left pane makes room for the traffic lights when the side panels are hidden.
    let isLeadingCorner: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let inset = isLeadingCorner && !appState.panesVisible
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Zen mode keeps the empty strip to drag the window by, without the tabs.
                if !appState.zenMode {
                    TabStrip(pane: pane, isFocused: isFocused)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .padding(.leading, inset ? 84 : 10)
            .padding(.trailing, 12)
            // The hairline the active tab's underline sits on.
            .background(alignment: .bottom) {
                if !appState.zenMode {
                    Rectangle()
                        .fill(palette.map { Color(hex: $0.hairline) } ?? Color.primary.opacity(0.1))
                        .frame(height: 1)
                }
            }
            if let id = pane.activeNoteID, let note = store.notes[id] {
                NoteEditorView(note: note, paneID: pane.id, initialContent: store.content(of: id))
                    .id(note.id)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The pane's tabs, packed from the left. The focused pane's active tab is underlined in the accent colour.
private struct TabStrip: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    let pane: EditorPane
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pane.tabs) { tab in
                TabItem(
                    title: store.notes[tab.noteID]?.title ?? "Untitled",
                    isPreview: tab.isPreview,
                    isActive: tab.id == pane.activeTabID,
                    isFocused: isFocused,
                    activate: { appState.layout.activate(tab.id, in: pane.id) },
                    keep: { appState.layout.keep(tab.id, in: pane.id) },
                    close: { appState.layout.close(tab.id, in: pane.id) })
                .contextMenu {
                    if tab.isPreview {
                        Button("Keep Open") { appState.layout.keep(tab.id, in: pane.id) }
                    }
                    Button("Open in Split") { appState.openInSplit(tab.noteID) }
                        .disabled(pane.tabs.count < 2 && tab.displacedNoteID == nil)
                    Divider()
                    Button("Close Tab") { appState.layout.close(tab.id, in: pane.id) }
                    Button("Close Other Tabs") { appState.layout.closeOtherTabs(than: tab.id, in: pane.id) }
                        .disabled(pane.tabs.count < 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }
}

/// A title, italic while the tab is a preview, with a close button on hover.
/// The active tab is underlined on the strip's bottom edge: accent in the
/// focused pane, grey in the others.
/// The tab is as wide as its title, up to a cap, so tabs sit next to each other.
private struct TabItem: View {
    let title: String
    let isPreview: Bool
    let isActive: Bool
    let isFocused: Bool
    let activate: () -> Void
    let keep: () -> Void
    let close: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HugWidth(upTo: 220) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .italic(isPreview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || isActive ? 1 : 0)
                .help("Close tab (⌘W)")
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(underline)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
        .onTapGesture {
            // One click handler: a separate double-click gesture would make
            // the single click wait out the double-click interval.
            #if os(macOS)
            // clickCount raises an exception on anything but a mouse event.
            let event = NSApp.currentEvent
            let isMouse = event.map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
            if isMouse, event!.clickCount >= 2 {
                keep()
            } else {
                activate()
            }
            #else
            activate()
            #endif
        }
        .help(isPreview ? "Preview: the next note you click replaces it. Double-click or ⌘/ to keep it open." : title)
    }

    private var underline: Color {
        if isActive {
            if let palette { return isFocused ? Color(hex: palette.accent) : Color(hex: palette.checkboxBorder) }
            return isFocused ? Color.accentColor : Color.primary.opacity(0.25)
        }
        return hovering ? Color.primary.opacity(0.18) : .clear
    }
}

/// Gives its content its own width, up to a cap, instead of the width the
/// container offers. A flexible frame would stretch every tab to the cap.
private struct HugWidth: Layout {
    var upTo: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = min(view.sizeThatFits(.unspecified).width, upTo)
        let height = view.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// What the editor side shows while no note is open.
private struct EmptyEditorPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView("No Note Open", systemImage: "note.text", description: Text("Pick a note, press ⌘N for a new one, ⌘P to find one, or ⌘\\ for the side panels."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
