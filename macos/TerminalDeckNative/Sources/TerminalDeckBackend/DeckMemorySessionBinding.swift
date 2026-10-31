import Foundation
import TerminalDeckNativeCore

/// L8 HOST · Deck Memory: the session side bound to M1 CORE's store, M2 FLOW's inbox and L4 AGENTS' owners.
/// Each call falls back to the plain files (`DeckMemorySessionFiles`) while the store is not open yet, so a
/// session started in the first second of the app still gets its card.
public extension DeckMemorySessionServices {
    static func deckMemory(report: @escaping @Sendable (String) -> Void) -> Self {
        var services = Self.files(memoryRoot: { DeckMemory.root }, report: report)
        services.owner = { input, provider in
            if let owners = BackendAGTMemoryOwners.shared { return await owners.owner(input, provider: provider) }
            return DeckMemorySessionFiles.owner(input, root: DeckMemory.root)
        }
        services.startContext = { owner, session, reason, lastMessages in
            await DeckMemorySessionBinding.startContext(owner, session: session, reason: reason, lastMessages: lastMessages)
        }
        services.promptLines = { owner, session in
            guard owner.hasDesk, let memoryOwner = BackendAGTMemoryOwners.memoryOwner(owner), DeckMemory.isReady,
                  let lines = try? await DeckMemoryBrief.messageLines(DeckMemory.store, owner: memoryOwner,
                      since: DeckMemorySessionCenter.shared?.lastPromptDate(sessionID: session.id), moment: .plain, limit: DeckMemoryBrief.Limit.messageLines) else {
                return DeckMemorySessionFiles.promptLines(owner, root: DeckMemory.root)
            }
            // Marked as the app's own words, so a transcript capture never stores them as the person's.
            return lines.isEmpty ? "" : DeckMemoryBrief.wrap(lines.text)
        }
        services.saveTopics = { owner, session in await DeckMemorySessionBinding.snapshotTopic(owner, session: session) }
        return services
    }
}

public enum DeckMemorySessionBinding {
    /// What a session-start hook may print and still reach the model whole (Claude Code's limit is 10,000).
    static let hookBudget = DeckMemoryBrief.Limit.claudeCodeHook - 100 - DeckMemoryBrief.wrap("").count
    /// The same opening Hoot's desk gets (full card, open topics, the board), with the session's own frame around it.
    static func startContext(_ owner: DeckMemorySessionOwner, session: BackendSessionMeta, reason: String,
                             lastMessages: [(role: String, text: String)], root: URL? = nil, filesOnly: Bool = false) async -> String {
        guard owner.hasDesk, let memoryOwner = BackendAGTMemoryOwners.memoryOwner(owner) else { return "" }
        let root = root ?? DeckMemory.root
        let who = owner.name.isEmpty ? owner.id : owner.name
        // The seat, not the hire: a new hire in this seat reads exactly the same card, notes and topics.
        var role = "the lead of the \(owner.project ?? owner.id) project"
        if owner.kind != .lead {
            role = "filling the \"\(owner.id)\" role"
            if let project = owner.project { role += " on the \(project) project" }
            if who != owner.id { role += " (as \(who))" }
        }
        var head = "# Your memory (kept by Terminal Deck, not by this chat)\nYou are \(role). "
        if reason == "compact" { head += "The conversation was just compacted; rely on what follows." }
        else { head += "The app hands you your card, your open topics and the board at the top of every clean desk." }
        head += owner.handLine
        head += " Trust this over your own recollection. Exact facts (which build is installed, did it ship) are checked at the source, never from memory."
        var tail: [String] = []
        if reason == "compact", !lastMessages.isEmpty {
            var block = "## The last messages, word for word"
            for message in lastMessages.suffix(6) { block += "\n**" + (message.role == "user" ? "User" : "You") + ":** " + (message.text.count > 500 ? String(message.text.prefix(500)) + " …" : message.text) }
            tail.append(block)
        }
        let folder = root.appendingPathComponent(memoryOwner.folder).path
        tail.append("## Keeping it current\nWhen a topic moves, update its \"where we are\" note with the memory_topic_update tool (or edit the file under `\(folder)/topics/`). A decision, a correction or a lesson worth keeping: memory_note_add. Looking something up: memory_search. This memory belongs to the role you fill, so whoever fills it next starts from it.")
        tail.append(DeckMemorySessionFiles.reportForm)
        // Claude Code passes at most 10,000 characters of hook output (over that the model only gets a 2,000
        // character preview). M1 fits its part to what is left by dropping whole items and saying which.
        let own = head.count + tail.reduce(0) { $0 + $1.count + 2 } + 2
        let budget = max(2_000, hookBudget - own)
        let fromStore = !filesOnly && DeckMemory.isReady
            ? try? await DeckMemoryBrief.opening(DeckMemory.store, owner: memoryOwner, session: session.id, job: owner.job, limit: budget) : nil
        let opening = fromStore ?? DeckMemorySessionFiles.opening(memoryOwner, job: owner.job, limit: budget, root: root)
        guard opening.fits else {
            // Even with everything optional left out the shared card is longer than the CLI passes on from a hook.
            // Never let it shrink to a silent preview: say so, and have the session read the card itself.
            DeckMemorySessionCenter.shared?.say("The card for \(session.title) is too long to hand over at the start of a \(session.provider) session; the session was told to read it from its file. Shorten the card or the category template.")
            let card = "## Your card\nIt is too long to lay down here. Read it now, before anything else: `cat \"\(folder)/card.md\"`, and the shared card of your category under `\(root.appendingPathComponent("templates").path)/`. Then read your open topics in `\(folder)/topics/`."
            return DeckMemoryBrief.wrap(([head, card] + tail).joined(separator: "\n\n"))
        }
        return DeckMemoryBrief.wrap(([head, opening.text] + tail).joined(separator: "\n\n"))
    }

