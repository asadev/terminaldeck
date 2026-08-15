/**
 * What a pairing code is, and how a string becomes one.
 *
 * Pairing hands the phone three things at once, and it needs all three before
 * it can say a word to a Mac:
 *
 *   - **where to knock** — a relay and a 26-character host id, or a direct
 *     address on a tailnet;
 *   - **who is going to answer** — the Mac's static X25519 public key, which is
 *     what makes the handshake IK rather than a trust-on-first-use guess. Without
 *     it the relay could answer in the Mac's place and nothing would notice;
 *   - **a pairing token** — the single-use bearer secret from `device-auth.ts`,
 *     good for 60 seconds and one redemption, which buys the durable credential.
 *
 * ## Two shapes, because there are two ways to reach a Mac
 *
 *     terminaldeck://pair?v=1&r=<relay ws url>&h=<host id>&k=<key>&t=<token>
 *     https://mac.tailnet.ts.net/#t=<token>
 *
 * The first is the relay path: everything inside it is sealed end to end, the
 * relay sees ciphertext, and `k` is what makes that true. The second is the
 * tailnet path the PWA already uses (`pwa/src/pair.ts`) — no sealed channel,
 * because on a tailnet the tunnel is the encryption and there is no third party
 * carrying the bytes. Both are accepted; which one a code produces is visible on
 * the pairing screen, because "who can read this session" is not a detail.
 *
 * ## Why the token is in the fragment on the https shape
 *
 * A fragment is never sent to a server in a request, so it cannot land in an
 * access log, a proxy log, or a `Referer` header on its way to becoming a bearer
 * secret in somebody's log aggregator. That is `pair.ts`'s reasoning and this
 * file keeps it: on the `terminaldeck://` shape there is no server to leak to —
 * the OS hands the whole URL to this app and nothing else sees it.
 *
 * ## What is checked here, and what is not
 *
 * Shape, and only shape. Whether the host is online, whether the key is the one
 * the Mac holds and whether the token has expired are answered by the handshake
 * and by the desktop, in that order, and a parser that appeared to answer them
 * would be the most dangerous kind of wrong. What this does refuse is anything
 * that cannot be a code — a host id in the wrong alphabet, a key that is not 32
 * bytes, a token with whitespace in it — because those become a connection
 * attempt that fails for a reason nobody can read.
 */

import Foundation

/// Where a Mac is, and how the bytes to it are protected.
enum DeckEndpoint: Equatable, Codable {
    /**
     * Through a rendezvous relay, sealed end to end.
     *
     * `hostKey` is the responder's static public key. It is stored with the
     * credential rather than fetched, because fetching it from the relay is the
     * same as asking the attacker for the fingerprint of the person you are
     * about to trust.
     */
    case relay(url: URL, hostId: String, hostKey: Data)

    /// Straight to the desktop's own listener, on a network that is already
    /// private. No sealed channel — see the header.
    case direct(url: URL)

    /// The URL a socket is actually opened against.
    var socketURL: URL {
        switch self {
        case let .relay(url, hostId, _):
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = "/v1/join"
            components?.queryItems = [URLQueryItem(name: "host", value: hostId)]
            return components?.url ?? url
        case let .direct(url):
            return url
        }
    }

    /**
     * Which machine this is, as a stable string.
     *
     * The relay's own host id where there is one — it is the identity the whole
     * rendezvous is built on and it survives a re-pair, which is exactly what a
     * key in a collection of pairings has to do.
     *
     * On the direct shape there is no host id, so the address stands in. That is
     * weaker and it is the honest weakness: two tailnet machines are told apart
     * by their address because that is the only thing the code carries. The
     * scheme is not part of it — the same machine paired over `http` and `https`
     * is one machine, and treating it as two would put a duplicate row in the
     * switcher. The prefix keeps the two namespaces from colliding: a relay host
     * id cannot contain a colon, so nothing can be produced by both branches.
     */
    var hostId: String {
        switch self {
        case let .relay(_, hostId, _):
            return hostId
        case let .direct(url):
            let host = url.host ?? url.absoluteString
            return url.port.map { "direct:\(host):\($0)" } ?? "direct:\(host)"
        }
    }

    /**
     * A few characters a person can pick a machine out of a list by.
     *
     * The last thing anybody wants in a switcher is a 26-character base32 id, so
     * a relay host is shortened — and shortened at the *front*, because the
     * pairing screen and the desktop both show the full id and the eye compares
     * the beginning. It is a fallback: `StoredCredential.nickname` is what the
     * row usually says.
     */
    var shortName: String {
        switch self {
        case let .relay(_, hostId, _):
            return String(hostId.prefix(6))
        case let .direct(url):
            return url.host ?? url.absoluteString
        }
    }

    /// One line for the pairing screen and the settings row. Says who can read
    /// the session, because that is the difference between the two.
    var summary: String {
        switch self {
        case let .relay(url, hostId, _):
            return "\(hostId) via \(url.host ?? url.absoluteString) — end-to-end sealed"
        case let .direct(url):
            return "\(url.host ?? url.absoluteString) — direct, over your own network"
        }
    }

    var isSealed: Bool {
        if case .relay = self { return true }
        return false
    }
}

