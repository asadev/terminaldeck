/**
 * The routines card, as this client reads it.
 *
 * A port of the `routines` / `routine.*` family in
 * `src/main/remote/protocol.ts`, and of the half of `RoutineView`
 * (`src/main/routines/engine.ts`) that the desktop's own Routines card draws.
 * Nothing here reimplements a routine: the machine owns the folder, the
 * scheduler and the budgets, and this file is only the narrowing that turns its
 * answers into something a phone can put on a screen.
 *
 * It exists because he looked at the phone's copilot screen next to the Mac's
 * and found one of them nearly empty:
 *
 * > *"the main co-pilot settings page is going around in circles: edit button,
 * > run now, delete and toggle thing. If you go to Mac side there is … 'check
 * > the work before it counts as done', 'what happened overnight' … all of these
 * > are like separate settings for co-pilot … Mac has a lot of things about
 * > copilot by the way."*
 *
 * Those names are routines — one file each, in the machine's own routines
 * folder — and this is what brings them across.
 *
 * ## Read, run, hold, delete. Not write.
 *
 * There is no verb on this wire that writes a routine file and this file must
 * not grow one. `routines/ipc.ts` on the desktop marks `saveText` **`human`**
 * rather than giving it a permission tier, because writing chosen bytes into the
 * routines folder is wider than the alter-tier `update` that goes through the
 * header guard — and that folder was moved out of the copilot's reach for
 * exactly that shape of hole. A window is a person; a frame is not. So a routine
 * arrives here as text to read, `RoutineFile.readOnlyBecause` carries the
 * machine's own sentence saying why there is no Save, and a screen draws that
 * sentence rather than a disabled button with no explanation. It is the same
 * position `WireCapability.files` takes about every other file on the machine,
 * for the same reason.
 *
 * ## Two rules the decoding keeps
 *
 *  1. **One malformed row must not discard the list.** The rule `WireCodec`
 *     already follows for a session list: eleven of twelve routines is useful,
 *     none because the twelfth had no id is not.
 *  2. **A state this build has never heard of is drawn as it stands.** Every one
 *     of the seven draws something different and there is no honest default
 *     among them — `disabled` and `paused` have different remedies, `unarmed`
 *     and `stale` are the two halves of *this looks quiet and is actually
 *     broken* — so an eighth word is carried through rather than folded into a
 *     neighbour that would be a confident lie.
 *
 * Kept free of SwiftUI so the whole wire layer stays testable without a
 * simulator, like every other file in this folder.
 */

import Foundation

/// Bounds and names this client applies to the routines capability.
enum RoutinesWire {
    /// The capability, named beside the model it belongs to — the way
    /// `MachineBrowserWire.capability` is, and aliased from `WireCapability`.
    ///
    /// A host advertises it only when it holds a routine engine, and only to one
    /// of its owner's own devices: a routine is a prompt that machine runs with
    /// that machine's tools in that machine's folders, so it goes where the
    /// copilot goes and *"the copilot is never shared"* covers it.
    static let capability = "routines"

    /// The most rows this client will draw off one `routines.rows`. The host caps
    /// itself at the same number, and a cap only the other end enforces is not a
    /// cap.
    static let maxRoutineRows = 100

    /// The most characters of a routine file this client will hold. The host
    /// sends at most this and says when it cut; this is the backstop.
    static let maxTextChars = 12 * 1024

    /// The longest reason this client will send with a hold. The desktop's
    /// `RoutineApi.pause` clamps to the same number.
    static let maxPauseReason = 300
}

// MARK: - What state a routine is in

/**
 * One routine's state, as one word.
 *
 * A closed list of the seven the engine reports, plus `other` for a word a newer
 * machine invents. `other` is the decision this enum exists to record: the
 * alternative is mapping an unknown state onto `unarmed`, which would draw
 * *nothing is listening* under a routine that is doing something else — and the
 * whole point of the state model on the far side is that *quiet* and *broken*
 * must never look the same.
 */
enum RoutineState: Equatable, Hashable {
    /// Armed and waiting for its trigger. The state a healthy routine sits in.
    case armed
    /// A run is going right now.
    case running
    /// Turned off in its own file — `enabled: no`, a line somebody typed.
    case disabled
    /// Its file did not parse. There is no prompt and no trigger to run.
    case broken
    /// Nothing is listening: a folder that is gone, a trigger with no emitter
    /// wired in this build, a copilot that is not running.
    case unarmed
    /// Held by the engine rather than by its file — a budget spent, five
    /// failures in a row, or somebody pressing the switch.
    case paused
    /// It said how long its silences are allowed to be, and it has been quiet
    /// longer than that. The one derived state, and the useful one.
    case stale
    /// A word this build has never heard of, kept as it came.
    case other(String)

    init(wire: String) {
        switch wire {
        case "armed": self = .armed
        case "running": self = .running
        case "disabled": self = .disabled
        case "broken": self = .broken
        case "unarmed": self = .unarmed
        case "paused": self = .paused
        case "stale": self = .stale
        default: self = .other(wire)
        }
    }

