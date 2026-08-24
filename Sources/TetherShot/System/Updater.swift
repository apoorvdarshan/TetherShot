import AppKit
import CryptoKit
import Foundation

struct UpdateInfo {
    let latest: String
    let isNewer: Bool
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let downloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case digest
    }
}

private struct PendingUpdate {
    let stagedApp: URL
    let destination: URL
}

private enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

/// Updates from the signed, notarized GitHub release rather than npm. This is
/// the same path for DMG and source/npm users, so normal updates never require
/// Node.js, Xcode, or a compiler.
@MainActor
final class Updater {
    private static let repository = "apoorvdarshan/TetherShot"
    private static let teamIdentifier = "23RV7FYH36"
    private static let bundleIdentifier = AppInstallation.bundleIdentifier
    private var pendingUpdate: PendingUpdate?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdate() async -> UpdateInfo? {
        guard let release = try? await latestRelease(),
              let latest = Self.version(from: release.tagName) else { return nil }
        return UpdateInfo(latest: latest, isNewer: Self.isNewer(latest, than: currentVersion))
    }

    /// Numeric, component-wise semver comparison. Prerelease suffixes do not
    /// outrank the matching stable version.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            let core = value.split(separator: "-").first.map(String.init) ?? value
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let remoteParts = parts(remote)
        let localParts = parts(local)
        for index in 0..<max(remoteParts.count, localParts.count) {
            let remotePart = index < remoteParts.count ? remoteParts[index] : 0
            let localPart = index < localParts.count ? localParts[index] : 0
            if remotePart != localPart { return remotePart > localPart }
        }
        return !remote.contains("-") && local.contains("-")
    }

    /// Downloads, verifies, and stages the latest release next to the running
    /// installation. Replacement happens only after this process exits.
    func installUpdate() async -> (Bool, String) {
        do {
            let release = try await latestRelease()
            guard let version = Self.version(from: release.tagName),
                  Self.isNewer(version, than: currentVersion) else {
                return (false, "No newer signed release is available.")
            }
            pendingUpdate = try await prepare(release: release, version: version)
            return (true, "Signed update prepared.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Launches a path-safe detached helper, then quits. The helper atomically
    /// swaps the verified staged bundle into the same installation location and
    /// rolls back if the replacement fails.
    func relaunchAndQuit() {
        guard let pendingUpdate else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.replacementScript,
            "tethershot-update",
            String(ProcessInfo.processInfo.processIdentifier),
            pendingUpdate.stagedApp.path,
            pendingUpdate.destination.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Log.shared.log("update helper failed to start: \(error.localizedDescription)")
        }
    }

    private func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            throw UpdateError.message("Invalid release endpoint.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("TetherShot-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("GitHub did not return the latest release.")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func prepare(release: GitHubRelease, version: String) async throws -> PendingUpdate {
        let destination = AppInstallation.currentApp
        guard AppInstallation.isSupportedInstallLocation(destination) else {
            throw UpdateError.message("Move TetherShot to Applications before installing updates.")
        }

        let assetName = "TetherShot-\(version)-universal.dmg"
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError.message("Release \(version) does not contain the universal DMG.")
        }
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") else {
            throw UpdateError.message("The release is missing its GitHub SHA-256 digest.")
        }

        let fileManager = FileManager.default
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let work = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        let dmg = work.appendingPathComponent(assetName)
        let mountPoint = work.appendingPathComponent("mounted", isDirectory: true)
        do {
            try await download(asset.downloadURL, to: dmg)
            let actualDigest = try Self.sha256(of: dmg)
            let expectedDigest = String(digest.dropFirst("sha256:".count))
            guard actualDigest == expectedDigest else {
                throw UpdateError.message("The downloaded update failed SHA-256 verification.")
            }

            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try Self.run("/usr/bin/hdiutil", [
                "attach", dmg.path,
                "-mountpoint", mountPoint.path,
                "-nobrowse",
                "-readonly",
            ])
            defer {
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
                try? fileManager.removeItem(at: work)
            }

            let sourceApp = mountPoint.appendingPathComponent("TetherShot.app", isDirectory: true)
            try Self.validate(app: sourceApp, expectedVersion: version)

            let stagedApp = destination.deletingLastPathComponent()
                .appendingPathComponent(".TetherShot.update-\(ProcessInfo.processInfo.processIdentifier).app", isDirectory: true)
            if fileManager.fileExists(atPath: stagedApp.path) {
                try fileManager.removeItem(at: stagedApp)
            }
            try Self.run("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
            try Self.validate(app: stagedApp, expectedVersion: version)
            return PendingUpdate(stagedApp: stagedApp, destination: destination)
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    private func download(_ source: URL, to destination: URL) async throws {
        var request = URLRequest(url: source)
        request.timeoutInterval = 120
        request.setValue("TetherShot-Updater", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("The update download failed.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func validate(app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
            throw UpdateError.message("The downloaded app has an unexpected identity or version.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])

        let details = try run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path], includeErrorOutput: true)
        guard details.contains("TeamIdentifier=\(teamIdentifier)"),
              details.contains("Authority=Developer ID Application: Apoorv Darshan (\(teamIdentifier))") else {
            throw UpdateError.message("The update was not signed by the expected developer.")
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(
        _ executable: String,
        _ arguments: [String],
        includeErrorOutput: Bool = false
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.message(message.isEmpty ? "\(executable) failed." : message)
        }
        return includeErrorOutput ? stdout + stderr : stdout
    }

    private static func version(from tag: String) -> String? {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard value.range(of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static let replacementScript = #"""
pid="$1"
staged="$2"
destination="$3"
backup="${destination}.previous-${pid}"

while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
moved_old=0
if /bin/mv "$destination" "$backup"; then
  moved_old=1
  if /bin/mv "$staged" "$destination"; then
    if /usr/bin/open -n "$destination"; then
      /bin/rm -rf "$backup"
      exit 0
    fi
  fi
fi

if [ "$moved_old" -eq 1 ] && [ -e "$backup" ]; then
  /bin/rm -rf "$destination"
  /bin/mv "$backup" "$destination"
  /usr/bin/open -n "$destination"
elif [ -e "$destination" ]; then
  /usr/bin/open -n "$destination"
fi
exit 1
"""#
}
