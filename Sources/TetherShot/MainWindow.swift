import AppKit
import SwiftUI

struct MainWindow: View {
    @ObservedObject var model: AppModel
    let appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model)
            ScrollView {
                VStack(spacing: 12) {
                    CaptureDashboardSection(model: model)
                    StorageDashboardSection(model: model)
                    ConnectionsDashboardSection(model: model)
                    BackgroundDashboardSection(model: model)
                    UpdatesDashboardSection(model: model)
                    ProjectDashboardSection()
                }
                .padding(18)
            }
            StatusFooter(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(TetherShotTheme.accent)
        .readWindow { appDelegate.attach(to: $0, model: model) }
    }
}

private struct DashboardHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("TetherShot")
                    .font(.system(size: 22, weight: .bold))
                Text("iPhone and Android screenshots from your Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(deviceStatus, systemImage: deviceStatusIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.devices.isEmpty ? Color.secondary : TetherShotTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var deviceStatus: String {
        if !model.devices.isEmpty { return "\(model.devices.count) ready" }
        if model.hiddenConnectedDeviceCount > 0 { return "\(model.hiddenConnectedDeviceCount) hidden" }
        return "No device"
    }

    private var deviceStatusIcon: String {
        if !model.devices.isEmpty { return "iphone.and.arrow.forward" }
        return model.hiddenConnectedDeviceCount > 0 ? "eye.slash" : "iphone.slash"
    }
}

