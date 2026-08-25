/**
 * More than one page open at once, on a phone that can only bind a port once.
 *
 * Asad, on how far short the phone's browser falls of the one on the desktop:
 * *"browser options are also super basic right now… we have profile, password,
 * cookies, everything and a lot of other features. So it should be all same"* —
 * and, naming this one: *"it should have all those options — to start a new
 * windows thing should be there."*
 *
 * The phone opens exactly one page. `LocalhostPortsView` holds a single
 * `browsing: PortTunnel?`, a tap replaces whatever was there, and going back
 * throws the page away — so reading a dashboard on `:3000` and glancing at the
 * API on `:8080` costs you the dashboard. This is the object that holds several
 * of them instead.
 *
 * ## The constraint that decides the whole design
 *
 * A tunnel **binds the machine's own port number on this phone's loopback**, and
 * it has to: a dev server writes absolute URLs into its own output — a redirect
 * to `http://localhost:3000/login`, a hot-reload socket at `ws://localhost:3000`
 * — and every one of those escapes a tunnel served on a different number. See
 * `PortTunnel.bind`, which asks whether the address already answers and refuses
 * rather than quietly half-working when it does.
 *
 * So **a second tunnel on port 3000 cannot exist**. Not "should not": the bind
 * is refused, by design, and the honest sentence about it is already written.
 * Which means a tab cannot own a tunnel. It can only own a *claim* on one.
 *
 * ## A tab is a (port, path) pair, and the live tunnels are a set of ports
 *
 * Two tabs on `3000` — one on `/`, one on `/admin` — are **one** tunnel, shared.
 * A tab on `5173` is a second tunnel. Closing one of the two `3000` tabs closes
 * nothing; closing the last one closes the tunnel.
 *
 * That is a reference count, and reference counts are where this kind of object
 * goes wrong: an increment on one path, a decrement on another, and one code
 * path that forgets — after which either a socket is held open on somebody's
 * machine forever, or a live page's tunnel is pulled out from under it.
 *
 * **So nothing here counts.** After every change to the tab list, `reconcile`
 * derives the set of ports the tabs need — `Set(tabs.map(\.port))` — and closes
 * every live tunnel whose port is not in it. The rule at the top of this comment
 * is not implemented; it is a *consequence* of set membership, which cannot fall
 * out of step with the list it is computed from. There is one place to read to
 * know when a tunnel closes, and it is four lines long.
 *
 * ## Keyed by machine, and only one machine's tabs are live
 *
 * Asad's rule for the split this app lives on: *"whatever cannot be linked, it
 * can be only here also… that can be native only for this application, for that
 * server only specific."* A tab is the phone's own — the machine has its own
 * browser and its own tabs — so this is `PortBook`'s and `BrowserHistory`'s
 * shape: keyed on the stable host id, so a phone paired with a Mac and a Hetzner
 * box does not show one's tabs while the other is connected.
 *
 * The port constraint bites again across machines, and harder. `localhost:3000`
 * on the Mac and `localhost:3000` on the Windows PC are two unrelated servers
 * that want the same socket on this phone, and only one of them can have it. So
 * **the tabs of the machine you switched away from are parked**: their rows,
 * their paths and their titles are kept, their tunnels are released, and the
 * tunnel comes back when you switch back and tap the tab. Anything else would
 * mean tapping a port on the machine in front of you and being told the port is
 * busy — because a machine in another room is still holding it.
 *
 * Parked tunnels are stopped **directly**, through `PortTunnel.stop()`, and not
 * through `TunnelSource.closeLocalhost(port:)`. That is not a shortcut, it is
 * the only correct call: `DeckModel` is a façade over *whichever machine is
 * current*, and by the time a switch is noticed the current machine is the new
 * one — so asking it to close port 3000 would close the wrong machine's tunnel
 * and leave the old one's bound. A `PortTunnel` holds the wire it was built
 * with, so `stop()` reaches the machine that actually owns it. On the ordinary
 * path — closing a tab on the machine you are looking at — the source *is* the
 * right machine, and it is asked, so its own map does not fill with corpses.
 *
 * ## Why the tabs are not written to disk
 *
 * `PortBook` and `BrowserHistory` both persist and this deliberately does not.
 * A tab restored at launch is one of two things and neither is acceptable: a row
 * that looks live and is not, or — worse — a tunnel opened on somebody's machine
 * at app start with nobody's finger behind it. **The tap is the consent** is the
 * rule the whole localhost feature is built on (see `HostLink.openLocalhost`),
 * and a session restorer is precisely a thing that acts without one. Where you
 * were last week is a question `BrowserHistory` already answers, on disk, with a
 * tap between it and a socket.
 */

