/**
 * **Connecting the copilot — in Settings, where he moved it.**
 *
 * Asad, holding 0.4.0: *"Actually connecting copilot should be in the settings.
 * So if the copilot is not connecting, this icon should not be inside the pill —
 * then it will be three icon pill. Otherwise if the copilot is connected, then
 * four icon pill, automatically, like that way."*
 *
 * Those are one sentence and one change, not two. The Copilot pill appears only
 * once this phone has a copilot connection to the machine on screen — see
 * `DeckModel.showsCopilotTab` — and the six-digit code used to be a screen
 * *behind that pill*. Leaving it there would have made the form for connecting
 * the copilot reachable only through a door that unlocks after you are through
 * it. So the code field moved here, to a row in Settings, and the Copilot screen
 * kept only the conversation.
 *
 * ## One machine at a time, chosen by the same control as everywhere else
 *
 * The copilot connection is per machine and per device: two phones paired with
 * one Mac hold two different credentials, and one phone paired with a Mac and a
 * PC has to connect each of them separately. So this screen has to say *whose*
 * copilot it is talking about, and it says it with `HostSwitcher` in the
 * navigation title — the identical control the Sessions, Localhost and Copilot
 * screens use for the identical question.
 *
 * A list of every machine with a code field on each was the other shape and it
 * is worse in three ways: two code fields on one screen invite typing a code
 * minted at one machine into the other's box, which fails with a message about
 * an invalid code rather than about the wrong machine; the screen would grow a
 * scroll for something almost every person does once; and it would be the only
 * place in the app where "which machine" is answered by a heading rather than by
 * the switcher.
 *
 * ## What it does when the code lands
 *
 * It takes the person to the copilot. That is the payoff of the thing they just
 * did, it is the moment the fourth pill appears, and arriving at the
 * conversation is more use than being left on a settings row that now reads
 * "Connected". It is deliberately narrow — only for a code submitted **on this
 * screen, in this visit**, tracked in `awaiting` — so that a copilot coming back
 * by itself after a reconnect, on a phone sitting in Settings for some unrelated
 * reason, moves nobody anywhere.
 */

import SwiftUI

struct CopilotConnectionView: View {
    let model: DeckModel

    /// The six digits being typed. Held here rather than on the link for the
    /// reason the composer's draft is: it is a half-typed thing, not a fact
    /// about the machine, and it must survive the redraws a live connection
    /// causes constantly.
    @State private var code = ""
    @FocusState private var typingCode: Bool

    /// The machine a code was submitted for on this visit, and the only one an
    /// arriving connection may move somebody for. Cleared as soon as it fires,
    /// so a second connection later in the same visit — a machine reconnecting
    /// behind the switcher — does nothing.
    @State private var awaiting: String?

