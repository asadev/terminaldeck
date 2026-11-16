import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 14 Nov phone asks, the app side: the permission mode a phone shows is passed at the start with the Mac's New
/// session page's mapping (refused when this Mac cannot start in it); its first message goes into a Chat as said, into a Terminal only at the AI's own prompt
/// (the page's `NativeLandingTerminal` rule), typed as the session's paste setting takes it. Recorded calls only: no app, engine or session host.
final class PhoneStartTextTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var rows: [(String, [NativeRPCValue])] = []
        func add(_ channel: String, _ args: [NativeRPCValue]) { lock.withLock { rows.append((channel, args)) } }
        var all: [(String, [NativeRPCValue])] { lock.withLock { rows } }
    }

    func testTheModeIsPassedAtTheStartWithThePagesMapping() throws {
        func start(_ mode: BackendHOOTSIMPermissionMode?, _ provider: String, host: Bool = true) throws -> BackendCreateSessionInput {
            var input = BackendCreateSessionInput(cwd: "/Projects/Phone", provider: provider)
            try NativePhoneStart.chooseStart(mode, provider: provider, into: &input, hostHonours: host)
            return input
        }
        // Chosen: the AI's own value, as launch mode AND explicit start (Chat or Terminal alike), never set afterwards.
        let plan = try start(.plan, "claude")
        XCTAssertEqual(plan.permissionMode, "plan"); XCTAssertEqual(plan.chosenStartPermission, "plan")
        let ask = try start(.ask, "codex")
        XCTAssertEqual(ask.chosenStartPermission, BackendHOOTSIMPermissionMode.ask.cliMode(provider: .codex))
        XCTAssertEqual(try start(.bypass, "claude").chosenStartPermission, "bypassPermissions", "an explicit Bypass too, as the page sends it")
        // No choice or a Shell: as every new session (nothing explicit).
        XCTAssertNil(try start(nil, "claude").chosenStartPermission)
        XCTAssertNil(try start(.plan, "shell").chosenStartPermission)
    }

    /// Lead's decision 14 Nov: the phone follows the Mac's page. `modeAtStart` false (today, `pickOffered` off): a
    /// stricter mode is refused with one plain line, never started weaker; no mode or Bypass goes through as before.
    func testModeAtStartFalseRefusesAStricterModeWithTheLine() throws {
        for mode in [BackendHOOTSIMPermissionMode.plan, .ask, .changes] {
            var input = BackendCreateSessionInput(cwd: "/Projects/Phone", provider: "claude")
            XCTAssertThrowsError(try NativePhoneStart.chooseStart(mode, provider: "claude", into: &input, hostHonours: false)) { error in
                XCTAssertEqual((error as? NativeRPCError)?.message, "This Mac starts new sessions in Bypass. Change it in the session after it starts.")
            }
        }
        for mode in [nil, BackendHOOTSIMPermissionMode.bypass] {
            var input = BackendCreateSessionInput(cwd: "/Projects/Phone", provider: "claude")
            XCTAssertNoThrow(try NativePhoneStart.chooseStart(mode, provider: "claude", into: &input, hostHonours: false))
            XCTAssertNil(input.chosenStartPermission); XCTAssertNil(input.permissionMode)
        }
    }

    /// `chats.choices.modeAtStart` is the Mac page's own switch (`NativeLandingHost.honoursChosenStart`): on since 15 Nov.
    func testTheChoicesSayModeAtStartFromThePagesSwitch() async {
        let lists = await NativePhoneStart.choices(folder: nil) { _, _ in throw NativeRPCError(code: "unavailable", message: "none") }
        let page = await MainActor.run { NativeLandingHost.honoursChosenStart() }
        XCTAssertEqual(lists["modeAtStart"].bool, page)
        XCTAssertEqual(lists["modeAtStart"].bool, true, "pickOffered is on (15 Nov); no helper here: this build's own launcher starts in it")
    }

    /// Phones ask 5: the phones' New session lists are the Mac page's own, so Claude has model rows even when the live
    /// catalogue has none (his own Claude Code sign-in), never an empty list.
    @MainActor
    func testThePhonesGetTheModelsTheMacPageOffers() async throws {
        let suite = "PhoneStartTextTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let nothing: NativePhoneStart.Invoke = { _, _ in throw NativeRPCError(code: "unavailable", message: "none") }
        let plain = await NativePhoneStart.choices(folder: nil, invoke: nothing)
        let claudeBefore = plain["providers"].elements?.first { $0["id"].string == "claude" }
        XCTAssertEqual(claudeBefore?["models"].elements?.count, 0, "the cause: the live catalogue alone has no Claude list")
        let lists = await NativePhoneStart.newSessionLists(folder: nil, invoke: nothing, defaults: defaults, cliDefault: { _ in (nil, nil) })
        let claude = lists["providers"].elements?.first { $0["id"].string == "claude" }
        XCTAssertFalse((claude?["models"].elements ?? []).isEmpty, "the page's own list reaches the phone")
        XCTAssertEqual(claude?["efforts"], claudeBefore?["efforts"], "effort choices as before")
    }

    func testAChatsFirstMessageIsSaid() async {
        let calls = Calls()
        let sent = await NativePhoneStart.deliverFirst(.init(sessionID: "s-1", provider: "claude", chat: true, text: "hello"),
            manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })) { channel, args in calls.add(channel, args); return .bool(true) }
        XCTAssertTrue(sent)
        XCTAssertEqual(calls.all.map(\.0), ["session:chat:say"])
        XCTAssertEqual(calls.all.first?.1.last?.string, "hello")
        let refused = await NativePhoneStart.deliverFirst(.init(sessionID: "s-1", provider: "claude", chat: true, text: "hello"),
            manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })) { _, _ in throw NativeRPCError(code: "unavailable", message: "no") }
        XCTAssertFalse(refused, "a chat that refused it: not sent, the phone gets it back")
    }

    @MainActor
    func testATerminalThatIsGoneIsNeverTypedInto() async {
        let calls = Calls()
        let sent = await NativePhoneStart.deliverFirst(.init(sessionID: "no-such-session", provider: "claude", chat: false, text: "run"),
            manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })) { channel, args in calls.add(channel, args); return .bool(true) }
        XCTAssertFalse(sent)
        XCTAssertTrue(calls.all.isEmpty)
    }

    /// Follows the session's real paste setting (review 14 Nov, point 5).
    func testTheTextFollowsTheSessionsPasteSetting() {
        // Bracketed paste on: one paste, its line breaks never press Return; Return goes separately.
        let typed = NativePhoneStart.typing("first line\nsecond line", provider: "shell", bracketed: true)
        XCTAssertTrue(typed?.hasPrefix("\u{1b}[200~") == true && typed?.hasSuffix("\u{1b}[201~") == true)
        XCTAssertFalse(typed?.hasSuffix("\r") == true, "Return is pressed separately, only after the text shows")
        // Off (a plain Shell, an added tool): one line typed plainly; several lines not sent.
        XCTAssertEqual(NativePhoneStart.typing("ls -la", provider: "shell", bracketed: false), "ls -la")
        XCTAssertNil(NativePhoneStart.typing("one\ntwo", provider: "shell", bracketed: false))
        XCTAssertNil(NativePhoneStart.typing("one\r\ntwo", provider: "aider", bracketed: false))
        XCTAssertNil(NativePhoneStart.typing("one\ntwo", provider: "claude", bracketed: false), "the real setting wins over the AI's name")
        // Unknown (an older session host): the three AIs' prompts switch it on; anything else counts as off.
        XCTAssertEqual(NativePhoneStart.typing("a\nb", provider: "codex", bracketed: nil), "\u{1b}[200~a\rb\u{1b}[201~")
        XCTAssertNil(NativePhoneStart.typing("a\nb", provider: "shell", bracketed: nil))
    }

    /// The page's own rule, as the phone's Terminal uses it: never ready within the limit, nothing typed.
    @MainActor
    func testNeverReadyWithinTheLimitTypesNothing() async {
        var typed = 0
        let sent = await NativeLandingTerminal.deliver(provider: "claude", text: "run", read: { (.waiting, "someone@mac:~$ ") },
            type: { _ in typed += 1 }, submit: { typed += 1 }, pause: {}, attempts: 8)
        XCTAssertFalse(sent); XCTAssertEqual(typed, 0)
    }
}
