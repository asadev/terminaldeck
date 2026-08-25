/**
 * Which profile the machine's browser is using, and the two things worth doing
 * about it from a phone.
 *
 * Asad, holding the two browsers side by side:
 *
 * > *"browser options are also super basic right now. If you just compare with
 * > the desktop browser options and compare with this one it is far lesser than
 * > that. We have a lot of things in the browser on the desktop side — we have
 * > profile, password, cookies, everything… it should be all same, because it is
 * > just linking this to the server side."*
 *
 * This is the linked half. The desktop's `ProfileMenu` and `ProfileSettings` are
 * on the machine; `BrowserProfilesWire` is the wire between them and this; and
 * what a profile *is* — a `persist:` session partition, a real cookie jar on a
 * real disk — is argued in `src/main/browser-profiles.ts` and not re-argued
 * here.
 *
 * ## Two sections, because a phone has a top of the screen
 *
 * The desktop draws one list with a tick in it. A tick is a fine answer on a
 * flyout that opens under the button that made it, and it is the wrong one here:
 * the first question somebody opens this screen with is *which one is it using*,
 * and the answer should be the first thing under the thumb rather than a glyph
 * to be hunted for down a list. So the profile in use has the top card to
 * itself, with what it holds, and everything else is a list headed by the act
 * that reaches it.
 *
 * That also makes the switch its own confirmation. Both verbs answer with a
 * fresh `browser.profile.rows`, so a tapped profile **moves** — out of the list
 * and into the card above it. Nothing has to be said, which is the best possible
 * outcome of *"we don't need to give the statements."*
 *
 * ## What is not here, and is not pretended to be
 *
 * No new profile, no rename, no badge picker, no delete. All four are on the
 * desktop and none of them is on this wire — see `BrowserProfilesWire` for why
 * that is a decision rather than an instalment. A row that opened nothing is the
 * defect this whole review is about, so there is no row.
 *
 * No saved passwords either, and that is the other half of his sentence:
 * *"whatever is not possible to do through that, that can be native only for
 * this application, for that server only specific."* What this phone saves is
 * this phone's, keyed per machine like `PortBook` and `BrowserHistory`, and it
 * lives on its own screen. This one only ever talks about the machine.
 *
 * ## Clearing is per profile, and it is not the Site data screen
 *
 * `BrowserDataView` clears **this phone's** jar — the `WKWebView` behind
 * `LocalhostBrowser`, over a tunnel. This clears **the machine's**, one
 * partition at a time. Two computers, two jars, and the confirmation names which
 * machine out loud precisely so the two can never be confused by somebody moving
 * quickly.
 */

import SwiftUI

struct MachineProfilesView: View {
    let model: DeckModel

    /// Which profile a Clear has been raised for, or nil.
    ///
    /// One optional driving one dialog, the shape `BrowserDataView` writes down:
    /// two `.confirmationDialog` modifiers on one view is a coin toss over which
    /// one presents, and the losing side of that toss is a destructive act.
    @State private var pending: MachineBrowserProfile?

    /// The profile a verb is in flight for, or nil.
    ///
    /// Held here rather than on the model because the wire has no correlation id
    /// on this family and needs none: both verbs answer with the whole list, so
    /// *the list changed* is the completion. `settle` is the backstop for the
    /// case where it changed into something identical — clearing a jar the
    /// machine reports no counts for produces the same rows it sent before, and
    /// a spinner with nothing to end it would sit there for the life of the
    /// screen.
    @State private var working: String?
    @State private var settle: Task<Void, Never>?

