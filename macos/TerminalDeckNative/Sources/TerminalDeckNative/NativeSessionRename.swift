import Foundation
import Observation
import TerminalDeckNativeCore

/// Renaming a session from this window (the side panel's "Rename…", the session bar's title, a pane's title):
/// straight to the engine (`session:rename`), never through the hidden page.
///
/// Asad, 12 Oct (install 18): "I can't rename sessions like before. If I edit and apply, it does not work."
/// Both renames went through the page (`rename-session`), which drops a command without a word, and the side
/// panel's alert read its row after SwiftUI had already cleared it. Now:
/// - the new name shows at once: AppModel lays `names` over the page's rail and strip, which the rows, the
///   session bar, pop-out windows and panes all read;
/// - the engine renames the session (in the session helper when it runs there; the helper running since
///   11 Oct takes the same `rename` request), keeps the name in its saved launch so a restart or restore
///   brings it back, and tells everyone: `session:renamed` (the page, the island, Deck Memory) and the
///   paired phones' session lists;
/// - as before (`userSessionTitle`): a blank field is a cancel, the name is cleaned and cut to 40 characters;
/// - a name that cannot be saved says so in one plain line; it never just vanishes.
@MainActor
@Observable
final class NativeSessionNames {
    static let shared = NativeSessionNames()

    /// Local session id → the name it carries now: given here, or announced by the engine.
    private(set) var names: [String: String] = [:]
    /// The one line the side panel shows when a name it was given could not be saved.
    var problem: String?

    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private let changed: @MainActor () -> Void
    @ObservationIgnored private let pause: @MainActor (Double) async -> Void
    @ObservationIgnored private var listening: [EngineSubscription] = []
    /// The latest rename asked for each session: an older one still being saved stops when a newer one comes.
    @ObservationIgnored private var asked: [String: UUID] = [:]
    /// Seconds before each try: a helper that is starting again (after a crash) gets time to come back.
    static let tries: [Double] = [0, 1, 3, 10, 30]

    init(invoke: @escaping Invoke = { try await EngineBridge.shared.invoke($0, $1) },
         changed: @escaping @MainActor () -> Void = { AppModel.shared.sessionNamesChanged() },
         pause: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.invoke = invoke
        self.changed = changed
        self.pause = pause
    }

    /// Follow names given anywhere else (a phone, a tool, another window) and forget closed sessions. Once.
    func start() {
        guard listening.isEmpty else { return }
        let bridge = EngineBridge.shared
        listening.append(bridge.on("session:renamed") { [weak self] args in
            guard let id = args.first as? String, !id.isEmpty else { return }
            self?.heard(id, title: args.count > 1 ? args[1] as? String : nil)
        })
        listening.append(bridge.on("session:removed") { [weak self] args in
            guard let id = args.first as? String, !id.isEmpty else { return }
            self?.set(id, nil)
        })
    }

    /// The engine's `session:renamed`: that is the session's name now (a blank leaves the page's own).
    func heard(_ id: String, title: String?) {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        NativeSessionRailContinuity.shared.renamed(id, title: name)
        set(id, name.isEmpty ? nil : name)
    }

    /// What a person typed as the new name of the session drawn under `tabId`.
    /// - report: where a failure is said (the session's own line); nil: the side panel's alert.
    @discardableResult
    func rename(tabId: String, typed: String, report: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        let say: @MainActor (String) -> Void = report ?? { [weak self] line in self?.problem = line }
        let target = SessionTarget(tabId: tabId)
        switch target {
        case .local(let id):
            guard let name = SessionTitleRules.typed(typed) else { return nil } // a blank field is a cancel, as before
            NativeSessionRailContinuity.shared.renamed(id, title: name)
            let before = names[id], ticket = UUID()
            asked[id] = ticket
            set(id, name)
            return Task { await self.save(id, name, ticket: ticket, before: before, say: say) }
        case .machine(let machineId, let sessionId):
            // The far machine cleans the name, renames it and announces it back to every window; a blank there is
            // "the folder's name again", as the web rail sent it.
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return Task {
                do { _ = try await invoke("machines:session:rename", [machineId, sessionId, name]) }
                catch { say("The other Mac did not take the new name. Check that it is still connected, then try again.") }
            }
        case .server, nil:
            say("A terminal on a server shows the server’s name; it cannot be renamed.")
            return nil
        }
    }

    /// `session:rename` until the engine takes it. A session that has closed is said at once; a helper that does
    /// not answer is asked again, and the name keeps showing meanwhile.
    private func save(_ id: String, _ name: String, ticket: UUID, before: String?, say: @MainActor (String) -> Void) async {
        defer { if asked[id] == ticket { asked[id] = nil } }
        for wait in Self.tries {
            if wait > 0 { await pause(wait) }
            guard asked[id] == ticket else { return } // renamed again meanwhile: the newer name wins
            do {
                if Self.yes(try await invoke("session:rename", [id, name])) { return }
                // No: the session is gone, or its helper refused. Gone is final; a refusal is asked again.
                if !(try await exists(id)) {
                    if asked[id] == ticket { set(id, before) }
                    say("That session has closed, so it cannot be renamed.")
                    return
                }
            } catch {
                continue
            }
        }
        guard asked[id] == ticket else { return }
        say("The new name could not be saved. It shows on this Mac for now, but may be lost when the app restarts.")
    }

    private func exists(_ id: String) async throws -> Bool {
        let rows = try await invoke("session:list", []) as? [[String: Any]] ?? []
        return rows.contains { $0["id"] as? String == id }
    }

    private static func yes(_ answer: Any) -> Bool {
        if let flag = answer as? Bool { return flag }
        return (answer as? NSNumber)?.boolValue == true
    }

    private func set(_ id: String, _ name: String?) {
        guard names[id] != name else { return }
        names[id] = name
        changed()
    }
}