import Foundation
import Observation

/**
 * The machine, as this object needs it: a name to key tabs under and two verbs.
 *
 * A protocol rather than `DeckModel` itself, so the counting above can be proven
 * against a fake in a unit test with no socket, no host and no simulator — the
 * same seam `PortTunnel` takes as `TunnelWire`. `DeckModel` conforms at the foot
 * of this file and adds nothing, because the two verbs are already its own.
 */
@MainActor
protocol TunnelSource: AnyObject {
    /// Which machine is current, as the stable id everything else in this app
    /// keys machines by — see `DeckEndpoint.hostId`. Empty when none is.
    var hostId: String { get }
    /// Open the machine's tunnel for this port, or hand back the one already on
    /// it. Nil when the machine refused — it has written its own sentence into
    /// `lastError` by then, which the Browser screen's banner draws.
    func openLocalhost(port: Int) -> PortTunnel?
    /// Close the tunnel on this port. Called only when the last tab on it goes.
    func closeLocalhost(port: Int)
}

/**
 * One open page.
 *
 * `port` is immutable and `path` is not, and that asymmetry is the tunnel rule
 * written into the type: a page can navigate anywhere within its own origin, and
 * it cannot navigate *off* it — a link to another port on the machine is a port
 * this phone has not bound, so it is refused by the loopback stack rather than
 * by anything here. A tab is on one port for its whole life.
 */
struct BrowserTab: Identifiable {

    /// Stable for the tab's whole life. Not `"\(port)\(path)"` — which is what
    /// `BrowserHistory.Visit` uses — because that string is the *page*, and this
    /// has to survive the page changing under it.
    let id: String
    /// Which machine's tab this is. Carried on the value so a tab can never be
    /// asked for a tunnel belonging to a different machine; see `tunnel(for:)`.
    let host: String
    let port: Int

    /// Always begins with `/`, and carries the query and the fragment when there
    /// were any — the same string `LocalhostAddress` produces and the same one
    /// `LocalhostBrowser` resolves against the tunnel's origin. Follows the page
    /// as it navigates, so re-entering a tab comes back where you left it.
    /// Settable by the store that owns the list — `private(set)` blocked the very
    /// object that is meant to move it, which is the wrong direction for a value
    /// type whose only writer is `BrowserTabs.mutate`.
    var path: String

    /// What the document calls itself, or empty until it has said. Empty is a
    /// normal state and not a missing one: a document has no title until it has
    /// loaded. Bounded and stripped on the way in — it is a string a web page
    /// chose, landing on this app's own chrome. See `label`.
    var title: String

    /**
     * What the strip draws.
     *
     * The page's own title once it has one, and the address until then — the
     * same fallback `LocalhostBrowser.title` makes, and for the same reason:
     * "Untitled" tells nobody which of their servers they are looking at.
     *
     * `String(port)`, never the Int interpolated. A port dropped straight into a
     * Swift string is formatted with the locale's grouping separator and comes
     * out as `localhost:3,000`.
     */
    var label: String {
        if !title.isEmpty { return title }
        return path == "/" ? "localhost:\(String(port))" : "localhost:\(String(port))\(path)"
    }
}

/**
 * Identity, and only identity.
 *
 * The same trade `PortTunnel` makes for the same reason (see `DeckChrome`): this
 * value is what `LocalhostPortsView` hands to `navigationDestination(item:)`, and
 * a synthesised `==` over every field would make the pushed page tear itself
 * down and rebuild the moment a title arrived from the document — which is a
 * second or so after every navigation.
 */
