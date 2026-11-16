import Foundation
import AppKit
import SystemConfiguration
import TerminalDeckBackend
import TerminalDeckNativeCore

/// WhatsApp agents on the Mac (DESIGN-WHATSAPP.md): the engine's five doors bound to the app's own owners, the engine
/// started once, and handed to the screens' store and the tools. One engine per app.
final class NativeWhatsAppEngineBox: @unchecked Sendable {
    static let shared = NativeWhatsAppEngineBox()
    private let lock = NSLock()
    private var held: BackendWhatsAppAgents?
    private var keeperHeld: BackendWhatsAppKeychain?
    var engine: BackendWhatsAppAgents? { lock.withLock { held } }
    func set(_ engine: BackendWhatsAppAgents) { lock.withLock { held = engine } }
    /// The one Keychain keeper, shared by the engine and the saved-passwords store "whatsapp".
    func keeper(appName: String) -> BackendWhatsAppKeychain {
        lock.withLock {
            if let keeperHeld { return keeperHeld }
            let made = BackendWhatsAppKeychain(appName: appName); keeperHeld = made; return made
        }
    }
    /// Set by the saved-passwords wiring: tells it a key was added or replaced here (taken at once, not in 10 minutes).
    private var keysChangedHandler: (@Sendable () -> Void)?
    func setKeysChanged(_ handler: (@Sendable () -> Void)?) { lock.withLock { keysChangedHandler = handler } }
    func keysChanged() { lock.withLock { keysChangedHandler }?() }
}

/// This computer and the account's other computers, from the Cloud account's device list.
struct NativeWhatsAppPresence: WhatsAppPresencePort {
    static let localIDKey = "whatsapp.thisComputer.v1"
    func thisComputer() async -> WhatsAppComputer {
        let name = NativeProjectSecretFiles.deviceName()
        if let id = await NativeProjectSecretFiles.deleteIdentity()?.mac, !id.isEmpty { return .init(id: id.lowercased(), name: name) }
        // Not signed in to Cloud yet: one id of this Mac's own, kept in its preferences (never synced).
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.localIDKey) { return .init(id: id, name: name) }
        let id = "local-" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.localIDKey)
        return .init(id: id, name: name)
    }
    func lastSeen(_ computerID: String) async -> Date? {
        await MainActor.run {
            NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == computerID.lowercased() }
                .map { Date(timeIntervalSince1970: Double($0.lastSeenAt) / 1000) }
        }
    }
    func name(_ computerID: String) async -> String? { await NativeProjectSecretFiles.macName(computerID) }
}

