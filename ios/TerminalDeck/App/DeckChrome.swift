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
 * And a night later, on the copilot, which is the same complaint about the third
 * screen that ends in a text field: *"if we are on copilot on mobile version,
 * now if we want to type here, the pill is still there. Why is the pill there if
 * we can type here? Either we will type or we will use the pill. So pill should
 * not be inside the chat box — there should be a back button to go back on
 * home."*
 *
 * The rule is not "hide it on anything that was pushed". Machines is pushed —
 * it is a row inside Settings now — and it keeps the bar, because he named it as
 * one of the three places the bar belongs. What loses the bar is a screen that is
 * *the whole thing you came for*: a terminal, a page from the machine, and the
 * conversation with the copilot. All three are surfaces you look at rather than
 * places you are passing through, all three are the full height of the phone,
 * and on all three the bar was covering the bottom of the content while pointing
 * at somewhere else.
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
     * The copilot conversation — a tab, and one that **hides** the bar anyway.
     *
     * This answer has now been given three times and the reasoning is worth
     * keeping whole, because each answer was right about the app it was written
     * against and somebody will otherwise re-derive the middle one.
     *
     * **First: hidden.** The copilot was a screen *pushed from the session
     * list*, and it was the pill complaint exactly — full height, the whole
     * thing you came for, and a text field at the bottom with the bar floating
     * over it: *"when this keyboard is down, see the pill is still there."*
     * Hiding the bar cost nothing, because the chevron was how you left.
     *
     * **Then: shown.** *"A fourth pill, and the copilot goes leftmost"* made it
     * a tab, and a tab that hides its own tab bar is a screen with **no way
     * out** — there is no chevron over a tab's root and no gesture that pops
     * one. So the bar came back and the composer was lifted above it with a
     * bottom `safeAreaInset`.
     *
     * **Then: hidden again, because he supplied the missing way out himself.**
     * *"Pill should not be inside the chat box — there should be a back button
     * to go back on home."* The whole case for the bar was that nothing else
     * could leave the screen; a back button leaves it. What was left was the
     * original complaint: a composer with a floating pill sitting over it is two
     * things competing for one thumb.
     *
     * **Now: shown, because the composer is not here any more.**
     *
     * *"When we land on the copilot page there should be directly a new session
     * started… if there is already an existing session it should start from
     * there."* The tab lands **in a session** now, and a session is `.session`,
     * not this — so the chat box that this rule was protecting is on the other
     * surface, and `.session` still hides the bar for exactly the reason it
     * always did. What is left here is a short list of rows with nothing to type
     * into, and the argument for hiding a tab bar over it has gone with the
     * field it was about.
     *
     * Measured, not reasoned: with the bar hidden this screen was the one tab in
     * the app you could not leave sideways — the walk found it, failing to reach
     * Menu from here, and a person is in the same position with only a chevron
     * that goes back rather than across. A four-icon pill that vanishes on one
     * of its four is a pill that cannot be trusted.
     *
     * `CopilotView` still draws its back button in `.topBarLeading` calling
     * `DeckModel.leaveCopilot()`, and it is still correct — going *back* and
     * going *across* are different acts and this screen now offers both.
     */
    case copilot
}

enum DeckChrome {

    /// Whether the tab bar is drawn over this screen.
    static func showsTabBar(on surface: DeckSurface) -> Bool {
        switch surface {
        case .sessions, .localhost, .settings, .machines, .copilot:
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
