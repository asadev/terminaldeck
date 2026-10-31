import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// iOS batch 1, step 3: agent chats on a phone (`chats`), Hoot's Switch account (`hoot.account.*`) and the task
/// Comment action's wire. The adapter runs against a recording engine and host; parsing, access levels, frame
/// validation and the Hoot account projection are the real code.
final class PHONEChatsTests: XCTestCase {
    // MARK: Shapes

    private func parse(_ json: String) -> BackendRemoteClientMessage? {
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
        return nil
    }

    func testChatFramesParse() throws {
        let watch = try XCTUnwrap(parse(#"{"t":"chats.watch","id":"chat-1"}"#))
        XCTAssertTrue(watch["id"].string == "chat-1")
        let say = try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"Run the tests"}"#))
        XCTAssertTrue(say["text"].string == "Run the tests")
        let answer = try XCTUnwrap(parse(#"{"t":"chats.answer","id":"chat-1","request":"toolu_01:a","approved":true}"#))
        XCTAssertTrue(answer["request"].string == "toolu_01:a")
        XCTAssertTrue(answer["approved"].bool == true)
        let new = try XCTUnwrap(parse(#"{"t":"chats.new","cwd":"/Projects/Phone","provider":"codex"}"#))
        XCTAssertTrue(new["provider"].string == "codex")
        XCTAssertTrue(new["cwd"].string == "/Projects/Phone")
        let started = try XCTUnwrap(parse(#"{"t":"chats.new","rid":"chat-new-1-ab12cd","cwd":"/Projects/Phone","provider":"codex"}"#))
        XCTAssertTrue(started["rid"].string == "chat-new-1-ab12cd", "kept, so an error answering the start carries it")
        // The host stamps the request's rid on an error it sends while answering that request (#58).
        let stamped = BackendRemoteHost.$answering.withValue(.init(connection: Self.connection, rid: "chat-new-1-ab12cd")) {
            BackendRemoteHost.stamped(try! .error(code: "unavailable", message: "No folder"), to: Self.connection)
        }
        XCTAssertTrue(stamped.value["rid"].string == "chat-new-1-ab12cd")
        let read = try XCTUnwrap(parse(#"{"t":"hoot.account.read","rid":"r1"}"#))
        XCTAssertTrue(read["rid"].string == "r1")
        let switching = try XCTUnwrap(parse(#"{"t":"hoot.account.switch","rid":"r2","accountId":"claude-work"}"#))
        XCTAssertTrue(switching["accountId"].string == "claude-work")
    }

    func testUnusableChatFramesAreRefused() {
        XCTAssertTrue(parse(#"{"t":"chats.new","cwd":"/Projects/Phone","provider":"shell"}"#) == nil, "only chat agents")
        XCTAssertTrue(parse(#"{"t":"chats.new","rid":"../x","cwd":"/Projects/Phone","provider":"codex"}"#) == nil, "an unusable rid")
        XCTAssertTrue(parse(#"{"t":"chats.say","id":"chat-1","text":""}"#) == nil, "no empty message")
        XCTAssertTrue(parse(#"{"t":"chats.say","id":"chat-1","text":"two\nlines"}"#) == nil, "one utterance, like Hoot")
        XCTAssertTrue(parse(#"{"t":"chats.answer","id":"chat-1","request":"r"}"#) == nil, "a decision is required")
        XCTAssertTrue(parse(#"{"t":"hoot.account.switch","rid":"r","accountId":"../x"}"#) == nil)
    }

    // MARK: Access

    func testAccessLevelsGateChatsLikeSessions() {
        let look = BackendINT2PhoneAccessLevel.look, hoot = BackendINT2PhoneAccessLevel.hoot
        let work = BackendINT2PhoneAccessLevel.work, full = BackendINT2PhoneAccessLevel.full
        XCTAssertTrue(look.permits("chats.watch") && !look.permits("chats.say") && !look.permits("chats.new"))
        XCTAssertTrue(work.permits("chats.say") && work.permits("chats.new") && work.permits("chats.interrupt"))
        XCTAssertTrue(!work.permits("chats.answer"), "approving is Full control")
        XCTAssertTrue(full.permits("chats.answer"))
        XCTAssertTrue(!hoot.permits("chats.watch"), "Hoot only never reaches other chats")
        XCTAssertTrue(hoot.permits("hoot.account.read") && !hoot.permits("hoot.account.switch"))
        XCTAssertTrue(!work.permits("hoot.account.switch") && full.permits("hoot.account.switch"))
    }

    // MARK: The adapter

    private static let connection = UUID()

    private static func context(_ connection: UUID = UUID(), folders: [String] = ["/Projects/Phone"]) -> BackendRemoteHostContext {
        .init(connectionID: connection, deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil, claimedCapabilities: [],
              reach: .init(kind: .mine, unrestricted: false, folders: folders, accounts: nil, drivesWindows: false), phoneAccess: .work)
    }

    private static func event(_ sequence: Int, _ kind: HootChatKind, conversation: String = "conv-1", text: String = "Hi") -> NativeRPCValue {
        HootChatEvent(conversationID: conversation, turnID: "turn-1", sequence: sequence, provider: .codex,
                      record: .text(kind, id: "m\(sequence)", text), at: 1).wireValue
    }

    func testWatchingSendsTheWholeConversationAndKeepsTheWatcher() async throws {
        let calls = Recorder()
        let chats = Self.adapter(calls, snapshot: .object([.init("conversationId", .string("conv-1")), .init("busy", .bool(true)),
            .init("events", .array([Self.event(1, .user), Self.event(2, .message), Self.event(3, .message, conversation: "older")]))]))
        let context = Self.context()
        let frames = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.watch","id":"chat-1"}"#)), context: context)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertTrue(frame.kind == .chatsEvents)
        XCTAssertTrue(frame.value["id"].string == "chat-1")
        XCTAssertTrue(frame.value["reset"].bool == true && frame.value["busy"].bool == true)
        XCTAssertTrue(frame.value["events"].elements?.count == 2, "only the current conversation's events")
        let seen1 = await chats.watched(by: context.connectionID)
        XCTAssertTrue(seen1 == ["chat-1"])
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.unwatch","id":"chat-1"}"#)), context: context)
        let seen2 = await chats.watched(by: context.connectionID)
        XCTAssertTrue(seen2.isEmpty)
    }

    func testSayStopAndAnswerReachTheEngine() async throws {
        let calls = Recorder()
        let chats = Self.adapter(calls)
        let context = Self.context()
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"Run the tests"}"#)), context: context)
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.interrupt","id":"chat-1"}"#)), context: context)
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.answer","id":"chat-1","request":"req-9","approved":false}"#)), context: context)
        let seen3 = await calls.log
        XCTAssertTrue(seen3 == ["say chat-1 Run the tests", "interrupt chat-1", "answer chat-1 req-9 false"])
    }

    func testAChatThatIsGoneIsRefused() async throws {
        let calls = Recorder()
        let chats = Self.adapter(calls, isChat: false)
        let frames = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"Hello"}"#)), context: Self.context())
        XCTAssertTrue(frames.first?.kind == .error)
        XCTAssertTrue(frames.first?.value["code"].string == "unknown-session")
        let seen4 = await calls.log
        XCTAssertTrue(seen4.isEmpty)
    }

    func testANewChatStartsOnlyInAnOfferedFolder() async throws {
        let calls = Recorder()
        let chats = Self.adapter(calls)
        let refused = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.new","cwd":"/Elsewhere","provider":"claude"}"#)), context: Self.context())
        XCTAssertTrue(refused.first?.kind == .error)
        let seen5 = await calls.log
        XCTAssertTrue(seen5.isEmpty, "nothing started outside the device's folders")
        let created = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.new","cwd":"/Projects/Phone","provider":"claude"}"#)), context: Self.context())
        XCTAssertTrue(created.first?.kind == .created)
        XCTAssertTrue(created.first?.value["session"]["provider"].string == "claude")
        // 27 Oct walk (c): the Mac's reply to a chat start says it is a chat; a terminal's never does.
        XCTAssertTrue(created.first?.value["session"]["chat"].bool == true)
        let terminal = BackendSessionMeta(id: "t-1", input: .init(cwd: "/Projects/Phone", provider: "claude"),
                                          spawn: .init(provider: "claude", command: "/not-run", args: [], path: ""), now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(try BackendRemoteServeSessionCreate.Outcome.created(terminal).message().value["session"]["chat"] == .missing)
        let seen6 = await calls.log
        XCTAssertTrue(seen6 == ["start /Projects/Phone claude", "admit chat-new"])
    }

    func testAPublishedChangeReachesOnlyAWatcherThatStillSeesIt() async throws {
        let calls = Recorder()
        let chats = Self.adapter(calls, snapshot: .object([.init("conversationId", .string("conv-1")),
            .init("events", .array([Self.event(1, .message)]))]))
        let context = Self.context()
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.watch","id":"chat-1"}"#)), context: context)
        await chats.published("chat-1")
        try await calls.waitFor("send")
        let seen7 = await calls.log
        XCTAssertTrue(seen7.contains("send chats.events"))
        await calls.setSees(false)
        await chats.published("chat-1")
        try await calls.waitFor("sees")
        try await Task.sleep(for: .milliseconds(50))
        let seen8 = await chats.watched(by: context.connectionID)
        XCTAssertTrue(seen8.isEmpty, "a chat this device can no longer see stops")
    }

    // MARK: Hoot's Switch account

    func testHootAccountsAreOnlyItsOwnAIsInTheSessionAccountShape() throws {
        let ready = NativeRPCValue.object([.init("provider", .string("claude")), .init("profileId", .string("claude-work")),
            .init("accounts", .array([
                .object([.init("id", .string("claude-work")), .init("name", .string("Work")), .init("provider", .string("claude")), .init("signedIn", .bool(true))]),
                .object([.init("id", .string("system")), .init("name", .string("Default")), .init("provider", .string("claude")), .init("signedIn", .bool(false))]),
                .object([.init("id", .string("codex-1")), .init("name", .string("Codex")), .init("provider", .string("codex")), .init("signedIn", .bool(true))]),
            ]))])
        let state = try BackendINT2HootPhone.accountState(rid: "r1", ready: ready)
        XCTAssertTrue(state.kind == .accountState)
        XCTAssertTrue(state.value["id"].string == "hoot")
        XCTAssertTrue(state.value["accounts"].elements?.map { $0["id"].string ?? "" } == ["claude-work", "system"])
        XCTAssertTrue(state.value["current"]["id"].string == "claude-work")
        XCTAssertTrue(state.value["accounts"].elements?.last?["system"].bool == true)
        XCTAssertTrue(state.value["accounts"].elements?.first?["signIn"]["state"].string == "signed-in")
        let switched = try BackendINT2HootPhone.accountSwitched(rid: "r2", ok: true, message: "Done")
        XCTAssertTrue(switched.kind == .accountSwitched && switched.value["id"].string == "hoot")
    }

    func testAnOlderPhoneIsUnderstoodAndANewerOneIsNotDropped() throws {
        // The phone's older name for Hoot's frames reads as hoot.* (TestFlight 0.20.0 still sends copilot.*).
        let say = try XCTUnwrap(parse(#"{"t":"copilot.say","text":"Hello"}"#))
        XCTAssertTrue(say.type == "hoot.say" && say["text"].string == "Hello")
        XCTAssertTrue(parse(#"{"t":"copilot.hello"}"#)?.type == "hoot.hello")
        // A frame this Mac does not know is named in the refusal (the connection still closes, as the protocol says).
        guard case .refused(let unknown) = BackendRemoteProtocol.parseClientMessage(#"{"t":"chats.future","id":"c"}"#) else { return XCTFail("refused") }
        XCTAssertTrue(unknown.reason == "unknown message type: chats.future")
        guard case .refused(let garbled) = BackendRemoteProtocol.parseClientMessage(#"{"t":"<script>"}"#) else { return XCTFail("refused") }
        XCTAssertTrue(garbled.reason == "unknown message type", "a garbled name is not echoed")
    }

    func testAPhoneThatReconnectsTooOftenIsSlowedBeforeThePasswordCheck() {
        var throttle = BackendRemoteReconnectThrottle()
        let key = BackendRemoteReconnectThrottle.key(token: "dev-1.c2VjcmV0", address: "relay:abc")
        XCTAssertTrue(key == "device:dev-1", "counted by the device a credential names, read without any check")
        XCTAssertTrue(BackendRemoteReconnectThrottle.key(token: "123456", address: "relay:abc") == "address:relay:abc", "a pairing code by its address")
        for second in 0 ..< 10 { XCTAssertTrue(throttle.admit(key, now: Double(second)) == nil, "ten a minute are fine") }
        XCTAssertTrue(throttle.admit(key, now: 10) == 2, "the eleventh waits")
        XCTAssertTrue(throttle.admit(key, now: 11) == 4, "a try while waiting doubles the wait")
        XCTAssertTrue(throttle.admit(key, now: 12) == 8)
        XCTAssertTrue(throttle.admit("device:other", now: 12) == nil, "another device is not held up")
        XCTAssertTrue(throttle.admit(key, now: 200) == nil, "after a quiet minute it is let in again")
        XCTAssertTrue(BackendRemoteReconnectThrottle.slowDown(7.2) == "Slow down: this device is reconnecting too often. Try again in 8 seconds.")
    }

    func testOtherFolderWalksAnyFolderForTheOwnerAndOnlyGivenOnesForAGuest() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("phone-folders-\(UUID().uuidString)")
        for name in ["Alpha/Inner", "Beta", ".hidden"] {
            try FileManager.default.createDirectory(at: made.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: made) }
        let base = made.resolvingSymlinksInPath().path
        let folders = BackendPhoneFolders(home: base)
        let owner = BackendRemoteDeviceReach(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false)
        let home = try folders.browse(nil, reach: owner)
        XCTAssertTrue(home.kind == .folderEntries && home.value["path"].string == base, "the owner starts at home")
        XCTAssertTrue((home.value["entries"].elements ?? []).compactMap { $0["name"].string } == ["Alpha", "Beta"], "folders only, no hidden ones")
        let guest = BackendRemoteDeviceReach(kind: .guest, unrestricted: false, folders: [base + "/Alpha"], accounts: nil, drivesWindows: false)
        let inside = try folders.browse(base + "/Alpha", reach: guest)
        XCTAssertTrue((inside.value["entries"].elements ?? []).compactMap { $0["name"].string } == ["Inner"])
        XCTAssertTrue(inside.value["parent"] == .null, "a guest never walks above what it was given")
        XCTAssertThrowsError(try folders.browse(base, reach: guest))
        XCTAssertTrue(BackendPhoneFolders.messages == ["folders.browse"])
    }

    func testTheMacsLastFolderGoesOnlyToADeviceThatMayStartThere() async throws {
        func reach(_ unrestricted: Bool, _ folders: [String]) -> BackendRemoteHostContext {
            .init(connectionID: UUID(), deviceID: "phone-1", kind: unrestricted ? .mine : .guest, address: "relay", peerPublicKey: nil,
                  claimedCapabilities: [], reach: .init(kind: unrestricted ? .mine : .guest, unrestricted: unrestricted, folders: folders,
                                                        accounts: nil, drivesWindows: false), phoneAccess: .work)
        }
        func sent(_ last: String, to context: BackendRemoteHostContext) async throws -> String? {
            let frames = try await Self.adapter(Recorder(), defaultFolder: last)
                .handle(try XCTUnwrap(parse(#"{"t":"chats.choices","rid":"c1"}"#)), context: context)
            return try XCTUnwrap(frames.first).value["defaultFolder"].string
        }
        let owner = try await sent("/Users/asad/Secret", to: reach(true, []))
        XCTAssertTrue(owner == "/Users/asad/Secret", "the owner's own device starts where the Mac last did")
        let inside = try await sent("/Projects/Phone/App", to: reach(false, ["/Projects/Phone"]))
        XCTAssertTrue(inside == "/Projects/Phone/App", "a guest learns a folder inside what it was given")
        let outside = try await sent("/Users/asad/Secret", to: reach(false, ["/Projects/Phone"]))
        XCTAssertTrue(outside == nil, "a guest never learns a folder outside its grant")
        let lookalike = try await sent("/Projects/PhoneOther", to: reach(false, ["/Projects/Phone"]))
        XCTAssertTrue(lookalike == nil, "a sibling with the same prefix is outside")
    }

    func testAGuestWhoseGivenFolderIsALinkWalksItsOwnFolder() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("phone-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made.appendingPathComponent("Real/Inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: made.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: made.appendingPathComponent("Link"), withDestinationURL: made.appendingPathComponent("Real"))
        defer { try? FileManager.default.removeItem(at: made) }
        let folders = BackendPhoneFolders(home: made.path)
        let guest = BackendRemoteDeviceReach(kind: .guest, unrestricted: false, folders: [made.path + "/Link"], accounts: nil, drivesWindows: false)
        let own = try folders.browse(made.path + "/Link", reach: guest)
        XCTAssertTrue((own.value["entries"].elements ?? []).compactMap { $0["name"].string } == ["Inner"], "its own folder, through the link")
        XCTAssertTrue(own.value["parent"] == .null)
        XCTAssertThrowsError(try folders.browse(made.path + "/Other", reach: guest), "and nothing beside it")
        let owner = BackendRemoteDeviceReach(kind: .mine, unrestricted: true, folders: [made.path + "/Link"], accounts: nil, drivesWindows: false)
        let listing = try folders.browse(made.path, reach: owner)
        let shared = (listing.value["entries"].elements ?? []).filter { $0["granted"] == .bool(true) }.compactMap { $0["name"].string }
        XCTAssertTrue(shared.contains("Real"), "a given folder reached through a link is marked shared")
    }

    /// iOS batch 1, open item 9: a task's comments are listed on its own page (`scope: task:<id>`), oldest first,
    /// after the task's row and its actions; empty comments are left out and the page names its view.
    func testAPanelPacketsPathIsNotSentThroughTheFileAuthority() {
        XCTAssertFalse(BackendMachineRegistration.checksFilePath("panel.read"))
        XCTAssertFalse(BackendMachineRegistration.checksFilePath("panel.act"))
        XCTAssertTrue(BackendMachineRegistration.checksFilePath("upload.begin"))
        XCTAssertTrue(BackendMachineRegistration.checksFilePath("tunnel.open"))
    }

    /// 27 Oct (Sessions seat phone-fix.md item 4): a chat sent only its newest events, with no way back. Each page now
    /// says where it starts and how many there are, and `chats.older` reads the page before.
    func testAChatIsReadBackPageByPage() async throws {
        let events = (1...700).map { Self.event($0, .message, text: "Line \($0)") }
        let adapter = Self.adapter(Recorder(), snapshot: .object([.init("conversationId", .string("conv-1")), .init("events", .array(events))]))
        let watched = try await adapter.handle(try XCTUnwrap(parse(#"{"t":"chats.watch","id":"chat-1"}"#)), context: Self.context())
        let newest = try XCTUnwrap(watched.first)
        XCTAssertTrue(newest.value["reset"].bool == true && newest.value["older"] == .missing && newest.value["total"].number == 700)
        let first = Int(try XCTUnwrap(newest.value["first"].number)), shown = newest.value["events"].elements?.count ?? 0
        XCTAssertTrue(first > 0 && first + shown == 700, "the newest events that fit one frame, and where they start")
        let before = #"{"t":"chats.older","id":"chat-1","before":"# + String(first) + "}"
        let paged = try await adapter.handle(try XCTUnwrap(parse(before)), context: Self.context())
        let older = try XCTUnwrap(paged.first)
        XCTAssertTrue(older.value["reset"].bool == false && older.value["older"].bool == true)
        let earlier = Int(try XCTUnwrap(older.value["first"].number))
        XCTAssertTrue(earlier < first && earlier + (older.value["events"].elements?.count ?? 0) == first)
        XCTAssertTrue(older.value["events"].elements?.last?["sequence"].number == Double(first), "ends just before the page the phone has")
        XCTAssertTrue(BackendINT2PhoneAccessLevel.look.permits("chats.older"), "reading back is a read")
        XCTAssertNil(parse(#"{"t":"chats.older","id":"chat-1"}"#), "it says where to read back from")
    }

    func testHootIsReadBackPageByPage() throws {
        let events = (1...700).map { Self.event($0, .message, text: "Line \($0) " + String(repeating: "x", count: 200)) }
        let snapshot: NativeRPCValue = .object([.init("conversationId", .string("conv-1")), .init("events", .array(events))])
        let newest = try BackendINT2HootPhone.page(snapshot, before: nil).value
        XCTAssertTrue(newest["reset"].bool == true && newest["older"] == .missing && newest["total"].number == 700)
        let first = Int(try XCTUnwrap(newest["first"].number)), shown = newest["events"].elements?.count ?? 0
        XCTAssertTrue(first > 0 && first + shown == 700, "the newest events that fit one frame, and where they start")
        let older = try BackendINT2HootPhone.page(snapshot, before: first).value
        XCTAssertTrue(older["reset"].bool == false && older["older"].bool == true)
        let earlier = Int(try XCTUnwrap(older["first"].number))
        XCTAssertTrue(earlier < first && earlier + (older["events"].elements?.count ?? 0) == first)
        XCTAssertTrue(older["events"].elements?.last?["sequence"].number == Double(first), "ends just before the page the phone has")
        XCTAssertTrue(BackendINT2PhoneAccessLevel.look.permits("hoot.older") && BackendCopilotRemoteSurface.frameTier["hoot.older"] == .read)
        XCTAssertNotNil(parse(#"{"t":"copilot.older","before":12}"#), "an older phone's name for it reads as Hoot's")
        XCTAssertNil(parse(#"{"t":"hoot.older"}"#), "it says where to read back from")
    }

    func testChatsIsAKnownCapabilityWithItsMessages() {
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("chats"))
        XCTAssertTrue(BackendPhoneChats.messages.contains("chats.watch") && BackendPhoneChats.messages.contains("chats.new"))
    }

    // MARK: Doubles

    /// A chat's box as the engine reads it: the catalogue's featured model, one listed in use, and a placeholder.
    private static let box: NativeRPCValue = .object([.init("permissionMode", .string("ask")), .init("model", .string("claude:opus")),
        .init("effort", .string("xhigh")), .init("efforts", .array(["high", "xhigh"].map(NativeRPCValue.string))),
        .init("catalog", .object([.init("claude", .object([.init("featured", .array([.string("claude-opus-5")])),
            .init("models", .array([.object([.init("id", .string("claude-opus-5")), .init("name", .string("Opus 5"))])]))]))])),
        .init("models", .array([.object([.init("id", .string("claude:default")), .init("name", .string("Default"))]),
                                .object([.init("id", .string("claude:opus")), .init("name", .string("Opus"))])]))])

    func testNewSessionChoicesParseAndReachTheLaunch() async throws {
        let full = #"{"t":"chats.new","rid":"n1","cwd":"/Projects/Phone","provider":"codex","agent":"agent-7","model":"gpt-6","effort":"high","permissionMode":"plan","account":"codex-work"}"#
        let message = try XCTUnwrap(parse(full))
        XCTAssertTrue(BackendRemoteStartChoices(message: message) == .init(agent: "agent-7", model: "gpt-6", effort: "high", permissionMode: "plan", account: "codex-work"))
        let calls = Recorder()
        // Work may start a session, not choose whose login it spends or what it may do unasked: Full control.
        let refused = try await Self.adapter(calls).handle(message, context: Self.context())
        XCTAssertTrue(refused.first?.kind == .error && refused.first?.value["code"].string == "unauthorized")
        let none = await calls.log
        XCTAssertTrue(none.isEmpty, "nothing started")
        var owner = Self.context(); owner.phoneAccess = .full
        _ = try await Self.adapter(calls).handle(message, context: owner)
        let seen = await calls.log
        XCTAssertTrue(seen.first == "choices agent-7 gpt-6 high plan codex-work", "the launch gets every choice")
        let workModel = try XCTUnwrap(parse(#"{"t":"chats.new","cwd":"/Projects/Phone","provider":"claude","model":"claude-opus-5"}"#))
        XCTAssertTrue(BackendPhoneChats.mayChooseLoginAndMode(.init(message: workModel), Self.context()), "a model is Work's to choose")
        // A terminal from the same form: `create` keeps the choices and an explicit Chat = false.
        let create = try XCTUnwrap(parse(#"{"t":"create","cwd":"/Projects/Phone","provider":"claude","model":"claude-opus-5","effort":"max","chat":false}"#))
        XCTAssertTrue(create["model"].string == "claude-opus-5" && create["effort"].string == "max" && create["chat"].bool == false)
        guard case .success(let planned) = BackendRemoteServeSessionCreate.plan(.init(message: create, deviceID: "phone-1"), offered: ["/Projects/Phone"]) else {
            return XCTFail("an offered folder plans")
        }
        XCTAssertTrue(planned.choices.model == "claude-opus-5" && planned.choices.chat == false)
        XCTAssertTrue(parse(#"{"t":"chats.new","cwd":"/Projects/Phone","provider":"claude","permissionMode":"yolo"}"#) == nil, "only the box's four words")
        XCTAssertTrue(parse(#"{"t":"create","cwd":"/Projects/Phone","effort":"Max!"}"#) == nil)
        XCTAssertTrue(parse(#"{"t":"chats.new","cwd":"/Projects/Phone","provider":"claude","account":"../x"}"#) == nil)
    }

    /// 29 Oct: a phone's pending bubble can be sent now; it reaches the Mac's interrupt-and-send (Work, like a message).
    func testSendNowFromAPhoneReachesTheMacsInterruptAndSend() async throws {
        XCTAssertTrue(BackendPhoneChats.messages.contains("chats.steer"))
        XCTAssertTrue(BackendINT2PhoneAccessLevel.workMessages.contains("chats.steer"))
        let calls = Recorder()
        let answer = try await Self.adapter(calls).handle(try XCTUnwrap(parse(#"{"t":"chats.steer","id":"chat-1","text":"do this first"}"#)), context: Self.context())
        XCTAssertTrue(answer.isEmpty)
        let seen = await calls.log
        XCTAssertTrue(seen == ["steer chat-1 do this first"])
        XCTAssertTrue(parse(#"{"t":"chats.steer","id":"chat-1"}"#) == nil, "no message, no Send now")
    }

    func testAChatsBoxIsReadAndChangedAndItsPermissionIsFullControl() async throws {
        let calls = Recorder()
        let chats = Self.adapter(calls)
        let read = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.options","id":"chat-1"}"#)), context: Self.context())
        let box = try XCTUnwrap(read.first)
        XCTAssertTrue(box.kind == .chatsOptions && box.value["id"].string == "chat-1")
        let models = (box.value["options"]["models"].elements ?? []).compactMap { $0["id"].string }
        // 28 Oct: the alias in use ("opus") is the live model it stands for, ticked, not listed a second time.
        XCTAssertTrue(models == ["claude:claude-opus-5"], "the catalogue, the alias in use as its live model, no placeholder")
        XCTAssertTrue(box.value["options"]["model"].string == "claude:claude-opus-5")
        let first = box.value["options"]["models"].elements?.first
        XCTAssertTrue(first?["detail"].string == "Newest of its line" && first?["more"].bool == false, "a line from the live facts")
        XCTAssertTrue(BackendPhoneChats.modelDetail(.object([.init("oneMillion", .bool(true))]), older: true) == "Earlier model · 1M context")
        XCTAssertTrue(box.value["options"]["permissionMode"].string == "ask" && box.value["options"]["effort"].string == "xhigh")
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.set","id":"chat-1","model":"claude:claude-opus-5","effort":"high"}"#)), context: Self.context())
        let refused = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.set","id":"chat-1","permissionMode":"bypass"}"#)), context: Self.context())
        XCTAssertTrue(refused.first?.kind == .error && refused.first?.value["code"].string == "unauthorized", "Work cannot change what the AI may do unasked")
        var full = Self.context(); full.phoneAccess = .full
        _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.set","id":"chat-1","permissionMode":"plan"}"#)), context: full)
        let seen = await calls.log
        XCTAssertTrue(seen == ["options chat-1", "set chat-1 claude:claude-opus-5 high", "set chat-1 plan"])
        XCTAssertTrue(parse(#"{"t":"chats.set","id":"chat-1"}"#) == nil, "a change of nothing")
    }

    func testTheNewSessionListsAnswerTheirRequest() async throws {
        let calls = Recorder()
        let frames = try await Self.adapter(calls).handle(try XCTUnwrap(parse(#"{"t":"chats.choices","rid":"c1","cwd":"/Projects/Phone"}"#)), context: Self.context())
        let frame = try XCTUnwrap(frames.first)
        XCTAssertTrue(frame.kind == .chatsChoices && frame.value["rid"].string == "c1")
        XCTAssertTrue(frame.value["providers"].elements?.first?["id"].string == "claude" && frame.value["defaultProvider"].string == "claude")
        let seen = await calls.log
        XCTAssertTrue(seen == ["choices for /Projects/Phone"])
        let hoot = BackendINT2PhoneAccessLevel.hoot, look = BackendINT2PhoneAccessLevel.look
        let work = BackendINT2PhoneAccessLevel.work, fullLevel = BackendINT2PhoneAccessLevel.full
        XCTAssertTrue(look.permits("chats.choices") && look.permits("chats.options") && !look.permits("chats.set"))
        XCTAssertTrue(work.permits("chats.set"))
        XCTAssertTrue(hoot.permits("hoot.options.read") && !hoot.permits("hoot.options.set"))
        XCTAssertTrue(!work.permits("hoot.options.set") && fullLevel.permits("hoot.options.set"), "Hoot's own box is Full control")
    }

    private static func adapter(_ calls: Recorder, isChat: Bool = true, defaultFolder: String? = nil,
                                snapshot: NativeRPCValue = .object([.init("conversationId", .string("conv-1")), .init("events", .array([]))])) -> BackendPhoneChats {
        BackendPhoneChats(engine: .init(
            read: { _ in snapshot },
            isChat: { _ in isChat },
            say: { id, text in await calls.note("say \(id) \(text)") },
            interrupt: { id in await calls.note("interrupt \(id)") },
            answer: { id, request, allowed in await calls.note("answer \(id) \(request) \(allowed)") },
            start: { request in
                let c = request.choices
                if !c.isEmpty { await calls.note("choices \(c.agent ?? "-") \(c.model ?? "-") \(c.effort ?? "-") \(c.permissionMode ?? "-") \(c.account ?? "-")") }
                await calls.note("start \(request.cwd) \(request.provider ?? "")")
                var input = BackendCreateSessionInput(cwd: request.cwd, provider: request.provider)
                input.chat = true
                return .init(id: "chat-new", input: input, spawn: .init(provider: request.provider ?? "claude", command: "/not-run", args: [], path: ""),
                             now: Date(timeIntervalSince1970: 1))
            },
            choices: { folder in
                await calls.note("choices for \(folder ?? "-")")
                return .object([.init("providers", .array([.object([.init("id", .string("claude")), .init("name", .string("Claude")), .init("chat", .bool(true))])])),
                                .init("accounts", .array([])), .init("agents", .array([])), .init("defaultProvider", .string("claude"))]
                               + (defaultFolder.map { [.init("defaultFolder", .string($0))] } ?? []))
            },
            options: { id in await calls.note("options \(id)"); return Self.box },
            setOptions: { id, patch in
                await calls.note("set \(id) " + ["permissionMode", "model", "effort"].compactMap { patch[$0].string }.joined(separator: " "))
                return Self.box
            },
            steer: { id, text in await calls.note("steer \(id) \(text)") }), host: .init(
            send: { _, message in await calls.note("send \(message.kind.rawValue)") },
            stillSees: { _, _ in let sees = await calls.sees; await calls.note("sees"); return sees },
            admitStarted: { _, meta in await calls.note("admit \(meta.id)") }), beat: .zero)
    }
}

private actor Recorder {
    private(set) var log: [String] = []
    private(set) var sees = true
    func note(_ line: String) { log.append(line) }
    func setSees(_ value: Bool) { sees = value; log.removeAll() }
    /// Bounded: ten seconds, then the test fails rather than hanging.
    func waitFor(_ prefix: String) async throws {
        for _ in 0..<500 {
            if log.contains(where: { $0.hasPrefix(prefix) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeRPCError(code: "fixture-timeout", message: "No \(prefix) within ten seconds.")
    }
}
