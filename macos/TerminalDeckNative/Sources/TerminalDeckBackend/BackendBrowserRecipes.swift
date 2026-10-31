import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Independent declarative page readers survive the retirement of extensions.
/// Files retain the old browser-tools/<id>/{recipe,installed}.json layout.
public actor BackendBrowserRecipes {
    public struct Entry: Sendable {
        public let id: String
        public let name: String
        public let summary: String
        public let homepage: String
        public let licence: String
        public let version: String
        public let origins: [String]
        public let digest: String
        public let bundled: Data?
        public let sourceURL: URL?
        public init(id: String, name: String, summary: String, homepage: String, licence: String,
                    version: String, origins: [String], digest: String, bundled: Data? = nil, sourceURL: URL? = nil) {
            self.id = id; self.name = name; self.summary = summary; self.homepage = homepage; self.licence = licence
            self.version = version; self.origins = origins; self.digest = digest; self.bundled = bundled; self.sourceURL = sourceURL
        }
    }
    public typealias Authorize = @Sendable (NativeRPCContext, String, String?) async throws -> Void
    public typealias Fetch = @Sendable (URL, Int) async throws -> Data
    public typealias Extract = @Sendable (NativeRPCContext, NativeRPCValue) async throws -> NativeRPCValue
    private let root: URL
    private let entries: [Entry]
    private let authorize: Authorize
    private let fetch: Fetch?
    private let extract: Extract
    public init(dataRoot: URL, catalogue: [Entry], authorize: @escaping Authorize, fetch: Fetch? = nil, extract: @escaping Extract) {
        root = dataRoot.standardizedFileURL.appendingPathComponent("browser-tools", isDirectory: true)
        entries = catalogue; self.authorize = authorize; self.fetch = fetch; self.extract = extract
    }
    /// INT (deck-tools browser.extract/store): every parsed, digest-verified install, read per call;
    /// damaged installs are left out (TS store-tools.ts:79-82, browser-store.ts:527-534).
    public func installedRecipes() -> [NativeRPCValue] { entries.compactMap { try? installed($0) } }
    /// TS browser-store.ts remove() of an orphanIds() folder: the same safe-path rules as remove, read back after.
    public func removeOrphan(_ context: NativeRPCContext, id: String) async throws -> NativeRPCValue {
        try await authorize(context, "remove", id)
        guard !entries.contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That browser reader is still offered; remove it from its row.") }
        let directory = try folder(id); try safeTree(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return .object([.init("ok", .bool(true)), .init("message", .string("It was not installed."))]) }
        for name in ["recipe.json", "installed.json"] {
            let file = directory.appendingPathComponent(name); try noSymlink(file)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try FileManager.default.removeItem(at: directory) }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recipe.json").path) else {
            return .object([.init("ok", .bool(false)), .init("message", .string("It could not be removed: the folder is still on disk."))])
        }
        return .object([.init("ok", .bool(true)), .init("message", .string("The withdrawn browser reader was removed. Other files in its folder were preserved."))])
    }
    public func list(_ context: NativeRPCContext) async throws -> NativeRPCValue {
        try await authorize(context, "list", nil)
        var rows: [NativeRPCValue] = []
        for entry in entries {
            var row = view(entry), state = "available", message = "", recipe: NativeRPCValue = .missing, at: NativeRPCValue = .number(0)
            do {
                if let kept = try installed(entry) {
                    state = "installed"; recipe = kept
                    let metadata = try NativeRPCValue.parseJSON(Data(contentsOf: folder(entry.id).appendingPathComponent("installed.json")), maximumBytes: 65_536)
                    at = metadata["installedAt"]
                }
            } catch { state = "damaged"; message = error.localizedDescription }
            row = row.setting("state", .string(state)).setting("message", .string(message))
                .setting("installedVersion", recipe["version"].isNullish ? .string("") : recipe["version"]).setting("installedAt", at)
                .setting("reads", .array((recipe["fields"].elements ?? []).compactMap { $0["name"].string.map(NativeRPCValue.string) }))
            rows.append(row)
        }
        let known = Set(entries.map(\.id))
        let orphans = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.filter { !known.contains($0) && !$0.hasPrefix(".") }.sorted() ?? []
        return .object([.init("view", .object([.init("tools", .array(rows)), .init("folder", .string(root.path))])),
            .init("orphans", .array(orphans.map(NativeRPCValue.string)))])
    }
    public func install(_ context: NativeRPCContext, id: String) async throws -> NativeRPCValue {
        try await authorize(context, "install", id)
        let entry = try entry(id)
        let bytes: Data
        if let bundled = entry.bundled { bytes = bundled }
        else {
            guard let url = entry.sourceURL, url.scheme == "https", url.user == nil, url.password == nil, let fetch else {
                throw NativeRPCError(code: "unavailable", message: "This catalogue entry has no authorized HTTPS recipe fetcher.")
            }
            bytes = try await fetch(url, 65_536)
        }
        let recipe = try verified(bytes, entry: entry)
        try Task.checkCancellation()
        let directory = try folder(id); try safeTree(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["recipe.json", "installed.json"] { try noSymlink(directory.appendingPathComponent(name)) }
        try bytes.write(to: directory.appendingPathComponent("recipe.json"), options: .atomic)
        let metadata = NativeRPCValue.object([.init("id", .string(id)), .init("version", recipe["version"]),
            .init("sha256", .string(entry.digest)), .init("installedAt", .number(Date().timeIntervalSince1970 * 1000))])
        try metadata.encodedJSON(pretty: true).write(to: directory.appendingPathComponent("installed.json"), options: .atomic)
        return .object([.init("ok", .bool(true)), .init("message", .string("\(entry.name) is installed. Use browser.extract on a page."))])
    }
    public func remove(_ context: NativeRPCContext, id: String) async throws -> NativeRPCValue {
        try await authorize(context, "remove", id); _ = try entry(id)
        let directory = try folder(id); try safeTree(directory)
        for name in ["recipe.json", "installed.json"] {
            let file = directory.appendingPathComponent(name); try noSymlink(file)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try FileManager.default.removeItem(at: directory) }
        return .object([.init("ok", .bool(true)), .init("message", .string("The browser reader was removed. Other files in its folder were preserved."))])
    }
    public func run(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        try await authorize(context, "extract", arguments["tool"].string)
        guard let id = arguments["tool"].string, !id.isEmpty else {
            var tools: [NativeRPCValue] = [], problems: [NativeRPCValue] = []
            for entry in entries {
                do {
                    if let recipe = try installed(entry) { tools.append(.object([.init("id", .string(entry.id)), .init("name", .string(entry.name)), .init("origins", recipe["origins"]), .init("fields", recipe["fields"])])) }
                } catch { problems.append(.object([.init("id", .string(entry.id)), .init("message", .string(error.localizedDescription))])) }
            }
            return .object([.init("tools", .array(tools)), .init("empty", .bool(tools.isEmpty)),
                .init("problems", .array(problems)), .init("emptyReason", .string(tools.isEmpty ? "No usable page readers are installed. Check the browser Tools store before extracting." : ""))])
        }
        let row = try entry(id)
        guard let recipe = try installed(row) else { throw NativeRPCError(code: "not-installed", message: "Install this page reader from the browser Tools store first.") }
        let rawLimit = arguments["limit"].number ?? 2_000
        let limit = min(2_000, max(1, Int(min(2_000, max(1, rawLimit)))))
        let answer = try await extract(context, arguments.setting("recipe", recipe).setting("limit", .number(Double(limit))))
        return answer.setting("tool", .string(id)).setting("name", .string(row.name))
    }
    private func installed(_ entry: Entry) throws -> NativeRPCValue? {
        let directory = try folder(entry.id); try safeTree(directory)
        let file = directory.appendingPathComponent("recipe.json"); try noSymlink(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 65_536 else { throw NativeRPCError.invalidArguments("The stored recipe is not a bounded regular file.") }
        return try verified(Data(contentsOf: file), entry: entry)
    }
    private func verified(_ data: Data, entry: Entry) throws -> NativeRPCValue {
        guard data.count <= 65_536, entry.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.digest else {
            throw NativeRPCError(code: "recipe-digest", message: "This recipe does not match the trusted catalogue's digest. Remove it and install again.")
        }
        let recipe = try NativeRPCValue.parseJSON(data, maximumBytes: 65_536)
        let known: Set<String> = ["id", "name", "summary", "version", "grants", "origins", "fields", "rows", "stated", "next"]
        guard recipe.fields?.allSatisfy({ known.contains($0.key) }) == true, recipe["id"].string == entry.id,
              recipe["version"].string == entry.version, let grants = recipe["grants"].elements,
              !grants.isEmpty, grants.allSatisfy({ $0.string == "page-read" }), let origins = recipe["origins"].elements,
              !origins.isEmpty, origins.count <= 40, origins.allSatisfy({ $0.string.map(entry.origins.contains) == true }) else {
            throw NativeRPCError.invalidArguments("The recipe exceeds the catalogue's identity, version or origin/grant declaration.")
        }
        try fields(recipe["fields"], limit: 40)
        if !recipe["rows"].isNullish { try selector(recipe["rows"]["selector"], allowEmpty: false); try fields(recipe["rows"]["fields"], limit: 24) }
        if !recipe["stated"].isNullish {
            try fields(.array([recipe["stated"]]), limit: 1)
            guard ["number", "count"].contains(recipe["stated"]["op"].string ?? ""), recipe["stated"]["all"].bool != true else { throw NativeRPCError.invalidArguments("The stated total must be one count or number.") }
        }
        if !recipe["next"].isNullish { try selector(recipe["next"], allowEmpty: false) }
        return recipe
    }
    private func fields(_ raw: NativeRPCValue, limit: Int) throws {
        let list = try raw.requireArray("recipe fields")
        guard !list.isEmpty, list.count <= limit else { throw NativeRPCError.invalidArguments("The recipe has too many or no fields.") }
        var names: Set<String> = []
        for field in list {
            guard let name = field["name"].string, name.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil,
                  names.insert(name).inserted, let operation = field["op"].string,
                  ["text", "attribute", "link", "image", "data", "count", "number"].contains(operation),
                  field.fields?.allSatisfy({ ["name", "selector", "op", "attribute", "all"].contains($0.key) }) == true,
                  field["all"].isNullish || field["all"].bool != nil else { throw NativeRPCError.invalidArguments("The recipe field has invalid or unknown properties.") }
            try selector(field["selector"], allowEmpty: ["text", "data", "count"].contains(operation))
            if operation == "attribute" {
                guard let attribute = field["attribute"].string, attribute.count <= 64,
                      attribute.range(of: "^[a-zA-Z_:][-a-zA-Z0-9_:.]*$", options: .regularExpression) != nil,
                      !attribute.isEmpty else { throw NativeRPCError.invalidArguments("That attribute is not a readable attribute name.") }
            } else if !field["attribute"].isNullish { throw NativeRPCError.invalidArguments("Only attribute operations may name an attribute.") }
        }
    }
    private func selector(_ value: NativeRPCValue, allowEmpty: Bool) throws {
        let text = try value.requireString("selector")
        guard (allowEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty), text.count <= 400,
              !text.contains("<"), !text.contains(">") else { throw NativeRPCError.invalidArguments("The recipe selector is invalid or exceeds 400 characters.") }
    }
    private func entry(_ id: String) throws -> Entry { guard let entry = entries.first(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("No browser recipe is offered under that id.") }; return entry }
    private func folder(_ id: String) throws -> URL {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Invalid recipe id.") }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    private func safeTree(_ directory: URL) throws {
        var path = directory
        while path.path != "/" { try noSymlink(path); path.deleteLastPathComponent() }
    }
    private func noSymlink(_ path: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
            throw NativeRPCError(code: "unsafe-path", message: "Browser recipes do not follow symbolic links.")
        }
    }
    private func view(_ entry: Entry) -> NativeRPCValue { .object([.init("id", .string(entry.id)), .init("name", .string(entry.name)), .init("summary", .string(entry.summary)),
        .init("homepage", .string(entry.homepage)), .init("licence", .string(entry.licence)), .init("version", .string(entry.version)),
        .init("grants", .array([.string("page-read")])), .init("origins", .array(entry.origins.map(NativeRPCValue.string))),
        .init("url", .string(entry.sourceURL?.absoluteString ?? "")), .init("fetched", .bool(entry.bundled == nil)), .init("sha256", .string(entry.digest))]) }
    public func registerChannels(_ registry: NativeChannelRegistry, ownerID: String = "native-safari-recipes") async throws {
        try await registry.register("browser-store:list", ownerID: ownerID) { [self] context, _ in try await list(context) }
        try await registry.register("browser-store:install", ownerID: ownerID) { [self] context, args in try await install(context, id: context.argument(0, in: args).requireString("id", nonempty: true)) }
        try await registry.register("browser-store:remove", ownerID: ownerID) { [self] context, args in try await remove(context, id: context.argument(0, in: args).requireString("id", nonempty: true)) }
    }
    public func registerTools(_ server: BackendNativeMCPServer, context: @escaping BackendBrowserFactories.MCPContext) async throws {
        let storeSchema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"action":{"type":"string","enum":["list","install","remove"]},"id":{"type":"string"}},"additionalProperties":false}"#.utf8))
        let store = try BackendMCPTool(id: "browser.store", wireName: "browser_store", description: "Independent browser page readers: list, install a digest-pinned recipe, or remove it. Installs and removals require the person's grant.", inputSchema: storeSchema, tier: .read)
        try await server.registerTool(store) { [self] caller, args in
          do {
            let rpc = try await context(caller), action = args["action"].string ?? "list"
            switch action {
            case "list": return .value(try await list(rpc))
            case "install": return .value(try await install(rpc, id: args["id"].requireString("id", nonempty: true)))
            case "remove": return .value(try await remove(rpc, id: args["id"].requireString("id", nonempty: true)))
            default: throw NativeRPCError.invalidArguments("Unknown browser store action.")
            }
          } catch is CancellationError { throw CancellationError() }
          catch { return .failure(NativeRPCError.wrapping(error).message) }
        }
        let extractionSchema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"tool":{"type":"string"},"sessionId":{"type":"string"},"window":{"type":"string"},"limit":{"type":"number"}},"additionalProperties":false}"#.utf8))
        let extraction = try BackendMCPTool(id: "browser.extract", wireName: "browser_extract", description: "Run an installed declarative page reader on your authorized browser window. Returns fields, rows, counts, the stated total and completeness; never a secret field value.", inputSchema: extractionSchema, tier: .read)
        try await server.registerTool(extraction) { [self] caller, args in
            try await BackendBrowserFactories.toolReply { try await run(try await context(caller), arguments: args) }
        }
    }
}