/// The receivers: a session's chat or terminal through the app's session owners; Hoot's lasting conversation per
/// WhatsApp agent (its own Hoot process and history, shown as a chat session "WhatsApp → Hoot · <name>"); an agent's
/// lasting chat per WhatsApp agent (a kept-open team job of that saved agent).
actor NativeWhatsAppReceivers: WhatsAppReceiverPort {
    private let chats: BackendSessionChats
    private let manager: BackendPTYManager
    private let hootConversations: BackendHootTaskConversations?
    private let startAgent: @Sendable (_ agentID: String, _ title: String) async throws -> String
    /// WhatsApp agent id -> the session of its Hoot or agent conversation in this run of the app.
    private var lasting: [String: String] = [:]
    private var hootRuntimes: [String: BackendCopilotSessionRuntime] = [:]

    init(chats: BackendSessionChats, manager: BackendPTYManager, hootConversations: BackendHootTaskConversations?,
         startAgent: @escaping @Sendable (String, String) async throws -> String) {
        self.chats = chats; self.manager = manager; self.hootConversations = hootConversations; self.startAgent = startAgent
    }

    private func alive(_ id: String) -> Bool { manager.list().contains { $0.id == id && $0.exitCode == nil } }

    func target(for receiver: WhatsAppReceiver, conversationName: String, agentID: String) async throws -> WhatsAppTarget? {
        switch receiver {
        case .nowhere: return nil
        case .session(let id, _):
            // The LOCAL session id (= its side panel tab id).
            guard alive(id) else { return nil }
            return .init(sessionID: id, isTerminal: !(await chats.isChat(id)))
        case .hoot:
            if let known = lasting["hoot:" + agentID], await chats.isChat(known) { return .init(sessionID: known, isTerminal: false) }
            guard let conversations = hootConversations else { throw WhatsAppProblem.notReady }
            let runtime = try await conversations.lastingConversation("whatsapp-" + agentID.replacingOccurrences(of: "wa-", with: ""))
            let state = try await runtime.ensure()
            let job = BackendTeamChatJob(fromID: "whatsapp", fromName: "WhatsApp", agentID: "hoot", agentName: "Hoot", title: conversationName)
            var kept = job; kept.keepOpen = true
            let meta = try await chats.exposeTaskRuntime(runtime, folder: state.folder.runningIn ?? NSHomeDirectory(), projectID: nil, job: kept)
            lasting["hoot:" + agentID] = meta.id; hootRuntimes[meta.id] = runtime
            return .init(sessionID: meta.id, isTerminal: false)
        case .agent(let id, _):
            let slot = "agent:" + agentID + ":" + id
            if let known = lasting[slot], await chats.isChat(known), alive(known) { return .init(sessionID: known, isTerminal: false) }
            let session = try await startAgent(id, conversationName)
            lasting[slot] = session
            return .init(sessionID: session, isTerminal: false)
        }
    }

    func say(_ target: WhatsAppTarget, text: String, attachments: [WhatsAppAttachment]) async throws {
        let blocks: [NativeRPCValue] = attachments.prefix(4).map { file in
            .object([.init("type", .string(file.mimeType == "application/pdf" ? "document" : "image")),
                     .init("source", .object([.init("type", .string("base64")), .init("media_type", .string(file.mimeType)),
                                              .init("data", .string(file.data.base64EncodedString()))]))])
        }
        let context = NativeRPCValue.object([.init("source", .object([.init("kind", .string("whatsapp")), .init("title", .string("WhatsApp"))]))])
        _ = try await chats.say(target.sessionID, text: text.isEmpty && !blocks.isEmpty ? "(picture)" : text, attachments: blocks, context: context)
    }

    func turn(_ target: WhatsAppTarget) async -> WhatsAppTurn? {
        guard let turn = try? await chats.turn(target.sessionID) else { return nil }
        let state: WhatsAppTurnState
        switch turn.state {
        case .idle: state = .idle
        case .working: state = .working
        case .done(let answer): state = .done(answer: answer)
        case .failed(let reason): state = .failed(reason: reason)
        case .needsPermission(let requests): state = .needsApproval(requests.compactMap(Self.approval))
        }
        return .init(turnID: turn.turnID, state: state)
    }
    /// One pending request as WhatsApp shows it: what it wants in one line, then the command or file exactly.
    static func approval(_ request: NativeRPCValue) -> WhatsAppApproval? {
        guard let id = request["requestId"].string ?? request["id"].string else { return nil }
        let input = request["input"]
        let tool = request["name"].string ?? request["toolName"].string ?? "a tool"
        let detail = input["command"].string ?? input["file_path"].string ?? input["path"].string
            ?? request["approvalDetails"].elements?.first?["detail"].string ?? (input.isNullish ? "" : input.compact)
        let summary = request["approvalDetails"].elements?.first?["title"].string ?? "It asks to use " + tool + "."
        return .init(id: id, summary: summary, detail: detail)
    }

    func approve(_ target: WhatsAppTarget, approvalID: String, allow: Bool) async throws -> Bool {
        guard let turn = try? await chats.turn(target.sessionID), case .needsPermission(let requests) = turn.state,
              requests.contains(where: { ($0["requestId"].string ?? $0["id"].string) == approvalID }) else { return false }
        _ = try await chats.answer(target.sessionID, request: approvalID, allowed: allow, answers: .object([]))
        return true
    }

    func type(_ target: WhatsAppTarget, text: String) async throws { try manager.write(target.sessionID, data: text) }
    func screen(_ target: WhatsAppTarget) async -> String? { manager.screen(target.sessionID) }
    func isOpen(_ target: WhatsAppTarget) async -> Bool { target.isTerminal ? alive(target.sessionID) : await chats.isChat(target.sessionID) }
    func isToolSession(_ target: WhatsAppTarget, _ sessionID: String) async -> Bool {
        hootRuntimes[target.sessionID]?.isCopilotSession(sessionID) == true
    }
    /// The Cloud id the session rows and "Switch to this Mac" use (its saved tab, else its own id).
    func cloudSessionID(_ sessionID: String) async -> String? {
        manager.list().first { $0.id == sessionID }.map(BackendCloudChats.cloudID)
    }
    /// The move's own journal on this Mac: the newest move of that session has this Mac giving it away (or stopping its
    /// woken copy) and was not called off.
    func leaving(cloudSessionID: String) async -> Bool {
        guard let mover = await MainActor.run(body: { NativeCloudChats.shared.mover }),
              let entry = await mover.entry(sessionId: cloudSessionID) else { return false }
        return (entry.role == .giver || entry.role == .stopped) && entry.step != .cancelled
    }
}

