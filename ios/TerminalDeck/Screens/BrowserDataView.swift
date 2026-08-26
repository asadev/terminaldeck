/**
 * What this phone has kept from the pages it has shown, and how big it draws
 * them — the two things the Browser tab remembers on its own.
 *
 * Asad, listing what the tab still owed: *"connecting and all of and search
 * history and cookies and all of this."*
 *
 * ## Why it is on the Browser tab and not in Settings
 *
 * Because it is not a setting about the app, it is the state of a browser, and
 * the whole point of merging these screens into one tab was that a browser is
 * one place. Somebody whose dev server will not sign them out is standing on the
 * Browser tab when they realise it; making them leave, find Settings, and come
 * back is the two-taps-and-a-modal problem the address bar on
 * `NewWindowSheet` was moved onto the screen to fix.
 *
 * ## Why the zoom is on the same screen as the cookies
 *
 * They have nothing to do with each other except the only thing that matters
 * here: both live on this phone and neither has ever touched the wire. Splitting
 * them would produce a screen with one row on it and a second screen with one
 * row on it, reachable from a tab whose spare toolbar slot is a single button.
 * `AppearanceView` made the same call for the same reason and wrote it down —
 * the terminal's size sits with the terminal's colours because *"the two
 * settings answer the same question."* So does this pair: what does a page do on
 * this phone.
 *
 * The order is zoom, then sites, then Clear everything. Least destructive to
 * most, and the list of sites is the section that grows — anything placed under
 * it would drift off the bottom of the screen on a phone that has browsed for a
 * month.
 *
 * ## One line about what clearing means, and the rest behind the dot
 *
 * *"here you have a very long description… Remove this full shit."* The nuance
 * on this screen is real — a cookie for `127.0.0.1` is not a cookie for a
 * website, and the row is a host rather than a port — but almost all of it is
 * explanation. `InfoDot` is where explanation lives.
 *
 * The half-line that stays on the screen is not a leftover. Somebody about to
 * press Clear is about to be signed out of the thing they were working on, and a
 * person who is about to lose a session does not tap an ⓘ first.
 *
 * ## Why a whole row is the destructive control
 *
 * A row that clears on tap sounds wrong and is not, because nothing is cleared
 * by the tap: it raises a confirmation naming the host, which is the same shape
 * `AppearanceView` deletes a colour scheme with. The alternative — a small
 * trash glyph at the trailing edge as the only target — is a fifteen-point
 * target on a screen where every other row is tappable across its whole width,
 * and a row that looks tappable and is not is the dead click his rule book names.
 *
 * ## No WebKit in this file
 *
 * Deliberate, and it is what makes the screen readable. `BrowserDataStore` hands
 * over `BrowserDataSite` values — a name, four possible kinds, and whether the
 * host is the machine — so nothing here has to know that a `WKWebsiteDataRecord`
 * exists, that it carries no size, or that WebKit groups it by the public suffix
 * list. All three of those facts are argued in that file, where they are true.
 */

import SwiftUI

struct BrowserDataView: View {

    @State private var data = BrowserDataStore()

    /// The zoom, mirrored into `@State` because `PageZoom` is a `UserDefaults`
    /// façade with no observation on it — the shape `AppearanceView` uses for
    /// the terminal's size, and for the same reason: the stepper answers the
    /// finger rather than a store round trip.
    @State private var zoom = PageZoom.stored

    /// What a confirmation is currently about, or nil.
    ///
    /// One optional driving one dialog rather than two `.confirmationDialog`
    /// modifiers on one view. Two of them attached to the same view is a
    /// coin-toss over which one presents — SwiftUI keeps one presentation of a
    /// kind per view — and the failure mode is the wrong dialog appearing over a
    /// destructive action.
    @State private var pending: Pending?

    private enum Pending: Equatable {
        case site(BrowserDataSite)
        case everything
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    zoomSection
                    sitesSection
                    everythingSection
                    // Measured, not guessed — see `TabBarClearance`. This screen
                    // is pushed inside the Browser tab, which keeps the floating
                    // pill: without this the Clear everything row sits behind it.
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Website data")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("browser.data")
        // `.task` rather than `.onAppear`: the read is async and this cancels it
        // if somebody pops the screen before WebKit answers.
        .task { await data.read() }
        .confirmationDialog("Clear website data?",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { target in
            Button("Clear", role: .destructive) {
                pending = nil
                Task {
                    switch target {
                    case let .site(site): await data.clear(site)
                    case .everything: await data.clearEverything()
                    }
                }
            }
            Button("Keep", role: .cancel) { pending = nil }
        } message: { target in
            Text(message(for: target))
        }
    }

