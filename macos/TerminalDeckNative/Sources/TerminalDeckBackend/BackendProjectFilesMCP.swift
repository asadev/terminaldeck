import Foundation
import TerminalDeckNativeCore

/// Required actual consent/action-log gate and authenticated caller→RPC scope.
/// No default permits effects. The gate receives redacted upload metadata.
public struct BackendProjectFilesToolAccess: Sendable {
    public let rpcContext: @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public let authorize: @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void
    public let boundary: @Sendable (String) async -> BackendDeviceBoundary?
    public init(rpcContext: @escaping @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext,
                authorize: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void,
                boundary: @escaping @Sendable (String) async -> BackendDeviceBoundary?) {
        self.rpcContext = rpcContext; self.authorize = authorize; self.boundary = boundary
    }
}

/// Real source schemas/handlers from files-tools.ts, project-tools.ts and the
/// Git catalogue/fleet-diff. Unsupported adjacent tools aren't registered.
public enum BackendProjectFilesMCP {
    public static func register(server: BackendNativeMCPServer, files: BackendFilesystemService, git: BackendGitService,
                                review: BackendGitReview, projects: BackendProjectService,
                                transfers: BackendFilesystemTransfers, access: BackendProjectFilesToolAccess) async throws -> [String] {
        struct Definition: Sendable { let id: String; let tier: BackendMCPTier; let description: String; let properties: NativeRPCValue; let required: [String] }
        let string = NativeRPCValue.object([.init("type", .string("string"))]), boolean = NativeRPCValue.object([.init("type", .string("boolean"))])
        let integer = NativeRPCValue.object([.init("type", .string("integer"))])
        let strings = NativeRPCValue.object([.init("type", .string("array")), .init("items", string)])
        func properties(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
        let definitions = [
            Definition(id: "projects.list", tier: .read, description: "The projects currently open in this app.", properties: .object([]), required: []),
            Definition(id: "projects.browse", tier: .read, description: "List folders to choose a project, starting from home. Hidden folders are optional.", properties: properties([("path", string), ("showHidden", boolean)]), required: []),
            Definition(id: "projects.add", tier: .alter, description: "Open an existing folder as a project. Confirmed because it widens which folders tools may name.", properties: properties([("path", string)]), required: ["path"]),
            Definition(id: "projects.remove", tier: .alter, description: "Remove an open project from the sidebar. Its files and running sessions are kept.", properties: properties([("path", string)]), required: ["path"]),
            Definition(id: "files.list", tier: .read, description: "One bounded level of an open project's tree; links leaving it and special files are blocked.", properties: properties([("cwd", string), ("path", string), ("showIgnored", boolean), ("withStats", boolean)]), required: ["cwd"]),
            Definition(id: "files.read", tier: .read, description: "Read an open project's text file in pages. Binary/over-2-MB files are reported; credential-shaped paths are refused.", properties: properties([("cwd", string), ("path", string), ("fromLine", integer), ("lines", integer)]), required: ["cwd", "path"]),
            Definition(id: "files.find", tier: .read, description: "Find project paths containing every query word; filename matches rank first.", properties: properties([("cwd", string), ("query", string), ("limit", integer), ("refresh", boolean)]), required: ["cwd", "query"]),
            Definition(id: "files.ignored", tier: .read, description: "Read .gitignore/.deckignore overview, explain why a path is hidden, or filter a list of paths.", properties: properties([("action", string), ("cwd", string), ("path", string), ("isFolder", boolean), ("paths", strings), ("refresh", boolean)]), required: ["action", "cwd"]),
            Definition(id: "files.upload", tier: .act, description: "Stage a small base64 file, at most 160 KB, in this app's upload folder. Names never overwrite existing files.", properties: properties([("name", string), ("contentBase64", string)]), required: ["name", "contentBase64"]),
            Definition(id: "sessions.attach", tier: .read, description: "Read a session boundary, or give it files. Held sessions receive bounded copies; credential files aren't handed over.", properties: properties([("sessionId", string), ("paths", strings)]), required: ["sessionId"]),
            Definition(id: "git.status", tier: .read, description: "Branch, ahead/behind and staged, unstaged, untracked and conflicted changes in an open project.", properties: properties([("cwd", string)]), required: ["cwd"]),
            Definition(id: "git.init", tier: .act, description: "Create a Git repository in an open project only if it is not already inside one; return its actual new status.", properties: properties([("cwd", string)]), required: ["cwd"]),
            Definition(id: "git.diff", tier: .read, description: "Every changed file with bounded unified diffs and modification-time session attribution; ambiguous ownership remains ambiguous.", properties: properties([("cwd", string), ("path", string), ("maxFiles", integer)]), required: ["cwd"]),
        ]
        for definition in definitions {
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", definition.properties),
                .init("required", .array(definition.required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: definition.id, wireName: definition.id.replacingOccurrences(of: ".", with: "_"),
                description: definition.description, inputSchema: schema, tier: definition.tier)
            try await server.registerTool(spec) { caller, args in
                try Task.checkCancellation()
                guard !caller.cancellation.isCancelled else { throw CancellationError() }
                let rpc = try await access.rpcContext(caller)
                guard let fields = args.fields else { throw NativeRPCError.invalidArguments("Tool arguments must be an object") }
                let known = Set((definition.properties.fields ?? []).map(\.key))
                guard fields.allSatisfy({ known.contains($0.key) }), definition.required.allSatisfy({ args[$0] != .missing }) else { throw NativeRPCError.invalidArguments("A required or additional tool argument is invalid") }
                for field in fields {
                    switch definition.properties[field.key]["type"].string {
                    case "string": guard field.value.string != nil else { throw NativeRPCError.invalidArguments("\(field.key) must be a string") }
                    case "boolean": guard field.value.bool != nil else { throw NativeRPCError.invalidArguments("\(field.key) must be a boolean") }
                    case "integer": guard let number = field.value.number, number.rounded(.towardZero) == number else { throw NativeRPCError.invalidArguments("\(field.key) must be an integer") }
                    case "array": guard let elements = field.value.elements, elements.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.invalidArguments("\(field.key) must be an array of strings") }
                    default: break
                    }
                }
                if let cwd = args["cwd"].string { _ = try await projects.requireKnown(cwd, restrictedTo: caller.projectRoot) }
                if definition.id == "projects.remove", let path = args["path"].string { _ = try await projects.requireKnown(path, restrictedTo: caller.projectRoot) }
                if definition.id == "projects.add", let path = args["path"].string {
                    let actual = try await files.authority.authorize(path, context: rpc)
                    guard !BackendFilesystemAuthority.within(actual, projects.appDataRoot.resolvingSymlinksInPath()),
                          try await files.isDirectory(path, context: rpc) else { throw NativeRPCError.invalidArguments("That folder cannot be opened as a project") }
                }
                var tier = definition.tier, logArguments = args
                if definition.id == "sessions.attach", !(args["paths"].elements ?? []).isEmpty {
                    tier = args["sessionId"].string == caller.sessionID ? .act : .alter
                }
                if definition.id == "files.upload" { logArguments = args.setting("contentBase64", .string("[redacted upload bytes]")) }
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "access-denied", message: "This caller does not have the requested tool tier") }
                try await access.authorize(caller, definition.id, logArguments, tier)
                try Task.checkCancellation()
                let value: NativeRPCValue
                switch definition.id {
                case "projects.list": value = .object([.init("projects", await projects.list())])
                case "projects.browse": value = try await projects.browse(path: args["path"].string, showHidden: args["showHidden"].bool == true, context: rpc)
                case "projects.add": value = try await projects.add(path: args["path"].requireString("path"), context: rpc)
                case "projects.remove": value = try await projects.remove(path: args["path"].requireString("path"), context: rpc)
                case "files.list":
                    let cwd = try await projects.requireKnown(args["cwd"].requireString("cwd"), restrictedTo: caller.projectRoot)
                    let relative = args["path"].string ?? ""
                    let listing = try await files.list(root: cwd, relative: relative, options: .init(showIgnored: args["showIgnored"].bool == true, withStats: args["withStats"].bool == true), context: rpc)
                    value = listing.setting("cwd", .string(cwd)).setting("path", .string(relative))
                case "files.read":
                    let cwd = try await projects.requireKnown(args["cwd"].requireString("cwd"), restrictedTo: caller.projectRoot)
                    let path = try args["path"].requireString("path", nonempty: true)
                    let file = try await files.read(root: cwd, relative: path, context: rpc, refuseCredentials: true)
                    if file["kind"].string != "text" { value = file.setting("cwd", .string(cwd)) }
                    else {
                        let from = try integerValue(args["fromLine"], fallback: 1, range: 1...9_007_199_254_740_991)
                        let count = try integerValue(args["lines"], fallback: 400, range: 1...2_000)
                        let lines = (file["text"].string ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                        let upper = min(lines.count, from - 1 + count)
                        let raw = from - 1 < lines.count ? lines[(from - 1)..<upper].joined(separator: "\n") : ""
                        let cut = raw.utf16.count > 60_000
                        value = .object([.init("cwd", .string(cwd)), .init("path", .string(path)), .init("bytes", file["bytes"]), .init("totalLines", file["lines"]),
                            .init("fromLine", .number(Double(from))), .init("toLine", .number(Double(upper))), .init("more", .bool(upper < lines.count || cut)),
                            .init("charsCut", .bool(cut)), .init("text", .string(String(decoding: raw.utf16.prefix(60_000), as: UTF16.self)))])
                    }
                case "files.find":
                    let cwd = try await projects.requireKnown(args["cwd"].requireString("cwd"), restrictedTo: caller.projectRoot)
                    let words = try args["query"].requireString("query").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                    let list = try await files.projectFiles(root: cwd, refresh: args["refresh"].bool == true, context: rpc)
                    let all = list["files"].elements?.compactMap(\.string) ?? []
                    let matches = all.filter { path in words.allSatisfy { path.lowercased().contains($0) } }.enumerated().sorted {
                        func score(_ path: String) -> Int { let name = URL(fileURLWithPath: path).lastPathComponent.lowercased(); return words.filter { name.contains($0) }.count * 1_000 - path.utf16.count }
                        let a = score($0.element), b = score($1.element); return a == b ? $0.offset < $1.offset : a > b
                    }.map(\.element)
                    let cap = try integerValue(args["limit"], fallback: 50, range: 1...200)
                    value = .object([.init("cwd", .string(cwd)), .init("files", .array(matches.prefix(cap).map(NativeRPCValue.string))), .init("matched", .number(Double(matches.count))), .init("searched", .number(Double(all.count)))])
                case "files.ignored":
                    let cwd = try await projects.requireKnown(args["cwd"].requireString("cwd"), restrictedTo: caller.projectRoot)
                    if args["refresh"].bool == true { await files.invalidate(root: cwd) }
                    value = try await files.ignore(root: cwd, action: args["action"].requireString("action"), path: args["path"].string,
                        directory: args["isFolder"].bool == true, paths: args["paths"].elements?.compactMap(\.string) ?? [], context: rpc)
                case "files.upload":
                    let raw = try args["contentBase64"].requireString("contentBase64").filter { !$0.isWhitespace }
                    guard raw.utf8.count <= 220_000, let bytes = Data(base64Encoded: raw), !bytes.isEmpty, bytes.count <= 160 * 1024 else { throw NativeRPCError.invalidArguments("The upload must be valid base64 for a nonempty file of at most 160 KB") }
                    let staged = try await transfers.stage(name: args["name"].requireString("name"), bytes: bytes)
                    guard staged["ok"].bool == true, let path = staged["path"].string else { throw NativeRPCError(code: "filesystem", message: staged["message"].string ?? "The upload could not be saved") }
                    value = .object([.init("path", .string(path)), .init("bytes", .number(Double(bytes.count))), .init("mention", .string(mention(path, directory: false)))])
                case "sessions.attach":
                    let id = try args["sessionId"].requireString("sessionId")
                    guard await projects.liveSessions().contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("There is no session with that id") }
                    let boundary = await access.boundary(id), paths = args["paths"].elements?.compactMap(\.string) ?? []
                    guard paths.count <= 10 else { throw NativeRPCError.invalidArguments("At most ten files can be attached at once") }
                    var attached: [NativeRPCValue] = [], refused: [NativeRPCValue] = []
                    for path in paths {
                        do {
                            if BackendFilesystemIgnore.credentialPath(path) { throw NativeRPCError(code: "access-denied", message: "It is a credential-shaped file") }
                            let directory = try await files.isDirectory(path, context: rpc)
                            if boundary != nil && directory { throw NativeRPCError.invalidArguments("A directory is not recursively copied inside a held session") }
                            let target: String
                            if let boundary { target = try await transfers.bringIn(source: path, folder: boundary.folder, context: rpc, refuseCredentials: true) }
                            else { target = path }
                            attached.append(.object([.init("from", .string(path)), .init("path", .string(target)), .init("isDirectory", .bool(directory)), .init("mention", .string(mention(target, directory: directory)))]))
                        } catch { refused.append(.object([.init("path", .string(path)), .init("why", .string((error as? NativeRPCError)?.message ?? "The attachment could not be copied"))])) }
                    }
                    value = .object([.init("sessionId", .string(id)), .init("heldInFolder", boundary.map { .string($0.folder) } ?? .null),
                        .init("alsoReadable", .array((boundary?.readOnlyProjects ?? []).map(NativeRPCValue.string))), .init("attached", .array(attached)), .init("refused", .array(refused))])
                case "git.status", "git.init", "git.diff":
                    let cwd = try await projects.requireKnown(args["cwd"].requireString("cwd"), restrictedTo: caller.projectRoot)
                    if definition.id == "git.status" { value = try await git.status(cwd: cwd, context: rpc) }
                    else if definition.id == "git.init" { value = try await git.initialize(cwd: cwd, context: rpc) }
                    else { value = try await review.collect(cwd: cwd, path: args["path"].string, maxFiles: integerValue(args["maxFiles"], fallback: 25, range: 1...100), context: rpc) }
                default: throw NativeRPCError(code: "missing-handler", message: "The native tool operation is unavailable")
                }
                guard !caller.cancellation.isCancelled else { throw CancellationError() }
                return .value(value)
            }
        }
        return definitions.map(\.id)
    }
    private static func integerValue(_ value: NativeRPCValue, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        if value == .missing { return fallback }
        guard let number = value.number, number.rounded(.towardZero) == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else { throw NativeRPCError.invalidArguments("An integer option is outside the supported range") }
        return Int(number)
    }
    private static func mention(_ path: String, directory: Bool) -> String { "@\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + (directory && !path.hasSuffix("/") ? "/" : "") + "\"" }
}
