/**
 * Pairing, and the wait that follows it.
 *
 * Two screens in one file because they are two halves of one thing the user
 * experiences as a single step: type the six digits off the Mac, then say yes on
 * the Mac.
 *
 * ## One field, and why the camera is gone
 *
 * This screen used to open with a live camera preview and a QR scanner, with a
 * paste field underneath for the link. The QR did not work, and the link it
 * carried was a live pairing token in a string whose route between two devices
 * was a messaging app. Both are gone, and what is left is the thing that never
 * needed either: six digits, on a numeric keypad.
 *
 * That is also why `NSCameraUsageDescription` is out of `Support/Info.plist`.
 * Nothing in this app opens the camera any more, and a permission string for a
 * capability the binary does not use is a thing App Review asks about and a user
 * is right to be suspicious of.
 *
 * ## The waiting state is a screen, not an error
 *
 * `device-auth.ts` is explicit that pairing alone is not trust — a code can be
 * read over a shoulder, so a human at the Mac approves the device before it
 * opens anything. The phone's side of that is a period of tens of seconds where
 * the connection is *refused*, repeatedly, on purpose. Rendering that as a red
 * banner saying the desktop refused this device would be technically accurate
 * and completely wrong: it describes the mechanism instead of the situation, and
 * it tells someone standing three metres from the button that they have failed.
 *
 * So it gets a screen of its own, with the two things the person needs — what to
 * click on the Mac, and which device it is going to say — and no error styling
 * anywhere on it.
 */

import SwiftUI

struct PairingView: View {
    let model: DeckModel
    /**
     * Whether this is the *first* machine or another one.
     *
     * The only difference is what the screen says and whether it can be closed —
     * the flow underneath is identical, because pairing has always added a
     * record and multi-host only made that visible. Splitting it into two screens
     * would be two screens to keep in step for one behaviour.
     */
    var adding = false
    var close: (() -> Void)?

    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if let notice = model.pairingNotice {
                        Banner(text: notice, tone: .warning)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    codeEntry
                    deviceKind
                    identity
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)

