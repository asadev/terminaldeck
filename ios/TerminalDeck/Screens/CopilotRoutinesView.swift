/**
 * **The routines, on the phone** — the rows on the control screen, and the file
 * behind one.
 *
 * > *"the main co-pilot settings page is going around in circles: edit button,
 * > run now, delete and toggle thing. If you go to Mac side there is 'check the
 * > work before it counts as done', 'what happened overnight', all of these are
 * > like separate settings for co-pilot — 'weekly', 'look at what you remember',
 * > 'uncommitted work left behind', 'something is waiting on you', 'pick up
 * > to-do' … Mac has a lot of things about copilot by the way."*
 *
 * Every name in that sentence is a **routine** — one file each in the machine's
 * own routines folder, with a trigger, a folder and a prompt — and this is the
 * half of the Mac's Routines card that a phone can honestly carry.
 *
 * ## Nothing here is derived
 *
 * Whether the switch reads as on, whether Run now can be pressed, and the
 * sentence saying why when it cannot, all arrive already decided: `armed`,
 * `canRun`, `runBecause`, `canArm`, `armBecause`. `RoutinesWire` argues why at
 * length, and the short version is the failure it prevents — *a routine that
 * looks armed on a phone and is not*. So this file draws what came and works out
 * nothing about state on its own. The one thing it composes is **sentences from
 * facts the machine sent**: how long ago it last ran, when it is next due, how
 * many runs were refused. Those are readings, not rules.
 *
 * ## There is no Save, and that is the feature
 *
 * A routine's file is read-only from a phone by design: writing chosen bytes
 * into the routines folder is wider than the alter tier, and that folder was
 * deliberately moved out of the copilot's reach for exactly that shape of hole.
 * `RoutineFile.readOnlyBecause` is the machine's own sentence saying so, it is
 * required on the wire rather than optional, and this screen prints it where the
 * Mac draws its Save. A greyed-out Save with nothing beside it is the *"blocked
 * control that opens onto a paragraph"* he has already struck once.
 *
 * ## Delete, not Close
 *
 * The destructive verb is **Delete** here, on the Mac and on the web, because it
 * removes a file from somebody's disk. That is his standing correction from the
 * 2026-08-26 review, applied everywhere the same act is offered.
 */

import SwiftUI

/* -------------------------------------------------------------------------- */
/* The row, in the card on the control screen                                  */
/* -------------------------------------------------------------------------- */

/**
 * One routine: what it is, what it is doing, and the `…` that acts on it.
 *
 * The body is not tappable and carries no chevron. There is nothing a whole-row
 * tap could honestly mean here — the four verbs are four different acts and one
 * of them deletes a file — so the row is a reading with its controls gathered
 * behind the one glyph this app already uses for *more about this row*.
 */
