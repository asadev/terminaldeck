/**
 * A ring, a bar, a name. The row over a session on the phone.
 *
 * The same three facts the desktop's own bar carries about the session you are
 * inside, and the same three he asked for by name:
 *
 *   > *"give it a maybe ring icon will be better, just like cloud, like this
 *   > ring"* — the usage figure.
 *   > *"context window should be a bar instead of numbers. It should be a bar."*
 *   > *"bring the account selection here for the remote sessions too."*
 *
 * ## What it deliberately does not draw
 *
 * Words. There is no label beside a figure, no "not reported", no reason for an
 * absence, no caption under the row. A chip whose figure is unknown is
 * **absent**. The only strings in this file are the ones VoiceOver needs, which
 * are not on the screen. That is his rule, stated four times in one recording,
 * and it is the one most often broken while fixing something else.
 *
 * ## Above the terminal, and above the conversation too
 *
 * These are facts about the *session*, not about which way it is being read, so
 * the row does not move or disappear when the mode changes.
 */

import SwiftUI

struct SessionBarView: View {
    let bar: SessionBarLink

    /**
     * The chosen terminal scheme, for this row's ground.
     *
     * Held as a property rather than reached for inside `body`, the way
     * `TerminalScreen` holds it, because `@Observable` only re-runs a body that
     * read the object — a row that took `.shared` inline would keep the colour it
     * was built with while the terminal three points below it changed.
     */
    var themes: TerminalThemeStore = .shared

    /// The sheet of logins, when the chip has been pressed.
    @State private var picking = false

    var body: some View {
        // Nothing known is nothing drawn — not an empty row, which reads as a
        // rendering fault rather than as a decision. `freshPlan` / `freshContext`
        // rather than the raw figures: *"usage should be the best version"* — a
        // ring or bar appears only while its reading is still the machine's
        // current answer, and the account chip keeps the row present so
        // withdrawing a stale figure never jolts the whole strip.
        if bar.freshPlan == nil && bar.freshContext == nil && bar.account == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                if let plan = bar.freshPlan { ring(plan) }
                if let context = bar.freshContext { contextBar(context) }
                if let account = bar.account { chip(account) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            /*
             * The terminal's ground, not the app's card.
             *
             * Asad, about the session screen: *"everything should be black, not
             * just base colour… background, full page should be black."* This row
             * is the one strip between the navigation bar and the emulator, and
             * with `Theme.surface` it was the last white band on a black page —
             * `#ffffff` across `#000000`, photographed, and the first thing the eye
             * lands on.
             *
             * It reads as chrome rather than as a card: full width, hard edges,
             * and the same ground the chrome above and the terminal below take.
             * The chips inside it keep their own fills — *"only buttons can stay
             * as they are."* Which half of `Theme` those fills resolve to is
             * decided for the whole screen by `TerminalChrome`, from the scheme
             * rather than from the phone, so a black ground here never carries
             * the light theme's near-black ink.
             *
             * **And no hairline under it.** There was one, drawn when this row
             * sat on `Theme.surface` and genuinely was a different surface from
             * the terminal beneath it. Once both take the scheme's paper the
             * line is drawing a boundary that no longer exists:
             *
             * > *"Remove this separator between header and terminal."*
             *
             * One page, one colour, and nothing ruled across it.
             */
            .background(TerminalChrome.paper(themes.selected))
            .accessibilityIdentifier("session.bar")
            .sheet(isPresented: $picking) {
                AccountSheet(bar: bar) { picking = false }
            }
        }
    }

    // MARK: - The ring

