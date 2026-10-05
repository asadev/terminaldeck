import Foundation

/// Append-only log at `~/Library/Application Support/Terminal Deck Native Proof/engine.log`.
/// Written from the pipe-reading queues, so every write goes through one serial queue.
public final class EngineLog: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "dev.terminaldeck.native-proof.engine-log")
    private var handle: FileHandle?
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    public init(url: URL) {
        self.url = url
        queue.sync { self.open() }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep one previous log when this one grows past 5 MB.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Raw engine output (stderr / stdout bytes), as-is.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { try? self.handle?.write(contentsOf: data) }
    }

    /// One line of engine stdout.
    public func line(_ text: String) {
        append(Data((text + "\n").utf8))
    }

    /// A note from the shell itself, timestamped so it stands out from engine output.
    public func note(_ text: String) {
        let stamp = Date().formatted(.iso8601)
        line("[native \(stamp)] \(text)")
    }

    public func flush() {
        queue.sync { try? self.handle?.synchronize() }
    }
}
