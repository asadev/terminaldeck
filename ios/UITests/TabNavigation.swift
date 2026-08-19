/**
 * Where the machine and account controls moved to, in one place.
 *
 * They used to live in the session list's `…` menu — pair another machine,
 * rename this one, forget it, the GitHub account, the alert switches, seven items
 * deep in a corner. They became two tabs; the machines have since moved again,
 * into a row on Settings, and the localhost list has become a tab of its own. The
 * reasoning for all of it is in `DeckTabs.swift` and `DeckModel.Tab`.
 *
 * That second move is exactly why this file exists, and it paid for itself: six
 * suites call `openMachinesTab()` and not one of them had to change when the
 * Machines tab stopped being a tab.
 *
 * Six suites reached for those menu items, in eight places, mostly as teardown.
 * This file is the seam so that the *next* change to the navigation is one edit
 * rather than eight — the previous arrangement had `sessions.more` hard-coded in
 * six files as a way of asking "am I on the list", which is why moving anything
 * at all was a day's work.
 *
 * ## Read this before trusting it
 *
 * Everything here is **compiled but not run**: it drives a paired phone against a
 * real desktop, and there was none on the machine this was written on. Each
 * helper therefore asserts that it *arrived* rather than assuming the tap landed
 * — a tab query that turns out to be wrong fails on the next line with a sentence
 * saying which screen it did not reach, instead of silently doing nothing and
 * failing somewhere unrelated ten lines later.
 */

import XCTest

extension XCUIApplication {

    /**
     * Move to a tab by its name.
     *
     * `tabBars.buttons[name]` is the query, and it survives the iOS 26
     * appearance: the bar draws itself as a floating pill there, but it is still
     * a `UITabBar` and its items are still buttons carrying the tab's label. The
     * fallback to a plain button query is a hedge against that not holding on
     * some future release — it is not a second way for this to pass, because the
     * caller checks what appeared afterwards either way.
     */
    func openTab(_ name: String) {
        let inBar = tabBars.buttons[name]
        if inBar.waitForExistence(timeout: 10) {
            inBar.tap()
            return
        }
        let anywhere = buttons[name]
        if anywhere.waitForExistence(timeout: 5) { anywhere.tap() }
    }

    /**
     * The machines, and proof they arrived.
     *
     * **No longer a tab.** It is a row inside Settings — *"maybe this machines
     * thing can go inside the settings this page overall… Here we can have a
     * section, we click and we reach to this page"* — so this is two taps now.
     * The name is unchanged on purpose: six suites call it, they care about
     * arriving rather than about how, and this file exists precisely so that a
     * move like this one is one edit instead of eight.
     *
     * A pop first, because Settings keeps its stack across tab switches: a case
     * that left the machines pushed would find the row it is about to tap
     * already off screen behind them.
     */
    @discardableResult
    func openMachinesTab() -> Bool {
        guard openSettingsTab() else { return false }
        let row = buttons["settings.machines"]
        guard row.waitForExistence(timeout: 10) else { return false }
        row.tap()
        return buttons["machines.add"].waitForExistence(timeout: 10)
    }

    /**
     * The Settings tab, and proof it arrived.
     *
     * Settings has a navigation stack of its own now, so arriving at the tab is
     * not the same as arriving at the *screen*: the machines may still be pushed
     * from earlier in the same case. `settings.github` is the proof, and the pop
     * is what makes it true.
     *
     * The first probe is short and the second is not, on purpose. When the root
     * is already showing, `waitForExistence` returns the moment it sees the row —
     * the timeout is only ever paid when something *is* pushed, and
     * `forgetEveryMachine` walks this loop six times. A false negative here costs
     * a tap on a navigation bar that has no back button, which does nothing.
     */
    @discardableResult
    func openSettingsTab() -> Bool {
        openTab("Settings")
        if buttons["settings.github"].waitForExistence(timeout: 4) { return true }
        // Something is pushed over it. One Back is enough — Settings is one deep.
        let back = navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        return buttons["settings.github"].waitForExistence(timeout: 10)
    }

