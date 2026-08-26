/**
 * One browser, four kinds of window — and the rules all four share.
 *
 * > *"So top, header and footer, tab bar should be same in all type of browsing
 * > windows, including on this phone, including isolated, including the server."*
 *
 * > *"All of these things inside of a terminal will be much better. They have
 * > different kind of looks, all of them. So let's just try to make them all
 * > simple, easier."*
 *
 * ## What the kinds were, and why they looked like separate products
 *
 * There are four things this app calls a browser window and each of them used to
 * wear its own chrome:
 *
 *  - **a window on the machine**, and **a private window on the machine** —
 *    the same Swift type (`MachineWindow`, one `isolated` flag) on the same
 *    screen, `MachineWindowView`. Header: the window's name. Bottom:
 *    `BrowserPageBar` — an address field and Go, then Back, Forward, Reload and
 *    a `…`.
 *  - **the machine's own front tab** — the page that opens when nobody named a
 *    window, which the machine lists under the empty name. Same screen; it used
 *    to land somewhere else entirely with one Reload on it.
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
 * ## The shape every one of them mounts now
 *
 * **Header** — the system's back chevron, the page's name on one line, and the
 * `…` that opens everything this window can be asked for. Nothing else, and in
 * particular nothing to *read*:
 *
 * > *"even if we remove the top header of paperclip and all of this basic
 * > information might not be required from the outside. We can just see and
 * > enter."*
 *
 * So the mono address line and the `· 3 connections` count are gone from the top
 * of the phone's page. Neither is lost: the address is now a **field** in the
 * bar, which is the thing he asked for and could not have before. *From the
 * outside* it is gone.
 *
 * **Bottom bar** — `BrowserPageBar`, two rows, the same two rows under every one
 * of the four kinds:
 *
 *  - the address, editable, with Go;
 *  - Back · Forward · Reload · Find · Inspect · Size.
 *
 * ## Where the `…` lives, and the round that moved it back
 *
 * **In the header, trailing side.** The pass before this one put it in the bar
 * as a sixth control and wrote three reasons down: a menu in the top-right
 * corner of a six-inch phone is the furthest pixel from a thumb; a header that
 * is only a chevron and a title has nothing left on it that can drift between
 * kinds of window; and two doors onto one menu is what that round was undoing.
 *
 * Every one of those is true and **none of them is what he asked for**:
 *
 * > *"Maybe we can give some better one header also, not only the bottom, so we
 * > can have most of the important controls for the flow, for this kind of
 * > things and whatever we require to get the job done."*
 *
 * *Not only the bottom* is the sentence, and a header carrying zero controls is
 * the exact opposite of it. So the three sentences he said about this header are
 * read together, because they are one instruction rather than three:
 *
 *  - the header carries the important **controls** — *"not only the bottom"*;
 *  - the header carries no **information** — *"we can just see and enter"*;
 *  - and it is the **same** on every kind of browsing window.
 *
 * Which resolves to: the header carries control and not information, and the
 * same control everywhere. The `…` is the window's own things — closing it, the
 * jar its cookies land in, the session that owns it, the screenshot, the
 * recorder — so it is the control that belongs up there, and the bar keeps the
 * verbs that act on the *page*, which is what a thumb reaches for while
 * reading one.
 *
 * The thumb argument survives the move and is answered rather than ignored:
 * nothing that is pressed while working a page went up there. Back, Forward,
 * Reload, Find and Inspect are all still under the thumb; what moved is the door
 * you go through once, to do something to the window rather than to the page.
 *
 * **There is still exactly one door.** The bar does not keep a More slot, not
 * even a greyed one — `BrowserWindowActions` below is the only `…` in this app's
 * browser, and it is drawn only where it opens something. On a window the
 * machine will not cast, the settings *are* the body of the screen; a `…` there
 * would lead to where you are already standing, so there is none, and there is
 * no sentence about one either.
 *
 * ## What lives in this file
 *
 * The rules that would otherwise be written four times and drift: how a page is
 * named, how a loopback address is spelled for a person to read, the two
 * sentences that explain why a control this phone cannot honour is greyed, and
 * the header's `…` itself. The bottom bar is `BrowserPageBar`; the screens are
 * `MachineWindowView`, `LocalhostBrowser` and `WatchViewerScreen`.
 */

import SwiftUI

enum BrowserChrome {

