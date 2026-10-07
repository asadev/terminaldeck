import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// Destination policy is reconsulted for every chunk and commit. A guest folder
/// grant withdrawn mid-transfer cannot keep writing through an old open handle.
public actor BackendUploadReceive {
    public typealias Destination = @Sendable (BackendRemoteHostContext, String?) async throws -> URL?
    private let destination: Destination
    private var active: [UUID: Sink] = [:]
    private var opening: [UUID: UUID] = [:]
    public init(destination: @escaping Destination) { self.destination = destination }
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "upload", messageTypes: ["upload.begin", "upload.data", "upload.end", "upload.cancel"], policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "upload-closed", message: "The native upload receiver stopped") }
            return try await self.handle(message, context: context)
        }
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        let id = message["id"].string!
        switch message.type {
        case "upload.begin":
            guard active[context.connectionID] == nil, opening[context.connectionID] == nil else { return [try failed(id, "This phone is already sending a file. Wait for it to finish, or cancel it.")] }
            let token = UUID(); opening[context.connectionID] = token
            do {
                guard let folder = try await destination(context, message["dir"].string) else { if opening[context.connectionID] == token { opening[context.connectionID] = nil }; return [try failed(id, "That machine will not put a file in that folder.")] }
                guard opening[context.connectionID] == token else { return [] }
                let sink = try Sink(directory: folder, id: id, suggestedName: message["name"].string!, size: Int64(message["size"].number!), requestedDirectory: message["dir"].string)
                opening[context.connectionID] = nil; active[context.connectionID] = sink
                return [try .init(.uploadReady, fields: [.init("id", .string(id)), .init("path", .string(sink.path))])]
            } catch { if opening[context.connectionID] == token { opening[context.connectionID] = nil }; return [try failed(id, "Could not create a file for that. Check that the downloads folder is writable.")] }
        case "upload.cancel":
            opening[context.connectionID] = nil
            if active[context.connectionID]?.id == id { active.removeValue(forKey: context.connectionID)?.discard() }
            return [try failed(id, "Cancelled on the phone.")]
        case "upload.data", "upload.end":
            guard let sink = active[context.connectionID], sink.id == id else { return message.type == "upload.data" ? [] : [try failed(id, "There is no upload with that id.")] }
            do {
                guard let permitted = try await destination(context, sink.requestedDirectory), permitted.standardizedFileURL.resolvingSymlinksInPath().path == sink.directory.path,
                      active[context.connectionID] === sink else { throw NativeRPCError(code: "upload-denied", message: "The destination grant was withdrawn") }
                if message.type == "upload.data" {
                    guard let bytes = Data(base64Encoded: message["data"].string!), bytes.count <= 24576 else { throw NativeRPCError.malformed("The upload chunk is invalid") }
                    if bytes.isEmpty { return [] }
                    try sink.write(bytes)
                    return [try .init(.uploadAck, fields: [.init("id", .string(id)), .init("bytes", .number(Double(bytes.count)))])]
                }
                let expected = message["sha256"].string!
                let hash = try sink.commit(expectedDigest: expected)
                active[context.connectionID] = nil
                return [try .init(.uploadDone, fields: [.init("id", .string(id)), .init("path", .string(sink.path)), .init("bytes", .number(Double(sink.size))), .init("sha256", .string(hash))])]
            } catch {
                if active[context.connectionID] === sink { active.removeValue(forKey: context.connectionID)?.discard() }
                // uploads.ts:310-390: each way an upload can end has its own sentence for the phone.
                let code = (error as? NativeRPCError)?.code ?? ""
                if message.type == "upload.data" {
                    return [try failed(id, code == "upload-size" ? "That file sent more bytes than it said it would. Nothing was saved." : "Writing that file stopped part way through. Nothing was saved.")]
                }
                switch code {
                case "upload-size": return [try failed(id, "That upload ended early — \(sink.received) of \(sink.size) bytes arrived. Nothing was saved.")]
                case "upload-checksum": return [try failed(id, "That file arrived corrupted — the checksum does not match. Nothing was saved.")]
                default: return [try failed(id, "Could not move that file into the downloads folder. Nothing was saved.")]
                }
            }
        default: throw NativeRPCError.invalidArguments("This is not an upload message")
        }
    }
    public func close(connectionID: UUID) { opening[connectionID] = nil; active.removeValue(forKey: connectionID)?.discard() }
    public func stop() { opening = [:]; for sink in active.values { sink.discard() }; active = [:] }
    private func failed(_ id: String, _ message: String) throws -> BackendRemoteServerMessage { try .init(.uploadFailed, fields: [.init("id", .string(id)), .init("message", .string(message))]) }

    private final class Sink: @unchecked Sendable {
        let directory: URL
        let id: String
        let name: String
        let path: String
        let size: Int64
        let requestedDirectory: String?
        private let directoryFD: Int32
        private var fd: Int32
        private var taken: Int64 = 0
        var received: Int64 { taken }
        private var digest = SHA256()
        private var finished = false
        private let partialName: String
        init(directory: URL, id: String, suggestedName: String, size: Int64, requestedDirectory: String?) throws {
            self.directory = directory.standardizedFileURL.resolvingSymlinksInPath(); self.id = id; self.size = size; self.requestedDirectory = requestedDirectory
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let root = Darwin.open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw BackendRemoteTrustStorage.filesystem("open upload directory") }
            var picked: (String, Int32)?
            let proposed = BackendUploadNames.safeName(suggestedName)
            for candidate in BackendUploadNames.variants(proposed) {
                let partial = candidate + ".part"
                let handle = Darwin.openat(root, partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if handle < 0 { if errno == EEXIST { continue }; Darwin.close(root); throw BackendRemoteTrustStorage.filesystem("reserve upload temporary file") }
                var info = stat()
                if fstatat(root, candidate, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    Darwin.close(handle); unlinkat(root, partial, 0); continue
                }
                if errno != ENOENT { Darwin.close(handle); unlinkat(root, partial, 0); Darwin.close(root); throw BackendRemoteTrustStorage.filesystem("check upload destination") }
                picked = (candidate, handle); break
            }
            guard let picked else { Darwin.close(root); throw NativeRPCError(code: "upload-name", message: "Every variant of that file name is taken") }
            directoryFD = root; fd = picked.1; name = picked.0; partialName = picked.0 + ".part"; path = self.directory.appendingPathComponent(picked.0).path
        }
        func write(_ bytes: Data) throws {
            guard !finished, taken + Int64(bytes.count) <= size else { throw NativeRPCError(code: "upload-size", message: "The upload sent too many bytes") }
            try bytes.withUnsafeBytes { data in
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw BackendRemoteTrustStorage.filesystem("write upload chunk") }
                    offset += count
                }
            }
            taken += Int64(bytes.count); digest.update(data: bytes)
        }
        func commit(expectedDigest: String) throws -> String {
            guard !finished, taken == size else { throw NativeRPCError(code: "upload-size", message: "The upload ended before every byte arrived") }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard hash == expectedDigest.lowercased() else { throw NativeRPCError(code: "upload-checksum", message: "The upload checksum differs") }
            var opened = stat(), current = stat()
            guard fstat(directoryFD, &opened) == 0, stat(directory.path, &current) == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { throw NativeRPCError(code: "upload-directory", message: "The upload directory moved or changed") }
            guard Darwin.fsync(fd) == 0 else { throw BackendRemoteTrustStorage.filesystem("flush upload") }
            let result = Darwin.close(fd); fd = -1
            guard result == 0, linkat(directoryFD, partialName, directoryFD, name, 0) == 0 else { throw BackendRemoteTrustStorage.filesystem("commit upload without replacing another file") }
            unlinkat(directoryFD, partialName, 0); finished = true
            return hash
        }
        func discard() { guard !finished else { return }; finished = true; if fd >= 0 { Darwin.close(fd); fd = -1 }; unlinkat(directoryFD, partialName, 0) }
        deinit { discard(); Darwin.close(directoryFD) }
    }
}

