import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortToolsCoreRulesTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private var step: NativeRPCValue { try! F.json(#"{"type":"object","properties":{"verb":{"type":"string","enum":["click","type","press"]},"selector":{"type":"string"},"value":{"type":"string"},"timeoutMs":{"type":"number"}},"required":["verb","selector"],"additionalProperties":false}"#) }
    private func refusal(_ schema: NativeRPCValue,_ args: NativeRPCValue) -> String { do { try BackendDeckCoreCatalogueSchema.check(schema:schema,arguments:args); return "" } catch { XCTAssertTrue(error is BackendDeckCoreSecurityRefusal); return error.localizedDescription } }
    private func attention(_ status: String = "idle",since: Double? = 1_000,exit: Int? = nil,now: Double = 61_000) -> NativeRPCValue { BackendDeckCoreAttention.view(status:status,statusSince:since,exitCode:exit,now:now) }
    // TSCASE attention.test.ts:21
    func testAttentionL21OnlyInputIsBlocked() { XCTAssertEqual(attention("input")["attention"],.string("blocked")); XCTAssertEqual(attention("input")["attentionReason"],.string("question-unanswered")); for status in ["idle","working","waiting","completed","exited"] { XCTAssertNotEqual(attention(status,exit:status == "exited" ? 0 : nil)["attention"],.string("blocked"),status) } }
    // TSCASE attention.test.ts:31
    func testAttentionL31OutputRunning() { XCTAssertEqual(attention("working")["attention"],.string("running")); XCTAssertEqual(attention("working")["attentionReason"],.string("output-streaming")) }
    // TSCASE attention.test.ts:38
    func testAttentionL38BothQuietReasons() { XCTAssertEqual(attention("waiting")["attentionReason"],.string("prompt-ready")); XCTAssertEqual(attention()["attentionReason"],.string("no-output")); XCTAssertEqual(attention("waiting")["attention"],.string("quiet")); XCTAssertEqual(attention()["attention"],.string("quiet")) }
    // TSCASE attention.test.ts:47
    func testAttentionL47CleanExitAndCrashAreDone() { for (code,reason) in [(0,"process-exited"),(137,"process-failed")] { let value = attention("exited",exit:code); XCTAssertEqual(value["attention"],.string("done")); XCTAssertEqual(value["attentionReason"],.string(reason)) } }
    // TSCASE attention.test.ts:58
    func testAttentionL58FinishedTurnIsNotDead() { let value = attention("completed"); XCTAssertEqual(value["attention"],.string("done")); XCTAssertEqual(value["attentionReason"],.string("turn-finished")); XCTAssertEqual(value["statusSource"],.string("screen")) }
    // TSCASE attention.test.ts:77
    func testAttentionL77RealShellPromptQuiet() { let status = BackendSessionClassifier.classify(viewport:"apple@Mac terminaldeck % ").rawValue; XCTAssertEqual(status,"waiting"); XCTAssertEqual(attention(status)["attention"],.string("quiet")) }
    // TSCASE attention.test.ts:88
    func testAttentionL88ClaudePromptNotLastLineStillQuiet() {
        let screen = ["╰──────────────────────────────────────────────────────╯","","        ✦ ultracode · xhigh effort + dynamic workflows","─────────────────────────────────────────── ultracode ─","❯ ","───────────────────────────────────────────────────────","","  ⏵⏵ bypass permissions on (shift+tab to cycle)"].joined(separator:"\n"),status = BackendSessionClassifier.classify(viewport:screen).rawValue
        XCTAssertEqual(status,"waiting"); XCTAssertEqual(attention(status)["attention"],.string("quiet"))
    }
    // TSCASE attention.test.ts:105
    func testAttentionL105TrustPromptBlocked() {
        let screen = ["Accessing workspace:","","/Users/apple/Projects/terminaldeck","","Claude Code will be able to read, edit, and execute files here.","","❯ 1. Yes, I trust this folder","  2. No, exit","","Enter to confirm · Esc to cancel"].joined(separator:"\n"),status = BackendSessionClassifier.classify(viewport:screen).rawValue
        XCTAssertEqual(status,"input"); XCTAssertEqual(attention(status)["attention"],.string("blocked"))
    }
    // TSCASE attention.test.ts:132
    func testAttentionL132RepaintReadsViewportRatherThanOldByteStream() throws {
        let viewport = try BackendPTYManager.viewportForTesting(cols:60,rows:8,chunks:[Data("Do you want to proceed? (y/n)".utf8),Data("\u{1b}[2J\u{1b}[H❯ \n".utf8)])
        let status = BackendSessionClassifier.classify(viewport:viewport).rawValue
        XCTAssertEqual(status,"waiting"); XCTAssertEqual(attention(status)["attention"],.string("quiet"))
    }
    // TSCASE attention.test.ts:149
    func testAttentionL149DurationFromStatusChange() { XCTAssertEqual(attention("input")["attentionForMs"],.number(60_000)) }
    // TSCASE attention.test.ts:153
    func testAttentionL153ClockBackwardsClamped() { XCTAssertEqual(attention("input",since:90_000)["attentionForMs"],.number(0)) }
    // TSCASE attention.test.ts:166
    func testAttentionL166NoInventedExitDuration() { let value = attention("exited",since:nil,exit:0); XCTAssertEqual(value["attentionForMs"],.null); XCTAssertEqual(value["attention"],.string("done")) }
    // TSCASE attention.test.ts:171
    func testAttentionL171ExitCodeAndScreenSources() { XCTAssertEqual(attention("exited",exit:0)["statusSource"],.string("exit-code")); XCTAssertEqual(attention("working")["statusSource"],.string("screen")) }
    // TSCASE attention.test.ts:182
    func testAttentionL182OnlyTwoSourcesExist() { let sources = Set(["idle","working","waiting","input","completed","exited"].compactMap { attention($0,exit:$0 == "exited" ? 0 : nil)["statusSource"].string }); XCTAssertEqual(sources,["exit-code","screen"]) }
    // TSCASE attention.test.ts:193
    func testAttentionL193ExitBeatsStaleStatus() { XCTAssertEqual(BackendDeckCoreAttention.status(exitCode:0,live:"working"),"exited"); XCTAssertEqual(BackendDeckCoreAttention.status(exitCode:nil,live:"working"),"working"); XCTAssertEqual(BackendDeckCoreAttention.status(exitCode:nil,live:nil),"idle") }
    // TSCASE attention.test.ts:204
    func testAttentionL204ExactTriageOrder() { let values = [attention("working"),attention(),attention("exited",exit:1),attention("input")].sorted(by:BackendDeckCoreAttention.precedes); XCTAssertEqual(values.map { $0["attention"].string },["blocked","done","quiet","running"]) }
    // TSCASE attention.test.ts:218
    func testAttentionL218LongestBlockedFirst() { let recent = attention("input",since:60_000),ancient = attention("input"); XCTAssertEqual([recent,ancient].sorted(by:BackendDeckCoreAttention.precedes),[ancient,recent]) }
    // TSCASE attention.test.ts:224
    func testAttentionL224UnknownDurationLast() { let unknown = attention("exited",since:nil,exit:0),known = attention("exited",exit:0); XCTAssertEqual([unknown,known].sorted(by:BackendDeckCoreAttention.precedes),[known,unknown]) }
    // TSCASE schema.test.ts:39
    func testSchemaL39NamesNearMissAndRealArguments() throws { let message = refusal(step,try F.json(##"{"verb":"type","selector":"#q","text":"hello"}"##)); for text in ["text","value","selector"] { XCTAssertTrue(message.contains(text)) } }
    // TSCASE schema.test.ts:48
    func testSchemaL48UnknownBeforeMissing() throws { XCTAssertTrue(refusal(step,try F.json(##"{"verb":"type","selector":"#q","text":"hi"}"##)).contains("is not an argument")) }
    // TSCASE schema.test.ts:56
    func testSchemaL56NamesEveryUnknownOnce() throws { let message = refusal(step,try F.json(##"{"verb":"click","selector":"#a","bypass":true,"approved":true}"##)); for text in ["bypass","approved","are not arguments"] { XCTAssertTrue(message.contains(text)) } }
    // TSCASE schema.test.ts:63
    func testSchemaL63OpenObjectAcceptsExtra() throws { try BackendDeckCoreCatalogueSchema.check(schema:F.json(#"{"type":"object","properties":{}}"#),arguments:F.json(#"{"anything":1}"#)) }
    // TSCASE schema.test.ts:69
    func testSchemaL69ExplicitUndefinedAbsent() throws { try BackendDeckCoreCatalogueSchema.check(schema:step,arguments:F.json(##"{"verb":"click","selector":"#a"}"##).setting("text",.missing)) }
    // TSCASE schema.test.ts:77
    func testSchemaL77ExactWrongTypeSentence() throws { XCTAssertEqual(refusal(step,try F.json(#"{"verb":"click","selector":7}"#)),"selector must be string, not integer") }
    // TSCASE schema.test.ts:81
    func testSchemaL81IntegerRejectsFractionAndAcceptsWhole() throws { let schema = try F.json(#"{"type":"object","properties":{"n":{"type":"integer"}}}"#); XCTAssertTrue(refusal(schema,try F.json(#"{"n":1.5}"#)).contains("must be integer")); try BackendDeckCoreCatalogueSchema.check(schema:schema,arguments:F.json(#"{"n":4}"#)) }
    // TSCASE schema.test.ts:87
    func testSchemaL87NonfiniteNumbersRejected() throws { let schema = try F.json(#"{"type":"object","properties":{"n":{"type":"number"}}}"#); for number in [Double.nan,.infinity] { XCTAssertTrue(refusal(schema,F.object([("n",.number(number))])).contains("must be number")) } }
    // TSCASE schema.test.ts:95
    func testSchemaL95NullIsSupplied() throws { XCTAssertTrue(refusal(step,try F.json(#"{"verb":"click","selector":null}"#)).contains("must be string")) }
    // TSCASE schema.test.ts:101
    func testSchemaL101EnumNamesAllowedAndOffered() throws { let message = refusal(step,try F.json(##"{"verb":"hover","selector":"#a"}"##)); for text in ["click","press","hover"] { XCTAssertTrue(message.contains(text)) } }
    // TSCASE schema.test.ts:108
    func testSchemaL108ArrayItemsExactSentenceAndAcceptedStrings() throws { let schema = try F.json(#"{"type":"object","properties":{"steps":{"type":"array","items":{"type":"string"}}}}"#); XCTAssertEqual(refusal(schema,try F.json(#"{"steps":["a",2]}"#)),"steps[1] must be string, not integer"); try BackendDeckCoreCatalogueSchema.check(schema:schema,arguments:F.json(#"{"steps":["a","b"]}"#)) }
    // TSCASE schema.test.ts:117
    func testSchemaL117EnumRefusalDoesNotEcho400Characters() { let text = String(repeating:"x",count:400),message = refusal(step,F.object([("verb",.string(text)),("selector",.string("#a"))])); XCTAssertLessThan(message.utf16.count,200); XCTAssertFalse(message.contains(text)) }
    // TSCASE schema.test.ts:126
    func testSchemaL126MissingSelectorExactSentence() throws { XCTAssertEqual(refusal(step,try F.json(#"{"verb":"click"}"#)),"selector is required") }
    // TSCASE schema.test.ts:130
    func testSchemaL130AllMissingExactSentence() { XCTAssertEqual(refusal(step,.object([])),"verb, selector are required") }
    // TSCASE schema.test.ts:136
    func testSchemaL136UnknownKeywordsIgnored() throws { try BackendDeckCoreCatalogueSchema.check(schema:F.json(#"{"type":"object","properties":{"at":{"type":"string","format":"date-time","pattern":"^z"}}}"#),arguments:F.json(#"{"at":"not a date"}"#)) }
    // TSCASE schema.test.ts:148
    func testSchemaL148AllBuiltinSchemasClosed() throws { for spec in try BackendDeckCoreCatalogueLiterals.builtins() { XCTAssertEqual(spec.tool.inputSchema["type"],.string("object"),spec.tool.id); XCTAssertEqual(spec.tool.inputSchema["additionalProperties"],.bool(false),spec.tool.id) } }
    // TSCASE schema.test.ts:155
    func testSchemaL155EveryEmptyCallAcceptedOrTypedRefusal() throws { for spec in try BackendDeckCoreCatalogueLiterals.builtins() { _ = refusal(spec.tool.inputSchema,.object([])) } }
    // TSCASE schema.test.ts:168
    func testSchemaL168WireSchemaIsTheCheckedSchema() throws { for spec in try BackendDeckCoreCatalogueLiterals.builtins() { XCTAssertEqual(spec.advertisedValue["inputSchema"],spec.tool.inputSchema,spec.tool.id) } }
    private func settings(_ text: String) throws -> BackendDeckCoreCataloguePatchCheck { try settings("settings",text) }
    private func settings(_ scope: String,_ text: String) throws -> BackendDeckCoreCataloguePatchCheck { BackendDeckCoreCatalogueSettings.check(scope:scope,patch:try F.json(text)) }
    // TSCASE settings-validate.test.ts:16
    func testSettingsL16RealTableAndSelectKind() { XCTAssertGreaterThan(SettingsSchema.all.count,10); XCTAssertEqual(SettingsSchema.setting("appearance.density")?.kind,.select) }
    // TSCASE settings-validate.test.ts:26
    func testSettingsL26DeclaredOptionExactEffective() throws { let value = try settings(#"{"appearance.density":"compact"}"#); XCTAssertTrue(value.problems.isEmpty); XCTAssertEqual(value.effective,try F.json(#"{"appearance.density":"compact"}"#)) }
    // TSCASE settings-validate.test.ts:41
    func testSettingsL41EnumNamesOptionsAndWritesNothing() throws { let value = try settings(#"{"appearance.density":"none"}"#); XCTAssertEqual(value.problems.count,1); for option in ["comfortable","compact"] { XCTAssertTrue(value.problemSentence.contains(option)) }; XCTAssertEqual(value.effective,.object([])) }
    // TSCASE settings-validate.test.ts:49
    func testSettingsL49UnknownKeyExactName() throws { XCTAssertTrue(try settings(#"{"made.up":true}"#).problemSentence.contains("there is no setting called made.up")) }
    // TSCASE settings-validate.test.ts:54
    func testSettingsL54ToggleRejectsString() throws { XCTAssertTrue(try settings(#"{"general.copyOnSelect":"yes"}"#).problemSentence.contains("true or false")) }
    // TSCASE settings-validate.test.ts:59
    func testSettingsL59EveryBadKeyAndPartialEffective() throws { let value = try settings(#"{"appearance.density":"none","made.up":1,"general.copyOnSelect":true}"#); XCTAssertEqual(value.problems.map(\.key).sorted(),["appearance.density","made.up"]); XCTAssertEqual(value.effective,try F.json(#"{"general.copyOnSelect":true}"#)) }
    // TSCASE settings-validate.test.ts:81
    func testSettingsL81SchemaOwnMaximumAndAdjustedKey() throws { let definition = try XCTUnwrap(SettingsSchema.setting("appearance.terminalFontSize")); XCTAssertEqual(definition.kind,.number); let value = try settings(#"{"appearance.terminalFontSize":4000}"#); XCTAssertTrue(value.problems.isEmpty); XCTAssertEqual(value.effective["appearance.terminalFontSize"].number,definition.number?.max); XCTAssertEqual(value.adjusted,["appearance.terminalFontSize"]) }
    // TSCASE settings-validate.test.ts:104
    func testSettingsL104PreferenceBackedKeyNamesOtherStore() throws { let message = try settings(#"{"appearance.theme":"light"}"#).problemSentence; XCTAssertTrue(message.contains("scope \"preferences\"")); XCTAssertTrue(message.contains("theme")) }
    // TSCASE settings-validate.test.ts:110
    func testSettingsL110SameChangeThroughPreferences() throws { let value = try settings("preferences",#"{"theme":"light"}"#); XCTAssertTrue(value.problems.isEmpty); XCTAssertEqual(value.effective,try F.json(#"{"theme":"light"}"#)) }
    // TSCASE settings-validate.test.ts:116
    func testSettingsL116InvalidPreferenceRows() throws { for text in [#"{"theme":"neon"}"#,#"{"defaultProvider":"gpt"}"#,#"{"restoreSessions":"yes"}"#] { XCTAssertEqual(try settings("preferences",text).problems.count,1,text) } }
    // TSCASE settings-validate.test.ts:125
    func testSettingsL125NullResetsOnlySettings() throws { XCTAssertTrue(try settings(#"{"appearance.density":null}"#).problems.isEmpty); XCTAssertTrue(try settings("preferences",#"{"theme":null}"#).problemSentence.contains("cannot be set to null")) }
}

final class BackendDeckCoreTestPortToolsBriefFake: BackendDeckCoreBriefSurface, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 0.0,looks = 0
    private var writes: [String] = []
    let screens: @Sendable (Int) -> String?
    let exit: Int?
    init(exit: Int? = nil,screens: @escaping @Sendable (Int) -> String?) { self.exit = exit; self.screens = screens }
    func listSessions() -> [NativeRPCValue] { [BackendDeckCoreTestPortToolsFixture.object([("id",.string("new-1")),("cwd",.string("/work/api")),("title",.string("api")),("provider",.string("claude")),("exitCode",exit.map { .number(Double($0)) } ?? .null),("createdAt",.number(0))])] }
    func sessionScreen(id: String) -> String? { let n = lock.withLock { looks += 1; return looks }; return screens(n) }
    func writeToSession(id: String,data: String) { lock.withLock { writes.append(data) } }
    func typed() -> [String] { lock.withLock { writes } }
    var clock: BackendDeckCoreBriefClock { .init(now:{ self.lock.withLock { self.instant } },sleep:{ delta in self.lock.withLock { self.instant += delta } }) }
}

@MainActor
final class BackendDeckCoreTestPortToolsBriefTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func scratch() throws -> URL { let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); return dir }
    // TSCASE brief.test.ts:38
    func testBriefL38RerunnableFacts() throws { let dir = try scratch(); defer { try? FileManager.default.removeItem(at:dir) }; let value = try BackendDeckCoreBrief.writeSpec(directory:BackendDeckCoreBrief.specsDirectory(copilotRoot:dir),input:F.json(#"{"title":"Fix the flaky auth test","brief":"Base branch is main. The test is auth.test.ts. Done means it passes ten times.","cwd":"/work/api","provider":"claude","callId":"row-7","at":1786959720000}"#),ownership:.exclusive); let text = try String(contentsOfFile:XCTUnwrap(value["path"].string),encoding:.utf8); for fact in ["repo: /work/api","agent: claude","from-turn: row-7","Base branch is main."] { XCTAssertTrue(text.contains(fact)) } }
    // TSCASE brief.test.ts:56
    func testBriefL56ExactTimestampSlugAndOnlyFile() throws { let dir = try scratch(); defer { try? FileManager.default.removeItem(at:dir) }; let directory = BackendDeckCoreBrief.specsDirectory(copilotRoot:dir),at = 1_786_959_720_000.0; let value = try BackendDeckCoreBrief.writeSpec(directory:directory,input:F.object([("title",.string("Fix the flaky auth test")),("brief",.string("x")),("cwd",.string("/work/api")),("provider",.null),("callId",.string("row-1")),("at",.number(at))]),ownership:.exclusive); let slug = BackendDeckCoreBrief.stamp(at:at)+"-fix-the-flaky-auth-test"; XCTAssertEqual(value["slug"],.string(slug)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),[slug+".md"]) }
    // TSCASE brief.test.ts:70
    func testBriefL70TitleCannotBecomePath() { XCTAssertEqual(BackendDeckCoreBrief.slugifyTitle("../../etc/passwd"),"etc-passwd"); XCTAssertEqual(BackendDeckCoreBrief.slugifyTitle("  "),"brief"); XCTAssertEqual(BackendDeckCoreBrief.slugifyTitle("A/B  test — round 2!"),"a-b-test-round-2") }
    // TSCASE brief.test.ts:115
    func testBriefL115TypeEchoThenSeparateReturn() async throws { let line = BackendDeckCoreBrief.deliveryLine("/spec.md"),fake = BackendDeckCoreTestPortToolsBriefFake { n in n < 3 ? "✶ Galloping…" : n == 3 ? "❯ " : "❯ " + String(line.prefix(60)) }; let value = try await BackendDeckCoreBrief.deliver(surface:fake,sessionID:"new-1",line:line,clock:fake.clock); XCTAssertEqual(value["delivered"],.bool(true)); XCTAssertEqual(fake.typed(),[line,"\r"]) }
    // TSCASE brief.test.ts:143
    func testBriefL143NoEchoClearsInsteadOfReturn() async throws { let fake = BackendDeckCoreTestPortToolsBriefFake { _ in "❯ " }; let value = try await BackendDeckCoreBrief.deliver(surface:fake,sessionID:"new-1",line:"go somewhere",pollMs:500,clock:fake.clock); XCTAssertEqual(value["delivered"],.bool(false)); XCTAssertTrue(value["reason"].string?.contains("never appeared on the session command line") == true); XCTAssertEqual(fake.typed(),["go somewhere","\u{15}"]) }
    // TSCASE brief.test.ts:167
    func testBriefL167ExistingComposerNeverTypedInto() async throws { let fake = BackendDeckCoreTestPortToolsBriefFake { _ in "❯ remind me to buy milk" }; let value = try await BackendDeckCoreBrief.deliver(surface:fake,sessionID:"new-1",line:"go",timeoutMs:2_000,pollMs:500,clock:fake.clock); XCTAssertTrue(fake.typed().isEmpty); XCTAssertEqual(value["delivered"],.bool(false)); XCTAssertTrue(value["reason"].string?.contains("unsent text") == true) }
    // TSCASE brief.test.ts:192
    func testBriefL192NoPromptDeadlineAndReason() async throws { let fake = BackendDeckCoreTestPortToolsBriefFake { _ in nil }; let value = try await BackendDeckCoreBrief.deliver(surface:fake,sessionID:"new-1",line:"go",pollMs:1_000,clock:fake.clock); XCTAssertEqual(value["delivered"],.bool(false)); XCTAssertTrue(value["reason"].string?.contains("never drew a prompt") == true); XCTAssertGreaterThanOrEqual(value["waitedMs"].number ?? 0,BackendDeckCoreBrief.deliveryTimeoutMs) }
    // TSCASE brief.test.ts:209
    func testBriefL209DeadSessionStopsImmediately() async throws { let fake = BackendDeckCoreTestPortToolsBriefFake(exit:1) { _ in "❯ " }; let value = try await BackendDeckCoreBrief.deliver(surface:fake,sessionID:"new-1",line:"go",clock:fake.clock); XCTAssertEqual(value["delivered"],.bool(false)); XCTAssertTrue(value["reason"].string?.contains("ended before") == true) }
    // TSCASE brief.test.ts:224
    func testBriefL224WholeBriefInstruction() { let line = BackendDeckCoreBrief.deliveryLine("/specs/x.md"); for phrase in ["/specs/x.md","whole brief","Read it before you start"] { XCTAssertTrue(line.contains(phrase)) } }
}
