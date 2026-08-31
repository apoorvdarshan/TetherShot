import Foundation

struct BackgroundPreferenceState: Equatable {
    let showInMenuBar: Bool
    let showInDock: Bool
    let launchAtLogin: Bool
}

/// Establishes background-behavior defaults once without overwriting choices
/// made by people who already use TetherShot.
enum BackgroundPreferenceStore {
    static let showInMenuBarKey = "showInMenuBar"
    static let showInDockKey = "showInDock"
    static let launchAtLoginKey = "launchAtLogin"

    private static let defaultsInitializedKey = "backgroundDefaultsInitializedV1"
    private static let existingInstallEvidenceKeys = [
        "organizeByDevice",
        "copyToClipboard",
        showInMenuBarKey,
        showInDockKey,
        "autoCheckForUpdates",
        "autoInstallUpdates",
        "destinationFolderBookmark",
        "quickCaptureDeviceID",
        "quickCaptureDeviceName",
        "hiddenCaptureDevices",
    ]

    static func bootstrap(
        defaults: UserDefaults = .standard,
        launchAtLoginIsEnabled: Bool = LaunchAtLogin.isEnabled,
        setLaunchAtLogin: (Bool) -> Bool = LaunchAtLogin.set
    ) -> BackgroundPreferenceState {
        let wasInitialized = defaults.bool(forKey: defaultsInitializedKey)
        let hasExistingPreferences = existingInstallEvidenceKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        let isNewUser = !wasInitialized && !hasExistingPreferences

        let showInMenuBar = (defaults.object(forKey: showInMenuBarKey) as? Bool) ?? true
        let showInDock = (defaults.object(forKey: showInDockKey) as? Bool) ?? true

        if defaults.object(forKey: showInMenuBarKey) == nil {
            defaults.set(showInMenuBar, forKey: showInMenuBarKey)
        }
        if defaults.object(forKey: showInDockKey) == nil {
            defaults.set(showInDock, forKey: showInDockKey)
        }

        let launchAtLogin = isNewUser
            ? setLaunchAtLogin(true)
            : launchAtLoginIsEnabled

        defaults.set(launchAtLogin, forKey: launchAtLoginKey)
        defaults.set(true, forKey: defaultsInitializedKey)

        return BackgroundPreferenceState(
            showInMenuBar: showInMenuBar,
            showInDock: showInDock,
            launchAtLogin: launchAtLogin
        )
    }

    static func saveLaunchAtLogin(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: launchAtLoginKey)
    }
}
