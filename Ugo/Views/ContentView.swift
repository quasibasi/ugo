import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(NotesStore.self) private var store
    @Environment(AppState.self) private var appState
    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.system.rawValue

    private var theme: AppTheme { AppTheme.stored(themeID) }

    private var trashPrompt: String {
        guard let folder = store.folder(withID: appState.folderPendingTrash) else { return "" }
        let notes = folder.noteCount == 1 ? "1 note" : "\(folder.noteCount) notes"
        return "Move \u{201C}\(folder.name)\u{201D} and its \(notes) to the trash?"
    }

    var body: some View {
        ZStack {
            if store.isEmpty {
                WelcomeView()
            } else {
                panes
            }
            if appState.quickOpenPresented {
                QuickOpenView()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .background { if let palette = theme.palette { Color(hex: palette.editor).ignoresSafeArea() } }
        .themedText(theme.palette)
        .confirmationDialog(
            trashPrompt,
            isPresented: Binding(get: { appState.folderPendingTrash != nil }, set: { if !$0 { appState.folderPendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: appState.folderPendingTrash
        ) { folderID in
            Button("Move to Trash", role: .destructive) { appState.trashFolder(folderID, store: store) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its notes and the folders inside it go too. Trashed notes can't be restored from Ugo yet.")
        }
        .environment(\.palette, theme.palette)
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        #endif
        // Tabs saved by the last run may point at notes trashed since.
        .onAppear { appState.layout.prune { store.notes[$0] != nil } }
        #if os(macOS)
        .background(WindowConfigurator())
        .onChange(of: themeID, initial: true) { theme.applyAppearance() }
        #else
        .preferredColorScheme(theme.colorScheme)
        #endif
    }

    @ViewBuilder private var panes: some View {
        #if os(macOS)
        SidePanels()
        #else
        NavigationSplitView {
            SidebarView()
        } detail: {
            EditorArea()
        }
        #endif
    }
}

#if os(macOS)
/// The sidebar at a fixed width beside the editor, which takes whatever the
/// window has left. Dragging the divider sets the sidebar's width.
private struct SidePanels: View {
    @Environment(AppState.self) private var appState
    /// The width a divider drag is showing, before it is saved on release.
    @State private var liveWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let width = SidePanelLayout.width(total: total, preferred: liveWidth ?? appState.sidebarWidth)
            HStack(spacing: 0) {
                if appState.panesVisible {
                    SidebarView()
                        .frame(width: width)
                    PanelDivider { start, delta in
                        // Never wider than leaves the editor its minimum.
                        let room = total - SidePanelLayout.editorMinimum - SidePanelLayout.divider
                        liveWidth = min(start + delta, max(room, SidePanelLayout.range.lowerBound))
                    } start: { width } ended: {
                        if let liveWidth { appState.sidebarWidth = SidePanelLayout.clamp(liveWidth, to: SidePanelLayout.range) }
                        liveWidth = nil
                    }
                    .zIndex(1)
                }
                EditorArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// A hairline between the sidebar and the editor, with a wider strip around it to grab.
private struct PanelDivider: View {
    @Environment(\.palette) private var palette
    /// Called during a drag with the width the panel had when it began and how far the pointer moved.
    let changed: (CGFloat, CGFloat) -> Void
    let start: () -> CGFloat
    let ended: () -> Void

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(palette.map { AnyShapeStyle(Color(hex: $0.hairline)) } ?? AnyShapeStyle(.separator))
            .frame(width: SidePanelLayout.divider)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let width = startWidth ?? start()
                                if startWidth == nil { startWidth = width }
                                changed(width, value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                ended()
                            })
            }
    }
}

/// Lets the window be dragged by its empty header strips and keeps the title bar out of the way.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguringView { ConfiguringView() }
    func updateNSView(_ nsView: ConfiguringView, context: Context) {}

    final class ConfiguringView: NSView {
        private var didSizeWindow = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Open filling the screen, leaving the menu bar and Dock visible.
            if !didSizeWindow, let screen = window.screen ?? NSScreen.main {
                didSizeWindow = true
                let frame = screen.visibleFrame
                DispatchQueue.main.async {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }
}
#endif
