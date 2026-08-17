/**
 * The three references hanging off the copilot screen: the confirmation waiting
 * at the desk, everything it has ever done, and the sessions it started.
 *
 * All three are sheets rather than pushes, for the reason `SessionDetailView`
 * gives about itself — *a reference somebody opens, reads and closes, not a
 * place they are going* — and none of them is a control. That is most obviously
 * true of the first, and the argument for it is the longest thing in this file.
 */

import SwiftUI

/* -------------------------------------------------------------------------- */
/* A confirmation waiting at the desk                                          */
/* -------------------------------------------------------------------------- */

/**
 * The card in the timeline: something needs a person, and the person is not
 * here.
 *
 * ## Why there is no Allow button on it, or anywhere on this phone
 *
 * This is the part of the feature most likely to be got wrong, so the reasoning
 * is written where somebody would come to add the button.
 *
 * The alter tier's entire safety property is *a human at the machine says yes*.
 * A dialog answered on the device that raised the request is answered by the
 * party being confirmed — so if holding the phone were sufficient to approve
 * what the phone asked for, the phone would hold `alter` and the grant would be
 * a ceremony. `REMOTE_GRANTABLE_TIERS` is `['read', 'act']` and there is no
 * frame on this wire that answers a question, which is not an omission to be
 * fixed later: it is the mechanism.
 *
 * Three further reasons, from `COPILOT-REMOTE.md` §4.5, that survive even if
 * somebody disagrees with the first:
 *
 *  - **There is no push in this product.** `SessionAlerts` says it plainly:
 *    there is no APNs certificate and no server holding one, so an alert exists
 *    only while the app is running. A confirmation lives 120 seconds. A phone
 *    that is not already open, connected and in a hand cannot be asked at all —
 *    so a phone Allow button would work in exactly the situation where walking
 *    to the desk was already possible, while changing everything about the trust
 *    model.
 *  - **A lock-screen Allow is worse than no gate.** An action that approves
 *    without the request being read is a gate that is always answered yes,
 *    wearing the appearance of protection.
 *  - **The real defence is that alter is rare.** Wanting to approve things from
 *    a phone several times a week means the tier boundary is wrong, and the fix
 *    is to look at which tool keeps asking — not to move the approval surface
 *    closer to a thumb.
 *
 * ## So what is this card *for*
 *
 * Telling you to go and look. The failure it fixes is real and specific: a
 * confirmation dialog on a screen nobody is watching, timing out silently after
 * two minutes, with the copilot then reporting a refusal nobody understands.
 * This turns that into something you knew about while it was still answerable.
 * It is watch-only and must stay watch-only: no Allow, no Refuse, no nudge, no
 * snooze.
 *
 * ## And why the countdown is on it
 *
 * Because "go and look" is worthless without "how long have I got". The number
 * is the desktop's own `expiresAt`, ticked locally, and it is deliberately **not
 * extended for a phone**: a longer window is how an approval lands six minutes
 * later from somebody who has forgotten what they were approving.
 */
struct CopilotQuestionCard: View {
    let question: CopilotQuestion
    /// What to call the machine — "Mac", "PC", "machine". The sentence has to
    /// name a real object for "go and look" to mean anything.
    let noun: String
    let read: () -> Void

    var body: some View {
        Button(action: read) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                    Text("Waiting for you at the \(noun)")
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
                    Text("See what it is asking")
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
 * The whole question, in full.
 *
 * Everything needed to judge it, and nothing that judges it. The order is the
 * order somebody reads in: what will happen, at what tier, with which arguments
 * verbatim, and how long is left — then the one sentence saying where it is
 * answered.
 *
 * The summary is the **desktop's** sentence, composed by the tool that wants to
 * run, and it is never re-worded here. A prompt whose words were written by the
 * side that draws it is a prompt that can flatter itself.
 *
 * The only control is Done, and it closes the sheet. Nothing on this screen
 * settles the question: leaving it does not refuse it, and there is nothing here
 * that could approve it. That is stated on the screen rather than left to be
 * inferred, because a sheet with one button is a sheet people assume that button
 * does something.
 */
struct CopilotQuestionSheet: View {
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
                                Text("This is answered at \(machine), not here.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Actions that change settings or stop your sessions are "
                                     + "confirmed by whoever is sitting at the \(noun). A phone "
                                     + "cannot approve one — including a phone that asked for it "
                                     + "— because then the thing being checked would be doing the "
                                     + "checking. Closing this changes nothing: the question is "
                                     + "still waiting there until it is answered or it runs out.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                /*
                                 * Said plainly, because this sheet used to try
                                 * to show the arguments and could not.
                                 *
                                 * They are not on this wire and they are not
                                 * coming — the desktop's own row type says why:
                                 * even scrubbed, they are the text of what was
                                 * typed into somebody's sessions, and this is a
                                 * relay. A person who has been shown a summary
                                 * and no detail has to know that the detail
                                 * exists and where, or they will read the
                                 * summary as the whole of it.
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
        .preferredColorScheme(.dark)
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
        .preferredColorScheme(.dark)
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
 * desk with every granted device. `deviceId` is the only place *which of my
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
        .preferredColorScheme(.dark)
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
