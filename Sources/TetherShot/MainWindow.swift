import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case livePreview = "Live Preview"
    case capture = "Capture & Save"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .livePreview: return "play.rectangle.on.rectangle"
        case .capture: return "camera"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var model: AppModel
    let appDelegate: AppDelegate
    @State private var selection: AppSection = .livePreview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 230)
        } detail: {
            VStack(spacing: 0) {
                detailContent
                StatusFooter(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(TetherShotTheme.accent)
        .readWindow { appDelegate.attach(to: $0, model: model) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TetherShot")
                        .font(.system(size: 16, weight: .bold))
                    Text("iPhone + Android")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)

            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
                    .accessibilityLabel(section.rawValue)
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 7) {
                Label(deviceStatus, systemImage: deviceStatusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.devices.isEmpty ? Color.secondary : TetherShotTheme.accent)
                Text("TetherShot \(model.appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .livePreview:
            LivePreviewPage(model: model)
        case .capture:
            CaptureSettingsPage(model: model)
        case .settings:
            PreferencesPage(model: model)
        case .about:
            AboutPage(model: model)
        }
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

private struct LivePreviewPage: View {
    @ObservedObject var model: AppModel
    @State private var selectedDeviceID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Live Preview",
                detail: "See the selected phone at full size and capture its latest frame"
            ) {
                Toggle("Live", isOn: Binding(
                    get: { model.livePreviewsEnabled },
                    set: { model.setLivePreviewsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .help("Enable or pause live device previews")
            }

            if model.devices.isEmpty {
                emptyState
            } else {
                deviceSelector

                if let device = selectedDevice,
                   let preview = model.previewStates[device.id] {
                    FullDevicePreview(
                        device: device,
                        preview: preview,
                        previewsEnabled: model.livePreviewsEnabled
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    previewActions(for: device)
                }
            }
        }
        .padding(18)
        .onAppear(perform: synchronizeSelection)
        .onChange(of: model.devices.map(\.id)) { _, _ in synchronizeSelection() }
    }

    private var selectedDevice: CaptureDevice? {
        model.devices.first(where: { $0.id == selectedDeviceID }) ?? model.devices.first
    }

    private var deviceSelector: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.devices) { device in
                    Button {
                        selectedDeviceID = device.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: device.systemImageName)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(device.connectionSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            selectedDevice?.id == device.id
                                ? TetherShotTheme.accent.opacity(0.18)
                                : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(
                                    selectedDevice?.id == device.id
                                        ? TetherShotTheme.accent.opacity(0.7)
                                        : Color(nsColor: .separatorColor).opacity(0.45),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(device.name), \(device.connectionSummary)")
                    .accessibilityAddTraits(selectedDevice?.id == device.id ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func previewActions(for device: CaptureDevice) -> some View {
        HStack(spacing: 9) {
            Button("Capture \(device.name)", systemImage: "camera.fill") {
                model.capture(device)
            }
            .buttonStyle(.borderedProminent)

            if model.devices.count > 1 {
                Button("Screenshot All", systemImage: "rectangle.stack.badge.plus") {
                    model.captureAll()
                }
            }

            Button("Refresh Devices", systemImage: "arrow.clockwise") {
                model.refreshDevices()
            }

            Spacer()

            Menu("Device", systemImage: "ellipsis.circle") {
                Button("Hide \(device.name)", systemImage: "eye.slash") {
                    model.hideDevice(device)
                    synchronizeSelection()
                }
            }
        }
        .controlSize(.regular)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                model.hiddenConnectedDeviceCount > 0 ? "Connected Phones Are Hidden" : "No Phone Detected",
                systemImage: model.hiddenConnectedDeviceCount > 0 ? "eye.slash" : "iphone.slash"
            )
        } description: {
            Text(model.hiddenConnectedDeviceCount > 0
                 ? "Restore a hidden phone, or connect another iPhone or Android device."
                 : "Connect an iPhone over USB/Wi-Fi or an Android phone with USB debugging enabled.")
        } actions: {
            if !model.hiddenDevices.isEmpty {
                HiddenDevicesMenu(model: model)
            }
            Button("Refresh Devices", action: model.refreshDevices)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func synchronizeSelection() {
        if !model.devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = model.devices.first?.id ?? ""
        }
    }
}

private struct FullDevicePreview: View {
    let device: CaptureDevice
    @ObservedObject var preview: DevicePreviewState
    let previewsEnabled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.94))

            if let image = preview.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            } else {
                VStack(spacing: 12) {
                    if previewsEnabled, preview.phase == .loading {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: previewsEnabled ? device.systemImageName : "pause.fill")
                            .font(.system(size: 42, weight: .medium))
                    }
                    Text(previewStatus)
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.72))
            }

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .bold))
                        Text(device.connectionSummary)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 9))

                    Spacer()

                    if previewsEnabled, preview.phase == .live {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.9), in: Capsule())
                    }
                }
                Spacer()
            }
            .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live preview of \(device.name)")
        .accessibilityValue(previewStatus)
    }

    private var previewStatus: String {
        guard previewsEnabled else { return "Preview paused" }
        switch preview.phase {
        case .idle: return "Waiting for preview"
        case .loading: return "Loading live preview"
        case .live: return "Live"
        case .paused: return "Preview paused"
        case .failed(let message): return message
        }
    }
}

