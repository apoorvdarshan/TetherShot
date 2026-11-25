import Foundation

/// Discovers and captures Android devices through Google's Android Debug
/// Bridge. Users enable USB debugging once; screenshots remain local and are
/// transferred as PNG files without installing anything on the phone.
final class AndroidCapture: CaptureBackend {
    private let routeIdentities = AndroidRouteIdentityCache()

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
        var routes: [AndroidDeviceParser.Route] = []
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
            routes.append(.init(device: parsed, androidID: androidID))
        }
        return await routeIdentities.reconcile(routes)
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

        let candidates = try await currentDevices(adbPath: adb)
        let aliases = AndroidDeviceParser.matchingSerials(requested: device.captureID, candidates: candidates)
        var lastError: CaptureError?
        for serial in aliases {
            do { return try await screenshot(adb: adb, serial: serial) }
            catch let error as CaptureError { lastError = error }
        }

        // A USB handle, manually connected address, or renamed Bonjour service
        // may also belong to this phone. Never fall back to another phone by model.
        if device.id.hasPrefix("android:") {
            let attempted = Set(aliases)
            for candidate in candidates where !attempted.contains(candidate.captureID) {
                let identity = await Proc.run(
                    adb,
                    ["-s", candidate.captureID, "shell", "settings", "get", "secure", "android_id"],
                    timeout: 5
                )
                guard identity.status == 0,
                      DeviceIdentity.android(androidID: identity.stdout, adbSerial: candidate.captureID) == device.id
                else { continue }
                do { return try await screenshot(adb: adb, serial: candidate.captureID) }
                catch let error as CaptureError { lastError = error }
            }
        }
        throw lastError ?? CaptureError.other("Android device disconnected. Reconnect USB or Wi-Fi; TetherShot will retry.")
    }

    private func screenshot(adb: String, serial: String) async throws -> Data {
        Log.shared.log("android: direct screencap \(serial)")
        let shot = await Proc.runData(
            adb,
            ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: 8
        )
        guard shot.status == 0, shot.stdout.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw CaptureError.other(Self.message(from: shot.stderr, fallback: "Android capture failed."))
        }
        return shot.stdout
    }

    private func currentDevices(adbPath: String) async throws -> [CaptureDevice] {
        let result = await Proc.run(adbPath, ["devices", "-l"], timeout: 8)
        guard result.status == 0 else {
            throw CaptureError.other(Self.message(
                from: result.stderr,
                fallback: "Could not query connected Android devices."
            ))
        }

        return AndroidDeviceParser.parse(result.stdout)
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

/// Remember verified Bonjour identities while the app runs so transient shell
/// timeouts don't turn a saved hotkey or hidden device into a different device.
actor AndroidRouteIdentityCache {
    private var knownIDs: [String: String] = [:]

    func reconcile(_ routes: [AndroidDeviceParser.Route]) -> [CaptureDevice] {
        let wifiGroups = Dictionary(grouping: routes.filter {
            AndroidDeviceParser.isBonjourSerial($0.device.captureID)
        }) { AndroidDeviceParser.stableSerial($0.device.captureID) }
        for (serial, group) in wifiGroups {
            let ids = Set(group.compactMap(\.verifiedID))
            if ids.count == 1, let id = ids.first {
                knownIDs[serial] = id
            } else if ids.count > 1 {
                knownIDs.removeValue(forKey: serial)
            }
        }
        return AndroidDeviceParser.reconcile(routes, knownBonjourIDs: knownIDs)
    }
}

enum AndroidDeviceParser {
    struct Route {
        let device: CaptureDevice
        let androidID: String?

        var verifiedID: String? {
            let id = DeviceIdentity.android(androidID: androidID, adbSerial: device.captureID)
            return id.hasPrefix("android:") ? id : nil
        }
    }

    /// Bonjour may advertise `adb-…` and `adb-… (2)` for the same phone. Share
    /// a verified Android ID across aliases even if one shell did not answer.
    /// Do not equate unrelated endpoints just because they share a model name.
    static func reconcile(_ routes: [Route], knownBonjourIDs: [String: String] = [:]) -> [CaptureDevice] {
        let groups = Dictionary(grouping: routes) { stableSerial($0.device.captureID) }
        // Equal-ranked Wi-Fi routes keep discovery order in CaptureDeviceMerger,
        // so put responsive, verified endpoints before unanswered aliases.
        let ordered = routes.filter { $0.verifiedID != nil } + routes.filter { $0.verifiedID == nil }
        return ordered.map { route in
            let device = route.device
            let stable = stableSerial(device.captureID)
            let groupIDs = Set(groups[stable, default: []].compactMap(\.verifiedID))
            let id = route.verifiedID
                ?? (groupIDs.count == 1 ? groupIDs.first : nil)
                ?? (groupIDs.isEmpty && isBonjourSerial(stable) ? knownBonjourIDs[stable] : nil)
                ?? DeviceIdentity.android(androidID: nil, adbSerial: stable)
            return CaptureDevice(id: id, captureID: device.captureID, name: device.name, connection: device.connection)
        }
    }

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

    static func matchingSerials(
        requested: String,
        candidates: [CaptureDevice]
    ) -> [String] {
        let stableRequested = stableSerial(requested)
        let matches = candidates.map(\.captureID).filter { stableSerial($0) == stableRequested }
        return matches.filter { $0 == requested } + matches.filter { $0 != requested }
    }

    static func stableSerial(_ serial: String) -> String {
        serial.replacingOccurrences(
            of: #"\s+\(\d+\)(?=\._adb-tls-connect\._tcp$)"#,
            with: "",
            options: .regularExpression
        )
    }

    static func isWireless(serial: String) -> Bool {
        serial.contains(":") || isBonjourSerial(serial)
    }

    static func isBonjourSerial(_ serial: String) -> Bool {
        serial.lowercased().hasSuffix("._adb-tls-connect._tcp")
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
