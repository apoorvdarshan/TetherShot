import Foundation

/// Captures an iPhone screenshot over Wi-Fi (or USB) via Apple's developer
/// services, by shelling out to `pymobiledevice3`.
///
/// The heavy lifting is done by a root `tunneld` LaunchDaemon (installed via
/// scripts/install-tunneld.sh) that keeps RemoteXPC tunnels alive and exposes
/// them on a local HTTP API. This backend just:
///   1. asks tunneld which devices are reachable (and over which transport), and
///   2. asks the long-lived scripts/wireless-screenshot.py helper for a frame,
///      falling back to `developer dvt screenshot OUT --tunnel <UDID>`.
///
/// Because tunneld holds the tunnel, the capture command runs as a normal user
/// with no sudo — and works whether the phone is on USB or pure Wi-Fi.
final class WirelessCapture: CaptureBackend {

    /// tunneld's default local HTTP API.
    private static let tunneldURL = URL(string: "http://127.0.0.1:49151/")!

    /// Resolved once: absolute path to pymobiledevice3 (the app's PATH from
    /// Finder doesn't include Homebrew).
    static let pmd3Path: String? = {
        let candidates = [
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
            "\(NSHomeDirectory())/.local/bin/pymobiledevice3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The interpreter pymobiledevice3 was installed into. Console scripts
    /// usually point straight at the venv python, but some (including pipx and
    /// `usr/bin/env`) use an indirection, and pip writes a `#!/bin/sh` wrapper
    /// when the python path has spaces or is too long for a shebang, so resolve
    /// those too. Returns nil when no usable interpreter is found; the caller
    /// then logs why and falls back to the one-shot CLI.
    private static let pythonPath: String? = {
        guard let pmd3Path,
              let handle = FileHandle(forReadingAtPath: pmd3Path),
              // A PATH-based shebang line can be long; read generously.
              let text = String(data: handle.readData(ofLength: 1024), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("#!") else { return nil }
        let parts = line.dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let command = parts.first, !command.isEmpty else { return nil }
        let base = (command as NSString).lastPathComponent
        // pip's wrapper is a /bin/sh script that execs the real interpreter on
        // its second line; parse that out instead of running sh with the Python
        // helper as its script (which would exit without replying).
        if base == "sh" || base == "bash" {
            if let interpreter = wrapperInterpreter(in: text) { return interpreter }
        }
        let resolved = FileManager.default.isExecutableFile(atPath: command)
            ? command
            : lookupInPATH(command)
        guard let resolved, FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        return resolved
    }()

    /// Extracts the interpreter from pip's `#!/bin/sh` console-script wrapper,
    /// e.g. `'''exec' "/opt/my venv/bin/python" "$0" "$@"`. Returns nil when the
    /// file doesn't look like that wrapper. Visible to tests.
    static func wrapperInterpreter(in text: String) -> String? {
        guard let execLine = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.contains("exec") && $0.contains("python") }) else { return nil }
        // The interpreter is the first quoted token after `exec`, which is how pip
        // protects a path containing spaces. Only trust it if it looks like a
        // python path — the later `"$0"`/`"$@"` quotes must not be mistaken for it.
        if let openQuote = execLine.firstIndex(of: "\""),
           let closeQuote = execLine[execLine.index(after: openQuote)...].firstIndex(of: "\"") {
            let path = String(execLine[execLine.index(after: openQuote)..<closeQuote])
            if isPythonPath(path), FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fall back to an unquoted python-looking token.
        for raw in execLine.split(whereSeparator: { " \t'".contains($0) }) {
            let candidate = String(raw)
            if isPythonPath(candidate), FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Heuristic for a token that names a Python interpreter, not an argument
    /// like `$0` or a shell name.
    private static func isPythonPath(_ candidate: String) -> Bool {
        candidate.contains("python")
    }

    /// Resolves a bare interpreter name against PATH, since Finder-launched
    /// apps inherit a minimal environment.
    private static func lookupInPATH(_ name: String) -> String? {
        let dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(NSHomeDirectory())/.local/bin",
        ]
        return dirs.lazy.map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var screenshotHelperPath: String? {
        if let bundled = Bundle.main.url(forResource: "wireless-screenshot", withExtension: "py")?.path {
            return bundled
        }
        let sourcePath = FileManager.default.currentDirectoryPath + "/scripts/wireless-screenshot.py"
        return FileManager.default.fileExists(atPath: sourcePath) ? sourcePath : nil
    }

    /// nil when the helper or its interpreter is missing; captures then use
    /// the one-shot CLI only.
    private let session: WirelessScreenshotSession? = {
        guard let python = WirelessCapture.pythonPath else {
            Log.shared.log("wireless helper: no python interpreter found; using CLI capture")
            return nil
        }
        guard let helper = WirelessCapture.screenshotHelperPath else {
            Log.shared.log("wireless helper: script not found; using CLI capture")
            return nil
        }
        return WirelessScreenshotSession(pythonPath: python, helperPath: helper)
    }()

    private let nameCacheLock = NSLock()
    private var nameCache: [String: String] = [:]
    private let nameRefreshLock = NSLock()
    private var lastNameRefresh = Date.distantPast

    /// True when the tunneld daemon answers — i.e. wireless setup is in place.
    func isTunneldRunning() async -> Bool {
        await tunneldDevices() != nil
    }

    /// Raw tunneld view: UDID -> list of tunnel interface names. nil if tunneld
    /// isn't reachable at all.
    private func tunneldDevices() async -> [String: [String]]? {
        var request = URLRequest(url: Self.tunneldURL)
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: [String]] = [:]
        for (udid, value) in json {
            let tunnels = value as? [[String: Any]] ?? []
            result[udid] = tunnels.compactMap { $0["interface"] as? String }
        }
        return result
    }

    func discoverDevices() -> [CaptureDevice] {
        // Synchronous shim isn't used; AppModel calls discoverDevicesAsync().
        []
    }

    /// Surfaces every tunneled iPhone. AppModel merges matching hardware IDs,
    /// advertises both transports, and prefers native USB capture when present.
    ///
    /// With `refreshNames` false (the hotkey path), cached names are reused and
    /// `usbmux list`, a separate Python process, only runs for unknown UDIDs.
    /// Known UDIDs are still refreshed in the background so a phone renamed
    /// while the app runs doesn't keep showing its old name.
    func discoverDevicesAsync(refreshNames: Bool = true) async -> [CaptureDevice] {
        guard let tunnels = await tunneldDevices() else { return [] }
        let tunneledDeviceIDs = tunnels.filter { !$0.value.isEmpty }.map(\.key)
        let cached = cachedNames()
        let needsLookup = refreshNames || tunnels.keys.contains { cached[$0] == nil }
        let names: [String: String]
        if needsLookup {
            names = await deviceNames(tunneledDeviceIDs: tunneledDeviceIDs)
        } else {
            names = cached
            scheduleNameRefresh(tunneledDeviceIDs: tunneledDeviceIDs)
        }
        var devices: [CaptureDevice] = []
        for (udid, interfaces) in tunnels where !interfaces.isEmpty {
            let name = names[udid] ?? "iPhone …\(udid.suffix(5))"
            devices.append(CaptureDevice(
                id: DeviceIdentity.iOS(rawID: udid),
                captureID: udid,
                name: name,
                connection: .wireless
            ))
        }
        return devices
    }

    /// Re-resolves device names off the capture path, at most once every few
    /// seconds, so a rename shows up without slowing the hotkey down.
    private func scheduleNameRefresh(tunneledDeviceIDs: [String]) {
        let now = Date()
        let shouldStart = nameRefreshLock.withLock {
            guard now.timeIntervalSince(lastNameRefresh) > 5 else { return false }
            lastNameRefresh = now
            return true
        }
        guard shouldStart else { return }
        Task.detached(priority: .utility) { [weak self] in
            _ = await self?.deviceNames(tunneledDeviceIDs: tunneledDeviceIDs)
        }
    }

    /// Resolve USB/Wi-Fi-sync names first, then query active tunnels for phones
    /// absent from usbmux (including pure Wi-Fi devices). Cache successful names
    /// so a transient failure cannot replace them with an identifier.
    private func deviceNames(tunneledDeviceIDs: [String]) async -> [String: String] {
        guard let pmd3 = Self.pmd3Path else { return cachedNames() }
        let discoveredNames = await WirelessDeviceNameLookup.resolve(
            pmd3Path: pmd3, tunneledDeviceIDs: tunneledDeviceIDs
        )
        return nameCacheLock.withLock {
            nameCache.merge(discoveredNames) { _, latest in latest }
            return nameCache
        }
    }

    private func cachedNames() -> [String: String] {
        nameCacheLock.withLock { nameCache }
    }

    /// Opens the helper's connection so the next capture skips setup.
    ///
    /// The session drops duplicates itself, so a repeated discovery pass is
    /// cheap. AppModel still only calls this for phones that just appeared, so
    /// it can't add latency ahead of a hotkey capture.
    func prewarm(deviceID: String) {
        session?.warm(deviceID: deviceID)
    }

    /// Clears warm state for devices that are no longer visible so a returning
    /// phone warms again. Nothing is sent on the capture pipe.
    func forget(deviceIDs gone: Set<String>) {
        for id in gone {
            session?.forget(deviceID: id)
        }
    }

    func capture(deviceID: String) async throws -> Data {
        if let session {
            do {
                let png = try await session.capture(deviceID: deviceID)
                Log.shared.log("wireless: helper screenshot \(deviceID)")
                return png
            } catch {
                Log.shared.log("wireless: helper failed (\(error.localizedDescription)), using CLI")
            }
        }
        return try await captureWithCLI(deviceID: deviceID)
    }

    private func captureWithCLI(deviceID: String) async throws -> Data {
        guard let pmd3 = Self.pmd3Path else {
            throw CaptureError.other("pymobiledevice3 not found — run scripts/install-tunneld.sh.")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tethershot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        Log.shared.log("wireless: dvt screenshot --tunnel \(deviceID)")
        let result = await Proc.run(
            pmd3,
            ["developer", "dvt", "screenshot", out.path, "--tunnel", deviceID],
            timeout: 40
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            Log.shared.log("wireless: failed status=\(result.status) err=\(result.stderr.prefix(200))")
            if result.stderr.contains("tunnel") || result.stderr.contains("RemoteServiceDiscovery") {
                throw CaptureError.other("No tunnel to this device. Is it on the same Wi-Fi and is tunneld running?")
            }
            throw CaptureError.other(firstLine(result.stderr) ?? "Wireless capture failed.")
        }
        return try Data(contentsOf: out)
    }

    private func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