private struct CaptureSettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                PageHeader(title: "Capture & Save", detail: "Choose targets, storage, and connected-device behavior") {
                    Button("Refresh", systemImage: "arrow.clockwise", action: model.refreshDevices)
                }

                Panel(title: "Capture", detail: "\(model.devices.count) visible device\(model.devices.count == 1 ? "" : "s")") {
                    VStack(spacing: 0) {
                        if model.devices.isEmpty {
                            Text("No visible device. Connect a phone or restore a hidden one.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        } else {
                            ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                                DeviceControlRow(
                                    device: device,
                                    capture: { model.capture(device) },
                                    hide: { model.hideDevice(device) }
                                )
                                if index < model.devices.count - 1 { Divider().padding(.leading, 48) }
                            }
                        }

                        Divider()
                        SettingRow(icon: "scope", title: "Quick Capture Device", detail: "Used by \(model.hotKeyDisplay); remembered across launches") {
                            QuickCaptureDevicePicker(model: model)
                                .labelsHidden()
                                .frame(width: 220)
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "play.rectangle.on.rectangle", title: "Live Previews", detail: "Refresh only while the app window is visible") {
                            Toggle("Live Previews", isOn: Binding(
                                get: { model.livePreviewsEnabled },
                                set: { model.setLivePreviewsEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        if !model.hiddenDevices.isEmpty {
                            Divider().padding(.leading, 48)
                            SettingRow(icon: "eye.slash", title: "Hidden Devices", detail: "Excluded from previews, hotkey, and Screenshot All") {
                                HiddenDevicesMenu(model: model)
                            }
                        }
                    }
                }

                Panel(title: "Save & copy", detail: model.destinationFolder.path) {
                    VStack(spacing: 0) {
                        SettingRow(icon: "folder", title: "Destination", detail: model.destinationFolder.lastPathComponent) {
                            HStack(spacing: 8) {
                                Button("Open", action: model.openFolder)
                                Button("Choose…", action: model.chooseFolder)
                            }
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "doc.on.clipboard", title: "Copy to Clipboard", detail: "Make every capture ready to paste") {
                            Toggle("Copy to Clipboard", isOn: Binding(
                                get: { model.copyToClipboard },
                                set: { model.setCopyToClipboard($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "folder.badge.gearshape", title: "Organize by Device", detail: "Create a folder for each phone") {
                            Toggle("Organize by Device", isOn: Binding(
                                get: { model.organizeByDevice },
                                set: { model.setOrganizeByDevice($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

                Panel(title: "Connections", detail: "iPhone and Android") {
                    VStack(spacing: 0) {
                        SettingRow(icon: "wifi", title: "iPhone Wi-Fi", detail: model.wirelessReady ? "Developer-services tunnel is ready" : "One-time wireless setup required") {
                            if model.wirelessReady {
                                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Set Up…", action: model.setupWireless)
                            }
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "apps.iphone", title: "Android (ADB)", detail: model.androidReady ? "Platform tools found; enable USB debugging on the phone" : "Install Android Platform Tools, then refresh") {
                            if model.androidReady {
                                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Setup Guide…", action: model.openAndroidSetup)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct PreferencesPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                PageHeader(title: "Settings", detail: "Background behavior, visibility, and updates") { EmptyView() }

                Panel(title: "Background", detail: "Capture can stay active when the window closes") {
                    VStack(spacing: 0) {
                        SettingRow(icon: "menubar.rectangle", title: "Show in Menu Bar", detail: "Quick capture and settings") {
                            Toggle("Show in Menu Bar", isOn: Binding(
                                get: { model.showInMenuBar },
                                set: { model.setShowInMenuBar($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "dock.rectangle", title: "Show in Dock", detail: "Keep TetherShot visible in the Dock when its window closes") {
                            Toggle("Show in Dock", isOn: Binding(
                                get: { model.showInDock },
                                set: { model.setShowInDock($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "power", title: "Launch at Login", detail: "Keep TetherShot available after sign-in") {
                            Toggle("Launch at Login", isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
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

                Panel(title: "Updates", detail: "Installed version \(model.appVersion)") {
                    VStack(spacing: 0) {
                        SettingRow(icon: "arrow.triangle.2.circlepath", title: "Automatically Check", detail: "Look for signed GitHub releases") {
                            Toggle("Automatically Check", isOn: Binding(
                                get: { model.autoCheckForUpdates },
                                set: { model.setAutoCheckForUpdates($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
                        }
                        Divider().padding(.leading, 48)
                        SettingRow(icon: "arrow.down.app", title: "Install Automatically", detail: "Verify, replace, and relaunch when an update appears") {
                            Toggle("Install Automatically", isOn: Binding(
                                get: { model.autoInstallUpdates },
                                set: { model.setAutoInstallUpdates($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch)
                        }
                        Divider().padding(.leading, 48)
                        HStack {
                            Text(model.availableUpdate.map { "Version \($0) is available" } ?? "TetherShot \(model.appVersion)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.availableUpdate != nil {
                                Button("Install & Relaunch", action: model.installUpdate)
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Check Now") { model.checkForUpdates(manual: true) }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct AboutPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                    Text("TetherShot")
                        .font(.system(size: 28, weight: .bold))
                    Text("Version \(model.appVersion) · Native macOS capture for iPhone and Android")
                        .foregroundStyle(.secondary)
                    Text("Local-first · Open source · MIT licensed")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)

                Panel(title: "Project & support", detail: "Apoorv Darshan") {
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
                        ProjectLinkRow(icon: "megaphone", title: "View on Product Hunt", detail: "Follow the launch and leave feedback", url: ProjectLinks.productHunt)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TetherShotTheme.accent)
                .frame(width: 30, height: 30)
                .background(TetherShotTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).fontWeight(.semibold)
                Text(device.connectionSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Capture", systemImage: "camera.fill", action: capture)
                .buttonStyle(.borderedProminent)
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Hide This Device", systemImage: "eye.slash", action: hide)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
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

private struct PageHeader<Accessory: View>: View {
    let title: String
    let detail: String
    let accessory: Accessory

    init(title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

private struct StatusFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(model.lastStatus.hasPrefix("Error") ? Color.red : Color.secondary)
            Text(model.lastStatus.isEmpty ? "Ready" : model.lastStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
                    Text(detail).font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption)
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
                    .font(.caption)
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
