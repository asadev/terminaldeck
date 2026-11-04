import Foundation
import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class MemoryCoreRulesOnceTests: XCTestCase {
    private func args(_ value: NativeRPCValue) -> NativeRPCValue { .object([.init("limit", value)]) }

    func testIntegerAdaptersPreserveStrictRequiredAndClampedOptionalValues() throws {
        for value in [500.0, -1, 2.5, Double.infinity, -Double.infinity, Double.nan] {
            let input = args(.number(value))
            XCTAssertThrowsError(try BackendDeckCoreArguments.int(input, "limit", min: 0, max: 200))
            XCTAssertThrowsError(try BackendDeckToolsArgs.int(input, "limit", 0, 200))
        }
        let cases: [(Double, Int)] = [(500, 200), (-1, 0), (2.5, 2), (0, 0), (200, 200),
                                     (Double.greatestFiniteMagnitude, 200), (-Double.greatestFiniteMagnitude, 0)]
        for (value, expected) in cases {
            let input = args(.number(value))
            XCTAssertEqual(try BackendDeckCoreArguments.optionalInt(input, "limit", fallback: 20, min: 0, max: 200), expected)
            XCTAssertEqual(try BackendDeckCoreCatalogueRules.optionalInt(input, "limit", fallback: 20, min: 0, max: 200), expected)
            XCTAssertEqual(try BackendDeckToolsArgs.optInt(input, "limit", 20, 0, 200), expected)
        }
        for value in [0, 2, 200] {
            XCTAssertEqual(try BackendDeckCoreArguments.int(args(.number(Double(value))), "limit", min: 0, max: 200), value)
            XCTAssertEqual(try BackendDeckToolsArgs.int(args(.number(Double(value))), "limit", 0, 200), value)
        }
        let invalid: [NativeRPCValue] = [.number(.infinity), .number(-.infinity), .number(.nan), .string("2"), .bool(true), .array([]), .object([])]
        for value in invalid {
            XCTAssertThrowsError(try BackendDeckCoreArguments.optionalInt(args(value), "limit", fallback: 20, min: 0, max: 200))
            XCTAssertThrowsError(try BackendDeckCoreCatalogueRules.optionalInt(args(value), "limit", fallback: 20, min: 0, max: 200))
            XCTAssertThrowsError(try BackendDeckToolsArgs.optInt(args(value), "limit", 20, 0, 200))
        }
        for input in [NativeRPCValue.object([]), args(.null)] {
            XCTAssertEqual(try BackendDeckCoreArguments.optionalInt(input, "limit", fallback: 20, min: 0, max: 200), 20)
            XCTAssertEqual(try BackendDeckCoreCatalogueRules.optionalInt(input, "limit", fallback: 20, min: 0, max: 200), 20)
            XCTAssertEqual(try BackendDeckToolsArgs.optInt(input, "limit", 20, 0, 200), 20)
            XCTAssertThrowsError(try BackendDeckCoreArguments.int(input, "limit", min: 0, max: 200))
        }
        XCTAssertEqual(try BackendDeckCoreArguments.optionalInt(args(.number(-2.5)), "limit", fallback: 20, min: -200, max: 200), -2)
        let strings = NativeRPCValue.object([.init("name", .string("  seat  "))])
        XCTAssertEqual(try BackendDeckCoreCatalogueRules.string(strings, "name"), "  seat  ")
        XCTAssertEqual(try BackendDeckToolsArgs.str(strings, "name"), "  seat  ")
        XCTAssertEqual(try BackendDeckToolsSessionsRules.str(strings, "name"), "seat")
    }

    func testTypingAndTranscriptAdaptersUseTheSameRules() async throws {
        for name in ["Enter", "shift+tab", "arrow_up", "ctrl-c", "y", " "] {
            XCTAssertEqual(try BackendDeckToolsSessionsTyping.resolveKey(.string(name)), try BackendDeckCoreTyping.resolveKey(.string(name)))
        }
        for text in ["hello", "hello\n", "\u{0085}"] {
            XCTAssertEqual(try? BackendDeckToolsSessionsTyping.sanitizeSendText(text), try? BackendDeckCoreCatalogueRules.sanitizeSendText(text))
        }
        let session = NativeRPCValue.object([.init("id", .string("one")), .init("createdAt", .number(100)), .init("provider", .string("claude"))])
        let other = session.setting("id", .string("two")).setting("createdAt", .number(500))
        let file = NativeRPCValue.object([.init("path", .string("/fake/c.jsonl")), .init("createdAt", .number(100)), .init("modifiedAt", .number(600)), .init("bytes", .number(20))])
        for row in [session, session.setting("resumed", .bool(true)), session.setting("provider", .string("codex"))] {
            XCTAssertEqual(BackendDeckToolsSessionsTranscriptMatch.match(session: row, files: [file], sessionsInFolder: [row, other]),
                           BackendDeckCoreReports.matchTranscript(session: row, files: [file], sessionsInFolder: [row, other]))
        }
        actor Trace {
            var lines: [String] = []
            func append(_ text: String) { lines.append(text) }
        }
        let first = Trace(), second = Trace()
        try await BackendDeckCoreTyping.typeLine(write: { await first.append($0) }, text: "@file", submit: true,
                                                clock: .init(now: { 0 }, sleep: { await first.append("sleep:\(Int($0))") }))
        try await BackendDeckToolsSessionsTyping.typeLine(write: { await second.append($0) }, text: "@file", submit: true,
                                                         sleep: { await second.append("sleep:\($0)") })
        let a = await first.lines, b = await second.lines
        XCTAssertEqual(a, ["@file ", "sleep:500", "\r"]); XCTAssertEqual(a, b)
    }

    func testProjectMatchingAndReportSequencesShareCoreRules() {
        let projects = [TaskProject(path: "/work/", title: "Work"), TaskProject(path: "/work/nested", title: "Nested")]
        for path in [" /work/ ", "/work/nested/src", "/worker", "/", ""] {
            XCTAssertEqual(BackendTaskProjectScope.clean(path), TaskProjects.clean(path))
            XCTAssertEqual(BackendTaskProjectScope.within(path, "/work"), TaskProjects.within(path, "/work"))
            XCTAssertEqual(BackendTaskProjectScope.owningProject(of: path, openProjects: projects.map(\.path)), TaskProjects.owner(of: path, among: projects).map { TaskProjects.clean($0.path) })
        }
        XCTAssertTrue(BackendRemoteServeSessionPolicy.sameFolder("/work/a/../b/", "/work/b"))
        let entries: [NativeRPCValue] = [.object([.init("id", .string("q")), .init("kind", .string("question"))]),
                                         .object([.init("id", .string("r")), .init("kind", .string("report"))])]
        let snapshot = RoutineChatSnapshot.snapshot(entries, routineID: "routine")
        XCTAssertEqual(snapshot["entries"].elements?.map { $0["sequence"].number }, [1, 2])
        XCTAssertEqual(snapshot["unread"]["count"].number, 0)
    }

    func testGroupingPreservesFolderAndRegisteredProjectViews() {
        func task(_ id: String, _ folder: String, _ status: String = "To-Do") -> TaskRow {
            .init(id: "local:" + id, keyId: "local", externalTaskId: id, title: id, project: folder, crmStatus: status, local: true, assignee: "me")
        }
        let rows = [task("a", "/work/app"), task("b", "/work/site"), task("c", ""), task("d", "/work/app", "Done")]
        let registered = [PROJProject(id: "site", name: "Site", folders: ["/work/site"]), PROJProject(id: "app", name: "App", folders: ["/work/app"])]
        let folders = [TaskProject(path: "/work/site", title: "Site"), TaskProject(path: "/work/app", title: "App")]
        for showClosed in [false, true] {
            let ids = TaskProjects.groups(rows, projects: registered, showClosed: showClosed).map { $0.items.map(\.id) }
            let paths = TaskProjects.groups(rows, open: folders, showClosed: showClosed).map { $0.items.map(\.id) }
            XCTAssertEqual(ids, paths)
            XCTAssertEqual(ids, showClosed ? [["local:b"], ["local:a", "local:d"], ["local:c"]] : [["local:b"], ["local:a"], ["local:c"], ["local:d"]])
        }
        let state = TasksState(tasks: rows)
        let ids = TaskProjects.scoped(state, projectID: "app", projects: registered).tasks.map(\.id)
        let paths = TaskProjects.scoped(state, scope: .this, current: "/work/app", open: folders).tasks.map(\.id)
        XCTAssertEqual(ids, paths)
    }

    func testSharedFolderRuleKeepsLocalAndGrantedCallersSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-folder-rule-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try BackendDeckCoreCatalogueBuiltins.requireKnownFolder(root.path, known: [], local: true), root.path)
        XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.requireKnownFolder(root.path, known: [], local: false))
        XCTAssertEqual(try BackendDeckCoreCatalogueBuiltins.requireKnownFolder(root.path, known: [root.path], local: false), root.path)
        XCTAssertEqual(try BackendDeckToolsFiles.relative("a/.."), "")
        XCTAssertThrowsError(try BackendDeckToolsFiles.relative("a/../../outside"))
    }

    func testSharedOwnerAndTurnReadOldFlowJobsAndKeepSessionDetails() throws {
        let raw = Data(#"{"kind":"agent","id":"memory","name":"Codex","project":"deck","memoryOn":true}"#.utf8)
        var flow = try JSONDecoder().decode(DeckMemoryFlowOwner.self, from: raw)
        flow.hand = 2; flow.job = "Core rules"
        let session: DeckMemorySessionOwner = flow
        let legacyHoot = try JSONDecoder().decode(DeckMemoryFlowOwner.self, from: Data(#"{"kind":"hoot","id":"hoot","name":"Hoot","project":"","memoryOn":true}"#.utf8))
        XCTAssertNil(legacyHoot.stamp(session: "hoot", provider: "claude").project)
        XCTAssertEqual(session.memoryOwner, .role(project: "deck", role: "memory"))
        XCTAssertEqual(session.stamp(session: "s1", provider: "codex").hand, 2)
        let turn = DeckMemoryFlowTurn(sessionID: "s1", provider: "codex", owner: session, title: "Core rules")
        let signal: DeckMemorySessionTurn = turn
        XCTAssertEqual(signal.owner, session)
        XCTAssertEqual(try JSONDecoder().decode(DeckMemorySessionOwner.self, from: JSONEncoder().encode(session)), session)
    }

    func testFilesAndStoreGiveTheSameOpeningIncludingBoardAndJobTopics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-core-rules-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await DeckMemoryStore.open(root: root, dataRoot: nil, embedder: nil, watch: false)
        let owner = DeckMemoryOwner.role(project: "deck", role: "memory")
        var template = try await store.template(.agent)
        template.parts = [.card, .topics, .board]
        _ = try await store.saveTemplate(template)
        _ = try await store.saveCard(owner, text: "# Memory\n\n## Top rules\n- Keep every note.\n")
        _ = try await store.updateTopic(owner, title: "Current job", body: "A complete topic.", stamp: .init(owner: owner, job: "Current job"))
        _ = try await store.updateTopic(owner, title: "Other job", body: "Another hand.", stamp: .init(owner: owner, job: "Other job"))
        _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: .init(owner: owner), title: "Memory work", doing: "checking the rules"))
        _ = try await store.addNote(.init(title: "Recent note", body: "Notes are searched later.", type: .decision, stamp: .init(owner: owner)))
        for limit: Int? in [nil, 2_000] {
            let indexed = try await DeckMemoryBrief.opening(store, owner: owner, job: "Current job", limit: limit)
            let files = DeckMemorySessionFiles.opening(owner, job: "Current job", limit: limit, root: root)
            XCTAssertEqual(files, indexed)
        }
        let opening = DeckMemorySessionFiles.opening(owner, job: "Current job", limit: nil, root: root)
        XCTAssertTrue(opening.text.contains("checking the rules")); XCTAssertFalse(opening.text.contains("Another hand."))
        XCTAssertFalse(opening.text.contains("Recent note"))
        let session = try JSONDecoder().decode(BackendSessionMeta.self, from: Data(#"{"id":"s1","cwd":"/fake","title":"Memory","provider":"claude","createdAt":0,"resumed":false}"#.utf8))
        let seat = DeckMemorySessionOwner(kind: .agent, id: "memory", project: "deck", memoryOn: true, job: "Current job")
        let start = await DeckMemorySessionFiles.startContext(seat, session: session, reason: "start", lastMessages: [], root: root)
        XCTAssertTrue(start.contains("checking the rules")); XCTAssertFalse(start.contains("Recent notes"))
        template.card = "## Top rules\n- " + String(repeating: "Never cut this rule. ", count: 600)
        _ = try await store.saveTemplate(template)
        let large = await DeckMemorySessionFiles.startContext(seat, session: session, reason: "start", lastMessages: [], root: root)
        XCTAssertTrue(large.contains("Read it now")); XCTAssertFalse(large.contains("cut here"))
        await store.close()
    }

    func testFilesOnlySourceDoesNotCreateAnIndex() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-no-index-" + UUID().uuidString)
        _ = DeckMemorySessionFiles.opening(.lead("deck"), job: nil, limit: 8_000, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
