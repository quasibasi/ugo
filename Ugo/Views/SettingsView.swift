#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Pane: Hashable {
        case general
        case favorites
    }

    @State private var pane: Pane? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $pane) {
                Label("General", systemImage: "gearshape").tag(Pane.general)
                Label("Favourites", systemImage: "star").tag(Pane.favorites)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            switch pane ?? .general {
            case .general: GeneralSettings()
            case .favorites: FavoritesSettings()
            }
        }
        .frame(width: 700, height: 500)
    }
}

/// Picks the notes ⌘0 to ⌘8 open, and their order.
private struct FavoritesSettings: View {
    @Environment(NotesStore.self) private var store
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var favorites: [NoteItem] { store.favorites }
    private var isFull: Bool { favorites.count >= NotesStore.maxFavorites }

    /// Notes matching the search that are not favourites yet.
    private var candidates: [QuickOpenResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let taken = Set(favorites.map(\.id))
        return store.search(query, limit: 30)
            .filter { $0.kind == .note && !taken.contains($0.noteID) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Favourites").font(.title2.weight(.semibold))
                Text("⌘0 to ⌘8 open these notes, the top one first. Drag to reorder.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(isFull ? "Nine favourites; remove one to add another" : "Search for a note to add", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = candidates.first { add(first.noteID) } }
                    .disabled(isFull)
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))

            if !candidates.isEmpty {
                VStack(spacing: 1) {
                    ForEach(candidates) { result in
                        CandidateRow(result: result) { add(result.noteID) }
                    }
                }
            }

            List {
                ForEach(Array(favorites.enumerated()), id: \.element.id) { index, note in
                    HStack(spacing: 10) {
                        Text("⌘\(index)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                        Text(note.title).lineLimit(1)
                        Text(store.folderPath(note.folderID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.removeFavorite(note.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove from favourites")
                    }
                    .padding(.vertical, 3)
                }
                .onMove { from, to in
                    var ids = favorites.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    store.setFavorites(ids)
                }
                .onDelete { offsets in
                    var ids = favorites.map(\.id)
                    ids.remove(atOffsets: offsets)
                    store.setFavorites(ids)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if favorites.isEmpty {
                    Text("No favourites yet").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { searchFocused = true }
    }

    private func add(_ id: String) {
        store.addFavorite(id)
        query = ""
        searchFocused = !isFull
    }
}

private struct CandidateRow: View {
    let result: QuickOpenResult
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 16)
            Text(result.title).lineLimit(1)
            if !result.subtitle.isEmpty {
                Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill").foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: add)
    }
}

private struct GeneralSettings: View {
    @Environment(NotesStore.self) private var store
    @AppStorage("editorFontSize") private var fontSize: Double = 15
    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.system.rawValue
    @AppStorage(TitleFont.familyKey) private var titleFamily = TitleFont.defaultFamily
    @AppStorage(TitleFont.weightKey) private var titleWeight = TitleFont.defaultWeight
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeCard(theme: theme, isSelected: theme.rawValue == themeID) { themeID = theme.rawValue }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Editor") {
                Slider(value: $fontSize, in: 11...24, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("A").font(.caption)
                } maximumValueLabel: {
                    Text("A").font(.title3)
                }
                LabeledContent("Size", value: "\(Int(fontSize)) pt")
            }
            Section("Note title") {
                Picker("Font", selection: $titleFamily) {
                    ForEach(TitleFont.builtIn, id: \.id) { Text($0.name).tag($0.id) }
                    Divider()
                    ForEach(TitleFont.installedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Picker("Weight", selection: $titleWeight) {
                    ForEach(TitleFont.Weight.allCases) { Text($0.name).tag($0.rawValue) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Trip to Lisbon")
                        .font(TitleFont.font(family: titleFamily, weight: titleWeight, size: 28))
                        .lineLimit(1)
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
                .padding(.vertical, 6)
            }
            Section("Import") {
                if let vault = store.obsidianVaultURL {
                    LabeledContent("Obsidian vault") {
                        Button("Import Again") { Task { await store.importMarkdownFolder(at: vault) } }
                    }
                    Text(vault.path).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Markdown folder") {
                    Button("Import…") { choosingFolder = true }
                }
                if store.isImporting {
                    ProgressView("Importing…")
                } else if let summary = store.importSummary {
                    Text(summary).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await store.importMarkdownFolder(at: url) }
            }
        }
    }
}

/// A theme's name under a small drawing of the window in its colours. Clicking it picks the theme.
private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemePreview(palette: theme.previewPalette(for: colorScheme))
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                }
            HStack(spacing: 4) {
                Text(theme.name).font(.system(size: 12, weight: .medium))
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                }
            }
            Text(theme.summary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The window in miniature: the sidebar, and a note with a tab, a heading, checkboxes and a quote.
private struct ThemePreview: View {
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 4, height: 4) }
                }
                .padding(.bottom, 3)
                bar(0.6, palette.text)
                bar(0.85, palette.text, highlighted: true).padding(.leading, 6)
                bar(0.6, palette.text).padding(.leading, 6)
                bar(0.75, palette.text).padding(.leading, 6)
                bar(0.5, palette.text)
                bar(0.7, palette.text)
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(width: 46)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(hex: palette.side))
            hairline
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: palette.tabActive)).frame(width: 26, height: 6)
                RoundedRectangle(cornerRadius: 1).fill(Color(hex: palette.heading)).frame(width: 34, height: 4)
                checkbox(done: true, width: 0.7)
                checkbox(done: false, width: 0.55)
                HStack(spacing: 3) {
                    Rectangle().fill(Color(hex: palette.quoteBar)).frame(width: 1.5, height: 7)
                    RoundedRectangle(cornerRadius: 1).fill(Color(hex: palette.muted)).frame(height: 2.5)
                }
                .frame(maxWidth: 40)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: palette.editor))
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color(hex: palette.hairline)).frame(width: 1)
    }

    private func bar(_ fraction: CGFloat, _ hex: UInt32, highlighted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(hex: hex).opacity(0.55))
            .frame(height: 2.5)
            .scaleEffect(x: fraction, anchor: .leading)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 2)
            .background(highlighted ? Color(hex: palette.highlight) : .clear, in: RoundedRectangle(cornerRadius: 2))
    }

    private func checkbox(done: Bool, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(done ? Color(hex: palette.accent) : .clear)
                .overlay { if !done { RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color(hex: palette.checkboxBorder), lineWidth: 0.8) } }
                .frame(width: 6, height: 6)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(hex: done ? palette.muted : palette.text).opacity(done ? 1 : 0.7))
                .frame(width: 50 * width, height: 2.5)
        }
    }
}
#endif
