/**
 * The passwords this phone saved for one machine's pages, and the four things
 * anybody wants to do with one.
 *
 * > *"password saving and stuff like that, whatever is not possible to do
 * > through that — that can be native only for this application, for that server
 * > only specific."*
 *
 * The store behind it is `SavedLogins`, and its header carries the argument for
 * why a password typed on this phone stays on this phone and is keyed by
 * machine. This file is the screen: sites, the accounts under each of them, and
 * a row that reveals, copies or forgets one.
 *
 * ## The rule this screen exists to keep
 *
 * **A password is never drawn until the person has authenticated.** Until then a
 * row is a site and a username and a row of dots — which is the whole list, and
 * the list draws with no prompt at all, because the store keeps origins and
 * usernames as Keychain *attributes* and the password as the item's *data*.
 * Nothing here can get at one by accident: `SavedLogins.reveal` takes a
 * non-optional `LAContext`, and the only source of one is a successful
 * `BiometricGate` evaluation.
 *
 * `authenticateOnce` rather than `BiometricGate.unlock`, and the difference
 * matters. `unlock` keeps the authentication for the whole app session, which is
 * exactly right for a server page that opens four SSH connections in two minutes
 * and exactly wrong here: it would mean a password appearing with no prompt
 * because somebody visited a server screen ten minutes ago. Every reveal and
 * every copy of a password asks, every time.
 *
 * And what is revealed does not stay revealed: it is dropped when the app leaves
 * the foreground, when the screen goes, when another row is opened, and on a
 * timer, because a phone put face-down on a desk with somebody's password on it
 * is the same exposure as not having asked at all.
 *
 * ## Why it is cards and not a `List`
 *
 * The rows group by site, and a grouped list wants section headers — which under
 * `.listStyle(.plain)` are sticky, translucent bands that read as chrome rather
 * than as part of the group they name. The app already has a shape for exactly
 * this: a caption over a `Theme.surface` card, hairlines between the rows
 * inside it, which is what `MachineDetailView` and every settings group draw.
 * The cost is swipe-to-delete, and it is not much of one — every action on this
 * screen is in the row's own menu, where the two that are destructive can sit
 * beside the two that are not and be told apart.
 */

