import Foundation
import TerminalDeckNativeCore

/// The task popup's client side of `tasks:local-detail` (renderer calls in
/// src/shared/crm): one call never throws, a failure is a sentence, and an
/// optional argument keeps its explicit null slot. The transport is injected,
/// so the app's bridge and the tests use this same code.
public struct BackendCrmDetailClient: Sendable {
    public typealias Transport = @Sendable (_ function: String, _ arguments: [NativeRPCValue]) async throws -> NativeRPCValue?
    private let ready: Bool, transport: Transport
    public init(isReady: Bool, transport: @escaping Transport) { ready = isReady; self.transport = transport }

    /// One `tasks:local-detail` call, answered in the `{ ok, error? }` envelope.
    public func call(_ function: String, _ arguments: [NativeRPCValue]) async -> NativeRPCValue {
        guard ready else { return Self.failure("This build cannot change tasks.") }
        do {
            guard let answer = try await transport(function, arguments), answer.fields != nil, let ok = answer["ok"].bool else { return Self.failure("Terminal Deck did not answer that.") }
            return ok ? answer : Self.failure(answer["error"].string ?? "failed")
        } catch { return Self.failure(error.localizedDescription) }
    }
    public func addChecklist(_ task: String, title: String? = nil) async -> NativeRPCValue { await call("addChecklist", [.string(task), title.map(NativeRPCValue.string) ?? .null]) }
    public func saveRoutine(_ task: String, rule: CrmValue?, version: Double? = nil) async -> NativeRPCValue {
        await call("saveRoutine", [.string(task), rule.map(BackendCrmWire.native) ?? .null, version.map(NativeRPCValue.number) ?? .null])
    }
    public func setReminder(_ task: String, at: String, note: String? = nil) async -> NativeRPCValue { await call("setReminder", [.string(task), .string(at), note.map(NativeRPCValue.string) ?? .null]) }
    private static func failure(_ text: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("error", .string(text))]) }
}
