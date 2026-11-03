import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Assertions are ready, but the concrete production factory has no fake scan,
/// preview, clock or helper door. Each case throws the exact missing dependency
/// until its owner supplies SourceDoor.adapter. This is blocked, never a skip.
@MainActor
final class BackendRemoteServeMachinesTestsPanelsArtifacts: XCTestCase {
    private typealias F = BackendRemoteServeMachinesTestsPanelsArtifactsFixtures
    private func adapter() throws -> BackendRemoteServeMachinesTestsPanelsArtifactsAdapter { try BackendRemoteServeMachinesTestsPanelsArtifactsSourceDoor.require() }
    private func read(_ rig: BackendRemoteServeMachinesTestsPanelsArtifactsRig, scope: String? = nil, query: String? = nil) async throws -> NativeRPCValue {
        let panel = try await adapter().provider(rig)
        return try await panel.read(.init(path: F.root, scope: scope, query: query), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func act(_ rig: BackendRemoteServeMachinesTestsPanelsArtifactsRig, _ action: String, _ id: String? = nil) async throws -> NativeRPCValue {
        let panel = try await adapter().provider(rig), run = try XCTUnwrap(panel.act)
        return try await run(.init(panel: .init(path: F.root, scope: nil, query: nil), action: action, id: id, fields: [:]), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func rows(_ payload: NativeRPCValue) -> [NativeRPCValue] { payload["rows"].elements ?? [] }
    private func scopes(_ payload: NativeRPCValue) -> [NativeRPCValue] { payload["scopes"].elements ?? [] }
    private func lit(_ payload: NativeRPCValue) -> [String] { scopes(payload).filter { $0["on"].bool == true }.compactMap { $0["label"].string } }
    private func id(_ row: NativeRPCValue) throws -> [String] { try XCTUnwrap(row["id"].string).split(separator: " ", maxSplits: 4).map(String.init) }
    private func tokens(_ payload: NativeRPCValue) throws -> [String] { try rows(payload).map { try id($0)[0] } }
    func testDefaultScopeIsMadeAcrossEverySession() throws {
        let adapter = try adapter(); XCTAssertEqual(adapter.parseScope(nil), F.scope("made", "all", nil)); XCTAssertEqual(adapter.parseScope(""), F.scope("made", "all", nil))
    }
    func testScopeOrderIsFlexibleAndFirstDimensionWins() throws {
        let adapter = try adapter(); XCTAssertEqual(adapter.parseScope("session:abc changed project"), F.scope("changed", "project", "abc")); XCTAssertEqual(adapter.parseScope("changed made all")["kind"].string, "changed")
    }
    func testUnknownScopeTokenIsIgnored() throws { XCTAssertEqual(try adapter().parseScope("changed sortBy:size"), F.scope("changed", "all", nil)) }
    func testEncodingTappedTokenFirstKeepsBothLiveChipIDsDistinct() throws {
        let adapter = try adapter(), state = adapter.parseScope("made all")
        XCTAssertEqual(adapter.encodeScope(state, "made"), "made all session:*"); XCTAssertEqual(adapter.encodeScope(state, "all"), "all made session:*")
        XCTAssertNotEqual(adapter.encodeScope(state, "made"), adapter.encodeScope(state, "all"))
    }
    func testMadeFilesAreNewestFirstAndCarryRelativePathTitle() async throws {
        let payload = try await read(.init(F.scanned(F.three)))
        XCTAssertEqual(payload["path"].string, F.root); XCTAssertEqual(try tokens(payload), ["index.html", "src/hero.png"])
        XCTAssertEqual(rows(payload)[0]["title"].string, "index.html"); XCTAssertEqual(rows(payload)[0]["value"].string, "1h ago"); XCTAssertEqual(rows(payload)[0]["status"].string, "made"); XCTAssertEqual(rows(payload)[1]["title"].string, "src/hero.png")
    }
    func testRowsNameWritingSessionOrUseShortID() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); await rig.names(["session-one": "Rewrite the hero"])
        let payload = try await read(rig); XCTAssertEqual(rows(payload)[0]["detail"].string, "Rewrite the hero"); XCTAssertEqual(rows(payload)[1]["detail"].string, "session session-")
    }
    func testQueryMatchesWholeRelativePath() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three))
        let hero = try await read(rig, query: "hero"), folder = try await read(rig, query: "src/"), index = try await read(rig, query: "index")
        XCTAssertEqual(try tokens(hero), ["src/hero.png"]); XCTAssertEqual(try tokens(folder), ["src/hero.png"]); XCTAssertEqual(rows(index).count, 1)
    }
    func testMadeAndChangedAreSeparateLists() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)), made = try await read(rig, scope: "made all"), changed = try await read(rig, scope: "changed all")
        XCTAssertEqual(try tokens(made), ["index.html", "src/hero.png"]); XCTAssertEqual(try tokens(changed), ["src/server.html"]); XCTAssertEqual(rows(changed)[0]["status"].string, "changed")
    }
    func testBreadthReachesScannerWith600ArtifactBudget() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); _ = try await read(rig); _ = try await read(rig, scope: "project made")
        let calls = await rig.calls; XCTAssertEqual(calls.map { $0.scope.rawValue }, ["all", "project"]); XCTAssertEqual(calls[0].maxArtifacts, 600)
    }
    func testSessionFilterPreservesSelectedKind() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three))
        let made = try await read(rig, scope: "session:session-two made all"), changed = try await read(rig, scope: "session:session-two changed all")
        XCTAssertEqual(try tokens(made), ["src/hero.png"]); XCTAssertEqual(try tokens(changed), ["src/server.html"])
    }
    func testHostScanBudgetOverrideCannotPinScopeControl() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); await rig.overrideScan(); _ = try await read(rig, scope: "all made")
        let calls = await rig.calls; XCTAssertEqual(calls[0].timeBudgetMilliseconds, 2_000); XCTAssertEqual(calls[0].scope, .all)
    }
    func testOnlyPrototypesAreSentWithNoMarkdownSourceOrOtherRows() async throws {
        let payload = try await read(.init(F.scanned(F.mixed))); XCTAssertEqual(try tokens(payload), ["demo/index.html", "shots/hero.png"])
        XCTAssertFalse(rows(payload).contains { $0["title"].string?.hasSuffix(".md") == true }); XCTAssertFalse(rows(payload).contains { $0["title"].string?.hasSuffix(".markdown") == true })
        XCTAssertFalse(try rows(payload).contains { try id($0)[1] == "text" }); XCTAssertFalse(try rows(payload).contains { try id($0)[1] == "other" })
    }
    func testPrototypeCountMatchesFilteredRows() async throws {
        let payload = try await read(.init(F.scanned(F.mixed))); XCTAssertEqual(rows(payload).count, 2); XCTAssertTrue(payload["note"].string?.contains("2 made here") == true); XCTAssertFalse(payload["note"].string?.contains("6") == true)
    }
    func testSearchCannotRestoreExcludedProse() async throws {
        let payload = try await read(.init(F.scanned(F.mixed)), query: "PLAN"); XCTAssertEqual(rows(payload), []); XCTAssertEqual(payload["note"].string, "Nothing matches that filter.")
    }
    func testProseOnlyScanExplainsEmptyPrototypePage() async throws {
        let payload = try await read(.init(F.scanned(F.prose).setting("sessionsScanned", .number(15))))
        XCTAssertEqual(rows(payload), []); XCTAssertEqual(payload["note"].string, "No prototypes in /work/deck — 4 files of prose or source, which is what Files is for.")
    }
    func testDeletedPrototypeSurvivesButDeletedMarkdownDoesNot() async throws {
        let page = F.artifact("demo/index.html", gone: true), prose = F.artifact("PLAN.md", gone: true), adapter = try adapter()
        XCTAssertTrue(adapter.isArtifact(page)); XCTAssertFalse(adapter.isArtifact(prose))
        let payload = try await read(.init(F.scanned([page, prose]))); XCTAssertEqual(try tokens(payload), ["demo/index.html"])
        XCTAssertEqual(try id(rows(payload)[0])[1], "gone"); XCTAssertTrue(rows(payload)[0]["detail"].string?.contains("not on disk") == true)
    }
    func testSessionChipCountsExcludeProseAndEmptySessions() async throws {
        let payload = try await read(.init(F.scanned([F.artifact("demo/index.html"), F.artifact("PLAN.md"), F.artifact("shots/hero.png", sessions: ["session-two"]), F.artifact("notes/log.md", sessions: ["session-three"])], sessions: [F.session("session-one", hours: 1, files: 2), F.session("session-two", hours: 2, files: 1), F.session("session-three", hours: 3, files: 1)])))
        let labels = scopes(payload).compactMap { $0["label"].string }; XCTAssertTrue(labels.contains("1h ago · 1 file")); XCTAssertTrue(labels.contains("2h ago · 1 file")); XCTAssertFalse(labels.contains { $0.hasPrefix("3h ago") })
    }
    func testExactlyOneChipPerDimensionIsLitWithUniqueIDs() async throws {
        let payload = try await read(.init(F.scanned(F.three, sessions: [F.session("session-one", hours: 1, files: 2), F.session("session-two", hours: 2, files: 2)])), scope: "changed project session:session-two")
        XCTAssertEqual(lit(payload), ["Changed", "This project's sessions", "2h ago · 2 files"]); XCTAssertEqual(lit(payload).count, 3)
        let ids = scopes(payload).compactMap { $0["id"].string }; XCTAssertFalse(ids.contains("")); XCTAssertEqual(Set(ids).count, scopes(payload).count)
    }
    func testEachChipEncodesTheWholeCurrentState() async throws {
        let payload = try await read(.init(F.scanned(F.three)), scope: "changed project")
        XCTAssertEqual(scopes(payload).first { $0["label"].string == "Every session" }?["id"].string, "all changed session:*")
        XCTAssertEqual(scopes(payload).first { $0["label"].string == "Made here" }?["id"].string, "made project session:*")
    }
    func testSessionChipGroupExistsOnlyWithAChoice() async throws {
        let one = try await read(.init(F.scanned(F.three))); XCTAssertEqual(scopes(one).compactMap { $0["label"].string }, ["Made here", "Changed", "This project's sessions", "Every session"])
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three, sessions: [F.session("session-one", hours: 1, files: 2), F.session("session-two", hours: 26, files: 1)])); await rig.names(["session-one": "Rewrite the hero"])
        let many = try await read(rig), labels = scopes(many).compactMap { $0["label"].string }; XCTAssertTrue(labels.contains("All sessions")); XCTAssertTrue(labels.contains("Rewrite the hero · 2 files")); XCTAssertTrue(labels.contains("1d ago · 1 file"))
    }
    func testSelectedSessionChipSurvivesTheScannerDroppingIt() async throws {
        let payload = try await read(.init(F.scanned(F.three)), scope: "session:rolled-past made all")
        XCTAssertTrue(scopes(payload).contains { $0["label"].string == "session rolled-p" }); XCTAssertEqual(lit(payload), ["Made here", "Every session", "session rolled-p"])
        XCTAssertTrue(scopes(payload).contains { $0["label"].string == "All sessions" }); XCTAssertEqual(rows(payload), [])
    }
    func testRowIDHasTokenKindBytesNoPreviewAndAbsolutePath() async throws {
        let payload = try await read(.init(F.scanned([F.artifact("demo/index.html")]))); XCTAssertEqual(try id(rows(payload)[0]), ["demo/index.html", "page", "400", "-", "/work/deck/demo/index.html"])
    }
    func testKindRoutesToCorrectViewerIncludingGone() throws {
        let adapter = try adapter()
        for (path, expected) in [("demo/index.html", "page"), ("art/logo.PNG", "image"), ("art/logo.svg", "image"), ("notes/walkthrough.mp4", "media"), ("src/hero.tsx", "text"), ("build/app.zip", "other")] { XCTAssertEqual(adapter.kindOf(F.artifact(path)), expected) }
        XCTAssertEqual(adapter.kindOf(F.artifact("scratch.txt", gone: true)), "gone")
    }
    func testExtensionlessFilesUseTextViewer() throws { let adapter = try adapter(); for path in ["Makefile", ".gitignore", "scripts/deploy"] { XCTAssertEqual(adapter.kindOf(F.artifact(path)), "text") } }
    func testRowsOfferNoFakeOpenInFilesAction() async throws { let payload = try await read(.init(F.scanned(F.three))); XCTAssertTrue(rows(payload).allSatisfy { !$0.has("actions") }) }
    func testTokensAreBoundedStableAndUnambiguous() throws {
        let adapter = try adapter(); XCTAssertEqual(adapter.tokenFor("PLAN.md"), "PLAN.md")
        let deep = String(repeating: "nested/", count: 30) + "index.ts", token = adapter.tokenFor(deep)
        XCTAssertGreaterThan(deep.count, 128); XCTAssertLessThanOrEqual(token.utf8.count, 128); XCTAssertEqual(adapter.tokenFor(deep), token)
        XCTAssertFalse(adapter.tokenFor("my notes.md").contains(" ")); XCTAssertNotEqual(adapter.tokenFor("my notes.md"), adapter.tokenFor("my notes.txt"))
    }
    func testAbsolutePathLastPreservesNamesWithSpaces() throws {
        let id = try adapter().rowIDFor(F.artifact("design notes/read me.html"), F.root, nil).split(separator: " ", maxSplits: 4).map(String.init)
        XCTAssertEqual(id[4], "/work/deck/design notes/read me.html"); XCTAssertEqual(id[1], "page")
    }
    func testPreviewRegistersRedirectAndPortOnEveryRow() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)), payload = try await act(rig, "preview", "index.html")
        XCTAssertEqual(payload["notice"].string, "Serving index.html from this machine."); let links = await rig.links
        XCTAssertEqual(links, [[F.root, "index.html", "index.html"]]); XCTAssertEqual(try rows(payload).map { try id($0)[3] }, ["41000.sEcReT0123456789", "41000.sEcReT0123456789"])
    }
    func testStopServingExistsOnlyWhileServingAndClearsRowPort() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)), quiet = try await read(rig); XCTAssertFalse(quiet.has("actions"))
        let serving = try await act(rig, "preview", "index.html"); XCTAssertEqual(serving["actions"].elements?.map { $0["id"].string }, ["stop"]); XCTAssertEqual(serving["actions"].elements?.first?["kind"].string, "destructive")
        let stopped = try await act(rig, "stop"); XCTAssertEqual(stopped["notice"].string, "Nothing is being served now."); XCTAssertFalse(stopped.has("actions")); XCTAssertTrue(try rows(stopped).allSatisfy { try id($0)[3] == "-" })
    }
    func testGonePreviewNamesFileAndStartsNoServer() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned([F.artifact("scratch.html", gone: true)])), payload = try await act(rig, "preview", "scratch.html")
        XCTAssertEqual(payload["notice"].string, "scratch.html is no longer on disk."); let held = await rig.handle; XCTAssertNil(held)
    }
    func testMissingTapAndUnknownActionHaveSpecificNotices() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)), missing = try await act(rig, "preview", "deleted.html"), unknown = try await act(rig, "rename", "index.html")
        XCTAssertEqual(missing["notice"].string, "deleted.html is not in this list any more."); XCTAssertEqual(unknown["notice"].string, "This panel has nothing called rename."); XCTAssertEqual(rows(unknown).count, 2)
    }
    func testBindFailureIsNoticeOverStillWorkingList() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); await rig.fail(serve: "listen EADDRINUSE")
        let payload = try await act(rig, "preview", "index.html"); XCTAssertEqual(payload["notice"].string, "index.html could not be served: listen EADDRINUSE"); XCTAssertEqual(rows(payload).count, 2)
    }
    func testUnavailablePreviewQueryStillDrawsNoPreviewRows() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); await rig.fail(current: "no preview on this host")
        let payload = try await read(rig); XCTAssertEqual(rows(payload).count, 2); XCTAssertEqual(try id(rows(payload)[0])[3], "-")
    }
    func testRowCapReportsAllOlderMatchesAndLogsToHost() async throws {
        let many = (0..<231).map { F.artifact("shots/\($0).png", lastAt: F.now - Double($0) * 1000) }, rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(many))
        let payload = try await read(rig); XCTAssertEqual(rows(payload).count, 200)
        XCTAssertTrue(payload["note"].string?.contains("31 older matches not sent to this phone") == true); XCTAssertTrue(payload["note"].string?.contains("200 of 231 made here") == true)
        XCTAssertTrue(rig.log.values.contains("artifacts panel: 231 rows for /work/deck cut to 200"))
    }
    func testScannerTruncationIsPassedOn() async throws { let payload = try await read(.init(F.scanned(F.three).setting("truncated", .bool(true)))); XCTAssertTrue(payload["note"].string?.contains("older work not read") == true) }
    func testEmptyHistoryNamesFolderReadEvidenceAndOutsideChanges() async throws {
        let snapshot = F.scanned([], sessions: []).setting("sessionsScanned", .number(15)).setting("outsideProject", .number(40))
        let payload = try await read(.init(snapshot), scope: "project made"), note = payload["note"].string ?? ""
        for expected in [F.root, "15 sessions read", "40 changes to files outside it", "Every session"] { XCTAssertTrue(note.contains(expected), expected) }; XCTAssertEqual(rows(payload), [])
    }
    func testEmptyFilterAndEmptyKindHaveDifferentNotices() async throws {
        let filtered = try await read(.init(F.scanned(F.three)), query: "nope"), noneMade = try await read(.init(F.scanned([F.three[2]])))
        XCTAssertEqual(filtered["note"].string, "Nothing matches that filter."); XCTAssertTrue(noneMade["note"].string?.contains("What it edited is under Changed") == true)
    }
    func testScanFailureKeepsChosenChipsPathAndExactReason() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); await rig.fail(scan: "EACCES: permission denied, scandir")
        let payload = try await read(rig, scope: "project changed"); XCTAssertEqual(payload["note"].string, "This project's history could not be read: EACCES: permission denied, scandir")
        XCTAssertEqual(rows(payload), []); XCTAssertEqual(payload["path"].string, F.root); XCTAssertEqual(lit(payload), ["Changed", "This project's sessions"])
    }
    func testSessionNameFailureFallsBackToShortIDWithoutScanError() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsArtifactsRig(F.scanned(F.three)); await rig.fail(names: "no window on this host")
        let payload = try await read(rig); XCTAssertEqual(rows(payload).count, 2); XCTAssertEqual(rows(payload)[0]["detail"].string, "session session-"); XCTAssertFalse(payload["note"].string?.contains("could not be read") == true)
    }
}

