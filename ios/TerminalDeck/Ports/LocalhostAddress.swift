/**
 * What somebody typed into the Localhost tab's address field, turned into a port
 * on the machine and a path to ask it for — or into the sentence explaining why
 * it is not one.
 *
 * Asad, on the phone: *"the `+` starts a new browsing window here too"*, and
 * *"for localhost I want it exactly the way I explained for the Mac app — PC-to-PC
 * control. The same way I want all the controls here for iOS too."*
 *
 * ## Why a `+` was needed at all, when there is already a list
 *
 * Because the list can only ever offer what the machine reported, at the root of
 * the site. Three ordinary things were unreachable from it and each of them is
 * the sort of thing this feature exists for:
 *
 *  - **a path.** `localhost:3000/admin` is where the thing being worked on
 *    actually is, and every row on that screen opens `/`.
 *  - **a port that has just come up.** The list is a `ports` frame the desktop
 *    pushes; a server started twenty seconds ago is not on it until the next
 *    scan, and until then the phone can see it is missing but cannot ask for it.
 *  - **a port the grouping folded away.** Three of the five groups start closed,
 *    on purpose, and opening a group to find one number is not the gesture
 *    somebody who already knows the number wants.
 *
 * The tunnel underneath does not have any of those limits: `tunnel.open` on the
 * desktop is checked against a **fresh scan** rather than against whatever was
 * last offered, so a typed port either answers or is refused by the machine with
 * a sentence. See `src/main/remote/tunnel.ts`.
 *
 * ## A live link is **not** refused any more, and here is what changed
 *
 * This file used to end its argument with *"a live link is refused, and that
 * refusal is the answer"*: driving the desktop's own browser from a paired
 * device is blocked at every one of the five browser tools in
 * `src/main/deck-control/browser-tools.ts`, because a phone that can make
 * somebody's Mac open a page and raise a banner asking for a password — inside
 * their own trusted chrome — is a phishing primitive with the best possible
 * disguise.
 *
 * That is still true of the *tools*, and it was never true of the **machine's
 * own browser opened by its owner's own phone**. Asad, having typed a web
 * address and been told the machine could not:
 *
 * > *"browsers should browse any normal Google or any web internet website
 * > also. But it will be actually browsing on the server side; here it will be
 * > presenting that. So it shouldn't say that it cannot browse, because before I
 * > failed to browse. So this browser is not only for local, it is for internet
 * > also, for live websites also. So it should work seamless for everything."*
 *
 * **The refusal he hit was a missing wire, not a policy**, and the wire is
 * named: `CAPABILITY.web` is advertised only when `RemoteEndpointOptions.openUrl`
 * is a function — `src/main/remote/server.ts` line 2280, `if (name ===
 * CAPABILITY.web) return typeof options.openUrl === 'function'` — and the
 * headless host passed none. `src/headless/host.ts` says so in its own words
 * where it finally passes one: *"the refusal was not a policy — it was a missing
 * wire… `web.open` is backed by `openUrl`, this host passed none, and
 * `capabilitiesFor` therefore never advertised `web` — so the phone's address
 * bar took one look at `canOpenPages`, decided the machine could not do it, and
 * printed a sentence explaining that a site would load on the phone instead. The
 * sentence was true of a world where this option did not exist."*
 *
 * So the phone's job is no longer to refuse; it is to **decide which of three
 * things a typed line is**, and `classify` is that decision. `parse` below is
 * unchanged and is still the narrower question — *is this one of this machine's
 * own ports* — which is what the tunnel needs and what its own tests pin.
 *
 * ## What counts as the machine
 *
 * The loopback names, and only those: `localhost`, `127.0.0.1` (and the rest of
 * `127/8`, which is all loopback), and `::1` in both its bare and bracketed
 * spellings. A bare number is treated as a port on it, because somebody typing
 * `3000` into a field on the Localhost tab means the obvious thing.
 *
 * Deliberately **not** the machine's LAN address. The tunnel dials the machine's
 * *own* loopback, so an address that resolves somewhere else would be a request
 * this app cannot serve however plausible it looks — and one that quietly served
 * a different computer's page under the machine's name would be worse than a
 * refusal.
 */

import Foundation

enum LocalhostAddress {

