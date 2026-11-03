import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Standalone read-only SSH fixture: no process, socket, terminal or real credential.
private final class PROJServersClient: BackendServersConnection, @unchecked Sendable {
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "This fixture supports add and look only.") }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        if let stdin, String(decoding: stdin, as: UTF8.self) == BackendServersProbe.script {
            return .init(code: 0, stdout: "schema=1\nos=Ubuntu 24.04\nroot=yes\ninit=systemd\ncontainers=\n#services ok\n#adminunits ok\n#agents ok\n#end ok\n")
        }
        if let stdin, String(decoding: stdin, as: UTF8.self).contains("##compose-available") {
            return .init(code: 0, stdout: "##compose-available\nno\n##repos\n")
        }
        throw unavailable()
    }
    func dockerDialStdio() async throws -> any BackendServersDuplex { throw unavailable() }
    func follow(command: String) async throws -> any BackendServersFollow { throw unavailable() }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { throw unavailable() }
    func openSFTP() async throws -> any BackendServersSFTP { throw unavailable() }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { throw unavailable() }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { throw unavailable() }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { {} }
    func close() {}
}

private struct PROJServersDialer: BackendServersSSHDialer {
    let client: PROJServersClient
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential,
              verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        var key = Data([0, 0, 0, 11]); key.append(Data("ssh-ed25519".utf8))
        key.append(Data([0, 0, 0, 32])); key.append(Data(repeating: 7, count: 32))
        try verifyHostKey(key)
        return client
    }
}

private struct PROJServersScratchFixture: Sendable {
    let root: URL, store: BackendServersStore, credentials: BackendServersCredentials
    let pool: BackendServersConnections, room: BackendServersCoordinator, ipc: BackendServersIPC
    let caller = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "proj-window"))
    init(sshConfig: BackendDockerMCPServerSSHConfig) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-server-" + UUID().uuidString + ".noindex")
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "new-1" })
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { String(decoding: $0, as: UTF8.self) }, encrypt: { text, _ in Data(text.utf8) })
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in "Unused fixture key." })
        let pool = BackendServersConnections(store: store, credentials: credentials, dialer: PROJServersDialer(client: PROJServersClient()))
        let room = BackendServersCoordinator(store: store, connections: pool,
            grants: .init(assistantName: "Hoot", now: { 1_000 }, knows: { (try? store.get($0)) != nil }),
            journal: BackendServersMemoryJournal(), storageDirectory: root, authorize: { _, _ in }, download: nil, now: { 1_000 }, enforceKeyScope: false)
        let shells = BackendServersShells(room: room, connections: pool, store: store, hooks: .init(
            arm: { _, _ in .object([.init("ok", .bool(false))]) }, disarm: { _ in }, cancelSetup: { _, _ in },
            whyNot: { _ in "Fixture supports add and look only." }, belonging: { _ in nil }, publish: { _, _, _ in }, report: { _ in }, controls: nil))
        let ipc = BackendServersIPC(room: room, shells: shells, store: store, credentials: credentials,
            keys: .init(keyRoot: root.appendingPathComponent("keys")),
            setups: .init(.init(runScript: { try await pool.runScript($0, script: $1) })),
            hosts: .init(.init(runScript: { try await pool.runScript($0, script: $1) }, hostPackage: { nil })),
            hooks: .init(resolve: { BackendServersCaller(kind: .nativeUI, attended: true, context: $0) }, pickKey: nil,
                uploadFile: { _, _, _ in }, uploadDirectory: { _, _ in "Fixture" }, appVersion: { "fixture" },
                linkStanding: { _ in nil }, redial: { _ in }, revokeWindows: { _ in }, forgetReach: { _ in }),
            serverAccessEnabled: false, sshHome: root, sshConfig: sshConfig)
        self.root = root; self.store = store; self.credentials = credentials; self.pool = pool; self.room = room; self.ipc = ipc
    }
    func call(_ channel: String, _ args: NativeRPCValue...) async throws -> NativeRPCValue {
        try await ipc.invoke(channel, arguments: args, context: caller.context)
    }
    func stop() async { await ipc.stop() }
    func cleanup() { credentials.close(); try? FileManager.default.removeItem(at: root) }
}

