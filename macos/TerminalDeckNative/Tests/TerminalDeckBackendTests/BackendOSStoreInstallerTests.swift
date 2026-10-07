import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendOSStoreInstallFixture {
    static func item(kind: String = "skill", install: NativeRPCValue = .object([.init("dir", .string("skill"))]),
                     extra: [BackendOSStoreArchiveFixture.Entry] = [.init("skill/SKILL.md", "# Skill\n")], tier: Int = 1) throws -> (archive: Data, row: NativeRPCValue) {
        let manifest: NativeRPCValue = .object([
            .init("terminaldeck", .number(1)), .init("publisher", .string("pub")), .init("id", .string("thing")), .init("kind", .string(kind)),
            .init("name", .string("A Thing")), .init("summary", .string("One honest line about it.")), .init("version", .string("1.0.0")),
            .init("licence", .string("MIT")), .init("category", .string("utility")), .init("tags", .array([])), .init("agents", .array([.string("claude"), .string("codex"), .string("gemini")])),
            .init("platforms", .array([.string("darwin"), .string("win32"), .string("linux")])), .init("delivery", .string("repo")),
            .init("pricing", .object([.init("model", .string("free")), .init("note", .null), .init("url", .null)])), .init("licenceEnv", .null), .init("aiFile", .null),
            .init("links", .object([.init("repo", .string("https://github.com/pub/thing")), .init("home", .null), .init("docs", .null)])), .init("needs", .array([])), .init("install", install)])
        let parsed = BackendSharedStoreManifest.parse(manifest.compact, expectedPublisher: "pub", expectedID: "thing")
        let normalized = try XCTUnwrap(parsed.value, parsed.why ?? "manifest refused")
        let entries = [BackendOSStoreArchiveFixture.Entry("root/terminaldeck.json", manifest.compact)] + extra.map { entry in
            BackendOSStoreArchiveFixture.Entry("root/" + entry.name, String(decoding: entry.body, as: UTF8.self), type: entry.type, mode: entry.mode, statedSize: entry.statedSize)
        }
        let archive = try BackendOSStoreArchiveFixture.tarGzip(entries)
        let row: NativeRPCValue = .object([
            .init("id", .string("pub/thing")), .init("publisher", .string("pub")), .init("listedBy", .string("pub")), .init("kind", .string(kind)),
            .init("name", .string("A Thing")), .init("summary", .string("One honest line about it.")), .init("version", .string("1.0.0")), .init("licence", .string("MIT")),
            .init("category", .string("utility")), .init("tags", .array([])), .init("agents", normalized["agents"]), .init("platforms", normalized["platforms"]), .init("tier", .number(Double(tier))),
            .init("needs", .array([])), .init("cost", .string("free")), .init("costNote", .null), .init("delivery", .string("repo")),
            .init("source", .object([.init("repo", .string("https://github.com/pub/thing")), .init("commit", .string(String(repeating: "a", count: 40))), .init("path", .string(".")), .init("host", .string("github.com"))])),
            .init("artifact", .object([.init("url", .string("https://example.invalid/item.tar.gz")), .init("sha256", .string(SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined())), .init("bytes", .number(Double(archive.count))), .init("files", .number(Double(entries.count))), .init("unpacked", .number(Double(entries.reduce(0) { $0 + $1.body.count })))])),
            .init("install", normalized["install"]), .init("network", .array([])), .init("icon", .null), .init("ai", .null), .init("repoStats", .null),
            .init("publishedAt", .string("2026-08-01T00:00:00.000Z")), .init("updatedAt", .string("2026-08-01T00:00:00.000Z"))])
        return (archive, row)
    }
    static func loaded(_ rows: [NativeRPCValue], revoked: [NativeRPCValue] = []) -> NativeRPCValue {
        .object([.init("ok", .bool(true)), .init("index", .object([
            .init("v", .number(1)), .init("serial", .number(1)), .init("issuedAt", .string("2026-08-01T00:00:00.000Z")), .init("expiresAt", .null), .init("generator", .string("fixture")),
            .init("truncated", .bool(false)), .init("items", .array(rows)), .init("revoked", .array(revoked))])), .init("from", .string("store")), .init("at", .string("2026-08-29T00:00:00.000Z")), .init("stale", .null), .init("because", .null)])
    }
}

final class BackendOSStoreInstallerTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func store(root: URL, row: NativeRPCValue, archive: Data, writable: Bool = true,
                       revoked: [NativeRPCValue] = [], run: @escaping BackendOSStoreInstaller.RunAgent = { _, _ in .object([.init("ok", .bool(true)), .init("message", .string(""))]) }) throws -> BackendOSStoreInstaller {
        try BackendOSStoreInstaller(userData: root.appendingPathComponent("data"), environment: [:], home: root.appendingPathComponent("home").path, writable: writable,
            loadIndex: { BackendOSStoreInstallFixture.loaded([row], revoked: revoked) }, fetchArtifact: { _, _ in .init(ok: true, bytes: archive) }, runAgent: run)
    }
    func testAgentHomesAndGeminiParent() {
        XCTAssertEqual(BackendOSStoreInstaller.agentHome("claude", environment: ["CLAUDE_CONFIG_DIR": "/x/c"], home: "/home"), "/x/c")
        XCTAssertEqual(BackendOSStoreInstaller.agentHome("gemini", environment: ["GEMINI_CLI_HOME": "/x/g"], home: "/home"), "/x/g/.gemini")
        XCTAssertEqual(BackendOSStoreInstaller.agentHomes(environment: [:], home: "/home")["codex"].string, "/home/.codex")
    }
    func testSkillInstallRemoveKeepsHandwrittenNeighboursAndMemory() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackendOSStoreInstallFixture.item(), installer = try store(root: root, row: fixture.row, archive: fixture.archive)
        let memory = root.appendingPathComponent("home/.codex/AGENTS.md")
        try FileManager.default.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = "# My notes\n\nSomething I wrote.\n"; try Data(before.utf8).write(to: memory)
        let result = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("claude"), .string("codex")]))]))
        XCTAssertEqual(result["ok"].bool, true)
        XCTAssertTrue(try String(contentsOf: memory, encoding: .utf8).contains("Skill available"))
        let neighbour = root.appendingPathComponent("home/.claude/skills/mine/SKILL.md")
        try FileManager.default.createDirectory(at: neighbour.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("mine".utf8).write(to: neighbour)
        let removed = try await installer.remove(id: "pub/thing"); XCTAssertEqual(removed["ok"].bool, true)
        XCTAssertEqual(try String(contentsOf: memory, encoding: .utf8), before); XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
        XCTAssertEqual(BackendOSStoreInstaller.readLedger(root.appendingPathComponent("data")), [])
    }
    func testLengthDigestManifestAndTierChecksPrecedeWrites() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }; let fixture = try BackendOSStoreInstallFixture.item()
        let rows = [fixture.row.setting("artifact", fixture.row["artifact"].setting("bytes", .number(1))), fixture.row.setting("artifact", fixture.row["artifact"].setting("sha256", .string(String(repeating: "0", count: 64)))), fixture.row.setting("version", .string("2.0.0"))]
        for row in rows { let installer = try store(root: root, row: row, archive: fixture.archive); let result = try await installer.install(id: "pub/thing"); XCTAssertEqual(result["ok"].bool, false) }
        let scripted = try BackendOSStoreInstallFixture.item(extra: [.init("skill/SKILL.md", "x"), .init("skill/do.sh", "echo x")])
        let installer = try store(root: root, row: scripted.row, archive: scripted.archive), result = try await installer.install(id: "pub/thing")
        XCTAssertTrue(result["message"].string?.contains("skill/do.sh") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/community/items/pub.thing").path))
    }
    func testExistingSkillAndMissingSkillRefuse() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }; let fixture = try BackendOSStoreInstallFixture.item()
        let target = root.appendingPathComponent("home/.claude/skills/pub.thing/SKILL.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("mine".utf8).write(to: target)
        let installer = try store(root: root, row: fixture.row, archive: fixture.archive), result = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("claude")]))]))
        XCTAssertEqual(result["ok"].bool, false); XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "mine")
        let empty = try BackendOSStoreInstallFixture.item(extra: [.init("skill/notes.md", "no skill")]), other = try store(root: root, row: empty.row, archive: empty.archive)
        let missing = try await other.install(id: "pub/thing"); XCTAssertTrue(missing["message"].string?.contains("SKILL.md") == true)
    }
    func testRoutineDisarmedAndUserFolderReplacesPublishedFolder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let body = "# Nightly\n\nwhen: schedule 09:00\nin: /publisher/chose\n\n---\n\nSweep.\n"
        let fixture = try BackendOSStoreInstallFixture.item(kind: "routine", install: .object([.init("file", .string("routine.md"))]), extra: [.init("routine.md", body)], tier: 2)
        let installer = try store(root: root, row: fixture.row, archive: fixture.archive)
        let missing = try await installer.install(id: "pub/thing"); XCTAssertEqual(missing["ok"].bool, false)
        let result = try await installer.install(id: "pub/thing", choice: .object([.init("folder", .string("/chosen"))])); XCTAssertEqual(result["ok"].bool, true)
        let text = try String(contentsOf: root.appendingPathComponent("data/routines/pub-thing.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("enabled: no")); XCTAssertTrue(text.contains("in: /chosen")); XCTAssertFalse(text.contains("/publisher/chose"))
    }
    func testInstructionsUseImportOnlyWhereAgentReadsIt() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackendOSStoreInstallFixture.item(kind: "instructions", install: .object([.init("file", .string("rules.md"))]), extra: [.init("rules.md", "Be brief.")])
        let installer = try store(root: root, row: fixture.row, archive: fixture.archive), result = try await installer.install(id: "pub/thing"); XCTAssertEqual(result["ok"].bool, true)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("home/.claude/CLAUDE.md"), encoding: .utf8).contains("@instructions/pub.thing.md"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("home/.codex/AGENTS.md"), encoding: .utf8).contains("Standing instructions: A Thing"))
    }
    func testViewDamagedOutdatedAndDelistedRowsRemainVisible() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }; let fixture = try BackendOSStoreInstallFixture.item()
        let installer = try store(root: root, row: fixture.row, archive: fixture.archive)
        _ = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("claude")]))]))
        var view = try await installer.view(); XCTAssertEqual(view["items"].elements?.first?["state"].string, "installed")
        let later = try store(root: root, row: fixture.row.setting("version", .string("2.0.0")), archive: fixture.archive)
        view = try await later.view(); XCTAssertEqual(view["items"].elements?.first?["state"].string, "outdated")
        try Data("edited".utf8).write(to: root.appendingPathComponent("data/community/items/pub.thing/skill/SKILL.md"))
        view = try await installer.view(); XCTAssertEqual(view["items"].elements?.first?["state"].string, "damaged")
        let empty = try BackendOSStoreInstaller(userData: root.appendingPathComponent("data"), environment: [:], home: root.path, loadIndex: { BackendOSStoreInstallFixture.loaded([]) })
        view = try await empty.view(); XCTAssertEqual(view["items"].elements?.first?["state"].string, "withdrawn")
    }
    func testMcpExactArgumentsAndMissingInputsRefuse() {
        XCTAssertEqual(BackendOSStoreInstaller.mcpAddArguments(agent: "codex", name: "n", argv: ["npx", "p"], extras: ["K=v"]), ["mcp", "add", "n", "--env", "K=v", "--", "npx", "p"])
        XCTAssertEqual(BackendOSStoreInstaller.mcpAddArguments(agent: "gemini", name: "n", argv: ["npx"], extras: []), ["mcp", "add", "-s", "user", "-t", "stdio", "n", "npx"])
        XCTAssertEqual(BackendOSStoreInstaller.mcpRemoveArguments(agent: "gemini", name: "n"), ["mcp", "remove", "-s", "user", "n"])
        XCTAssertEqual(BackendOSStoreInstaller.mcpRemoveArguments(agent: "codex", name: "n"), ["mcp", "remove", "n"])
    }
    func testSecondAgentFailureRollsBackAndFailedRemoveStaysInLedger() async throws {
        actor Calls { var operations: [String] = []; func record(_ agent: String, _ args: [String]) -> NativeRPCValue { operations.append(agent + ":" + (args.count > 1 ? args[1] : "")); return .object([.init("ok", .bool(agent != "gemini")), .init("message", .string("gemini said no"))]) }; func list() -> [String] { operations } }
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let install: NativeRPCValue = .object([.init("runtime", .string("node")), .init("package", .string("thing-server")), .init("args", .array([])), .init("inputs", .array([])), .init("token", .string("thing-server"))])
        let fixture = try BackendOSStoreInstallFixture.item(kind: "mcp", install: install, extra: [], tier: 3), calls = Calls()
        let installer = try store(root: root, row: fixture.row, archive: fixture.archive, run: { await calls.record($0, $1) })
        let result = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("codex"), .string("gemini")]))])); XCTAssertEqual(result["ok"].bool, false)
        let operations = await calls.list(); XCTAssertEqual(operations, ["codex:add", "gemini:add", "codex:remove"])
        XCTAssertEqual(BackendOSStoreInstaller.readLedger(root.appendingPathComponent("data")), [])
        _ = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("codex")]))]))
        let stubborn = try store(root: root, row: fixture.row, archive: fixture.archive, run: { _, _ in .object([.init("ok", .bool(false)), .init("message", .string("tool is not installed"))]) })
        let removed = try await stubborn.remove(id: "pub/thing"); XCTAssertEqual(removed["ok"].bool, false)
        XCTAssertEqual(BackendOSStoreInstaller.readLedger(root.appendingPathComponent("data")).first?["writes"].elements?.count, 1)
    }
    func testReadOnlyOwnershipAndRevokedItemsRefuse() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }; let fixture = try BackendOSStoreInstallFixture.item()
        let readonly = try store(root: root, row: fixture.row, archive: fixture.archive, writable: false)
        do { _ = try await readonly.install(id: "pub/thing"); XCTFail("Read-only writer mutated") } catch { XCTAssertTrue(error.localizedDescription.contains("Node owns")) }
        let revoked = try store(root: root, row: fixture.row, archive: fixture.archive, revoked: [.object([.init("id", .string("pub/thing")), .init("version", .string("*")), .init("reason", .string("bad"))])])
        let result = try await revoked.install(id: "pub/thing"); XCTAssertTrue(result["message"].string?.contains("withdrawn") == true)
    }
    func testGrammarVocabulariesAgreeWithInstalledMcpStore() {
        for runtime in BackendSharedStoreManifest.mcpRuntimes { XCTAssertNotNil(BackendMcpClientCatalogue.runtimeBinary[runtime]) }
        XCTAssertFalse(BackendSharedStoreManifest.mcpRuntimes.contains("docker"))
        XCTAssertEqual(Set(BackendSharedStoreManifest.agents), ["claude", "codex", "gemini"])
    }
}
