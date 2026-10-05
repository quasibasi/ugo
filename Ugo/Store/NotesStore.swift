import Foundation
import Observation
import SwiftData

/// All reads and writes go through here. Views get value snapshots; the
/// SwiftData objects never leave this class.
@Observable @MainActor
final class NotesStore {
    let container: ModelContainer
    @ObservationIgnored private let context: ModelContext

    private(set) var root: FolderItem?
    private(set) var notes: [String: NoteItem] = [:]
    private(set) var isEmpty = true
    private(set) var lastError: String?

    @ObservationIgnored private var folderNames: [String: String] = [:]
    /// Each folder's parent; "" for the top level.
    @ObservationIgnored private var folderParents: [String: String] = [:]
    @ObservationIgnored private var contents: [String: String] = [:]

    init(inMemory: Bool = false) {
        let schema = Schema([Folder.self, Note.self])
        let configuration = ModelConfiguration("Notes", schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not open the notes database: \(error)")
        }
        context = container.mainContext
        refresh()
        // A fresh database fills itself from the Obsidian vault, once.
        if isEmpty, let vault = ObsidianConfig.defaultVaultURL() {
            Task { await importMarkdownFolder(at: vault) }
        }
    }

    // MARK: Snapshots

    func refresh() {
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.trashedAt == nil })
        descriptor.propertiesToFetch = [\.uid, \.title, \.folderUID, \.modifiedAt, \.favoriteRank]
        let fetched = (try? context.fetch(descriptor)) ?? []

        var items: [String: NoteItem] = [:]
        for note in fetched {
            items[note.uid] = NoteItem(id: note.uid, folderID: note.folderUID ?? "", title: note.title, modifiedAt: note.modifiedAt, favoriteRank: note.favoriteRank)
        }
        notes = items
        folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.uid, $0.name) })
        folderParents = Dictionary(uniqueKeysWithValues: folders.map { ($0.uid, $0.parentUID ?? "") })

        var childrenOf: [String: [String]] = [:]
        for folder in folders {
            childrenOf[folder.parentUID ?? "", default: []].append(folder.uid)
        }
        var directCounts: [String: Int] = [:]
        for note in items.values {
            directCounts[note.folderID, default: 0] += 1
        }
        func make(_ id: String) -> FolderItem {
            let kids = (childrenOf[id] ?? [])
                .sorted { (folderNames[$0] ?? "").localizedStandardCompare(folderNames[$1] ?? "") == .orderedAscending }
                .map(make)
            let count = (directCounts[id] ?? 0) + kids.reduce(0) { $0 + $1.noteCount }
            return FolderItem(id: id, name: id.isEmpty ? "Notes" : (folderNames[id] ?? "Folder"), children: kids.isEmpty ? nil : kids, noteCount: count)
        }
        root = make("")
        isEmpty = folders.isEmpty && items.isEmpty
    }

    func folder(withID id: String?) -> FolderItem? {
        guard let root else { return nil }
        guard let id, !id.isEmpty else { return root }
        func find(_ folder: FolderItem) -> FolderItem? {
            if folder.id == id { return folder }
            for child in folder.children ?? [] {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return find(root)
    }

    /// Notes directly inside a folder, newest first. nil means the top level.
    func notes(in folderID: String?) -> [NoteItem] {
        let id = folderID ?? ""
        return notes.values
            .filter { $0.folderID == id }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    // MARK: Content

    private func record(_ id: String) -> Note? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.uid == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func content(of id: String) -> String {
        if let cached = contents[id] { return cached }
        let text = record(id)?.content ?? ""
        contents[id] = text
        return text
    }

    private func persist(_ what: String) {
        do {
            try context.save()
        } catch {
            lastError = "Could not \(what): \(error.localizedDescription)"
        }
    }

    func save(_ id: String, content: String) {
        guard let note = record(id) else { return }
        note.content = content
        note.modifiedAt = .now
        persist("save the note")
        contents[id] = content
        notes[id]?.modifiedAt = note.modifiedAt
    }

    // MARK: Creating, renaming, trashing

    private func uniqueTitle(_ requested: String, in folderID: String) -> String {
        let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Untitled" : base
        let taken = Set(notes.values.filter { $0.folderID == folderID }.map { $0.title.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var counter = 2
        while taken.contains("\(name) \(counter)".lowercased()) { counter += 1 }
        return "\(name) \(counter)"
    }

    @discardableResult
    func createNote(in folderID: String?, title: String? = nil) -> NoteItem? {
        let folder = folderID ?? ""
        let note = Note(title: uniqueTitle(title ?? "", in: folder), folderUID: folder.isEmpty ? nil : folder)
        context.insert(note)
        persist("create the note")
        contents[note.uid] = ""
        refresh()
        return notes[note.uid]
    }

    /// Names already used by the folders directly inside `parentID`, lowercased.
    private func siblingFolderNames(in parentID: String, excluding id: String? = nil) -> Set<String> {
        Set(folderParents.filter { $0.value == parentID && $0.key != id }.compactMap { folderNames[$0.key]?.lowercased() })
    }

    /// Creates a folder inside `parentID` (nil for the top level). A name that is
    /// already taken there gets a number, so "New Folder" becomes "New Folder 2".
    @discardableResult
    func createFolder(named name: String = "New Folder", in parentID: String?) -> FolderItem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parent = parentID ?? ""
        let taken = siblingFolderNames(in: parent)
        var unique = trimmed
        var counter = 2
        while taken.contains(unique.lowercased()) {
            unique = "\(trimmed) \(counter)"
            counter += 1
        }
        let folder = Folder(name: unique, parentUID: parent.isEmpty ? nil : parent)
        context.insert(folder)
        persist("create the folder")
        refresh()
        return self.folder(withID: folder.uid)
    }

    /// Returns false when the name is empty or another folder beside it already has it.
    @discardableResult
    func renameFolder(_ id: String, to newName: String) -> Bool {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let parent = folderParents[id] else { return false }
        guard clean != folderNames[id] else { return true }
        guard !siblingFolderNames(in: parent, excluding: id).contains(clean.lowercased()) else { return false }
        var descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.uid == id })
        descriptor.fetchLimit = 1
        guard let folder = try? context.fetch(descriptor).first else { return false }
        folder.name = clean
        persist("rename the folder")
        refresh()
        return true
    }

    /// Whether `id` is `ancestor` itself or sits somewhere below it.
    func isFolder(_ id: String, within ancestor: String) -> Bool {
        var current = id
        while !current.isEmpty {
            if current == ancestor { return true }
            current = folderParents[current] ?? ""
        }
        return false
    }

    /// Whether the folder can go into `parentID` (nil for the top level):
    /// not into itself or a folder below it, and not where it already is.
    func canMoveFolder(_ id: String, into parentID: String?) -> Bool {
        let parent = parentID ?? ""
        guard let current = folderParents[id], current != parent else { return false }
        return parent.isEmpty || !isFolder(parent, within: id)
    }

    /// Moves the folder, with everything in it, into `parentID` (nil for the top
    /// level). A name already taken there gets a number, as a new folder's does.
    @discardableResult
    func moveFolder(_ id: String, into parentID: String?) -> Bool {
        guard canMoveFolder(id, into: parentID) else { return false }
        let parent = parentID ?? ""
        var descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.uid == id })
        descriptor.fetchLimit = 1
        guard let folder = try? context.fetch(descriptor).first else { return false }
        let taken = siblingFolderNames(in: parent)
        var unique = folder.name
        var counter = 2
        while taken.contains(unique.lowercased()) {
            unique = "\(folder.name) \(counter)"
            counter += 1
        }
        folder.name = unique
        folder.parentUID = parent.isEmpty ? nil : parent
        persist("move the folder")
        refresh()
        return true
    }

    /// Moves the note into `folderID` (nil for the top level). It keeps its
    /// modified date, so it sorts among the other notes as before; a title
    /// already taken there gets a number.
    @discardableResult
    func moveNote(_ id: String, to folderID: String?) -> Bool {
        let folder = folderID ?? ""
        guard let item = notes[id], item.folderID != folder, folder.isEmpty || folderParents[folder] != nil,
              let note = record(id) else { return false }
        note.title = uniqueTitle(note.title, in: folder)
        note.folderUID = folder.isEmpty ? nil : folder
        persist("move the note")
        refresh()
        return true
    }

    /// The folder's parent, nil for a top-level folder.
    func parentID(ofFolder id: String) -> String? {
        guard let parent = folderParents[id], !parent.isEmpty else { return nil }
        return parent
    }

    /// Moves every note in the folder and in the folders below it to the trash,
    /// then removes those folders. Returns the IDs of the notes that were trashed.
    @discardableResult
    func trashFolder(_ id: String) -> [String] {
        guard folderParents[id] != nil else { return [] }
        var doomed: Set<String> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for (child, parent) in folderParents where parent == next && !doomed.contains(child) {
                doomed.insert(child)
                frontier.append(child)
            }
        }
        let now = Date.now
        var trashed: [String] = []
        let live = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.trashedAt == nil }))) ?? []
        for note in live where doomed.contains(note.folderUID ?? "") {
            note.trashedAt = now
            note.favoriteRank = nil
            contents[note.uid] = nil
            trashed.append(note.uid)
        }
        for folder in (try? context.fetch(FetchDescriptor<Folder>())) ?? [] where doomed.contains(folder.uid) {
            context.delete(folder)
        }
        persist("move the folder to the trash")
        refresh()
        return trashed
    }

    /// Returns the note with its new title, or nil when the title is empty or already used in that folder.
    func rename(_ id: String, to newTitle: String) -> NoteItem? {
        guard let item = notes[id], let note = record(id) else { return nil }
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != item.title else { return nil }
        let clash = notes.values.contains { $0.id != id && $0.folderID == item.folderID && $0.title.lowercased() == clean.lowercased() }
        guard !clash else { return nil }
        note.title = clean
        persist("rename the note")
        let renamed = NoteItem(id: id, folderID: item.folderID, title: clean, modifiedAt: item.modifiedAt, favoriteRank: item.favoriteRank)
        notes[id] = renamed
        return renamed
    }

    func trash(_ id: String) {
        guard let note = record(id) else { return }
        note.trashedAt = .now
        note.favoriteRank = nil
        persist("move the note to the trash")
        contents[id] = nil
        refresh()
    }

    // MARK: Favourites

    static let maxFavorites = 9

    /// Favourite notes in shortcut order: the first opens with ⌘0.
    var favorites: [NoteItem] {
        notes.values
            .filter { $0.favoriteRank != nil }
            .sorted { $0.favoriteRank! < $1.favoriteRank! }
    }

    /// Makes exactly these notes the favourites, in this order.
    func setFavorites(_ ids: [String]) {
        let wanted = Array(ids.prefix(Self.maxFavorites))
        let current = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.favoriteRank != nil }))) ?? []
        for note in current where !wanted.contains(note.uid) {
            note.favoriteRank = nil
            notes[note.uid]?.favoriteRank = nil
        }
        for (rank, id) in wanted.enumerated() {
            guard let note = record(id) else { continue }
            note.favoriteRank = rank
            notes[id]?.favoriteRank = rank
        }
        persist("save the favourites")
    }

    func addFavorite(_ id: String) {
        let ids = favorites.map(\.id)
        guard !ids.contains(id), ids.count < Self.maxFavorites else { return }
        setFavorites(ids + [id])
    }

    func removeFavorite(_ id: String) {
        setFavorites(favorites.map(\.id).filter { $0 != id })
    }

    // MARK: Import

    private(set) var isImporting = false
    private(set) var importSummary: String?

    struct ImportedFile: Sendable {
        let relativePath: String
        let title: String
        let content: String?
        let createdAt: Date
        let modifiedAt: Date
    }

    /// Reads every Markdown file below `rootURL` on a background thread. Files
    /// iCloud has evicted are requested and waited for, a few seconds each.
    nonisolated static func scanMarkdownFolder(at rootURL: URL) async -> (folders: [String], files: [ImportedFile]) {
        await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants]) else {
                return ([], [])
            }
            let rootPath = rootURL.standardizedFileURL.path
            var folders: [String] = []
            var files: [ImportedFile] = []
            while let url = enumerator.nextObject() as? URL {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: keys)
                let isDirectory = values?.isDirectory ?? false
                if name.hasPrefix(".") {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath) else { continue }
                let relative = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if isDirectory {
                    folders.append(relative)
                    continue
                }
                guard url.pathExtension.lowercased() == "md" else { continue }
                if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    let deadline = Date().addingTimeInterval(8)
                    while Date() < deadline {
                        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus, status == .current { break }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                let content = try? String(contentsOf: url, encoding: .utf8)
                files.append(ImportedFile(
                    relativePath: relative, title: String(name.dropLast(3)), content: content,
                    createdAt: values?.creationDate ?? .now, modifiedAt: values?.contentModificationDate ?? .now))
            }
            return (folders, files)
        }.value
    }

    /// Copies a folder of Markdown files, such as an Obsidian vault, into the database.
    /// Folders become folders, each .md file becomes a note. A note that already exists in
    /// the same folder is skipped, unless it is empty and the file has text, in which case
    /// it is filled in.
    @discardableResult
    func importMarkdownFolder(at rootURL: URL) async -> Int {
        isImporting = true
        defer { isImporting = false }
        let (folders, files) = await Self.scanMarkdownFolder(at: rootURL)

        var folderUIDByPath: [String: String] = ["": ""]
        let existingFolders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        var existingByParentAndName: [String: String] = [:]
        for folder in existingFolders {
            existingByParentAndName[(folder.parentUID ?? "") + "/" + folder.name.lowercased()] = folder.uid
        }
        let existingNotes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.trashedAt == nil }))) ?? []
        var existingByKey: [String: Note] = [:]
        for note in existingNotes {
            existingByKey[(note.folderUID ?? "") + "/" + note.title.lowercased()] = note
        }

        func folderUID(forPath path: String) -> String {
            if let uid = folderUIDByPath[path] { return uid }
            let parentPath = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
            let parentUID = folderUID(forPath: parentPath)
            let name = path.contains("/") ? String(path[path.index(after: path.lastIndex(of: "/")!)...]) : path
            let key = parentUID + "/" + name.lowercased()
            if let uid = existingByParentAndName[key] {
                folderUIDByPath[path] = uid
                return uid
            }
            let folder = Folder(name: name, parentUID: parentUID.isEmpty ? nil : parentUID)
            context.insert(folder)
            existingByParentAndName[key] = folder.uid
            folderUIDByPath[path] = folder.uid
            return folder.uid
        }

        for path in folders {
            _ = folderUID(forPath: path)
        }
        var imported = 0
        var filled = 0
        var unreadable = 0
        for file in files {
            let parentPath = file.relativePath.contains("/") ? String(file.relativePath[..<file.relativePath.lastIndex(of: "/")!]) : ""
            let uid = folderUID(forPath: parentPath)
            let key = uid + "/" + file.title.lowercased()
            if file.content == nil { unreadable += 1 }
            if let existing = existingByKey[key] {
                if existing.content.isEmpty, let text = file.content, !text.isEmpty {
                    existing.content = text
                    existing.modifiedAt = file.modifiedAt
                    filled += 1
                }
                continue
            }
            let note = Note(
                title: file.title, content: file.content ?? "", folderUID: uid.isEmpty ? nil : uid,
                createdAt: file.createdAt, modifiedAt: file.modifiedAt)
            context.insert(note)
            existingByKey[key] = note
            imported += 1
        }
        persist("import the folder")
        contents = [:]
        refresh()
        var parts = ["Imported \(imported) notes"]
        if filled > 0 { parts.append("filled \(filled) that were empty") }
        if unreadable > 0 { parts.append("\(unreadable) could not be read, most likely not downloaded from iCloud yet; import again later") }
        importSummary = parts.joined(separator: ", ") + "."
        return imported + filled
    }

    /// The Obsidian vault the first import came from, when Obsidian is set up.
    var obsidianVaultURL: URL? { ObsidianConfig.defaultVaultURL() }

    // MARK: Search

    private static let checklistLine = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+\[([ xX])\][ \t]+(.+?)[ \t]*$"#)

    func search(_ rawQuery: String, limit: Int = 12) -> [QuickOpenResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            return notes.values.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map {
                QuickOpenResult(id: "note:" + $0.id, kind: .note, noteID: $0.id, title: $0.title, subtitle: folderPath($0.folderID), score: 0)
            }
        }
        var results: [QuickOpenResult] = []
        for note in notes.values {
            if let score = Self.match(query, in: note.title.lowercased()) {
                // A title that contains the query beats everything; a loose subsequence match ranks below an exact checklist hit.
                let ranked = score >= 200 ? 1000 + score : score
                results.append(QuickOpenResult(id: "note:" + note.id, kind: .note, noteID: note.id, title: note.title, subtitle: folderPath(note.folderID), score: ranked))
            }
        }
        let needle = rawQuery.trimmingCharacters(in: .whitespaces)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.trashedAt == nil && $0.content.localizedStandardContains(needle) })
        for note in (try? context.fetch(descriptor)) ?? [] {
            var lineNumber = 0
            note.content.enumerateLines { line, _ in
                lineNumber += 1
                let ns = line as NSString
                guard let m = Self.checklistLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
                let body = ns.substring(with: m.range(at: 2))
                guard let score = Self.match(query, in: body.lowercased()) else { return }
                let done = ns.substring(with: m.range(at: 1)).lowercased() == "x"
                results.append(QuickOpenResult(
                    id: "line:\(note.uid):\(lineNumber)", kind: .checklistLine(done: done), noteID: note.uid,
                    title: body, subtitle: note.title, score: (done ? 0 : 200) + score))
            }
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return Array(results.prefix(limit))
    }

    func folderPath(_ id: String) -> String {
        folderNames[id] ?? ""
    }

    /// Substring match scores highest, then a subsequence match with few gaps.
    private static func match(_ query: String, in text: String) -> Int? {
        if text.hasPrefix(query) { return 300 }
        if text.contains(query) { return 200 }
        var score = 100
        var index = text.startIndex
        for ch in query {
            guard let found = text[index...].firstIndex(of: ch) else { return nil }
            score -= text.distance(from: index, to: found)
            index = text.index(after: found)
        }
        return max(score, 1)
    }
}
