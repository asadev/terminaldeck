import Foundation
import UserNotifications
import TerminalDeckNativeCore

// Siri / Shortcuts (lane R): asking Hoot from outside the window.
//
// The island's Ask box, done from Swift (src/renderer/island/IslandPage.tsx):
// find Hoot (`copilot:state`, starting it with `copilot:ensure` when it is not
// running — the same Hoot the sidebar pins, never a second one), type the
// question into its session (`session:write`, text then Enter), and read the
// answer from Hoot's own conversation (`chat:load` on Hoot's folder) once its
// session says the turn is over (`session:status`). Nothing polls the
// conversation: it is read when the status changes, or after twenty quiet
// seconds as a safety net.
//
// One ask runs to its end on its own task. Siri waits for it within its budget;
// if the answer is later than that, the ask carries on and the answer arrives
// as a notification.

@MainActor
final class HootAsk {
    enum Outcome: Sendable {
        case answer(IntentAnswer)
        case failed(IntentProblem)
    }

    let question: String
    private(set) var assistant: String
    /// The question has been typed into Hoot's session.
    private(set) var asked = false
    private(set) var task: Task<Outcome, Never>?
    private var finished: Outcome?
    private var notifyWhenDone = false

    private init(question: String) {
        self.question = question
        assistant = IntentsEngine.assistantName
    }

    static func start(question: String) -> HootAsk {
        let ask = HootAsk(question: question)
        ask.task = Task { @MainActor in
            let outcome = await ask.run()
            ask.finish(outcome)
            return outcome
        }
        return ask
    }

    /// Siri could not wait: send the answer (or why there is none) as a notification.
    func deferToNotification() {
        if let finished { post(finished) } else { notifyWhenDone = true }
    }

    private func finish(_ outcome: Outcome) {
        finished = outcome
        switch outcome {
        case .answer: IntentsEngine.note("Hoot answered")
        case .failed(let problem): IntentsEngine.note("Hoot ask ended: \(problem.sentence)")
        }
        if notifyWhenDone { post(outcome) }
    }

    private func post(_ outcome: Outcome) {
        let assistant = self.assistant
        switch outcome {
        case .answer(let answer):
            let note = IntentHoot.notification(answer, assistant: assistant)
            Task { await IntentsNotifier.post(title: note.title, body: note.body) }
        case .failed(let problem):
            Task { await IntentsNotifier.post(title: "\(assistant) couldn't answer", body: problem.sentence) }
        }
    }

    // MARK: The ask