extension BrowserTab: Hashable {
    static func == (left: BrowserTab, right: BrowserTab) -> Bool { left.id == right.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/**
 * Has this tunnel settled into `.ended`?
 *
 * Here rather than on `PortTunnel` because it is this file's question: a tunnel
 * that has ended is one this object must ask the machine to open again rather
 * than hand to a tab as though it were live. `phase` is `private(set)`, so
 * reading it from here is exactly as intended.
 */
extension PortTunnel {
    var hasEnded: Bool {
        if case .ended = phase { return true }
        return false
    }
}

@MainActor
@Observable
final class BrowserTabs {

    /**
     * The most tabs one machine may hold open.
     *
     * The number that matters is not this one — it is the count of *distinct
     * ports* among them, because each of those is a listener bound on this phone
     * and a socket held open on the machine. Twelve tabs is the loosest cap that
     * cannot get there by accident, and it is also about where a strip stops
     * being something you scan and starts being something you search.
     *
     * A refusal rather than an eviction. Silently closing somebody's oldest page
     * to make room for a new one is the app throwing away work nobody asked it
     * to throw away; a sentence and a tap on a close button is not.
     */
    static let capacity = 12

    /**
     * Why the last open was refused, or nil. Cleared at the top of every open.
     *
     * Only ever set for a refusal *this object* decided. A machine that refuses
     * the tunnel has already written its own sentence into `HostLink.lastError`,
     * which the Browser screen draws in its banner — two sentences about one
     * press, in two places, is the duplication this app keeps arguing against.
     */
    private(set) var notice: String?

    /// host id → its tabs, in the order they were opened. Nested by host for the
    /// reason `PortBook` nests: two machines' port 3000s are unrelated pages.
    private var byHost: [String: [BrowserTab]] = [:]

    /**
     * The tunnels that exist right now, by port — **for one machine only**.
     *
     * The whole of the reference count, and it is not a count. A port is in here
     * because at least one tab of `liveHost` is on it, and `reconcile` is the
     * only thing that adds to or removes from it.
     */
    private var live: [Int: PortTunnel] = [:]

    /// Which machine `live` belongs to. Nil before the first open.
    private var liveHost: String?

    // MARK: - Reading

    /// One machine's tabs, in the order they were opened.
    func tabs(on machine: TunnelSource) -> [BrowserTab] {
        byHost[machine.hostId] ?? []
    }

    /// One tab by its id, or nil once it has been closed.
    func tab(_ id: String) -> BrowserTab? {
        for list in byHost.values {
            if let found = list.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /**
     * The tunnel this tab's page rides, or nil.
     *
     * A pure lookup with no side effect of any kind, because the one caller is
     * inside a SwiftUI `navigationDestination` builder and a view body that
     * opens a socket is a view body that opens a socket several times.
     * `resume(_:machine:)` is the version that may act, and it is called from a
     * tap.
     *
     * Nil for a parked tab — one belonging to a machine that is not the live one
     * — which is why `host` is on the value at all.
     */
    func tunnel(for tab: BrowserTab) -> PortTunnel? {
        guard tab.host == liveHost else { return nil }
        guard let tunnel = live[tab.port], !tunnel.hasEnded else { return nil }
        return tunnel
    }

    /// How many of one machine's tabs are on a port. The rule at the top of this
    /// file stated as a number, for the tests that pin it.
    func count(onPort port: Int, of machine: TunnelSource) -> Int {
        tabs(on: machine).filter { $0.port == port }.count
    }

    /// How many tunnels are bound right now. Never more than the number of
    /// distinct ports among the live machine's tabs, and the tests say so.
    var openTunnels: Int { live.count }

    // MARK: - Opening

    /**
     * Open a page, and hand back the tab it is in.
     *
     * Nil means nothing was pushed and nothing should be: either this object
     * refused, in which case `notice` says why, or the machine did, in which case
     * it has already said so in the banner.
     *
     * A page that is **already open in a tab is not opened twice**. Five taps on
     * the port 3000 row are one tab, not five identical ones — the port list is
     * the main way into this screen and a browser that grows a twin every time
     * somebody double-taps a row is a browser nobody can find anything in. The
     * match is on the tab's *current* address rather than on where it was
     * opened, so a tab that has already navigated to `/admin` is the tab you get
     * when you type `/admin`.
     */
    @discardableResult
    func open(port: Int, path rawPath: String = "/", machine: TunnelSource) -> BrowserTab? {
        notice = nil
        let host = machine.hostId
        guard !host.isEmpty else { return nil }

        guard port > 0, port <= 65_535 else {
            notice = "\(String(port)) is not a port this phone can open."
            return nil
        }
        guard let path = Self.normalised(rawPath) else {
            // Refused rather than cut, the same way `BrowserHistory` refuses one:
            // a truncated path is an address for a different page, so the tab
            // would open something other than what was asked for.
            notice = "That address is too long to open."
            return nil
        }

        adopt(machine)

        var list = byHost[host] ?? []
        if let existing = list.first(where: { $0.port == port && $0.path == path }) {
            guard ensureTunnel(port: port, machine: machine) != nil else { return nil }
            return existing
        }

        guard list.count < Self.capacity else {
            notice = "\(String(Self.capacity)) tabs are already open. Close one first."
            return nil
        }
        // The tunnel first, and the tab only if it came up. A tab whose page can
        // never load is a row that does nothing when it is tapped.
        guard ensureTunnel(port: port, machine: machine) != nil else { return nil }

        let tab = BrowserTab(id: UUID().uuidString, host: host, port: port, path: path, title: "")
        list.append(tab)
        byHost[host] = list
        return tab
    }

    /**
     * Go back to a tab that is already open.
     *
     * The same act as opening — it re-binds the port when the tab has been
     * parked by a machine switch, or when its tunnel ended while nobody was
     * looking — but addressed by the tab rather than by an address, so a tab
     * that has navigated somewhere comes back where it is rather than where it
     * started. Hands back the *current* value of the tab, which is what the
     * screen pushes.
     */
    @discardableResult
    func resume(_ tab: BrowserTab, machine: TunnelSource) -> BrowserTab? {
        notice = nil
        guard tab.host == machine.hostId else { return nil }
        guard let current = byHost[tab.host]?.first(where: { $0.id == tab.id }) else { return nil }
        adopt(machine)
        guard ensureTunnel(port: current.port, machine: machine) != nil else { return nil }
        return current
    }

    // MARK: - Closing

    /**
     * Close one tab.
     *
     * Whether that closes a tunnel is not decided here and is not decided
     * anywhere: `reconcile` recomputes which ports are still wanted and the
     * answer falls out. Two tabs on 3000 and one goes — 3000 is still wanted,
     * nothing happens to the socket, and the page in the other tab does not
     * flinch.
     */
    func close(_ tab: BrowserTab, machine: TunnelSource) {
        guard var list = byHost[tab.host] else { return }
        list.removeAll { $0.id == tab.id }
        if list.isEmpty { byHost.removeValue(forKey: tab.host) } else { byHost[tab.host] = list }
        // Only the live machine's tunnels can be reconciled against a source —
        // see the header on why a parked machine's are stopped directly instead.
        guard tab.host == machine.hostId else { return }
        adopt(machine)
        reconcile(machine)
    }

    /// Close every tab on one machine, and with them every tunnel it was holding.
    func closeAll(machine: TunnelSource) {
        byHost.removeValue(forKey: machine.hostId)
        adopt(machine)
        reconcile(machine)
    }

    // MARK: - What the page says about itself

    /**
     * The page navigated. Told by `LocalhostBrowser`, which is watching its web
     * view's `url` — the same signal that feeds `BrowserHistory.record`.
     *
     * A navigation that lands on a **different port** is ignored rather than
     * followed, and that is the tunnel rule defending itself: the tab's tunnel
     * is bound to its own port, so a tab that claimed to be on another one would
     * be a row pointing at a socket it has no claim on. It should not be
     * reachable — the loopback stack refuses an unbound port before the web view
     * gets anywhere — and if it ever is, the truthful thing is to keep saying
     * what this tab is.
     */
    func note(address: String, for id: String, machine: TunnelSource) {
        guard case let .address(port, path) = LocalhostAddress.parse(address) else { return }
        guard let path = Self.normalised(path) else { return }
        mutate(id, on: machine) { tab in
            guard tab.port == port, tab.path != path else { return }
            tab.path = path
        }
    }

    /**
     * The document says what it is called.
     *
     * Bounded through `BrowserHistory.clean`, which is the app's one function for
     * this and is shared deliberately: a tab pill and a history row are drawing
     * the same untrusted string off the same page, and two different opinions
     * about how long it may be is how one screen ends up rendering something the
     * other refused.
     *
     * An empty or whitespace-only title is **ignored, never written**. WebKit
     * blanks `title` on every navigation before the new document sets its own,
     * and a strip that took that literally would flicker back to the address on
     * every page load.
     */
    func retitle(_ raw: String?, for id: String, machine: TunnelSource) {
        guard let cleaned = BrowserHistory.clean(raw) else { return }
        mutate(id, on: machine) { tab in
            guard tab.title != cleaned else { return }
            tab.title = cleaned
        }
    }

    // MARK: - The counting, such as it is

    /**
     * Make this machine the one whose tabs may hold tunnels.
     *
     * Everything the machine you left was holding is released here. The tabs
     * themselves are untouched — they are rows in `byHost` and they wait — and
     * `resume` re-binds the port the moment one of them is tapped again.
     */
    private func adopt(_ machine: TunnelSource) {
        let host = machine.hostId
        guard host != liveHost else { return }
        for (_, tunnel) in live {
            // Directly, not through `machine`: by now `machine` resolves to the
            // machine that was switched *to*. See the file header.
            tunnel.stop()
        }
        live = [:]
        liveHost = host
    }

    /**
     * The one place a tunnel is closed, and it closes exactly the ones no tab
     * needs any more.
     *
     * Derived, never counted. `wanted` is recomputed from the tab list on every
     * call, so there is no counter to leak and no path that can forget to
     * decrement one. The dictionary being iterated is a value, so removing from
     * `live` inside the loop is safe.
     */
    private func reconcile(_ machine: TunnelSource) {
        let wanted = Set((byHost[machine.hostId] ?? []).map(\.port))
        for (port, tunnel) in live where !wanted.contains(port) {
            machine.closeLocalhost(port: port)
            // Belt as well as braces: `closeLocalhost` is the machine's own
            // teardown and it already stops this object, but a tunnel this file
            // has dropped must not be able to go on holding a socket because a
            // link somewhere decided it did not recognise the port.
            tunnel.stop()
            live.removeValue(forKey: port)
        }
    }

    /// The tunnel for a port, opening one if there is not a live one already.
    /// The only place `live` grows.
    private func ensureTunnel(port: Int, machine: TunnelSource) -> PortTunnel? {
        if let existing = live[port], !existing.hasEnded { return existing }
        guard let opened = machine.openLocalhost(port: port) else {
            live.removeValue(forKey: port)
            return nil
        }
        live[port] = opened
        return opened
    }

    /// Change one tab in place. Written once so that the two callers cannot
    /// disagree about where a tab lives or about what to do when it has gone.
    private func mutate(_ id: String, on machine: TunnelSource, _ change: (inout BrowserTab) -> Void) {
        let host = machine.hostId
        guard var list = byHost[host], let index = list.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&list[index])
        byHost[host] = list
    }

    /**
     * A path as it will be stored, or nil when it is not one this app can hold.
     *
     * `BrowserHistory.maxPathLength` rather than a second number of this file's
     * own: a page that could be opened in a tab but never written to history is
     * a page somebody could reach once and never find again.
     */
    private static func normalised(_ raw: String) -> String? {
        let path = raw.isEmpty ? "/" : (raw.hasPrefix("/") ? raw : "/" + raw)
        guard path.count <= BrowserHistory.maxPathLength else { return nil }
        return path
    }
}

/**
 * The app's one machine.
 *
 * Empty, because `DeckModel` already has both verbs — they are the façade over
 * `HostLink` that the Browser screen has always called. `hostId` is the same
 * expression every screen in this app writes inline to key something against the
 * machine on screen; naming it here means this object cannot be handed a host
 * that disagrees with the machine the tunnels are being opened on.
 */
extension DeckModel: TunnelSource {
    var hostId: String { current?.id ?? "" }
}
