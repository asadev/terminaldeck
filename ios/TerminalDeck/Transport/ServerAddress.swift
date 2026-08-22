/**
 * A **server address**, and how a pasted blob becomes one.
 *
 * ## Why this file has to exist at all
 *
 * A phone opening its *first* connection to a machine runs a Noise IK handshake,
 * and IK needs the responder's X25519 static public key before the first byte
 * goes out. A host id does not carry it: `BASE32(SHA-256(hostSecret))` is a
 * one-way hash, so a person who types 26 characters of host id has given this
 * app a *name* for a machine and nothing it can dial. That is precisely why the
 * Add-server screen did not exist in 0.10.0 — there was no valid thing to put in
 * the field.
 *
 * A server address is the missing thing: the three facts `endpoint.ts` names as
 * the irreducible set, printed by the server for somebody to copy.
 *
 *   - **relay url** — which rendezvous service. Configurable, because the whole
 *     design assumes it is hostile.
 *   - **host id** — which slot at it. 26 characters, comparable by eye.
 *   - **host key** — that machine's X25519 static public key. This is the one
 *     that makes the handshake IK rather than trust-on-first-use: without it the
 *     relay could answer in the machine's place and nothing here would notice.
 *
 * There is deliberately **no secret in it**. It is safe to read out over a call,
 * photograph, or paste into a chat — the sign-in that follows is what proves who
 * you are, and it proves it against the server's own sshd. That is the whole
 * difference from the pairing link this product deleted, which carried a live
 * bearer token.
 *
 * ## Reading is deliberately looser than writing
 *
 * `pwa/src/endpoint.ts`'s `asEndpoint` reads one exact shape, because it reads
 * back what that client itself wrote to storage. This reads what a **person**
 * pasted, which is a different problem: it has been through a clipboard, a
 * terminal that soft-wrapped it, and very often a messaging app. So four shapes
 * are accepted and all four produce the same `DeckEndpoint`:
 *
 *  1. **The JSON object** `{"kind":"relay","url":…,"hostId":…,"hostKey":…}` —
 *     `asEndpoint`'s own shape, and the rendezvous offer's field names
 *     (`relayUrl`/`publicKey`) as aliases, because those are the two spellings
 *     this product already has for the same three facts.
 *  2. **That JSON base64'd** into one unbroken token, with or without a scheme
 *     prefix. A single line survives a paste; four lines of JSON do not.
 *  3. **A URL** — `terminaldeck://server?r=…&h=…&k=…` — the shape the deleted
 *     pairing link had, minus the token that made it dangerous.
 *  4. **Anything containing all three**, found by scanning. A server that prints
 *     a labelled block with a heading and three rows is a server whose output a
 *     person will select a bit too much of, and refusing that paste teaches
 *     nothing.
 *
 * The scan is last and it is not a guess: a host id must be exactly 26
 * characters of the relay alphabet with a non-alphanumeric on both sides, a key
 * must *decode* to exactly 32 bytes, and a relay must be a `ws`/`wss` URL. What
 * it cannot do is tell one valid address from another if two are in the text, so
 * it takes the first of each — which is why the exact shapes are tried first.
 *
 * ## Every refusal names the fix
 *
 * `notAnAddress` is the only one that means "this is not it". The other three
 * mean "this is an address and *this field* is wrong", which is a different
 * sentence for a person holding a blob they believe is right — most often a
 * paste that stopped one line short.
 */

import Foundation

enum ServerAddressError: Error, Equatable {
    case empty
    case notAnAddress
    case relay
    case hostId
    case hostKey

    /// A sentence for the screen. No field name that only this file knows, and
    /// nothing that describes the parser instead of the situation.
    var detail: String {
        switch self {
        case .empty:
            return "Paste the server address first."
        case .notAnAddress:
            return "That is not a server address. One carries three things — a relay address, a "
                + "26-character host id, and the server's key — so copy the whole block rather than "
                + "one line of it."
        case .relay:
            return "The relay address in that block is not a WebSocket address. Copy the whole block again."
        case .hostId:
            return "The host id in that block is not 26 characters of the server alphabet. Copy the "
                + "whole block again."
        case .hostKey:
            return "The server key in that block is not 32 bytes. Copy the whole block again — a key "
                + "usually loses its end when a line wraps."
        }
    }
}

enum ServerAddress {

    /**
     * The most this will read.
     *
     * Nothing here is a security boundary — the handshake is — but a paste is
     * whatever was on the clipboard, and walking a megabyte of it on the main
     * thread while somebody watches a text field is its own small failure. Four
     * kilobytes is an order of magnitude more than the longest real address.
     */
    static let maxBytes = 4 * 1024