    private var host: HostLink? { model.current }
    private var link: CopilotLink? { model.current?.copilot }
    private var access: CopilotAccess { model.copilotAccess }
    private var machine: String { host?.label ?? "that machine" }
    private var hostNoun: String { host?.hostPlatform.noun ?? "desktop" }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            /*
             * **Which state is drawn, named on the `ScrollView` and nowhere
             * further in.**
             *
             * This cost two runs to get right and the fact is worth keeping.
             * `.accessibilityIdentifier` on a `VStack` makes that stack an
             * accessibility *element*, and its children stop existing as far as
             * a UI test is concerned — measured here on iOS 26.4, where a code
             * field plainly on the phone could not be found by
             * `textFields["copilot.connect.field"]` because the stack around it
             * carried the state's name. A `ScrollView` is already a container
             * and naming it costs nothing, which is why the screen this replaced
             * had always put it here.
             *
             * So: one identifier, outermost, saying what the screen is showing.
             * Two of the six names are the ones the previous home of this screen
             * used, because the suites that walk it are the same suites.
             */
            .accessibilityIdentifier(stateIdentifier)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The same control, in the same slot, answering the same question as
            // on every other screen: *which machine am I talking about*. With
            // one machine paired it falls back to the screen's own name.
            ToolbarItem(placement: .principal) {
                HostSwitcher(model: model, singleHostTitle: "Copilot")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = model.lastError {
                Banner(text: error, tone: .warning)
                    .onTapGesture { model.dismissError() }
                    .accessibilityIdentifier("copilot.settings.error")
            }
        }
        /*
         * Switching machines abandons what was typed.
         *
         * A connect code is minted at one specific machine and is refused
         * everywhere else, so digits left in the field after a switch can only
         * produce a failure whose message is about the code rather than about
         * the mistake. Clearing them is not tidiness — it is the difference
         * between an empty field and a trap.
         */
        .onChange(of: model.currentHostId) { _, _ in
            code = ""
            awaiting = nil
        }
        .onChange(of: access) { _, now in
            guard now.isConnected, let id = awaiting, id == model.currentHostId else { return }
            awaiting = nil
            model.openCopilot(on: id)
            // And the settings stack goes back to its root behind them. Left
            // pushed, this screen would still be under the Settings pill saying
            // "connect the copilot" about a copilot that is now connected, which
            // is where somebody's Back button would land them.
            model.settingsRoute.removeAll()
        }
    }

    /// The screen's state, for a test that has to say *I arrived* before it says
    /// anything about what is on it. See the note where it is applied.
    private var stateIdentifier: String {
        switch access {
        case .notOffered: return "copilot.settings.notOffered"
        case .notConnected: return "copilot.notConnected"
        case .credentialLost: return "copilot.credentialLost"
        case .connecting: return "copilot.settings.connecting"
        case .notGranted: return "copilot.settings.notGranted"
        case .watch, .direct: return "copilot.settings.connected"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .notOffered:
            notOffered
        case .notConnected:
            connect(lostCredential: false)
        case .credentialLost:
            connect(lostCredential: true)
        case .connecting:
            connecting
        case .notGranted:
            connected(headline: "Connected, and given nothing",
                      icon: "lock",
                      detail: "This phone is connected to \(machine)'s copilot and every box "
                            + "beside it is unticked, so there is nothing it may do yet. Tick one "
                            + "at the \(hostNoun) — Settings, under Remote, on this phone's own "
                            + "card. Watching is the one to start with: it shows what the copilot "
                            + "is doing and carries no power at all.")
        case .watch, .direct:
            connected(headline: grantLine,
                      icon: "checkmark.circle",
                      detail: access == .direct
                          ? "This phone can watch \(machine)'s copilot and ask it to work. What it "
                            + "is allowed to do is decided at the \(hostNoun), and can be changed "
                            + "or taken away there at any time."
                          : "This phone can watch \(machine)'s copilot — what it is doing, what it "
                            + "started, what it was refused. Talking to it is a second switch at "
                            + "the \(hostNoun).")
        }
    }

    // MARK: - The states

    /**
     * A machine whose build has no copilot in it.
     *
     * No code field, because there is nothing on that computer to mint one with.
     * This is the one state on this screen with no action on it, and saying so
     * is the action: the thing that changes the answer is an update over there.
     */
    private var notOffered: some View {
        Card {
            Label("No copilot on \(machine)", systemImage: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("\(machine) is running a version of \(Brand.name) without a copilot in it. "
                 + "Update the \(hostNoun) and it will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /**
     * **The Connect screen**, moved here whole from `CopilotView`.
     *
     * The wording is unchanged because it was doing real work, and each sentence
     * answers a thing somebody would otherwise get wrong:
     *
     *  - **the copilot is a second connection**, not a permission on the one this
     *    phone already has. Somebody who has paired their phone and can run ten
     *    terminals on it will reasonably assume the copilot came with them; it
     *    did not, deliberately, and *"connecting copilot will be a separate
     *    connection than the sessions"* is why.
     *  - **where the code comes from** — Settings → Remote, on that machine, on
     *    this phone's own card. A screen that said "enter your code" with no
     *    address is how somebody concludes the feature is broken.
     *  - **what connecting hands over**, before it is handed over rather than
     *    after. The tiers are chosen at the machine when the code is minted, so
     *    this cannot promise a particular set — what it can say is that the
     *    person minting it decides, and that confirmations may end up here.
     *  - **the code is short-lived and single-use**, so somebody who fumbles it
     *    knows to ask for another rather than retyping the dead one.
     *
     * `lostCredential` is the same screen with the first sentence replaced. The
     * desktop holds a record for this device and this phone does not hold the
     * key — restored from a backup, or a Keychain item that would not read — and
     * the remedy is *a new code*, not a retry, because the credential is sent
     * exactly once and nothing on that machine can show it again.
     */
    private func connect(lostCredential: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 12)

            Text(lostCredential ? "Connect this phone again" : "Connect the copilot")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.bottom, 8)

            Text(lostCredential
                 ? "\(machine) still has this phone on its copilot list, but this phone no longer "
                    // No markdown emphasis: this string is built by
                    // interpolation, so it is a `String` rather than a
                    // `LocalizedStringKey`, and SwiftUI would draw the
                    // asterisks. The word carries itself.
                    + "holds the key it was given. It is sent once and cannot be sent again, so "
                    + "ask for a new code at the \(hostNoun) — Settings, under Remote, on this "
                    + "phone's card."
                 : "The copilot is a separate connection from your terminals. Pairing this phone "
                    + "did not include it, on purpose. Open Settings → Remote on \(machine), find "
                    + "this phone, and press “Connect the copilot” — it shows six digits.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)

            Text("Connect code")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
                .padding(.bottom, 10)

            // The same field as the pairing screen, deliberately: same format,
            // same keypad, same self-submit on the sixth digit. Learning a second
            // shape of code entry for the second thing you connect would be this
            // app inventing work.
            TextField("000000", text: $code)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .kerning(8)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.primary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typingCode)
                .accessibilityIdentifier("copilot.connect.field")
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
                .onChange(of: code) { _, value in
                    // Trimmed to six, then submitted on six. The trim is not
                    // cosmetic: a number pad has no length limit of its own, and
                    // a seventh digit landing after the sixth has already gone
                    // would leave a field somebody has to clear before they can
                    // try again.
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }
                        .prefix(Copilot.codeLength))
                    if digits != value { code = digits }
                    guard digits.count == Copilot.codeLength,
                          link?.isConnecting != true else { return }
                    typingCode = false
                    submitCode()
                }
                .padding(.bottom, 10)

            Button {
                typingCode = false
                submitCode()
            } label: {
                HStack(spacing: 7) {
                    if link?.isConnecting == true {
                        ProgressView().controlSize(.small).tint(Theme.onAccent)
                    } else {
                        Image(systemName: "arrow.right")
                    }
                    Text(link?.isConnecting == true ? "Checking that code…" : "Connect")
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .background(Theme.accent.opacity(code.isEmpty ? 0.28 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(code.isEmpty ? Theme.secondary : Theme.onAccent)
            .disabled(code.isEmpty || link?.isConnecting == true)
            .accessibilityIdentifier("copilot.connect.submit")
            .padding(.bottom, 14)

            Text("A connect code is good for one minute and one use. What it grants is chosen at "
                 + "the \(hostNoun) when the code is made — watching, working, or also answering "
                 + "the confirmations that would otherwise wait at that machine. Whoever mints it "
                 + "can disconnect this phone again at any time, without unpairing it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The credential is on its way, or the socket is down and it cannot be.
    /// Drawn as a state rather than left as an empty screen, because an empty
    /// screen with no explanation is indistinguishable from a broken one.
    private var connecting: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.secondary)
                Text(model.connection.isLive
                     ? "Opening the copilot on \(machine)…"
                     : "Waiting for \(machine) to come back.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primary)
            }
            Text("This phone is connected to \(machine)'s copilot and holds the key for it. "
                 + "Nothing needs a code — the conversation comes back on its own when that "
                 + "\(hostNoun) does.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /**
     * Connected, in one card, with the one control that belongs on it.
     *
     * There is deliberately no Disconnect button beside it. Asad, on the item
     * that used to be the closest thing to one: *"Why do we have Close the
     * copilot here? It doesn't make any sense."* And nothing this phone can do
     * on its own would honestly be called disconnecting: dropping the credential
     * here leaves the record standing at the machine, so the phone would say
     * "disconnected" while that computer still lists it. Ending the connection is
     * done where it was granted — the sentence on the connect screen has always
     * said so — and the phone's own total revoke is Forget this machine, on
     * Machines, which drops everything including this.
     */
    private func connected(headline: String, icon: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Label(headline, systemImage: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.openCopilot()
            } label: {
                Text("Open the copilot")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .accessibilityIdentifier("copilot.settings.open")

            Text("The copilot has a pill of its own in the bar below while it is connected. "
                 + "Disconnecting this phone is done at the \(hostNoun) that gave it the code — "
                 + "or here, by forgetting the machine altogether under Machines.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// What this connection may do, in outcomes rather than tier names — the same
    /// line the conversation's own state card carries, so the two screens cannot
    /// describe one grant differently.
    private var grantLine: String {
        let grant = link?.grant ?? .none
        var parts = ["Connected"]
        if grant.canWatch { parts.append("watching") }
        if grant.canDirect { parts.append("can ask it to work") }
        if grant.canAnswer { parts.append("answers confirmations here") }
        return parts.joined(separator: " · ")
    }

    /// The field keeps its digits when the frame did not go, and loses them when
    /// it did: a code is single-use, so leaving a spent one in the field invites
    /// a second tap that can only fail.
    private func submitCode() {
        guard link?.connect(code: code) == true else { return }
        code = ""
        awaiting = model.currentHostId
    }
}

/// A card holding a headline and a sentence. The design brief's rule, once: a
/// card is a fill with a radius, not an outline, and separation is space before
/// it is ever a line.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