/// A parsed pairing code: an endpoint and the single-use token that opens it.
struct PairingCode: Equatable {
    let endpoint: DeckEndpoint
    let token: String

    /// The Mac's key fingerprint, for the "does this match the screen?" line on
    /// the pairing sheet. Nil on the direct shape, which carries no key.
    var fingerprint: String? {
        guard case let .relay(_, _, key) = endpoint else { return nil }
        return sealedFingerprint(key)
    }
}

enum PairingCodeError: Error, Equatable {
    case empty
    case notACode
    case badHostId
    case badKey
    case badRelay
    case badToken

    /// A sentence for the screen. Every one of these is a thing the person can
    /// act on, so none of them say "invalid input".
    var detail: String {
        switch self {
        case .empty: return "Nothing to pair with yet."
        case .notACode: return "That does not look like a pairing code. Scan the QR on the desktop, or paste the whole link."
        case .badHostId: return "That code names a machine id this app cannot read. Generate a new code on the desktop."
        case .badKey: return "That code carries a key of the wrong size, so the desktop could not be identified."
        case .badRelay: return "That code points at a relay address this app cannot use."
        case .badToken: return "That code has no usable pairing token in it."
        }
    }
}

enum PairingCodeParser {

    /// Host ids are 26 characters of the same alphabet as the fingerprints: no
    /// `0`/`O` or `1`/`I`. Matches `isHostId` in `relay/src/rendezvous.ts`.
    static func isHostId(_ value: String) -> Bool {
        guard value.count == 26 else { return false }
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return value.allSatisfy { allowed.contains($0) }
    }

    /**
     * A code out of a QR reader, a paste, or a deep link.
     *
     * Takes text rather than a URL because all three sources hand over text and
     * two of them hand over text that is not a URL at all.
     */
    static func parse(_ raw: String) -> Result<PairingCode, PairingCodeError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .failure(.notACode)
        }

        switch scheme {
        case Brand.id:
            return parseDeckURL(url)
        case "https", "http":
            return parseDirectURL(url)
        default:
            return .failure(.notACode)
        }
    }

    // MARK: - terminaldeck://pair

    private static func parseDeckURL(_ url: URL) -> Result<PairingCode, PairingCodeError> {
        // `terminaldeck://pair?…` parses with "pair" as the host, and
        // `terminaldeck:pair?…` with it as the path. Both are things a QR
        // encoder produces, so both are read.
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "pair" else { return .failure(.notACode) }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard let token = value("t").flatMap(cleanToken) else { return .failure(.badToken) }
        guard let hostId = value("h") else { return .failure(.badHostId) }
        guard isHostId(hostId) else { return .failure(.badHostId) }
        guard let rawKey = value("k"), let key = base64url(rawKey), key.count == Sealed.keyBytes else {
            return .failure(.badKey)
        }
        guard let relay = value("r").flatMap(relayURL) else { return .failure(.badRelay) }

        return .success(PairingCode(endpoint: .relay(url: relay, hostId: hostId, hostKey: key), token: token))
    }

    /// `ws://` and `wss://` as written, `https://` and `http://` translated —
    /// people paste what is in their browser's address bar.
    private static func relayURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "ws", "wss": break
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        guard components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - https://mac.tailnet/#t=…

    private static func parseDirectURL(_ url: URL) -> Result<PairingCode, PairingCodeError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { return .failure(.notACode) }
        guard let token = readFragmentToken(components.fragment) else { return .failure(.badToken) }

        var socket = URLComponents()
        socket.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        socket.host = host
        socket.port = components.port
        // `WS_PATH` in `src/main/remote/server.ts`. The pairing link points at
        // the PWA that the same server hosts, not at the socket.
        socket.path = "/ws"
        guard let socketURL = socket.url else { return .failure(.notACode) }
        return .success(PairingCode(endpoint: .direct(url: socketURL), token: token))
    }

    /// `#t=<token>`, and `#token=<token>`, and a bare `#<token>` — the three
    /// things that have ever come off a QR code for this.
    private static func readFragmentToken(_ fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty else { return nil }
        if fragment.contains("=") {
            let pairs = fragment.split(separator: "&").map { part -> (String, String) in
                let halves = part.split(separator: "=", maxSplits: 1)
                let name = String(halves.first ?? "")
                let value = halves.count > 1 ? String(halves[1]) : ""
                return (name, value.removingPercentEncoding ?? value)
            }
            let found = pairs.first { $0.0 == "t" }?.1 ?? pairs.first { $0.0 == "token" }?.1
            return found.flatMap(cleanToken)
        }
        return cleanToken(fragment.removingPercentEncoding ?? fragment)
    }

    // MARK: - Pieces

    /**
     * The token, bounded but not pinned to a charset.
     *
     * What a credential looks like belongs to `device-auth.ts` — today a
     * base64url pairing token, tomorrow whatever that module mints — and a
     * regex here would be this client refusing a token the desktop had just
     * issued. What is refused is whitespace and control characters, which no
     * encoding of a token produces and which is the shape of something mangled
     * by a messaging app on the way here.
     */
    private static func cleanToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= Wire.maxTokenLength else { return nil }
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard token.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return token
    }

    /// base64url, with the padding the encoder left off.
    static func base64url(_ raw: String) -> Data? {
        var text = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: text)
    }
}
