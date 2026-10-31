import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

enum NativeAPIAccountToolIntent {
    static func secureEntry(action: String, credential: String?) throws -> Bool {
        guard let credential else { return false }
        if credential == "request-on-mac", ["add", "update"].contains(action) { return true }
        if credential == "invalid-check", action == "add" { return false }
        throw NativeRPCError.invalidArguments("Request secure entry when adding or updating an account; invalid-check is only for a new check account.")
    }
}

extension NativeCompositionProduction {
    func installAPIAccountTools() async throws {
        guard let authority, let sessions else { return }
        if let local = sessions.accountRPC as? BackendAccountRPC {
            await MainActor.run {
                NativeAPIAccounts.shared.configure { id, key in
                    try await local.apiAccounts.storeNativeKey(id: id, key: key, context: authority.localContext())
                }
            }
        }
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let spec = try BackendMCPTool(id: "accounts.api", wireName: "accounts_api",
            description: "List accounts with authentication type; add/update API connection metadata (workspaceID wrkspc_… for a Claude key not scoped to one workspace; empty clears it), check one key with one model-list request, or remove an API account. Real keys are entered only in the Mac's secure field, never in tool arguments or replies. credential invalid-check creates only a new check-prefixed dummy account. Changes use normal approval. API launches require the updated session service.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([
                .init("do", text.setting("enum", .array(["list", "add", "update", "check", "remove"].map(NativeRPCValue.string)))),
                .init("id", text), .init("name", text),
                .init("kind", text.setting("enum", .array(BackendAPIAccountRecord.Kind.allCases.map { .string($0.rawValue) }))),
                .init("baseURL", text), .init("model", text), .init("workspaceID", text),
                .init("credential", text.setting("enum", .array([.string("request-on-mac"), .string("invalid-check")])))])),
                .init("required", .array([.string("do")])), .init("additionalProperties", .bool(false))]), tier: .read)
        let owner = "native-composition:api-accounts", joins = self.joins
        try await root.mcp.registerTool(spec, ownerID: owner) { caller, args in
            let action = try args["do"].requireString("action", nonempty: true)
            let secureEntry = try NativeAPIAccountToolIntent.secureEntry(action: action, credential: args["credential"].string)
            let tier: BackendMCPTier = action == "list" ? .read : action == "check" ? .act : .alter
            guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot change API accounts.") }
            let resolved = try await authority.resolve(caller)
            if args["credential"].string == "invalid-check", resolved.caller.kind != .local {
                throw NativeRPCError(code: "not-granted", message: "Only the Mac's owner can create an invalid-key check account.")
            }
            guard ["list", "add", "update", "check", "remove"].contains(action) else { throw NativeRPCError.invalidArguments("Choose a supported account action.") }
            var fields: [NativeRPCValue.Field] = []
            for key in ["id", "name", "kind", "baseURL", "model", "workspaceID"] where !args[key].isNullish { fields.append(.init(key, args[key])) }
            if action == "add", args["credential"].string == "invalid-check" { fields.append(.init("invalidCheckCredential", .bool(true))) }
            if tier != .read {
                let destination = args["baseURL"].string.map { " at " + $0 } ?? ""
                try await joins.prepareNative(caller, tier: tier, sentence: "\(action.capitalized) API account\(destination)", ownerMustAnswer: true)
            }
            let context = try await authority.rpc(caller)
            let value = try await sessions.accountRPC.invoke("profiles:api:" + action, args: [.object(fields)], context: context)
            if tier != .read {
                await MainActor.run { NativeCodingAIStore.shared.refreshAll(); NativeCodingAIPages.announceAccountsChanged() }
            }
            if secureEntry {
                let id = try value["id"].requireString("API account", nonempty: true)
                await MainActor.run {
                    NativeAPIAccounts.shared.requestedEditorID = id
                    NativeChatAccount.openSettings(provider: value["apiKind"].string.flatMap(BackendAPIAccountRecord.Kind.init(rawValue:))?.provider)
                }
            }
            return .value(secureEntry ? value.setting("secureEntryRequested", .bool(true)) : value)
        }
        let registered = await root.mcp.registrations().filter { $0.0.id == spec.id }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}
