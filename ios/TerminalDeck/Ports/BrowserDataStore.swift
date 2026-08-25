/**
 * What the phone's own web view has kept from the pages it has been shown — and
 * the two ways of getting rid of it.
 *
 * Asad, listing what the Browser tab still owed him: *"connecting and all of and
 * search history and cookies and all of this."*
 *
 * ## Nothing here goes near the wire, and that is the whole design
 *
 * His rule for this split: *"any of the feature which is not something that we
 * can wire or it should be sitting in the device whichever the device we are
 * using at the moment and it is not related to the folder sided or server sided
 * then build also but keep it on the phone side or app side."*
 *
 * Cookies for a page the phone rendered are the phone's, in the phone's WebKit
 * storage, written by the phone's network process. The Mac has no idea they
 * exist and could not be asked to enumerate or delete them without inventing a
 * frame for a question it cannot answer. So this file talks to
 * `WKWebsiteDataStore` and to nothing else — no protocol, no capability, no host
 * code — the same way Safari's own Advanced screen does.
 *
 * ## The store is the persistent one, and that is checked rather than assumed
 *
 * `BrowserBridge.init` sets `configuration.websiteDataStore = .default()` and
 * says why: *"a dev server that logs you in with a cookie should keep you logged
 * in between taps, and an ephemeral store would make every open a fresh
 * browser."* That decision is what gives this screen something to show. Against
 * a `.nonPersistent()` store there would be nothing to list and nothing to
 * clear, and the honest build would have been one sentence rather than a screen.
 *
 * `.default()` is process-wide, so this reads the same storage the browser
 * writes without either of them having to be handed the other.
 *
 * ## What WebKit will tell you, and the one thing it will not
 *
 * **There are no sizes.** `WKWebsiteDataRecord` is two properties —
 * `displayName` and `dataTypes` — and that is the entire public surface. The
 * byte count exists as `_dataSize` in `WKWebsiteDataRecordPrivate.h`, and
 * reaching for it would put an underscored WebKit selector in a binary that goes
 * through App Store review. It is not worth a number.
 *
 * So the second line of each row is *what kind* of thing is stored rather than
 * how much of it, which on a dev server is the more useful half anyway: a person
 * looking at this screen is nearly always trying to work out why a page is still
 * logged in, still serving a stale bundle, or still being answered by a service
 * worker they thought they had killed. Cookies / Storage / Service worker /
 * Cache answers all three. "412 KB" answers none of them.
 *
 * ## A record is a host, not an origin — and cookies were never port-scoped
 *
 * The header on `WKWebsiteDataRecord` is explicit: records are *"grouped by
 * domain name using the public suffix list."* There is no port and no scheme in
 * a `displayName`, so every dev server on the machine — `:3000`, `:5173`,
 * `:8080` — arrives here as one record called `127.0.0.1`.
 *
 * That is not WebKit being coarse. It is the cookie spec: cookies have never
 * been scoped by port, so `127.0.0.1:3000` and `127.0.0.1:5173` genuinely share
 * a cookie jar and always have. A per-port row would be a promise this cannot
 * keep — it would offer to sign you out of one dev server and sign you out of
 * all of them. The other data types (local storage, IndexedDB, the file system
 * API) *are* per origin and therefore per port, and they go with the host when
 * the host is cleared. The screen says so; see `BrowserDataView`.
 *
 * `127.0.0.1` and `::1` are two records for one machine, for the same reason
 * `LocalhostBrowser.first` resolves against the tunnel's own URL: the loopback
 * literal is whichever one `PortTunnel` managed to bind, and over a few weeks a
 * phone will have used both.
 *
 * ## Neither call can fail
 *
 * `fetchDataRecordsOfTypes:` hands back an array and `removeDataOfTypes:` a
 * completion handler that takes nothing at all — no `NSError` on either. So
 * there is no `problem` property here and no failure path in the screen, and
 * that absence is deliberate rather than forgotten: an error state nothing can
 * ever enter is a state that will be wrong the first time someone edits around
 * it.
 */

import CoreGraphics
import Foundation
import Observation
import WebKit

/**
 * What a site has left behind, in the four groups worth telling apart.
 *
 * Four rather than the fourteen `WKWebsiteDataType*` constants, because the
 * constants are an implementation list and this is a sentence a person reads at
 * a glance. `WebSQLDatabases` and `IndexedDBDatabases` are one idea to everybody
 * who is not writing WebKit; `DiskCache`, `MemoryCache` and `FetchCache` are one
 * idea to everybody at all.
 *
 * The split is by *what breaks if you clear it*, which is the only question
 * being asked here: your session, your app's saved state, a worker that is
 * answering instead of the server, or a stale copy of a file.
 */