public enum BackendUploadNames {
    public static func safeName(_ suggested: String) -> String {
        let tail = suggested.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        var name = String(String.UnicodeScalarView(tail.unicodeScalars.map { scalar in
            scalar.value < 32 || scalar.value == 127 || "<>:\"|?*/\\".unicodeScalars.contains(scalar) ? "_" : scalar
        })).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "file" }
        let base = (name as NSString).deletingPathExtension
        if base.range(of: #"^(con|prn|aux|nul|com[1-9]|lpt[1-9])$"#, options: [.regularExpression, .caseInsensitive]) != nil { name = "_" + name }
        return cap(name, maximum: 255)
    }
    public static func variants(_ name: String) -> [String] {
        let ext = (name as NSString).pathExtension, suffix = ext.isEmpty ? "" : "." + ext, stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return [name] + (2...99).map { cap(stem + " (\($0))" + suffix, maximum: 255) }
    }
    private static func cap(_ name: String, maximum: Int) -> String {
        if name.utf8.count <= maximum { return name }
        let ext = (name as NSString).pathExtension, suffix = ext.isEmpty ? "" : "." + ext
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        var output = "", used = 0
        let keep = max(0, maximum - suffix.utf8.count)
        for scalar in stem.unicodeScalars { let cost = String(scalar).utf8.count; if used + cost > keep { break }; output.unicodeScalars.append(scalar); used += cost }
        if output.isEmpty {
            for scalar in name.unicodeScalars { let cost = String(scalar).utf8.count; if used + cost > maximum { break }; output.unicodeScalars.append(scalar); used += cost }
            return output.isEmpty ? "file" : output
        }
        return output + suffix
    }
}
