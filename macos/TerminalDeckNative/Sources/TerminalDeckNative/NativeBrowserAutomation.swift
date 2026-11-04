import AppKit
import WebKit
import TerminalDeckNativeCore

/// Browser 27: what agents (and the person's own answers) set on one tab —
/// how the page's alert/confirm/prompt are answered, files waiting for the page's
/// file chooser, camera and microphone answers, network routes, extra headers,
/// offline, console capture and emulation. One per tab; nothing here is saved.
@MainActor
final class NativeBrowserAutomation {
    // MARK: Page dialogs

    /// "ask": the person answers on the tab (the default). "accept"/"dismiss":
    /// answered for them, and every one is written down for the agent to read.
    enum DialogPolicy: String { case ask, accept, dismiss }
    var dialogPolicy: DialogPolicy = .ask
    var promptText: String?
    /// Answer only the next dialog this way, then go back to asking.
    var dialogOnce = false

    struct DialogRecord {
        let kind: String
        let message: String
        let site: String
        let answer: String
        let by: String
        let at: Date
    }
    private(set) var dialogs: [DialogRecord] = []

    func note(_ record: DialogRecord) {
        dialogs.append(record)
        if dialogs.count > 50 { dialogs.removeFirst(dialogs.count - 50) }
    }

    /// The agent's standing answer for this dialog, or nil to ask the person.
    func autoAnswer() -> DialogPolicy? {
        guard dialogPolicy != .ask else { return nil }
        let answer = dialogPolicy
        if dialogOnce { dialogPolicy = .ask; dialogOnce = false }
        return answer
    }

    // MARK: Files for the page's file chooser

    /// Files an agent's upload step is handing over; the next file chooser the
    /// page opens (within a few seconds) gets them instead of showing a panel.
    private var pendingUpload: (urls: [URL], until: Date, origin: String, authority: @MainActor () -> Bool)?
    private(set) var uploadArmed = false
    private var uploadWaiter: (id: UUID, continuation: CheckedContinuation<[URL]?, Never>)?
    private var answeredUpload: [URL]?

    func armUpload(_ urls: [URL], origin: String, seconds: Double = 5, authority: @escaping @MainActor () -> Bool) {
        pendingUpload = (urls, Date().addingTimeInterval(seconds), origin, authority)
        uploadArmed = true
        answeredUpload = nil
    }

    func disarmUpload() {
        pendingUpload = nil
        uploadArmed = false
        answeredUpload = nil
        finishUploadWait(nil, id: nil)
    }

    /// Called by the page's file-chooser request. Nil when nothing is waiting.
    func takeUpload(multiple: Bool, mainFrame: Bool, origin: String?) -> [URL]? {
        guard let pending = pendingUpload else { return nil }
        pendingUpload = nil
        guard pending.until > Date(), mainFrame, origin == pending.origin, pending.authority() else {
            disarmUpload()
            return nil
        }
        let urls = multiple ? pending.urls : Array(pending.urls.prefix(1))
        answeredUpload = urls
        finishUploadWait(urls, id: nil)
        return urls
    }

    /// Wait for the page to ask for the armed files: what it got, or nil if it never asked.
    func waitForUpload(timeout: Duration) async -> [URL]? {
        if let answeredUpload { return answeredUpload }
        guard uploadArmed else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            uploadWaiter = (id, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishUploadWait(nil, id: id)
            }
        }
    }

    private func finishUploadWait(_ urls: [URL]?, id: UUID?) {
        guard let waiter = uploadWaiter, id == nil || waiter.id == id else { return }
        uploadWaiter = nil
        waiter.continuation.resume(returning: urls)
    }

    // MARK: Camera and microphone

    enum MediaPolicy: String { case ask, allow, deny }
    var camera: MediaPolicy = .ask
    var microphone: MediaPolicy = .ask
    /// What the person answered on this tab, per site, until the tab closes.
    var personAnswers: [String: Bool] = [:]

    // MARK: Network, console, emulation

    var networkHookInstalled = false
    var networkConfig: [String: Any] = ["bodies": false, "routes": [], "headers": [:], "offline": false]
    var blockPatterns: [String] = []
    var blockList: WKContentRuleList?
    var offlineList: WKContentRuleList?
    /// Sent with navigations the tools start, and with the page's own same-origin fetch/XHR.
    var extraHeaders: [String: String] = [:]
    var consoleArmed = false
    var emulation: [String: Any] = [:]
    var emulationInstalled = false
    var viewport: CGSize?
    /// The off-screen window the page lives in while an agent drives it and nobody
    /// shows it; closed the moment the person's browser shows the tab.
    var parkingWindow: NSWindow?
}

/// Cancellation can arrive off the main actor while WebKit asks for its chooser.
final class NativeBrowserUploadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