    /// How long a verb may be in flight before the row goes back to being a row.
    /// The same figure `DeviceRosterLink` waits on a revoke, and for the same
    /// reason: it is long enough that a slow machine is not called dead, and
    /// short enough that a person does not conclude the app is stuck.
    private static let settleAfter: TimeInterval = 30

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                    // Pushed inside the Browser tab, which keeps the floating
                    // pill — measured, not guessed. See `TabBarClearance`.
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("browser.profiles")
        /*
         * Read on every appearance rather than once.
         *
         * The roster next door reads once and stays fresh on a push; this family
         * has no push, and what it answers moves for reasons this phone never
         * hears about — somebody switched profile on the machine itself, a jar
         * grew while a page was open. One small frame when a screen opens is the
         * cheapest way to be right, and the screen is not one anybody opens in a
         * loop.
         */
        .onAppear { model.readMachineProfiles() }
        .onDisappear { settle?.cancel(); settle = nil }
        // The answer landed: whatever was in flight is finished. Cheap because
        // `MachineProfileList` is `Equatable` all the way down, so an identical
        // frame does not even fire it — which is what `settle` is for.
        .onChange(of: model.machineProfiles) { _, _ in done() }
        .confirmationDialog("Clear this profile?",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { profile in
            Button("Clear", role: .destructive) {
                pending = nil
                begin(profile.id)
                model.clearMachineProfile(profile.id)
            }
            Button("Keep", role: .cancel) { pending = nil }
        } message: { profile in
            Text(MachineProfileText.clearing(profile, machine: model.theMachine))
        }
    }

    // MARK: - What is on the screen

