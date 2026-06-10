import Foundation

/// Tiny async wrapper around `Process` for shelling out to CLI tools, with a
/// hard timeout and Homebrew on PATH (a Finder-launched app's PATH is bare).
enum Proc {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runBlocking(launchPath, arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain pipes concurrently so a chatty tool can't fill the buffer and deadlock.
        var outData = Data()
        var errData = Data()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); drain.leave() }
        drain.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); drain.leave() }

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let deadline = DispatchTime.now() + timeout
        let exited = DispatchGroup()
        exited.enter()
        DispatchQueue.global().async { process.waitUntilExit(); exited.leave() }
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }

        _ = drain.wait(timeout: .now() + 3)
        return Result(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