enum BrowserDataKind: CaseIterable {
    /// The session. This is the one that signs you out.
    case cookies
    /// Local storage, session storage, IndexedDB, the file system API.
    case storage
    /// A service worker registration — the thing that answers a request the
    /// server never sees, and the usual reason a hard reload changes nothing.
    case worker
    /// Disk, memory and fetch caches: a copy of something the server already
    /// sent, kept in case it is asked for again.
    case cache

    var label: String {
        switch self {
        case .cookies: return "Cookies"
        case .storage: return "Storage"
        case .worker: return "Service worker"
        case .cache: return "Cache"
        }
    }
}

/**
 * One row: a host WebKit is holding something for.
 *
 * A value type with no `WKWebsiteDataRecord` in it, so the screen never imports
 * WebKit and the whole list can be built in a test out of four strings. The
 * records themselves stay inside `BrowserDataStore`, keyed by this `id` —
 * removal needs the real objects and nothing above this layer should be holding
 * a main-actor WebKit object it did not ask for.
 *
 * `id` is WebKit's own `displayName`, used verbatim rather than prettified. It
 * is what the row draws and it is the key the record is found under, and those
 * being the same string is what makes a clear provably act on the row that was
 * tapped.
 */
struct BrowserDataSite: Identifiable, Equatable {
    let id: String
    let kinds: [BrowserDataKind]
    /// Whether this host is the machine's own loopback — which is nearly always,
    /// and which changes what clearing it means. See `BrowserDataView`.
    let isMachine: Bool

    /// `Cookies · Storage · Cache`. Built here rather than in the view so the
    /// order is the declaration order of `BrowserDataKind` rather than whatever
    /// order a `Set` happened to iterate in — a row whose subtitle reshuffles
    /// itself between two reads looks like the data changed when nothing did.
    var summary: String {
        kinds.map(\.label).joined(separator: " · ")
    }
}

@MainActor
@Observable
final class BrowserDataStore {

    /// What is being cleared right now, if anything. One value rather than a
    /// `Bool` per row: two clears cannot be in flight at once because both
    /// controls disable while one is, and a single optional is the shape that
    /// cannot disagree with itself.
    enum Job: Equatable {
        case site(String)
        case everything
    }

    private(set) var sites: [BrowserDataSite] = []
    /// True from the first `read` until it answers. Distinct from *empty*: a
    /// screen that drew "Nothing stored" for the third of a second WebKit takes
    /// to answer would be telling a lie that is about to correct itself.
    private(set) var reading = true
    private(set) var working: Job?

    private let store: WKWebsiteDataStore
    /// The real records, keyed by the id the screen hands back. Kept because
    /// `removeDataOfTypes:forDataRecords:` takes the objects and there is no
    /// public way to make one from a host name.
    private var records: [String: WKWebsiteDataRecord] = [:]

    /**
     * The default store, unless a test says otherwise.
     *
     * Injected rather than reached for, so a test can drive this against
     * `.nonPersistent()` and get a real WebKit store that is empty at the start
     * of every run. The production call site passes nothing, which is what keeps
     * this pointed at the same storage `BrowserBridge` writes to.
     *
     * `nil` and a fallback rather than `= .default()` as the default argument. A
     * default argument is evaluated at the *call site*, outside this init's
     * isolation, and `WKWebsiteDataStore` is `WK_SWIFT_UI_ACTOR` — so the
     * shorter spelling asks a main-actor class method to run somewhere it has
     * not been promised. It compiles today because the app is in Swift 5 language
     * mode; it is a diagnostic the day that changes, for no reading benefit.
     */
    init(store: WKWebsiteDataStore? = nil) {
        self.store = store ?? .default()
    }

    /**
     * Ask WebKit what it is holding.
     *
     * Every type, via `allWebsiteDataTypes()`, rather than a hand-written set.
     * The list grows — `FileSystem` arrived in iOS 16, `MediaKeys` and
     * `HashSalt` in 17, `ScreenTime` in 26 — and a screen that offers to clear
     * "everything" while enumerating a set frozen in the year it was written
     * quietly stops being true. Anything WebKit adds lands in `.cache` by
     * default below, which is the honest place for a kind this app has never
     * heard of: it says something is there without claiming to know what.
     */
    func read() async {
        reading = true
        await refresh()
        reading = false
    }

