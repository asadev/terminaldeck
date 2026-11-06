import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func chatFeatureToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let hootRuntime = hoot?.runtime
        let spec = try BackendMCPTool(id: "sessions.chat_feature", wireName: "sessions_chat_feature", description: "Mac owner's native Chat feature controls. feature running: read/open/close lists the same Running tray; stop request task ID stops only that task with the existing approval rules; output request task ID reads its latest output where the provider supports it. feature activity: read reports the same provider-backed Working line shown above the composer. feature tool-cards: read lists recorded fold keys and open view IDs; expand/collapse request a finished card key, optional text selects a view ID. Uses the same fold state as its button, does not send or run a tool. feature follow: read reports each open view, latest follows the newest message, earlier/later scroll one page without sending. Sending and opening follow automatically; scrolling up pauses until the end is reached. feature rendering: read with request set to the available chat width in points returns body text size, avatar alignment, and each markdown table's column widths or stacked labeled rows. Wide tables scroll within the chat; code keeps its original lines. A JSON request with rowId reads the authoritative message or tool source, including stored images. feature controls: read/open/close, request model/effort/reasoning/permissions/approve/config/status/login/logout opens its exact control. feature terminal-context: read/open/close lists recorded command outputs; insert request versioned output ID and optional text one-based line range a:b appends a bounded exact excerpt with hash/line/byte draft receipt. details opens its recorded source. This recorded-context feature performs no terminal I/O; sessions_chat_terminal owns live app-approved terminal controls. feature policy: read/open/close reports the current helper-confirmed provider effectivePolicy, with historical records used only as source receipts, with separate app permission choice; permissions opens that existing choice and manage opens provider settings. It does not infer sandbox/trust/network from permissions. feature notifications: read/open/close shows actual in-app delivery-request outcomes, manage opens existing preferences. No test banner is sent by this feature tool. feature agents: read/open/close shows reported child hierarchy; stop request child ID uses existing child stop, details opens source event, task opens a confirmed app-task report. Provider child transcript/resume uses sessions_chat_children. feature hooks: read/open/close shows only emitted structured hook notices and explicit trust/stop reasons; details request event ID opens its source; manage opens provider-focused hook setup. feature mcp: read/open/close separates project app-client status from provider session status; test request enabled server ID uses existing app inventory with source checks, manage opens the owner. Provider auth/reconnect uses sessions_chat_provider. feature long-draft: open snapshots an editable prompt; edit text updates its copy; apply writes only if the original full draft/conversation are unchanged. export creates a private UTF-8 file; open-editor opens it, import validates a regular non-symlink file within 256 KiB and the original snapshot; cancel removes the copy. No automatic send. feature diffs: read/open/close reads recorded file/hunk previews; comment request hunk ID and optional text appends a review-comment draft, details opens its emitted source, reveal opens an existing project file. Conditional apply/reject uses sessions_chat_diffs. feature model-timing: read/open/close distinguishes requested/saved/provider-confirmed model and next-turn timing; choose opens its control. feature mentions: read/open/close reads ordinary Chat context choices and recorded message receipts; insert request exact marker adds context without sending or delegating. feature commands: read/open/close lists provider-by-Chat support; prepare request command name and optional text arguments opens its app control or prepares an empty draft, never sends. Existing sessions_chat options owns actual changes and approvals.", inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"feature":{"type":"string"},"do":{"type":"string"},"request":{"type":"string"},"text":{"type":"string"},"revision":{"type":"integer","minimum":0}},"required":["sessionId","feature","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Chat feature controls") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                guard resolved.caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "These native controls belong to the Mac owner; existing scoped session tools remain available.") }
                let id = try args["sessionId"].requireString("session ID", nonempty: true), action = try args["do"].requireString("action"), feature = try args["feature"].requireString("feature")
                let name: String
                if id == "hoot" {
                    guard caller.sessionID.isEmpty || caller.sessionID != hootRuntime?.structuredChat?.conversationID else { throw NativeRPCError(code: "access-denied", message: "This Chat belongs to the Mac owner.") }; name = "Hoot"
                } else { let meta = try await gate.authority.requireSession(id, native: caller); guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }; name = TerminalAgent.name(meta.provider) }
                let readOnly = action == "read" || feature == "running" && action == "output"
                try await gate.authorize(caller, readOnly ? .read : .act, "Use Chat feature \(feature)", !readOnly)
                return .value(try await Task { @MainActor in
                    let model = await NativeHootChatModel.featureModel(id, name: name)
                    return try await model.featureTool(feature, action: action, args: args)
                }.value)
            }
        }]
    }
}
extension NativeHootChatModel {
    func featureTool(_ feature: String, action: String, args: NativeRPCValue) async throws -> NativeRPCValue {
        if feature == "running", ["read", "open", "close", "stop", "output"].contains(action) { return try await runningTasksTool(action, request: args["request"].string) }
        if feature == "activity", action == "read" { return workingState.wire().setting("sessionId", .string(source.sessionID ?? "hoot")) }
        if feature == "tool-cards" { return try toolCardsTool(action, request: args["request"].string, viewID: args["text"].string) }
        if feature == "follow" { return try followTool(action) }
        if feature == "rendering", action == "read" {
            if let request = args["request"].string,
               let data = request.data(using: .utf8), let value = try? NativeRPCValue.parseJSON(data),
               let rowID = value["rowId"].string {
                guard rows.contains(where: { $0.id == rowID }) else {
                    throw NativeRPCError.invalidArguments("Choose a message or tool in this chat.")
                }
                if fixtureMode {
                    return rows.first(where: { $0.id == rowID })?.value ?? .null
                }
                return try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("chat:mcp-app:read", [source.sessionID ?? "hoot", rowID]))
            }
            var state = try renderingTool(width: args["request"].string)
            state = state.setting("sourceReads", .array(rows.filter { [.toolCall, .toolResult].contains($0.kind) }.map { row in
                .object([.init("rowId", .string(row.id)), .init("request", .string("{\"rowId\":\"" + row.id + "\"}"))])
            }))
            if !fixtureMode {
                var apps: [NativeRPCValue] = []
                for row in rows where row.kind == .toolCall && row.value["finished"].bool == true && BackendChatMCPApps.toolIdentity(row) != nil {
                    let value = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("chat:mcp-app:read", [source.sessionID ?? "hoot", row.id]))
                    if let html = value["html"].string {
                        apps.append(.object([.init("rowId", .string(row.id)), .init("type", .string("mcpApp")), .init("source", .string(html)), .init("resourceUri", value["resourceUri"])]))
                    }
                }
                state = state.setting("mcpApps", .array(apps))
            }
            return state
        }
        if feature == "terminal-context", ["read", "open", "close", "insert", "details"].contains(action) { return try terminalContextTool(action, request: args["request"].string, range: args["text"].string) }
        if feature == "policy", ["read", "open", "close", "permissions", "manage"].contains(action) { return try policyTool(action) }
        if feature == "notifications", ["read", "open", "close", "manage"].contains(action) { return attentionTool(action) }
        if feature == "agents", ["read", "open", "close", "stop", "details", "task"].contains(action) { return try await agentTreeTool(action, request: args["request"].string) }
        if feature == "hooks", ["read", "open", "close", "details", "manage"].contains(action) { return try hooksTool(action, request: args["request"].string) }
        if feature == "mcp", ["read", "open", "close", "test", "manage"].contains(action) { return try await mcpFeatureTool(action, request: args["request"].string) }
        if feature == "long-draft", ["read", "open", "close", "edit", "apply", "export", "open-editor", "import", "cancel"].contains(action) { return try longDraftTool(action, text: args["text"].string) }
        if feature == "diffs", ["read", "open", "close", "comment", "details", "reveal"].contains(action) { return try await diffReviewTool(action, request: args["request"].string, text: args["text"].string) }
        if feature == "model-timing", ["read", "open", "close", "choose"].contains(action) { return try modelTimingTool(action) }
        if feature == "mentions", ["read", "open", "close", "insert"].contains(action) { return try mentionsTool(action, request: args["request"].string) }
        if feature == "commands", ["read", "open", "close", "prepare"].contains(action) { return try commandsTool(action, request: args["request"].string, text: args["text"].string) }
        if feature == "controls", ["read", "open", "close"].contains(action) { return try controlsTool(action, request: args["request"].string) }
        throw NativeRPCError.invalidArguments("Choose a supported Chat feature and action.")
    }
}
