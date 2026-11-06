import CryptoKit
import Darwin
import Foundation
import TerminalDeckNativeCore

/// Reads only the content-addressed image named by an authoritative tool result.
public enum BackendChatStoredMedia {
    public static let maximumBytes = 4 * 1024 * 1024
    public static func hasImages(_ value: NativeRPCValue) -> Bool {
        if value["dataFile"].string != nil { return true }
        if let elements = value.elements { return elements.contains(where: hasImages) }
        return value.fields?.contains(where: { hasImages($0.value) }) == true
    }
    public static func result(store: BackendHootChatStore, rowID: String) async throws -> NativeRPCValue {
        var events: [HootChatEvent] = [], cursor: Int? = 0
        for _ in 0..<2000 {
            let page = await store.snapshot(after: cursor, limit: 500)
            events += try (page["events"].elements ?? []).map { try HootChatEvent(wire: $0) }
            if page["hasMore"].bool != true { break }
            guard let next = page["cursor"].number, next > Double(cursor ?? 0), next < Double(Int.max / 2) else {
                throw NativeRPCError(code: "unavailable", message: "The tool's complete source history could not be read.")
            }
            cursor = Int(next)
        }
        guard let row = HootChatProjection.rows(events).first(where: { $0.id == rowID }),
              [.toolCall, .toolResult].contains(row.kind), row.value.has("output") else {
            throw NativeRPCError(code: "access-denied", message: "That tool result is not in this source chat.")
        }
        return try restore(BackendChatMCPApps.toolResult(row.value["output"]), historyFile: await store.historyFileURL)
    }
    public static func restore(_ result: NativeRPCValue, historyFile: URL) throws -> NativeRPCValue {
        var remaining = maximumBytes
        func walk(_ value: NativeRPCValue, depth: Int) throws -> NativeRPCValue {
            guard depth <= 20 else { throw NativeRPCError(code: "too-large", message: "The tool result is nested too deeply.") }
            if let values = value.elements { return .array(try values.map { try walk($0, depth: depth + 1) }) }
            guard let fields = value.fields else { return value }
            var restored = NativeRPCValue.object(try fields.map { .init($0.key, try walk($0.value, depth: depth + 1)) })
            if let reference = value["dataFile"].string,
               value["type"].string == "image" || (value["mimeType"].string?.hasPrefix("image/") ?? false) {
                let bytes = try read(reference, historyFile: historyFile, remaining: remaining)
                remaining -= bytes.count
                restored = restored.setting("data", .string(bytes.base64EncodedString()))
            }
            return restored
        }
        return try walk(result, depth: 0)
    }
    private static func read(_ reference: String, historyFile: URL, remaining: Int) throws -> Data {
        guard reference.range(of: #"^media/[a-f0-9]{64}\.(png|jpg|gif|webp|bin)$"#, options: .regularExpression) != nil else {
            throw NativeRPCError(code: "access-denied", message: "The recorded image name is invalid.")
        }
        let base = historyFile.deletingLastPathComponent().resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("media", isDirectory: true)
        let file = base.appendingPathComponent(reference)
        guard folder.resolvingSymlinksInPath().path == folder.path,
              file.resolvingSymlinksInPath().path == file.path else {
            throw NativeRPCError(code: "access-denied", message: "The recorded image must stay in this chat's media folder.")
        }
        let mediaDescriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard mediaDescriptor >= 0 else { throw NativeRPCError(code: "unavailable", message: "The recorded media folder could not be read.") }
        defer { close(mediaDescriptor) }
        let descriptor = openat(mediaDescriptor, file.lastPathComponent, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NativeRPCError(code: "unavailable", message: "The recorded image could not be read.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= remaining else {
            throw NativeRPCError(code: "too-large", message: "The recorded image is empty or too large.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Int(info.st_size) + 1) ?? Data()
        guard data.count == Int(info.st_size),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.deletingPathExtension().lastPathComponent else {
            throw NativeRPCError(code: "access-denied", message: "The recorded image does not match its content name.")
        }
        return data
    }
}
