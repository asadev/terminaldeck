import Foundation
import Darwin
import TerminalDeckNativeCore

/// Reads an actual authorized descriptor; parent replacement cannot reopen a
/// different file after the authority check or block on a FIFO.
public enum BackendCompositionFileBytes {
    public static func read(_ path: String, authority: BackendFilesystemAuthority, context: NativeRPCContext,
                            maximumBytes: Int) async throws -> Data {
        let approved = try await authority.authorize(path, context: context)
        let descriptor = Darwin.open(approved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NativeRPCError(code: "file-read", message: "The authorized file could not be opened.") }
        defer { Darwin.close(descriptor) }
        var info = stat(), actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes,
              actual.withUnsafeMutableBufferPointer({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else {
            throw NativeRPCError(code: "file-read", message: "The attachment is not a regular bounded file.")
        }
        let heldPath = String(cString: actual)
        let current = try await authority.authorize(heldPath, context: context)
        guard current.standardizedFileURL.path == approved.standardizedFileURL.path else {
            throw NativeRPCError(code: "file-read", message: "The attachment moved outside its authorized path.")
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, bytes.count + max(count, 0) <= maximumBytes else {
                throw NativeRPCError(code: "file-read", message: "The attachment changed or exceeded its read limit.")
            }
            if count == 0 { return bytes }; bytes.append(contentsOf: buffer.prefix(count))
        }
    }
}
