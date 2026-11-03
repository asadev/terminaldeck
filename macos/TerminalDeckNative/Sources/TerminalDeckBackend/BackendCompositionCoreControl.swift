import Foundation
import TerminalDeckNativeCore

/// Lets policies capture the sole core's gate before that core is constructed.
/// Calls refuse until bound; this owns no budgets, consent or action rows.
final class BackendCompositionCoreControl: @unchecked Sendable {
    private let lock = NSLock()
    private var control: BackendDeckCoreSecurityControl?
    private var closed = false
    func bind(_ actual: BackendDeckCoreSecurityControl) throws {
        try lock.withLock {
            guard !closed, control == nil else { throw unavailable() }
            control = actual
        }
    }
    func unbind(_ actual: BackendDeckCoreSecurityControl) {
        lock.withLock { if control === actual { control = nil } }
    }
    func close() { lock.withLock { closed = true; control = nil } }
    private func actual() throws -> BackendDeckCoreSecurityControl {
        try lock.withLock {
            guard !closed, let control else { throw unavailable() }
            return control
        }
    }
    private func unavailable() -> NativeRPCError {
        .init(code: "composition-incomplete", message: "The sole native deck-control policy gate has not been bound or has stopped.")
    }
    var gate: BackendCompositionCoreGate {
        .init(authorize: { [self] context, tool, arguments, tier, sentence, ownerMustAnswer in
            let control = try actual()
            _ = try await control.prepareEffect(context: context, tool: tool, arguments: arguments,
                tier: tier, sentence: sentence, ownerMustAnswer: ownerMustAnswer)
        }, record: { [self] context, tool, arguments, summary in
            try await actual().recordEffect(context: context, tool: tool, arguments: arguments, summary: summary)
        })
    }
}