    /**
     * What a page is called, everywhere.
     *
     * The page's own title once it has one, its address until then, and a
     * last-resort name for a page that has neither yet. This is not a new rule —
     * it is `MachineWindow.label` (`title.isEmpty ? url : title`) with the third
     * case spelled out, and it is written here so that the screens cannot grow
     * four versions of it.
     *
     * **This is not where *Untitled* belongs.** *Untitled* is this round's word
     * for a window with **no page in it**, and a page that has an address is not
     * one of those: naming it *Untitled* would tell nobody which of their four
     * windows they are looking at, which is exactly when the name matters. The
     * address is the honest name, and the caller's `fallback` covers the last
     * case — a window that is not anywhere yet.
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
     * is one fact about one wire and four copies of it would be four places for
     * it to drift. The day a host learns to search a window, the screen passes a
     * closure and this sentence stops being read.
     */
    static let findIsLocal =
        "Find looks through the words on a page this phone has open. This one is on the machine, "
        + "so there is nothing here to search."

    /**
     * Why Inspect is greyed on a screen that is **only watching** a page.
     *
     * It used to say *"tapping into a window on the machine is not ready yet"*,
     * and that sentence is gone because the thing it apologised for **is built
     * and is wired up**: a tap on a machine window's picture becomes
     * `browser.window.pick`, the machine's own browser answers with the element,
     * and one sheet draws both. `MachineWindowView.bar` passes the closure, and
     * `MachineWindowView.toggleInspecting` arms the canvas for it.
     *
     * What is left is the one screen that genuinely cannot ask. `WatchViewerScreen`
     * is reached from **Settings**, holding a `WatchLink` and no model — so there
     * is no `HostLink` behind it and no `browser.control` verb it could send,
     * whatever the machine is offering. A picture is all it has.
     *
     * A default on the bar rather than a sentence each screen writes, because it
     * is one fact about one wire and copies of it would be places for it to
     * drift.
     */
    static let inspectIsLocal =
        "Pointing at one thing on a page is asked of the machine's own browser. This screen is "
        + "only watching a picture of it, so there is nothing here to ask."

    /**
     * Why Inspect is greyed on a window the machine is **not casting**.
     *
     * This one is not about the wire at all — the verb is there and the window
     * can be sent it. There is simply nothing on the screen to point at: a window
     * the machine will not cast draws its own settings as the body, and *tap the
     * thing you mean* has no picture to be a tap on.
     *
     * It is a real state and not a rare one. A window opened from the Browser
     * tab's `+` is minted through `openForSession(NO_SESSION)` and detached in
     * the same breath, so it holds no binding row and `castWindows` cannot see
     * it: it is in `browser.window.rows` and in no `browser.surfaces` entry. So
     * this sentence is what somebody reads on the first window they open, which
     * is why it names what is on the screen instead — the settings are the body
     * of that screen, and saying so is what stops the greyed glyph reading as a
     * feature that is missing.
     */
    static let inspectNeedsThePicture =
        "Pointing at one thing needs the page on screen to point at. This machine is not showing "
        + "this window, so there is only its settings here."

    /**
     * Why Size **used to be** greyed on a window that lives on the machine.
     *
     * ## The expiry this sentence named has arrived — it is not read any more
     *
     * The last paragraph below said *"the day a host learns `browser.window.size`
     * the screen passes a closure and this sentence stops being read."* The host
     * has learnt it: `MachineWindowView` passes a real `BrowserPageSize` whose
     * `choose` sends the machine a rectangle in CSS pixels, and the machine lays
     * the document out in it. So nothing reads this string today.
     *
     * It is kept rather than deleted because what it states is still the **rule**,
     * and the rule is the thing somebody will break: magnifying a picture and
     * calling it a page size is a fake, and any future screen that has a picture
     * and no way to ask for a re-layout owes this sentence rather than a control
     * that quietly does the other thing. The paragraphs below are left exactly as
     * they were written so that the argument survives its own conclusion.
     *
     * > *"they can pinch and zoom also they can see all the different dimensions
     * > in responsive views how it will look like in mobile how it will look like
     * > on Windows."*
     *
     * Both halves of that control need a **document**, and a machine window is a
     * picture of one. Re-laying a page out at 1280 × 800 CSS px is a viewport
     * instruction to the engine that owns the DOM: the engine here is the
     * machine's, the window it is drawing has whatever size the machine gave it,
     * and there is no verb in `MachineWindow.Act` that carries a size — back,
     * forward, reload, close, record, share and isolate, and nothing else.
     * Magnifying the picture instead is the thing this control must never be: it
     * would answer *"how does this look on a laptop"* with a phone layout in
     * bigger letters, which is the exact fake the honest implementation exists to
     * avoid (see `PageWidths`).
     *
     * That is a fact about this wire rather than about this feature, so the day a
     * host learns `browser.window.size` the screen passes a closure and this
     * sentence stops being read. Until then it is one sentence in one place, and
     * the four screens cannot grow four paraphrases of it.
     *
     * Pinching a machine window is not lost and is not what this is about: that
     * screen's canvas has had its own magnification for rounds, and
     * `BrowserPageBarUITests` performs one. What it cannot do is change the
     * rectangle the page was laid out in.
     */
    static let sizeIsLocal =
        "Page size re-lays out a page this phone has open. This one is on the machine, which "
        + "sends pictures, so there is no layout here to change."
}

