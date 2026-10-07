import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendKnowledgeTestAuthority: BackendKnowledgeToolAuthority {
    let identity: BackendKnowledgeToolCaller; let known: Set<String>
    func caller(_ context: BackendMCPCallContext) async throws -> BackendKnowledgeToolCaller { identity }
    func requireKnownFolder(_ project: String) async throws -> String {
        guard known.contains(project) else { throw NativeRPCError(code: "not-permitted", message: "\(project) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return project
    }
    func authorize(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws {
        guard context.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-permitted", message: "tier not granted") }
    }
}
@MainActor
final class BackendKnowledgeMCPTests: XCTestCase {
    private func context(machine: String = "") -> BackendMCPCallContext {
        .init(sessionID: "s1", machineID: machine, projectRoot: nil, attended: true, allowedTools: Set(BackendKnowledgeMCP.localToolIDs + BackendKnowledgeMCP.sessionToolIDs + ["memory.read", "memory.search"]), allowedTiers: [.read, .act], cancellation: .init())
    }
    private func temp() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-knowledge-mcp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return try BackendFilesystemAuthority.canonical(url).path
    }
    private func args(project: String, kind: String = "decision") -> NativeRPCValue {
        BackendMemoryParsing.object([("project", .string(project)), ("kind", .string(kind)), ("subject", .string("CI")), ("statement", .string("Never ship on red."))])
    }
    func testSchemasNamesTiersAudienceAndIndex() throws {
        let tools = try BackendKnowledgeMCP.specifications()
        XCTAssertEqual(tools.map(\.id), ["knowledge.search", "knowledge.get", "knowledge.record", "knowledge.supersede", "knowledge.note"])
        XCTAssertEqual(tools.filter { $0.tier == .read }.map(\.id), ["knowledge.search", "knowledge.get"])
        for tool in tools { XCTAssertEqual(tool.wireName, tool.id.replacingOccurrences(of: ".", with: "_")); XCTAssertEqual(tool.inputSchema["additionalProperties"].bool, false); XCTAssertFalse(tool.advertised) }
        XCTAssertEqual(BackendKnowledgeMCP.sessionToolIDs, ["knowledge.note"])
        XCTAssertEqual(try BackendMemoryMCP.specifications().map(\.wireName), ["memory_search", "memory_read"])
        XCTAssertEqual(BackendKnowledgeMCP.grantToolNames(for: .session), ["knowledge.note", "knowledge_note"])
        XCTAssertTrue(BackendKnowledgeMCP.grantToolNames(for: .session, machineID: "remote").isEmpty)
        XCTAssertFalse(BackendKnowledgeMCP.grantToolNames(for: .local).contains("knowledge.note"))
        XCTAssertTrue(BackendKnowledgeMCP.grantToolNames(for: .key).isEmpty)
        XCTAssertTrue(BackendMemoryMCP.grantToolNames(for: .remote).isEmpty)
        for line in BackendKnowledgeMCP.index.values { XCTAssertTrue(line.hasSuffix(".")); XCTAssertGreaterThan(line.count, 60); XCTAssertLessThan(line.count, 200) }
    }
    func testLocalRecordSearchGetAndSupersede() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let project = root + "/api", service = BackendKnowledgeService(userData: root + "/data"), authority = BackendKnowledgeTestAuthority(identity: .init(kind: .local), known: [project])
        let result = try await BackendKnowledgeMCP.call(tool: "knowledge.record", args: args(project: project).setting("as", .string("owner")), context: context(), service: service, authority: authority)
        let id = try XCTUnwrap(result["record"]["id"].string); XCTAssertEqual(result["record"]["status"].string, "claim"); XCTAssertEqual(result["record"]["source"].string, "owner")
        let search = try await BackendKnowledgeMCP.call(tool: "knowledge.search", args: BackendMemoryParsing.object([("project", .string(project)), ("query", .string("ship CI"))]), context: context(), service: service, authority: authority)
        XCTAssertEqual(search["records"].elements?.first?["id"].string, id); XCTAssertEqual(search["of"].number, 1)
        let readArgs = BackendMemoryParsing.object([("project", .string(project)), ("id", .string(id))])
        let read = try await BackendKnowledgeMCP.call(tool: "knowledge.get", args: readArgs, context: context(), service: service, authority: authority)
        XCTAssertEqual(read["record"]["statement"].string, "Never ship on red.")
        let replaced = try await BackendKnowledgeMCP.call(tool: "knowledge.supersede", args: readArgs.setting("reason", .string("changed")).setting("statement", .string("Green only.")), context: context(), service: service, authority: authority)
        XCTAssertEqual(replaced["superseded"]["status"].string, "superseded"); XCTAssertEqual(replaced["replacement"]["supersedes"].string, id)
    }
    func testHootOnlyAndWorkerCannotWriteVerifiedOrOtherKinds() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let project = root + "/api", service = BackendKnowledgeService(userData: root + "/data")
        let local = BackendKnowledgeTestAuthority(identity: .init(kind: .local), known: [project]), worker = BackendKnowledgeTestAuthority(identity: .init(kind: .session, task: .init(taskId: "local:9", project: project, agentId: "builder", goalId: "g1")), known: [project])
        for kind in [BackendKnowledgeToolCaller.Kind.key, .remote, .session] {
            let authority = BackendKnowledgeTestAuthority(identity: .init(kind: kind), known: [project])
            do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.search", args: args(project: project), context: context(), service: service, authority: authority); XCTFail("Hoot-only tool accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("Hoot’s own tool")) }
        }
        for key in ["status", "verified", "verifiedAt"] {
            do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(project: project).setting(key, .string("verified")), context: context(), service: service, authority: worker); XCTFail("status accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("only a task’s review")) }
        }
        do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.record", args: args(project: project, kind: "result"), context: context(), service: service, authority: local); XCTFail("result accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("kind must be one of")) }
        do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(project: project), context: context(machine: "remote"), service: service, authority: worker); XCTFail("remote worker accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("another one")) }
        do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(project: project), context: context(), service: service, authority: local); XCTFail("Hoot note accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("knowledge_record")) }
    }
    func testWorkerTaskScopeOverridesNamedProjectAndKeepsProvenance() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let api = root + "/api", web = root + "/web", service = BackendKnowledgeService(userData: root + "/data")
        let authority = BackendKnowledgeTestAuthority(identity: .init(kind: .session, task: .init(taskId: "local:9", project: api, agentId: "builder", goalId: "g1", conversationId: "c9")), known: [api, web])
        let value = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(project: web).setting("statement", .string("Verified: tests pass.")).setting("evidence", BackendMemoryParsing.strings([api + "/src/a.ts"])), context: context(), service: service, authority: authority)
        XCTAssertEqual(value["noted"]["status"].string, "claim")
        let views = try await service.list(api), p = try XCTUnwrap(views.first).record.provenance
        XCTAssertEqual(p, .init(source: "worker", taskId: "local:9", goalId: "g1", agentId: "builder", sessionId: "s1", conversationId: "c9", evidence: ["src/a.ts"]))
        let other = try await service.list(web); XCTAssertTrue(other.isEmpty)
    }
    func testUnknownProjectMalformedEvidenceAndBoundsRefuse() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let project = root + "/api", service = BackendKnowledgeService(userData: root + "/data"), authority = BackendKnowledgeTestAuthority(identity: .init(kind: .local), known: [project])
        do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.search", args: args(project: "/etc"), context: context(), service: service, authority: authority); XCTFail("unknown project accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("not a folder this app has open")) }
        do { _ = try await BackendKnowledgeMCP.call(tool: "knowledge.record", args: args(project: project).setting("evidence", .array([.number(1)])), context: context(), service: service, authority: authority); XCTFail("evidence accepted") } catch { XCTAssertEqual(error.localizedDescription, "evidence must be a list of strings") }
        XCTAssertEqual(try BackendKnowledgeToolArguments.integer(BackendMemoryParsing.object([("limit", .number(100))]), "limit", fallback: 20, min: 1, max: 50), 50)
        XCTAssertEqual(try BackendKnowledgeToolArguments.integer(BackendMemoryParsing.object([("limit", .number(-1))]), "limit", fallback: 20, min: 1, max: 50), 1)
    }
    func testMemoryRefusesKeyAndSessionNamedProject() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(atPath: root) }
        struct Environment: BackendMemoryEnvironment { func sources() async throws -> BackendMemorySources { .init(stores: [], hootMemory: nil, userData: nil) } }
        let service = BackendMemoryService(environment: Environment(), watch: false)
        let key = BackendKnowledgeTestAuthority(identity: .init(kind: .key), known: [])
        do { _ = try await BackendMemoryMCP.call(tool: "memory.search", args: BackendMemoryParsing.object([("query", .string("x"))]), context: context(), service: service, authority: key); XCTFail("key accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("read on this computer only")) }
        let session = BackendKnowledgeTestAuthority(identity: .init(kind: .session), known: [])
        do { _ = try await BackendMemoryMCP.scope(service: service, authority: session, context: context(), project: root); XCTFail("named project accepted") } catch { XCTAssertEqual(error.localizedDescription, "A session reads its own memory only; it cannot name another project.") }
        await service.close()
    }
}