            if adding {
                VStack {
                    HStack {
                        Spacer()
                        Button("Cancel") { close?() }
                            .font(.system(size: 15, weight: .medium))
                            .tint(Theme.accent)
                            .padding(16)
                            .accessibilityIdentifier("pairing.cancel")
                    }
                    Spacer()
                }
            }
        }
        // The keypad is up before the person has to ask for it. This screen has
        // exactly one thing to do and typing is it.
        .onAppear { typing = true }
    }

    /**
     * The title, and one ⓘ carrying everything this screen used to say out loud.
     *
     * Five paragraphs stood on this screen — where the code comes from, what a
     * code is worth, what the two device kinds mean, that the kind is fixed, and
     * what the fingerprint is for. Every one of them is now behind an ⓘ beside
     * the thing it is about. *"Don't put any single statement in anywhere… Let
     * the smart people use it."*
     *
     * "Machine", not "Mac", in the note: the protocol is OS-agnostic and a phone
     * genuinely cannot tell one from the other, so telling somebody with a
     * Windows PC to open it on their Mac is this app being wrong about its own
     * capabilities.
     */
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(adding ? "Pair another machine" : "Pair with your Mac")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.primary)
            InfoDot(about: "pairing",
                    text: adding
                        ? "Open \(Brand.name) on the other Mac or Windows PC and show its pairing code. "
                            + "The machines you already have stay paired. A code is good for one minute "
                            + "and one use, and pairing alone does not grant access — the machine still "
                            + "asks somebody to approve this device."
                        : "Open \(Brand.name) on the machine and show the pairing code. A code is good "
                            + "for one minute and one use, and pairing alone does not grant access — the "
                            + "machine still asks somebody to approve this device.")
            Spacer(minLength: 0)
        }
    }

    /**
     * The six-digit field.
     *
     * ## Why `.numberPad` and not `.default`
     *
     * Half the argument for digits is what a phone puts under them: ten large
     * targets instead of a keyboard, no case to get wrong, and nothing to type by
     * accident that the field will then refuse. `.numberPad` rather than
     * `.numbersAndPunctuation` or `.phonePad` — the first is a full keyboard with
     * digits on it, and the second carries `+`, `*`, `#` and a pause key, none of
     * which can appear in a pairing code.
     *
     * ## Why it submits itself
     *
     * A code is exactly six digits long, so the moment the sixth lands there is
     * nothing left to decide. Tapping a button at that point is a tap that asks a
     * question with one possible answer. The Pair button stays — for the person
     * who pasted something the field refused, and because a screen whose only
     * action is implicit is a screen somebody can get stuck on.
     *
     * `onChange` rather than `onSubmit`, because a number pad has no return key.
     */
    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pairing code")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)

            TextField("000000", text: $typed)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                // Read by iOS's own SMS-code autofill and by password managers,
                // which is exactly what this field is.
                .textContentType(.oneTimeCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .kerning(8)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.primary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .accessibilityIdentifier("pairing.field")
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The one border on this screen, and it earns it: a text field
                // with no edge on a dark background is indistinguishable from a
                // paragraph until it is tapped.
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
                .onChange(of: typed) { _, value in
                    /*
                     * Trimmed to six, then submitted on six.
                     *
                     * The trim is not cosmetic: `.numberPad` has no length limit
                     * of its own, and a seventh digit landing after the sixth has
                     * already been submitted would leave a field the person has
                     * to clear before they can try again. `PairingCodeParser`
                     * still decides — an assignment is not a check.
                     */
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(PairingCodeParser.codeLength))
                    if digits != value { typed = digits }
                    guard digits.count == PairingCodeParser.codeLength, !model.isPairing else { return }
                    typing = false
                    model.pair(with: digits)
                }

            Button {
                typing = false
                model.pair(with: typed)
            } label: {
                HStack(spacing: 7) {
                    // A spinner rather than the word alone. Finding the machine
                    // is a memory-hard derivation and a round trip over a relay,
                    // and a button whose only sign of life is a changed caption
                    // reads as one that has stuck.
                    if model.isPairing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.onAccent)
                    } else {
                        Image(systemName: "arrow.right")
                    }
                    Text(model.isPairing ? "Looking for that machine…" : "Pair")
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            // Dimmed rather than greyed: this is the primary action and it has
            // to stay recognisable as the blue one while it is waiting for
            // something to be typed.
            //
            // The ink changes with it, and that is not decoration. On the
            // full-strength blue the label is near-black — see `Theme.onAccent` —
            // but near-black on a blue at a third strength is a dark grey on a
            // dark navy, which rendered as an unreadable button on this screen.
            // So the disabled state takes secondary ink instead, which is what a
            // disabled control should read as anyway.
            .background(Theme.accent.opacity(typed.isEmpty ? 0.28 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(typed.isEmpty ? Theme.secondary : Theme.onAccent)
            .accessibilityIdentifier("pairing.submit")
            .disabled(typed.isEmpty || model.isPairing)
            // The paragraph that stood here — what a code is worth, and that
            // pairing is not access — is behind the ⓘ in `header`. It is the
            // same fact and it is one tap away, which is where an explanation
            // goes on this product now.
        }
    }

    /**
     * The choice that is about to be made **on the other machine**, said here.
     *
     * ## Why this is on the phone at all
     *
     * Approving a device is now two decisions rather than one: what kind of
     * device it is, and — for a guest — which folders it may reach. Both are
     * made at the desktop, by the person who owns it, and neither is anything
     * this phone can influence. That is exactly why it belongs on this screen.
     * The person typing these six digits is usually the person about to be
     * approved, and until now the next thing they saw was either everything on
     * the machine or almost nothing on it, with no explanation of which had
     * happened or why.
     *
     * ## Two cards rather than a paragraph
     *
     * Because it is a fork, and a fork drawn as prose reads as a list of
     * features. The wording is the desktop's own, word for word — `device-kind.ts`
     * and `DeviceApproval.tsx` carry the same two sentences — and that is
     * deliberate rather than lazy: somebody reads one of them here and then
     * watches the other person read the identical line over there, which is the
     * only way two people at two keyboards can be sure they agreed the same
     * thing.
     *
     * *"The copilot is never shared"* is printed here for the same reason it is
     * printed on the card the owner is choosing from. It is the one property of
     * the guest tier that is not a folder list, it is not derivable from
     * anything else on either screen, and a guest who was never told it would
     * spend the rest of the session looking for a tab that is deliberately not
     * there.
     *
     * ## And that it cannot be changed afterwards
     *
     * The last line, because it is the part that turns this from a preference
     * into a boundary. A kind that could be flipped with one tap on the desktop
     * would be a default with a delay on it; re-pairing is the whole of the
     * change, and somebody who is about to be a guest is entitled to know that
     * before they hand over the code.
     */
    private var deviceKind: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("What the machine will ask")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .textCase(.uppercase)
                InfoDot(about: "device kinds",
                        text: "My device is full access — it’s you at another keyboard. A guest reaches "
                            + "only the folders that are chosen for it, and the copilot is never shared. "
                            + "Whoever approves this device picks one, and it is fixed once they do: "
                            + "changing it means pairing again.")
                Spacer(minLength: 0)
            }

            kindCard(name: "My device", symbol: "person.fill", identifier: "pairing.kind.mine")
            kindCard(name: "Guest", symbol: "person.2", identifier: "pairing.kind.guest")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /**
     * One of the two kinds, as a card that is deliberately not a button.
     *
     * Nothing here is selectable and nothing pretends to be: this phone is
     * reading the choice, not making it. So there is no tint, no selected state
     * and no tap target — a card that looked pressable and did nothing would be
     * the exact failure this review is about, one step before it happens.
     */
    private func kindCard(name: String, symbol: String, identifier: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                // Fixed width so the two names start on the same column; the
                // glyphs are different widths and a ragged left edge on two
                // stacked cards reads as a mistake.
                .frame(width: 18, alignment: .center)
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// This phone's own fingerprint, shown before pairing rather than after.
    /// It is what the Mac will display in its approval prompt, and a person can
    /// only compare two things if they can see both.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("This device")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .textCase(.uppercase)
                InfoDot(about: "this fingerprint",
                        text: "The machine shows this fingerprint when it asks you to approve the "
                            + "device. If the two do not match, something else is answering.")
                Spacer(minLength: 0)
            }
            Text(model.deviceName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primary)
            Text(model.deviceFingerprint)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

