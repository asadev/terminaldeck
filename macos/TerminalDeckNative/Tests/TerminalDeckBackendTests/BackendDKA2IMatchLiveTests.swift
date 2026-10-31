import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Every Docker HTTP request passes through here. Only GET and HEAD reach the
/// server; anything else is refused locally and counted. This is a second wall
/// behind Look only, so a regression can never change production.
private actor BackendDKA2ReadOnlyTransport: BackendDockerTransport {
    let inner: any BackendDockerTransport
    private(set) var blocked: [String] = []
    private(set) var reads = 0
    init(_ inner: any BackendDockerTransport) { self.inner = inner }
    private func allow(_ request: BackendDockerRequest) throws {
        guard ["GET", "HEAD"].contains(request.method) else {
            blocked.append(request.method + " " + (request.path.split(separator: "?").first.map(String.init) ?? ""))
            throw NativeRPCError(code: "unavailable", message: "DKA2 read-only harness refused a change.")
        }
        reads += 1
    }
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse { try allow(request); return try await inner.request(request) }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream { try allow(request); return try await inner.stream(request) }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex {
        blocked.append("HIJACK " + request.path)
        throw NativeRPCError(code: "unavailable", message: "DKA2 read-only harness refused a terminal.")
    }
}

/// DKA2 live proof against Asad's iMatch production server, READ ONLY, opt-in:
/// TD_DKA2_IMATCH=imza-server and TD_DKA2_HELPER. Uses the app's own code: the
/// SSH-settings dialer, the server room (server page data), the Docker service
/// and channels, and the shared Look only rule. Never execs, never writes files,
/// never pulls or prunes, never reads env values or .env files. Output keeps
/// names, states and counts only; log lines are counted, not printed.
final class BackendDKA2IMatchLiveTests: XCTestCase {
    func testIMatchReadOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment["TD_DKA2_IMATCH"] else { throw XCTSkip("Live iMatch check is opt-in.") }
        guard alias == "imza-server" else { XCTFail("This check is only for imza-server."); return }
        let helper = URL(fileURLWithPath: try XCTUnwrap(environment["TD_DKA2_HELPER"], "TD_DKA2_HELPER"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = BackendServersS4RealTemp.directory().appendingPathComponent("dka2-imatch-" + UUID().uuidString.prefix(8))
        let scratch = URL(fileURLWithPath: "/private/tmp/dka2i-" + UUID().uuidString.prefix(6), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: scratch) }
        var timings: [NativeRPCValue.Field] = []
        func timed<T>(_ name: String, _ work: () async throws -> T) async throws -> T {
            let mark = Date(); let value = try await work()
            timings.append(.init(name, .number((Date().timeIntervalSince(mark) * 100).rounded() / 100))); return value
        }

        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        let store = BackendServersStore(dataRoot: root, policy: policy)
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { String(decoding: $0, as: UTF8.self) }, encrypt: { text, _ in Data(text.utf8) })
        let ssh = BackendServersSSH(scratchRoot: scratch,
            policy: .init(mayConnect: true, helperExecutable: helper, helperDispatchInstalled: FileManager.default.isExecutableFile(atPath: helper.path)),
            sshHome: home, agentSocket: BackendServersSSH.personAgentSocket())
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: policy, keyValidator: ssh.keyValidator())
        let connections = BackendServersConnections(store: store, credentials: credentials, dialer: ssh)
        let room = BackendServersCoordinator(store: store, connections: connections,
            grants: .init(assistantName: "Hoot", knows: { (try? store.get($0)) != nil }), journal: BackendServersMemoryJournal(),
            storageDirectory: root, authorize: { _, _ in }, download: nil)
        let window = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "dka2-imatch"))

        // 1. Add from SSH settings, Look only (scratch store; Asad's own app data is untouched).
        let resolved = try await timed("resolveSSHSettings") { try await BackendDockerMCPServerSSHConfig().resolve(alias: alias, home: home) }
        let row = try store.add(.init(name: "iMatch production", address: resolved.hostname, port: resolved.port, username: resolved.user),
                                sshAlias: alias, lookOnly: true)
        let lease = try await timed("signIn") { try await connections.acquireLease(row.id) }
        defer { Task { await connections.release(lease); await connections.closeAll() } }
        let pinned = try XCTUnwrap(try store.get(row.id)?.hostKey?.fingerprint)

        // 2. Server page data (the same room.look the Servers page calls).
        let view = try await timed("serverPage") { try await room.look(row.id, caller: window, holdSurface: false) }
        let page = try view.wireValue()
        let facts = page["facts"]
        let cards = page["cards"].elements ?? []

        // 3. Docker through the real service + channels, with the composition's
        //    Look only rule and the read-only wall underneath.
        let guarded = BackendDKA2ReadOnlyTransport(BackendDockerSSHTransport(openDialStdio: { command in
            guard command == BackendDockerSSHTransport.command else { throw NativeRPCError(code: "access-denied", message: "fixed command only") }
            return try await connections.dockerDialStdio(row.id)
        }))
        let client = BackendDockerClient(transport: guarded)
        let lookOnly: @Sendable (String) async throws -> Bool = { try store.get($0)?.isLookOnly == true }
        let askedToChange = BackendDeckCoreSecurityTestBox<[String]>([])
        let docker = BackendDockerService(dependencies: .init(resolve: { _, _ in client },
            targets: { _ in [.init(id: row.id, name: row.name, kind: "server", platform: "linux", lookOnly: true)] },
            authorize: { action, _ in
                try await BackendDockerMCPServerApproval.refuseIfLookOnly(target: action.target.isEmpty ? nil : action.target,
                    changing: action.writesServer || action.channel == "docker:install", lookOnly: lookOnly)
                if action.writesServer { askedToChange.edit { $0.append(action.channel) } }
            }, install: nil))
        let registry = NativeChannelRegistry()
        try await BackendDockerChannels.register(registry: registry, service: docker)
        let rpc = NativeRPCContext(caller: .nativeApp, ownerID: "dka2-imatch")
        func read(_ channel: String, _ extra: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
            try await registry.invoke(channel, context: rpc, arguments: [.object([.init("target", .string(row.id))] + extra)])
        }
        let status = try await timed("dockerStatus") { try await read("docker:status") }
        let containersReply = try await timed("containers") { try await read("docker:containers:list", [.init("all", .bool(true))]) }
        let imagesReply = try await timed("images") { try await read("docker:images:list") }
        let volumesReply = try await timed("volumes") { try await read("docker:volumes:list") }
        let networksReply = try await timed("networks") { try await read("docker:networks:list") }
        let composeReply = try await timed("compose") { try await read("docker:compose:list") }
        let containers = containersReply["containers"].elements ?? [], images = imagesReply["images"].elements ?? []
        let volumes = volumesReply["volumes"].elements ?? [], networks = networksReply["networks"].elements ?? []
        let compose = composeReply["projects"].elements ?? []
        let running = containers.filter { $0["state"].string == "running" }
        var logs: [NativeRPCValue] = []
        for row2 in running.prefix(2) {
            let id = try XCTUnwrap(row2["id"].string)
            let window = try await timed("logs:" + (row2["name"].string ?? id)) {
                try await BackendDockerMCPReadWindow.read(tool: "docker.logs.open",
                    arguments: .object([.init("target", .string(row.id)), .init("id", .string(id)), .init("tail", .number(20))]),
                    channel: "docker:logs:open", rpc: rpc, registry: registry)
            }
            logs.append(.object([.init("container", row2["name"]), .init("records", .number(Double(window["records"].elements?.count ?? 0))), .init("finishedBecause", window["finishedBecause"])]))
        }
        var stats: NativeRPCValue = .null, statsRecord: NativeRPCValue = .null
        if let first = running.first, let id = first["id"].string {
            let sample = try await timed("stats") {
                try await BackendDockerMCPReadWindow.read(tool: "docker.stats.open", arguments: .object([.init("target", .string(row.id)), .init("id", .string(id))]),
                    channel: "docker:stats:open", rpc: rpc, registry: registry)
            }
            let record = sample["records"].elements?.first ?? sample
            statsRecord = record
            stats = .object([.init("container", first["name"]), .init("cpuPercent", record["cpuPercent"]), .init("memoryBytes", record["memoryBytes"])])
        }

        // 3b. The pages read this same data: run the app's own UI parsers on it.
        func ui(_ value: NativeRPCValue) -> CodingAIJSON { CodingAIJSON(value.foundation ?? NSNull()) }
        let pageView = try XCTUnwrap(ServerView.parse(ui(page)), "the Servers page could not read the live view")
        XCTAssertEqual(pageView.cards.count, cards.count)
        var projected: [NativeRPCValue.Field] = [.init("serverPageCards", .number(Double(pageView.cards.count)))]
        for (section, reply, count) in [(NativeDockerSection.containers, containersReply, containers.count), (.images, imagesReply, images.count),
                                         (.volumes, volumesReply, volumes.count), (.networks, networksReply, networks.count), (.projects, composeReply, compose.count)] {
            let items = try NativeDockerContractProjection.items(section: section, reply: ui(reply))
            XCTAssertEqual(items.count, count, section.rawValue)
            projected.append(.init(section.rawValue, .number(Double(items.count))))
        }
        var inspectReply: NativeRPCValue = .null
        if let first = running.first?["id"].string {
            inspectReply = try await timed("inspect") { try await read("docker:containers:inspect", [.init("id", .string(first))]) }
            let detail = try NativeDockerContractProjection.container(ui(inspectReply))
            projected.append(.init("inspectFacts", .number(Double(detail.facts.count))))
        }
        if statsRecord != .null {
            let usage = try NativeDockerContractProjection.usage(ui(statsRecord))
            projected.append(.init("usageMemoryBytes", .number(Double(usage.memoryBytes ?? 0))))
        }

        // 4. Every Docker change is refused by Look only before approval or I/O.
        let anyContainer = containers.first?["id"].string ?? "missing"
        let anyContainerName = containers.first?["name"].string ?? "missing"
        let anyImage = images.first, anyVolume = volumes.first?["name"].string, network = networks.first { $0["name"].string == "bridge" }
        let changes: [(String, [NativeRPCValue.Field])] = [
            ("docker:containers:start", [.init("id", .string(anyContainer))]), ("docker:containers:stop", [.init("id", .string(anyContainer))]),
            ("docker:containers:restart", [.init("id", .string(anyContainer))]),
            ("docker:containers:remove", [.init("id", .string(anyContainer)), .init("confirmName", .string(anyContainerName))]),
            ("docker:containers:upload", [.init("id", .string(anyContainer)), .init("files", .array([.object([.init("name", .string("dka2-never.txt")), .init("data", .string("eA=="))])]))]),
            ("docker:images:remove", [.init("id", .string(anyImage?["id"].string ?? "missing")), .init("confirmName", .string(anyImage?["tags"].elements?.first?.string ?? anyImage?["id"].string ?? "missing"))]),
            ("docker:volumes:create", [.init("name", .string("td-dka2-never"))]),
            ("docker:volumes:remove", [.init("name", .string(anyVolume ?? "td-dka2-never")), .init("confirmName", .string(anyVolume ?? "td-dka2-never"))]),
            ("docker:networks:create", [.init("name", .string("td-dka2-never"))]),
            ("docker:networks:remove", [.init("id", .string(network?["id"].string ?? "bridge")), .init("confirmName", .string("bridge"))]),
            ("docker:exec:open", [.init("id", .string(anyContainer)), .init("command", .array([.string("true")]))]),
            ("docker:install", [])]
        var refusals: [NativeRPCValue] = []
        for (channel, fields) in changes {
            var code = "ran", message = ""
            do { _ = try await read(channel, fields) }
            catch let error as NativeRPCError { code = error.code; message = error.message }
            refusals.append(.object([.init("channel", .string(channel)), .init("code", .string(code))]))
            XCTAssertEqual(code, "look-only", "\(channel): \(message)")
        }
        // The same rule across every MCP tool catalogue that can change things.
        var toolRefusals = 0, toolReads = 0
        for tool in try BackendDockerMCP.definitions() {
            do { try await BackendDockerMCPServerApproval.refuseIfLookOnly(target: row.id, changing: BackendDockerMCP.changes(tool: tool.id), lookOnly: lookOnly); toolReads += 1 }
            catch { toolRefusals += 1 }
            XCTAssertEqual(BackendDockerMCP.changes(tool: tool.id), tool.tier != .read)
        }
        var appRefusals = 0, appReads = 0
        for tool in BackendAppsMCP.definitions() {
            do { try await BackendDockerMCPServerApproval.refuseIfLookOnly(target: row.id, changing: tool.tier != .read, lookOnly: lookOnly); appReads += 1 }
            catch { appRefusals += 1; XCTAssertNotEqual(tool.tier, .read) }
        }
        var serverRefusals = 0
        for operation in BackendServersCoordinator.lookOnlyRefusedForEveryone.sorted() {
            do { try await room.check(window, .init(operation: operation, serverId: row.id, tier: .alter)) } catch { serverRefusals += 1 }
        }
        let blocked = await guarded.blocked, dockerReads = await guarded.reads
        XCTAssertTrue(blocked.isEmpty, "a change reached the read-only wall: \(blocked)")
        XCTAssertTrue(askedToChange.get().isEmpty, "Look only must refuse before anyone is asked")
        await docker.shutdown()

        let record: NativeRPCValue = .object([
            .init("at", .string(ISO8601DateFormatter().string(from: Date()))), .init("alias", .string(alias)),
            .init("hostKeyPinned", .string(pinned)),
            .init("server", .object([.init("os", facts["os"]), .init("kernel", facts["kernel"]), .init("cpus", facts["cpus"]),
                .init("containerRuntime", facts["containerRuntime"]), .init("init", facts["init"]),
                .init("pageCards", .array(cards.map { .object([.init("kind", $0["kind"]), .init("name", $0["name"])]) })),
                .init("pageCannot", page["cannot"])])),
            .init("docker", .object([.init("version", status["version"]), .init("api", status["apiVersion"]),
                .init("containers", .array(containers.map { .object([.init("name", $0["name"]), .init("state", $0["state"])]) })),
                .init("images", .number(Double(images.count))), .init("volumes", .number(Double(volumes.count))),
                .init("networks", .array(networks.map { $0["name"] })), .init("composeProjects", .array(compose.map { $0["name"] }))])),
            .init("logs", .array(logs)), .init("stats", stats),
            .init("refusedDockerChanges", .array(refusals)), .init("refusedDockerTools", .number(Double(toolRefusals))), .init("allowedDockerReadTools", .number(Double(toolReads))),
            .init("refusedAppsTools", .number(Double(appRefusals))), .init("allowedAppsReadTools", .number(Double(appReads))),
            .init("refusedServerOperations", .number(Double(serverRefusals))),
            .init("pagesReadTheSameData", .object(projected)),
            .init("dockerReadRequests", .number(Double(dockerReads))), .init("changesThatReachedTheServer", .number(Double(blocked.count))),
            .init("seconds", .object(timings))])
        print("DKA2-IMATCH " + String(decoding: try record.encodedJSON(), as: UTF8.self))
        if let out = environment["TD_DKA2_SNAPSHOT"] {
            // For the offscreen Docker page render: the live replies with labels,
            // env, commands and mounts removed. Kept outside the repository.
            func clean(_ value: NativeRPCValue) -> NativeRPCValue {
                if let fields = value.fields {
                    return .object(fields.filter { !["labels", "env", "environment", "command", "cmd", "entrypoint", "args", "mounts", "options"].contains($0.key.lowercased()) }
                        .map { .init($0.key, clean($0.value)) })
                }
                if let elements = value.elements { return .array(elements.map(clean)) }
                return value
            }
            let snapshot = NativeRPCValue.object([.init("status", status), .init("containers", clean(containersReply)), .init("images", clean(imagesReply)),
                .init("volumes", clean(volumesReply)), .init("networks", clean(networksReply)), .init("projects", clean(composeReply)),
                .init("inspect", clean(inspectReply)), .init("stats", statsRecord)])
            try snapshot.encodedJSON().write(to: URL(fileURLWithPath: out))
        }
    }
}