private struct PROJConnectedTasksFake: BackendConnectedTasksTransport {
    let token = "fixture-token-1234"
    func send(_ request: BackendConnectedTasksHTTPRequest) async throws -> BackendConnectedTasksHTTPResponse {
        if request.method == "GET" { return .init(status: 404, body: Data("{}".utf8)) }
        let rpc = try NativeRPCValue.parseJSON(request.body)
        if rpc["method"].string == "notifications/initialized" { return .init(status: 202, body: Data()) }
        let result: NativeRPCValue
        switch rpc["method"].string {
        case "initialize": result = .object([.init("protocolVersion", .string("2025-06-18")),
            .init("serverInfo", .object([.init("name", .string("Fixture tracker")), .init("version", .string("1"))]))])
        case "tools/list": result = .object([.init("tools", .array([.object([.init("name", .string("list_tasks")),
            .init("inputSchema", .object([.init("type", .string("object")), .init("properties", .object([]))]))])]))])
        default: throw NativeRPCError(code: "unexpected", message: "Unexpected fixture call.")
        }
        let answer = NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", rpc["id"]), .init("result", result)])
        return .init(status: 200, headers: ["content-type": "application/json"], body: try answer.encodedJSON())
    }
}

@Suite("PROJ server and task source ownership", .serialized, .madeUpProjects)
struct PROJServersTests {
    @Test func crmAddLookAndReadOnlyRefusalUseScratchConfig() async throws {
        let ssh = BackendDockerMCPServerSSHConfig(evaluate: { request in
            #expect(request.arguments.last == "imza-vps")
            return .init(code: 0, stdout: "hostname 46.28.44.154\nuser root\nport 22\nidentityfile ~/.ssh/fixture\nproxycommand none\n")
        })
        let app = try PROJServersScratchFixture(sshConfig: ssh)
        defer { app.cleanup() }
        #expect(app.root.path.hasSuffix(".noindex"))
        let added = try await app.call("servers:add", .object([
            .init("method", .string("ssh-config")), .init("sshAlias", .string("imza-vps")),
            .init("projectId", .string("crm")), .init("lookOnly", .bool(true))]))
        #expect(added["ok"].bool == true)
        let id = try #require(added["id"].string)
        let row = try #require(try app.store.get(id))
        #expect(row.resolvedProjectId == "crm" && row.isLookOnly && row.address == "46.28.44.154")
        let looked = try await app.call("servers:look", .string(id))
        #expect(looked["ok"].bool == true && looked["view"]["facts"]["serverId"].string == id)
        let filtered = try await app.call("servers:list", .object([.init("projectId", .string("crm"))]))
        #expect(filtered.elements?.count == 1 && filtered.elements?.first?["id"].string == id)
        let reopened = BackendServersStore(dataRoot: app.root, policy: .init(mayRead: true, mayWrite: true))
        #expect(try reopened.get(id)?.resolvedProjectId == "crm")
        do {
            try await app.room.check(app.caller, .init(operation: "servers.control", serverId: id, tier: .alter))
            Issue.record("Look only server allowed a change")
        } catch let error as NativeRPCError { #expect(error.message.contains("Look only")) }
        #expect(!FileManager.default.fileExists(atPath: app.credentials.file.path))
        await app.stop()
    }

    // 11 Oct: a server's SSH name never means a project by itself (two names of the builder's own Mac did).
    @Test(.madeUpProjects) func legacyServerFoldersInferTheirProjectAndAServerNameNeverDoes() throws {
        let rows: NativeRPCValue = .object([.init("servers", .array([
            .object([.init("id", .string("one")), .init("address", .string("fixture.test")), .init("startIn", .string("/work/crm/site"))]),
            .object([.init("id", .string("two")), .init("address", .string("fixture.test")), .init("sshAlias", .string("imza-server"))]),
            .object([.init("id", .string("three")), .init("address", .string("fixture.test"))]),
        ]))])
        #expect(BackendServersStore.readServers(rows).map(\.resolvedProjectId) == ["crm", "independent", "independent"])
    }

    @Test func oldILoopConnectionLoadsAsCRMPersistsAndFiltersWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-tasks-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        try persistence.write(BackendConnectedTasksService.fileName, value: .object([.init("connections", .array([
            .object([.init("id", .string("iloop-old")), .init("name", .string("iLoop")), .init("url", .string("https://fixture.invalid/mcp"))]),
            .object([.init("id", .string("independent")), .init("name", .string("Other")), .init("url", .string("https://other.invalid/mcp"))]),
        ]))]))
        let service = BackendConnectedTasksService(persistence: persistence, secrets: BackendConnectedTasksMemorySecrets(),
            agents: .init(create: { _ in "fixture" }, outcome: { _ in nil }, agent: { _ in nil }))
        try await service.start()
        let filtered = try await service.state(projectId: "crm")
        #expect(filtered["connections"].elements?.count == 1)
        #expect(filtered["connections"].elements?.first?["projectId"].string == "crm")
        _ = try await service.update("iloop-old", .object([.init("name", .string("CRM tasks"))]))
        let saved = try #require(try persistence.read(BackendConnectedTasksService.fileName))
        #expect(saved["connections"].elements?.first?["projectId"].string == "crm")
        let visible = try #require(ConnectedTaskSystem(filtered["connections"].elements!.first!))
        #expect(visible.projectId == "crm")
    }

