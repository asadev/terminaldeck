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

    /// The verbs, or nil for a page that cannot be asked for one. A nil is drawn
    /// dead where `unavailable` says why, and left out where it does not.
    let back: (() -> Void)?
    let forward: (() -> Void)?
    let reload: (() -> Void)?

    /// The surface to type into, or nil when this screen has no live picture —
    /// a window the machine will not cast still has an address and still has its
    /// page verbs, and has nothing to send a keystroke to.
    let page: String?

    /// The `…`, for a screen that has somewhere to put one.
    let more: (() -> Void)?

    /**
     * Why this page cannot be asked for the verbs it is not being given — or nil
     * on a page that can be asked for everything.
     *
     * Present, it turns every `nil` verb above into a **dead** button in its own
     * slot and the address field into a read-only line, with this sentence on the
     * ⓘ beside it. Absent, a `nil` verb is left out and a page with no `go` draws
     * no address at all, which is what a screen with no model behind it wants.
     *
     * A sentence rather than a flag, because the answer is different every time —
     * a page with no window id, a machine that has stopped offering its browser,
     * a cast with no `web` behind it — and *this control is off* without the
     * reason is the dead control it is trying not to be.
     */
    var unavailable: String?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)

            if typing {
                keyRow
                topDivider
            } else if go != nil || unavailable != nil {
                addressRow
                topDivider
            }

            if hasVerbs { verbRow }
        }
        .background(Theme.background)
        .onChange(of: focused) { _, now in editing = now }
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

    private var topDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    // MARK: - The address

    /**
     * The address, and the ⓘ that stands where the globe does on a page this
     * phone can move.
     *
     * One row with two shapes rather than two rows: *"This one is the one that
     * should be everywhere."* Where the page can be navigated it is a field with
     * a Go beside it; where it cannot, the same line is drawn read-only, because
     * an address bar that disappears on some pages is how one of these screens
     * turned into a video of a browser.
     *
     * The leading glyph carries the difference. A page that can be asked for
     * everything gets the globe, which is decoration; a page that cannot gets the
     * ⓘ in the same 24-point slot, and tapping it is the only place the *why*
     * behind the greyed verbs below is written down.
     */
    @ViewBuilder
    private var addressRow: some View {
        if go != nil { editableAddress } else { readOnlyAddress }
    }

    private var editableAddress: some View {
        HStack(spacing: 12) {
            leadingGlyph
            TextField(placeholder, text: $address)
                .textFieldStyle(.plain)
                // Each of these is load-bearing: a URL keyboard puts the slash
                // and the dot under a thumb, autocapitalisation would send
                // "Localhost", autocorrect "local host", and the `.URL` content
                // type stops iOS offering a contact's name.
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .focused($focused)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("\(id).address")
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
            Text(address.isEmpty ? placeholder : address)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(address.isEmpty ? Theme.faint : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(id).address.readOnly")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /// The globe, or the ⓘ that replaces it on a page with something to explain.
    @ViewBuilder
    private var leadingGlyph: some View {
        if let unavailable {
            InfoDot(about: "this page", text: unavailable)
                .frame(width: 24, height: 28)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.faint)
                .frame(width: 24, height: 28)
        }
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
     * Back, forward, reload — and the `…` where there is something behind it.
     *
     * A verb that **can** be sent is never *disabled*, and that is not the
     * never-dead-click rule being bent. `MachineWindow` carries no `canGoBack`:
     * the desktop's own history state is not on this wire, so a phone that greyed
     * Back out would be guessing, and the guess that is wrong in the common
     * direction — a window with history, drawn dead — is the exact defect the
     * tunnel browser's Back had for months.
     *
     * A verb this page has **no way to ask for at all** is a different thing, and
     * since *"it should be the same case, or all the options should be available
     * at least"* it is drawn in its place and greyed rather than left out. The
     * reason is on the ⓘ in the address row, which is why `unavailable` is one
     * sentence for the whole bar and not one per glyph: the answer is a fact about
     * the page, and three copies of it would be three places for it to drift.
     */
    /**
     * Whether the bottom row has anything left on it.
     *
     * It can be empty, which it could not be before the keyboard verb went: that
     * was the one verb every screen with a live picture drew, and a page that can
     * be watched and not navigated — this bar on a screen reached from Settings
     * with no model behind it — has nothing else and nothing to say about why.
     * Twenty points of empty bar is chrome pretending to be a control, so the row
     * goes rather than standing there. A page that *does* have a reason draws the
     * three dead verbs and the reason beside them.
     *
     * The `VStack` around it stays either way, because it is what carries the
     * subscription that puts the typing row up.
     */
    private var hasVerbs: Bool {
        back != nil || forward != nil || reload != nil || more != nil || unavailable != nil
    }

    private var verbRow: some View {
        HStack(spacing: 0) {
            slot("Back", "chevron.left", id: "\(id).back", act: back)
            slot("Forward", "chevron.right", id: "\(id).forward", act: forward)
            slot("Reload", "arrow.clockwise", id: "\(id).reload", act: reload)
            if let more {
                verb("More", "ellipsis", id: "\(id).settings", act: more)
            }
        }
        .padding(.vertical, 10)
    }

    /// One place in the row: the verb where it can act, the same glyph dead where
    /// the page cannot be asked for it and the bar has a reason, and nothing at
    /// all where it has neither.
    @ViewBuilder
    private func slot(_ title: String, _ icon: String,
                      id: String, act: (() -> Void)?) -> some View {
        if let act {
            verb(title, icon, id: id, act: act)
        } else if let unavailable {
            dead(title, icon, id: id, why: unavailable)
        }
    }

    private func verb(_ title: String, _ icon: String,
                      id: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /**
     * The same glyph, in the same place, and it does nothing.
     *
     * `.disabled(true)` rather than a button that opens an explanation: a control
     * that answers a tap with a sentence is still a control that did not do what
     * it says, and the sentence is already one tap away on the ⓘ beside the
     * address. The hint carries it as well, because a greyed glyph is the one
     * thing on this bar VoiceOver would otherwise read as a plain button.
     */
    private func dead(_ title: String, _ icon: String,
                      id: String, why: String) -> some View {
        Button {} label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel(title)
        .accessibilityHint(why)
        .accessibilityIdentifier(id)
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

    /// Put the keyboard away. `typing` is set here as well as being announced
    /// back by the canvas, so the row changes on the press rather than on the
    /// answer to it.
    private func stopTyping() {
        typing = false
        guard let page else { return }
        WatchStage.post(.endTyping, to: page)
    }
}
