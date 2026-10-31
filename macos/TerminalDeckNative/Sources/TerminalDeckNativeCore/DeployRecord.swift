import Foundation

// DEPLOY-PIPELINE (Asad, 12 Oct): "a small pipeline box … where we see live and history of deployments of the
// projects … which stage we are currently and … the name of the tools and steps we are using like github coolify".
// One record for every deployment of a project: its steps in order (tests included, with their numbers), the tool
// each step used, who ran it and where the person asked for it. The app keeps it in its data folder, history kept.

/// The state of a step, and of a whole run (a run is running, done, failed, or skipped = cancelled).
public enum DeployState: String, Codable, Sendable, CaseIterable {
    case waiting, running, done, failed, skipped

    public var finished: Bool { self == .done || self == .failed || self == .skipped }

    /// Loose words an AI or a source may use.
    public static func parse(_ text: String?) -> DeployState? {
        guard let word = text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else { return nil }
        switch word {
        case "waiting", "queued", "pending", "planned", "requested", "todo", "to do", "next": return .waiting
        case "running", "in_progress", "in progress", "started", "start", "building", "working", "active": return .running
        case "done", "ok", "success", "succeeded", "passed", "pass", "complete", "completed", "finished", "green": return .done
        case "failed", "fail", "failure", "error", "timed_out", "timeout", "red", "broken": return .failed
        case "skipped", "skip", "neutral", "cancelled", "canceled", "stopped": return .skipped
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeployState(rawValue: raw) ?? .waiting
    }
}

/// The icon for a tool, by its name as it was really used ("GitHub Actions", "Vercel", "codesign"). Nothing here is a
/// list of steps or tools a run must have (Asad, 12 Oct: "dynamic according to the steps the user uses"): a run shows
/// exactly what was reported or detected; an unknown tool shows its own name beside a neutral icon.
public enum DeployToolIcon {
    public static let neutral = "gearshape"
    /// Lower-case words in a tool's name → a monoline SF Symbol. First match wins.
    static let known: [(String, String)] = [
        ("github actions", "gearshape.2"), ("actions", "gearshape.2"), ("workflow", "gearshape.2"),
        ("github", "chevron.left.forwardslash.chevron.right"), ("gitlab", "chevron.left.forwardslash.chevron.right"),
        ("git", "arrow.triangle.branch"),
        ("testflight", "airplane"), ("app store", "app.badge"), ("google play", "play"), ("play console", "play"),
        ("notar", "checkmark.seal"), ("codesign", "signature"), ("signing", "signature"),
        ("docker", "shippingbox"), ("container", "shippingbox"),
        ("coolify", "server.rack"), ("apps", "server.rack"), ("server", "server.rack"), ("ssh", "server.rack"),
        ("vercel", "triangle"), ("netlify", "globe"), ("cloudflare", "cloud"), ("aws", "cloud"), ("fly", "cloud"),
        ("test", "checklist"), ("suite", "checklist"), ("typecheck", "checklist"), ("lint", "checklist"),
        ("build", "hammer"), ("xcode", "hammer"), ("compile", "hammer"),
        ("backup", "externaldrive"), ("relay", "antenna.radiowaves.left.and.right"), ("crm", "person.2"),
        ("quit", "power"), ("applications", "macwindow"), ("mac app", "macwindow"), ("install", "square.and.arrow.down"),
        ("proof", "checkmark.shield"), ("check", "stethoscope"), ("health", "stethoscope"), ("log", "doc.text.magnifyingglass"),
        ("board", "list.bullet.clipboard"), ("npm", "shippingbox"), ("script", "terminal"), ("terminal", "terminal"),
    ]
    public static func symbol(_ tool: String?) -> String {
        guard let name = tool?.lowercased(), !name.isEmpty else { return neutral }
        return known.first { name.contains($0.0) }?.1 ?? neutral
    }
}

public struct DeployStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Plain words: "Tests", "Release build", "Upload to TestFlight".
    public var name: String
    /// The tool really used, in its own name ("GitHub Actions", "Vercel", "codesign"); nil when none was named.
    public var tool: String?
    public var state: DeployState
    /// Seconds since 1970.
    public var startedAt: Double?
    public var endedAt: Double?
    /// The step's result in one short line, from the step itself: "built 1c29bb8b · signed", "17/17 checks",
    /// "deployed to app.example.com · health 200", "failed: 2 tests · <first failure>". While it runs: what it is doing.
    public var result: String?
    /// Optional details shown when the step is clicked: a log excerpt.
    public var log: String?
    public var link: String?
    /// Test steps: their numbers.
    public var passed: Int?
    public var failed: Int?

