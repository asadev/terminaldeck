import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// All moved buttons share this native path with tools; no page ticket or JavaScript command is needed.
    func installButtonTools() async throws {
        guard let authority else { return }
        let owner = "native-composition:button-tools", mcp = root.mcp, joins = self.joins
        let actions = NativeButtonActions.names.sorted()
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("action", text.setting("enum", .array(actions.map(NativeRPCValue.string)))), .init("id", text), .init("value", text), .init("folder", text)])),
            .init("required", .array([.string("action")])), .init("additionalProperties", .bool(false))])
        let spec = try BackendMCPTool(id: "window.buttons", wireName: "window_buttons",
            description: "Use the main window’s native buttons. action is a button name; id is a tab, pane, split, folder, server or panel. value is the divider ratio, server name or panel focus; folder optionally sets the server terminal’s start folder. set-mode uses id terminal or split. Either side of the split can be a session or a browser tab: select-tab with a browser tab id fills the focused pane while the split is on (else shows it), and split-with id (a session or browser tab) puts it beside the one on show, turning the split on if needed. Every answer lists the panes (pane id, tab, kind, focused) for focus-pane, close-pane and resize-split. Opening sessions shows the native form; new-session-start submits it, new-session-cancel closes it. remove-project removes its folder and ends its local sessions. start-machine-session uses id machine, folder remote path and value AI, and waits for creation. open-server-shell uses id server and value agent command. server-shell-opened uses id tab and value shell ID; server-shell-ended marks its tab ended; close-tab folds a session back into the side panel; close-session and close-project ask the person’s usual delete question. Refusals return an error.",
            inputSchema: schema, tier: .alter)
        try await mcp.registerTool(spec, ownerID: owner) { caller, args in
            guard caller.allowedTiers.contains(.alter) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot change the window.") }
            _ = try await authority.resolve(caller)
            let action = try args["action"].requireString("action", nonempty: true)
            let command = try await MainActor.run { try NativeButtonActions.command(action, id: args["id"].string ?? "", value: args["value"].string ?? "", folder: args["folder"].string) }
            try await joins.prepareNative(caller, tier: .alter, sentence: "Use the window’s " + action + " button", ownerMustAnswer: false)
            let task = await MainActor.run {
                NativeButtonActions.routeForTool(command, nativeSelection: { id in
                    guard AppModel.nativeOnly(id) else { return false }
                    AppModel.shared.select(id); return true
                }, fallback: {
                    command.name == "close-tab" ? AppModel.shared.closeTabForTool(args["id"].string ?? "") : AppModel.shared.runButtonForTool(command)
                })
            }
            let outcome = await task.value
            guard outcome.succeeded else {
                throw NativeRPCError(code: "refused", message: outcome.message)
            }
            let panes = try await MainActor.run { try NativeRPCValue.fromFoundation(AppModel.shared.buttonActions.paneSummary()) }
            return .value(.object([.init("ok", .bool(true)), .init("action", .string(action)), .init("window", panes)]))
        }
        let registered = await mcp.registrations().filter { $0.0.id == spec.id }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: "Native window buttons", index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}

extension NativeButtonActions {
    @MainActor static func routeForTool(_ command: PageCommand, nativeSelection: (String) -> Bool,
                                       fallback: () -> Task<Outcome, Never>) -> Task<Outcome, Never> {
        if command.name == "select", let id = command.argument, nativeSelection(id) { return Task { .completed } }
        return fallback()
    }
    @MainActor static func route(_ command: PageCommand, nativeSelection: (String) -> Bool,
                                 fallback: () -> Task<Bool, Never>) -> Task<Bool, Never> {
        if command.name == "select", let id = command.argument, nativeSelection(id) { return Task { true } }
        return fallback()
    }
    static func command(_ action: String, id: String, value: String, folder: String? = nil) throws -> PageCommand {
        switch action {
        case "select": return .select(id)
        case "select-tab": return .selectTab(id)
        case "close-session": return .closeSession(id)
        case "close-tab": return .closeTab(id)
        case "new-session": return .newSession
        case "new-terminal-tab": return .newTerminalTab
        case "new-session-in": return .newSessionIn(id)
        case "close-project": return .closeProject(id)
        case "toggle-project": return .toggleProject(id)
        case "set-mode": return .setMode(id)
        case "resize-split":
            guard let ratio = Double(value), ratio.isFinite else { throw NativeRPCError.invalidArguments("Give a divider ratio between 0 and 1.") }
            return .resizeSplit(id, ratio: ratio)
        case "focus-pane": return .focusPane(id)
        case "close-pane": return .closePane(id)
        case "split-with": return .splitWith(id)
        case "open-server-session": return .openServerSession(serverId: id, serverName: value.isEmpty ? "Server" : value, startIn: folder)
        case "open-server-shell": return .openServerShell(serverId: id, agentId: value.isEmpty ? nil : value)
        case "server-shell-opened": return .serverShellOpened(id, shellId: value)
        case "server-shell-ended": return .serverShellEnded(id)
        case "start-machine-session": return .startMachineSession(machineId: id, folder: folder ?? "", provider: value)
        case "new-session-start": return .submitNewSession
        case "new-session-cancel": return .cancelNewSession
        case "remove-project": return .removeProject(id)
        case "server-renamed": return .serverRenamed(serverId: id, name: value)
        case "open-file": return .openFile(id)
        case "show-panel": return .showPanel(id, focus: value.isEmpty ? nil : value)
        case "show-sessions": return .showSessions
        default: throw NativeRPCError.invalidArguments("That native button is not available.")
        }
    }
}
