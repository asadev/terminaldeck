/**
 * The three things a session's bar says on a Mac, on the phone — and the
 * conversation behind it.
 *
 * A port of `pwa/src/session-bar.ts` and `pwa/src/chat-view.ts` onto the wire
 * types this app already speaks. Nothing here is new protocol: `usage`,
 * `account` and `chat` have been in `src/main/remote/protocol.ts` and answered
 * by every desktop since 2026-08-18. Two clients were asking; this one was not,
 * which is why *"the phone gained a usage ring, a context bar, the account and
 * a chat view"* was true of the browser page and false of the app on his phone.
 *
 * ## Why the reading is narrowed here rather than carried
 *
 * `usage.reading` carries the far machine's **own** record — an open
 * `Record<string, unknown>` — because the client that shape was designed for is
 * another copy of the desktop, whose readers are already total over it. This
 * app is not that client, so the two figures it draws are lifted field by field
 * and anything unreadable answers nil. A figure this build does not understand
 * is a chip that is **not drawn**, never a chip drawn with a guess.
 *
 * That also keeps `ServerMessage` `Equatable`: a `[String: Any]` on the enum
 * would not be, and every test in this app compares decoded frames by value.
 */

import Foundation

/**
 * Which reading is being asked for.
 *
 * The three are not interchangeable and the cost is why they are three:
 * `context` is a transcript read on the far side (milliseconds, so it may ride
 * the same events the terminal does), `plan` is memory the desktop already
 * holds, and `refresh` boots a whole Claude Code over there — which is why it
 * is only ever sent because a finger pressed the ring.
 */
enum UsageWant: String, Equatable, CaseIterable {
    case plan
    case refresh
    case context
}

/**
 * The two fractions a bar draws, lifted out of whatever the far end sent.
 *
 * Both optional and both meaning the same thing when absent: *there is no
 * figure*, which draws nothing. `emptyUsageReading` on the desktop composes a
 * report whose every window is `not-reported` precisely so that "nothing to
 * report" cannot be mistaken for zero, and this keeps that distinction: a
 * report with no readable window answers nil, not 0.
 */
struct UsageFigures: Equatable {
    /// The **highest** plan window in the report, 0…1. See {@link plan}.
    let plan: Double?
    /// How full this session's context window is, 0…1.
    let context: Double?

    static let none = UsageFigures(plan: nil, context: nil)
}

/**
 * One login on the far machine, as the chip draws it.
 *
 * `provider` is a bare agent id — `claude`, `codex`, `gemini` — and is
 * deliberately not an enum: this app is shipped against desktops that may have
 * grown an agent it has never heard of, and a closed set would turn a new agent
 * into a dropped account rather than into a row it cannot switch to.
 *
 * `color` is a **custom property name** (`--accent`), never a colour value, so
 * the palette stays in one place and a machine on the other end of a socket
 * cannot paint anything on this screen. `Palette.accountTint` is the only
 * reader, and it matches against a known table rather than interpolating.
 */
struct WireAccount: Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String?
    let color: String?
    /// The machine's own install — the login every fallback ends on.
    let system: Bool
}

/**
 * Is this a login of a *different* agent than the session is running?
 *
 * A port of `foreignAccount` in `pwa/src/session-bar.ts`, and it exists because
 * the far side already refuses the switch: `session-switch.ts` answers with a
 * sentence and stops, and nothing on this bar draws sentences. A row that could
 * be pressed and could only ever do nothing is worse than a row that cannot.
 *
 * Both providers have to be *known* before two of them can be said to differ. A
 * row whose own provider is nil stays pressable rather than being dimmed
 * because an older machine did not name its agent.
 */
func foreignAccount(current: WireAccount?, account: WireAccount) -> Bool {
    guard let current, let mine = current.provider, let theirs = account.provider else { return false }
    return mine != theirs
}

// MARK: - Narrowing

