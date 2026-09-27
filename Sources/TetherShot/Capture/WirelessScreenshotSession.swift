import Foundation

/// Talks to `scripts/wireless-screenshot.py`, a long-lived helper that keeps
/// one DVT connection open per iPhone. A capture is then a single request
/// instead of a new Python process, RemoteXPC handshake and instruments
/// channel, which cut Wi-Fi captures from roughly 0.7 s to 0.1 s.
///
/// Requests are serialized on one queue. Any failure tears the helper down so
/// the next request starts a fresh one, and callers fall back to the CLI.
final class WirelessScreenshotSession: @unchecked Sendable {
    private let pythonPath: String
    private let helperPath: String
    private let queue = DispatchQueue(label: "com.apoorvdarshan.tethershot.wireless-screenshot")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(pythonPath: String, helperPath: String) {
        self.pythonPath = pythonPath
        self.helperPath = helperPath
    }

    /// Opens the connection ahead of time so the first capture is fast too.
    func warm(deviceID: String) {
        queue.async {
            if case .failure(let error) = self.send("warm", deviceID, timeout: 15) {
                Log.shared.log("wireless helper: warm failed \(error.localizedDescription)")
            }
        }
    }

    func capture(deviceID: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: self.send("shot", deviceID, timeout: 15))
            }
        }
    }

    /// Runs on `queue`. The watchdog terminates a stuck helper, which unblocks
    /// the pending read with EOF.
    private func send(_ command: String, _ deviceID: String, timeout: TimeInterval) -> Result<Data, Error> {
        do {
            let (process, input, output) = try runningHelper()
            let watchdog = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            defer { watchdog.cancel() }

            try input.write(contentsOf: Data("\(command) \(deviceID)\n".utf8))
            let header = try read(5, from: output)
            let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
            let payload = try read(length, from: output)
            switch header.first {
            case UInt8(ascii: "P"), UInt8(ascii: "K"):
                return .success(payload)
            case UInt8(ascii: "E"):
                return .failure(CaptureError.other(String(decoding: payload, as: UTF8.self)))
            default:
                throw CaptureError.other("Wireless helper sent an unexpected reply.")
            }
        } catch {
            stop()
            return .failure(error)
        }
    }

    private func runningHelper() throws -> (Process, FileHandle, FileHandle) {
        if let process, process.isRunning, let input, let output {
            return (process, input, output)
        }
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [helperPath]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                Log.shared.log("wireless helper: \(line)")
            }
        }
        // A write racing the helper's exit must fail with EPIPE instead of
        // raising SIGPIPE, which would terminate the app.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        Log.shared.log("wireless helper: started pid \(process.processIdentifier)")

        self.process = process
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        return (process, inPipe.fileHandleForWriting, outPipe.fileHandleForReading)
    }

    private func read(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw CaptureError.other("Wireless helper exited.")
            }
            data.append(chunk)
        }
        return data
    }

    private func stop() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        process = nil
        input = nil
        output = nil
    }
}
