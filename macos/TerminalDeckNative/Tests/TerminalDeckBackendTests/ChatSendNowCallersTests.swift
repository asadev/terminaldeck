import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor SendNowCallerDriver: BackendCopilotSessionDriving {
    func hasClaude() async throws -> Bool { true }
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        .init(id: "system", name: "Fixture", provider: "claude", configDir: projectPath, system: true,
              color: "#000000", createdAt: 0, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) { ("unknown", nil, nil) }
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        .init(id: "hosted-hoot", input: input, spawn: .init(provider: "claude", command: "/not-run", args: [], path: ""), now: Date())
    }
    func isAlive(_ sessionID: String) async -> Bool { true }
    func stop(_ sessionID: String) async throws {}
}
private struct SendNowCallerRecords: BackendCopilotSessionRecordsProviding {
    let root: URL
    func paths(userData: String) async throws -> BackendCopilotLayerRecords {
        try .init(paths: ["routines", "routine-state.json", "hoot-log", "remote/remote-device-kinds.json", "remote/remote-auth.json", "remote/access-keys.json", "plugin-grants.json"].map { root.appendingPathComponent($0).path })
    }
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement { .init(fence: nil, reason: "Scratch fixture only") }
}
private final class SendNowCallerWire: @unchecked Sendable {
    let lock = NSLock()
    var sent: [NativeRPCValue] = []
    var fail = false
    func calls() -> [NativeRPCValue] { lock.withLock { sent } }
    func reply(_ method: String, _ data: Data, root: URL) throws -> Data {
        let message = try NativeRPCValue.parseJSON(data)
        if method == "chats.say" || method == "chats.steer" {
            try BackendHOSTChats.validateDeliveryIdentity(method, payload: data)
            // The whole payload and the generated ID must already be on disk when the socket arrives.
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("chat-outgoing"), includingPropertiesForKeys: nil)
            #expect(try files.contains { try NativeRPCValue.parseJSON(Data(contentsOf: $0))["message"] == message })
            lock.withLock { sent.append(message) }
            if fail { throw NativeRPCError(code: "uncertain-delivery", message: "Scratch reply lost after accepting the message") }
        }
        let events = [HootChatEvent(conversationID: "caller-chat", turnID: "caller-turn", sequence: 1, provider: .claude,
            record: .init(.completed, value: .object([]))).wireValue]
        let value: NativeRPCValue = method == "chats.inventory" ? .object([.init("jobs", .array([])), .init("sessions", .array([]))]) :
            .object([.init("alive", .bool(true)), .init("busy", .bool(false)), .init("foreground", .bool(false)),
                     .init("conversationId", .string("caller-chat")), .init("events", .array(events)), .init("sequence", .number(1))])
        return try value.encodedJSON()
    }
}

private final class SendNowCallerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 9089.9)
    func read() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
}

