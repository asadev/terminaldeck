import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func chatLibraryToolDefinitions(gate: BackendCompositionDeckToolsGate, runtime: any BackendDeckToolsSessionsRuntime) throws -> [BackendDeckToolsDefinition] {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let spec = try BackendMCPTool(id: "sessions.chat_library", wireName: "sessions_chat_library",
            description: "List Claude project transcripts, preview one read-only, or resume its exact provider conversation in a separate Chat. Existing project access and approval apply. List returns sessionId/path; resume requires both from list. This catalogue does not claim all providers. Current chat drafts stay untouched.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([
                .init("do", string.setting("enum", .array(["list", "preview", "resume"].map(NativeRPCValue.string)))),
                .init("cwd", string), .init("query", string), .init("path", string), .init("conversationId", string)])),
                .init("required", .array([.string("do"), .string("cwd")])), .init("additionalProperties", .bool(false))]), tier: .read)
        let registry = root.registry
        return [BackendDeckToolsDefinition(spec: spec, title: "Past Chat conversations") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                let cwd = try args["cwd"].requireString("project folder", nonempty: true)
                guard try await runtime.knownFolders(caller).contains(cwd) else { throw NativeRPCError(code: "access-denied", message: "Choose an open project folder.") }
                let action = try args["do"].requireString("action")
                guard ["list", "preview", "resume"].contains(action) else { throw NativeRPCError.invalidArguments("Choose list, preview or resume.") }
                if action == "resume", resolved.caller.kind != .local { throw NativeRPCError(code: "not-granted", message: "Ask Hoot to resume this conversation, or use sessions_start with your existing launch limits.") }
                try await gate.authorize(caller, action == "resume" ? .act : .read, "Browse or resume a past conversation", action == "resume")
                let context = try await gate.authority.rpc(caller)
                let rows = try await registry.invoke("insights:list", context: context, arguments: [.string(cwd)]).elements ?? []
                if action == "list" { return .value(.array(rows.filter { NativeChatLibrary.matches($0, query: args["query"].string ?? "") })) }
                guard let row = rows.first(where: { $0["path"].string == args["path"].string && (action != "resume" || $0["sessionId"].string == args["conversationId"].string) }) else {
                    throw NativeRPCError.invalidArguments("Choose a transcript from list in this project.")
                }
                if action == "preview" { return .value(try await registry.invoke("chat:load", context: context, arguments: [.object([.init("transcriptPath", row["path"])])])) }
                let result = try await registry.invoke("session:create", context: context, arguments: [NativeChatLibrary.resumeInput(row, cwd: cwd)])
                if let id = result["id"].string { resolved.noteStarted(id) }
                await gate.noteResult(caller, result)
                return .value(result)
            }
        }]
    }
}
