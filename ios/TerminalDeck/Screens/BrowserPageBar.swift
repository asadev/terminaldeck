/**
 * The bar a browser has, under the page it belongs to — written once because two
 * screens show a live page and both of them owe it the same controls.
 *
 * > *"I cannot click inside, I cannot touch the URL and things. I mean I need it
 * > should be feeling like a neat native browser… It should be like a proper
 * > native browser which I'm just controlling from here."*
 *
 * ## Why this stopped being `MachineWindowView`'s private property
 *
 * There are two screens that show a cast page and they had two different amounts
 * of browser on them. `MachineWindowView` — a window with an id — had an address,
 * Back, Forward and Reload. `WatchViewerScreen` — a page **no window claims** —
 * had a keyboard glyph and nothing else, on the argument that *"every one of
 * those is a `browser.control` verb addressed by window id, and there is no
 * window id to address."*
 *
 * That argument was true of Back and Forward and **false of the address**, and
 * the screen it was wrong about is the one he was looking at. On a server, a page
 * opened from the `+` with an address in it goes through `web.open`, which the
 * headless host backs with `browserDrive.open({ isolate: false })` — it lands in
 * the drive's own front slot, and that slot is a `browser.surfaces` row with an
 * **empty** window name that `openTab` mints no shell id for. So every page he
 * opened arrived on the screen with no address bar on it. A picture, full
 * bleed, that you cannot type an address into is a video of a browser.
 *
 * `web.open` is the address bar for that page: it navigates the same front slot
 * rather than opening a second one. Reload is the same call with the address the
 * surface already reports. **Back and Forward genuinely cannot be sent** — the
 * desktop's history is not on this wire and nothing addresses that slot by id.
 *
 * ## A verb that cannot be sent is drawn dead, not left out
 *
 * They used to be `nil` and nothing was drawn for them, on the rule about never
 * drawing a control that cannot act. He put two windows side by side and read the
 * result as two products:
 *
 * > *"In iMatch, one of them has different menu options here in the bottom, the
 * > tab menu, and this one has different only reload, nothing else. So why they
 * > are two different type… it should be the same case, or all the options should
 * > be available at least."*
 *
 * So the rule is narrower than it was: a control that could only ever be refused
 * is still not *offered*, and it is **drawn** — greyed, in its own place in the
 * row, so the bar under one page is the same bar as under any other. `unavailable`
 * is the sentence that says why, and it is on the ⓘ that takes the globe's place
 * in the address row, so the reason is one tap from the dead glyph rather than
 * something only VoiceOver can reach. Pass it nil and every `nil` verb is left out
 * exactly as it was.
 *
 * The address obeys the same rule and it is the half he named twice: *"This one
 * is the one that should be everywhere."* A page that cannot be navigated draws
 * its address **read-only** rather than drawing no address at all — the field is
 * the one thing on this bar that says where you are, and a browser that hides it
 * on some pages is the video again.
 *
 * ## Two rows, and the second one is what makes typing real
 *
 * The top row is the address, or — while the page is being typed into — a line
 * saying so and a way out of it. The system keyboard is raised on the **canvas**
 * rather than on a field here, so each keystroke reaches the page as it is
 * struck instead of being held in a text field until somebody presses Send. See
 * `WatchSurfaceUIView`.
 *
 * The bottom row is the page verbs. It is the same row on both screens with the
 * ones that cannot act left out, rather than two rows that drift.
 *
 * On the one screen that has moved its address into the navigation bar there is
 * only the second row, and the card is the verbs alone — see *Where the address
 * is drawn* below. The typing line is not the address and stays here in every
 * case.
 *
 * ## Three screens now, and the row grew to the union of what they carried
 *
 * > *"So top, header and footer, tab bar should be same in all type of browsing
 * > windows, including on this phone, including isolated, including the server."*
 *
 * `LocalhostBrowser` — a page this phone is holding open over a tunnel — used to
 * have a bar of its own: the system `UIToolbar`, with Back, Forward, a Reload
 * that doubled as Stop, Find, Inspect and Done, and **no address anywhere**. It
 * mounts this bar now, so there are three screens on it and one row under all of
 * them:
 *
 *     Back · Forward · Reload · Find · Inspect · Size
 *
 * ## Where the address is drawn is the screen's choice now
 *
 * > *"this link should be on the top header instead of bottom just like the
 * > normal browsers. I think on top you should have back button and link only,
 * > and then in the bottom you should have the rest of the options and three dot
 * > in the right side which will open the rest of the options, not upside here.
 * > Three dot should be here where we have right now size, so it can bring the
 * > options from up to down down to up."*
 *
 * So the address is not always in this card. `addressIn` is where the screen
 * draws it: `.bar`, the top row of this card, which is what three of the four
 * screens still do; or `.header`, the system navigation bar beside the chevron,
 * which is what `LocalhostBrowser` does now. The field is one view either way —
 * `BrowserAddressField` — so a screen that puts it up there is showing the same
 * control, under the same name, with the same seeding rule and the same keyboard,
 * wearing a shape that fits where it is standing.
 *
 * It is deliberately **not** applied to all four at once. He was holding the
 * phone's own page when he said it, and he said of the terminal screen in the
 * same breath: *"same way here it is fine because it is terminal, it should be
 * the way I said."* Changing every screen on one screen's sentence is how a round
 * of this gets undone by the next one.
 *
 * ## The `…` came back down, and that is not the last round undone
 *
 * > *"Maybe we can give some better one header also, not only the bottom, so we
 * > can have most of the important controls for the flow, for this kind of
 * > things and whatever we require to get the job done."*
 *
 * There was a slot here holding the `…`, and it was taken out and made a trailing
 * item in the system navigation bar, because a header carrying nothing at all is
 * the opposite of *not only the bottom*. That reading was right for a header with
 * a chevron and a title on it. It stops being right the moment the header carries
 * the **address**: the top is then a control rather than a label, which is what
 * that sentence asked for — and *"on top you should have back button and link
 * only"* says plainly what else may be up there. Nothing.
 *
 * So on a screen that has taken `.header` for its address, the `…` comes back
 * down here as the last slot in the row (`more`), drawn by the same
 * `BrowserWindowActions` that draws it in a header and under the same name.
 * *"Three dot should be here where we have right now size"*: the right-hand end
 * of this row, which is the place Size holds while it is the last thing in it.
 *
 * **Size is not deleted to make room.** It is a page verb — how wide the page is
 * laid out is a thing done to the page, in front of your eyes, over and over
 * while you compare — and *"in the bottom you should have the rest of the
 * options"* keeps every one of them down here. What he named was a **position**,
 * the right side; the `…` takes it and Size sits one slot to its left. A row that
 * answered the sentence by dropping a control would be answering a different one.
 *
 * *"so it can bring the options from up to down down to up"* is the menu's own
 * direction, and it needs no argument: iOS opens a menu into the space it has,
 * and a control sitting on the bottom edge of a phone has that space above it.
 *
 * The screens whose `…` is still in a header pass no `more`, and this row is
 * unchanged under them. There is still exactly one `…` per window and one view
 * that draws it; what changed is that the view knows two places to stand.
 *
 * Seven shares of a phone's width is about fifty points each on the narrowest
 * phone this app runs on. `BrowserVerbLabel` carries the two lines that keep the
 * longest word in the row — *Forward* — on one line inside that.
 *
 * The menu it opens is names and nothing else — *This phone*, *Laptop 1280* —
 * because *"you are also putting so much of a description under the title of that
 * thing under the title of the feature instead of just i button or nothing."* The
 * width in the name **is** the explanation; there is no second line under any of
 * them.
 *
 * Done went with the same reasoning a round earlier: it tore the tunnel down,
 * which is a thing you do to the window rather than to the page, so it is
 * `Close this window` on the page's own settings screen behind that `…`.
 *
 * ## Two kinds of *cannot*, kept apart on purpose
 *
 *  - **Nowhere to go.** `canGoBack` / `canGoForward` are the page's real history
 *    state where the page can be asked for one — a `WKWebView` this phone owns
 *    answers honestly, through KVO, including for the `pushState` navigations a
 *    dev server makes constantly. The button is disabled and owes no
 *    explanation: *the first page of a site has nothing behind it* is a fact
 *    anybody reads off a grey chevron.
 *  - **Cannot be asked at all.** `MachineWindow` carries no history state — the
 *    desktop's back-forward list is not on this wire — so on a machine window
 *    these are left `nil`, which means *do not grey this*. Guessing in the
 *    common direction (a window with history, drawn dead) is the exact defect
 *    the tunnel browser's own Back had for months. What genuinely cannot be put
 *    on the wire is a `nil` **action** with a sentence, and that is drawn greyed
 *    in its own place with the reason on the ⓘ.
 *
 * The two must not be unified. A grey button that means *not yet* and a grey
 * button that means *never here* look identical, and only one of them is worth a
 * sentence.
 *
 * ## The keyboard verb is gone, and this bar follows the canvas instead
 *
 * > *"This keyboard should not be working like this. If we just click inside and
 * > type from our keyboard, it should work… I should not have to have this
 * > separate button of keyboard. It should just come up from down, and the
 * > original native button should be there to move it down if I want, not a
 * > separate keyboard here inside the browser window."*
 *
 * There was a `Keyboard` verb in the bottom row, beside Back and Reload, drawn
 * wherever there was a live picture to deliver a keystroke to, and the argument
 * for it was that the phone is never told what has focus on the page — so
 * somebody had to say *now*. It is deleted. `WatchSurfaceUIView.onTap` takes
 * first responder now, so the keyboard comes up with the tap that focused the
 * field, and the keyboard's own accessory carries the button that puts it down.
 *
 * What is left here is **following**, not deciding: the canvas announces the
 * responder on `WatchSurface.typingNote` and this bar swaps its top row on it.
 * That is why `startTyping` is gone and `stopTyping` is not — where the
 * keystrokes are going is worth a line, and a second way out of them costs
 * nothing.
 */

