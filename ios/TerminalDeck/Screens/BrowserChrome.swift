/**
 * One browser, three kinds of window — and the rules all three share.
 *
 * > *"So top, header and footer, tab bar should be same in all type of browsing
 * > windows, including on this phone, including isolated, including the server."*
 *
 * > *"All of these things inside of a terminal will be much better. They have
 * > different kind of looks, all of them. So let's just try to make them all
 * > simple, easier."*
 *
 * ## What the three kinds were, and why they looked like three products
 *
 * There are three things this app calls a browser window and until this pass
 * each of them wore its own chrome:
 *
 *  - **a window on the machine**, and **an isolated window on the machine** —
 *    the same Swift type (`MachineWindow`, one `isolated` flag) on the same
 *    screen, `MachineWindowView`. Header: the window's name. Bottom:
 *    `BrowserPageBar` — an address field and Go, then Back, Forward, Reload and
 *    a `…`.
 *  - **a page on this phone** — a different type entirely (`BrowserTab`: a port
 *    and a path claimed on a tunnel) on its own screen, `LocalhostBrowser`.
 *    Header: two lines, the page's title over a mono line reading
 *    `http://127.0.0.1:52311/admin  ·  3 connections`. Bottom: the system
 *    toolbar — Back, Forward, Reload, Find, Inspect, Done. **No address
 *    anywhere**, because that screen's address was chosen once, up front, in the
 *    sheet that opened it.
 *
 * He held them side by side and read the difference as a defect rather than as
 * an implementation detail, which is what it was:
 *
 * > *"if it is in this phone, I cannot edit the link and make a change and
 * > search it again."*
 *
 * > *"when we come back to this phone one, in this phone one, this button needs
 * > to, this overall buttons needs to be more better. They can be much better
 * > than now."*
 *
 * ## The shape both screens mount now
 *
 * **Header** — the system's back chevron, the page's name on one line, and
 * nothing else. What came off it is the half he called information rather than
 * control:
 *
 * > *"even if we remove the top header of paperclip and all of this basic
 * > information might not be required from the outside. We can just see and
 * > enter."*
 *
 * So the mono address line and the `· 3 connections` count are gone from the top
 * of the phone's page. Neither is lost: the address is now a **field** in the
 * bar, which is the thing he asked for and could not have before, and the
 * connection count is one line inside the `…`. *From the outside* it is gone.
 *
 * **Bottom bar** — `BrowserPageBar`, two rows, the same two rows under every one
 * of the three kinds:
 *
 *  - the address, editable, with Go;
 *  - Back · Forward · Reload · Find · Inspect · More.
 *
 * ## Where the `…` lives, decided once
 *
 * In the **bar**, as the sixth control, and not in the header — one door, and it
 * is the door under a thumb. Three reasons, in the order they mattered:
 *
 *  1. A menu in the top-right corner of a six-inch phone is the furthest pixel
 *     from a thumb on the screen, and *"this overall buttons needs to be more
 *     better"* is a sentence about the bottom of the screen.
 *  2. *"top, header and footer… should be same in all type"* is satisfied more
 *     completely by a header that is the system chevron and one line of title on
 *     every kind — there is then nothing left up there that can drift.
 *  3. Two doors onto the same menu is the thing this whole pass is undoing.
 *
 * The bar's More therefore carries **everything else this window can do**,
 * including the verb that used to be a button of its own on the phone: Done tore
 * the tunnel down, and it is `Close this window` in that menu now. The chevron
 * top-left still leaves the page and still closes the tunnel, so the one-tap way
 * out was never the button.
 *
 * ## What lives in this file
 *
 * The rules that would otherwise be written twice and drift: how a page is
 * named, how a loopback address is spelled for a person to read, and the two
 * sentences that explain why a control this phone cannot honour is greyed. The
 * drawing is `BrowserPageBar`; the two screens are `MachineWindowView` and
 * `LocalhostBrowser`.
 */

import SwiftUI

enum BrowserChrome {

    /**
     * What a page is called, everywhere.
     *
     * The page's own title once it has one, its address until then, and a
     * last-resort name for a page that has neither yet. This is not a new rule —
     * it is `MachineWindow.label` (`title.isEmpty ? url : title`) with the third
     * case spelled out, and it is written here so that the two screens cannot
     * grow two versions of it. *"Untitled"* tells nobody which of their four
     * windows they are looking at, which is exactly when the name matters.
     */
    static func pageTitle(title: String, address: String, fallback: String) -> String {
        if !title.isEmpty { return title }
        if !address.isEmpty { return address }
        return fallback
    }

