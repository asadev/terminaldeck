import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// HOOT-FLOW (Asad, 12 Oct): short titles for every rule (made when saved, the helper's later), the job-flow report tool
/// (rules with a tick, skill steps, agents' reports kept with their task), and what Hoot and every session are told.
/// Scratch folders only; the helper AI is a stand-in.
final class HootFlowTitlesTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }
    private func temp(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-hoot-flow-" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }
    private func open() async throws -> DeckMemoryStore {
        let data = try temp("data"), root = try temp("root").appendingPathComponent("Memory")
        return try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false)
    }

    /// Stands in for the helper AI: answers every numbered item with "Title <n>", and counts the questions.
    private final class Helper: DeckMemoryFlowHelperRunning, @unchecked Sendable {
        let lock = NSLock()
        var asked: [String] = []
        var fail = false
        func run(_ request: DeckMemoryFlowHelperRequest) async throws -> DeckMemoryFlowHelperReply {
            let failing = lock.withLock { asked.append(request.prompt); return fail }
            if failing { throw NativeRPCError(code: "failed", message: "Claude Code is not signed in.") }
            let count = request.prompt.components(separatedBy: "\n").filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count
            let titles = (1...max(1, count)).map { #"{"n": \#($0), "short": "Title \#($0)"}"# }.joined(separator: ", ")
            return .init(text: #"Here you go: {"titles": [\#(titles)]}"#)
        }
        var questions: Int { lock.withLock { asked.count } }
    }

    // MARK: The first words

    func testTheFirstWordsMakeAPlainShortTitle() {
        XCTAssertEqual(DeckMemoryShortTitle.fallback("On 2026-10-11 Hoot said it cannot set Bypass permission when starting a session"), "Hoot said it cannot set Bypass")
        XCTAssertEqual(DeckMemoryShortTitle.fallback("Background turns: turn id \"bg:<reason>:<id>:<uuid>\""), "Background turns")
        XCTAssertEqual(DeckMemoryShortTitle.fallback("- **Never** touch the install he's using."), "Never touch the install he's using")
        XCTAssertEqual(DeckMemoryShortTitle.fallback("Keep the latest copy open on his Mac at all times"), "Keep the latest copy open")
        XCTAssertEqual(DeckMemoryShortTitle.fallback("ship only on his word"), "Ship only on his word")
        XCTAssertEqual(DeckMemoryShortTitle.cleaned("\"Bypass only from playbook.\"\nmore"), "Bypass only from playbook")
        XCTAssertNil(DeckMemoryShortTitle.cleaned("  ...  "))
        XCTAssertEqual(DeckMemoryShortTitle.ruleKey("-  Always  ANSWER short "), "always answer short")
        for text in ["One", "A very long rule that keeps going well past six words and more", "On 2026-10-11 x"] {
            XCTAssertLessThanOrEqual(DeckMemoryShortTitle.fallback(text).split(separator: " ").count, DeckMemoryShortTitle.maximumWords, text)
        }
    }

    // MARK: Saved with a short title

    func testEveryNoteIsSavedWithItsShortTitle() async throws {
        let store = try await open()
        let plain = try await store.addNote(.init(title: "Keep the latest copy open on his Mac at all times", body: "He reviews the newest build.", stamp: .hoot, source: "agent"))
        XCTAssertEqual(plain.shortTitle, "Keep the latest copy open"); XCTAssertEqual(plain.shortTitleBy, .firstWords)
        XCTAssertEqual(plain.listTitle, "Keep the latest copy open")
        let helped = try await store.addNote(.init(title: "Bypass permission only from the playbook", body: "Hoot cannot choose Bypass itself.", stamp: .hoot,
                                                   source: "helper", shortTitle: "Bypass only from playbook"))
        XCTAssertEqual(helped.shortTitle, "Bypass only from playbook"); XCTAssertEqual(helped.shortTitleBy, .helper)
        // The person's own title is never replaced by the helper's.
        let mine = try await store.addNote(.init(title: "Releases", body: "Only on his word.", stamp: .hoot, source: "user", shortTitle: "Ship on his word"))
        XCTAssertEqual(mine.shortTitleBy, .person)
        let kept = try await store.setShortTitle(noteID: mine.id, short: "Something else", by: .helper)
        XCTAssertEqual(kept.shortTitle, "Ship on his word")
        // The helper's title replaces the first words; the text and its date stay.
        let titled = try await store.setShortTitle(noteID: plain.id, short: "Latest build always open", by: .helper)
        XCTAssertEqual(titled.shortTitle, "Latest build always open"); XCTAssertEqual(titled.shortTitleBy, .helper)
        XCTAssertEqual(titled.body, plain.body); XCTAssertEqual(titled.labels.date, plain.labels.date)
        // Changed words: the title is made again (first words now), unless the person wrote it.
        let edited = try await store.updateNote(id: plain.id, title: "Leave the newest build running in front of him", body: "Every round.")
        XCTAssertEqual(edited.shortTitle, "Leave the newest build running"); XCTAssertEqual(edited.shortTitleBy, .firstWords)
        let stillMine = try await store.updateNote(id: mine.id, title: "Releases", body: "Only on his word, both ways.")
        XCTAssertEqual(stillMine.shortTitle, "Ship on his word")
        // It is in the file, so it survives a rebuilt index.
        try await store.reindex()
        let again = try await store.note(id: helped.id)
        XCTAssertEqual(again?.shortTitle, "Bypass only from playbook")
    }

    func testTheHelperWritesAShortTitleWithEveryNote() throws {
        let answer = try DeckMemoryFlowHelperPrompt.parse(#"{"notes": [{"type": "decision", "title": "Ship on Tuesday", "short": "Ship on Tuesday.", "text": "The ship date is Tuesday, decided by the person."}]}"#)
        XCTAssertEqual(answer.notes.first?.short, "Ship on Tuesday")
        let writes = DeckMemoryFlowRules.turn(answer, stamp: .hoot, boardRow: "chat:hoot", boardKind: .chat, asking: false, at: Date(), personSpoke: true, stored: [])
        XCTAssertEqual(writes.notes.first?.shortTitle, "Ship on Tuesday")
        XCTAssertTrue(DeckMemoryFlowPrompts.standard.helperTurn.contains(#""short""#))
    }

    // MARK: The titles job

    func testOlderNotesAndEveryTopRuleGetTheHelpersTitlesOnce() async throws {
        let store = try await open()
        _ = try await store.saveCard(.hoot, text: "# Hoot\n\n## Top rules\n- Never push live without his word\n- Always answer in short plain English\n")
        let a = try await store.addNote(.init(title: "First older note about builds", body: "Builds go through one-build.sh.", stamp: .hoot, source: "agent"))
        let b = try await store.addNote(.init(title: "Second older note about the island", body: "The island is notch-aware.", stamp: .hoot, source: "agent"))
        let helper = Helper()
        let titles = DeckMemoryShortTitles(store: { store }, runner: helper, helper: { .init(ai: "claude", model: "sonnet") })
        let made = await titles.pass()
        XCTAssertGreaterThanOrEqual(made, 4)
        let noteA = try await store.note(id: a.id), noteB = try await store.note(id: b.id)
        XCTAssertEqual(noteA?.shortTitleBy, .helper); XCTAssertEqual(noteB?.shortTitleBy, .helper)
        XCTAssertTrue(noteA?.shortTitle?.hasPrefix("Title ") == true)
        let rules = await DeckMemoryShortTitles.ruleTitles(store)
        XCTAssertNotNil(rules[DeckMemoryShortTitle.ruleKey("Never push live without his word")])
        XCTAssertNotNil(rules[DeckMemoryShortTitle.ruleKey("- Always answer in short plain English")])
        // Asked once; nothing left, so a second pass asks nothing.
        let asked = helper.questions
        let second = await titles.pass()
        XCTAssertEqual(second, 0)
        XCTAssertEqual(helper.questions, asked)
        XCTAssertTrue(helper.asked.first?.contains("3 to 6 plain words") == true)
    }

    func testWithTheHelperOffOrFailingTheFirstWordsStay() async throws {
        let store = try await open()
        let note = try await store.addNote(.init(title: "A note while the helper is off", body: "Text.", stamp: .hoot, source: "agent"))
        let helper = Helper()
        let off = DeckMemoryShortTitles(store: { store }, runner: helper, helper: { nil })
        let none = await off.pass()
        XCTAssertEqual(none, 0); XCTAssertEqual(helper.questions, 0)
        helper.fail = true
        let failing = DeckMemoryShortTitles(store: { store }, runner: helper, helper: { .init(ai: "claude", model: "") })
        let first = await failing.pass()
        XCTAssertEqual(first, 0)
        // It rests after a failure: no second question straight away.
        let rested = await failing.pass()
        XCTAssertEqual(rested, 0); XCTAssertEqual(helper.questions, 1)
        let kept = try await store.note(id: note.id)
        XCTAssertEqual(kept?.shortTitle, "A note while the helper"); XCTAssertEqual(kept?.shortTitleBy, .firstWords)
    }

    // MARK: The job flow's report tool

    func testAReportedRuleIsFoundByIdByItsWordsOrStaysItsOwnWords() async throws {
        let store = try await open()
        _ = try await store.saveCard(.hoot, text: "## Top rules\n- Never push live without his word\n")
        let note = try await store.addNote(.init(title: "Bypass permission only from the playbook", body: "Hoot cannot set Bypass itself.", stamp: .hoot,
                                                 source: "helper", shortTitle: "Bypass only from playbook"))
        let byID = await DeckMemoryTools.resolveRule(note.id, owner: .hoot, memory: store)
        XCTAssertEqual(byID.id, note.id); XCTAssertEqual(byID.title, "Bypass only from playbook"); XCTAssertTrue(byID.matched)
        let byWords = await DeckMemoryTools.resolveRule("never push live without his word", owner: .hoot, memory: store)
        XCTAssertNil(byWords.id); XCTAssertTrue(byWords.matched); XCTAssertEqual(byWords.full, "- Never push live without his word")
        XCTAssertEqual(byWords.title, "Never push live without his word")
        let unknown = await DeckMemoryTools.resolveRule("Always check the disk before a big download starts", owner: .hoot, memory: store)
        XCTAssertFalse(unknown.matched); XCTAssertEqual(unknown.title, "Always check the disk before")
        XCTAssertEqual(JobFlowWords.line(kind: .rule, title: byID.title, step: nil, stepTitle: nil), "Rule applied: Bypass only from playbook")
        XCTAssertEqual(JobFlowWords.line(kind: .skill, title: "resume", step: 2, stepTitle: "Read the handoff"), "Skill resume · step 2: Read the handoff")
    }

    func testTheReportToolIsOneEveryoneHasAndNeverAsks() throws {
        struct Unused: Error {}
        let tools = try DeckMemoryTools.definitions(access: .init(
            caller: { _ in throw Unused() }, knownFolder: { _, _ in throw Unused() }, session: { _, _ in throw Unused() },
            runnableProject: { _, _ in throw Unused() }, rpc: { _ in throw Unused() },
            authorize: { _, _, _, _, _, _ in throw Unused() }, record: { _, _, _, _ in throw Unused() }))
        let tool = try XCTUnwrap(tools.first { $0.spec.id == JobFlowWords.toolID })
        XCTAssertEqual(tool.spec.tier, .read); XCTAssertEqual(tool.spec.wireName, JobFlowWords.toolWire)
        XCTAssertTrue(DeckMemoryTools.sessionToolNames.contains(JobFlowWords.toolWire))
        XCTAssertNotNil(tools.first { $0.spec.id == "memory.note.add" }?.spec.inputSchema["properties"]["short"].fields)
        XCTAssertTrue(JobFlowWords.isReport(name: "mcp__deck-control__flow_applied", input: .object([])))
        XCTAssertTrue(JobFlowWords.isReport(name: "mcp__deck-control__tools_run", input: .object([.init("name", .string("flow.applied"))])))
        XCTAssertFalse(JobFlowWords.isReport(name: "mcp__deck-control__tools_run", input: .object([.init("name", .string("tasks_list"))])))
    }

    func testAnAgentsReportsAreKeptWithItsTaskAndSurviveARestart() async throws {
        let file = try temp("log").appendingPathComponent("job-flow.jsonl")
        let log = BackendJobFlowLog()
        await log.configure(file: file)
        await log.noteTasks([.object([.init("id", .string("local:task-1")), .init("sessionId", .string("session-9")), .init("agent", .string("iOS fixer"))])])
        await log.record(.init(at: 1_000, session: "session-9", who: "", seat: "role:shop/ios", kind: .rule, title: "Never push live", full: "- Never push live"))
        await log.record(.init(at: 2_000, session: "session-9", who: "", seat: "role:shop/ios", kind: .skill, title: "resume", step: 1, stepTitle: "Read the handoff"))
        let kept = await log.entries(tasks: ["local:task-1"])
        XCTAssertEqual(kept.map(\.task), ["local:task-1", "local:task-1"]); XCTAssertEqual(kept.first?.who, "iOS fixer")
        // The task's session ends: the task still has its reports.
        await log.noteTasks([.object([.init("id", .string("local:task-1")), .init("sessionId", .null)])])
        let still = await log.entries(tasks: ["local:task-1"])
        XCTAssertEqual(still.count, 2)
        let reopened = BackendJobFlowLog()
        await reopened.configure(file: file)
        let reread = await reopened.all()
        XCTAssertEqual(reread.map(\.line), ["Rule applied: Never push live", "Skill resume · step 1: Read the handoff"])
    }

    // MARK: SETTINGS-TRUTH line 47: a project's "What it is" reaches its agents and Hoot

    func testAProjectsLineReachesItsSeatsAndHootsDesk() async throws {
        let store = try await open()
        XCTAssertEqual(DeckMemoryCard.replacingSection("What this project is", with: "A shop app.", in: ""), "## What this project is\nA shop app.\n")
        let card = "# Shop\n\n## What this project is\nOld line.\n\n## Rules\n- Keep it fast\n"
        let changed = DeckMemoryCard.replacingSection("What this project is", with: "A shop app for iOS.", in: card)
        XCTAssertTrue(changed.contains("## What this project is\nA shop app for iOS.") && changed.contains("## Rules\n- Keep it fast") && !changed.contains("Old line"))
        XCTAssertFalse(DeckMemoryCard.replacingSection("What this project is", with: "", in: card).contains("What this project is"))
        _ = try await store.ensureOwner(.project("shop"), name: "Shop")
        _ = try await store.saveCard(.project("shop"), text: DeckMemoryCard.replacingSection(DeckMemoryCard.projectAboutHeading, with: "A shop app for iOS.", in: ""))
        // Every seat of the project gets it with the project's card; Hoot's desk names it.
        let opening = try await DeckMemoryBrief.opening(store, owner: .role(project: "shop", role: "ios"))
        XCTAssertTrue(opening.text.contains("A shop app for iOS."))
        let lines = await BackendHootDesk.projectLines(store)
        XCTAssertEqual(lines, "## What each project is\n- Shop (shop): A shop app for iOS.")
    }

    // MARK: FINAL-HOOT: Hoot gets the MCP page's servers like every other session

    func testHootGetsTheMCPPagesServersWithItsOwnSwitchAndNoSecretOnACommandLine() throws {
        let home = try temp("home"), folder = try temp("hootfolder")
        try Data(#"{"mcpServers": {"notes": {"command": "/usr/bin/notes-mcp", "args": ["--ro"], "env": {"NOTES_TOKEN": "s3cret-value"}}, "web": {"type": "http", "url": "https://example.com/mcp"}, "deck-control": {"type": "http", "url": "https://x.example/mcp"}}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        var document = BackendMcpPolicyDocument()
        var web = BackendMcpPolicyEntry(); web.agentsOff = [BackendMcpPolicy.hootAgentID]; document.servers["web"] = web
        var notes = BackendMcpPolicyEntry(); notes.toolsOff = ["delete_note"]; document.servers["notes"] = notes
        let page = BackendMcpPolicy.hootServers(provider: "codex", cwd: folder.path, home: home.path, environment: [:], document: document)
        XCTAssertEqual(page.map(\.name), ["notes"], "Hoot's own switch is off for web; Hoot's lease name is never taken")
        // Codex: over the conversation's own pipe, never argv.
        let codex = try BackendHootChatLaunchPlan(provider: .codex, cwd: folder.path, sessionID: nil, extra: [], pageServers: page)
        XCTAssertFalse(codex.arguments.joined(separator: " ").contains("s3cret"))
        let server = try XCTUnwrap(codex.setup?.session["config"]["mcp_servers"]["notes"])
        XCTAssertEqual(server["command"].string, "/usr/bin/notes-mcp"); XCTAssertEqual(server["required"].bool, false)
        XCTAssertEqual(server["disabled_tools"].elements?.compactMap(\.string), ["delete_note"])
        // Claude Code: one private file holding the lease and the page's servers; the tools that are off are disallowed.
        let lease = folder.appendingPathComponent("lease.json")
        try Data(#"{"mcpServers": {"deck-control": {"type": "http", "url": "http://127.0.0.1:9/mcp"}}}"#.utf8).write(to: lease)
        let extra = try BackendHootChatLaunchPlan.withPageServers(["--mcp-config", lease.path, "--strict-mcp-config"], page, privateDirectory: try temp("private"))
        XCTAssertNotEqual(extra[1], lease.path); XCTAssertFalse(extra.joined(separator: " ").contains("s3cret"))
        XCTAssertEqual(Array(extra.suffix(2)), ["--disallowedTools", "mcp__notes__delete_note"])
        let merged = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: extra[1])))
        XCTAssertNotNil(merged["mcpServers"]["deck-control"].fields); XCTAssertEqual(merged["mcpServers"]["notes"]["env"]["NOTES_TOKEN"].string, "s3cret-value")
        XCTAssertEqual(try BackendHootChatLaunchPlan.withPageServers(["--mcp-config", lease.path], [], privateDirectory: nil), ["--mcp-config", lease.path])
    }

    // MARK: What the AIs are told

    func testHootAndEverySessionAreToldHowToReportAndHowToShapeAnswers() {
        let desk = BackendHootDesk.howTo
        XCTAssertTrue(desk.contains(JobFlowWords.toolWire) && desk.contains("green tick") && desk.contains("stepTitle"))
        for marker in [":::needs-you", ":::done", ":::waiting", ":::heads-up"] { XCTAssertTrue(desk.contains(marker), marker) }
        XCTAssertTrue(desk.contains("numbered list") && desk.contains("Markdown table"))
        XCTAssertTrue(BackendBuiltInSkills.flowLine.contains(JobFlowWords.toolWire))
        // Hoot is told the skills that ship with the app (seen missing in the dev copy), and to report their steps.
        XCTAssertNil(BackendHootDesk.builtInSkills(folder: nil))
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("built-in-skills", isDirectory: true)
        let told = BackendHootDesk.builtInSkills(folder: shipped) ?? ""
        XCTAssertTrue(told.contains("save-session") && told.contains(JobFlowWords.toolWire), told)
        XCTAssertTrue(desk.contains("never as a quote or a bold label"))
        XCTAssertTrue(BackendANDROIDSessionPhoneNote.note.contains(JobFlowWords.toolWire))
        XCTAssertTrue(BackendANDROIDSessionPhoneNote.codexNote.contains(JobFlowWords.toolWire))
    }
}
