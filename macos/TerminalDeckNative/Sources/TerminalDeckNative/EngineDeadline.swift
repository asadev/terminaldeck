import Foundation
import TerminalDeckNativeCore

/// One engine call with a deadline: the answer, or the page's sentence saying it
/// did not come ("Reading this repository did not answer within 15 seconds.").
@MainActor
enum EngineDeadline {
    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any

    struct Overdue: Error { let message: String }

    private final class Box: @unchecked Sendable {
        let value: Any
        init(_ value: Any) { self.value = value }
    }

    private final class Fired: @unchecked Sendable { var value = false }

    static func invoke(_ channel: String, _ args: [Any?] = [], what: String, seconds: Double, invoke: Invoke? = nil) async throws -> Any {
        let payload = Box(args)
        let work = Task { @MainActor () throws -> Box in
            let args = payload.value as? [Any?] ?? []
            if let invoke { return Box(try await invoke(channel, args)) }
            return Box(try await EngineBridge.shared.invoke(channel, args))
        }
        let fired = Fired()
        let timer = Task { @MainActor in
            try await Task.sleep(for: .seconds(seconds))
            fired.value = true
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await work.value.value
        } catch {
            if fired.value { throw Overdue(message: ArtifactRules.overdue(what, seconds: seconds)) }
            throw error
        }
    }

    /// The sentence for a failure: the deadline's own, or the engine's without Electron's wrapper.
    static func describe(_ error: Error) -> String {
        if let overdue = error as? Overdue { return overdue.message }
        if let wire = error as? EngineWireError { return ArtifactRules.readFailure(wire.description) }
        return ArtifactRules.readFailure(error.localizedDescription)
    }

    /// A server screen's sentence: the deadline's own, or the engine's (`fallback` when it said nothing).
    static func serverText(_ error: Error, fallback: String) -> String {
        (error as? Overdue)?.message ?? CodingAIErrorText.from(error, fallback: fallback)
    }
}
