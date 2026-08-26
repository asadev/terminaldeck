/**
 * Looking at a page at a size that is not this phone's.
 *
 * > *"they can use the the mode currently we have this machine they can just
 * > browse as phone view and it should have all the by the way views also they
 * > can pinch and zoom also they can see all the different dimensions in
 * > responsive views how it will look like in mobile how it will look like on
 * > Windows so they can have different dimensions also in phone just like
 * > MacBook"*
 *
 * This is the device toolbar every desktop browser has, on the phone that is
 * holding the page. He builds sites and reviews them from the sofa; *"how it
 * will look like on Windows"* is a question he currently has to walk to a laptop
 * to answer.
 *
 * ## What this round changed, and why the old shape was worthless
 *
 * > *"when i make other frame like desktop or laptop biew it is trying to fit
 * > inside the same given space a sphone instead of giving me less hieght and
 * > like actual laptop dimension"*
 *
 * > *"and there are very less options for dimensiins too"*
 *
 * The first version of this file chose a **width** and nothing else. The fitting
 * kept the phone's own height and only narrowed or widened the box:
 *
 * ```
 * web.bounds = CGRect(x: 0, y: 0, width: wanted, height: box.height / scale)
 * ```
 *
 * So *Laptop* drew a 1280-wide column that was as tall as an iPhone is tall,
 * scaled onto the screen — a tall narrow strip of laptop-width text. It answered
 * nothing about how a page behaves on a laptop, which is the entire point of the
 * control, and he said so in the first ten seconds of looking at it.
 *
 * A chosen size is now a **width and a height** — a real device rectangle,
 * scaled by one factor so its proportions survive, drawn with an edge on a
 * tinted ground with room above and below it. A laptop is wide and short. A
 * phone is tall and narrow. That is what the shape is *for*: it is the answer,
 * not the container the answer is drawn in.
 *
 * ## The page has to **believe** it, or the feature is a lie
 *
 * The cheap way to do this is a CSS transform: draw the page at the phone's own
 * width and scale the pixels up or down. It looks right in a screenshot and it
 * is worthless, because the whole question being asked is *does the layout
 * answer* — and a layout answers through `@media (min-width: 1024px)`, which
 * fires off the **viewport**, not off how big the result is drawn. A scaled
 * phone layout is a phone layout with bigger letters.
 *
 * So the size is real, twice over, and the two halves cover different pages:
 *
 *  1. **The web view is genuinely that big.** `LocalhostBrowser`'s surface lays
 *     its `WKWebView` out at `layout` **points** and then scales the *view* — a
 *     UIKit transform on a `UIView`, which the document inside knows nothing
 *     about — to fit the space. For the overwhelming majority of pages, which
 *     declare `width=device-width`, that alone is the whole answer: device-width
 *     **is** 1280 now, `window.innerWidth` is 1280, `window.innerHeight` is 800,
 *     and every media query fires as it would on a laptop.
 *  2. **A viewport the page reads**, for the two kinds of page the first half
 *     does not reach: one that declares no viewport at all — WebKit lays those
 *     out at a fixed 980 CSS px whatever the view's size — and one that declares
 *     a fixed `width=320`. `PageViewportScript` writes a viewport of its own into
 *     the document for those, which is the same instruction a desktop's device
 *     toolbar gives.
 *
 * ## The height is no longer the approximate half — and that is the win
 *
 * The old file carried a paragraph apologising for `100vh`: the viewport was as
 * tall as the phone's aspect ratio made it, so a hero block written to fill a
 * laptop screen overflowed the frame and there was no honest way to tell whether
 * it would have overflowed a laptop. That apology is **deleted rather than
 * moved**, because the thing it apologised for is gone: the web view is
 * 1280 × 800 points, so `100vh` is 800 CSS px, which is what it is on the
 * laptop.
 *
 * ## What it costs instead, written down because somebody will hit it
 *
 * A 1280-wide frame drawn inside roughly 370 points of phone is scaled to about
 * **0.29**, and a `CGAffineTransform` does not change a layer's `contentsScale`
 * — WebKit still rasterises at the full 1280 × 800 at the screen's own scale and
 * the layer is scaled down, so nothing is re-rendered blurrily, but body text
 * lands at roughly a third of its size and is small. That is the trade the
 * shape *is*: you cannot see a laptop's proportions and a laptop's type size at
 * once on a phone. Pinch and the three zoom verbs are the way in — they magnify
 * inside the frame and leave the layout alone, which is exactly what a desktop's
 * device toolbar does at 30%.
 *
 * ## Not measured on a device, and this file says so
 *
 * Written and reasoned against WebKit's documented viewport handling and against
 * UIKit's documented transform rules. The arithmetic in `PageFit` is covered by
 * tests and the shape claim is covered by a UI test that reads the drawn frame
 * back off the screen; what has **not** happened in this pass is somebody
 * holding the phone and looking at a real dev server at 0.29. The legibility
 * paragraph above is arithmetic, not an observation.
 */