    /// The word as the machine sent it. Never shown on its own — see `badge`.
    var word: String {
        switch self {
        case .armed: return "armed"
        case .running: return "running"
        case .disabled: return "disabled"
        case .broken: return "broken"
        case .unarmed: return "unarmed"
        case .paused: return "paused"
        case .stale: return "stale"
        case let .other(raw): return raw
        }
    }

    /**
     * What the badge on the row says.
     *
     * Deliberately the same seven phrases `ROUTINE_STATE_TEXT` uses in
     * `CopilotSection.tsx`, so a routine reads the same on the phone as it does
     * on the machine it runs on. Two screens describing one routine in two
     * vocabularies is how somebody comes to believe they are looking at two
     * different things.
     */
    var badge: String {
        switch self {
        case .armed: return "armed"
        case .running: return "running now"
        case .disabled: return "off in its own file"
        case .broken: return "broken"
        case .unarmed: return "nothing is listening"
        case .paused: return "paused"
        case .stale: return "stale"
        case let .other(raw): return raw
        }
    }
}

// MARK: - One routine

/**
 * One routine, as a row.
 *
 * Identified by `id`, which is the name of its file without the extension and
 * the only thing this client ever sends back. Everything else on here is drawn
 * and nothing else is echoed — so a name, a purpose or a reason that arrived
 * mangled becomes an ugly row rather than a frame naming the wrong routine.
 *
 * `armed`, `canRun`, `runBecause`, `canArm` and `armBecause` are **the host's**
 * answers, not this client's. Deriving *is this switch on* from a state name and
 * two booleans is exactly the kind of rule that ends up written twice and
 * disagreeing, and the disagreement that matters is the one where a routine
 * looks armed on a phone and is not.
 */
struct RoutineRow: Equatable, Identifiable, Hashable {
    let id: String
    /// Cleaned for display. Falls back to the id when the file names nothing.
    let name: String
    /// The first line of its prompt — what it is for, in its own words.
    let purpose: String
    /// The `when:` lines as the machine serialised them, joined. Empty when the
    /// routine has no trigger, which a row draws as *no trigger*.
    let schedule: String
    /// The folder it watches and runs in. Nil when it names none.
    let folder: String?
    let state: RoutineState
    /// Its file's own `enabled:` line. Not the switch — that is `armed`.
    let enabled: Bool
    let paused: Bool
    /// Whether the switch on this row reads as on.
    let armed: Bool
    /// The engine's one sentence saying why the state is what it is.
    let reason: String?
    /// What the parser could not read, when it could not.
    let problems: [String]
    /// When it last **finished**. The outcome beside it belongs to that run.
    let lastRunAt: Date?
    let lastOutcome: RoutineOutcome?
    let lastError: String?
    let nextDueAt: Date?
    /// When a held routine comes back on its own. Nil when a person has to act.
    let pausedUntil: Date?
    /// Times a schedule came due while the machine's app was not running.
    let missedWhileClosed: Int
    let consecutiveFailures: Int
    /// Calls its runs were not allowed to make — nearly always an alter-tier
    /// tool refused because nobody was at the machine, which is the boundary
    /// working and the only answer to *it ran and nothing happened*.
    let refusedCalls: Int
    let canRun: Bool
    /// Why Run now is not offered, when it is not.
    let runBecause: String?
    let canArm: Bool
    /// Why the switch cannot be moved, when it cannot.
    let armBecause: String?

    /**
     * The routine the engine stopped after it kept failing.
     *
     * The one case the desktop card calls out above everything else about a
     * routine, and worth carrying here rather than leaving each screen to
     * rediscover: a routine that was switched off by its own failures and one
     * that simply has not been triggered lately look identical in any list
     * showing a name and a last-run time, and only the first is something
     * somebody has to act on.
     */
    var stoppedByFailures: Bool { state == .paused && consecutiveFailures > 0 }
}

/// How a routine's last run ended. Absent when it has never run, or when the
/// machine could not say — three answers, and a row draws all three differently.
enum RoutineOutcome: String, Equatable, Hashable {
    case ok
    case failed
}

/**
 * One routine's file, to read.
 *
 * `file` is the file's bare name and never its path, which is the rule this app
 * applied to every panel on 2026-08-17: a person looking at a trigger is not
 * asking where on the disk it lives.
 *
 * `readOnlyBecause` is the machine's own sentence and it is **not** optional,
 * because the absence of a Save button is the thing somebody asks about. A
 * screen draws it where the desktop draws its editor's Save. See this file's
 * header for the argument behind it.
 *
 * `problem` is set when the file could not be read at all — deleted between the
 * list and the tap, or refused by the disk. The frame arrives either way, so a
 * screen never spins over a machine that answered instantly.
 */
struct RoutineFile: Equatable, Hashable, Identifiable {
    let id: String
    let file: String
    let text: String
    /// True when the file was longer than one frame carries. A screen says so
    /// rather than showing a file that silently stops.
    let truncated: Bool
    let readOnlyBecause: String
    let problem: String?
}

// MARK: - Narrowing

