import Foundation
import AppKit

struct UpdateInfo {
    let latest: String
    let isNewer: Bool
}

/// In-app updater driven by npm. Checks the npm registry for a newer published
/// version, and (on request) runs `npm install -g tethershot@latest` — which
/// re-runs the package's postinstall to rebuild and reinstall the .app — then
/// relaunches via a detached helper.
final class Updater {
    static let packageName = "tethershot"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: Version check (no npm/PATH needed — hits the registry directly)

    func checkForUpdate() async -> UpdateInfo? {
        guard let latest = await latestVersion() else { return nil }
        return UpdateInfo(latest: latest, isNewer: Self.isNewer(latest, than: currentVersion))
    }

    private func latestVersion() async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/\(Self.packageName)/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            return nil
        }
        return version
    }

    /// Numeric, component-wise semver comparison (pads missing parts with 0, so
    /// "1.1" vs "1.1.0" compare equal — unlike String.compare(.numeric)).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Apply update

    /// Runs `npm install -g tethershot@latest`. Returns (success, message).
    func installUpdate() async -> (Bool, String) {
        guard let npm = Self.resolveNpm() else {
            return (false, "npm not found. Update manually:  npm i -g tethershot@latest")
        }
        // Long timeout: the postinstall recompiles the whole app.
        let install = await Proc.run(npm, ["install", "-g", "\(Self.packageName)@latest"], timeout: 600)
        guard install.status == 0 else {
            let line = install.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
            return (false, line ?? "npm install failed.")
        }
        // npm 11 defers postinstall by default (allow-scripts), so the .app may
        // not have been rebuilt. Run the build explicitly via the freshly linked
        // CLI — a user-invoked command, so it isn't gated by allow-scripts.
        let cli = (npm as NSString).deletingLastPathComponent + "/\(Self.packageName)"
        if FileManager.default.isExecutableFile(atPath: cli) {
            let rebuild = await Proc.run(cli, ["install"], timeout: 600)
            guard rebuild.status == 0 else {
                let line = rebuild.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
                return (false, line ?? "Rebuild after update failed.")
            }
        }
        return (true, "Updated.")
    }

    /// Relaunches a fresh instance once this process exits, then quits. The
    /// helper has no dependency on the (just-replaced) app bundle.
    func relaunchAndQuit() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installed = home.appendingPathComponent("Applications/TetherShot.app")
        let target = FileManager.default.fileExists(atPath: installed.path) ? installed : Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; /usr/bin/open -n \"\(target.path)\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()

        NSApp.terminate(nil)
    }

    /// npm absolute path — a Finder-launched app has a bare PATH, so probe known
    /// locations and fall back to a login shell.
    static func resolveNpm() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "\(home)/.volta/bin/npm",
            "\(home)/.npm-global/bin/npm",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "command -v npm"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) { return out }
        return nil
    }
}
