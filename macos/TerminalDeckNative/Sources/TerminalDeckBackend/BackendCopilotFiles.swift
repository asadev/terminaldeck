import Foundation
import TerminalDeckNativeCore

/// Source copilot-files.ts. A device sends a closed ID, never a filesystem path.
/// The selected folder is resolved anew for each operation, including writes.
public struct BackendCopilotFilesHere: BackendCopilotFilesProviding, Sendable {
    public static let maxBytes = 32 * 1024
    public static let maxRows = 200
    public static let maxPurpose = 240
    public static let memoryPrefix = "memory:"
    public static let fromPhone = "a paired device"
    private let paths: @Sendable () async throws -> BackendCopilotPaths
    public init(paths: @escaping @Sendable () async throws -> BackendCopilotPaths) { self.paths = paths }

    public func list() async throws -> [NativeRPCValue] {
        let paths = try await paths()
        var stats: [String: BackendCopilotStartupFile] = [:]
        for file in BackendCopilotHome.layerFiles(paths) + BackendCopilotHome.startupFiles(paths, list: { _ in [] }) { stats[file.path] = file }
        let fixed = try ["yours", "contract", "composed", "folder"].map { id -> NativeRPCValue in
            let path = try Self.fixedPath(paths, id), file = stats[path], size = file?.size
            let writable = (id == "yours" || id == "folder") && (size == nil || size! <= Self.maxBytes)
            return .object([.init("id", .string(id)), .init("name", .string(Self.baseName(path))),
                .init("purpose", .string(Self.display(file?.purpose ?? ""))), .init("owner", .string(file?.owner ?? "app")),
                .init("exists", .bool(file?.exists ?? false)), .init("size", BackendCopilotStorageIO.optional(size)),
                .init("modifiedAt", BackendCopilotStorageIO.optional(file?.modifiedAt)), .init("writable", .bool(writable))])
        }
        let facts = BackendCopilotInspect.readMemory(paths).facts.prefix(max(0, Self.maxRows - fixed.count))
        return fixed + facts.map { fact in
            .object([.init("id", .string(Self.memoryPrefix + fact.name)), .init("name", .string(Self.display(fact.name))),
                .init("purpose", .string(Self.display(fact.description ?? (fact.index ? "Memory index" : "Memory")))),
                .init("owner", .string("folder")), .init("exists", .bool(true)), .init("size", .number(fact.bytes)),
                .init("modifiedAt", .number(fact.modifiedAt)), .init("writable", .bool(fact.bytes <= Double(Self.maxBytes)))])
        }
    }
    public func read(_ target: BackendRemoteProtocol.CopilotFileTarget) async throws -> BackendCopilotRemoteFileText {
        let paths = try await paths(), raw = try Self.rawRead(paths, target)
        guard raw.error == nil else { return .init(text: "", error: raw.error) }
        let bytes = raw.text.utf8.count
        if bytes > Self.maxBytes {
            return .init(text: "", error: "That file is \(Self.kilobytes(bytes)) KB, and the most that can be sent to a device is 32 KB. Open it on the computer running \(BackendSharedBrand.assistant).")
        }
        return raw
    }
    public func write(_ target: BackendRemoteProtocol.CopilotFileTarget, text: String) async throws -> BackendCopilotRemoteFileWrite {
        let paths = try await paths()
        if case .layer(let id) = target {
            _ = try Self.fixedPath(paths, id)
            if id == "contract" || id == "composed" {
                return .init(ok: false, error: "That file is written by the app every time \(BackendSharedBrand.assistant) starts, so there is nothing to save. Edit its instructions instead — this one is composed from them.")
            }
        }
        if let existing = try Self.onDisk(paths, target), existing > Self.maxBytes {
            return .init(ok: false, error: "That file is \(Self.kilobytes(existing)) KB — larger than a device can be sent — so it cannot be saved from here. Edit it on the computer running \(BackendSharedBrand.assistant).")
        }
        switch target {
        case .memory(let name):
            let result = BackendCopilotInspect.writeMemoryFact(paths, name: .string(name), text: .string(text), where: Self.fromPhone)
            return .init(ok: result["ok"].bool == true, error: result["error"].string)
        case .layer("folder"):
            let result = BackendCopilotHome.writeFolderInstructions(paths, text: .string(text))
            guard result.saved else { return .init(ok: false, error: result.error ?? "It could not be saved just now.") }
            let detail: String
            if result.created { detail = "you created the folder’s own instructions from \(Self.fromPhone) at \(paths.root)" }
            else if let backup = result.backup { detail = "you edited the folder’s own instructions from \(Self.fromPhone); the previous file is at \(backup)" }
            else { detail = "you saved the folder’s own instructions from \(Self.fromPhone); nothing changed" }
            BackendCopilotHome.appendAction(paths, .init(action: "folder-instructions.edited", detail: detail))
            return .init(ok: true, error: nil)
        case .layer:
            let result = BackendCopilotHome.writeInstructions(paths, text: .string(text))
            guard result.saved else { return .init(ok: false, error: result.error ?? "It could not be saved just now.") }
            if let backup = result.backup {
                BackendCopilotHome.appendAction(paths, .init(action: "instructions.edited", detail: "you edited its instructions from \(Self.fromPhone); the previous file is at \(backup)"))
            }
            return .init(ok: true, error: nil)
        }
    }
    public func reset() async throws -> BackendCopilotRemoteFileWrite {
        let paths = try await paths(), result = BackendCopilotHome.resetInstructions(paths)
        if let error = result.error { return .init(ok: false, error: error) }
        let detail = "the instructions this build ships were restored from \(Self.fromPhone)" + (result.backup.map { "; the previous file is at \($0)" } ?? "")
        BackendCopilotHome.appendAction(paths, .init(action: "instructions.reset", detail: detail))
        return .init(ok: true, error: nil)
    }
    public func forget(_ name: String) async throws -> BackendCopilotRemoteFileWrite {
        let result = BackendCopilotInspect.deleteMemoryFact(try await paths(), name: .string(name), where: Self.fromPhone)
        return .init(ok: result["ok"].bool == true, error: result["error"].string)
    }
    private static func rawRead(_ paths: BackendCopilotPaths, _ target: BackendRemoteProtocol.CopilotFileTarget) throws -> BackendCopilotRemoteFileText {
        switch target {
        case .memory(let name):
            let read = BackendCopilotInspect.readMemoryFact(paths, name: .string(name))
            if read["ok"].bool != true { return .init(text: "", error: read["error"].string) }
            if read["truncated"].bool == true { return .init(text: "", error: "That memory is too large to open on a device. Open it on the computer.") }
            return .init(text: read["text"].string ?? "", error: nil)
        case .layer(let id):
            let path = try fixedPath(paths, id)
            if id == "yours" {
                let read = BackendCopilotHome.readInstructions(paths)
                return .init(text: read.ok ? (read.text ?? "") : "", error: read.error)
            }
            if id == "folder" {
                let read = BackendCopilotHome.readFolderInstructions(paths)
                return .init(text: read.text, error: read.error)
            }
            let read = BackendCopilotLayer.readFile(path)
            return .init(text: read.text ?? "", error: read.text == nil ? read.error : nil)
        }
    }
    private static func onDisk(_ paths: BackendCopilotPaths, _ target: BackendRemoteProtocol.CopilotFileTarget) throws -> Int? {
        switch target {
        case .memory(let name): return BackendCopilotInspect.readMemory(paths).facts.first(where: { $0.name == name }).map { Int($0.bytes) }
        case .layer(let id): return BackendCopilotStorageIO.bytes(try fixedPath(paths, id), regularOnly: true)
        }
    }
    private static func fixedPath(_ paths: BackendCopilotPaths, _ id: String) throws -> String {
        switch id {
        case "yours": return paths.layer.yours
        case "contract": return paths.layer.contract
        case "composed": return paths.layer.composed
        case "folder": return BackendCopilotHome.folderInstructions(paths)
        default: throw NativeRPCError(code: "invalid-arguments", message: "That is not a Hoot file.")
        }
    }
    private static func display(_ text: String) -> String {
        BackendSharedText.prefix(text.replacingOccurrences(of: #"[\u0000-\u001f\u007f-\u009f]"#, with: "", options: .regularExpression), maxPurpose)
    }
    private static func baseName(_ path: String) -> String { path.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? path }
    private static func kilobytes(_ bytes: Int) -> Int { Int(floor(Double(bytes) / 1024 + 0.5)) }
}
