/**
 * The four references hanging off the copilot screen: the confirmation this
 * phone must answer, the one it may only watch, everything the copilot has ever
 * done, and the sessions it started.
 *
 * All four are sheets rather than pushes, for the reason `SessionDetailView`
 * gives about itself — *a reference somebody opens, reads and closes, not a
 * place they are going*. The first one is the only control in this file, and the
 * argument for its shape is the longest thing here, because it is the screen
 * this feature is most easily made worse by.
 */

import SwiftUI

/* -------------------------------------------------------------------------- */
/* A confirmation                                                              */
/* -------------------------------------------------------------------------- */

/**
 * The card in the timeline: something needs a person.
 *
 * ## What changed, and what did not
 *
 * This card used to state, at length, that there was no Allow button on it or
 * anywhere on this phone, because *the alter tier's whole safety property is a
 * human at the machine says yes, and a dialog answered on the device that raised
 * the request is answered by the party being confirmed.* That argument is
 * preserved in `COPILOT-REMOTE.md` §4.8 verbatim rather than deleted, and it was
 * superseded for a reason worth understanding: the second factor was never
 * *geography*. Somebody who walks away from an unlocked Mac has taken their
 * geography with them. It was **reaching the dialog required an authorisation
 * the requesting party did not already hold** — and that is now the copilot
 * connection, which is minted at the machine, is separate from pairing, and can
 * be revoked in one press without unpairing anything.
 *
 * So a connected device holding `alter` answers **its own run's** questions.
 * Everything else on this card is unchanged, and the unchanged half is still
 * most of the value: the failure the design named is a desktop dialog on a
 * screen nobody is looking at, timing out in silence two minutes later, with the
 * copilot then reporting a refusal nobody understands. A phone that shows the
 * question while it is still answerable fixes that whether or not it can answer
 * it.
 *
 * ## `decidable`, and why it is not `question.mine`
 *
 * `mine` says the desktop would accept an answer from this device. It does not
 * say this phone was ever *sent* the request — and the two come apart in a case
 * that is not rare, because **there is no replay**: a phone that reconnects
 * while a confirmation is outstanding gets the watch row and no `copilot.ask`.
 * It then holds an id and not a request, and answering on an id alone is
 * answering blind, which is the reflex Yes this whole design refuses. So the
 * caller passes `decidable` only when it has the full question, and this card
 * says *go and look* in every other case — including for somebody else's
 * question, whose arguments the desktop deliberately strips.
 *
 * ## And why the countdown is on it
 *
 * Because "there is a decision here" is worthless without "how long have I got",
 * and because the deadline is not a deferral: it **expires into a refusal**. The
 * number is the desktop's own `expiresAt`, ticked locally, and it is deliberately
 * not extended for a phone — a longer window is how an approval lands six
 * minutes later from somebody who has forgotten what they were approving.
 */
struct CopilotQuestionCard: View {
    let question: CopilotQuestion
    /// What to call the machine — "Mac", "PC", "machine". The sentence has to
    /// name a real object for "go and look" to mean anything.
    let noun: String
    /// This phone holds the whole request and may answer it. See the header:
    /// **not** the same as `question.mine`.
    let decidable: Bool
    let read: () -> Void

    var body: some View {
        Button(action: read) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: decidable ? "hand.raised.fill" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                    Text(decidable ? "Waiting for you" : "Waiting for you at the \(noun)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    Spacer(minLength: 8)
                    // Ticks once a second, and only while this card is on
                    // screen. A `Timer` on the model would keep a phone awake
                    // counting down something nobody is looking at.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdown(now: context.date))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                            .monospacedDigit()
                    }
                }

