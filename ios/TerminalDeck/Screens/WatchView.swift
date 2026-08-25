/**
 * Watching — and **driving** — the machine's browser from the phone.
 *
 * The view half of `WatchLink`, and a port of `pwa/src/browser-view.ts` onto
 * UIKit. `WatchSurfacesView` is the tab strip: the surfaces the machine says are
 * watchable, each opening `WatchViewerScreen` (in `WatchViewerScreen.swift`).
 * `WatchSurfaceUIView` is the canvas — it decodes each frame's JPEG onto a layer
 * and turns every touch into a `browser.input` aimed at the frame it was
 * measured against.
 *
 * The four rules from the PWA hold here exactly:
 *
 *  1. **Ack from the paint callback.** The host holds one un-acked frame per
 *     watcher, so the ack fires after the layer's contents are set, not on
 *     receipt — otherwise the phone asks for frames faster than it can show them.
 *  2. **The page lives on the server, so the surface never scrolls itself.** A
 *     swipe is a `browser.input` wheel; the layer only ever shows the server's
 *     viewport.
 *  3. **Coordinates are image pixels of a named frame.** Every gesture is
 *     measured against the frame currently drawn and sent with *that* `seq`.
 *  4. **A masked frame is a curtain, never pixels.** `data` is empty and the
 *     view draws its own lock card; the pixels never crossed the wire.
 *
 * ## Why this file was rewritten: *"it feels like a streaming… like just a video"*
 *
 * > *"if I open a browser window it feels like a streaming, exactly — and if I
 * > open any one it feels like just like a video. I cannot click inside, I cannot
 * > touch the URL and things. I mean I need it should be feeling like a neat
 * > native browser. It should not feel like I'm streaming. It should be like a
 * > proper native browser which I'm just controlling from here."*
 *
 * Three separate things made that true, and they were three separate defects.
 *
 * ### 1. Every tap landed somewhere else
 *
 * `WatchMath.imageCoords` mapped a touch against the **view's** box on each axis
 * while the layer drew with `.resizeAspect`, which **letterboxes**. A 1280×800
 * page fitted to a 393-point-wide phone is about 246 points tall in a 760-point
 * view: a touch at the top of the picture was reported a third of the way down
 * the document, and a touch on the black bars was clamped onto the page and
 * clicked something anyway. That function now takes the rectangle the picture is
 * actually in, and this view is the thing that knows it — the page is a sublayer
 * whose `frame` **is** that rectangle, so the mapping is a ratio inside a
 * rectangle the view set itself rather than a guess about how a gravity behaved.
 *
 * ### 2. Two gestures existed, and a browser needs six
 *
 * A tap sent `down`+`up` and a drag sent a wheel. Nothing else was ever sent —
 * no `move`, so a page whose menus open on hover was inert; no held button, so
 * nothing could be dragged or selected; nothing at all for two fingers. What is
 * sent now:
 *
 *  - **tap** — `move` to the point, then `down`/`up`. The move is not decoration:
 *    CSS `:hover` and every menu that opens on `mouseover` need the pointer to
 *    arrive before the button goes down, and on a desktop page that is most
 *    navigation bars.
 *  - **one-finger drag** — a wheel, as before, but in the frame's **CSS** pixels
 *    rather than its image pixels. `browser-watch.ts` divides a *position* by the
 *    frame's `scale` and uses a *delta* raw, so a delta measured in image pixels
 *    was quietly short by that scale on every page whose width is not exactly
 *    what this phone asked to render at.
 *  - **long press, then drag** — `down`, `move`, `move`, `up` with the button
 *    held. Selecting text, dragging a slider, moving a thing on a canvas. The
 *    scroll recogniser is disabled for the duration rather than allowed to race
 *    it, because a wheel arriving in the middle of a held drag scrolls the page
 *    out from under the selection.
 *  - **pinch** — the viewer's own magnification of the picture it was sent, and
 *    **not** a page zoom. There is no honest way to zoom the page from here: the
 *    browser's own zoom is ctrl-and-wheel, and `BrowserInputFrame.mouse` carries
 *    no modifier field (`src/main/remote/protocol.ts` line 1591). What this does
 *    instead is what a phone showing a desktop-width page should do — magnify,
 *    and then **ask the host to render wider**, so the text sharpens rather than
 *    turning into a blown-up JPEG.
 *  - **two-finger drag** — pans the magnified picture, which is the only thing
 *    it can mean once one finger is spoken for.
 *  - **a keyboard**, below.
 *
 * ### 3. There was no way to type into the page, only a way to paste at it
 *
 * The old keyboard was a `TextField` in the app's own chrome: you typed a line
 * into it, pressed Send, and the line was pasted into the page followed by
 * Return. Nothing arrived until you pressed Send, so a page that filters a list
 * as you type showed nothing and an autocomplete never opened.
 *
 * This view is a `UIKeyInput` now. A tap on the page raises the system keyboard
 * on it and every keystroke goes to the page as it is struck: text through
 * `Input.insertText`, Return as a key event. `hasText` is `false` and stays
 * false — this view holds no text of its own, the page does, and there is no
 * signal on the wire that says what the page's field contains.
 *
 * **What was measured against his live server**, on DuckDuckGo, because none of
 * this can be established by reading either end:
 *
 *  - characters — work, one at a time, and the site's own autocomplete opened as
 *    they were typed, which is the proof that they arrived as input events
 *    rather than in a lump;
 *  - Return — works; the search submitted;
 *  - **Backspace — does nothing**, and neither do the arrows. `dispatchKey` in
 *    `src/main/browser-watch.ts` sends `key`, `code`, `text` and `modifiers` and
 *    **no `windowsVirtualKeyCode`**, so Chromium hands the event to the page's
 *    JavaScript (which is why DuckDuckGo's own Return handler fires) and does
 *    nothing with it itself — and Backspace, Tab and the arrows are the browser's
 *    own handling, not the page's. `BrowserPageBar` explains what was taken off
 *    the bar because of it, and the fix needs no wire change: a lookup from
 *    `key`/`code` to a virtual key code inside `dispatchKey`.
 *
 * ## A tap raises the keyboard, and that rule used to be the other way round
 *
 * The phone is not told *what has focus on the page* — nothing on the
 * `browser.frame` wire carries focus — so this file's rule was: you tap the
 * field, then you press a keyboard button in the app's own chrome, because an
 * auto-raise from a heuristic would be a keyboard appearing over pages with no
 * field on them.
 *
 * > *"This keyboard should not be working like this. If we just click inside and
 * > type from our keyboard, it should work… I should not have to have this
 * > separate button of keyboard. It should just come up from down, and the
 * > original native button should be there to move it down if I want, not a
 * > separate keyboard here inside the browser window."*
 *
 * So `onTap` takes first responder as well as sending the click, and the trade
 * that was refused is now paid: a tap on a page with no field under it raises a
 * keyboard nobody asked for. What makes that a nuisance rather than a dead end
 * is the way back down. `inputAccessoryView` puts the same
 * `keyboard.chevron.compact.down` over this keyboard that `KeyboardAccessory`
 * has pinned to the right of the terminal's bar all along — same glyph, same
 * corner, same press — so *"the original native button… to move it down"* is
 * there on every screen that mounts a canvas.
 */

