import Foundation
import Darwin
import TerminalDeckNativeCore

/// A bounded read of one artifact already named by the authorized project index.
/// No listener, file edit or preview-server grant is created by reading it.
public enum BackendWEBArtifactBytes {
    public static let maximumChunk = 32_768

    public static func read(authority: BackendFilesystemAuthority, root: String, relative: String,
                            at: Int, maximum: Int, context: NativeRPCContext) async throws -> NativeRPCValue {
        try context.require("filesystem.read")
        guard at >= 0, maximum > 0, maximum <= maximumChunk, ArtifactRules.isArtifact(relative) else {
            throw NativeRPCError.invalidArguments("Choose a supported artifact and a bounded part of the file.")
        }
        _ = try await authority.authorize(root, context: context)
        let target: BackendFilesystemAuthority.Target
        if ArtifactRules.isOutside(relative) {
            // Outside files are still checked against this caller's own file grants.
            // Resolve from their parent so symlink swaps are refused by openStable.
            let file = try await authority.authorize(relative, context: context)
            target = try await authority.resolve(root: file.deletingLastPathComponent().path,
                                                 relative: file.lastPathComponent, context: context)
        } else {
            target = try await authority.resolve(root: root, relative: relative, context: context)
        }
        let fd = try BackendFilesystemAuthority.openStable(target)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw NativeRPCError(code: "artifact-unavailable", message: "That artifact is no longer a regular file.")
        }
        let total = Int(info.st_size)
        guard at <= total else { throw NativeRPCError.invalidArguments("That part is past the end of the artifact.") }
        var bytes = [UInt8](repeating: 0, count: min(maximum, total - at))
        let count = bytes.isEmpty ? 0 : bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, off_t(at)) }
        guard count >= 0 else { throw NativeRPCError(code: "artifact-unavailable", message: "That artifact could not be read.") }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            throw NativeRPCError(code: "artifact-changed", message: "The artifact changed while it was being read. Open it again.")
        }
        return .object([.init("name", .string(target.path.lastPathComponent)), .init("mime", .string(mime(target.path.pathExtension))),
            .init("encoding", .string("base64")), .init("data", .string(Data(bytes.prefix(count)).base64EncodedString())),
            .init("offset", .number(Double(at))), .init("next", .number(Double(at + count))),
            .init("total", .number(Double(total))), .init("done", .bool(at + count >= total))])
    }

    static func mime(_ suffix: String) -> String {
        switch suffix.lowercased() {
        case "html", "htm", "xhtml": return "text/html"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}
