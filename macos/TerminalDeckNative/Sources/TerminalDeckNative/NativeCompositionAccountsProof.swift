import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// An isolated test fixture can exercise the same native Add button channel.
/// This tool is never registered in the installed app or an ordinary dev copy.
extension NativeCompositionProduction {
    func installAccounts18ProofTool() async throws {
        let env = ProcessInfo.processInfo.environment, bundle = Bundle.main.bundleIdentifier
        let scratch = bundle == "dev.terminaldeck.oldhost.scratch" && env[NativeLaunchSwitches.quitProof] == "1"
        let dev = bundle == "dev.terminaldeck.app.dev" && env["TD_ACCOUNTS18_PROOF"] == "1" && root.dataRoot.lastPathComponent == "accounts18-dev-proof"
        let data = root.dataRoot.standardizedFileURL.resolvingSymlinksInPath(), home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        guard scratch || dev, env[NativeLaunchSwitches.dataFolder] == data.path, data.path.hasPrefix(home.path + "/"),
              data.path != home.appendingPathComponent("Library/Application Support/terminaldeck").path,
              let authority, let sessions else { return }
        let owner = "native-composition:accounts18-proof", state = NativeAccounts18ProofState(), chats = sessionChats
        let tool = try BackendMCPTool(id: "oldhost.accounts.probe", wireName: "oldhost_accounts_probe", description: "Isolated accounts18 fixture only.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([.init("op", .object([.init("type", .string("string"))])), .init("flow", .object([.init("type", .string("string"))])), .init("accountId", .object([.init("type", .string("string"))]))])), .init("required", .array([.string("op")]))]), tier: .read)
        try await root.mcp.registerTool(tool, ownerID: owner) { _, args in
            let context = try authority.localContext(), op = args["op"].string ?? ""
            let rpc = sessions.accountRPC
            switch op {
            case "scratch-window-chat":
                var input = BackendCreateSessionInput(cwd: home.appendingPathComponent("work").path, provider: "claude")
                input.chat = true; input.profileId = try args["accountId"].requireString("scratch account")
                let requested = input
                #if TD_HOST_ACCOUNT_BRIDGE
                let session = try await BackendHOSTProfileScope.withContext(context) {
                    try await sessions.lifecycle.create(requested, context: .init(rememberTab: true, fromWindow: true))
                }
                #else
                let session = try await sessions.lifecycle.create(requested, context: .init(rememberTab: true, fromWindow: true))
                #endif
                return .value(try NativeRPCValue.parseJSON(JSONEncoder().encode(session)))
            case "scratch-window-say":
                guard let chats else { throw BackendAccountFailure("The scratch chat owner is unavailable.") }
                _ = try await chats.say(args["accountId"].requireString("scratch session"), text: "chatbind21 window answer")
                return .value(.object([.init("sent", .bool(true))]))
            case "add":
                let raw = try await rpc.invoke("profiles:add-signin", args: [.object([.init("provider", .string("claude")), .init("name", .string("Accounts18 sign-in fixture"))])], context: context)
                let id = raw["profileId"].string ?? "", flow = raw["flow"].string ?? ""
                let snapshot = try await rpc.invoke("profiles:list", args: [.string("claude")], context: context)
                let folder = snapshot["profiles"].elements?.first { $0["id"].string == id }?["configDir"].string ?? ""
                await state.put(flow, id: id, folder: folder)
                return .value(.object([.init("flow", .string(flow)), .init("accountId", .string(id)), .init("state", raw["state"]), .init("hasURL", .bool(raw["url"].string != nil))]))
            case "state", "cancel":
                let flow = args["flow"].string ?? "", held = await state.get(flow)
                let raw = try await rpc.invoke(op == "state" ? "profiles:signin-state" : "profiles:signin-cancel", args: [.string(flow)], context: context)
                let snapshot = try await rpc.invoke("profiles:list", args: [.string("claude")], context: context)
                return .value(.object([.init("state", raw["state"]), .init("hasURL", .bool(raw["url"].string != nil)),
                    .init("accountExists", .bool(snapshot["profiles"].elements?.contains { $0["id"].string == held?.id } == true)),
                    .init("folderExists", .bool(held.map { FileManager.default.fileExists(atPath: $0.folder) } ?? false))]))
            case "read":
                let raw = try await rpc.invoke("profiles:list", args: [.string("claude")], context: context)
                let snapshot = CodingAIAccountsParse.snapshot(CodingAIJSON(raw.foundation))
                var probes: [String: CodingAISignIn] = [:]
                for account in snapshot.accounts {
                    let report = try await rpc.invoke("profiles:signin", args: [.string(account.id), .object([.init("refresh", .bool(true))])], context: context)
                    probes[account.id] = CodingAIAccountsParse.signIn(CodingAIJSON(report.foundation))
                }
                let copies = CodingAILogins.duplicates(snapshot.accounts, signIn: probes)
                let vault = try await rpc.invoke("profiles:vault-status", args: [], context: context)
                return .value(.object([.init("rawCount", .number(Double(snapshot.accounts.count))), .init("rowCount", .number(Double(CodingAILogins.oneRowPerEmail(snapshot.accounts, signIn: probes).count))), .init("copyCount", .number(Double(copies.count))), .init("copyIds", .array(copies.keys.sorted().map(NativeRPCValue.string))), .init("vault", vault)]))
            case "remove-copy":
                return .value(try await rpc.invoke("profiles:remove-copy", args: [args["accountId"]], context: context))
            default: throw BackendAccountFailure("Choose add, state, cancel, read or remove-copy in this test fixture.")
            }
        }
        let metadata = BackendDeckCoreCatalogueMetadata(tool: tool, title: tool.description, index: tool.description)
        let registered = await root.mcp.registrations().first { $0.0.id == tool.id }
        if let registered { try joins.replaceContributions(owner: owner, [try .init(metadata: [metadata], policies: [joins.mcpPolicy(metadata, handler: registered.1)])], policiesWrapped: true) }
    }
}

private actor NativeAccounts18ProofState {
    struct Held: Sendable { let id: String, folder: String }
    private var flows: [String: Held] = [:]
    func put(_ flow: String, id: String, folder: String) { flows[flow] = .init(id: id, folder: folder) }
    func get(_ flow: String) -> Held? { flows[flow] }
}