import CoreGraphics
import Foundation
import Observation

/*
 * `CoreGraphics` is imported by name rather than left to arrive with Foundation,
 * and that is not tidiness. A size here is a `CGSize`, `PageFit` derives
 * `Equatable` from two of them, and `CGSize`'s own `Equatable` conformance lives
 * in the CoreGraphics overlay: type-checked with only Foundation in scope, this
 * file fails with *type 'PageFit' does not conform to protocol 'Equatable'*, and
 * that was measured here rather than guessed. In the app it would probably
 * compile anyway, because some other file in the module imports UIKit and a
 * conformance is not import-scoped — which is exactly the kind of "probably"
 * that breaks on the day somebody splits a target.
 */

/**
 * The devices on offer.
 *
 * > *"and there are very less options for dimensiins too"*
 *
 * There were four. There are seven, and they are the set a person actually
 * checks a site against: the narrow floor, the two phone classes, a tablet each
 * way up, a laptop and a desktop. Still a list of real ones rather than a
 * slider — *"Many of the even buttons are so much of confusing I can't
 * understand what they mean"* — because a row that reads **Laptop 1280 × 800**
 * is a name he can point at and a number he can check, and a slider from 320 to
 * 2560 is a control that asks him to already know the answer.
 *
 * ## Why these numbers
 *
 * Breakpoint neighbourhoods rather than particular products, because naming a
 * case after a manufacturer dates it the moment a model changes size:
 *
 *  - **320 × 568** — the narrow floor. Every responsive framework's smallest
 *    breakpoint, and still real hardware.
 *  - **390 × 844** — the phone class most people are holding.
 *  - **430 × 932** — the large-phone class, which is where a two-column layout
 *    first tries to appear and usually should not.
 *  - **834 × 1194** and **1194 × 834** — a tablet each way up. Landscape is its
 *    own row rather than only a rotation because *"how does this look on an
 *    iPad"* is nearly always asked about the landscape one, and one tap is the
 *    right price for the common question.
 *  - **1280 × 800** — a laptop's usable browser box, a MacBook Air's.
 *  - **1440 × 900** — the desktop one, where a Windows machine at 1920 puts a
 *    maximised window once its own scaling is applied.
 *
 * The raw value is an ordinal rather than the width, which is a change from the
 * first version of this file and is deliberate: a size now carries two numbers,
 * so a raw value that was one of them would be half a fact wearing the name of
 * the whole. The widths reach the wire through `PageViewportScript`, which asks
 * for them by name.
 */
enum PageDevice: Int, CaseIterable, Identifiable {
    /// This phone's own width and height, laid out and drawn exactly as it
    /// always was: no frame, no edge, no caption. The default, the way back, and
    /// the one state in which nothing in this file touches the page at all.
    case fit = 0
    case smallPhone = 1
    case phone = 2
    case largePhone = 3
    case tablet = 4
    case tabletLandscape = 5
    case laptop = 6
    case desktop = 7

    var id: Int { rawValue }

    /// The rectangle in CSS pixels, or nil for this phone's own.
    var size: CGSize? {
        switch self {
        case .fit: return nil
        case .smallPhone: return CGSize(width: 320, height: 568)
        case .phone: return CGSize(width: 390, height: 844)
        case .largePhone: return CGSize(width: 430, height: 932)
        case .tablet: return CGSize(width: 834, height: 1194)
        case .tabletLandscape: return CGSize(width: 1194, height: 834)
        case .laptop: return CGSize(width: 1280, height: 800)
        case .desktop: return CGSize(width: 1440, height: 900)
        }
    }

