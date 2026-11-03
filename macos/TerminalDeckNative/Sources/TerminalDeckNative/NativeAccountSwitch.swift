import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The account chip's actions, done by the app itself (12 Oct). They used to be page commands
/// (`web.run(PageCommand)`), and the hidden page can drop a command with no error — the same defect that
/// killed rename: the person picks an account and nothing happens. Each action here asks the engine directly
/// and says in plain words when it could not be done.
@MainActor @Observable
final class NativeAccountSwitcher {
    static let shared = NativeAccountSwitcher()

    /// The switch being asked about (its dialog), or nil.
    struct Asking: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let accountId: String
        let title: String
        let from: String
        let to: String
        var plan: AccountSwitchPlanView?
        var busy = false
        var problem: String?
        static func == (a: Asking, b: Asking) -> Bool { a.id == b.id && a.plan == b.plan && a.busy == b.busy && a.problem == b.problem }
    }
    var asking: Asking?
    /// "Switching to …" while it is worked out or made, then "Switched to …" for a moment.
    private(set) var note: AccountSwitchNote?
    /// A chip action that could not be done (a new session, a server terminal), said once, by the chip that asked.
    struct Problem: Identifiable, Equatable { let id = UUID(); let owner: String; let text: String }
    var problem: Problem?
    private var generation = 0

    func note(for sessionId: String) -> AccountSwitchNote? { AccountSwitchNote.shown(note, for: sessionId) }

    /// Pick an account for a running session: switched in place at once where it can be, otherwise the
    /// dialog says first what will happen.
    func ask(sessionId: String, accountId: String, title: String, from: String, to: String) {
        AppModel.shared.buttonActions.start()
        generation += 1
        let mine = generation
        asking = nil
        note = AccountSwitchNote(sessionId: sessionId, state: .working, text: "Switching to \(to)…")
        Task {
            let plan: AccountSwitchPlanView
            do {
                let raw = try await EngineBridge.shared.invoke("session:switch-plan", [sessionId, accountId])
                guard let read = AccountSwitchPlanView.read(raw) else {
                    show(Asking(sessionId: sessionId, accountId: accountId, title: title, from: from, to: to, problem: AccountSwitchWords.unreadablePlan), mine)
                    return
                }
                plan = read
            } catch {
                show(Asking(sessionId: sessionId, accountId: accountId, title: title, from: from, to: to, problem: Self.plain(error)), mine)
                return
            }
            guard mine == generation else { return }
            // 13 Oct: picking the account it is already on (or was just switched to) does nothing and says so.
            if plan.already { settle(sessionId, AccountSwitchWords.alreadyOn(to)); return }
            let asked = Asking(sessionId: sessionId, accountId: accountId, title: title, from: from, to: to, plan: plan)
            if plan.switchesWithoutAsking { await perform(asked, mine) } else { show(asked, mine) }
        }
    }

    func confirm() {
        guard var asked = asking, asked.plan?.refusal == nil, !asked.busy else { return }
        asked.busy = true; asked.problem = nil; asking = asked
        let mine = generation
        Task { await perform(asked, mine) }
    }

    func later() {
        guard var asked = asking, asked.plan?.refusal == nil, !asked.busy else { return }
        asked.busy = true; asked.problem = nil; asking = asked
        let mine = generation
        Task {
            do {
                _ = try await EngineBridge.shared.invoke("session:switch-later", [asked.sessionId, asked.accountId])
                guard mine == generation else { return }
                asking = nil
            } catch {
                guard mine == generation else { return }
                asked.busy = false; asked.problem = Self.plain(error); asking = asked
            }
        }
    }

    func cancel() {
        generation += 1
        asking = nil
        note = nil
    }

    /// The tick and the sentence under the chip, for a moment.
    private func settle(_ sessionId: String, _ text: String) {
        let done = AccountSwitchNote(sessionId: sessionId, state: .done, text: text)
        note = done
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.note == done { self.note = nil }
        }
    }

    private func show(_ asked: Asking, _ mine: Int) {
        guard mine == generation else { return }
        note = nil
        asking = asked
    }

    private func perform(_ asked: Asking, _ mine: Int) async {
        NativeSessionRailContinuity.shared.begin(asked.sessionId)
        defer { NativeSessionRailContinuity.shared.finishedInPlace(asked.sessionId) }
        do {
            let raw = try await EngineBridge.shared.invoke("session:switch-account", [asked.sessionId, asked.accountId])
            guard mine == generation else { return }
            let answer = raw as? [String: Any]
            let next = (answer?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? asked.sessionId
            asking = nil
            if let answer {
                let replacement = NativeTerminalSessions.shared.session(for: next)
                let previous = NativeTerminalSessions.shared.retainedSession(asked.sessionId)
                replacement.adoptSessionMetadata(answer)
                if next != asked.sessionId {
                    if replacement.isChat, let previous, previous.isChat { replacement.chatModel().carryDisplay(from: previous.chatModel()) }
                    let inspection = AGTAgentsStore.shared
                    let history = AGTTeamChatHistory.shared
                    var embedded = inspection.inspectedSession == asked.sessionId
                    if embedded { inspection.inspectedSession = next }
                    for (agent, row) in history.openedByAgent where row["session"]["id"].string == asked.sessionId {
                        embedded = true
                        if let meta = try? NativeRPCValue.fromFoundation(answer) { history.openedByAgent[agent] = row.setting("session", meta) }
                    }
                    AppModel.shared.buttonActions.replaced(asked.sessionId, with: answer)
                    if embedded { AppModel.shared.select(NativeINT2Navigation.allID) }
                    else { AppModel.shared.selectTab(next) }
                }
            }
            settle(next, answer?["accountSwitchPhase"] as? String == "already" ? AccountSwitchWords.alreadyOn(asked.to) : "Switched to \(asked.to)")
        } catch {
            guard mine == generation else { return }
            NativeSessionRailContinuity.shared.failed(asked.sessionId)
            // It did not happen, and the session is as it was: the dialog says why.
            var failed = asked
            failed.busy = false; failed.problem = Self.plain(error)
            note = nil
            asking = failed
        }
    }

    // MARK: The chip's other actions

    /// A new session on this account, in the same folder (a shell's chip, or an agent the session cannot switch).
    func newSession(from owner: String, in folder: String?, accountId: String, provider: String?) {
        guard let folder, !folder.isEmpty else {
            problem = Problem(owner: owner, text: "This session has no folder to start the new one in. Use New session instead.")
            return
        }
        Task {
            var input: [String: Any] = ["cwd": folder, "profileId": accountId, "resume": false, "cols": 100, "rows": 30]
            if let provider, !provider.isEmpty { input["provider"] = provider }
            do {
                let raw = try await EngineBridge.shared.invoke("session:create", [input], timeout: 10)
                guard let id = (raw as? [String: Any])?["id"] as? String, !id.isEmpty else {
                    problem = Problem(owner: owner, text: "The new session did not start. Check the sessions list before trying again.")
                    return
                }
                AppModel.shared.selectTab(id)
            } catch {
                problem = Problem(owner: owner, text: "The new session did not start: " + Self.plain(error))
            }
        }
    }

    /// Add account: Settings › Coding AI with its Add account sheet open.
    static func addAccount(provider: String? = nil) {
        AppModel.shared.openSettings(section: "agents")
        NativeCodingAIStore.shared.scope = .thisMachine
        NativeCodingAIStore.shared.askForAddAccount(provider)
    }

    /// Settings › Coding AI, where accounts are managed.
    static func manageAccounts() { AppModel.shared.openSettings(section: "agents") }

    /// Open through the native engine; the chip and MCP share the same action.
    func openServerShell(from owner: String, serverId: String, agentId: String?) {
        Task {
            problem = nil
            if await AppModel.shared.runButton(.openServerShell(serverId: serverId, agentId: agentId)).value { return }
            let message = AppModel.shared.buttonActions.problem ?? "The new terminal on that server did not open. Please try again."
            AppModel.shared.buttonActions.problem = nil
            problem = Problem(owner: owner, text: message)
        }
    }

    static func plain(_ error: Error) -> String {
        let text: String
        if let wire = error as? EngineWireError { text = wire.description }
        else if let local = error as? LocalizedError, let description = local.errorDescription { text = description }
        else { text = error.localizedDescription }
        return AccountSwitchWords.problem(text)
    }
}

