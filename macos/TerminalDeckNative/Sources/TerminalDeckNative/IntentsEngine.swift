import AppKit
import AppIntents
import TerminalDeckNativeCore

// Siri / Shortcuts (lane R): how an intent reaches Terminal Deck.
//
// A direct line, no MCP: an intent runs inside this app's own process (the
// system launches the app in the background when it is not running), waits —
// within its budget — for the engine this app starts at launch, and then uses
// the same engine channels and page commands the window uses.

/// A plain sentence Siri reads out when an intent cannot do what was asked.
struct IntentError: Error, CustomLocalizedStringResourceConvertible {
    let sentence: String

    init(_ problem: IntentProblem) { sentence = problem.sentence }
    init(_ sentence: String) { self.sentence = sentence }

    var localizedStringResource: LocalizedStringResource { "\(sentence)" }
}

@MainActor
enum IntentsEngine {
    static var model: AppModel { AppModel.shared }

    /// The engine is up and the bridge configured — starting it if nothing has
    /// (an intent can arrive before launch has finished). Throws a plain sentence
    /// when it failed or did not come up within `cap` / the budget.
    static func ready(_ budget: IntentBudget, cap: Duration = IntentDeadline.engineStart) async throws {
        if isUp { return }
        if case .idle = model.engine.phase { model.startEngine() }
        _ = await IntentDeadline.until(budget.remaining(cap: cap)) {
            await MainActor.run { IntentsEngine.isUp || IntentsEngine.hasFailed }
        }
        if isUp { return }
        if case .failed(let failure) = model.engine.phase { throw IntentError(.down(failure.message)) }
        throw IntentError(.starting)
    }

    static var isUp: Bool {
        guard EngineBridge.shared.isReady, case .ready = model.engine.phase else { return false }
        return true
    }

    private static var hasFailed: Bool {
        if case .failed = model.engine.phase { return true }
        return false
    }

    /// An engine channel, with its errors as plain sentences.
    static func invoke(_ channel: String, _ args: [Any?] = []) async throws -> Any {
        do {
            return try await EngineBridge.shared.invoke(channel, args)
        } catch let error as EngineWireError {
            throw IntentError(.from(error))
        } catch {
            throw IntentError("Terminal Deck didn't answer: \(error.localizedDescription)")
        }
    }

    /// The window's sidebar, once the page has drawn it (nil if it has not within `limit`).
    static func sidebar(within limit: Duration) async -> SidebarState? {
        if let sidebar = model.sidebar { return sidebar }
        _ = await IntentDeadline.until(limit) { await MainActor.run { AppModel.shared.sidebar != nil } }
        return model.sidebar
    }

    /// The main page is loaded and takes commands.
    static func pageReady(within limit: Duration) async -> Bool {
        if model.canRun { return true }
        return await IntentDeadline.until(limit) { await MainActor.run { AppModel.shared.canRun } }
    }

    /// Hoot's name as the sidebar shows it (it can be renamed).
    static var assistantName: String {
        let title = model.sidebar?.allItems.first(where: { $0.kind == .hoot })?.title ?? ""
        return title.isEmpty ? "Hoot" : title
    }

    static func projects() async throws -> [IntentProject] {
        let raw = try await invoke("projects:list")
        return IntentProjects.parse(raw, headings: IntentProjects.headings(from: model.sidebar))
    }

    static func tasksAndGoals() async throws -> (tasks: [IntentTaskSummary], goals: [IntentGoalSummary]) {
        let raw = try await invoke("tasks:state")
        guard let parsed = IntentTasks.parse(raw) else { throw IntentError("Terminal Deck's tasks couldn't be read.") }
        return parsed
    }

    /// The agent new sessions start with (Settings → General), if set.
    static func defaultAgent() async -> IntentAgent? {
        guard let settings = try? await invoke("settings:get") as? [String: Any] else { return nil }
        return IntentAgent.fromProvider(settings["general.defaultProvider"] as? String)
    }

    /// Bring the app and its window to the front.
    static func bringForward() {
        NativeFrontGuard.expect("Siri or Shortcuts")
        NSApplication.shared.activate() // front-ok: a Siri or Shortcuts request the person made
        let windows = NSApplication.shared.windows.filter { $0.canBecomeMain }
        (windows.first(where: \.isVisible) ?? windows.first)?.makeKeyAndOrderFront(nil) // front-ok: same Siri or Shortcuts request
    }

    static func note(_ text: String) {
        model.engine.log.note("siri: \(text)")
    }

    static var home: String { NSHomeDirectory() }
}