/// The exact add path Commander used (servers:add with method ssh-config),
/// then the server page read, against imza-server. READ ONLY, same opt-in.
final class BackendDKA2IMatchAddPathTests: XCTestCase {
    func testAddFromSSHSettingsThenLook() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment["TD_DKA2_IMATCH"] else { throw XCTSkip("Live iMatch check is opt-in.") }
        guard alias == "imza-server" else { XCTFail("This check is only for imza-server."); return }
        let helper = URL(fileURLWithPath: try XCTUnwrap(environment["TD_DKA2_HELPER"], "TD_DKA2_HELPER"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        // A space in the scratch path, exactly like the app's "Application Support".
        let scratch = URL(fileURLWithPath: "/private/tmp/dka2 a-" + UUID().uuidString.prefix(6), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ssh = BackendServersSSH(scratchRoot: scratch,
            policy: .init(mayConnect: true, helperExecutable: helper, helperDispatchInstalled: FileManager.default.isExecutableFile(atPath: helper.path)),
            sshHome: home, agentSocket: BackendServersSSH.personAgentSocket())
        let app = try BackendServersIPCPortFixture(sshConfig: .init(), realDialer: ssh, sshHome: home)
        defer { app.cleanup() }
        let started = Date()
        let added = try await app.call("servers:add", .object([.init("method", .string("ssh-config")), .init("sshAlias", .string(alias)),
            .init("name", .string("iMatch production")), .init("lookOnly", .bool(true))]))
        print("DKA2-ADD " + String(decoding: try added.encodedJSON(), as: UTF8.self) + " \(Date().timeIntervalSince(started))s")
        XCTAssertEqual(added["ok"].bool, true, added["sentence"].string ?? "")
        let id = try XCTUnwrap(added["id"].string)
        let row = try XCTUnwrap(try app.store.get(id))
        XCTAssertTrue(row.isLookOnly)
        let look = try await app.call("servers:look", .string(id))
        XCTAssertEqual(look["ok"].bool, true)
        print("DKA2-ADD pinned \(row.hostKey?.algorithm ?? "-") \(row.hostKey?.fingerprint ?? "-") cards \(look["view"]["cards"].elements?.count ?? 0)")
        await app.pool.closeAll(); await app.stop()
    }
}
