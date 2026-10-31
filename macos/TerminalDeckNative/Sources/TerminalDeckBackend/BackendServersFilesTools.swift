import Foundation
import TerminalDeckNativeCore

/// SRVFILES #120 channels (the server page's Files view) and MCP tools (servers_files_list,
/// servers_files_read, servers_gallery_list, servers_files_change). Reads keep the same folder limits and the
/// key's server permissions; files_change asks the owner first and is refused on Look only.
public enum BackendServersFilesChannels {
    public static let channels = ["servers:files:list", "servers:files:info", "servers:files:read", "servers:files:preview", "servers:files:preview:close",
        "servers:files:download", "servers:files:rename", "servers:files:delete", "servers:files:upload", "servers:files:folders", "servers:files:folders:set",
        "servers:files:gallery", "servers:files:gallery:scan", "servers:files:thumb", "servers:files:measure"]
    public static let events = ["servers:files:scan"]

    public static func register(on registry: NativeChannelRegistry, ownerID: String, files: BackendServersFiles,
                                resolve: @escaping @Sendable (NativeRPCContext) async throws -> BackendServersCaller) async throws {
        var installed: [String] = []
        do {
            for channel in channels {
                try await registry.register(channel, ownerID: ownerID) { context, args in
                    try await invoke(channel, args, context: context, files: files, caller: resolve(context))
                }
                installed.append(channel)
            }
        } catch { for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }; throw error }
    }
    public static func remove(from registry: NativeChannelRegistry, ownerID: String) async {
        for channel in channels { await registry.removeHandler(channel, ownerID: ownerID) }
    }

    static func failure(_ error: Error) -> NativeRPCValue {
        let code = (error as? BackendServersFilesRefusal)?.code ?? (error as? NativeRPCError)?.code ?? (error as? BackendServersProblem)?.kind ?? "failed"
        let sentence = (error as? BackendServersFilesRefusal)?.sentence ?? (error as? BackendServersProblem)?.sentence ?? error.localizedDescription
        return .object([.init("ok", .bool(false)), .init("code", .string(code)), .init("sentence", .string(sentence.isEmpty ? "That did not work." : sentence))])
    }

    public static func invoke(_ channel: String, _ args: [NativeRPCValue], context: NativeRPCContext, files: BackendServersFiles,
                              caller: BackendServersCaller) async throws -> NativeRPCValue {
        func arg(_ i: Int) -> NativeRPCValue { context.argument(i, in: args) }
        // Same clamp as the AI-tool path below: Int(1e300) traps the whole app.
        func int(_ value: NativeRPCValue, _ fallback: Int) -> Int { BackendServersWire.integer(value, fallback: fallback, minimum: 0, maximum: 1 << 53) }
        guard caller.context.ownerID == context.ownerID else { throw NativeRPCError(code: "not-permitted", message: "The caller identity does not match its surface.") }
        do {
            let id = try arg(0).requireString("server", nonempty: true)
            let opts = arg(1)
            switch channel {
            case "servers:files:list":
                return try await files.list(id, path: opts["path"].string ?? "", query: opts["query"].string ?? "", sort: opts["sort"].string ?? "name",
                    descending: opts["descending"].bool ?? false, offset: int(opts["offset"], 0), limit: int(opts["limit"], BackendServersFiles.pageSize),
                    fresh: opts["fresh"].bool ?? false, caller: caller)
            case "servers:files:info":
                return .object([.init("ok", .bool(true)), .init("entry", try await files.info(id, path: opts["path"].string ?? "", caller: caller).wireValue)])
            case "servers:files:read":
                let got = try await files.read(id, path: opts["path"].string ?? "", from: int(opts["from"], 0), length: int(opts["length"], 65536), caller: caller)
                return .object([.init("ok", .bool(true)), .init("path", .string(got.path)), .init("size", .number(Double(got.size))), .init("bytes", .bytes(got.bytes))])
            case "servers:files:preview":
                let local = try await files.fetchForPreview(id, path: opts["path"].string ?? "", caller: caller)
                return .object([.init("ok", .bool(true)), .init("local", .string(local.path))])
            case "servers:files:preview:close":
                guard caller.kind == .nativeUI else { throw BackendServersFilesRefusal("access-denied", BackendServersFiles.ownerOnly) }
                if let local = opts["local"].string { files.releasePreview(local) }
                return .object([.init("ok", .bool(true))])
            case "servers:files:download":
                let saved = try await files.download(id, path: opts["path"].string ?? "", caller: caller)
                return .object([.init("ok", .bool(true)), .init("local", .string(saved.path)), .init("name", .string(saved.lastPathComponent))])
            case "servers:files:rename":
                let target = try await files.rename(id, path: opts["path"].string ?? "", to: try opts["name"].requireString("name", nonempty: true), caller: caller)
                return .object([.init("ok", .bool(true)), .init("path", .string(target))])
            case "servers:files:delete":
                try await files.delete(id, path: opts["path"].string ?? "", caller: caller)
                return .object([.init("ok", .bool(true))])
            case "servers:files:upload":
                guard caller.kind == .nativeUI else { throw BackendServersFilesRefusal("access-denied", BackendServersFiles.ownerOnly) }
                let placed = try await files.upload(id, local: URL(fileURLWithPath: try opts["local"].requireString("file", nonempty: true)), folder: opts["folder"].string ?? "", caller: caller)
                return .object([.init("ok", .bool(true)), .init("path", .string(placed))])
            case "servers:files:folders":
                return try await files.folders(id, caller: caller).setting("ok", .bool(true))
            case "servers:files:folders:set":
                let paths: [String]? = opts["folders"].isNullish ? nil : (opts["folders"].elements ?? []).compactMap(\.string)
                return try await files.setFolders(id, paths, caller: caller).setting("ok", .bool(true))
            case "servers:files:gallery":
                return try await files.gallery(id, type: opts["type"].string ?? "photo", query: opts["query"].string ?? "", sort: opts["sort"].string ?? "date",
                    descending: opts["descending"].bool ?? true, group: opts["group"].string ?? "none", offset: int(opts["offset"], 0),
                    limit: int(opts["limit"], 300), caller: caller)
            case "servers:files:gallery:scan":
                let index = try await files.scan(id, caller: caller)
                return .object([.init("ok", .bool(true)), .init("found", .number(Double(index.entries.count))), .init("complete", .bool(index.complete))])
            case "servers:files:thumb":
                let file = try await files.thumbnail(id, path: opts["path"].string ?? "", caller: caller)
                return .object([.init("ok", .bool(true)), .init("local", file.map { .string($0.path) } ?? .null)])
            case "servers:files:measure":
                let value = try await files.measure(id, path: opts["path"].string ?? "", caller: caller)
                return .object([.init("ok", .bool(true)), .init("value", value.map(NativeRPCValue.number) ?? .null)])
            default: throw NativeRPCError(code: "unavailable", message: "This files operation is unavailable.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return failure(error) }
    }
}

public enum BackendServersFilesTools {
    public static let names = ["servers.files_list", "servers.files_read", "servers.gallery_list", "servers.files_change"]
    public static func definitions() throws -> [BackendMCPTool] {
        func schema(_ json: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(json.utf8)) }
        let list = #"{"type":"object","properties":{"serverId":{"type":"string","description":"Which server (servers_look lists them)."},"path":{"type":"string","description":"Folder to list. Empty = the first allowed folder (usually the home folder). ~/ works."},"query":{"type":"string","description":"Only names containing this text."},"sort":{"type":"string","enum":["name","size","date","kind"]},"descending":{"type":"boolean"},"offset":{"type":"integer"},"limit":{"type":"integer","description":"Default 200, max 1000."}},"required":["serverId"],"additionalProperties":false}"#
        let read = #"{"type":"object","properties":{"serverId":{"type":"string"},"path":{"type":"string","description":"File inside the server's allowed folders."},"offset":{"type":"integer","description":"Byte to start at. Default 0."},"maxBytes":{"type":"integer","description":"Default 65536, max 262144."}},"required":["serverId","path"],"additionalProperties":false}"#
        let gallery = #"{"type":"object","properties":{"serverId":{"type":"string"},"type":{"type":"string","enum":["photo","video","audio","document"]},"query":{"type":"string","description":"Only paths containing this text."},"sort":{"type":"string","enum":["date","size","name"]},"descending":{"type":"boolean"},"group":{"type":"string","enum":["none","folder","month"]},"offset":{"type":"integer"},"limit":{"type":"integer","description":"Default 100, max 1000."},"rescan":{"type":"boolean","description":"Search the allowed folders again first (read-only on the server)."}},"required":["serverId","type"],"additionalProperties":false}"#
        let change = #"{"type":"object","properties":{"serverId":{"type":"string"},"do":{"type":"string","enum":["rename","delete","upload"]},"path":{"type":"string","description":"rename/delete: the file or folder on the server. upload: the folder on the server to copy into."},"name":{"type":"string","description":"rename: the new name (no slash)."},"localPath":{"type":"string","description":"upload: an absolute path to a file on this Mac."}},"required":["serverId","do","path"],"additionalProperties":false}"#
        return [
            try .init(id: names[0], wireName: "servers_files_list", description: "List one folder on a server: names, sizes, dates and kinds, a page at a time. Only the folders the owner allows for that server (default its home folder); hidden apps' folders are left out.", inputSchema: schema(list), tier: .read),
            try .init(id: names[1], wireName: "servers_files_read", description: "Read up to 256 KB of one file on a server, inside its allowed folders. Text comes back as text, anything else as base64. Key and password files are refused.", inputSchema: schema(read), tier: .read),
            try .init(id: names[2], wireName: "servers_gallery_list", description: "List every photo, video, audio file or document found in a server's allowed folders, sorted and grouped. Uses the cached index; rescan searches again (read-only).", inputSchema: schema(gallery), tier: .read),
            try .init(id: names[3], wireName: "servers_files_change", description: "Rename, delete or upload one file on a server. Runs at once when the calling AI's permission mode allows it, and is refused on a Look only server or outside its allowed folders.", inputSchema: schema(change), tier: .alter)
        ]
    }
    public static func register(on server: BackendNativeMCPServer, ownerID: String, files: BackendServersFiles, resolve: @escaping BackendServersTools.Resolve) async throws {
        do {
            for spec in try definitions() {
                try await server.registerTool(spec, ownerID: ownerID) { context, arguments in
                    do {
                        guard !context.cancellation.isCancelled else { throw CancellationError() }
                        return .value(try await invoke(spec.id, arguments: arguments, caller: resolve(context), files: files))
                    } catch is CancellationError { throw CancellationError() }
                    catch { return .failure((error as? BackendServersFilesRefusal)?.sentence ?? (error as? BackendServersProblem)?.sentence ?? error.localizedDescription) }
                }
            }
        } catch { await server.removeTools(ownerID: ownerID); throw error }
    }
    public static func invoke(_ id: String, arguments a: NativeRPCValue, caller: BackendServersCaller, files: BackendServersFiles) async throws -> NativeRPCValue {
        guard let fields = a.fields else { throw NativeRPCError.invalidArguments("Tool arguments must be an object.") }
        let allowed: Set<String> = ["servers.files_list": ["serverId", "path", "query", "sort", "descending", "offset", "limit"], "servers.files_read": ["serverId", "path", "offset", "maxBytes"],
            "servers.gallery_list": ["serverId", "type", "query", "sort", "descending", "group", "offset", "limit", "rescan"], "servers.files_change": ["serverId", "do", "path", "name", "localPath"]][id] ?? []
        guard fields.allSatisfy({ allowed.contains($0.key) }) else { throw NativeRPCError.invalidArguments("That files tool has an argument it does not accept.") }
        guard caller.kind != .remote, caller.context.caller != .pairedDevice else {
            throw BackendServersFilesRefusal("access-denied", "A server's files can be read only from this Mac: the person here, Hoot, its sessions, or an AI app given a key.")
        }
        let server = try a["serverId"].requireString("serverId", nonempty: true)
        // Wire numbers are clamped, never converted bare: Int(1e300) traps the whole app.
        func int(_ key: String, _ fallback: Int, max: Int = 1 << 53) -> Int { BackendServersWire.integer(a[key], fallback: fallback, minimum: 0, maximum: max) }
        switch id {
        case "servers.files_list":
            return try await files.list(server, path: a["path"].string ?? "", query: a["query"].string ?? "", sort: a["sort"].string ?? "name",
                descending: a["descending"].bool ?? false, offset: int("offset", 0), limit: int("limit", BackendServersFiles.pageSize), caller: caller).removing("ok")
        case "servers.files_read":
            let got = try await files.read(server, path: try a["path"].requireString("path", nonempty: true), from: int("offset", 0),
                length: int("maxBytes", 65536, max: BackendServersFiles.aiReadCap), caller: caller)
            let text = String(data: got.bytes, encoding: .utf8) ?? (got.bytes.count >= 3 ? String(data: got.bytes.dropLast(3), encoding: .utf8) : nil)
            let looksText = text.map { !$0.unicodeScalars.contains { $0.value == 0 } } ?? false
            var value = NativeRPCValue.object([.init("path", .string(got.path)), .init("size", .number(Double(got.size))), .init("offset", .number(Double(int("offset", 0)))),
                .init("bytesRead", .number(Double(got.bytes.count))), .init("more", .bool(int("offset", 0) + got.bytes.count < got.size))])
            value = looksText ? value.setting("text", .string(text ?? "")) : value.setting("base64", .string(got.bytes.base64EncodedString()))
            return value
        case "servers.gallery_list":
            let type = try a["type"].requireString("type", nonempty: true)
            if a["rescan"].bool == true { _ = try await files.scan(server, caller: caller) }
            return try await files.gallery(server, type: type, query: a["query"].string ?? "", sort: a["sort"].string ?? "date", descending: a["descending"].bool ?? true,
                group: a["group"].string ?? "none", offset: int("offset", 0), limit: int("limit", 100), scanIfMissing: true, caller: caller).removing("ok")
        case "servers.files_change":
            guard caller.actsAsOwner || caller.kind == .session else { throw BackendServersFilesRefusal("access-denied", "Changing files on a server works only for the person at this Mac or an AI app they approve.") }
            let path = try a["path"].requireString("path", nonempty: true)
            switch a["do"].string {
            case "rename": return .object([.init("path", .string(try await files.rename(server, path: path, to: try a["name"].requireString("name", nonempty: true), caller: caller)))])
            case "delete": try await files.delete(server, path: path, caller: caller); return .object([.init("deleted", .string(path))])
            case "upload":
                let local = try BackendDeckCoreArguments.sendableFile(try a["localPath"].requireString("localPath", nonempty: true))
                return .object([.init("path", .string(try await files.upload(server, local: URL(fileURLWithPath: local), folder: path, caller: caller)))])
            default: throw NativeRPCError.invalidArguments("do must be rename, delete or upload")
            }
        default: throw NativeRPCError.invalidArguments("No such files tool.")
        }
    }
}
