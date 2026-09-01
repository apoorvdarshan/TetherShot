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
    @Published var androidReady = AndroidCapture.adbPath != nil
    @Published var launchAtLogin: Bool
    @Published var organizeByDevice = UserDefaults.standard.bool(forKey: "organizeByDevice")
    @Published var copyToClipboard = (UserDefaults.standard.object(forKey: "copyToClipboard") as? Bool) ?? true
    @Published var showInMenuBar: Bool
    @Published var showInDock: Bool
    @Published var autoCheckForUpdates: Bool
    @Published var autoInstallUpdates: Bool
    @Published var availableUpdate: String?
    @Published private(set) var quickCapturePreference = QuickCapturePreferenceStore.load()
    @Published private(set) var hiddenDevices = HiddenDevicePreferenceStore.load()

    let hotKeyDisplay = HotKey.defaultDisplay
    var appVersion: String { updater.currentVersion }
    var quickCaptureSelectionID: String { quickCapturePreference?.id ?? "" }
    var quickCaptureTargetName: String { quickCapturePreference?.name ?? "All connected devices" }
    var hiddenConnectedDeviceCount: Int {
        CaptureDeviceVisibility.hiddenConnectedCount(in: discoveredDevices, hidden: hiddenDevices)
    }

    private let usb = USBCapture()
    private let wireless = WirelessCapture()
    private let android = AndroidCapture()
    private let updater = Updater()
    private var hotKey: HotKey?
    private var isCapturing = false
    private var discoveredDevices: [CaptureDevice] = []
    var dockVisibilityDidChange: ((Bool) -> Void)?

    init() {
        let backgroundPreferences = BackgroundPreferenceStore.bootstrap()
        launchAtLogin = backgroundPreferences.launchAtLogin
        showInMenuBar = backgroundPreferences.showInMenuBar
        showInDock = backgroundPreferences.showInDock
        autoCheckForUpdates = backgroundPreferences.autoCheckForUpdates
        autoInstallUpdates = backgroundPreferences.autoInstallUpdates

        Notifier.requestAuthorization()
        registerHotKey()
        refreshDevices()
        if autoCheckForUpdates || autoInstallUpdates {
            checkForUpdates(manual: false)
        }
    }

    // MARK: Devices

    /// Merges USB (AVFoundation, instant) and Wi-Fi (tunneld) device lists.
    func refreshDevices() {
        let usbDevices = usb.discoverDevices()
        applyDiscoveredDevices(usbDevices)            // show USB immediately
        Task {
            async let refreshedUSBDevices = discoverUSBDevicesWithStartupRetry(initial: usbDevices)
            async let wirelessDevices = wireless.discoverDevicesAsync()
            async let androidDevices = android.discoverDevicesAsync()
            wirelessReady = await wireless.isTunneldRunning()
            androidReady = AndroidCapture.adbPath != nil
            applyDiscoveredDevices(
                (await refreshedUSBDevices) + (await wirelessDevices) + (await androidDevices)
            )
            if devices.isEmpty {
                if hiddenConnectedDeviceCount > 0 {
                    lastStatus = "All connected phones are hidden. Restore one under Hidden Devices."
                } else {
                    lastStatus = wirelessReady
                        ? "No phone found. Connect an iPhone or an authorized Android device."
                        : "Connect an iPhone over USB, or an Android phone with USB debugging."
                }
            } else {
                lastStatus = ""
            }
        }
    }

    /// CoreMediaIO can register a connected iPhone screen just after app
    /// launch. Retry only when the immediate discovery was empty so the USB
    /// route can replace Wi-Fi without requiring a manual refresh.
    private func discoverUSBDevicesWithStartupRetry(
        initial: [CaptureDevice]
    ) async -> [CaptureDevice] {
        guard initial.isEmpty else { return initial }
        for delay in [250_000_000, 750_000_000, 1_500_000_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return [] }
            let discovered = usb.discoverDevices()
            if !discovered.isEmpty { return discovered }
        }
        return []
    }

    private func merged(with usbDevices: [CaptureDevice]) async -> [CaptureDevice] {
        async let wirelessDevices = wireless.discoverDevicesAsync()
        async let androidDevices = android.discoverDevicesAsync()
        return usbDevices + (await wirelessDevices) + (await androidDevices)
    }

    private func applyDiscoveredDevices(_ discovered: [CaptureDevice]) {
        let merged = CaptureDeviceMerger.merge(discovered)
        discoveredDevices = merged
        refreshHiddenDeviceNames(from: merged)
        devices = CaptureDeviceVisibility.visibleDevices(from: merged, hidden: hiddenDevices)
        migrateQuickCapturePreferenceIfNeeded()
    }

    private func refreshHiddenDeviceNames(from devices: [CaptureDevice]) {
        let names = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
        let refreshed = hiddenDevices.map { preference in
            HiddenDevicePreference(id: preference.id, name: names[preference.id] ?? preference.name)
        }
        guard refreshed != hiddenDevices else { return }
        hiddenDevices = refreshed
        HiddenDevicePreferenceStore.save(refreshed)
    }

    private func migrateQuickCapturePreferenceIfNeeded() {
        guard let preference = quickCapturePreference,
              case .device(let device) = QuickCaptureTarget.resolve(
                devices: devices,
                preference: preference
              ),
              preference.id != device.id || preference.name != device.name else { return }
        let migrated = QuickCaptureDevicePreference(id: device.id, name: device.name)
        quickCapturePreference = migrated
        QuickCapturePreferenceStore.save(migrated)
    }

    func hideDevice(_ device: CaptureDevice) {
        guard !hiddenDevices.contains(where: { $0.id == device.id }) else { return }
        hiddenDevices.append(HiddenDevicePreference(id: device.id, name: device.name))
        HiddenDevicePreferenceStore.save(hiddenDevices)
        if quickCapturePreference?.id == device.id {
            quickCapturePreference = nil
            QuickCapturePreferenceStore.save(nil)
        }
        applyDiscoveredDevices(discoveredDevices)
        lastStatus = "Hidden \(device.name). Restore it anytime under Hidden Devices."
    }

    func restoreDevice(_ deviceID: String) {
        guard let preference = hiddenDevices.first(where: { $0.id == deviceID }) else { return }
        hiddenDevices.removeAll { $0.id == deviceID }
        HiddenDevicePreferenceStore.save(hiddenDevices)
        applyDiscoveredDevices(discoveredDevices)
        lastStatus = "Restored \(preference.name). It will appear whenever it is connected."
    }

    func restoreAllHiddenDevices() {
        guard !hiddenDevices.isEmpty else { return }
        hiddenDevices = []
        HiddenDevicePreferenceStore.save([])
        applyDiscoveredDevices(discoveredDevices)
        lastStatus = "Restored all hidden devices."
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

    /// Global-hotkey entry point: re-discovers, then captures the saved device
    /// or every device when no preference has been set.
    func hotKeyCapture() {
        Task {
            let list = await merged(with: usb.discoverDevices())
            applyDiscoveredDevices(list)

            switch QuickCaptureTarget.resolve(devices: devices, preference: quickCapturePreference) {
            case .all(let devices):
                guard !devices.isEmpty else {
                    lastStatus = "Quick capture: no visible phone found"
                    NSSound(named: "Funk")?.play()
                    return
                }
                for device in devices { await performCapture(device) }
            case .device(let device):
                await performCapture(device)
            case .preferredDeviceUnavailable:
                lastStatus = "Quick capture: \(quickCaptureTargetName) is not connected"
                NSSound(named: "Funk")?.play()
            }
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
                png = try await usb.capture(deviceID: device.captureID)
            case .wireless:
                png = try await wireless.capture(deviceID: device.captureID)
            case .androidUSB, .androidWireless:
                png = try await android.capture(device: device)
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
        BackgroundPreferenceStore.saveLaunchAtLogin(launchAtLogin)
    }

    func setOrganizeByDevice(_ enabled: Bool) {
        organizeByDevice = enabled
        UserDefaults.standard.set(enabled, forKey: "organizeByDevice")
    }

    func setCopyToClipboard(_ enabled: Bool) {
        copyToClipboard = enabled
        UserDefaults.standard.set(enabled, forKey: "copyToClipboard")
    }

    func setQuickCaptureDevice(_ deviceID: String) {
        if deviceID.isEmpty {
            quickCapturePreference = nil
            QuickCapturePreferenceStore.save(nil)
            lastStatus = "Quick capture will use all connected devices."
            return
        }

        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        let preference = QuickCaptureDevicePreference(id: device.id, name: device.name)
        quickCapturePreference = preference
        QuickCapturePreferenceStore.save(preference)
        lastStatus = "Quick capture will use \(device.name)."
    }

    func setShowInMenuBar(_ enabled: Bool) {
        guard showInMenuBar != enabled else { return }
        showInMenuBar = enabled
        UserDefaults.standard.set(enabled, forKey: BackgroundPreferenceStore.showInMenuBarKey)
        lastStatus = enabled
            ? "Menu-bar icon enabled."
            : "Menu-bar icon hidden. Reopen TetherShot from Applications or Spotlight."
    }

    func setShowInDock(_ enabled: Bool) {
        guard showInDock != enabled else { return }
        showInDock = enabled
        UserDefaults.standard.set(enabled, forKey: BackgroundPreferenceStore.showInDockKey)
        dockVisibilityDidChange?(enabled)
        lastStatus = enabled
            ? "Dock icon enabled."
            : "Dock icon hidden. Use the menu bar, Spotlight, or \(hotKeyDisplay) to return."
    }

    func setAutoCheckForUpdates(_ enabled: Bool) {
        autoCheckForUpdates = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: BackgroundPreferenceStore.autoCheckForUpdatesKey
        )
    }

    /// When on, the app silently installs a newer version and relaunches as soon
    /// as one is found (implies checking).
    func setAutoInstallUpdates(_ enabled: Bool) {
        autoInstallUpdates = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: BackgroundPreferenceStore.autoInstallUpdatesKey
        )
        if enabled { checkForUpdates(manual: false) }
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
                if autoInstallUpdates {
                    lastStatus = "Auto-updating to \(info.latest)…"
                    installUpdate()
                } else {
                    lastStatus = "Update available: \(info.latest)"
                }
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
        lastStatus = "Downloading and verifying the signed update…"
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

    func openAndroidSetup() {
        guard let url = URL(string: "https://developer.android.com/tools/releases/platform-tools") else { return }
        NSWorkspace.shared.open(url)
        lastStatus = "Install Android Platform Tools, enable USB debugging, then refresh devices."
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