private struct CaptureDashboardSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Panel(title: "Capture", detail: "USB and Wi-Fi devices") {
            VStack(spacing: 0) {
                if model.devices.isEmpty {
                    emptyDevices
                } else {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        DeviceControlRow(
                            device: device,
                            capture: { model.capture(device) },
                            hide: { model.hideDevice(device) }
                        )
                        if index < model.devices.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }

                Divider()

                SettingRow(
                    icon: "scope",
                    title: "Quick Capture Device",
                    detail: "Used by \(model.hotKeyDisplay); remembered across launches"
                ) {
                    QuickCaptureDevicePicker(model: model)
                        .labelsHidden()
                        .frame(width: 210)
                }

                if !model.hiddenDevices.isEmpty {
                    Divider().padding(.leading, 48)
                    SettingRow(
                        icon: "eye.slash",
                        title: "Hidden Devices",
                        detail: "Excluded from captures and the global hotkey"
                    ) {
                        HiddenDevicesMenu(model: model)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Refresh Devices", systemImage: "arrow.clockwise", action: model.refreshDevices)
                    if model.devices.count > 1 {
                        Button("Screenshot All", systemImage: "camera.fill", action: model.captureAll)
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .controlSize(.small)
                .padding(12)
            }
        }
    }

    private var emptyDevices: some View {
        HStack(spacing: 12) {
            Image(systemName: model.hiddenConnectedDeviceCount > 0 ? "eye.slash" : "iphone.slash")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.hiddenConnectedDeviceCount > 0 ? "Connected phones are hidden" : "No phone detected")
                    .fontWeight(.semibold)
                Text(model.hiddenConnectedDeviceCount > 0
                     ? "Restore a hidden phone below, or connect another device."
                     : "Connect an iPhone over USB/Wi-Fi or an authorized Android phone.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }
}

private struct StorageDashboardSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Panel(title: "Save & copy", detail: model.destinationFolder.path) {
            VStack(spacing: 0) {
                SettingRow(icon: "folder", title: "Destination", detail: model.destinationFolder.lastPathComponent) {
                    HStack(spacing: 8) {
                        Button("Open", action: model.openFolder)
                        Button("Choose…", action: model.chooseFolder)
                    }
                    .controlSize(.small)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "doc.on.clipboard", title: "Copy to Clipboard", detail: "Make every capture ready to paste") {
                    Toggle("Copy to Clipboard", isOn: Binding(
                        get: { model.copyToClipboard },
                        set: { model.setCopyToClipboard($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "folder.badge.gearshape", title: "Organize by Device", detail: "Create a folder for each phone") {
                    Toggle("Organize by Device", isOn: Binding(
                        get: { model.organizeByDevice },
                        set: { model.setOrganizeByDevice($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }
}

private struct ConnectionsDashboardSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Panel(title: "Connections", detail: "iPhone and Android") {
            VStack(spacing: 0) {
                SettingRow(
                    icon: "wifi",
                    title: "iPhone Wi-Fi",
                    detail: model.wirelessReady ? "Developer-services tunnel is ready" : "One-time wireless setup required"
                ) {
                    if model.wirelessReady {
                        ReadyLabel()
                    } else {
                        Button("Set Up…", action: model.setupWireless)
                            .controlSize(.small)
                    }
                }
                Divider().padding(.leading, 48)
                SettingRow(
                    icon: "apps.iphone",
                    title: "Android (ADB)",
                    detail: model.androidReady ? "Platform tools found; enable USB or wireless debugging" : "Install Android Platform Tools, then refresh"
                ) {
                    if model.androidReady {
                        ReadyLabel()
                    } else {
                        Button("Setup Guide…", action: model.openAndroidSetup)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct ReadyLabel: View {
    var body: some View {
        Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.green)
    }
}

private struct BackgroundDashboardSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Panel(title: "Background", detail: "Capture stays active when this window closes") {
            VStack(spacing: 0) {
                SettingRow(icon: "menubar.rectangle", title: "Show in Menu Bar", detail: "Quick capture and settings") {
                    Toggle("Show in Menu Bar", isOn: Binding(
                        get: { model.showInMenuBar },
                        set: { model.setShowInMenuBar($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "dock.rectangle", title: "Show in Dock", detail: "Keep TetherShot visible in the Dock") {
                    Toggle("Show in Dock", isOn: Binding(
                        get: { model.showInDock },
                        set: { model.setShowInDock($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "power", title: "Launch at Login", detail: "Keep TetherShot available after sign-in") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "command", title: "Quick Capture", detail: "Current target: \(model.quickCaptureTargetName)") {
                    Text(model.hotKeyDisplay)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

private struct UpdatesDashboardSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Panel(title: "Updates", detail: "Installed version \(model.appVersion)") {
            VStack(spacing: 0) {
                SettingRow(icon: "arrow.triangle.2.circlepath", title: "Automatically Check", detail: "Look for signed GitHub releases") {
                    Toggle("Automatically Check", isOn: Binding(
                        get: { model.autoCheckForUpdates },
                        set: { model.setAutoCheckForUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "arrow.down.app", title: "Install Automatically", detail: "Verify, replace, and relaunch when an update appears") {
                    Toggle("Install Automatically", isOn: Binding(
                        get: { model.autoInstallUpdates },
                        set: { model.setAutoInstallUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                HStack {
                    Text(model.availableUpdate.map { "Version \($0) is available" } ?? "TetherShot \(model.appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.availableUpdate != nil {
                        Button("Install & Relaunch", action: model.installUpdate)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Check Now") { model.checkForUpdates(manual: true) }
                    }
                }
                .controlSize(.small)
                .padding(12)
            }
        }
    }
}

private struct ProjectDashboardSection: View {
    var body: some View {
        Panel(title: "Project & support", detail: "Open source") {
            VStack(spacing: 0) {
                ProjectLinkRow(icon: "globe", title: "TetherShot website", detail: "Documentation, privacy, and terms", url: ProjectLinks.website)
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "Open-source repository", detail: "View the code on GitHub", url: ProjectLinks.repository)
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "shippingbox", title: "View on npm", detail: "Install the latest public release", url: ProjectLinks.npm)
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "ladybug", title: "Report a bug", detail: "Open a GitHub issue", url: ProjectLinks.issues)
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "doc.text", title: "MIT license", detail: "Read the open-source license", url: ProjectLinks.license)
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "heart", title: "Support on Ko-fi", detail: "Sponsor development", url: ProjectLinks.koFi)
            }
        }
    }
}

private struct DeviceControlRow: View {
    let device: CaptureDevice
    let capture: () -> Void
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.systemImageName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(TetherShotTheme.accent)
                .frame(width: 30, height: 30)
                .background(TetherShotTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).fontWeight(.semibold)
                Text(device.availableConnectionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Capture", systemImage: "camera.fill", action: capture)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Hide This Device", systemImage: "eye.slash", action: hide)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
    }
}

private struct HiddenDevicesMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu("Restore…") {
            ForEach(model.hiddenDevices) { device in
                Button("Restore \(device.name)") { model.restoreDevice(device.id) }
            }
            if model.hiddenDevices.count > 1 {
                Divider()
                Button("Restore All", action: model.restoreAllHiddenDevices)
            }
        }
        .accessibilityLabel("Restore hidden devices")
    }
}

private struct StatusFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(model.lastStatus.hasPrefix("Error") ? Color.red : Color.secondary)
            Text(model.lastStatus.isEmpty ? "Ready — close this window to keep TetherShot running in the background." : model.lastStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Text("TetherShot \(model.appVersion)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusIcon: String {
        if model.lastStatus.hasPrefix("Error") { return "exclamationmark.triangle.fill" }
        if model.lastStatus.hasPrefix("Saved") { return "checkmark.circle.fill" }
        return "circle.fill"
    }
}

private struct ProjectLinkRow: View {
    let icon: String
    let title: String
    let detail: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TetherShotTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    init(title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .bold))
                Spacer()
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}

private struct SettingRow<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    init(icon: String, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(TetherShotTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