    @ViewBuilder
    private var content: some View {
        if !model.canUseMachineProfiles {
            /*
             * Reachable, and not a dead end drawn on purpose.
             *
             * The Browser tab hides the row that opens this when the machine did
             * not offer the capability, so nobody arrives here cold. What does
             * happen is a machine dropping off — or coming back as a guest,
             * which is told apart nowhere on this side and does not need to be —
             * while the screen is already up. One line, the shape
             * `MachineDetailView` answers the same event with.
             */
            note("This machine is not offering its browser profiles.")
                .accessibilityIdentifier("browser.profiles.unavailable")
        } else if let list = model.machineProfiles {
            if list.isEmpty {
                note("This machine's browser has no profiles.")
                    .accessibilityIdentifier("browser.profiles.empty")
            } else {
                inUse(list)
                switchTo(list)
            }
        } else {
            // Nothing yet. A spinner rather than an empty card, because *not
            // known* and *nothing there* are different answers and only one of
            // them is worth drawing a Clear beside.
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    @ViewBuilder
    private func inUse(_ list: MachineProfileList) -> some View {
        SchemeSectionCaption(
            "In use",
            about: "browser profiles",
            info: "A profile is a separate cookie jar on this machine — its own logins, storage "
                + "and cache. Switching decides which one the next page opens into; pages already "
                + "open keep the one they started in. Pages this phone tunnels are its own, and "
                + "are cleared under Site data.")

        SchemeGroup {
            if let profile = list.currentProfile {
                HStack(spacing: 12) {
                    badge(profile, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if let holds = MachineProfileText.holds(profile) {
                            Text(holds)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    clearControl(profile)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("browser.profiles.current")
            }
        }
    }

    @ViewBuilder
    private func switchTo(_ list: MachineProfileList) -> some View {
        // Absent, not empty. One profile is an ordinary state of a machine
        // nobody has made a second jar on, and a heading over nothing is a
        // section that exists to look furnished.
        if !list.others.isEmpty {
            SchemeSectionCaption("Switch to")
            SchemeGroup {
                ForEach(Array(list.others.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { rowDivider }
                    row(profile)
                }
            }
        }
    }

    /**
     * One profile that is not in use: the whole row switches, and the trailing
     * word clears.
     *
     * Two sibling buttons rather than one nested inside the other. Nesting is
     * what the desktop's markup does — an `<li>` with a choice button and a
     * `Delete` beside it — and SwiftUI has no equivalent: a `Button` inside a
     * `Button`'s label is a hit-testing coin toss, and the coin here decides
     * between switching profile and destroying a cookie jar.
     *
     * So the switch takes everything the Clear does not, `contentShape` and all,
     * which is what keeps the row a row rather than a name-sized target — the
     * dead-click rule, and the same argument `BrowserDataView` makes for making
     * a whole row its control instead of a fifteen-point trash glyph.
     */
    private func row(_ profile: MachineBrowserProfile) -> some View {
        HStack(spacing: 0) {
            Button {
                begin(profile.id)
                model.useMachineProfile(profile.id)
            } label: {
                HStack(spacing: 12) {
                    badge(profile, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if let holds = MachineProfileText.holds(profile) {
                            Text(holds)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
            // One sentence rather than the two `Text`s a button reads by
            // default: the name and what it holds only mean anything together,
            // and the hint is the thing a tap actually does.
            .accessibilityLabel(MachineProfileText.holds(profile).map { "\(profile.name), \($0)" }
                                ?? profile.name)
            .accessibilityHint("Switches this machine's browser to this profile")
            .accessibilityIdentifier("browser.profiles.use.\(profile.id)")

            clearControl(profile)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /**
     * The trailing word, on every row including the one in use.
     *
     * Red at rest, and it arms nothing by itself — the confirmation is the
     * dialog, which names the profile and says what is lost. *"It should give
     * the warning also"*, and the warning is the sentence
     * `MachineProfileText.clearing` writes for the three cases that lose three
     * different things.
     *
     * The word swaps for the state rather than for a spinner: a row that
     * exchanges a 14-point word for a small `ProgressView` changes height while
     * it works, which is the flicker `BrowserDataView` calls out on its own
     * clearing row.
     */
    @ViewBuilder
    private func clearControl(_ profile: MachineBrowserProfile) -> some View {
        if working == profile.id {
            Text("Clearing…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                // The same 12 the button beside it takes, so the row does not
                // shuffle sideways at the moment it stops taking taps.
                .padding(.leading, 12)
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            Button {
                pending = profile
            } label: {
                Text("Clear")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.critical)
                    .padding(.leading, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
            .accessibilityLabel("Clear \(profile.name)")
            .accessibilityHint("Signs this machine's browser out of everything in it")
            .accessibilityIdentifier("browser.profiles.clear.\(profile.id)")
        }
    }

    // MARK: - In flight

    /// A verb has gone. Everything on the screen stops taking taps until the
    /// list comes back, because both verbs re-answer with the whole list and a
    /// second one sent underneath the first would be acting on rows that are
    /// about to be replaced.
    private func begin(_ id: String) {
        working = id
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .seconds(Self.settleAfter))
            guard !Task.isCancelled else { return }
            working = nil
        }
    }

    private func done() {
        settle?.cancel()
        settle = nil
        working = nil
    }

    // MARK: - Chrome

    /**
     * The badge, and it is the row's icon rather than a decoration beside one.
     *
     * A character in a circle, the same one the desktop's toolbar and flyout
     * wear — `MachineProfileText.initial`, ported from `profile-badge.ts`, where
     * the argument for a letter over a colour is written out. The circle for the
     * profile in use carries the accent, which is the one place on this screen
     * colour says something: it is the answer to the question the screen was
     * opened with.
     *
     * 24 points in the list, which is exactly the column every row icon in this
     * app is drawn in — see `SettingsRowBody` — so the badge, the globes on the
     * Site data screen and the port icons next door all start on the same
     * vertical line, and the divider inset below is the same arithmetic.
     */
    private func badge(_ profile: MachineBrowserProfile, size: CGFloat) -> some View {
        Circle()
            .fill(profile.isCurrent ? Theme.accent.opacity(0.16) : Theme.surfaceHigh)
            .frame(width: size, height: size)
            .overlay(
                Text(profile.badge)
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(profile.isCurrent ? Theme.accent : Theme.secondary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            )
            .accessibilityHidden(true)
    }

    /// A line of prose inside a card, at the insets a row would have — so a card
    /// that is empty and a card with one row in it are the same height. The
    /// shape `BrowserDataView` draws its own waiting line as.
    private func note(_ text: String) -> some View {
        SchemeGroup {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 20)
    }

    /// 52 is arithmetic rather than taste: the row is inset 16, its icon column
    /// is 24 wide and the `HStack` spacing is 12, so this starts exactly under
    /// the first letter of the name. The same sum `SettingsDivider` works out in
    /// `DeckTabs.swift` — that type is private to its file, so the number is
    /// copied and the reason is written down, which is the trade
    /// `BrowserDataView` made first.
    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 52)
    }
}
