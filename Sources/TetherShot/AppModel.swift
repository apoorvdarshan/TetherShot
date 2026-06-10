import SwiftUI
import AppKit
import AVFoundation

/// Owns app state and orchestrates capture across backends. UI reads
/// `@Published` values; all mutation happens on the main actor so the menu
/// always renders a consistent view.
@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [CaptureDevice] = []
    @Published var destinationFolder: URL = FolderStore.load()
    @Published var lastStatus: String = ""
    @Published var wirelessReady = false
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var organizeByDevice = UserDefaults.standard.bool(forKey: "organizeByDevice")
    @Published var copyToClipboard = (UserDefaults.standard.object(forKey: "copyToClipboard") as? Bool) ?? true
    @Published var autoCheckForUpdates = (UserDefaults.standard.object(forKey: "autoCheckForUpdates") as? Bool) ?? true
    @Published var availableUpdate: String?

    let hotKeyDisplay = HotKey.defaultDisplay
    var appVersion: String { updater.currentVersion }

    private let usb = USBCapture()
    private let wireless = WirelessCapture()
    private let updater = Updater()
    private var hotKey: HotKey?
    private var isCapturing = false

    init() {
        Notifier.requestAuthorization()
        registerHotKey()
        refreshDevices()
        if autoCheckForUpdates {
            checkForUpdates(manual: false)
        }
    }

    // MARK: Devices

    /// Merges USB (AVFoundation, instant) and Wi-Fi (tunneld) device lists.
    func refreshDevices() {
        let usbDevices = usb.discoverDevices()
        devices = usbDevices                         // show USB immediately
        Task {
            wirelessReady = await wireless.isTunneldRunning()
            devices = await merged(with: usbDevices)
            if devices.isEmpty {
                lastStatus = wirelessReady
                    ? "No iPhone found. Plug in over USB, or check Wi-Fi/same network."
                    : "Plug in an iPhone over USB and tap Trust."
            } else {
                lastStatus = ""
            }
        }
    }

    private func merged(with usbDevices: [CaptureDevice]) async -> [CaptureDevice] {
        usbDevices + (await wireless.discoverDevicesAsync())
    }

    // MARK: Capture

    func capture(_ device: CaptureDevice) {
        Task { await performCapture(device) }
    }

    func captureAll() {
        Task {
            for device in devices { await performCapture(device) }
        }
    }

    /// Global-hotkey entry point: re-discovers, then captures every device found.
    func hotKeyCapture() {
        Task {
            let list = await merged(with: usb.discoverDevices())
            devices = list
            guard !list.isEmpty else {
                lastStatus = "Quick capture: no iPhone found"
                NSSound(named: "Funk")?.play()
                return
            }
            for device in list { await performCapture(device) }
        }
    }

    private func performCapture(_ device: CaptureDevice) async {
        isCapturing = true
        defer { isCapturing = false }
        lastStatus = "Capturing \(device.name)…"
        Log.shared.log("performCapture: '\(device.name)' [\(device.connection.rawValue)] -> \(destinationFolder.path)")
        do {
            let png: Data
            switch device.connection {
            case .usb:
                guard await ensureCameraAccess() else {
                    if lastStatus.hasPrefix("Capturing") {
                        lastStatus = "Camera permission needed — grant it, then retry."
                    }
                    return
                }
                png = try await usb.capture(deviceID: device.id)
            case .wireless:
                png = try await wireless.capture(deviceID: device.id)
            }
            try save(png: png, device: device)
        } catch {
            lastStatus = "Error: \(error.localizedDescription)"
            Log.shared.log("performCapture: error \(error.localizedDescription)")
        }
    }

    private func save(png: Data, device: CaptureDevice) throws {
        var folder = destinationFolder
        if organizeByDevice {
            folder = folder.appendingPathComponent(Filename.folderName(for: device.name), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Filename.make(deviceName: device.name))
        try png.write(to: url)
        if copyToClipboard {
            Pasteboard.copyPNG(png)
        }
        lastStatus = copyToClipboard
            ? "Saved \(url.lastPathComponent) · copied to clipboard"
            : "Saved \(url.lastPathComponent)"
        Log.shared.log("performCapture: saved \(url.path)\(copyToClipboard ? " + clipboard" : "")")
        NSSound(named: "Glass")?.play()
        Notifier.notify(title: "TetherShot", body: lastStatus)
    }

    // MARK: Permissions / settings

    /// Camera access is only needed for the AVFoundation (USB) path. Brings the
    /// prompt to the front for `.notDetermined`; routes `.denied` straight to
    /// the right Settings pane so the user isn't left guessing.
    private func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            lastStatus = "Camera blocked — enable TetherShot in Settings ▸ Privacy & Security ▸ Camera, then retry."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
            return false
        @unknown default:
            return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = LaunchAtLogin.set(enabled)
    }

    func setOrganizeByDevice(_ enabled: Bool) {
        organizeByDevice = enabled
        UserDefaults.standard.set(enabled, forKey: "organizeByDevice")
    }

    func setCopyToClipboard(_ enabled: Bool) {
        copyToClipboard = enabled
        UserDefaults.standard.set(enabled, forKey: "copyToClipboard")
    }

    func setAutoCheckForUpdates(_ enabled: Bool) {
        autoCheckForUpdates = enabled
        UserDefaults.standard.set(enabled, forKey: "autoCheckForUpdates")
    }

    /// `manual` checks announce "up to date"; automatic checks stay silent unless
    /// there's an update, to avoid nagging.
    func checkForUpdates(manual: Bool) {
        if manual { lastStatus = "Checking for updates…" }
        Task {
            guard let info = await updater.checkForUpdate() else {
                if manual { lastStatus = "Update check failed (offline?)." }
                return
            }
            if info.isNewer {
                availableUpdate = info.latest
                lastStatus = "Update available: \(info.latest)"
            } else {
                availableUpdate = nil
                if manual { lastStatus = "You're up to date (\(appVersion))." }
            }
        }
    }

    func installUpdate() {
        guard !isCapturing else {
            lastStatus = "Finish the current capture before updating."
            return
        }
        lastStatus = "Updating… (recompiling, ~1 min)"
        Task {
            let (ok, message) = await updater.installUpdate()
            if ok {
                lastStatus = "Updated — relaunching…"
                updater.relaunchAndQuit()
            } else {
                lastStatus = "Update failed: \(message)"
            }
        }
    }

    private func registerHotKey() {
        hotKey = HotKey(keyCode: HotKey.defaultKeyCode, modifiers: HotKey.defaultModifiers) { [weak self] in
            Task { @MainActor in self?.hotKeyCapture() }
        }
    }

    /// Runs the bundled installer for the wireless tunnel service. The script
    /// itself raises the admin-password prompt.
    func setupWireless() {
        guard let script = Bundle.main.url(forResource: "install-tunneld", withExtension: "sh") else {
            lastStatus = "Installer missing from app bundle."
            return
        }
        lastStatus = "Setting up wireless… (enter your password)"
        Task {
            let result = await Proc.run("/bin/bash", [script.path], timeout: 180)
            lastStatus = result.status == 0
                ? "Wireless ready. Capturing over Wi-Fi is now available."
                : "Wireless setup failed: \(result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown")"
            refreshDevices()
        }
    }

    // MARK: Folder

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder where TetherShot saves screenshots"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationFolder = url
        FolderStore.save(url)
        lastStatus = "Saving to \(url.lastPathComponent)"
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationFolder)
    }
}