    /**
     * The read itself, without the flag.
     *
     * Split out because a clear also has to re-read, and a clear that went
     * through `read` would flip `reading` — which swaps the card for *"Reading
     * what this phone has kept…"* and takes away the row somebody is watching
     * say "Clearing…". The flag means *this screen has never had an answer*,
     * which is true exactly once.
     */
    private func refresh() async {
        let found = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        records = Dictionary(found.map { ($0.displayName, $0) }, uniquingKeysWith: { first, _ in first })
        sites = found
            .map { record in
                BrowserDataSite(id: record.displayName,
                                kinds: Self.kinds(in: record.dataTypes),
                                isMachine: Self.isLoopback(record.displayName))
            }
            // The machine first, then alphabetically. Loopback is the reason
            // this screen exists and an internet host only ever gets here
            // because somebody followed a link out of a dev page; sorting them
            // together would bury the row that is nearly always the point.
            .sorted { left, right in
                left.isMachine == right.isMachine
                    ? left.id.localizedStandardCompare(right.id) == .orderedAscending
                    : left.isMachine
            }
    }

    /**
     * Clear one host.
     *
     * Every type for that record, not just the cookies — the row said what it
     * holds and the button said clear, so leaving an IndexedDB behind because it
     * was not the interesting part would be the screen lying about what it just
     * did.
     *
     * Silently does nothing for an id with no record behind it, which is the
     * state after two taps on the same row before the re-read lands. The button
     * disables while a job is in flight, so this is a guard against a future
     * caller rather than against the screen as it stands.
     */
    func clear(_ site: BrowserDataSite) async {
        guard let record = records[site.id] else { return }
        working = .site(site.id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: [record])
        // Re-read before the job clears rather than after. The other order puts
        // one frame on screen in which the controls are live again and the list
        // still names a record that has just been deleted.
        await refresh()
        working = nil
    }

    /**
     * Clear the lot.
     *
     * `modifiedSince: .distantPast` rather than a pass over every record, and
     * the difference is real: some data types produce no `WKWebsiteDataRecord`
     * at all, so removing the records one by one leaves behind exactly the
     * things a person pressing "Clear everything" meant. The date form goes
     * through WebKit's own sweep instead.
     */
    func clearEverything() async {
        working = .everything
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await refresh()
        working = nil
    }

    /**
     * Whether this row is the one being cleared, asked rather than deduced.
     *
     * The screen could compare against `working` itself, and then the optional
     * enum match would be written once per control instead of once here — three
     * places that have to agree about a shape only this file owns.
     */
    func isClearing(_ id: String) -> Bool {
        if case .site(let clearing)? = working { return clearing == id }
        return false
    }

    var isClearingEverything: Bool {
        if case .everything? = working { return true }
        return false
    }

    /// Whether anything at all is in flight. Every control on the screen
    /// disables on this rather than on its own job: the store runs one at a
    /// time, and a second press during the re-read would act on a record that
    /// has already gone.
    var isBusy: Bool { working != nil }

    // MARK: - Reading a record

    /// Group the raw types, in the declaration order of `BrowserDataKind`.
    private static func kinds(in types: Set<String>) -> [BrowserDataKind] {
        // Anything WebKit has that the four groups below do not name — a type
        // added to the framework after this was written. It counts as cache, so
        // the row still says *something is here* rather than dropping a kind out
        // of the summary and reading as empty when it is not.
        let unnamed = !types.subtracting(named).isEmpty
        return BrowserDataKind.allCases.filter { kind in
            switch kind {
            case .cookies: return types.contains(WKWebsiteDataTypeCookies)
            case .storage: return !types.isDisjoint(with: storageTypes)
            case .worker: return types.contains(WKWebsiteDataTypeServiceWorkerRegistrations)
            case .cache: return unnamed || !types.isDisjoint(with: cacheTypes)
            }
        }
    }

    private static let storageTypes: Set<String> = [
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeFileSystem,
    ]

    private static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
    ]

    /// Every constant the three groups above name. `WKWebsiteDataTypeOffline-
    /// WebApplicationCache` is deliberately not among them: it is deprecated as
    /// of iOS 26.2 and naming it buys a build warning to classify a feature
    /// WebKit has removed.
    private static let named: Set<String> =
        storageTypes.union(cacheTypes).union([WKWebsiteDataTypeCookies,
                                              WKWebsiteDataTypeServiceWorkerRegistrations])

    /**
     * Whether a host name means *this machine's own loopback*.
     *
     * `LocalhostAddress.isLoopback` is the same eight lines and it is `private`,
     * which is the right visibility for it there — it exists to decide what an
     * address bar may open, and widening it so a settings screen can colour an
     * icon would be a worse trade than this copy. If a third caller ever appears,
     * promote that one and delete this.
     *
     * `127.0.0.0/8` in full for the reason that file gives: a dev server bound
     * to `127.0.0.2` is how two projects share a port.
     */
    private static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "::1" || name == "[::1]" { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return false }
        return octets[0] == 127
    }
}

