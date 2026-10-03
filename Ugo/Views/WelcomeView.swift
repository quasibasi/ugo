import SwiftUI
import UniformTypeIdentifiers

/// First launch: bring the existing folders and notes in, or start empty.
struct WelcomeView: View {
    @Environment(NotesStore.self) private var store
    @State private var choosingFolder = false
    @State private var obsidianVault = ObsidianConfig.defaultVaultURL()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Bring your notes in")
                .font(.title2.weight(.semibold))
            if let vault = obsidianVault {
                Text("Obsidian vault found at\n\(vault.path)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("Import from Obsidian") { Task { await store.importMarkdownFolder(at: vault) } }
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                Button("Import a Folder…") { choosingFolder = true }
                Button("Start Empty") { store.createNote(in: nil) }
            }
            .padding(.top, 4)
            if store.isImporting {
                ProgressView("Importing…").padding(.top, 8)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await store.importMarkdownFolder(at: url) } }
        }
    }
}
