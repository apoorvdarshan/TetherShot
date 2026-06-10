import Foundation

/// Builds timestamped, filesystem-safe screenshot names, e.g.
/// `Apoorvs-iPhone_2026-06-11_14-23-05.png`.
enum Filename {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func make(deviceName: String, date: Date = Date()) -> String {
        "\(folderName(for: deviceName))_\(formatter.string(from: date)).png"
    }

    /// Filesystem-safe device name used for both the filename stem and the
    /// per-device subfolder.
    static func folderName(for deviceName: String) -> String {
        let safe = deviceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return safe.isEmpty ? "iPhone" : safe
    }
}
