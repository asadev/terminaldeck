import Foundation
import TerminalDeckNativeCore

/// A session switched to another AI's account (Asad, 13 Oct: "conversation can stay same, just other AI takes over").
/// The same idea as Hoot's (BackendHootHandover): a CLI's own conversation belongs to one AI, so the new AI starts in
/// the same tab, folder, project and seat, and its first message carries the conversation so far, word for word,
/// inside the app's own marker (never the person's words), newest kept, as much as fits. The whole record goes in a
/// file it is told it can read for anything older. Each switch adds the AI that is handing over to that record, so a
/// later switch back carries everything, including what happened under the other AI.
public enum BackendSessionAIHandover {
    public static let agents: Set<String> = ["claude", "codex", "gemini"]
    /// About 12,000 tokens, like Hoot's: well inside every AI's window and one file it reads first.
    public static let budget = 50_000
    static let messageCap = 8_000
    static let folderName = "session-handover"
    public static let open = "<terminal-deck-conversation>", close = "</terminal-deck-conversation>"

    public static func aiName(_ provider: String) -> String { BackendHootHandover.names[provider] ?? provider }

    /// One message of the record: who said it, under which AI, and what, word for word.
    public struct Turn: Sendable, Equatable, Codable {
        public let speaker: String
        public let text: String
        public let fromPerson: Bool
        /// The AI (and account) the session was on when it was said.
        public let ai: String
        public init(speaker: String, text: String, fromPerson: Bool, ai: String) {
            self.speaker = speaker; self.text = text; self.fromPerson = fromPerson; self.ai = ai
        }
    }

    // MARK: Planning

    /// The plan for picking another AI's account, or nil when it is the same AI (or not an AI session).
    static func plan(sessionID: String, live: BackendSessionMeta, saved: BackendSessionSaved, target: BackendAccountProfile) -> BackendSessionSwitchPlan? {
        guard live.exitCode == nil, live.provider != target.provider, agents.contains(live.provider), agents.contains(target.provider) else { return nil }
        var plan = BackendSessionSwitchPlan(sessionID: sessionID, refusal: nil, from: BackendSessionSwitchCoordinator.account(of: live), to: target,
                                            conversation: "handover", resume: false, conversationID: nil, mode: .restart, saved: saved, carried: nil)
        plan.notice = SwitchAccountRestartOffer.handoverSentence(accountName: target.name, ai: aiName(target.provider))
        return plan
    }

    // MARK: The words

    /// The turns of one AI's stretch, from its own record: the person's and the AI's messages, the hand-over line
    /// the app typed left out (it is not the person's).
    static func turns(_ pieces: [DeckMemoryFlowPiece], ai: String, account: String) -> [Turn] {
        let section = "\(ai) (\(account))"
        return pieces.compactMap { piece in
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch piece.role {
            case .user: return isPointer(text) ? nil : Turn(speaker: "The person", text: text, fromPerson: true, ai: section)
            case .assistant: return Turn(speaker: ai, text: text, fromPerson: false, ai: section)
            default: return nil
            }
        }
    }
    static func isPointer(_ text: String) -> Bool { text.contains("/" + folderName + "/") && text.hasPrefix("Read ") }

    /// The whole record for the AI to read: every turn, oldest first, a heading where the AI changed.
    static func render(_ turns: [Turn]) -> String {
        var text = "# This session's conversation, word for word\n\nOldest first. Each part names the AI that was answering.", section = ""
        for turn in turns {
            if turn.ai != section { section = turn.ai; text += "\n\n## " + section }
            text += "\n\n" + turn.speaker + ": " + turn.text
        }
        return text + (turns.isEmpty ? "\n\n(Nothing has been said yet.)\n" : "\n")
    }

