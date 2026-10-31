import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class PCDecisionHostValidationTests: XCTestCase, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        private var relayValue: BackendHOSTAppRelayServer?
        private var allowedValue = true
        private var countValue = 0
        private var lastValue: BackendPCDecisionHostValidation.Envelope?
        private var deliveredValue: [String] = []
        var relay: BackendHOSTAppRelayServer? { lock.withLock { relayValue } }
        var allowed: Bool { lock.withLock { allowedValue } }
        var count: Int { lock.withLock { countValue } }
        var last: BackendPCDecisionHostValidation.Envelope? { lock.withLock { lastValue } }
        var delivered: [String] { lock.withLock { deliveredValue } }
        func deliver(_ text: String) { lock.withLock { deliveredValue.append(text) } }
        func bind(_ relay: BackendHOSTAppRelayServer) { lock.withLock { relayValue = relay } }
        func deny() { lock.withLock { allowedValue = false } }
        func checked() { lock.withLock { countValue += 1 } }
        func record(_ proof: BackendPCDecisionHostValidation.Envelope) { lock.withLock { lastValue = proof } }
    }
    private actor Pause {
        private var entered = false
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []
        func suspend() async {
            entered = true
            let ready = observers; observers.removeAll(); for waiter in ready { waiter.resume() }
            if released { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func untilEntered() async {
            if entered { return }
            await withCheckedContinuation { observers.append($0) }
        }
        func release() { released = true; waiting?.resume(); waiting = nil }
    }
    private final class Blocking: @unchecked Sendable {
        let lock = NSLock()
        let ready = DispatchSemaphore(value: 0)
        var result: Result<Void, any Error>?
        static func run(_ operation: @escaping @Sendable () async throws -> Void) throws {
            let gate = Blocking()
            let task = Task.detached {
                let result: Result<Void, any Error>
                do { try await operation(); result = .success(()) } catch { result = .failure(error) }
                gate.lock.withLock { gate.result = result }; gate.ready.signal()
            }
            guard gate.ready.wait(timeout: .now() + .seconds(5)) == .success else {
                task.cancel(); throw BackendPCDecisionHostValidation.held()
            }
            try gate.lock.withLock { try gate.result!.get() }
        }
    }
    private struct Fixture: Sendable {
        let root: URL
        let paths: BackendHOSTPaths
        let host: BackendHOSTServer
        let relay: BackendHOSTAppRelayServer
        let app: BackendHOSTAppRelayClient
        let client: BackendHOSTClient
        let state: State
        let manager: BackendPTYManager
    }
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("pc-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func attach(paths: BackendHOSTPaths, hello: BackendHOSTProtocol.Hello) throws -> BackendHOSTAppRelayClient {
        let app = try BackendHOSTAppRelayClient(paths: paths, host: hello, handler: { _ in .failure("No MCP call in this fixture.") })
        BackendHOSTResourceFactory.installAppControls(client: app, controls: .init(verifyClaims: { _, _ in false },
            hookContext: { _, _ in nil }, openLink: { _, _, _ in throw BackendHOSTFailure.unavailable }))
        addTeardownBlock { app.detach() }
        return app
    }
    private func fixture(capable: Bool = true) throws -> Fixture {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root), state = State()
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        // Actual authenticated host socket plus the actual private duplex relay.
        // This fake helper prepares no provider and performs no filesystem effect.
        let host = try BackendHOSTServer(paths: paths, hostVersion: "decision-fixture", manager: manager,
            launch: { launch in
                guard let proof = launch.pcDecision, let relay = state.relay,
                      proof.digest == (try BackendPCDecisionHostValidation.launchDigest(launch)),
                      proof.sessionID == launch.id else { throw BackendPCDecisionHostValidation.held() }
                state.record(proof)
                try Blocking.run {
                    let answer = try await relay.invokeControl(operation: .decisionValidate,
                        arguments: BackendPCDecisionHostValidation.arguments(proof, effect: .spawn))
                    let receipt = try JSONDecoder().decode(BackendPCDecisionHostValidation.Receipt.self, from: answer.encodedJSON())
                    guard receipt == .init(envelope: proof, effect: .spawn, ticket: proof.spawn) else { throw BackendPCDecisionHostValidation.held() }
                }
                return launch.metadata
            }, snapshot: { id in
                guard let meta = manager.list().first(where: { $0.id == id }) else { return nil }
                return .init(sequence: 0, session: meta, pid: nil, replay: "", screen: nil, scrollbackText: nil, status: .idle)
            }, onIdle: {}, resource: { method, payload in
                try BackendPCDecisionHostValidation.requireSupportedChatEffect(method, required: BackendPCDecisionHostValidation.incoming != nil)
                guard let proof = BackendPCDecisionHostValidation.incoming, let relay = state.relay,
                      proof.digest == BackendPCDecisionHostValidation.digest(method: method, payload: payload),
                      proof.sessionID == (try NativeRPCValue.parseJSON(payload))["id"].string else { throw BackendPCDecisionHostValidation.held() }
                state.record(proof)
                for effect in [BackendPCDecisionHostValidation.Effect.spawn, .input] {
                    let reply = try await relay.invokeControl(operation: .decisionValidate,
                        arguments: BackendPCDecisionHostValidation.arguments(proof, effect: effect))
                    let receipt = try JSONDecoder().decode(BackendPCDecisionHostValidation.Receipt.self, from: reply.encodedJSON())
                    let expectedTicket = effect == .spawn ? proof.spawn : proof.input
                    guard receipt.envelope == proof, receipt.effect == effect, receipt.ticket == expectedTicket else { throw BackendPCDecisionHostValidation.held() }
                }
                return Data("{\"delivered\":true}".utf8)
            }, pcDecisionValidation: capable, beforeInput: { request in
                guard let proof = request.pcDecision, let relay = state.relay, let id = request.id, let bytes = request.bytes,
                      proof.sessionID == id,
                      proof.digest == (try BackendPCDecisionHostValidation.writeDigest(id: id, bytes: bytes, expectedCreatedAt: request.expectedCreatedAt)) else {
                    throw BackendPCDecisionHostValidation.held()
                }
                state.record(proof)
                try Blocking.run {
                    let answer = try await relay.invokeControl(operation: .decisionValidate,
                        arguments: BackendPCDecisionHostValidation.arguments(proof, effect: .input))
                    let receipt = try JSONDecoder().decode(BackendPCDecisionHostValidation.Receipt.self, from: answer.encodedJSON())
                    guard let ticket = proof.input, receipt == .init(envelope: proof, effect: .input, ticket: ticket) else { throw BackendPCDecisionHostValidation.held() }
                }
            })
        let relay = try BackendHOSTAppRelayServer(paths: paths, host: host.hello)
        state.bind(relay)
        addTeardownBlock { relay.stop(); host.stopListening() }
        let app = try attach(paths: paths, hello: host.hello)
        return Fixture(root: root, paths: paths, host: host, relay: relay, app: app,
                       client: try BackendHOSTClient(paths: paths), state: state, manager: manager)
    }
    private func issue(_ fixture: Fixture, session: String = UUID().uuidString) throws -> BackendPCDecisionHostValidation.Envelope {
        try BackendPCDecisionDelivery.$required.withValue(true) {
            try BackendPCDecisionDelivery.$hostedReference.withValue("task:one/scope:fixed/decision:two/epoch:3") {
                try BackendPCDecisionDelivery.$validate.withValue({
                    fixture.state.checked()
                    guard fixture.state.allowed else { throw BackendPCDecisionHostValidation.held() }
                }) {
                    // Not XCTUnwrap: it records a failure when it throws, even for a test that expects the refusal.
                    guard let envelope = try BackendPCDecisionHostValidation.issue(host: fixture.host.hello, session: session, digest: "exact-request", input: true) else {
                        throw BackendPCDecisionHostValidation.held()
                    }
                    return envelope
                }
            }
        }
    }
    private func consume(_ fixture: Fixture, _ proof: BackendPCDecisionHostValidation.Envelope,
                         effect: BackendPCDecisionHostValidation.Effect = .spawn) async throws {
        let answer = try await fixture.relay.invokeControl(operation: .decisionValidate,
            arguments: BackendPCDecisionHostValidation.arguments(proof, effect: effect))
        let receipt = try JSONDecoder().decode(BackendPCDecisionHostValidation.Receipt.self, from: answer.encodedJSON())
        XCTAssertEqual(receipt.envelope, proof)
        XCTAssertEqual(receipt.effect, effect)
        XCTAssertEqual(receipt.ticket, effect == .spawn ? proof.spawn : proof.input)
    }
    private func refuses(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected held effect", file: file, line: line) } catch { }
    }
    func testActualHostSocketAndPrivateCallbackCarrySeparateOneUseEffects() async throws {
        let fixture = try fixture(), id = UUID().uuidString
        let reply = try await BackendPCDecisionDelivery.$required.withValue(true) {
            try await BackendPCDecisionDelivery.$hostedReference.withValue("task:one/scope:fixed/decision:two/epoch:3") {
                try await BackendPCDecisionDelivery.$validate.withValue({ fixture.state.checked() }) {
                    try await fixture.client.resource("chats.say", arguments: .object([.init("id", .string(id)), .init("text", .string("scratch"))]))
                }
            }
        }
        XCTAssertEqual(reply["delivered"].bool, true)
        XCTAssertEqual(fixture.state.count, 2)
        let proof = try XCTUnwrap(fixture.state.last)
        XCTAssertEqual(proof.sessionID, id)
        XCTAssertEqual(proof.host, fixture.host.hello.instance)
        XCTAssertEqual(proof.attachment, fixture.app.attachmentID())
        await refuses { try await self.consume(fixture, proof) }
        await refuses { try await self.consume(fixture, proof, effect: .input) }
        XCTAssertEqual(fixture.state.count, 2)
    }
    private func launch() throws -> BackendHOSTProtocol.Launch {
        let input = BackendCreateSessionInput(cwd: "/tmp", provider: "shell")
        return try .init(id: UUID().uuidString, input: input,
            spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: [], path: "/usr/bin:/bin", env: [:]), inheritedEnvironment: [:])
    }
    func testAsyncCreateCapturesScopeBeforeDetachAndCanCallMainActor() async throws {
        let fixture = try fixture(), launch = try launch()
        let result = try await BackendPCDecisionDelivery.$required.withValue(true) {
            try await BackendPCDecisionDelivery.$hostedReference.withValue("task:async-create") {
                try await BackendPCDecisionDelivery.$validate.withValue({
                    await MainActor.run { fixture.state.checked() }
                }) { try await fixture.client.createAsync(launch) }
            }
        }
        XCTAssertEqual(result.id, launch.id)
        XCTAssertEqual(fixture.state.count, 1)
        XCTAssertEqual(fixture.state.last?.reference, "task:async-create")
    }
    func testCancellingOriginalAsyncCreateRevokesCallbackAlreadyAwaitingAuthority() async throws {
        let fixture = try fixture(), launch = try launch(), pause = Pause()
        let work = Task {
            try await BackendPCDecisionDelivery.$required.withValue(true) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue("task:cancelled-create") {
                    try await BackendPCDecisionDelivery.$validate.withValue({ await pause.suspend() }) {
                        try await fixture.client.createAsync(launch)
                    }
                }
            }
        }
        await pause.untilEntered()
        work.cancel()
        await pause.release()
        await refuses { _ = try await work.value }
        let proof = try XCTUnwrap(fixture.state.last)
        await refuses { try await self.consume(fixture, proof) }
    }
    func testCancellationRevocationInvalidatesAnInFlightTicket() async throws {
        let attachment = UUID(), pause = Pause()
        let broker = BackendPCDecisionHostValidation.Broker(host: UUID(), attachment: attachment, current: { attachment })
        let proof = try broker.issue(session: UUID().uuidString, reference: "task", digest: "request", input: true,
            validate: { await pause.suspend() })
        let work = Task { try await broker.consume(proof, effect: .spawn, cancellation: BackendMCPCancellation()) }
        await pause.untilEntered()
        broker.revoke(proof)
        await pause.release()
        await refuses { _ = try await work.value }
        await refuses { _ = try await broker.consume(proof, effect: .input, cancellation: BackendMCPCancellation()) }
    }
    func testRequiredProviderControlWithoutFinalHookIsRefusedBeforeCallbackOrEffect() async throws {
        let fixture = try fixture(), id = UUID().uuidString
        await refuses {
            _ = try await BackendPCDecisionDelivery.$required.withValue(true) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue("task:held-provider-control") {
                    try await BackendPCDecisionDelivery.$validate.withValue({ fixture.state.checked() }) {
                        try await fixture.client.resource("chats.provider", arguments: .object([
                            .init("id", .string(id)), .init("operation", .string("goal.resume")), .init("arguments", .object([]))]))
                    }
                }
            }
        }
        XCTAssertEqual(fixture.state.count, 0)
        XCTAssertNil(fixture.state.last)
        XCTAssertTrue(fixture.state.delivered.isEmpty)
    }
    private func writable(_ fixture: Fixture) throws -> BackendSessionMeta {
        let value = try launch()
        try fixture.manager.registerChat(value.metadata, controls: .init(send: { fixture.state.deliver($0) }, stop: {}, text: { "" }, pid: { nil }))
        return value.metadata
    }
    func testAsyncWriteCapturesScopeAndPreservesExpectedIncarnation() async throws {
        let fixture = try fixture(), meta = try writable(fixture)
        try await BackendPCDecisionDelivery.$required.withValue(true) {
            try await BackendPCDecisionDelivery.$hostedReference.withValue("task:async-write") {
                try await BackendPCDecisionDelivery.$validate.withValue({ await MainActor.run { fixture.state.checked() } }) {
                    try await fixture.client.writeAsync(meta.id, bytes: Data("exact input".utf8), expectedCreatedAt: meta.createdAt)
                    await self.refuses {
                        try await fixture.client.writeAsync(meta.id, bytes: Data("stale input".utf8), expectedCreatedAt: meta.createdAt + 1)
                    }
                }
            }
        }
        XCTAssertEqual(fixture.state.delivered, ["exact input"])
        XCTAssertEqual(fixture.state.count, 2)
    }
    func testCancellingOriginalAsyncWritePreventsInputAfterHeldCallback() async throws {
        let fixture = try fixture(), meta = try writable(fixture), pause = Pause()
        let work = Task {
            try await BackendPCDecisionDelivery.$required.withValue(true) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue("task:cancelled-write") {
                    try await BackendPCDecisionDelivery.$validate.withValue({ await pause.suspend() }) {
                        try await fixture.client.writeAsync(meta.id, bytes: Data("must stay unsent".utf8), expectedCreatedAt: meta.createdAt)
                    }
                }
            }
        }
        await pause.untilEntered()
        work.cancel(); await pause.release()
        await refuses { try await work.value }
        XCTAssertTrue(fixture.state.delivered.isEmpty)
    }
    #if TD_HOST_INTEGRATED
    func testRequiredManagerWriteUsesAsyncBridgeAndCancelledCallerCannotDeliver() async throws {
        let fixture = try fixture(), meta = try writable(fixture), pause = Pause()
        let frontend = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let bridge = BackendHOSTManagerBridge(client: fixture.client,
            write: { _, _, _ in XCTFail("Protected write used the synchronous bridge") }, drain: { _ in true },
            setWatched: { _ in }, stampIndependent: { _ in })
        let attached = expectation(description: "private manager attached")
        try frontend.installHOSTFrontend(bridge, ready: { attached.fulfill() }, disconnected: {})
        defer { frontend.detachHOSTFrontend() }
        await fulfillment(of: [attached], timeout: 5)
        XCTAssertTrue(frontend.isHostedSession(meta.id))
        let work = Task {
            try await BackendPCDecisionDelivery.$required.withValue(true) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue("task:manager-write") {
                    try await BackendPCDecisionDelivery.$validate.withValue({ await pause.suspend() }) {
                        try await frontend.writeAsync(meta.id, bytes: Data("must stay unsent".utf8), expectedCreatedAt: meta.createdAt)
                    }
                }
            }
        }
        await pause.untilEntered()
        work.cancel(); await pause.release()
        await refuses { try await work.value }
        XCTAssertTrue(fixture.state.delivered.isEmpty)
    }
    #endif
    func testDecisionChangedAfterPreparationRefusesAndBurnsTicket() async throws {
        let fixture = try fixture(), proof = try issue(fixture)
        fixture.state.deny()
        await refuses { try await self.consume(fixture, proof) }
        await refuses { try await self.consume(fixture, proof) }
        XCTAssertEqual(fixture.state.count, 1)
    }
    func testExactRequestSessionReferenceAndHelperBindingCannotBeSubstituted() async throws {
        let fixture = try fixture()
        for field in 0..<5 {
            let original = try issue(fixture)
            var changed = original
            switch field {
            case 0: changed.digest = "different-request"
            case 1: changed.sessionID = UUID().uuidString
            case 2: changed.reference = "different-task"
            case 3: changed.host = UUID()
            default: changed.attachment = UUID()
            }
            let tampered = changed
            await refuses { try await self.consume(fixture, tampered) }
            await refuses { try await self.consume(fixture, original) }
        }
        XCTAssertEqual(fixture.state.count, 0)
    }
    func testDisconnectAndNewAppAttachmentCannotReviveOldTicket() async throws {
        let fixture = try fixture(), proof = try issue(fixture)
        fixture.app.detach()
        let next = try attach(paths: fixture.paths, hello: fixture.host.hello)
        XCTAssertNotEqual(next.attachmentID(), proof.attachment)
        await refuses { try await self.consume(fixture, proof) }
        XCTAssertEqual(fixture.state.count, 0)
    }
    func testRequiredWorkRefusesOldHelperAndMissingDecisionReference() async throws {
        let old = try fixture(capable: false)
        XCTAssertThrowsError(try issue(old))
        let fixture = try fixture()
        try BackendPCDecisionDelivery.$required.withValue(true) {
            try BackendPCDecisionDelivery.$validate.withValue({}) {
                XCTAssertThrowsError(try BackendPCDecisionHostValidation.issue(host: fixture.host.hello,
                    session: UUID().uuidString, digest: "request", input: true))
            }
        }
        XCTAssertEqual(fixture.state.count, 0)
    }
    func testRevocationAndCancellationDuringAuthoritativeAwaitCannotPass() async throws {
        let fixture = try fixture(), proof = try issue(fixture)
        BackendPCDecisionHostValidation.revoke(proof)
        await refuses { try await self.consume(fixture, proof) }
        let scope = BackendMCPCancellation()
        let attachment = UUID()
        let broker = BackendPCDecisionHostValidation.Broker(host: UUID(), attachment: attachment, current: { attachment })
        let cancelled = try broker.issue(session: UUID().uuidString, reference: "task", digest: "request", input: false,
            validate: { scope.cancel() })
        await refuses { try await broker.consume(cancelled, effect: .spawn, cancellation: scope) }
        await refuses { try await broker.consume(cancelled, effect: .spawn, cancellation: BackendMCPCancellation()) }
    }
    func testRequiredAttributionSurvivesReloadWithoutPersistingTickets() throws {
        let root = try scratch(), id = UUID().uuidString
        let first = try BackendPCDecisionRequiredSessions(directory: root)
        try first.bind(session: id, reference: "task:one/scope:fixed")
        let reloaded = try BackendPCDecisionRequiredSessions(directory: root)
        XCTAssertTrue(reloaded.contains(id))
        let data = try Data(contentsOf: root.appendingPathComponent("decision-required-sessions.json"))
        let object = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(object, [id: "task:one/scope:fixed"])
    }
    /// Review sessions-security #3: a full list drops ended sessions' bindings instead of refusing every new one forever.
    func testFullAttributionListDropsEndedSessionsAndKeepsLiveOnes() throws {
        let root = try scratch()
        var saved: [String: String] = [:]
        for _ in 0..<4_096 { saved[UUID().uuidString] = "task:old/scope:fixed" }
        let live = saved.keys.sorted()[0], ended = saved.keys.sorted()[1]
        try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("decision-required-sessions.json"))
        let list = try BackendPCDecisionRequiredSessions(directory: root), fresh = UUID().uuidString
        XCTAssertThrowsError(try list.bind(session: fresh, reference: "task:new/scope:fixed"))
        try list.bind(session: fresh, reference: "task:new/scope:fixed", live: { [live] })
        XCTAssertTrue(list.contains(fresh)); XCTAssertTrue(list.contains(live)); XCTAssertFalse(list.contains(ended))
        let reloaded = try BackendPCDecisionRequiredSessions(directory: root)
        XCTAssertTrue(reloaded.contains(fresh)); XCTAssertTrue(reloaded.contains(live)); XCTAssertFalse(reloaded.contains(ended))
    }
    func testCorruptPersistedAttributionRefusesOwnerConstruction() throws {
        let root = try scratch()
        try Data("[]".utf8).write(to: root.appendingPathComponent("decision-required-sessions.json"))
        XCTAssertThrowsError(try BackendPCDecisionRequiredSessions(directory: root))
    }
    func testLaunchDigestExcludesOnlySealedCarrierAndIncludesActualCommand() throws {
        let input = BackendCreateSessionInput(cwd: "/tmp", provider: "shell")
        var launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString, input: input,
            spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: [], path: "/usr/bin:/bin", env: [:]), inheritedEnvironment: [:])
        let original = try BackendPCDecisionHostValidation.launchDigest(launch)
        launch.pcDecision = .init(sessionID: launch.id, reference: "task", digest: original, host: UUID(), attachment: UUID(), spawn: UUID(), input: nil)
        XCTAssertEqual(try BackendPCDecisionHostValidation.launchDigest(launch), original)
        launch.arguments.append("different")
        XCTAssertNotEqual(try BackendPCDecisionHostValidation.launchDigest(launch), original)
    }
}