                Text(question.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copilot.question.card.summary")

                HStack(spacing: 6) {
                    Text(question.tool)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 5,
                                                                            style: .continuous))
                    Spacer(minLength: 0)
                    // The words differ because the errands differ, and a card
                    // that said "answer it" over a question this phone cannot
                    // answer would be a control that is always refused wearing a
                    // verb.
                    Text(decidable ? "Read it and decide" : "See what it is asking")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .overlay {
            // The one outline in this app, and it is earned: this card has a
            // deadline on it and everything around it does not. Space and a tint
            // are the first two tools, they are both already spent on the rows
            // above and below, and the third exists for exactly this.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.warning.opacity(0.4), lineWidth: 1)
        }
        .accessibilityIdentifier("copilot.question.\(question.id)")
    }

    /// `1:23`, or a word when there is nothing to count. `expiresAt` of zero
    /// means the desktop did not say, and an invented deadline on a consent
    /// prompt is the worst possible thing to invent.
    private func countdown(now: Date) -> String {
        guard let left = question.secondsLeft(now: now) else { return "waiting" }
        if left == 0 { return "expired" }
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}

/**
 * **The consent sheet.** The whole request, and the two answers.
 *
 * This is the screen `COPILOT-REMOTE.md` calls *the part worth the most care*,
 * so the rules it is built from are written here rather than left to be
 * inferred.
 *
 * ## 1. Everything needed to judge it, or it is worse than nothing
 *
 * *A consent prompt without enough context becomes a reflex Yes, and a gate that
 * is always answered yes is worse than no gate, because it looks like
 * protection.* So the sheet shows the desktop's own summary, the tool by its
 * canonical id, the tier, **every argument verbatim**, who asked, and how long
 * is left. Nothing is re-composed: the summary was written by the tool that is
 * about to run, by the code that knows what it will do, and a client that wrote
 * its own sentence would be describing an action it did not implement — the
 * first time the two drifted, somebody would approve one thing having read
 * another.
 *
 * ## 2. Refusing is at least as easy as accepting
 *
 * Not Allow under the thumb and Refuse in a corner. The two buttons are one
 * `HStack` of equal halves built from the **same** metrics — see `answerHeight`
 * — at the same distance from the bottom of the screen, and neither is behind a
 * confirmation, a long-press or a biometric. The safe answer here is *Refuse*,
 * and a design that makes the safe answer the harder gesture has inverted the
 * gate it is pretending to be.
 *
 * Refuse is not painted red. Red would say *danger*, and refusing is the safe
 * half; the colour would be arguing for the other button.
 *
 * ## 3. The countdown says what silence means
 *
 * It expires into a **refusal**, not a deferral, and the sheet says so in those
 * words. A person who walks away has decided rather than postponed, and being
 * told that is the difference between a deadline and a trap.
 *
 * ## 4. It does not vanish
 *
 * First answer wins, and the desktop tells every surface where a question went.
 * When one is settled elsewhere — at the Mac, or by the timeout — this sheet
 * stays up and **says where it was answered**. A dialog that disappears on its
 * own teaches a person that the app does things behind their back, which is the
 * opposite of what a consent surface is for.
 *
 * ## 5. No biometric gate, and the reason is what one would be worth
 *
 * §4.6 offers a device unlock in front of Allow as optional, *"worth having,
 * defeats a found phone and nothing else"*, and never in front of Refuse. It is
 * not built, and the argument for leaving it out is the same one that bounds
 * what it would buy: this sheet only exists while the app is open in somebody's
 * hand — there is no push in this product — so the phone it would defend against
 * is one found unlocked, with the app foregrounded, inside a two-minute window.
 * Against that it is worth a little; against the failure this screen is actually
 * about, a reflex Yes from the person who owns the phone, it is worth nothing,
 * and a gesture that feels like security while adding none is the thing this
 * whole design keeps refusing.
 *
 * If it is added: in front of Allow only, never Refuse — a gate that makes the
 * safe answer the harder one has inverted itself — and the sheet must say what
 * it defeats rather than implying more.
 *
 * ## 6. There is no notification to answer from, and that is deliberate
 *
 * There is no APNs in this product — `SessionAlerts` says so plainly — so this
 * only ever appears while the app is open in somebody's hand. If push is ever
 * added, §4.6 is not negotiable: the payload carries nothing and it carries no
 * actions, because a lock-screen Allow that approves without the request being
 * read is the reflex-Yes machine wearing a badge.
 */
