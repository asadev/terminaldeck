/**
 * The session's control cluster on the wire — model, effort, fast mode,
 * permission — and the narrowing that turns a `controls.reading` into it.
 *
 * A port of the reading half of `src/main/remote/protocol.ts` (`ControlName`,
 * `ControlReadingWire`, `ControlsReadingWire`) onto the types this app speaks,
 * and the client of it is `SessionControlsLink`, a port of
 * `pwa/src/session-controls.ts`. Nothing here is new protocol: `controls.read`
 * and `controls.apply` have been answered by every desktop since 0.5.0 — the
 * desktop's own remote window already sends them — and this client simply never
 * did, which is why a phone could watch a session and not once change what it
 * runs at.
 *
 * ## Why the reading is narrowed here rather than carried
 *
 * The `ControlsReadingWire` the desktop composes is total over its own shapes
 * because the client it was designed for is another copy of the desktop. This
 * app is not that client, so each field is lifted with the same leniency
 * `SessionWire.swift` gives a usage figure: a reading this build cannot make
 * sense of answers a blank reading, never a guess, and one malformed sub-object
 * does not discard the whole cluster. Keeping it in real structs rather than a
 * `[String: Any]` is also what keeps `ServerMessage` `Equatable`, which every
 * decode test in this app relies on.
 */

import Foundation

/// The four controls, named on the wire. A frozen set for the reason the
/// desktop's `CONTROL_IDS` is: the value selects a branch that types into
/// somebody's terminal, and a name nothing recognises is refused at the parser.
enum ControlName: String, Equatable, CaseIterable {
    case model
    case effort
    case fast
    case permission
}

/// The longest a control's value may be. A model name is the long one.
let maxControlValueLength = 64

/**
 * One control's current reading, as the far machine read it.
 *
 * `value` and `label` are null together when nothing real could be read.
 * `source` is dropped on this side rather than narrowed — a build newer or older
 * than this one may name a source it has no word for, and nothing on a phone
 * prints source notes, so the honest translation is to drop it rather than guess
 * (the same call `asCatalogReading` in `pwa/src/session-controls.ts` makes).
 * `unavailableReason` travels because the whole value of it is the wording.
 */
struct ControlReadingWire: Equatable {
    let value: String?
    let label: String?
    let unavailableReason: String?

    static let empty = ControlReadingWire(value: nil, label: nil, unavailableReason: nil)
}

/// Everything one session's control cluster needs, in one answer.
struct ControlsReadingWire: Equatable {
    let model: ControlReadingWire
    let effort: ControlReadingWire
    let fast: ControlReadingWire
    let permission: ControlReadingWire
    /// False when the far end had no such session, so nothing could be read.
    let live: Bool
    /// Whether an agent CLI is drawing that session's screen over there. A model
    /// menu over `/bin/zsh` is the defect the desktop's own cluster withdraws
    /// itself for, so this app draws nothing when it is false.
    let agentRunning: Bool
    /// Whether a command could be typed at that session this instant, and the
    /// far end's sentence for why not. What lets a remote chip grey out for the
    /// same reasons a local one does.
    let canType: Bool
    let gateReason: String?

    /// One field replaced by an apply's re-read — the row that ticks is the one
    /// the session is actually on. Mirrors `appliedTo` in the PWA.
    func applying(_ control: ControlName, _ answer: ControlReadingWire) -> ControlsReadingWire {
        switch control {
        case .model: return ControlsReadingWire(model: answer, effort: effort, fast: fast, permission: permission, live: live, agentRunning: agentRunning, canType: canType, gateReason: gateReason)
        case .effort: return ControlsReadingWire(model: model, effort: answer, fast: fast, permission: permission, live: live, agentRunning: agentRunning, canType: canType, gateReason: gateReason)
        case .fast: return ControlsReadingWire(model: model, effort: effort, fast: answer, permission: permission, live: live, agentRunning: agentRunning, canType: canType, gateReason: gateReason)
        case .permission: return ControlsReadingWire(model: model, effort: effort, fast: fast, permission: answer, live: live, agentRunning: agentRunning, canType: canType, gateReason: gateReason)
        }
    }

    /// One control's reading, by name — so a caller can loop over `ControlName`.
    func reading(_ control: ControlName) -> ControlReadingWire {
        switch control {
        case .model: return model
        case .effort: return effort
        case .fast: return fast
        case .permission: return permission
        }
    }
}

// MARK: - Narrowing

extension WireCodec {
    /**
     * One control's reading off the wire, always a value — a missing or
     * malformed sub-object narrows to `.empty`, which draws the unread label
     * rather than refusing the frame. Mirrors `parseReading` in `protocol.ts`,
     * dropping the `source` field this client has no use for.
     */
    static func controlReading(_ value: Any?) -> ControlReadingWire {
        guard let row = value as? [String: Any] else { return .empty }
        let val = string(row["value"]).map { String($0.prefix(maxControlValueLength)) }
        let label = displayLine(row["label"])
        let reason = displayLine(row["unavailableReason"])
        return ControlReadingWire(value: val, label: label, unavailableReason: reason)
    }

    /// The whole cluster off a `controls.reading`. Every field is read
    /// defensively: an absent `gate`, `agent` or `live` reads as the safe
    /// "nothing to draw" rather than failing the frame.
    static func controlsReading(_ value: Any?) -> ControlsReadingWire {
        let row = value as? [String: Any] ?? [:]
        let agent = row["agent"] as? [String: Any]
        let gate = row["gate"] as? [String: Any]
        return ControlsReadingWire(
            model: controlReading(row["model"]),
            effort: controlReading(row["effort"]),
            fast: controlReading(row["fast"]),
            permission: controlReading(row["permission"]),
            live: row["live"] as? Bool == true,
            agentRunning: (agent?["running"] as? Bool) == true,
            /*
             * Absent gate is read as "cannot type" — the safe reading, which
             * greys the chips rather than offering a press that would be
             * refused. `literalTrue` for the same reason one step further in:
             * this is the flag that decides whether this phone draws a composer
             * that can type into somebody's running session, and `as? Bool`
             * succeeds for `NSNumber(1)` through the ObjC bridge, so the lenient
             * spelling would open the composer on `{"canType":1}`. `live` and
             * `agentRunning` beside it stay lenient: they colour a chip and name
             * what is on screen, and a `1` there costs a badge at worst.
             */
            canType: literalTrue(gate?["canType"]),
            gateReason: displayLine(gate?["reason"]))
    }
}
