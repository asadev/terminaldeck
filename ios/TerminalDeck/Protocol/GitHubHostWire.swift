/**
 * The host's GitHub login, as this phone sees it on the wire.
 *
 * The account lives on the machine now, not on the phone — a re-architecture of
 * what used to be the phone-side credential proxy. So this shape is *read only*
 * here: it is the whole of what a `github.state` or a `github.changed` frame
 * carries, and the phone never composes it, only renders it. The four verbs the
 * phone sends (`github.read/connect/cancel/disconnect`) carry nothing but a
 * `rid`; everything a screen draws comes back inside this.
 *
 * A port of `GitHubHostWire` in `src/main/remote/protocol.ts`, and it changes
 * when that file changes, with the same fields and the same meanings. The client
 * is `GitHubLink`; the screen is `ConnectGitHubView`.
 *
 * ## The fields, and which state each belongs to
 *
 *  - **Connected.** `connected` is true, `login` names the account, and `name`
 *    and `avatarUrl` are the profile if the host has them. `source` is how the
 *    host got there (a device-flow sign-in, a token) — display text, not a
 *    branch. `disconnect` is shown, if set, as the last sign-out's outcome.
 *  - **Not connected, ready to connect.** `connected` is false, `appConfigured`
 *    is true, and `pending` is nil. The screen offers a Connect button.
 *  - **Signing in.** `pending` holds the `userCode` and the `verificationUri`
 *    to open, and the `expiresAt` after which the code is dead. The screen shows
 *    the code with copy and open-in-browser, and a Cancel.
 *  - **The host has no GitHub App configured.** `appConfigured` is false, and
 *    `failure` is the sentence saying so. No Connect button is drawn — there is
 *    nothing behind it — so the screen shows only the sentence.
 *  - **Something failed.** `failure` is set, and shown, on top of whatever else
 *    the frame carries.
 */

import Foundation

/// Bounds on the strings this frame carries, so a garbled or hostile frame is
/// clipped rather than drawn at full length. Generous, because these are names
/// and URLs GitHub issues and sentences the host writes, not fields this phone
/// has any reason to pin tightly.
enum GitHubWireLimits {
    static let login = 128
    static let name = 128
    static let source = 64
    static let url = 2048
    static let userCode = 32
    static let sentence = 512
}

/**
 * A sign-in in flight on the host: the code a person types, where they type it,
 * and when it dies.
 *
 * `verificationURI` is opened in a browser rather than shown as text to type,
 * and `userCode` is shown as text rather than folded into the URL — the same
 * split the old phone-side flow kept, because GitHub's `verification_uri_complete`
 * fills the field in for you, which makes a link that grants access if it is
 * forwarded.
 */
struct GitHubPending: Equatable {
    let userCode: String
    let verificationURI: URL
    /// When GitHub's code expires. From `expiresAt` on the wire, an epoch in
    /// **milliseconds**, so the screen can say a flow has lapsed rather than
    /// showing a dead code.
    let expiresAt: Date
}

struct GitHubHostWire: Equatable {
    let connected: Bool
    let login: String?
    let name: String?
    let avatarURL: String?
    /// How the host got its token, as display text — never branched on.
    let source: String?
    /// Whether the host even has a GitHub App to sign into. When false there is
    /// no Connect button to draw; `failure` says why.
    let appConfigured: Bool
    /// Where a person chooses which repositories the host's App may touch. Shown
    /// as a link on a connected account, when the host provides one.
    let installURL: String?
    /// A sign-in in flight on the host, or nil.
    let pending: GitHubPending?
    /// A sentence about the last thing that went wrong, or nil.
    let failure: String?
    /// A sentence about the last sign-out, or nil.
    let disconnect: String?

    /// Nothing connected, nothing configured — the shape used when a frame could
    /// not be read at all, so a screen has something honest to draw rather than
    /// a crash.
    static let empty = GitHubHostWire(connected: false, login: nil, name: nil,
                                      avatarURL: nil, source: nil, appConfigured: false,
                                      installURL: nil, pending: nil, failure: nil,
                                      disconnect: nil)
}

extension WireCodec {
    /**
     * One `GitHubHostWire` off an inbound frame's `github` field.
     *
     * Lenient on every field for the reason the rest of this codec is: one bad
     * value is clipped or dropped rather than discarding the frame. `nil` is
     * returned only when the value is not an object at all — a `github.state`
     * without a `github` object is a malformed frame, and the decode arm refuses
     * it rather than inventing a state.
     */
    static func gitHubHost(_ value: Any?) -> GitHubHostWire? {
        guard let object = value as? [String: Any] else { return nil }

        func bounded(_ any: Any?, _ limit: Int) -> String? {
            guard let text = string(any) else { return nil }
            return String(text.prefix(limit))
        }

        return GitHubHostWire(
            connected: object["connected"] as? Bool == true,
            login: bounded(object["login"], GitHubWireLimits.login),
            name: bounded(object["name"], GitHubWireLimits.name),
            avatarURL: bounded(object["avatarUrl"], GitHubWireLimits.url),
            source: bounded(object["source"], GitHubWireLimits.source),
            appConfigured: object["appConfigured"] as? Bool == true,
            installURL: bounded(object["installUrl"], GitHubWireLimits.url),
            pending: gitHubPending(object["pending"]),
            failure: displayLine(object["failure"]).map { String($0.prefix(GitHubWireLimits.sentence)) },
            disconnect: displayLine(object["disconnect"]).map { String($0.prefix(GitHubWireLimits.sentence)) })
    }

    /**
     * The `pending` sub-object, or nil.
     *
     * Every field is required: a code with no URL to type it into, or a URL with
     * no code, is not a flow a person can complete, so a half-built `pending` is
     * dropped rather than drawn. `expiresAt` is an epoch in **milliseconds** — a
     * bool bridges to `NSNumber` too, so it is read through the same guard the
     * rest of this codec uses for numbers.
     */
    private static func gitHubPending(_ value: Any?) -> GitHubPending? {
        guard let object = value as? [String: Any],
              let code = string(object["userCode"]), !code.isEmpty,
              let uriString = string(object["verificationUri"]),
              let uri = URL(string: uriString), uri.host != nil else { return nil }
        guard let number = object["expiresAt"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let millis = number.doubleValue
        guard millis.isFinite, millis > 0 else { return nil }
        return GitHubPending(userCode: String(code.prefix(GitHubWireLimits.userCode)),
                             verificationURI: uri,
                             expiresAt: Date(timeIntervalSince1970: millis / 1000))
    }
}
