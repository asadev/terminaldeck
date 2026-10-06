import Foundation

// Hoot's window (lane R): the pure half of `NativeHootScreen`, ported from
// src/renderer/copilot/CopilotView.tsx, CopilotRestart.tsx, copilot-model.ts
// (`copilotStage`) and session-origin.ts (`partitionByOrigin`, `turnOf`).

/// What Hoot's window is showing, as one word (`CopilotStage`).
public enum HootStage: String, Equatable, Sendable {
    case stopped, starting, checking
    case firstRun = "first-run"
    case unverified, ready
}

public enum HootScreen {
    /// `BRAND.assistant` — the product's word for it in these sentences.
    public static let assistant = "Hoot"

    /// `copilotStage(state, signIn)`: `status` is `copilot:state`'s (nil when none
    /// was read); `signIn` is `copilot:signin`'s `state` (nil until one answered).
    public static func stage(status: String?, signIn: String?) -> HootStage {
        guard let status else { return .stopped }
        if status == "starting" { return .starting }
        if status != "running" { return .stopped }
        guard let signIn else { return .checking }
        if signIn == "signed-out" { return .firstRun }
        if signIn == "unknown" { return .unverified }
        return .ready
    }

    /// `stateLine(copilot)` in CopilotRestart.tsx.
    public static func stateLine(stage: HootStage, loading: Bool, account: String?, recordsHeld: Bool) -> String {
        switch stage {
        case .starting: return "Starting…"
        case .stopped: return loading ? "Checking…" : "Not running"
        case .checking: return "Running · checking sign-in"
        case .firstRun: return "Running · signed out"
        case .unverified: return "Running · sign-in unknown"
        case .ready:
            if let account, !account.isEmpty { return "Running · \(account)" }
            return recordsHeld ? "Running · signed in, its log held" : "Running · signed in"
        }
    }

    /// The Restart button's title text (the web's `title`).
    public static func restartHelp(stateLine: String) -> String {
        "\(stateLine) — restarting ends this conversation and starts a fresh one. Its folder and memory are untouched."
    }

    /// Restart is drawn only over a running Hoot on this computer.
    public static func showsRestart(status: String?, elsewhere: Bool) -> Bool {
        status == "running" && !elsewhere
    }

    // MARK: The record strip

    public struct Notice: Equatable, Sendable {
        public enum Kind: String, Sendable { case firstRun = "first-run", unverified, problem }
        public let kind: Kind
        public let title: String?
        public let paragraphs: [String]
    }

    /// The notices above the terminal, in the web's order; none over another machine's Hoot.
    public static func notices(stage: HootStage, problem: String?, elsewhere: Bool) -> [Notice] {
        guard !elsewhere else { return [] }
        switch stage {
        case .firstRun:
            return [Notice(kind: .firstRun, title: "The account it runs as is signed out", paragraphs: [
                "\(assistant) runs as one of your accounts, the same as any other session — it has no login of its own. This one is not signed in yet. Signing it in here signs it in everywhere that account is used, and you can do it under Settings → Accounts instead.",
                "Its terminal is below. Run /login there: it prints a URL, and you paste the code back here.",
            ])]
        case .unverified:
            return [Notice(kind: .unverified, title: nil, paragraphs: [
                "This window could not check whether \(assistant) is signed in — asking timed out or was refused. It is running, so the conversation below is live; if it answers with a login prompt, open the terminal.",
            ])]
        case .stopped:
            guard let problem, !problem.isEmpty else { return [] }
            return [Notice(kind: .problem, title: nil, paragraphs: [problem])]
        default:
            return []
        }
    }

    /// One row of the action log (`deck-control:activity`), as much as this window draws.
    public struct Turn: Equatable, Sendable, Identifiable {
        public let id: String
        public let at: String
        public let detail: String
    }

    /// `readTurns`: rows without a string id and detail are skipped.
    public static func turns(_ value: Any) -> [Turn] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { entry in
            guard let row = entry as? [String: Any], let id = row["id"] as? String,
                  let detail = row["detail"] as? String else { return nil }
            return Turn(id: id, at: row["at"] as? String ?? "", detail: detail)
        }
    }

    public static let missingTurn = "The turn that started that session is not in the recent action log."

    /// `new Date(at).toLocaleString()`; the text itself when it is not a date.
    public static func when(_ at: String, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = iso.date(from: at) ?? plain.date(from: at) else { return at }
        let out = DateFormatter()
        out.locale = locale
        out.timeZone = timeZone
        out.dateStyle = .short
        out.timeStyle = .medium
        return out.string(from: date)
    }

    // MARK: Sessions it started

    /// A session as `session:list` reports it, the parts this window reads.
    public struct Meta: Equatable, Sendable {
        public let id: String
        public let title: String
        public let origin: String?
        public let runId: String?

        public init(id: String, title: String, origin: String?, runId: String?) {
            self.id = id
            self.title = title
            self.origin = origin
            self.runId = runId
        }
    }

    public static func metas(_ value: Any) -> [Meta] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { entry in
            guard let row = entry as? [String: Any], let id = row["id"] as? String else { return nil }
            let run = row["originRunId"] as? String
            return Meta(id: id, title: row["title"] as? String ?? "", origin: row["origin"] as? String,
                        runId: run?.isEmpty == false ? run : nil)
        }
    }

    public struct Started: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        /// The action-log row of the turn that started it (`turnOf`).
        public let runId: String?
    }

    /// The sidebar's run of rows for the sessions Hoot started.
    public static let startedGroup = "hoot-started"

    /// `partitionByOrigin(tabs).copilot`: in the sidebar's order and with its labels
    /// (the rail's `hoot-started` run), else every session whose origin is the copilot.
    public static func started(metas: [Meta], sidebar: SidebarState?) -> [Started] {
        let byId = Dictionary(metas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let rows = sidebar?.projects.first(where: { $0.id == startedGroup })?.sessions, !rows.isEmpty {
            return rows.filter { $0.kind == .session }.map { row in
                Started(id: row.id, label: row.title.isEmpty ? (byId[row.id]?.title ?? "Session") : row.title,
                        runId: byId[row.id]?.origin == "copilot" ? byId[row.id]?.runId : nil)
            }
        }
        return metas.filter { $0.origin == "copilot" }.map {
            Started(id: $0.id, label: $0.title.isEmpty ? "Session" : $0.title, runId: $0.runId)
        }
    }

    /// `sessionsFromTurn`: the sessions one turn started.
    public static func fromTurn(_ focus: String?, in started: [Started]) -> [Started] {
        guard let focus else { return [] }
        return started.filter { $0.runId == focus }
    }

    // MARK: Not running

    public static func emptyTitle(stage: HootStage) -> String {
        stage == .starting ? "Starting \(assistant)…" : "\(assistant) is not running"
    }

    public static let emptyBody = "It runs in a folder of its own, with its own memory, as one of your accounts. Ask it which of your sessions needs you, to review a diff before it lands, or to turn a rough ask into a prompt worth giving a sub-session."
}
