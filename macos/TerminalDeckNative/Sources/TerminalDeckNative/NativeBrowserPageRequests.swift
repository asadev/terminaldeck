import AppKit
import Observation
import WebKit
import TerminalDeckNativeCore

/// Questions belong to a tab, never to whichever window happens to have the keyboard.
/// A hidden tab advertises a quiet unread dot. Only the person's Review/click releases its question.
@MainActor
@Observable
final class NativeBrowserPageRequests {
    struct Question: Identifiable {
        let id: UUID
        let kind: String
        let message: String
        let site: String
    }
    private(set) var questions: [Question] = []
    private(set) var problem: String?
    private(set) var issueRevision = 0
    private(set) var reviewNotice: String?
    @ObservationIgnored private weak var tab: NativeBrowserTab?
    @ObservationIgnored private var gates: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var active: Set<UUID> = []
    @ObservationIgnored private let ready: (@MainActor () -> Bool)?
    @ObservationIgnored weak var sheetParent: NSWindow?
    @ObservationIgnored weak var pageSheet: NSWindow?
    private var surfaceRevision = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(tab: NativeBrowserTab, ready: (@MainActor () -> Bool)? = nil) {
        self.tab = tab; self.ready = ready
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.surfaceRevision += 1 }
            })
        }
    }
    isolated deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    var needsAttention: Bool { !questions.isEmpty || problem != nil || reviewNotice != nil }
    var line: String? { questions.first.map { "Waiting for the person: " + $0.message } ?? problem ?? reviewNotice }
    var waitingReason: String? {
        if let question = questions.first { return "Waiting for the person: \(question.message) Open this tab and choose Review. Do not repeat the action that opened it." }
        return nil
    }
    var canReview: Bool {
        _ = surfaceRevision
        _ = tab?.pageInWindow
        if let ready { return ready() }
        guard let view = tab?.webView, let window = view.window else { return false }
        return !(window is NativeBrowserCaptureWindow) && window.isKeyWindow && !window.isMiniaturized && NSApp.isActive
    }

    func showing(kind: String, message: String, site: String) -> UUID {
        let id = UUID()
        questions.append(.init(id: id, kind: kind, message: message, site: site))
        active.insert(id)
        return id
    }

    func review() {
        guard canReview else { return }
        // WebAuthn also requires a focused document. This is the person's explicit Review/click,
        // never a tool's attempt to take the keyboard.
        if questions.first?.kind == "webauthn", let view = tab?.webView,
           let window = view.window, !(window is NativeBrowserCaptureWindow) { window.makeFirstResponder(view) }
        problem = nil
        reviewNotice = nil
        guard let first = questions.first, !active.contains(first.id) else { return }
        active.insert(first.id)
        gates.removeValue(forKey: first.id)?.resume(returning: true)
    }

    /// Each caller must finish its ticket after the native sheet has answered.
    func wait(kind: String, message: String, site: String) async -> UUID? {
        let id = UUID()
        questions.append(.init(id: id, kind: kind, message: message, site: site))
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                gates[id] = continuation
                if let view = tab?.webView, NativeBrowserPageDelegate.personUsing(view) { review() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id) }
        }
        guard allowed, questions.contains(where: { $0.id == id }) else { finish(id); return nil }
        return id
    }

    func finish(_ id: UUID) {
        gates.removeValue(forKey: id)?.resume(returning: false)
        active.remove(id)
        questions.removeAll { $0.id == id }
    }
    func unavailable(kind: String, reason: String, site: String = "") {
        problem = reason
        issueRevision += 1
        tab?.automation.noteForTool(.init(kind: kind, message: reason, site: site, answer: "cannot be shown", by: "built-in browser", at: Date()))
    }
    func notice(_ message: String) { reviewNotice = message }
    func reset(preserveNotice: Bool = false) {
        if let window = sheetParent, let sheet = pageSheet, window.attachedSheet === sheet { window.endSheet(sheet, returnCode: .cancel) }
        sheetParent = nil; pageSheet = nil
        let waiting = Array(gates.values)
        gates = [:]; active = []; questions = []; problem = nil
        if !preserveNotice { reviewNotice = nil }
        waiting.forEach { $0.resume(returning: false) }
    }
    func toolNotes() -> [[String: Any]] {
        var result = questions.map { ["kind": $0.kind, "message": $0.message, "site": $0.site, "answer": "waiting for the person"] }
        if let reviewNotice { result.append(["kind": "popup", "message": reviewNotice, "site": "", "answer": "waiting for the person"]) }
        return result
    }

    /// WebKit can leave evaluateJavaScript pending behind a JS dialog. Answer the tool promptly,
    /// keeping WebKit's original request alive for the person. No cancellation or invented dialog answer.
    func perform<T: Sendable>(timeoutMs: Int, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        if let waitingReason { throw BrowserDriverRefusal(waitingReason) }
        let revision = issueRevision
        let result = NativeBrowserRequestResult<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.continuation = continuation
                result.watch = Task { [weak self] in
                    guard let self else { return }
                    let changed = await NativeBrowserSignalWait.until {
                        self.waitingReason != nil || self.issueRevision != revision
                    }
                    if changed { result.finish(.failure(BrowserDriverRefusal(self.waitingReason ?? self.problem ?? "The built-in browser could not show the page's request."))) }
                }
                result.deadline = Task {
                    do { try await Task.sleep(for: .milliseconds(timeoutMs)) } catch { return }
                    result.finish(.failure(BrowserDriverRefusal("The page did not answer within \(timeoutMs) ms.")))
                }
                Task {
                    do { result.finish(.success(try await operation())) }
                    catch { result.finish(.failure(error)) }
                }
                if Task.isCancelled { result.finish(.failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in result.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class NativeBrowserRequestResult<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?
    var watch: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    func finish(_ value: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        watch?.cancel(); deadline?.cancel(); watch = nil; deadline = nil
        continuation.resume(with: value)
    }
}