/* -------------------------------------------------------------------------- */
/* Page zoom                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * How big a page is drawn on this phone.
 *
 * `TextSize`'s shape, deliberately and almost line for line — same store, same
 * clamp-on-the-way-out, same `larger`/`smaller`/`canGo…` quartet, same `label`.
 * It lives in this file rather than in one of its own because it is the other
 * half of the same sentence: these are the two things the phone remembers about
 * the browser, and neither of them ever leaves it.
 *
 * ## Why this one *is* a zoom, when the terminal's deliberately is not
 *
 * `TextSize`'s header is emphatic that it must not be built as a display zoom,
 * and it is right — a terminal's column count *is* its font, so scaling pixels
 * would leave the far end writing eighty columns into fifty and hand back a
 * magnified mess.
 *
 * A web page is the opposite case and by construction: CSS reflows. `pageZoom`
 * changes the CSS pixel ratio, so the layout re-runs at the new width, media
 * queries re-evaluate, and a responsive site does at 200% exactly what it does
 * on a narrower phone. There is no far end to tell and nothing to resize. The
 * two settings look like the same setting and are opposite decisions for the
 * same reason: match what the thing on screen actually is.
 *
 * ## The bounds, and why the step is coarse
 *
 * Half size is where a dev server's 14-pixel body text lands at about seven
 * points and stops being text. Triple is where a phone in portrait is showing
 * roughly a hundred and thirty CSS pixels of page — a single column of a single
 * component — which is still a real thing to want when the point is reading one
 * error message, and is where usefulness ends.
 *
 * A quarter, because that is the smallest change anybody can see. This is
 * `TextSize`'s "whole points" argument arriving at a different number: a step
 * that produces two settings which look identical and behave differently is a
 * step that is too small, and 10% on a phone is that. Eleven stops also means
 * the stepper crosses the whole range in ten presses rather than twenty-five.
 */
enum PageZoom {

    /// Below this, ordinary body text is not text.
    static let minimum: CGFloat = 0.5
    /// Above this a portrait phone holds one column of one component.
    static let maximum: CGFloat = 3
    /// What WebKit does with no opinion expressed, and what this starts at.
    static let standard: CGFloat = 1
    /// One press. See the header for why it is not a tenth.
    static let step: CGFloat = 0.25

    private static let key = "terminaldeck.pageZoom.v1"

    /// The zoom in use. `standard` until somebody changes it, and clamped on the
    /// way out so a value stored by a build with different bounds cannot produce
    /// an unreadable page.
    static var stored: CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 0 else { return standard }
        return clamp(CGFloat(saved))
    }

    static func save(_ zoom: CGFloat) {
        UserDefaults.standard.set(Double(clamp(zoom)), forKey: key)
    }

    /// Held inside the bounds and snapped to a stop. Every path into a zoom goes
    /// through here, so there is one place that can be wrong.
    ///
    /// The arithmetic is exact rather than nearly so: `0.5` and `0.25` are both
    /// exact in binary, so `minimum + n * step` reproduces the eleven stops
    /// without drift, and `label` never has to defend itself against `1.7499999`.
    static func clamp(_ zoom: CGFloat) -> CGFloat {
        let bounded = min(maximum, max(minimum, zoom))
        let stops = ((bounded - minimum) / step).rounded()
        return min(maximum, minimum + stops * step)
    }

    static func larger(_ zoom: CGFloat) -> CGFloat { clamp(zoom + step) }
    static func smaller(_ zoom: CGFloat) -> CGFloat { clamp(zoom - step) }

    static func canGoLarger(_ zoom: CGFloat) -> Bool { clamp(zoom) < maximum }
    static func canGoSmaller(_ zoom: CGFloat) -> Bool { clamp(zoom) > minimum }

    /// What the row reads. A percentage rather than a multiplier, because every
    /// browser anybody has used says 150% and none of them says 1.5×. Mono in
    /// the UI because it is a measurement, which is the same rule `TextSize.label`
    /// is drawn under.
    static func label(_ zoom: CGFloat) -> String {
        "\(Int((clamp(zoom) * 100).rounded()))%"
    }

    /**
     * Put the stored zoom on a web view.
     *
     * One line, in a function, so that the call site in `BrowserBridge` reads as
     * a decision rather than as a property assignment somebody might tidy away.
     * `pageZoom` sticks to the view rather than to the page, so this survives
     * every navigation the page makes and only has to be said when the view is
     * built.
     */
    @MainActor
    static func apply(to webView: WKWebView) {
        webView.pageZoom = stored
    }
}