/* -------------------------------------------------------------------------- */
/* Waiting for a human                                                         */
/* -------------------------------------------------------------------------- */

/**
 * The screen an unapproved device sits on — in either of the two states it can
 * actually be in.
 *
 * ## The two states, and why they must not share a headline
 *
 * `.pending` is the good one: the Mac answered, and it said a human has to press
 * a button. Everything about that is normal and none of it is an error.
 *
 * The other one is a device that is unapproved *and cannot reach the Mac at
 * all*. It used to render identically — a spinner, "Waiting for approval", and
 * whatever the last approval sentence had been — because the transport wrote
 * `approvalDetail` over the real failure. That is how a client whose handshake
 * was one byte short and failing on every single attempt presented as a phone
 * patiently waiting for someone to walk to their desk. Nothing on screen was
 * false-sounding enough to investigate, so nobody did.
 *
 * So the failing state gets a different headline, a warning tint, the actual
 * reason instead of a remembered one, and no spinner — a spinner beside a
 * connection that is not connecting is its own small lie.
 */
struct PendingApprovalView: View {
    let model: DeckModel

    /// True only when the Mac answered and asked for approval. See
    /// `ConnectionState.awaitingApproval` for why this is not the same question
    /// as "is this device unapproved".
    private var reached: Bool { model.connection.phase == .pending }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                if reached {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.warning)
                }

                Text(reached ? "Waiting for approval" : "Cannot reach that Mac")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("pending.title")

                // The desktop's own sentence when there is one — it is the only
                // thing that knows whether this is a fresh pairing, a device
                // someone has not got to yet, or one that was revoked. When the
                // Mac has not answered, this is instead the real reason the last
                // attempt failed, which is the whole point of the distinction.
                Text(model.connection.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pending.detail")

                if !reached {
                    // `Brand.name` rather than the words: this file is not the
                    // one place the product is allowed to be spelled out, and it
                    // had quietly become a second one.
                    Text("This device is paired but has not been approved yet, and the machine is "
                         + "not answering. Approving it will not help until the two can reach each "
                         + "other — check that it is awake and that \(Brand.name) is running on it.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 4) {
                    Text(model.deviceName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primary)
                    Text(model.deviceFingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                    if let endpoint = model.endpointSummary {
                        Text(endpoint)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

                if let retryAt = model.connection.retryAt {
                    // Says when, so the screen is visibly doing something
                    // between attempts rather than appearing to have stopped.
                    Text(RetryClock.sentence(until: retryAt, attempts: model.connection.attempts))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }

                HStack(spacing: 10) {
                    // "Check now" is a question for the Mac; when the Mac is not
                    // answering there is nothing to check, only another attempt.
                    Button(reached ? "Check now" : "Try again") { model.resume() }
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))

                    Button("Start over") { model.unpairCurrent() }
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                .foregroundStyle(Theme.primary)
            }
            .padding(24)
        }
    }
}

/// A countdown that reads like a sentence. Recomputed by the view that shows it
/// rather than driven by a timer: this text is inside a screen that is already
/// being redrawn by the connection state changing under it.
enum RetryClock {
    static func sentence(until: Date, attempts: Int) -> String {
        let seconds = max(0, Int(until.timeIntervalSinceNow.rounded()))
        let when = seconds <= 1 ? "now" : "in \(seconds)s"
        // The attempt count is only worth showing once it stops looking like a
        // blip; before that it is noise about something nobody noticed.
        return attempts >= 3 ? "Checking again \(when) · \(attempts) tries" : "Checking again \(when)"
    }
}
