import Foundation

/// Resolves friendly names even when a Wi-Fi phone is absent from usbmux.
enum WirelessDeviceNameLookup {
    typealias Run = @Sendable (String, [String], TimeInterval) async -> Proc.Result

    static func resolve(
        pmd3Path: String,
        tunneledDeviceIDs: [String],
        run: @escaping Run = { await Proc.run($0, $1, timeout: $2) }
    ) async -> [String: String] {
        let result = await run(pmd3Path, ["usbmux", "list"], 8)
        var names: [String: String] = [:]
        if result.status == 0,
           let data = result.stdout.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in list {
                guard let udid = entry["Identifier"] as? String,
                      let rawName = entry["DeviceName"] as? String,
                      let name = friendlyName(rawName) else { continue }
                names[udid] = name
            }
        }
        // These reads use the existing tunnel; they neither pair nor rename
        // the phone. Resolve missing names independently for multiple phones.
        let missing = Set(tunneledDeviceIDs).filter { names[$0] == nil }
        await withTaskGroup(of: (String, String?).self) { group in
            for udid in missing {
                group.addTask {
                    let result = await run(
                        pmd3Path, ["lockdown", "device-name", "--tunnel", udid], 8
                    )
                    return (udid, result.status == 0 ? friendlyName(result.stdout) : nil)
                }
            }
            for await (udid, name) in group {
                if let name { names[udid] = name }
            }
        }
        return names
    }

    private static func friendlyName(_ output: String) -> String? {
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { return nil }
        return name
    }
}
