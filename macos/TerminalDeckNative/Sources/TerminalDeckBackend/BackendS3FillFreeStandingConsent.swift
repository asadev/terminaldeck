import AppKit
import Foundation

/// Source plugins/consent.ts in the native shell: when no window is available to hang the question
/// from, the question is asked in a free-standing box and its answer counts. The presenter is
/// injected (a fake in tests, a modal NSAlert in the app). Default and Escape refuse; one question
/// at a time; shutdown refuses.
@MainActor public final class BackendS3FillFreeStandingConsent: BackendPluginsConsent {
    public typealias Presenter = @MainActor @Sendable (BackendPluginsConsentRequest) async -> Bool
    private let present: Presenter
    private var closed = false, asking = false
    public init(present: @escaping Presenter = BackendS3FillFreeStandingConsent.modalAlert) { self.present = present }
    public func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome {
        guard !closed else { return .init(granted: false, reason: "shutting-down") }
        guard !asking else { return .init(granted: false, reason: "no-approver") }
        asking = true; defer { asking = false }
        let granted = await present(question)
        return closed ? .init(granted: false, reason: "shutting-down") : .init(granted: granted, reason: granted ? "allowed" : "declined")
    }
    public func shutdown() async { closed = true }
    public static let modalAlert: Presenter = { question in
        let box = NSAlert(); box.alertStyle = .warning; box.messageText = question.message; box.informativeText = question.detail
        box.addButton(withTitle: "Don’t allow"); box.addButton(withTitle: "Allow")
        box.buttons[0].keyEquivalent = "\r"; box.buttons[1].keyEquivalent = ""
        return box.runModal() == .alertSecondButtonReturn
    }
}