/**
 * The `…` in the header of every browser window, and the only one in the app.
 *
 * > *"Maybe we can give some better one header also, not only the bottom, so we
 * > can have most of the important controls for the flow."*
 *
 * Placed by each screen as a trailing item in the system navigation bar, so it
 * sits beside the title with the chevron opposite it — the same two things in
 * the same two corners on a machine window, a private window, the machine's
 * own front tab, and a page this phone is holding open. The header carries this
 * and nothing else: a control, never a line to read.
 *
 * ## One identifier, wherever it is drawn
 *
 * `"\(id).settings"`, built here from the bar's own prefix rather than by the
 * screens, so `browser.machine.window.settings` and `localhost.settings` still
 * name this control after it changed places. Six suites reach for those two
 * strings and none of them had to move.
 *
 * ## Two shapes, and they are not interchangeable
 *
 *  - **`open`, a screen.** Every kind of window that has one: a window on the
 *    machine, the machine's own front tab, and — since this round — a page on
 *    this phone. All three push `MachineWindowSettingsView`, which is where
 *    *"settings of per window, how to connect to it, how to make it shared or
 *    isolated, all of these things should be inside of the window"* lives. A
 *    menu in front of a screen would be one tap of nothing.
 *  - **`menu`, a short list.** The one page with no settings screen behind it:
 *    a prototype opened straight from a file, which `ArtifactView` pushes at a
 *    tunnel without a row in the Browser tab's list to hang settings off. What it
 *    has is one verb and one fact, and a screen for that would be a page of white
 *    space.
 *
 * ## Drawn only where it opens something
 *
 * There is no greyed shape of this and no sentence explaining one. The case that
 * would have wanted them is a window the machine refuses to cast: that screen
 * draws its settings **as its body**, so a `…` leading to them would lead to
 * where you are already standing. An absent trailing button in a header is not
 * the gap a missing slot in a row of six was — the row was the thing he counted,
 * and the row is now five under every page.
 */
struct BrowserWindowActions: View {

    /// The bar's prefix for this screen — `browser.machine.window`, `localhost`.
    /// The suffix is added here so the name is spelled in one place.
    let id: String

    /// Push the window's settings. Nil where this page has a list instead, or
    /// nothing at all.
    var open: (() -> Void)?

    /// The short list, for the one page whose everything-else is not a screen.
    var menu: BrowserPageMenu?

    var body: some View {
        if let menu {
            Menu {
                items(menu)
            } label: {
                glyph
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("\(id).settings")
        } else if let open {
            // No `.buttonStyle` on either shape, deliberately. iOS 26 wraps a
            // navigation-bar item in its own glass capsule, and a `.plain` on one
            // of the two would draw the phone page's `…` and a machine window's
            // `…` differently — which is the exact drift *"top, header and
            // footer… should be same in all type of browsing windows"* is about.
            Button(action: open) {
                glyph
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("\(id).settings")
        }
    }

    /// The same three dots the bar used to draw, at the weight the system bar's
    /// own items are drawn at. Tinted explicitly rather than inherited: this app
    /// states its accent everywhere else and a header item that took the system
    /// default would be the one blue thing on the screen.
    private var glyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func items(_ menu: BrowserPageMenu) -> some View {
        // A plain label rather than a `Section` header: iOS draws a bare `Text`
        // in a menu un-tappable and greyed, which is exactly what a line of fact
        // among a list of verbs should look like.
        if let note = menu.note {
            Text(note)
        }
        ForEach(menu.items) { item in
            Button(role: item.destructive ? ButtonRole.destructive : nil, action: item.act) {
                Label(item.title, systemImage: item.icon)
            }
            .accessibilityIdentifier(item.id)
        }
    }
}

/**
 * What the header's `…` opens on a page whose *everything else* is a short list
 * rather than a screen.
 *
 * One page is left in that shape and it is not one of the four kinds of browsing
 * window: a prototype `ArtifactView` opens straight from a file, pushed at a
 * tunnel with no row in the Browser tab's list and therefore no `BrowserTab` id
 * to carry into `MachineWindowSettingsView`. What it has is one verb — the Done
 * that used to sit in the toolbar and tears the tunnel down — and one fact worth
 * keeping, the number of connections the tunnel is holding open, which is the
 * honest signal that a hot-reload socket is still talking with nothing on screen
 * changing.
 *
 * Every page that *does* have a row — every page on the Browser tab — pushes the
 * settings screen instead, because it exists now and *"all of them should have
 * all the options."*
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
