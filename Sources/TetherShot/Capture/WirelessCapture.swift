import Foundation

/// Captures an iPhone screenshot over Wi-Fi (or USB) via Apple's developer
/// services, by shelling out to `pymobiledevice3`.
///
/// The heavy lifting is done by a root `tunneld` LaunchDaemon (installed via
/// scripts/install-tunneld.sh) that keeps RemoteXPC tunnels alive and exposes
/// them on a local HTTP API. This backend just:
///   1. asks tunneld which devices are reachable (and over which transport), and
///   2. runs `developer dvt screenshot OUT --tunnel <UDID>` to grab a frame.
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

    private static let pythonPath: String? = {
        guard let pmd3Path,
              let handle = FileHandle(forReadingAtPath: pmd3Path),
              let line = String(data: handle.readData(ofLength: 256), encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first,
              line.hasPrefix("#!") else { return nil }
        let path = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    private var nameCache: [String: String] = [:]

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
    func discoverDevicesAsync() async -> [CaptureDevice] {
        guard let tunnels = await tunneldDevices() else { return [] }
        let names = await deviceNames()
        var devices: [CaptureDevice] = []
        for (udid, interfaces) in tunnels where !interfaces.isEmpty {
            let name = names[udid] ?? nameCache[udid] ?? "iPhone …\(udid.suffix(5))"
            devices.append(CaptureDevice(
                id: DeviceIdentity.iOS(rawID: udid),
                captureID: udid,
                name: name,
                connection: .wireless
            ))
        }
        return devices
    }

    /// UDID -> friendly name, via `pymobiledevice3 usbmux list` (covers USB and
    /// Wi-Fi-sync devices). Cached for the session.
    private func deviceNames() async -> [String: String] {
        guard let pmd3 = Self.pmd3Path else { return nameCache }
        let result = await Proc.run(pmd3, ["usbmux", "list"], timeout: 8)
        if let data = result.stdout.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in list {
                if let udid = entry["Identifier"] as? String,
                   let name = entry["DeviceName"] as? String {
                    nameCache[udid] = name
                }
            }
        }
        return nameCache
    }

    func capture(deviceID: String) async throws -> Data {
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

    func streamPreview(
        deviceID: String,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard let python = Self.pythonPath else {
            throw CaptureError.other("Python for pymobiledevice3 could not be found.")
        }
        guard let helper = Self.previewHelperPath else {
            throw CaptureError.other("Wireless live-preview helper is missing.")
        }
        let stream = LengthPrefixedImagePreviewStream(
            executablePath: python,
            arguments: [helper, deviceID]
        )
        try await stream.run(onFrame: onFrame)
    }

    private static var previewHelperPath: String? {
        if let bundled = Bundle.main.url(
            forResource: "wireless-preview",
            withExtension: "py"
        )?.path {
            return bundled
        }
        let sourcePath = FileManager.default.currentDirectoryPath
            + "/scripts/wireless-preview.py"
        return FileManager.default.fileExists(atPath: sourcePath) ? sourcePath : nil
    }

    private func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

private final class LengthPrefixedImagePreviewStream: @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    func run(onFrame: @escaping @Sendable (Data) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.runBlocking(onFrame: onFrame)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func runBlocking(onFrame: @escaping @Sendable (Data) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let shouldLaunch = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            self.process = process
            return true
        }
        guard shouldLaunch else { return }
        defer { lock.withLock { self.process = nil } }

        do {
            try process.run()
        } catch {
            throw CaptureError.other("Could not start Wi-Fi live preview: \(error.localizedDescription)")
        }
        if isCancelled, process.isRunning { process.terminate() }
        Log.shared.log("wireless: persistent DVT preview started")

        var errorData = Data()
        let errorDrain = DispatchGroup()
        errorDrain.enter()
        DispatchQueue.global().async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorDrain.leave()
        }

        let handle = outputPipe.fileHandleForReading
        while !isCancelled {
            guard let header = try handle.readExactly(4) else { break }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= 32 * 1_024 * 1_024,
                  let imageData = try handle.readExactly(Int(length)) else { break }
            onFrame(imageData)
        }

        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        _ = errorDrain.wait(timeout: .now() + 2)
        guard isCancelled else {
            let message = String(data: errorData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).last.map(String.init)
            throw CaptureError.other(message ?? "Wi-Fi live preview stopped.")
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let chunk = try read(upToCount: count - result.count), !chunk.isEmpty else {
                return nil
            }
            result.append(chunk)
        }
        return result
    }
}
