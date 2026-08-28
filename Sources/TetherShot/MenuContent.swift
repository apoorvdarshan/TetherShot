import SwiftUI

/// The menu shown when the user clicks the TetherShot status-bar icon.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    let showMainWindow: () -> Void

    var body: some View {
        Button("Show TetherShot") { showMainWindow() }

        Divider()

        if model.devices.isEmpty {
            Text("No phone detected")
        } else {
            ForEach(model.devices) { device in
                Button("📸  \(device.name) (\(device.connectionSummary))") {
                    model.capture(device)
                }
            }
            if model.devices.count > 1 {
                Button("📸  Screenshot All") { model.captureAll() }
            }
        }
        QuickCaptureDevicePicker(model: model)
        Text("Quick capture: \(model.hotKeyDisplay)")
        if !model.devices.isEmpty {
            Menu("Hide Device") {
                ForEach(model.devices) { device in
                    Button("Hide \(device.name)") { model.hideDevice(device) }
                }
            }
        }
        if !model.hiddenDevices.isEmpty {
            Menu("Hidden Devices") {
                ForEach(model.hiddenDevices) { device in
                    Button("Restore \(device.name)") { model.restoreDevice(device.id) }
                }
                if model.hiddenDevices.count > 1 {
                    Divider()
                    Button("Restore All") { model.restoreAllHiddenDevices() }
                }
            }
        }

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
        Toggle("Live Device Previews", isOn: Binding(
            get: { model.livePreviewsEnabled },
            set: { model.setLivePreviewsEnabled($0) }
        ))

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Toggle("Show in Menu Bar", isOn: Binding(
            get: { model.showInMenuBar },
            set: { model.setShowInMenuBar($0) }
        ))
        Toggle("Show in Dock", isOn: Binding(
            get: { model.showInDock },
            set: { model.setShowInDock($0) }
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

        Button("View Source on GitHub") { open(ProjectLinks.repository) }
        Button("Report an Issue…") { open(ProjectLinks.issues) }
        Button("MIT License") { open(ProjectLinks.license) }
        Button("Vote on Product Hunt") { open(ProjectLinks.productHunt) }
        Button("Support on Ko-fi") { open(ProjectLinks.koFi) }
        Button("Follow @apoorvdarshan on X") { open(ProjectLinks.x) }

        Divider()

        Text("TetherShot v\(model.appVersion)")
        Button("Quit TetherShot") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
