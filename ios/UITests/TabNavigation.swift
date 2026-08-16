/**
 * Where the machine and account controls moved to, in one place.
 *
 * They used to live in the session list's `…` menu — pair another machine,
 * rename this one, forget it, the GitHub account, the alert switches, seven items
 * deep in a corner. They are now two tabs, `Machines` and `Settings`, and the
 * reasoning is in `DeckTabs.swift`.
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

    /// The Machines tab, and proof it arrived.
    @discardableResult
    func openMachinesTab() -> Bool {
        openTab("Machines")
        return buttons["machines.add"].waitForExistence(timeout: 10)
    }

    /// The Settings tab, and proof it arrived.
    @discardableResult
    func openSettingsTab() -> Bool {
        openTab("Settings")
        return buttons["settings.github"].waitForExistence(timeout: 10)
    }

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