    /// PreCompact, no AI involved: the last exchanges go into ONE app-kept topic of the
    /// owner, so "where we were" is on disk even if the agent never wrote a topic itself.
    static func snapshotTopic(_ owner: DeckMemorySessionOwner, session: BackendSessionMeta) async {
        guard owner.hasDesk, let memoryOwner = BackendAGTMemoryOwners.memoryOwner(owner), DeckMemory.isReady,
              let center = DeckMemorySessionCenter.shared else { return }
        let last = center.lastMessages(sessionID: session.id, count: 8)
        guard !last.isEmpty else { return }
        var body = "Saved by the app (not by an AI) just before this session's desk was cleared, from the session \"\(session.title)\". These are its last messages, word for word.\n"
        for message in last { body += "\n**" + (message.role == "user" ? "User" : "Agent") + ":** " + message.text + "\n" }
        // The topic belongs to the JOB (spec 3b), so several hands on one seat never overwrite each other's.
        let title = owner.job.map { "Desk snapshot: " + $0 + (owner.hand.map { " (hand \($0))" } ?? "") } ?? "Desk snapshot: " + session.title
        _ = try? await DeckMemory.store.updateTopic(memoryOwner, title: title, body: body,
            stamp: DeckMemoryStamp(owner: memoryOwner, project: owner.project ?? session.projectId, session: session.id,
                                   agent: owner.name.isEmpty ? session.provider : owner.name, hand: owner.hand, job: owner.job))
    }

    /// Who a session is, for a memory tool call made from inside it (M1's session resolver).
    public static func stamp(sessionID: String, manager: BackendPTYManager) -> DeckMemoryStamp? {
        guard let center = DeckMemorySessionCenter.shared, let session = manager.list().first(where: { $0.id == sessionID }) else { return nil }
        let owner = center.owner(sessionID: sessionID)
        if let memoryOwner = BackendAGTMemoryOwners.memoryOwner(owner) {
            return DeckMemoryStamp(owner: memoryOwner, project: owner.project ?? session.projectId, session: sessionID, agent: owner.name.isEmpty ? session.provider : owner.name,
                                   hand: owner.hand, job: owner.job)
        }
        // A plain session writes to its project's memory, never to another owner's.
        return DeckMemoryStamp(owner: .project(owner.project ?? session.resolvedProjectID), project: owner.project ?? session.resolvedProjectID, session: sessionID, agent: session.provider)
    }
}
