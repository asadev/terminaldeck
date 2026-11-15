import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 14 Nov phone asks (team/phone-apps/notes/2026-11-14-mac-asks.md), the Mac side, over the real host and a fixture
/// phone link: a default folder for the person's own phone, a first message on a start (`start.text`: "not sent" is
/// the phones' own `error {rid, code: unavailable}`, no frame of its own), the start's rid as the session row's `rid`
/// (`start.rid`), and an older phone answered exactly as before. No app, engine or session host.
@Suite("Phone start asks", .serialized)
struct PhoneStartAsksTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func of(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
        /// The `error` frames that carry this rid (the phones' "not sent").
        func errors(rid: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == "error" && $0["rid"].string == rid } }
        /// Bounded: five seconds, then the test fails rather than hanging.
        func waitForError(rid: String) async throws -> NativeRPCValue {
            for _ in 0..<250 {
                if let found = errors(rid: rid).last { return found }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NativeRPCError(code: "fixture-timeout", message: "No error for \(rid) within five seconds.")
        }
        /// Bounded: five seconds, then the test fails rather than hanging.
        func waitFor(_ type: String) async throws -> NativeRPCValue {
            for _ in 0..<250 {
                if let found = frames.last(where: { $0["t"].string == type }) { return found }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NativeRPCError(code: "fixture-timeout", message: "No \(type) frame within five seconds.")
        }
    }
    private actor Deliveries {
        var jobs: [BackendPhoneStartText.Job] = []
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
        func take(_ job: BackendPhoneStartText.Job) -> Bool { jobs.append(job); return answer }
        /// Bounded wait for the delivery to have run.
        func waitForJob() async throws {
            for _ in 0..<250 where jobs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            if jobs.isEmpty { throw NativeRPCError(code: "fixture-timeout", message: "No delivery within five seconds.") }
        }
    }

    /// A host with a fixture `create` (no session is spawned), one phone of the person's own, its frames captured.
    private struct Link {
        let host: BackendRemoteHost, trust: BackendRemoteTrustStore, directory: URL
        let capture = Capture()
        var connection = UUID()
        /// What a test's setup must keep alive (a feature's owner holds itself weakly).
        var kept: (any Sendable)? = nil
        func send(_ type: String, _ fields: [NativeRPCValue.Field]) async throws {
            await host.receive(connection, text: String(decoding: try NativeRPCValue.object([.init("t", .string(type))] + fields).encodedJSON(), as: UTF8.self))
        }
        func close() async { await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: directory) }
    }

    static func meta(_ id: String, chat: Bool, provider: String = "claude", cwd: String = "/Projects/Phone") -> BackendSessionMeta {
        var input = BackendCreateSessionInput(cwd: cwd, provider: provider)
        input.chat = chat
        return .init(id: id, input: input, spawn: .init(provider: provider, command: "/not-run", args: [], path: ""), now: Date(timeIntervalSince1970: 1))
    }

    private static func link(claims: [String], defaultFolder: String? = nil, deliver: Deliveries? = nil, chat: Bool = false,
                             guestFolders: [String]? = nil,
                             before: (@Sendable (BackendRemoteHost, BackendRemoteTrustStore) async throws -> (any Sendable)?)? = nil) async throws -> Link {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneStartAsks-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let device = try await trust.redeem(try await trust.createPairingOffer().token, name: "Test phone", address: "test", publicKey: nil)
        try await trust.approve(device.device.id, kind: guestFolders == nil ? .mine : .guest)
        if let guestFolders { try await trust.remoteServeSetFolderGrants(device.device.id, folders: guestFolders.map(NativeRPCValue.string)) }
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [],
            operations: .init(create: { request, _ in Self.meta("started-1", chat: chat, cwd: request.cwd) }),
            sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        if let deliver { await host.setStartTextDelivery { job in await deliver.take(job) } }
        if let defaultFolder { await host.setDefaultStartFolder { defaultFolder } }
        let kept = try await before?(host, trust) ?? nil
        try await host.start()
        var link = Link(host: host, trust: trust, directory: directory)
        link.kept = kept
        let capture = link.capture
        link.connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        try await link.send("hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array(claims.map(NativeRPCValue.string)))])
        return link
    }

    // MARK: Shapes

    @Test("text is an optional first message on create and chats.new; an unusable one is refused") func textParses() throws {
        func parse(_ json: String) -> BackendRemoteClientMessage? {
            if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
            return nil
        }
        let create = try #require(parse(#"{"t":"create","rid":"r-1","cwd":"/Projects/Phone","provider":"claude","text":"run the tests\nplease"}"#))
        #expect(create["text"].string == "run the tests\nplease" && create["rid"].string == "r-1")
        let new = try #require(parse(#"{"t":"chats.new","rid":"chat-new-1-ab12cd","cwd":"/Projects/Phone","provider":"claude","text":"hello"}"#))
        #expect(new["text"].string == "hello")
        #expect(try #require(parse(#"{"t":"create","cwd":"/Projects/Phone","text":"   "}"#))["text"] == .missing, "blank: nothing to deliver")
        #expect(try #require(parse(#"{"t":"create","cwd":"/Projects/Phone"}"#))["text"] == .missing)
        #expect(parse(#"{"t":"create","cwd":"/Projects/Phone","text":"a\u001b[2Jb"}"#) == nil, "no terminal control bytes")
        #expect(parse(#"{"t":"chats.new","rid":"r","cwd":"/P","provider":"claude","text":7}"#) == nil)
    }

    // MARK: An older phone: exactly as before

    @Test("an older phone's create is answered exactly as the installed build (43a62d07) answers it: no rid, no first message, nothing new")
    func olderPhoneUnchanged() async throws {
        let deliver = Deliveries(answer: true)
        let link = try await Self.link(claims: ["settings"], deliver: deliver)
        try await link.send("create", [.init("rid", .string("r-1")), .init("cwd", .string("/Projects/Phone")), .init("provider", .string("claude")),
                                       .init("text", .string("run the tests"))])
        let created = try await link.capture.waitFor("created")
        // Byte for byte what an older phone reads: the frame 43a62d07 builds (its `Outcome.message()`, field by field).
        let meta = Self.meta("started-1", chat: false)
        let before = NativeRPCValue.object([.init("t", .string("created")), .init("session", .object([
            .init("id", .string(meta.id)), .init("title", .string(meta.title)), .init("cwd", .string(meta.cwd)),
            .init("provider", .string(meta.provider)), .init("status", .string("idle")), .init("exitCode", .null),
            .init("lastActivityAt", .number(meta.createdAt))]))])
        #expect(created == (try BackendRemoteServeSessionCreate.Outcome.created(meta).message()).value)
        #expect(try created.encodedJSON() == before.encodedJSON(), "the same bytes as before")
        let welcome = try #require(await link.capture.of("welcome").first)
        let advertised = (welcome["capabilities"].elements ?? []).compactMap(\.string)
        #expect(!advertised.contains("start.text") && !advertised.contains("start.rid"))
        #expect(await deliver.jobs.isEmpty, "an older phone never sends text; one that did is not typed")
        #expect(await link.capture.of("start.text").isEmpty, "no frame type an iPhone cannot read")
        #expect(await link.capture.errors(rid: "r-1").isEmpty)
        #expect(await link.capture.of("sessions").allSatisfy { ($0["sessions"].elements ?? []).allSatisfy { $0["rid"] == .missing } })
        await link.close()
    }

    // MARK: The rid on the session

    @Test("a phone that claims start.rid finds its rid on created and on its session; no other device does")
    func ridOnCreatedAndSession() async throws {
        let link = try await Self.link(claims: ["start.rid"])
        let welcome = try await link.capture.waitFor("welcome")
        #expect((welcome["capabilities"].elements ?? []).compactMap(\.string).contains("start.rid"))
        try await link.send("create", [.init("rid", .string("r-7")), .init("cwd", .string("/Projects/Phone")), .init("provider", .string("claude"))])
        let created = try await link.capture.waitFor("created")
        // The phones read it on the session row (iOS `WireCodec` row decoder, Android `RemoteSession.rid`).
        #expect(created["session"]["rid"].string == "r-7" && created["session"]["id"].string == "started-1")
        #expect(created["rid"] == .missing && created["session"]["startRid"] == .missing, "one name only")
        let device = try #require(await link.trust.listDevices().first?.id)
        func context(_ id: String, claims: Set<String>) -> BackendRemoteHostContext {
            .init(connectionID: UUID(), deviceID: id, kind: .mine, address: "t", peerPublicKey: nil, claimedCapabilities: claims,
                  reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false))
        }
        #expect(await link.host.startRid("started-1", context: context(device, claims: ["start.rid"])) == "r-7", "the session list row's rid")
        #expect(await link.host.startRid("started-1", context: context("another-phone", claims: ["start.rid"])) == nil, "only the device that started it")
        #expect(await link.host.startRid("started-1", context: context(device, claims: [])) == nil, "never to a phone that did not claim it")
        await link.close()
    }

    // MARK: Start with a first message

    @Test("a start with text: delivered, then nothing more is said") func textDelivered() async throws {
        let deliver = Deliveries(answer: true)
        let link = try await Self.link(claims: ["start.text", "start.rid"], deliver: deliver)
        let welcome = try await link.capture.waitFor("welcome")
        #expect((welcome["capabilities"].elements ?? []).compactMap(\.string).contains("start.text"))
        try await link.send("create", [.init("rid", .string("page-start-r2")), .init("cwd", .string("/Projects/Phone")), .init("provider", .string("claude")),
                                       .init("text", .string("run the tests"))])
        let created = try await link.capture.waitFor("created")
        #expect(created["session"]["rid"].string == "page-start-r2")
        try await deliver.waitForJob()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.capture.errors(rid: "page-start-r2").isEmpty, "sent: nothing")
        #expect(await link.capture.of("start.text").isEmpty)
        #expect(await deliver.jobs == [.init(sessionID: "started-1", provider: "claude", chat: false, text: "run the tests")])
        await link.close()
    }

    @Test("not sent: one error with the start's rid, code unavailable, the text never sent back") func textNotSent() async throws {
        let deliver = Deliveries(answer: false)
        let link = try await Self.link(claims: ["start.text"], deliver: deliver)
        try await link.send("create", [.init("rid", .string("page-start-r3")), .init("cwd", .string("/Projects/Phone")), .init("provider", .string("claude")),
                                       .init("text", .string("run the tests"))])
        let created = try await link.capture.waitFor("created")
        #expect(created["session"]["rid"] == .missing, "start.rid not claimed: created as before")
        let answer = try await link.capture.waitForError(rid: "page-start-r3")
        // What iOS `HostLink` (.error → textBack by rid) and Android `applyError` read; the phone puts back its own copy.
        #expect(answer["code"].string == "unavailable" && answer["message"].string == BackendPhoneStartText.notSent)
        #expect(answer["text"] == .missing && answer["id"] == .missing && answer["sent"] == .missing)
        #expect(await link.capture.of("start.text").isEmpty)
        #expect(try BackendPhoneStartText.answer(rid: "x", sent: true) == nil && BackendPhoneStartText.answer(rid: nil, sent: false) == nil)
        await link.close()
    }

    @Test("chats.new with text: the chat's first message, through the same start checks") func chatTextDelivered() async throws {
        let deliver = Deliveries(answer: true)
        let link = try await Self.link(claims: ["start.text", "start.rid", "chats"], deliver: deliver) { host, trust in
            let bridge = BackendPhoneChats(endpoint: host, trust: trust, engine: .init(
                read: { _ in .object([.init("conversationId", .string("c")), .init("events", .array([]))]) }, isChat: { _ in true },
                say: { _, _ in }, interrupt: { _ in }, answer: { _, _, _ in },
                start: { request in Self.meta("chat-1", chat: true, cwd: request.cwd) }))
            try await host.register(await bridge.feature())
            return bridge
        }
        try await link.send("chats.new", [.init("rid", .string("page-start-c1")), .init("cwd", .string("/Projects/Phone")),
                                          .init("provider", .string("claude")), .init("text", .string("hello"))])
        let created = try await link.capture.waitFor("created")
        #expect(created["session"]["rid"].string == "page-start-c1" && created["session"]["chat"].bool == true)
        try await deliver.waitForJob()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.capture.errors(rid: "page-start-c1").isEmpty)
        let job = await deliver.jobs.first
        #expect(job?.chat == true && job?.text == "hello")
        await link.close()
    }

    @Test("a first message begins only after its start's created went out: a chat's not-sent never overtakes created")
    func notSentNeverOvertakesCreated() async throws {
        let deliver = Deliveries(answer: false)
        let link = try await Self.link(claims: ["start.text", "chats"], deliver: deliver) { host, trust in
            let bridge = BackendPhoneChats(endpoint: host, trust: trust, engine: .init(
                read: { _ in .object([.init("conversationId", .string("c")), .init("events", .array([]))]) }, isChat: { _ in true },
                say: { _, _ in }, interrupt: { _ in }, answer: { _, _, _ in },
                start: { request in Self.meta("chat-2", chat: true, cwd: request.cwd) }))
            try await host.register(await bridge.feature())
            return bridge
        }
        try await link.send("chats.new", [.init("rid", .string("page-start-c2")), .init("cwd", .string("/Projects/Phone")),
                                          .init("provider", .string("claude")), .init("text", .string("hello"))])
        _ = try await link.capture.waitForError(rid: "page-start-c2")
        let frames = await link.capture.frames
        let order = frames.compactMap { frame -> String? in
            frame["t"].string == "created" ? "created" : frame["t"].string == "error" && frame["rid"].string == "page-start-c2" ? "not sent" : nil
        }
        #expect(order == ["created", "not sent"])
        // Held on the host until then: nothing begins before `startDeliveries`.
        let device = try #require(await link.trust.listDevices().first?.id)
        await link.host.phoneStarted(connection: link.connection, deviceID: device, meta: Self.meta("held-1", chat: false), rid: "r-h", text: "later")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await deliver.jobs.count == 1, "only the chat's, the held one has not begun")
        #expect(await link.host.startDeliveries(link.connection) == 1)
        await link.close()
    }

    @Test("the Tasks resend waits a quarter second after the LAST change, never more than two seconds after the first")
    func tasksResendWaitsForQuiet() {
        #expect(BackendRemoteHost.tasksPushDue(firstChange: 0, lastChange: 0) == 250)
        #expect(BackendRemoteHost.tasksPushDue(firstChange: 0, lastChange: 1000) == 1250, "each change moves it on")
        #expect(BackendRemoteHost.tasksPushDue(firstChange: 0, lastChange: 1900) == 2000, "the two-second ceiling")
    }

    // MARK: Tasks changed (phones ask 4)

    @Test("a task change sends a phone the Tasks list it read, again, unasked (no rid); a phone that never read Tasks gets nothing")
    func tasksChangedResendsReadLists() async throws {
        let link = try await Self.link(claims: ["panels"]) { host, _ in
            // The panels feature as the real registry answers: the rows for that path, the rid only when one was sent.
            try await host.register(.init(capability: "panels", messageTypes: ["panel.read", "panel.act"], policy: .grantedDevice) { message, _ in
                var fields: [NativeRPCValue.Field] = [.init("panel", message["panel"]), .init("path", message["path"]),
                    .init("rows", .array([.object([.init("id", .string("t-1")), .init("title", .string("Ship it"))])]))]
                if let rid = message["rid"].string { fields.append(.init("rid", .string(rid))) }
                return [try .init(.panelRows, fields: fields)]
            })
            return nil
        }
        _ = try await link.capture.waitFor("welcome")
        #expect(await link.host.pushTaskLists() == 0, "never read Tasks: nothing sent")
        try await link.send("panel.read", [.init("panel", .string("tasks")), .init("path", .string("/Projects/Phone")), .init("rid", .string("p-1"))])
        let asked = try await link.capture.waitFor("panel.rows")
        #expect(asked["rid"].string == "p-1")
        #expect(await link.host.pushTaskLists() == 1)
        let pushed = try #require(await link.capture.of("panel.rows").last)
        #expect(pushed["rid"] == .missing && pushed["panel"].string == "tasks" && pushed["path"].string == "/Projects/Phone")
        #expect(await link.capture.of("panel.rows").count == 2)
        await link.close()
    }

    @Test("a state change sends a phone the Agents list it read, again, with the new state; an agent's own page is not resent")
    func agentsChangedResendsReadLists() async throws {
        actor State { var value = "Idle"; func set(_ text: String) { value = text } }
        let state = State()
        let link = try await Self.link(claims: ["panels"]) { host, _ in
            try await host.register(.init(capability: "panels", messageTypes: ["panel.read", "panel.act"], policy: .grantedDevice) { message, _ in
                var fields: [NativeRPCValue.Field] = [.init("panel", message["panel"]), .init("path", .string("")),
                    .init("rows", .array([.object([.init("id", .string("session:s1")), .init("title", .string("Deck Dev session")),
                                                    .init("value", .string(await state.value))])]))]
                if let scope = message["scope"].string { fields.append(.init("view", .string(scope))) }
                if let rid = message["rid"].string { fields.append(.init("rid", .string(rid))) }
                return [try .init(.panelRows, fields: fields)]
            })
            return nil
        }
        _ = try await link.capture.waitFor("welcome")
        #expect(await link.host.pushAgentLists() == 0, "never read Agents: nothing sent")
        try await link.send("panel.read", [.init("panel", .string("agents")), .init("rid", .string("a-1"))])
        try await link.send("panel.read", [.init("panel", .string("agents")), .init("scope", .string("agent:builder")), .init("rid", .string("a-2"))])
        var tries = 0
        while await link.capture.of("panel.rows").count < 2, tries < 250 { tries += 1; try await Task.sleep(for: .milliseconds(20)) }
        #expect(await link.capture.of("panel.rows").first?["rows"].elements?.first?["value"].string == "Idle")
        await state.set("Working")
        #expect(await link.host.pushAgentLists() == 1, "the list only, not the agent's page")
        let pushed = try #require(await link.capture.of("panel.rows").last)
        #expect(pushed["rid"] == .missing && pushed["panel"].string == "agents" && pushed["view"] == .missing)
        #expect(pushed["rows"].elements?.first?["value"].string == "Working", "the project page's card: the state the session lists show")
        await link.close()
    }

    // MARK: 14 Nov phone link: unasked lists never crowd the link

    /// The reproduction (Mac log 14 Nov 16:20-16:29Z: the iPhone's link over TURN ended every 25 s while a session was
    /// busy): every hook step and state change sent the whole Agents list again, the same list each time, on the one
    /// ordered channel the phone's pong and the terminal's echo ride. Before the fix: 50 identical lists; after: one.
    @Test("fifty state changes that leave the Agents list as it was send it once, not fifty times")
    func unchangedAgentListIsNotSentAgain() async throws {
        let link = try await Self.link(claims: ["panels"]) { host, _ in
            try await host.register(.init(capability: "panels", messageTypes: ["panel.read", "panel.act"], policy: .grantedDevice) { message, _ in
                var fields: [NativeRPCValue.Field] = [.init("panel", message["panel"]), .init("path", .string("")),
                    .init("rows", .array([.object([.init("id", .string("session:s1")), .init("value", .string("Working"))])]))]
                if let rid = message["rid"].string { fields.append(.init("rid", .string(rid))) }
                return [try .init(.panelRows, fields: fields)]
            })
            return nil
        }
        _ = try await link.capture.waitFor("welcome")
        try await link.send("panel.read", [.init("panel", .string("agents")), .init("rid", .string("a-1"))])
        _ = try await link.capture.waitFor("panel.rows")
        var sent = 0
        for _ in 0..<50 { sent += await link.host.pushAgentLists() }
        #expect(sent == 1, "the same list went \(sent) times")
        #expect(await link.capture.of("panel.rows").count == 2, "the asked answer and one unasked copy")
        // A list thrown away with a link (BackendRemoteLinkOutbox.stop → listsLost) does not count as delivered.
        await link.host.forgetPushedLists(link.connection)
        #expect(await link.host.pushAgentLists() == 1, "the same list goes again after it was lost")
        await link.close()
    }

    @Test("an unasked list waits for a link that is still opening, settling or backed up, and goes to a plain socket")
    func unaskedListWaitsForASettledLink() async throws {
        final class Fake: BackendLinkConnection, @unchecked Sendable {
            var waiting: UInt64 = 0
            func offer() async throws -> String { "" }
            func accept(answer: String) async throws {}
            func add(candidate: String, mid: String?, index: Int32) {}
            func send(_ data: Data, lane: BackendLinkLane) -> Bool { true }
            func close() {}
            func queued(_ lane: BackendLinkLane) -> UInt64 { lane == .control ? waiting : 0 }
        }
        let fake = Fake()
        let path = BackendRemoteLinkPath(relay: { _ in })
        path.set(.link(clientOnly: true))
        var state = BackendRemoteLinkState(path: path)
        #expect(BackendRemoteHost.pushMayGo(link: state, now: 10_000), "no link at all: a plain socket takes it")
        state.token = UUID(); state.connection = fake
        #expect(!BackendRemoteHost.pushMayGo(link: state, now: 10_000), "the link is still opening")
        path.attach(fake, failure: nil)
        try await path.write(BackendRemoteLinkPath.movedText)
        state.open = true; state.openedAt = 9_000
        #expect(!BackendRemoteHost.pushMayGo(link: state, now: 10_000), "opened a second ago: still taking its opening answers")
        #expect(BackendRemoteHost.pushMayGo(link: state, now: 9_000 + BackendRemoteHost.pushSettleMs), "settled and empty")
        fake.waiting = BackendRemoteHost.pushMostQueued + 1
        #expect(!BackendRemoteHost.pushMayGo(link: state, now: 20_000), "the phone is still taking earlier frames")
    }

    // MARK: The default folder

    @Test("the Mac's default folder is listed last for the person's own phone and startable") func defaultFolderListed() async throws {
        let independent = "/Users/someone/Terminal Deck/Independent"
        let link = try await Self.link(claims: [], defaultFolder: independent)
        let welcome = try await link.capture.waitFor("welcome")
        let folders = (welcome["folders"].elements ?? []).compactMap(\.string)
        #expect(folders.last == independent && folders.first != independent, "the first folder an older phone falls back to is unchanged")
        try await link.send("create", [.init("cwd", .string(independent)), .init("provider", .string("claude"))])
        let created = try await link.capture.waitFor("created")
        #expect(created["session"]["cwd"].string == independent)
        await link.close()
    }

    @Test("a guest is not given the default folder and cannot start there; its own folder still works") func defaultFolderNotForGuests() async throws {
        let independent = "/Users/someone/Terminal Deck/Independent"
        let link = try await Self.link(claims: [], defaultFolder: independent, guestFolders: ["/Projects/Shared"])
        let welcome = try await link.capture.waitFor("welcome")
        #expect((welcome["folders"].elements ?? []).compactMap(\.string) == ["/Projects/Shared"])
        try await link.send("create", [.init("cwd", .string(independent)), .init("provider", .string("claude"))])
        let refused = try await link.capture.waitFor("error")
        #expect(refused["code"].string == "unauthorized")
        #expect(await link.capture.of("created").isEmpty)
        // The plan itself: nothing newly startable for a guest.
        let plan = BackendRemoteServeSessionCreate.plan(.init(deviceID: "g", cwd: independent), offered: ["/Projects/Shared"], unrestricted: false)
        if case .success = plan { Issue.record("a guest started outside its folders") }
        await link.close()
    }
}

