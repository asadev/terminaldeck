import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor
final class BackendCommunityProjectionTests: XCTestCase {
    private func row(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        BackendGitHubRules.object([("id", .string("acme/thing")), ("publisher", .string("acme")), ("kind", .string("skill")), ("name", .string("A Thing")), ("agents", .array([.string("claude"), .string("codex"), .string("gemini")])), ("source", BackendGitHubRules.object([("host", .string("github.com")), ("repo", .string("acme/thing")), ("commit", .string(String(repeating: "a", count: 40)))])), ("needs", .array([]))]).merging(patch)
    }
    private func item(_ row: NativeRPCValue, state: String = "available", note: String = "") -> NativeRPCValue { BackendGitHubRules.object([("row", row), ("state", .string(state)), ("note", .string(note)), ("installed", .null)]) }
    private let agents: [NativeRPCValue] = ["claude", "gemini"].map { BackendGitHubRules.object([("id", .string($0)), ("found", .bool(true))]) }
    func testMissingNeedsMeasuresOnlyNamedRuntimes() async throws {
        let missing = try await BackendCommunityProjection.missingNeeds(["node", "python", "api-key", "account", "local-app", "runs-scripts"], probe: BackendCommunityFixtureProbe(present: ["node"]))
        XCTAssertEqual(missing, ["python"])
    }
    func testRepositoryFactsAndNoInventedRatings() async throws {
        let projection = try await BackendCommunityProjection.projectItem(item(row()), agents: agents, userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(projection["updatedAt"].string, ""); XCTAssertEqual(projection["stars"].number, -1); XCTAssertEqual(projection["ratingCount"].number, 0); XCTAssertEqual(projection["ratingScore"].number, 0)
        let dated = row(BackendGitHubRules.object([("updatedAt", .string("listing-date")), ("repoStats", BackendGitHubRules.object([("pushedAt", .string("repository-date")), ("stars", .number(12)), ("openIssues", .number(3))]))]))
        let projectionWithStats = try await BackendCommunityProjection.projectItem(item(dated), agents: agents, userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(projectionWithStats["updatedAt"].string, "repository-date"); XCTAssertEqual(projectionWithStats["openIssues"].number, 3)
    }
    func testRealHomesAndEveryAgentReported() async throws {
        let homes = BackendGitHubRules.object([("claude", .string("/h/.claude")), ("codex", .string("/h/.codex")), ("gemini", .string("/h/.gemini"))])
        let view = BackendGitHubRules.object([("ok", .bool(true)), ("items", .array([item(row())])), ("homes", homes), ("folder", .string("/data/community/items"))])
        let out = try await BackendCommunityProjection.projectView(view, userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(out["agents"].elements?.compactMap { $0["id"].string }, ["claude", "codex", "gemini"])
        let lands = out["items"].elements?.first?["lands"].elements?.compactMap(\.string) ?? []
        XCTAssertTrue(lands.contains("/h/.claude/skills/acme.thing")); XCTAssertTrue(lands.contains("/h/.gemini/skills/acme.thing")); XCTAssertFalse(lands.contains { $0.contains(".codex") })
        XCTAssertEqual(out["from"].string, "store"); XCTAssertEqual(out["stale"].string, "")
    }
    func testMcpCommandComesFromCodeAndVariablesAreOnlyNames() async throws {
        let install = BackendGitHubRules.object([("kind", .string("mcp")), ("runtime", .string("node")), ("package", .string("thing")), ("args", .array([.string("${input:TOKEN}")])), ("inputs", .array([BackendGitHubRules.object([("key", .string("TOKEN"))])]))])
        let out = try await BackendCommunityProjection.projectItem(item(row(BackendGitHubRules.object([("kind", .string("mcp")), ("install", install)]))), agents: agents, userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(out["command"].string, "npx -y thing ${TOKEN}"); XCTAssertEqual(out["variables"], .array([.string("TOKEN")]))
        XCTAssertEqual(out["offsiteUrl"].string, ""); XCTAssertEqual(out["trigger"].string, "")
    }
    func testWithdrawalReasonMatchesStateMessageAndKeptCatalogue() async throws {
        let out = try await BackendCommunityProjection.projectItem(item(row(), state: "withdrawn", note: "Withdrawn: publisher asked."), agents: agents, userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(out["reason"], out["message"])
        let view = try await BackendCommunityProjection.projectView(BackendGitHubRules.object([("ok", .bool(false)), ("from", .string("kept")), ("why", .string("signature failed")), ("because", .string("offline")), ("items", .array([]))]), userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(view["from"].string, "kept"); XCTAssertEqual(view["problem"].string, "signature failed"); XCTAssertEqual(view["because"].string, "offline")
    }
    func testTargetsIncludeCodexInstructionReferenceAndRoutineOffStateNotGuessed() {
        let homes = BackendGitHubRules.object([("codex", .string("/h/.codex"))])
        XCTAssertEqual(BackendCommunityProjection.plannedTargets(row: row(), agents: ["codex"], homes: homes, userData: "/data"), ["/data/community/items/acme.thing", "/h/.codex/skills/acme.thing", "/h/.codex/AGENTS.md"])
        XCTAssertEqual(BackendCommunityProjection.plannedTargets(row: row(BackendGitHubRules.object([("kind", .string("routine"))])), agents: [], homes: homes, userData: "/data"), ["/data/community/items/acme.thing", "/data/routines/acme-thing.md"])
    }
    func testUnavailableStoreIsAnExplicitFailure() async throws {
        let registry = NativeChannelRegistry()
        let channels = try await BackendCommunityChannels.register(registry: registry, ownerID: "fixture", store: nil, userData: "/data", probe: BackendCommunityFixtureProbe())
        XCTAssertEqual(channels, ["community:list", "community:install", "community:remove"])
        let result = try await registry.invoke("community:install", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.string("a/b")])
        XCTAssertEqual(result["ok"].bool, false); XCTAssertEqual(result["message"].string, BackendCommunityChannels.unavailable)
        let view = try await registry.invoke("community:list", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [])
        XCTAssertEqual(view["problem"].string, BackendCommunityChannels.unavailable)
    }
}

struct BackendCommunityFixtureProbe: BackendCommunityMachineProbing {
    let present: Set<String>
    init(present: Set<String> = []) { self.present = present }
    func onPath(_ binary: String) async throws -> Bool { present.contains(binary) }
    func agents() async throws -> [String: BackendNativeProviders.Binary] {
        Dictionary(BackendCommunityProjection.agentIDs.map { id in
            let path = id == "codex" ? nil : "/fixture/" + id
            return (id, .init(id: id, onPath: path, runnable: path, version: nil, broken: false, said: nil, usedAlternate: false, checkedAt: Date(timeIntervalSince1970: 0)))
        }, uniquingKeysWith: { first, _ in first })
    }
}
