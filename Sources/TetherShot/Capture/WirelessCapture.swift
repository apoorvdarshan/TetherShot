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

    /// Surfaces only devices that are reachable WITHOUT a USB interface — i.e.
    /// pure Wi-Fi. USB-attached phones are handled by the faster AVFoundation
    /// backend, so this avoids showing the same phone twice.
    func discoverDevicesAsync() async -> [CaptureDevice] {
        guard let tunnels = await tunneldDevices() else { return [] }
        let names = await deviceNames()
        var devices: [CaptureDevice] = []
        for (udid, interfaces) in tunnels where !interfaces.isEmpty {
            // A USB tunnel interface ends in "-USB" (e.g. "usbmux-<udid>-USB").
            // Match the suffix, NOT a bare "usb" substring — otherwise the Wi-Fi
            // interface "usbmux-<udid>-Network" (which contains "usb" inside
            // "usbmux") would be wrongly treated as USB and hidden.
            let hasUSB = interfaces.contains { $0.uppercased().hasSuffix("-USB") }
            if hasUSB { continue }                       // USB → AVFoundation handles it
            let name = names[udid] ?? nameCache[udid] ?? "iPhone …\(udid.suffix(5))"
            devices.append(CaptureDevice(id: udid, name: name, connection: .wireless))
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

    private func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