struct CopilotRoutineRowBody: View {
    let routine: RoutineRow
    /// Greys the menu while the socket is down, on the graced reading rather
    /// than the live one — the rule `CopilotControlView.row` records: a control
    /// that dies the instant a socket blinks is the *"consistent connection"*
    /// complaint, and one still lit five seconds into a real outage cannot act.
    let dead: Bool
    let run: () -> Void
    let hold: () -> Void
    let arm: () -> Void
    let read: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(routine.name)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    badge
                }
                if !routine.purpose.isEmpty {
                    Text(routine.purpose)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(RoutineLines.schedule(routine))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RoutineLines.history(routine))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                // Keyed by position, not by the string. Two problems that read
                // the same are still two problems, and `id: \.self` would fold
                // them into one row — which is how a repeated parser complaint
                // quietly stops being reported.
                ForEach(Array(RoutineLines.alerts(routine).enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(RoutineLines.notes(routine).enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            menu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The state as one word, tinted by what it means.
    ///
    /// The colour is on the badge rather than on a rule down the side for the
    /// reason the Mac's card gives: a rule would indent every routine name away
    /// from the rows above it, and the house order is space, then a tint, then —
    /// only then — a line. The words are `RoutineState.badge`, which is the same
    /// seven phrases the Mac uses, so one routine reads the same in both places.
    private var badge: some View {
        Text(routine.state.badge)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(RoutineLines.tone(routine.state))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoutineLines.tone(routine.state).opacity(0.12), in: Capsule())
            .accessibilityIdentifier("copilot.routine.state.\(routine.id)")
    }

    /**
     * The four verbs.
     *
     * Run now and the switch are disabled from the machine's own booleans, and
     * the sentence saying why is printed **on the row** rather than hidden
     * behind the disabled item — a menu row cannot explain itself, and a control
     * that refuses with no reason anywhere is the defect this whole screen is
     * written against. `RoutineLines.notes` is where those two sentences come
     * from.
     */
    private var menu: some View {
        Menu {
            Button {
                run()
            } label: {
                Label("Run now", systemImage: "play.circle")
            }
            .disabled(!routine.canRun || dead)

            Button {
                if routine.armed { hold() } else { arm() }
            } label: {
                Label(routine.armed ? "Hold" : "Let it run",
                      systemImage: routine.armed ? "pause.circle" : "alarm")
            }
            .disabled(!routine.canArm || dead)

            Button {
                read()
            } label: {
                Label("Read", systemImage: "eye")
            }
            .disabled(dead)

            Button(role: .destructive) {
                remove()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(dead)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .opacity(dead ? 0.4 : 1)
        .accessibilityLabel("More about \(routine.name)")
        .accessibilityIdentifier("copilot.routine.more.\(routine.id)")
    }
}

/* -------------------------------------------------------------------------- */
/* The file, read                                                              */
/* -------------------------------------------------------------------------- */

/**
 * One routine's file, as it stands on the machine.
 *
 * Pushed rather than sheeted, for the reason the copilot's own file editor is: a
 * routine file is a trigger, a folder and up to eight kilobytes of prompt, which
 * is a screen's worth of text and not a card's.
 *
 * It scrolls in both directions and wraps nothing. A routine's front matter is
 * indented YAML and its prompt is Markdown a person wrote in an editor with
 * columns; folding a long line into eight phone-width rows destroys the
 * structure rather than presenting it. Same decision, same words, as
 * `FileTextView`.
 */
struct CopilotRoutineFileView: View {
    let model: DeckModel
    let hostID: String
    let routine: RoutineRow

    private var link: CopilotLink? { model.host(hostID)?.copilot }

    /// The answer, but only when it is **this** routine's. A file that arrives
    /// for one somebody has navigated away from would otherwise be drawn under
    /// this heading, which is the whole reason the id travels on the frame.
    private var file: RoutineFile? {
        guard let file = link?.routineFile, file.id == routine.id else { return nil }
        return file
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if let file {
                    if let problem = file.problem {
                        // The file was there in the list and is not on the disk,
                        // or the disk refused it. The frame arrives either way,
                        // so this screen says what happened instead of spinning
                        // over a machine that answered instantly.
                        Text(problem)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.critical)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .accessibilityIdentifier("copilot.routine.file.problem")
                        Spacer(minLength: 0)
                    } else {
                        fileBody(file)
                    }
                    foot(file)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { link?.openRoutine(routine.id) }
        .onDisappear { link?.closeRoutine() }
    }

    /// The file's own bare name once the machine has sent it, and the routine's
    /// name until then. Never a path: a person looking at a trigger is not
    /// asking where on the disk it lives, which is the rule this app applied to
    /// every panel on 2026-08-17 and the reason no path crosses at all.
    private var title: String {
        guard let name = file?.file, !name.isEmpty else { return routine.name }
        return name
    }

    private func fileBody(_ file: RoutineFile) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(file.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .accessibilityIdentifier("copilot.routine.file.body")
        }
    }

    /// What the machine said about the file, under it. `readOnlyBecause` is not
    /// optional on the wire precisely so that this line is always there: the
    /// absence of a Save is the thing somebody asks about, and an empty string
    /// would leave a read-only screen with nothing at all saying why.
    private func foot(_ file: RoutineFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if file.truncated {
                Text("This is the front of the file — the rest was more than one message carries. "
                     + "Open it on the machine to see all of it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .accessibilityIdentifier("copilot.routine.file.truncated")
            }
            Text(file.readOnlyBecause)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, file.truncated ? 0 : 10)
                .padding(.bottom, 14)
                .accessibilityIdentifier("copilot.routine.file.readonly")
        }
    }
}

/* -------------------------------------------------------------------------- */
/* The sentences, with no view in them                                         */
/* -------------------------------------------------------------------------- */

/**
 * What a routine's row says, composed from what the machine sent and from
 * nothing else.
 *
 * Pure and separately callable for the reason `CopilotControl` is: every way one
 * of these can be wrong is silent, and most of them need a machine with a
 * routine engine, a failed run and a clock in the right place to be visible at
 * all. `now` is a parameter throughout so the boundaries can be checked without
 * waiting for one.
 */
enum RoutineLines {

    /// The trigger words, and the folder it watches. *"no trigger"* is the Mac's
    /// own phrase for a routine with none, which is a real and worrying state —
    /// a prompt nothing will ever fire.
    static func schedule(_ routine: RoutineRow) -> String {
        let when = routine.schedule.isEmpty ? "no trigger" : routine.schedule
        guard let folder = routine.folder, !folder.isEmpty else { return when }
        return "\(when) — in \(folder)"
    }

    /**
     * When it last ran, how that ended, and when it is next due.
     *
     * The outcome belongs to the run that **finished** — a run still in flight is
     * `state: .running`, which the badge already says — so a routine with no
     * `lastRunAt` reads *it has never run* rather than borrowing a time from
     * anywhere else.
     */
    static func history(_ routine: RoutineRow, now: Date = Date()) -> String {
        var sentence: String
        if let at = routine.lastRunAt {
            let ago = SessionDetails.activityLine(at.timeIntervalSince1970 * 1000, now: now)
                ?? "some time ago"
            sentence = "Last run \(ago) — \(outcome(routine))."
        } else {
            sentence = "It has never run."
        }
        if let due = routine.nextDueAt {
            sentence += " Next due \(until(due, now: now))."
        }
        if routine.missedWhileClosed > 0 {
            sentence += " \(routine.missedWhileClosed) due while the app was closed."
        }
        return sentence
    }

    /// How the last run ended — three answers, because *failed*, *finished* and
    /// *the machine could not say* are three different things and only one of
    /// them is somebody's problem.
    private static func outcome(_ routine: RoutineRow) -> String {
        switch routine.lastOutcome {
        case .ok: return "finished"
        case .failed:
            guard let error = routine.lastError, !error.isEmpty else { return "failed" }
            return "failed: \(error)"
        case nil: return "outcome unknown"
        }
    }

    /**
     * The lines worth alarm: a routine the engine stopped, a file that did not
     * parse, and whatever the parser could not read.
     *
     * The first is the one the Mac's card calls out above everything else, and
     * it earns that: a routine switched off by its own failures and one that has
     * simply not been triggered lately look identical in any list showing a name
     * and a time, and only the first is something somebody has to act on.
     */
    static func alerts(_ routine: RoutineRow, now: Date = Date()) -> [String] {
        var lines: [String] = []
        if routine.stoppedByFailures {
            let why = routine.reason
                ?? "Stopped after \(routine.consecutiveFailures) failures in a row."
            let next = routine.pausedUntil.map { "It comes back on its own \(until($0, now: now))." }
                ?? "It will not run again until you let it run."
            lines.append("\(why) \(next)")
        } else if routine.state == .broken, let why = routine.reason {
            lines.append(why)
        }
        lines.append(contentsOf: routine.problems)
        return lines
    }

    /**
     * The lines worth saying and not worth alarm — including the two that
     * explain a control the machine has switched off.
     *
     * They are drawn beside the still-usable `…` rather than inside it, because
     * a disabled menu row cannot carry a reason and *"a blocked control that
     * opens onto a paragraph is a description"*. The Mac prints the same two in
     * the same place, and keeps them apart for the same reason: a switch that
     * cannot move and a Run that cannot start have different causes — one is the
     * file's own `enabled:` line, the other is the engine — and one sentence
     * covering both would be a guess about which.
     */
    static func notes(_ routine: RoutineRow) -> [String] {
        var lines: [String] = []
        // The reason, once. `disabled` and `broken` are excluded because their
        // sentence is already on screen: the first is repeated by `armBecause`
        // with what to do about it, and the second is an alert above.
        if !routine.stoppedByFailures,
           routine.state != .disabled,
           routine.state != .broken,
           let why = routine.reason {
            lines.append(why)
        }
        if routine.refusedCalls > 0 {
            // An unattended run cannot answer a confirmation, so an alter-tier
            // call is refused at the boundary rather than hanging on a dialog
            // nobody will see. That is the boundary working — and the only
            // answer to *it ran and nothing happened*.
            let calls = routine.refusedCalls == 1 ? "1 call was" : "\(routine.refusedCalls) calls were"
            lines.append("\(calls) refused during its runs — a decision is waiting for you rather "
                         + "than the routine being broken.")
        }
        if !routine.canArm, let why = routine.armBecause { lines.append(why) }
        if !routine.canRun, let why = routine.runBecause { lines.append("Run now: \(why)") }
        return lines
    }

    /**
     * The badge's colour.
     *
     * Seven states and no honest default among them, which is why `.other`
     * lands on the same neutral as *nothing is listening* rather than borrowing
     * a colour that would make a word this build has never heard of look
     * healthy or broken on a guess.
     */
    static func tone(_ state: RoutineState) -> Color {
        switch state {
        case .armed: return Theme.positive
        case .running: return Theme.accent
        case .paused, .stale: return Theme.warning
        case .broken: return Theme.critical
        case .disabled, .unarmed, .other: return Theme.faint
        }
    }

    /**
     * A moment in the future, said the way a person says it.
     *
     * The sibling of `SessionDetails.activityLine`, which only looks backwards
     * and folds every negative interval onto *just now*. A schedule that came
     * due while nothing was listening is genuinely in the past, and *"in -3m"*
     * is worse than the vaguest true answer — so that case is a phrase of its
     * own rather than a negative number.
     */
    static func until(_ at: Date, now: Date = Date()) -> String {
        let seconds = at.timeIntervalSince(now)
        if seconds <= 0 { return "any moment now" }
        if seconds < 60 { return "in under a minute" }
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        if seconds < 86_400 { return "in \(Int(seconds / 3600))h" }
        return "in \(Int(seconds / 86_400))d"
    }
}