// Combine for `NotificationCenter.publisher(for:)`: the canvas announces the
// keyboard on a notification and this bar is the one thing that follows it.
import Combine
import SwiftUI

struct BrowserPageBar: View {
    /// The prefix every control on this bar is named with, so a failure names
    /// the screen as well as the button.
    let id: String

    /// What is in the address field. Seeded by the screen from the page's own
    /// URL — never bound to it; see `MachineWindowView.seed`.
    @Binding var address: String
    /// Whether somebody is in the field. The screen reads this to know not to
    /// re-seed under a thumb.
    @Binding var editing: Bool
    /// Whether the canvas is holding the system keyboard, which is also which
    /// top row this bar draws. Written from the canvas's own announcement rather
    /// than from a button here, and a binding because the screens above read it
    /// on their way out to end typing with the screen.
    @Binding var typing: Bool

    let placeholder: String
    /// Where a typed address goes, given the trimmed text — or nil for a page
    /// that cannot be navigated at all, in which case the address is drawn
    /// read-only. That last case is real: a machine that casts a window without
    /// advertising `web` or `browser.control` can be watched, typed into, and not
    /// sent anywhere.
    let go: ((String) -> Void)?

    /**
     * **Where this screen draws the address** — in this card, or up in the
     * system navigation bar.
     *
     * > *"this link should be on the top header instead of bottom just like the
     * > normal browsers."*
     *
     * A default of `.bar`, so the three screens that were not the subject of that
     * sentence keep the bar they had without being touched. A screen that says
     * `.header` is promising to mount `BrowserAddressField` itself, with the same
     * `id`, the same bindings and `place: .header` — see `LocalhostBrowser`.
     * This bar then draws no address row at all and the card under the page is
     * the verbs alone.
     *
     * The **typing** row is not covered by this and stays here in every case. It
     * is not the address: it is the line that says the canvas has taken the
     * keyboard, and the way out of it. A screen with a canvas and its address in
     * the header would show the address up there and the notice down here, which
     * is the honest arrangement rather than an oversight — the two say different
     * things.
     */
    var addressIn: BrowserAddressPlace = .bar