    @Test func connectedSourceExplicitIndependentAndCustomProjectsSurviveReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-connect-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let fake = PROJConnectedTasksFake(), secrets = BackendConnectedTasksMemorySecrets()
        let agents = BackendConnectedTasksService.Agents(create: { _ in "fixture" }, outcome: { _ in nil }, agent: { _ in nil })
        let service = BackendConnectedTasksService(persistence: persistence, secrets: secrets, transport: fake, agents: agents)
        try await service.start()
        let first = try await service.connect(.object([
            .init("name", .string("iLoop")), .init("url", .string("https://fixture.invalid/mcp")),
            .init("token", .string(fake.token)), .init("projectId", .string("independent"))]))
        let second = try await service.connect(.object([
            .init("name", .string("Workshop")), .init("url", .string("https://other.invalid/mcp")),
            .init("token", .string(fake.token)), .init("projectId", .string("workshop"))]))
        #expect(first["projectId"].string == "independent" && second["projectId"].string == "workshop")
        let reloaded = BackendConnectedTasksService(persistence: persistence, secrets: secrets, transport: fake, agents: agents)
        try await reloaded.start()
        #expect(try await reloaded.state(projectId: "workshop")["connections"].elements?.count == 1)
        #expect(try await reloaded.state(projectId: "crm")["connections"].elements?.isEmpty == true)
    }


    @Test func legacyCustomServerFolderResolvesThroughRegistryAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-server-identity-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("workshop").path
        let legacy: NativeRPCValue = .object([.init("id", .string("old-custom")), .init("address", .string("fixture.invalid")), .init("startIn", .string(folder))])
        let independent = legacy.setting("id", .string("explicit")).setting("projectId", .string("independent"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try NativeRPCValue.object([.init("servers", .array([legacy, independent]))]).encodedJSON().write(to: root.appendingPathComponent("servers.json"))
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let first = try #require(try store.get("old-custom"))
        #expect(first.projectId == nil && first.projectIdInferred)
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("registry.json"))
        _ = try await registry.save(.init(id: "workshop", name: "Workshop", folders: [folder]))
        let summaries = try store.list().map { BackendServersSummary($0).wireValue }
        let filtered = try await registry.filter(summaries, projectID: "workshop")
        #expect(filtered.count == 1 && filtered.first?["id"].string == "old-custom")
        let summary = BackendServersSummary(first).wireValue
        #expect(summary["projectIdInferred"].bool == true && summary["startIn"].string == folder)
        let dto = try #require(CodingAIServer.parseList(.array([CodingAIJSON.parse(String(decoding: try summary.encodedJSON(), as: UTF8.self))])).first)
        #expect(dto.projectID == nil && dto.startIn == folder)
        #expect(try await registry.resolve(projectID: dto.projectID, folder: dto.startIn) == "workshop")
        let explicit = try #require(try store.get("explicit"))
        #expect(explicit.resolvedProjectId == "independent" && !explicit.projectIdInferred)
        #expect(BackendServersSummary(explicit).wireValue["projectIdInferred"] != .bool(true))
        #expect(try store.rename("old-custom", name: "Renamed"))
        let reopened = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let retained = try #require(try reopened.get("old-custom"))
        #expect(retained.projectId == nil && retained.projectIdInferred)
        #expect(try await registry.filter([BackendServersSummary(retained).wireValue], projectID: "workshop").count == 1)
        let new = try store.add(.init(name: "New", address: "other.invalid", username: "fixture"))
        #expect(new.projectId == "independent" && !new.projectIdInferred)
        let crm = BackendServersStoredServer(id: "crm", name: "CRM", address: "46.28.44.154", username: "fixture", sshAlias: "imza-vps")
        #expect(crm.projectId == nil && crm.projectIdInferred, "a server name means no project by itself")
    }

    /// 11 Oct: a connection's project is never decided by its name any more. An old connection with no
    /// project saved that the name rule used to place gets that project written into its settings once,
    /// only when a registered project with that id exists, and never over a project already saved.
    @Test func anOldConnectionPlacedByItsNameGetsThatProjectSavedOnceAndOnlyIfItExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-connection-migration-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        func connection(_ id: String, _ name: String, project: String? = nil) -> NativeRPCValue {
            var row = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(name)), .init("url", .string("https://\(id).invalid/mcp"))])
            if let project { row = row.setting("projectId", .string(project)) }
            return row
        }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        try persistence.write(BackendConnectedTasksService.fileName, value: .object([.init("connections", .array([
            connection("iloop", "iLoop"),                           // his case: no project saved → crm
            connection("crm-named", "CRM", project: "imatch"),       // a project already saved is never changed
            connection("imatch-named", "iMatch"),                   // "imatch" is not registered in this test → untouched
            connection("other", "Tracker"),                         // a name the old rule never knew → untouched
        ]))]))
        let agents = BackendConnectedTasksService.Agents(create: { _ in "fixture" }, outcome: { _ in nil }, agent: { _ in nil })
        let registered = PROJMadeUp.projects.filter { $0.id != "imatch" }
        try await PROJRegisteredProjects.$scoped.withValue(registered) {
            let service = BackendConnectedTasksService(persistence: persistence, secrets: BackendConnectedTasksMemorySecrets(), agents: agents)
            try await service.start()
            let saved = try #require(try persistence.read(BackendConnectedTasksService.fileName))["connections"].elements ?? []
            func savedProject(_ id: String) -> String? { saved.first { $0["id"].string == id }?["projectId"].string }
            #expect(savedProject("iloop") == "crm", "written into its own saved settings")
            #expect(savedProject("crm-named") == "imatch")
            #expect(savedProject("imatch-named") == nil && savedProject("other") == nil)
            let shown = try await service.state()["connections"].elements ?? []
            #expect(shown.first { $0["id"].string == "imatch-named" }?["projectIdInferred"].bool == true, "no name decides a project")
            // Once: the next start finds a project saved and writes nothing.
            let bytes = try Data(contentsOf: root.appendingPathComponent(BackendConnectedTasksService.fileName))
            let again = BackendConnectedTasksService(persistence: persistence, secrets: BackendConnectedTasksMemorySecrets(), agents: agents)
            try await again.start()
            #expect(try Data(contentsOf: root.appendingPathComponent(BackendConnectedTasksService.fileName)) == bytes)
        }
        // A rename later never moves it back: the saved project stays.
        #expect(BackendConnectedTasksService.migrateLegacyProjects([connection("x", "Renamed", project: "crm")], registered: []).changed == false)
        #expect(BackendConnectedTasksService.migrateLegacyProjects([connection("y", "iLoop")], registered: []).changed == false, "no registered project: nothing")
    }

    @Test func legacyCustomTaskSourceFolderStaysInferableAndExplicitChoiceClearsMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-source-identity-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("workshop").path
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let legacy: NativeRPCValue = .object([.init("id", .string("old-custom")), .init("name", .string("Old tracker")), .init("url", .string("https://fixture.invalid/mcp")), .init("folder", .string(folder))])
        let explicit = legacy.setting("id", .string("explicit")).setting("projectId", .string("independent"))
        let iloop = legacy.setting("id", .string("iloop")).setting("name", .string("iLoop"))
        try persistence.write(BackendConnectedTasksService.fileName, value: .object([.init("connections", .array([legacy, explicit, iloop]))]))
        let agents = BackendConnectedTasksService.Agents(create: { _ in "fixture" }, outcome: { _ in nil }, agent: { _ in nil })
        let service = BackendConnectedTasksService(persistence: persistence, secrets: BackendConnectedTasksMemorySecrets(), agents: agents)
        try await service.start()
        let rows = try await service.state()["connections"].elements ?? []
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("registry.json"))
        _ = try await registry.save(.init(id: "workshop", name: "Workshop", folders: [folder]))
        let filtered = try await registry.filter(rows, projectID: "workshop")
        #expect(filtered.count == 1 && filtered.first?["id"].string == "old-custom")
        let row = try #require(rows.first { $0["id"].string == "old-custom" })
        let dto = try #require(ConnectedTaskSystem(row))
        #expect(dto.projectID == nil && dto.projectIdInferred && dto.folder == folder)
        #expect(rows.first { $0["id"].string == "iloop" }?["projectId"].string == "crm")
        _ = try await service.update("old-custom", .object([.init("name", .string("Renamed tracker"))]))
        let reloaded = BackendConnectedTasksService(persistence: persistence, secrets: BackendConnectedTasksMemorySecrets(), agents: agents)
        try await reloaded.start()
        #expect(try await registry.filter(try await reloaded.state()["connections"].elements ?? [], projectID: "workshop").count == 1)
        let changed = try await reloaded.update("old-custom", .object([.init("projectId", .string("independent"))]))
        #expect(changed["projectId"].string == "independent" && changed["projectIdInferred"].bool != true)
        #expect(try await registry.filter([changed], projectID: "workshop").isEmpty)
    }

    @Test func projectFiltersAndAddAreExposedInMCP() throws {
        let look = try #require(BackendServersTools.definitions().first { $0.id == "servers.look" })
        #expect(look.inputSchema["properties"]["projectId"]["type"].string == "string")
        let manage = try #require(BackendDeckToolsMachinesCatalogue.rows().first { $0["id"].string == "servers.manage" })
        #expect(manage["inputSchema"]["properties"]["projectId"]["type"].string == "string")
        let tools = try BackendConnectedTasksTools.specs()
        #expect(tools.first { $0.id == "connected_tasks.systems" }?.inputSchema["properties"]["projectId"]["type"].string == "string")
        #expect(tools.first { $0.id == "connected_tasks.connect" }?.inputSchema["properties"]["projectId"]["type"].string == "string")
    }
}
