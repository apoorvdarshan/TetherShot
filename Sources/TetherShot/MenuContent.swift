import SwiftUI

/// The menu shown when the user clicks the TetherShot status-bar icon.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.devices.isEmpty {
            Text("No iPhone detected")
        } else {
            ForEach(model.devices) { device in
                Button("📸  \(device.name) (\(device.connection.rawValue))") {
                    model.capture(device)
                }
            }
            if model.devices.count > 1 {
                Button("📸  Screenshot All") { model.captureAll() }
            }
        }
        Text("Quick capture anywhere: \(model.hotKeyDisplay)")

        Divider()

        Button("Refresh Devices") { model.refreshDevices() }
        if model.wirelessReady {
            Text("Wi-Fi capture: ready")
        } else {
            Button("Set Up Wi-Fi Capture…") { model.setupWireless() }
        }

        Divider()

        Text("Saving to: \(model.destinationFolder.lastPathComponent)")
        Button("Choose Folder…") { model.chooseFolder() }
        Button("Open Folder") { model.openFolder() }
        Toggle("Organize by Device", isOn: Binding(
            get: { model.organizeByDevice },
            set: { model.setOrganizeByDevice($0) }
        ))
        Toggle("Copy to Clipboard", isOn: Binding(
            get: { model.copyToClipboard },
            set: { model.setCopyToClipboard($0) }
        ))

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        if let update = model.availableUpdate {
            Button("⬆︎  Update to \(update) — Relaunch") { model.installUpdate() }
        } else {
            Button("Check for Updates…") { model.checkForUpdates(manual: true) }
        }
        Toggle("Auto-check for Updates", isOn: Binding(
            get: { model.autoCheckForUpdates },
            set: { model.setAutoCheckForUpdates($0) }
        ))
        Toggle("Auto-update (install & relaunch)", isOn: Binding(
            get: { model.autoInstallUpdates },
            set: { model.setAutoInstallUpdates($0) }
        ))

        if !model.lastStatus.isEmpty {
            Divider()
            Text(model.lastStatus)
        }

        Divider()

        Button("View Source on GitHub") { open("https://github.com/apoorvdarshan/TetherShot") }
        Button("Report an Issue…") { open("https://github.com/apoorvdarshan/TetherShot/issues/new") }
        Button("Vote on Product Hunt") { open("https://www.producthunt.com/products/tethershot") }
        Button("Support on Ko-fi") { open("https://ko-fi.com/apoorvdarshan") }
        Button("Follow @apoorvdarshan on X") { open("https://x.com/apoorvdarshan") }

        Divider()

        Text("TetherShot v\(model.appVersion)")
        Button("Quit TetherShot") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