/// Owner's rule (14 Nov): an old paired device unused for 30 days is removed by itself; account devices never.
/// Counted only while the app ran with a sane clock; never what is connected (review 14 Nov 15:01, point 2).
@Suite("Old paired devices unused for 30 days")
struct StalePairedDevicesTests {
    static let day = 24 * 3600 * 1000.0, hour = 3600 * 1000.0
    static func device(_ id: String, lastSeen: Double?, revoked: Bool = false) -> BackendRemoteDevice {
        .init(id: id, name: "Phone \(id)", addedAt: 0, lastSeenAt: lastSeen, approved: true, revoked: revoked, fingerprint: nil)
    }
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var rows: [String] = []
        func add(_ line: String) { lock.withLock { rows.append(line) } }
        var all: [String] { lock.withLock { rows } }
    }
    /// The roster as the sweep sees it: the trust store's own rules (seen now saved; removal refused for a device seen
    /// after the cut-off), and a connection list that may change between two reads.
    private actor Roster {
        var rows: [String: BackendRemoteDevice] = [:]
        var online: [Set<String>]
        var removed: [String] = []
        init(_ devices: [BackendRemoteDevice], online: [Set<String>] = [[]]) {
            for device in devices { rows[device.id] = device }
            self.online = online
        }
        func list() -> [BackendRemoteDevice] { rows.values.sorted { $0.id < $1.id } }
        /// Each read takes the next list; the last one stays.
        func connected() -> Set<String> { online.count > 1 ? online.removeFirst() : online[0] }
        func setOnline(_ ids: Set<String>) { online = [ids] }
        func noteSeen(_ ids: Set<String>, _ now: Double) {
            for id in ids { if let d = rows[id] { rows[id] = .init(id: d.id, name: d.name, addedAt: d.addedAt, lastSeenAt: now, approved: true, revoked: d.revoked, fingerprint: nil) } }
        }
        func seen(_ id: String, at: Double) { noteSeen([id], at) }
        func revoke(_ id: String, _ quietBefore: Double) -> Bool {
            guard let d = rows[id], !d.revoked else { return false }
            if let seen = d.lastSeenAt, seen > quietBefore { return false }
            rows[id] = .init(id: d.id, name: d.name, addedAt: d.addedAt, lastSeenAt: d.lastSeenAt, approved: true, revoked: true, fingerprint: nil)
            removed.append(id); return true
        }
    }
    private static func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StaleDevices-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    /// A mark as earlier checks of this app left it: `running` counted, the last check, each device's running time when seen.
    private static func mark(_ directory: URL, running: Double, lastCheckAt: Double, seen: [String: Double]) throws {
        try BackendRemoteStaleDevices.write(.init(running: running, lastCheckAt: lastCheckAt, seen: seen),
                                            directory.appendingPathComponent(BackendRemoteStaleDevices.markFile))
    }
    private static func running(_ directory: URL) -> Double? {
        BackendRemoteStaleDevices.read(directory.appendingPathComponent(BackendRemoteStaleDevices.markFile))?.running
    }
    @discardableResult
    private static func sweep(_ directory: URL, _ roster: Roster, at now: Double, lines: Lines = Lines()) async -> [String] {
        await BackendRemoteStaleDevices.sweep(directory: directory, now: now, devices: { await roster.list() },
            connected: { await roster.connected() }, noteSeen: { ids, at in await roster.noteSeen(ids, at) },
            revoke: { id, quietBefore in await roster.revoke(id, quietBefore) }, report: { lines.add($0) })
    }

    @Test("30 running days since seen: due; 29: not; connected now: not; revoked: left alone; never seen: from the start") func due() {
        let running = 40 * Self.day
        let rows = [Self.device("old", lastSeen: nil), Self.device("recent", lastSeen: nil),
                    Self.device("online", lastSeen: nil), Self.device("gone", lastSeen: nil, revoked: true), Self.device("never", lastSeen: nil)]
        let seen = ["old": 9 * Self.day, "recent": 11 * Self.day, "online": 0, "gone": 0]
        #expect(BackendRemoteStaleDevices.due(rows, connected: ["online"], running: running, seen: seen).map(\.id) == ["old", "never"])
        #expect(BackendRemoteStaleDevices.due(rows, connected: [], running: 29 * Self.day, seen: [:]).isEmpty)
    }

    @Test("the first check removes nothing; a sane next check removes through Remove, one log line each") func sweep() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = 100 * Self.day
        let roster = Roster([Self.device("old", lastSeen: 0), Self.device("recent", lastSeen: 0)])
        #expect(await Self.sweep(directory, roster, at: now).isEmpty, "no mark yet: nothing, the count starts now")
        // As if the app had been running and checking for 40 days.
        try Self.mark(directory, running: 40 * Self.day, lastCheckAt: now - 6 * Self.hour, seen: ["old": 0, "recent": 11 * Self.day])
        let lines = Lines()
        #expect(await Self.sweep(directory, roster, at: now, lines: lines) == ["old"])
        #expect(await roster.removed == ["old"])
        #expect(lines.all == [BackendRemoteStaleDevices.line("Phone old")], "one plain line, by its name")
    }

    @Test("a Mac or app off for a month removes nothing at its next check; the days off are skipped, running days add up") func macOffForAMonth() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let lastCheck = 100 * Self.day, back = lastCheck + 31 * Self.day
        try Self.mark(directory, running: 20 * Self.day, lastCheckAt: lastCheck, seen: ["phone": 0])
        let roster = Roster([Self.device("phone", lastSeen: 0)])
        #expect(await Self.sweep(directory, roster, at: back).isEmpty)
        #expect(Self.running(directory) == 20 * Self.day, "the month off counted nothing")
        // Then running every day, checked every six hours: due after the 10 running days still missing, not before.
        var removedAt: Double?
        for step in 1...(12 * 4) {
            let at = back + Double(step) * 6 * Self.hour
            if !(await Self.sweep(directory, roster, at: at)).isEmpty { removedAt = at; break }
        }
        let after = try #require(removedAt) - back
        #expect(after >= 10 * Self.day && after <= 10 * Self.day + 6 * Self.hour)
    }

    @Test("off every weekend: a dead device goes after about 30 running days; one seen every week never") func offEveryWeekend() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let roster = Roster([Self.device("dead", lastSeen: nil), Self.device("weekly", lastSeen: nil)])
        var removedWeek: Int?
        for week in 0..<12 {
            for weekday in 0..<5 { // Monday to Friday; off from Friday night to Monday morning
                let day = Double(week * 7 + weekday) * Self.day
                if weekday == 2 { await roster.seen("weekly", at: day + 10 * Self.hour) } // connects every Wednesday
                for hour in [8.5, 14.5, 20.5] {
                    let removed = await Self.sweep(directory, roster, at: day + hour * Self.hour)
                    #expect(!removed.contains("weekly"), "a device seen every week is never removed")
                    if removed.contains("dead"), removedWeek == nil { removedWeek = week }
                }
            }
        }
        // About 4.5 running days a week (each Monday's 60-hour gap counts nothing): due in week 6 or 7, never in the first.
        let week = try #require(removedWeek, "a dead device is removed eventually")
        #expect(week >= 6 && week <= 7)
        #expect(await roster.removed == ["dead"])
    }

    @Test("asleep or quit every night: a dead device goes after about 30 days; one connected every day never") func asleepEveryNight() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let roster = Roster([Self.device("dead", lastSeen: nil), Self.device("daily", lastSeen: nil)])
        var removedDay: Int?
        for day in 0..<40 { // the app runs 08:00 to 18:00: checks half an hour after launch, then six hours later
            for (hour, online) in [(8.5, Set<String>()), (14.5, Set(["daily"]))] {
                await roster.setOnline(online)
                let removed = await Self.sweep(directory, roster, at: Double(day) * Self.day + hour * Self.hour)
                #expect(!removed.contains("daily"))
                if removed.contains("dead"), removedDay == nil { removedDay = day }
            }
        }
        let day = try #require(removedDay, "a dead device is removed eventually")
        #expect(day >= 29 && day <= 31)
    }

    @Test("a clock a year ahead (or gone backwards) removes nothing and uses up nothing: one gap adds at most 24 hours") func clockJumps() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = 400 * Self.day
        let roster = Roster([Self.device("phone", lastSeen: 0)])
        try Self.mark(directory, running: 25 * Self.day, lastCheckAt: now - 6 * Self.hour, seen: ["phone": 0])
        #expect(await Self.sweep(directory, roster, at: now + 365 * Self.day).isEmpty, "a year ahead")
        #expect(Self.running(directory) == 25 * Self.day, "the jump counted nothing")
        #expect(await Self.sweep(directory, roster, at: now + 365 * Self.day + 6 * Self.hour).isEmpty, "and the next check only six hours")
        try Self.mark(directory, running: 25 * Self.day, lastCheckAt: now, seen: ["phone": 0])
        #expect(await Self.sweep(directory, roster, at: now - 365 * Self.day).isEmpty, "a year behind")
        #expect(Self.running(directory) == 25 * Self.day)
        // A step of a day counts in full; a day and a minute counts nothing.
        try Self.mark(directory, running: 0, lastCheckAt: now, seen: [:])
        _ = await Self.sweep(directory, roster, at: now + Self.day)
        #expect(Self.running(directory) == Self.day)
        _ = await Self.sweep(directory, roster, at: now + 2 * Self.day + 60_000)
        #expect(Self.running(directory) == Self.day)
        #expect(await roster.removed.isEmpty)
    }

    @Test("a device connected for weeks is kept across an app restart") func connectedForWeeksKept() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = 100 * Self.day
        try Self.mark(directory, running: 40 * Self.day, lastCheckAt: now - 6 * Self.hour, seen: ["desk": 0, "old": 0])
        // Connected since 40 days ago (its last verified connection), without a break; "old" not.
        let roster = Roster([Self.device("desk", lastSeen: 0), Self.device("old", lastSeen: 0)], online: [["desk"]])
        #expect(await Self.sweep(directory, roster, at: now) == ["old"], "connected: kept, and marked seen now")
        #expect(await roster.list().first { $0.id == "desk" }?.lastSeenAt == now)
        // The app restarts; the desk has not reconnected yet at the next check.
        let after = Roster(await roster.list(), online: [[]])
        #expect(await Self.sweep(directory, after, at: now + 6 * Self.hour).isEmpty)
        #expect(await after.removed.isEmpty)
    }

    @Test("a device connected at the removal instant is kept") func connectedAtRemovalKept() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = 100 * Self.day
        try Self.mark(directory, running: 40 * Self.day, lastCheckAt: now - 6 * Self.hour, seen: ["late": 0])
        // Not connected at the snapshot, connected when its removal runs.
        let late = Roster([Self.device("late", lastSeen: 0)], online: [[], ["late"]])
        #expect(await Self.sweep(directory, late, at: now).isEmpty)
        // Connected (and verified, so seen) between the connection read and the removal: the roster refuses it.
        try Self.mark(directory, running: 40 * Self.day, lastCheckAt: now - 6 * Self.hour, seen: ["racing": 0])
        let racing = Roster([Self.device("racing", lastSeen: 0)])
        await racing.seen("racing", at: now)
        let stale = [Self.device("racing", lastSeen: 0)]
        let removed = await BackendRemoteStaleDevices.sweep(directory: directory, now: now, devices: { stale },
            connected: { [] }, noteSeen: { _, _ in }, revoke: { id, quietBefore in await racing.revoke(id, quietBefore) }, report: { _ in })
        #expect(removed.isEmpty)
        #expect(await racing.removed.isEmpty)
    }

    @Test("the trust store saves seen-now and refuses a removal of a device seen after the cut-off") func trustStoreRules() async throws {
        let directory = try Self.folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let id = try await trust.redeem(try await trust.createPairingOffer().token, name: "Desk phone", address: "test", publicKey: nil).device.id
        try await trust.approve(id, kind: .mine)
        let at = 5_000_000_000_000.0
        try await trust.noteSeen([id], at: at)
        await trust.close()
        let reopened = BackendRemoteTrustStore(directory: directory)
        try await reopened.open()
        #expect(await reopened.listDevices().first?.lastSeenAt == at, "saved: it survives an app restart")
        #expect(try await reopened.revoke(id, quietBefore: at - 1) == false, "seen after the cut-off: kept")
        #expect(try await reopened.revoke(id, quietBefore: at + 1) == true)
        await reopened.close()
    }

    @Test("an account device is never on the pairing roster the rule reads") func accountDeviceUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StaleDevicesAccount-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        _ = await trust.admitReachDevice(.init(deviceId: "acct-1", label: "His phone", platform: "ios",
                                               reachKey: Data(repeating: 1, count: 32), firstTime: false))
        #expect(await trust.listDevices().isEmpty, "the sweep reads listDevices(): account devices are not there")
        #expect(await trust.isReachDevice("reach-acct-1"))
        await trust.close()
    }
}

