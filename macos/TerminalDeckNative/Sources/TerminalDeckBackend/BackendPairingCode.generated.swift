// Generated from the product's shared Swift source: the phone app's PairingCode.swift
// Source SHA256 9e5617e9263b4a7e1c965e3aeece1047b58b996c6004081733966f210a7cee38; regenerate with scripts/assemble-swift-backend.mjs.
// Mac copy: only what the relay rendezvous uses; the header below describes the phone, where the rest lives.
/**
 * What a pairing code is, and how a string becomes one.
 *
 * ## Six digits, and nothing else
 *
 * A pairing code is six decimal digits — `shared/short-code.ts` on the desktop
 * is the format, and this is the same rule in Swift.
 *
 * It used to be a URL. Two of them, in fact:
 *
 *     terminaldeck://pair?v=1&r=<relay ws url>&h=<host id>&k=<key>&t=<token>
 *     https://mac.tailnet.ts.net/#t=<token>
 *
 * The first came off a QR code on the Mac's screen, and it carried the whole
 * address — a relay, a host id, a public key — so this file's job was to take it
 * apart. Neither exists now: the QR did not work, and a link with a live pairing
 * token in it is a bearer secret whose only route to a second device is a
 * messaging app that keeps a copy. So the address is no longer *carried*; it is
 * *looked up*, at the rendezvous slot the code names. `Rendezvous.swift` is that
 * lookup and its header is the argument for it.
 *
 * ## What is left here
 *
 *  - `DeckEndpoint`, which is where a machine *is* once the lookup has answered.
 *    It is `Codable` and it is on disk in the Keychain beside every credential,
 *    which is why the `.direct` case is still here: a phone paired over the
 *    tailnet before this change still has one, and dropping the case would make
 *    its stored credential undecodable and sign it out.
 *  - `normalise`, which is what somebody typed read as the code they meant.
 *
 * ## Reading is looser than writing, and stops short of guessing
 *
 * Separators are dropped — spaces, hyphens, the curly dash a chat app
 * substitutes — because the string makes a journey and things get inserted into
 * it. A **letter** is refused rather than folded. The old eight-character format
 * folded `O` onto `0` and `I`/`L` onto `1`, which was right when the screen was
 * showing letters; the screen shows digits now, so a letter is a typo, and
 * folding a typo produces a *different valid code* belonging to somebody else's
 * pairing or to nobody at all.
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
}

enum PairingCodeParser {

    /// Digits in a code. `CODE_LENGTH` in `src/shared/short-code.ts`.
    static let codeLength = 6

    /// Host ids are 26 characters of the same alphabet as the fingerprints: no
    /// `0`/`O` or `1`/`I`. Matches `isHostId` in `relay/src/rendezvous.ts`.
    static func isHostId(_ value: String) -> Bool {
        guard value.count == 26 else { return false }
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return value.allSatisfy { allowed.contains($0) }
    }

    /**
     * What somebody typed, as the six digits they meant — or nil.
     *
     * Bounded before it is scanned. Nothing here is a security boundary — the
     * code is checked for real by `device-auth.ts` on the far machine — but a
     * paste of a megabyte is still a megabyte to walk on the main thread, and
     * the answer was never going to be longer than six digits.
     *
     * The scan stops the moment there are too many digits, so a paste of a
     * thousand of them is not a thousand appends.
     */
    static func normalise(_ raw: String) -> String? {
        var digits = ""
        for character in raw.prefix(256) {
            if character.isASCII, character.isNumber {
                digits.append(character)
                if digits.count > codeLength { return nil }
                continue
            }
            // A letter is a typo; see the header. Everything else — spaces,
            // hyphens, the curly dash a chat app substitutes — is separator
            // noise and is dropped, because refusing it would mean refusing the
            // exact string somebody pasted out of a message.
            if character.isLetter { return nil }
        }
        return digits.count == codeLength ? digits : nil
    }
}