    /**
     * What the row says. The device, and nothing else.
     *
     * *"you are also putting so much of a description under the title of that
     * thing… instead of just i button or nothing."* So this is a title: two
     * words at the outside, no sentence, nothing under it. The pixels are the
     * quiet second element of the row (`measure`, drawn faint beside this) and
     * the sentence explaining what any of it does is on the ⓘ, once, for the
     * whole control.
     */
    var name: String {
        switch self {
        case .fit: return "This phone"
        case .smallPhone: return "Small phone"
        case .phone: return "Phone"
        case .largePhone: return "Large phone"
        case .tablet: return "Tablet"
        case .tabletLandscape: return "Tablet landscape"
        case .laptop: return "Laptop"
        case .desktop: return "Desktop"
        }
    }

    /// The pixels, for the quiet half of the row. Nil for this phone, whose size
    /// is whatever the phone is and is not a fact worth printing.
    var measure: String? {
        guard let size else { return nil }
        return PageSize.pixels(size)
    }

    /**
     * The row this one turns into when it is put on its side, where that row
     * already exists.
     *
     * Only the tablet has one, and having it is what stops the menu growing a
     * state you can reach two ways. Without this mapping, *Tablet* + *Rotate*
     * and *Tablet landscape* would draw the identical 1194 × 834 rectangle while
     * ticking different rows — two names for one shape, which is the shape of
     * every menu he has ever called confusing. With it, rotation of a tablet
     * **lands on the listed row**, and `PageSize.turned` is only ever true for
     * the devices that have no listed twin. `LocalhostChromeTests` holds that
     * invariant: no two reachable sizes draw the same rectangle.
     */
    var turnedTwin: PageDevice? {
        switch self {
        case .tablet: return .tabletLandscape
        case .tabletLandscape: return .tablet
        default: return nil
        }
    }

    /// The stable half of an accessibility identifier — `localhost.size.laptop`.
    /// Written out rather than reflected off the case name, because a test that
    /// depends on `String(describing:)` depends on a compiler detail.
    var key: String {
        switch self {
        case .fit: return "fit"
        case .smallPhone: return "smallphone"
        case .phone: return "phone"
        case .largePhone: return "largephone"
        case .tablet: return "tablet"
        case .tabletLandscape: return "tabletlandscape"
        case .laptop: return "laptop"
        case .desktop: return "desktop"
        }
    }
}

/**
 * One chosen size: a device, and whether it is on its side.
 *
 * A pair rather than a longer enum, because the alternative was thirteen cases —
 * every device and its rotation — in a menu he has twice asked to be made
 * shorter. Seven rows and one *Rotate* is the same set of shapes and half the
 * reading.
 *
 * `turned` is forced false for `fit` in the initialiser rather than merely
 * ignored: this phone on its side is this phone, the row is not offered when
 * there is no frame to turn, and a stored `true` that nothing can act on is a
 * fact waiting to be read by mistake.
 */
struct PageSize: Equatable {
    var device: PageDevice
    var turned: Bool

    init(_ device: PageDevice, turned: Bool = false) {
        self.device = device
        self.turned = device == .fit ? false : turned
    }

    /// Where everything starts and the way back: this phone's own width and
    /// height, with nothing drawn around the page.
    static let fit = PageSize(.fit)

    /// The rectangle to lay the page out in, in CSS pixels — or nil for this
    /// phone's own, which is the state in which no frame is drawn at all.
    var layout: CGSize? {
        guard let size = device.size else { return nil }
        return turned ? CGSize(width: size.height, height: size.width) : size
    }

    /// The pixels as they stand, which is what the caption under the frame says.
    /// Nil for this phone.
    var measure: String? {
        guard let layout else { return nil }
        return Self.pixels(layout)
    }

    /// `1280 × 800`. A multiplication sign rather than an `x`, because this is
    /// the one place in the feature that prints a dimension and it should look
    /// like the dimension it is.
    ///
    /// Named `pixels` rather than `measure` so that it cannot be confused with
    /// the instance property above it: a static function and an instance
    /// property sharing a base name compile, and then somebody writes
    /// `Self.measure(x)` and the overload that gets picked depends on the
    /// argument's type. That is a coin toss written as code.
    static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /**
     * The same device, on its side.
     *
     * A tablet lands on the listed landscape row and back; everything else flips
     * its own flag. See `PageDevice.turnedTwin` for why that asymmetry exists —
     * it is what keeps one rectangle to one row.
     *
     * This phone turns into itself. The row is not drawn in that state, so this
     * is the belt to the menu's braces rather than a path anybody takes.
     */
    func turnedOver() -> PageSize {
        guard device != .fit else { return self }
        if let twin = device.turnedTwin { return PageSize(twin) }
        return PageSize(device, turned: !turned)
    }