    /**
     * A tunnelled address, written the way the person who opened it thinks of it.
     *
     * A page on this phone is really at `http://127.0.0.1:52311/admin`, where
     * `52311` is a port **this phone picked at random** when it bound the
     * listener. Nobody chose that number, nobody can act on it, and it is the
     * exact string he pointed at and called information he does not need. What he
     * chose is the port on the machine — `3000` — so that is what the field says:
     * `localhost:3000/admin`.
     *
     * This is a spelling, not a redirection. Both forms are read back correctly
     * when they are typed in: `LocalhostAddress.classify` treats every loopback
     * host the same, and the screen accepts either the machine's port or the
     * phone's own before it navigates. So somebody who edits `localhost:3000`
     * into `localhost:3000/admin` and somebody who pastes the raw
     * `127.0.0.1:52311/x` both land where they meant to.
     *
     * Anything that is not a loopback URL is handed back untouched — once a page
     * has navigated off to a real site, that site's own address is the honest
     * thing to show.
     */
    static func shownAddress(_ raw: String, machinePort: Int) -> String {
        guard let url = URL(string: raw), let host = url.host(), isLoopback(host) else { return raw }
        var line = "localhost:\(machinePort)"
        line += url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { line += "?\(query)" }
        if let fragment = url.fragment, !fragment.isEmpty { line += "#\(fragment)" }
        return line
    }

    /// The spellings of *this phone*. `LocalhostAddress` asks the same question
    /// of the same names on the way in; this is the way out, and the two have to
    /// agree or an address would stop round-tripping.
    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        return name == "localhost" || name == "127.0.0.1" || name == "::1" || name == "[::1]"
    }

    /**
     * Why Find is greyed on a page that lives on the machine.
     *
     * Find reads the words out of a document **this phone has loaded** — it is
     * `WKWebView`'s own find, driven by `BrowserFindSession`. A window on the
     * machine is a picture of that machine's browser arriving frame by frame:
     * there is no text on this phone to look through, and no verb in the
     * `browser.window.*` family that would ask the machine to look for us.
     *
     * A default on the bar rather than a sentence each screen writes, because it
     * is one fact about one wire and three copies of it would be three places for
     * it to drift. The day a host learns to search a window, the screen passes a
     * closure and this sentence stops being read.
     */
    static let findIsLocal =
        "Find looks through the words on a page this phone has open. This one is on the machine, "
        + "so there is nothing here to search."

    /**
     * Why Inspect is greyed on a page that lives on the machine.
     *
     * Same shape as Find and a different reason: inspecting runs a script inside
     * the page and reads an element back out of it, which needs the page itself
     * rather than a picture of it. Reaching into a window on the machine is real
     * work on the host and it is not built yet — see `MachineWindowView.bar` for
     * the seam it will arrive through.
     */
    static let inspectIsLocal =
        "Inspect describes whatever you tap on a page this phone has open. Tapping into a window "
        + "on the machine is not ready yet."
}

/**
 * What the `…` at the end of the bar opens, on a page whose *everything else* is
 * a short list rather than a screen.
 *
 * Two shapes fill that one slot and they are not interchangeable, which is why
 * `BrowserPageBar` takes both:
 *
 *  - **`more`, an action.** A window on the machine has a whole screen of things
 *    that are about the window rather than about the page — the jar its cookies
 *    land in, the session that owns it, the screenshot, the recorder, Close. The
 *    `…` pushes `MachineWindowSettingsView`, and a menu in front of that screen
 *    would be one tap of nothing.
 *  - **`menu`, this.** A page on this phone has no window on the machine and so
 *    no such screen. What it has is one verb — the Done that used to sit in the
 *    toolbar and tears the tunnel down — and one fact worth keeping, the number
 *    of connections the tunnel is holding open, which is the honest signal that
 *    a hot-reload socket is still talking with nothing on screen changing. A
 *    menu is the right size for that; a screen would be a page of white space.
 */
struct BrowserPageMenu {

    /// One line of plain fact at the top, or nil. Drawn as a menu label, which
    /// iOS renders un-tappable — it is information and must not look like a
    /// control that refused.
    var note: String?

    var items: [Item]

    /// One thing the page can be asked to do.
    struct Item: Identifiable {
        /// The accessibility identifier, given whole rather than built from the
        /// bar's prefix: these are the names a test reaches for, and an item that
        /// only exists after the menu has been opened is hard enough to find
        /// already.
        let id: String
        let title: String
        let icon: String
        /// Whether iOS should draw it in red. True for a verb that ends something
        /// a person would not expect to get back.
        var destructive = false
        let act: () -> Void
    }
}
