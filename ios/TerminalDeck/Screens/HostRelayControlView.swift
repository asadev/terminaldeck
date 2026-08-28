/**
 * **Manage the host over the relay** — status, restart, stop — on the server
 * page, when the server is a connected machine.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A server page reaches one box by two roads: an SSH address it was added with,
 * and the relay it is paired over. Asad's SSH address is a Tailscale name
 * (`imza-pc-wsl`) that drops on its own — and when it does, the SSH survey on
 * this page reports the box as unreachable while every session on it is still
 * running over the public relay. His rule is that the relay *is* the network, so
 * the status a headless server has no screen to show, and the restart/stop it
 * has no screen to press, are answered here over the relay whenever the server
 * is a connected machine — independent of whether its SSH address answers.
 *
 * It is the sibling of `ConnectGitHubView`: mounted on the server page, gated on
 * a live `HostLink` that advertises the capability, and reading its whole state
 * off `HostControlLink` over the wire. It draws **nothing** over a machine whose
 * welcome did not name `host.control` — an older host, still reachable only over
 * SSH — so the server page falls back to its SSH lifecycle controls there, and
 * never shows two Restart buttons (`HostStepCard` withholds its own SSH row when
 * this one is live).
 *
 * There is no Start here on purpose: a stopped host is not connected over the
 * relay, so there is nothing on this wire to start — that stays on the SSH page.
 */

import SwiftUI

struct HostRelayControlView: View {
    let host: HostLink

    var body: some View {
        let control = host.hostControl
        Group {
            // Only when the machine is connected as a machine AND speaks the
            // capability. Both are required: a machine that dropped off the relay
            // cannot be restarted over it, and an older host that never learned
            // the verb must fall back to SSH rather than meet a dead button.
            if host.connection.isLive, control.offered {
                card(control)
            }
        }
        .task(id: host.id) { control.ensureRead() }
    }

    // MARK: - The card

    @ViewBuilder
    private func card(_ control: HostControlLink) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The host, over the relay")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("hostRelay.title")

            if let state = control.state {
                statusLines(state)
            } else {
                loading
            }

            // The restart Asad asked for by name — "one button to restart the
            // terminal deck" — and stop beside it. Over the relay, so they reach
            // the box even when this server's SSH address is offline.
            Text("Reached over the relay, so these work even when this server's address is offline.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            action("Restart it", "arrow.clockwise.circle",
                   identifier: "hostRelay.restart",
                   disabled: control.working) {
                control.restart()
            }
            HStack(spacing: 10) {
                action("Stop", "stop.circle",
                       identifier: "hostRelay.stop",
                       disabled: control.working, compact: true) {
                    control.stop()
                }
                if control.working {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                }
                Spacer(minLength: 0)
            }

            if let note = control.note {
                sentence(note, tone: Theme.secondary)
                    .accessibilityIdentifier("hostRelay.note")
            }
            if control.timedOut {
                // Not "it failed": a restart drops the connection as it acts, so
                // the confirmation can race the drop. It is coming back — see
                // `HostControlLink`.
                sentence("No word came back before the connection dropped — the host may be on its way back up. Pull down to look again.",
                         tone: Theme.warning)
                    .accessibilityIdentifier("hostRelay.timeout")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Status

    @ViewBuilder
    private func statusLines(_ state: HostControlWire) -> some View {
        // It answered over the relay, so it is running — the whole point of the
        // card is that this is true even when the SSH survey above could not say
        // so.
        HStack(spacing: 6) {
            Circle().fill(Theme.positive).frame(width: 7, height: 7)
            Text(state.version.isEmpty ? "Running" : "Running \(state.version)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("hostRelay.status")
        }
        Text(detailLine(state))
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detailLine(_ state: HostControlWire) -> String {
        var parts: [String] = []
        if state.uptimeSeconds > 0 { parts.append("up for \(Self.spell(state.uptimeSeconds))") }
        switch state.managed {
        case .systemd: parts.append("kept running by systemd, so a restart comes back on its own")
        case .direct: parts.append("started directly, so a restart re-launches it")
        case .unknown: break
        }
        return parts.isEmpty ? "Reached over the relay." : parts.joined(separator: " · ")
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reaching the host over the relay…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityIdentifier("hostRelay.loading")
    }

    // MARK: - Parts

    private func sentence(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String,
                        _ symbol: String,
                        identifier: String,
                        disabled: Bool,
                        compact: Bool = false,
                        act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if !compact { Spacer(minLength: 0) }
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.horizontal, compact ? 14 : 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Theme.secondary : Theme.onAccent)
        .background(Theme.accent.opacity(disabled ? 0.28 : 1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
    }

    private static func spell(_ seconds: Int) -> String {
        let days = seconds / 86400
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = seconds / 3600
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
