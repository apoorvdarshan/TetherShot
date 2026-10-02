import SwiftUI

/// The persistent panel shown when the user clicks the TetherShot status-bar icon.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    let showMainWindow: () -> Void
    @State private var preferencesExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    devicesSection
                    Divider()
                    captureSection
                    Divider()
                    preferencesSection
                    if !model.lastStatus.isEmpty {
                        Label(model.lastStatus, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 480)
        .font(.system(size: 13))
        .buttonStyle(.borderless)
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(TetherShotTheme.accent)
            Text("TetherShot").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: showMainWindow) {
                Label("Open App", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .help("Show TetherShot")
            .accessibilityLabel("Show TetherShot")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Devices")
                Spacer()
                Button(action: model.refreshDevices) {
                    HStack(spacing: 5) {
                        if model.isRefreshingDevices {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise").frame(width: 12, height: 12)
                        }
                        Text(model.isRefreshingDevices ? "Refreshing…" : "Refresh")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .disabled(model.isRefreshingDevices)
                .help("Refresh Devices")
                .accessibilityLabel("Refresh Devices")
            }
            if model.devices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isRefreshingDevices ? "Looking for your phone…" : "No phone detected")
                            .fontWeight(.medium)
                        Text("Connect over USB or Wi-Fi.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.platformName == "iPhone" ? "iphone" : "smartphone")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Label(device.availableConnectionSummary, systemImage: device.systemImageName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button { model.capture(device) } label: {
                                Label("Capture", systemImage: "camera")
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Capture a screenshot from \(device.name)")
                            .accessibilityLabel("Capture \(device.name)")
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if model.devices.count > 1 {
                    Button(action: model.captureAll) {
                        Label("Screenshot All", systemImage: "square.stack")
                    }
                }
            }
            HStack {
                Text("Quick capture").foregroundStyle(.secondary)
                Spacer()
                Text(model.hotKeyDisplay)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Target").foregroundStyle(.secondary)
                Spacer()
                QuickCaptureDevicePicker(model: model)
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .labelsHidden()
                    .lineLimit(1)
                    .frame(maxWidth: 230, alignment: .trailing)
            }
            HStack {
                Label(model.wirelessReady ? "Wi-Fi ready" : "Wi-Fi not configured", systemImage: "wifi")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.wirelessReady {
                    Button("Set Up…", action: model.setupWireless).font(.caption)
                }
                deviceManagementMenu
            }
        }
    }

    private var deviceManagementMenu: some View {
        Menu {
            if !model.devices.isEmpty {
                Menu("Hide Device") {
                    ForEach(model.devices) { device in
                        Button(device.name) { model.hideDevice(device) }
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
                        Button("Restore All", action: model.restoreAllHiddenDevices)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .tint(.primary)
        .foregroundStyle(.secondary)
        .fixedSize()
        .disabled(model.devices.isEmpty && model.hiddenDevices.isEmpty)
        .help("Manage visible and hidden devices")
        .accessibilityLabel("Manage Devices")
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Capture & Save")
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.destinationFolder.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    Text("Save location").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change…", action: model.chooseFolder)
                    .buttonStyle(.bordered)
                    .tint(.primary)
                Button(action: model.openFolder) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open Folder")
                .accessibilityLabel("Open Folder")
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .help(model.destinationFolder.path)
            preference("Organize by Device", value: model.organizeByDevice, set: model.setOrganizeByDevice)
            preference("Copy to Clipboard", value: model.copyToClipboard, set: model.setCopyToClipboard)
            preference("Paste After Capture", value: model.pasteAfterCapture, set: model.setPasteAfterCapture)
                .disabled(!model.copyToClipboard)
        }
    }

    private var preferencesSection: some View {
        DisclosureGroup(isExpanded: $preferencesExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                preference("Launch at Login", value: model.launchAtLogin, set: model.setLaunchAtLogin)
                preference("Show in Menu Bar", value: model.showInMenuBar, set: model.setShowInMenuBar)
                preference("Show in Dock", value: model.showInDock, set: model.setShowInDock)
                Divider()
                if let update = model.availableUpdate {
                    Button("Update to \(update) & Relaunch", action: model.installUpdate)
                } else {
                    Button("Check for Updates…") { model.checkForUpdates(manual: true) }
                }
                preference("Auto-check for Updates", value: model.autoCheckForUpdates, set: model.setAutoCheckForUpdates)
                preference("Auto-update & Relaunch", value: model.autoInstallUpdates, set: model.setAutoInstallUpdates)
            }
            .padding(.top, 10)
        } label: {
            Label("Preferences", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var footer: some View {
        HStack {
            Text("v\(model.appVersion)").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Menu("Help") {
                Button("View Source on GitHub") { open(ProjectLinks.repository) }
                Button("Report an Issue…") { open(ProjectLinks.issues) }
                Button("MIT License") { open(ProjectLinks.license) }
                Divider()
                Button("Upvote on Product Hunt") { open(ProjectLinks.productHunt) }
                Button("Support on Ko-fi") { open(ProjectLinks.koFi) }
                Button("Follow @apoorvdarshan on X") { open(ProjectLinks.x) }
            }
            .menuStyle(.borderlessButton)
            .tint(.primary)
            .foregroundStyle(.secondary)
            .fixedSize()
            Divider().frame(height: 12).padding(.horizontal, 4)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func preference(_ title: String, value: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: Binding(get: { value }, set: set))
                .labelsHidden()
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
