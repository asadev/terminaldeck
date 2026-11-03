import Foundation
import TerminalDeckNativeCore

// ACCOUNTS-SPEC §4a (Asad, 11 Oct): "we need easy sign in setup for ai accounts". The app runs
// the AI's own sign-in command itself (no terminal): that command opens the AI's sign-in page in
// the browser and finishes when the person approves. If the AI asks for a code, the person pastes
// it into one field and it is passed straight to the command. The login goes where that account's
// logins always go (the app's own store for an app-kept account). Nothing the command prints, and
// no code, is ever logged or kept after the sign-in ends.

/// One sign-in in progress.
final class BackendAccountSignInFlow: @unchecked Sendable {
    enum State: String { case waiting, needsCode = "needs-code", done, failed, cancelled }
    let id = UUID().uuidString.lowercased()
    private var accountID: String
    var profileID: String { lock.withLock { accountID } }
    let provider: String
    let startedAt = Date()
    private let lock = NSLock()
    private var state = State.waiting
    private var detail = ""
    private var seen = ""
    private var signInURL: String?
    private var settled = false
    private var successVerified = false
    /// 18 Oct (#513): counts every change a sign-in sheet shows; a sheet waits for the next one instead of asking every second.
    private var revision = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The AI's sign-in command, through the standard child runner: its own group, so a stop also ends
    /// the browser helper or server it started. Set once by `start`.
    private var child: NativeChild?

    init(profileID: String, provider: String) { self.accountID = profileID; self.provider = provider }
    func attach(profileID: String) { lock.withLock { accountID = profileID } }
    func reject(_ message: String) {
        lock.lock(); state = .failed; detail = message; seen = ""; let woken = changedLocked(); lock.unlock(); wake(woken)
    }
    func confirmSuccess() {
        lock.lock(); let now = state == .done && !successVerified; if now { successVerified = true }; let woken = now ? changedLocked() : []; lock.unlock(); wake(woken)
    }

