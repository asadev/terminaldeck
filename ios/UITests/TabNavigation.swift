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
     * from earlier in the same case. `settings.alerts` is the proof, and the pop
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
        /*
         * Pressed by its new name, and kept under its old one.
         *
         * > *"we can rename this settings page to menu page — settings should
         * > be inside it."*
         *
         * The pill says **Menu** since 2026-08-24 and the screen it opens is
         * still the settings screen with the six machine tools stacked above it,
         * so the helper keeps the name every caller here already uses rather
         * than renaming twenty call sites to match a label. The `settings.alerts`
         * probe below is what actually proves arrival, and it is unchanged.
         */
        openTab("Menu")
        if buttons["settings.alerts"].waitForExistence(timeout: 4) { return true }
        // Something is pushed over it. One Back is enough — Settings is one deep.
        let back = navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        return buttons["settings.alerts"].waitForExistence(timeout: 10)
    }

    /**
     * The **Browser** tab, at its root, and proof it arrived.
     *
     * Called `openBrowserTab` until 2026-08-24, when the tab it opens stopped
     * being called Localhost: *"instead of having local host page on the pill
     * and one separate feature as watch browser in the settings page, we should
     * have only one which will be called browser."* Renamed with it, because a
     * helper that says Localhost and presses Browser is the next person's
     * confusion.
     *
     * ## The proof has moved three times, which is what this indirection is for
     *
     * There is no *row* that is always present — a machine with nothing open has
     * none — so the proof has always been the tab's own always-on control. It
     * was a Refresh button, then a `+` that raised an address sheet, then the
     * address bar itself once that came out of the sheet and onto the screen.
     * Five suites failed on `localhost.open` the day the `+` went.
     *
     * It is the `…` now, because the address bar is no longer on this screen:
     * *"the home page of the browser should be for the open browser windows, and
     * we should be able just to see only the open windows… Even the localhost
     * thing should be folded somewhere else."* The tab's root is the machine's
     * open windows and nothing else, and the one control on it that does not
     * depend on a capability or on there being anything open is that menu.
     *
     * ## And it walks back, because this tab is now three deep
     *
     * Localhost, a window, that window's settings and a tunnelled page all push
     * onto this tab's stack, and a case that left one of them standing used to
     * come back to it rather than to the root. Tapping an already-selected tab
     * does not pop a SwiftUI `NavigationStack`, so the chevron is pressed until
     * the root's own menu is what is on screen — the same shape
     * `openSettingsTab` uses one screen up, with a deeper stack to walk.
     */
    @discardableResult
    func openBrowserTab() -> Bool {
        openTab("Browser")
        if buttons["browser.more"].waitForExistence(timeout: 8) { return true }
        // Four, which is one more than the deepest this tab goes: Localhost, a
        // page on it, and back out. A bounded loop rather than `while`, because
        // a screen with a nav bar and no back button would otherwise hang here.
        for _ in 0 ..< 4 {
            let back = navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            if buttons["browser.more"].waitForExistence(timeout: 3) { return true }
        }
        return buttons["browser.more"].waitForExistence(timeout: 10)
    }

    /**
     * The **ports and the dev servers**, which are inside the sheet that opens a
     * window.
     *
     * They were the Browser tab itself, then for one round they were a pushed
     * screen behind its `…`, and now they are neither:
     *
     * > *"now here you still kept localhost as a separate page inside the page,
     * > and the browser as a separate page in the page. So I wanted it to be
     * > like ONE page where I can start a new window."*
     *
     * A port is an address, so the ports live where an address is chosen. Every
     * suite that wants a port row, a dev server or the address field comes
     * through here, and what changed for them is only the way in — the rows,
     * their identifiers, their swipes and their menus are the same ones.
     *
     * The name is kept because four suites call it and what it means has not
     * changed: *get me to the ports*.
     */
    @discardableResult
    func openLocalhostList() -> Bool {
        // Already there — including the case where a previous test left the
        // sheet up, which is cheaper to keep than to dismiss and re-raise.
        if textFields["browser.address"].exists { return true }
        guard openBrowserTab() else { return false }

        let plus = buttons["browser.new"]
        guard plus.waitForExistence(timeout: 10) else { return false }
        plus.tap()
        guard textFields["browser.address"].waitForExistence(timeout: 15) else { return false }

        /*
         * And put the sheet on **This phone**, because that is what a port meant
         * on the screen these suites were written against.
         *
         * The sheet opens on *Machine* — the common case is a window in the
         * machine's own browser — and a port tapped there opens over there, on a
         * screen whose controls are named `browser.machine.window.…` rather than
         * `localhost.…`, so a suite waiting for this phone's own page never sees
         * it arrive. Every suite that comes through this helper and then taps a
         * port row is a suite about this phone's own tunnel browsing; the one
         * that does not tap a row at all (the swipe suite) is unaffected by which
         * destination is lit.
         *
         * The probe used to be named here as `localhost.done`, and there is no
         * Done any more: the page on this phone wears the same six controls as
         * every other browser window and closing the tunnel moved into the `…`
         * as `localhost.close`. The prefix is unchanged, so `localhost.reload`
         * and the rest still say which screen arrived.
         *
         * Absent on a machine that will not serve a port to a phone, which is a
         * real state and not a failure: the destination is simply not drawn, and
         * the suites that need a tunnel skip on the row that is missing.
         *
         * ## The tap landing is now asserted, and that is not tidying
         *
         * This was `if phone.exists { phone.tap() }` and nothing else, so a
         * destination control that stopped selecting on one tap — a `Menu`, whose
         * first tap only presents — would leave every one of these suites
         * passing while they quietly opened windows in his **real** Chromium
         * profile instead of a throwaway one. Nothing in a build log says so and
         * no screenshot looks wrong. `isSelected` is the trait the destination
         * rows carry, so this is one line and it closes that hole for good.
         */
        let phone = buttons["This phone"]
        if phone.waitForExistence(timeout: 3) {
            phone.tap()
            XCTAssertTrue(phone.isSelected,
                          "one tap on This phone must SELECT it. If it does not, every suite that "
                          + "comes through here is opening pages in the machine's own browser "
                          + "while still passing.")
        }
        return true
    }

    /// Put the new-window sheet away, for a case that opened it only to read the
    /// ports. Never presses Open — that would put a window on a real machine.
    func closeLocalhostList() {
        let cancel = buttons["browser.open.cancel"]
        if cancel.exists { cancel.tap() }
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
     *
     * **It answers a confirmation now.** Forget went straight through to
     * `unpair` until 0.10.3; it asks first since the same verb became a swipe on
     * the row, because a gesture a thumb can complete must not be able to unpair
     * a computer on its own. Six suites call this helper as teardown and every
     * one of them would otherwise have stopped at a standing alert — which is
     * exactly what this file exists to absorb. The confirm is taken as optional
     * rather than asserted: this is teardown, and a helper that fails a case
     * about something else because a dialog changed shape is worse than one that
     * quietly does nothing.
     */
    func forgetEveryMachine() {
        for _ in 0 ..< 6 {
            // Nothing left to forget — the phone is back at its first screen.
            // That is the **server login** now, with pairing one tap behind it,
            // so testing for the pairing field alone would loop six times over a
            // phone that had already finished. See `reachPairingField`.
            if textFields["pairing.field"].exists { return }
            if buttons["serverLogin.pairingDoor"].exists { return }
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
            /*
             * The confirmation, answered in the affirmative — the one place in
             * this target that is allowed to.
             *
             * `.firstMatch`, for the reason `renameFirstMachine` gives about its
             * Save: SwiftUI nests an alert's button inside a button carrying the
             * same identifier, and a bare subscript throws on the ambiguity.
             * Scoped to the alert's own window, because the alert is one.
             */
            let confirm = alerts.firstMatch.buttons["forget.confirm"].firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            _ = textFields["pairing.field"].waitForExistence(timeout: 3)
            _ = buttons["serverLogin.pairingDoor"].waitForExistence(timeout: 3)
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
    /**
     * The six-digit field — **opening the door to it first, if that is where it
     * is.**
     *
     * Every self-pairing suite in this target used to reach straight for
     * `textFields["pairing.field"]` on the app's first frame, and for a long
     * time that was right: the first screen *was* the pairing screen.
     *
     * It is not any more. *"Say no MacBook or Windows exists at all — a user
     * only has a server and a phone"* put the **server login** on the first
     * frame and moved pairing behind one tap — `serverLogin.pairingDoor`, which
     * `OneLoginUITests` asserts is *"one tap away"*. Every helper that waited on
     * the field alone therefore waited eight seconds, found nothing, and
     * concluded the phone was **already paired** — so the suite carried on
     * against a machine it had never connected to, and its cases failed or
     * skipped for reasons that looked like anything but this.
     *
     * That is what this exists to stop happening again in twenty-two files: the
     * question *"where is the pairing field"* is answered once, here.
     *
     * Returns false when there is no pairing field to be had — which is the
     * honest answer for a phone that really is already paired, and is what the
     * callers key their "nothing to do" branch off.
     */
    @discardableResult
    func reachPairingField(timeout: TimeInterval = 8) -> Bool {
        let field = textFields["pairing.field"]
        if field.waitForExistence(timeout: timeout) { return true }
        // Not on screen — so either this phone is paired, or the login is in
        // front of it. The door is only ever on the first frame, so a short wait
        // is enough and a long one would be eight seconds per case for nothing.
        let door = buttons["serverLogin.pairingDoor"]
        guard door.waitForExistence(timeout: 3), door.isHittable else { return false }
        door.tap()
        return field.waitForExistence(timeout: timeout)
    }

    @discardableResult
    func beginPairingAnotherMachine() -> Bool {
        guard openMachinesTab() else { return false }
        let add = buttons["machines.add"]
        guard add.waitForExistence(timeout: 10) else { return false }
        add.tap()
        return textFields["pairing.field"].waitForExistence(timeout: 20)
    }

    /**
     * The login, from wherever this phone happens to be — and there is only one.
     *
     * It used to be two walks: this one, and a `beginAddingAServer` that went
     * through it and then tapped a line at the foot of it to reach a *second*
     * form. That second form is deleted, and so is the walk to it. What is left
     * is the route a person takes.
     *
     * On a phone with nothing on it the login **is** the window — `RootView`
     * puts it there rather than a pairing code — so there is nothing to tap and
     * the fields are already on screen. On a phone that has something, it is the
     * row on Machines. Both are real first steps and a helper that knew only one
     * of them would be walking the wrong phone.
     */
    @discardableResult
    func beginLoggingIntoAServer() -> Bool {
        // Already there: the gate is the login now.
        if textFields["serverLogin.address"].waitForExistence(timeout: 5) { return true }
        guard openMachinesTab() else { return false }
        let add = buttons["machines.addServer"]
        guard add.waitForExistence(timeout: 10) else { return false }
        add.tap()
        return textFields["serverLogin.address"].waitForExistence(timeout: 20)
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

extension XCUIApplication {
    /**
     * Close a presented `Menu`, if one is up, the way tapping outside it does.
     *
     * UIKit puts a full-screen `PopoverDismissRegion` behind every presented
     * menu and popover, and tapping it is the dismissal. `app.tap()` is not a
     * substitute: it lands in the middle of the screen, which on this app is
     * usually a row *underneath* the popover, and whether it dismisses or
     * navigates depends on what happens to be there.
     *
     * Silent when nothing is presented — every caller uses it as a "make sure
     * nothing is over the screen" before moving to another tab, and the common
     * case is that nothing is.
     */
    func dismissAnyMenu() {
        if otherElements["PopoverDismissRegion"].exists {
            otherElements["PopoverDismissRegion"].tap()
            return
        }
        /*
         * **A coordinate, because on iPhone there is no element to press.**
         *
         * Measured on iOS 26: a SwiftUI `Menu` on iPhone presents with **no**
         * `PopoverDismissRegion` in the hierarchy at all, and neither
         * `app.tap()` nor a tap on the navigation bar closes it — the run sat on
         * the Browser tab with the menu standing over it until it timed out,
         * twice, and every later tap was eaten by the invisible dismiss layer.
         *
         * A tap outside the popover's own bounds is what a person does, and the
         * only way to express that here is a point. Low and left: 0.9 down the
         * screen is under every menu this app presents from a toolbar, and 0.12
         * across is clear of the tab bar's leftmost pill, which sits from about
         * 0.15. Harmless when no menu is up — it lands on empty ground.
         */
        coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.9)).tap()
    }
}
