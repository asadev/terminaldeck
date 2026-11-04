import Foundation
import Darwin

/// Startup is not permission to quit. Only the helper's final, verified receipt is.
enum NativeUpdateHelperHandshake {
    static func checkLimit(archiveBytes: Int64) -> TimeInterval {
        // At least two minutes; larger archives get 15 seconds per 128 MiB, up to ten minutes.
        max(120, min(600, 60 + Double(max(0, archiveBytes)) / (128 * 1024 * 1024) * 15))
    }

    static func wait(for child: NativeChild, directory: URL, timeout: TimeInterval) throws {
        let fm = FileManager.default
        let started = directory.appendingPathComponent("helper-started")
        let ready = directory.appendingPathComponent("helper-ready")
        let failed = directory.appendingPathComponent("helper-error")
        // A wall-clock correction must not shorten (or extend) validation.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var reason = "The update checks took too long. Please try again."
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let bytes = try? FileHandle(forReadingFrom: failed) {
                let message = (try? bytes.read(upToCount: 2048)).flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try? bytes.close()
                reason = message.map { "The update could not be installed: " + $0 } ?? "The update checks failed. Please download it again."
                break
            }
            guard child.isRunning else {
                reason = "The update helper stopped before its checks finished. Please try again."
                break
            }
            if fm.fileExists(atPath: started.path), fm.fileExists(atPath: ready.path) { return }
            usleep(25_000)
        }
        // Cancel BEFORE stopping the helper. A late receipt can never trigger a swap after a refused quit.
        try? Data().write(to: directory.appendingPathComponent("helper-cancelled"), options: .atomic)
        child.terminate()
        throw NativeUpdateFeed.Failure(reason + " The app is still running.")
    }
}
