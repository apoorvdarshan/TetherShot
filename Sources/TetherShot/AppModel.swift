import SwiftUI
import AppKit

/// Owns app state and orchestrates capture. UI reads `@Published` values; all
/// mutation happens on the main actor so the menu always renders a consistent view.
@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [CaptureDevice] = []
    @Published var destinationFolder: URL = FolderStore.load()
    @Published var lastStatus: String = ""

    private let usb = USBCapture()

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        devices = usb.discoverDevices()
        lastStatus = devices.isEmpty ? "Plug in an iPhone over USB and tap Trust." : ""
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
        do {
            let png = try await usb.capture(deviceID: device.id)
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let url = destinationFolder.appendingPathComponent(Filename.make(deviceName: device.name))
            try png.write(to: url)
            lastStatus = "Saved \(url.lastPathComponent)"
            NSSound(named: "Glass")?.play()
        } catch {
            lastStatus = "Error: \(error.localizedDescription)"
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
