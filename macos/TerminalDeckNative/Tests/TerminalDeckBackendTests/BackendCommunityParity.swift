import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendCommunityParity: XCTestCase {
    private func row(_ patch: NativeRPCValue = .object([])) throws -> NativeRPCValue {
        try BackendGitHubParityJSON(#"{"id":"acme/thing","publisher":"acme","listedBy":"terminaldeck","kind":"skill","name":"A Thing","summary":"One honest line.","version":"1.0.0","licence":"MIT","category":"code","tags":["thing"],"agents":["claude","codex","gemini"],"platforms":["darwin","win32","linux"],"tier":1,"needs":[],"cost":"free","costNote":null,"delivery":"repo","source":{"repo":"acme/thing","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"skills/thing","host":"github.com"},"artifact":{"url":"https://x/t.tgz","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","bytes":10,"files":1,"unpacked":20},"install":{"kind":"skill","dir":"."},"icon":null,"ai":null,"repoStats":null,"network":[],"publishedAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-08-28T00:00:00.000Z"}"#).merging(patch)
    }
    private func item(_ row: NativeRPCValue, state: String = "available", note: String? = nil, installed: NativeRPCValue = .null) -> NativeRPCValue { BackendGitHubParityObject([("row", row), ("state", .string(state)), ("note", BackendGitHubRules.text(note)), ("installed", installed)]) }
    private func agents() -> [NativeRPCValue] { [BackendGitHubParityObject([("id", .string("claude")), ("name", .string("Claude Code")), ("found", .bool(true)), ("note", .string(""))]), BackendGitHubParityObject([("id", .string("codex")), ("name", .string("Codex CLI")), ("found", .bool(false)), ("note", .string("Codex CLI is not installed."))]), BackendGitHubParityObject([("id", .string("gemini")), ("name", .string("Gemini CLI")), ("found", .bool(true)), ("note", .string(""))])] }
    private func view(_ patch: NativeRPCValue = .object([])) throws -> NativeRPCValue { BackendGitHubParityObject([("ok", .bool(true)), ("why", .null), ("items", .array([item(try row())])), ("from", .string("store")), ("at", .string("2026-08-29T00:00:00.000Z")), ("stale", .null), ("because", .null), ("homes", try BackendGitHubParityJSON(#"{"claude":"/h/.claude","codex":"/h/.codex","gemini":"/h/.gemini"}"#)), ("folder", .string("/data/community/items"))]).merging(patch) }
    func testMissingRuntimeAndPresentRuntimeButNoHumanOrScriptNeeds() async throws {
        let missing = try await BackendCommunityProjection.missingNeeds(["python"], probe: BackendCommunityParityProbe(present: ["node"]))
        XCTAssertEqual(missing, ["python"])
        let present = try await BackendCommunityProjection.missingNeeds(["python", "node"], probe: BackendCommunityParityProbe(present: ["python3", "node"]))
        XCTAssertEqual(present, [])
        for needs in [["runs-scripts"], ["api-key", "account"], ["local-app"]] { let ignored = try await BackendCommunityProjection.missingNeeds(needs, probe: BackendCommunityParityProbe()); XCTAssertEqual(ignored, []) }
    }
    func testPublisherURLComesFromPinnedHostOrIsAbsent() throws {
        XCTAssertEqual(BackendCommunityProjection.profileURL(try row()), "https://github.com/acme")
        XCTAssertEqual(BackendCommunityProjection.profileURL(try row(BackendGitHubParityObject([("publisher", .string(""))]))), "")
        let source = try row()["source"].setting("host", .string(""))
        XCTAssertEqual(BackendCommunityProjection.profileURL(try row(BackendGitHubParityObject([("source", source)]))), "")
    }
    func testAgentLinesAreMeasuredAndUndefinedIsNotGuessed() {
        XCTAssertTrue(BackendCommunityProjection.agentLine(BackendCommunityParityProbe.binary("codex", runnable: nil)).contains("not installed"))
        XCTAssertEqual(BackendCommunityProjection.agentLine(BackendCommunityParityProbe.binary("claude", runnable: "/usr/bin/claude")), "")
        XCTAssertEqual(BackendCommunityProjection.agentLine(nil), "")
    }
    func testRepositoryOwnPushDateAndMissingStatsHaveExactFields() async throws {
        let stats = try BackendGitHubParityJSON(#"{"stars":12,"openIssues":3,"pushedAt":"2026-07-01T00:00:00.000Z","readAt":"2026-08-28T00:00:00.000Z"}"#)
        let projected = try await BackendCommunityProjection.projectItem(item(try row(BackendGitHubParityObject([("repoStats", stats)]))), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe(present: ["node", "python3"]))
        XCTAssertEqual(projected["updatedAt"].string, "2026-07-01T00:00:00.000Z"); XCTAssertEqual(projected["stars"].number, 12); XCTAssertEqual(projected["openIssues"].number, 3)
        let missing = try await BackendCommunityProjection.projectItem(item(try row()), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(missing["updatedAt"].string, ""); XCTAssertEqual(missing["stars"].number, -1); XCTAssertEqual(missing["openIssues"].number, -1)
    }
    func testFirstProjectionNamesOwnFolderWithBlankHomesAndClaimedAgentsOnly() async throws {
        let out = try await BackendCommunityProjection.projectItem(item(try row()), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe(present: ["node", "python3"]))
        let lands = out["lands"].elements!.compactMap(\.string)
        XCTAssertFalse(lands.contains { $0.contains("claude") }); XCTAssertEqual(lands.first, "/data/community/items/acme.thing")
    }
    func testPythonMcpCommandAndSecretVariableNamesOnly() async throws {
        let python = try BackendGitHubParityJSON(#"{"kind":"mcp","runtime":"python","package":"ddg-mcp","args":[],"inputs":[],"token":"ddg-mcp"}"#)
        let py = try await BackendCommunityProjection.projectItem(item(try row(BackendGitHubParityObject([("kind", .string("mcp")), ("tier", .number(3)), ("install", python)]))), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(py["command"].string, "uvx ddg-mcp")
        let node = try BackendGitHubParityJSON(#"{"kind":"mcp","runtime":"node","package":"thing","args":["${input:TOKEN}"],"inputs":[{"key":"TOKEN","label":"A token","hint":"From the dashboard","kind":"secret","into":"env","required":true}],"token":"thing"}"#)
        let out = try await BackendCommunityProjection.projectItem(item(try row(BackendGitHubParityObject([("kind", .string("mcp")), ("tier", .number(3)), ("install", node)]))), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(out["variables"], .array([.string("TOKEN")])); XCTAssertFalse(out.compact.contains("secret-value"))
    }
    func testWithdrawalSentenceDamageReasonInstalledVersionAndNoInventedRatings() async throws {
        let withdrawn = try await BackendCommunityProjection.projectItem(item(try row(), state: "withdrawn", note: "Withdrawn: the publisher asked."), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(withdrawn["reason"].string, "Withdrawn: the publisher asked."); XCTAssertEqual(withdrawn["message"].string, "Withdrawn: the publisher asked.")
        let damaged = try await BackendCommunityProjection.projectItem(item(try row(), state: "damaged", note: "It changed on disk."), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(damaged["reason"].string, ""); XCTAssertEqual(damaged["message"].string, "It changed on disk.")
        let available = try await BackendCommunityProjection.projectItem(item(try row()), agents: agents(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(available["installedVersion"].string, ""); XCTAssertEqual(available["ratingCount"].number, 0); XCTAssertEqual(available["ratingScore"].number, 0)
    }
    func testWholeViewEveryAgentAndExactRealHomesOnlyForFoundOnes() async throws {
        let out = try await BackendCommunityProjection.projectView(try view(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(out["agents"].elements?.map { $0["id"].string }, ["claude", "codex", "gemini"])
        let codex = out["agents"].elements!.first { $0["id"].string == "codex" }!
        XCTAssertEqual(codex["found"].bool, false); XCTAssertTrue(codex["note"].string!.contains("not installed"))
        let lands = out["items"].elements!.first!["lands"].elements!.compactMap(\.string)
        XCTAssertTrue(lands.contains("/h/.claude/skills/acme.thing")); XCTAssertTrue(lands.contains("/h/.gemini/skills/acme.thing")); XCTAssertFalse(lands.contains { $0.contains(".codex") })
    }
    func testWholeViewNullFieldsKeptReasonAndMissingCatalogueError() async throws {
        let ordinary = try await BackendCommunityProjection.projectView(try view(), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(ordinary["stale"].string, ""); XCTAssertEqual(ordinary["because"].string, ""); XCTAssertEqual(ordinary["problem"].string, ""); XCTAssertEqual(ordinary["from"].string, "store")
        let kept = try await BackendCommunityProjection.projectView(try view(BackendGitHubParityObject([("from", .string("kept")), ("because", .string("the store could not be reached from this machine"))])), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(kept["from"].string, "kept"); XCTAssertEqual(kept["because"].string, "the store could not be reached from this machine")
        let missing = try await BackendCommunityProjection.projectView(try view(BackendGitHubParityObject([("ok", .bool(false)), ("why", .string("this catalogue was not signed by Terminal Deck")), ("items", .array([])), ("from", .null), ("at", .null)])), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertEqual(missing["problem"].string, "this catalogue was not signed by Terminal Deck"); XCTAssertEqual(missing["items"], .array([])); XCTAssertEqual(missing["at"].string, "")
        let noReason = try await BackendCommunityProjection.projectView(try view(BackendGitHubParityObject([("ok", .bool(false)), ("why", .null), ("items", .array([]))])), userData: "/data", probe: BackendCommunityParityProbe())
        XCTAssertFalse(noReason["problem"].string!.isEmpty)
    }
    func testNativeProbeContractWithFixturePathAndFakeBinaryResolver() async throws {
        let dir = try BackendGitHubParityDirectory("community-native-probe"); defer { try? FileManager.default.removeItem(at: dir) }
        let node = dir.appendingPathComponent("node")
        try Data().write(to: node); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let paths = BackendGitHubParityCounter(), binaries = BackendCommunityParityBinaryCalls()
        let probe = BackendCommunityNativeProbe(loginPath: { _ = await paths.increment(); return dir.path }, resolveBinary: { await binaries.resolve($0, path: $1) })
        let nodePresent = try await probe.onPath("node"), pythonAbsent = try await probe.onPath("python3")
        XCTAssertTrue(nodePresent); XCTAssertFalse(pythonAbsent)
        // Runtime measurement is cached per probe, even if fixture files move.
        try FileManager.default.removeItem(at: node)
        let stillMeasured = try await probe.onPath("node"); XCTAssertTrue(stillMeasured)
        let agents = try await probe.agents(), recorded = await binaries.calls(), pathCalls = await paths.value()
        XCTAssertEqual(Set(agents.keys), Set(["claude", "codex", "gemini"]))
        XCTAssertEqual(Set(recorded.map(\.0)), Set(["claude", "codex", "gemini"]))
        XCTAssertTrue(recorded.allSatisfy { $0.1 == dir.path }); XCTAssertEqual(pathCalls, 2)
        XCTAssertNil(agents["codex"]?.runnable); XCTAssertNotNil(agents["claude"]?.runnable)
    }
}

struct BackendCommunityParityProbe: BackendCommunityMachineProbing {
    let present: Set<String>
    init(present: Set<String> = []) { self.present = present }
    static func binary(_ id: String, runnable: String?) -> BackendNativeProviders.Binary { .init(id: id, onPath: runnable, runnable: runnable, version: nil, broken: false, said: nil, usedAlternate: false, checkedAt: Date(timeIntervalSince1970: 0)) }
    func onPath(_ binary: String) async throws -> Bool { present.contains(binary) }
    func agents() async throws -> [String: BackendNativeProviders.Binary] { ["claude": Self.binary("claude", runnable: "/usr/bin/claude"), "codex": Self.binary("codex", runnable: nil), "gemini": Self.binary("gemini", runnable: "/usr/bin/gemini")] }
}
private actor BackendCommunityParityBinaryCalls {
    private var seen: [(String, String)] = []
    func resolve(_ id: String, path: String) -> BackendNativeProviders.Binary {
        seen.append((id, path))
        return BackendCommunityParityProbe.binary(id, runnable: id == "codex" ? nil : "/fixture/" + id)
    }
    func calls() -> [(String, String)] { seen }
}