/// Point 5 (14 Nov web walk): the Agents panel on a phone or browser counts working agents as the side panel does and
/// never prints the Mac owner's own sentences. The directory tool is faked at the panel port.
@Suite("Agents panel on a device")
struct DeviceAgentsPanelTests {
    private static let ownerOnly = ["Live activity is outside this caller's access.", "Connected-machine activity is outside this caller's access."]
    private static func directory(live: Bool, notices: [String]) -> NativeRPCValue {
        func agent(_ id: String, _ state: String?) -> NativeRPCValue {
            .object([.init("id", .string(id)), .init("kind", .string("profile")), .init("name", .string(id.capitalized)),
                     .init("statusLabel", .string(state == "working" ? "Working" : state == "waiting" ? "Waiting" : "Ready")),
                     .init("live", live ? state.map(NativeRPCValue.string) ?? .null : .null)])
        }
        return .object([.init("agents", .array([agent("builder", "working"), agent("critic", "waiting"), agent("idle", nil)])),
                        .init("groups", .array([.object([.init("title", .string("Every project")), .init("agents", .array(["builder", "critic", "idle"].map(NativeRPCValue.string)))])])),
                        .init("notices", .array(notices.map(NativeRPCValue.string)))])
    }
    private static func read(level: BackendINT2PhoneAccessLevel, _ answer: NativeRPCValue) async throws -> NativeRPCValue {
        let port = BackendIOS2PanelPort(call: { _, _, _, _, _ in answer }, level: { _, _ in level }, device: { _, _, _ in "phone-1" })
        return try await BackendIOS2PhonePanels.agents(port: port).read(.init(path: "", scope: nil, query: nil),
                                                                        NativeRPCContext(caller: .pairedDevice, ownerID: "phone-1"))
    }

