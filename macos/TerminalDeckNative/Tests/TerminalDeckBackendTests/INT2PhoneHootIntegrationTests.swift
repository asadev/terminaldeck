import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// The only doubles are a no-process session driver and an in-memory wire.
/// Trust, host dispatch, Hoot phone adapter, consent and durable chat are real.
private actor INT2PhoneHootDriver: BackendCopilotSessionDriving {
    private var live = false
    private(set) var starts = 0
    private(set) var stops = 0
    func hasClaude() async throws -> Bool { true }
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        .init(id: "system", name: "Fixture", provider: "claude", configDir: projectPath,
              system: true, color: "#000000", createdAt: 0, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) {
        ("unknown", nil, nil)
    }
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        starts += 1; live = true
        return .init(id: "int2-desk-owner", input: input,
                     spawn: .init(provider: "claude", command: "/not-executed", args: extraArguments, path: ""),
                     now: Date(timeIntervalSince1970: 1))
    }
    func isAlive(_ sessionID: String) async -> Bool { live && sessionID == "int2-desk-owner" }
    func stop(_ sessionID: String) async throws { stops += 1; live = false }
}

private struct INT2PhoneHootRecords: BackendCopilotSessionRecordsProviding {
    let root: URL
    func paths(userData: String) async throws -> BackendCopilotLayerRecords {
        try .init(paths: ["routines", "routine-state.json", "hoot-log", "remote/remote-device-kinds.json",
                         "remote/remote-auth.json", "remote/access-keys.json", "plugin-grants.json"].map {
            root.appendingPathComponent($0).path
        })
    }
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement {
        .init(fence: nil, reason: "No process is launched by this fixture.")
    }
}

