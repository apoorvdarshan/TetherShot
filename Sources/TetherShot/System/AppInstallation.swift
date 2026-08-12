import AppKit
import Foundation

/// Resolves TetherShot's two supported installation locations and keeps only
/// one discoverable copy. A DMG installation in /Applications is canonical;
/// the per-user location remains the no-admin fallback for source/npm installs.
enum AppInstallation {
    static let bundleIdentifier = "com.apoorvdarshan.tethershot"
    static let systemApp = URL(fileURLWithPath: "/Applications/TetherShot.app", isDirectory: true)

    static var userApp: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/TetherShot.app", isDirectory: true)
    }

    static var currentApp: URL {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    static var canonicalApp: URL {
        isTetherShot(systemApp) ? systemApp : userApp
    }

    static func isSupportedInstallLocation(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return resolved == systemApp.standardizedFileURL.resolvingSymlinksInPath()
            || resolved == userApp.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// If both copies exist and the user opened the per-user copy, relaunch the
    /// canonical system copy. Its next launch archives the stale user copy.
    @MainActor
    static func relaunchCanonicalCopyIfNeeded() -> Bool {
        guard currentApp == userApp.standardizedFileURL.resolvingSymlinksInPath(),
              isTetherShot(systemApp) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", systemApp.path]
        do {
            try process.run()
            NSApp.terminate(nil)
            return true
        } catch {
            Log.shared.log("canonical install relaunch failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Recoverably removes an old npm/source copy after the /Applications copy
    /// has become canonical. Only a bundle with TetherShot's identifier moves.
    static func archiveDuplicateUserCopyIfNeeded() {
        guard currentApp == systemApp.standardizedFileURL.resolvingSymlinksInPath(),
              isTetherShot(userApp) else { return }
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: userApp, resultingItemURL: &trashedURL)
            Log.shared.log("archived duplicate app: \(trashedURL?.path ?? userApp.path)")
        } catch {
            Log.shared.log("duplicate app cleanup failed: \(error.localizedDescription)")
        }
    }

    private static func isTetherShot(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url) else { return false }
        return bundle.bundleIdentifier == bundleIdentifier
    }
}