    /// The verbs, or nil for a page that cannot be asked for one. A nil is drawn
    /// dead where `unavailable` says why, and left out where it does not.
    let back: (() -> Void)?
    let forward: (() -> Void)?
    let reload: (() -> Void)?

    /// The surface to type into, or nil when this screen has no live picture —
    /// a window the machine will not cast still has an address and still has its
    /// page verbs, and has nothing to send a keystroke to.
    let page: String?


    /**
     * Whether there is anywhere to go back to — or **nil where this page does not
     * say**, which is not the same as *no*.
     *
     * A `WKWebView` this phone owns answers this honestly and live, so the page
     * on the phone greys its own chevron at the start of a site. `MachineWindow`
     * carries nothing of the kind: the desktop's back-forward list never comes
     * over this wire, so a machine window passes nil and the button stays lit.
     * Greying it there would be a guess, and the guess that is wrong in the
     * common direction — a window deep in a site, drawn dead — is precisely the
     * bug the tunnel browser's Back had for months.
     */
    var canGoBack: Bool? = nil
    var canGoForward: Bool? = nil

    /// Whether the page is fetching something right now. Draws the load line the
    /// screens put under their header, and turns Reload into Stop where the page
    /// can actually be stopped.
    var loading: Bool = false

    /**
     * Stop the load in flight, or nil for a page nothing can call off.
     *
     * `WKWebView.stopLoading` is a local call and always works, so the phone's
     * page passes one. A window on the machine reports `loading` and there is
     * **no stop in `MachineWindow.Act`** — back, forward, reload, close, record,
     * share, isolate and nothing else — so passing nil there is the honest
     * answer, and the slot keeps drawing a live Reload rather than a dead Stop.
     * A Reload that works is worth more than a Stop that does not, and reloading
     * a page that is still loading is a real thing to do: it starts it again.
     */
    var stop: (() -> Void)? = nil

    /// Search the words on this page, or nil where the page is not on this
    /// phone — in which case the slot is simply not drawn. See `slot`.
    var find: (() -> Void)? = nil
    /// Whether the find bar is up, which fills the glyph the way Inspect's is
    /// filled — the page gets shorter and something visible has to explain it.
    var finding: Bool = false

    /**
     * Describe whatever is tapped on the page, or nil where this phone cannot
     * reach into it.
     *
     * **This is built on both sides and it works.** The page this phone holds
     * open answers a tap in its own JavaScript (`InspectScript`), and a window on
     * the machine answers it over the wire — `browser.window.pick`, sent by
     * `MachineWindowView.toggleInspecting`, answered by the machine's own
     * browser. Both land in one `InspectSheet`.
     *
     * What is left `nil` is the one screen that has no way to ask at all: the
     * surface viewer reached from Settings, which holds a `WatchLink` and no
     * model — and a nil slot is not drawn at all now rather than greyed. See
     * `slot`.
     */
    var inspect: (() -> Void)? = nil
    var inspecting: Bool = false

    /**
     * Look at the page at another width, and zoom into it — or nil where this
     * screen has no document of its own to re-lay-out.
     *
     * > *"they can pinch and zoom also they can see all the different dimensions
     * > in responsive views how it will look like in mobile how it will look
     * > like on Windows."*
     *
     * Nil on every screen that draws a **picture** of a page rather than the page
     * — see `BrowserChrome.sizeIsLocal` for why magnifying a screenshot is the
     * one thing this control must never quietly become. Those screens draw the
     * glyph dead in its slot with that sentence on the ⓘ, which is the rule the
     * whole row follows: *"it should be the same case, or all the options should
     * be available at least."*
     */
    var size: BrowserPageSize? = nil

    /**
     * What the `…` at the right-hand end of the row opens, or nil for a screen
     * whose `…` is a trailing item in its header instead.
     *
     * > *"in the bottom you should have the rest of the options and three dot in
     * > the right side which will open the rest of the options, not upside here.
     * > Three dot should be here where we have right now size."*
     *
     * Data rather than a view, and the bar builds `BrowserWindowActions` from it
     * with this bar's own `id`. Handing the view over would let a screen spell
     * the identifier a second time, and `\(id).settings` is a name six suites
     * reach for — one place to spell it is the whole reason that view builds it
     * from a prefix.
     *
     * Nil is the ordinary case and the three screens that pass nothing are
     * unchanged: their `…` is where it has been since the round that put it in
     * the header, and this row is six verbs long under them.
     */
    var more: BrowserPageMore? = nil