    /// The Localhost tab, and proof it arrived. There is no row that is always
    /// present — a machine serving nothing has none — so the proof is the tab's
    /// own toolbar control, which is on the screen in every state. It used to be
    /// a Refresh button and it is the `+` that opens an address now; the pull
    /// gesture took over the refreshing. See `LocalhostListView`.
    @discardableResult
    func openLocalhostTab() -> Bool {
        openTab("Localhost")
        return buttons["localhost.open"].waitForExistence(timeout: 10)
    }

    /**
     * The Copilot tab, and proof it arrived.
     *
     * **Was a row on the session list** — `copilot.row`, pinned above the
     * sessions — until *"a fourth pill, and the copilot goes leftmost"*. Five
     * suites reached for that row and none of them cares how it is reached, only
     * that they end up looking at the conversation, which is exactly what this
     * file exists for.
     *
     * **And the pill is now conditional**, which changes what a `false` from
     * here means: *"if the copilot is not connecting, this icon should not be
     * inside the pill — then it will be three icon pill. Otherwise if the
     * copilot is connected, then four icon pill."* So a phone that has not
     * connected a copilot to the machine on screen has no Copilot pill at all,
     * and this returns false rather than failing — which is the correct answer,
     * not a flake. A caller that needs the connection first calls
     * `connectTheCopilot` in its own suite, or `openCopilotSettings()` below.
     *
     * A pop first, for the reason `openSettingsTab` does one: this tab has a
     * stack of its own, and a case that left a terminal pushed on it would come
     * back to the terminal rather than to the copilot. **Back on this screen is
     * `copilot.back`, not a chevron the navigation stack supplied** — the screen
     * draws no tab bar any more, so that button is its only way out — and it is
     * in the same leading slot, so `element(boundBy: 0)` still finds whichever
     * one is there.
     *
     * The proof is deliberately loose — *something* the copilot screen draws.
     * There is no one element common to every access state: a phone whose socket
     * is in has a composer, one waiting for its machine has a spinner, and a
     * machine with no copilot for this phone has a sentence. Asserting any
     * single one of those here would make this helper mean "arrived at the
     * copilot **and** it is in the state I expected", which is the caller's
     * assertion, not this one's.
     */
    @discardableResult
    func openCopilotTab() -> Bool {
        // No pill means this phone has no copilot on the machine on screen —
        // a guest, or a build without one — which is an answer rather than a
        // failure. Checked before tapping rather than relying on `openTab`'s
        // fallback, which searches the whole screen for the word and would find
        // it in a sentence explaining why there is no copilot here.
        guard tabBars.firstMatch.buttons["Copilot"].waitForExistence(timeout: 10) else {
            return false
        }
        tabBars.firstMatch.buttons["Copilot"].tap()
        if copilotIsShowing { return true }
        // Something is pushed over it — one Back is enough; this stack is one
        // deep by construction.
        let back = navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        return copilotIsShowing
    }

    private var copilotIsShowing: Bool {
        for _ in 0 ..< 10 {
            if textFields["copilot.composer"].exists
                || buttons["copilot.back"].exists
                || otherElements["copilot.notGranted"].exists
                || otherElements["copilot.notOffered"].exists
                || staticTexts["Copilot"].exists {
                return true
            }
            _ = staticTexts["Copilot"].waitForExistence(timeout: 1)
        }
        return false
    }

    /*
     * **`openCopilotSettings()` used to be here, and there is nothing left for
     * it to open.**
     *
     * It tapped a `settings.copilot` row and waited for a screen with a
     * six-digit field on it — *"actually connecting copilot should be in the
     * settings"* — which was where the code went when the Copilot pill started
     * appearing only for a connected copilot.
     *
     * Then the code itself went: *"if we are connecting as my device copilot
     * automatically comes, if we connect as guest then copilot don't come."*
     * There is no connect screen, no row that pushes one, and nothing in
     * Settings that mentions the copilot at all — a row whose only content was a
     * status is clutter, and the pill's presence says the same thing faster.
     *
     * The lesson underneath it is kept, because it is about SwiftUI rather than
     * about this feature: an `accessibilityIdentifier` on a container — a
     * `ScrollView`, a `VStack`, a `ContentUnavailableView` — makes the container
     * an accessibility *element* and everything inside it stops existing.
     * Measured here on iOS 26.4, where a text field plainly on screen could not
     * be found because the stack around it carried the screen's name. Name the
     * control, not the container.
     */

