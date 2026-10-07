import Foundation
import Darwin

public struct BackendRoutinesDefault: Sendable, Equatable {
    public let id: String
    public let name: String
    public let triggers: [String]
    public let enabled: Bool
    public let overlap: String?
    public let quietFor: String?
    public let maxRunsPerHour: Int?
    public let expectEvery: String?
    public let why: String
    public let prompt: String

    public func file(folder: String) -> String {
        var lines = ["# \(name)", ""] + triggers.map { "when: \($0)" }
        lines += ["in: \(folder)", "enabled: \(enabled ? "yes" : "no")"]
        if let overlap { lines.append("overlap: \(overlap)") }
        if let quietFor { lines.append("quiet-for: \(quietFor)") }
        if let maxRunsPerHour, maxRunsPerHour != 0 { lines.append("max-runs-per-hour: \(maxRunsPerHour)") }
        if let expectEvery { lines.append("expect-every: \(expectEvery)") }
        lines += ["", "# \(why)", "# `in:` is the folder this watches. Point it somewhere else, or copy this",
                  "# file once per project — Terminal Deck reads every .md in this folder.",
                  "", "---", "", prompt.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }
}

public struct BackendRoutinesSeedResult: Sendable, Equatable {
    public let written: [String]
    public let skipped: String?
}

/// defaults.ts: exact shipped prompts, trigger settings and deletion-respecting marker.
public enum BackendRoutinesDefaults {
    public static let routines: [BackendRoutinesDefault] = [
        BackendRoutinesDefault(id: "blocked-agent", name: "Something is waiting on you",
            triggers: ["alert session-blocked"], enabled: true,
            overlap: "skip", quietFor: "5m", maxRunsPerHour: 6,
            expectEvery: nil, why: "A blocked agent burns wall-clock silently. This is the most valuable routine here.",
            prompt: #"""
            A session in this folder has been waiting on a human for ten minutes or more.
            
            Call sessions_list. For every session whose `attention` is "blocked", say in one
            line each: which session, how long it has been waiting, and **what it is actually
            asking**. Read the last few messages with sessions_transcript to get the question
            — do not guess it from the status.
            
            If more than one is blocked, put them in one message, longest wait first. One
            digest, never one message per session.
            
            ## Do not
            
            - Do not answer the question for them. You cannot see what they intended.
            - Do not type into the session. It is theirs and they are mid-thought in it.
            - Do not report a session whose `attention` is "quiet" — an idle prompt is not
              somebody being blocked, it is a session nobody is using.
            - Do not report the same session twice in a row if nothing has changed about it.
            """#),
        BackendRoutinesDefault(id: "session-failed", name: "A session died",
            triggers: ["session-failed"], enabled: true,
            overlap: "queue", quietFor: "30s", maxRunsPerHour: 10,
            expectEvery: nil, why: "Converts a red dot into a decision. Cheap: it only fires when something actually died.",
            prompt: #"""
            A session in this folder exited with a non-zero code.
            
            Call sessions_result for that session. In two lines: why it died, and whether it
            is worth restarting. The exit code, the last thing it said, and whether it left
            changes on disk are the three facts that answer that — sessions_result has all
            three.
            
            If it left uncommitted changes behind, say so and say how many files, because a
            dead session with half an edit in the working tree is the thing that bites
            tomorrow.
            
            ## Do not
            
            - Do not restart it. That is a decision with money attached and it is theirs.
            - Do not report a clean exit. This routine only fires on a failure, but a shell
              that exited 130 because somebody pressed Ctrl-C is not news — say so in one
              line and stop.
            """#),
        BackendRoutinesDefault(id: "stuck-session", name: "Going round in circles",
            triggers: ["alert loop", "alert heavy-session"], enabled: true,
            overlap: "skip", quietFor: "10m", maxRunsPerHour: 4,
            expectEvery: nil, why: "A live session repeating itself with nothing landing on disk. The cost alert is kept as the second trigger, for the expensive sessions that are not looping.",
            prompt: #"""
            A session in this folder looks like it is going round in circles, or is
            costing far more than the others in it. Which one it is, is in the alert's title.
            
            Call sessions_result for that session and look at `progress`. It says whether the
            session is repeating itself and what it is repeating: the same tool over and over,
            the same failure, a compaction immediately undone, nothing written to a file.
            
            **Check the alert against the tool before you report it.** The alert was raised
            from a scan that ran a moment ago; sessions_result reads the transcript now. If
            the session has moved on — files written since, a different tool, the failures
            stopped — say so and stop. An alert that was true a minute ago and is not true
            now is the single most common way this kind of report loses somebody's trust.
            
            Then say one of three things, and nothing else:
            
            1. It is working and it is expensive — here is what it has spent and what it has
               changed on disk.
            2. It looks stuck — here is exactly what it has been retrying, for how long, and
               what it has spent doing it.
            3. It cannot be told — this session writes no transcript, so there is nothing to
               read. Say that plainly rather than saying it looks fine.
            
            ## Do not
            
            - Do not stop the session. Reporting is your job; stopping is theirs.
            - Do not call it stuck when `progress.verdict` is "suspect" — that is repetition
              with files still landing, which is what a refactor looks like.
            - Do not read the whole transcript to double-check. sessions_result already read
              the part that matters, and a transcript read costs tens of thousands of tokens.
            - Do not repeat the alert back. It is already on their screen. Say what the
              evidence adds to it.
            """#),
        BackendRoutinesDefault(id: "overnight", name: "What happened overnight",
            triggers: ["schedule 08:30"], enabled: true,
            overlap: "skip", quietFor: nil, maxRunsPerHour: 2,
            expectEvery: "26h", why: "The one place a clock genuinely beats an event: \"when I next sit down\" is not something the machine can see.",
            prompt: #"""
            Report on everything that ran since yesterday.
            
            Call sessions_result with no sessionId and sinceMinutes: 960. That is the whole
            report in one call — every session that was active, ranked so the ones needing a
            human come first.
            
            Write it as:
            
            - One line at the top: the headline the tool gives you.
            - Then one line per session that matters: what it was, how it ended, what it
              spent, what it changed on disk.
            - Then, for any folder with uncommitted changes, call git_diff on it and say
              what changed and **which session did it** — the tool attributes each file, and
              says honestly when two sessions could both have written it.
            
            Every claim gets its pointer: the transcript path, the file paths, the exit code.
            A summary they have to re-verify by hand costs more than no summary.
            
            ## Do not
            
            - Do not repeat what a session *said* it did. Say what the evidence shows. "It
              says the tests pass" and "the tests pass" are different sentences and you can
              only honestly write the first one.
            - Do not include sessions that did nothing.
            - Do not paste diffs. Say what changed; they can open it.
            """#),
        BackendRoutinesDefault(id: "dirty-tree", name: "Uncommitted work left behind",
            triggers: ["alert dirty-tree"], enabled: true,
            overlap: "skip", quietFor: "30m", maxRunsPerHour: 2,
            expectEvery: nil, why: "Fires on the existing dirty-tree alert, which already has its streak counters tuned.",
            prompt: #"""
            Several sessions have come and gone in this folder and left the working tree
            dirty.
            
            Call git_diff on this folder. Say:
            
            - how many files are changed, and roughly what the change is,
            - which sessions the changes are attributable to — the tool works this out from
              file times against session start times, and says "one of these two" rather
              than guessing when it cannot tell,
            - and whether anything looks like it was not asked for: a lockfile nobody
              mentioned, a config file, a file in a directory unrelated to the work.
            
            That last one is the point of this routine. The rest is bookkeeping.
            
            ## Do not
            
            - Do not commit, stash or revert anything. Ever. You have no write access and no
              shell, and even if you had, deciding what goes into somebody's history is not
              a thing to do while they are asleep.
            - Do not report a tree that is dirty because of build output. Check whether the
              paths are ignored-looking before you raise them.
            """#),
        BackendRoutinesDefault(id: "memory-check", name: "Weekly look at what you remember",
            triggers: ["schedule 03:00 sun"], enabled: true,
            overlap: "skip", quietFor: nil, maxRunsPerHour: 1,
            expectEvery: "8d", why: "Memory pollution is invisible: superseded facts stay retrievable and quietly degrade every answer.",
            prompt: #"""
            Read every file in your memory/ folder and report what has gone wrong with it.
            
            The failure to look for is not "too much" — it is **memory pollution**: a fact
            that used to be true, is still retrievable, and is now quietly wrong. The two
            worst examples on record were both durability failures rather than retrieval
            ones: a curated file that still named a retired account months after everything
            had moved.
            
            For each problem, one line: the file, what is wrong, and what should replace it.
            
            - Anything with a `verified:` date more than 30 days old that is about an
              account, a credential, a path or a URL.
            - Two files saying the same thing.
            - Two files contradicting each other.
            - Anything with an `expires:` date in the past.
            - Anything that is a rule about your own behaviour. Those belong in your
              instructions, because memory is not always loaded — which is the whole point
              of memory not being always loaded.
            
            ## Do not
            
            - **Do not edit or delete anything.** You are running unattended and you have no
              write access at all in this run. Report; the person or a later conversation
              does the pruning. A routine that claimed to prune and could not is worse than
              one that reports, because they would stop checking.
            - Do not report a memory simply for being old. Age is not the problem;
              being wrong is.
            - If nothing is wrong, say so in one line and stop.
            """#),
        BackendRoutinesDefault(id: "quality-gate", name: "Check the work before it counts as done",
            triggers: ["session-finished"], enabled: false,
            overlap: "queue", quietFor: "2m", maxRunsPerHour: 6,
            expectEvery: nil, why: "Off by default: it starts a session, and a session costs money. Turn it on when you are running agents unattended.",
            prompt: #"""
            A session in this folder finished. Find out whether its work actually holds.
            
            Call sessions_result for it. If it changed nothing on disk, say so in one line and
            stop — there is nothing to check.
            
            If it did change files:
            
            1. Call git_diff and read what changed.
            2. Read the project's own gate — its package.json scripts, its agent
               instructions file — and work out what "it passes" means here. For this
               repository that is
               `npm run typecheck` and `npm test`.
            3. Start a session with sessions_start to run that gate, with a brief that says
               exactly which command to run, that it must report the output verbatim, and
               that it must change nothing.
            
            Then report: what the session claimed, what the diff shows, and that the gate is
            running. Do not wait for it.
            
            ## Do not
            
            - Do not trust "it says the tests pass". This whole routine exists because two
              bugs in this repository shipped clean typechecks.
            - Do not start a gate session if one is already running in this folder — the
              start will be refused for that reason and the refusal is correct.
            - Do not fix anything yourself. You have no write access.
            """#),
        BackendRoutinesDefault(id: "ai-marker", name: "Pick up TODO(deck) markers",
            triggers: ["file-change **/*.{ts,tsx,js,jsx,py,go,rs,rb,java,swift,kt}"], enabled: false,
            overlap: "skip", quietFor: "2m", maxRunsPerHour: 4,
            expectEvery: nil, why: "Off by default: it starts sessions. The most developer-specific trigger there is — you write the request where the work is.",
            prompt: #"""
            A source file in this folder changed. Look for a request written into the code.
            
            Read the file that changed and look for a marker comment: `TODO(deck):`,
            `AI!` or `AI?` at the end of a line. That is somebody asking for work without
            leaving their editor, and the surrounding code is the context.
            
            If there is no marker, reply with nothing to report. That will be almost every
            time this fires, and that is correct.
            
            If there is one:
            
            1. Read enough of the file around it to understand what is being asked.
            2. Write a proper brief — the repo, the file and line, what to change, what
               counts as done, what not to touch — and start a session with it using
               sessions_start's `brief` argument.
            3. Say in one line which marker you picked up and which session you started.
            
            ## Do not
            
            - Do not start more than one session for one marker. If a session is already
              running in this folder the start will be refused, and that refusal is correct.
            - Do not act on a marker inside a comment that is *about* markers — this file's
              own text, documentation, a test fixture.
            - Do not remove the marker. You have no write access, and the session you start
              is the one that should clear it.
            """#)
    ]

    public static func seedMarkerPath(directory: URL) -> URL { directory.appendingPathComponent(".seeded") }

    public static func chooseSeedFolder(projects: [String], stateRoot: String, separator: String = "/") -> String? {
        projects.first { $0 != stateRoot && !$0.hasPrefix(stateRoot + separator) }
    }

    /// The store's writer is supplied so format, permissions and confinement have one owner.
    public static func seed(directory: URL, folder: String?,
                            existing: () throws -> [String],
                            write: (String, String) throws -> Void) throws -> BackendRoutinesSeedResult {
        guard let folder else {
            return .init(written: [], skipped: "No project folder to point a routine at yet.")
        }
        let marker = seedMarkerPath(directory: directory)
        var offered = Set<String>()
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            offered = Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") })
        }
        let onDisk = Set(try existing())
        var written: [String] = []
        for entry in routines where !offered.contains(entry.id) && !onDisk.contains(entry.id) {
            try write(entry.id, entry.file(folder: folder))
            written.append(entry.id); offered.insert(entry.id)
        }
        if !written.isEmpty {
            let body = (["# Routines Terminal Deck has already offered you, one per line.",
                         "# Delete a line to be offered that routine again on the next launch.",
                         "# Deleting a routine file does NOT bring it back — that is the point of this file."]
                        + offered.sorted() + [""]).joined(separator: "\n")
            // Source intentionally tolerates an unwritable marker at startup.
            if let bytes = body.data(using: .utf8) {
                let descriptor = marker.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
                if descriptor >= 0 {
                    defer { Darwin.close(descriptor) }
                    bytes.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            if count <= 0 { break }
                            offset += count
                        }
                    }
                }
            }
        }
        return .init(written: written, skipped: nil)
    }
}