    /**
     * What the confirmation says, and it is the one place on this screen allowed
     * to be two sentences.
     *
     * A confirmation is read, unlike a caption — it is the last thing between a
     * person and losing a session — so the loopback case names the consequence
     * rather than describing the action. "Signs you out" is what happens;
     * "removes cookies" is what the code does.
     */
    private func message(for target: Pending) -> String {
        switch target {
        case let .site(site) where site.isMachine:
            return "Signs you out of every dev server on \(site.id) and clears what they saved here."
        case let .site(site):
            return "Clears everything \(site.id) has saved on this phone."
        case .everything:
            return "Clears cookies, storage and caches for every site this phone has opened."
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Page zoom")

            SchemeGroup {
                HStack(spacing: 12) {
                    // 19 light in a 24-point column, which is what every row
                    // icon in this app is set at — see `SettingsRowBody`. The
                    // SF Symbols default of 15 regular is precisely the look he
                    // complained about.
                    Image(systemName: "textformat.size")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24)
                    Text("Page zoom")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    InfoDot(about: "page zoom",
                            text: "CSS reflows, so a responsive site at 200% lays itself out the "
                                + "way it would on a narrower phone rather than being magnified. "
                                + "A page already open keeps the size it opened at.")
                    Spacer(minLength: 8)
                    Text(PageZoom.label(zoom))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                    Stepper("Page zoom", value: $zoom,
                            in: PageZoom.minimum...PageZoom.maximum,
                            step: PageZoom.step)
                        .labelsHidden()
                        .onChange(of: zoom) { _, value in PageZoom.save(value) }
                        .accessibilityIdentifier("browser.data.zoom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Sites

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            /*
             * The ⓘ carries the whole of the port argument, because it is the
             * thing a developer will not believe until they read it: these rows
             * are hosts, not origins, and clearing one takes every port with it.
             * That is the cookie spec rather than a shortcut — see
             * `BrowserDataStore` — and it is exactly the kind of fact that
             * belongs one tap away from a control rather than printed above it.
             */
            SchemeSectionCaption(
                "Sites",
                about: "these sites",
                info: "Cookies were never scoped to a port, and WebKit groups this list by host — "
                    + "so 127.0.0.1 is every dev server on the machine at once. Storage and caches "
                    + "are per port and go with it.")

            SchemeGroup {
                if data.reading {
                    note("Reading what this phone has kept…")
                } else if data.sites.isEmpty {
                    note("Nothing kept yet.")
                        .accessibilityIdentifier("browser.data.empty")
                } else {
                    ForEach(Array(data.sites.enumerated()), id: \.element.id) { index, site in
                        if index > 0 { rowDivider }
                        siteRow(site)
                    }
                }
            }

            /*
             * The half-line, and the one thing on this screen that is not a
             * control.
             *
             * "Clear cookies" means something different here than it does in
             * Safari: on the internet it signs you out of a website you can log
             * back into, and on a dev server it signs you out of the thing you
             * were in the middle of. Somebody about to press Clear should not
             * have to tap an ⓘ to find that out.
             */
            Text("Cookies here are a dev server’s login. Clearing one signs you out of it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
    }

    private func siteRow(_ site: BrowserDataSite) -> some View {
        let clearing = data.isClearing(site.id)
        return Button {
            pending = .site(site)
        } label: {
            HStack(spacing: 12) {
                // The machine, or somewhere else. A dev page with a link out to
                // its own docs is how anything but loopback ends up on this
                // list, and the two are worth telling apart at a glance because
                // only one of them is somebody's own work.
                Image(systemName: site.isMachine ? "desktopcomputer" : "globe")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    // Mono, because a host is data — the same rule the address
                    // under `LocalhostBrowser`'s title is drawn under. Truncated
                    // in the middle rather than at either end: the interesting
                    // parts of a long host are both of its ends.
                    Text(site.id)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(site.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if clearing {
                    // The word rather than a spinner, which is what
                    // `ServerSettingsSection` says while an apply is in flight.
                    // A row that swaps a glyph for a spinner of a different size
                    // changes height while it works.
                    Text("Clearing…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.critical)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(data.isBusy)
        // One sentence rather than the three `Text`s a button reads out by
        // default — the host, what it holds and what happens only mean anything
        // together. Stated as a label instead of `accessibilityElement(children:
        // .combine)` so the element stays the button it is.
        .accessibilityLabel("\(site.id), \(site.summary)")
        .accessibilityHint("Clears this site’s data from this phone")
        .accessibilityIdentifier("browser.data.site.\(site.id)")
    }

    // MARK: - Everything

    /**
     * The second control, and it is not the first one said eleven times.
     *
     * Clearing every row one at a time is not the same operation: some data
     * types produce no record at all, so a sweep over the list leaves behind
     * exactly the things somebody pressing this meant to be rid of.
     * `BrowserDataStore.clearEverything` goes through WebKit's own date sweep
     * instead. Its own card at the bottom, away from the rows, because a
     * destructive control that sits in the same group as the ordinary ones gets
     * pressed by the thumb that meant the row above it.
     */
    private var everythingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Everything")

            SchemeGroup {
                Button {
                    pending = .everything
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "trash")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(Theme.critical)
                            .frame(width: 24)
                        Text(data.isClearingEverything ? "Clearing…" : "Clear everything")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.critical)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Nothing to clear is a real state — a phone that has only ever
                // been shown one page it did not log into — and an enabled
                // button that does nothing is worse than a disabled one. Also
                // off while the first read is in flight: *not known yet* is not
                // the same answer as *nothing*, and one of the two is a button
                // that would do something.
                .disabled(data.isBusy || data.reading || data.sites.isEmpty)
                .accessibilityIdentifier("browser.data.clearAll")
            }
        }
    }

    // MARK: - Chrome

    /// A line of prose inside a card, at the same insets a row would have. The
    /// shape `ServerSettingsSection` draws while it is waiting for a machine to
    /// answer, so a card that is empty and a card that is loading are the same
    /// height as a card with one row in it.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 52 is arithmetic rather than taste: the row is `.padding(.horizontal, 16)`,
    /// its icon column is 24 wide and the `HStack` spacing is 12, so this starts
    /// exactly under the first letter of the host. The same sum `SettingsDivider`
    /// works out in `DeckTabs.swift`; that type is private to its file and this
    /// screen stays self-contained, so the number is copied and the reason is
    /// written down — which is the trade `ServerSettingsSection` made first.
    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 52)
    }
}
