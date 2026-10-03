import Foundation

enum ObsidianConfig {
    /// The vault Obsidian has open, read from its own config, or nil when Obsidian is not set up.
    static func defaultVaultURL() -> URL? {
        #if os(macOS)
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        let ordered = vaults.values.sorted { a, b in
            let aOpen = a["open"] as? Bool ?? false
            let bOpen = b["open"] as? Bool ?? false
            if aOpen != bOpen { return aOpen }
            return (a["ts"] as? Double ?? 0) > (b["ts"] as? Double ?? 0)
        }
        guard let path = ordered.first?["path"] as? String else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }
}
