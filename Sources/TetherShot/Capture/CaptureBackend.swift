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
        connection.rawValue
    }

    var availableConnectionSummary: String {
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
        let devices = reconcileIOSRouteIdentities(in: devices)
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

    /// AVFoundation exposes an iPhone screen with a CoreMediaIO UUID that is
    /// unrelated to the device's Apple UDID. When exactly one native USB route
    /// and one wireless route have the same friendly name, use the wireless
    /// route's stable UDID as the shared identity while keeping the USB
    /// capture handle. Ambiguous names are intentionally left separate.
    private static func reconcileIOSRouteIdentities(
        in devices: [CaptureDevice]
    ) -> [CaptureDevice] {
        let usbByName = Dictionary(grouping: devices.filter { $0.connection == .usb }) {
            normalizedName($0.name)
        }
        let wirelessByName = Dictionary(grouping: devices.filter { $0.connection == .wireless }) {
            normalizedName($0.name)
        }
        var aliases: [String: String] = [:]

        for (name, usbDevices) in usbByName {
            guard !name.isEmpty,
                  usbDevices.count == 1,
                  let wirelessDevices = wirelessByName[name],
                  wirelessDevices.count == 1,
                  !isFallbackName(usbDevices[0].name),
                  !isFallbackName(wirelessDevices[0].name) else { continue }
            aliases[usbDevices[0].id] = wirelessDevices[0].id
        }

        guard !aliases.isEmpty else { return devices }
        return devices.map { device in
            guard let canonicalID = aliases[device.id] else { return device }
            return CaptureDevice(
                id: canonicalID,
                captureID: device.captureID,
                name: device.name,
                connection: device.connection,
                availableConnections: device.availableConnections
            )
        }
    }

    private static func rank(_ connection: ConnectionKind) -> Int {
        // Lower ranks win when the same physical device is reachable both ways.
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

    private static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