struct CopilotConsentSheet: View {
    let question: CopilotConsentQuestion
    /// Where it went, when it has already gone. Non-nil replaces the buttons
    /// with a sentence — see rule 4.
    let settlement: CopilotSettlement?
    let machine: String
    let noun: String
    /// Returns whether the answer reached the wire. **Not `Void`** — see
    /// `answered` below: a sheet that dimmed its buttons over a dropped socket
    /// would be a consent prompt that looks answered and is not.
    let answer: (Bool) -> Bool
    let dismiss: () -> Void

    /// The one place the answer buttons' metrics live, so that "the same size"
    /// is a fact rather than two numbers somebody keeps in step. Rule 2.
    private static let answerHeight: CGFloat = 52

    /**
     * Set once the answer is **on the wire**, so a second tap cannot send a
     * second frame and the sheet can say it is waiting rather than looking
     * unresponsive while the desktop settles it.
     *
     * Set from the send's own result rather than from the tap, because
     * `Transport.send` refuses instead of queuing: over a dropped socket the tap
     * sends nothing, and a sheet that greyed itself out anyway would be showing
     * somebody a decision they did not make. The error banner behind this sheet
     * is not an answer to that — it is behind the sheet.
     */
    @State private var answered: Bool?

    /// What went wrong here, on this sheet, where the person is looking.
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(question.summary)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("copilot.consent.summary")

