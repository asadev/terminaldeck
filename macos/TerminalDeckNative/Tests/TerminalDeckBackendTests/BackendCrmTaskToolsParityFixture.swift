import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// local-task-tools.test.ts: `island: () => ({ get, set })` over `{ enabled: true }`.
actor BackendCrmTaskToolsParityIsland {
    var enabled = true
    func set(_ value: Bool) -> Bool { enabled = value; return enabled }
}
actor BackendCrmTaskToolsParityAudit {
    var tiers: [BackendMCPTier] = []
    func record(_ tier: BackendMCPTier) { tiers.append(tier) }
}
struct BackendCrmTaskToolsParityFixture: Sendable {
    let f: BackendCrmTaskDetailParityFixture, server: BackendNativeMCPServer, engine: BackendTaskEngine
    let planning: BackendGoalPlanning, audit: BackendCrmTaskToolsParityAudit
    let io: BackendCrmTaskDetailParityNativeIO
    let registrations: [(BackendMCPTool, BackendNativeMCPServer.Handler)]
    static func make(localOnly: Bool = false, io suppliedIO: BackendCrmTaskDetailParityNativeIO? = nil, knowledge: BackendKnowledgeService? = nil, control: BackendTaskControlOperations? = nil) async throws -> Self {
        let io: BackendCrmTaskDetailParityNativeIO
        if let suppliedIO { io = suppliedIO } else { io = try await BackendCrmTaskDetailParityNativeIO.make(notify: true) }
        let f = io.fixture
        if localOnly { try await f.config.removeAgent("tester") }
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] }, start: { _,_,_,_,_ in throw NativeRPCError(code: "test-process", message: "No production process may be launched by these tests.") }, send: { _,_ in }, stop: { _ in }, setControl: { _,_,_ in }, check: { _,_ in (true, "fake verification") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: f.store, configuration: f.config, goals: f.goals, access: access, workspace: { $0.project }, problem: { _ in })
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/crm-tool-parity-inert"), ownership: .memory)
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil }, post: { _,_ in throw NativeRPCError(code: "test-network", message: "No network may be used by these tests.") }, onCommentID: { _,_ in }, problem: { _ in })
        let view = BackendTaskStateView(store: f.store, configuration: f.config, goals: f.goals, outbox: outbox, keyViews: { [] })
        let planning = BackendGoalPlanning(goals: f.goals, tasks: f.store, configuration: f.config, local: f.local, detail: f.detail)
        let server = BackendNativeMCPServer(), audit = BackendCrmTaskToolsParityAudit(), island = BackendCrmTaskToolsParityIsland()
        let authority = BackendTaskToolAuthority(requireTasks: { caller in
            if caller.machineID == "key-off" { throw NativeRPCError(code: "not-granted", message: "This app may not use your tasks. Settings → Connect an AI app → Your tasks") }
        }, requireHoot: { caller in
            if caller.machineID != "hoot" { throw NativeRPCError(code: "not-granted", message: "Hoot’s own tool") }
        }, visible: { caller, row in caller.projectRoot == nil || row.project == caller.projectRoot || row.project.hasPrefix((caller.projectRoot ?? "") + "/") }, project: { caller, path in
            if let scope = caller.projectRoot, path != scope && !path.hasPrefix(scope + "/") { throw NativeRPCError.invalidArguments("This app is limited to some folders") }
            if path != "/work/app" && !path.hasPrefix("/work/app/") { throw NativeRPCError.invalidArguments("The project is not inside a folder Terminal Deck has open") }
        }, authorize: { _,_,_,tier in await audit.record(tier) }, actorName: { $0.machineID == "hoot" ? "hoot" : "app:Claude Desktop" })
        _ = try await BackendTaskMCP.register(server: server, view: view, local: f.local, engine: engine, detail: f.detail, planning: planning, api: nil, indexed: true, authority: authority,
            knowledge: knowledge.map { BackendTaskKnowledgeAdapter(service:$0) }, readAttachment: { _,path in
                guard path.hasPrefix("/work/app/") else { throw NativeRPCError.invalidArguments("The file is not inside a folder Terminal Deck has open") }
                return (URL(fileURLWithPath:path).lastPathComponent,nil,try Data(contentsOf:io.root.appendingPathComponent("picked").appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent)))
            }, island: BackendTaskIslandControl(get: { await island.enabled }, set: { await island.set($0) }), control: control)
        return Self(f: f, server: server, engine: engine, planning: planning, audit: audit, io: io, registrations: await server.registrations())
    }
    func context(_ caller: String = "hoot", folder: String? = nil, tiers: Set<BackendMCPTier> = [.read,.act,.alter]) -> BackendMCPCallContext {
        BackendMCPCallContext(sessionID: "parity", machineID: caller, projectRoot: folder, attended: true, allowedTools: Set(registrations.map { $0.0.id }), allowedTiers: tiers, cancellation: BackendMCPCancellation())
    }
    func spec(_ id: String) throws -> BackendMCPTool { try #require(registrations.first { $0.0.id == id }?.0) }
    func call(_ id: String, _ input: NativeRPCValue, caller: String = "hoot", folder: String? = nil, tiers: Set<BackendMCPTier> = [.read,.act,.alter]) async throws -> NativeRPCValue {
        let handler = try #require(registrations.first { $0.0.id == id }?.1, "Missing actual native MCP tool: \(id)")
        return try #require(try await handler(context(caller, folder: folder, tiers: tiers), input).structuredContent)
    }
    func refused(_ id: String, _ input: NativeRPCValue, caller: String = "hoot", folder: String? = nil, tiers: Set<BackendMCPTier> = [.read,.act,.alter]) async -> String {
        do { _ = try await call(id, input, caller: caller, folder: folder, tiers: tiers); #expect(false, "Expected refusal from \(id)"); return "" }
        catch { return error.localizedDescription }
    }
    func create(_ title: String, _ extra: NativeRPCValue = .object([]), caller: String = "hoot", folder: String? = nil) async throws -> String {
        try #require(try await call("tasks.local_change", crmParityValue(["do": "create", "title": title]).merging(extra), caller: caller, folder: folder)["created"]["task"].string)
    }
}

/// Uses the real scratch knowledge service and current task knowledge adapter.
protocol BackendCrmTaskToolsParityKnowledgeDriver: Sendable {
    var tools: BackendCrmTaskToolsParityFixture { get }
    func record(project: String, kind: String, subject: String, statement: String, source: String) async throws
}
enum BackendCrmTaskToolsParityKnowledgeBinding {
    static let make: (@Sendable () async throws -> any BackendCrmTaskToolsParityKnowledgeDriver)? = {
        let io = try await BackendCrmTaskDetailParityNativeIO.make(notify:true)
        let service = BackendKnowledgeService(userData:io.root.appendingPathComponent("user-data").path,now:{ io.fixture.clock.now() },statMtime:{ _ in nil },onError:{ #expect(false,"\($0): \($1)") })
        return BackendCrmTaskToolsParityNativeKnowledge(tools:try await BackendCrmTaskToolsParityFixture.make(io:io,knowledge:service),service:service)
    }
}
struct BackendCrmTaskToolsParityNativeKnowledge: BackendCrmTaskToolsParityKnowledgeDriver {
    let tools: BackendCrmTaskToolsParityFixture, service: BackendKnowledgeService
    func record(project:String,kind:String,subject:String,statement:String,source:String) async throws {
        _ = try await service.record(project,input:.init(kind:kind,subject:subject,statement:statement,provenance:.init(source:source)))
    }
}
/// The source accepts fake retry/review dependencies. Native registration
/// presently takes a concrete Engine, so method-request capture needs a genuine
/// injected control-operations seam, not a fake MCP handler implementation.
protocol BackendCrmTaskToolsParityControlDriver: Sendable {
    var tools: BackendCrmTaskToolsParityFixture { get }
    func retried() async -> [NativeRPCValue]
    func reviewed() async -> [NativeRPCValue]
}
enum BackendCrmTaskToolsParityControlBinding {
    static let make: (@Sendable () async throws -> any BackendCrmTaskToolsParityControlDriver)? = {
        let log = BackendCrmTaskToolsParityControlLog()
        let control = BackendTaskControlOperations(retry: { task, note in await log.retry(task, note) }, review: { task, pass, evidence, reasons in await log.review(task, pass, evidence, reasons) })
        return BackendCrmTaskToolsParityNativeControl(tools: try await BackendCrmTaskToolsParityFixture.make(control: control), log: log)
    }
}
/// The injected control operations record the request; no engine, process or agent runs.
actor BackendCrmTaskToolsParityControlLog {
    var retries: [NativeRPCValue] = [], reviews: [NativeRPCValue] = []
    func retry(_ task: String, _ note: String) { retries.append(crmParityValue(["task": task, "note": note])) }
    func review(_ task: String, _ pass: Bool, _ evidence: [String], _ reasons: String) { reviews.append(crmParityValue(["task": task, "pass": pass, "evidence": evidence, "reasons": reasons])) }
}
struct BackendCrmTaskToolsParityNativeControl: BackendCrmTaskToolsParityControlDriver {
    let tools: BackendCrmTaskToolsParityFixture, log: BackendCrmTaskToolsParityControlLog
    func retried() async -> [NativeRPCValue] { await log.retries }
    func reviewed() async -> [NativeRPCValue] { await log.reviews }
}
