import Foundation
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var uid: String = UUID().uuidString
    var title: String = ""
    var content: String = ""
    /// nil means the note sits at the top level.
    var folderUID: String?
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now
    /// Set instead of deleting, so a note can be recovered.
    var trashedAt: Date?
    /// Position among the favourites, nil when the note is not one. The lowest opens with ⌘0.
    var favoriteRank: Int?
    /// Shown across the whole pane instead of in the reading column.
    var fullWidth: Bool = false

    init(title: String, content: String = "", folderUID: String?, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.title = title
        self.content = content
        self.folderUID = folderUID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