    // MARK: - On disk

    /**
     * One integer, because the store writes one dictionary.
     *
     * The device in the high bits and the rotation in the low one. Two
     * `UserDefaults` dictionaries — one of devices, one of flags — would be two
     * things that can disagree with each other, and the disagreement would show
     * up as a page drawn portrait with the landscape row ticked.
     */
    var stored: Int { device.rawValue << 1 | (turned ? 1 : 0) }

    init?(stored: Int) {
        guard stored >= 0, let device = PageDevice(rawValue: stored >> 1) else { return nil }
        self.init(device, turned: stored & 1 == 1)
    }
}

/**
 * How a chosen rectangle is drawn into the space this screen has.
 *
 * The whole of *"like actual laptop dimension"* is these six lines, so they live
 * in a value type a test can hold rather than inside a `layoutSubviews` nobody
 * can call. `LocalhostBrowser` builds one per redraw from the geometry it is
 * given and hands the halves to two different places: `drawn` sizes the SwiftUI
 * frame that gets the edge and the shadow, `layout` goes to the web view as its
 * real point size.
 *
 * ## One scale, both axes
 *
 * The old code divided width by width and let the height be whatever was left,
 * which is precisely how a laptop came out phone-shaped. This takes the smaller
 * of the two ratios, so the rectangle keeps its proportions and fits inside the
 * space on the axis that binds first: a laptop binds on **width** and leaves
 * ground above and below it; a phone binds on **height** and leaves ground to
 * either side.
 *
 * ## Never bigger than life
 *
 * The scale is capped at 1. A 320 × 568 frame on a 390-point phone would
 * otherwise be blown up to 1.14 and read as *bigger* than the phone holding it,
 * which is the opposite of true — a small phone is narrower than his. Capped, it
 * sits at life size with a strip of ground either side, and the strip is the
 * fact: that is how much narrower.
 *
 * ## The margins are part of the picture
 *
 * `margin` is the ground that makes the frame read as a device sitting on
 * something rather than as a layout that broke, and `caption` is the line under
 * it that says the pixels. Both are taken out of the space **before** the scale
 * is worked out, so the caption can never be pushed off the bottom by a frame
 * that fits without it.
 */
struct PageFit: Equatable {
    /// The CSS pixels the web view is really laid out at.
    let layout: CGSize
    /// The points it is drawn in on this phone's screen.
    let drawn: CGSize
    /// `drawn / layout`, on both axes. Never above 1.
    let scale: CGFloat

    /// Ground around the frame, per edge.
    static let margin: CGFloat = 12
    /// Room kept under the frame for the line that says the pixels.
    static let caption: CGFloat = 22

    /// Nil exactly when the size is `fit` — this phone's own, which is drawn
    /// full-bleed with no frame at all. A box too small to hold anything still
    /// returns a fit, clamped to a point: a nil there would flip the screen from
    /// framed to unframed for one layout pass and back, which is a web view
    /// changing size twice for nothing.
    init?(_ size: PageSize, in box: CGSize) {
        guard let layout = size.layout, layout.width > 0, layout.height > 0 else { return nil }
        let room = CGSize(width: max(box.width - Self.margin * 2, 1),
                          height: max(box.height - Self.margin * 2 - Self.caption, 1))
        let scale = min(1, min(room.width / layout.width, room.height / layout.height))
        self.layout = layout
        // Rounded, so the edge lands on a whole point rather than being drawn
        // across two of them. It costs less than a point of aspect ratio, and
        // `ScaledPageView` takes the smaller of the two ratios back out so the
        // rounding can only ever tuck the page in, never crop it.
        self.drawn = CGSize(width: (layout.width * scale).rounded(),
                            height: (layout.height * scale).rounded())
        self.scale = scale
    }
}

