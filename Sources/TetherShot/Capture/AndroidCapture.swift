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
        let device = CaptureDevice(
            id: DeviceIdentity.android(androidID: nil, adbSerial: deviceID),
            captureID: deviceID,
            name: "Android",
            connection: AndroidDeviceParser.isWireless(serial: deviceID) ? .androidWireless : .androidUSB
        )
        return try await capture(device: device)
    }

    func capture(device: CaptureDevice) async throws -> Data {
        guard let adb = Self.adbPath else {
            throw CaptureError.other("Android platform tools are not installed.")
        }

        let deviceID = try await currentCaptureID(for: device, adbPath: adb)
        Log.shared.log("android: direct screencap \(deviceID)")
        let shot = await Proc.runData(
            adb,
            ["-s", deviceID, "exec-out", "screencap", "-p"],
            timeout: 8
        )
        guard shot.status == 0, shot.stdout.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw CaptureError.other(Self.message(from: shot.stderr, fallback: "Android capture failed."))
        }
        return shot.stdout
    }

    private func currentCaptureID(for device: CaptureDevice, adbPath: String) async throws -> String {
        let result = await Proc.run(adbPath, ["devices", "-l"], timeout: 8)
        guard result.status == 0 else {
            throw CaptureError.other(Self.message(
                from: result.stderr,
                fallback: "Could not query connected Android devices."
            ))
        }

        let candidates = AndroidDeviceParser.parse(result.stdout)
        if let serial = AndroidDeviceParser.preferredSerial(
            requested: device.captureID,
            candidates: candidates
        ) {
            return serial
        }

        // The mDNS service instance can change beyond its Bonjour conflict
        // suffix. Fall back to Android's persistent hardware identity so a
        // renamed/re-advertised phone resumes without becoming a new device.
        if device.id.hasPrefix("android:") {
            for candidate in candidates {
                let identity = await Proc.run(
                    adbPath,
                    ["-s", candidate.captureID, "shell", "settings", "get", "secure", "android_id"],
                    timeout: 5
                )
                guard identity.status == 0 else { continue }
                if DeviceIdentity.android(
                    androidID: identity.stdout,
                    adbSerial: candidate.captureID
                ) == device.id {
                    return candidate.captureID
                }
            }
        }

        throw CaptureError.other("Android device disconnected. Reconnect USB or Wi-Fi; TetherShot will retry.")
    }

    private static func message(from text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? fallback
        if line.localizedCaseInsensitiveContains("unauthorized") {
            return "Unlock the Android phone and allow USB debugging."
        }
        if line.localizedCaseInsensitiveContains("not found") {
            return "Android device disconnected. Reconnect USB or Wi-Fi; TetherShot will retry."
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
                // Wireless ADB service-instance names can contain a Bonjour
                // conflict suffix such as "(2)". Treat every field before the
                // connection-state token as the serial instead of assuming the
                // state is always the second field.
                guard let stateIndex = fields.firstIndex(of: "device"), stateIndex > 0 else {
                    return nil
                }
                let serial = fields[..<stateIndex].joined(separator: " ")
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

    static func preferredSerial(
        requested: String,
        candidates: [CaptureDevice]
    ) -> String? {
        if candidates.contains(where: { $0.captureID == requested }) { return requested }
        let stableRequested = stableSerial(requested)
        let matches = candidates.filter { stableSerial($0.captureID) == stableRequested }
        return matches.count == 1 ? matches[0].captureID : nil
    }

    static func stableSerial(_ serial: String) -> String {
        serial.replacingOccurrences(
            of: #"\s+\(\d+\)(?=\._adb-tls-connect\._tcp$)"#,
            with: "",
            options: .regularExpression
        )
    }

    static func isWireless(serial: String) -> Bool {
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
