import Observation
import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// What the island view draws.
@MainActor
@Observable
final class IslandViewModel {
    var layout: IslandLayout
    /// Grown into the panel (set inside an animation).
    var expanded = false
    /// The engine is up and the main page is loaded.
    var engineUp = false
    /// The island's own page has loaded and can be shown.
    var pageLoaded = false
    var nativeState: IslandState?
    var appearance = "dark"
    var builtInScreen = false
    var cameraNotchScreen = false
    var options = FIXESIslandOptions()
    /// What lives in the island (15 Nov, item 47). Synced like every island choice.
    var shows = NativeIslandShows.hoot
    /// Hoot's own "nothing is happening" from the snapshot.
    var quiet = true
    /// Every session of the snapshot (name and state only; the island never shows an id).
    var sessions: [NativeIslandSessionFact] = []
    /// Previews and pictures hand in fixed facts; the app reads the live ones.
    var suppliedFacts: NativeIslandFacts?
    var facts: NativeIslandFacts {
        suppliedFacts ?? .live(hootLine: nativeState?.line ?? "Hoot", hootQuiet: quiet,
            hootWorking: nativeState?.status == .working, sessions: sessions)
    }
    /// The capsule's glyph, line and one mark for the chosen "Shows".
    var face: NativeIslandFace { NativeIslandFace.make(shows: shows, facts: facts, engineUp: state != nil || suppliedFacts != nil) }
    var quietNow: Bool { shows == .hoot ? quiet : face.quiet }
    var hiddenWhileQuiet: Bool { quietNow && !expanded && options.whenQuiet == .hide }
    var usesBlack: Bool { darkAppearance }
    var darkAppearance: Bool { FIXESIslandDisplayPolicy.dark(appearance: appearance, builtIn: builtInScreen, hasNotch: cameraNotchScreen || layout.notched, look: options.look) }

    init(layout: IslandLayout) {
        self.layout = layout
    }

    /// Only real state: nothing while the engine is down or before the page has spoken.
    var state: IslandState? { engineUp ? nativeState : nil }

    /// The production snapshot projector also accepts injected screen numbers
    /// for hermetic previews. It performs no IO and constructs no app owner.
    func acceptNativeSnapshot(_ value: NativeRPCValue, screen: IslandScreen, builtIn: Bool, options: FIXESIslandOptions) {
        engineUp = true; pageLoaded = true; appearance = value["appearance"].string ?? "dark"
        self.options = options; quiet = value["quiet"].bool ?? true; builtInScreen = builtIn
        sessions = (value["sessions"].elements ?? []).compactMap { row in
            row["status"].string.map { NativeIslandSessionFact(id: row["id"].string ?? "", name: row["label"].string ?? "", status: $0) }
        }
        var statuses = (value["sessions"].elements ?? []).compactMap { $0["status"].string }
        if value["hoot"]["busy"].bool == true { statuses.append("working") }
        nativeState = IslandState.native(sessionStatuses: statuses,
            line: value["label"]["text"].string ?? "Hoot", hootStatus: value["hoot"]["status"].string)
        var next = FIXESIslandDisplayPolicy.layout(for: screen, options: options, quiet: quiet)
        cameraNotchScreen = screen.safeAreaTop > 0 || next.notched
        let displayWidth = CGFloat(value["geometry"]["displayWidth"].number ?? Double(screen.frame.width))
        let barHeight = CGFloat(value["geometry"]["barHeight"].number ?? Double(next.row))
        let size = BackendHootIslandBounds.clamp(displayWidth: displayWidth, barHeight: barHeight,
            size: CGSize(width: value["size"]["width"].number.map { CGFloat($0) } ?? options.width.grown,
                height: value["size"]["height"].number.map { CGFloat($0) } ?? 420)) // room for Hoot's chat by default (Asad, 10 Oct)
        next.panel.width = size.width; next.panel.height = size.height
        next.contentSize = CGSize(width: max(1, size.width - 2 * IslandMetrics.contentInset),
            height: max(1, size.height - next.contentTop - IslandMetrics.contentInset))
        let canvas = BackendHootIslandBounds.window(displayWidth: displayWidth, barHeight: barHeight)
        next.expandedFrame = CGRect(x: next.centreX - canvas.width / 2, y: screen.frame.maxY - canvas.height,
            width: canvas.width, height: canvas.height)
        layout = next
    }
}

// MARK: - What the island shows (15 Nov, item 47)

/// "Shows": what lives in the island. Default Hoot, as before.
enum NativeIslandShows: String, CaseIterable, Sendable {
    case hoot, sessions, tasks, needsMe = "needs-me"
    var title: String {
        switch self {
        case .hoot: "Hoot"
        case .sessions: "Running sessions"
        case .tasks: "Tasks"
        case .needsMe: "Only what needs me"
        }
    }
    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .hoot }
}

struct NativeIslandSessionFact: Equatable, Sendable {
    var id: String
    var name: String
    var status: String
    /// Open in the app: not finished and not closed.
    var running: Bool { status != "exited" && status != "completed" }
    var needsYou: Bool { status == "input" }
}

