import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendMemoryTestEnvironment: BackendMemoryEnvironment {
    let input: BackendMemorySources; let trashDirectory: String; let log: String?
    func sources() async throws -> BackendMemorySources { input }
    func trash(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: trashDirectory + "/" + URL(fileURLWithPath: path).lastPathComponent)
    }
    func hootActionLogger() async -> BackendMemoryActionLogger? {
        guard let log else { return nil }
        return .init { action, detail in
            do { try Data((action + " " + detail).utf8).write(to: URL(fileURLWithPath: log)) }
            catch { NSLog("%@", error.localizedDescription) }
        }
    }
}

@MainActor
final class BackendMemoryTests: XCTestCase {
    private func temp() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-memory-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try BackendFilesystemAuthority.canonical(root).path
    }
    private func write(_ file: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    }
    private func fixture(_ root: String) throws -> (BackendMemoryTestEnvironment, String) {
        let projects = root + "/claude/projects", memory = projects + "/-work-alpha/memory"
        try write(memory + "/MEMORY.md", "# Index\n- [Rule](rule.md)\n- [Keep](keep.md)\n")
        try write(memory + "/rule.md", "---\nname: deploy-rules\ndescription: release meaning\ntype: feedback\n---\nDeploy to TestFlight. [[keep]] [[missing]]\n")
        try write(memory + "/keep.md", "Keep the platypus build open.\n")
        try write(projects + "/-work-alpha/c1.jsonl", "{\"cwd\":\"/work/alpha\"}\n")
        try write(projects + "/-work-beta/c2.jsonl", "{\"cwd\":\"/work/beta\"}\n")
        try FileManager.default.createSymbolicLink(atPath: projects + "/-work-beta/memory", withDestinationPath: memory)
        try FileManager.default.createDirectory(atPath: root + "/second", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/second/projects", withDestinationPath: projects)
        try write(root + "/codex/memories/rollout_summaries/r.md", "Codex remembers platypus.\n")
        try write(root + "/hoot/memory/MEMORY.md", "Hoot memory.\n")
        try write(root + "/data/knowledge/key/project.json", "{\"project\":\"/work/alpha\"}")
        try write(root + "/data/knowledge/key/k1.md", "---\nkind: decision\nstatus: verified\nsource: review\nverified: 1759622400000\n---\nDisk.\n")
        let input = BackendMemorySources(stores: [.init(provider: "claude", configDir: root + "/claude", name: "Own"), .init(provider: "claude", configDir: root + "/second", name: "Two"), .init(provider: "codex", configDir: root + "/codex", name: "Codex own")], hootMemory: root + "/hoot/memory", userData: root + "/data")
        return (.init(input: input, trashDirectory: root + "/Trash", log: root + "/actions"), memory)
    }
    func testFlatNoteAndBothLinkSpellings() {
        let text = "---\nname: 'deploy-rules'\ndescription: a fact\nmetadata:\n  type: feedback\n---\n\n# Heading\n[[a|alias]] [[a#heading]] [[ ]] [b](b.md) ![picture](image.md) [web](https://x/a.md) [space](my%20note.md)"
        let note = BackendMemoryParsing.parseNote(text, file: "x.md")
        XCTAssertEqual(note.title, "deploy-rules"); XCTAssertEqual(note.front["type"], "feedback")
        XCTAssertTrue(note.body.hasPrefix("\n# Heading")); XCTAssertEqual(BackendMemoryParsing.noteLinks(note.body), ["a", "b.md", "my note.md"])
        XCTAssertEqual(BackendMemoryParsing.bodyOf("---\nname: x\nno end"), "---\nname: x\nno end")
        XCTAssertEqual(BackendMemoryParsing.parseNote("# Title\nbody", file: "x.md").title, "Title")
        XCTAssertEqual(BackendMemoryParsing.parseNote("plain", file: "note.MD").title, "note")
    }
    func testResolverAndGraphBoundaries() {
        let notes: [BackendMemoryParsing.Linkable] = [.init(path: "MEMORY.md", links: ["rule", "../elsewhere/rule.md", "missing"]), .init(path: "feedback.md", name: "rule", links: ["feedback", "sub/readme.md", "sub/readme"]), .init(path: "Readme.md"), .init(path: "sub/Readme.md")]
        let resolver = BackendMemoryParsing.Resolver(notes)
        XCTAssertEqual(resolver.resolve(from: "MEMORY.md", target: "RULE"), "feedback.md")
        XCTAssertEqual(resolver.resolve(from: "sub/other.md", target: "readme"), "sub/Readme.md")
        XCTAssertNil(resolver.resolve(from: "MEMORY.md", target: "../elsewhere/rule.md"))
        let graph = BackendMemoryParsing.graph(notes)
        XCTAssertEqual(graph.nodes, ["MEMORY.md", "Readme.md", "feedback.md", "sub/Readme.md"])
        XCTAssertFalse(graph.edges.contains { $0.from == $0.to })
        XCTAssertEqual(graph.edges.filter { $0.from == "feedback.md" }.count, 1)
        XCTAssertEqual(graph.dangling.map(\.target), ["../elsewhere/rule.md", "missing"])
    }
    func testBM25TitlePrefixScopeReplacementAndUnicode() {
        var index = BackendMemoryTextIndex()
        index.put(id: "keychain", title: "Keychain", body: "The vault keeps logins.")
        index.put(id: "vault", title: "Account vault", body: "One vault per machine. The vault file.")
        index.put(id: "relay", title: "Relay", body: "never Tailscale")
        XCTAssertEqual(index.search("vault").map(\.id), ["vault", "keychain"])
        XCTAssertEqual(index.search("tailsc").map(\.id), ["relay"])
        XCTAssertEqual(index.search("vault", filter: { $0 != "vault" }).map(\.id), ["keychain"])
        index.put(id: "relay", title: "beta", body: "beta"); XCTAssertTrue(index.search("tailsc").isEmpty)
        index.remove("relay"); XCTAssertEqual(index.size, 2); XCTAssertTrue(index.search("  ").isEmpty)
        XCTAssertEqual(BackendMemoryTextIndex.tokens("Grüße, 東京 2026!"), ["grüße", "東京", "2026"])
        XCTAssertTrue(BackendMemoryTextIndex.snippet(String(repeating: "x ", count: 80) + "needle " + String(repeating: "y ", count: 80), words: ["needle"]).hasPrefix("…"))
    }
    func testDiscoveryGroupsSharedStoresAndConfirmsProjects() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, memory) = try fixture(root)
        let found = BackendMemorySpaces.discover(env.input), alpha = try XCTUnwrap(found.first { $0.space.kind == .claudeProject })
        XCTAssertEqual(alpha.root, memory); XCTAssertEqual(alpha.space.label, "alpha"); XCTAssertEqual(alpha.space.project, "/work/alpha")
        XCTAssertEqual(alpha.space.sharedWith, ["/work/beta"]); XCTAssertEqual(alpha.space.accounts, ["Own", "Two"])
        XCTAssertEqual(found.map { $0.space.kind }, [.hoot, .claudeProject, .codex, .knowledge])
        try write(root + "/claude/projects/-odd-folder-name/memory/a.md", "odd")
        let odd = try XCTUnwrap(BackendMemorySpaces.discover(env.input).first { $0.space.label == "-odd-folder-name" }); XCTAssertNil(odd.space.project)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root + "/claude/projects/-work-beta/memory"), memory)
    }
    func testReadGraphLabelsNestedNotesAndScopedSearch() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, _) = try fixture(root)
        let service = BackendMemoryService(environment: env, watch: false), spaces = try await service.spaces()
        let alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject }), codex = try XCTUnwrap(spaces.first { $0.space.kind == .codex }), knowledge = try XCTUnwrap(spaces.first { $0.space.kind == .knowledge })
        let read = await service.read(alpha.id, path: .string("rule.md"))
        XCTAssertEqual(read["ok"].bool, true); XCTAssertEqual(read["indexed"].bool, true); XCTAssertEqual(read["backlinks"].elements?.compactMap(\.string), ["MEMORY.md"])
        XCTAssertEqual(read["links"].elements?.first?["to"].string, "keep.md")
        let nested = try await service.notes(codex.id); XCTAssertEqual(nested.first?["path"].string, "rollout_summaries/r.md")
        let labels = try await service.notes(knowledge.id).first?["labels"].elements ?? []
        XCTAssertEqual(labels.last?["value"].string, "2025-10-05")
        let hits = await service.searchIn("platypus", spaceIDs: [alpha.id]); XCTAssertEqual(hits.map { $0["path"].string }, ["keep.md"])
        let gone = await service.searchIn("platypus", spaceIDs: ["gone"]); XCTAssertTrue(gone.isEmpty)
        await service.close()
    }
    func testSaveRefusesEscapeAndConcurrentVersionAndLimits() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, memory) = try fixture(root)
        try write(root + "/outside.md", "outside")
        try FileManager.default.createSymbolicLink(atPath: memory + "/escape.md", withDestinationPath: root + "/outside.md")
        let service = BackendMemoryService(environment: env, watch: false), spaces = try await service.spaces()
        let alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject })
        let read = await service.read(alpha.id, path: .string("keep.md"))
        for path in ["../x.md", root + "/outside.md", "escape.md", "sub/../../x.md", "notes.txt", "C:\\file.md", "a\0.md"] {
            let result = await service.save(alpha.id, path: .string(path), text: .string("overwrite"), version: read["version"])
            XCTAssertEqual(result["ok"].bool, false, path)
        }
        let notes = try await service.notes(alpha.id); XCTAssertFalse(notes.contains { $0["path"].string == "escape.md" })
        try write(memory + "/keep.md", "agent changed this with a different size")
        let refused = await service.save(alpha.id, path: .string("keep.md"), text: .string("draft"), version: read["version"])
        XCTAssertTrue(refused["error"].string?.contains("changed after you opened") == true)
        let current = await service.read(alpha.id, path: .string("keep.md"))
        let saved = await service.save(alpha.id, path: .string("keep.md"), text: .string("Corrected.\n"), version: current["version"])
        XCTAssertEqual(saved["ok"].bool, true); XCTAssertEqual(try String(contentsOfFile: memory + "/keep.md", encoding: .utf8), "Corrected.\n")
        let large = await service.save(alpha.id, path: .string("keep.md"), text: .string(String(repeating: "x", count: BackendMemoryService.maxNoteBytes + 1)), version: saved["version"])
        XCTAssertEqual(large["error"].string, "A note cannot be larger than 256 KB.")
        await service.close()
    }
    func testTrashAndExactOptionalIndexLineRemoval() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, memory) = try fixture(root)
        let service = BackendMemoryService(environment: env, watch: false), spaces = try await service.spaces()
        let alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject })
        let deleted = await service.remove(alpha.id, path: .string("keep.md")); XCTAssertEqual(deleted["indexLineRemoved"].bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Trash/keep.md"))
        XCTAssertTrue(try String(contentsOfFile: memory + "/MEMORY.md", encoding: .utf8).contains("[Keep]"))
        let removed = await service.remove(alpha.id, path: .string("rule.md"), indexLine: true); XCTAssertEqual(removed["indexLineRemoved"].bool, true)
        XCTAssertEqual(try String(contentsOfFile: memory + "/MEMORY.md", encoding: .utf8), "# Index\n- [Keep](keep.md)\n")
        let outside = await service.remove(alpha.id, path: .string("../file.md")); XCTAssertEqual(outside["ok"].bool, false)
        await service.close()
    }
    func testReadTruncationAndProvenanceViaLinkedFolder() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, memory) = try fixture(root)
        try write(memory + "/big.md", String(repeating: "x", count: BackendMemoryService.maxNoteBytes + 10))
        let written = root + "/claude/projects/-work-beta/memory/keep.md"
        let line = BackendMemoryParsing.object([("timestamp", .string("2026-10-02T10:00:00Z")), ("message", BackendMemoryParsing.object([("content", .array([BackendMemoryParsing.object([("type", .string("tool_use")), ("name", .string("Write")), ("input", BackendMemoryParsing.object([("file_path", .string(written)), ("content", .string("x"))]))])]))]))])
        try write(root + "/claude/projects/-work-beta/writer.jsonl", "{\"cwd\":\"/work/beta\"}\n" + line.compact + "\n")
        let service = BackendMemoryService(environment: env, watch: false), spaces = try await service.spaces(), alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject }), codex = try XCTUnwrap(spaces.first { $0.space.kind == .codex })
        let big = await service.read(alpha.id, path: .string("big.md")); XCTAssertEqual(big["truncated"].bool, true); XCTAssertEqual(big["text"].string?.utf8.count, BackendMemoryService.maxNoteBytes)
        let found = await service.provenance(alpha.id, path: .string("keep.md")); XCTAssertEqual(found["writes"].elements?.first?["conversationId"].string, "writer")
        let wrongKind = await service.provenance(codex.id, path: .string("rollout_summaries/r.md")); XCTAssertEqual(wrongKind["ok"].bool, false)
        await service.close()
    }
    func testShareRequiresConsentAndDoesNotReplaceMemory() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (_, memory) = try fixture(root)
        let projects = root + "/claude/projects"
        let no = try await BackendMemorySpaces.share(projectsDir: projects, from: "/work/alpha", to: "/work/delta") { _, _ in false }
        XCTAssertEqual(no["ok"].bool, false); XCTAssertFalse(FileManager.default.fileExists(atPath: projects + "/-work-delta"))
        let yes = try await BackendMemorySpaces.share(projectsDir: projects, from: "/work/alpha", to: "/work/delta") { title, detail in title == "Share this memory?" && detail.contains("/work/delta") }
        XCTAssertEqual(yes["target"].string, memory)
        let existing = try await BackendMemorySpaces.share(projectsDir: projects, from: "/work/alpha", to: "/work/beta") { _, _ in XCTFail("must not ask"); return true }
        XCTAssertEqual(existing["ok"].bool, false)
    }
    func testHootActionLoggerIsOptionalAndDoesNotTurnSaveIntoFailure() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, _) = try fixture(root)
        let withoutLog = BackendMemoryTestEnvironment(input: env.input, trashDirectory: env.trashDirectory, log: nil)
        let service = BackendMemoryService(environment: withoutLog, watch: false), spaces = try await service.spaces()
        let hoot = try XCTUnwrap(spaces.first { $0.space.kind == .hoot }), read = await service.read(hoot.id, path: .string("MEMORY.md"))
        let saved = await service.save(hoot.id, path: .string("MEMORY.md"), text: .string("Changed.\n"), version: read["version"])
        XCTAssertEqual(saved["ok"].bool, true)
        await service.close()
        let withLog = BackendMemoryService(environment: env, watch: false), next = await withLog.read(hoot.id, path: .string("MEMORY.md"))
        let logged = await withLog.save(hoot.id, path: .string("MEMORY.md"), text: .string("Again.\n"), version: next["version"])
        XCTAssertEqual(logged["ok"].bool, true)
        XCTAssertEqual(try String(contentsOfFile: root + "/actions", encoding: .utf8), "memory.edited you edited memory/MEMORY.md from the Memory page")
        await withLog.close()
    }
    func testInjectedFileEventsKeepOpenedSpaceCurrent() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }; let (env, memory) = try fixture(root)
        let watch = BackendMemoryParityWatch(), clock = BackendMemoryParityClock(), events = BackendMemoryParityChanges()
        let service = BackendMemoryService(environment: env, watch: true, onChanged: { await events.append($0) },
            watchFactory: { watch.factory($0, $1) }, debounceClock: clock)
        let spaces = try await service.spaces(), alpha = try XCTUnwrap(spaces.first { $0.space.kind == .claudeProject })
        _ = try await service.notes(alpha.id)
        try write(memory + "/fresh.md", "A fact about wombats.")
        watch.fire(root: memory, paths: [memory + "/fresh.md"])
        await clock.scheduled(); await clock.advance()
        let arrived = await events.read(); XCTAssertEqual(arrived, [alpha.id])
        let hits = await service.searchIn("wombats", spaceIDs: [alpha.id]); XCTAssertEqual(hits.map { $0["path"].string }, ["fresh.md"])
        await service.close(); await clock.advance()
    }
}
