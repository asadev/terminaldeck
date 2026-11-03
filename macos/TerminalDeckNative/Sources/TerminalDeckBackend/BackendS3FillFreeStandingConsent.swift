import Foundation

/// Injected compatibility channel. Production asks through the shared consent
/// broker; there is no platform dialog fallback here. Shutdown refuses.
@MainActor public final class BackendS3FillFreeStandingConsent: BackendPluginsConsent {
    public typealias Presenter = @MainActor @Sendable (BackendPluginsConsentRequest) async -> Bool
    private let present: Presenter
    private var closed = false, asking = false
    public init(present: @escaping Presenter) { self.present = present }
    public func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome {
        guard !closed else { return .init(granted: false, reason: "shutting-down") }
        guard !asking else { return .init(granted: false, reason: "no-approver") }
        asking = true; defer { asking = false }
        let granted = await present(question)
        return closed ? .init(granted: false, reason: "shutting-down") : .init(granted: granted, reason: granted ? "allowed" : "declined")
    }
    public func shutdown() async { closed = true }
}
