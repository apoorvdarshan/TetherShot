import Foundation

/// How a phone is reachable. USB is implemented in Phase 1; Wi-Fi arrives in Phase 2.
enum ConnectionKind: String, Equatable {
    case usb = "USB"
    case wireless = "Wi-Fi"
    case androidUSB = "Android USB"
    case androidWireless = "Android Wi-Fi"
}

/// A capturable phone surfaced by a backend.
struct CaptureDevice: Identifiable, Hashable {
    let id: String          // stable hardware identity, independent of display name/transport
    let captureID: String   // backend-specific handle (AVFoundation ID, UDID, or ADB serial)
    let name: String        // e.g. "Apoorv's iPhone"
    let connection: ConnectionKind
    let availableConnections: [ConnectionKind]

    init(
        id: String,
        captureID: String? = nil,
        name: String,
        connection: ConnectionKind,
        availableConnections: [ConnectionKind]? = nil
    ) {
        self.id = id
        self.captureID = captureID ?? id
        self.name = name
        self.connection = connection
        self.availableConnections = availableConnections ?? [connection]
    }
}

extension CaptureDevice {
    var systemImageName: String {
        switch connection {
        case .usb: return "cable.connector"
        case .wireless: return "wifi"
        case .androidUSB: return "cable.connector"
        case .androidWireless: return "wifi"
        }
    }

    var platformName: String {
        switch connection {
        case .androidUSB, .androidWireless: return "Android"
        case .usb, .wireless: return "iPhone"
        }
    }

    var connectionSummary: String {
        availableConnections.map(\.rawValue).joined(separator: " + ")
    }
}

enum DeviceIdentity {
    static func iOS(rawID: String) -> String {
        let patterns = [
            #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}"#,
            #"[0-9A-Fa-f]{40}"#,
        ]
        for pattern in patterns {
            if let range = rawID.range(of: pattern, options: .regularExpression) {
                return "ios:" + rawID[range].lowercased()
            }
        }
        return "ios:" + rawID.lowercased()
    }

    static func android(androidID: String?, adbSerial: String) -> String {
        if let androidID {
            let normalized = androidID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, normalized != "null" { return "android:" + normalized }
        }
        return "android-adb:" + adbSerial.lowercased()
    }
}

enum CaptureDeviceMerger {
    static func merge(_ devices: [CaptureDevice]) -> [CaptureDevice] {
        var order: [String] = []
        var merged: [String: CaptureDevice] = [:]

        for device in devices {
            guard let current = merged[device.id] else {
                order.append(device.id)
                merged[device.id] = device
                continue
            }

            let preferred = rank(device.connection) < rank(current.connection) ? device : current
            let connections = (current.availableConnections + device.availableConnections)
                .reduce(into: [ConnectionKind]()) { result, connection in
                    if !result.contains(connection) { result.append(connection) }
                }
                .sorted { rank($0) < rank($1) }
            let name = isFallbackName(current.name) && !isFallbackName(device.name)
                ? device.name
                : current.name
            merged[device.id] = CaptureDevice(
                id: device.id,
                captureID: preferred.captureID,
                name: name,
                connection: preferred.connection,
                availableConnections: connections
            )
        }

        return order.compactMap { merged[$0] }
    }

    private static func rank(_ connection: ConnectionKind) -> Int {
        switch connection {
        case .usb: return 0
        case .androidUSB: return 1
        case .wireless: return 2
        case .androidWireless: return 3
        }
    }

    private static func isFallbackName(_ name: String) -> Bool {
        name.hasPrefix("iPhone …") || name.hasPrefix("Android …")
    }
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