/**
 * Which size each site was last looked at in.
 *
 * Deliberately **not** `@MainActor`, for the reason `BrowserHistory` writes out
 * at length: a screen holds one of these as a default argument on a memberwise
 * initialiser, and default arguments are evaluated in a non-isolated context.
 *
 * ## Why a site and not a URL
 *
 * *Per page* is the ask, and a literal reading of it would be forgotten by the
 * first link. Everything this feature exists to look at is a dev server, every
 * dev server serves a single-page app, and every route change in one rewrites the
 * URL — that is not a guess, it is the fact `LocalhostBrowser.seed` is built
 * around and the reason the address field is seeded rather than bound. A memory
 * keyed on the whole address would drop back to the phone's size the moment he
 * clicked *Orders*, in the middle of checking how Orders looks on a laptop.
 *
 * So the key is the site as he thinks of it — `localhost:3000`, `app.example.com`
 * — which is stable across the route changes *and* across closing the window and
 * opening it again. The tunnel's own loopback port is never it: this phone picks
 * that number at random on every open, so a memory keyed on it would be a memory
 * that never matched twice.
 */
@Observable
final class PageWidths {

    /// The one the screens read. A property of *this phone*, beside
    /// `BrowserHistory.shared`.
    static let shared = PageWidths()

    /**
     * How many sites are remembered.
     *
     * Bounded by where it lives rather than by what anybody wants: this is read
     * whole at launch and written whole on every change, at roughly 30 bytes a
     * row. Sixty sites is more dev servers than one phone sees in a month, and
     * the oldest choice falling off is a page reverting to this phone's own size,
     * which is the state it started in.
     */
    static let maxSites = 60

    private let defaults: UserDefaults
    /**
     * `v2`, and the `v1` rows are abandoned rather than migrated.
     *
     * A `v1` value was a CSS width — `1280` — and a `v2` value is a device
     * ordinal with a rotation bit, so `1280` read as `v2` is device 640, which is
     * no device at all and would be dropped by the loader anyway. Reading the old
     * key and mapping four widths onto four devices is possible and is not worth
     * a line of code that has to be right forever: what is lost is which of his
     * dev servers he last looked at on a laptop, the wrong answer is the default
     * he started from, and the first tap fixes it.
     */
    private static let storageKey = "terminaldeck.pageSizes.v2"

    /// site → packed size. Insertion order is not kept; `order` is what ages rows
    /// out, because a `Dictionary` has no order to trust.
    private var chosen: [String: Int] = [:]
    /// Sites in the order they were last chosen for, oldest first.
    private var order: [String] = []

    /// `defaults` is a seam for the tests, which run against their own suite so a
    /// test run cannot write onto the machine it is running from — the same
    /// arrangement `PortBook` and `BrowserHistory` use.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// What this site was last looked at in. `fit` for one never chosen for, and
    /// for the empty key — a page with no site is a page nothing can be
    /// remembered about, and it is a real state (`about:blank`, a failed load).
    func size(for site: String) -> PageSize {
        guard !site.isEmpty, let raw = chosen[site] else { return .fit }
        return PageSize(stored: raw) ?? .fit
    }

    /**
     * Remember a choice.
     *
     * `fit` is stored like any other rather than removed, because *back to this
     * phone* is a choice somebody made and a forgotten row would read as one they
     * never made — which matters only in that it would age a different site out
     * of the list. It costs one integer.
     */
    func choose(_ size: PageSize, for site: String) {
        guard !site.isEmpty else { return }
        chosen[site] = size.stored
        order.removeAll { $0 == site }
        order.append(site)
        while order.count > Self.maxSites, let oldest = order.first {
            order.removeFirst()
            chosen[oldest] = nil
        }
        save()
    }

    /**
     * The site a page belongs to, spelled the way the address field spells it.
     *
     * A loopback page is named by the port **on the machine** — the number he
     * chose and can act on — for the same reason `BrowserChrome.shownAddress`
     * shows that one: the phone's own listener port is picked at random per open
     * and names nothing. Anything else is named by its host, lowercased, so that
     * `Example.com` and `example.com` are one site.
     */
    static func site(_ address: String, machinePort: Int) -> String {
        guard let url = URL(string: address), let host = url.host(), !host.isEmpty else { return "" }
        if BrowserChrome.isLoopback(host) { return "localhost:\(machinePort)" }
        return host.lowercased()
    }

    // MARK: - Disk

