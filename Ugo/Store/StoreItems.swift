import Foundation

/// Lightweight snapshots the views work with, so lists never touch the database directly.
struct FolderItem: Identifiable, Hashable {
    let id: String
    let name: String
    /// nil when the folder has no subfolders, so outline views show no disclosure control.
    var children: [FolderItem]?
    /// Notes in this folder and every folder below it.
    var noteCount: Int
}

struct NoteItem: Identifiable, Hashable {
    let id: String
    let folderID: String
    let title: String
    var modifiedAt: Date
    var favoriteRank: Int?
    var fullWidth = false
}

struct QuickOpenResult: Identifiable, Hashable {
    enum Kind: Hashable {
        case note
        case checklistLine(done: Bool)
        case createNote
    }

    let id: String
    let kind: Kind
    let noteID: String
    let title: String
    let subtitle: String
    let score: Int
}