    /// One typed line, resolved.
    enum Parsed: Equatable {
        /// A port on the machine, and the path to ask it for. The path always
        /// begins with `/` — `PortTunnel` hands back an origin and this is
        /// resolved against it, so a relative one would be dropped.
        case address(port: Int, path: String)
        /// Not something this screen can open, and the sentence to show. Written
        /// as a whole sentence rather than a code, because it is drawn under the
        /// field the moment it is true and nothing else will explain it.
        case refused(String)
    }

    /**
     * One typed line, as the app can act on it. Three outcomes are a *place to
     * go* and the fourth is a sentence.
     */
    enum Typed: Equatable {
        /// One of this machine's own ports — a tunnel, opened in this phone's
        /// own web view on a real loopback origin, so the page gets cookies, a
        /// service worker and the WebSocket a dev server's hot reload runs on.
        case tunnel(port: Int, path: String)
        /// Somewhere on the web, normalised to a URL the machine will accept.
        /// It opens **on the machine**, in the machine's own browser.
        case page(String)
        /// Not an address at all, so it is a search — with the words as typed,
        /// for the sentence that confirms it, and the URL that performs it.
        case search(query: String, url: String)
        /// It **is** an address and this app will not open it: a scheme that is
        /// not http or https, a port outside 1–65535, a paste with a control
        /// character in it. The sentence is written to be shown under the field.
        case refused(String)
    }

    /**
     * Where a search goes.
     *
     * One constant rather than a setting, because a setting nobody has asked for
     * is a screen to maintain and a preference to migrate. Every browser on this
     * phone has a default and this is that default; it is a `https` URL on a
     * host the machine resolves, so it goes down exactly the same path as any
     * other page typed here and needs no special case at either end.
     */
    static let searchBase = "https://www.google.com/search?q="

    /**
     * **The one decision the address bars make.** Which of three things is this?
     *
     * > *"So this browser is not only for local, it is for internet also, for
     * > live websites also. So it should work seamless for everything."*
     *
     * Seamless means there is no mode to choose, so this is where the choosing
     * happens — once, over a `String`, with no view and no capability in scope.
     * Both address fields in the app call it and neither has an opinion of its
     * own; what a caller decides is only *which door* a `page` goes through, and
     * `MachineBrowserView` argues that separately.
     *
     * ## The rules, in the order they are applied, and why each is where it is
     *
     *  1. **Whitespace inside means a search.** A URL cannot contain a space —
     *     it percent-encodes one — so `what is my ip` was never an address, and
     *     a browser that answered "that is not an address this phone can read"
     *     to a question is the flat refusal this whole change exists to delete.
     *  2. **A control character means a paste went wrong**, or is smuggling a
     *     second target past the eye. Refused rather than searched, because the
     *     honest reading is that the input is damaged. `browser-url.ts` makes
     *     the same check on the host for the same reason.
     *  3. **A bare number is a port.** `3000` typed into this app means the
     *     obvious thing, and `:3000` is the same habit with a colon. An
     *     out-of-range number is refused rather than searched: somebody who
     *     typed `70000` meant a port and wants to know it is not one.
     *  4. **A scheme that is not http(s) is refused** — `file:`, `ws:`,
     *     `javascript:` — and the check has to come before anything reads the
     *     string as a host, because otherwise `file:///etc/passwd` becomes the
     *     host `file` and is opened as a page. It also has to *not* fire on
     *     `localhost:3000`, whose "scheme" is `localhost`: that is the single
     *     most likely thing anybody types here and `new URL` gets it wrong.
     *     `hostAndPort` is the same shape `browser-url.ts` matches for the same
     *     trap, kept in step deliberately.
     *  5. **This machine's own loopback is the tunnel**, and `parse` owns that
     *     answer including its refusal for a loopback name with no port —
     *     *"Which port?"* is a question with an answer somebody can type, and a
     *     search for the word `localhost` is not.
     *  6. **Anything that looks like a host is a page**; anything else is a
     *     search. `looksLikeAHost` is the whole of that judgement.
     *
     * ## Why `google.com` is the case this is measured against
     *
     * Nobody types the scheme. `web.open` on the host runs what it is given
     * through `normalizeUrl` in `browser-url.ts`, which completes a bare host
     * itself — but `isNavigationAllowed`, the guard on a *page-initiated*
     * navigation, does not, and `new URL('google.com')` throws. Completing it
     * here means what goes on the wire is a thing every gate on the far side
     * accepts, rather than a string whose fate depends on which gate reads it.
     */
    static func classify(_ raw: String) -> Typed {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .refused("Type an address, a port on this machine, or something to search for.")
        }