    /// The first message's file: the app's marker, who is taking over from whom, the newest messages that fit, and
    /// where the whole record is.
    static func message(turns: [Turn], from: String, to: String, recordPath: String, budget: Int = budget) -> String {
        let lastPerson = turns.lastIndex { $0.fromPerson } ?? turns.count - 1
        var kept: [String] = [], used = 0
        for index in turns.indices.reversed() {
            let text = turns[index].text.count > messageCap
                ? String(turns[index].text.prefix(messageCap / 2)) + "\n[… left out here; the full text is in the record …]\n" + String(turns[index].text.suffix(messageCap / 2))
                : turns[index].text
            let line = turns[index].speaker + ": " + text
            guard index >= lastPerson || used + line.count <= budget else { break }
            kept.insert(line, at: 0); used += line.count
        }
        let left = turns.count - kept.count
        return open + "\n## The conversation so far, word for word\n"
            + "You are \(to), taking over this session from \(from) in the same terminal: the person switched this session to you on purpose. "
            + "This text is from Terminal Deck, not from the person. Everything below was said before, oldest first"
            + (left > 0 ? "; the \(left) earlier message\(left == 1 ? " is" : "s are") in the full record" : "")
            + ". The full record of this session, every word under every AI, is \(recordPath): read it whenever you need anything older. "
            + "Carry on from here as if nothing changed: do not greet the person again. Answer only \"Ready, carrying on.\" and wait for their next message.\n\n"
            + (kept.isEmpty ? "(Nothing has been said yet.)" : kept.joined(separator: "\n\n")) + "\n" + close + "\n"
    }

    /// The one short line typed into the new AI's prompt.
    static func pointer(_ path: String) -> String {
        "Read " + path + " first: it is this session's conversation so far, from Terminal Deck (not the person's words)."
    }

    // MARK: Doing it