struct NativeIslandTaskFact: Equatable, Sendable {
    var id: String
    var title: String
    var updatedAt: Double
    var due: String?
}

/// One thing waiting for him: an approval or a session asking. `sessionID` opens that session.
struct NativeIslandWaitingFact: Equatable, Sendable {
    var id: String
    var asker: String
    var sessionID: String?
}

/// Everything the capsule may show, from data the app already has: the island's snapshot (Hoot's line, the sessions),
/// the tasks store (open tasks) and the permission desk (approvals and questions waiting).
struct NativeIslandFacts: Equatable, Sendable {
    var hootLine = "Hoot"
    var hootQuiet = true
    var hootWorking = false
    var sessions: [NativeIslandSessionFact] = []
    /// Open tasks, newest first.
    var tasks: [NativeIslandTaskFact] = []
    var waiting: [NativeIslandWaitingFact] = []

    var running: [NativeIslandSessionFact] { sessions.filter(\.running) }

    /// Open = not done, archived or deleted; newest change first.
    static func openTasks(_ rows: [TaskRow]) -> [NativeIslandTaskFact] {
        rows.filter { $0.completedAt == nil && $0.archivedAt == nil && $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { NativeIslandTaskFact(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, due: $0.dueDate) }
    }

    /// Approvals on the desk first, then sessions asking that have no card there.
    static func waiting(desk: [NativePermissionDesk.Item], sessions: [NativeIslandSessionFact]) -> [NativeIslandWaitingFact] {
        var rows = desk.map { item -> NativeIslandWaitingFact in
            if case .session(let id) = item.source { return .init(id: item.id, asker: item.asker, sessionID: id) }
            return .init(id: item.id, asker: item.asker, sessionID: nil)
        }
        let carded = Set(rows.compactMap(\.sessionID))
        rows += sessions.filter { $0.needsYou && !carded.contains($0.id) }
            .map { .init(id: "session:" + $0.id, asker: $0.name, sessionID: $0.id) }
        return rows
    }

    @MainActor static func live(hootLine: String, hootQuiet: Bool, hootWorking: Bool, sessions: [NativeIslandSessionFact]) -> NativeIslandFacts {
        NativeIslandFacts(hootLine: hootLine, hootQuiet: hootQuiet, hootWorking: hootWorking, sessions: sessions,
            tasks: openTasks(TasksStore.shared.state?.tasks ?? []),
            waiting: waiting(desk: NativePermissionDesk.shared.visible, sessions: sessions))
    }
}

/// What the capsule draws: one glyph, one line, at most one trailing mark.
struct NativeIslandFace: Equatable, Sendable {
    enum Glyph: Equatable, Sendable { case hoot, symbol(String) }
    enum Mark: Equatable, Sendable {
        case none
        /// A count; orange when something in it needs him.
        case count(Int, attention: Bool)
        /// Hoot is thinking (the three moving dots).
        case working
    }
    var glyph: Glyph
    var line: String
    var mark: Mark
    /// Nothing is happening for this choice ("When nothing is happening" applies).
    var quiet: Bool

    static func make(shows: NativeIslandShows, facts: NativeIslandFacts, engineUp: Bool = true) -> NativeIslandFace {
        switch shows {
        case .hoot:
            let asking = facts.sessions.filter(\.needsYou).count
            let mark: Mark = asking > 0 ? .count(asking, attention: true) : facts.hootWorking ? .working : .none
            return .init(glyph: .hoot, line: facts.hootQuiet ? "All quiet" : shown(facts.hootLine, or: "Hoot"),
                mark: engineUp ? mark : .none, quiet: facts.hootQuiet)
        case .sessions:
            let running = facts.running
            return .init(glyph: .symbol("terminal"), line: running.last.map { shown($0.name, or: "Session") } ?? "No sessions running",
                mark: running.isEmpty ? .none : .count(running.count, attention: running.contains(where: \.needsYou)),
                quiet: running.isEmpty)
        case .tasks:
            return .init(glyph: .symbol("checklist"), line: facts.tasks.first.map { shown($0.title, or: "Task") } ?? "No open tasks",
                mark: facts.tasks.isEmpty ? .none : .count(facts.tasks.count, attention: false), quiet: facts.tasks.isEmpty)
        case .needsMe:
            return .init(glyph: .symbol("bell"), line: facts.waiting.first.map { shown($0.asker, or: "Someone") + " needs you" } ?? "Nothing needs you",
                mark: facts.waiting.isEmpty ? .none : .count(facts.waiting.count, attention: true), quiet: facts.waiting.isEmpty)
        }
    }

    /// One line, never an internal line, a path or an id: newlines flattened, a path cut to its last part.
    static func shown(_ raw: String, or fallback: String) -> String {
        var text = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            text = text.split(separator: "/").last.map(String.init) ?? ""
        }
        if text.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil { text = "" }
        return text.isEmpty ? fallback : String(text.prefix(80))
    }

    var countText: String? {
        if case .count(let n, _) = mark { return n > 99 ? "99+" : "\(n)" }
        return nil
    }
}
