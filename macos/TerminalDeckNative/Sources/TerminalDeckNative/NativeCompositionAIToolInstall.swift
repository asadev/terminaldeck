import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// CONNECT-SKILLS (Asad "go", 11 Oct): one-click install of Claude Code, Codex and Gemini CLI.
// The screens call ai-tools:install / ai-tools:install-state and follow ai-tools:install-progress; Hoot, sessions
// and connected AI apps get the same install as app tools (every feature ships its tools):
//   ai_tools_status   which AIs are installed here, their versions, and any install in progress (read)
//   ai_tools_install  install one with its official route; asks first as the person's permission mode says (alter)
// An AI cannot sign in for the person: after an install it says where the person signs in.

extension NativeCompositionProduction {
    /// Never fatal: without it the screens fall back to the AI's own page.
    func installAIToolInstall() async {
        await NativeFinishSound.start(root: root)   // TRUTH-B: Settings › Notifications › Sound plays on finish
        do { try await installAIToolInstallThrowing() }
        catch { NSLog("[native graph] one-click AI install was not set up: %@", error.localizedDescription) }
    }

    private func installAIToolInstallThrowing() async throws {
        // TRUTH-B: the MCP page's per-agent switches list the saved agents (read when the window asks).
        if let page = try wired(clients, "clients").mcpClients {
            await page.setAgentsSource { [weak self] in
                guard let config = await MainActor.run(body: { self?.taskView?.config }),
                      let agents = try? await config.allAgents() else { return [] }
                return agents.compactMap { row in row["id"].string.map { ($0, row["name"].string ?? $0) } }
            }
        }
        let owner = "native-composition:ai-tool-install", registry = root.registry, mcp = root.mcp, providers = root.providers
        guard let authority else { return }
        let joins = self.joins
        let installer = BackendAIToolInstaller(dependencies: .init(
            loginPath: { try await providers.loginPath() },
            installed: { tool, refresh in
                let path = (try? await providers.loginPath()) ?? ""
                let binary = await providers.resolveBinary(tool, path: path, refresh: refresh)
                return (binary.runnable, binary.version)
            },
            resetCaches: { await providers.resetCaches() },
            // To the app's own screens (the event is addressed to the native app's listener).
            publish: { status in try? await registry.publish(BackendAIToolInstaller.progressEvent, arguments: [status], ownerID: BackendCompositionRoot.appOwnerID) },
            scratch: root.dataRoot.appendingPathComponent("ai-tool-install", isDirectory: true),
            home: configuration.homeDirectory.path, environment: configuration.inheritedEnvironment))
        do {
            try await retainChannels("ai-tool-install", owner: owner, try await BackendAIToolInstaller.register(
                registry: registry, ownerID: owner, installer: installer, policy: { context in try authority.requireLocalUI(context) }))
        } catch { await registry.removeOwner(owner); throw error }

        let tools = NativeRPCValue.object([.init("type", .string("string")), .init("enum", .array(BackendAIToolInstallPlan.tools.map(NativeRPCValue.string)))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let definitions: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("ai_tools.status", .read,
             "Which coding AIs are installed on this Mac (Claude Code, Codex, Gemini CLI), each with its version, and any install in progress. Read-only.",
             schema([])),
            ("ai_tools.install", .alter,
             "Install a missing coding AI on this Mac with its official route, the same as the Install button: Claude Code with Anthropic's own installer, Codex with OpenAI's (or Homebrew/npm), Gemini CLI with Homebrew or npm. Never uses admin rights. Runs at once when the calling AI's permission mode allows it; the action is logged. Waits for the end unless wait is false; ai_tools_status shows progress. The person then signs in (Settings › Coding AI); no AI can sign in for them.",
             schema([("tool", tools), ("wait", .object([.init("type", .string("boolean"))]))], required: ["tool"])),
        ]
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description, input) in definitions {
            if taken.contains(id) { NSLog("[native graph] %@ is already registered by another owner; skipped", id); continue }
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(spec, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot install coding AIs.") }
                let core = try await authority.resolve(caller)
                if id == "ai_tools.status" {
                    let path = (try? await providers.loginPath()) ?? ""
                    var rows: [NativeRPCValue] = []
                    for status in await installer.all() {
                        let binary = await providers.resolveBinary(status.tool, path: path, refresh: false)
                        rows.append(.object([.init("tool", .string(status.tool)), .init("label", .string(status.label)),
                                             .init("installed", .bool(binary.runnable != nil)),
                                             .init("version", binary.version.map(NativeRPCValue.string) ?? .null),
                                             .init("install", status.wire)]))
                    }
                    return .value(.object([.init("tools", .array(rows))]))
                }
                let tool = try args["tool"].requireString("tool", nonempty: true)
                guard BackendAIToolInstallPlan.tools.contains(tool) else { throw NativeRPCError.invalidArguments("tool is claude, codex or gemini.") }
                // An AI app holding a key is not at the keyboard: the person answers. Everyone else: the permission mode.
                try await joins.prepareNative(caller, tier: tier, sentence: "Install " + CodingAICatalog.label(tool) + " on this Mac",
                                              ownerMustAnswer: core.caller.kind == .key)
                let status = args["wait"].bool == false ? try await installer.start(tool) : try await installer.install(tool)
                var reply = status.wire
                if status.state == "installed" {
                    reply = reply.setting("next", .string("Sign in: the person opens Settings › Coding AI and presses Sign in beside " + status.label + ". No AI can sign in for them."))
                }
                return .value(reply)
            }
        }
        let ids = Set(definitions.map(\.0))
        let registered = await mcp.registrations().filter { ids.contains($0.0.id) && !taken.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}
