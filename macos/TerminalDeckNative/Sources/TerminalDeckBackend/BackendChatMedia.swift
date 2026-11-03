import CryptoKit
import Darwin
import Foundation
import TerminalDeckNativeCore

/// Pictures inside a chat's records: a tool that read an image file, a screenshot a tool returned. The AI's stream
/// carries each one as inline base64, twice (the content block and the tool's own result), about 1.3 MB per
/// picture. Nothing draws them from there, and a chat with a few of them outgrew every limit on its way to the
/// window and the phones (28 Oct, Asad's 12 MB chat). What leaves the chat engine carries a small stand-in instead:
/// the picture's type and size, never its bytes. The conversation itself is untouched.
public enum BackendChatMedia {
    /// A string this long that is all base64 is a picture's bytes, not text anyone reads.
    static let inlineLimit = 16 * 1024
    static let maximumDepth = 16

    /// The snapshot with every picture's bytes replaced by a stand-in. Unchanged (the same value) when it has none.
    public static func slim(_ snapshot: NativeRPCValue) -> NativeRPCValue {
        guard let events = snapshot["events"].elements, events.contains(where: carriesPicture) else { return snapshot }
        return snapshot.setting("events", .array(events.map(slimEvent)))
    }
    /// One event with its pictures' bytes replaced; others unchanged.
    public static func slimEvent(_ event: NativeRPCValue) -> NativeRPCValue {
        guard carriesPicture(event) else { return event }
        return event.setting("value", strip(event["value"], depth: 0))
    }
    // MARK: Kept as files, next to the conversation

    /// The record with each picture kept as a file in `folder` (named by its content, so the two copies of one
    /// picture are one file) and a reference in its place: `<key>File` ("media/<sha256>.<ext>") and `<key>Omitted`
    /// (its size). The conversation file then no longer grows with picture bytes. A picture that cannot be written
    /// stays inline: nothing is ever lost.
    public static func keep(_ record: HootChatRecord, in folder: URL) -> HootChatRecord {
        guard [.toolResult, .toolCall].contains(record.kind), hasBlob(record.value, depth: 0) else { return record }
        return .init(record.kind, id: record.messageID, value: keep(record.value, folder: folder, depth: 0))
    }
    public static func keep(_ event: HootChatEvent, in folder: URL) -> HootChatEvent {
        let record = keep(event.record, in: folder)
        guard record != event.record else { return event }
        return .init(conversationID: event.conversationID, turnID: event.turnID, sequence: event.sequence, provider: event.provider, record: record, at: event.at)
    }
    private static func keep(_ value: NativeRPCValue, folder: URL, depth: Int) -> NativeRPCValue {
        guard depth <= maximumDepth else { return value }
        switch value {
        case .array(let items): return .array(items.map { keep($0, folder: folder, depth: depth + 1) })
        case .object(let fields):
            // The picture's type, from its own object ("media_type": "image/jpeg", or a "type" with a slash).
            let mime = fields.first { ["media_type", "mediaType", "mimeType", "type"].contains($0.key) && ($0.value.string?.contains("/") ?? false) }?.value.string
            var out: [NativeRPCValue.Field] = []
            for field in fields {
                if case .string(let text) = field.value, isBlob(text), let name = file(text, mime: mime, folder: folder) {
                    out.append(.init(field.key, .string("")))
                    out.append(.init(field.key + "File", .string("media/" + name.name)))
                    out.append(.init(field.key + "Omitted", .number(Double(name.bytes))))
                } else {
                    out.append(.init(field.key, keep(field.value, folder: folder, depth: depth + 1)))
                }
            }
            return .object(out)
        default: return value
        }
    }
    private static func file(_ base64: String, mime: String?, folder: URL) -> (name: String, bytes: Int)? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext: String
        switch (mime ?? "").lowercased() {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "application/pdf": ext = "pdf"
        default: ext = "bin"
        }
        let name = digest + "." + ext, url = folder.appendingPathComponent(name)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == data.count { return (name, data.count) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // On the disk (the file and its folder) before any conversation file can name it (Reviewer 28 Oct, MUST).
            try durableWrite(data, to: url)
            return (name, data.count)
        } catch { return nil }
    }

    // MARK: Writes that survive a power cut

    /// `data` at `url`: a temporary file beside it, flushed to the disk (F_FULLFSYNC), renamed over, then the folder
    /// flushed, so after a crash the file is either the old one or the whole new one. Mode 0600.
    public static func durableWrite(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString.prefix(8) + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NativeRPCError(code: "write-failed", message: "Could not write \(url.lastPathComponent).") }
        var failed = false
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { failed = true; break }
                offset += written
            }
        }
        if !failed, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { failed = true }
        close(fd)
        guard !failed, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw NativeRPCError(code: "write-failed", message: "Could not write \(url.lastPathComponent).")
        }
        syncFolder(folder)
    }
    /// The folder's own entries (a new or renamed file in it) on the disk.
    public static func syncFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }
    /// Before the first save that takes pictures out of a conversation saved inline: the original, once, as
    /// `<file>.pre-media` (byte for byte, 0600, on the disk). An existing backup is never overwritten.
    public static func keepOriginal(_ file: URL) throws {
        let backup = file.appendingPathExtension("pre-media")
        guard !FileManager.default.fileExists(atPath: backup.path), FileManager.default.fileExists(atPath: file.path) else { return }
        try durableWrite(try Data(contentsOf: file), to: backup)
    }

    static func carriesPicture(_ event: NativeRPCValue) -> Bool {
        guard ["toolResult", "toolCall"].contains(event["kind"].string ?? "") else { return false }
        return hasBlob(event["value"], depth: 0)
    }
    static func isBlob(_ text: String) -> Bool {
        guard text.utf8.count > inlineLimit else { return false }
        return text.utf8.prefix(256).allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2F || byte == 0x3D
                || byte == 0x2D || byte == 0x5F || byte == 0x0A || byte == 0x0D
        }
    }
    static func hasBlob(_ value: NativeRPCValue, depth: Int) -> Bool {
        guard depth <= maximumDepth else { return false }
        switch value {
        case .string(let text): return isBlob(text)
        case .array(let items): return items.contains { hasBlob($0, depth: depth + 1) }
        case .object(let fields): return fields.contains { hasBlob($0.value, depth: depth + 1) }
        default: return false
        }
    }
    private static func strip(_ value: NativeRPCValue, depth: Int) -> NativeRPCValue {
        guard depth <= maximumDepth else { return value }
        switch value {
        case .array(let items): return .array(items.map { strip($0, depth: depth + 1) })
        case .object(let fields):
            var out: [NativeRPCValue.Field] = []
            for field in fields {
                if case .string(let text) = field.value, isBlob(text) {
                    // The stand-in: the bytes are gone, how many there were stays (the base64's decoded size).
                    out.append(.init(field.key, .string("")))
                    out.append(.init(field.key + "Omitted", .number(Double(text.utf8.count / 4 * 3))))
                } else {
                    out.append(.init(field.key, strip(field.value, depth: depth + 1)))
                }
            }
            return .object(out)
        default: return value
        }
    }
}