import LocalAuthentication
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SavedLoginsView: View {
    /// Which machine's sign-ins these are — `DeckEndpoint.hostId`, the same key
    /// `PortBook` and `BrowserHistory` store against.
    let host: String
    /// What to call that machine in a sentence. A name rather than "the
    /// machine", because somebody with two paired needs to know which one they
    /// are about to forget everything for — the same reason `BrowserHistoryView`
    /// takes one.
    let machine: String
    /// Injected rather than reached for, so a preview or a test can hand in a
    /// store of its own. See `PortBook` for why this can be a default argument.
    var logins: SavedLogins = .shared

    /// This screen's own gate. There is no shared one in the app — `AppLock` and
    /// `ServerConnector` each make theirs — and a shared one would be worse
    /// here: its cached authentication is the thing this screen must not have.
    @State private var gate = BiometricGate()

    @State private var query = ""
    /// The row whose password is on screen, and the password. Two properties
    /// rather than one dictionary because only ever one is open: revealing a
    /// second closes the first, which is what stops a screenshot of this screen
    /// being a screenshot of everything.
    @State private var openRow: SavedLoginSummary.ID?
    @State private var openSecret: String?
    /// The countdown that closes it again. Held so a second reveal can cancel
    /// the first one's timer rather than letting it fire over the new row.
    @State private var hiding: Task<Void, Never>?

    @State private var toast: String?
    @State private var notice: String?
    @State private var forgetting = false

    @Environment(\.scenePhase) private var phase

    /// How long a revealed password stays on screen with nothing touched.
    ///
    /// Long enough to read a generated password off it and type it somewhere,
    /// short enough that a phone left on a table is not still showing it. The
    /// timer restarts on nothing — a password that is being read is not being
    /// tapped, so any activity-based extension would be a guess.
    private static let visibleFor: TimeInterval = 30

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                        .accessibilityIdentifier("logins.toast")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("Saved logins")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search sites and usernames")
        // A site is not a sentence: capitalising it sends `Localhost` and
        // correcting it sends `local host`, neither of which matches a row. The
        // same three lines the history screen and the address bar carry.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            /*
             * Along the bottom and at the leading end, where Safari has kept the
             * same control for as long as it has had this screen — and drawn
             * only when there is something to forget, because a permanently
             * disabled button on an empty screen is chrome pretending to be a
             * control.
             */
            if !all.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Forget all", role: .destructive) { forgetting = true }
                        .accessibilityIdentifier("logins.forgetAll")
                    Spacer()
                }
            }
        }
        .confirmationDialog("Forget every saved login for \(machine)?",
                            isPresented: $forgetting,
                            titleVisibility: .visible) {
            Button("Forget them", role: .destructive) {
                hide()
                logins.forgetAll(host: host)
            }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Only this machine's sign-ins are forgotten, and only on this phone. There is no "
                 + "other copy of them — nothing was ever sent to \(machine).")
        }
        /*
         * The screen left the foreground. Whatever was revealed is not revealed
         * any more, which is the same moment `BiometricGate` drops its own
         * context and for the same reason: the phone has left the person's
         * attention.
         */
        .onChange(of: phase) { _, now in if now != .active { hide() } }
        .onDisappear { hide() }
        .alert("Saved logins",
               isPresented: Binding(get: { notice != nil },
                                    set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - What is on the screen

    /// Everything for this machine, for the two decisions that are about the
    /// store rather than about the search: whether there is anything to forget,
    /// and which empty state is the true one.
    private var all: [SavedLoginSummary] { logins.summaries(host: host) }

    private var rows: [SavedLoginSummary] { logins.summaries(host: host, matching: query) }

    /// The rows grouped by site, in the order the store hands them over — which
    /// is already sorted by site and then by account, so this only has to keep
    /// it rather than sort it again.
    private var sites: [(origin: String, site: String, rows: [SavedLoginSummary])] {
        var order: [String] = []
        var groups: [String: [SavedLoginSummary]] = [:]
        for row in rows {
            if groups[row.origin] == nil { order.append(row.origin) }
            groups[row.origin, default: []].append(row)
        }
        return order.compactMap { origin in
            guard let list = groups[origin], let first = list.first else { return nil }
            return (origin: origin, site: first.site, rows: list)
        }
    }

    /**
     * Three empty states, because they are three different facts.
     *
     * *This phone cannot keep a password at all* is about the device and is the
     * only one that is not really empty — it is a refusal, and it says what to
     * do about it. *Nothing saved yet* is about the machine and needs the
     * sentence that explains how a row gets here. *Nothing matches* is about the
     * characters somebody just typed, and the platform writes that one better
     * than this file would.
     */
    @ViewBuilder
    private var content: some View {
        if all.isEmpty && !logins.canProtect {
            ContentUnavailableView {
                Label("No passcode on this iPhone", systemImage: "lock.slash")
            } description: {
                Text(SavedLogins.noPasscode)
            }
            .accessibilityIdentifier("logins.noPasscode")
        } else if all.isEmpty {
            ContentUnavailableView {
                Label("Nothing saved yet", systemImage: "key")
            } description: {
                Text("Sign in to a page on \(machine) and this app offers to remember it. What it "
                     + "remembers stays on this phone, in its Keychain.")
            }
            .accessibilityIdentifier("logins.empty")
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sites, id: \.origin) { group in
                    caption(group.site)
                    card {
                        ForEach(group.rows) { row in
                            // A hairline between rows, never above the first —
                            // compared by id rather than by an index, because
                            // `ForEach` over an enumerated sequence is a tuple
                            // and this reads as what it means.
                            if row.id != group.rows.first?.id { line }
                            LoginRow(row: row,
                                     secret: openRow == row.id ? openSecret : nil,
                                     toggle: { toggle(row) },
                                     copyUsername: { copyUsername(row) },
                                     copyPassword: { copyPassword(row) },
                                     forget: { forget(row) })
                        }
                    }
                }

                footnote
                TabBarClearance()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /**
     * The honest sentence at the foot, and it is the same kind
     * `BrowserHistoryView` ends with.
     *
     * The risk this screen carries is somebody assuming these are the machine's
     * saved passwords — that signing in from the sofa put something in Chrome
     * over there, or that forgetting one here takes it off the Mac. Neither is
     * true and neither could be, and the second half of that is the part worth
     * saying: there is no other copy. Somebody who forgets one here has forgotten
     * it.
     */
    private var footnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("Saved on this phone, for \(machine)'s pages only. Nothing was sent to "
                 + "\(machine), and there is no other copy.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            InfoDot(about: "saved logins",
                    text: "A password typed into a page here never leaves this phone — the "
                        + "machine's own browser never saw it, so there is nothing over there to "
                        + "link it to. It is kept in this iPhone's Keychain, locked to your face "
                        + "or passcode, and separately for every machine you pair with.")
        }
        .padding(.top, 20)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("logins.footnote")
    }

    // MARK: - Doing something to a row

    /**
     * Show a password, or put it away again.
     *
     * Putting it away is free. Showing it costs an authentication, every time —
     * see the type header for why this asks rather than riding one that already
     * happened.
     */
    private func toggle(_ row: SavedLoginSummary) {
        if openRow == row.id { hide(); return }
        // `@MainActor in` rather than a bare `Task`: this is a plain method on a
        // `View` and therefore not isolated, so an inherited context is not
        // something to rely on — and what happens inside touches `@State` and a
        // main-actor `BiometricGate`.
        Task { @MainActor in
            await reveal(row) { secret in
                hide()
                openRow = row.id
                openSecret = secret
                hideAfterAWhile()
            }
        }
    }

    private func copyUsername(_ row: SavedLoginSummary) {
        guard !row.username.isEmpty else { return }
        // Not a secret, so no authentication and no expiry — and deliberately
        // not `.localOnly` either: a username is exactly the kind of thing
        // somebody wants to paste on their Mac a moment later.
        UIPasteboard.general.string = row.username
        show("Username copied")
    }

    private func copyPassword(_ row: SavedLoginSummary) {
        Task { @MainActor in
            await reveal(row) { secret in
                /*
                 * On the clipboard, briefly, and only on this device.
                 *
                 * `.localOnly` because Universal Clipboard would otherwise put
                 * the password on every Mac and iPad signed into the same Apple
                 * account — including ones this person does not have with them.
                 * The expiration is the other half: iOS clears the item after a
                 * minute, so a password copied to paste into a page is not still
                 * sitting in the clipboard tonight for whatever reads it next.
                 */
                UIPasteboard.general.setItems(
                    [[UTType.utf8PlainText.identifier: secret]],
                    options: [.localOnly: true,
                              .expirationDate: Date().addingTimeInterval(60)])
                show("Password copied — clears in a minute")
            }
        }
    }

    /**
     * Forget one sign-in. **Red, and no second question.**
     *
     * Red rather than the orange `BrowserHistoryView` gives its Forget, and the
     * difference is real rather than decorative: forgetting a page from a history
     * loses nothing — open it again and the row comes straight back. This is the
     * only copy of a password that exists anywhere. `SessionListView` settled the
     * app's vocabulary — red for the thing that cannot be undone — and this is
     * squarely that.
     *
     * It does not ask, though, and Forget all does. One row is a small, visible,
     * deliberate act on a named account; the button that touches every row at
     * once is the one people press meaning something narrower.
     */
    private func forget(_ row: SavedLoginSummary) {
        if openRow == row.id { hide() }
        logins.forget(row)
        show("Forgotten")
    }

    /**
     * Authenticate, then hand the password to one closure.
     *
     * Every branch of `BiometryOutcome` is answered, because every one of them
     * is a real phone somebody is holding and a reveal that silently does
     * nothing is a button that reads as broken. Cancel is the one exception:
     * somebody who pressed Cancel knows what happened and does not need an alert
     * telling them.
     */
    @MainActor
    private func reveal(_ row: SavedLoginSummary, then use: (String) -> Void) async {
        switch await gate.authenticateOnce(
            reason: "Show the password saved for \(row.site) on this iPhone."
        ) {
        case let .unlocked(context):
            guard let secret = logins.reveal(row, context: context) else {
                notice = "This iPhone would not hand back that password. If you have changed your "
                    + "Face ID or Touch ID enrolment, unlock the phone with its passcode once and "
                    + "try again."
                return
            }
            use(secret)
        case .cancelled:
            break
        case let .lockedOut(kind):
            notice = "\(kind.name ?? "Biometric unlock") is locked after too many failed attempts. "
                + "Unlock this iPhone with its passcode once and it comes back."
        case let .notEnrolled(kind):
            notice = "\(kind.name ?? "Biometric unlock") is not set up on this iPhone, and the "
                + "passcode was not accepted either. Nothing is shown without one of them."
        case .unavailable:
            notice = SavedLogins.noPasscode
        case let .failed(message):
            notice = message
        }
    }

    // MARK: - Keeping it on screen for as long as it should be, and no longer

    private func hide() {
        hiding?.cancel()
        hiding = nil
        openRow = nil
        openSecret = nil
    }

    private func hideAfterAWhile() {
        hiding?.cancel()
        hiding = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleFor * 1_000_000_000))
            // A cancelled sleep still returns, so the check is not optional: the
            // task from a previous reveal must not close the row that replaced
            // it.
            guard !Task.isCancelled else { return }
            openRow = nil
            openSecret = nil
        }
    }

    private func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }

    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed, and that is not a preference:
     * `SectionCaption`, `SettingsGroup` and `SettingsDivider` are **private to
     * `DeckTabs.swift`**, so a screen that reached for them would have to live
     * in that file. The same three shapes at the same metrics `MachineDetailView`
     * redraws for the same reason.
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
            .accessibilityAddTraits(.isHeader)
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
}

