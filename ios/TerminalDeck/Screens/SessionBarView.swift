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

    /// The sheet of logins, when the chip has been pressed.
    @State private var picking = false

    var body: some View {
        // Nothing known is nothing drawn — not an empty row, which reads as a
        // rendering fault rather than as a decision.
        if bar.plan == nil && bar.context == nil && bar.account == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                if let plan = bar.plan { ring(plan) }
                if let context = bar.context { contextBar(context) }
                if let account = bar.account { chip(account) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
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

    private func chip(_ account: WireAccount) -> some View {
        Button {
            picking = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(SessionBarView.tint(account.color))
                    .frame(width: 8, height: 8)
                Text(account.name)
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
        .accessibilityLabel("Account: \(account.name)")
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

    /// Whole percent, never a decimal on a phone.
    static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func percent(_ value: Double) -> String { SessionBarView.percentText(value) }
}

/**
 * Which login this session runs as, and the way to change it.
 *
 * A sheet rather than a menu, because on a phone the list can be four rows long
 * and a `Menu` puts them under the finger that opened it. No header, no
 * explanation, no note about what switching does — the rows are the screen.
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
        Button {
            dismiss()
            if !chosen { bar.switchTo(account.id) }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(SessionBarView.tint(account.color))
                    .frame(width: 9, height: 9)
                Text(account.name)
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
                if chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(foreign)
        .opacity(foreign ? 0.4 : 1)
        .accessibilityIdentifier("session.account.\(account.id)")
    }
}
