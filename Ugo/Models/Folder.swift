import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var uid: String = UUID().uuidString
    var name: String = ""
    /// nil means the folder sits at the top level.
    var parentUID: String?
    var createdAt: Date = Date.now

    init(name: String, parentUID: String?) {
        self.name = name
        self.parentUID = parentUID
    }
}