extension NativeCompositionProduction {
    /// Starts WhatsApp agents once the sessions, the chat owners and Hoot exist. Nothing is read from WhatsApp until he
    /// has added an agent; one engine per app.
    func installWhatsApp() async {
        guard NativeWhatsAppEngineBox.shared.engine == nil, let chats = sessionChats, let sessions, let authority else { return }
        let appName = configuration.appName
        let keeper = NativeWhatsAppEngineBox.shared.keeper(appName: appName)
        let registry = root.registry, lifecycle = sessions.lifecycle
        let specs = try? BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        // An agent's lasting chat: a kept-open job of that saved agent, started the way New session starts one.
        let startAgent: @Sendable (String, String) async throws -> String = { agentID, title in
            guard let specs else { throw WhatsAppProblem.notReady }
            let saved = try await registry.invoke("tasks:state", context: authority.localContext(), arguments: [])
            let choice = try BackendAgentStartSelection(arguments: .object([.init("agent", .string(agentID))]), agents: saved["agents"].elements ?? [])
            let folder = choice.agent?["cwd"].string ?? choice.agent?["folder"].string
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Terminal Deck/Independent").path
            var input = try choice.input(folder: folder, projectID: PROJProjects.resolve(projectID: nil, folder: folder), specs: specs)
            var job = BackendTeamChatJob(fromID: "whatsapp", fromName: "WhatsApp", agentID: choice.id, agentName: choice.name, title: title)
            job.keepOpen = true
            input.teamJob = job
            let meta = try await lifecycle.create(input, context: .init(rememberTab: false, fromAI: false), holdOnFailure: false)
            return meta.id
        }
        let receivers = NativeWhatsAppReceivers(chats: chats, manager: sessions.manager, hootConversations: hoot?.taskConversations, startAgent: startAgent)
        let engine = BackendWhatsAppAgents(transport: WhatsAppHTTPTransport(), settings: BackendWhatsAppSettingsStore(store: root.settings),
            keys: keeper, presence: NativeWhatsAppPresence(), receivers: receivers,
            removeEverywhere: { id in
                // Remove in the app = everywhere through the saved passwords' delete rule (Bin 30 days, Put back).
                (try? await BackendCloudKeysRemovals.shared.removeEverywhere(sourceId: BackendWhatsAppKeysStore.source, id: id)) ?? false
            })
        await engine.setKeysChanged { NativeWhatsAppEngineBox.shared.keysChanged() }
        NativeWhatsAppEngineBox.shared.set(engine)
        NativeWhatsAppAgents.shared.connect(engine)
        await engine.start()
    }
}
