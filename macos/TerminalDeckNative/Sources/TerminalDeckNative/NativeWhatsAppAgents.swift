import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The one observable store every WhatsApp screen reads (Settings > AI apps "WhatsApp" group, the "WhatsApp" submenu in a
/// page's "…" menu and a session row's right-click menu, the heading chip). It holds the list of WhatsApp agents and
/// passes every action to the engine. The composition sets `engine` once WhatsApp agents are ready on this computer;
/// picture tests set a fixture engine (any `WhatsAppAgentsControlling`).
@MainActor @Observable final class NativeWhatsAppAgents {
    static let shared = NativeWhatsAppAgents()

    /// The profiles, in the order he added them.
    private(set) var agents: [WhatsAppAgentProfile] = []
    /// The last refusal in one plain sentence (a refused key, a sixth agent); the screen that acted shows it, then clears it.
    var problem: String?
    /// True while an add or a key replacement is being checked with WhatsApp (the field and "Add" wait).
    private(set) var checking = false

    @ObservationIgnored private(set) var engine: (any WhatsAppAgentsControlling)?

    init() {}

    /// Set by the composition (or a test). Reads the list at once and follows every change.
    func connect(_ engine: (any WhatsAppAgentsControlling)?) {
        self.engine = engine
        guard let engine else { agents = []; return }
        Task { [weak self] in
            await engine.observe { list in Task { @MainActor in self?.agents = list } }
            let list = await engine.agents()
            await MainActor.run { self?.agents = list }
        }
    }

    // MARK: What the views read

    var canAdd: Bool { agents.canAdd }
    /// The WhatsApp agents attached to this page or session (the submenu's check marks).
    func attached(to receiver: WhatsAppReceiver) -> [WhatsAppAgentProfile] { agents.attached(to: receiver) }
    /// The chip: the first WhatsApp agent attached here, nil = no chip.
    func chip(for receiver: WhatsAppReceiver) -> WhatsAppAgentProfile? { attached(to: receiver).first }
    func attached(sessionID: String) -> [WhatsAppAgentProfile] { attached(to: .session(id: sessionID, name: "")) }
    var attachedToHoot: [WhatsAppAgentProfile] { attached(to: .hoot) }
    /// The default name the add row's name field is prefilled with.
    var nextDefaultName: String { WhatsAppAgentsLimits.defaultName(taken: agents.map(\.name)) }

    // MARK: What the views call (each returns true when it was done; a refusal is in `problem`)

    @discardableResult func add(name: String, key: String) async -> Bool {
        checking = true; defer { checking = false }
        return await run { _ = try await $0.add(name: name, key: key) }
    }
    @discardableResult func rename(_ id: String, to name: String) async -> Bool { await run { try await $0.rename(id, to: name) } }
    @discardableResult func replaceKey(_ id: String, key: String) async -> Bool {
        checking = true; defer { checking = false }
        return await run { try await $0.replaceKey(id, key: key) }
    }
    @discardableResult func remove(_ id: String) async -> Bool { await run { try await $0.remove(id) } }
    @discardableResult func setReceiver(_ id: String, _ receiver: WhatsAppReceiver) async -> Bool { await run { try await $0.setReceiver(id, receiver) } }
    /// "WhatsApp > <agent>" on this page or session: attach it here. A menu or the chip has no line of its own, so a
    /// refusal is said once on the app's problem line.
    @discardableResult func attach(_ id: String, to receiver: WhatsAppReceiver) async -> Bool {
        await sayOnProblemLine(await run { try await $0.attach(id, to: receiver) })
    }
    /// The switch on an attached agent (on = answers go to WhatsApp, off = they stay in Terminal Deck).
    @discardableResult func setSending(_ on: Bool, for agentID: String) async -> Bool {
        await sayOnProblemLine(await run { try await $0.setSending(on, for: agentID) })
    }
    /// "WhatsApp > Off" on this page or session.
    @discardableResult func off(_ receiver: WhatsAppReceiver) async -> Bool { await sayOnProblemLine(await run { try await $0.off(receiver) }) }
    private func sayOnProblemLine(_ done: Bool) async -> Bool {
        if !done, let problem { AppModel.shared.buttonActions.problem = problem; self.problem = nil }
        return done
    }

    private func run(_ action: @escaping @Sendable (any WhatsAppAgentsControlling) async throws -> Void) async -> Bool {
        guard let engine else { problem = WhatsAppProblem.notReady.message; return false }
        do {
            try await action(engine)
            problem = nil
            agents = await engine.agents()
            return true
        } catch let refusal as WhatsAppProblem {
            problem = refusal.message; return false
        } catch {
            // Never the error's own text: it could quote what was typed.
            problem = "That did not work. Try again."; return false
        }
    }
}