        if text.contains(where: \.isWhitespace) { return searching(text) }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return .refused("That contains characters an address cannot contain.")
        }

        // A bare port, with or without the colon somebody types out of habit.
        // Handed to `parse` rather than parsed again here, so the range check
        // and its sentence exist once.
        let bare = text.hasPrefix(":") ? String(text.dropFirst()) : text
        if bare.allSatisfy(\.isNumber) { return fromParse(text) }

        if let scheme = explicitScheme(text), scheme != "http", scheme != "https" {
            return .refused("Only http and https pages can be opened, not \(scheme):.")
        }

        // Protocol-relative — `//example.com` — is given a scheme rather than a
        // second pair of slashes. Vanishingly rare from a thumb and handled all
        // the same, because `browser-url.ts` handles it on the host and a string
        // the two ends disagree about is a refusal nobody can explain.
        let withScheme = text.contains("://")
            ? text
            : (text.hasPrefix("//") ? "http:\(text)" : "http://\(text)")
        guard var parts = URLComponents(string: withScheme),
              let host = parts.host, !host.isEmpty else {
            // Not readable as a URL at all — `a b`, `??`, a stray bracket. A
            // browser searches for it rather than lecturing about grammar.
            return searching(text)
        }

        if isLoopback(host) { return fromParse(text) }

        guard looksLikeAHost(host, hasPort: parts.port != nil) else { return searching(text) }

        // Lowercased on the way out as well as on the way through the checks, so
        // `HTTP://GOOGLE.COM` and `google.com` reach the machine as one string.
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        return .page(parts.string ?? withScheme)
    }

    /// The tunnel half, borrowed from `parse` so that its answers and its
    /// sentences exist in exactly one place.
    private static func fromParse(_ text: String) -> Typed {
        switch parse(text) {
        case let .address(port, path): return .tunnel(port: port, path: path)
        case let .refused(why): return .refused(why)
        }
    }

    /// Words, and the address that searches for them. Percent-encoded against
    /// `alphanumerics` rather than a query character set: it over-encodes, and
    /// over-encoding a query is always safe while under-encoding one silently
    /// changes what was searched for.
    private static func searching(_ query: String) -> Typed {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return .search(query: query, url: searchBase + encoded)
    }

    /**
     * `host:port` with an optional path — the shape that fools `new URL` and
     * `URL(string:)` alike into reading the host as a scheme.
     *
     * The same expression `browser-url.ts` matches on the host, deliberately: a
     * string this side reads as a host and that side reads as a scheme is a
     * refusal nobody can explain from either end.
     */
    private static let hostAndPort = try? NSRegularExpression(
        pattern: "^(?:[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*|\\[[0-9A-Fa-f:]+\\]):[0-9]{1,5}(?:[/?#].*)?$")

    /// The scheme a line actually has, or nil — including nil for the two shapes
    /// that only look like they have one.
    private static func explicitScheme(_ text: String) -> String? {
        let whole = NSRange(text.startIndex ..< text.endIndex, in: text)
        if hostAndPort?.firstMatch(in: text, range: whole) != nil { return nil }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = String(text[text.startIndex ..< colon])
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" })
        else { return nil }
        return scheme.lowercased()
    }

    /**
     * Whether a host name is a name somebody meant, rather than a word.
     *
     * Four ways to be one, and the last is the interesting one:
     *
     *  - it carries a **port**, which nobody writes on a search term;
     *  - it is an **IPv6 literal**, which arrives bracketed;
     *  - it is an **IPv4 literal**;
     *  - it has a **dot** and its last label is two or more letters. That is the
     *    rule every browser uses and it is deliberately not a list of real
     *    top-level domains: the list changes, a phone that shipped last year
     *    would refuse a domain that exists, and being wrong about `.zip` costs
     *    nothing next to being wrong about a domain a person is looking at.
     *
     * `git`, `readme`, `terminal deck` and `1.2.3` are all *not* hosts, which is
     * what makes them searches.
     */
    private static func looksLikeAHost(_ host: String, hasPort: Bool) -> Bool {
        if hasPort { return true }
        let name = host.lowercased()
        if name.hasPrefix("[") { return true }
        if isIPv4(name) { return true }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let last = labels.last, last.count >= 2, last.allSatisfy(\.isLetter) else {
            return false
        }
        return true
    }

    /// A dotted quad, each octet in range. Shared by `looksLikeAHost` and
    /// `isLoopback`, which asks the same question of the same shape.
    private static func isIPv4(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        return parts.compactMap { Int($0) }.allSatisfy { $0 >= 0 && $0 <= 255 }
    }

    /**
     * Turn a line into a port and a path.
     *
     * Written as a static function over a `String` rather than as a
     * `URLComponents` extension because two of the four shapes people type are
     * not URLs at all — `3000` and `localhost:3000` both parse as a *path* under
     * `URLComponents`, with `localhost` as a scheme-less path segment and `3000`
     * as, remarkably, nothing at all. Handling those first and only then handing
     * the rest to `URL` is what makes the common case work.
     */
    static func parse(_ raw: String) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .refused("Type a port, or an address on this machine.")
        }

        // A bare port, with or without the colon somebody types out of habit.
        let bare = text.hasPrefix(":") ? String(text.dropFirst()) : text
        if bare.allSatisfy(\.isNumber) {
            return port(Int(bare) ?? 0, path: "/")
        }

        /*
         * Everything else is a URL, and one is given a scheme if it has none:
         * `URL(string:)` accepts `localhost:3000/admin` and reads `localhost` as
         * the *scheme*, which puts the port in the path and the host nowhere.
         *
         * `URLComponents` rather than `URL` for the reading, and the difference
         * is a trailing slash. `URL.path` normalises one away — `/a/b/` comes
         * back as `/a/b` — and that is not cosmetic on a dev server: a directory
         * URL and a file URL resolve relative assets from different places, so
         * the page would load and its stylesheet would 404. The percent-encoded
         * forms are used for the same class of reason: a path with a space or a
         * `#` in it survives the round trip instead of being re-encoded wrongly
         * when it is resolved against the tunnel's origin.
         */
        let withScheme = text.contains("://") ? text : "http://\(text)"
        guard let parts = URLComponents(string: withScheme), let host = parts.host else {
            return .refused("That is not an address this phone can read.")
        }

        guard let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .refused("Only http and https pages can be opened here.")
        }

        guard isLoopback(host) else {
            /*
             * A fact about **this function**, and nothing more.
             *
             * `parse` answers one question — *is this one of this machine's own
             * ports* — so a host that is not loopback is a no here and is not a
             * refusal anywhere a person can see. `classify` is what the address
             * bars call, and it takes this case and opens it on the machine.
             * Nothing draws this string; it is kept because `parse` is a public
             * answer with its own tests and *"no"* with no reason attached is a
             * worse value to hand back than one with a sentence on it.
             */
            return .refused("\(host) is not a page this machine is serving.")
        }

        guard let number = parts.port else {
            return .refused("Which port? A page on this machine is reached by its port number.")
        }

        var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery, !query.isEmpty { path += "?\(query)" }
        if let fragment = parts.percentEncodedFragment, !fragment.isEmpty { path += "#\(fragment)" }
        return port(number, path: path)
    }

    /// The range check, in one place, so a bare number and a full URL are refused
    /// with the same sentence. Port 0 is excluded as well as the out-of-range
    /// values: nothing listens on it, and `PortTunnel` refuses it a step later
    /// with a message about this phone rather than about what was typed.
    private static func port(_ number: Int, path: String) -> Parsed {
        guard number > 0, number <= 65_535 else {
            return .refused("A port is a number between 1 and 65535.")
        }
        return .address(port: number, path: path)
    }

    /**
     * Whether a host name means *this machine's own loopback*.
     *
     * `127.0.0.0/8` in full rather than the one address people type, because a
     * dev server bound to `127.0.0.2` is a real thing — it is how two projects
     * share a port — and the desktop's own scan reports whatever it finds on the
     * loopback interface rather than only the canonical address.
     */
    private static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "::1" || name == "[::1]" { return true }
        guard isIPv4(name) else { return false }
        return name.split(separator: ".").first.flatMap { Int($0) } == 127
    }
}