    /// Back to the sessions, which is where every other suite expects to be.
    func openSessionsTab() {
        openTab("Sessions")
    }

    /**
     * The row menu on the first machine in the list.
     *
     * By prefix rather than by id: a row's identifier carries the host id, which
     * is minted at pairing time and is not knowable from a test. Every helper
     * below that acts on "a machine" acts on the first one, which is what the old
     * menu did too — it only ever offered the machine on screen.
     */
    private func firstMachineMenu() -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'machine.more.'"))
            .firstMatch
    }

    /**
     * Forget every paired machine, through the app's own controls.
     *
     * Deliberately not a launch argument that wipes the Keychain: a back door
     * that exists for a test is product code nobody uses, and doing it this way
     * exercises unpairing for free. Six passes, because a phone in these suites
     * is paired with at most two or three and the loop has to end.
     */
    func forgetEveryMachine() {
        for _ in 0 ..< 6 {
            // Already at the pairing screen — there is nothing left to forget.
            if textFields["pairing.field"].exists { return }
            guard openMachinesTab() else { return }
            let menu = firstMachineMenu()
            guard menu.waitForExistence(timeout: 3) else { return }
            menu.tap()
            let forget = buttons["machine.forget"]
            guard forget.waitForExistence(timeout: 3) else {
                // Dismiss whatever is up rather than leaving a menu open over the
                // next case's first tap.
                tap()
                return
            }
            forget.tap()
            _ = textFields["pairing.field"].waitForExistence(timeout: 3)
        }
    }

    /**
     * Rename the first machine on the Machines tab.
     *
     * The two things that cost this a night the first time it was written are
     * unchanged and still the reason it is written this way: the alert lives in a
     * window of its own, so the query has to be scoped to the alert rather than
     * to the app; and the text field carries no identifier, because SwiftUI drops
     * one on the way to `UIAlertController` — the placeholder is the handle.
     */
    func renameFirstMachine(to name: String) {
        guard openMachinesTab() else { return }
        let menu = firstMachineMenu()
        guard menu.waitForExistence(timeout: 10) else { return }
        menu.tap()
        let rename = buttons["machine.rename"]
        guard rename.waitForExistence(timeout: 10) else { return }
        rename.tap()

        let alert = alerts.firstMatch
        guard alert.waitForExistence(timeout: 10) else { return }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { return }
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText(name)
        // `.firstMatch`, because SwiftUI nests the alert's button inside a button
        // of the same identifier and a bare subscript throws on the ambiguity.
        alert.buttons["rename.save"].firstMatch.tap()
    }

    /// Open the sheet that takes a pairing code for an additional machine.
    @discardableResult
    func beginPairingAnotherMachine() -> Bool {
        guard openMachinesTab() else { return false }
        let add = buttons["machines.add"]
        guard add.waitForExistence(timeout: 10) else { return false }
        add.tap()
        return textFields["pairing.field"].waitForExistence(timeout: 20)
    }

    /// The GitHub account screen, from Settings.
    @discardableResult
    func openGitHubAccount() -> Bool {
        guard openSettingsTab() else { return false }
        let row = buttons["settings.github"]
        guard row.waitForExistence(timeout: 10) else { return false }
        row.tap()
        return buttons["github.done"].waitForExistence(timeout: 10)
    }

    /// The alerts screen, from Settings.
    @discardableResult
    func openAlerts() -> Bool {
        guard openSettingsTab() else { return false }
        let row = buttons["settings.alerts"]
        guard row.waitForExistence(timeout: 10) else { return false }
        row.tap()
        return buttons["alerts.done"].waitForExistence(timeout: 10)
    }
}
