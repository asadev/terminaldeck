import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckToolsSessionsTests: XCTestCase {
    private func obj(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    private func session(_ id: String, at: Double, provider: String = "claude", resumed: Bool = false) -> NativeRPCValue {
        obj([("id", .string(id)), ("cwd", .string("/work/api")), ("provider", .string(provider)), ("createdAt", .number(at)), ("resumed", .bool(resumed)), ("exitCode", .null), ("status", .string("waiting")), ("attention", .string("quiet")), ("attentionReason", .string("prompt-ready"))])
    }
    private func transcript(_ path: String, born: Double, modified: Double = 0, bytes: Int = 1) -> NativeRPCValue {
        obj([("path", .string(path)), ("sessionId", .string(path)), ("createdAt", .number(born)), ("modifiedAt", .number(modified)), ("bytes", .number(Double(bytes)))])
    }
    private func context(attended: Bool = true) -> BackendMCPCallContext {
        BackendMCPCallContext(sessionID: "caller", machineID: "", projectRoot: nil, attended: attended,
            allowedTools: Set(BackendDeckToolsSessionsCatalogue.entries.map(\.id)), allowedTiers: [.read, .act, .alter], cancellation: .init())
    }
    private func handler(_ id: String, _ definitions: [BackendDeckToolsDefinition]) throws -> BackendNativeMCPServer.Handler {
        try XCTUnwrap(definitions.first { $0.spec.id == id }).handler
    }
    func testExactCatalogueIdentitiesSchemasAndBaseTiers() throws {
        let entries = BackendDeckToolsSessionsCatalogue.entries
        XCTAssertEqual(entries.count, 29)
        XCTAssertEqual(Set(entries.map(\.id)).count, 29)
        for entry in entries {
            let tool = try entry.spec()
            XCTAssertEqual(tool.wireName, tool.id.replacingOccurrences(of: ".", with: "_"))
            XCTAssertEqual(tool.inputSchema["type"], .string("object"))
            XCTAssertEqual(tool.inputSchema["additionalProperties"], .bool(false))
            XCTAssertFalse(tool.advertised)
            for key in tool.inputSchema["required"].elements ?? [] { XCTAssertTrue(tool.inputSchema["properties"].has(key.string ?? "")) }
        }
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.id == "accounts.sign_in" }).tier, .alter)
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.id == "sessions.account" }).tier, .read)
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.id == "sessions.wait" }).schemaJSON.contains("Default 40, max 240."), true)
    }
    func testTypingSeparatesLineAndEnterAndWaitsForMentionCompletion() async throws {
        let recorder = BackendDeckToolsSessionsTrace()
        try await BackendDeckToolsSessionsTyping.typeLine(write: { recorder.append("write:" + $0) }, text: "inspect @src/app.swift", submit: true, sleep: { recorder.append("sleep:\($0)") })
        XCTAssertEqual(recorder.values, ["write:inspect @src/app.swift ", "sleep:50", "write:\r"])
        recorder.clear()
        try await BackendDeckToolsSessionsTyping.typeLine(write: { recorder.append("write:" + $0) }, text: "inspect @src/app.swift", submit: false, sleep: { recorder.append("sleep:\($0)") })
        XCTAssertEqual(recorder.values, ["write:inspect @src/app.swift"])
    }
    func testNamedKeysAreClosedAndEscapeGetsLongerGap() async throws {
        let keys = try BackendDeckToolsSessionsTyping.resolveKeys(.array([.string("esc"), .string("2"), .string("Return")]))
        XCTAssertEqual(keys.map(\.name), ["escape", "char:2", "enter"])
        let recorder = BackendDeckToolsSessionsTrace()
        try await BackendDeckToolsSessionsTyping.pressKeys(write: { recorder.append("write:" + $0) }, keys: keys, sleep: { recorder.append("sleep:\($0)") })
        XCTAssertEqual(recorder.values, ["write:\u{1b}", "sleep:150", "write:2", "sleep:50", "write:\r"])
        XCTAssertEqual(try BackendDeckToolsSessionsTyping.resolveKey(.string("Ctrl+C")).bytes, "\u{3}")
        XCTAssertEqual(try BackendDeckToolsSessionsTyping.resolveKey(.string("ctrl_c")).name, "ctrl-c")
        XCTAssertEqual(try BackendDeckToolsSessionsTyping.resolveKey(.string("é")).name, "char:é")
        XCTAssertEqual(try BackendDeckToolsSessionsTyping.resolveKey(.string("😀")).name, "char:😀")
        for key in ["ctrl-z", "hyper", "\u{1b}", "\u{9b}", "\u{1b}[2J"] { XCTAssertThrowsError(try BackendDeckToolsSessionsTyping.resolveKey(.string(key))) }
        XCTAssertThrowsError(try BackendDeckToolsSessionsTyping.resolveKeys(.array([])))
        XCTAssertThrowsError(try BackendDeckToolsSessionsTyping.resolveKeys(.array(Array(repeating: .string("down"), count: 25))))
    }
    func testFailedLineWriteDoesNotSendEnter() async {
        let recorder = BackendDeckToolsSessionsTrace()
        do {
            try await BackendDeckToolsSessionsTyping.typeLine(write: { text in recorder.append(text); throw NativeRPCError(code: "write-failed", message: "failed") }, text: "hello", submit: true, sleep: { recorder.append("sleep:\($0)") })
            XCTFail("The write failure should stop the sequence")
        } catch { XCTAssertEqual(recorder.values, ["hello"]) }
    }
    func testSendTextRejectsControlsAndUsesUTF16Limit() throws {
        XCTAssertEqual(try BackendDeckToolsSessionsTyping.sanitizeSendText("テストを実行してください"), "テストを実行してください")
        for text in ["", "two\nlines", "a\tb", "\u{1b}[2J", "\u{9b}", String(repeating: "😀", count: 2_001)] { XCTAssertThrowsError(try BackendDeckToolsSessionsTyping.sanitizeSendText(text)) }
        XCTAssertEqual(try BackendDeckToolsSessionsTyping.sanitizeSendText(String(repeating: "😀", count: 2_000)).utf16.count, 4_000)
    }
    func testTranscriptAssignmentNeverDuplicatesTwoNearbySessions() {
        let older = session("older", at: 10_000), newer = session("newer", at: 114_000)
        let files = [transcript("/small.jsonl", born: 10_500, modified: 40_000, bytes: 966), transcript("/big.jsonl", born: 114_500, modified: 150_000, bytes: 88_000)]
        let first = BackendDeckToolsSessionsTranscriptMatch.match(session: older, files: files, sessionsInFolder: [older, newer])
        let second = BackendDeckToolsSessionsTranscriptMatch.match(session: newer, files: files, sessionsInFolder: [older, newer])
        XCTAssertEqual(first["path"], .string("/small.jsonl")); XCTAssertEqual(second["path"], .string("/big.jsonl"))
        XCTAssertEqual(first["basis"], .string("started-together")); XCTAssertEqual(first["ambiguous"], .bool(true))
    }
    func testTranscriptEligibilityEmptyFilesResumeAndTies() {
        let one = session("a", at: 10_000), two = session("b", at: 10_000), file = transcript("/a.jsonl", born: 10_000, modified: 20_000)
        XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: one, files: [file], sessionsInFolder: [two, one])["path"], .string("/a.jsonl"))
        XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: two, files: [file], sessionsInFolder: [one, two])["path"], .null)
        let shell = session("shell", at: 10_000, provider: "shell")
        XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: shell, files: [file], sessionsInFolder: [shell])["basis"], .string("none"))
        XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: one, files: [file], sessionsInFolder: [one, shell])["ambiguous"], .bool(false))
        XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: one, files: [transcript("/empty", born: 10_000, bytes: 0)], sessionsInFolder: [one])["path"], .null)
        let resumed = session("resumed", at: 11_000, resumed: true)
        let match = BackendDeckToolsSessionsTranscriptMatch.match(session: resumed, files: [file], sessionsInFolder: [one, resumed])
        XCTAssertEqual(match["basis"], .string("newest")); XCTAssertTrue(match["note"].string?.contains("it was resumed") == true)
    }
    func testFreshSessionCannotClaimOlderConversationInSharedFolder() {
        let one = session("one", at: 1_000_000), two = session("two", at: 2_000_000)
        let result = BackendDeckToolsSessionsTranscriptMatch.match(session: one, files: [transcript("/old", born: 1, modified: 3_000_000)], sessionsInFolder: [one, two])
        XCTAssertEqual(result["path"], .null); XCTAssertTrue(result["note"].string?.contains("none of them is its") == true)
        XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: one, files: [transcript("/old", born: 1)], sessionsInFolder: [one])["path"], .string("/old"))
    }
    func testAccountChoiceDoesNotFallBackAcrossUnknownOrAmbiguousNames() throws {
        let work = obj([("id", .string("p1")), ("name", .string("Work")), ("provider", .string("claude"))])
        let codex = obj([("id", .string("p2")), ("name", .string("Work")), ("provider", .string("codex"))])
        XCTAssertEqual(try BackendDeckToolsSessionsRules.chooseAccount([work], wanted: " work ", provider: "claude"), work)
        XCTAssertEqual(try BackendDeckToolsSessionsRules.chooseAccount([work, codex], wanted: "p1", provider: "claude"), work)
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.chooseAccount([work, codex], wanted: "Work", provider: nil))
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.chooseAccount([work], wanted: "Holiday", provider: nil))
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.chooseAccount([work], wanted: "p1", provider: "codex"))
    }
    func testResultsWithholdSecretsButKeepMetadataAndRankings() {
        let value = obj([("token", .string("secret")), ("credentialsRetained", .bool(true)), ("nested", .array([obj([("api_key", .string("hidden")), ("name", .string("Work"))])]))])
        let scrubbed = BackendDeckToolsSessionsRules.withoutSecrets(value)
        XCTAssertEqual(scrubbed["token"], .string("[withheld]")); XCTAssertEqual(scrubbed["credentialsRetained"], .bool(true))
        XCTAssertEqual(scrubbed["nested"].elements?.first?["api_key"], .string("[withheld]"))
        let numbers = obj([("timeline", .array([.number(1)])), ("contextSeries", .array([])), ("heaviest", .array((0..<8).map { .number(Double($0)) })), ("tools", .array(Array(repeating: .null, count: 20))), ("compactions", .array([.null, .null]))])
        let trim = BackendDeckToolsSessionsRules.trimInsights(numbers)
        XCTAssertEqual(trim["timeline"], .missing); XCTAssertEqual(trim["contextSeries"], .missing)
        XCTAssertEqual(trim["heaviest"].elements?.count, 5); XCTAssertEqual(trim["tools"].elements?.count, 15); XCTAssertEqual(trim["compactions"], .number(2))
    }
    func testDisplayNamesAliasesAmbiguityAndTitleBoundaries() throws {
        let view = obj([("displays", .array([obj([("id", .number(1)), ("label", .string("Built-in Retina Display")), ("primary", .bool(true))]), obj([("id", .number(7)), ("label", .string("DELL U2723QE")), ("primary", .bool(false))])]))])
        XCTAssertEqual(try BackendDeckToolsSessionsRules.displayID(.string("dell u2723qe"), view: view), 7)
        XCTAssertEqual(try BackendDeckToolsSessionsRules.displayID(.string("7"), view: view), 7)
        XCTAssertEqual(try BackendDeckToolsSessionsRules.displayID(.string("main"), view: view), 1)
        XCTAssertNil(try BackendDeckToolsSessionsRules.displayID(.missing, view: view))
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.displayID(.number(42), view: view))
        XCTAssertEqual(try BackendDeckToolsSessionsRules.title(obj([("title", .string("  Fix login  "))])), "Fix login")
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.title(obj([("title", .string("two\nlines"))])))
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.title(obj([("title", .string(String(repeating: "😀", count: 61)))])))
    }
    func testOrdinaryAndElsewhereGrantsKeepSessionDrivingAndCredentialsOut() {
        for forbidden in ["sessions.send", "sessions_send", "sessions.start", "sessions_start", "report", "brief", "browser.password", "browser.lift", "devices.shutdown", "browser.extensions"] {
            XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains(forbidden)); XCTAssertFalse(BackendDeckToolsSessionsGrants.elsewhere.contains(forbidden))
        }
        for name in BackendDeckToolsSessionsGrants.elsewhere { XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(name)) }
        for name in ["assets_fetch", "browser_network", "devices_tap", "memory_read", "knowledge_note"] { XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(name)); XCTAssertFalse(BackendDeckToolsSessionsGrants.elsewhere.contains(name)) }
        XCTAssertTrue(BackendDeckToolsSessionsGrants.elsewhere.contains("browser_open"))
    }
    func testLiftGateUsesCallerIdentityAndPanelNames() throws {
        let local = BackendDeckToolsSessionsCaller(kind: .local, callID: "c")
        let remote = BackendDeckToolsSessionsCaller(kind: .remote, deviceID: "phone", callID: "c")
        let session = BackendDeckToolsSessionsCaller(kind: .session, sessionID: "secret-id", callID: "c")
        XCTAssertNoThrow(try BackendDeckToolsSessionsArea.mayAskLift(caller: local, attended: true))
        XCTAssertThrowsError(try BackendDeckToolsSessionsArea.mayAskLift(caller: remote, attended: true))
        XCTAssertThrowsError(try BackendDeckToolsSessionsArea.mayAskLift(caller: session, attended: false))
        XCTAssertEqual(BackendDeckToolsSessionsArea.askerName(caller: session, slots: ["B1"]), "The session driving B1")
        XCTAssertEqual(BackendDeckToolsSessionsArea.askerName(caller: session, slots: []), "A session in this app")
        XCTAssertEqual(BackendDeckToolsSessionsArea.askerName(caller: local, slots: []), "Hoot")
    }
    func testAgentsArgumentsTrimWhileCatalogueArgumentsKeepText() throws {
        let args = obj([("name", .string("  Work  ")), ("empty", .string("  ")), ("items", .string("one")), ("flag", .null)])
        XCTAssertEqual(try BackendDeckToolsSessionsRules.str(args, "name"), "Work")
        XCTAssertEqual(try BackendDeckToolsArgs.str(args, "name"), "  Work  ")
        XCTAssertNil(try BackendDeckToolsSessionsRules.optStr(args, "empty"))
        XCTAssertEqual(try BackendDeckToolsSessionsRules.optStrings(args, "items"), ["one"])
        XCTAssertEqual(try BackendDeckToolsSessionsRules.oneOf(args, "absent", ["a", "b"], fallback: "a"), "a")
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.oneOf(obj([("choice", .string(" a "))]), "choice", ["a", "b"]))
        XCTAssertTrue(try BackendDeckToolsArgs.optBool(args, "flag", true))
    }
    func testSignInFolderUsesPairedDeviceGrantsAndNeverFallsBackToOpenProjects() async throws {
        let fixture = BackendDeckToolsSessionsFixture(rows: [session("s1", at: 1_000)])
        await fixture.setCaller(.init(kind: .remote, deviceID: "phone-1", callID: "c"))
        do { _ = try await BackendDeckToolsSessionsArea.signInFolder("/work/api", runtime: fixture, context: context()); XCTFail("Missing grants must refuse") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "not-permitted"); XCTAssertTrue(error.message.contains("not available")) }
        await fixture.setDeviceFolders(["/work/web"])
        do { _ = try await BackendDeckToolsSessionsArea.signInFolder("/work/api", runtime: fixture, context: context()); XCTFail("An open folder is not automatically a device grant") }
        catch let error as NativeRPCError { XCTAssertTrue(error.message.contains("this device may only start a session in: /work/web")) }
        let allowed = try await BackendDeckToolsSessionsArea.signInFolder("/work/web/", runtime: fixture, context: context())
        XCTAssertEqual(allowed.cwd, "/work/web"); XCTAssertEqual(allowed.device, "phone-1")
    }
    func testWaitDistinguishesBlockedQuietFreshAnswerAndWorkingFlicker() async throws {
        let fixture = BackendDeckToolsSessionsFixture(rows: [session("s1", at: 1_000)])
        let clock = BackendDeckToolsSessionsTestClock()
        let definitions = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: fixture, surface: fixture, clock: .init(now: { clock.now }, sleep: { clock.advance($0) }))
        let wait = try handler("sessions.wait", definitions)
        await fixture.setStatus("input", at: 1)
        await fixture.setScreen("Question?\n 1. Yes\n 2. No\n\n")
        let blocked = try await wait(context(), obj([("sessionId", .string("s1"))]))
        XCTAssertEqual(blocked.structuredContent?["outcome"], .string("blocked")); XCTAssertEqual(blocked.structuredContent?["screen"], .string("Question?\n 1. Yes\n 2. No"))
        await fixture.setStatus("waiting", at: 1)
        let quiet = try await wait(context(), obj([("sessionId", .string("s1")), ("timeoutSeconds", .number(2))]))
        XCTAssertEqual(quiet.structuredContent?["outcome"], .string("timed-out"))
        await fixture.setTranscripts([transcript("/a.jsonl", born: 1_000)])
        await fixture.setMessages([obj([("role", .string("agent")), ("at", .number(9_200)), ("text", .string("Done."))])])
        let fresh = try await wait(context(), obj([("sessionId", .string("s1")), ("after", .number(9_100))]))
        XCTAssertEqual(fresh.structuredContent?["outcome"], .string("finished")); XCTAssertEqual(fresh.structuredContent?["answer"]["afterSend"], .bool(true))
        await fixture.setMessages([]); await fixture.setStatus("working", at: clock.now)
        let flickerClock = BackendDeckToolsSessionsTestClock()
        let flicker = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: fixture, surface: fixture, clock: .init(now: { flickerClock.now }, sleep: { milliseconds in
            flickerClock.advance(milliseconds)
            if flickerClock.now == 10_250 { await fixture.setStatus("waiting", at: flickerClock.now) }
            if flickerClock.now == 10_500 { await fixture.setStatus("working", at: flickerClock.now) }
        }))
        let flickerReply = try await handler("sessions.wait", flicker)(context(), obj([("sessionId", .string("s1")), ("timeoutSeconds", .number(3))]))
        XCTAssertEqual(flickerReply.structuredContent?["outcome"], .string("timed-out"))
    }
    func testKeysEffectiveTierAndValidationBeforeConsent() async throws {
        let fixture = BackendDeckToolsSessionsFixture(rows: [session("s1", at: 1_000)])
        let definitions = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: fixture, surface: fixture, clock: .init(sleep: { _ in }))
        let keys = try handler("sessions.keys", definitions)
        let malformed = try await keys(context(), obj([("sessionId", .string("s1")), ("keys", .array([.string("ctrl-z")]))]))
        XCTAssertTrue(malformed.isError)
        let noConsent = await fixture.tiers; XCTAssertEqual(noConsent, [])
        _ = try await keys(context(), obj([("sessionId", .string("s1")), ("keys", .array([.string("enter")]))]))
        let theirs = await fixture.tiers; XCTAssertEqual(theirs, [.alter])
        await fixture.setOwn(["s1"])
        _ = try await keys(context(), obj([("sessionId", .string("s1")), ("keys", .array([.string("2"), .string("enter")]))]))
        let tiers = await fixture.tiers; XCTAssertEqual(tiers, [.alter, .act])
        let writes = await fixture.writes; XCTAssertEqual(writes, ["\r", "2", "\r"])
    }
    func testChatsReadsOnlyAListedTranscriptInTheKnownFolder() async throws {
        let fixture = BackendDeckToolsSessionsFixture(rows: [session("s1", at: 1_000)])
        await fixture.setTranscripts([transcript("/old", born: 1, modified: 10), transcript("/new", born: 2, modified: 20)])
        await fixture.setMessages([obj([("id", .string("a")), ("role", .string("agent")), ("text", .string("hello")), ("at", .number(1))])])
        let definitions = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: fixture, surface: fixture)
        let read = try handler("chats.read", definitions)
        let allowed = try await read(context(), obj([("cwd", .string("/work/api"))]))
        XCTAssertEqual(allowed.structuredContent?["transcriptPath"], .string("/new"))
        let denied = try await read(context(), obj([("cwd", .string("/work/api")), ("transcriptPath", .string("/Users/x/.ssh/id_rsa"))]))
        XCTAssertTrue(denied.isError); XCTAssertTrue(denied.structuredContent?["error"].string?.contains("not one of the conversations") == true)
    }
}

