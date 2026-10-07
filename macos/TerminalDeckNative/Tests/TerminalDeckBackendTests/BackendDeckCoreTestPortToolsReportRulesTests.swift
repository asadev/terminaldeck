import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckCoreTestPortToolsEvidenceFixture {
    static func trail(_ groups: [(String,Int,Bool?)],compactions: [Double] = [],partial: Bool = false,missingTime: Bool = false) -> BackendCostTranscript {
        var result = BackendCostTranscript(path:"fixture.jsonl",sessionID:"s",cwd:"/work/api"),seq = 0
        for (name,count,failed) in groups { for _ in 0..<count { seq += 1; result.toolTrail.append(.init(id:String(seq),name:name,at:missingTime ? 0 : Double(1_000_000+seq*1_000),failed:failed)) } }
        result.compactions = compactions.map { BackendDeckCoreTestPortToolsFixture.object([("at",.number($0)),("preTokens",.number(190_000)),("postTokens",.number(20_000)),("trigger",.string("auto"))]) }; result.truncated = partial; return result
    }
    static func input(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue { (try! BackendDeckCoreTestPortToolsFixture.json(#"{"attention":"running","attentionReason":"output-streaming","exitCode":null,"progress":null,"totalTokens":null,"changedFiles":0,"lastMessage":null}"#)).merging(patch) }
    static var looping: NativeRPCValue { BackendDeckCoreProgress.assess(trail([("Bash",10,true)])) }
}

@MainActor
final class BackendDeckCoreTestPortToolsProgressImportanceTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias E = BackendDeckCoreTestPortToolsEvidenceFixture
    private typealias P = BackendDeckCoreProgress
    private typealias I = BackendDeckCoreImportance
    // TSCASE progress.test.ts:34
    func testProgressL34VariedWorkHealthyAndThreeWrites() { let value = P.assess(E.trail([("Read",4,false),("Edit",3,false),("Bash",2,false),("Grep",1,false)])); XCTAssertEqual(value["verdict"],.string("ok")); XCTAssertEqual(value["findings"],.array([])); XCTAssertEqual(value["writes"],.number(3)) }
    // TSCASE progress.test.ts:43
    func testProgressL43ExactWarningBoundaryLoops() { let value = P.assess(E.trail([("Bash",P.repeatWarning,false)])); XCTAssertEqual(value["verdict"],.string("looping")); XCTAssertEqual(value["findings"].elements?.map { $0["signal"].string },["repeated-tool","no-writes"]) }
    // TSCASE progress.test.ts:49
    func testProgressL49OneBelowRepeatThresholdQuiet() { XCTAssertEqual(P.assess(E.trail([("Bash",P.repeatWarning-1,false)]))["verdict"],.string("ok")) }
    // TSCASE progress.test.ts:63
    func testProgressL63ProductiveRepetitionVersusStuck() { let productive = P.assess(E.trail([("Edit",P.repeatWarning+2,false)])),stuck = P.assess(E.trail([("Bash",P.repeatWarning+2,false)])); XCTAssertEqual(productive["verdict"],.string("suspect")); XCTAssertEqual(productive["writes"],.number(Double(P.repeatWarning+2))); XCTAssertEqual(stuck["verdict"],.string("looping")); XCTAssertEqual(stuck["writes"],.number(0)) }
    // TSCASE progress.test.ts:73
    func testProgressL73RepeatedFailureAtExactBoundary() { let value = P.assess(E.trail([("Bash",P.failureWarning,true),("Read",2,false)])); XCTAssertEqual(value["findings"].elements?.first?["signal"],.string("repeated-failure")); XCTAssertEqual(value["findings"].elements?.first?["tool"],.string("Bash")); XCTAssertEqual(value["failures"],.number(Double(P.failureWarning))) }
    // TSCASE progress.test.ts:82
    func testProgressL82FailureLeadsOverRepeatCount() { let value = P.assess(E.trail([("Read",P.repeatCritical,false),("Bash",P.failureWarning+1,true)])); XCTAssertEqual(value["findings"].elements?.first?["tool"],.string("Bash")); XCTAssertEqual(value["findings"].elements?.first?["signal"],.string("repeated-failure")) }
    // TSCASE progress.test.ts:90
    func testProgressL90OldThrashRollsOutAtThirty() { let value = P.assess(E.trail([("Bash",P.repeatCritical,false),("Edit",P.windowCalls,false)])); XCTAssertEqual(value["examined"],.number(Double(P.windowCalls))); XCTAssertEqual(value["verdict"],.string("suspect")); XCTAssertTrue((value["findings"].elements ?? []).allSatisfy { $0["tool"].string != "Bash" }) }
    // TSCASE progress.test.ts:101
    func testProgressL101CompactionImmediatelyUndone() { let value = P.assess(E.trail([("Read",14,false)],compactions:[1_012_500])); XCTAssertTrue(value["findings"].elements?.contains { $0["signal"].string == "compaction-echo" } == true) }
    // TSCASE progress.test.ts:113
    func testProgressL113CompactionMovedOn() { let value = P.assess(E.trail([("Read",12,false),("Edit",3,false)],compactions:[1_012_500])); XCTAssertFalse(value["findings"].elements?.contains { $0["signal"].string == "compaction-echo" } == true) }
    // TSCASE progress.test.ts:133
    func testProgressL133MissingAndNoToolTranscriptUnknown() { let none = P.assess(nil),empty = P.assess(E.trail([])); XCTAssertEqual(none["verdict"],.string("unknown")); XCTAssertTrue(none["unknownReason"].string?.contains("keeps no transcript") == true); XCTAssertTrue(P.sentence(none).contains("keeps no transcript")); XCTAssertEqual(empty["verdict"],.string("unknown")); XCTAssertTrue(empty["unknownReason"].string?.contains("not called a tool") == true) }
    // TSCASE progress.test.ts:144
    func testProgressL144PartialFlagSurvives() { XCTAssertEqual(P.assess(E.trail([("Read",3,false)],partial:true))["partial"],.bool(true)) }
    // TSCASE progress.test.ts:149
    func testProgressL149NoTimestampDoesNotDateSince1970() { XCTAssertEqual(P.assess(E.trail([("Bash",2,false)],missingTime:true))["spanMs"],.null) }
    // TSCASE progress.test.ts:161
    func testProgressL161UnknownResultNotSuccessOrFailure() { let value = P.assess(E.trail([("Bash",P.failureWarning+2,nil)])); XCTAssertEqual(value["failures"],.number(0)); XCTAssertFalse(value["findings"].elements?.contains { $0["signal"].string == "repeated-failure" } == true) }
    // TSCASE importance.test.ts:78
    func testImportanceL78AttentionFacts() throws { for (why,patch,expected) in [("blocked-on-you",#"{"attention":"blocked"}"#,true),("blocked-on-you",#"{"attention":"quiet"}"#,false),("failed",#"{"attentionReason":"process-failed","exitCode":1}"#,true),("failed",#"{"attentionReason":"process-exited","exitCode":0}"#,false),("finished",#"{"attention":"done"}"#,true),("finished",#"{"attention":"running"}"#,false)] { XCTAssertEqual(I.supports(why,input:E.input(try F.json(patch))),expected,why+patch) } }
    // TSCASE importance.test.ts:89
    func testImportanceL89LoopingAndFailuresComeFromProgress() { XCTAssertEqual(E.looping["verdict"],.string("looping")); for reason in ["looping","tool-failing"] { XCTAssertTrue(I.supports(reason,input:E.input(F.object([("progress",E.looping)])))); let healthy = P.assess(E.trail([("Read",1,false)])); XCTAssertFalse(I.supports(reason,input:E.input(F.object([("progress",healthy)])))) } }
    // TSCASE importance.test.ts:100
    func testImportanceL100NoTranscriptNeverClaimsLoopFailureCompaction() { let unknown = P.assess(nil); XCTAssertEqual(unknown["verdict"],.string("unknown")); for why in ["looping","tool-failing","compacted"] { XCTAssertFalse(I.supports(why,input:E.input(F.object([("progress",unknown)])))) }; XCTAssertFalse(I.supports("looping",input:E.input())) }
    // TSCASE importance.test.ts:114
    func testImportanceL114ReadWindowCompactionCounts() { let compacted = P.assess(E.trail([("Read",1,false)],compactions:[500,501])); XCTAssertTrue(I.supports("compacted",input:E.input(F.object([("progress",compacted)])))); XCTAssertFalse(I.supports("compacted",input:E.input(F.object([("progress",E.looping)])))) }
    // TSCASE importance.test.ts:120
    func testImportanceL120ExpensiveRequiresFloorSampleAndPeers() { let heavy = E.input(F.object([("totalTokens",.number(I.heavyMinTokens*I.heavyMultiple))])); XCTAssertTrue(I.supports("expensive",input:heavy,fleet:.init(medianTokens:I.heavyMinTokens,sample:I.heavyMinSample))); XCTAssertFalse(I.supports("expensive",input:E.input(F.object([("totalTokens",.number(I.heavyMinTokens-1))])),fleet:.init(medianTokens:1,sample:9))); XCTAssertFalse(I.supports("expensive",input:heavy,fleet:.init(medianTokens:I.heavyMinTokens,sample:I.heavyMinSample-1))); XCTAssertFalse(I.supports("expensive",input:heavy,fleet:.none)) }
    // TSCASE importance.test.ts:148
    func testImportanceL148NewestQuestionAndNoTruncatedText() { for (message,expected) in [("Should I use pnpm here?",true),("Done, tests pass.",false)] { XCTAssertEqual(I.supports("question-asked",input:E.input(F.object([("lastMessage",.string(message))]))),expected) }; XCTAssertFalse(I.supports("question-asked",input:E.input())) }
    // TSCASE importance.test.ts:136
    func testImportanceL136ThresholdsAgreeWithNativeAlertOwner() throws {
        var source = URL(fileURLWithPath:#filePath)
        for _ in 0..<3 { source.deleteLastPathComponent() }
        source.appendPathComponent("Sources/TerminalDeckBackend/BackendAlertsService.swift")
        let text = try String(contentsOf:source,encoding:.utf8)
        func number(_ pattern: String) throws -> Double {
            let regex = try NSRegularExpression(pattern:pattern),match = try XCTUnwrap(regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text))),range = try XCTUnwrap(Range(match.range(at:1),in:text))
            return try XCTUnwrap(Double(text[range].replacingOccurrences(of:"_",with:"")))
        }
        XCTAssertEqual(Double(I.heavyMinSample),try number(#"counted\.count >= ([0-9_]+)"#))
        XCTAssertEqual(I.heavyMultiple,try number(#"worst\.tokens / median >= ([0-9_]+)"#))
        XCTAssertEqual(I.heavyMinTokens,try number(#"worst\.tokens >= ([0-9_]+)"#))
    }
    // TSCASE importance.test.ts:156
    func testImportanceL156OnlyDecisionUnchecked() { XCTAssertTrue(I.uncheckedReasons.contains("decision")); XCTAssertTrue(I.supports("decision",input:E.input())); for reason in I.priority where reason != "decision" { XCTAssertFalse(I.uncheckedReasons.contains(reason),reason) } }
    // TSCASE importance.test.ts:168
    func testImportanceL168EveryClosedReasonHasBooleanPrecondition() { for reason in I.priority { let actual: Bool = I.supports(reason,input:E.input()); XCTAssertEqual(actual,reason == "decision",reason) } }
    // TSCASE importance.test.ts:181
    func testImportanceL181NothingWorthSayingHasNoReasons() { XCTAssertEqual(I.reasons(E.input()),[]) }
    // TSCASE importance.test.ts:185
    func testImportanceL185DecisionNeverProposedByApp() throws { let everything = E.input(try F.json(#"{"attention":"blocked","attentionReason":"question-unanswered","changedFiles":4,"lastMessage":"which branch?"}"#).setting("progress",E.looping)); XCTAssertFalse(I.reasons(everything).contains { $0["why"].string == "decision" }) }
    // TSCASE importance.test.ts:196
    func testImportanceL196SharedPriorityOrdering() throws { let input = E.input(try F.json(#"{"attention":"blocked","attentionReason":"question-unanswered","changedFiles":3}"#).setting("progress",E.looping)),reasons = I.reasons(input).compactMap { $0["why"].string },ranks = reasons.compactMap { I.priority.firstIndex(of:$0) }; XCTAssertEqual(reasons.first,"blocked-on-you"); XCTAssertEqual(ranks,ranks.sorted()) }
    // TSCASE importance.test.ts:210
    func testImportanceL210FactsNotAssessmentsInSentences() throws { let failed = I.reasons(E.input(try F.json(#"{"attention":"done","attentionReason":"process-failed","exitCode":137}"#))),changed = I.reasons(E.input(try F.json(#"{"changedFiles":1}"#))); XCTAssertEqual(failed.first?["why"],.string("failed")); XCTAssertTrue(failed.first?["detail"].string?.contains("137") == true); XCTAssertEqual(changed.first?["detail"],.string("1 uncommitted file in its folder.")) }
    // TSCASE importance.test.ts:221
    func testImportanceL221ZerosAndMissingRequestsDroppedFromMedian() { let value = BackendDeckCoreFleetContext.make([0,0,0,nil,100,200,300]); XCTAssertEqual(value.medianTokens,200); XCTAssertEqual(value.sample,3) }
    // TSCASE importance.test.ts:232
    func testImportanceL232NoFleetWhenNoPositiveReadings() { let datasets: [[Double?]] = [[],[nil,0]]; for rows in datasets { let value = BackendDeckCoreFleetContext.make(rows); XCTAssertNil(value.medianTokens); XCTAssertEqual(value.sample,BackendDeckCoreFleetContext.none.sample) } }
    // TSCASE importance.test.ts:239
    func testImportanceL239LoopSeverityExactThresholds() { XCTAssertEqual(I.loopSeverity(nil),0); XCTAssertEqual(I.loopSeverity(E.looping),P.repeatWarning); XCTAssertFalse(I.isCriticalLoop(E.looping)); XCTAssertTrue(I.isCriticalLoop(P.assess(E.trail([("Bash",P.repeatCritical,true)])))) }
}

final class BackendDeckCoreTestPortToolsReportFake: BackendDeckCoreReportSurface, @unchecked Sendable {
    var path: String? = "/store/a.jsonl",bytes = 4096.0
    var events: BackendCostTranscript = BackendDeckCoreTestPortToolsEvidenceFixture.trail([])
    var messages: [NativeRPCValue] = []
    var sessionRows: [NativeRPCValue] = [BackendDeckCoreTestPortToolsReportFake.view()]
    var totals: NativeRPCValue? = try! BackendDeckCoreTestPortToolsFixture.json(#"{"requests":12,"usage":{"input":100,"output":200,"cacheWrite5m":300,"cacheWrite1h":0,"cacheRead":400},"models":["claude-opus-5"],"compactions":1,"context":{"tokens":90000,"window":200000,"percent":45,"remaining":110000,"level":"ok"},"startedAt":1000,"lastActivityAt":20000}"#)
    var totalsSequence: [NativeRPCValue] = []
    var trailAsked: [NativeRPCValue] = [],totalsAsked: [String] = []
    static func view(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue { (try! BackendDeckCoreTestPortToolsFixture.json(#"{"id":"one","cwd":"/work/api","title":"api","provider":"claude","status":"working","windows":[],"statusSince":10000,"createdAt":1000,"exitCode":null,"resumed":false,"profileName":null,"startedByCopilot":false,"startedByApp":null,"attention":"running","attentionReason":"output-streaming","attentionForMs":0,"statusSource":"screen"}"#)).merging(patch) }
    func listSessions() -> [NativeRPCValue] { sessionRows }
    func transcriptsIn(cwd: String) -> [NativeRPCValue] { path.map { [BackendDeckCoreTestPortToolsFixture.object([("path",.string($0)),("sessionId",.string("cli-1")),("createdAt",.number(1000)),("modifiedAt",.number(2000)),("bytes",.number(bytes))])] } ?? [] }
    func transcriptBytes(path: String) -> Double { bytes }
    func readTranscriptFrom(path: String,fromByte: Double) -> [NativeRPCValue] { messages }
    func readToolTrail(path: String,windowBytes: Int) -> BackendDeckCoreReportTrail { trailAsked.append(BackendDeckCoreTestPortToolsFixture.object([("path",.string(path)),("windowBytes",.number(Double(windowBytes)))])); return .init(transcript:events,fileBytes:bytes,fromByte:max(0,bytes-Double(windowBytes))) }
    func transcriptTotals(path: String) -> NativeRPCValue? { totalsAsked.append(path); if !totalsSequence.isEmpty { return totalsSequence.removeFirst() }; return totals }
    func gitChanges(cwd: String) -> NativeRPCValue { try! BackendDeckCoreTestPortToolsFixture.json(#"{"repo":true,"root":"/work/api","branch":"main","ahead":0,"behind":0,"files":[{"path":"src/a.ts","group":"unstaged","kind":"modified","insertions":4,"deletions":2,"binary":false}],"reason":null}"#) }
    func fileModifiedAt(path: String) -> Double? { 5000 }
}

@MainActor
final class BackendDeckCoreTestPortToolsReportTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias R = BackendDeckCoreReports
    private typealias Fake = BackendDeckCoreTestPortToolsReportFake
    // TSCASE report.test.ts:157
    func testReportL157EvidencePointersAndWholeSpend() async throws { let fake = Fake(); fake.bytes = 9_000_000; let value = try await R.session(surface:fake,session:Fake.view()); XCTAssertEqual(value["transcript"],try F.json(#"{"path":"/store/a.jsonl","bytes":9000000,"parsedFrom":6902848,"partial":true,"basis":"only-one","ambiguous":false}"#)); XCTAssertEqual(value["changes"]["paths"],.array([.string("src/a.ts")])); XCTAssertEqual(value["spend"]["requests"],.number(12)); XCTAssertEqual(value["spend"]["totalTokens"],.number(1000)) }
    // TSCASE report.test.ts:178
    func testReportL178TrailWindowAndWholeTotalsReads() async throws { let fake = Fake(); _ = try await R.session(surface:fake,session:Fake.view()); XCTAssertEqual(fake.trailAsked,[F.object([("path",.string("/store/a.jsonl")),("windowBytes",.number(Double(R.trailWindowBytes)))])]); XCTAssertEqual(fake.totalsAsked,["/store/a.jsonl"]) }
    // TSCASE report.test.ts:187
    func testReportL187OversizedTranscriptTotalsRefused() async throws { let fake = Fake(); fake.bytes = Double(R.totalsMaxBytes)+1; let value = try await R.session(surface:fake,session:Fake.view()); XCTAssertTrue(fake.totalsAsked.isEmpty); XCTAssertTrue(value["spend"]["skipped"].string?.contains("too large to total") == true) }
    // TSCASE report.test.ts:194
    func testReportL194NoTranscriptIsUnknown() async throws { let fake = Fake(); fake.path = nil; let value = try await R.session(surface:fake,session:Fake.view(F.object([("provider",.string("shell"))]))); XCTAssertEqual(value["transcript"],.null); XCTAssertEqual(value["spend"],.null); XCTAssertEqual(value["progress"]["verdict"],.string("unknown")) }
    // TSCASE report.test.ts:202
    func testReportL202NewestAgentMessagePromoted() async throws { let fake = Fake(); fake.messages = try F.json(#"[{"id":"you:1","role":"you","at":1,"text":"do the thing","truncated":false},{"id":"agent:2","role":"agent","at":2,"text":"starting","truncated":false},{"id":"agent:3","role":"agent","at":3,"text":"done, tests pass","truncated":false}]"#).requireArray("messages"); let value = try await R.session(surface:fake,session:Fake.view()); XCTAssertEqual(value["lastMessage"]["text"],.string("done, tests pass")) }
    // TSCASE report.test.ts:214
    func testReportL214LongLastMessageCarriesTruncation() async throws { let fake = Fake(); fake.messages = [F.object([("id",.string("agent:2")),("role",.string("agent")),("at",.number(2)),("text",.string(String(repeating:"z",count:R.maxLastMessageChars*2))),("truncated",.bool(false))])]; let value = try await R.session(surface:fake,session:Fake.view()); XCTAssertEqual(value["lastMessage"]["truncated"],.bool(true)); XCTAssertEqual(value["lastMessage"]["text"].string?.utf16.count,R.maxLastMessageChars+1) }
    // TSCASE report.test.ts:230
    func testReportL230BlockedPersonLeadsSentence() async throws { let value = try await R.session(surface:Fake(),session:Fake.view(try F.json(#"{"attention":"blocked","attentionReason":"question-unanswered","attentionForMs":1500000}"#))); XCTAssertTrue(value["verdict"].string?.hasPrefix("Blocked on you for 25 min") == true) }
    // TSCASE report.test.ts:239
    func testReportL239FailedExitLeads() async throws { let value = try await R.session(surface:Fake(),session:Fake.view(try F.json(#"{"attention":"done","attentionReason":"process-failed","exitCode":1,"status":"exited"}"#))); XCTAssertTrue(value["verdict"].string?.hasPrefix("Exited 1") == true) }
    // TSCASE report.test.ts:248
    func testReportL248FinishedNamesDiskChanges() async throws { let value = try await R.session(surface:Fake(),session:Fake.view(try F.json(#"{"attention":"done","attentionReason":"turn-finished","status":"completed"}"#))); XCTAssertTrue(value["verdict"].string?.contains("Finished — 1 file changed") == true) }
    // TSCASE report.test.ts:259
    func testReportL259FleetCountsAndExactHeadline() async throws { let rows = [Fake.view(try F.json(#"{"id":"a","attention":"blocked"}"#)),Fake.view(try F.json(#"{"id":"b","attention":"done","exitCode":2,"status":"exited"}"#)),Fake.view(try F.json(#"{"id":"c"}"#))],value = try await R.fleet(surface:Fake(),sessions:rows,now:100_000); XCTAssertEqual(value["totals"]["sessions"],.number(3)); XCTAssertEqual(value["totals"]["blocked"],.number(1)); XCTAssertEqual(value["totals"]["failed"],.number(1)); XCTAssertEqual(value["totals"]["running"],.number(1)); XCTAssertEqual(value["headline"],.string("3 sessions: 1 waiting on you, 1 failed, 1 still working.")) }
    // TSCASE report.test.ts:274
    func testReportL274ReadsFourAndNamesEightOmitted() async throws { let rows = (0..<12).map { Fake.view(F.object([("id",.string("s\($0)"))])) },value = try await R.fleet(surface:Fake(),sessions:rows,limit:4,now:100_000); XCTAssertEqual(value["reports"].elements?.count,4); XCTAssertEqual(value["omitted"],.number(8)) }
    // TSCASE report.test.ts:282
    func testReportL282OnlyActiveWindowRows() async throws { let rows = [Fake.view(try F.json(#"{"id":"recent","statusSince":95000,"createdAt":95000}"#)),Fake.view(try F.json(#"{"id":"ancient","statusSince":1000,"createdAt":1000}"#))],value = try await R.fleet(surface:Fake(),sessions:rows,since:90_000,now:100_000); XCTAssertEqual(value["reports"].elements?.map { $0["sessionId"] },[.string("recent")]) }
    // TSCASE report.test.ts:295
    func testReportL295NoSessionsExactHeadline() async throws { let value = try await R.fleet(surface:Fake(),sessions:[],now:100_000); XCTAssertEqual(value["headline"],.string("Nothing has run in that window.")) }
    // TSCASE report.test.ts:301
    func testReportL301FleetSecondPassExpensiveAgainstPeers() async throws { let fake = Fake(),rows = (0..<6).map { Fake.view(F.object([("id",.string("s\($0)")),("cwd",.string("/work/p\($0)"))])) }; fake.sessionRows = rows; fake.totalsSequence = [8_000_000.0,250_000,250_000,250_000,250_000,250_000].map { total in let share = total/4; return fake.totals!.setting("usage",F.object([("input",.number(share)),("output",.number(share)),("cacheWrite5m",.number(share)),("cacheWrite1h",.number(0)),("cacheRead",.number(total-share*3))])) }; let value = try await R.fleet(surface:fake,sessions:rows,now:100_000),reports = try XCTUnwrap(value["reports"].elements); XCTAssertEqual(reports[0]["spend"]["totalTokens"],.number(8_000_000)); XCTAssertTrue(reports[0]["reasons"].elements?.contains { $0["why"].string == "expensive" } == true); XCTAssertFalse(reports[1]["reasons"].elements?.contains { $0["why"].string == "expensive" } == true) }
    // TSCASE report.test.ts:372 -- expands all 3 source rows.
    func testReportL372VerdictReasonsRows() async throws { let rows = [("blocked on a person",#"{"attention":"blocked","attentionReason":"question-unanswered","attentionForMs":1200000}"#,"blocked-on-you","Blocked on you"),("died with a non-zero exit",#"{"attention":"done","attentionReason":"process-failed","status":"exited","exitCode":2}"#,"failed","Exited 2"),("finished cleanly",#"{"attention":"done","attentionReason":"process-exited","status":"exited","exitCode":0}"#,"finished","Finished")]; for (name,patch,leads,opening) in rows { let value = try await R.session(surface:Fake(),session:Fake.view(F.json(patch))); XCTAssertEqual(value["reasons"].elements?.first?["why"],.string(leads),name); XCTAssertTrue(value["verdict"].string?.hasPrefix(opening) == true,name) } }
    // TSCASE report.test.ts:380
    func testReportL380LoopingOutranksFilesAndMatchesSentence() async throws { let fake = Fake(); fake.events = BackendDeckCoreTestPortToolsEvidenceFixture.trail([("Bash",12,true)]); let value = try await R.session(surface:fake,session:Fake.view()); XCTAssertEqual(value["progress"]["verdict"],.string("looping")); XCTAssertEqual(value["reasons"].elements?.first?["why"],.string("looping")); XCTAssertTrue(value["verdict"].string?.hasPrefix("Looks stuck") == true) }
}
