import Foundation
import Darwin
import TerminalDeckNativeCore

enum BackendRemoteServeText {
    static let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    static func words(_ value: String) -> [String] { value.components(separatedBy: whitespace).filter { !$0.isEmpty } }
}
extension String { var remoteServeTrimmed: String { trimmingCharacters(in: BackendRemoteServeText.whitespace) } }

/// Mac half of remote/secret-file.ts. Windows ACL operations do not apply on Mac.
/// Explicit calls only: constructing a service never writes a secret file.
public enum BackendRemoteServeSecretFile {
    private static let writer = NSLock()
    public static func write(directory: URL, file: URL, contents: Data) throws {
        writer.lock(); defer { writer.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = file.path + ".\(getpid()).tmp"
        _ = Darwin.unlink(temporary)
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("create secret temporary file") }
        var opened = true
        defer { if opened { Darwin.close(fd) }; Darwin.unlink(temporary) }
        try contents.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("write secret file") }
                written += count
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw failure("flush secret file") }
        let closed = Darwin.close(fd); opened = false
        guard closed == 0, Darwin.chmod(temporary, 0o600) == 0 else { throw failure("protect secret temporary file") }
        guard Darwin.rename(temporary, file.path) == 0 else { throw failure("replace secret file") }
        guard Darwin.chmod(file.path, 0o600) == 0 else { throw failure("protect secret file") }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parent >= 0 { _ = Darwin.fsync(parent); Darwin.close(parent) }
    }
    public static func write(_ value: NativeRPCValue, file: URL) throws {
        var contents = try value.encodedJSON(pretty: true); contents.append(0x0a)
        try write(directory: file.deletingLastPathComponent(), file: file, contents: contents)
    }
    /// The source's protect-on-read path is Windows-only and a no-op on Mac.
    public static func protectExisting(directory: URL, file: URL) {}
    private static func failure(_ action: String) -> NativeRPCError {
        .init(code: "unavailable", message: "Could not \(action): \(String(cString: strerror(errno)))")
    }
}