struct BackendRemoteServeMachinesTestsPanelsArtifactsAdapter: Sendable {
    let provider: @Sendable (BackendRemoteServeMachinesTestsPanelsArtifactsRig) async throws -> BackendRemotePanelProvider
    let parseScope: @Sendable (String?) -> NativeRPCValue
    let encodeScope: @Sendable (NativeRPCValue, String) -> String
    let isArtifact: @Sendable (NativeRPCValue) -> Bool
    let kindOf: @Sendable (NativeRPCValue) -> String
    let tokenFor: @Sendable (String) -> String
    let rowIDFor: @Sendable (NativeRPCValue, String, NativeRPCValue?) -> String
}
/// The production panel (BackendRemotePanelArtifacts) with only its scan/preview/names/clock/log seams faked (artifacts.test.ts deps).
@MainActor
enum BackendRemoteServeMachinesTestsPanelsArtifactsSourceDoor {
    static func require() throws -> BackendRemoteServeMachinesTestsPanelsArtifactsAdapter {
        typealias P = BackendRemotePanelArtifacts
        let now = BackendRemoteServeMachinesTestsPanelsArtifactsFixtures.now
        return .init(provider: { rig in
            let overrides = await rig.scanOverrides
            return P.provider(P.Seams(
                list: { path, options, _ in try await rig.list(path, options) },
                current: { _ in try await rig.current().map { BackendArtifactsPreview.Handle(port: Int($0["port"].number ?? 0), secret: $0["secret"].string ?? "") } },
                serve: { root, _ in _ = try await rig.serve(root) },
                link: { root, token, relative in await rig.link(root, token, relative) },
                stop: { _ in await rig.stop() },
                sessionNames: { try await rig.names() },
                scan: overrides, now: { now }, log: { rig.log.write($0) }))
        }, parseScope: { P.parseScope($0) }, encodeScope: { P.encodeScope($0, $1) }, isArtifact: { P.isArtifact($0) }, kindOf: { P.kindOf($0) },
           tokenFor: { P.tokenFor($0) }, rowIDFor: { P.rowIDFor($0, $1, $2) })
    }
}
enum BackendRemoteServeMachinesTestsPanelsArtifactsFixtures {
    static let root = "/work/deck", hour = 3_600_000.0
    static let now = ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z")!.timeIntervalSince1970 * 1000
    static var three: [NativeRPCValue] { [artifact("index.html"), artifact("src/hero.png", lastAt: now - 2 * hour, sessions: ["session-two"]), artifact("src/server.html", lastAt: now - 3 * hour, writes: 0, edits: 5, sessions: ["session-two", "session-one"])] }
    static var prose: [NativeRPCValue] { [artifact("PLAN.md", lastAt: now - hour / 2), artifact("notes/README.markdown"), artifact("src/server.ts", writes: 0, edits: 5), artifact("build/app.zip")] }
    static var mixed: [NativeRPCValue] { [artifact("PLAN.md", lastAt: now - hour / 2), artifact("demo/index.html"), artifact("notes/README.markdown", lastAt: now - 2 * hour), artifact("src/hero.tsx", lastAt: now - 3 * hour), artifact("build/app.zip", lastAt: now - 4 * hour), artifact("shots/hero.png", lastAt: now - 5 * hour)] }
    static func scope(_ kind: String, _ breadth: String, _ session: String?) -> NativeRPCValue { .object([.init("kind", .string(kind)), .init("breadth", .string(breadth)), .init("session", session.map(NativeRPCValue.string) ?? .null)]) }
    static func session(_ id: String, hours: Double, files: Int) -> NativeRPCValue { .object([.init("sessionId", .string(id)), .init("at", .number(now - hours * hour)), .init("files", .number(Double(files)))]) }
    static func artifact(_ relative: String, lastAt: Double? = nil, writes: Int = 1, edits: Int = 0, sessions: [String] = ["session-one"], gone: Bool = false) -> NativeRPCValue {
        .object([.init("relPath", .string(relative)), .init("name", .string(relative.split(separator: "/").last.map(String.init) ?? relative)), .init("firstAt", .number(now - 3 * hour)), .init("lastAt", .number(lastAt ?? now - hour)), .init("writes", .number(Double(writes))), .init("edits", .number(Double(edits))), .init("lastChars", .number(120)), .init("lastTool", .string(writes == 0 ? "Edit" : "Write")), .init("sessionIds", .array(sessions.map(NativeRPCValue.string))), .init("onDisk", gone ? .null : .object([.init("bytes", .number(400)), .init("modifiedAt", .number(now - hour))]))])
    }
    static func scanned(_ artifacts: [NativeRPCValue], sessions: [NativeRPCValue]? = nil) -> NativeRPCValue {
        .object([.init("root", .string(root)), .init("scope", .string("all")), .init("artifacts", .array(artifacts)), .init("sessions", .array(sessions ?? [session("session-one", hours: 1, files: artifacts.count)])), .init("sessionsScanned", .number(4)), .init("outsideProject", .number(0)), .init("truncated", .bool(false)), .init("cancelled", .bool(false)), .init("tookMs", .number(12))])
    }
}
struct BackendRemoteServeMachinesTestsPanelsArtifactsError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
final class BackendRemoteServeMachinesTestsPanelsArtifactsLog: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: [String] = []
    func write(_ text: String) { lock.lock(); recorded.append(text); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}
