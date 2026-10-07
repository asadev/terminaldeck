import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// store-install.ts. Shared grammar, signed index/cache, MCP input composer and
/// routines parser are reused from their owning workers. Construction has no
/// network or disk effects. Writes require exclusive native ownership.
public actor BackendOSStoreInstaller: BackendCommunityStoreProviding {
    public struct Artifact: Sendable {
        public let ok: Bool; public let bytes: Data; public let message: String
        public init(ok: Bool, bytes: Data = Data(), message: String = "") { self.ok = ok; self.bytes = bytes; self.message = message }
    }
    public typealias FetchArtifact = @Sendable (String, Int) async -> Artifact
    public typealias RunAgent = @Sendable (String, [String]) async -> NativeRPCValue
    public typealias Index = @Sendable () async -> NativeRPCValue
    public struct ClaudeOperations: Sendable {
        public let add: @Sendable (NativeRPCValue) async -> NativeRPCValue
        public let remove: @Sendable (NativeRPCValue) async -> NativeRPCValue
        public init(add: @escaping @Sendable (NativeRPCValue) async -> NativeRPCValue,
                    remove: @escaping @Sendable (NativeRPCValue) async -> NativeRPCValue) { self.add = add; self.remove = remove }
    }
    private let userData: URL, environment: [String: String], home: String, writable: Bool
    private let loadIndex: Index, fetch: FetchArtifact, runAgent: RunAgent
    private let claudeAdd: @Sendable (NativeRPCValue) async -> NativeRPCValue
    private let claudeRemove: @Sendable (NativeRPCValue) async -> NativeRPCValue
    private let environmentNames: @Sendable () async throws -> Set<String>
    private let now: @Sendable () -> Date
    private var mutating = false
    private struct Write: Sendable {
        let kind: String, path: String; let agent: String?
        init(_ kind: String, _ path: String, agent: String? = nil) { self.kind = kind; self.path = path; self.agent = agent }
        var wire: NativeRPCValue { .object([.init("kind", .string(kind)), .init("path", .string(path)), .init("agent", agent.map(NativeRPCValue.string) ?? .missing)]) }
        init?(_ raw: NativeRPCValue) { guard let kind = raw["kind"].string, let path = raw["path"].string else { return nil }; self.kind = kind; self.path = path; agent = raw["agent"].string }
    }
    private struct KindResult { let ok: Bool, message: String; let writes: [Write] }
    private struct TreeWriteFailure: Error, LocalizedError {
        let writes: [Write]; let cause: Error
        var errorDescription: String? { cause.localizedDescription }
    }
    public init(userData: URL, environment: [String: String], home: String, writable: Bool = false,
                loadIndex: @escaping Index, fetchArtifact: @escaping FetchArtifact = BackendOSStoreInstaller.fetchArtifact,
                runAgent: @escaping RunAgent = { _, _ in .object([.init("ok", .bool(false)), .init("message", .string("The native agent command runner is unavailable."))]) },
                claudeMCP: BackendMcpClientWriter? = nil, claudeOperations: ClaudeOperations? = nil,
                environmentNames: @escaping @Sendable () async throws -> Set<String> = { [] },
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/"), home.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Community installation needs the app's own data root and absolute user home.") }
        self.userData = userData.standardizedFileURL; self.environment = environment; self.home = home; self.writable = writable
        self.loadIndex = loadIndex; fetch = fetchArtifact; self.runAgent = runAgent; self.environmentNames = environmentNames; self.now = now
        claudeAdd = { request in if let claudeOperations { return await claudeOperations.add(request) }; guard let claudeMCP else { return Self.result(false, "The native Claude MCP configuration writer is unavailable.") }; return await claudeMCP.add(request) }
        claudeRemove = { request in if let claudeOperations { return await claudeOperations.remove(request) }; guard let claudeMCP else { return Self.result(false, "The native Claude MCP configuration writer is unavailable.") }; return await claudeMCP.remove(request) }
    }
    public static func agentHome(_ agent: String, environment: [String: String], home: String) -> String {
        let key = agent == "claude" ? "CLAUDE_CONFIG_DIR" : agent == "codex" ? "CODEX_HOME" : "GEMINI_CLI_HOME"
        let configured = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent == "gemini" { return URL(fileURLWithPath: configured.flatMap { $0.isEmpty ? nil : $0 } ?? home).appendingPathComponent(".gemini").path }
        return configured.flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: home).appendingPathComponent(agent == "claude" ? ".claude" : ".codex").path
    }
    public static func agentHomes(environment: [String: String], home: String) -> NativeRPCValue { .object(BackendSharedStoreManifest.agents.map { .init($0, .string(agentHome($0, environment: environment, home: home))) }) }
    public static func itemsDirectory(_ userData: URL) -> URL { userData.appendingPathComponent("community/items") }
    public static func ledgerFile(_ userData: URL) -> URL { userData.appendingPathComponent("community/installed.json") }
    public static func backupsDirectory(_ userData: URL) -> URL { userData.appendingPathComponent("community/backups") }
    public static func folderName(publisher: String, item: String) -> String { publisher + "." + item }
    public static func plannedTargets(row: NativeRPCValue, agents: [String], homes: NativeRPCValue, userData: String) -> [String] {
        BackendCommunityProjection.plannedTargets(row: row, agents: agents, homes: homes, userData: userData)
    }
    private static let installable = ["skill", "instructions", "mcp", "routine"]
    public static let unsupported: [String: String] = [
        "hooks": "Hook sets are not installed from the store in this version. The Hooks screen writes them.",
        "extension": "Chrome extensions are retired in the native Mac app, so this item cannot be installed.",
        "tool": "This is a listing, not a download. Open it with the link on the row."]
    private static func result(_ ok: Bool, _ message: String) -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
    public static func readLedger(_ userData: URL) -> [NativeRPCValue] {
        guard let data = try? Data(contentsOf: ledgerFile(userData)), let parsed = try? NativeRPCValue.parseJSON(data), parsed.fields != nil,
              let entries = parsed["items"].elements else { return [] }
        return entries.filter { $0["id"].string != nil && $0["root"].string != nil && $0["writes"].elements != nil }
    }
    public func installed() -> [NativeRPCValue] { Self.readLedger(userData) }
    private func writeLedger(_ records: [NativeRPCValue]) throws { try Self.writeAtomic(.object([.init("v", .number(1)), .init("items", .array(records))]), file: Self.ledgerFile(userData)) }
    public static func treeDigest(_ files: [BackendOSStoreArchive.File]) -> String {
        var hash = SHA256()
        for file in files.sorted(by: { $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }) {
            hash.update(data: Data(file.path.utf8)); hash.update(data: Data([0])); hash.update(data: Data(SHA256.hash(data: file.bytes))); hash.update(data: Data([10]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func readTree(_ root: URL, prefix: String = "") -> [BackendOSStoreArchive.File] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [BackendOSStoreArchive.File] = []
        for name in names.sorted() {
            let url = root.appendingPathComponent(name), path = prefix.isEmpty ? name : prefix + "/" + name
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true { result += readTree(url, prefix: path) }
            else if values.isRegularFile == true, let bytes = try? Data(contentsOf: url) { result.append(.init(path: path, bytes: bytes)) }
        }
        return result
    }
    private func homes() -> NativeRPCValue { Self.agentHomes(environment: environment, home: home) }
    /// The screen's plan is the installer's source of filesystem destinations.
    /// One-agent plans identify that agent's payload and optional memory file;
    /// index zero is always the retained item root, including for MCP items.
    private func plannedDestination(row: NativeRPCValue, agents: [String], at index: Int) throws -> URL {
        let plan = Self.plannedTargets(row: row, agents: agents, homes: homes(), userData: userData.path)
        guard plan.indices.contains(index), plan[index].hasPrefix("/"), !plan[index].contains("\0") else {
            throw NativeRPCError(code: "unavailable", message: "The shared community plan has no usable filesystem destination for this item.")
        }
        return URL(fileURLWithPath: plan[index])
    }
    private func baseView(_ loaded: NativeRPCValue, items: [NativeRPCValue]) -> NativeRPCValue {
        var view = loaded.removing("index").setting("items", .array(items)).setting("homes", homes()).setting("folder", .string(Self.itemsDirectory(userData).path))
        if loaded["ok"].bool == true { view = view.setting("why", .null) }
        else { for key in ["from", "at", "stale", "because"] { view = view.setting(key, .null) } }
        return view
    }
    public func view() async throws -> NativeRPCValue {
        let records = installed(), loaded = await loadIndex()
        guard loaded["ok"].bool == true else { return baseView(loaded, items: []) }
        let index = loaded["index"], rows = index["items"].elements ?? []
        var items = rows.map { row in stateOf(row, record: records.first { $0["id"] == row["id"] }, index: index) }
        for record in records where !rows.contains(where: { $0["id"] == record["id"] }) {
            items.append(Self.itemView(row: Self.rowFromRecord(record), state: "withdrawn", note: "This is no longer listed in the store. It is still installed here.", record: record))
        }
        return baseView(loaded, items: items)
    }
    private static func itemView(row: NativeRPCValue, state: String, note: String?, record: NativeRPCValue?) -> NativeRPCValue {
        .object([.init("row", row), .init("state", .string(state)), .init("note", note.map(NativeRPCValue.string) ?? .null), .init("installed", record ?? .null)])
    }
    private func stateOf(_ row: NativeRPCValue, record: NativeRPCValue?, index: NativeRPCValue) -> NativeRPCValue {
        let withdrawn = BackendAppStoreIndex.revocation(index, id: row["id"].string ?? "", version: record?["version"].string ?? row["version"].string ?? "")
        let state: String, note: String?
        if let record {
            if Self.treeDigest(Self.readTree(URL(fileURLWithPath: record["root"].string ?? ""))) != record["tree"].string {
                state = "damaged"; note = "The copy on this machine no longer matches what was installed. Remove it and install it again."
            } else if let withdrawn { state = "withdrawn"; note = "Withdrawn after you installed it: \(withdrawn["reason"].string ?? "")" }
            else if record["version"] != row["version"] { state = "outdated"; note = "Version \(row["version"].string ?? "") is available." }
            else { state = "installed"; note = nil }
        } else if let withdrawn { state = "withdrawn"; note = "Withdrawn: \(withdrawn["reason"].string ?? "")" }
        else if !Self.installable.contains(row["kind"].string ?? "") { state = "unsupported"; note = Self.unsupported[row["kind"].string ?? ""] }
        else if !(row["platforms"].elements ?? []).contains(.string("darwin")) { state = "unsupported"; note = "This item does not run on this kind of computer." }
        else { state = "available"; note = nil }
        return Self.itemView(row: row, state: state, note: note, record: record)
    }
    public func install(id: String, choice raw: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        guard writable else { throw NativeRPCError(code: "unavailable", message: "The community installer cannot write while Node owns the app's data.") }
        guard !mutating else { throw NativeRPCError(code: "unavailable", message: "Another community installation is changing files. Try again when it finishes.") }; mutating = true; defer { mutating = false }
        let choice = BackendCommunityChannels.readChoice(raw), records = installed()
        if records.contains(where: { $0["id"].string == id }) { return Self.result(false, "This is already installed. Remove it first to install it again.") }
        let loaded = await loadIndex()
        guard loaded["ok"].bool == true else { return Self.result(false, loaded["why"].string ?? "The community store could not be read.") }
        guard let row = loaded["index"]["items"].elements?.first(where: { $0["id"].string == id }) else { return Self.result(false, "This store has no item with that name.") }
        if let withdrawn = BackendAppStoreIndex.revocation(loaded["index"], id: id, version: row["version"].string ?? "") { return Self.result(false, "This has been withdrawn: \(withdrawn["reason"].string ?? "")") }
        let kind = row["kind"].string ?? ""
        guard Self.installable.contains(kind) else { return Self.result(false, Self.unsupported[kind] ?? "This app does not install that kind of item.") }
        guard (row["platforms"].elements ?? []).contains(.string("darwin")) else { return Self.result(false, "This item does not run on this kind of computer.") }
        let artifact = row["artifact"]
        guard row["delivery"].string == "repo", !artifact.isNullish, !row["install"].isNullish else { return Self.result(false, "This item is a listing rather than a download, so there is nothing to install.") }
        let known = BackendSharedStoreManifest.agents.filter { (row["agents"].elements ?? []).contains(.string($0)) }
        if kind != "routine" && known.isEmpty { return Self.result(false, "This item names no coding tool this app can write to.") }
        let asked = choice["agents"].elements?.compactMap(\.string) ?? known, agents = kind == "routine" ? [] : known.filter(asked.contains)
        if kind != "routine" && agents.isEmpty { return Self.result(false, "Choose at least one tool to install this into.") }
        let downloaded = await fetch(artifact["url"].string ?? "", BackendOSStoreArchive.Limits.small.archiveBytes)
        if !downloaded.ok { return Self.result(false, downloaded.message) }
        guard artifact["bytes"].number == Double(downloaded.bytes.count), BackendAppStoreIndex.artifactMatches(downloaded.bytes, expectedHex: artifact["sha256"].string ?? "") else { return Self.result(false, BackendAppStoreIndex.digestRefusal) }
        let opened = BackendOSStoreArchive.read(downloaded.bytes)
        guard let unpacked = opened.files else { return Self.result(false, opened.why ?? "This item’s archive is empty.") }
        let files = BackendOSStoreArchive.stripSingleRoot(unpacked)
        guard !files.isEmpty else { return Self.result(false, "This item’s archive is empty.") }
        guard let manifestFile = BackendOSStoreArchive.fileAt(files, path: BackendSharedStoreManifest.manifestFile) else { return Self.result(false, "This item ships no \(BackendSharedStoreManifest.manifestFile), so there is nothing to check it against.") }
        let publisher = row["publisher"].string ?? "", item = id.components(separatedBy: "/").dropFirst().first ?? id
        let parsed = BackendSharedStoreManifest.parse(String(decoding: manifestFile.bytes, as: UTF8.self), expectedPublisher: publisher, expectedID: item)
        guard let manifest = parsed.value else { return Self.result(false, parsed.why ?? "This manifest could not be read.") }
        if let disagreement = Self.disagrees(row: row, manifest: manifest) { return Self.result(false, disagreement) }
        let tier = BackendSharedStoreManifest.deriveTier(kind: kind, files: files.map { .init(path: $0.path, bytes: $0.bytes.count, mode: $0.mode) })
        if Double(tier.tier) > (row["tier"].number ?? 0) { return Self.result(false, "The store says this reaches less of your machine than it does: the list says \(Int(row["tier"].number ?? 0)), and what arrived is \(tier.tier), because \(tier.because). Nothing was installed.") }
        let folder = Self.folderName(publisher: publisher, item: item)
        let root = try plannedDestination(row: row, agents: agents, at: 0)
        var writes: [Write] = []
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            writes = try Self.writeTree(root, files: files)
            let applied = await installKind(row: row, manifest: manifest, item: item, folder: folder, files: files, agents: agents, choice: choice)
            if !applied.ok { await rollback(applied.writes, marker: folder); try? FileManager.default.removeItem(at: root); return Self.result(false, applied.message) }
            writes += applied.writes
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var record = NativeRPCValue.object([])
            for key in ["id", "publisher", "kind", "name", "summary", "version", "licence", "category"] { record = record.setting(key, row[key]) }
            record = record.setting("item", .string(item)).setting("repo", row["source"]["repo"]).setting("commit", row["source"]["commit"]).setting("sha256", artifact["sha256"])
                .setting("tier", .number(Double(tier.tier))).setting("agents", .array(agents.map(NativeRPCValue.string))).setting("installedAt", .string(formatter.string(from: now())))
                .setting("root", .string(root.path)).setting("tree", .string(Self.treeDigest(files))).setting("writes", .array(writes.map(\.wire)))
            try writeLedger(records + [record]); return Self.result(true, applied.message)
        } catch { await rollback(writes, marker: folder); try? FileManager.default.removeItem(at: root); return Self.result(false, error.localizedDescription) }
    }
    private func installKind(row: NativeRPCValue, manifest: NativeRPCValue, item: String, folder: String, files: [BackendOSStoreArchive.File], agents: [String], choice: NativeRPCValue) async -> KindResult {
        let install = manifest["install"], kind = install["kind"].string ?? ""; var writes: [Write] = []
        func failed(_ message: String) -> KindResult { .init(ok: false, message: message, writes: writes) }
        do {
            if kind == "skill" {
                let dir = install["dir"].string ?? ".", selected = BackendOSStoreArchive.filesUnder(files, directory: dir)
                guard BackendOSStoreArchive.fileAt(selected, path: "SKILL.md") != nil else { return failed("This skill has no SKILL.md\(dir == "." ? "" : " in " + dir).") }
                for agent in agents {
                    let target = try plannedDestination(row: row, agents: [agent], at: 1)
                    if FileManager.default.fileExists(atPath: target.path) { return failed("There is already a folder at \(target.path), so nothing was written.") }
                    writes += try Self.writeTree(target, files: selected)
                    if agent == "codex" {
                        let memory = try plannedDestination(row: row, agents: [agent], at: 2)
                        try Self.writeBlock(file: memory, marker: folder, body: "Skill available: \(manifest["name"].string ?? "") — \(target.path)/SKILL.md", backups: Self.backupsDirectory(userData))
                        writes.append(Write("block", memory.path, agent: agent))
                    }
                }
            } else if kind == "instructions" {
                let sourcePath = install["file"].string ?? ""
                guard let source = BackendOSStoreArchive.fileAt(files, path: sourcePath) else { return failed("This item has no \(sourcePath) in it.") }
                for agent in agents {
                    let target = try plannedDestination(row: row, agents: [agent], at: 1)
                    try Self.writeAtomic(Data(String(decoding: source.bytes, as: UTF8.self).utf8), file: target); writes.append(Write("file", target.path))
                    let memory = try plannedDestination(row: row, agents: [agent], at: 2), body = agent == "codex" ? "Standing instructions: \(manifest["name"].string ?? "") — \(target.path)" : "@instructions/\(folder).md"
                    try Self.writeBlock(file: memory, marker: folder, body: body, backups: Self.backupsDirectory(userData)); writes.append(Write("block", memory.path, agent: agent))
                }
            } else if kind == "routine" {
                let sourcePath = install["file"].string ?? ""
                guard let source = BackendOSStoreArchive.fileAt(files, path: sourcePath) else { return failed("This item has no \(sourcePath) in it.") }
                let selectedFolder = choice["folder"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !selectedFolder.isEmpty else { return failed("Choose the folder this routine will run in before installing it.") }
                let id = (row["publisher"].string ?? "") + "-" + item
                let parsed = BackendRoutinesFormat.parseRoutine(id, text: Self.setRoutineFolder(String(decoding: source.bytes, as: UTF8.self), folder: selectedFolder))
                guard var routine = parsed.routine else { return failed(parsed.problems.joined(separator: " ")) }; routine.enabled = false
                let target = try plannedDestination(row: row, agents: [], at: 1)
                guard !FileManager.default.fileExists(atPath: target.path) else { return failed("There is already a routine called \(id), so nothing was written.") }
                try Self.writeAtomic(Data(BackendRoutinesFormat.serializeRoutine(routine).utf8), file: target); writes.append(Write("file", target.path))
                return .init(ok: true, message: "Installed \(manifest["name"].string ?? ""), switched off.", writes: writes)
            } else if kind == "mcp" {
                let name = Self.mcpName(row)
                let entry: NativeRPCValue = .object([.init("name", manifest["name"]), .init("command", .string(BackendSharedStoreManifest.composeMcpCommand(install))), .init("inputs", install["inputs"])])
                let built = try BackendMcpClientStoreRules.buildInstall(entry, values: choice["values"], available: try await environmentNames()), argv = try BackendMcpClientCommands.tokenize(built.command)
                for agent in agents {
                    let added: NativeRPCValue
                    if agent == "claude" { added = await claudeAdd(.object([.init("name", .string(name)), .init("scope", .string("user")), .init("transport", .string("stdio")), .init("command", .string(built.command)), .init("url", .string("")), .init("extras", .array(built.extras.map(NativeRPCValue.string))), .init("projectPath", .null)])) }
                    else { added = await runAgent(agent, Self.mcpAddArguments(agent: agent, name: name, argv: argv, extras: built.extras)) }
                    guard added["ok"].bool == true else { return failed(added["message"].string ?? "The native MCP writer did not answer.") }
                    writes.append(Write("server", name, agent: agent))
                }
                return .init(ok: true, message: "Added \(name).", writes: writes)
            } else { return failed(Self.unsupported[kind] ?? "This app does not install that kind of item.") }
            return .init(ok: true, message: "Installed \(manifest["name"].string ?? "").", writes: writes)
        } catch {
            if let tree = error as? TreeWriteFailure { writes += tree.writes }
            return failed(error.localizedDescription)
        }
    }
    public func remove(id: String) async throws -> NativeRPCValue {
        guard writable else { throw NativeRPCError(code: "unavailable", message: "The community installer cannot write while Node owns the app's data.") }
        guard !mutating else { throw NativeRPCError(code: "unavailable", message: "Another community installation is changing files. Try again when it finishes.") }; mutating = true; defer { mutating = false }
        let records = installed(); guard let record = records.first(where: { $0["id"].string == id }) else { return Self.result(false, "That is not installed.") }
        var left: [NativeRPCValue] = [], problems: [String] = []
        for raw in (record["writes"].elements ?? []).reversed() {
            guard let write = Write(raw) else { left.insert(raw, at: 0); problems.append("An installed write record could not be read."); continue }
            if let problem = await undoOne(write, record: record) { left.insert(raw, at: 0); problems.append(problem) }
        }
        if !left.isEmpty { try writeLedger(records.map { $0["id"].string == id ? $0.setting("writes", .array(left)) : $0 }); return Self.result(false, "Some of it could not be removed: " + problems.joined(separator: " ")) }
        try writeLedger(records.filter { $0["id"].string != id }); return Self.result(true, "Removed \(record["name"].string ?? "").")
    }
    private func undoOne(_ write: Write, record: NativeRPCValue) async -> String? {
        do {
            let marker = Self.folderName(publisher: record["publisher"].string ?? "", item: record["item"].string ?? "")
            if write.kind == "server" {
                let agent = write.agent ?? "claude", gone = agent == "claude" ? await claudeRemove(.object([.init("name", .string(write.path)), .init("scope", .string("user")), .init("projectPath", .null)])) : await runAgent(agent, Self.mcpRemoveArguments(agent: agent, name: write.path))
                return gone["ok"].bool == true ? nil : "\(CodingAICatalog.label(agent)) could not remove \(write.path): \(gone["message"].string ?? "The native writer did not answer.")"
            }
            if write.kind == "block" { _ = try Self.removeBlock(file: URL(fileURLWithPath: write.path), marker: marker); return nil }
            if write.kind == "file" {
                if FileManager.default.fileExists(atPath: write.path) {
                    let properties = try URL(fileURLWithPath: write.path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard properties.isDirectory != true || properties.isSymbolicLink == true else { throw NativeRPCError(code: "remove-refused", message: "A directory now occupies this file's path, so it was left alone.") }
                    try FileManager.default.removeItem(atPath: write.path)
                }
                return nil
            }
            Self.pruneEmpty(URL(fileURLWithPath: write.path)); return nil
        } catch { return "\(write.path): \(error.localizedDescription)" }
    }
    private func rollback(_ writes: [Write], marker: String) async {
        for write in writes.reversed() {
            if write.kind == "server" { let agent = write.agent ?? "claude"; if agent == "claude" { _ = await claudeRemove(.object([.init("name", .string(write.path)), .init("scope", .string("user")), .init("projectPath", .null)])) } else { _ = await runAgent(agent, Self.mcpRemoveArguments(agent: agent, name: write.path)) } }
            else if write.kind == "block" { _ = try? Self.removeBlock(file: URL(fileURLWithPath: write.path), marker: marker) }
            else { try? FileManager.default.removeItem(atPath: write.path) }
        }
    }
    public static func mcpName(_ row: NativeRPCValue) -> String { (row["publisher"].string ?? "") + "-" + (row["id"].string?.components(separatedBy: "/").dropFirst().first ?? row["id"].string ?? "") }
    public static func mcpAddArguments(agent: String, name: String, argv: [String], extras: [String]) -> [String] {
        agent == "codex" ? ["mcp", "add", name] + extras.flatMap { ["--env", $0] } + ["--"] + argv : ["mcp", "add", "-s", "user", "-t", "stdio"] + extras.flatMap { ["-e", $0] } + [name] + argv
    }
    public static func mcpRemoveArguments(agent: String, name: String) -> [String] { agent == "codex" ? ["mcp", "remove", name] : ["mcp", "remove", "-s", "user", name] }
    public static func setRoutineFolder(_ text: String, folder: String) -> String {
        let document = BackendRoutinesFormat.splitDocument(text), kept = document.header.filter { $0.range(of: #"^\s*in\s*:"#, options: [.regularExpression, .caseInsensitive]) == nil }
        return (document.heading.map { "# \($0)\n\n" } ?? "") + (kept + ["in: " + folder]).joined(separator: "\n") + "\n\n---\n\n" + (document.prompt ?? "") + "\n"
    }
    public static func sameInstall(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool { stable(a) == stable(b) }
    private static func stable(_ value: NativeRPCValue) -> String {
        if let array = value.elements { return "[" + array.map(stable).joined(separator: ",") + "]" }
        if let fields = value.fields { return "{" + fields.sorted { $0.key < $1.key }.map { NativeRPCValue.string($0.key).compact + ":" + stable($0.value) }.joined(separator: ",") + "}" }
        return value.compact
    }
    private static func disagrees(row: NativeRPCValue, manifest: NativeRPCValue) -> String? {
        if row["kind"] != manifest["kind"] { return "The store listed this as a \(row["kind"].string ?? "") and the download says it is a \(manifest["kind"].string ?? ""). Nothing was installed." }
        if row["version"] != manifest["version"] { return "The store listed version \(row["version"].string ?? "") and the download says \(manifest["version"].string ?? ""). Nothing was installed." }
        if !sameInstall(row["install"], manifest["install"]) { return "What the store said this would do and what the download does are not the same. Nothing was installed." }; return nil
    }
    private static func writeTree(_ root: URL, files: [BackendOSStoreArchive.File]) throws -> [Write] {
        var writes = [Write("dir", root.path)]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for file in files {
                guard BackendOSStoreArchive.safePath(file.path) != nil else { throw NativeRPCError(code: "archive-refused", message: "The install tree contains a path this app will not write.") }
                let target = root.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.bytes.write(to: target); writes.append(Write("file", target.path))
            }
            return writes
        } catch { throw TreeWriteFailure(writes: writes, cause: error) }
    }
    private static func writeAtomic(_ value: NativeRPCValue, file: URL) throws { try writeAtomic(try value.encodedJSON(pretty: true) + Data([10]), file: file) }
    private static func writeAtomic(_ bytes: Data, file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = URL(fileURLWithPath: file.path + ".\(getpid()).\(UUID().uuidString).tmp"); defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary); guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    public static func blockMarkers(_ name: String) -> (start: String, end: String) { ("<!-- terminaldeck-store \(name) -->", "<!-- /terminaldeck-store \(name) -->") }
    public static func stripBlock(_ text: String, marker: String) -> String {
        let markers = blockMarkers(marker)
        guard let start = text.range(of: markers.start), let end = text.range(of: markers.end, range: start.lowerBound..<text.endIndex) else { return text }
        let head = String(text[..<start.lowerBound]).replacingOccurrences(of: #"\n+$"#, with: "\n", options: .regularExpression)
        let tail = String(text[end.upperBound...]).replacingOccurrences(of: #"^\n+"#, with: "", options: .regularExpression)
        return (head + tail).replacingOccurrences(of: #"^\n+"#, with: "", options: .regularExpression)
    }
    public static func writeBlock(file: URL, marker: String, body: String, backups: URL?) throws {
        let exists = FileManager.default.fileExists(atPath: file.path), current = exists ? try String(contentsOf: file, encoding: .utf8) : ""
        if exists, let backups {
            let backup = backups.appendingPathComponent(file.path.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression))
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true); try? FileManager.default.copyItem(at: file, to: backup) }
        }
        let stripped = stripBlock(current, marker: marker), spacer = stripped.isEmpty || stripped.hasSuffix("\n\n") ? "" : stripped.hasSuffix("\n") ? "\n" : "\n\n", markers = blockMarkers(marker)
        try writeAtomic(Data((stripped + spacer + markers.start + "\n" + body + "\n" + markers.end + "\n").utf8), file: file)
    }
    public static func removeBlock(file: URL, marker: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let current = try String(contentsOf: file, encoding: .utf8), stripped = stripBlock(current, marker: marker)
        if current == stripped { return false }; try writeAtomic(Data(stripped.utf8), file: file); return true
    }
    private static func pruneEmpty(_ directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries { let child = directory.appendingPathComponent(entry); if (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true { pruneEmpty(child) } }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { _ = rmdir(directory.path) }
    }
    private static func rowFromRecord(_ record: NativeRPCValue) -> NativeRPCValue {
        var row = NativeRPCValue.object([])
        for key in ["id", "publisher", "kind", "name", "summary", "version", "licence", "category", "agents", "tier"] { row = row.setting(key, record[key]) }
        row = row.setting("listedBy", record["publisher"]).setting("cost", .string("free")).setting("costNote", .null).setting("delivery", .string("repo"))
            .setting("source", .object([.init("repo", record["repo"]), .init("commit", record["commit"]), .init("path", .string(".")), .init("host", .string(""))]))
            .setting("publishedAt", record["installedAt"]).setting("updatedAt", record["installedAt"])
        for key in ["tags", "platforms", "needs", "network"] { row = row.setting(key, .array([])) }
        for key in ["artifact", "install", "icon", "ai", "repoStats"] { row = row.setting(key, .null) }; return row
    }
    public static func fetchArtifact(_ raw: String, _ limit: Int) async -> Artifact {
        guard let parts = URLComponents(string: raw), let url = parts.url, let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return Artifact(ok: false, message: "that is not a URL") }
        guard scheme == "https" || scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return Artifact(ok: false, message: "this item can only be downloaded over https") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse else { return Artifact(ok: false, message: "the download failed") }
            guard (200..<300).contains(response.statusCode) else { return Artifact(ok: false, message: "the download answered \(response.statusCode)") }
            var data = Data()
            for try await byte in stream { guard data.count < limit else { return Artifact(ok: false, message: "the download is larger than this app will read") }; data.append(byte) }
            return Artifact(ok: true, bytes: data)
        } catch { return Artifact(ok: false, message: "the download failed: " + error.localizedDescription) }
    }
}

/// Native command implementation for Codex/Gemini. Claude uses the existing
/// MCP writer. The actual resolved provider binary and login PATH are reused.
public struct BackendOSStoreAgentRunner: Sendable {
    private let providers: BackendNativeProviders, runner: BackendCommandRunner, environment: [String: String], home: String
    public init(providers: BackendNativeProviders, runner: BackendCommandRunner, environment: [String: String], home: String) { self.providers = providers; self.runner = runner; self.environment = environment; self.home = home }
    public func run(agent: String, arguments: [String]) async -> NativeRPCValue {
        do {
            let path = try await providers.loginPath(), binary = await providers.resolveBinary(agent, path: path)
            guard let command = binary.runnable else { return .object([.init("ok", .bool(false)), .init("message", .string("\(CodingAICatalog.label(agent))’s command line tool could not be found, and it is what writes this configuration. Install it, then try again."))]) }
            var environment = self.environment; environment["PATH"] = path
            let output = try await runner.run(command: command, arguments: arguments, environment: environment, cwd: home, timeoutMilliseconds: 30_000)
            let said = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = said.isEmpty && !output.succeeded ? (output.timedOut ? "Command timed out after 30000ms" : output.outputLimited ? "Command output exceeded the supported size" : "Command failed") : said
            return .object([.init("ok", .bool(output.succeeded)), .init("message", .string(message))])
        } catch { return .object([.init("ok", .bool(false)), .init("message", .string(error.localizedDescription))]) }
    }
}
