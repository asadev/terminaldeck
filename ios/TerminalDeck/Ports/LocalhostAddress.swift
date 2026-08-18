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
 * ## Why a live link is refused rather than opened
 *
 * He asked for both — *"a live link and a localhost link both open on the
 * connected machine"* — and only one of them can be built, because of a decision
 * this codebase has already taken deliberately and written down at length.
 * Driving the desktop's own browser from a paired device is refused at every one
 * of the five browser tools in `src/main/deck-control/browser-tools.ts`, and the
 * comment above the check says why: a phone that can make somebody's Mac open a
 * page, click through it and raise a banner asking for a password — inside their
 * own trusted app chrome — is a remote phishing primitive with the best possible
 * disguise. That refusal is not an oversight to route around; it is the answer.
 *
 * So this field opens **what the machine is serving**, which is the half that can
 * be honest, and it says the other half out loud rather than quietly loading the
 * site over the phone's own network and letting a person believe it ran on their
 * Mac. That would be exactly the *"phone web view pretending"* he named.
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
            // Named, because the refusal is about *where the page would come
            // from* and the person typed a perfectly good address. The second
            // sentence is the whole of the decision above, in the words somebody
            // reading it on a phone needs.
            return .refused("\(host) is not on this machine. This opens pages the machine itself is "
                            + "serving; anything else would load on the phone rather than on it.")
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
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return false }
        return octets[0] == 127
    }
}