    public init(id: String, name: String, tool: String? = nil, state: DeployState,
                startedAt: Double? = nil, endedAt: Double? = nil, result: String? = nil, log: String? = nil, link: String? = nil,
                passed: Int? = nil, failed: Int? = nil) {
        self.id = id; self.name = name; self.tool = tool; self.state = state
        self.startedAt = startedAt; self.endedAt = endedAt; self.result = result; self.log = log; self.link = link
        self.passed = passed; self.failed = failed
    }

    public var symbol: String { DeployToolIcon.symbol(tool ?? name) }
    /// "5,792 passed · 0 failed" for a step with numbers.
    public var counts: String? {
        guard passed != nil || failed != nil else { return nil }
        return [passed.map { DeployFormat.number($0) + " passed" }, failed.map { DeployFormat.number($0) + " failed" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    /// The step's short line: its numbers first, then its result.
    public var line: String? {
        let parts = [counts, result.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    public var duration: Double? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt - startedAt
    }
}

/// Who ran a deployment. `kind`: hoot, lead, agent, session, person, app (an outside AI app), source (GitHub, TD Apps,
/// a log the history was read from).
public struct DeployActor: Codable, Sendable, Equatable {
    public var kind: String
    public var name: String
    public var agentID: String?
    public var sessionID: String?
    public init(kind: String, name: String, agentID: String? = nil, sessionID: String? = nil) {
        self.kind = kind; self.name = name; self.agentID = agentID; self.sessionID = sessionID
    }
}

/// Where the person asked for it: the first conversation with them up the hand-off chain. The live strip shows there.
/// `kind`: hoot (Hoot's chat, at the turn that asked), lead or session (that session), person (he made the task
/// himself: the strip shows in the session that does it), app (an outside AI app: no strip).
public struct DeployOrigin: Codable, Sendable, Equatable {
    public var kind: String
    public var name: String
    public var sessionID: String?
    /// When the request was made (seconds since 1970): which Hoot turn it belongs to.
    public var at: Double
    public init(kind: String, name: String, sessionID: String? = nil, at: Double) {
        self.kind = kind; self.name = name; self.sessionID = sessionID; self.at = at
    }
}

public struct DeployRun: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectID: String
    /// What this deployment is, in a few words.
    public var title: String?
    public var version: String?
    /// A hash, commit or build number.
    public var commit: String?
    /// reported (an AI reported it through the app tools), github-actions, td-apps, route-log.
    public var source: String
    public var externalID: String?
    public var link: String?
    public var by: DeployActor
    public var origin: DeployOrigin?
    /// running, done, failed, or skipped (cancelled).
    public var state: DeployState
    /// The final words.
    public var result: String?
    public var startedAt: Double
    public var updatedAt: Double
    public var endedAt: Double?
    public var steps: [DeployStep]

    public init(id: String, projectID: String, title: String? = nil, version: String? = nil, commit: String? = nil,
                source: String, externalID: String? = nil, link: String? = nil, by: DeployActor, origin: DeployOrigin? = nil,
                state: DeployState, result: String? = nil, startedAt: Double, updatedAt: Double? = nil, endedAt: Double? = nil,
                steps: [DeployStep] = []) {
        self.id = id; self.projectID = projectID; self.title = title; self.version = version; self.commit = commit
        self.source = source; self.externalID = externalID; self.link = link; self.by = by; self.origin = origin
        self.state = state; self.result = result; self.startedAt = startedAt; self.updatedAt = updatedAt ?? startedAt
        self.endedAt = endedAt; self.steps = steps
    }

    public var isLive: Bool { !state.finished }
    /// The step to highlight: the one running, else the one that failed, else the next one waiting.
    public var currentIndex: Int? {
        steps.firstIndex { $0.state == .running } ?? steps.firstIndex { $0.state == .failed }
            ?? (isLive ? steps.firstIndex { $0.state == .waiting } : nil)
    }
    public var current: DeployStep? { currentIndex.map { steps[$0] } }
    public var duration: Double? { endedAt.map { max(0, $0 - startedAt) } }
    /// "v0.21 · 04bcd2a" or the title: how a row names this run.
    public var label: String {
        let name = [version, commit.map { String($0.prefix(8)) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return name.isEmpty ? (title ?? "Deployment") : name
    }
    /// "Release agent · asked via Hoot".
    public var byLine: String {
        guard let origin, origin.kind != by.kind || origin.name != by.name else { return "run by " + by.name }
        return "run by " + by.name + " · asked via " + origin.name
    }
    /// Steps after a failed one that never ran: the pipeline stopped there.
    public func stopped(_ index: Int) -> Bool {
        guard state == .failed, let failed = steps.firstIndex(where: { $0.state == .failed }) else { return false }
        return index > failed && steps[index].state == .waiting
    }
    public var resultWord: String {
        switch state {
        case .done: "Done"
        case .failed: "Failed"
        case .skipped: "Cancelled"
        case .running, .waiting: "Running"
        }
    }
}

/// What an AI reports about one step.
public struct DeployStepReport: Sendable, Equatable {
    public var name: String
    public var tool: String?
    public var state: DeployState?
    public var result: String?
    public var log: String?
    public var link: String?
    public var passed: Int?
    public var failed: Int?
    public init(name: String, tool: String? = nil, state: DeployState? = nil, result: String? = nil, log: String? = nil,
                link: String? = nil, passed: Int? = nil, failed: Int? = nil) {
        self.name = name; self.tool = tool; self.state = state; self.result = result; self.log = log; self.link = link
        self.passed = passed; self.failed = failed
    }
}

public struct DeployFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The whole record: every project's runs, newest first, and which histories were already read in.
public struct DeployLedger: Codable, Sendable, Equatable {
    public var runs: [DeployRun] = []
    public var imports: [String] = []
    /// History kept per project.
    public static let keepPerProject = 200
    /// A run nobody reported on for this long no longer shows as live (the pill hides it); its row says so.
    public static let quietAfter: Double = 6 * 3600
    /// Tool ids. Every AI gets the same four (sessions, Hoot, AI apps).
    public static let toolIDs = ["deploy.start", "deploy.step", "deploy.finish", "deploy.runs"]
    public static var sessionToolNames: Set<String> { Set(toolIDs.flatMap { [$0, $0.replacingOccurrences(of: ".", with: "_")] }) }

    public init(runs: [DeployRun] = [], imports: [String] = []) { self.runs = runs; self.imports = imports }

    public func run(_ id: String) -> DeployRun? { runs.first { $0.id == id } }
    public func runs(project: String) -> [DeployRun] { runs.filter { $0.projectID == project } }
    /// Runs going on now (not quiet for hours).
    public func live(at now: Double) -> [DeployRun] { runs.filter { $0.isLive && now - $0.updatedAt < Self.quietAfter } }

    // MARK: Reported runs

    @discardableResult
    public mutating func start(projectID: String, title: String? = nil, version: String? = nil, commit: String? = nil,
                               by: DeployActor, origin: DeployOrigin?, plan: [(name: String, tool: String?)] = [],
                               link: String? = nil, at: Double, id: String = UUID().uuidString.lowercased()) -> DeployRun {
        var run = DeployRun(id: "run-" + id.prefix(12), projectID: projectID, title: Self.clip(title, 120), version: Self.clip(version, 60),
                            commit: Self.clip(commit, 60), source: "reported", link: Self.clip(link, 600), by: by, origin: origin,
                            state: .running, startedAt: at)
        var seen = Set<String>()
        for (index, step) in plan.prefix(40).enumerated() {
            let name = Self.clip(step.name, 80) ?? "Step \(index + 1)"
            guard seen.insert(name.lowercased()).inserted else { continue }
            run.steps.append(DeployStep(id: "s\(run.steps.count + 1)", name: name, tool: Self.clip(step.tool, 40), state: .waiting))
        }
        runs.insert(run, at: 0)
        closeQuiet(at: at)
        prune()
        return run
    }

    /// #492: a reported run nobody reported on for `quietAfter` is closed as cancelled at its last news, so an AI
    /// session that crashed or stopped after deploy_start does not leave a run that shows Running and is kept forever.
    /// Runs from a source are left to that source. Returns how many were closed.
    @discardableResult
    public mutating func closeQuiet(at now: Double) -> Int {
        let quiet = runs.filter { $0.source == "reported" && $0.isLive && now - $0.updatedAt >= Self.quietAfter }
        for run in quiet {
            _ = try? finish(runID: run.id, state: .skipped, result: "no news for " + DeployFormat.duration(Self.quietAfter) + ", closed by the app",
                            at: run.updatedAt)
        }
        return quiet.count
    }

    /// One step's news. A step with the same name is updated; a new name is added after the others.
    @discardableResult
    public mutating func report(runID: String, _ report: DeployStepReport, at: Double) throws -> (run: DeployRun, index: Int) {
        guard let position = runs.firstIndex(where: { $0.id == runID }) else { throw DeployFailure("There is no deployment \(runID). deploy_runs lists them.") }
        var run = runs[position]
        guard run.state != .done, run.state != .skipped else { throw DeployFailure("That deployment is finished. Start a new one with deploy_start.") }
        guard let name = Self.clip(report.name, 80) else { throw DeployFailure("Name the step in a few words.") }
        let state = report.state ?? (report.failed.map { $0 > 0 ? .failed : .done } ?? .running)
        let index: Int
        if let found = run.steps.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == report.name }) { index = found }
        else {
            run.steps.append(DeployStep(id: "s\(run.steps.count + 1)", name: name, state: .waiting))
            index = run.steps.count - 1
        }
        var step = run.steps[index]
        if let tool = Self.clip(report.tool, 40) { step.tool = tool }
        if let result = report.result { step.result = Self.clip(result, 200) }
        if let log = report.log?.trimmingCharacters(in: .whitespacesAndNewlines), !log.isEmpty { step.log = String(log.suffix(4000)) }
        if let link = report.link { step.link = Self.clip(link, 600) }
        if let passed = report.passed { step.passed = max(0, passed) }
        if let failed = report.failed { step.failed = max(0, failed) }
        step.state = state
        switch state {
        case .running:
            step.startedAt = step.startedAt ?? at; step.endedAt = nil
        case .done, .failed, .skipped:
            // A step reported only when it ended started when the one before it ended.
            step.startedAt = step.startedAt ?? (index > 0 ? run.steps[..<index].compactMap(\.endedAt).max() : nil) ?? at
            step.endedAt = at
        case .waiting:
            step.startedAt = nil; step.endedAt = nil
        }
        run.steps[index] = step
        // A failed step stops the pipeline where everyone can see it; reporting the step again (a retry) goes on.
        if state == .failed { run.state = .failed; run.endedAt = at; run.result = "Stopped at " + name + (step.line.map { ": " + $0 } ?? "") }
        else if run.state == .failed, state == .running || state == .done { run.state = .running; run.endedAt = nil; run.result = nil }
        run.updatedAt = at
        runs[position] = run
        return (run, index)
    }

    /// The end of a run. With no state: failed when a step failed, else done. Steps still running end with it;
    /// steps that never started are marked skipped.
    @discardableResult
    public mutating func finish(runID: String, state: DeployState? = nil, result: String? = nil, version: String? = nil,
                                commit: String? = nil, link: String? = nil, at: Double) throws -> DeployRun {
        guard let position = runs.firstIndex(where: { $0.id == runID }) else { throw DeployFailure("There is no deployment \(runID). deploy_runs lists them.") }
        var run = runs[position]
        let final: DeployState = {
            if let state, state.finished { return state }
            return run.steps.contains { $0.state == .failed } ? .failed : .done
        }()
        for index in run.steps.indices {
            switch run.steps[index].state {
            case .running:
                run.steps[index].state = final == .done ? .done : final == .failed ? .failed : .skipped
                run.steps[index].endedAt = at
            case .waiting:
                if final != .failed { run.steps[index].state = .skipped }
            default: break
            }
        }
        run.state = final
        run.endedAt = at; run.updatedAt = at
        if let result { run.result = Self.clip(result, 200) } else if final == .done { run.result = nil }
        if let version { run.version = Self.clip(version, 60) }
        if let commit { run.commit = Self.clip(commit, 60) }
        if let link { run.link = Self.clip(link, 600) }
        runs[position] = run
        return run
    }

    // MARK: Runs from live sources and old logs

    /// Adds or refreshes runs that came from a source (same id = same run). Reported runs are never touched.
    public mutating func merge(_ incoming: [DeployRun]) {
        guard !incoming.isEmpty else { return }
        for run in incoming {
            if let index = runs.firstIndex(where: { $0.id == run.id }) {
                guard runs[index].source != "reported" else { continue }
                runs[index] = run
            } else { runs.append(run) }
        }
        prune()
    }

    /// Newest first, and at most `keepPerProject` per project (live runs always stay).
    mutating func prune() {
        runs.sort { $0.startedAt > $1.startedAt }
        var counts: [String: Int] = [:]
        runs = runs.filter { run in
            counts[run.projectID, default: 0] += 1
            return run.isLive || counts[run.projectID, default: 0] <= Self.keepPerProject
        }
    }

    static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    // MARK: Where the live strip shows

    /// The run whose strip shows at the top of this session: asked for there (live, or folded for a few minutes after).
    public func strip(forSession id: String, at now: Double) -> DeployRun? {
        runs.first { run in
            guard let origin = run.origin, origin.kind != "hoot", origin.sessionID == id else { return false }
            return run.isLive ? now - run.updatedAt < Self.quietAfter : now - (run.endedAt ?? run.updatedAt) < Self.foldedFor
        }
    }
    /// Runs asked for in Hoot's chat, for the slim panel at the right of Hoot's page (Asad, 12 Oct: beside the chat, so
    /// the chat keeps going): live ones, and for a few minutes after they finish (folded to one line). Newest first.
    public func hootPanel(at now: Double) -> [DeployRun] {
        runs.filter { run in
            guard run.origin?.kind == "hoot" else { return false }
            return run.isLive ? now - run.updatedAt < Self.quietAfter : now - (run.endedAt ?? run.updatedAt) < Self.foldedFor
        }
    }
    /// How long a finished run stays beside where it was asked for, folded to one line.
    public static let foldedFor: Double = 10 * 60
}

/// The small live pill in the side panel: shown only while something deploys.
public enum DeployPill {
    /// The pill shows just the current step ("Install"), never a line cut short (Asad, 13 Oct: "instead of ... just
    /// show the current step"); `full` ("Deploying Terminal Deck · step 4 of 7 · Install") is its hover text.
    /// Before any step is reported it reads "Deploying Terminal Deck". nil when nothing is running.
    public static func line(_ ledger: DeployLedger, projectName: (String) -> String, at now: Double) -> (run: DeployRun, text: String, full: String)? {
        guard let run = ledger.live(at: now).first else { return nil }
        var text = "Deploying " + projectName(run.projectID), full = text
        if let index = run.currentIndex, !run.steps.isEmpty {
            text = run.steps[index].name
            full += " · step \(index + 1) of \(run.steps.count) · " + run.steps[index].name
        }
        let others = ledger.live(at: now).count - 1
        if others > 0 { text += " +\(others)"; full += " · +\(others) more" }
        return (run, text, full)
    }
}

public enum DeployFormat {
    public static func number(_ value: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    /// "45 s", "4 min", "1 h 12 min".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
    }
    /// Seconds from a time the outside world wrote in seconds or milliseconds.
    public static func seconds(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value > 100_000_000_000 ? value / 1000 : value
    }
    public static func iso(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)?.timeIntervalSince1970
    }
}

/// The record on disk: `<app data>/deployments.json`, written whole and atomically.
public enum DeployLedgerFile {
    public static let name = "deployments.json"
    /// The record as read, with `problem` set when part of it did not read and `writable` false when not even a
    /// copy of the file could be kept (U1: then nothing is saved over it).
    public struct Loaded: Sendable {
        public var ledger: DeployLedger, problem: String?, writable: Bool
    }
    /// Read run by run, so one run that no longer reads (an update changed a field) costs only that run.
    private struct SavedLedger: Decodable {
        var runs: [SavedRun]?
        var imports: [String]?
    }
    private struct SavedRun: Decodable {
        let run: DeployRun?
        init(from decoder: Decoder) throws { run = try? DeployRun(from: decoder) }
    }
    public static func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(ledger: DeployLedger(), problem: nil, writable: true) }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedLedger.self, from: data) {
            let runs = (saved.runs ?? []).compactMap(\.run)
            let ledger = DeployLedger(runs: runs, imports: saved.imports ?? [])
            if runs.count == saved.runs?.count, saved.imports != nil { return Loaded(ledger: ledger, problem: nil, writable: true) }
            let copy = DamagedFile.keepCopy(of: url)
            return Loaded(ledger: ledger, problem: DamagedFile.sentence("The saved deployment history", copy: copy), writable: copy != nil)
        }
        let copy = DamagedFile.keepCopy(of: url)
        return Loaded(ledger: DeployLedger(), problem: DamagedFile.sentence("The saved deployment history", copy: copy), writable: copy != nil)
    }
    public static func save(_ ledger: DeployLedger, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(ledger).write(to: url, options: [.atomic])
    }
}
