/**
 * Where the tab bar belongs — one rule, in one place, for every screen — and the
 * one conformance that lets a live tunnel be a navigation destination.
 *
 * Both facts are here because neither belongs to a screen: the first is a
 * statement about *all* of them, and the second is what makes a screen reachable
 * by a push rather than by a modal.
 *
 * Asad, walking the phone app: *"when this keyboard is down, see the pill is
 * still there. So inside the session we don't need the pill. Pill should be on
 * here only on the homepage or machines or settings, but not inside the session
 * and not also inside the localhost page."*
 *
 * The rule is not "hide it on anything that was pushed". Machines is pushed —
 * it is a row inside Settings now — and it keeps the bar, because he named it as
 * one of the three places the bar belongs. What loses the bar is a screen that is
 * *the whole thing you came for*: a terminal, and a page from the machine. Both
 * are surfaces you look at rather than places you are passing through, both are
 * the full height of the phone, and on both the bar was covering the bottom of
 * the content while pointing at somewhere else.
 *
 * ## Why this is a function rather than a modifier on each screen
 *
 * Because the failure it prevents is drift: the policy would otherwise live in
 * as many places as there are screens, be invisible in review, and be checkable
 * only by launching the app and looking at the bottom sixty points. A screen
 * that quietly kept the bar would look exactly like a screen that had never been
 * considered.
 *
 * With the decision here it is one switch a test can enumerate — see
 * `DeckChromeTests`, which walks every case rather than checking the two that
 * happen to be interesting today, so adding a surface and forgetting to decide
 * about it fails to compile.
 *
 * ## And why `DeckTabs` applies it, rather than each screen
 *
 * Because the obvious arrangement does not work. `.toolbar(.hidden, for:
 * .tabBar)` written on the pushed screen itself is what the documentation
 * describes and it had **no effect at all** here: measured on iOS 26.5, in a
 * screenshot of a real session with the keyboard down — the exact frame he
 * complained about — the floating pill was still drawn over the last three rows
 * of terminal output. Moving the modifier to the very end of that screen's
 * modifier chain changed nothing either. iOS 26 draws the tab bar as a floating
 * pill owned by the `TabView`, and the `TabView` is where it listens.
 *
 * So each tab's `NavigationStack` in `DeckTabs` states the visibility for
 * *whatever is currently on top of it*, which it works out from the model. That
 * needs the model to know when a localhost page is up — see
 * `DeckModel.localhostPageIsOpen`, which exists for this and nothing else.
 */

import SwiftUI

/**
 * Every screen in the app, as the tab bar sees it.
 *
 * Deliberately not the same type as `DeckModel.Tab`. A tab is something you can
 * select; this is something you can be looking at, and the two screens the whole
 * rule is about — a session and a localhost page — are neither of them tabs.
 */
enum DeckSurface: Hashable, CaseIterable {
    /// The list of sessions on the machine. The tab he calls "the homepage".
    case sessions
    /// The Localhost tab: what is serving on the machine, and what could be.
    case localhost
    /// The Settings tab.
    case settings
    /// The paired machines, pushed from Settings.
    case machines
    /// A terminal, pushed from the session list.
    case session
    /// A page from the machine, pushed from the Localhost tab.
    case localhostPage
    /**
     * The copilot conversation — **a tab**, and therefore one that keeps the bar.
     *
     * This answer is the opposite of what it was, and the fact underneath it
     * changed rather than the judgement. While the copilot was a screen *pushed
     * from the session list* it was the pill complaint exactly — full height,
     * the whole thing you came for, and a text field at the bottom with the bar
     * floating over it: *"when this keyboard is down, see the pill is still
     * there."* Hiding the bar cost nothing there, because the chevron was how
     * you left.
     *
     * *"A fourth pill, and the copilot goes leftmost"* moved it, and a tab that
     * hides its own tab bar is a screen with **no way out**. There is no
     * chevron over a tab's root and no gesture that pops one. So the bar stays,
     * and the composer sits above it rather than under it — `CopilotView` puts
     * the footer in a bottom `safeAreaInset`, which is measured against the bar's
     * own safe area, so the two do not overlap. Verified by looking, in both
     * appearances, which is the only way this class of thing is ever verified.
     */
    case copilot
}

enum DeckChrome {

    /// Whether the tab bar is drawn over this screen.
    static func showsTabBar(on surface: DeckSurface) -> Bool {
        switch surface {
        case .copilot, .sessions, .localhost, .settings, .machines:
            return true
        case .session, .localhostPage:
            return false
        }
    }

    /// The same answer in the shape `.toolbar(_:for:)` wants. Screens that keep
    /// the bar state it too: `.visible` is what SwiftUI would do anyway, and
    /// saying it means every screen in the app has made the decision out loud
    /// rather than three of them having inherited it.
    static func tabBar(on surface: DeckSurface) -> Visibility {
        showsTabBar(on: surface) ? .visible : .hidden
    }
}

/**
 * A tunnel can be navigated to.
 *
 * `navigationDestination(item:)` takes a `Hashable`, and this is how the
 * localhost page became a push instead of a `fullScreenCover` — his *"give it a
 * native feel"*. A tunnel is a reference to one live socket rather than a value:
 * two tunnels on the same port are two different things, and one tunnel stays
 * the same thing as its phase moves from `opening` to `live` to `ended`. So
 * **identity** is the hash, which is also what stops the page being torn down
 * and rebuilt underneath somebody the moment the port answers.
 *
 * Written here rather than on `PortTunnel` because it exists for this navigation
 * and nothing else — the tunnel itself has no opinion about being pushed — and
 * because the screen that pushes it is being redesigned in parallel.
 */
extension PortTunnel: Hashable {
    nonisolated static func == (lhs: PortTunnel, rhs: PortTunnel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
