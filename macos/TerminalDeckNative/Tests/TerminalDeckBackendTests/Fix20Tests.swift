import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Fix20: team access and real Codex chat commands")
struct Fix20Tests {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func reply(_ id: NativeRPCValue, _ value: NativeRPCValue) -> NativeRPCValue {
        .object([.init("id", id), .init("result", value)])
    }
    private func started() throws -> (BackendHootChatRPC, BackendHootChatRPCUpdate) {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch"))
        let hello = try rpc.begin(id: "hello", resume: nil)
        let start = try rpc.receive(reply(hello["id"], .object([]))).send.last!
        let update = try rpc.receive(reply(start["id"], json(#"{"thread":{"id":"thread"},"model":"test-model"}"#)))
        return (rpc, update)
    }
    @Test func savedLeadAndWorkerGrantIncludesEveryChatToolAndKeepsProfileRestrictions() {
        let tools = ["sessions.conversations", "sessions.chat", "sessions.start_agent"]
        for task in [nil, "task"] as [String?] {
            let names = BackendTAGToolPolicy.sessionNames(taskID: task)
            for tool in tools {
                #expect(names.contains(tool))
                #expect(names.contains(tool.replacingOccurrences(of: ".", with: "_")))
            }
            let denied = BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: nil,
                denied: ["mcp__deck-control__sessions_conversations"])
            #expect(!denied.contains("sessions.conversations"))
            #expect(!denied.contains("sessions_conversations"))
            let only = BackendTAGToolPolicy.filter(names, server: "deck-control",
                allowed: ["mcp__deck-control__sessions_conversations"], denied: [])
            #expect(only == ["sessions.conversations", "sessions_conversations"])
        }
    }
    @Test func chatsAndFinishedHistoryUseTheCallersOwnProject() throws {
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "lead")
        #expect(try BackendCompositionAuthority.sessionProjectPermits(id: "agent", cwd: "/scratch/agent", caller: caller, callerCWD: "/scratch"))
        #expect(try !BackendCompositionAuthority.sessionProjectPermits(id: "agent", cwd: "/scratch-other", caller: caller, callerCWD: "/scratch"))
        #expect(try !BackendCompositionAuthority.sessionProjectPermits(id: "agent", cwd: "/scratch", caller: caller, callerCWD: nil))
        #expect(try BackendCompositionAuthority.sessionProjectPermits(id: "lead", cwd: "/scratch", caller: caller, callerCWD: nil))
        let task = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "worker", projectRoot: "/project", taskProject: "/project")
        #expect(try BackendCompositionAuthority.sessionProjectPermits(id: "agent", cwd: "/project", caller: task, callerCWD: "/workspace"))
        #expect(try BackendCompositionAuthority.sessionProjectPermits(id: "agent", cwd: "/workspace", caller: task, callerCWD: "/workspace"))
        #expect(try !BackendCompositionAuthority.sessionProjectPermits(id: "agent", cwd: "/elsewhere", caller: task, callerCWD: "/workspace"))
    }
    @Test func codexOffersRealBuiltinsImmediatelyAndRequestsItsOwnSkills() throws {
        let (_, update) = try started()
        #expect(update.ready)
        let names = Set(update.records.last!.value["commands"].elements!.compactMap { $0["name"].string })
        #expect(names == ["model", "permissions", "status", "compact", "review", "init", "plan"])
        #expect(update.send.last?["method"].string == "skills/list")
        #expect(update.send.last?["params"]["cwds"].elements == [.string("/scratch")])
    }
    @Test func skillMenuUsesOnlyEnabledSkillsFromThisFolderAndRunsTheReportedFile() throws {
        var (rpc, update) = try started()
        let skills = try json(#"{"data":[{"cwd":"/scratch","skills":[{"name":"project-check","description":"Check this project","path":"/scratch/.agents/skills/project-check/SKILL.md","enabled":true},{"name":"disabled","path":"/scratch/disabled","enabled":false}]},{"cwd":"/foreign","skills":[{"name":"foreign","path":"/foreign/SKILL.md","enabled":true}]}]}"#)
        let offered = try rpc.receive(reply(update.send.last!["id"], skills))
        let names = offered.records[0].value["commands"].elements!.compactMap { $0["name"].string }
        #expect(names.contains("project-check")); #expect(!names.contains("disabled")); #expect(!names.contains("foreign"))
        let request = try rpc.user("hidden context", attachments: [], id: "run", commandText: "/project-check use scratch")
        #expect(request["method"].string == "turn/start")
        #expect(request["params"]["input"].elements?.last?["type"].string == "skill")
        #expect(request["params"]["input"].elements?.last?["path"].string == "/scratch/.agents/skills/project-check/SKILL.md")
    }
    @Test func optionalSkillListFailureKeepsTheRealBuiltinMenu() throws {
        var (rpc, update) = try started()
        let response = NativeRPCValue.object([.init("id", update.send.last!["id"]), .init("error", .object([.init("message", .string("unsupported"))]))])
        let offered = try rpc.receive(response)
        #expect(offered.records[0].value["commands"].elements?.count == 7)
        #expect(try rpc.user("hello", attachments: [], id: "p")["method"].string == "turn/start")
    }
    @Test func compactUsesRPCAndWaitsForItsCompletion() throws {
        var (rpc, _) = try started()
        let request = try rpc.user("hidden context", attachments: [], id: "compact", commandText: "/compact ")
        #expect(request["method"].string == "thread/compact/start")
        #expect(try rpc.receive(reply(request["id"], .object([]))).records.isEmpty)
        #expect(throws: (any Error).self) { try rpc.user("too early", attachments: [], id: "early") }
        #expect(try rpc.receive(json(#"{"method":"thread/compacted","params":{"threadId":"foreign"}}"#)).records.isEmpty)
        let done = try rpc.receive(json(#"{"method":"thread/compacted","params":{"threadId":"thread"}}"#))
        #expect(done.records.last?.kind == .completed)
        #expect(try rpc.user("next", attachments: [], id: "next")["method"].string == "turn/start")
    }
    @Test func reviewUsesCodexReviewAndInitAndPlanUseTheirRealActions() throws {
        var (review, _) = try started()
        let request = try review.user("context", attachments: [], id: "r", commandText: "/review")
        #expect(request["method"].string == "review/start")
        #expect(request["params"]["target"]["type"].string == "uncommittedChanges")
        var (custom, _) = try started()
        #expect(try custom.user("context", attachments: [], id: "r", commandText: "/review check access")["params"]["target"]["instructions"].string == "check access")
        var (initial, _) = try started()
        #expect(try initial.user("context", attachments: [], id: "i", commandText: "/init")["params"]["input"].elements?.first?["text"].string?.contains("AGENTS.md") == true)
        var (plan, _) = try started()
        let planned = try plan.user("context", attachments: [], id: "p", commandText: "/plan check menus")
        #expect(planned["params"]["collaborationMode"]["mode"].string == "plan")
        #expect(planned["params"]["collaborationMode"]["settings"]["model"].string == "test-model")
    }
}