/// The switch dialog for the app's own switch: the same confirm the page's switch draws, answered here.
struct NativeAccountChipSwitchSheet: ViewModifier {
    /// The chip's session (a local session's id, or a server shell's).
    let sessionId: String
    @Bindable var switcher = NativeAccountSwitcher.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { switcher.asking?.sessionId == sessionId ? switcher.asking : nil },
                                 set: { if $0 == nil, switcher.asking?.sessionId == sessionId { switcher.cancel() } })) { asked in
                NativeSwitchAccountConfirm(
                    request: AccountSwitchWords.request(asked.plan, title: asked.title, from: asked.from, to: asked.to,
                                                        busy: asked.busy, problem: asked.problem, canDefer: true),
                    model: AppModel.shared,
                    notice: asked.plan?.notice.map { _ in
                        asked.plan?.handsOver == true
                            ? SwitchAccountRestartOffer.handoverSentence(accountName: asked.to, ai: AccountSwitchWords.aiName(asked.plan?.toProvider))
                            : SwitchAccountRestartOffer.sentence(accountName: asked.to, carriesOn: Self.carries(asked.plan)) },
                    warning: AccountSwitchWords.warning(offer: asked.plan?.notice != nil,
                                                        status: AppModel.shared.tabs?.tabs.first(where: { $0.id == asked.sessionId })?.status),
                    answer: { action in
                        switch action {
                        case "confirm": switcher.confirm()
                        case "defer": switcher.later()
                        default: switcher.cancel()
                        }
                    })
            }
            .alert("That did not work", isPresented: Binding(get: { switcher.problem?.owner == sessionId },
                                                             set: { if !$0, switcher.problem?.owner == sessionId { switcher.problem = nil } })) {
                Button("OK") { switcher.problem = nil }
            } message: {
                Text(switcher.problem?.text ?? "")
            }
    }

    private static func carries(_ plan: AccountSwitchPlanView?) -> Bool {
        plan?.conversation == "follows" || plan?.conversation == "carried"
    }
}