actor BackendRemoteServeMachinesTestsPanelsArtifactsRig {
    nonisolated let log = BackendRemoteServeMachinesTestsPanelsArtifactsLog()
    private let snapshot: NativeRPCValue
    private var scanError: String?, serveError: String?, currentError: String?, namesError: String?, sessionNames: [String: String] = [:]
    private(set) var calls: [BackendArtifactScanOptions] = [], links: [[String]] = [], handle: NativeRPCValue?, scanOverrides: BackendArtifactScanOptions?
    init(_ snapshot: NativeRPCValue) { self.snapshot = snapshot }
    func names(_ names: [String: String]) { sessionNames = names }
    func fail(scan: String? = nil, serve: String? = nil, current: String? = nil, names: String? = nil) { scanError = scan; serveError = serve; currentError = current; namesError = names }
    func overrideScan() { var options = BackendArtifactScanOptions(); options.timeBudgetMilliseconds = 2_000; options.scope = .project; scanOverrides = options }
    func list(_ path: String, _ options: BackendArtifactScanOptions) throws -> NativeRPCValue { guard path == BackendRemoteServeMachinesTestsPanelsArtifactsFixtures.root else { throw BackendRemoteServeMachinesTestsPanelsArtifactsError(message: "wrong root") }; calls.append(options); if let scanError { throw BackendRemoteServeMachinesTestsPanelsArtifactsError(message: scanError) }; return snapshot }
    func names() throws -> [String: String] { if let namesError { throw BackendRemoteServeMachinesTestsPanelsArtifactsError(message: namesError) }; return sessionNames }
    func serve(_ root: String) throws -> NativeRPCValue { guard root == BackendRemoteServeMachinesTestsPanelsArtifactsFixtures.root else { throw BackendRemoteServeMachinesTestsPanelsArtifactsError(message: "wrong preview root") }; if let serveError { throw BackendRemoteServeMachinesTestsPanelsArtifactsError(message: serveError) }; let opened = NativeRPCValue.object([.init("port", .number(41000)), .init("secret", .string("sEcReT0123456789"))]); handle = opened; return opened }
    func link(_ root: String, _ token: String, _ relative: String) { links.append([root, token, relative]) }
    func current() throws -> NativeRPCValue? { if let currentError { throw BackendRemoteServeMachinesTestsPanelsArtifactsError(message: currentError) }; return handle }
    func stop() { handle = nil }
}
