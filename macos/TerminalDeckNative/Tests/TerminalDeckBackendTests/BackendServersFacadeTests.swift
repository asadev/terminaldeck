import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Servers facade contracts; no SSH or live roots")
struct BackendServersFacadeTests {
    @Test func exactClosedToolVocabulary() throws {
        let specs = try BackendServersTools.definitions()
        #expect(specs.map(\.id) == ["servers.look", "servers.logs", "servers.control"])
        #expect(specs.map(\.wireName) == ["servers_look", "servers_logs", "servers_control"])
        #expect(specs.allSatisfy { $0.inputSchema["additionalProperties"].bool == false })
        #expect(specs[2].inputSchema["properties"]["action"]["enum"].elements?.compactMap(\.string) == ["start", "restart", "stop", "update", "go-back", "backup"])
        #expect(specs.allSatisfy { $0.inputSchema["properties"]["command"] == .missing && $0.inputSchema["properties"]["argv"] == .missing })
    }
    @Test func accountsAreMaskedOnlyOnToolProjection() {
        let agent: NativeRPCValue = .object([.init("id", .string("codex")), .init("account", .string("owner@example.invalid")), .init("signedIn", .string("yes"))])
        let original: NativeRPCValue = .object([.init("facts", .object([.init("agents", .object([.init("known", .string("yes")), .init("value", .array([agent]))]))]))])
        let masked = BackendServersTools.withoutAccounts(original)
        #expect(masked["facts"]["agents"]["value"].elements?.first?["account"] == .null)
        #expect(original["facts"]["agents"]["value"].elements?.first?["account"].string == "owner@example.invalid")
        let cannot: NativeRPCValue = .object([.init("facts", .object([.init("agents", .object([.init("known", .string("cannot")), .init("why", .string("not allowed"))]))]))])
        #expect(BackendServersTools.withoutAccounts(cannot) == cannot)
    }
    @Test func remoteCannotLearnControlTargetOrUseLocalGrant() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        _ = try await app.room.grants.grant("one", asker: "local")
        let remote = BackendServersCaller(kind: .remote, attended: true, context: .init(caller: .pairedDevice, ownerID: "phone"))
        do {
            _ = try await BackendServersTools.invoke("servers.control", arguments: .object([.init("serverId", .string("missing")), .init("cardId", .string("missing")), .init("action", .string("stop"))]), caller: remote, room: app.room)
            Issue.record("Remote controlled a server")
        } catch let error as BackendServersActionRefused { #expect(error.sentence.contains("paired device cannot")) }
        #expect(app.client.probes == 0 && app.dialer.count == 0)
    }
    @Test func toolRejectsCommandBeforeDialing() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        do {
            _ = try await BackendServersTools.invoke("servers.look", arguments: .object([.init("serverId", .string("one")), .init("command", .string("anything"))]), caller: app.caller, room: app.room)
            Issue.record("Accepted a command argument")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(app.dialer.count == 0)
    }
    @Test func refreshIsRealButAccountReadUsesCurrentMeasurement() async throws {
        let clock = BackendServersFacadeClock(), app = try BackendServersFacadeFixture(clock: { clock.read() }); defer { app.cleanup() }
        _ = try await app.room.look("one", caller: app.caller)
        let first = try await app.room.measured("one")
        #expect(app.client.probes == 1)
        clock.set(200)
        _ = try await app.room.look("one", caller: app.caller)
        let second = try await app.room.measured("one")
        #expect(app.client.probes == 2 && first.measuredAt == 100 && second.measuredAt == 200)
        await app.room.stop()
    }
    @Test func setupEventInvalidatesSynchronouslyBeforeDelivery() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        _ = try await app.room.look("one", caller: app.caller)
        app.room.invalidateFromEvent("one")
        #expect(await app.room.cached("one") == nil)
        _ = try await app.room.measured("one")
        #expect(app.client.probes == 2)
        await app.room.stop()
    }
    @Test func timestampIsSampledAfterProbeAnswers() async throws {
        let clock = BackendServersFacadeClock()
        let app = try BackendServersFacadeFixture(clock: { clock.read() }, probeCompletes: { clock.set(321) }); defer { app.cleanup() }
        let facts = try await app.room.measured("one")
        #expect(facts.measuredAt == 321)
        await app.room.stop()
    }
    @Test func credentialInputCapabilityNeverElevatesRemoteOrSession() {
        let context = NativeRPCContext(caller: .internalEngine, ownerID: "trusted-server-manage", capabilities: ["servers:credential-input"])
        #expect(BackendServersCaller(kind: .key, attended: true, context: context).canConsumeCredentialInput)
        #expect(!BackendServersCaller(kind: .session, attended: true, context: context).canConsumeCredentialInput)
        #expect(!BackendServersCaller(kind: .remote, attended: true, context: context).canConsumeCredentialInput)
        #expect(!BackendServersCaller(kind: .local, attended: true, context: .init(caller: .internalEngine, ownerID: "plain-mcp")).canConsumeCredentialInput)
    }
    @Test func concurrentPageReadsOwnOneHoldAndPageCloseKeepsTerminal() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        async let a = app.room.look("one", caller: app.caller)
        async let b = app.room.look("one", caller: app.caller)
        _ = try await (a, b)
        #expect(app.dialer.count == 1)
        let opened = try await app.shells.open("one", cols: .number(120), rows: .number(30), startIn: .missing, caller: app.caller)
        let shellId = try #require(opened["shellId"].string)
        _ = try await app.room.closePage("one", caller: app.caller)
        #expect(await app.pool.isOpen("one"))
        #expect(await app.shells.serverOfShell(shellId) == "one")
        _ = try await app.shells.close(shellId, caller: app.caller)
        #expect(await app.shells.serverOfShell(shellId) == nil)
        #expect(await app.shells.historicalServerOfShell(shellId) == "one")
        #expect(await app.client.waitForClose())
        #expect(!(await app.pool.isOpen("one")))
        await app.room.stop()
    }
    @Test func forgetStopsAllPageOwnersAndPendingCapability() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        let other = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "other-window"))
        _ = try await app.room.look("one", caller: app.caller); _ = try await app.room.look("one", caller: other)
        let lifetime = app.room.serverLifetime("one")
        await app.room.forgetServer("one")
        #expect(!(await app.pool.isOpen("one")))
        do { try await app.room.requireLiveServer("one", lifetime: lifetime); Issue.record("Forgotten lifetime survived") } catch is CancellationError { }
        await app.room.stop()
    }
    @Test func grantCanLowerOnlyLocalControlTier() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        let view = try await app.room.look("one", caller: app.caller)
        let card = try #require(view.cards.first { view.offered[$0.id]?.contains(.stop) == true })
        _ = try await app.room.grants.grant("one", asker: "local")
        let local = BackendServersCaller(kind: .local, attended: true, context: .init(caller: .internalEngine, ownerID: "local-mcp"))
        _ = try await app.room.act("one", cardId: card.id, action: .stop, caller: local, requireCached: true)
        #expect(await app.audit.lastControlTier() == .act)
        _ = try await app.room.look("one", caller: app.caller)
        let key = BackendServersCaller(kind: .key, attended: true, context: .init(caller: .internalEngine, ownerID: "key-mcp"))
        _ = try await app.room.act("one", cardId: card.id, action: .stop, caller: key, requireCached: true)
        #expect(await app.audit.lastControlTier() == .alter)
        await app.room.stop()
    }
    @Test func malformedChannelsKeepTheirSpecificReplyShapes() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        let ipc = app.ipc()
        #expect(try await ipc.invoke("servers:close", arguments: [.null], context: app.caller.context) == .object([.init("closed", .bool(false))]))
        #expect(try await ipc.invoke("servers:controls:read", arguments: [.null], context: app.caller.context) == .null)
        let controls = try await ipc.invoke("servers:controls:apply", arguments: [.null], context: app.caller.context)
        #expect(controls["ok"].bool == false && controls["message"].string == "No terminal was named." && controls["reading"]["value"] == .null)
        let account = try await ipc.invoke("servers:shell:account", arguments: [.null], context: app.caller.context)
        #expect(account["known"].string == "cannot" && account["why"].string == "No terminal was named.")
        await ipc.stop()
    }
    @Test func grantEnvelopeAndUploadRefusalStayDistinct() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        let ipc = app.ipc()
        let grant = try await ipc.invoke("servers:grant", arguments: [.string("one"), .number(5000)], context: app.caller.context)
        #expect(grant["ok"].bool == true && grant["grant"]["serverId"].string == "one")
        let upload = try await ipc.invoke("servers:upload", arguments: [.string("one"), .string(app.root.appendingPathComponent("missing-file").path)], context: app.caller.context)
        #expect(upload["ok"].bool == false && upload["message"].string == "That file is not there any more." && upload["sentence"] == .missing)
        #expect(app.dialer.count == 0)
        await ipc.stop()
    }
    @Test func fortyFourInvokesAndSendInputAreRegisteredWithoutDial() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        let ipc = app.ipc(), registry = NativeChannelRegistry()
        let tokens = try await ipc.register(on: registry, ownerID: "test-backend")
        let reaches = BackendServersReach(connections: app.pool, ownPorts: BackendDevOwnPorts(), servers: { try app.store.list() }, facts: { try await app.room.measured($0) }, tunnelsDropped: { _ in })
        try await BackendServersReachChannels(room: app.room, reach: reaches, resolve: { BackendServersCaller(kind: .nativeUI, attended: true, context: $0) }).register(on: registry, ownerID: "test-backend")
        let channels = await registry.channels(), sendsInput = await registry.hasSend("servers:shell:write")
        #expect(channels.count == 44 && sendsInput)
        #expect(app.dialer.count == 0)
        for token in tokens { await token.cancelAndWait() }; await registry.shutdown(); await reaches.stop(); await ipc.stop()
    }
    @Test func dataAndEOFRemainOrderedEvenBeforeConsumerStarts() async {
        let events = BackendServersShellEvents()
        events.append(.data("first")); events.append(.data("last")); events.append(.ended); events.append(.data("after EOF"))
        var read: [BackendServersShellEvents.Event] = []
        for await event in events.stream { read.append(event) }
        #expect(read == [.data("first"), .data("last"), .ended])
    }
    @Test func actualTerminalDeliversFinalBytesBeforeEOFAndCancelsSetup() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        _ = try await app.shells.open("one", cols: .number(120), rows: .number(30), startIn: .missing, caller: app.caller)
        app.client.shellHandle.emit("first"); app.client.shellHandle.emit("last"); app.client.shellHandle.close()
        let received = await app.audit.readThroughClose()
        #expect(received.map(\.channel) == ["servers:shell:output", "servers:shell:output", "servers:shell:closed"])
        #expect(received.prefix(2).map { $0.value["data"].string } == ["first", "last"])
        #expect(await app.audit.cancelledSetup("one"))
        await app.shells.stop(); await app.room.stop()
    }
    @Test func stoppingDuringArmingCannotOpenOrPublishATerminal() async throws {
        let app = try BackendServersFacadeFixture(); defer { app.cleanup() }
        let gate = BackendServersFacadeArmGate()
        let shells = BackendServersShells(room: app.room, connections: app.pool, store: app.store,
            hooks: .init(arm: { _, _ in await gate.enter(); return .object([.init("ok", .bool(false))]) }, disarm: { _ in await gate.disarmed() }, cancelSetup: { _ in }, whyNot: { _ in nil }, belonging: { _ in nil }, publish: { _, _, _ in Issue.record("Published a stopped terminal") }, report: { _ in }, controls: nil))
        let opening = Task { try await shells.open("one", cols: .number(120), rows: .number(30), startIn: .missing, caller: app.caller) }
        await gate.whenEntered(); await shells.beginStopping(); await app.room.beginStopping()
        let stopping = Task { await shells.stop() }
        await gate.release()
        do { _ = try await opening.value; Issue.record("Opened after stopping") } catch is CancellationError { }
        await stopping.value
        let cleaned = await gate.wasDisarmed()
        #expect(app.client.shellOpens == 0 && cleaned)
        #expect(await app.client.waitForClose())
        await app.room.stop()
    }
    @Test func orderedStateEventsAndRealOnlinePredicate() async {
        let events = BackendServersStateEvents()
        events.append("servers:setup:changed", .string("signing-in")); events.append("servers:setup:changed", .string("done")); events.finish()
        var read: [String] = []; for await event in events.stream { read.append(event.value.string ?? "") }
        #expect(read == ["signing-in", "done"])
        let storedOnly: NativeRPCValue = .object([.init("machines", .array([.object([.init("id", .string("one"))])])), .init("links", .array([]))])
        #expect(!BackendServersMachineLink.isOnline(storedOnly, id: "one"))
        let live = storedOnly.setting("links", .array([.object([.init("id", .string("one")), .init("state", .string("online"))])]))
        #expect(BackendServersMachineLink.isOnline(live, id: "one"))
        #expect(!BackendServersMachineLink.isOnline(live, id: "other"))
    }
}

