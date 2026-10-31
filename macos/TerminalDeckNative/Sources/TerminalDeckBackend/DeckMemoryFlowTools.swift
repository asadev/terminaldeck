import Foundation
import TerminalDeckNativeCore

/// The flow's MCP tools: what the profile's Helper and Tidy-up parts can do, a session, Hoot
/// or a connected AI app can do too. Reading is free; running costs an AI question, so it is
/// an action; changing the checklist asks the person first.
public enum DeckMemoryFlowTools {
    public static let ownerID = "native-composition:deck-memory-flow"
    public static let status = "memory.helper.status"
    public static let runHelper = "memory.helper.run"
    public static let runTidy = "memory.tidy.run"
    public static let readChecklist = "memory.checklist.read"
    public static let addToChecklist = "memory.checklist.add"
    public static let ids = [status, runHelper, runTidy, readChecklist, addToChecklist]

    public typealias Authorize = @Sendable (BackendMCPCallContext, _ tool: String, _ arguments: NativeRPCValue, BackendMCPTier, _ sentence: String) async throws -> Void
    /// Whose memory this caller may act on: Hoot and the app may name an owner; a session only ever gets its own.
    public typealias Owner = @Sendable (BackendMCPCallContext, _ requested: String?) async throws -> String

    public static func install(server: BackendNativeMCPServer, ownerID: String = ownerID, authorize: @escaping Authorize, owner: @escaping Owner,
                               checklist: @escaping @Sendable () async -> String) async throws {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        func schema(_ properties: [NativeRPCValue.Field], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties)),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let ownerField = NativeRPCValue.Field("owner", string.setting("description",
            .string("Whose memory: \"hoot\", \"project:<id>\", \"lead:<project id>\" or an agent role's key. Left out: the caller's own.")))

        try await server.registerTool(try BackendMCPTool(id: status, wireName: "memory_helper_status",
            description: "The note helper and the nightly tidy-up: whether they are on, which AI and model they use, what is waiting to be read, and the last runs with what each wrote or why it failed.",
            inputSchema: schema([]), tier: .read), ownerID: ownerID) { context, args in
            try await authorize(context, status, args, .read, "Read the note helper's status")
            let now = await DeckMemoryFlow.status()
            func job(_ job: DeckMemoryFlowJob) -> NativeRPCValue {
                .object([.init("kind", .string(job.kind.rawValue)), .init("about", .string(job.subject)), .init("title", .string(job.title)),
                         .init("dueAt", job.dueAt.map(NativeRPCValue.number) ?? .null), .init("tries", .number(Double(job.attempts))),
                         .init("lastProblem", job.lastError.map(NativeRPCValue.string) ?? .null)])
            }
            return .value(.object([
                .init("helperOn", .bool(now.helperOn)), .init("ai", .string(now.helperAI)), .init("model", .string(now.helperModel)),
                .init("pauseSeconds", .number(Double(now.pauseSeconds))), .init("atOnce", .number(Double(now.parallel))),
                .init("waiting", .array(now.waiting.map(job))), .init("running", .array(now.runningJobs.map(job))),
                .init("lastRuns", .array(now.lastRuns.prefix(20).map { run in
                    .object([.init("kind", .string(run.kind.rawValue)), .init("about", .string(run.subject)), .init("title", .string(run.title)),
                             .init("at", .number(run.at)), .init("ok", .bool(run.ok)), .init("summary", .string(run.summary)),
                             .init("ai", run.ai.isEmpty ? .null : .string(run.ai)), .init("model", run.model.isEmpty ? .null : .string(run.model)),
                             .init("tokensRead", run.inputTokens.map { .number(Double($0)) } ?? .null),
                             .init("tokensWritten", run.outputTokens.map { .number(Double($0)) } ?? .null)])
                })),
                .init("tidyOn", .bool(now.tidyOn)), .init("tidyHour", .number(Double(now.tidyHour))),
                .init("tidyLastDay", now.tidyLastDay.map(NativeRPCValue.string) ?? .null), .init("tidyRunning", .bool(now.tidyRunning)),
                .init("problem", now.problem.map(NativeRPCValue.string) ?? .null)]))
        }
        try await server.registerTool(try BackendMCPTool(id: runHelper, wireName: "memory_helper_run",
            description: "Run the note helper now for one owner: it reads what that owner's conversations said since it last looked and writes the notes, topics and board result lines. Answers with one sentence.",
            inputSchema: schema([ownerField]), tier: .act), ownerID: ownerID) { context, args in
            try await authorize(context, runHelper, args, .act, "Run the note helper now")
            let key = try await owner(context, args["owner"].string)
            return .value(.object([.init("owner", .string(key)), .init("result", .string(await DeckMemoryFlow.runHelperNow(ownerKey: key)))]))
        }
        try await server.registerTool(try BackendMCPTool(id: runTidy, wireName: "memory_tidy_run",
            description: "Run the tidy-up now for one owner: merge duplicate notes, settle contradictions (the newer note wins, the older is archived), check the diary for anything missed. Nothing is deleted; unsure cases become questions for the person. Answers with one sentence.",
            inputSchema: schema([ownerField]), tier: .act), ownerID: ownerID) { context, args in
            try await authorize(context, runTidy, args, .act, "Run the memory tidy-up now")
            let key = try await owner(context, args["owner"].string)
            return .value(.object([.init("owner", .string(key)), .init("result", .string(await DeckMemoryFlow.runTidyNow(ownerKey: key)))]))
        }
        try await server.registerTool(try BackendMCPTool(id: readChecklist, wireName: "memory_checklist_read",
            description: "The note helper's checklist: what counts as worth noting, including the person's corrections.",
            inputSchema: schema([]), tier: .read), ownerID: ownerID) { context, args in
            try await authorize(context, readChecklist, args, .read, "Read the note helper's checklist")
            return .value(.object([.init("checklist", .string(await checklist()))]))
        }
        try await server.registerTool(try BackendMCPTool(id: addToChecklist, wireName: "memory_checklist_add",
            description: "Add one line to the note helper's checklist when the person says something should have been noted (\"you should have noted X\"). Runs at once when the calling AI's permission mode allows it; the action is logged.",
            inputSchema: schema([.init("text", string.setting("description", .string("What should be noted from now on, in the person's words.")))], required: ["text"]),
            tier: .alter), ownerID: ownerID) { context, args in
            let text = try args["text"].requireString("text", nonempty: true)
            guard text.utf8.count <= 2_000 else { throw NativeRPCError.invalidArguments("Keep the checklist line under 2,000 characters.") }
            try await authorize(context, addToChecklist, args, .alter, "Add to the note helper's checklist: " + String(text.prefix(120)))
            let added = await DeckMemoryFlow.addCorrection(text)
            return .value(.object([.init("added", .bool(added)), .init("result", .string(added ? "Added to the checklist." : "That line is already on the checklist."))]))
        }
    }
}
