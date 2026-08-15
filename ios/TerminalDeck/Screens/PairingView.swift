/**
 * Pairing, and the wait that follows it.
 *
 * Two screens in one file because they are two halves of one thing the user
 * experiences as a single step: point the phone at the Mac, then walk over and
 * say yes.
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

                    QRScanner { code in
                        typed = code
                        // Closing is the model's, not this view's: it is the only
                        // place that knows whether the code parsed. See `pair`.
                        model.pair(with: code)
                    }

                    manualEntry
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(adding ? "Pair another machine" : "Pair with your Mac")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(adding
                 // "Machine", not "Mac". The protocol is OS-agnostic and a phone
                 // genuinely cannot tell one from the other — telling somebody
                 // with a Windows PC to open it on their Mac is this app being
                 // wrong about its own capabilities.
                 ? "Open \(Brand.name) on the other Mac or Windows PC and show its pairing code. "
                    + "The machines you already have stay paired."
                 : "Open \(Brand.name) on the Mac and show the pairing code. "
                    + "Point the camera at it, or paste the link.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or paste the link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)

            TextField("terminaldeck://pair?…", text: $typed, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .lineLimit(1 ... 3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .accessibilityIdentifier("pairing.field")
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The one border on this screen, and it earns it: a text field
                // with no edge on a dark background is indistinguishable from a
                // paragraph until it is tapped.
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))

            HStack(spacing: 10) {
                Button {
                    // The pairing link most often arrives through a message or a
                    // note, so the clipboard is the likeliest place it is.
                    if let text = UIPasteboard.general.string { typed = text }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .foregroundStyle(Theme.primary)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    typing = false
                    model.pair(with: typed)
                } label: {
                    HStack(spacing: 7) {
                        // A spinner rather than the word alone. Redeeming a code
                        // is a round trip to a machine over a relay, and a button
                        // whose only sign of life is a changed caption reads as
                        // one that has stuck.
                        if model.isPairing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.onAccent)
                        } else {
                            Image(systemName: "link")
                        }
                        Text(model.isPairing ? "Pairing…" : "Pair")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                // Dimmed rather than greyed: this is the primary action and it
                // has to stay recognisable as the blue one while it is waiting
                // for something to be typed.
                //
                // The ink changes with it, and that is not decoration. On the
                // full-strength blue the label is near-black — see
                // `Theme.onAccent` — but near-black on a blue at a third
                // strength is a dark grey on a dark navy, which rendered as an
                // unreadable button on the pairing screen. So the disabled state
                // takes secondary ink instead, which is what a disabled control
                // should read as anyway.
                .background(Theme.accent.opacity(typed.isEmpty ? 0.28 : 1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(typed.isEmpty ? Theme.secondary : Theme.onAccent)
                .accessibilityIdentifier("pairing.submit")
                .disabled(typed.isEmpty || model.isPairing)
            }
        }
    }

    /// This phone's own fingerprint, shown before pairing rather than after.
    /// It is what the Mac will display in its approval prompt, and a person can
    /// only compare two things if they can see both.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This device")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            Text(model.deviceName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primary)
            Text(model.deviceFingerprint)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.secondary)
            Text("The Mac shows this fingerprint when it asks you to approve the device. "
                 + "If the two do not match, something else is answering.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
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
