/**
 * Connect GitHub — on the **host**, driven from this phone.
 *
 * ## What this is, and the re-architecture behind it
 *
 * The GitHub account used to live on the phone: this device held a token and
 * answered git logins for every machine it was paired with. That whole proxy is
 * gone. The account lives on the machine now — it signs in, holds its own token
 * and spends it on its own pushes — and this phone only *drives* that: it reads
 * the host's status, starts a sign-in over there, cancels one, or signs the host
 * out. Nothing here ever holds a secret.
 *
 * ## The mount API
 *
 * A standalone card, so the server/machine detail page can drop it in wherever
 * its layout wants without this view knowing anything about that layout:
 *
 * ```swift
 * ConnectGitHubView(host: hostLink)
 * ```
 *
 * `host` is the `HostLink` for the machine on screen. This view reaches its
 * `github` client (`GitHubLink`), asks it to read once when the card appears,
 * and renders whatever state comes back. It paints no page background of its own
 * — it is one `Theme.surface` card meant to sit on the page's tinted ground
 * beside the other cards, matching `ServerDetailView`'s idiom exactly.
 *
 * Over a machine whose welcome did not advertise `github`, it renders nothing —
 * an older host or a guest gets the page it always had, never a control that
 * reaches a capability the socket will refuse.
 *
 * ## The states
 *
 *  - **Loading** — asked, nothing back yet. A quiet line, no controls.
 *  - **Ready** — nothing connected, an App is configured. A Connect button.
 *  - **Signing in** — the host reported a device code. The code, big and
 *    selectable, with copy and open-in-browser, and a Cancel.
 *  - **Connected** — `@login`, the profile if the host has it, a link to choose
 *    repositories, and Disconnect.
 *  - **No App configured** — the host has no GitHub App. The host's sentence,
 *    and deliberately no Connect button: there is nothing behind it.
 *
 * A `failure` sentence, if the host sent one, shows on top of any state.
 */

import SwiftUI
import UIKit

struct ConnectGitHubView: View {
    let host: HostLink

    @Environment(\.openURL) private var openURL

    var body: some View {
        let github = host.github
        Group {
            if github.offered {
                card(github)
            }
        }
        .task(id: host.id) { github.ensureRead() }
    }

    // MARK: - The card

    @ViewBuilder
    private func card(_ github: GitHubLink) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("connectGitHub.title")

            if let state = github.state {
                content(state, github)
            } else {
                loading
            }

            if github.timedOut {
                note("This machine did not answer. Try again.", tone: Theme.warning)
                    .accessibilityIdentifier("connectGitHub.timeout")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func content(_ state: GitHubHostWire, _ github: GitHubLink) -> some View {
        if let pending = state.pending {
            signingIn(pending, state, github)
        } else if state.connected {
            connected(state, github)
        } else if !state.appConfigured {
            notConfigured(state)
        } else {
            ready(state, github)
        }
    }

    // MARK: - Loading

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the machine's GitHub…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityIdentifier("connectGitHub.loading")
    }

    // MARK: - Ready to connect

    @ViewBuilder
    private func ready(_ state: GitHubHostWire, _ github: GitHubLink) -> some View {
        Text("Connect a GitHub account on this machine. It signs in over there and uses it for git in your sessions — this phone never holds the token.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)

        primaryButton(title: github.working ? "Starting…" : "Connect GitHub",
                      symbol: "arrow.right.circle",
                      working: github.working,
                      identifier: "connectGitHub.connect") {
            github.connect()
        }

        failureLine(state)
    }

    // MARK: - Signing in

    @ViewBuilder
    private func signingIn(_ pending: GitHubPending, _ state: GitHubHostWire, _ github: GitHubLink) -> some View {
        Text("On the machine, open GitHub and enter this code:")
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text(pending.userCode)
            .font(.system(size: 32, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.primary)
            .textSelection(.enabled)
            .padding(.vertical, 2)
            .accessibilityIdentifier("connectGitHub.code")

        HStack(spacing: 10) {
            secondaryButton(title: "Copy code", symbol: "doc.on.doc",
                            identifier: "connectGitHub.copy") {
                UIPasteboard.general.string = pending.userCode
            }
            secondaryButton(title: "Open GitHub", symbol: "safari",
                            identifier: "connectGitHub.open") {
                openURL(pending.verificationURI)
            }
        }

        Text(pending.verificationURI.absoluteString)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .truncationMode(.middle)

        Text("It finishes on its own once the code is entered — you do not have to stay here.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)

        plainButton(title: github.working ? "Cancelling…" : "Cancel sign-in",
                    working: github.working,
                    tone: Theme.secondary,
                    identifier: "connectGitHub.cancel") {
            github.cancel()
        }

        failureLine(state)
    }

    // MARK: - Connected

    @ViewBuilder
    private func connected(_ state: GitHubHostWire, _ github: GitHubLink) -> some View {
        HStack(spacing: 12) {
            avatar(state.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(state.login ?? "")")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("connectGitHub.login")
                if let sub = subtitle(state) {
                    Text(sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }

        if let installURL = state.installURL, let url = URL(string: installURL) {
            Button {
                openURL(url)
            } label: {
                Text("Choose repositories on GitHub")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("connectGitHub.chooseRepos")
        }

        plainButton(title: github.working ? "Disconnecting…" : "Disconnect",
                    working: github.working,
                    tone: Theme.critical,
                    identifier: "connectGitHub.disconnect") {
            github.disconnect()
        }

        failureLine(state)
    }

    // MARK: - No App configured

    @ViewBuilder
    private func notConfigured(_ state: GitHubHostWire) -> some View {
        note(state.failure ?? "This machine has no GitHub App set up, so there is nothing to connect to yet.",
             tone: Theme.warning)
            .accessibilityIdentifier("connectGitHub.unavailable")
    }

    // MARK: - Pieces

    @ViewBuilder
    private func failureLine(_ state: GitHubHostWire) -> some View {
        if let failure = state.failure {
            note(failure, tone: Theme.warning)
                .accessibilityIdentifier("connectGitHub.failure")
        }
    }

    private func avatar(_ urlString: String?) -> some View {
        let url = urlString.flatMap { URL(string: $0) }
        return AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.faint)
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func subtitle(_ state: GitHubHostWire) -> String? {
        // The profile name if there is one, otherwise how the host got the
        // account — display text, never branched on.
        if let name = state.name, !name.isEmpty { return name }
        if let source = state.source, !source.isEmpty { return source }
        return nil
    }

    private func note(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Buttons

    private func primaryButton(title: String, symbol: String, working: Bool,
                               identifier: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if working {
                    ProgressView().controlSize(.small).tint(Theme.onAccent)
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.onAccent)
        .background(Theme.accent.opacity(working ? 0.6 : 1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(working)
        .accessibilityIdentifier(identifier)
    }

    private func secondaryButton(title: String, symbol: String,
                                 identifier: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.primary)
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier(identifier)
    }

    private func plainButton(title: String, working: Bool, tone: Color,
                             identifier: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small).tint(tone) }
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tone)
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(working)
        .accessibilityIdentifier(identifier)
    }
}