    @Test("Full control: working and waiting marks as the side panel counts them; no owner-only note") func fullControl() async throws {
        // What the directory answers a Full-control device now (the live picture of this Mac; no owner notices).
        let value = try await Self.read(level: .full, Self.directory(live: true, notices: []))
        let statuses = (value["rows"].elements ?? []).map { $0["status"].string }
        #expect(statuses == ["ok", "warn", nil], "1 working, 1 waiting, as the side panel")
        #expect(value["note"] == .missing)
    }

    @Test("this Mac's live picture: his own device at Full or with no level set; never a guest, even at Full") func livePictureWho() {
        #expect(BackendIOS2PhonePanels.seesThisMacsLiveAgents(kind: .guest, level: .full) == false, "a guest raised to Full: as before")
        #expect(BackendIOS2PhonePanels.seesThisMacsLiveAgents(kind: .guest, level: nil) == false)
        #expect(BackendIOS2PhonePanels.seesThisMacsLiveAgents(kind: .mine, level: nil) == true, "his own device, no level set: Full by the start rule")
        #expect(BackendIOS2PhonePanels.seesThisMacsLiveAgents(kind: .mine, level: .full) == true)
        #expect(BackendIOS2PhonePanels.seesThisMacsLiveAgents(kind: .mine, level: .work) == false, "a level he lowered stays")
        // The same answer as the start rule's own Full control (login and mode choices).
        for level in [nil, BackendINT2PhoneAccessLevel.full, .work, .look] {
            #expect(BackendIOS2PhonePanels.seesThisMacsLiveAgents(kind: .mine, level: level) == BackendPhoneChats.fullControl(level: level, kind: .mine))
        }
    }

    @Test("lower access: rows as today; the owner's sentences never reach the device") func lowerLevel() async throws {
        let value = try await Self.read(level: .work, Self.directory(live: false, notices: Self.ownerOnly))
        #expect((value["rows"].elements ?? []).allSatisfy { $0["status"] == .missing }, "no live marks, as today")
        #expect(value["note"] == .missing, "no owner-only sentence")
        // A sentence the person can act on stays.
        #expect(BackendIOS2PhonePanels.deviceNote([.string("Task agents are paused."), .string(Self.ownerOnly[0])]) == .string("Task agents are paused."))
    }
}
