import AppKit
import SwiftUI

struct MainWindow: View {
    @ObservedObject var model: AppModel
    let appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    captureSection
                    storageSection
                    backgroundSection
                    updatesSection
                    projectSection
                }
                .padding(18)
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(TetherShotTheme.accent)
        .readWindow { appDelegate.attach(to: $0) }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("TetherShot")
                    .font(.system(size: 22, weight: .bold))
                Text("iPhone screenshots from your Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.devices.isEmpty ? "No device" : "\(model.devices.count) ready", systemImage: model.devices.isEmpty ? "iphone.slash" : "iphone.gen3")
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

    private var captureSection: some View {
        Panel(title: "Capture", detail: "USB and Wi-Fi devices") {
            VStack(spacing: 0) {
                if model.devices.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No iPhone detected").fontWeight(.semibold)
                            Text("Connect a trusted iPhone over USB, or configure Wi-Fi capture.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                } else {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        DeviceRow(device: device) { model.capture(device) }
                        if index < model.devices.count - 1 { Divider().padding(.leading, 54) }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Refresh Devices", systemImage: "arrow.clockwise") { model.refreshDevices() }
                    if model.devices.count > 1 {
                        Button("Screenshot All", systemImage: "camera.fill") { model.captureAll() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    if model.wirelessReady {
                        Label("Wi-Fi ready", systemImage: "wifi")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Set Up Wi-Fi…") { model.setupWireless() }
                    }
                }
                .controlSize(.small)
                .padding(12)
            }
        }
    }

    private var storageSection: some View {
        Panel(title: "Save & copy", detail: model.destinationFolder.path) {
            VStack(spacing: 0) {
                SettingRow(icon: "folder", title: "Destination", detail: model.destinationFolder.lastPathComponent) {
                    HStack(spacing: 8) {
                        Button("Open") { model.openFolder() }
                        Button("Choose…") { model.chooseFolder() }
                    }
                    .controlSize(.small)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "doc.on.clipboard", title: "Copy to Clipboard", detail: "Make every capture ready to paste") {
                    Toggle("", isOn: Binding(get: { model.copyToClipboard }, set: { model.setCopyToClipboard($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "folder.badge.gearshape", title: "Organize by Device", detail: "Create a folder for each iPhone") {
                    Toggle("", isOn: Binding(get: { model.organizeByDevice }, set: { model.setOrganizeByDevice($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var backgroundSection: some View {
        Panel(title: "Background", detail: "Capture stays active when this window closes") {
            VStack(spacing: 0) {
                SettingRow(icon: "menubar.rectangle", title: "Show in Menu Bar", detail: "Quick capture and settings; on by default") {
                    Toggle("", isOn: Binding(get: { model.showInMenuBar }, set: { model.setShowInMenuBar($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "power", title: "Launch at Login", detail: "Keep TetherShot available after sign-in") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "command", title: "Quick Capture", detail: "Capture every connected device from anywhere") {
                    Text(model.hotKeyDisplay)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var updatesSection: some View {
        Panel(title: "Updates", detail: "Installed version \(model.appVersion)") {
            VStack(spacing: 0) {
                SettingRow(icon: "arrow.triangle.2.circlepath", title: "Automatically Check", detail: "Look for signed GitHub releases") {
                    Toggle("", isOn: Binding(get: { model.autoCheckForUpdates }, set: { model.setAutoCheckForUpdates($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                SettingRow(icon: "arrow.down.app", title: "Install Automatically", detail: "Verify, replace, and relaunch when an update appears") {
                    Toggle("", isOn: Binding(get: { model.autoInstallUpdates }, set: { model.setAutoInstallUpdates($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 48)
                HStack {
                    Text(model.availableUpdate.map { "Version \($0) is available" } ?? "TetherShot \(model.appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.availableUpdate != nil {
                        Button("Install & Relaunch") { model.installUpdate() }
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

    private var projectSection: some View {
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
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "person.crop.circle.badge.plus", title: "Follow @apoorvdarshan on X", detail: "Developer updates", url: ProjectLinks.x)
                Divider().padding(.leading, 48)
                ProjectLinkRow(icon: "megaphone", title: "View on Product Hunt", detail: "Follow the launch and leave feedback", url: ProjectLinks.productHunt)
            }
        }
    }

    private var footer: some View {
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

private struct DeviceRow: View {
    let device: CaptureDevice
    let capture: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.connection == .usb ? "cable.connector" : "wifi")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(TetherShotTheme.accent)
                .frame(width: 30, height: 30)
                .background(TetherShotTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).fontWeight(.semibold)
                Text(device.connection.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Capture", systemImage: "camera.fill", action: capture)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let detail: String
    let content: Content

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
    let accessory: Accessory

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
                    .lineLimit(1)
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
