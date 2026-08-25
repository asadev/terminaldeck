/**
 * Looking at a page at a width that is not this phone's.
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
 * ## The page has to **believe** it, or the feature is a lie
 *
 * The cheap way to do this is a CSS transform: draw the page at the phone's own
 * width and scale the pixels up or down. It looks right in a screenshot and it
 * is worthless, because the whole question being asked is *does the layout
 * answer* — and a layout answers through `@media (min-width: 1024px)`, which
 * fires off the **viewport**, not off how big the result is drawn. A scaled
 * phone layout is a phone layout with bigger letters.
 *
 * So the width is real, twice over, and the two halves cover different pages:
 *
 *  1. **The web view is genuinely that wide.** `LocalhostBrowser`'s surface lays
 *     its `WKWebView` out at `points` and then scales the *view* — a UIKit
 *     transform on a `UIView`, which the document inside knows nothing about — to
 *     fit the screen. For the overwhelming majority of pages, which declare
 *     `width=device-width`, that alone is the whole answer: device-width **is**
 *     1440 now, `window.innerWidth` is 1440, and every media query fires as it
 *     would on a laptop.
 *  2. **A viewport the page reads**, for the two kinds of page the first half
 *     does not reach: one that declares no viewport at all — WebKit lays those
 *     out at a fixed 980 CSS px whatever the view's size — and one that declares
 *     a fixed `width=320`. `PageViewportScript` writes a viewport of its own into
 *     the document for those, which is the same instruction a desktop's device
 *     toolbar gives.
 *
 * ## Not measured on a device, and this file says so
 *
 * Written and reasoned against WebKit's documented viewport handling; the render
 * itself has not been looked at on hardware in this pass. What is *known* rather
 * than assumed is the shape of the trade below, which is arithmetic.
 *
 * ## The viewport is as tall as the phone, and that is a deliberate trade
 *
 * A laptop window is 1440 × 900. Scaled to fit a phone's width, a 1440 × 900
 * rectangle occupies about a quarter of the screen and leaves the rest of it
 * empty — you would be reading a postage stamp with a wall of background around
 * it. So the height is filled instead: the page gets a 1440-wide viewport that is
 * as tall as the phone's aspect ratio makes it, which is an unusually tall
 * desktop window and nothing stranger than that.
 *
 * What it costs is honest and worth writing down: `100vh` blocks come out taller
 * than they would on a laptop, so a hero section that fills a laptop screen will
 * overflow this one. Width is what responsive layout keys off and width is exact;
 * height is the half that is approximate here.
 */

import Foundation
import Observation

/**
 * The widths on offer, and their names.
 *
 * A short list of real ones rather than a slider. *"Many of the even buttons are
 * so much of confusing I can't understand what they mean"* — a row that reads
 * **Laptop 1280** is a name he can point at and a number he can check; a slider
 * from 320 to 2560 is a control that asks him to know what the answer is.
 *
 * The raw value is the width itself, so there is no second table mapping cases to
 * numbers that could drift from the names.
 *
 * The four sizes are the standard breakpoint neighbourhoods rather than
 * particular products: 390 is the iPhone class, 834 the iPad class, 1280 the
 * laptop class — a MacBook Air's usable browser width — and 1440 the desktop one,
 * which is where a Windows machine at 1920 puts a maximised window once its own
 * scaling is applied. Naming a case after a manufacturer would date the moment a
 * model changed size.
 */
enum PageWidth: Int, CaseIterable, Identifiable {
    /// The phone's own width, laid out and drawn exactly as it always was. The
    /// default, and the one state in which nothing here touches the page at all.
    case fit = 0
    case phone = 390
    case tablet = 834
    case laptop = 1280
    case desktop = 1440

    var id: Int { rawValue }

    /// The CSS width to lay the page out at, or nil for this phone's own.
    var points: CGFloat? { rawValue == 0 ? nil : CGFloat(rawValue) }

    /**
     * What the row says, and all it says.
     *
     * One line, a name and — where there is one — the number that name means.
     * No second line under it: *"you are also putting so much of a description
     * under the title of that thing… instead of just i button or nothing."* The
     * sentence explaining what any of this does is on the ⓘ, once, for the whole
     * control.
     */
    var name: String {
        switch self {
        case .fit: return "This phone"
        case .phone: return "Phone 390"
        case .tablet: return "Tablet 834"
        case .laptop: return "Laptop 1280"
        case .desktop: return "Desktop 1440"
        }
    }
}

/**
 * Which width each site was last looked at in.
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
 * keyed on the whole address would drop back to the phone's width the moment he
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
     * the oldest choice falling off is a page reverting to this phone's width,
     * which is the state it started in.
     */
    static let maxSites = 60

    private let defaults: UserDefaults
    private static let storageKey = "terminaldeck.pageWidths.v1"

    /// site → raw width. Insertion order is not kept; `order` is what ages rows
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
    func width(for site: String) -> PageWidth {
        guard !site.isEmpty, let raw = chosen[site] else { return .fit }
        return PageWidth(rawValue: raw) ?? .fit
    }

    /**
     * Remember a choice.
     *
     * `fit` is stored like any other rather than removed, because *back to this
     * phone* is a choice somebody made and a forgotten row would read as one they
     * never made — which matters only in that it would age a different site out
     * of the list. It costs one integer.
     */
    func choose(_ width: PageWidth, for site: String) {
        guard !site.isEmpty else { return }
        chosen[site] = width.rawValue
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
            // width this build does not offer is not a width, and drawing the
            // menu with nothing ticked is worse than starting from the default.
            guard let number = value as? Int, PageWidth(rawValue: number) != nil else { continue }
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
 * width.
 *
 * Runs in `WKContentWorld.defaultClient` like every other script this app
 * injects, so the page can neither see nor call it.
 *
 * ## What it does and does not touch
 *
 * Nothing at all until a width other than *this phone* is chosen. A page that is
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
            /* No user-scalable=no, ever. Pinch is half of what this control is
               for, and a page that is being examined is exactly the page
               somebody needs to zoom into. */
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

    /// The call that puts one width in force on the document that is loaded now.
    static func apply(_ width: PageWidth) -> String {
        "window.__terminaldeckViewport && window.__terminaldeckViewport.apply(\(width.rawValue))"
    }
}