private final class BackendDeckToolsSessionsTrace: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ text: String) { lock.withLock { storage.append(text) } }
    func clear() { lock.withLock { storage.removeAll() } }
}
private final class BackendDeckToolsSessionsTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var milliseconds = 10_000.0
    var now: Double { lock.withLock { milliseconds } }
    func advance(_ amount: Int) { lock.withLock { milliseconds += Double(amount) } }
}
private actor BackendDeckToolsSessionsFixture: BackendDeckToolsSessionsRuntime, BackendDeckToolsSessionsSurface {
    var rows: [NativeRPCValue]; var tiers: [BackendMCPTier] = []; var writes: [String] = []
    private var owned = Set<String>(), live = NativeRPCValue.object([.init("status", .string("waiting")), .init("at", .number(1))])
    private var visible = "", files: [NativeRPCValue] = [], messages: [NativeRPCValue] = []
    private var identity = BackendDeckToolsSessionsCaller(kind: .local, callID: "call-1"), devicePaths: [String]?
    init(rows: [NativeRPCValue]) { self.rows = rows }
    func setStatus(_ status: String, at: Double) { live = .object([.init("status", .string(status)), .init("at", .number(at))]) }
    func setScreen(_ text: String) { visible = text }
    func setOwn(_ ids: Set<String>) { owned = ids }
    func setTranscripts(_ rows: [NativeRPCValue]) { files = rows }
    func setMessages(_ rows: [NativeRPCValue]) { messages = rows }
    func setCaller(_ value: BackendDeckToolsSessionsCaller) { identity = value }
    func setDeviceFolders(_ folders: [String]?) { devicePaths = folders }
    func caller(_ context: BackendMCPCallContext) -> BackendDeckToolsSessionsCaller { identity }
    func sessions(_ context: BackendMCPCallContext) -> [NativeRPCValue] { rows }
    func knownFolders(_ context: BackendMCPCallContext) -> Set<String> { ["/work/api"] }
    func deviceFolders(deviceID: String, context: BackendMCPCallContext) -> [String]? { devicePaths }
    func startedByCaller(sessionID: String, context: BackendMCPCallContext) -> Bool { owned.contains(sessionID) }
    func noteStarted(sessionID: String, context: BackendMCPCallContext) { owned.insert(sessionID) }
    func authorize(tool: BackendMCPTool, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue, context: BackendMCPCallContext) { tiers.append(tier) }
    func recordResult(toolID: String, summary: NativeRPCValue, context: BackendMCPCallContext) {}
    func browserSlots(sessionID: String, machineID: String, context: BackendMCPCallContext) -> [String] { [] }
    func status(sessionID: String, context: BackendMCPCallContext) -> NativeRPCValue? { live }
    func screen(sessionID: String, context: BackendMCPCallContext) -> String? { visible }
    func write(sessionID: String, data: String, context: BackendMCPCallContext) { writes.append(data) }
    func rename(sessionID: String, title: String, context: BackendMCPCallContext) -> String? { title.isEmpty ? "api" : title }
    func held(context: BackendMCPCallContext) -> [NativeRPCValue] { [] }
    func retryHeld(key: String, context: BackendMCPCallContext) throws -> [NativeRPCValue] { throw BackendDeckToolsSupport.unavailable("fixture held retry") }
    func forgetHeld(key: String, context: BackendMCPCallContext) throws -> [NativeRPCValue] { throw BackendDeckToolsSupport.unavailable("fixture held forget") }
    func account(sessionID: String, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture account") }
    func limits(sessionID: String, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture limits") }
    func accountPlan(sessionID: String, profileID: String, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture plan") }
    func switchAccount(sessionID: String, profileID: String, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture switch") }
    func switchLater(sessionID: String, profileID: String, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture later") }
    func cancelSwitch(sessionID: String, context: BackendMCPCallContext) throws -> Bool { throw BackendDeckToolsSupport.unavailable("fixture cancel") }
    func armedSwitches(context: BackendMCPCallContext) -> [NativeRPCValue] { [] }
    func accounts(context: BackendMCPCallContext) -> [NativeRPCValue] { [] }
    func search(request: NativeRPCValue, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture search") }
    func insights(transcriptPath: String, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture insights") }
    func transcripts(cwd: String, context: BackendMCPCallContext) -> [NativeRPCValue] { files }
    func transcriptBytes(path: String, context: BackendMCPCallContext) -> Int { 1 }
    func transcriptMessages(path: String, fromByte: Int, context: BackendMCPCallContext) -> [NativeRPCValue] { messages }
    func start(input: BackendCreateSessionInput, deviceID: String?, context: BackendMCPCallContext) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("fixture start") }
}