    private func run() async -> Outcome {
        do {
            // Generous here: this part may run on after Siri has been answered.
            try await IntentsEngine.ready(IntentBudget(.seconds(90)), cap: .seconds(90))
            _ = await IntentsEngine.sidebar(within: .seconds(5))
            assistant = IntentsEngine.assistantName

            var hoot = try await copilotState()
            var startedNow = false
            if !hoot.isRunning {
                IntentsEngine.note("starting Hoot for a question")
                if let ensured = IntentHoot.copilot(try await IntentsEngine.invoke("copilot:ensure")) { hoot = ensured }
                startedNow = true
                // `ensure` answers once the CLI is spawned; a slow sandbox can still say "starting".
                var tries = 0
                while !hoot.isRunning, hoot.isStarting || hoot.sessionId == nil, tries < 30 {
                    tries += 1
                    try await Task.sleep(for: .seconds(1))
                    hoot = try await copilotState()
                    if hoot.status == "stopped" || hoot.status == "failed" { break }
                }
            }
            guard hoot.isRunning, let sessionId = hoot.sessionId else {
                let why = hoot.problem.map { " \(IntentSpeech.ending($0))" } ?? ""
                return .failed(.plain("\(assistant) couldn't be started.\(why)"))
            }
            guard let folder = hoot.folder else {
                return .failed(.plain("\(assistant)'s conversation couldn't be found."))
            }

            let feed = StatusFeed(sessionId: sessionId)
            defer { feed.close() }

            if startedNow {
                // A CLI that has not drawn its prompt drops what is typed into it.
                var ready = false
                let clock = ContinuousClock()
                let end = clock.now.advanced(by: .seconds(40))
                while !ready, clock.now < end {
                    guard let status = await feed.next(within: end - clock.now) else { break }
                    ready = status == "waiting" || status == "idle"
                }
                try await Task.sleep(for: .milliseconds(400))
            }

            let known = Set(try await conversation(folder).map(\.id))
            let writes = IntentHoot.writes(for: question)
            for (index, data) in writes.enumerated() {
                EngineBridge.shared.send("session:write", [sessionId, data])
                if index < writes.count - 1 { try await Task.sleep(for: IntentHoot.submitGap) }
            }
            asked = true
            IntentsEngine.note("asked Hoot (\(question.count) characters)")

            let clock = ContinuousClock()
            let askedAt = clock.now
            let end = askedAt.advanced(by: IntentHoot.backgroundLimit)
            var sawWorking = false
            while clock.now < end {
                let status = await feed.next(within: min(.seconds(20), end - clock.now))
                if let status {
                    if status == "working" { sawWorking = true; continue }
                    if status == "exited" { return .failed(.plain("\(assistant) stopped before it answered.")) }
                    guard IntentHoot.isTurnOver(status), sawWorking || clock.now - askedAt > .seconds(3) else { continue }
                }
                // A turn ended (or it has been quiet a while): read the conversation.
                // A beat first, so the island's own read of this change goes ahead of this one.
                try await Task.sleep(for: .milliseconds(400))
                let current = status ?? feed.latest
                let reply = IntentHoot.reply(to: question, in: try await conversation(folder), known: known)
                let over = current.map(IntentHoot.isTurnOver) ?? true
                if reply.asked, !reply.answer.isEmpty, over {
                    return .answer(IntentHoot.answer(reply, assistant: assistant, askingYou: current == "input"))
                }
                if current == "input" {
                    let line = "\(assistant) needs your OK in Terminal Deck before it can answer."
                    return .answer(IntentAnswer(spoken: line, detail: [line]))
                }
            }
            return .failed(.plain("\(assistant) didn't answer within five minutes. Its reply will be in its conversation in Terminal Deck."))
        } catch let error as IntentError {
            return .failed(.plain(error.sentence))
        } catch is CancellationError {
            return .failed(.plain("The question to \(assistant) was cancelled."))
        } catch {
            return .failed(.plain("\(assistant) couldn't be asked: \(error.localizedDescription)"))
        }
    }

    private func copilotState() async throws -> IntentCopilot {
        guard let state = IntentHoot.copilot(try await IntentsEngine.invoke("copilot:state")) else {
            throw IntentError("\(assistant)'s state couldn't be read.")
        }
        return state
    }

    private func conversation(_ folder: String) async throws -> [IntentChatLine] {
        IntentHoot.lines(try await IntentsEngine.invoke("chat:load", [["cwd": folder]])).lines
    }
}

/// One session's `session:status` pushes, handed out one at a time.
@MainActor
private final class StatusFeed {
    private var subscription: EngineSubscription?
    private(set) var latest: String?
    private var queued: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var waiterToken = 0

    init(sessionId: String) {
        subscription = EngineBridge.shared.on("session:status") { [weak self] args in
            guard let event = IntentHoot.statusEvent(args), event.id == sessionId else { return }
            self?.push(event.status)
        }
    }

    /// The next status, or nil after `limit` with none.
    func next(within limit: Duration) async -> String? {
        if !queued.isEmpty { return queued.removeFirst() }
        guard subscription != nil, limit > .zero else { return nil }
        waiterToken += 1
        let token = waiterToken
        return await withCheckedContinuation { continuation in
            waiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                self?.expire(token)
            }
        }
    }

    func close() {
        subscription?.cancel()
        subscription = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    private func push(_ status: String) {
        latest = status
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: status)
        } else {
            queued.append(status)
            if queued.count > 50 { queued.removeFirst(queued.count - 50) }
        }
    }

    private func expire(_ token: Int) {
        guard token == waiterToken, let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
    }
}

/// A late answer, as a notification from this app.
@MainActor
enum IntentsNotifier {
    static func post(title: String, body: String) async {
        // Outside an app bundle (a bare test binary) there is no notification centre to ask.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                IntentsEngine.note("notifications are turned off for this app; the answer is in Hoot's conversation")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "siri-\(UUID().uuidString)", content: content, trigger: nil))
        } catch {
            IntentsEngine.note("notification failed: \(error.localizedDescription)")
        }
    }
}
