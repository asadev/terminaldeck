import Foundation
import Darwin
import TerminalDeckNativeCore

/// Task-private files, not another filesystem owner. Source paths must pass
/// the existing real filesystem/grant authority on every copy; private file
/// names come from validated local metadata and stay under task-files.
public struct BackendTaskAttachments: Sendable {
    public let persistence: BackendTaskPersistence
    private let authorizeSource: @Sendable (String) async throws -> URL
    public init(persistence: BackendTaskPersistence, authorizeSource: @escaping @Sendable (String) async throws -> URL) { self.persistence = persistence; self.authorizeSource = authorizeSource }
    public func upload(_ task: BackendTaskRecord, name: String, mime: String?, bytes: Data, actor: String) throws -> NativeRPCValue {
        try check(name, size: bytes.count); try persistence.writable()
        guard persistence.ownership == .exclusive else { throw BackendSessionFailure.missingCapability("actual on-disk private task file storage") }
        guard UUID(uuidString: task.value["externalTaskId"].string ?? "") != nil else { throw NativeRPCError.invalidArguments("The local task's file directory is invalid") }
        let id = UUID().uuidString.lowercased(), filename = id + "-" + safeName(name), external = task.value["externalTaskId"].string!
        let directory = persistence.directory.appendingPathComponent(external)
        let owned = try BackendTaskPersistence(directory: directory, ownership: persistence.ownership)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard NativeTranscriptPaths.isDescendant(NativeTranscriptPaths.canonical(directory.path), of: NativeTranscriptPaths.canonical(persistence.directory.path)) else { throw NativeRPCError(code: "path-escape", message: "The task file directory left its private store") }
        try owned.writeBytes(filename, data: bytes, replace: false)
        return BackendTaskValues.object([("id", .string(id)), ("kind", .string("upload")), ("fileName", .string(BackendCrmInlineFiles.slice(URL(fileURLWithPath: name).lastPathComponent.isEmpty ? "file" : URL(fileURLWithPath: name).lastPathComponent, 0, 200))), ("mimeType", mimeOf(name, given: mime).map(NativeRPCValue.string) ?? .null), ("sizeBytes", .number(Double(bytes.count))), ("file", .string(external + "/" + filename)), ("documentId", .null), ("uploadedBy", .string(actor)), ("at", .number(BackendTaskValues.time()))])
    }
    public func copy(_ task: BackendTaskRecord, source: String, actor: String) async throws -> NativeRPCValue {
        let url = try await authorizeSource(source), target = BackendFilesystemAuthority.Target(root: url.deletingLastPathComponent(), path: url, relative: url.lastPathComponent)
        let fd = try BackendFilesystemAuthority.openStable(target); defer { Darwin.close(fd) }; var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeRPCError.invalidArguments("“\(url.lastPathComponent)” could not be read.") }
        try check(url.lastPathComponent, size: Int(info.st_size)); let bytes = try read(fd, maximum: BackendCrmTaskRules.maxUploadBytes)
        return try upload(task, name: url.lastPathComponent, mime: nil, bytes: bytes, actor: actor)
    }
    public func view(_ row: NativeRPCValue) throws -> NativeRPCValue {
        var preview = NativeRPCValue.null
        if let mime = row["mimeType"].string, ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"].contains(mime), let file = row["file"].string, (row["sizeBytes"].number ?? 0) <= 4 * 1024 * 1024 {
            if let fd = try? open(file) { defer { Darwin.close(fd) }; if let data = try? read(fd, maximum: 4 * 1024 * 1024) { preview = .string("data:" + mime + ";base64," + data.base64EncodedString()) } }
        }
        return BackendTaskValues.object([("id", row["id"]), ("kind", row["kind"]), ("fileName", row["fileName"]), ("mimeType", row["mimeType"]), ("sizeBytes", row["sizeBytes"]), ("documentId", row["kind"].string == "document" ? row["documentId"] : .null), ("storagePath", row["kind"].string == "upload" ? row["file"] : .null), ("uploadedBy", row["uploadedBy"]), ("createdAt", .string(BackendTaskOutbox.iso(row["at"].number ?? 0))), ("previewUrl", preview)])
    }
    public func path(_ relative: String) throws -> String {
        let fd = try open(relative); defer { Darwin.close(fd) }; var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { throw NativeRPCError(code: "filesystem", message: "The task file could not be located") }; return String(cString: buffer)
    }
    public func remove(_ relative: String) throws {
        try persistence.writable(); let path = try self.path(relative)
        guard unlink(path) == 0 else { if errno == ENOENT { return }; throw NativeRPCError(code: "filesystem", message: "The unused task file could not be removed") }
        _ = rmdir(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
    private func open(_ relative: String) throws -> Int32 {
        guard !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator: "/").contains("..") else { throw NativeRPCError.invalidArguments("The task file path is invalid") }
        let root = persistence.directory, file = root.appendingPathComponent(relative).standardizedFileURL
        guard NativeTranscriptPaths.isDescendant(file.path, of: root.path) else { throw NativeRPCError(code: "path-escape", message: "The task file left its private store") }
        return try BackendFilesystemAuthority.openStable(.init(root: root, path: file, relative: relative))
    }
    private func read(_ fd: Int32, maximum: Int) throws -> Data {
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum else { throw NativeRPCError.invalidArguments("The task file is too large or no longer a regular file") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true { try Task.checkCancellation(); let n = Darwin.read(fd, &buffer, buffer.count); if n == 0 { return data }; if n < 0 { if errno == EINTR { continue }; throw NativeRPCError(code: "filesystem", message: "The task file could not be read") }; guard data.count + n <= maximum else { throw NativeRPCError.invalidArguments("The task file grew beyond its size limit") }; data.append(contentsOf: buffer.prefix(n)) }
    }
    private func check(_ name: String, size: Int) throws { if case .refused(let error, _) = BackendCrmTaskRules.checkUpload(name: name, size: Double(size)) { throw NativeRPCError.invalidArguments(error) } }
    private func safeName(_ name: String) -> String { let clean = URL(fileURLWithPath: name).lastPathComponent.replacingOccurrences(of: #"[^\w.\- ()]+"#, with: "_", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines); return BackendCrmInlineFiles.slice(clean.isEmpty ? "file" : clean, 0, 120) }
    private func mimeOf(_ name: String, given: String?) -> String? {
        if let given, !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return BackendCrmInlineFiles.slice(given.trimmingCharacters(in: .whitespacesAndNewlines), 0, 120) }
        let map = ["pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp", "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff", "tiff": "image/tiff", "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "rtf": "application/rtf", "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "ppt": "application/vnd.ms-powerpoint", "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation", "odt": "application/vnd.oasis.opendocument.text", "ods": "application/vnd.oasis.opendocument.spreadsheet", "odp": "application/vnd.oasis.opendocument.presentation", "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "ogg": "audio/ogg", "mp4": "video/mp4", "mov": "video/quicktime"]
        return map[BackendCrmTaskRules.fileExtension(name)]
    }
}

public struct BackendTaskDetailDesktop: Sendable {
    public let chooseFiles: @Sendable () async throws -> [String]
    public let chooseFolder: @Sendable () async throws -> String?
    public let openPath: @Sendable (String) async throws -> String
    public init(chooseFiles: @escaping @Sendable () async throws -> [String], chooseFolder: @escaping @Sendable () async throws -> String?, openPath: @escaping @Sendable (String) async throws -> String) { self.chooseFiles = chooseFiles; self.chooseFolder = chooseFolder; self.openPath = openPath }
}
