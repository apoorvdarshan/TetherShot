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

    private let usb = USBCapture()
    private let wireless = WirelessCapture()

    init() {
        refreshDevices()
    }

    /// Merges USB (AVFoundation, instant) and Wi-Fi (tunneld) device lists.
    func refreshDevices() {
        let usbDevices = usb.discoverDevices()      // synchronous, instant
        devices = usbDevices                         // show USB immediately
        Task {
            let ready = await wireless.isTunneldRunning()
            let wifiDevices = await wireless.discoverDevicesAsync()
            wirelessReady = ready
            devices = usbDevices + wifiDevices
            if devices.isEmpty {
                lastStatus = ready
                    ? "No iPhone found. Plug in over USB, or check Wi-Fi/same network."
                    : "Plug in an iPhone over USB and tap Trust."
            } else {
                lastStatus = ""
            }
        }
    }

    func capture(_ device: CaptureDevice) {
        Task { await performCapture(device) }
    }

    func captureAll() {
        Task {
            for device in devices { await performCapture(device) }
        }
    }

    private func performCapture(_ device: CaptureDevice) async {
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
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let url = destinationFolder.appendingPathComponent(Filename.make(deviceName: device.name))
        try png.write(to: url)
        lastStatus = "Saved \(url.lastPathComponent)"
        Log.shared.log("performCapture: saved \(url.path)")
        NSSound(named: "Glass")?.play()
    }

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
            if result.status == 0 {
                lastStatus = "Wireless ready. Capturing over Wi-Fi is now available."
            } else {
                lastStatus = "Wireless setup failed: \(result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown")"
            }
            refreshDevices()
        }
    }

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