    /**
     * **One box, with rounded corners, and nothing drawn dead in it.**
     *
     * > *"this bar looks like very classic style and old and not according to
     * > the overall design system. So maybe we can give it a nice box instead of
     * > this type, like this type of so much of separation and difference —
     * > maybe a smooth cool beautiful box maybe round corners or something which
     * > looks like latest shapes."*
     *
     * > *"maybe we can have all of it in one pill instead of two different upper
     * > and bottom."*
     *
     * It was two full-width bands separated by hairlines that ran edge to edge —
     * the shape a browser toolbar had in 2012, and the one thing on these
     * screens that did not look like the rest of the app. It is one card now,
     * inset from the edges, `Theme.surface` on the screen's own ground, with the
     * address and the verbs inside it and a short rule between them that stops
     * before the corners. The rest of this app is *"tinted ground, floating
     * cards, 20pt radii"* and this is now the same thing.
     */
    var body: some View {
        VStack(spacing: 0) {
            if typing {
                keyRow
                if hasVerbs { insetDivider }
            } else if addressIn == .bar, go != nil || address != "" {
                /*
                 * **Only where this bar is the one drawing it.** A screen that
                 * has taken `.header` for its address is showing the same field
                 * beside its chevron — *"on top you should have back button and
                 * link only"* — and a second copy of it down here would be two
                 * address bars over one page, which is worse than the bar he
                 * asked to have emptied.
                 */
                addressRow
                if hasVerbs { insetDivider }
            }

            if hasVerbs { verbRow }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        /*
         * **The canvas has taken the keyboard, or given it up.**
         *
         * The one thing on this bar that is no longer this bar's to decide. A
         * tap on the page raises the keyboard, so the only honest source for
         * *is somebody typing* is the responder itself; the canvas announces
         * every edge of it and this row follows. Filtered on `page`, because two
         * screens can be alive at once and only one of them is showing this
         * surface.
         */
        .onReceive(NotificationCenter.default.publisher(for: WatchSurface.typingNote)) { note in
            guard let page, note.object as? String == page,
                  let now = note.userInfo?[WatchSurface.typingKey] as? Bool else { return }
            typing = now
        }
    }

    /// The one rule left, and it stops short of the card's corners — a hairline
    /// run edge to edge is the "so much of separation" the box replaced.
    private var insetDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    // MARK: - The address

    /**
     * The address, drawn inside this card — the shape three of the four screens
     * still wear.
     *
     * The field itself is `BrowserAddressField`, which is the same view a screen
     * mounts in its navigation bar when it has taken `.header`. One view for both
     * places, because *"this link should be on the top header instead of bottom"*
     * moved a control rather than replacing it: the same name, the same seeding
     * rule, the same URL keyboard, the same read-only shape on a page nothing can
     * be sent to.
     *
     * It used to be four properties here — the row, the editable field, the
     * read-only line and the leading glyph. They are that view's now, unchanged,
     * so that a bar and a header cannot grow two address fields that drift.
     */
    private var addressRow: some View {
        BrowserAddressField(id: id, address: $address, editing: $editing,
                            placeholder: placeholder, go: go, place: .bar)
    }

    /**
     * What the bar says while the page is being typed into, and the way out.
     *
     * ## There was a row of keys here — Escape, Tab, the four arrows — and it
     * was taken out because it was measured not working
     *
     * They were drawn on the argument that a page needs keys a phone keyboard
     * has none of, which is true. What was not checked until it was run against
     * his live server is whether the far side does anything with them. It does
     * not, and the reason is exact:
     * `src/main/browser-watch.ts`'s `dispatchKey` passes `key`, `code`, `text`
     * and `modifiers` to `Input.dispatchKeyEvent` and **never a
     * `windowsVirtualKeyCode`**. Chromium delivers such an event to the page's
     * JavaScript — a `keydown` listener sees it and `key` is right — but the
     * *browser's own* handling of a key, which is what Backspace, Tab and the
     * arrows are, keys off the virtual key code and gets zero.
     *
     * Measured on a real page (DuckDuckGo, on his WSL server, over the relay):
     *
     *  - typing characters — **works**, every keystroke, the site's autocomplete
     *    opens as it is typed;
     *  - Return — **works**; the search submitted;
     *  - Backspace — **nothing**, the field kept its text;
     *  - ArrowDown — **nothing**, the document did not scroll.
     *
     * Return works and Backspace does not because DuckDuckGo submits from its own
     * `keydown` handler while Backspace's effect is an editing command inside the
     * browser. So a row of six keys would have been six controls that look like
     * keys and are not, on the exact screen whose complaint was that it *"feels
     * like just like a video"*. They come back the day the host derives a virtual
     * key code from `key`/`code` — no wire change is needed for that, only a
     * lookup in `dispatchKey`.
     *
     * Done resigns the canvas, which is the way back to the address row. It is
     * no longer the only way out — the keyboard now carries its own dismiss, on
     * every screen that mounts a canvas rather than only the two that have this
     * bar under one — but the dead end it was written against is unchanged: a
     * keyboard over a live page with nothing that puts it away is a picture with
     * no controls.
     *
     * The row is entered by the **canvas** rather than by a button here. See the
     * file header for the verb that used to open it and for why a tap on the
     * page opens it now.
     */
    private var keyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 28)
            Text("Typing into the page")
                .font(.system(size: 15))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("\(id).keys.label")
            Spacer(minLength: 4)
            Button {
                stopTyping()
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop typing into the page")
            .accessibilityIdentifier("\(id).keys.done")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    // MARK: - The verbs

    /**
     * Whether the bottom row has anything left on it.
     *
     * It can be empty, which it could not be before the keyboard verb went: that
     * was the one verb every screen with a live picture drew, and a page that can
     * be watched and not navigated — this bar on a screen reached from Settings
     * with no model behind it — has nothing else and nothing to say about why.
     * Twenty points of empty bar is chrome pretending to be a control, so the row
     * goes rather than standing there. A page that *does* have a reason draws the
     * dead glyphs and the sentence on the ⓘ beside them, because *"it should be
     * the same case, or all the options should be available at least."*
     *
     * The `VStack` around it stays either way, because it is what carries the
     * subscription that puts the typing row up.
     */
    private var hasVerbs: Bool {
        back != nil || forward != nil || reload != nil || find != nil || inspect != nil
            || size != nil || more != nil
    }

    /**
     * The six page verbs, in his order, in the same places under every page — and
     * the `…` after them on the one screen that keeps its `…` down here.
     *
     * Every identifier this row hands out is written here rather than inside the
     * helpers, so that the order of the row can be read straight off this
     * function — which is what `LocalhostChromeTests` walks. A row whose order is
     * assembled somewhere else is a row nobody can pin.
     *
     * What the six have in common is that every one of them does something to the
     * **page** a thumb is reading — including Size, which is pressed over and over
     * while comparing one width against another and would be a poor thing to keep
     * two taps away.
     *
     * `moreSlot` is the seventh and it is not one of them: it is the door to the
     * **window** — closing it, binding it to a session, photographing it — and it
     * is drawn only where the screen handed one over.
     *
     * > *"in the bottom you should have the rest of the options and three dot in
     * > the right side which will open the rest of the options, not upside here.
     * > Three dot should be here where we have right now size."*
     *
     * The right-hand end of the row is the place he named, and it is where Size
     * was standing while Size was last in the row. Both are here: the position
     * changed hands, the control did not go anywhere. See the file header for why
     * that is not the round before this one being undone.
     */
    private var verbRow: some View {
        HStack(spacing: 0) {
            slot("Back", "chevron.left", id: "\(id).back", act: back, enabled: canGoBack ?? true)
            slot("Forward", "chevron.right", id: "\(id).forward",
                 act: forward, enabled: canGoForward ?? true)
            reloadSlot(id: "\(id).reload")
            slot("Find", finding ? "magnifyingglass.circle.fill" : "magnifyingglass",
                 id: "\(id).find", act: find)
            slot("Inspect", inspecting ? "square.dashed.inset.filled" : "square.dashed",
                 id: "\(id).inspect", act: inspect)
            sizeSlot(id: "\(id).size")
            moreSlot()
        }
        .padding(.vertical, 10)
    }

    /**
     * The `…`, last in the row, on a screen whose header is carrying the address
     * instead of this control.
     *
     * `BrowserWindowActions` with `place: .row` — the **same view** that draws it
     * in a header, told where it is standing. Not a second `…` written here: the
     * rule that there is one of them per window, spelled once, named once, is
     * older than this round and is the reason `BrowserChrome` owns that view at
     * all. What it wears here is `BrowserVerbLabel`, the same glyph-over-word the
     * six verbs beside it wear, so the row is seven identical shapes rather than
     * six and a visitor.
     *
     * The identifier is built inside that view from this bar's own `id`, so a
     * page whose `…` moved from the header to the row is still `localhost.settings`
     * and nothing that reaches for it had to move.
     *
     * Nothing forces the menu upwards and nothing needs to: *"so it can bring the
     * options from up to down down to up"* is what iOS does by itself for a
     * control sitting on the bottom edge of the screen — the space is above it, so
     * that is where the menu goes.
     */
    @ViewBuilder
    private func moreSlot() -> some View {
        if let more {
            BrowserWindowActions(id: id, place: .row, open: more.open, menu: more.menu)
        }
    }

    /**
     * Size: a menu where the other five are buttons, and dead in its slot where
     * this screen has only a picture.
     *
     * A `Menu` rather than a `Button` because there is nothing to toggle — the
     * answer is *which* device — and a sheet for a list of one-line names would
     * be a screen of white space. It wears `verbLabel` like every other slot, so
     * the row is six identical shapes rather than five and a special one.
     *
     * No `.buttonStyle` and no menu-order arguments: the devices lead because
     * they are the question he asked, Rotate follows them behind a divider
     * because it is a second question about the device already chosen, and the
     * three zoom verbs come last because they are about looking closer at
     * whatever is already there.
     */
    @ViewBuilder
    private func sizeSlot(id: String) -> some View {
        if let size {
            Menu {
                sizeItems(size)
            } label: {
                verbLabel("Size", "macbook.and.iphone", tint: Theme.accent)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Size")
            .accessibilityIdentifier(id)
        }
    }

    /**
     * What is in that menu: names, and the pixels quietly beside them.
     *
     * A `Toggle` per device rather than a `Picker`, for one reason that is about
     * him rather than about SwiftUI: iOS draws a toggle in a menu as a row with a
     * checkmark, which is the same shape as the devices themselves, and a
     * `Picker`'s inline section arrives with a header — one more line of prose in
     * a menu he has now twice asked to be made shorter.
     *
     * The current device's row is still live and does nothing when pressed. That
     * is deliberate: this is a one-of-many choice and un-choosing is not one of
     * them, so the press closes the menu and changes nothing, which is what
     * pressing the ticked row does everywhere else on the phone.
     *
     * ## Picking a device always lands on its own way up
     *
     * `PageSize(device)` and never `PageSize(device, turned: size.size.turned)`.
     * Carrying the rotation across a change of device would mean tapping
     * *Laptop* while a phone was on its side produced a laptop stood on end —
     * a shape nobody asked for, arrived at by a control they were not touching.
     * Rotate is one tap away and it is the tap that says so.
     */
    @ViewBuilder
    private func sizeItems(_ size: BrowserPageSize) -> some View {
        ForEach(PageDevice.allCases) { device in
            Toggle(isOn: Binding(get: { size.size.device == device },
                                 set: { if $0 { size.choose(PageSize(device)) } })) {
                sizeRow(device)
            }
            .accessibilityIdentifier("\(id).size.\(device.key)")
        }
        /*
         * **Rotate is drawn only where there is something to rotate.**
         *
         * At *This phone* there is no frame — the page is the whole screen — so
         * the row is absent rather than greyed. A greyed row inside a menu is the
         * one place a dead control cannot carry its own sentence, and *"it should
         * be the same case, or all the options should be available at least"* is
         * about controls a person can see and not reach. One they never see owes
         * nothing.
         *
         * A `Button` and not a `Toggle`, which is the honest shape: *Tablet
         * landscape* is a listed device whose own way up **is** landscape, so a
         * tick meaning "on its side" would be off while the frame plainly was on
         * its side. A verb has no such claim to get wrong — it turns whatever is
         * there, every time.
         */
        if size.size.device != .fit {
            Divider()
            Button { size.choose(size.size.turnedOver()) } label: {
                // The editing-set rotate rather than `arrow.clockwise`, which
                // this same bar already spends on Reload — two identical glyphs
                // in one menu is a menu somebody has to read twice. Checked
                // against this Mac's own `name_availability.plist` rather than
                // from memory: `rotate.right` is a 2019 symbol, so iOS 13, so it
                // is there on every phone this app will ever run on.
                Label("Rotate", systemImage: "rotate.right")
            }
            .accessibilityIdentifier("\(id).size.rotate")
        }
        /*
         * **Zoom in and Zoom out are not here, and that is the second time this
         * menu has been cut.**
         *
         * They were: three rows, on the argument that getting close to a laptop
         * frame drawn at 29% should not depend on landing a two-finger gesture.
         * With eight devices and Rotate above them the menu became twelve rows,
         * the last of them below the fold — measured against a live host, where
         * `Actual size` could not be found at all because it was never rendered.
         *
         * > *"you should compact all the features or buttons and without losing
         * > any of them"*
         *
         * Nothing is lost: **pinch works**, on every frame, and that is the whole
         * point of the control it belongs to. What pinch cannot do is land on
         * exactly 100%, so the one row that survives is the one that is not a
         * gesture — the reset.
         */
        Divider()
        Button { size.actualSize() } label: {
            Label("Actual size", systemImage: "1.magnifyingglass")
        }
        .accessibilityIdentifier("\(id).size.actual")
    }

    /**
     * One row of the Size menu: the device, then its pixels, quieter.
     *
     * > *"you are also putting so much of a description under the title of that
     * > thing under the title of the feature instead of just i button or nothing
     * > maybe so they have becomes too big"*
     *
     * So the row is a **title** — *Laptop* — and the measurement is the second
     * element of the same line rather than a sentence beneath it. Two `Text`s
     * concatenated rather than an `HStack`, because a menu row is not a layout
     * this app gets to arrange: iOS renders the label of a menu item itself, and
     * a stack in there is at the system's mercy in a way a run of text is not.
     *
     * If a future iOS flattens the styling out of a concatenated `Text` in a
     * menu, what is lost is the greying and the row still reads
     * *Laptop   1280 × 800*. That is the whole reason it is written this way and
     * not with a colour applied to the row: the fallback is the same words.
     */
    private func sizeRow(_ device: PageDevice) -> Text {
        guard let measure = device.measure else { return Text(device.name) }
        return Text(device.name) + Text("   \(measure)").foregroundStyle(Theme.faint)
    }

    /**
     * Reload, and Stop while the page is fetching — one control, one identifier.
     *
     * The identifier does not change with the state, deliberately: it is the same
     * button doing the same job at two moments of it, and a test that had to know
     * which half of a load it caught would be a test nobody could write. The
     * spoken label does change, because *Reload* on a button that stops a load is
     * the kind of wrong VoiceOver cannot recover from.
     *
     * Where there is no `stop` the glyph stays Reload however loud `loading` is —
     * see the property for why a machine window has no stop to give.
     */
    @ViewBuilder
    private func reloadSlot(id: String) -> some View {
        if loading, let stop {
            verb("Stop", "xmark", id: id, act: stop, label: "Stop loading")
        } else {
            slot("Reload", "arrow.clockwise", id: id, act: reload)
        }
    }

    /**
     * A verb, or nothing at all.
     *
     * ## This used to draw a dead one, and he reversed it
     *
     * The rule was *a control that could only ever be refused is still drawn,
     * greyed, in its own place in the row, so the bar under one page is the same
     * bar as under any other* — his own words, from the round that put Find,
     * Inspect and Size in every row with a sentence on the ⓘ saying why two of
     * them were grey. It is reversed by his own words too:
     *
     * > *"if the browsers cannot have this options like find, inspect and size…
     * > it should be first of all possible and useful here also. But if not then
     * > I think here we can just make it more simplified, remove find, inspect
     * > and size."*
     *
     * Possible, or gone. Find reads a document *this phone* has loaded and there
     * is no verb on the wire that asks a machine to search one; Size needs a
     * layout width this wire cannot ask for; Inspect needs a sheet to answer
     * into. So on a machine's window those three are simply not there, and the
     * row under a page this phone holds is the full six — which is the honest
     * version of *the same bar everywhere*: the same bar, showing what it can
     * actually do here.
     */
    @ViewBuilder
    private func slot(_ title: String, _ icon: String,
                      id: String, act: (() -> Void)?,
                      enabled: Bool = true) -> some View {
        if let act {
            verb(title, icon, id: id, act: act, enabled: enabled)
        }
    }

    private func verb(_ title: String, _ icon: String,
                      id: String, act: @escaping () -> Void,
                      enabled: Bool = true,
                      label: String? = nil) -> some View {
        Button(action: act) {
            verbLabel(title, icon, tint: enabled ? Theme.accent : Theme.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label ?? title)
        .accessibilityIdentifier(id)
    }

    /// The glyph and its word, drawn identically wherever this row puts one.
    /// `BrowserVerbLabel` rather than a stack written here, because the `…` at
    /// the end of the row is drawn by `BrowserWindowActions` in another file and
    /// has to be the same shape to the point — a seventh slot half a point taller
    /// than its six neighbours is exactly the drift this whole bar exists to have
    /// removed.
    private func verbLabel(_ title: String, _ icon: String, tint: Color) -> some View {
        BrowserVerbLabel(title: title, icon: icon, tint: tint)
    }

    // MARK: - Actions

    /// Put the keyboard away. `typing` is set here as well as being announced
    /// back by the canvas, so the row changes on the press rather than on the
    /// answer to it.
    private func stopTyping() {
        typing = false
        guard let page else { return }
        WatchStage.post(.endTyping, to: page)
    }
}

/**
 * The address, in whichever of those two places it is standing.
 *
 * ## Why this is a view of its own now
 *
 * It was four properties inside `BrowserPageBar` — the row, the editable field,
 * the read-only line, the globe — and it could not stay there the moment one
 * screen wanted the same control in its navigation bar. The alternatives were
 * both worse than moving it: a second field written in `LocalhostBrowser` would
 * be two address bars in this app with two sets of keyboard rules and one of them
 * would quietly stop matching, and lifting the bar itself into the header would
 * carry the verbs up with it, which is the opposite of what he asked for.
 *
 * So it is one view with a `place`. Everything that makes it an address bar —
 * the URL keyboard, no autocapitalisation, no autocorrect, the Go key on the
 * keyboard, the `\(id).address` name, seeding rather than binding, and the
 * read-only shape for a page nothing can be sent to — is written once and is
 * identical in both places. What the place changes is the **shape**: a full row
 * with a globe and a Go button inside a card, or a capsule that fits between a
 * chevron and the edge of the screen.
 *
 * ## What the header shape drops, and it is not silent
 *
 *  - **The globe.** *"on top you should have back button and link only"*. It was
 *    decoration in the bar and it would be decoration eating a fifth of the width
 *    of a phone's navigation bar.
 *  - **The Go button.** The keyboard's own Go key is still there —
 *    `submitLabel(.go)` and `onSubmit` are on the field in both places — and that
 *    is the key every phone browser submits with, which is the benchmark he named:
 *    *"just like the normal browsers"*. A second Go rendered beside a field with
 *    about two hundred and eighty points to live in would take the address down to
 *    a stub.
 *
 * Both are recorded here rather than dropped quietly, because the bar shape keeps
 * both and somebody comparing the two screens will want to know which of the
 * differences were decided.
 */
struct BrowserAddressField: View {

    /// The screen's prefix, so the field is `localhost.address` wherever it is
    /// drawn — a control that changed places must not change name.
    let id: String

    /// What is in it. Seeded by the screen from the page's own URL, never bound
    /// to it; see `MachineWindowView.seed` for the dev-server route change that
    /// would otherwise retype it under a thumb mid-word.
    @Binding var address: String

    /// Whether somebody is in it. The screen reads this to know not to re-seed.
    @Binding var editing: Bool

    let placeholder: String

    /// Where a typed address goes, or nil for a page that cannot be navigated at
    /// all — in which case the same line is drawn read-only rather than not drawn.
    let go: ((String) -> Void)?

    var place: BrowserAddressPlace = .bar

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch place {
            case .bar: inTheCard
            case .header: inTheHeader
            }
        }
        // The focus mirror lives here rather than on the bar, which is what makes
        // the header shape work at all: the screen still learns that somebody is
        // in the field and still stops re-seeding it, without the bar having to
        // be the thing that owns the cursor.
        .onChange(of: focused) { _, now in editing = now }
    }

    // MARK: - Inside the card

    /**
     * The address, and the globe that leads it, on the bar under the page.
     *
     * One row with two shapes rather than two rows: *"This one is the one that
     * should be everywhere."* Where the page can be navigated it is a field with
     * a Go beside it; where it cannot, the same line is drawn read-only, because
     * an address bar that disappears on some pages is how one of these screens
     * turned into a video of a browser.
     */
    @ViewBuilder
    private var inTheCard: some View {
        if go != nil { editableAddress } else { readOnlyAddress }
    }

    private var editableAddress: some View {
        HStack(spacing: 12) {
            leadingGlyph
            field
            Button(action: submit) {
                Text("Go")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(typed.isEmpty ? Theme.faint : Theme.accent)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Genuinely disabled rather than hidden: an empty address is not a
            // thing to send, and a button that appears the moment somebody types
            // moves the field's width under their thumb.
            .disabled(typed.isEmpty)
            .accessibilityLabel("Go to this address")
            .accessibilityIdentifier("\(id).go")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /**
     * The same line, on a page nothing can be sent to.
     *
     * `Theme.secondary` rather than `Theme.primary`, and no Go: a line somebody
     * cannot type into should not be drawn at the weight of one they can. What is
     * in it is still the page's own address — the last thing the machine reported
     * about this page — so *where am I* is answered on every screen in this app
     * that shows a page.
     *
     * A separate identifier from the field, deliberately. A test asking for
     * `\(id).address` is asking whether this page can be typed into, and a label
     * wearing the field's name is exactly the pass that would mean nothing.
     */
    private var readOnlyAddress: some View {
        HStack(spacing: 12) {
            leadingGlyph
            readOnlyLine
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /**
     * The globe, and nothing else in this slot.
     *
     * > *"this icon is not required here, i information button, it can go so it
     * > will be more simple."*
     *
     * There was an ⓘ here on any page some verb could not act on, and it carried
     * the sentences saying why each greyed control was greyed. Those controls are
     * not drawn any more — see `BrowserPageBar.slot` — so there is nothing left
     * for it to explain, and a dot that opens onto an empty explanation is worse
     * than the greyed row it replaced.
     */
    private var leadingGlyph: some View {
        Image(systemName: "globe")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.faint)
            .frame(width: 24, height: 28)
    }

    // MARK: - Up in the header

    /**
     * The same address, between the chevron and the edge of the screen.
     *
     * > *"this link should be on the top header instead of bottom just like the
     * > normal browsers. I think on top you should have back button and link
     * > only."*
     *
     * A capsule of `Theme.surface` on the navigation bar's own ground, which is
     * `Theme.background` — the same floating-card-on-tinted-ground relationship
     * the bar below has, so the field reads as something you can put a cursor in
     * rather than as a title that happens to be in a monospace. The hairline round
     * it is what keeps that true in dark mode, where the two greys are eight
     * points apart.
     *
     * `maxWidth: .infinity` because a principal toolbar item is sized to its
     * content: without it the capsule would shrink to the length of whatever URL
     * the page last reported and jump about as the page navigated.
     *
     * A point smaller than the bar's field. The navigation bar is forty-four
     * points tall and the capsule has to sit inside it with air above and below;
     * the monospace at fifteen with seven points of padding is a point over.
     */
    private var inTheHeader: some View {
        HStack(spacing: 8) {
            if go != nil { field } else { readOnlyLine }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
    }

    // MARK: - The two pieces both shapes share

    /**
     * The field, written once.
     *
     * Each of these modifiers is load-bearing: a URL keyboard puts the slash and
     * the dot under a thumb, autocapitalisation would send "Localhost", autocorrect
     * "local host", and the `.URL` content type stops iOS offering a contact's
     * name. `submitLabel(.go)` is the key that sends it, and it is the only way to
     * send it from the header shape — see this type's own header for why there is
     * no second Go button up there.
     */
    private var field: some View {
        TextField(placeholder, text: $address)
            .textFieldStyle(.plain)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(submit)
            .focused($focused)
            .font(.system(size: place == .header ? 14 : 15, design: .monospaced))
            .foregroundStyle(Theme.primary)
            .accessibilityIdentifier("\(id).address")
    }

    /// The read-only line, written once, for the same reason the field is.
    /// `truncationMode(.middle)` because the two ends of a URL are the two halves
    /// worth reading and the query in the middle is the part nobody is looking at.
    private var readOnlyLine: some View {
        Text(address.isEmpty ? placeholder : address)
            .font(.system(size: place == .header ? 14 : 15, design: .monospaced))
            .foregroundStyle(address.isEmpty ? Theme.faint : Theme.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("\(id).address.readOnly")
    }

    // MARK: - Actions

    private var typed: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !typed.isEmpty, let go else { return }
        go(typed)
        focused = false
    }
}

/**
 * One slot of the page bar's verb row: a glyph with its word under it.
 *
 * A view of its own rather than a function inside `BrowserPageBar`, because the
 * `…` at the end of that row is drawn by `BrowserWindowActions` — a different
 * type in a different file — and the two have to be the same shape to the point.
 * Seven slots that were assembled in two places would drift by a point the first
 * time either was touched, and one control half a point taller than its
 * neighbours is the sort of thing he spots in a screenshot and nobody can find
 * in a diff.
 *
 * Seven shares of the narrowest phone this app runs on is about fifty points
 * each, and *Forward* is the longest word in the row. `lineLimit(1)` and
 * `minimumScaleFactor(0.8)` are what keep it on one line inside that instead of
 * wrapping and making one slot taller than the six beside it.
 */
struct BrowserVerbLabel: View {

    let title: String
    let icon: String

    /// The accent, or `Theme.faint` for a verb that is genuinely disabled —
    /// *nowhere to go back to* rather than *never here*. See
    /// `BrowserPageBar.canGoBack` for why those two are not the same grey.
    var tint: Color = Theme.accent

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
    }
}

/**
 * Everything the Size slot needs, handed over by the screen that owns the page.
 *
 * A small struct rather than four separate parameters on the bar, for the reason
 * every one of them is the same decision: a screen either owns a document — in
 * which case it can re-lay it out **and** magnify it — or it owns a picture, in
 * which case it can do neither. Four optionals would make four states possible
 * where there are two, and three of them would be screens where the menu opens
 * onto rows that do nothing.
 *
 * `size` is the choice as it stands, so the menu can tick it and Rotate can turn
 * it over. It is read rather than bound because the store behind it is per
 * **site** and outlives this screen — see `PageWidths` for why the memory is not
 * per URL.
 */
struct BrowserPageSize {

    /// The device the page is being laid out as right now, and which way up.
    var size: PageSize

    /// Lay it out as another one. The screen writes the choice down. Rotate goes
    /// through here too, as `choose(size.turnedOver())` — there is no second
    /// closure for it, because turning a frame over is choosing a size and a
    /// separate seam would be a second place for the store to be written.
    var choose: (PageSize) -> Void

    /**
     * Magnify what is on screen, without touching the layout.
     *
     * These are the pinch, as buttons. The gesture is the thing he asked for and
     * it is the web view's own — see `LocalhostBrowser`'s configuration — but a
     * page laid out at 1440 CSS px and scaled onto a phone needs a way *back* to
     * a readable scale that does not depend on landing a two-finger gesture
     * precisely, and a way to step in that does not overshoot.
     *
     * Deliberately separate from `choose`: magnification and layout size are two
     * different questions about the same page, and a control that mixed them
     * would answer *"how does this look on a laptop"* by making a phone layout
     * bigger, which is the fake this whole feature exists to avoid.
     */
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var actualSize: () -> Void
}
