import Foundation

/// Discovers and captures Android devices through Google's Android Debug
/// Bridge. Users enable USB debugging once; screenshots remain local and are
/// transferred as PNG files without installing anything on the phone.
final class AndroidCapture: CaptureBackend {
    static let adbPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func discoverDevices() -> [CaptureDevice] { [] }

    func discoverDevicesAsync() async -> [CaptureDevice] {
        guard let adb = Self.adbPath else { return [] }
        let result = await Proc.run(adb, ["devices", "-l"], timeout: 8)
        guard result.status == 0 else { return [] }
        var devices: [CaptureDevice] = []
        for parsed in AndroidDeviceParser.parse(result.stdout) {
            async let kernelQEMUResult = Proc.run(
                adb,
                ["-s", parsed.captureID, "shell", "getprop", "ro.kernel.qemu"],
                timeout: 5
            )
            async let bootQEMUResult = Proc.run(
                adb,
                ["-s", parsed.captureID, "shell", "getprop", "ro.boot.qemu"],
                timeout: 5
            )
            let identityResult = await Proc.run(
                adb,
                ["-s", parsed.captureID, "shell", "settings", "get", "secure", "android_id"],
                timeout: 5
            )
            guard !AndroidDeviceParser.isEmulator(
                kernelQEMU: (await kernelQEMUResult).stdout,
                bootQEMU: (await bootQEMUResult).stdout
            ) else { continue }
            let androidID = identityResult.status == 0 ? identityResult.stdout : nil
            devices.append(CaptureDevice(
                id: DeviceIdentity.android(androidID: androidID, adbSerial: parsed.captureID),
                captureID: parsed.captureID,
                name: parsed.name,
                connection: parsed.connection
            ))
        }
        return devices
    }

    func capture(deviceID: String) async throws -> Data {
        guard let adb = Self.adbPath else {
            throw CaptureError.other("Android platform tools are not installed.")
        }

        let token = UUID().uuidString
        let remotePath = "/data/local/tmp/tethershot-\(token).png"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tethershot-android-\(token).png")
        defer { try? FileManager.default.removeItem(at: localURL) }

        Log.shared.log("android: screencap \(deviceID)")
        let shot = await Proc.run(
            adb,
            ["-s", deviceID, "shell", "screencap", "-p", remotePath],
            timeout: 15
        )
        guard shot.status == 0 else {
            throw CaptureError.other(Self.message(from: shot.stderr, fallback: "Android capture failed."))
        }

        let pull = await Proc.run(
            adb,
            ["-s", deviceID, "pull", remotePath, localURL.path],
            timeout: 15
        )
        _ = await Proc.run(adb, ["-s", deviceID, "shell", "rm", "-f", remotePath], timeout: 5)

        guard pull.status == 0, FileManager.default.fileExists(atPath: localURL.path) else {
            throw CaptureError.other(Self.message(from: pull.stderr, fallback: "Could not transfer the Android screenshot."))
        }
        return try Data(contentsOf: localURL)
    }

    private static func message(from text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? fallback
        if line.localizedCaseInsensitiveContains("unauthorized") {
            return "Unlock the Android phone and allow USB debugging."
        }
        return line
    }
}

enum AndroidDeviceParser {
    static func parse(_ output: String) -> [CaptureDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> CaptureDevice? in
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 2, fields[1] == "device" else { return nil }
                let serial = fields[0]
                guard !isEmulator(serial: serial, fields: fields) else { return nil }
                let model = fields
                    .first(where: { $0.hasPrefix("model:") })?
                    .dropFirst("model:".count)
                    .replacingOccurrences(of: "_", with: " ")
                let name = model?.isEmpty == false ? model! : "Android …\(serial.suffix(5))"
                let connection: ConnectionKind = isWireless(serial: serial)
                    ? .androidWireless
                    : .androidUSB
                return CaptureDevice(id: serial, captureID: serial, name: name, connection: connection)
            }
    }

    static func isEmulator(kernelQEMU: String, bootQEMU: String) -> Bool {
        [kernelQEMU, bootQEMU].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
    }

    private static func isWireless(serial: String) -> Bool {
        serial.contains(":") || serial.localizedCaseInsensitiveContains("._adb-tls-connect._tcp")
    }

    private static func isEmulator(serial: String, fields: [String]) -> Bool {
        let serial = serial.lowercased()
        if serial.hasPrefix("emulator-") { return true }

        let normalizedFields = fields.map(
            { $0.lowercased().replacingOccurrences(of: "-", with: "_") }
        )
        return normalizedFields.contains { field in
            field.hasPrefix("product:sdk_gphone")
                || field.hasPrefix("model:sdk_gphone")
                || field.hasPrefix("device:emu")
                || field == "device:generic"
        }
    }
}