import SwiftUI
import UIKit

// MARK: - The tab strip

struct WatchSurfacesView: View {
    let watch: WatchLink

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if watch.surfaces.isEmpty {
                ContentUnavailableView("No windows to watch",
                                       systemImage: "macwindow",
                                       description: Text("Open a browser window on the machine, or attach one to a session, and it will appear here."))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(watch.surfaces.enumerated()), id: \.element.id) { index, surface in
                            if index > 0 { Divider().background(Theme.hairline).padding(.leading, 16) }
                            NavigationLink {
                                WatchViewerScreen(watch: watch, surface: surface)
                            } label: {
                                surfaceRow(surface)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(16)

                    // Pushed from Settings, so it keeps the bar and owes it room.
                    TabBarClearance()
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .navigationTitle("Watch browser")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { watch.ensureRead() }
    }

    private func surfaceRow(_ surface: BrowserSurfaceRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: surface.live ? "dot.radiowaves.left.and.right" : "macwindow")
                .font(.system(size: 15))
                .foregroundStyle(surface.live ? Theme.positive : Theme.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(surface.title.isEmpty ? (surface.window.isEmpty ? "Front tab" : surface.window) : surface.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !surface.url.isEmpty {
                    Text(surface.url)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - What a screen asks the canvas to do

/**
 * One instruction from a screen to the canvas underneath it.
 *
 * The screens are SwiftUI value types and the canvas is a `UIView` inside a
 * `UIViewRepresentable`; there is no reference from one to the other, so this
 * rides a notification. One case list rather than one notification name per
 * verb, because four names is four places to forget to remove an observer.
 */
enum WatchCommand {
    /**
     * Put the keyboard away.
     *
     * The only direction left. There was a `beginTyping` beside it and every
     * screen that sent it drew a button to do so — *"I should not have to have
     * this separate button of keyboard. It should just come up from down"* — so
     * raising is `onTap`'s job and no screen asks for it. What a screen still
     * knows, and the canvas cannot, is when typing has to **stop**: a pane being
     * folded, a screen being left, a page being handed back.
     */
    case endTyping
}

/**
 * What the lock card says, which is a decision and not a layout.
 *
 * Out of the view so it can be pinned, because it is wrong in two directions
 * and only one of them is visible in a screenshot. Saying the sentence twice is
 * ugly and was shipped; **not** saying it at all is a person looking at a black
 * rectangle with no idea what is wanted, and that one only happens on the
 * screens a photograph of the session page would never show.
 */
enum WatchCurtain {
    /// The part that is always true: there are no pixels here.
    static let lock = "\u{1F512}"

    /**
     * What the card says when the sentence is already on screen above it.
     *
     * About the **pixels** rather than about the request. The request is the
     * bar's job and is two inches higher up; what the bar cannot say, and what
     * somebody looking at a black rectangle actually needs, is that the black is
     * temporary and what ends it.
     */
    static let shortLine = "The page is hidden until this is answered."

    static func card(prompt: String, sentenceIsDrawnAbove: Bool) -> String {
        lock + "\n\n" + (sentenceIsDrawnAbove ? shortLine : prompt)
    }
}

// MARK: - The canvas

struct WatchSurface: UIViewRepresentable {
    let watch: WatchLink
    let window: String

    /**
     * Told how tall the picture is, in view points, whenever that changes.
     *
     * The letterbox is the reason this exists. A 1280×800 page fitted to a
     * 393-point phone is about 246 points tall, and the four hundred points
     * underneath it are the black area Asad was looking at when he said *"let's
     * give terminal here in black area available down here, to watch what the
     * session is doing."* A screen cannot hand that space to anything else
     * without knowing where the picture stops, and nothing in SwiftUI can work it
     * out: the aspect ratio belongs to a frame that has not arrived yet, and it
     * changes when the host renegotiates the render width.
     *
     * So the canvas — which is the one thing that does know, because `layoutPage`
     * computes the rectangle — says so. A screen that takes this and sizes the
     * canvas to it ends up with **no letterbox at all**: the page occupies
     * exactly its own height and the session gets the rest.
     *
     * It converges in one pass rather than oscillating. Given a box `H` points
     * tall and `W` wide, `WatchMath.fit` scales by `min(W/fw, H/fh)`; setting
     * `H = W·fh/fw` makes those two terms equal, so the next fit is the same fit
     * and the reported height does not move again. A page too tall for the cap a
     * screen applies settles at the cap with its own side bars, which is the
     * honest shape for a page that is taller than it is wide.
     *
     * Reported from a runloop hop, never from inside `layoutSubviews`: the
     * receiver is `@State` on a SwiftUI view and writing it during a layout pass
     * is the "Modifying state during view update" warning followed by a frame of
     * the old size.
     */
    var onPageHeight: ((CGFloat) -> Void)?

    /**
     * Whether the screen above this canvas is already showing the agent's
     * sentence, so the lock card must not say it a second time.
     *
     * Measured rather than reasoned about: on a 393-point phone with a handover
     * outstanding, the bar printed the sentence and the card underneath printed
     * the same sentence again in a larger face — between them most of a phone
     * screen spent saying one thing twice, with the page it was about reduced to
     * the strip above them.
     *
     * A flag from the mount rather than a look at `WatchLink`, and that
     * distinction is the whole safety of it. The link knows a handover is
     * outstanding; it does **not** know whether the screen drawing this canvas
     * has a bar on it. Two of the three screens that mount a canvas have no bar
     * at all — `WatchViewerScreen` and `MachineWindowView` — and on those the
     * card's sentence is the only thing the person gets. And a curtain raised by
     * a **secret field in view** rather than by a handover has no bar anywhere,
     * on any screen, ever: `PageCast.maskFor` withholds the pixels of any frame
     * with an `input[type=password]` in it whether or not anybody has been
     * asked about it. Suppressing on either of those would delete the only
     * sentence there was.
     *
     * So the only thing that may set this is a screen that can see its own bar,
     * for the frames that bar is about.
     */
    var sentenceIsDrawnAbove = false

    /// The instruction a screen wants carried out, handed across the value-type
    /// boundary. Read and cleared by the view on the notification.
    static var pending: WatchCommand?
    static let commandNote = Notification.Name("WatchSurfaceCommand")

    /**
     * The other direction: the canvas saying whether it is holding the keyboard.
     *
     * It has to say so because it is now the thing that decides. A tap on the
     * page raises the keyboard, so a bar drawn above the canvas can no longer
     * know from its own button whether somebody is typing — and saying where the
     * keystrokes are going is the one thing that bar is for while they are. The
     * surface name is the object and the flag rides in `userInfo`, so a bar over
     * a different page ignores it.
     */
    static let typingNote = Notification.Name("WatchSurfaceTyping")
    /// The `userInfo` key `typingNote` carries its `Bool` under.
    static let typingKey = "typing"

    func makeUIView(context: Context) -> WatchSurfaceUIView {
        let view = WatchSurfaceUIView(watch: watch, target: window)
        view.onPageHeight = onPageHeight
        view.sentenceIsDrawnAbove = sentenceIsDrawnAbove
        return view
    }

    // Re-handed on every update rather than captured once: the closure is a
    // SwiftUI value that closes over this rebuild's `@State`, and one kept from
    // `makeUIView` would go on writing into a binding nobody is reading.
    func updateUIView(_ uiView: WatchSurfaceUIView, context: Context) {
        uiView.onPageHeight = onPageHeight
        // Re-handed on every update, and the card is redrawn when it changes: a
        // handover that arrives while a curtain is already up (a password box was
        // on screen first) has to take the sentence off the card at that moment,
        // not at the next frame.
        uiView.sentenceIsDrawnAbove = sentenceIsDrawnAbove
    }

    static func dismantleUIView(_ uiView: WatchSurfaceUIView, coordinator: ()) {
        uiView.tearDown()
    }
}

/// The layer-backed canvas: one surface's frames, and every gesture that drives
/// it.
final class WatchSurfaceUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    private let watch: WatchLink
    /// The surface this canvas shows — `""` for the front tab, else a slot name.
    /// Named `target` rather than `window` because `UIView.window` is taken.
    private let target: String

    /// See `WatchSurface.sentenceIsDrawnAbove`. Redraws the card when it moves,
    /// because the curtain may already be up when the question arrives.
    var sentenceIsDrawnAbove = false {
        didSet {
            guard sentenceIsDrawnAbove != oldValue, let frame = lastFrame, frame.masked else { return }
            showCurtain(frame.prompt ?? defaultCurtainPrompt)
        }
    }

    /// The last frame actually drawn — what a gesture is measured against.
    private var lastFrame: BrowserFrame?
    /// The width last asked for, so a resize renegotiates only on a real change.
    private var requestedWidth = 0

    /// One decode at a time; a frame arriving mid-decode replaces the one waiting.
    private var painting = false
    private var queued: BrowserFrame?

    /**
     * The page, as its own layer.
     *
     * Not the view's own layer with a gravity, which is how the letterbox
     * defect got in: a gravity is a rule the layer applies where nothing can
     * read the result, and the result is exactly what a tap needs. This layer's
     * `frame` **is** where the picture is, the view sets it, and `drawn` is the
     * same rectangle kept for the gesture handlers.
     */
    private let pageLayer = CALayer()
    /// Where the picture is, in view points. Set by `layoutPage`.
    private var drawn: CGRect = .zero
    /// The viewer's magnification of the received picture — never a page zoom.
    private var zoom: CGFloat = 1
    /// How far the magnified picture has been dragged from where `fit` puts it.
    private var pan: CGPoint = .zero

    private let curtain = UILabel()
    private let decodeQueue = DispatchQueue(label: "watch.decode", qos: .userInteractive)

    private let tapGesture = UITapGestureRecognizer()
    private let scrollGesture = UIPanGestureRecognizer()
    private let dragGesture = UILongPressGestureRecognizer()
    private let pinchGesture = UIPinchGestureRecognizer()
    private let panGesture = UIPanGestureRecognizer()

    /// A held mouse button is in flight, so the scroll recogniser must stay out
    /// of the way — see `beginDrag`.
    private var dragging = false
    /// The pan translation already turned into wheels or into movement, so each
    /// callback acts on the step rather than on the running total.
    private var spentScroll: CGPoint = .zero
    private var spentPan: CGPoint = .zero
    /// The magnification when the pinch began, and the point under the fingers.
    private var zoomAtPinchStart: CGFloat = 1
    private var pinchAnchor: CGPoint = .zero

    /// Whether the system keyboard is up on this canvas. Maintained by the two
    /// responder overrides rather than by whoever asked, because a tap raises it
    /// and four different things put it away.
    private var typing = false

    /// Told the height the picture is drawn at. See `WatchSurface.onPageHeight`.
    var onPageHeight: ((CGFloat) -> Void)?
    /// The last height announced, so a page that is not changing size is not
    /// announced sixty times a second — every frame runs `layoutPage`.
    private var announcedHeight: CGFloat = -1

    // The traits `UIKeyInput` inherits. Every one of them is off on purpose: the
    // page is the thing being typed into and it has its own opinion about what
    // the words are. Autocorrect would rewrite a URL, autocapitalisation would
    // send "Localhost", and smart quotes would put a curly apostrophe into a
    // password field.
    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var returnKeyType: UIReturnKeyType = .go

    init(watch: WatchLink, target: String) {
        self.watch = watch
        self.target = target
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true

        pageLayer.contentsGravity = .resize
        pageLayer.minificationFilter = .trilinear
        pageLayer.magnificationFilter = .linear
        pageLayer.isHidden = true
        layer.addSublayer(pageLayer)

        curtain.numberOfLines = 0
        curtain.textAlignment = .center
        // The lock card is a fixed dark surface in both themes — the page is not
        // being shown, so it is deliberately not the app's paper. These are the
        // PWA's own curtain colours (`#e6e8ec` on `#101216`), written as RGB
        // rather than a white tint: `AppearanceTests` bans the tint shorthand
        // because it is the smell of a colour that forgot to adapt, and this one
        // is meant not to.
        curtain.textColor = UIColor(red: 0.902, green: 0.910, blue: 0.925, alpha: 1)
        curtain.font = .systemFont(ofSize: 15)
        curtain.isHidden = true
        curtain.translatesAutoresizingMaskIntoConstraints = false
        addSubview(curtain)
        NSLayoutConstraint.activate([
            curtain.centerXAnchor.constraint(equalTo: centerXAnchor),
            curtain.centerYAnchor.constraint(equalTo: centerYAnchor),
            curtain.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            curtain.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        installGestures()

        adopt()

        NotificationCenter.default.addObserver(self, selector: #selector(command(_:)),
                                               name: WatchSurface.commandNote, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    /**
     * Which canvas currently owns `WatchLink.frameHandler`.
     *
     * `WatchStage`'s header states the rule — one canvas, because the link holds
     * one sink — and until this existed the rule was *hoped for* rather than
     * enforced. There are now three screens that can mount a stage (the window,
     * the surface viewer, and the page inside a session), they live on different
     * tabs, and **a tab swap fires no lifecycle callback on the tab being left**
     * — the fact `TerminalScreen.frontmost` exists for. So the arriving screen's
     * canvas can be built before the leaving one is dismantled, in an order
     * neither screen chooses.
     *
     * The old `tearDown` cleared the sink unconditionally, so that order left the
     * *surviving* canvas registered with nothing: frames arrived at a closure
     * whose `weak self` was gone, and the picture froze with no way to recover,
     * because `didMoveToWindow` had already fired and the width had not changed
     * so nothing called `startWatching` again.
     *
     * Weak, and compared by identity: it is a record of who registered, never a
     * reason to keep a view alive.
     */
    private static weak var owner: WatchSurfaceUIView?

    /// Take the link's one frame sink. Called on build and on every re-entry
    /// into a window, so a canvas that was mounted, superseded and then left
    /// alone is registered again rather than sitting on a dead closure.
    private func adopt() {
        Self.owner = self
        // One sink, because a phone shows one surface at a time; a frame for
        // another window is dropped rather than buffered — a live frame is stale
        // before anything could catch up on it.
        watch.frameHandler = { [weak self] frame in
            guard let self, frame.window == self.target else { return }
            self.onFrame(frame)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if Self.owner !== self { adopt() }
        startWatching()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPage()
        // A rotation or a size change renegotiates the render width, but only
        // when the width actually moved — a host reading a stream of identical
        // watches would restart a screencast for nothing. The keyboard coming up
        // changes the height and not the width, which is why this is asked of
        // the width alone.
        if renderWidth() != requestedWidth { startWatching() }
    }

    /// The pixel width to ask the host to render at, magnification included: a
    /// page held at 2× and rendered at the phone's own width is a blown-up JPEG,
    /// and the host will happily send more pixels of the same layout.
    private func renderWidth() -> Int {
        WatchMath.watchWidth(pointWidth: bounds.width * zoom, scale: traitCollection.displayScale)
    }

    private func startWatching() {
        guard bounds.width > 0 else { return }
        requestedWidth = renderWidth()
        _ = watch.watch(window: target, maxWidth: requestedWidth, quality: defaultWatchQuality)
    }

    func tearDown() {
        if typing { _ = resignFirstResponder() }
        // Unconditional: this canvas asked for the cast of `target` and is going
        // away, so the host must stop sending it. Another canvas showing the same
        // surface has its own `browser.watch` in flight and the host is idempotent
        // about them — see `WatchLink.watch`.
        watch.unwatch(window: target)
        // The sink, on the other hand, is **only** cleared by whoever holds it.
        // See `owner`: a screen arriving on another tab can build its canvas
        // before this one is dismantled, and clearing here regardless is what
        // used to leave the survivor registered with a dead closure.
        if Self.owner === self {
            watch.frameHandler = nil
            Self.owner = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Paint + ack

    private func onFrame(_ frame: BrowserFrame) {
        if painting {
            queued = frame
            return
        }
        painting = true
        paint(frame)
    }

    private func paint(_ frame: BrowserFrame) {
        if frame.masked {
            showCurtain(frame.prompt ?? defaultCurtainPrompt)
            lastFrame = frame
            ackAndContinue(frame.seq)
            return
        }
        curtain.isHidden = true
        let data = frame.data
        decodeQueue.async { [weak self] in
            let image = UIImage(data: data)?.cgImage
            DispatchQueue.main.async {
                guard let self else { return }
                if let image {
                    self.pageLayer.contents = image
                    self.pageLayer.isHidden = false
                }
                // A frame the phone could not decode is still acked, or the whole
                // cast stalls on one bad frame; the last good frame stays under
                // the finger and its `seq` is what the next gesture maps against.
                self.lastFrame = frame
                self.layoutPage()
                self.ackAndContinue(frame.seq)
            }
        }
    }

    private func ackAndContinue(_ seq: Int) {
        watch.ack(window: target, seq: seq)
        painting = false
        if let next = queued {
            queued = nil
            onFrame(next)
        }
    }

    /**
     * The lock card: why there are no pixels, in as few words as are true.
     *
     * The sentence is the host's, off the masked frame, and it is the only thing
     * a person gets when the curtain is a **secret field** in view — no question
     * was asked, no bar is drawn anywhere, and the card is the whole
     * explanation. So it is printed in full by default.
     *
     * When the screen above is already showing that same sentence, printing it
     * again is not emphasis, it is a phone screen spent twice on one thing. Then
     * the card keeps the lock — which is the part that says *there are no pixels
     * here* — and one short line for the part the lock cannot say, which is that
     * this is temporary and what ends it. See
     * `WatchSurface.sentenceIsDrawnAbove` for why this is a flag from the mount
     * and not a question asked of `WatchLink`.
     */
    private func showCurtain(_ prompt: String) {
        pageLayer.contents = nil
        pageLayer.isHidden = true
        backgroundColor = UIColor(red: 0.063, green: 0.071, blue: 0.086, alpha: 1)
        curtain.text = WatchCurtain.card(prompt: prompt, sentenceIsDrawnAbove: sentenceIsDrawnAbove)
        curtain.isHidden = false
    }

    /**
     * Put the picture where it goes, and remember where that is.
     *
     * The clamp is applied and then **written back into `pan`**, so a pinch that
     * pushed the picture past an edge does not keep the refused offset and spend
     * the next drag paying it back. Actions are disabled because a frame lands
     * every few tens of milliseconds and an implicit CALayer animation on each of
     * them is a picture that is always a quarter of a second behind the finger.
     */
    private func layoutPage() {
        guard let frame = lastFrame, !frame.masked, frame.w > 0, frame.h > 0, bounds.width > 0 else { return }
        let base = WatchMath.fit(frameW: frame.w, frameH: frame.h, in: bounds.size)
        guard base.width > 0 else { return }
        let wanted = CGRect(x: base.minX + pan.x, y: base.minY + pan.y,
                            width: base.width * zoom, height: base.height * zoom)
        let placed = WatchMath.clampDrawn(wanted, in: bounds.size)
        pan = CGPoint(x: placed.minX - base.minX, y: placed.minY - base.minY)
        drawn = placed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.frame = placed
        CATransaction.commit()
        announce(placed.height)
    }

    /**
     * Say how tall the picture is, but only when it has moved.
     *
     * `layoutPage` runs on every frame — tens of times a second on a page that
     * is scrolling — and the height is the same on all of them, so the guard is
     * what keeps this from being a `@State` write per frame and a SwiftUI
     * re-layout per frame with it. Half a point of tolerance because the
     * rectangle is computed in floating point from a rounded fit and can wobble
     * in the last digit without the picture moving at all.
     *
     * Nothing is announced while the picture is magnified: at `zoom > 1` the
     * drawn rectangle is deliberately larger than the box it is in, and a screen
     * that sized its pane to it would grow the pane every time somebody pinched.
     * The pane is the size of the page at 1×; the zoom is what happens *inside*
     * it.
     */
    private func announce(_ height: CGFloat) {
        guard let onPageHeight, zoom == 1, height.isFinite, height > 0 else { return }
        guard abs(height - announcedHeight) > 0.5 else { return }
        announcedHeight = height
        DispatchQueue.main.async { onPageHeight(height) }
    }

    // MARK: - Gestures

    /**
     * The five recognisers, and the two relationships between them that matter.
     *
     * `pinch` and the two-finger `pan` run **together**: pinching to look closer
     * and sliding to bring the thing you are looking at into the middle is one
     * movement, and a phone that made you finish one before starting the other
     * would feel exactly like the thing being complained about.
     *
     * The long-press drag and the one-finger scroll are the opposite — they are
     * two readings of the same finger and only one can be right. The press wins
     * when it fires, and it wins by **disabling the scroll recogniser for the
     * duration** rather than by a `require(toFail:)`: making the scroll wait for
     * the press to fail would put 0.35 seconds of nothing under every ordinary
     * swipe, which is the whole feel of the screen.
     */
    private func installGestures() {
        tapGesture.addTarget(self, action: #selector(onTap(_:)))
        addGestureRecognizer(tapGesture)

        scrollGesture.addTarget(self, action: #selector(onScroll(_:)))
        scrollGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(scrollGesture)

        dragGesture.addTarget(self, action: #selector(onDrag(_:)))
        dragGesture.minimumPressDuration = 0.35
        dragGesture.allowableMovement = 12
        addGestureRecognizer(dragGesture)

        pinchGesture.addTarget(self, action: #selector(onPinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        panGesture.addTarget(self, action: #selector(onTwoFingerPan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gesture === pinchGesture && other === panGesture)
            || (gesture === panGesture && other === pinchGesture)
    }

    /**
     * A tap: the click goes to the page, and the keyboard comes up with it.
     *
     * > *"If we just click inside and type from our keyboard, it should work…
     * > It should just come up from down."*
     *
     * The click is unchanged and stays first — it is what a tap is for, and its
     * coordinates were measured against the frame drawn before the keyboard
     * moved anything. Taking first responder afterwards is the whole of the
     * keyboard: there is no field to focus on this end, only a canvas that
     * forwards keystrokes to whatever the far page has focused.
     *
     * A tap on the letterbox raises nothing, because `page(at:)` above refuses
     * it as a tap that is not on the page at all.
     */
    @objc private func onTap(_ gesture: UITapGestureRecognizer) {
        guard let at = page(at: gesture.location(in: self)) else { return }
        // Inspect mode: a tap *names* what is under it instead of pressing it.
        //
        // `page(at:)` has already refused a touch on the letterbox and returned
        // the same point a click would have used, so the two roads cannot land
        // on two different elements — which is the whole reason the conversion
        // to document coordinates lives in `MachinePick` and not here.
        // `take` answers false whenever inspect is off, this is not the armed
        // window, or the frame is curtained, and the ordinary click follows.
        if let frame = lastFrame,
           MachinePick.take(window: target, frame: frame, imageX: at.x, imageY: at.y) { return }
        // The pointer arrives before the button goes down. A desktop page's
        // navigation opens on `mouseover` far more often than on click, and a
        // click with no move before it lands on a menu that never opened.
        send(.mouse(.init(type: .move, x: at.x, y: at.y, button: nil, clicks: nil, dx: nil, dy: nil)), seq: at.seq)
        send(.mouse(.init(type: .down, x: at.x, y: at.y, button: .left, clicks: 1, dx: nil, dy: nil)), seq: at.seq)
        send(.mouse(.init(type: .up, x: at.x, y: at.y, button: .left, clicks: 1, dx: nil, dy: nil)), seq: at.seq)
        if !isFirstResponder { _ = becomeFirstResponder() }
    }

    /**
     * One finger: the page scrolls, unless the picture is magnified and has room
     * to move first.
     *
     * At 1× there is nothing to pan — the picture is fitted to the view — so the
     * whole movement is a wheel. Magnified, the movement pans the picture until
     * it reaches an edge and **what is left over becomes the wheel**, which is
     * how a scroll view inside a scroll view behaves and is what stops a zoomed
     * page from being a dead end at the bottom of the screen.
     */
    @objc private func onScroll(_ gesture: UIPanGestureRecognizer) {
        guard !dragging else { return }
        switch gesture.state {
        case .began:
            spentScroll = .zero
        case .changed:
            let total = gesture.translation(in: self)
            let step = CGPoint(x: total.x - spentScroll.x, y: total.y - spentScroll.y)
            spentScroll = total
            let leftOver = movePicture(by: step)
            wheel(leftOver, at: gesture.location(in: self))
        default:
            spentScroll = .zero
        }
    }

    /// Two fingers: only the picture moves. The page cannot be scrolled by this
    /// gesture, because at 1× there is nothing under two fingers that is not
    /// already the pinch.
    @objc private func onTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            spentPan = .zero
        case .changed:
            let total = gesture.translation(in: self)
            _ = movePicture(by: CGPoint(x: total.x - spentPan.x, y: total.y - spentPan.y))
            spentPan = total
        default:
            spentPan = .zero
        }
    }

    /**
     * Press and hold, then drag: the left button is **held down** for the whole
     * movement.
     *
     * Selecting a paragraph, dragging a slider's handle, moving a node on a
     * canvas — none of which a wheel can express, and all of which are what
     * somebody means when they say a live view is not a browser. `move` events
     * carry the button so the far side sees a drag rather than a hover, which is
     * what `browser-watch.ts` puts on `Input.dispatchMouseEvent` when a move
     * names one.
     */
    @objc private func onDrag(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let at = page(at: point) else { return }
            dragging = true
            // Take the finger away from the scroll recogniser mid-gesture. Toggling
            // `isEnabled` is UIKit's own way to cancel a recogniser that has
            // already begun; it comes back on at the end of the press.
            scrollGesture.isEnabled = false
            scrollGesture.isEnabled = true
            send(.mouse(.init(type: .move, x: at.x, y: at.y, button: nil, clicks: nil, dx: nil, dy: nil)), seq: at.seq)
            send(.mouse(.init(type: .down, x: at.x, y: at.y, button: .left, clicks: 1, dx: nil, dy: nil)), seq: at.seq)
        case .changed:
            guard dragging, let at = anywhere(at: point) else { return }
            send(.mouse(.init(type: .move, x: at.x, y: at.y, button: .left, clicks: nil, dx: nil, dy: nil)), seq: at.seq)
        case .ended, .cancelled, .failed:
            guard dragging, let at = anywhere(at: point) else {
                dragging = false
                return
            }
            dragging = false
            send(.mouse(.init(type: .up, x: at.x, y: at.y, button: .left, clicks: 1, dx: nil, dy: nil)), seq: at.seq)
        default:
            break
        }
    }

    /**
     * Pinch: magnify the picture, and then ask for a better one.
     *
     * This is the viewer's own zoom and not the page's, and the difference is
     * worth being exact about. The page's zoom is ctrl-and-wheel in every
     * desktop browser, and `BrowserInputFrame.mouse` has no modifier field to
     * carry the ctrl with — so a page zoom cannot be asked for over this wire at
     * all. What can be done is what a phone showing a desktop-width page should
     * do anyway: draw the received picture larger, and raise `maxWidth` on the
     * cast so the larger drawing is made of real pixels instead of enlarged ones.
     *
     * The renegotiation happens on **release**. `browser.watch` is a
     * reconfiguration of a running screencast, and one per frame of a pinch is a
     * host restarting its cast sixty times a second.
     */
    @objc private func onPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoomAtPinchStart = zoom
            pinchAnchor = gesture.location(in: self)
        case .changed:
            guard let frame = lastFrame, !frame.masked else { return }
            let base = WatchMath.fit(frameW: frame.w, frameH: frame.h, in: bounds.size)
            guard base.width > 0, drawn.width > 0, drawn.height > 0 else { return }
            let next = min(maxWatchZoom, max(1, zoomAtPinchStart * gesture.scale))
            // Keep whatever is under the fingers under the fingers: the point's
            // position within the picture is a fraction, and it is the fraction
            // that must not move.
            let across = (pinchAnchor.x - drawn.minX) / drawn.width
            let down = (pinchAnchor.y - drawn.minY) / drawn.height
            zoom = next
            pan = CGPoint(x: pinchAnchor.x - across * base.width * next - base.minX,
                          y: pinchAnchor.y - down * base.height * next - base.minY)
            layoutPage()
        case .ended, .cancelled, .failed:
            if renderWidth() != requestedWidth { startWatching() }
        default:
            break
        }
    }

    /**
     * Move the magnified picture, and answer with the part of the movement it
     * could not use.
     *
     * The leftover is the whole point: it is what turns a drag at the bottom of a
     * zoomed page into a page scroll instead of a dead stop.
     */
    private func movePicture(by step: CGPoint) -> CGPoint {
        guard zoom > 1, let frame = lastFrame, !frame.masked else { return step }
        let base = WatchMath.fit(frameW: frame.w, frameH: frame.h, in: bounds.size)
        guard base.width > 0 else { return step }
        let before = drawn
        pan = CGPoint(x: pan.x + step.x, y: pan.y + step.y)
        layoutPage()
        return CGPoint(x: step.x - (drawn.minX - before.minX), y: step.y - (drawn.minY - before.minY))
    }

    /**
     * Send a movement to the page as a wheel.
     *
     * The deltas are in the frame's **CSS** pixels, not its image pixels, and
     * that is a measured difference rather than a preference: `dispatchMouse` in
     * `src/main/browser-watch.ts` divides a *position* by the frame's `scale` to
     * reach the viewport but passes `dx`/`dy` to `Input.dispatchMouseEvent`
     * untouched. A phone that asked to render at 1179 pixels wide and got a
     * 1280-pixel-wide page has a scale of 0.92, so deltas measured in image
     * pixels were short by eight per cent on every scroll.
     *
     * The position is still in image pixels, because that is the axis the host
     * *does* convert. The two disagreeing is the wire's shape, not a mistake here.
     */
    private func wheel(_ step: CGPoint, at point: CGPoint) {
        guard step != .zero, let at = anywhere(at: point), let frame = lastFrame, drawn.width > 0 else { return }
        let cssPerPoint = Double(frame.dw > 0 ? frame.dw : frame.w) / Double(drawn.width)
        let dx = (Double(step.x) * cssPerPoint).rounded()
        let dy = (Double(step.y) * cssPerPoint).rounded()
        guard dx != 0 || dy != 0 else { return }
        send(.mouse(.init(type: .wheel, x: at.x, y: at.y, button: nil, clicks: nil,
                          dx: Int(dx), dy: Int(dy))), seq: at.seq)
    }

    /**
     * The image pixel a touch names, **only** when the touch is on the page.
     *
     * A touch on the letterbox is not a touch on the page, and refusing it is
     * half the fix for *"I cannot click inside"*: the old mapping clamped a touch
     * on the black bar onto the page's nearest edge and clicked there, so a
     * finger resting on nothing pressed whatever was at the top of the document.
     */
    private func page(at point: CGPoint) -> (seq: Int, x: Int, y: Int)? {
        guard let frame = lastFrame, !frame.masked, drawn.contains(point) else { return nil }
        let coords = WatchMath.imageCoords(frameW: frame.w, frameH: frame.h, drawn: drawn,
                                           px: point.x, py: point.y)
        return (frame.seq, coords.x, coords.y)
    }

    /// The same, clamped rather than refused — for a gesture that **began** on
    /// the page and has since travelled off it. A selection dragged past the
    /// edge of the picture is a selection to the edge, not a cancelled drag.
    private func anywhere(at point: CGPoint) -> (seq: Int, x: Int, y: Int)? {
        guard let frame = lastFrame, !frame.masked, drawn.width > 0 else { return nil }
        let coords = WatchMath.imageCoords(frameW: frame.w, frameH: frame.h, drawn: drawn,
                                           px: point.x, py: point.y)
        return (frame.seq, coords.x, coords.y)
    }

    private func send(_ input: BrowserInput, seq: Int) {
        watch.input(window: target, seq: seq, input: input)
    }

    // MARK: - The keyboard

    override var canBecomeFirstResponder: Bool { true }

    /**
     * The way back down, over the keyboard rather than inside the page.
     *
     * > *"The original native button should be there to move it down if I want,
     * > not a separate keyboard here inside the browser window."*
     *
     * A keyboard raised on a canvas has no Done of its own: the return key is
     * `.go` and belongs to the page, and nothing else on an iPhone's keyboard
     * dismisses one. So the dismiss rides on the keyboard, which is where this
     * app already keeps it — `KeyboardAccessory` pins the same glyph to the
     * right of the terminal's bar.
     *
     * A toolbar rather than a bar of key caps like that one, because there is
     * exactly one thing on it. The page's keys are the system keyboard's, and
     * the row of Escape/Tab/arrows that was once offered beside them was
     * measured doing nothing at all — see `BrowserPageBar.keyRow`.
     */
    override var inputAccessoryView: UIView? { keyboardBar }

    private lazy var keyboardBar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 44))
        let hide = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"),
                                   style: .plain, target: self, action: #selector(hideKeyboard))
        hide.accessibilityLabel = "Hide the keyboard"
        hide.accessibilityIdentifier = "browser.page.keys.dismiss"
        bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), hide]
        bar.sizeToFit()
        return bar
    }()

    @objc private func hideKeyboard() {
        _ = resignFirstResponder()
    }

    /**
     * Both halves of the responder, overridden for one reason: the chrome above
     * the canvas has to be able to follow it.
     *
     * The keyboard is raised by a tap here and put away from four places — the
     * button above it, a screen leaving, a pane folding, a page being handed
     * back — and the first of those never goes through `command(_:)` at all. So
     * the state is read off the responder itself and announced once, on the
     * edge, rather than tracked by whoever happened to ask for it.
     */
    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { announceTyping(true) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { announceTyping(false) }
        return gave
    }

    private func announceTyping(_ now: Bool) {
        guard typing != now else { return }
        typing = now
        // From a runloop hop and with the surface name copied out, for the two
        // reasons `announce` above hops: the receiver is `@State` on the bar
        // over this canvas and writing it inside a responder change that a
        // SwiftUI update started is the "Modifying state during view update"
        // warning — and a canvas torn down while the keyboard is up still owes
        // that bar the news, after this view is gone.
        let page = target
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: WatchSurface.typingNote, object: page,
                                            userInfo: [WatchSurface.typingKey: now])
        }
    }

    /**
     * Always false, and it is a claim rather than a shortcut.
     *
     * `hasText` asks whether the responder holds text that Backspace would eat.
     * This one holds none — the page does, on the far side of a wire that never
     * says what is in a field. Answering `true` would make the keyboard draw a
     * Backspace that this view would then have to pretend about; answering
     * `false` still delivers `deleteBackward()`, which is forwarded as a real
     * Backspace key and let the page decide whether there was anything to delete.
     */
    var hasText: Bool { false }

    func insertText(_ text: String) {
        guard let frame = lastFrame, !frame.masked else { return }
        if text == "\n" || text == "\r" {
            key("Enter", code: "Enter")
            return
        }
        let cleaned = WatchMath.cleanPaste(text)
        guard !cleaned.isEmpty else { return }
        // `insertText` on the far side, which is what a paste is. It carries a
        // whole string in one frame, which is also what a Chinese or Japanese
        // keyboard hands over when a candidate is chosen — a per-character key
        // event could not express that at all.
        send(.paste(cleaned), seq: frame.seq)
    }

    /**
     * The system keyboard's delete key, sent both ways it could work — and
     * neither of them does, which is written here because the next person to
     * look will otherwise try the same two.
     *
     * The key event is the correct shape and the host drops the half of it that
     * matters; see the file header. The `char` with a `\u{8}` in its `text` is
     * the other thing CDP will take — `Input.dispatchKeyEvent` with `type:
     * 'char'` is how a character is inserted without a key code — and Blink
     * treats a control character in a `char` event as text to insert rather than
     * as an edit, so it does nothing visible either.
     *
     * Both are sent rather than one, because they cost a few bytes each on a
     * keystroke that is already happening and because the day `dispatchKey`
     * learns a virtual key code the first of them starts working with no change
     * here. Nothing is drawn that claims this works: the bar carries no delete
     * key, and this is the system keyboard's own.
     */
    func deleteBackward() {
        key("Backspace", code: "Backspace")
        guard let frame = lastFrame, !frame.masked else { return }
        send(.key(.init(type: .char, key: nil, code: "Backspace", text: "\u{8}", mods: 0)),
             seq: frame.seq)
    }

    /// One key, down then up. Both halves, because a page listening on `keyup`
    /// — which is most search-as-you-type boxes — never hears a key that is only
    /// pressed.
    private func key(_ name: String, code: String) {
        guard let frame = lastFrame, !frame.masked else { return }
        send(.key(.init(type: .down, key: name, code: code, text: nil, mods: 0)), seq: frame.seq)
        send(.key(.init(type: .up, key: name, code: code, text: nil, mods: 0)), seq: frame.seq)
    }

    @objc private func command(_ note: Notification) {
        guard (note.object as? String) == target, let command = WatchSurface.pending else { return }
        WatchSurface.pending = nil
        switch command {
        case .endTyping:
            // Idempotent: a resign on a canvas that is not holding the keyboard
            // does nothing, which is what lets a screen say *stop typing* on its
            // way out without first asking whether anybody was.
            _ = resignFirstResponder()
        }
    }
}

/// How far the viewer will magnify the picture it was sent. Five is where a
/// 1600-pixel render — the host's own ceiling — stops having pixels left to
/// give on a three-times phone screen.
let maxWatchZoom: CGFloat = 5