                        // The countdown stops when the question does. A clock
                        // still saying "90 seconds left — if nobody answers, it
                        // is refused" over a question that has already been
                        // answered is a screen contradicting itself about the
                        // one thing on it that matters.
                        if settlement == nil {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(deadline(now: context.date))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 8)
                                    .accessibilityIdentifier("copilot.consent.countdown")
                            }
                        }

                        Caption("What it is asking to do")
                        Card {
                            Row(name: "Tool", value: question.tool, mono: true)
                            Hairline()
                            Row(name: "Permission", value: tierWord, mono: false)
                            Hairline()
                            Row(name: "Asked by", value: askedBy, mono: false)
                        }

                        Caption(argumentsCaption)
                        Card {
                            if question.arguments.isEmpty {
                                // A real answer, not an empty state: some tools
                                // genuinely take none, and "no arguments" is
                                // different from "we could not show them".
                                Text("This call takes no arguments.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(question.arguments.enumerated()), id: \.element.id) {
                                        index, argument in
                                        if index > 0 { Hairline() }
                                        ArgumentRow(argument: argument)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("copilot.consent.args")

                        if !question.argumentsAreOrdered && !question.arguments.isEmpty {
                            // Said, because *as the tool wrote them* and *by
                            // name* are two different claims and a sheet that
                            // made the wrong one would have somebody comparing
                            // this screen with the Mac's dialog and finding two
                            // different orders with nothing to explain it.
                            Text("Listed by name — this build could not read the order the tool "
                                 + "wrote them in.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.faint)
                                .padding(.top, 8)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Caption("Answering it")
                        Card {
                            Text(answeringNote)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("copilot.consent.where")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { answers }
            .navigationTitle("Needs you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: dismiss)
                        .accessibilityIdentifier("copilot.consent.done")
                }
            }
        }
        // Not dismissable by swiping it away while it is still answerable.
        // Flicking a consent prompt off the screen is not an answer, and the
        // gesture that means "I have dealt with this" must not be the same one
        // that means "I did not look". Closing it deliberately is still there,
        // top right, and still changes nothing — the question goes on waiting.
        .interactiveDismissDisabled(settlement == nil)
    }

    /**
     * The two answers, equal in every dimension that costs a thumb anything.
     *
     * Same height, same width, same corner, same distance from the bottom edge,
     * same number of taps. The only difference is the fill, and that difference
     * is spent on making them tellable apart rather than on making one of them
     * easier.
     */
    @ViewBuilder
    private var answers: some View {
        VStack(spacing: 0) {
            if let settlement {
                // Rule 4: it does not vanish. This is where the sheet says where
                // the answer came from, and it is deliberately in the same place
                // the buttons were, so the eye lands on it.
                VStack(alignment: .leading, spacing: 6) {
                    Text(settledHeadline(settlement))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(settlement.granted ? Theme.primary : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(settledDetail(settlement))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("copilot.consent.settled")

                Button("Close", action: dismiss)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: Self.answerHeight)
                    .background(Theme.surfaceHigh,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("copilot.consent.close")
            } else {
                HStack(spacing: 12) {
                    Button {
                        send(false)
                    } label: {
                        Text("Refuse")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: Self.answerHeight)
                    }
                    /*
                     * Neutral, not red — refusing is the *safe* half of this
                     * screen, and painting it as the dangerous one would be the
                     * sheet arguing for the other button.
                     *
                     * The outline is why this is not merely a paler Allow. A
                     * filled blue button beside an unbordered grey one reads as
                     * a primary action beside a way out, and rule 2 is about
                     * more than hit targets: an eye that finds only one button
                     * has been steered. The edge makes it a button of the same
                     * weight, drawn in a different colour rather than a quieter
                     * one — which is the most this design will spend on telling
                     * the two apart.
                     */
                    .background(Theme.surfaceHigh,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("copilot.consent.refuse")

                    Button {
                        send(true)
                    } label: {
                        Text("Allow")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: Self.answerHeight)
                    }
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .foregroundStyle(Theme.onAccent)
                    .accessibilityIdentifier("copilot.consent.allow")
                }
                .disabled(answered != nil)
                .opacity(answered == nil ? 1 : 0.5)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("copilot.consent.problem")
                } else if answered != nil {
                    Text("Sent. Waiting for \(machine) to confirm where it was answered.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /**
     * One answer, on the wire or not at all.
     *
     * Both buttons come through here, which is the mechanical half of *refusing
     * must be at least as easy as accepting*: there is one path, so neither
     * answer can acquire a guard, a confirmation or a retry the other does not
     * have. The buttons dim only once the frame has gone.
     */
    private func send(_ approved: Bool) {
        guard answer(approved) else {
            problem = approved
                ? "That did not reach \(machine). Nothing was allowed — the question is still "
                    + "waiting there."
                : "That did not reach \(machine). Nothing was refused — the question is still "
                    + "waiting there, and it runs out on its own."
            return
        }
        problem = nil
        answered = approved
    }

    /// The caption above the arguments, which is also the claim about them.
    private var argumentsCaption: String {
        question.argumentsAreOrdered ? "With these arguments, exactly" : "With these arguments"
    }

    /// The tier, in a word somebody can act on. Printed rather than mapped when
    /// it is not one this build knows — a newer desktop may send a fourth tier,
    /// and inventing a description of it would be this phone explaining somebody
    /// else's permission model to them incorrectly.
    private var tierWord: String {
        switch question.tier {
        case "alter": return "alter — changes things"
        case "act": return "act — does work"
        case "read": return "read — looks only"
        case "": return "not stated"
        default: return question.tier
        }
    }

    /// Which copilot asked. The two must never read the same: *your phone's
    /// copilot* and *the copilot at the Mac* are different things to be
    /// approving, and `origin` is the only field that says which.
    private var askedBy: String {
        if question.origin == "window" { return "The copilot at \(machine)" }
        if question.fromADevice { return "This phone's own copilot run" }
        if question.origin.isEmpty { return "A copilot on \(machine)" }
        return question.origin
    }

    private var answeringNote: String {
        "Allowing this runs it once, now. It is not remembered and it does not widen anything: "
        + "the next call like it asks again. Refusing tells the copilot no, and it carries on "
        + "with the rest of its turn. Closing this without answering leaves the question "
        + "waiting until it runs out, and running out is a refusal. "
        + "Whoever is at \(machine) can answer it there instead — the first answer wins."
    }

    /// **The countdown says what silence means.** Rule 3.
    private func deadline(now: Date) -> String {
        guard let left = question.secondsLeft(now: now) else {
            return "Waiting for an answer. The \(noun) did not say when it runs out."
        }
        if left == 0 {
            return "This one ran out. Nobody answered, so the copilot was told no."
        }
        return "\(left) second\(left == 1 ? "" : "s") left — if nobody answers, it is refused."
    }

    private func settledHeadline(_ settlement: CopilotSettlement) -> String {
        if settlement.timedOut { return "Nobody answered — it was refused" }
        if settlement.granted { return "Allowed" }
        return "Refused"
    }

    /// Where it went, in a sentence. The whole reason `copilot.settled` carries
    /// `by`: an answer that arrived from somewhere else has to be attributed, or
    /// the sheet is just a dialog that closed itself.
    private func settledDetail(_ settlement: CopilotSettlement) -> String {
        if settlement.timedOut {
            return "It ran out after two minutes without an answer, which is a refusal. "
                + "The copilot has been told."
        }
        /*
         * **"Here" is decided by `answered`, not by `by`.**
         *
         * The desktop sends `device:<id>` for any device, and this end does not
         * compare device ids — it does not need to. First answer wins, this
         * sheet only ever shows a question this device owns, and only the owner
         * or the desktop may answer one; so a device answer on a question this
         * sheet just answered is this phone's. Reading "answered on a connected
         * device" about your own tap two seconds ago is the kind of small
         * wrongness that makes somebody stop trusting the sentence beside it.
         */
        let place = answered != nil ? "here"
            : (settlement.atTheMachine ? "at \(machine)" : "on another connected device")
        if settlement.granted { return "Answered \(place). It is running now." }
        let reason = settlement.reason.map { " (\($0))" } ?? ""
        return "Answered \(place)\(reason). The copilot has been told no."
    }
}

/// One argument: the name the tool gave it and the value the desktop sent.
///
/// A block value gets its own line and a monospaced face, because the things
/// that end up here are paths, commands and settings keys, and a path squeezed
/// against a label on a phone is a path somebody approves without reading. Short
/// values stay on the label's line, where a `true` given its own paragraph would
/// be the opposite mistake.
///
/// Selectable, both ways round: somebody who is unsure about an argument will
/// want to paste it somewhere before deciding, and a consent screen that made
/// that impossible would be pushing them towards the quicker answer.
private struct ArgumentRow: View {
    let argument: CopilotArgument

    var body: some View {
        if argument.isBlock {
            VStack(alignment: .leading, spacing: 5) {
                Text(argument.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Text(argument.value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("copilot.consent.arg.\(argument.name)")
        } else {
            Row(name: argument.name, value: argument.value, mono: true)
                // Combined **and** identified, in that order. An identifier on a
                // container that is still two separate accessibility elements
                // names nothing a query can find — which is not only a test
                // problem: VoiceOver would read the name and the value as two
                // unrelated fragments on the one screen where they only mean
                // something together.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("copilot.consent.arg.\(argument.name)")
        }
    }
}

/**
 * The watch-only sheet: somebody else's question, or one this phone reconnected
 * in the middle of.
 *
 * **No Allow and no Refuse, and that is not squeamishness.** Two different
 * reasons land here and both of them make a button wrong:
 *
 *  - a question raised by another device or at the desk is not this device's to
 *    answer — `ConsentBroker.respond` refuses it, so a button would be a control
 *    whose only possible outcome is a refusal, which is the defect this
 *    repository has paid for twice. The desktop strips those arguments too, so
 *    there is nothing here to judge with even if there were a button.
 *  - a question this device *may* answer but was never sent in full — there is
 *    no replay of `copilot.ask`, so a phone that reconnected mid-question holds
 *    the id and not the request. Answering on an id alone is answering blind.
 *
 * So this says *go and look*, with enough to know whether it is worth getting up
 * for and how long there is to do it.
 */
struct CopilotWatchSheet: View {
    let question: CopilotQuestion
    let machine: String
    let noun: String
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(question.summary)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("copilot.question.summary")

                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(deadline(now: context.date))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                                .accessibilityIdentifier("copilot.question.countdown")
                        }

                        Caption("What it is asking to do")
                        Card {
                            Row(name: "Tool", value: question.tool, mono: true)
                        }

                        Caption("Answering it")
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(question.mine
                                     ? "This one is yours to answer, and the full request was not "
                                        + "sent to this phone."
                                     : "This one is answered at \(machine), not here.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(explanation)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                /*
                                 * Said plainly, because a person who has been
                                 * shown a summary and no detail has to know that
                                 * the detail exists and where — or they will
                                 * read the summary as the whole of it.
                                 *
                                 * The arguments of a question this device cannot
                                 * answer are deliberately not on the wire:
                                 * `CopilotPendingRow` says why, and it is the
                                 * same reason the action log carries none —
                                 * even scrubbed, they are the text of what was
                                 * typed into somebody's sessions.
                                 */
                                Text("The full request — every argument it would use — is on the "
                                     + "dialog at \(machine). It is not sent here.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.faint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("copilot.question.where")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Needs you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss)
                        .accessibilityIdentifier("copilot.question.done")
                }
            }
        }
    }

    private var explanation: String {
        if question.mine {
            return "A confirmation is only sent in full to the connection that was watching when "
                + "it was raised, and it is never sent twice. This phone reconnected after that, "
                + "so it knows a question exists and not what is in it — and answering something "
                + "you have not read is exactly what this gate is for stopping. Answer it at "
                + "\(machine); it is still waiting there."
        }
        return "Actions that change settings or stop sessions are confirmed by whoever raised "
            + "them, or by somebody sitting at the \(noun). A phone cannot answer another "
            + "device's question — that would be a permission model with a shared password. "
            + "Closing this changes nothing: the question is still waiting until it is answered "
            + "or it runs out."
    }

    private func deadline(now: Date) -> String {
        guard let left = question.secondsLeft(now: now) else {
            return "Waiting for an answer at \(machine)."
        }
        if left == 0 {
            // Not an error, and worded so it does not read as one. A question
            // that ran out was refused by the timeout, which is the safe answer
            // and the design's intended one.
            return "This one ran out. The copilot was told no."
        }
        return "\(left) second\(left == 1 ? "" : "s") left to answer it at \(machine)."
    }
}

/* -------------------------------------------------------------------------- */
/* Everything it did                                                           */
/* -------------------------------------------------------------------------- */

/**
 * The action log: every call, in order, oldest at the top.
 *
 * The timeline on the screen behind this holds what happened while this phone
 * was connected and bounded at `Copilot.maxTimelineRows`. This is the file on
 * the machine — `<userData>/copilot-log/actions.jsonl`, which the app writes and
 * the copilot may only append a note to — paged backwards a screenful at a time.
 * It is the answer to *"what did it do while I was asleep"*, which the timeline
 * cannot answer because this phone was not there.
 *
 * Read tier. A watching phone gets all of it, which is most of what makes the
 * watching grant worth handing out.
 */
struct CopilotActivitySheet: View {
    let model: DeckModel
    let hostID: String
    let dismiss: () -> Void

    private var link: CopilotLink? { model.host(hostID)?.copilot }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if (link?.log.isEmpty ?? true) && (link?.isLoadingLog ?? false) {
                    ProgressView().controlSize(.large).tint(Theme.secondary)
                } else if link?.log.isEmpty ?? true {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "list.bullet.rectangle")
                    } description: {
                        // Not "the copilot has done nothing", which would be a
                        // claim about the machine. The honest statement is about
                        // the log, which is the thing that was read.
                        Text("The copilot's action log is empty. Every call it makes lands there, "
                             + "including the ones it was refused.")
                    }
                    .accessibilityIdentifier("copilot.log.empty")
                } else {
                    list
                }
            }
            .navigationTitle("Everything it did")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss)
                }
            }
        }
        // Asked for when the sheet appears rather than kept current, because the
        // live view of the same thing is the timeline behind it. A log that
        // refreshed itself on a timer would be this app polling something it is
        // already being pushed.
        .task { link?.loadLog() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                // Older rows go **above**, so the button that fetches them is
                // above them too. A "load older" at the foot of a list that
                // grows upward is a button that walks away from the finger.
                if link?.logHasMore == true {
                    Button {
                        link?.loadOlder()
                    } label: {
                        HStack(spacing: 8) {
                            if link?.isLoadingLog == true {
                                ProgressView().controlSize(.mini).tint(Theme.secondary)
                            }
                            Text(link?.isLoadingLog == true ? "Loading…" : "Load older")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .disabled(link?.isLoadingLog == true)
                    .accessibilityIdentifier("copilot.log.older")
                }

                ForEach(link?.log ?? []) { action in
                    CopilotLogRow(action: action)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/**
 * One row of the log.
 *
 * Almost the tool row from the timeline, and deliberately not the same type: it
 * carries one thing that one does not, which is **who asked**. In the timeline
 * that is always answerable — you are looking at your own conversation — and in
 * the log it is the whole question, because the file mixes the copilot at the
 * desk with every connected device. `deviceId` is the only place *which of my
 * phones did that* has an answer at all, since a relayed call leaves no other
 * trace.
 */
private struct CopilotLogRow: View {
    let action: CopilotAction

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tone)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(action.tool)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let line = SessionDetails.activityLine(action.at) {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                    }
                }
                Text(action.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(askedBy)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                    if let refusal = action.refusal {
                        Text("refused — \(refusal)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copilot.log.\(action.id)")
    }

    /**
     * Who asked.
     *
     * Nil `deviceId` is **the person at the machine**, which is a fact rather
     * than an absence: `CopilotActionRow` on the desktop says so in as many
     * words — *null for the person at the Mac*. That is worth stating here
     * because the shape invites the opposite reading, and hedging it into "not
     * said" would leave the one row a person most wants attributed — their own
     * — as the only unlabelled one.
     */
    private var askedBy: String {
        guard let device = action.deviceId else { return "asked at the machine" }
        return "asked by a device (\(device))"
    }

    private var tone: Color {
        if action.wasRefused { return Theme.warning }
        if action.failed { return Theme.critical }
        return Theme.positive
    }
}

/* -------------------------------------------------------------------------- */
/* Sessions it started                                                         */
/* -------------------------------------------------------------------------- */

/**
 * The sessions the copilot started, and the way back into each of them.
 *
 * These are ordinary sessions — the same rows, the same statuses, opened by the
 * same route — and the only thing that makes them a list of their own is
 * `origin: 'copilot'` on the desktop. That is worth a screen because it is the
 * *"why does this exist"* question: a session that appeared while somebody was
 * asleep, in a folder they did not choose, is alarming until it is attached to
 * the turn that made it.
 *
 * Tapping one closes this and opens it. It does not pop the copilot underneath —
 * the terminal goes on top, and Back comes straight back to the conversation
 * that started it, which is the other half of "one click in either direction".
 */
struct CopilotSessionsSheet: View {
    let model: DeckModel
    let hostID: String
    let dismiss: () -> Void

    private var link: CopilotLink? { model.host(hostID)?.copilot }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if link?.sessions.isEmpty ?? true {
                    ContentUnavailableView {
                        Label("None yet", systemImage: "terminal")
                    } description: {
                        Text("Sessions the copilot starts appear here, each one linked back to "
                             + "the turn that started it.")
                    }
                    .accessibilityIdentifier("copilot.sessions.empty")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(link?.sessions ?? []) { row in
                                Button {
                                    dismiss()
                                    model.open(session: row.session.id, on: hostID)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        StatusDot(status: row.session.status)
                                            .padding(.top, 7)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(row.session.title)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(Theme.primary)
                                                .lineLimit(1)
                                            Text(row.session.cwd)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Theme.faint)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                            Text(SessionDetails.statusLine(row.session))
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.faint)
                                            .padding(.top, 4)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityIdentifier("copilot.session.\(row.session.id)")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .navigationTitle("Sessions it started")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss)
                }
            }
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Small pieces                                                                */
/* -------------------------------------------------------------------------- */

/// A caption over a card. The same shape `DeckSettingsView` and
/// `SessionDetailView` use, so the sheets read as one app.
private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 14)
    }
}

private struct Row: View {
    let name: String
    let value: String
    let mono: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