/* -------------------------------------------------------------------------- */
/* One account                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * One saved sign-in.
 *
 * The username leads, because the site is already the caption over the card and
 * repeating it eighty times would spend the row saying what the group says once.
 * Underneath it is either a row of dots or the password itself — never both, and
 * never the password without an authentication having happened first: this view
 * cannot produce one, it can only draw the one it is handed.
 *
 * The whole row is the reveal, which is the gesture people reach for anyway, and
 * the `…` carries the rest. A row that did nothing until somebody found a menu
 * would be a dead tap on the only screen where the obvious action is obvious.
 */
private struct LoginRow: View {
    let row: SavedLoginSummary
    /// The password, or nil — which is the whole of this view's access to one.
    let secret: String?
    let toggle: () -> Void
    let copyUsername: () -> Void
    let copyPassword: () -> Void
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    // The app's row glyph: monoline at 19, in a 24-point column.
                    // See `PortRow` for the argument.
                    Image(systemName: "key")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.account)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(row.username.isEmpty ? Theme.faint : Theme.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let secret {
                            Text(secret)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.primary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            // A fixed count, not the real length. The number of
                            // characters in a password is not a secret anybody
                            // needs from a list, and it is a real hint to
                            // whoever is looking over a shoulder.
                            Text("••••••••")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: secret == nil ? "eye" : "eye.slash")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("logins.row.\(row.id)")
            .accessibilityLabel(secret == nil
                                ? "\(row.account), password hidden"
                                : "\(row.account), password shown")
            .accessibilityHint(secret == nil ? "Shows the password after unlocking" : "Hides it")

            Menu {
                Button {
                    copyPassword()
                } label: {
                    Label("Copy password", systemImage: "doc.on.doc")
                }

                if !row.username.isEmpty {
                    Button {
                        copyUsername()
                    } label: {
                        Label("Copy username", systemImage: "person")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    forget()
                } label: {
                    Label("Forget this login", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(row.account)")
            .accessibilityIdentifier("logins.more.\(row.id)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/* -------------------------------------------------------------------------- */
/* The offer                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * *Save this password?* — the card that turns a sign-in into a saved login.
 *
 * A card over the page rather than an alert, for the reason every browser has
 * settled on the same shape: an alert takes the screen and demands an answer to
 * a question nobody asked, at the exact moment somebody has just got where they
 * were going. This sits above the browser's toolbar, it can be ignored, and
 * ignoring it is a real answer — the offer goes when the page does.
 *
 * **It draws the site and the account and nothing else.** The password is not on
 * this view and cannot be: `SavedLogins` publishes a `SavedLoginSummary`, which
 * has no field for one, and keeps the secret in a private property until the
 * answer comes back. That is the desktop's rule, ported — *"the renderer is told
 * an offer exists and answers yes or no; the secret never makes the trip."*
 */
struct SaveLoginPrompt: View {
    let offer: SavedLoginSummary
    var logins: SavedLogins = .shared
    /// Shown when the save is refused — no passcode on the phone, or a password
    /// this app will not store. A refusal that vanished silently would look
    /// exactly like a save.
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Save this password?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(offer.username.isEmpty
                         ? offer.site
                         : "\(offer.username) — \(offer.site)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                InfoDot(about: "saving this password",
                        text: "It is kept in this iPhone's Keychain, locked to your face or "
                            + "passcode, and only for this machine's pages. Nothing is sent to the "
                            + "machine — its own browser never saw this sign-in.")
            }

            if let refusal {
                Text(refusal)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Not now") {
                    logins.answer(keep: false)
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("logins.offer.no")

                Spacer(minLength: 8)

                Button("Save") {
                    if case let .refused(why)? = logins.answer(keep: true) {
                        refusal = why
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Theme.accent, in: Capsule())
                .accessibilityIdentifier("logins.offer.yes")
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("logins.offer")
    }
}
