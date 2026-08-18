/**
 * Everything the wire says about one session, on one screen.
 *
 * The desktop puts this under the session's name as two chips — `FolderChip`
 * says *where* it runs and `AccountChip` says *who* it runs as — plus a status
 * line in its toolbar. On a phone there is no room for chips under a title, and
 * the answer is not to shrink them: it is a sheet you can reach from the row and
 * from the session itself, holding the same facts with room to read them.
 *
 * ## What it does *not* offer, and why each one is missing
 *
 * This screen is where somebody will look for the two things they cannot do, so
 * it is worth writing down why they are not here rather than leaving the gap to
 * be rediscovered.
 *
 *  - **Renaming a session.** There is no verb for it. `protocol.ts` carries
 *    `list`, `attach`, `input`, `resize`, `create`, and the capability
 *    extensions — nothing that changes a session's title, and the desktop's own
 *    titles come from `PtyManager` naming a session after its folder. A field
 *    here would have nowhere to send what was typed in it.
 *  - **Choosing which account a session runs as.** `create` carries `cwd`,
 *    `cols`, `rows` and `provider`; it does not carry an account, and no frame
 *    reports which one a running session got. The desktop's `AccountChip` reads
 *    a config directory that only exists on that machine. What this screen can
 *    honestly say is the *other* account question — which login this phone would
 *    answer a git prompt with — and it says exactly that, in those words, rather
 *    than a line somebody could read as "this session runs as".
 *
 * Both are named in the report that came with this change rather than faked with
 * a control that would refuse.
 *
 * ## The folder is a control, not a caption
 *
 * The same rule the desktop's chip follows: it does not move the running session
 * — a pty has one working directory for its whole life — so what it offers is a
 * new session in that folder, and the dev server for it. That is the honest
 * version of "change the folder", and it is the version the wire can serve.
 */

import SwiftUI
// For `UIPasteboard`. The folder path is the one string on this screen somebody
// wants in another app — a message, a note, the terminal on their own machine.
import UIKit

struct SessionDetailView: View {
    let model: DeckModel
    /// Which machine, named rather than inferred: session ids are unique per
    /// machine and nothing makes them unique across machines. Same rule as
    /// `TerminalScreen`.
    let hostID: String
    let sessionID: String
    /// Offered only where opening it is somewhere to go — from the list. Nil
    /// when the sheet was raised from inside the session itself, where a button
    /// leading to the screen underneath is furniture.
    let open: (() -> Void)?
    let dismiss: () -> Void

    @State private var copied: String?

