import Foundation
import Observation
import TerminalDeckNativeCore

/// One change at a time for an Apps page split into parts (the server page,
/// an app's server sections, an app's options): the change in flight, the part
/// its result belongs to, and that result. Shared so a fix lands on every page.
@MainActor
@Observable
final class NativeAppsChangeRunner<Part: Equatable> {
    /// The change in flight ("Saving alerts"), or nil.
    private(set) var busy: String?
    /// Which part the latest note or problem belongs to.
    private(set) var resultPart: Part?
    private(set) var note: String?
    private(set) var problem: String?

    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private let describe: @MainActor (Error) -> String

    init(problem describe: @escaping @MainActor (Error) -> String = NativeAppsSRV2Engine.problem) {
        self.describe = describe
    }

    /// A new read started: replies to requests sent before it are not shown.
    func advance() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ mark: Int) -> Bool { generation == mark }

    func report(_ part: Part, _ message: String) { resultPart = part; note = nil; problem = message }

    /// Clears what `part` shows, as after a revert.
    func clear(_ part: Part) {
        if resultPart == part { note = nil; problem = nil }
    }

    /// App creation has several stages and its own recovery messages, but uses
    /// the same single-operation gate as the section saves.
    @discardableResult
    func begin(_ part: Part, _ label: String, writesDisabled: Bool = false) -> Bool {
        guard busy == nil, !writesDisabled else { return false }
        busy = label
        resultPart = part; note = nil; problem = nil
        return true
    }

    func relabel(_ label: String) { if busy != nil { busy = label } }
    func finish() { busy = nil }

    /// The engine asks for approval; the note `operation` returns (nil shows
    /// none) or its problem is then shown in `part`, unless a newer read began.
    func run(_ part: Part, _ label: String, writesDisabled: Bool = false,
             _ operation: @escaping @MainActor () async throws -> String?, after: (@MainActor () -> Void)? = nil) {
        guard begin(part, label, writesDisabled: writesDisabled) else { return }
        let mine = generation
        Task {
            do {
                let text = try await operation()
                finish()
                guard generation == mine else { return }
                note = text
                after?()
            } catch {
                finish()
                guard generation == mine else { return }
                problem = describe(error)
            }
        }
    }
}