@Suite("Current phone, MCP, task and Hoot send identities", .serialized)
struct ChatSendNowCallersTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL, client: BackendHOSTClient, server: BackendHOSTServer, chat: BackendHootChatStore
        let wire = SendNowCallerWire()
        let runtime: BackendCopilotSessionRuntime
        init() async throws {
            root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("sn-call-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
            let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
            let wire = self.wire, root = self.root
            server = try BackendHOSTServer(paths: paths, hostVersion: "scratch-callers", manager: manager,
                launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {},
                resource: { try wire.reply($0, $1, root: root) }, chatUpdates: { AsyncStream { _ in } })
            client = try BackendHOSTClient(paths: paths)
            chat = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
            runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: root.path, driver: SendNowCallerDriver(), records: SendNowCallerRecords(root: root), chat: chat))
            try await chat.connectHosted(client, sessionID: "hosted-hoot")
        }
        func close() { client.detach(); server.stopListening(); try? FileManager.default.removeItem(at: root) }
    }
    private func parse(_ value: NativeRPCValue) throws -> BackendRemoteClientMessage {
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(value) else { throw NativeRPCError.invalidArguments("Fixture frame did not parse") }
        return message
    }
    @Test func hostedHootSaySteerAndRuntimeChannelsAlwaysNameAndSaveTheirAttempts() async throws {
        let f = try await Fixture(); defer { f.close() }
        _ = try await f.chat.say("same text")
        _ = try await f.chat.steer("same text")
        _ = try await f.runtime.invoke("hoot:chat:say", arguments: [.string("same text")])
        _ = try await f.runtime.invoke("hoot:chat:steer", arguments: [.string("same text"), .array([]), .object([]), .string("explicit-steer")])
        let ids = f.wire.calls().compactMap { $0["clientMessageId"].string }
        #expect(ids.count == 4 && Set(ids).count == 4)
        #expect(ids.last == "explicit-steer")
    }
    @Test func hootMCPAskSendAndAliasUseTheHostedSendBoundary() async throws {
        let f = try await Fixture(); defer { f.close() }
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .key, keyName: "fixture") },
            knownFolder: { _, folder in folder }, session: { _, _ in .null }, runnableProject: { _, folder in folder },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "fixture") }, authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let tools = try BackendHootChatMCP.definitions(runtime: f.runtime, access: access, visible: { _ in })
        let context = BackendMCPCallContext(sessionID: "external", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["hoot.chat.ask", "hoot.send", "hoot_say"], allowedTiers: [.alter], cancellation: .init())
        for id in ["hoot.chat.ask", "hoot.send"] {
            let tool = try #require(tools.first { $0.spec.id == id })
            let args = NativeRPCValue.object([.init(id == "hoot.send" ? "text" : "message", .string("MCP note " + id))])
            _ = try await tool.handler(context, args)
            _ = try await tool.handler(context, args)
        }
        let send = try #require(tools.first { $0.spec.id == "hoot.send" })
        #expect(send.aliases.contains("hoot_say"))
        let args = NativeRPCValue.object([.init("text", .string("intentional repeat")), .init("clientMessageId", .string("mcp-retry"))])
        _ = try await send.handler(context, args)
        _ = try await send.handler(context, args)
        #expect(f.wire.calls().count == 3, "A repeated tool operation with the same ID does not send again")
        #expect(f.wire.calls().last?["clientMessageId"].string == "mcp-retry")
        f.wire.fail = true
        let lost = NativeRPCValue.object([.init("text", .string("idless tool reply lost"))])
        do { _ = try await send.handler(context, lost); Issue.record("First reply must be lost") } catch {}
        do { _ = try await send.handler(context, lost); Issue.record("Uncertain tool retry must stay held") }
        catch { #expect(error.localizedDescription.contains("held in the queue")) }
        #expect(f.wire.calls().count == 4, "An id-less MCP retry must not write twice")
    }
    @Test func taskAndBackgroundTurnsKeepOneIDThroughTheirSendAndReplay() async throws {
        let f = try await Fixture(); defer { f.close() }
        let task = BackendHootTaskTurn(taskID: "task-one", title: "One", body: "", brief: "task brief")
        _ = try await f.runtime.taskTurn(task, progress: { _ in })
        _ = try await f.runtime.taskTurn(task, progress: { _ in })
        #expect(f.wire.calls().count == 1)
        #expect(f.wire.calls().first?["clientMessageId"].string == task.clientMessageID)
        let background = BackendHootBackgroundTurn(reason: "handoff", id: "one", title: "One", message: "background brief")
        _ = try await f.runtime.backgroundTurn(background)
        #expect(f.wire.calls().last?["clientMessageId"].string == background.clientMessageID)
        #expect(background.clientMessageID != task.clientMessageID)
    }
    @Test func phoneHootSendReachesHostedStoreAndPreservesItsID() async throws {
        let f = try await Fixture(); defer { f.close() }
        let trust = BackendRemoteTrustStore(directory: f.root.appendingPathComponent("remote")); try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Scratch phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine); try await trust.setPhoneAccess(device.device.id, level: .work)
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(), home: f.root.path, hostName: "Fixture", appVersion: "test", privateRoots: [])
        try await host.start()
        let connection = try #require(await host.accept(.init(address: "fixture", send: { _ in }, close: { _, _ in })))
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)), .init("device", .object([.init("name", .string("Scratch phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([.string("hoot")]))])
        await host.receive(connection, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        let context = BackendRemoteHostContext(connectionID: connection, deviceID: device.device.id, kind: .mine, address: "fixture", peerPublicKey: nil, claimedCapabilities: ["hoot"], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .work)
        let phone = BackendINT2HootPhone(trust: trust, endpoint: host, consent: .init(ask: { _ in false }), runtime: { f.runtime }, log: { _ in [] }, setInteractive: { _ in })
        let feature = await phone.feature()
        for identity in [NativeRPCValue.null, NativeRPCValue.null, .string("phone-retry"), .string("phone-retry")] {
            let frame = try parse(.object([.init("t", .string("hoot.say")), .init("text", .string("phone note")), .init("clientMessageId", identity)]))
            _ = try await feature.handle(frame, context)
        }
        #expect(f.wire.calls().count == 2)
        #expect(f.wire.calls().last?["clientMessageId"].string == "phone-retry")
        await host.stop()
    }
    @Test func phoneSessionSayAndSteerPassSuppliedOrGeneratedIDs() async throws {
        let f = try await Fixture(); defer { f.close() }
        var engine = BackendPhoneChats.Engine(read: { _ in .object([]) }, isChat: { _ in true }, say: { _, _ in },
            interrupt: { _ in }, answer: { _, _, _ in }, start: { _ in throw BackendHOSTFailure.unavailable })
        engine.sendIdentified = { _, text, messageID, steer in
            if steer { _ = try await f.chat.steer(text, clientMessageID: messageID) }
            else { _ = try await f.chat.say(text, clientMessageID: messageID) }
        }
        let phone = BackendPhoneChats(engine: engine, host: .init(send: { _, _ in }, stillSees: { _, _ in true }, admitStarted: { _, _ in }))
        let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "fixture", kind: .mine, address: "fixture", peerPublicKey: nil,
            claimedCapabilities: ["chats"], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .work)
        for verb in ["chats.say", "chats.steer"] {
            let retryID = verb == "chats.say" ? "phone-say-retry" : "phone-steer-retry"
            for identity in [NativeRPCValue.null, NativeRPCValue.null, .string(retryID), .string(retryID)] {
                let frame = try parse(.object([.init("t", .string(verb)), .init("id", .string("hosted-hoot")), .init("text", .string("phone session note " + verb)), .init("clientMessageId", identity)]))
                _ = try await phone.handle(frame, context: context)
            }
        }
        let ids = f.wire.calls().compactMap { $0["clientMessageId"].string }
        #expect(ids.count == 4 && Set(ids).count == 4)
        #expect(ids.contains("phone-say-retry") && ids.contains("phone-steer-retry"))
    }
    @Test func compatibilityIdentityUsesExactBytesCallerConversationAndCallerClock() {
        let early = Date(timeIntervalSince1970: 9000)
        func id(_ text: String = "same", caller: String = "phone:one", chat: String = "chat", frame: NativeRPCValue = .object([]), now: Date = Date(timeIntervalSince1970: 9000)) -> String {
            BackendChatRetryIdentity.messageID(nil, caller: caller, conversation: chat, text: text, frame: frame, now: now)
        }
        #expect(id() == id(now: early.addingTimeInterval(30)))
        #expect(id() == id(now: early.addingTimeInterval(300)), "The registry, rather than a wall-clock bucket, chooses the saved operation")
        #expect(id() != id(caller: "phone:two"))
        #expect(id() != id(chat: "other"))
        #expect(id("same") != id("same "))
        #expect(id("é") != id("e\u{301}"), "Hash bytes without Unicode normalization")
        for key in ["sentAt", "timestamp", "sequence", "clientSequence"] {
            let marker = NativeRPCValue.object([.init(key, .number(123))])
            #expect(id(frame: marker) == id(frame: marker, now: early.addingTimeInterval(300)))
            #expect(id(frame: marker) != id(frame: .object([.init(key, .number(124))])))
        }
        #expect(BackendChatRetryIdentity.messageID("supplied", caller: "phone", conversation: "chat", text: "same", now: early) == "supplied")
    }
    @Test func phoneParserRetainsItsOwnSendClockAcrossRetryWindows() throws {
        for verb in ["chats.say", "chats.steer", "hoot.say"] {
            let frame = try parse(.object([.init("t", .string(verb)), .init("id", .string("chat")), .init("text", .string("same")),
                .init("sentAt", .number(12345)), .init("clientSequence", .string("7"))]))
            #expect(frame["sentAt"].number == 12345)
            #expect(frame["clientSequence"].string == "7")
            let before = BackendChatRetryIdentity.messageID(nil, caller: "phone", conversation: "chat", text: "same", frame: frame.value, now: Date(timeIntervalSince1970: 9000))
            let after = BackendChatRetryIdentity.messageID(nil, caller: "phone", conversation: "chat", text: "same", frame: frame.value, now: Date(timeIntervalSince1970: 9300))
            #expect(before == after)
        }
    }
    @Test func idlessPhoneLostReplyAcrossOldBoundaryAndReconnectStaysHeld() async throws {
        let f = try await Fixture(); defer { f.close() }
        let clock = SendNowCallerClock()
        var engine = BackendPhoneChats.Engine(read: { _ in .object([]) }, isChat: { _ in true }, say: { _, _ in },
            interrupt: { _ in }, answer: { _, _, _ in }, start: { _ in throw BackendHOSTFailure.unavailable })
        engine.sendIdentified = { _, text, messageID, _ in _ = try await f.chat.say(text, clientMessageID: messageID) }
        func phone() -> BackendPhoneChats {
            BackendPhoneChats(engine: engine, host: .init(send: { _, _ in }, stillSees: { _, _ in true }, admitStarted: { _, _ in }), now: { clock.read() })
        }
        func context() -> BackendRemoteHostContext {
            .init(connectionID: UUID(), deviceID: "stable-phone", kind: .mine, address: "fixture", peerPublicKey: nil,
                  claimedCapabilities: ["chats"], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .work)
        }
        let frame = try parse(.object([.init("t", .string("chats.say")), .init("id", .string("hosted-hoot")), .init("text", .string("same phone note"))]))
        f.wire.fail = true
        do { _ = try await phone().handle(frame, context: context()); Issue.record("First reply must be lost") } catch {}
        clock.advance(0.2)
        // A fresh adapter and connection must still name the original saved pending send.
        do { _ = try await phone().handle(frame, context: context()); Issue.record("Unknown delivery must stay held") }
        catch { #expect(error.localizedDescription.contains("held in the queue")) }
        #expect(f.wire.calls().count == 1)
        clock.advance(300); f.wire.fail = false
        do { _ = try await phone().handle(frame, context: context()); Issue.record("Pending sends must remain held even after 120 seconds") }
        catch { #expect(error.localizedDescription.contains("held in the queue")) }
        #expect(f.wire.calls().count == 1)
        #expect(Set(f.wire.calls().compactMap { $0["clientMessageId"].string }).count == 1)
        #expect(f.wire.calls().allSatisfy { $0["text"].string == "same phone note" })
    }
    @Test(arguments: [9, 11]) func confirmedIdlessRetryWindowAcrossReload(minutes: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-window-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 9089.9)
        let outgoing = root.appendingPathComponent("outgoing"), keeper = root.appendingPathComponent("keeper")
        func request(at date: Date) -> NativeRPCValue {
            .object([.init("id", .string("chat")), .init("text", .string("same")), .init("clientMessageId", .string(
                BackendChatRetryIdentity.messageID(nil, caller: "phone", conversation: "chat", text: "same", now: date)))])
        }
        let first = try BackendChatDeliveryQueue(directory: outgoing).claim(request(at: start), now: start)
        #expect(!first.confirmed)
        var actualSends = 0
        func deliver(_ message: NativeRPCValue, at date: Date) throws {
            // Each call opens a fresh keeper registry, as after a keeper restart.
            let queue = BackendChatDeliveryQueue(directory: keeper)
            if try !queue.begin(message, now: date) { actualSends += 1; try queue.finish(message, now: date) }
        }
        try deliver(first.message, at: start)
        // Lost reply: app reload retains uncertainty; keeper reload returns confirmation.
        let boundary = start.addingTimeInterval(0.2)
        let restored = try BackendChatDeliveryQueue(directory: outgoing).resolve(request(at: boundary), now: boundary)
        #expect(restored == first.message)
        try deliver(restored, at: boundary)
        #expect(actualSends == 1)
        try BackendChatDeliveryQueue(directory: outgoing).finish(restored, now: boundary)
        let retryAt = boundary.addingTimeInterval(Double(minutes) * 60)
        let retry = try BackendChatDeliveryQueue(directory: outgoing).claim(request(at: retryAt), now: retryAt)
        if minutes == 9 {
            #expect(retry.confirmed)
            #expect(retry.message == first.message)
            try deliver(retry.message, at: retryAt)
            // Lose the replay reply, then reload beyond the original completion cutoff.
            let slidingAt = retryAt.addingTimeInterval(9 * 60)
            let sliding = try BackendChatDeliveryQueue(directory: outgoing).claim(request(at: slidingAt), now: slidingAt)
            #expect(sliding.confirmed)
            #expect(sliding.message == first.message)
            try deliver(sliding.message, at: slidingAt)
            #expect(actualSends == 1)
        } else {
            #expect(!retry.confirmed)
            #expect(retry.message["clientMessageId"] != first.message["clientMessageId"])
            try deliver(retry.message, at: retryAt)
            #expect(actualSends == 2)
        }
    }
    @Test func bothRegistriesBoundCleanupAndHoldExpiredExplicitReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-bound-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 10000)
        func message(_ index: Int, chat: String = "chat") -> NativeRPCValue {
            .object([.init("id", .string(chat)), .init("text", .string("note")), .init("clientMessageId", .string("explicit-" + String(index)))])
        }
        for registry in ["chat-outgoing", "delivery-requests"] {
            let directory = root.appendingPathComponent(registry)
            let queue = BackendChatDeliveryQueue(directory: directory)
            for index in 0..<500 {
                let date = start.addingTimeInterval(Double(index) / 1000)
                #expect(try !queue.begin(message(index), now: date))
                try queue.finish(message(index), now: date)
            }
            let later = start.addingTimeInterval(601)
            #expect(try !queue.begin(message(500), now: later))
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(files.filter { $0.pathExtension == "json" }.count == 500)
            let reloaded = BackendChatDeliveryQueue(directory: directory)
            #expect(throws: (any Error).self) { try reloaded.begin(message(0), now: later) }
            // Per-conversation limit: another conversation still has room.
            #expect(try !reloaded.begin(message(501, chat: "other"), now: later))
            let expired = later.addingTimeInterval(86401)
            #expect(try !reloaded.begin(message(502), now: expired))
            #expect(throws: (any Error).self) { try BackendChatDeliveryQueue(directory: directory).begin(message(1), now: expired) }
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(remaining.filter { $0.pathExtension == "json" }.count == 1)
            #expect(try Data(contentsOf: directory.appendingPathComponent("retired.bin")).count == 65536)
        }
    }
    @Test func fullPendingRegistryHoldsNewSendWithoutEvictingUncertainty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-full-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = BackendChatDeliveryQueue(directory: root), now = Date()
        func message(_ index: Int) -> NativeRPCValue {
            .object([.init("id", .string("chat")), .init("clientMessageId", .string("pending-" + String(index)))])
        }
        for index in 0..<500 { #expect(try !queue.begin(message(index), now: now)) }
        #expect(throws: (any Error).self) { try queue.begin(message(500), now: now) }
        #expect(throws: (any Error).self) { try BackendChatDeliveryQueue(directory: root).begin(message(0), now: now) }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.count == 500)
    }
    @Test func keeperClaimsRemainHeldAcrossReloadAndCompletedClaimsNeverSendAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-claim-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let message = NativeRPCValue.object([.init("id", .string("chat")), .init("text", .string("queued")), .init("clientMessageId", .string("once")),
            .init("attachments", .array([.object([.init("type", .string("image")), .init("source", .string("retained"))])]))])
        let first = BackendChatDeliveryQueue(directory: root)
        #expect(try first.begin(message) == false)
        let reloaded = BackendChatDeliveryQueue(directory: root)
        do { _ = try reloaded.begin(message); Issue.record("A pending send was released after reload") }
        catch { #expect(error.localizedDescription.contains("held in the queue")) }
        try first.finish(message)
        #expect(try reloaded.begin(message) == true)
        #expect(try reloaded.begin(message.setting("clientMessageId", .string("another intentional send"))) == false)
    }
    @Test func savedOutgoingMessageSurvivesLostReplyAndRefusesChangedPayload() async throws {
        let f = try await Fixture(); defer { f.close() }
        f.wire.fail = true
        do { _ = try await f.chat.say("keep me", clientMessageID: "lost"); Issue.record("Fixture should lose the reply") } catch {}
        let fresh = BackendHOSTChatClient(client: f.client)
        let fields: [NativeRPCValue.Field] = [.init("text", .string("keep me")), .init("attachments", .array([])), .init("context", .object([])), .init("clientMessageId", .string("lost"))]
        do { _ = try await fresh.call("say", id: "hosted-hoot", fields: fields); Issue.record("Unknown delivery must remain held") }
        catch { #expect(error.localizedDescription.contains("held in the queue")) }
        do { _ = try await fresh.call("say", id: "hosted-hoot", fields: fields.filter { $0.key != "text" } + [.init("text", .string("changed"))]); Issue.record("Reused ID must not change text") } catch {}
        #expect(f.wire.calls().count == 1)
    }
}