    /// The record of the session's current AI, in its own account's folder (nil when none can be found).
    static func source(live: BackendSessionMeta, saved: BackendSessionSaved, configDir: String, claimed: Set<String>) throws -> DeckMemoryFlowRecordTarget? {
        switch live.provider {
        case "claude":
            guard let id = BackendSessionSwitchCoordinator.onScreenConversation(meta: live, cwd: saved.cwd, configDir: configDir, claimed: claimed) else { return nil }
            let projects = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
            for spelling in NativeTranscriptPaths.projectSpellings(saved.cwd) {
                let file = projects.appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(spelling)).appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: file.path) {
                    return DeckMemoryFlowRecordTarget(path: file.path, roots: [projects.path], provider: "claude", conversation: id)
                }
            }
            return nil
        case "codex", "gemini":
            guard let found = try BackendTaskAgentTranscripts.target(provider: live.provider, configDirectory: configDir, cwd: saved.cwd,
                                                                    createdAt: live.createdAt, knownID: live.agentSessionId, claimed: claimed) else { return nil }
            return DeckMemoryFlowRecordTarget(path: found.path, roots: found.roots, provider: live.provider, conversation: live.agentSessionId ?? "")
        default: return nil
        }
    }

    /// U144 (#423): the newest record holds every earlier stretch, so a switch that went through leaves only its own
    /// three files in the tab's folder, not a growing copy of the conversation per switch.
    static func keepNewest(in folder: URL, stamp: String) {
        let kept: Set<String> = ["record-\(stamp).json", "record-\(stamp).md", "handover-\(stamp).md"]
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(file.lastPathComponent) && (file.lastPathComponent.hasPrefix("record-") || file.lastPathComponent.hasPrefix("handover-")) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    /// The tab was removed: the conversation handed over in it goes too.
    static func forget(tab: String, data: URL) {
        guard !tab.isEmpty, !tab.contains("/"), tab != ".", tab != ".." else { return }
        try? FileManager.default.removeItem(at: data.appendingPathComponent(folderName).appendingPathComponent(tab))
    }

    /// Hand the session to the other AI: write the record and the first message, start the new AI in the same tab,
    /// prove it alive, give it the conversation, remember it, and only then stop the old one.
    static func perform(_ plan: BackendSessionSwitchPlan, target: BackendAccountProfile, saved: BackendSessionSaved,
                        lifecycle: BackendSessionLifecycleCoordinator, store: NativeStateStore, planner: BackendSessionRestorePlanner,
                        emit: @Sendable (BackendSessionLifecycleEvent) -> Void, note: String, rememberTab: Bool) async throws -> BackendSessionSwitchCoordinator.Execution {
        let sessionID = plan.sessionID
        guard let live = lifecycle.manager.list().first(where: { $0.id == sessionID && $0.exitCode == nil }) else { throw BackendSessionFailure.missingSession }
        guard let data = store.file?.deletingLastPathComponent() else {
            throw BackendSessionFailure.unsupported("This app has no folder to keep the conversation in, so nothing was changed.")
        }
        let from = aiName(live.provider), to = aiName(target.provider)
        // This AI's stretch, from its own record, after whatever earlier switches handed over.
        let account = try await planner.accountFolder(saved)
        let others = lifecycle.manager.list().filter { $0.id != sessionID && $0.exitCode == nil }
        let claimed = Set(others.compactMap { $0.agentSessionId })
        let pieces = try await Task.detached(priority: .utility) { () -> [DeckMemoryFlowPiece] in
            guard let found = try Self.source(live: live, saved: saved, configDir: account.configDir, claimed: claimed) else { return [] }
            return try DeckMemoryFlowTranscripts.readNew(found, record: nil).pieces
        }.value
        let root = data.appendingPathComponent(folderName), folder = root.appendingPathComponent(live.tabKey ?? sessionID)
        // What earlier switches in this tab handed over: the newest record in the tab's own folder (the saved record's
        // pointer is only a hint: the app re-notes kept sessions from their launch at every start, which drops it).
        var earlier: [Turn] = []
        let newest = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("record-") && $0.pathExtension == "json" }.map(\.path).sorted().last
        if let path = newest ?? saved.raw["handoverRecord"].string, NativeTranscriptPaths.isDescendant(path, of: root.path),
           let bytes = FileManager.default.contents(atPath: path), let turns = try? JSONDecoder().decode([Turn].self, from: bytes) { earlier = turns }
        let reading = await lifecycle.sessionAccount(sessionID: sessionID)
        let label = account.system && !account.promised ? (reading.email ?? live.profileName ?? account.name) : (live.profileName ?? account.name)
        let all = earlier + turns(pieces, ai: from, account: label)
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let recordData = folder.appendingPathComponent("record-\(stamp).json"), recordFile = folder.appendingPathComponent("record-\(stamp).md")
        let messageFile = folder.appendingPathComponent("handover-\(stamp).md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try BackendAccountFiles.writeAtomic(JSONEncoder().encode(all), to: recordData)
            try BackendAccountFiles.writeAtomic(Data(render(all).utf8), to: recordFile)
            try BackendAccountFiles.writeAtomic(Data(message(turns: all, from: from, to: to, recordPath: recordFile.path).utf8), to: messageFile)
        } catch { throw BackendSessionFailure.unsupported("The conversation could not be written down for \(to), so nothing was changed. This session is still running as it was.") }

        // The new AI in the same tab, folder, project and seat; nothing of the old AI's own settings.
        var input = saved.input(resume: false, profileID: target.id, conversationID: nil, replaces: sessionID)
        input.provider = target.provider; input.homeProfileId = nil; input.resumeConversationId = nil
        input.model = nil; input.effort = nil; input.claudeAgent = nil; input.agentDefinitionsFile = nil; input.permissionMode = nil; input.agentSettings = nil
        let created = try await lifecycle.create(input, context: BackendLaunchContext(rememberTab: rememberTab), holdOnFailure: false, announce: false,
                                                 named: saved.title)
        do {
            let readiness = try await BackendSessionReplacementReadiness.awaitReady(sessionID: created.id, manager: lifecycle.manager)
            guard readiness.outcome != .died, readiness.outcome != .signedOut else {
                throw BackendSessionFailure.unsupported(readiness.outcome == .signedOut
                    ? "\(target.name) is not signed in to \(to), so nothing was switched. This session is still running as it was."
                    : BackendSessionSwitchCoordinator.startFailedMessage(accountName: target.name, said: readiness.said))
            }
            var remembered = saved.raw.setting("provider", .string(target.provider)).setting("profileId", .string(target.id))
                .setting("homeProfileId", .missing).setting("handoverRecord", .string(recordData.path))
                .setting("model", .missing).setting("effort", .missing).setting("claudeAgent", .missing).setting("agentDefinitionsFile", .missing).setting("permissionMode", .missing)
            remembered = remembered.setting("agentSessionId", created.agentSessionId.map(NativeRPCValue.string) ?? .missing)
            try await store.ledgerNote(created.id, saved: remembered)
            try await lifecycle.close(sessionID: sessionID, reason: .replaced)
            emit(.replaced(oldID: sessionID, session: created, note: note))
        } catch { try? await lifecycle.close(sessionID: created.id); throw error }
        keepNewest(in: folder, stamp: stamp)
        // The conversation goes in as soon as its prompt takes it (a first-run or trust screen first is answered there).
        let line = pointer(messageFile.path), id = created.id
        Task {
            for _ in 0..<120 {
                do {
                    try await BackendTaskBriefDelivery.deliver(id, line: line, manager: lifecycle.manager, write: { text in try await lifecycle.write(sessionID: id, data: text) })
                    return
                } catch {
                    guard lifecycle.manager.list().contains(where: { $0.id == id && $0.exitCode == nil }) else { return }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        return BackendSessionSwitchCoordinator.Execution(phase: .replaced, session: created, requestedAccount: target.identity)
    }
}

/// Switching a CHAT session (13 Oct; the Sessions seat's chat sessions run their AI in Hoot's structured mode). Hoot's
/// own switching is the model: nothing to read first, the next turn simply runs on the new account or AI, with the
/// conversation carried. One code path for both kinds: a chat session (its saved launch has `chat: true`) is switched by
/// relaunching its tab through the ordinary launcher, whose chat dispatch (BackendSessionChats.launch) closes the tab's
/// live chat and opens the same tab's conversation store under the new account or AI, which carries the conversation
/// into its next message. No session-host in-place step and no hand-over file are involved.
public enum BackendSessionChatSwitch {
    static func isChat(_ saved: BackendSessionSaved?) -> Bool { saved?.raw["chat"].bool == true }

    /// The plan for a chat session (any account, same AI or another), or nil for a terminal session.
    static func plan(sessionID: String, live: BackendSessionMeta, saved: BackendSessionSaved, target: BackendAccountProfile) -> BackendSessionSwitchPlan? {
        guard isChat(saved), live.exitCode == nil, BackendSessionAIHandover.agents.contains(target.provider) else { return nil }
        var plan = BackendSessionSwitchPlan(sessionID: sessionID, refusal: nil, from: BackendSessionSwitchCoordinator.account(of: live), to: target,
                                            conversation: "same", resume: false, conversationID: nil, mode: .inPlace, saved: saved, carried: nil)
        plan.chat = true
        return plan
    }

    /// What the tab is started again with, and what is remembered for it: the same launch (its `chat` included) on the
    /// chosen account; for another AI, its own settings left for the new AI's defaults.
    static func relaunch(saved: BackendSessionSaved, target: BackendAccountProfile, from provider: String,
                         replacing sessionID: String) -> (BackendCreateSessionInput, NativeRPCValue) {
        var input = saved.input(resume: false, profileID: target.id, conversationID: nil, replaces: sessionID)
        input.homeProfileId = nil; input.resumeConversationId = nil
        var remembered = saved.raw.setting("profileId", .string(target.id)).setting("homeProfileId", .missing)
        if target.provider != provider {
            input.provider = target.provider
            input.model = nil; input.effort = nil; input.claudeAgent = nil; input.agentDefinitionsFile = nil; input.permissionMode = nil; input.agentSettings = nil
            remembered = remembered.setting("provider", .string(target.provider)).setting("model", .missing).setting("effort", .missing)
                .setting("claudeAgent", .missing).setting("agentDefinitionsFile", .missing).setting("permissionMode", .missing).setting("agentSessionId", .missing)
        }
        return (input, remembered)
    }
    /// The tab's chat relaunched on the account (and AI) chosen; its own store carries the conversation.
    static func perform(_ plan: BackendSessionSwitchPlan, target: BackendAccountProfile, saved: BackendSessionSaved,
                        lifecycle: BackendSessionLifecycleCoordinator, store: NativeStateStore,
                        emit: @Sendable (BackendSessionLifecycleEvent) -> Void, note: String, rememberTab: Bool) async throws -> BackendSessionSwitchCoordinator.Execution {
        let sessionID = plan.sessionID
        guard let live = lifecycle.manager.list().first(where: { $0.id == sessionID && $0.exitCode == nil }) else { throw BackendSessionFailure.missingSession }
        var (input, remembered) = relaunch(saved: saved, target: target, from: live.provider, replacing: sessionID)
        let created = try await lifecycle.create(input, context: BackendLaunchContext(rememberTab: rememberTab), holdOnFailure: false, announce: false,
                                                 named: saved.title)
        do {
            if let id = created.agentSessionId { remembered = remembered.setting("agentSessionId", .string(id)) }
            try await store.ledgerNote(created.id, saved: remembered)
            if created.id != sessionID {
                try await lifecycle.close(sessionID: sessionID, reason: .replaced)
                emit(.replaced(oldID: sessionID, session: created, note: note))
            }
        } catch { if created.id != sessionID { try? await lifecycle.close(sessionID: created.id) }; throw error }
        return BackendSessionSwitchCoordinator.Execution(phase: created.id == sessionID ? .confirmed : .replaced, session: created,
                                                         requestedAccount: target.identity)
    }
}