actor BackendServersFacadeAudit {
    struct Output: Sendable { let channel: String, value: NativeRPCValue }
    private let events: AsyncStream<Output>, continuation: AsyncStream<Output>.Continuation
    private var checks: [BackendServersAuthorization] = []
    private var cancelled: Set<String> = []
    init() { let pair = AsyncStream<Output>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func append(_ request: BackendServersAuthorization) { checks.append(request) }
    func lastControlTier() -> BackendMCPTier? { checks.last { $0.operation == "servers.control" }?.tier }
    func publish(_ channel: String, _ value: NativeRPCValue) { continuation.yield(.init(channel: channel, value: value)) }
    func cancelSetup(_ id: String) { cancelled.insert(id) }
    func cancelledSetup(_ id: String) -> Bool { cancelled.contains(id) }
    func readThroughClose() async -> [Output] {
        var rows: [Output] = []
        for await row in events { rows.append(row); if row.channel == "servers:shell:closed" { break } }
        return rows
    }
}
final class BackendServersFacadeClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double = 100
    func read() -> Double { lock.withLock { value } }; func set(_ next: Double) { lock.withLock { value = next } }
}
actor BackendServersFacadeArmGate {
    private var entered = false, cleaned = false
    private var observers: [CheckedContinuation<Void, Never>] = [], permission: CheckedContinuation<Void, Never>?
    func enter() async { entered = true; let old = observers; observers = []; for waiter in old { waiter.resume() }; await withCheckedContinuation { permission = $0 } }
    func whenEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { permission?.resume(); permission = nil }
    func disarmed() { cleaned = true }; func wasDisarmed() -> Bool { cleaned }
}
struct BackendServersFacadeFixture: Sendable {
    let root: URL, store: BackendServersStore, credentials: BackendServersCredentials, client: BackendServersFacadeClient
    let dialer: BackendServersFacadeDialer, pool: BackendServersConnections, room: BackendServersCoordinator, shells: BackendServersShells
    let audit: BackendServersFacadeAudit
    let caller = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "one-window"))
    init(clock: @escaping @Sendable () -> Double = { 100 }, probeCompletes: @escaping @Sendable () -> Void = {}) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("servers-facade-" + UUID().uuidString)
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "one" })
        _ = try store.add(.init(name: "fixture", address: "fixture.invalid", username: "fixture"))
        let credentials = BackendServersCredentials(dataRoot: root, cipher: .init(available: { false }, decrypt: { _ in throw CancellationError() }, encrypt: { _, _ in throw CancellationError() }), policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil })
        credentials.holdForSession("one", credential: .password("fixture-only"))
        let client = BackendServersFacadeClient(probeCompletes: probeCompletes), dialer = BackendServersFacadeDialer(client), pool = BackendServersConnections(store: store, credentials: credentials, dialer: dialer), audit = BackendServersFacadeAudit()
        let room = BackendServersCoordinator(store: store, connections: pool, grants: .init(assistantName: "Hoot", now: clock, knows: { (try? store.get($0)) != nil }), journal: BackendServersMemoryJournal(), storageDirectory: root,
            authorize: { _, request in await audit.append(request) }, download: nil, now: clock)
        let shells = BackendServersShells(room: room, connections: pool, store: store, hooks: .init(arm: { _, _ in .object([.init("ok", .bool(false)), .init("why", .string("fixture has no browser endpoint"))]) }, disarm: { _ in }, cancelSetup: { await audit.cancelSetup($0) }, whyNot: { _ in nil }, belonging: { _ in nil }, publish: { _, channel, value in await audit.publish(channel, value) }, report: { _ in }, controls: nil))
        self.root = root; self.store = store; self.credentials = credentials; self.client = client; self.dialer = dialer; self.pool = pool; self.room = room; self.shells = shells; self.audit = audit
    }
    func ipc() -> BackendServersIPC {
        BackendServersIPC(room: room, shells: shells, store: store, credentials: credentials, keys: .init(keyRoot: root.appendingPathComponent("fixture-keys")),
            setups: .init(.init(runScript: { try await pool.runScript($0, script: $1) })), hosts: .init(.init(runScript: { try await pool.runScript($0, script: $1) }, hostPackage: { nil })),
            hooks: .init(resolve: { BackendServersCaller(kind: .nativeUI, attended: true, context: $0) }, pickKey: nil, uploadFile: { _, _, _ in }, uploadDirectory: { _, _ in "Terminal Deck" }, appVersion: { "test" }, linkStanding: { _ in nil }, redial: { _ in }, revokeWindows: { _ in }, forgetReach: { _ in }))
    }
    func cleanup() { client.close(); credentials.close(); try? FileManager.default.removeItem(at: root) }
}
final class BackendServersFacadeDialer: BackendServersSSHDialer, @unchecked Sendable {
    private let client: BackendServersFacadeClient, lock = NSLock(); private var dials = 0
    init(_ client: BackendServersFacadeClient) { self.client = client }; var count: Int { lock.withLock { dials } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential, verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        try verifyHostKey(BackendServersConnectionTestDialer.key); lock.withLock { dials += 1 }; return client
    }
}
final class BackendServersFacadeClient: BackendServersConnection, @unchecked Sendable {
    private let base = BackendServersConnectionTestClient(), lock = NSLock(); private var checked = 0, openedShells = 0
    let shellHandle = BackendServersFacadeShell()
    private let closeEvents: AsyncStream<Bool>, closeContinuation: AsyncStream<Bool>.Continuation
    private let probeCompletes: @Sendable () -> Void
    init(probeCompletes: @escaping @Sendable () -> Void) {
        self.probeCompletes = probeCompletes
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1)); closeEvents = pair.stream; closeContinuation = pair.continuation
    }
    var probes: Int { lock.withLock { checked } }
    var shellOpens: Int { lock.withLock { openedShells } }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        if stdin == Data(BackendServersProbe.script.utf8) {
            lock.withLock { checked += 1 }
            probeCompletes()
            return .init(code: 0, stdout: "schema=1\nos=Fixture\nkernel=Linux\narch=x86_64\nhost=fixture\nuser=root\nroot=yes\ninit=systemd\n#services ok\nmy-api.service\tactive\trunning\tMy API\n#adminunits ok\nmy-api.service\n#agents ok\n#end ok\n")
        }
        return .init(code: 0, stdout: "")
    }
    func follow(command: String) async throws -> any BackendServersFollow { try await base.follow(command: command) }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { lock.withLock { openedShells += 1 }; shellHandle.resize(size); return shellHandle }
    func openSFTP() async throws -> any BackendServersSFTP { try await base.openSFTP() }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { try await base.forward(host: host, port: port) }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { try await base.reverseForward(bindAddress: bindAddress, bindPort: bindPort) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { base.onClose(listener) }
    func close() { base.close(); closeContinuation.yield(true) }
    func waitForClose() async -> Bool {
        var read = closeEvents.makeAsyncIterator(); return await read.next() == true
    }
}
final class BackendServersFacadeShell: BackendServersShell, @unchecked Sendable {
    private let data = BackendServersSSHEvents<String>(), end = BackendServersSSHEvents<Bool>(replayLatest: true), lock = NSLock()
    private var closed = false
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe { data.listen(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { end.listen { _ in listener() } }
    func emit(_ text: String) { if lock.withLock({ !closed }) { data.send(text) } }
    func write(_ text: String) { }
    func resize(_ size: BackendServersTerminalSize) { }
    func close() { let first = lock.withLock { if closed { return false }; closed = true; return true }; if first { end.send(true) } }
}