    private var host: HostLink? { model.host(hostID) }
    private var session: RemoteSession? { host?.session(sessionID) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    if let session, let host {
                        VStack(alignment: .leading, spacing: 0) {
                            heading(session)
                            where_(session, host: host)
                            about(session, host: host)
                            machine(host)
                            gitLogins(host)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // The session ended, or the machine was unpaired out from
                        // under this sheet. Both are real sequences; neither is a
                        // reason to draw a screen of blanks.
                        ContentUnavailableView("That session is gone",
                                               systemImage: "terminal",
                                               description: Text("It is no longer on this machine's list."))
                            .padding(.top, 60)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)

                if let copied {
                    VStack {
                        Spacer()
                        Text(copied)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 28)
                            .accessibilityIdentifier("detail.toast")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("detail.done")
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Sections

    /// The name, and what it is doing, in the two sizes the rest of the app uses
    /// for exactly this pair.
    private func heading(_ session: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                StatusDot(status: session.status)
                Text(SessionDetails.statusLine(session))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("detail.status")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /**
     * Where it runs — the folder, and the two things this phone can honestly do
     * with one.
     *
     * The path is drawn whole rather than truncated. It is the answer to "which
     * checkout is this", it is the one string on this screen somebody may want
     * to read character by character, and a sheet is where there is finally room
     * for it — the list row above truncates from the head because a row has no
     * room, which is a different screen making a different trade.
     */
    @ViewBuilder
    private func where_(_ session: RemoteSession, host: HostLink) -> some View {
        DetailCaption("Folder")
        DetailCard {
            Button {
                UIPasteboard.general.string = session.cwd
                show("Copied the folder path.")
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(SessionDetails.folderName(session.cwd))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Text(session.cwd)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    // Rendered without this and it was a card that copied a path
                    // with nothing on it saying so — a control whose only signal
                    // that it is one is that you happened to press it. The glyph
                    // is the affordance; the whole card stays the target,
                    // because a 20-point icon is not one on a phone.
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Folder \(session.cwd). Copies the path.")
            .accessibilityIdentifier("detail.folder")

            /*
             * A new session in this folder, which is what the desktop's folder
             * chip means by "change the folder".
             *
             * Offered only when the machine is currently granting this device
             * that exact folder. A session's `cwd` is not automatically a folder
             * this phone may start in — the grant is per device and editable on
             * the desktop at any moment — so a button drawn off the session's own
             * path would be one whose only outcome is a refusal on a machine
             * whose grant has since been narrowed.
             */
            if host.startableFolders.contains(session.cwd) {
                DetailDivider()
                Button {
                    host.createSession(in: session.cwd)
                    dismiss()
                } label: {
                    DetailAction(title: "New session here", icon: "plus")
                }
                .buttonStyle(.plain)
                .disabled(!host.canStartSomewhere)
                .accessibilityIdentifier("detail.newHere")
            }
        }

        // The dev server for *this* folder, if the machine has one to talk about.
        // The same row the session list draws, because it is the same fact — and
        // this is the screen somebody is on when they wonder why the port their
        // agent keeps mentioning is not answering.
        if let report = host.devServer(for: session.cwd), report.status != .noDevScript {
            DetailCaption("Dev server")
            DevServerRow(report: report,
                         canTunnel: host.canBrowseLocalhost,
                         start: { host.startDevServer(in: report.folder) },
                         // The browser is a full-screen cover on the list, and
                         // this is a sheet over it. Rather than stacking a cover
                         // on a sheet — which iOS presents but nobody enjoys —
                         // this closes and lets the list open the page.
                         openPort: { _ in dismiss() },
                         openSession: { id in
                             dismiss()
                             model.open(session: id, on: hostID)
                         })
        }
    }

    /// What it is. Four facts, each of them straight off the wire.
    @ViewBuilder
    private func about(_ session: RemoteSession, host: HostLink) -> some View {
        DetailCaption("Session")
        DetailCard {
            DetailRow(name: "Agent", value: session.provider, mono: true)
            DetailDivider()
            DetailRow(name: "Status", value: SessionDetails.statusLine(session), mono: true)
            // Only when the desktop timestamped the row. It has the value in
            // `session-activity.ts` and does not put it on the wire yet, so this
            // appears the day it does and prints nothing until then rather than
            // inventing a time. See `WireCodec.lastActivity`.
            if let line = SessionDetails.activityLine(host.lastActivity[session.id]) {
                DetailDivider()
                DetailRow(name: "Last active", value: line, mono: false)
            }
            DetailDivider()
            // The id, because it is what a deep link carries and what somebody
            // reading a desktop log is looking at. Mono, and allowed to wrap:
            // half an id identifies nothing.
            DetailRow(name: "ID", value: session.id, mono: true, wraps: true)
        }

        if let open {
            DetailCard {
                Button {
                    open()
                } label: {
                    DetailAction(title: "Open session", icon: "terminal")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail.open")
            }
            .padding(.top, 10)
        }
    }

    /// Which machine, which is the question a phone paired with three of them
    /// must never leave open — the same answer the Machines tab gives, here
    /// because a session is only meaningful with a machine attached to it.
    @ViewBuilder
    private func machine(_ host: HostLink) -> some View {
        DetailCaption("Machine")
        DetailCard {
            DetailRow(name: "Name", value: host.label, mono: false)
            DetailDivider()
            // The neutral noun for a desktop that never said what it is —
            // `HostPlatform.unknown` reads "desktop", which is true of every
            // machine this app can reach and singles out none of them.
            DetailRow(name: "Kind", value: host.hostPlatform.noun, mono: false)
            DetailDivider()
            DetailRow(name: "Address", value: host.endpointSummary, mono: true, wraps: true)
        }
    }

    /**
     * The account question this phone can actually answer.
     *
     * Deliberately not labelled as the session's account, because it is not one:
     * the agent's login lives in a config directory on that machine and nothing
     * on this wire reports it. What *is* true, and worth knowing on the screen
     * where somebody is looking at a session that is about to push, is which
     * GitHub this phone would hand over when git on that machine asks — which is
     * the whole of the `credential` capability, running the other way round.
     *
     * Shown only when the machine advertised that it may ask. A machine that
     * never will is one where this sentence would be a promise about nothing.
     */
    @ViewBuilder
    private func gitLogins(_ host: HostLink) -> some View {
        if host.canAskForGitLogins {
            DetailCaption("Git logins")
            DetailCard {
                Button {
                    dismiss()
                    model.showingGitHub = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.gitHubAccount.map { "@\($0.login)" } ?? "Not connected")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.primary)
                            Text(model.gitHubAccount == nil
                                 ? "A push from \(host.label) will not be answered from this phone."
                                 : "Used when git on \(host.label) asks for one.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail.github")
            }
        }
    }

    /// Copy is silent by nature; without this the row feels broken even when it
    /// worked. The same two and a half seconds `TerminalScreen` settled on.
    private func show(_ message: String) {
        withAnimation { copied = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { copied = nil }
        }
    }
}

/* -------------------------------------------------------------------------- */
/* The facts, without a view around them                                       */
/* -------------------------------------------------------------------------- */

/**
 * The lines this screen prints, as functions rather than as view code.
 *
 * Pulled out so they can be checked without a simulator, which matters more than
 * usual here: every one of them is a sentence about somebody's session, two of
 * them have an "and nothing at all" case that is easy to get backwards, and all
 * of them are the sort of thing that is verified by reading rather than by
 * looking. `SessionDetailsTests` pins them.
 */
enum SessionDetails {

    /**
     * What the session is doing, and how it ended if it has.
     *
     * The status vocabulary belongs to the desktop and is free-form on the wire,
     * so it is printed rather than mapped — a build of the desktop newer than
     * this app will send a word that is not in today's list and the honest thing
     * to do with it is show it. The exit code is appended rather than replacing
     * the word, because `exited · exit 1` and `exited · exit 0` are the two
     * facts somebody is actually after and one of them is not visible in the
     * word alone.
     */
    static func statusLine(_ session: RemoteSession) -> String {
        guard let code = session.exitCode else { return session.status }
        return "\(session.status) · exit \(code)"
    }

    /**
     * How long ago the desktop last saw this session do something.
     *
     * Nil when it did not say, and that is the whole reason this returns an
     * optional: the field is read defensively off a row the desktop does not
     * populate yet, so "no timestamp" is the normal answer today and printing
     * "just now" for it would be inventing a fact about somebody's session.
     *
     * `now` is a parameter so the boundaries can be checked at all. With `Date()`
     * baked in, a test for "59 seconds reads as just now" is a test that passes
     * because the clock happened not to tick between two lines.
     */
    static func activityLine(_ epochMilliseconds: Double?, now: Date = Date()) -> String? {
        guard let epochMilliseconds, epochMilliseconds > 0 else { return nil }
        let seconds = now.timeIntervalSince1970 - epochMilliseconds / 1000
        // A machine whose clock is ahead of this phone's produces a negative
        // interval, and "-3m ago" is worse than the vaguest true answer.
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /**
     * The folder's own name — the last component, which is what a person calls
     * the project.
     *
     * Split on both separators rather than through `NSString.lastPathComponent`,
     * because the machine on the other end is as likely to be a Windows PC as a
     * Mac and that method knows only about `/`. A phone paired to a PC used to
     * show `C:\Users\asad\Projects\app` as its own full self in a menu row.
     */
    static func folderName(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }
}

/* -------------------------------------------------------------------------- */
/* Small pieces                                                                */
/* -------------------------------------------------------------------------- */

/// A caption over a card. The same shape `DeckSettingsView` uses, so the two
/// screens read as one app rather than as two people's work.
private struct DetailCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}

private struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DetailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/**
 * A name on the left and its value on the right.
 *
 * `mono` is not decoration: the design brief's rule runs through the whole
 * product — data is monospaced because its characters are exact and countable, a
 * sentence is not. A provider id, a status word, a session id and an endpoint are
 * data; "3m ago" and a machine's nickname are not.
 *
 * `wraps` exists for the two values that are long and must not be cut. Half a
 * session id and half an endpoint each identify nothing, and both were truncated
 * to uselessness on the Machines tab before somebody rendered it and looked.
 */
private struct DetailRow: View {
    let name: String
    let value: String
    let mono: Bool
    var wraps: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: mono ? 13 : 15, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.primary)
                .lineLimit(wraps ? 3 : 1)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: wraps)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A row that does something, in the shape the rest of the app's action rows
/// take: the accent on the icon and the words, because the accent means "this is
/// the action" and there is exactly one on each of these cards.
private struct DetailAction: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
