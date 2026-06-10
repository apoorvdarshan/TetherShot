import Foundation

/// Minimal append-only logger so we can diagnose capture behaviour without a
/// debugger attached. Writes to ~/Library/Logs/TetherShot.log and stderr.
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let url: URL
    private let queue = DispatchQueue(label: "com.apoorvdarshan.tethershot.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("TetherShot.log")
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async { [url] in
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