    /// Answers when something the sheet shows has changed since `seen`, or after `seconds` with nothing new.
    func waitForChange(after seen: Int, seconds: Double) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard revision == seen, !Task.isCancelled else { lock.unlock(); waiter.resume(); return }
                waiters[id] = waiter
                lock.unlock()
                Task { try? await Task.sleep(for: .seconds(seconds)); self.wake(id) }
            }
        } onCancel: { self.wake(id) }
    }
    private func wake(_ id: UUID) { lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock(); waiter?.resume() }
    private func wake(_ woken: [CheckedContinuation<Void, Never>]) { for waiter in woken { waiter.resume() } }
    /// With the lock held, after a change: the waiting sheets, answered once the lock is let go.
    private func changedLocked() -> [CheckedContinuation<Void, Never>] {
        revision += 1
        defer { waiters = [:] }
        return Array(waiters.values)
    }

    func start(runnable: String, arguments: [String], environment: [String: String], cwd: String) throws {
        // Its input stays open for a pasted code (the runner makes a write after the end EPIPE, never SIGPIPE);
        // both streams are read as one text. Its end is reported after the last byte it printed.
        let started = try NativeChild.start(.init(URL(fileURLWithPath: runnable).path, arguments, environment: environment,
                                                  cwd: URL(fileURLWithPath: cwd).path, input: .pipe, output: .pipe, errors: .merged),
                                            output: { [weak self] data in self?.read(String(decoding: data, as: UTF8.self)) },
                                            exit: { [weak self] end in self?.finish(code: end.code) })
        lock.withLock { child = started }
    }
    private var running: NativeChild? { lock.withLock { child }.flatMap { $0.isRunning ? $0 : nil } }

    /// Only what the next step needs is kept: whether the AI is asking for a code.
    private func read(_ text: String) {
        lock.lock()
        let before = (state, signInURL)
        seen = String((seen + text).suffix(4_000))
        let lower = seen.lowercased()
        if signInURL == nil, let range = seen.range(of: #"https://[^\s\x1B<>\"']+"#, options: .regularExpression) {
            let candidate = String(seen[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
            if let url = URL(string: candidate), let host = url.host?.lowercased(),
               ["claude.ai", "console.anthropic.com", "auth.openai.com", "chatgpt.com"].contains(host) { signInURL = candidate }
        }
        if state == .waiting, lower.contains("paste") && lower.contains("code") { state = .needsCode }
        let woken = (state, signInURL) != before ? changedLocked() : []
        lock.unlock(); wake(woken)
    }

    private func finish(code: Int32) {
        lock.lock()
        guard state == .waiting || state == .needsCode else { lock.unlock(); return }
        if code == 0 { state = .done; detail = "" }
        else {
            state = .failed
            let lower = seen.lowercased()
            detail = lower.contains("invalid") && lower.contains("code") ? "That code was not accepted. Try again and copy the whole code."
                : lower.contains("timed out") || lower.contains("timeout") ? "The sign-in page was not finished in time. Try again."
                : "The sign-in did not finish. Try again."
        }
        seen = ""
        let woken = changedLocked()
        lock.unlock(); wake(woken)
    }

    static let ended = "The sign-in already ended. Press Try Again to sign in."
    /// False when it is not a code. Throws when the AI's sign-in command has ended, also in the moment between the
    /// check and the write: the write then fails with an error instead of raising an exception that ends the helper.
    func submit(code: String) throws -> Bool {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 2_000, !clean.contains("\n") else { return false }
        guard let child = running else { throw BackendAppSessionError(Self.ended) }
        lock.lock(); let asked = state == .needsCode; if asked { state = .waiting; seen = "" }; let woken = asked ? changedLocked() : []; lock.unlock(); wake(woken)
        do { try child.write(Data((clean + "\n").utf8)) } catch { throw BackendAppSessionError(Self.ended) }
        return true
    }

    /// Asks the command to stop, and ends it (and whatever it started) a second later if it has not.
    func cancel() {
        lock.lock(); let running = state == .waiting || state == .needsCode || (state == .done && !successVerified); if running { state = .cancelled; seen = "" }
        let woken = running ? changedLocked() : []; lock.unlock(); wake(woken)
        self.running?.terminate(grace: .seconds(1))
    }

    /// Nobody finished the sign-in page: stop waiting, so the AI's sign-in command never lingers.
    func expire() {
        lock.lock()
        let running = state == .waiting || state == .needsCode
        if running { state = .failed; detail = "The sign-in page was not finished in time. Try again."; seen = "" }
        let woken = running ? changedLocked() : []
        lock.unlock(); wake(woken)
        if running { self.running?.terminate(grace: .seconds(1)) }
    }

    /// True the first time it is asked after the sign-in succeeded (so the caller refreshes once).
    func takeSettled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .done, !settled else { return false }
        settled = true; return true
    }

    var finished: Bool { lock.lock(); defer { lock.unlock() }; return (state == .done && successVerified) || state == .failed || state == .cancelled }
    var isRunning: Bool { running != nil }

    var wire: NativeRPCValue {
        lock.lock(); defer { lock.unlock() }
        let visibleState: State = state == .done && !successVerified ? .waiting : state
        let words: String
        switch visibleState {
        case .waiting: words = state == .done ? "Checking the account’s login…" : "Waiting for you to approve in the browser…"
        case .needsCode: words = "The sign-in page shows a code. Copy it and paste it here."
        case .done: words = "Signed in."
        case .failed: words = detail
        case .cancelled: words = "Sign-in cancelled."
        }
        return .object([.init("flow", .string(id)), .init("profileId", .string(accountID)), .init("provider", .string(provider)),
                        .init("state", .string(visibleState.rawValue)), .init("message", .string(words)),
                        .init("url", signInURL.map(NativeRPCValue.string) ?? .null), .init("revision", .number(Double(revision)))])
    }
}

/// The sign-ins in progress (a handful at most; finished ones are forgotten after ten minutes).
public actor BackendAccountSignInFlows {
    private var flows: [String: BackendAccountSignInFlow] = [:]
    static let limit = 600
    public init() {}

    func begin(profile: BackendAccountProfile, provider: String, runnable: String, arguments: [String],
               environment: [String: String], cwd: String) throws -> BackendAccountSignInFlow {
        let now = Date()
        flows = flows.filter { !$0.value.finished || $0.value.isRunning || now.timeIntervalSince($0.value.startedAt) < 600 }
        // One sign-in per account at a time: starting again replaces the unfinished one.
        for flow in flows.values where flow.profileID == profile.id && !flow.finished { flow.cancel() }
        let flow = BackendAccountSignInFlow(profileID: profile.id, provider: provider)
        try flow.start(runnable: runnable, arguments: arguments, environment: environment, cwd: cwd)
        flows[flow.id] = flow
        // Ten minutes is long enough for any sign-in page; after that the command is stopped.
        Task { try? await Task.sleep(for: .seconds(Self.limit)); flow.expire() }
        return flow
    }
    func flow(_ id: String) -> BackendAccountSignInFlow? { flows[id] }
    public func cancelAll() { for flow in flows.values { flow.cancel() } }
}
