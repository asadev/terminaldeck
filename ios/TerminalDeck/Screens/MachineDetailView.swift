/**
 * One machine, and everything this phone knows about it.
 *
 * > *"before we had a list of connected servers where we could click and go
 * > inside server info and settings now its gone."*
 *
 * It had not gone — the **Servers** section is still on the Machines screen,
 * directly under the machines. What it needs is a server record, and only an SSH
 * login makes one: a machine paired with six digits becomes a *machine* and
 * never a *server*, so for that half of the list the section is empty and hidden
 * and the row leads nowhere. Tapping it selected the machine and that was all.
 *
 * That is a dead end whichever way the list was reached, and this is the missing
 * half: every row now opens onto what this phone actually knows about the
 * machine behind it.
 *
 * ## Why it is not `ServerDetailView`
 *
 * That screen is about **a server this phone can administer over SSH** — its
 * disk, its services, install/start/stop/update, the host key it proved itself
 * with. All of it comes from a `StoredServer` and an open SSH session, and a
 * code-paired Mac has neither. Pointing this row at that screen would draw an
 * empty shell of controls that could never act.
 *
 * So this is the other axis: what the **wire** says. Kind, build, platform,
 * fingerprint, what it is serving, what it will let this phone do. A machine
 * that is *also* a server gets a row that crosses over to the other screen,
 * which is where the acting lives.
 *
 * ## Capabilities are shown, and that is deliberate
 *
 * A phone that cannot start a session on a machine currently discovers it by
 * finding no button. The wire already answers *why* — the capability list — and
 * a person who has just been surprised by a missing control is entitled to the
 * machine's own answer rather than a guess about their own device kind.
 */

import SwiftUI

struct MachineDetailView: View {
    let model: DeckModel
    let hostID: String

    private var host: HostLink? { model.host(hostID) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let host {
                        identity(host)
                        /*
                         * **The six are not here any more — they are on Menu.**
                         *
                         * They were, for about an hour: *"inside the server page
                         * it is most probably for the server setting, server
                         * related stuff — not all the features should be inside
                         * the server page."* He is right, and the mistake was a
                         * category one rather than a placement one. This page is
                         * about *a machine as a machine* — what it is, what it
                         * will let this phone do. Files and Source control are
                         * about **work**, and burying them behind Settings →
                         * Machines → ⓘ put the two most-used doors three taps
                         * from anywhere.
                         */
                        capabilities(host)
                        github(host)
                        crossing(host)
                    } else {
                        // Forgotten while this screen was open — from the `…` on
                        // the row behind it, or from another device.
                        Text("This machine is not paired with this phone any more.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, 8)
                    }
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(host.map { model.label(for: $0) } ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - What it is

    @ViewBuilder
    private func identity(_ host: HostLink) -> some View {
        caption("This machine")
        card {
            plain("Kind", host.hostKind.noun.capitalized)
            line
            plain("System", host.hostPlatform.noun)
            line
            // Absent from every host before 0.10.0, and absent stays absent
            // rather than guessing — the same rule the About row follows.
            plain("Build", host.hostAppVersion ?? "Older than 0.10.0")
            line
            plain("Connection", host.connection.label)
        }

        /*
         * **No fingerprint row, and that is a fact about the app rather than a
         * gap on this screen.**
         *
         * The pairing screen shows one — it comes off the sealed channel at the
         * moment of the handshake — and nothing keeps it: `StoredCredential`
         * holds the token and the label and no digest. Inventing a source here
         * would mean either recomputing it from a key this phone does not store,
         * or printing something that looks like a fingerprint and is not, which
         * is worse than the absence on the one screen whose whole job is
         * answering *is this the machine I think it is*.
         *
         * Worth carrying to the wire eventually: the machine already sends its
         * host id, and a digest beside it would cost one field.
         */
    }

    // MARK: - What it will let this phone do

    @ViewBuilder
    private func capabilities(_ host: HostLink) -> some View {
        caption("What this phone may do here")
        card {
            can("Start sessions", host.canCreateSessions)
            line
            can("Choose folders", host.canPickFolders)
            line
            can("Reach its ports", host.canBrowseLocalhost)
            line
            can("Open pages in its browser", host.canOpenPagesThere)
            line
            can("Send files", host.canSendFiles)
        }
    }

    /**
     * **Connect GitHub, on a relay-paired machine.**
     *
     * Audit gap 21: the Connect-GitHub card was drawn only inside
     * `ServerDetailView`, which needs an SSH server record — so a Mac or PC
     * paired with six digits, the machine Asad actually reviews on, had no GitHub
     * UI at all, even though the `github` capability is advertised over the relay
     * just the same. *"connect server, then app, then GitHub, so it's linked
     * there. The host owns it, not the phone."* This is the same card
     * `ServerDetailView` mounts, reached the same way — `host.github` — and gated
     * the same way: it draws nothing until the host advertises `github`, so an
     * older host or a guest gets the page it always had.
     *
     * The `offered` check here is only so the section's top spacing is added when
     * there is a card to space, never as a 24-point gap on a machine without one.
     * The card itself re-checks and reads its own state.
     */
    @ViewBuilder
    private func github(_ host: HostLink) -> some View {
        if host.github.offered {
            ConnectGitHubView(host: host)
                .padding(.top, 24)
        }
    }

    /**
     * The row that crosses to the other screen, when there is one to cross to.
     *
     * A machine that was reached by an SSH login is *also* a server, and the
     * things somebody wants to do to a server — install, start, stop, update,
     * remove — all live on `ServerDetailView` behind that login. Drawn only when
     * the crossing exists, rather than drawn and refused.
     */
    @ViewBuilder
    private func crossing(_ host: HostLink) -> some View {
        if let server = model.serverConnector.servers.first(where: { $0.linkedHostId == host.id }) {
            caption("As a server")
            card {
                NavigationLink(value: DeckModel.SettingsRoute.server(server.id)) {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24)
                        Text("Server settings")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                        Spacer(minLength: 8)
                        Text(server.name)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.faint)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("machine.server")
            }
        }
    }


    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed, and that is not a preference.
     *
     * `SectionCaption`, `SettingsGroup` and `SettingsDivider` are **private to
     * `DeckTabs.swift`** — a screen that reached for them would have to live in
     * that file, which is the argument `AppLockScreen` makes about the same
     * three names. These are the same shapes at the same metrics: 11pt kerned
     * caption, a `Theme.surface` card at radius 20, and a hairline inset to the
     * label rather than to the card's edge.
     */
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    // MARK: - Rows

    private func plain(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// A capability, as a yes or a no rather than a chip somebody has to decode.
    private func can(_ title: String, _ yes: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Image(systemName: yes ? "checkmark" : "minus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(yes ? Theme.positive : Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(yes ? "yes" : "no")")
    }
}
