import Foundation
import TerminalDeckNativeCore

public struct BackendMacAppHandoffFileInfo: Sendable {
    public let isDirectory: Bool
    public let modifiedMS: Double
    public init(isDirectory: Bool, modifiedMS: Double) { self.isDirectory = isDirectory; self.modifiedMS = modifiedMS }
}
/// Metadata and pasted PNG storage only. Attachment copying remains the existing transfer owner.
public protocol BackendMacAppHandoffAttachFiles: Sendable {
    func info(_ path: String) async throws -> BackendMacAppHandoffFileInfo
    func entries(_ directory: String) async throws -> [String]
    func makePasteDirectory(_ directory: String) async throws
    func writePNG(_ path: String, bytes: Data) async throws
    func removeFile(_ path: String) async throws
}
public struct BackendMacAppHandoffAttachDisk: BackendMacAppHandoffAttachFiles, Sendable {
    public init() {}
    public func info(_ path: String) throws -> BackendMacAppHandoffFileInfo {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { throw NativeRPCError(code: "filesystem", message: "The attachment path is not present.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return .init(isDirectory: directory.boolValue, modifiedMS: ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000)
    }
    public func entries(_ directory: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory) }
    public func makePasteDirectory(_ directory: String) throws { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    public func writePNG(_ path: String, bytes: Data) throws { try bytes.write(to: URL(fileURLWithPath: path)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
    public func removeFile(_ path: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard attrs[.type] as? FileAttributeType != .typeDirectory else { throw NativeRPCError(code: "filesystem", message: "A pasted-image cleanup does not remove directories.") }
        try FileManager.default.removeItem(atPath: path)
    }
}
public protocol BackendMacAppHandoffAttachClipboard: Sendable {
    func read(_ format: String) async throws -> String
    /// nil is an empty image; nonnil contains the pasteboard's PNG bytes.
    func imagePNG() async throws -> Data?
}
public protocol BackendMacAppHandoffAttachPanels: Sendable {
    func windowAvailable(_ ownerID: String) async -> Bool
    func open(ownerID: String, options: NativeRPCValue) async throws -> (cancelled: Bool, paths: [String])
}
public protocol BackendMacAppHandoffAttachBoundary: Sendable {
    func boundary(_ sessionID: String, context: NativeRPCContext) async throws -> BackendDeviceBoundary?
}
public protocol BackendMacAppHandoffBringIn: Sendable {
    func bringOne(source: String, folder: String, context: NativeRPCContext) async throws -> String?
}
/// No duplicate copying code: uses the file lane's stable, bounded, exclusive copy owner.
public struct BackendMacAppHandoffBringInTransfers: BackendMacAppHandoffBringIn, Sendable {
    public let transfers: BackendFilesystemTransfers
    public init(transfers: BackendFilesystemTransfers) { self.transfers = transfers }
    public func bringOne(source: String, folder: String, context: NativeRPCContext) async throws -> String? {
        do { return try await transfers.bringIn(source: source, folder: folder, context: context) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }
}
public enum BackendMacAppHandoffAttachRules {
    public static let pasteKeepMS: Double = 14 * 24 * 60 * 60 * 1_000
    public static func randomHex() throws -> String { try BackendAccountFiles.randomHex(bytes: 3) }
    public static let channels = ["attach:boundary", "attach:browse", "attach:inspect", "attach:paste", "attach:bring-in"]
    public static func pathFromFileURL(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("file://") else { return nil }
        let tail = String(value.dropFirst(7))
        guard tail.hasPrefix("/"), let decoded = tail.removingPercentEncoding, !decoded.isEmpty else { return nil }
        // Windows drive/UNC clipboard translation is not applicable to the native Mac app.
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }
    public static func decodeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
    public static func clipboardPaths(plist: String, fileURL: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"<string>([^<]*)</string>"#)
        let range = NSRange(plist.startIndex..<plist.endIndex, in: plist)
        let paths = expression.matches(in: plist, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: plist) else { return nil }; let value = decodeXML(String(plist[range])); return value.isEmpty ? nil : value
        }
        if !paths.isEmpty { return paths }
        return pathFromFileURL(fileURL).map { [$0] } ?? []
    }
    public static func pastedImageName(nowMS: Double, random: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: nowMS / 1_000)).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "T", with: "_")
        return "pasted-" + String(stamp.prefix(19)) + "-" + random + ".png"
    }
    public static func browseOptions(_ request: NativeRPCValue, home: String) -> NativeRPCValue {
        let mode = request["mode"].string ?? "file", folder = mode == "folder"
        var fields: [NativeRPCValue.Field] = [.init("properties", .array((folder ? ["openDirectory"] : ["openFile", "multiSelections"]).map(NativeRPCValue.string))), .init("title", .string(folder ? "Add a folder" : mode == "image" ? "Add an image" : "Add files")), .init("buttonLabel", .string("Add")), .init("defaultPath", .string((request["startIn"].string ?? "").isEmpty ? home : request["startIn"].string!))]
        let extensions = request["extensions"].elements?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        if mode == "image" && !extensions.isEmpty { fields.append(.init("filters", .array([.object([.init("name", .string("Images")), .init("extensions", .array(extensions.map(NativeRPCValue.string)))]), .object([.init("name", .string("All files")), .init("extensions", .array([.string("*")]))])]))) }; return .object(fields)
    }
    public static func bringInDirectory(_ folder: String) -> String { URL(fileURLWithPath: folder).appendingPathComponent("Terminal Deck").path }
}

public struct BackendMacAppHandoffAttachments: Sendable {
    public let files: any BackendMacAppHandoffAttachFiles
    public let clipboard: (any BackendMacAppHandoffAttachClipboard)?
    public let panels: (any BackendMacAppHandoffAttachPanels)?
    public let boundaries: any BackendMacAppHandoffAttachBoundary
    public let bringIn: any BackendMacAppHandoffBringIn
    public let pasteDirectory: String
    public let home: String
    public let nativeShell: Bool
    private let now: @Sendable () -> Double
    private let random: @Sendable () throws -> String
    public init(files: any BackendMacAppHandoffAttachFiles, clipboard: (any BackendMacAppHandoffAttachClipboard)?,
                panels: (any BackendMacAppHandoffAttachPanels)?, boundaries: any BackendMacAppHandoffAttachBoundary,
                bringIn: any BackendMacAppHandoffBringIn, pasteDirectory: String, home: String, nativeShell: Bool = true,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                random: @escaping @Sendable () throws -> String = { try BackendMacAppHandoffAttachRules.randomHex() }) {
        self.files = files; self.clipboard = clipboard; self.panels = panels; self.boundaries = boundaries; self.bringIn = bringIn
        self.pasteDirectory = pasteDirectory; self.home = home; self.nativeShell = nativeShell; self.now = now; self.random = random
    }
    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private func pick(_ path: String) async -> NativeRPCValue {
        let directory = (try? await files.info(path).isDirectory) ?? false
        return object([("path", .string(path)), ("isDirectory", .bool(directory))])
    }
    public func boundary(_ sessionID: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        let none = object([("confined", .bool(false)), ("folder", .string("")), ("projects", .array([]))])
        guard let id = sessionID.string, !id.isEmpty else { return none }
        guard let boundary = try await boundaries.boundary(id, context: context) else { return none }
        return object([("confined", .bool(true)), ("folder", .string(boundary.folder)), ("projects", .array(boundary.readOnlyProjects.map(NativeRPCValue.string)))])
    }
    public func browse(_ request: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard let panels else { throw NativeRPCError(code: "unavailable", message: "The native attachment open panel is unavailable.") }
        let hasWindow = await panels.windowAvailable(context.ownerID)
        if !nativeShell && !hasWindow { return object([("ok", .bool(false)), ("reason", .string("no-window"))]) }
        let result = try await panels.open(ownerID: context.ownerID, options: BackendMacAppHandoffAttachRules.browseOptions(request, home: home))
        if result.cancelled || result.paths.isEmpty { return object([("ok", .bool(false)), ("reason", .string("cancelled"))]) }
        var picks: [NativeRPCValue] = []; for path in result.paths { picks.append(await pick(path)) }
        return object([("ok", .bool(true)), ("picks", .array(picks))])
    }
    public func inspect(_ paths: NativeRPCValue) async -> NativeRPCValue {
        let wanted = paths.elements?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        var result: [NativeRPCValue] = []; for path in wanted { result.append(await pick(path)) }; return .array(result)
    }
    public func prune(nowMS: Double, keepMS: Double = BackendMacAppHandoffAttachRules.pasteKeepMS) async {
        guard let entries = try? await files.entries(pasteDirectory) else { return }
        for name in entries { let path = URL(fileURLWithPath: pasteDirectory).appendingPathComponent(name).path; if let info = try? await files.info(path), nowMS - info.modifiedMS > keepMS { try? await files.removeFile(path) } }
    }
    public func paste() async throws -> NativeRPCValue {
        guard let clipboard else { throw NativeRPCError(code: "unavailable", message: "The native attachment pasteboard is unavailable.") }
        let plist = (try? await clipboard.read("NSFilenamesPboardType")) ?? ""
        var paths = BackendMacAppHandoffAttachRules.clipboardPaths(plist: plist, fileURL: "")
        if paths.isEmpty { let url = (try? await clipboard.read("public.file-url")) ?? ""; paths = BackendMacAppHandoffAttachRules.clipboardPaths(plist: "", fileURL: url) }
        if !paths.isEmpty { var picks: [NativeRPCValue] = []; for path in paths { picks.append(await pick(path)) }; return object([("ok", .bool(true)), ("picks", .array(picks)), ("source", .string("files"))]) }
        guard let image = try await clipboard.imagePNG() else { return object([("ok", .bool(false)), ("reason", .string("nothing")), ("detail", .string("There is no file or image on the clipboard."))]) }
        do {
            try await files.makePasteDirectory(pasteDirectory); await prune(nowMS: now())
            let name = BackendMacAppHandoffAttachRules.pastedImageName(nowMS: now(), random: try random()), path = URL(fileURLWithPath: pasteDirectory).appendingPathComponent(name).path
            try await files.writePNG(path, bytes: image)
            return object([("ok", .bool(true)), ("picks", .array([object([("path", .string(path)), ("isDirectory", .bool(false))])])), ("source", .string("image"))])
        } catch { return object([("ok", .bool(false)), ("reason", .string("write-failed")), ("detail", .string(error.localizedDescription))]) }
    }
    public func bring(_ sessionID: NativeRPCValue, paths: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        let none = object([("brought", .array([])), ("refused", .number(0))])
        guard let id = sessionID.string, !id.isEmpty, let raw = paths.elements else { return none }
        let wanted = raw.compactMap(\.string).filter { !$0.isEmpty }; if wanted.isEmpty { return none }
        guard let boundary = try await boundaries.boundary(id, context: context), !boundary.folder.isEmpty else { return object([("brought", .array([])), ("refused", .number(Double(wanted.count)))]) }
        var brought: [NativeRPCValue] = [], refused = 0
        for path in wanted { try Task.checkCancellation(); if let landed = try await bringIn.bringOne(source: path, folder: boundary.folder, context: context) { brought.append(object([("from", .string(path)), ("path", .string(landed))])) } else { refused += 1 } }
        return object([("brought", .array(brought)), ("refused", .number(Double(refused)))])
    }
    public func register(registry: NativeChannelRegistry, ownerID: String = "mac-attachments") async throws {
        let policy: NativeChannelRegistry.Policy = { context in guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Only the app may browse, paste or bring local attachments into a session.") } }
        for channel in BackendMacAppHandoffAttachRules.channels {
            try await registry.register(channel, ownerID: ownerID, policy: policy) { context, args in
                let first = args.first ?? .missing
                switch channel {
                case "attach:boundary": return try await self.boundary(first, context: context)
                case "attach:browse": return try await self.browse(first, context: context)
                case "attach:inspect": return await self.inspect(first)
                case "attach:paste": return try await self.paste()
                default: return try await self.bring(first, paths: args.count > 1 ? args[1] : .missing, context: context)
                }
            }
        }
    }
}
