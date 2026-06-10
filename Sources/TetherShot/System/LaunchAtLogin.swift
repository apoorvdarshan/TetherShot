import ServiceManagement

/// Thin wrapper over `SMAppService` (macOS 13+) for the "Launch at Login" toggle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state (re-read from the system, so the UI reflects
    /// reality even if registration was blocked).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.shared.log("launchAtLogin: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
