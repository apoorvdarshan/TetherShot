import Foundation

/// Persists the user's chosen destination folder across launches using a
/// bookmark (survives the folder being moved/renamed). Defaults to
/// ~/Pictures/TetherShot on first run.
enum FolderStore {
    private static let key = "destinationFolderBookmark"

    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("TetherShot", isDirectory: true)
    }

    static func load() -> URL {
        if let data = UserDefaults.standard.data(forKey: key) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                if isStale { save(url) }
                return url
            }
        }
        let folder = defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func save(_ url: URL) {
        if let data = try? url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
