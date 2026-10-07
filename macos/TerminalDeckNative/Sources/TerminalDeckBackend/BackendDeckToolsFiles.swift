import Foundation
import TerminalDeckNativeCore

/// Authenticated dispatcher facts and actual consent/log owner. Copilot-created
/// ownership is a ledger fact, never inferred from this call's session id.
public protocol BackendDeckToolsFilesRuntime: Sendable {
    func rpc(_ caller: BackendMCPCallContext) async throws -> NativeRPCContext
    func knownFolder(_ path: String, caller: BackendMCPCallContext) async throws -> String
    func requireSession(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func startedByCopilot(_ id: String, caller: BackendMCPCallContext) async throws -> Bool
    func boundary(_ id: String) async throws -> BackendDeviceBoundary?
    func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier,
                   summary: String, arguments: NativeRPCValue) async throws
    func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws
}

/// Existing filesystem services implement the disk work; this adapter adds the
/// source tool's paging, argument sentences, redaction and attachment outputs.
public protocol BackendDeckToolsFilesProvider: Sendable {
    func list(root: String, relative: String, showIgnored: Bool, withStats: Bool, context: NativeRPCContext) async throws -> NativeRPCValue
    func read(root: String, relative: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func projectFiles(root: String, refresh: Bool, context: NativeRPCContext) async throws -> NativeRPCValue
    func invalidate(root: String) async
    func ignore(root: String, action: String, path: String?, directory: Bool, paths: [String], context: NativeRPCContext) async throws -> NativeRPCValue
    func stage(name: String, bytes: Data) async -> NativeRPCValue
    func isDirectory(_ path: String, context: NativeRPCContext) async throws -> Bool?
    func bringIn(source: String, folder: String, context: NativeRPCContext) async throws -> String
}
public struct BackendDeckToolsFilesService: BackendDeckToolsFilesProvider, Sendable {
    public let files: BackendFilesystemService
    public let transfers: BackendFilesystemTransfers
    public init(files: BackendFilesystemService, transfers: BackendFilesystemTransfers) {
        self.files = files; self.transfers = transfers
    }
    public func list(root: String, relative: String, showIgnored: Bool, withStats: Bool, context: NativeRPCContext) async throws -> NativeRPCValue { try await files.list(root:root,relative:relative,options:.init(showIgnored:showIgnored,withStats:withStats),context:context) }
    public func read(root: String, relative: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await files.read(root:root,relative:relative,context:context,refuseCredentials:true) }
    public func projectFiles(root: String, refresh: Bool, context: NativeRPCContext) async throws -> NativeRPCValue { try await files.projectFiles(root:root,refresh:refresh,context:context) }
    public func invalidate(root: String) async { await files.invalidate(root:root) }
    public func ignore(root: String, action: String, path: String?, directory: Bool, paths: [String], context: NativeRPCContext) async throws -> NativeRPCValue { try await files.ignore(root:root,action:action,path:path,directory:directory,paths:paths,context:context) }
    public func stage(name: String, bytes: Data) async -> NativeRPCValue { await transfers.stage(name:name,bytes:bytes) }
    public func isDirectory(_ path: String, context: NativeRPCContext) async throws -> Bool? { try await files.isDirectory(path,context:context) }
    public func bringIn(source: String, folder: String, context: NativeRPCContext) async throws -> String { try await transfers.bringIn(source:source,folder:folder,context:context,refuseCredentials:true) }
}

public enum BackendDeckToolsFiles {
    private typealias A = BackendDeckToolsArgs
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    public static let maxUploadBytes = 160 * 1024
    public static func definitions(service: BackendDeckToolsFilesService,
                                   runtime: any BackendDeckToolsFilesRuntime) throws -> [BackendDeckToolsDefinition] {
        try definitions(provider:service,runtime:runtime)
    }
    public static func definitions(provider service: any BackendDeckToolsFilesProvider,
                                   runtime: any BackendDeckToolsFilesRuntime) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsCatalogue.entries().filter { $0.module == "files-tools" }.map { entry in
            BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index) { caller, args in
                await BackendDeckToolsSupport.reply {
                    let (value, summary) = try await call(entry.spec.id, args: args, caller: caller, service: service, runtime: runtime)
                    try await runtime.completed(caller, tool: entry.spec.id, summary: summary)
                    return .value(value)
                }
            }
        }
    }
    public static func area(service: BackendDeckToolsFilesService,
                            runtime: any BackendDeckToolsFilesRuntime) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: "files", definitions: definitions(service: service, runtime: runtime))
    }
    /// path.posix.normalize after accepting Windows-style separators in a
    /// project-relative argument; Mac absolute paths are the only absolute form.
    public static func relative(_ raw: String?) throws -> String {
        guard let raw, !raw.isEmpty, raw != "." else { return "" }
        if raw.hasPrefix("/") { throw A.bad("path must be relative to the project folder") }
        let converted = raw.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []
        for part in converted.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() } else { parts.append("..") }
            } else { parts.append(String(part)) }
        }
        let normal = (converted.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
        if normal == ".." || normal.hasPrefix("../") { throw A.bad("path must stay inside the project folder") }
        return normal
    }
    public static func mention(_ path: String, directory: Bool) -> String {
        "@\"" + path + (directory && !path.hasSuffix("/") ? "/" : "") + "\""
    }
    public static func attachmentSuggestedTier(paths: [String], owned: Bool) -> BackendMCPTier {
        paths.isEmpty ? .read : owned ? .act : .alter
    }
    public static func rankMatches(_ files: [String], words: [String]) -> [String] {
        files.enumerated().filter { _, path in words.allSatisfy { path.lowercased().contains($0) } }.sorted { a, b in
            func score(_ path: String) -> Int {
                let lower = path.lowercased(), name = lower.split(separator: "/").last.map(String.init) ?? lower
                return words.filter { name.contains($0) }.count * 1000 - path.utf16.count
            }
            let first = score(a.element), second = score(b.element)
            return first == second ? a.offset < b.offset : first > second
        }.map(\.element)
    }
    public static func decodeUpload(_ args: NativeRPCValue) throws -> Data {
        _ = try A.str(args, "name")
        let raw = try A.str(args, "contentBase64").filter { !$0.isWhitespace }
        guard raw.range(of: #"^[A-Za-z0-9+/]*={0,2}$"#, options: .regularExpression) != nil else { throw A.bad("contentBase64 must be base64") }
        // Buffer.from accepts unpadded base64, and ignores a trailing singleton.
        var text = String(raw.prefix { $0 != "=" })
        if text.utf8.count % 4 == 1 { text.removeLast() }
        text += String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        let bytes = Data(base64Encoded: text) ?? Data()
        guard !bytes.isEmpty else { throw A.bad("the file is empty") }
        guard bytes.count <= maxUploadBytes else {
            throw A.bad("that file is \(bytes.count) bytes; at most \(maxUploadBytes) can be sent this way. A larger one has to reach this machine some other way — a shared folder, a download a session runs.")
        }
        return bytes
    }
    public static func attachPaths(_ args: NativeRPCValue) throws -> [String] {
        if args["paths"].isNullish { return [] }
        guard let raw = args["paths"].elements else { throw A.bad("paths must be a list of absolute paths") }
        guard raw.count <= 10 else { throw A.bad("at most 10 files at once") }
        return try raw.map { value in
            guard let text = value.string, text.hasPrefix("/") else { throw A.bad("each path must be absolute") }
            return text
        }
    }
    public struct SecretShape: Sendable { public let name: String, why: String }
    /// Source credential shape names/reasons are retained. The confinement
    /// service independently enforces the same denylist on resolved disk paths.
    public static func secretShape(_ raw: String) -> SecretShape? {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        for pattern in [#"\.env\.(example|sample|template|defaults|dist)$"#, #"\.env\.d\.ts$"#] {
            if path.range(of: "(^|/)" + pattern, options: .regularExpression) != nil { return nil }
        }
        let shapes: [(String, String, String)] = [
            ("dotenv", "the conventional home of every local credential a project has", #"\.env(\.[^/]*)?$"#),
            ("direnv", ".envrc is shell that exports secrets when you cd into the folder", #"\.envrc$"#),
            ("registry-auth", "package-manager configs carry publish tokens in plain text", #"(\.npmrc|\.yarnrc\.yml|\.pypirc)$"#),
            ("network-auth", "netrc, pgpass and htpasswd are password files by definition", #"(\.netrc|_netrc|\.pgpass|\.htpasswd)$"#),
            ("stored-credentials", "git's plaintext store, an agent CLI's token file, a Vault token", #"(\.git-credentials|\.credentials\.json|\.vault-token)$"#),
            ("ssh-private-key", "the private half of an SSH key; the .pub half stays readable", #"id_(rsa|dsa|ecdsa|ed25519)(_sk)?$"#),
            ("private-key-file", "private keys, signing keys and keystores, by extension", #"[^/]*\.(pem|key|p8|p12|pfx|jks|keystore|asc|ppk)$"#),
            ("terraform-state", "tfvars and tfstate hold provider credentials in clear text", #"[^/]*\.(tfvars(\.json)?|tfstate(\.backup)?)$"#),
            ("cloud-config-dir", "per-tool credential directories that sometimes sit inside a repo", #"(\.ssh|\.aws|\.gnupg|\.kube|\.azure|\.docker)(/.*)?$"#),
            ("secrets-file", "a file that says in its own name what is in it", #"(secrets?\.(json|ya?ml|toml|env)|[^/]*\.secrets?\.(json|ya?ml|toml))$"#),
            ("service-account", "a Google service-account JSON is a private key with a filename", #"service-account[^/]*\.json$"#)
        ]
        for (name, why, pattern) in shapes where path.range(of: "(^|/)" + pattern, options: .regularExpression) != nil { return SecretShape(name: name, why: why) }
        return nil
    }
    private static func refuseSecret(_ path: String) throws {
        if let shape = secretShape(path) {
            throw A.bad("\(path) is a credential file (\(shape.name): \(shape.why)), and its contents are not handed out through these tools. The person can open it themselves.")
        }
    }
    private static func ignoreAction(_ args: NativeRPCValue) throws -> String {
        let action = try A.str(args, "action")
        guard ["overview", "explain", "filter"].contains(action) else { throw A.bad("action must be \"overview\", \"explain\" or \"filter\"") }
        return action
    }
    private static func call(_ id: String, args: NativeRPCValue, caller: BackendMCPCallContext,
                             service: any BackendDeckToolsFilesProvider, runtime: any BackendDeckToolsFilesRuntime) async throws -> (NativeRPCValue, NativeRPCValue) {
        try Task.checkCancellation()
        let rpc = try await runtime.rpc(caller)
        var cwd = "", rel = "", action = "", paths: [String] = [], bytes = Data()
        var tier: BackendMCPTier = id == "files.upload" || id == "sessions.attach" ? .act : .read
        // Source precheck before the actual tier/consent/log gate.
        switch id {
        case "files.list", "files.read", "files.find", "files.ignored":
            cwd = try await runtime.knownFolder(A.str(args, "cwd"), caller: caller)
            if id == "files.list" { rel = try relative(A.optStr(args, "path")) }
            if id == "files.read" { rel = try relative(A.str(args, "path")); try refuseSecret(rel) }
            if id == "files.find" { _ = try A.str(args, "query") }
            if id == "files.ignored" { action = try ignoreAction(args) }
        case "files.upload": bytes = try decodeUpload(args)
        case "sessions.attach":
            paths = try attachPaths(args)
            // control.ts only raises tiers. The source's no-path escalation
            // returns read, but its declared act floor still applies.
            if !paths.isEmpty { tier = attachmentSuggestedTier(paths:paths,owned:try await runtime.startedByCopilot(A.optStr(args, "sessionId") ?? "", caller: caller)) }
        default: throw BackendDeckToolsSupport.unavailable(id)
        }
        let summaryText: String
        switch id {
        case "files.list": summaryText = "List \(try A.optStr(args, "path") ?? "the top") of \(try A.optStr(args, "cwd") ?? "?")"
        case "files.read": summaryText = "Read \(try A.optStr(args, "path") ?? "?") in \(try A.optStr(args, "cwd") ?? "?")"
        case "files.find": summaryText = "Find “\(try A.optStr(args, "query") ?? "?")” in \(try A.optStr(args, "cwd") ?? "?")"
        case "files.ignored": summaryText = "Read the ignore rules of \(try A.optStr(args, "cwd") ?? "?")"
        case "files.upload": summaryText = "Save \(try A.optStr(args, "name") ?? "a file") on this machine"
        default: summaryText = paths.isEmpty ? "Check what session \(try A.optStr(args, "sessionId") ?? "?") can read" : "Give session \(try A.optStr(args, "sessionId") ?? "?") \(paths.joined(separator: ", "))"
        }
        let logArgs = id == "files.upload" ? args.setting("contentBase64", .string("[\(args["contentBase64"].string?.utf16.count ?? 0) base64 characters]")) : args
        guard caller.allowedTiers.contains(tier), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "not-granted", message: "This caller is not permitted to use that tool.") }
        try await runtime.authorize(caller, tool: id, tier: tier, summary: summaryText, arguments: logArgs)
        try Task.checkCancellation()
        switch id {
        case "files.list":
            let listing = try await service.list(root: cwd, relative: rel, showIgnored: A.optBool(args, "showIgnored", false), withStats: A.optBool(args, "withStats", false), context: rpc)
            let entries: NativeRPCValue
            if try A.optBool(args,"withStats",false) { entries = listing["entries"] }
            else { entries = .array((listing["entries"].elements ?? []).map { row in o([("name",row["name"]),("relPath",row["relPath"]),("kind",row["kind"]),("symlink",row["symlink"]),("blocked",row["blocked"])]) }) }
            return (o([("cwd", .string(cwd)), ("path", .string(rel)), ("entries", entries), ("truncated", listing["truncated"])]), o([("cwd", .string(cwd)), ("path", .string(rel)), ("entries", .number(Double(entries.elements?.count ?? 0)))]))
        case "files.read":
            if rel.isEmpty { throw A.bad("path must name a file") }
            let read = try await service.read(root: cwd, relative: rel, context: rpc)
            if read["kind"].string != "text" { return (read.setting("cwd", .string(cwd)), o([("cwd", .string(cwd)), ("path", .string(rel)), ("kind", read["kind"])])) }
            let from = try A.optInt(args, "fromLine", 1, 1, 9_007_199_254_740_991), count = try A.optInt(args, "lines", 400, 1, 2000)
            let lines = (read["text"].string ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            let end = min(lines.count, from - 1 + count)
            let page = from - 1 < end ? lines[(from - 1)..<end].joined(separator: "\n") : ""
            let cut = page.utf16.count > 60_000
            var value = o([("cwd", .string(cwd)), ("path", .string(rel)), ("bytes", read["bytes"]), ("totalLines", read["lines"]), ("fromLine", .number(Double(from))), ("toLine", .number(Double(end))), ("more", .bool(end < lines.count || cut)), ("text", .string(BackendDeckToolsSupport.slice(page, 0, 60_000)))])
            if cut { value = value.setting("charsCut", .bool(true)) }
            return (value, o([("cwd", .string(cwd)), ("path", .string(rel)), ("fromLine", .number(Double(from))), ("toLine", .number(Double(end)))]))
        case "files.find":
            let words = try A.str(args, "query").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let list = try await service.projectFiles(root: cwd, refresh: A.optBool(args, "refresh", false), context: rpc)
            let all = list["files"].elements?.compactMap(\.string) ?? [], matches = rankMatches(all, words: words), cap = try A.optInt(args, "limit", 50, 1, 200)
            var value = o([("cwd", .string(cwd)), ("files", .array(matches.prefix(cap).map(NativeRPCValue.string))), ("matched", .number(Double(matches.count))), ("searched", .number(Double(all.count)))])
            if list["truncated"].bool == true { value = value.setting("note", .string("The project has more files than were listed; some may be missing.")) }
            return (value, o([("cwd", .string(cwd)), ("matched", .number(Double(matches.count)))]))
        case "files.ignored":
            if try A.optBool(args, "refresh", false) { await service.invalidate(root: cwd) }
            if action == "filter" {
                guard let raw = args["paths"].elements, !raw.isEmpty else { throw A.bad("paths must be a non-empty list for \"filter\"") }
                let wanted = try raw.map { try relative($0.string) }.prefix(2000)
                let result = try await service.ignore(root: cwd, action: action, path: nil, directory: false, paths: Array(wanted), context: rpc)
                let kept = result["kept"].elements?.compactMap(\.string) ?? []
                return (o([("cwd", .string(cwd)), ("kept", .array(kept.map(NativeRPCValue.string))), ("hidden", .array(wanted.filter { !kept.contains($0) }.map(NativeRPCValue.string)))]), o([("cwd", .string(cwd)), ("action", .string(action))]))
            }
            let path = action == "explain" ? try relative(A.str(args, "path")) : nil
            let result = try await service.ignore(root: cwd, action: action, path: path, directory: A.optBool(args, "isFolder", false), paths: [], context: rpc)
            return (result, o([("cwd", .string(cwd)), ("action", .string(action))]))
        case "files.upload":
            let staged = await service.stage(name: try A.str(args, "name"), bytes: bytes)
            guard staged["ok"].bool == true, let path = staged["path"].string else { throw A.bad(staged["message"].string ?? "The upload could not be saved") }
            return (o([("path", .string(path)), ("bytes", .number(Double(bytes.count))), ("mention", .string(mention(path, directory: false)))]), o([("bytes", .number(Double(bytes.count)))]))
        default:
            let session = try await runtime.requireSession(A.str(args, "sessionId"), caller: caller), sid = session["id"].string ?? ""
            let boundary = try await runtime.boundary(sid), held = boundary?.folder.isEmpty == false
            var attached: [NativeRPCValue] = [], refused: [NativeRPCValue] = []
            for path in paths {
                var why: String?
                if let shape = secretShape(path) { why = "it is a credential file (\(shape.name))" }
                else {
                    let directory: Bool?
                    do { directory = try await service.isDirectory(path, context: rpc) }
                    catch { directory = nil }
                    if let directory {
                        if held && directory { why = "a folder is not copied into a held session — copy the files in it" }
                        else {
                            var target: String? = path
                            if held, let boundary { target = try? await service.bringIn(source: path, folder: boundary.folder, context: rpc) }
                            if let target { attached.append(o([("from", .string(path)), ("path", .string(target)), ("isDirectory", .bool(directory)), ("mention", .string(mention(target, directory: directory)))])) }
                            else { why = "it could not be copied (too big, or the disk refused)" }
                        }
                    } else { why = "there is nothing at that path" }
                }
                if let why { refused.append(o([("path", .string(path)), ("why", .string(why))])) }
            }
            return (o([("sessionId", .string(sid)), ("heldInFolder", held ? .string(boundary!.folder) : .null), ("alsoReadable", .array(held ? boundary!.readOnlyProjects.map(NativeRPCValue.string) : [])), ("attached", .array(attached)), ("refused", .array(refused))]), o([("sessionId", .string(sid)), ("attached", .number(Double(attached.count))), ("refused", .number(Double(refused.count))), ("held", .bool(held))]))
        }
    }
}
