import Foundation

struct HiddenDevicePreference: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

enum HiddenDevicePreferenceStore {
    private static let key = "hiddenCaptureDevices"

    static func load(defaults: UserDefaults = .standard) -> [HiddenDevicePreference] {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode([HiddenDevicePreference].self, from: data) else {
            return []
        }
        return preferences
    }

    static func save(
        _ preferences: [HiddenDevicePreference],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

enum CaptureDeviceVisibility {
    static func visibleDevices(
        from devices: [CaptureDevice],
        hidden: [HiddenDevicePreference]
    ) -> [CaptureDevice] {
        let hiddenIDs = Set(hidden.map(\.id))
        return devices.filter { !hiddenIDs.contains($0.id) }
    }

    static func hiddenConnectedCount(
        in devices: [CaptureDevice],
        hidden: [HiddenDevicePreference]
    ) -> Int {
        let hiddenIDs = Set(hidden.map(\.id))
        return devices.filter { hiddenIDs.contains($0.id) }.count
    }
}