    private func load() {
        guard let raw = defaults.dictionary(forKey: Self.storageKey) else { return }
        var kept: [String: Int] = [:]
        for (site, value) in raw {
            guard !site.isEmpty, site.count <= 200 else { continue }
            // A number that is not one of ours is dropped rather than clamped: a
            // size this build does not offer is not a size, and drawing the menu
            // with nothing ticked is worse than starting from the default.
            guard let number = value as? Int, PageSize(stored: number) != nil else { continue }
            kept[site] = number
        }
        chosen = kept
        // The order is not persisted — it is only an ageing hint, and a stored
        // one would be a second thing that can disagree with the first. On a
        // fresh launch every remembered site is equally old, which is true.
        order = Array(kept.keys)
    }

    private func save() {
        defaults.set(chosen, forKey: Self.storageKey)
    }
}

/**
 * The viewport this app writes into a page that is being looked at at another
 * size.
 *
 * Runs in `WKContentWorld.defaultClient` like every other script this app
 * injects, so the page can neither see nor call it.
 *
 * ## Width only, and the height is not missing
 *
 * A viewport meta can carry a `height`, and this one does not, because the
 * height is not a thing the page has to be *told* any more: the web view is
 * genuinely 800 points tall in a laptop frame, so `innerHeight` is 800 and
 * `100vh` is 800 without anybody writing it down. `height` in a viewport meta is
 * a legacy key WebKit treats as advisory at best; writing an advisory copy of a
 * fact that is already true is how the two come to disagree.
 *
 * ## What it does and does not touch
 *
 * Nothing at all until a size other than *this phone* is chosen. A page that is
 * never resized is a page this script has not written a node into, which keeps
 * the ordinary path byte-identical to what it was before this feature existed.
 *
 * Once it has written one, going back to *this phone* sets our own meta to
 * `width=device-width, initial-scale=1` **and then removes it**. Both, in that
 * order, on purpose: WebKit recomputes the viewport when a meta's `content`
 * changes, and whether it does so when the element is removed is not a thing to
 * bet a screen on. Setting first means the correct state is already in force
 * whichever way removal behaves.
 *
 * The one honest cost: a page that declares a fixed `width=320` of its own — a
 * legacy mobile site — comes back at device-width rather than at 320 after
 * somebody has used this control on it. Reloading restores it, and no dev server
 * anybody is building against writes that meta any more.
 */
enum PageViewportScript {

    /// Defines the hook and stops. Nothing is written into the document until
    /// `apply` is evaluated against it.
    static let source = """
    'use strict';
    (function () {
      if (window.__terminaldeckViewport) return;
      var ours = null;

      function meta() {
        if (ours && ours.isConnected) return ours;
        var tag = document.querySelector('meta[data-terminaldeck-viewport]');
        if (!tag) {
          tag = document.createElement('meta');
          tag.setAttribute('name', 'viewport');
          tag.setAttribute('data-terminaldeck-viewport', '');
        }
        /* Last in the head wins: WebKit reads every viewport meta in document
           order and later keys override earlier ones, so ours has to be appended
           rather than inserted. documentElement is the fallback for a document
           whose head has not been parsed yet — a document-start script can run
           before it exists. */
        var parent = document.head || document.documentElement;
        if (parent && tag.parentNode !== parent) parent.appendChild(tag);
        ours = tag;
        return tag;
      }

      window.__terminaldeckViewport = {
        apply: function (width) {
          var w = typeof width === 'number' && isFinite(width) ? Math.round(width) : 0;
          if (w > 0) {
            /* Zooming is never switched off here, and the test one file over
               greps this very script to prove it. Pinch is half of what this
               control is for: a page being examined at 29% is exactly the page
               somebody needs to get close to. Written without naming the
               attribute that would do it, because a grep cannot tell a promise
               from a breach. */
            meta().setAttribute('content', 'width=' + w + ', initial-scale=1');
            return;
          }
          if (!ours) return;
          ours.setAttribute('content', 'width=device-width, initial-scale=1');
          if (ours.parentNode) ours.parentNode.removeChild(ours);
          ours = null;
        }
      };
    })();
    """

    /// The call that puts one size in force on the document that is loaded now.
    /// Zero is *this phone*, which is the state that clears the meta again.
    static func apply(_ size: PageSize) -> String {
        let width = Int((size.layout?.width ?? 0).rounded())
        return "window.__terminaldeckViewport && window.__terminaldeckViewport.apply(\(width))"
    }
}