    /// What a person pasted, as somewhere to dial — or the reason it is not.
    static func parse(_ raw: String) -> Result<DeckEndpoint, ServerAddressError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.utf8.count <= maxBytes else { return .failure(.notAnAddress) }

        // The exact shapes first, the scan last: only the exact shapes can tell
        // which of two addresses in one paste was meant.
        if let parts = fromJSON(trimmed) ?? fromJSON(unwrapped(trimmed) ?? "") { return build(parts) }
        if let parts = fromURL(trimmed) { return build(parts) }
        if let parts = byScanning(trimmed) { return build(parts) }
        return .failure(.notAnAddress)
    }

    /// The three facts as they were written down, before any of them is believed.
    private struct Parts {
        var relay: String?
        var hostId: String?
        var hostKey: String?

        var isComplete: Bool { relay != nil && hostId != nil && hostKey != nil }
    }

    /**
     * The one place a candidate becomes an endpoint.
     *
     * Field by field, each with its own refusal, because "that address is wrong"
     * is not a thing anybody can act on and "the key is short" is.
     */
    private static func build(_ parts: Parts) -> Result<DeckEndpoint, ServerAddressError> {
        guard let relay = parts.relay, let url = relayURL(relay) else { return .failure(.relay) }
        guard let hostId = parts.hostId, PairingCodeParser.isHostId(hostId) else { return .failure(.hostId) }
        guard let key = parts.hostKey, let bytes = keyBytes(key) else { return .failure(.hostKey) }
        return .success(.relay(url: url, hostId: hostId, hostKey: bytes))
    }

    /* ---------------------------------------------------------------- URLs -- */

    /**
     * A relay address, checked the way `isRelayUrl` in `shared/pairing-link.ts`
     * checks one.
     *
     * `ws://` is allowed beside `wss://` for the same reason it is there: a relay
     * running on the machine itself, for its own tests. Nothing is downgraded by
     * it — everything inside the channel is sealed before it reaches the socket.
     */
    private static func relayURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "ws" || scheme == "wss", url.host != nil else { return nil }
        return url
    }

    /**
     * The 32 bytes behind a key, in any of the three ways this product writes them.
     *
     * base64url because a URL parameter has to be; standard base64 because
     * `machines/ipc.ts` re-encodes an offer's key that way; hex because a server
     * printing to a terminal often does. The two base64 alphabets are folded
     * rather than selected between — they differ in exactly two characters — and
     * the length is checked afterwards rather than trusted, because a key two
     * bytes short is a handshake that fails with nothing on screen to explain it.
     */
    static func keyBytes(_ raw: String) -> Data? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'"))
        if text.count == Sealed.keyBytes * 2, let hex = hexBytes(text) { return hex }
        var folded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = folded.count % 4
        if remainder > 0 { folded.append(String(repeating: "=", count: 4 - remainder)) }
        guard let bytes = Data(base64Encoded: folded), bytes.count == Sealed.keyBytes else { return nil }
        return bytes
    }

    private static func hexBytes(_ text: String) -> Data? {
        var out = Data()
        out.reserveCapacity(text.count / 2)
        var high: UInt8?
        for character in text {
            guard let digit = character.hexDigitValue, digit >= 0, digit < 16 else { return nil }
            if let first = high {
                out.append(first << 4 | UInt8(digit))
                high = nil
            } else {
                high = UInt8(digit)
            }
        }
        return high == nil ? out : nil
    }

    /* ---------------------------------------------------------------- JSON -- */

    /// The field names this product already uses for these three facts. Both
    /// spellings, because `endpoint.ts` and the rendezvous offer disagree and
    /// neither is wrong.
    private static let relayKeys = ["url", "relayurl", "relay", "relayaddress"]
    private static let hostIdKeys = ["hostid", "host", "id"]
    private static let hostKeyKeys = ["hostkey", "publickey", "key", "pubkey"]

    private static func fromJSON(_ text: String) -> Parts? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else { return nil }
        if let parts = read(object), parts.isComplete { return parts }
        // One level in, and one only. A server that prints its address under a
        // heading — `{"server": {…}}` — is describing the same three facts, and
        // walking arbitrarily deep would be walking a stranger's document.
        for value in object.values {
            guard let nested = value as? [String: Any], let parts = read(nested), parts.isComplete else { continue }
            return parts
        }
        return nil
    }

    /// Case-insensitive, because a JSON key is whatever the thing that printed it
    /// felt like, and this is reading rather than writing.
    private static func read(_ object: [String: Any]) -> Parts? {
        var lowered: [String: String] = [:]
        for (key, value) in object {
            guard let text = value as? String else { continue }
            lowered[key.lowercased()] = text
        }
        var parts = Parts()
        parts.relay = relayKeys.compactMap { lowered[$0] }.first
        parts.hostId = hostIdKeys.compactMap { lowered[$0] }.first
        parts.hostKey = hostKeyKeys.compactMap { lowered[$0] }.first
        return parts
    }

    /**
     * A one-token blob, unwrapped.
     *
     * A server address is four lines of JSON, and four lines do not survive a
     * paste into a chat, a terminal that wraps, or a person selecting with a
     * finger. One unbroken token does. The prefix — `td1:`, `terminaldeck:` or
     * none — is dropped rather than required, because this reads whatever
     * arrives and the thing after the colon is the only part that carries
     * anything.
     */
    private static func unwrapped(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var body = text
        if let colon = body.firstIndex(of: ":"), !body.hasPrefix("{") {
            let after = body[body.index(after: colon)...]
            // A `//` after the colon is a URL, which shape 3 reads; anything else
            // is a label in front of a blob.
            if !after.hasPrefix("//") { body = String(after) }
        }
        body.removeAll { $0.isWhitespace }
        guard !body.isEmpty, body.count <= maxBytes else { return nil }
        var folded = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = folded.count % 4
        if remainder > 0 { folded.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: folded), let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /* ----------------------------------------------------------------- URL -- */

    /// The query-parameter shape, in either spelling. `v` is read and ignored:
    /// there has only ever been one version of these three fields, and refusing
    /// an address because it announced itself would be refusing the future.
    private static func fromURL(_ text: String) -> Parts? {
        guard text.contains("://"), let components = URLComponents(string: text) else { return nil }
        let items = (components.queryItems ?? []) + fragmentItems(components.fragment)
        guard !items.isEmpty else { return nil }
        var lowered: [String: String] = [:]
        for item in items {
            guard let value = item.value, !value.isEmpty else { continue }
            lowered[item.name.lowercased()] = value
        }
        var parts = Parts()
        parts.relay = (["r"] + relayKeys).compactMap { lowered[$0] }.first
        parts.hostId = (["h"] + hostIdKeys).compactMap { lowered[$0] }.first
        parts.hostKey = (["k"] + hostKeyKeys).compactMap { lowered[$0] }.first
        return parts.isComplete ? parts : nil
    }

    /// `#r=…&h=…&k=…`, because a fragment never leaves the device it is pasted
    /// into — which is the right place for an address that names a machine, even
    /// one carrying no secret.
    private static func fragmentItems(_ fragment: String?) -> [URLQueryItem] {
        guard let fragment, !fragment.isEmpty else { return [] }
        return fragment.split(separator: "&").compactMap { pair in
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { return nil }
            return URLQueryItem(name: String(halves[0]),
                                value: String(halves[1]).removingPercentEncoding ?? String(halves[1]))
        }
    }

    /* -------------------------------------------------------------- Scanning -- */

    /**
     * The three facts, found wherever they are.
     *
     * The last resort, and the one that makes a labelled block pasted with its
     * heading work. Each candidate is held to the same rule the exact shapes are
     * held to, which is what keeps this from being a guess: a token is a host id
     * only if it is exactly 26 characters of the relay alphabet standing alone,
     * and a key only if it *decodes* to 32 bytes.
     *
     * Tokens are cut at every non-alphanumeric that is not part of an encoding,
     * so a 43-character base64 key cannot be mistaken for a 26-character host id
     * — the whole token is one run and the run is the wrong length.
     */
    private static func byScanning(_ text: String) -> Parts? {
        var parts = Parts()

        if let range = text.range(of: "wss://") ?? text.range(of: "ws://") {
            let tail = text[range.lowerBound...]
            let end = tail.firstIndex { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "," || $0 == ">" }
            parts.relay = String(tail[..<(end ?? tail.endIndex)])
        }

        for token in tokens(in: text) {
            if parts.hostId == nil, token.count == 26, PairingCodeParser.isHostId(token) {
                parts.hostId = token
                continue
            }
            // Held off until the host id is settled: the alphabets overlap, and a
            // 26-character run that is a valid host id must not be spent as a key
            // candidate that will fail the length check anyway.
            if parts.hostKey == nil, token.count >= 43, keyBytes(token) != nil {
                parts.hostKey = token
                continue
            }
            if parts.hostKey == nil, token.count == Sealed.keyBytes * 2, keyBytes(token) != nil {
                parts.hostKey = token
            }
        }

        return parts.isComplete ? parts : nil
    }

    /// Runs of the characters an encoded field can contain, split on everything
    /// else. `=` rides along because it is base64 padding at the end of a key.
    private static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber
                                     || character == "-" || character == "_" || character == "+"
                                     || character == "/" || character == "=") {
                current.append(character)
                continue
            }
            if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