private actor INT2PhoneHootWire {
    private var frames: [NativeRPCValue] = []
    private(set) var closes = 0
    func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    func close() { closes += 1 }
    func rows(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
}

/// Breaks only the construction cycle; every delivery enters the real adapter.
private actor INT2PhoneHootRelay {
    private var phone: BackendINT2HootPhone?
    func bind(_ phone: BackendINT2HootPhone) { self.phone = phone }
    func ask(_ question: BackendDeckCoreSecurityConsentRequest) async throws -> Bool {
        _ = try await phone?.ask(question)
        // The fixture also keeps a desktop approver available. This permits
        // assertions that an unrelated/expired question is not sent to a phone.
        return true
    }
    func settled(_ id: String, _ outcome: BackendDeckCoreSecurityConsentOutcome) async throws {
        try await phone?.settled(id: id, outcome: outcome)
    }
}

private final class INT2PhoneHootFixture: Sendable {
    struct Peer: Sendable { let id: UUID; let wire: INT2PhoneHootWire }
    let directory: URL
    let trust: BackendRemoteTrustStore
    let device: BackendRemoteCredential
    let host: BackendRemoteHost
    let chat: BackendHootChatStore
    let runtime: BackendCopilotSessionRuntime
    let driver: INT2PhoneHootDriver
    let broker: BackendDeckCoreSecurityConsentBroker
    let clock: BackendDeckCoreTestPortSecurityClock
    let phone: BackendINT2HootPhone
    let lease: NativeRPCSubscription
    let seed: [NativeRPCValue]

    init(level: BackendINT2PhoneAccessLevel = .full) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("INT2PhoneHoot-" + UUID().uuidString)
        self.directory = directory
        let trust = BackendRemoteTrustStore(directory: directory.appendingPathComponent("remote"))
        self.trust = trust
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Fixture phone", address: "fixture", publicKey: nil)
        self.device = device
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: level)
        let clock = BackendDeckCoreTestPortSecurityClock(1_000), relay = INT2PhoneHootRelay()
        self.clock = clock
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 60_000, clock: clock,
            ask: { try await relay.ask($0) }, settled: { try await relay.settled($0, $1) })
        self.broker = broker
        let seed = [
            HootChatEvent(conversationID: "desk-conversation", turnID: "turn-one", sequence: 1, provider: .claude,
                          record: .text(.user, id: "user-one", "Saved question"), at: 100).wireValue,
            HootChatEvent(conversationID: "desk-conversation", turnID: "turn-one", sequence: 2, provider: .claude,
                          record: .text(.message, id: "answer-one", "Saved answer"), at: 101).wireValue
        ]
        self.seed = seed
        let file = directory.appendingPathComponent("history.json")
        try NativeRPCValue.object([.init("version", .number(1)), .init("provider", .string("claude")),
            .init("conversationId", .string("desk-conversation")), .init("sessionId", .string("saved-cli-session")),
            .init("events", .array(seed))]).encodedJSON().write(to: file)
        let chat = try BackendHootChatStore(file: file, consent: broker, consentNow: { clock.now() })
        self.chat = chat
        let driver = INT2PhoneHootDriver(); self.driver = driver
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: directory.path, driver: driver,
            records: INT2PhoneHootRecords(root: directory), chat: chat))
        self.runtime = runtime
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let host = BackendRemoteHost(trust: trust, manager: manager, state: NativeStateStore(),
            home: directory.path, hostName: "Fixture", appVersion: "test", privateRoots: [])
        self.host = host
        let phone = BackendINT2HootPhone(trust: trust, endpoint: host, consent: broker, runtime: { runtime },
                                        log: { _ in [] }, setInteractive: { _ in })
        self.phone = phone
        await relay.bind(phone)
        let feature = await phone.feature()
        lease = try await host.installFeatures(ownerID: "int2.phone-hoot-test", features: [feature],
            connectionClosed: { await phone.disconnected($0) })
        try await host.start()
        let running = try await runtime.ensure()
        guard running.status == .running else { throw NativeRPCError(code: "fixture", message: "Fixture owner did not start.") }
    }

    func connect(capabilities: [String] = ["device.access", "copilot", "hoot.events"]) async throws -> Peer {
        let wire = INT2PhoneHootWire()
        guard let id = await host.accept(.init(address: "fixture", send: { try await wire.receive($0) },
                                               close: { _, _ in await wire.close() })) else {
            throw NativeRPCError(code: "fixture", message: "Fixture host rejected a wire.")
        }
        let peer = Peer(id: id, wire: wire)
        try await send(peer, "hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Fixture phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array(capabilities.map(NativeRPCValue.string)))])
        return peer
    }
    func send(_ peer: Peer, _ type: String, _ fields: [NativeRPCValue.Field] = []) async throws {
        let value = NativeRPCValue.object([.init("t", .string(type))] + fields)
        await host.receive(peer.id, text: String(decoding: try value.encodedJSON(), as: UTF8.self))
    }
    func question(tool: String = "settings.write", origin: String? = nil) async throws
        -> (Task<BackendDeckCoreSecurityConsentOutcome, Never>, BackendDeckCoreSecurityConsentRequest) {
        let origin = origin ?? "device:" + device.device.id
        let broker = broker
        let task = Task { await broker.request(tool: tool, tier: .alter, summary: "Fixture confirmation",
                                              arguments: .object([]), origin: origin) }
        try await Self.wait { await broker.list().count == 1 }
        guard let question = await broker.list().first else { throw NativeRPCError(code: "fixture", message: "Missing issued question.") }
        return (task, question)
    }
    static func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeRPCError(code: "fixture-timeout", message: "The actual host callback did not arrive.")
    }
    func finish() async {
        await host.stop(); await phone.stop(); await lease.cancelAndWait(); await broker.stop()
        _ = try? await runtime.quiesceAndStop(); await chat.stop(); await trust.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("INT2 actual phone Hoot join", .serialized)
struct INT2PhoneHootIntegrationTests {
    @Test func supportingPeerNegotiatesEventsAndCurrentGrantMetadata() async throws {
        let fixture = try await INT2PhoneHootFixture(level: .look)
        do {
            let peer = try await fixture.connect()
            let welcome = try #require(await peer.wire.rows("welcome").last)
            let capabilities = welcome["capabilities"].elements?.compactMap(\.string) ?? []
            #expect(capabilities.contains("copilot") && capabilities.contains("hoot.events") && capabilities.contains("device.access"))
            #expect(!capabilities.contains("copilot.files"))
            #expect(await peer.wire.rows("device.access").last?["level"].string == "look")
            try await fixture.send(peer, "copilot.hello")
            let look = try #require(await peer.wire.rows("copilot.grant").last)
            #expect(look["link"]["linked"].bool == true)
            #expect(look["link"]["grant"] == .object([.init("read", .bool(true)), .init("act", .bool(false)), .init("alter", .bool(false))]))
            try await fixture.trust.setPhoneAccess(fixture.device.device.id, level: .work)
            try await fixture.send(peer, "copilot.hello")
            #expect(await peer.wire.rows("copilot.grant").last?["link"]["grant"]["act"].bool == true)
            #expect(await peer.wire.rows("copilot.grant").last?["link"]["grant"]["alter"].bool == false)
            try await fixture.trust.setPhoneAccess(fixture.device.device.id, level: .full)
            try await fixture.send(peer, "copilot.hello")
            #expect(await peer.wire.rows("copilot.grant").last?["link"]["grant"]["alter"].bool == true)
            let oldPeer = try await fixture.connect(capabilities: ["copilot", "device.access"])
            #expect(await oldPeer.wire.rows("welcome").last?["capabilities"].elements?.contains(.string("hoot.events")) == false)
            try await fixture.send(oldPeer, "copilot.attach")
            #expect(await oldPeer.wire.rows("error").last?["code"].string == "unavailable")
            #expect(await oldPeer.wire.rows("hoot.events").isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func attachAndReconnectResetUseTheSameSavedOwnerConversation() async throws {
        let fixture = try await INT2PhoneHootFixture()
        do {
            #expect(fixture.runtime.structuredChat === fixture.chat)
            let first = try await fixture.connect()
            try await fixture.send(first, "copilot.attach")
            try await INT2PhoneHootFixture.wait { await first.wire.rows("hoot.events").count == 1 }
            let initial = try #require(await first.wire.rows("hoot.events").last)
            #expect(initial["conversationId"].string == fixture.chat.conversationID)
            #expect(initial["reset"].bool == true && initial["events"] == .array(fixture.seed))
            await fixture.host.closed(first.id)
            let second = try await fixture.connect()
            try await fixture.send(second, "copilot.attach")
            try await INT2PhoneHootFixture.wait { await second.wire.rows("hoot.events").count == 1 }
            #expect(await second.wire.rows("hoot.events").last == initial)
            #expect(await fixture.chat.cliSessionID == "saved-cli-session")
            #expect(await fixture.driver.starts == 1)
            #expect(await fixture.driver.stops == 0)
            #expect(try await fixture.runtime.state().sessionId == "int2-desk-owner")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func detachTransportCloseRevokeAndAreaTeardownLeaveTheSharedOwnerRunning() async throws {
        for reason in ["detach", "close", "revoke", "teardown"] {
            let fixture = try await INT2PhoneHootFixture()
            do {
                let peer = try await fixture.connect()
                try await fixture.send(peer, "copilot.attach")
                try await INT2PhoneHootFixture.wait { await peer.wire.rows("hoot.events").count == 1 }
                switch reason {
                case "detach": try await fixture.send(peer, "copilot.detach")
                case "close": await fixture.host.closed(peer.id)
                case "revoke":
                    try await fixture.trust.revoke(fixture.device.device.id)
                    await fixture.host.remoteServeDropDevice(fixture.device.device.id)
                default: await fixture.phone.stop(); await fixture.lease.cancelAndWait()
                }
                // An independent owner subscription stays usable. Stopping a
                // chat with no CLI publishes its existing snapshot; this test
                // action never stops the running runtime's no-process driver.
                var owner = await fixture.chat.subscribe().makeAsyncIterator()
                let saved = await owner.next()
                await fixture.chat.stop()
                let published = await owner.next()
                #expect(saved?["events"] == .array(fixture.seed) && published?["events"] == .array(fixture.seed))
                try await Task.sleep(for: .milliseconds(100))
                #expect(await peer.wire.rows("hoot.events").count == 1, "Phone received an update after \(reason)")
                #expect(await fixture.driver.starts == 1)
                #expect(await fixture.driver.stops == 0)
                #expect(try await fixture.runtime.state().status == .running)
                #expect(await fixture.chat.cliSessionID == "saved-cli-session")
                if reason == "revoke" { #expect(await fixture.host.connections().isEmpty) }
            } catch { await fixture.finish(); throw error }
            await fixture.finish()
        }
    }

    @Test func brokerIssuedQuestionUsesCurrentFullAndCannotBeAnsweredTwice() async throws {
        let fixture = try await INT2PhoneHootFixture()
        do {
            let peer = try await fixture.connect()
            try await fixture.send(peer, "copilot.hello")
            let (request, question) = try await fixture.question()
            try await INT2PhoneHootFixture.wait { await peer.wire.rows("copilot.ask").count == 1 }
            #expect(await peer.wire.rows("copilot.ask").last?["question"]["id"].string == question.id)
            try await fixture.send(peer, "copilot.answer", [.init("id", .string("forged-question")), .init("approved", .bool(true))])
            #expect(await fixture.broker.list().first?.id == question.id)
            for tier in [BackendINT2PhoneAccessLevel.work, .look] {
                try await fixture.trust.setPhoneAccess(fixture.device.device.id, level: tier)
                // Deliberately do not refresh/reconnect the wire: dispatch must
                // re-read trust, rather than reuse the Full hello context.
                try await fixture.send(peer, "copilot.answer", [.init("id", .string(question.id)), .init("approved", .bool(true))])
                #expect(await fixture.broker.list().first?.id == question.id)
                #expect(await peer.wire.rows("error").last?["code"].string == "unauthorized")
            }
            try await fixture.trust.setPhoneAccess(fixture.device.device.id, level: .full)
            try await fixture.send(peer, "copilot.answer", [.init("id", .string(question.id)), .init("approved", .bool(true))])
            let outcome = await request.value
            #expect(outcome.granted && outcome.by == "device:" + fixture.device.device.id)
            try await INT2PhoneHootFixture.wait { await peer.wire.rows("copilot.settled").count == 1 }
            #expect(await peer.wire.rows("copilot.settled").last?["settled"]["id"].string == question.id)
            try await fixture.send(peer, "copilot.answer", [.init("id", .string(question.id)), .init("approved", .bool(true))])
            #expect(await fixture.broker.list().isEmpty)
            #expect(await peer.wire.rows("error").last?["code"].string == "unavailable")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func expiredAndOtherDeviceQuestionsCannotBeApproved() async throws {
        let fixture = try await INT2PhoneHootFixture()
        do {
            let peer = try await fixture.connect()
            try await fixture.send(peer, "copilot.hello")
            let (foreign, otherQuestion) = try await fixture.question(origin: "device:other-phone")
            try await fixture.send(peer, "copilot.pending")
            #expect(await peer.wire.rows("copilot.pending").last?["questions"].elements?.isEmpty == true)
            try await fixture.send(peer, "copilot.answer", [.init("id", .string(otherQuestion.id)), .init("approved", .bool(true))])
            #expect(await fixture.broker.list().first?.id == otherQuestion.id)
            try await fixture.broker.callerGone("device:other-phone")
            #expect(await foreign.value.reason == .callerGone)
            let (expired, question) = try await fixture.question()
            try await INT2PhoneHootFixture.wait { fixture.clock.pending() > 0 }
            fixture.clock.advance(question.expiresAt - fixture.clock.now() + 1)
            try await fixture.send(peer, "copilot.answer", [.init("id", .string(question.id)), .init("approved", .bool(true))])
            let outcome = await expired.value
            #expect(!outcome.granted && outcome.reason == .timeout)
            #expect(await fixture.broker.list().isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func hootCLIQuestionNeedsTheStoresPrivateLiveBinding() async throws {
        let fixture = try await INT2PhoneHootFixture()
        do {
            let peer = try await fixture.connect()
            try await fixture.send(peer, "copilot.hello")
            // An issued broker ID alone does not manufacture a CLI turn or
            // permission request in the saved store.
            let (request, question) = try await fixture.question(tool: "hoot.cli")
            try await fixture.send(peer, "copilot.answer", [.init("id", .string(question.id)), .init("approved", .bool(true))])
            #expect(await peer.wire.rows("error").last?["code"].string == "unavailable")
            #expect(await fixture.broker.list().first?.id == question.id)
            #expect(await fixture.chat.snapshot()["events"] == .array(fixture.seed))
            try await fixture.broker.callerGone("device:" + fixture.device.device.id)
            #expect(await request.value.reason == .callerGone)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func disconnectCancelsTheDevicesPendingQuestion() async throws {
        let fixture = try await INT2PhoneHootFixture()
        do {
            let peer = try await fixture.connect()
            try await fixture.send(peer, "copilot.hello")
            let (request, _) = try await fixture.question()
            await fixture.host.closed(peer.id)
            let outcome = await request.value
            #expect(!outcome.granted && outcome.reason == .callerGone)
            #expect(await fixture.broker.list().isEmpty)
            #expect(await fixture.driver.stops == 0)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func actualTaskPanelRequiresIssuedIdentityAndItsExactNegotiatedDomain() async throws {
        let fixture = try await INT2PhoneHootFixture()
        let data = fixture.directory.appendingPathComponent("panel-core")
        let store = NativeStateStore()
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: fixture.directory.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in fixture.directory.appendingPathComponent("hoot").path })
        do {
            let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: fixture.directory,
                appName: "INT2 Phone Fixture", appID: "terminaldeck", helperExecutable: data.appendingPathComponent("never-run"),
                inheritedEnvironment: [:])
            let bindings = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
            let control = try BackendDeckCoreSecurityControl(log: .init(directory: data.appendingPathComponent("actions")), consent: fixture.broker)
            let scope = BackendINT2PhonePanelScope(endpoint: fixture.host, trust: fixture.trust, control: control, bindings: bindings,
                projectRows: { [] }, sessionLinks: { _, _ in [:] })
            let provider = BackendINT2PhonePanels.tasks(scope: scope)
            let rpc = NativeRPCContext(caller: .pairedDevice, ownerID: fixture.device.device.id)
            let request = BackendRemotePanelRequest(path: data.path, scope: nil, query: nil)
            // Knowing a real credential's owner ID does not supply the host's
            // TaskLocal connection, and nativeApp is never projected for it.
            for caller in [rpc, NativeRPCContext(caller: .nativeApp, ownerID: fixture.device.device.id)] {
                do {
                    _ = try await provider.read(request, caller)
                    Issue.record("Task panel accepted a caller without the issued host connection")
                } catch let failure as NativeRPCError { #expect(failure.code == "access-denied") }
            }
            let panels = BackendRemotePanelRegistry()
            try await panels.register(.tasks, provider: provider)
            let panelFeature = try await panels.feature()
            try await fixture.host.register(panelFeature)
            let unsupported = try await fixture.connect(capabilities: ["device.access", "copilot", "panels.goals"])
            let oldWelcome = try #require(await unsupported.wire.rows("welcome").last)
            #expect(oldWelcome["capabilities"].elements?.contains(.string("panels.tasks")) == false)
            #expect(oldWelcome["capabilities"].elements?.contains(.string("panels.goals")) == false)
            try await fixture.send(unsupported, "panel.read", [.init("panel", .string("tasks")), .init("path", .string(data.path))])
            let domainRefusal = try #require(await unsupported.wire.rows("error").last)
            #expect(domainRefusal["code"].string == "unavailable")
            #expect(domainRefusal["message"].string == "This device did not negotiate panels.")
            let supported = try await fixture.connect(capabilities: ["device.access", "panels.tasks"])
            let welcome = try #require(await supported.wire.rows("welcome").last)
            #expect(welcome["capabilities"].elements?.contains(.string("panels.tasks")) == true)
            #expect(welcome["capabilities"].elements?.contains(.string("panels.memory")) == false)
            try await fixture.send(supported, "panel.read", [.init("panel", .string("tasks")), .init("path", .string(data.path))])
            // The actual provider now passes identity/negotiation and reaches
            // its real Core policy lookup. This focused fixture deliberately
            // installs no task operation, so it must refuse instead of rows.
            let policyRefusal = try #require(await supported.wire.rows("error").last)
            #expect(policyRefusal["code"].string == "unavailable")
            #expect(policyRefusal["message"].string == "The existing tasks.local tool is unavailable.")
            #expect(await supported.wire.rows("panel.rows").isEmpty)
            #expect(BackendINT2PhonePanelCaller.current == nil)
        } catch {
            await state.stop(); try? await root.shutdown(); await fixture.finish(); throw error
        }
        await state.stop(); try await root.shutdown(); await fixture.finish()
    }
}
