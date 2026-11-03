import Foundation
import TerminalDeckNativeCore

/// Plugin questions use the same authenticated window/phone/tool answers as
/// other confirmations. No free-standing modal dialog or nested run loop.
public actor BackendPluginsBrokerConsent: BackendPluginsConsent {
    private let broker: BackendDeckCoreSecurityConsentBroker
    private let cancellation = BackendMCPCancellation()
    private var closed = false, asking = false
    public init(broker: BackendDeckCoreSecurityConsentBroker) { self.broker = broker }
    public func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome {
        guard !closed else { return .init(granted: false, reason: "shutting-down") }
        guard !asking else { return .init(granted: false, reason: "no-approver") }
        asking = true; defer { asking = false }
        let args = NativeRPCValue.object([
            .init("plugin", .string(question.id)), .init("version", .string(question.version)),
            .init("hash", .string(question.hash)), .init("detail", .string(question.detail)),
            .init("capabilities", .array(question.capabilities.map(NativeRPCValue.string))),
            .init("projects", .array(question.projects.map(NativeRPCValue.string))),
            .init("tools", .array(question.tools.map(NativeRPCValue.string)))])
        let outcome = await broker.request(tool: "plugins.allow", tier: .act, summary: question.message,
            arguments: args, cancellation: cancellation, origin: "plugin-consent", label: question.name)
        return .init(granted: outcome.granted && !closed,
            reason: closed ? "shutting-down" : outcome.reason?.rawValue ?? "allowed", at: outcome.at)
    }
    public func shutdown() async { closed = true; cancellation.cancel() }
}
