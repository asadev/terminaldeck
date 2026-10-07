import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendMemoryParityEnvironment: BackendMemoryEnvironment {
    let input: BackendMemorySources; let trashFolder: String; var log: String? = nil
    func sources() async throws -> BackendMemorySources { input }
    func trash(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: trashFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: trashFolder + "/" + URL(fileURLWithPath: path).lastPathComponent)
    }
    func hootActionLogger() async -> BackendMemoryActionLogger? {
        guard let log else { return nil }
        return .init { action, detail in
            let value = BackendMemoryParsing.object([("action", .string(action)), ("detail", .string(detail))])
            do { try Data((value.compact + "\n").utf8).write(to: URL(fileURLWithPath: log)) }
            catch { XCTFail(error.localizedDescription) }
        }
    }
}
final class BackendMemoryParityWatch: BackendMemoryWatching, @unchecked Sendable {
    private let lock = NSLock(); private var events: [String: BackendMemoryWatchEvent] = [:]
    private var stopped = false
    func factory(_ root: String, _ event: @escaping BackendMemoryWatchEvent) -> any BackendMemoryWatching {
        lock.withLock { events[root] = event }; return self
    }
    var count: Int { lock.withLock { events.count } }
    var didStop: Bool { lock.withLock { stopped } }
    func fire(root: String, paths: [String], rescan: Bool = false) { let event = lock.withLock { events[root] }; event?(paths, rescan) }
    func stop() { lock.withLock { stopped = true; events.removeAll() } }
}
actor BackendMemoryParityClock: BackendMemoryDebounceClock {
    private var waiters: [CheckedContinuation<Void, Never>] = [], started: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [Int] = []
    func wait(milliseconds: Int) async throws {
        try Task.checkCancellation(); requests.append(milliseconds)
        await withCheckedContinuation { continuation in
            waiters.append(continuation); let notifications = started; started.removeAll(); notifications.forEach { $0.resume() }
        }
        try Task.checkCancellation()
    }
    func scheduled() async { if !waiters.isEmpty { return }; await withCheckedContinuation { started.append($0) } }
    func advance() { let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
actor BackendMemoryParityChanges {
    private var ids: [String] = [], waiters: [CheckedContinuation<[String], Never>] = []
    func append(_ id: String) { ids.append(id); let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume(returning: ids) } }
    func read() async -> [String] { if !ids.isEmpty { return ids }; return await withCheckedContinuation { waiters.append($0) } }
}
@MainActor final class BackendMemoryParityTests: XCTestCase {
    private func temp() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-memory-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return try BackendFilesystemAuthority.canonical(url).path
    }
    private func write(_ file: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    }
    private func fixture(_ root: String) throws -> (environment: BackendMemoryParityEnvironment, memory: String, projects: String) {
        let projects = root + "/claude/projects", memory = projects + "/-work-alpha/memory"
        try write(memory + "/MEMORY.md", "# Memory index\n\n- [Deploy rules](feedback_deploy.md) — ship to TestFlight\n- [Keep it open](keep_open.md) — the latest build\n- [Gone](gone.md) — deleted long ago\n")
        try write(memory + "/feedback_deploy.md", "---\nname: deploy-rules\ndescription: Deploy means TestFlight\ntype: feedback\n---\n\nDeploy means a TestFlight release. See [[keep_open]] and [[nowhere]].\n")
        try write(memory + "/keep_open.md", "---\nname: keep_open\ndescription: Leave the build running\n---\nThe platypus build stays open.\n")
        for name in ["alpha", "beta", "gamma"] { try write(projects + "/-work-" + name + "/conv-" + name + ".jsonl", "{\"cwd\":\"/work/" + name + "\"}\n") }
        try FileManager.default.createSymbolicLink(atPath: projects + "/-work-beta/memory", withDestinationPath: memory)
        try write(projects + "/-work-gamma/memory/MEMORY.md", "# Gamma\n\n- [Secret plan](plan.md)\n")
        try write(projects + "/-work-gamma/memory/plan.md", "The gamma plan mentions platypus too.\n")
        try FileManager.default.createDirectory(atPath: root + "/second", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/second/projects", withDestinationPath: projects)
        try write(root + "/codex/memories/MEMORY.md", "# Codex memory\n")
        try write(root + "/codex/memories/memory_summary.md", "Codex remembers the platypus too.\n")
        try write(root + "/codex/memories/rollout_summaries/r1.md", "A rollout.\n")
        try write(root + "/hoot/memory/MEMORY.md", "# Hoot\n")
        try write(root + "/data/knowledge/abc123/project.json", "{\"project\":\"/work/alpha\"}")
        try write(root + "/data/knowledge/abc123/k1.md", "---\nid: k1\nkind: decision\nsubject: storage\nstatus: verified\nsource: review\nverified: 1759622400000\n---\nNotes live on disk.\n")
        let input = BackendMemorySources(stores: [.init(provider: "claude", configDir: root + "/claude", name: "Own"), .init(provider: "claude", configDir: root + "/second", name: "Two"), .init(provider: "codex", configDir: root + "/codex", name: "Codex own")], hootMemory: root + "/hoot/memory", userData: root + "/data")
        return (.init(input: input, trashFolder: root + "/Trash"), memory, projects)
    }
    func testBothLinkSpellingsAndOnlyMarkdownTargets() {
        let body = "See [[deploy-rules|the rules]] and [[testflight#steps]].\n- [Keep](feedback_keep_open.md)\n[Site](https://example.com/page.md) [top](#heading)\n![picture](diagram.md) [Spaced](my%20note.md)"
        XCTAssertEqual(BackendMemoryParsing.noteLinks(body), ["deploy-rules", "testflight", "feedback_keep_open.md", "my note.md"])
        XCTAssertEqual(BackendMemoryParsing.markdownLinks("[a](notes.txt) [b](other.md#x) [c](/abs/path.md)"), ["other.md"])
    }
    func testEverySourceLinkResolutionCaseAndBacklinks() {
        let notes: [BackendMemoryParsing.Linkable] = [.init(path: "MEMORY.md"), .init(path: "feedback_deploy.md", name: "deploy-rules"), .init(path: "sub/testflight.md"), .init(path: "sub/Readme.md"), .init(path: "Readme.md")]
        let r = BackendMemoryParsing.Resolver(notes)
        XCTAssertEqual(r.resolve(from: "MEMORY.md", target: "Deploy-Rules"), "feedback_deploy.md")
        XCTAssertEqual(r.resolve(from: "MEMORY.md", target: "testflight"), "sub/testflight.md")
        XCTAssertEqual(r.resolve(from: "MEMORY.md", target: "feedback_deploy.md"), "feedback_deploy.md")
        XCTAssertEqual(r.resolve(from: "sub/testflight.md", target: "Readme.md"), "sub/Readme.md")
        XCTAssertEqual(r.resolve(from: "MEMORY.md", target: "sub/testflight.md"), "sub/testflight.md")
        XCTAssertEqual(r.resolve(from: "sub/testflight.md", target: "readme"), "sub/Readme.md")
        XCTAssertEqual(r.resolve(from: "MEMORY.md", target: "readme"), "Readme.md")
        XCTAssertNil(r.resolve(from: "MEMORY.md", target: "../other-project/memory/MEMORY.md")); XCTAssertNil(r.resolve(from: "MEMORY.md", target: "nowhere"))
        let graph = BackendMemoryParsing.graph([.init(path: "MEMORY.md", links: ["a.md", "b.md", "gone.md"]), .init(path: "a.md", links: ["b", "b.md", "a", "missing-name"]), .init(path: "b.md")])
        XCTAssertEqual(graph.nodes, ["MEMORY.md", "a.md", "b.md"])
        XCTAssertEqual(graph.edges, [.init(from: "MEMORY.md", to: "a.md"), .init(from: "MEMORY.md", to: "b.md"), .init(from: "a.md", to: "b.md")])
        XCTAssertEqual(graph.dangling, [.init(from: "MEMORY.md", target: "gone.md"), .init(from: "a.md", target: "missing-name")])
        XCTAssertEqual(graph.edges.filter { $0.to == "b.md" }.map(\.from).sorted(), ["MEMORY.md", "a.md"])
        XCTAssertTrue(graph.edges.filter { $0.to == "MEMORY.md" }.isEmpty)
    }
    func testOriginalTextIndexFixtureExactRankingAndEmptyIndex() {
        var index = BackendMemoryTextIndex()
        index.put(id: "keychain", title: "Keychain access", body: "The vault keeps logins encrypted with safeStorage.")
        index.put(id: "relay", title: "Relay server", body: "The relay is the network; never Tailscale.")
        index.put(id: "vault", title: "Account vault", body: "One vault per machine. The vault file is account-vault.bin.")
        let hits = index.search("vault"); XCTAssertEqual(hits.map(\.id), ["vault", "keychain"]); XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertEqual(index.search("tailsc").map(\.id), ["relay"])
        XCTAssertEqual(index.search("vault", filter: { $0 != "vault" }).map(\.id), ["keychain"])
        XCTAssertTrue(index.search("   ").isEmpty); XCTAssertTrue(BackendMemoryTextIndex().search("vault").isEmpty)
    }
    func testOriginalIndexReplacementRemovalUnicodeAndSnippet() {
        var index = BackendMemoryTextIndex(); index.put(id: "a", title: "one", body: "alpha"); index.put(id: "a", title: "one", body: "beta")
        XCTAssertTrue(index.search("alpha").isEmpty); XCTAssertEqual(index.search("beta").map(\.id), ["a"])
        index.remove("a"); XCTAssertEqual(index.size, 0); XCTAssertTrue(index.search("beta").isEmpty)
        XCTAssertEqual(BackendMemoryTextIndex.tokens("Grüße, 東京 2026!"), ["grüße", "東京", "2026"])
        let body = String(repeating: "x ", count: 80) + "the needle is here " + String(repeating: "y ", count: 80)
        let snippet = BackendMemoryTextIndex.snippet(body, words: ["needle"]); XCTAssertTrue(snippet.contains("needle")); XCTAssertTrue(snippet.hasPrefix("…"))
    }
    func testOriginalDiscoveryFixtureAndReadShape() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let service = BackendMemoryService(environment: f.environment, watch: false), spaces = try await service.spaces()
        let claude = spaces.filter { $0.space.kind == .claudeProject }, alpha = try XCTUnwrap(claude.first)
        XCTAssertEqual(claude.map { $0.space.label }, ["alpha", "gamma"])
        XCTAssertEqual(alpha.space.sharedWith, ["/work/beta"]); XCTAssertEqual(alpha.space.accounts, ["Own", "Two"])
        XCTAssertEqual(alpha.members.map(\.folder), ["-work-alpha", "-work-beta"]); XCTAssertEqual(alpha.members.map(\.linked), [false, true])
        let notes = try await service.notes(alpha.id), deploy = try XCTUnwrap(notes.first { $0["path"].string == "feedback_deploy.md" })
        XCTAssertEqual(deploy["title"].string, "deploy-rules"); XCTAssertEqual(deploy["description"].string, "Deploy means TestFlight"); XCTAssertEqual(deploy["type"].string, "feedback")
        XCTAssertEqual(deploy["links"].elements?.compactMap(\.string), ["keep_open", "nowhere"])
        let read = await service.read(alpha.id, path: .string("feedback_deploy.md"))
        XCTAssertEqual(read["links"], .array([BackendMemoryParsing.object([("target", .string("keep_open")), ("to", .string("keep_open.md"))]), BackendMemoryParsing.object([("target", .string("nowhere")), ("to", .null)])]))
        XCTAssertEqual(read["backlinks"].elements?.compactMap(\.string), ["MEMORY.md"]); XCTAssertEqual(read["indexed"].bool, true)
        let graph = try await service.graph(alpha.id)
        XCTAssertEqual(graph.edges, [.init(from: "MEMORY.md", to: "feedback_deploy.md"), .init(from: "MEMORY.md", to: "keep_open.md"), .init(from: "feedback_deploy.md", to: "keep_open.md")])
        XCTAssertEqual(graph.dangling, [.init(from: "MEMORY.md", target: "gone.md"), .init(from: "feedback_deploy.md", target: "nowhere")])
        await service.close()
    }
    func testOriginalSearchEveryRequestedSpaceAndNestedSummaries() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let service = BackendMemoryService(environment: f.environment, watch: false), spaces = try await service.spaces()
        let claude = spaces.filter { $0.space.kind == .claudeProject }, codex = try XCTUnwrap(spaces.first { $0.space.kind == .codex })
        let notes = try await service.notes(codex.id); XCTAssertEqual(notes.compactMap { $0["path"].string }.sorted(), ["MEMORY.md", "memory_summary.md", "rollout_summaries/r1.md"])
        let own = await service.searchIn("platypus", spaceIDs: [claude[0].id]); XCTAssertEqual(own.map { [$0["spaceId"].string!, $0["path"].string!] }, [[claude[0].id, "keep_open.md"]])
        let both = await service.searchIn("platypus", spaceIDs: [claude[0].id, claude[1].id, codex.id]); XCTAssertEqual(Set(both.compactMap { $0["spaceId"].string }), Set([claude[0].id, claude[1].id, codex.id]))
        await service.close()
    }
    func testNewVersionSavesAgainAndOldVersionNeverOverwrites() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let service = BackendMemoryService(environment: f.environment, watch: false), spaces = try await service.spaces(), alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject })
        let read = await service.read(alpha.id, path: .string("keep_open.md")), saved = await service.save(alpha.id, path: .string("keep_open.md"), text: .string("Corrected.\n"), version: read["version"])
        XCTAssertEqual(saved["ok"].bool, true); XCTAssertEqual(try BackendMemoryFiles.text(f.memory + "/keep_open.md"), "Corrected.\n")
        let old = await service.save(alpha.id, path: .string("keep_open.md"), text: .string("again"), version: read["version"]); XCTAssertEqual(old["ok"].bool, false)
        let next = await service.save(alpha.id, path: .string("keep_open.md"), text: .string("again"), version: saved["version"]); XCTAssertEqual(next["ok"].bool, true)
        await service.close()
    }
    func testOptionalDeleteIndexLineExactSourceFixture() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let service = BackendMemoryService(environment: f.environment, watch: false), spaces = try await service.spaces(), alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject })
        let removed = await service.remove(alpha.id, path: .string("feedback_deploy.md"), indexLine: true)
        XCTAssertEqual(removed["ok"].bool, true); XCTAssertEqual(removed["version"], .null); XCTAssertEqual(removed["indexLineRemoved"].bool, true)
        XCTAssertEqual(try BackendMemoryFiles.text(f.memory + "/MEMORY.md"), "# Memory index\n\n- [Keep it open](keep_open.md) — the latest build\n- [Gone](gone.md) — deleted long ago\n")
        await service.close()
    }
    func testHootCorrectionLogsOwnersExactActionAndDetail() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        var environment = f.environment; environment.log = root + "/actions.jsonl"
        try write(root + "/hoot/memory/pref.md", "---\ndescription: Short answers\ntype: preference\n---\nShort, plain answers.\n")
        let service = BackendMemoryService(environment: environment, watch: false), spaces = try await service.spaces(), hoot = try XCTUnwrap(spaces.first { $0.space.kind == .hoot })
        let read = await service.read(hoot.id, path: .string("pref.md")), changed = await service.save(hoot.id, path: .string("pref.md"), text: .string("Longer answers now.\n"), version: read["version"])
        XCTAssertEqual(changed["ok"].bool, true)
        let log = try BackendMemoryFiles.text(root + "/actions.jsonl")
        XCTAssertTrue(log.contains("\"action\":\"memory.edited\"")); XCTAssertTrue(log.contains("you edited memory/pref.md from the Memory page"))
        await service.close()
    }
    func testProvenanceMatchesOwnerAndLinkedWritesAndExcludesNamesake() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        func conversation(_ dir: String, _ id: String, _ cwd: String, _ path: String, _ stamp: String) throws {
            let head = BackendMemoryParsing.object([("cwd", .string(cwd))]), call = BackendMemoryParsing.object([("timestamp", .string(stamp)), ("message", BackendMemoryParsing.object([("content", .array([BackendMemoryParsing.object([("type", .string("tool_use")), ("name", .string("Write")), ("input", BackendMemoryParsing.object([("file_path", .string(path)), ("content", .string("x"))]))])]))]))])
            try write(dir + "/" + id + ".jsonl", head.compact + "\n" + call.compact + "\n")
        }
        try conversation(f.projects + "/-work-alpha", "conv-writer", "/work/alpha", f.memory + "/keep_open.md", "2026-10-01T10:00:00Z")
        try conversation(f.projects + "/-work-beta", "conv-linked", "/work/beta", f.projects + "/-work-beta/memory/keep_open.md", "2026-10-02T10:00:00Z")
        try conversation(f.projects + "/-work-gamma", "conv-other", "/work/gamma", f.projects + "/-work-gamma/memory/keep_open.md", "2026-10-03T10:00:00Z")
        let service = BackendMemoryService(environment: f.environment, watch: false), spaces = try await service.spaces(), alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject })
        let result = await service.provenance(alpha.id, path: .string("keep_open.md")), writes = result["writes"].elements ?? []
        XCTAssertEqual(result["ok"].bool, true)
        XCTAssertEqual(writes.map { [$0["conversationId"].string!, $0["folder"].string!, $0["tool"].string!] }, [["conv-linked", "/work/beta", "Write"], ["conv-writer", "/work/alpha", "Write"]])
        await service.close()
    }
    func testShareConsentThrowLeavesNothingAndNeverAsksOverExistingMemory() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let answer = try await BackendMemorySpaces.share(projectsDir: f.projects, from: "/work/alpha", to: "/work/delta") { _, _ in throw NativeRPCError(code: "closed", message: "window gone") }
        XCTAssertEqual(answer["ok"].bool, false); XCTAssertEqual(answer["message"].string, "Not shared. Nothing was changed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.projects + "/-work-delta/memory"))
        let own = try await BackendMemorySpaces.share(projectsDir: f.projects, from: "/work/alpha", to: "/work/gamma") { _, _ in XCTFail("Must not ask"); return true }
        XCTAssertEqual(own["ok"].bool, false)
        XCTAssertFalse((try FileManager.default.attributesOfItem(atPath: f.projects + "/-work-gamma/memory")[.type] as? FileAttributeType) == .typeSymbolicLink)
    }
    func testShareAppearsInFreshDiscoveryAndNoDiscoveryRetargetsLink() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let before = try FileManager.default.destinationOfSymbolicLink(atPath: f.projects + "/-work-beta/memory")
        _ = BackendMemorySpaces.discover(f.environment.input)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.projects + "/-work-beta/memory"), before)
        let yes = try await BackendMemorySpaces.share(projectsDir: f.projects, from: "/work/alpha", to: "/work/delta") { title, detail in title == "Share this memory?" && detail.contains("/work/delta") }
        XCTAssertEqual(yes["ok"].bool, true); XCTAssertEqual(yes["target"].string, f.memory)
        let alpha = try XCTUnwrap(BackendMemorySpaces.discover(f.environment.input).first { $0.root == f.memory }); XCTAssertTrue(alpha.space.sharedWith.contains("-work-delta"))
    }
    func testDeterministicEventsRefreshNotesSearchAndPublishAfter150Milliseconds() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let f = try fixture(root)
        let watch = BackendMemoryParityWatch(), clock = BackendMemoryParityClock(), changes = BackendMemoryParityChanges()
        let service = BackendMemoryService(environment: f.environment, watch: true, onChanged: { await changes.append($0) }, watchFactory: { watch.factory($0, $1) }, debounceClock: clock)
        XCTAssertEqual(watch.count, 0)
        let spaces = try await service.spaces(), alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject }); XCTAssertEqual(watch.count, 0)
        _ = try await service.notes(alpha.id); XCTAssertEqual(watch.count, 1)
        try write(f.memory + "/fresh.md", "---\nname: fresh\n---\nA new fact about wombats.\n")
        watch.fire(root: f.memory, paths: [f.memory + "/fresh.md"])
        await clock.scheduled(); let requests = await clock.requests; XCTAssertEqual(requests, [150])
        await clock.advance(); let changed = await changes.read(); XCTAssertEqual(changed, [alpha.id])
        let notes = try await service.notes(alpha.id); XCTAssertTrue(notes.contains { $0["path"].string == "fresh.md" })
        let hits = await service.searchIn("wombats", spaceIDs: [alpha.id]); XCTAssertEqual(hits.compactMap { $0["path"].string }, ["fresh.md"])
        await service.close(); XCTAssertTrue(watch.didStop); await clock.advance()
    }
}
