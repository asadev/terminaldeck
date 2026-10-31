import Foundation

// DEPLOY-PIPELINE: runs that appear even when nobody reports them, mapped into the same record. Each run carries only
// the steps its source really had (GitHub's own jobs, the app engine's own phases, the log's own lines).

/// GitHub Actions: a project's linked repository. Only deployment-like workflows (release, deploy, publish, a tag…).
public enum DeployGitHubActions {
    public static let source = "github-actions"
    static let words: Set<String> = ["deploy", "deployment", "deploys", "release", "releases", "publish", "ship", "testflight",
                                     "notarize", "notarise", "notarization", "production", "prod", "pages", "cd", "delivery", "store", "upload", "rollout", "launch"]

    /// A workflow run that deploys something, by its workflow's name, file, title, or because a release or tag started it.
    public static func isDeploy(_ run: NativeRPCValue) -> Bool {
        if run["event"].string == "release" { return true }
        if let branch = run["head_branch"].string, branch.range(of: #"^v?\d+\.\d+"#, options: .regularExpression) != nil { return true }
        let text = [run["name"].string, run["path"].string, run["display_title"].string].compactMap { $0 }.joined(separator: " ").lowercased()
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains { words.contains($0) }
    }

    /// One workflow run with its jobs (nil: not read yet) → a run whose steps are GitHub's own jobs, with their results.
    public static func run(_ value: NativeRPCValue, jobs: [NativeRPCValue]?, projectID: String) -> DeployRun? {
        guard let id = value["id"].number.map({ String(Int($0)) }) ?? value["id"].string else { return nil }
        let created = DeployFormat.iso(value["run_started_at"].string) ?? DeployFormat.iso(value["created_at"].string) ?? 0
        let updated = DeployFormat.iso(value["updated_at"].string) ?? created
        let state = state(status: value["status"].string, conclusion: value["conclusion"].string)
        let sha = value["head_sha"].string
        let repo = value["repository"]["full_name"].string
        let workflow = value["name"].string ?? "Workflow"
        var steps: [DeployStep] = []
        if let sha {
            let message = value["head_commit"]["message"].string?.split(separator: "\n").first.map(String.init)
            steps.append(DeployStep(id: "push", name: "Code pushed", tool: "GitHub", state: .done, startedAt: created, endedAt: created,
                                    result: [String(sha.prefix(7)), message].compactMap { $0 }.joined(separator: " · "),
                                    link: repo.map { "https://github.com/\($0)/commit/\(sha)" }))
        }
        if let jobs, !jobs.isEmpty {
            for job in jobs { steps.append(step(job)) }
        } else {
            steps.append(DeployStep(id: "workflow", name: workflow, tool: "GitHub Actions", state: state == .skipped ? .skipped : state,
                                    startedAt: created, endedAt: state.finished ? updated : nil,
                                    result: conclusionWords(value["conclusion"].string), link: value["html_url"].string))
        }
        let actor = value["triggering_actor"]["login"].string ?? value["actor"]["login"].string
        let branch = value["head_branch"].string
        let tag = branch.flatMap { $0.range(of: #"^v?\d+\.\d+"#, options: .regularExpression) != nil ? $0 : nil }
        let number = value["run_number"].number.map { "#\(Int($0))" }
        return DeployRun(id: source + ":" + id, projectID: projectID,
                         title: [workflow, value["display_title"].string].compactMap { $0 }.joined(separator: " · "),
                         version: tag ?? number, commit: sha.map { String($0.prefix(7)) }, source: source, externalID: id,
                         link: value["html_url"].string,
                         by: DeployActor(kind: "source", name: "GitHub Actions" + (actor.map { " · started by \($0)" } ?? "")),
                         state: state, result: state.finished ? conclusionWords(value["conclusion"].string) : nil,
                         startedAt: created, updatedAt: updated, endedAt: state.finished ? updated : nil, steps: steps)
    }

    static func step(_ job: NativeRPCValue) -> DeployStep {
        let state = state(status: job["status"].string, conclusion: job["conclusion"].string)
        let inner = job["steps"].elements ?? []
        let doneCount = inner.filter { $0["status"].string == "completed" }.count
        let result: String?
        switch state {
        case .running:
            result = inner.first { $0["status"].string == "in_progress" }?["name"].string.map { "now: " + $0 }
        case .failed:
            let broken = inner.first { ["failure", "timed_out", "cancelled"].contains($0["conclusion"].string ?? "") }?["name"].string
            result = "failed" + (broken.map { " at " + $0 } ?? "")
        case .done:
            result = inner.isEmpty ? "passed" : "\(doneCount)/\(inner.count) steps passed"
        default:
            result = conclusionWords(job["conclusion"].string)
        }
        return DeployStep(id: "job-" + (job["id"].number.map { String(Int($0)) } ?? job["name"].string ?? UUID().uuidString),
                          name: job["name"].string ?? "Job", tool: "GitHub Actions", state: state,
                          startedAt: DeployFormat.iso(job["started_at"].string), endedAt: state.finished ? DeployFormat.iso(job["completed_at"].string) : nil,
                          result: result, link: job["html_url"].string)
    }

    static func state(status: String?, conclusion: String?) -> DeployState {
        switch status {
        case "completed":
            switch conclusion {
            case "success": return .done
            case "skipped", "neutral", "cancelled", "stale": return .skipped
            default: return .failed
            }
        case "queued", "waiting", "requested", "pending": return .waiting
        default: return .running
        }
    }
    static func conclusionWords(_ conclusion: String?) -> String? {
        switch conclusion {
        case "success": "passed"
        case "failure": "failed"
        case "timed_out": "timed out"
        case "cancelled": "cancelled"
        case "skipped": "skipped"
        case "action_required": "needs approval on GitHub"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: nil
        }
    }
}

/// Terminal Deck Apps (the app's own Coolify replacement) on the project's servers: each deploy of an app, with the
/// phases the engine records.
public enum DeployTDApps {
    public static let source = "td-apps"

    /// An app's saved deploy row → a run. `server`: the server's name, `app`: the app's record.
    public static func run(_ row: NativeRPCValue, app: NativeRPCValue, serverID: String, server: String, projectID: String) -> DeployRun? {
        guard let id = row["id"].string, let appID = app["id"].string else { return nil }
        let status = row["status"].string ?? ""
        let started = DeployFormat.seconds(row["createdAt"].number) ?? 0
        let ended = DeployFormat.seconds(row["finishedAt"].number)
        let appName = app["name"].string ?? appID
        let commit = row["commit"].string ?? row["requestedRevision"].string
        let domain = (row["domains"].elements ?? app["domains"].elements ?? []).compactMap { $0.string ?? $0["host"].string }.first
        let warnings = (row["warnings"].elements ?? []).compactMap(\.string)
        let state: DeployState
        var build = DeployState.done, start = DeployState.done
        switch status {
        case "building": state = .running; build = .running; start = .waiting
        case "ready": state = .running; start = .running
        // The engine keeps one status per deploy, so a failure sits on the build.
        case "failed": state = .failed; build = .failed; start = .skipped
        default: state = .done
        }
        let repo = app["source"]["repository"].string
        var steps: [DeployStep] = []
        if let repo {
            steps.append(DeployStep(id: "source", name: "Fetch the code", tool: "GitHub", state: .done, startedAt: started, endedAt: started,
                                    result: [repo, commit.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · ")))
        }
        steps.append(DeployStep(id: "build", name: "Build the image", tool: "Docker", state: build, startedAt: started,
                                endedAt: build.finished ? ended : nil,
                                result: build == .failed ? "failed: see the app's deploy log" : build == .done ? (row["imageTag"].string.map { "image " + $0 } ?? "built") : "building",
                                log: build == .failed ? warnings.joined(separator: "\n") : nil))
        steps.append(DeployStep(id: "start", name: "Start on " + server, tool: "Terminal Deck Apps", state: start, startedAt: start == .waiting || start == .skipped ? nil : started,
                                endedAt: start.finished ? ended : nil,
                                result: start == .done ? (["running", domain.map { "on " + $0 }].compactMap { $0 }.joined(separator: " ")) : start == .running ? "starting" : nil))
        let title = row["rollbackOf"].isNullish ? appName : "Rollback of " + appName
        return DeployRun(id: source + ":" + serverID + ":" + appID + ":" + id, projectID: projectID, title: title,
                         version: row["imageTag"].string, commit: commit.map { String($0.prefix(7)) }, source: source, externalID: id,
                         link: domain.map { "https://" + $0 }, by: DeployActor(kind: "source", name: "Terminal Deck Apps · " + server),
                         state: state, result: state == .failed ? "failed" : state == .done ? (domain.map { "deployed to " + $0 } ?? "deployed") : nil,
                         startedAt: started, updatedAt: ended ?? started, endedAt: state.finished ? (ended ?? started) : nil, steps: steps)
    }
}

/// Real history read once from a team board in the project's folder (Terminal Deck's ROUTE.md): each INSTALLED line
/// with the FREEZE, test SUITE, RELEASE BUILT and PROOF lines around it. Only steps the lines say.
public enum DeployRouteLog {
    public static let source = "route-log"
    /// Where such a board sits inside a project's folder.
    public static let places = ["macos/docker/ROUTE.md", "code/td-native-shell/macos/docker/ROUTE.md"]

    struct Line { let index: Int; let kind: String; let text: String; let time: Double? }

    public static func runs(_ text: String, projectID: String, timeZone: TimeZone = .current) -> [DeployRun] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var lastDay: DateComponents?
        var lines: [Line] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let kind: String
            if raw.hasPrefix("INSTALLED ") { kind = "installed" }
            else if raw.hasPrefix("FREEZE ") { kind = "freeze" }
            else if raw.hasPrefix("RELEASE BUILT ") { kind = "built" }
            else if raw.hasPrefix("SUITE") { kind = "suite" }
            else if raw.hasPrefix("OLD-HOST PROOF") || raw.range(of: #"^PROOF \d"#, options: .regularExpression) != nil { kind = "proof" }
            else { kind = "" }
            // Every dated line moves the day on; lines with only a clock time take the last day.
            var time: Double?
            if let match = raw.range(of: #"20\d\d-\d\d-\d\d \d\d:\d\d"#, options: .regularExpression) {
                let stamp = String(raw[match])
                let parts = stamp.split { $0 == "-" || $0 == " " || $0 == ":" }.compactMap { Int($0) }
                if parts.count == 5 {
                    lastDay = DateComponents(year: parts[0], month: parts[1], day: parts[2])
                    time = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))?.timeIntervalSince1970
                }
            } else if !kind.isEmpty, let day = lastDay, let clock = firstClock(raw) {
                time = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: clock.0, minute: clock.1))?.timeIntervalSince1970
            }
            if !kind.isEmpty { lines.append(Line(index: index, kind: kind, text: raw, time: time)) }
        }
        var runs: [DeployRun] = []
        var pending: [Line] = []
        var lastInstalled: Int?
        for line in lines {
            if line.kind == "installed" {
                if let run = make(pending: pending, installed: line, number: runs.count + 1, projectID: projectID, calendar: calendar) { runs.append(run) }
                pending = []; lastInstalled = line.index
                continue
            }
            // A suite run on the frozen tree but posted just after the install belongs to that install.
            if line.kind == "suite", let last = lastInstalled, line.index - last <= 5, line.text.contains("frozen tree"),
               !pending.contains(where: { $0.kind == "freeze" }), var run = runs.popLast() {
                let step = suite(line, calendar: calendar)
                run.steps.insert(step, at: min(1, run.steps.count))
                runs.append(run)
                continue
            }
            pending.append(line)
        }
        return runs
    }

    static func firstClock(_ text: String) -> (Int, Int)? {
        guard let match = text.range(of: #"\b\d\d:\d\d\b"#, options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
    /// "(06:03–06:11)" or "built 06:00–06:11" on the same day as `line`.
    static func range(_ text: String, day: Double?, calendar: Calendar) -> (Double, Double)? {
        guard let day, let match = text.range(of: #"\d\d:\d\d[–-]\d\d:\d\d"#, options: .regularExpression) else { return nil }
        let clocks = text[match].split { $0 == "–" || $0 == "-" }.map { $0.split(separator: ":").compactMap { Int($0) } }
        guard clocks.count == 2, clocks.allSatisfy({ $0.count == 2 }) else { return nil }
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: day)).timeIntervalSince1970
        return (start + Double(clocks[0][0] * 3600 + clocks[0][1] * 60), start + Double(clocks[1][0] * 3600 + clocks[1][1] * 60))
    }
    static func number(_ text: String, _ pattern: String) -> Int? {
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let digits = text[match].filter(\.isNumber)
        return Int(digits)
    }

    static func suite(_ line: Line, calendar: Calendar) -> DeployStep {
        let total = number(line.text, #"\d[\d,]* tests"#)
        let failing = number(line.text, #"REAL FAILURES: \d+"#) ?? number(line.text, #"FAILING: \d+"#) ?? 0
        let span = range(line.text, day: line.time, calendar: calendar)
        return DeployStep(id: "tests-\(line.index)", name: "Tests", tool: "Swift tests (full suite)", state: failing > 0 ? .failed : .done,
                          startedAt: span?.0 ?? line.time, endedAt: span?.1 ?? line.time,
                          result: failing > 0 ? "failed: \(failing) test\(failing == 1 ? "" : "s")" : "all passed",
                          log: line.text, passed: total.map { max(0, $0 - failing) }, failed: failing)
    }

    static func make(pending: [Line], installed: Line, number: Int, projectID: String, calendar: Calendar) -> DeployRun? {
        guard let end = installed.time else { return nil }
        // The first freeze after the last install (a re-freeze for a rebuild is a later step of the same run).
        let freeze = pending.first { $0.kind == "freeze" }
        let start = min(freeze?.time ?? pending.compactMap(\.time).min() ?? end, end)
        var steps: [DeployStep] = []
        var cursor = start
        func add(_ step: DeployStep) {
            var step = step
            let begin = min(max(step.startedAt ?? cursor, start), end)
            step.startedAt = begin
            step.endedAt = min(max(step.endedAt ?? begin, begin), end)
            cursor = step.endedAt ?? cursor
            steps.append(step)
        }
        var signed = false
        for line in pending {
            switch line.kind {
            case "freeze":
                add(DeployStep(id: "freeze-\(line.index)", name: "Freeze the code", tool: "Team board (ROUTE)", state: .done,
                               startedAt: line.time, endedAt: line.time, result: "nobody saves until the install is done", log: line.text))
            case "suite":
                add(suite(line, calendar: calendar))
            case "built":
                let span = range(line.text, day: line.time, calendar: calendar)
                add(DeployStep(id: "build-\(line.index)", name: "Release build", tool: "Local release build", state: .done,
                               startedAt: span?.0, endedAt: span?.1 ?? line.time, result: "built", log: line.text))
                if !signed, line.text.localizedCaseInsensitiveContains("signed") {
                    signed = true
                    add(DeployStep(id: "sign-\(line.index)", name: "Signing check", tool: "codesign", state: .done,
                                   startedAt: cursor, endedAt: cursor, result: "signed, strict check passed"))
                }
            case "proof":
                let passed = line.text.range(of: #"ALL (\d+ )?LINES PASS"#, options: .regularExpression)
                let count = Self.number(line.text, #"ALL \d+ LINES"#)
                add(DeployStep(id: "proof-\(line.index)", name: "Old-host safety proof", tool: "Old-host proof harness",
                               state: passed == nil ? .failed : .done, endedAt: line.time,
                               result: passed == nil ? "failed: a line did not pass" : count.map { "\($0)/\($0) lines passed" } ?? "all lines passed",
                               log: line.text))
                if !signed, line.text.localizedCaseInsensitiveContains("strictly signed") {
                    signed = true
                    add(DeployStep(id: "sign-\(line.index)", name: "Signing check", tool: "codesign", state: .done,
                                   endedAt: line.time, result: "still strictly signed, app untouched"))
                }
            default: break
            }
        }
        let text = installed.text
        let hash = text.range(of: #"hash [0-9a-f]{8,}"#, options: .regularExpression).map { String(text[$0].dropFirst(5)) }
        if text.range(of: #"backup|backed up|old app in|previous build in"#, options: [.regularExpression, .caseInsensitive]) != nil {
            add(DeployStep(id: "backup", name: "Back up the app and data", tool: "Backup copy", state: .done, startedAt: end, endedAt: end, result: "previous build kept"))
        }
        if text.range(of: #"quit"#, options: .caseInsensitive) != nil {
            let detail = text.range(of: #"[Qq]uit[^;.]*?\([^)]*\)"#, options: .regularExpression).map { String(text[$0]) }
                ?? text.range(of: #"[Qq]uit[^;.]{0,60}"#, options: .regularExpression).map { String(text[$0]) }
            add(DeployStep(id: "quit", name: "Quit the app", tool: "Scripted quit", state: .done, startedAt: end, endedAt: end, result: detail ?? "closed"))
        }
        add(DeployStep(id: "swap", name: "Swap in the new app and reopen", tool: "Applications folder", state: .done, startedAt: end, endedAt: end,
                       result: hash.map { "installed " + String($0.prefix(8)) } ?? "installed"))
        var checks: [String] = []
        if text.localizedCaseInsensitiveContains("Hoot awake") { checks.append("Hoot awake") }
        if text.range(of: #"ERROR( lines)? 0"#, options: .regularExpression) != nil { checks.append("errors 0") }
        if text.range(of: #"startup failed 0"#, options: .regularExpression) != nil { checks.append("startup failed 0") }
        if text.range(of: #"kept"#, options: .caseInsensitive) != nil { checks.append("sessions kept") }
        if text.localizedCaseInsensitiveContains("gte-small") { checks.append("model loaded") }
        if text.localizedCaseInsensitiveContains("Checks green") && checks.isEmpty { checks.append("checks green") }
        if !checks.isEmpty {
            add(DeployStep(id: "checks", name: "Checks after the install", tool: "App log checks", state: .done, startedAt: end, endedAt: end,
                           result: checks.joined(separator: " · ")))
        }
        if text.contains("Committed") {
            add(DeployStep(id: "commit", name: "Commit", tool: "Git", state: .done, startedAt: end, endedAt: end, result: "committed"))
        }
        // What the install was for, from its freeze line.
        let purpose: String? = freeze.flatMap { line in
            guard let at = line.text.range(of: #"for install \d+"#, options: .regularExpression) else { return nil }
            var rest = line.text[at.upperBound...].drop { $0 == " " || $0 == ":" }
            if rest.hasPrefix("(") { rest = rest.dropFirst(); return rest.firstIndex(of: ")").map { String(rest[..<$0]) } }
            if line.text[at.upperBound...].hasPrefix(":") { return rest.firstIndex(of: ".").map { String(rest[..<$0]) } ?? String(rest) }
            return nil
        }
        let poster = text.split(separator: " ").dropFirst().first.map(String.init) ?? "lead"
        return DeployRun(id: "route-install-\(number)", projectID: projectID, title: DeployLedger.clip(purpose, 90) ?? "Install into the Mac app",
                         version: "Install \(number)", commit: hash.map { String($0.prefix(8)) }, source: source, externalID: "install-\(number)",
                         by: DeployActor(kind: "lead", name: "the lead's session (\(poster))"), state: .done,
                         result: "installed", startedAt: start, updatedAt: end, endedAt: end, steps: steps)
    }
}
