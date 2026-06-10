import Foundation

/// How a phone is reachable. USB is implemented in Phase 1; Wi-Fi arrives in Phase 2.
enum ConnectionKind: String {
    case usb = "USB"
    case wireless = "Wi-Fi"
}

/// A capturable phone surfaced by a backend.
struct CaptureDevice: Identifiable, Hashable {
    let id: String          // stable unique device id
    let name: String        // e.g. "Apoorv's iPhone"
    let connection: ConnectionKind
}

enum CaptureError: Error, LocalizedError {
    case noDevice
    case permissionDenied
    case timeout
    case encodingFailed
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:         return "No iPhone found over USB."
        case .permissionDenied: return "Camera permission denied — grant it in System Settings ▸ Privacy & Security ▸ Camera."
        case .timeout:          return "Timed out waiting for a frame. Unlock the iPhone and keep it trusted."
        case .encodingFailed:   return "Could not encode the screenshot."
        case .other(let m):     return m
        }
    }
}

/// A source of phone screenshots. Multiple backends (USB now, Wi-Fi later) implement this.
protocol CaptureBackend {
    func discoverDevices() -> [CaptureDevice]
    func capture(deviceID: String) async throws -> Data   // PNG bytes
}
