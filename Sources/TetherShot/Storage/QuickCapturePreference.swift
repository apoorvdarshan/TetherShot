import Foundation

/// The phone the global quick-capture hotkey should use. A `nil`
/// preference preserves the original behavior of capturing every connected
/// device.
struct QuickCaptureDevicePreference: Equatable {
    let id: String
    let name: String
}

enum QuickCapturePreferenceStore {
    private static let idKey = "quickCaptureDeviceID"
    private static let nameKey = "quickCaptureDeviceName"

    static func load(defaults: UserDefaults = .standard) -> QuickCaptureDevicePreference? {
        guard let id = defaults.string(forKey: idKey), !id.isEmpty else { return nil }
        let name = defaults.string(forKey: nameKey) ?? "Selected phone"
        return QuickCaptureDevicePreference(id: id, name: name)
    }

    static func save(
        _ preference: QuickCaptureDevicePreference?,
        defaults: UserDefaults = .standard
    ) {
        guard let preference else {
            defaults.removeObject(forKey: idKey)
            defaults.removeObject(forKey: nameKey)
            return
        }
        defaults.set(preference.id, forKey: idKey)
        defaults.set(preference.name, forKey: nameKey)
    }
}

/// Keeps hotkey-target resolution deterministic and separately testable from
/// the AVFoundation capture path.
enum QuickCaptureTarget: Equatable {
    case all([CaptureDevice])
    case device(CaptureDevice)
    case preferredDeviceUnavailable

    static func resolve(
        devices: [CaptureDevice],
        preference: QuickCaptureDevicePreference?
    ) -> QuickCaptureTarget {
        guard let preference else { return .all(devices) }
        guard let device = devices.first(where: {
            $0.id == preference.id
                || $0.captureID == preference.id
                || $0.id == DeviceIdentity.iOS(rawID: preference.id)
        }) else {
            return .preferredDeviceUnavailable
        }
        return .device(device)
    }
}
