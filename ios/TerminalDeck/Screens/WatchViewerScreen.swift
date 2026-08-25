/**
 * The one live canvas in this app, and the screen that mounts it for a page no
 * window claims.
 *
 * ## There is exactly one canvas, and that is a rule rather than a layout choice
 *
 * `WatchLink` holds **one** frame sink — *"a phone screen is one surface"* — and
 * `WatchSurfaceUIView.tearDown()` sets `watch.frameHandler = nil` and sends
 * `browser.unwatch` **unconditionally**, without checking whether the sink is
 * still its own. So two canvases alive at once is not a question of taste, it is
 * a defect generator: the second to mount steals the frames, and the first to
 * unmount stops the cast and unregisters the survivor — which then sits frozen
 * with no way to re-register, because its `didMoveToWindow` has already fired
 * and its width has not changed, so nothing calls `startWatching` again.
 *
 * `WatchStage` exists so that this rule has one place to be stated and two
 * places to be obeyed. It is a thin wrapper over `WatchSurface` on purpose: what
 * it carries is not layout, it is the invariant.
 *
 * The two mounts are:
 *
 *  - **`MachineWindowView`** — a window this phone can drive, which the machine
 *    is also casting. That screen *is* the page, with the address and the page
 *    verbs on a bar under it and everything else behind its `…`.
 *  - **`WatchViewerScreen`**, below — a surface with **no window behind it**.
 *    Two of those exist: on a server, `''` is the drive's own tab, which
 *    `openTab` mints no shell id for and no `browser.window.rows` entry names;
 *    and on a machine advertising `watch` without `browser.control`, every row
 *    on the Browser tab is one.
 *
 * A push from either one lands on a screen that mounts no canvas of its own, so
 * the stack can never hold two.
 *
 * ## Why the surface-only screen keeps a toolbar button for the keyboard
 *
 * It has no bar of its own to put a field on — there is nothing to navigate,
 * because there is no `browser.control` verb that will address a page with no
 * window id. So the one thing this screen can do besides taking taps is type,
 * and the keyboard glyph in the navigation bar is that. The window screen folds
 * the same field into the bar it already has, rather than growing a second one.
 */

import SwiftUI

/**
 * The canvas, and the fact that there is only ever one of it.
 *
 * Everything about painting, acking and gestures is `WatchSurfaceUIView`'s; this
 * is the SwiftUI face of it plus the black ground a letterboxed desktop page
 * needs. Black rather than `Theme.background`: the bars either side of a 16:10
 * page scaled into a phone are not part of the app's paper, and a page's own
 * white against a light theme's white would make the page's edges invisible.
 */
struct WatchStage: View {
    let watch: WatchLink
    /// The surface name — `""` for a server's front tab, else the shell tab id
    /// the window list uses. See `MachineBrowserView` on why that id is the join.
    let window: String

    var body: some View {
        ZStack {
            Color.black
            WatchSurface(watch: watch, window: window)
        }
    }

    /**
     * Put text into the page, then Return.
     *
     * The hand-off is a static plus a notification rather than a call, because
     * the thing that has to receive it is a `UIView` inside a
     * `UIViewRepresentable` and the sender is a SwiftUI value type with no
     * reference to it. The view reads and clears `pendingText` on the next
     * runloop tick, measuring it against the frame currently drawn — which is
     * the only frame a gesture or a paste may be measured against.
     *
     * Written once here rather than in each screen that offers a keyboard: two
     * copies of a three-line hand-off is how one of them ends up posting without
     * setting the text.
     */
    static func send(_ text: String, to window: String) {
        WatchSurface.pendingText = text
        NotificationCenter.default.post(name: WatchSurface.sendTextNote, object: window)
    }
}

/**
 * A page the machine will cast and this phone cannot drive.
 *
 * Full-bleed, which is the only size at which a desktop page is a thing a
 * fingertip can hit, and with nothing on it but the picture and a way to type —
 * because there is nothing else this phone is allowed to do to it. No address,
 * no Back, no Close: every one of those is a `browser.control` verb addressed by
 * window id, and the whole reason this screen exists rather than
 * `MachineWindowView` is that there is no window id to address.
 */
struct WatchViewerScreen: View {
    let watch: WatchLink
    let surface: BrowserSurfaceRow

    /**
     * The model, when whoever pushed this has one — and it is optional for a
     * reason rather than out of convenience.
     *
     * All it is used for is `DeckModel.localhostPageIsOpen`, the flag the
     * `TabView` reads to decide whether its floating pill is drawn over what is
     * on top of the Browser tab. *"Pill should be on here only on the homepage
     * or machines or settings"* — a cast page is the whole thing you came for
     * and the pill would sit over the bottom of it, pointing somewhere else.
     * `DeckChrome` holds that rule and explains why the flag exists at all: a
     * `.toolbar(.hidden, for: .tabBar)` written on a pushed screen has **no
     * effect** on iOS 26, measured.
     *
     * The other caller is `WatchSurfacesView`, which is reached from a
     * `DeckModel.SettingsRoute` that nothing pushes any more and is handed only a
     * `WatchLink`. Making this required would mean changing that view's
     * signature, which would mean changing its call site in `DeckTabs`. Nil
     * there is the honest answer: that screen is on another tab, whose bar this
     * flag does not describe.
     */
    var chrome: DeckModel?

    @State private var typing = ""
    @FocusState private var typingFocused: Bool

    var body: some View {
        WatchStage(watch: watch, window: surface.window)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(MachineBrowserText.surfaceLabel(surface))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { chrome?.localhostPageIsOpen = true }
            // Cleared on the way out rather than by whoever comes next, so a
            // Back from anywhere — the chevron, the edge swipe — restores the bar.
            .onDisappear { chrome?.localhostPageIsOpen = false }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        typingFocused = true
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .accessibilityLabel("Type into the page")
                    .accessibilityIdentifier("browser.watch.keyboard")
                }
            }
            .safeAreaInset(edge: .bottom) {
                // A field made visible only to send text and Return to the page
                // — a phone has no hardware keyboard, and a live view you cannot
                // type into is half a browser. What is typed is pasted as one
                // `insertText`; Return is sent as an Enter key.
                if typingFocused {
                    HStack(spacing: 8) {
                        TextField("Type into the page", text: $typing)
                            .textFieldStyle(.roundedBorder)
                            .focused($typingFocused)
                            .submitLabel(.send)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { sendTyping() }
                            .accessibilityIdentifier("browser.watch.type")
                        Button("Send") { sendTyping() }
                            .disabled(typing.isEmpty)
                            .accessibilityIdentifier("browser.watch.send")
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                }
            }
    }

    private func sendTyping() {
        let text = typing
        typing = ""
        WatchStage.send(text, to: surface.window)
    }
}
