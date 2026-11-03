import Foundation
import Darwin

/// U1, one rule for every saved file: what could not be read is never written over, and one bad record costs
/// only that record. A store that cannot read its file, or skips a record in it, first keeps the file's exact
/// bytes beside it as `<name>.damaged-<seconds>`; only then may it save there. When even that copy cannot be
/// made (the bytes cannot be read at all), the store saves nothing over the file and reads it again later.
public enum DamagedFile {
    public static let marker = ".damaged-"

    /// Keeps the exact bytes of `file` beside it, once: an identical copy already there is reused, so a file
    /// read again at every start leaves one copy. Returns the copy, or nil when the bytes could not be kept.
    @discardableResult
    public static func keepCopy(of file: URL, now: Date = Date()) -> URL? {
        guard let bytes = try? Data(contentsOf: file) else { return nil }
        let folder = file.deletingLastPathComponent(), prefix = file.lastPathComponent + marker
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            let copy = folder.appendingPathComponent(name)
            if (try? copy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == bytes.count, (try? Data(contentsOf: copy)) == bytes { return copy }
        }
        let stamp = String(Int(now.timeIntervalSince1970))
        for attempt in 0..<100 {
            let copy = folder.appendingPathComponent(prefix + stamp + (attempt == 0 ? "" : "-\(attempt)"))
            let fd = Darwin.open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 { if errno == EEXIST { continue }; return nil }
            let written = write(fd, bytes) && fsync(fd) == 0
            let closed = Darwin.close(fd) == 0
            guard written, closed else { unlink(copy.path); return nil }
            NSLog("[saved files] %@ could not be read in full; its exact contents are kept in %@", file.lastPathComponent, copy.lastPathComponent)
            return copy
        }
        return nil
    }

    /// Plain words for the person: which saved list could not be read, and where its old contents are.
    public static func sentence(_ what: String, copy: URL?) -> String {
        guard let copy else { return "\(what) could not be read, so it is left exactly as it is and nothing is saved over it until it can be read again." }
        return "\(what) could not be read in full. Its old contents are kept unchanged in \(copy.lastPathComponent), in the same folder."
    }

    private static func write(_ fd: Int32, _ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { return false }
                offset += amount
            }
            return true
        }
    }
}