extension WireCodec {
    /**
     * Every routine off one `routines.rows`.
     *
     * Never fails: a machine with no routines is an answer, not a malformed
     * frame, and one bad row is dropped rather than discarding the list. A row
     * with no `id` **is** dropped — it is the identity, the key a row is replaced
     * under and the only thing that goes back on the wire, so a row without one
     * could only ever be filed under a guess.
     */
    static func routineRows(_ object: [String: Any]) -> [RoutineRow] {
        (object["routines"] as? [Any] ?? []).prefix(RoutinesWire.maxRoutineRows).compactMap { routineRow($0) }
    }

    /// One row, or nil. Exposed for the tests, which check the field rules
    /// directly rather than through a whole frame.
    static func routineRow(_ raw: Any?) -> RoutineRow? {
        guard let row = raw as? [String: Any],
              let id = string(row["id"]), !id.isEmpty else { return nil }
        let outcome = string(row["lastOutcome"]).flatMap { RoutineOutcome(rawValue: $0) }
        return RoutineRow(
            id: id,
            // Falls back to the id rather than to an empty label. A row with no
            // name is a row nobody can tell from the one below it.
            name: displayLine(row["name"]) ?? id,
            purpose: displayLine(row["purpose"]) ?? "",
            schedule: displayLine(row["schedule"]) ?? "",
            folder: displayLine(row["folder"]),
            state: RoutineState(wire: string(row["state"]) ?? "unarmed"),
            enabled: row["enabled"] as? Bool ?? false,
            paused: row["paused"] as? Bool ?? false,
            // Defaulted to **on**, so a host too old to send the field draws a
            // switch that can be pressed rather than one stuck off with no
            // explanation. The host refuses the frame if it disagrees.
            armed: row["armed"] as? Bool ?? true,
            reason: displayLine(row["reason"]),
            problems: (row["problems"] as? [Any] ?? []).compactMap { displayLine($0) },
            lastRunAt: routineDate(row["lastRunAt"]),
            lastOutcome: outcome,
            lastError: displayLine(row["lastError"]),
            nextDueAt: routineDate(row["nextDueAt"]),
            pausedUntil: routineDate(row["pausedUntil"]),
            missedWhileClosed: whole(row["missedWhileClosed"]) ?? 0,
            consecutiveFailures: whole(row["consecutiveFailures"]) ?? 0,
            refusedCalls: whole(row["refusedCalls"]) ?? 0,
            /*
             * Defaulted to **true**, and the pair below to nil.
             *
             * The same argument as `armed`: a host that did not send the field
             * gets a button that can be pressed and a refusal it will explain
             * itself, rather than a control greyed out with nothing beside it.
             * A dead control that opens onto no reason is the failure this app
             * has been reviewed for by name.
             */
            canRun: row["canRun"] as? Bool ?? true,
            runBecause: displayLine(row["runBecause"]),
            canArm: row["canArm"] as? Bool ?? true,
            armBecause: displayLine(row["armBecause"])
        )
    }

    /**
     * One routine's file off a `routine.text.rows`.
     *
     * Refuses only when there is no `id`, for the reason a row does: it is what
     * says *which* routine this text belongs to, and two taps two seconds apart
     * must not draw the second answer under the first heading.
     *
     * The text itself is **not** put through `displayLine`. That helper flattens
     * to one line and strips the newlines with everything else, and the whole
     * value of showing somebody the file is that it is laid out the way they
     * wrote it — the machine has already taken out everything that could rewrite
     * a line and left the newlines and tabs alone. It is bounded here anyway,
     * because a cap only the other end enforces is not a cap.
     */
    static func routineFile(_ object: [String: Any]) -> RoutineFile? {
        guard let id = string(object["id"]), !id.isEmpty else { return nil }
        let raw = string(object["text"]) ?? ""
        let overLong = raw.count > RoutinesWire.maxTextChars
        return RoutineFile(
            id: id,
            file: displayLine(object["file"]) ?? "",
            text: overLong ? String(raw.prefix(RoutinesWire.maxTextChars)) : raw,
            // Either end may have been the one that cut it.
            truncated: (object["truncated"] as? Bool ?? false) || overLong,
            /*
             * Falls back to a sentence of this client's own, and only ever as a
             * backstop.
             *
             * The field is required on the wire precisely so that this line is
             * unreachable against any host that speaks the capability. It is
             * here because the alternative — an empty string — would draw a
             * read-only editor with nothing at all saying why, which is the one
             * outcome the field exists to prevent.
             */
            readOnlyBecause: displayLine(object["readOnlyBecause"])
                ?? "Routines are written where they run. This is the file as it stands there.",
            problem: displayLine(object["problem"])
        )
    }

    /// A moment the machine sent as milliseconds since the epoch, or nil.
    ///
    /// Nil rather than the epoch for anything that is not a number, because
    /// *never run* and *run in 1970* are two different rows and only one of them
    /// is true.
    private static func routineDate(_ value: Any?) -> Date? {
        guard let millis = (value as? NSNumber)?.doubleValue, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