/**
 * Lifting the two figures, and the account rows, out of records this app does
 * not own.
 *
 * On `WireCodec` because that is this app's one door for inbound text, and the
 * rule it exists to keep is that nothing outside it ever touches a raw
 * `[String: Any]`. Every shape below was taken from a real frame off a running
 * desktop rather than from the desktop's types, since the types are the half
 * that is allowed to grow.
 */
extension WireCodec {

    /// A fraction in 0…1, or nil. Bounded rather than trusted: a bar drawn from
    /// 3.4 is a bar that leaves its own frame, which is the defect he filmed on
    /// the desktop one element down.
    static func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // `NSNumber` is what `JSONSerialization` hands back for every JSON
        // number *and* for `true`/`false`. A boolean read as 1.0 would draw a
        // full ring out of a flag.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite else { return nil }
        return Swift.min(1, Swift.max(0, raw))
    }

    /**
     * The highest plan window a report carries, as a fraction.
     *
     * The highest rather than a chosen one: a person is limited by whichever
     * window they are nearest the end of, and picking "the five-hour one" would
     * draw a calm ring while the weekly window is what actually stops them
     * working. A ring is one number, so it is the worst one.
     *
     * `used` is a union on the wire — `{state:'reported', fraction}` or
     * `{state:'not-reported'}` — precisely so nothing can `?? 0` its way past
     * the difference, and that is kept: a report whose every window is
     * unreported answers nil, which draws no ring rather than an empty one that
     * reads as *"you have used nothing"*.
     */
    static func planFraction(_ reading: Any?) -> Double? {
        guard let record = reading as? [String: Any],
              let rows = record["readings"] as? [Any] else { return nil }
        var worst: Double?
        for row in rows {
            guard let entry = row as? [String: Any],
                  let used = entry["used"] as? [String: Any],
                  used["state"] as? String == "reported",
                  let value = fraction(used["fraction"]) else { continue }
            if let held = worst, value <= held { continue }
            worst = value
        }
        return worst
    }

    /**
     * How full the context window is, as a fraction.
     *
     * `percent` on the far end's record is 0…100 — `readContextWindow` writes a
     * percentage — so it is divided here and nowhere else. `state` is what says
     * whether there is a figure at all: anything but a live reading answers nil
     * and the bar is not drawn.
     */
    static func contextFraction(_ reading: Any?) -> Double? {
        guard let record = reading as? [String: Any] else { return nil }
        guard record["state"] as? String != "not-reported" else { return nil }
        guard let number = record["percent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return Swift.min(1, Swift.max(0, number.doubleValue / 100))
    }

    /**
     * The figures in one answer, whichever question was asked.
     *
     * A `refresh` answers with the outcome *and* the report; a `plan` answers
     * with the report alone. One reader, because the figure lives in the same
     * place in both and inventing a second path is how the two come apart.
     */
    static func usageFigures(want: UsageWant, reading: Any?) -> UsageFigures {
        switch want {
        case .context:
            return UsageFigures(plan: nil, context: contextFraction(reading))
        case .plan:
            return UsageFigures(plan: planFraction(reading), context: nil)
        case .refresh:
            let report = (reading as? [String: Any])?["report"] ?? reading
            return UsageFigures(plan: planFraction(report), context: nil)
        }
    }

    /// One account row, or nil. A malformed row is dropped rather than taking
    /// the list with it — the same rule a session row follows.
    static func account(_ value: Any?) -> WireAccount? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let name = displayLine(row["name"]) else { return nil }
        return WireAccount(id: id,
                           name: name,
                           provider: string(row["provider"]),
                           // Checked against the shape a custom property has
                           // rather than carried as free text: this string
                           // arrives from another machine and its only use is
                           // to pick a colour out of a table on this side.
                           color: customProperty(string(row["color"])),
                           system: row["system"] as? Bool == true)
    }

    static func accounts(_ value: Any?) -> [WireAccount] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { account($0) }
    }

    /// `--accent`, and nothing that is not one.
    static func customProperty(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("--"), raw.count <= 42 else { return nil }
        let body = raw.dropFirst(2)
        guard !body.isEmpty else { return nil }
        return body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } ? raw : nil
    }
}
