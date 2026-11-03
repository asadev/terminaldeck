import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Pictures on a paired phone (Asad, 28 Oct): the remote `pictures` capability, read from what this Mac's own
/// screens draw: the project registry and its logos (`ProjectLogoView`), the Agents page's agents and Hoot
/// (`AgentAvatar`), and the agent or lead each session's row names in the session list (`SIDEBARSessionAgents`), never
/// the lead for a session started with no agent.
/// Not fatal: without it a phone draws letter tiles and plain icons, as before.
extension NativeCompositionProduction {
    func installPhonePictures() async {
        guard let endpoint = remoteEndpoint, let authority else {
            report("Phone pictures are unavailable: the remote endpoint is not wired.")
            return
        }
        let registry = root.registry
        let source = BackendPhonePictures.Source(
            projects: { (try? await Self.registeredProjects(registry: registry, context: authority.localContext())) ?? [] },
            logos: root.dataRoot.appendingPathComponent(BackendPROJLogos.folderName, isDirectory: true),
            agents: { await MainActor.run { NativePhonePictureFaces.directory() } },
            sessionAgents: { ids in await MainActor.run { NativePhonePictureFaces.sessions(ids) } },
            visibleSessions: { context in try await endpoint.panelSessionIDs(context) })
        let owner = "native.phone-pictures"
        do {
            // Kept on the composition and in its stop step, as phone chats are: the endpoint holds the adapter only
            // weakly (install #7 kept nothing, so the adapter was freed at once; PHONEPicturesHostTests).
            let installation = try await BackendPhonePictures.install(on: endpoint, source: source, ownerID: owner)
            do {
                try await root.retain(.init(name: "phone-pictures", domains: ["phone-pictures"], ownerID: owner,
                                            invokes: [], stop: { await installation.stop() }))
                phonePictures = installation
                // Who each session was started as, read now and kept current: the faces need it even while no main
                // window (and so no side list, which starts it too) is on screen.
                Task { @MainActor in await AGTTeamChatHistory.shared.start() }
            } catch { await installation.stop(); throw error }
        } catch {
            report("Phone pictures are unavailable: " + error.localizedDescription)
        }
    }
}

/// An agent's picture as the phone draws it: the same icon and colour `AgentAvatar` draws here, Hoot as Hoot.
@MainActor
enum NativePhonePictureFaces {
    static func face(_ agent: AGTAgent) -> BackendPhonePictures.Face {
        .init(id: agent.profileID ?? agent.id, name: agent.name, icon: AGTIcon.raw(agent.icon, colour: agent.iconColour), hoot: agent.isHoot)
    }

    /// The Agents page's agents and Hoot (a live session without a profile is not an agent of its own).
    static func directory() -> [BackendPhonePictures.Face] {
        AGTAgentsStore.shared.agents.filter { $0.kind != .session }.map(face)
    }

    /// Who works in each session: the agent the session list draws under the session's name, except for a session
    /// nobody picked an agent for (`isLeadFallback`), which the phones show as its AI ("Claude").
    static func sessions(_ ids: [String]) -> [String: BackendPhonePictures.Face] {
        let agents = SIDEBARSessionAgents.all()
        var result: [String: BackendPhonePictures.Face] = [:]
        for id in ids { if let agent = agent(id, agents: agents) { result[id] = face(agent) } }
        return result
    }

    /// The one answer to "who works in this session", for the phones and the Mac's own session rows alike (Asad,
    /// 29 Oct: the Mac's rows as the phone's): the agent the session list names, never the lead for a session started
    /// with no agent. `agents` is `SIDEBARSessionAgents.all()`, read once for a whole list.
    static func agent(_ id: String, agents: [String: AGTAgent]) -> AGTAgent? {
        guard !isLeadFallback(id) else { return nil }
        return NativeSessionRailContinuity.shared.agent(id) ?? agents[id]
    }

    /// A session started with "No agent" that the Mac's session list names after its project's lead only because it
    /// was opened in that lead's folder (the app put it in the lead seat; `AGTLeads.worksAsLead`). On the phones it is
    /// the AI's own chat, not the lead's (28 Oct 2026: they said "Decker · Claude" / "Ask Decker" for it). A session
    /// started as an agent (its explicit owner, or a task's agent) keeps its face; the Mac's own list is unchanged.
    /// Until the agents sessions were started as have been read once (started with the phone pictures, and kept current
    /// by its session events), nothing is a fallback: every face is kept, so a session started as the lead never reads
    /// as "no agent" (Reviewer 28 Oct).
    static func isLeadFallback(_ id: String) -> Bool {
        guard AGTTeamChatHistory.shared.ownersLoaded, AGTAgentsStore.shared.sender(of: id) == nil,
              let key = AGTHandsStore.shared.sessionSeats[id], case .lead? = AGTSeat(key: key) else { return false }
        return AGTAgentsStore.shared.live.first { $0.sessionID == id }?.taskID == nil
    }
}