    /**
     * The usage figure, as a ring with the number inside it.
     *
     * His explicit choice and the fourth way this figure has been drawn:
     * *"just like cloud, like this ring."* Pressing it is a `refresh`, which is
     * the one reading that costs anything on the far machine — it boots a whole
     * Claude Code over there — so it happens because a finger asked and never on
     * its own.
     */
    private func ring(_ used: Double) -> some View {
        Button {
            bar.refresh()
        } label: {
            ZStack {
                Circle()
                    .stroke(Theme.hairline, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: used)
                    // From the top, clockwise. A ring that started at three
                    // o'clock would read as a different figure at a glance from
                    // the one on his Mac.
                    .rotation(.degrees(-90))
                    .stroke(ringInk(used), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Text(percent(used))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.primary)
            }
            .frame(width: 28, height: 28)
            .opacity(bar.busy ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(bar.busy)
        .accessibilityLabel("Usage \(percent(used))")
        .accessibilityIdentifier("session.bar.ring")
    }

    /// The same three bands the desktop reads a plan window in. Colour is the
    /// only thing that says *near the end* without a sentence.
    private func ringInk(_ used: Double) -> Color {
        used >= 0.9 ? Theme.critical : used >= 0.75 ? Theme.warning : Theme.accent
    }

    // MARK: - The context bar

    /**
     * The context window, as a bar.
     *
     * *"context window should be a bar instead of numbers."* The number stays
     * beside it because a bar with no figure cannot be compared with the one on
     * his Mac — and one figure is not a statement.
     */
    private func contextBar(_ used: Double) -> some View {
        HStack(spacing: 6) {
            GeometryReader { frame in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(ringInk(used))
                        .frame(width: max(2, frame.size.width * used))
                }
            }
            .frame(width: 46, height: 5)
            Text(percent(used))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent(used))")
        .accessibilityIdentifier("session.bar.context")
    }

    // MARK: - The account

    /**
     * Which login this session runs as.
     *
     * `accountLoginLabel`, never `account.name`. The name of the machine's own
     * install is a key `systemProfileId` generates — "Default", "Default (Codex
     * CLI)" — and this chip is the one control whose entire job is saying whose
     * account a session is on. Asad, 2026-08-26, pressing it:
     *
     *   > *"when we click on this link it should clearly mention the name of the
     *   > account here instead of saying default — name of the account should be
     *   > there."*
     *
     * The label goes through the same function the sheet's rows do, which is the
     * property worth having: the chip and the row you press it to reach can
     * never come to disagree about what one login is called.
     *
     * `lineLimit(1)` and nothing wider: an address is long, the bar is a phone
     * screen, and the truncation is the price of printing the real answer rather
     * than a short wrong one. VoiceOver gets the whole label, untruncated.
     */
    private func chip(_ account: WireAccount) -> some View {
        let login = accountLoginLabel(account)
        return Button {
            picking = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(SessionBarView.tint(account.color))
                    .frame(width: 8, height: 8)
                Text(login)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceHigh, in: Capsule())
            .opacity(bar.busy ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(bar.busy)
        .accessibilityLabel("Account: \(login)")
        .accessibilityIdentifier("session.bar.account")
    }

    /**
     * The dot's colour.
     *
     * `WireAccount.color` is a custom property **name** — `--accent`,
     * `--status-completed` — and never a colour value, which is what keeps the
     * palette in one place and stops a machine at the other end of a socket
     * painting anything on this screen. Matched against the desktop's own
     * `PROFILE_COLORS` rather than parsed: a name this build has never seen
     * takes the neutral fill rather than nothing at all, so a desktop that grows
     * a seventh colour draws a grey dot here instead of an invisible one.
     */
    static func tint(_ color: String?) -> Color {
        switch color {
        case "--accent": return Theme.accent
        case "--status-completed": return Theme.positive
        case "--status-waiting": return Theme.warning
        case "--status-input": return Theme.warning
        case "--color-warning": return Theme.warning
        case "--color-critical": return Theme.critical
        default: return Theme.neutralAction
        }
    }

    /**
     * Whether this app can sign an agent out from here — a port of `hasSignOut`
     * in `src/shared/agent-catalog.ts`.
     *
     * Claude and Codex carry a logout command (`claude auth logout`,
     * `codex logout`); Gemini and a plain shell do not. Where there is none the
     * Sign out is **absent**, never drawn and disabled — §4.1, and on this bar
     * doubly so, because the desktop's spoken reason for the missing button
     * would be a sentence, and this row draws none. A provider this build has
     * not heard of falls to false: no button rather than one that runs nothing.
     */
    static func canSignOut(provider: String?) -> Bool {
        switch provider {
        case "claude", "codex": return true
        default: return false
        }
    }

    /// Whole percent, never a decimal on a phone.
    static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func percent(_ value: Double) -> String { SessionBarView.percentText(value) }
}

/**
 * Which login this session runs as, the way to change it, and — since the
 * 2026-08-26 review — the way to sign one out.
 *
 * A sheet rather than a menu, because on a phone the list can be four rows long
 * and a `Menu` puts them under the finger that opened it. No header, no
 * explanation, no note about what switching does — the rows are the screen.
 *
 * The row is now two controls, not one: the name switches the session onto that
 * login, and a trailing **Sign out** signs it out of the machine where that can
 * be done. That is the audit's gap 20 — *"login, logout … we can just manage
 * from this"* — and it mirrors the desktop's `DeviceAccounts`: the machine runs
 * its own logout and the list is read again, this sheet only asks.
 */
private struct AccountSheet: View {
    let bar: SessionBarLink
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(bar.accounts) { account in
                    row(account)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("session.accounts")
    }

    @ViewBuilder
    private func row(_ account: WireAccount) -> some View {
        let chosen = bar.account?.id == account.id
        // A login of a *different* agent, which the far end refuses with a
        // sentence this app does not draw. So the row is not pressable rather
        // than pressable and futile — measured from a phone against a live
        // Claude session, pressing one did nothing, said nothing and left no
        // trace. See `foreignAccount`.
        let foreign = foreignAccount(current: bar.account, account: account)
        /*
         * The login, not the profile's name — the rows he filmed.
         *
         * This sheet is the screen the complaint was made about: three rows
         * reading "Default", "Default (Codex CLI)", "Default (Gemini CLI)", none
         * of which is a name anybody gave a login.
         *
         *   > *"when we click on this link it should clearly mention the name of
         *   > the account here instead of saying default — name of the account
         *   > should be there."*
         *
         * The default `namesTheAgent: true` is deliberate here and not merely
         * inherited: this list is *not* filtered to one agent — it is every
         * login on the far machine — so on a fresh machine all three rows fall
         * to the third rung with no address between them, and without the
         * agent's name all three would read "Your own install". The same caption
         * on three different accounts is the same defect with a politer word in
         * it. See `accountLoginLabel`.
         */
        let login = accountLoginLabel(account)
        /*
         * Sign out, the act the audit found missing (gap 20). Drawn only where
         * it can act, exactly as `DeviceAccounts` gates it: the machine manages
         * its own logins (`logins` advertised), this login is really signed in,
         * and its agent has a logout command. Where any of the three is false the
         * control is **absent** — §4.1 — never a disabled button, and on this
         * sheet never the spoken reason the desktop shows in its place: this row
         * draws no sentence.
         *
         * It is offered even on a foreign row and on the row in use. A foreign
         * login (another agent) cannot be *switched* to and so its switch is
         * dead, but signing it out of the machine is a separate, valid act the
         * far end runs on its own — machine-scoped, not about this session.
         */
        let signedIn = account.signIn?.state == WireSignIn.signedIn
        let canSignOut = bar.canManageLogins && signedIn
            && SessionBarView.canSignOut(provider: account.provider)

        HStack(spacing: 8) {
            Button {
                dismiss()
                if !chosen { bar.switchTo(account.id) }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(SessionBarView.tint(account.color))
                        .frame(width: 9, height: 9)
                    Text(login)
                        .foregroundStyle(Theme.primary)
                    Spacer(minLength: 0)
                    if chosen {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(foreign || bar.busy)
            .opacity(foreign ? 0.4 : 1)
            .accessibilityIdentifier("session.account.\(account.id)")

            if canSignOut {
                // A sibling of the switch, never nested inside its label: a
                // Button in a Button is a hit-testing coin toss, and the coin
                // here decides between switching login and signing one out. The
                // sheet stays open — the row losing its Sign out on the next read
                // is the confirmation, the way a switch's is the moved checkmark.
                Button {
                    bar.signOut(account.id)
                } label: {
                    Text("Sign out")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.critical)
                        .padding(.leading, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(bar.busy)
                .accessibilityLabel("Sign \(login) out")
                .accessibilityIdentifier("session.account.signout.\(account.id)")
            }
        }
    }
}
