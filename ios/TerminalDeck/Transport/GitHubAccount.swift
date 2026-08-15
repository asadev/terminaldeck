/**
 * The one GitHub account this phone holds, and the drawer it holds it in.
 *
 * This is the whole of "their token stays on their device". A session on
 * somebody else's machine gets no git credentials of its own — the desktop's
 * `git-guest.ts` sees to that — so when git over there needs a login it asks
 * over the sealed channel, and what answers is this. The token is read out of
 * the Keychain, put into one reply, and is never written anywhere else: not to
 * the host's disk, not to a file here, not to a log.
 *
 * ## A different drawer from the pairings, on purpose
 *
 * `KeychainCredentialStore` sweeps its own service with `kSecMatchLimitAll` to
 * recover the list of paired machines — the query *is* the list, so there is no
 * index to fall out of step with it. An item of a different kind living in that
 * service would be a row in that sweep that has to be recognised and skipped,
 * and the day somebody adds a second one the skipping is a filter with two rules
 * in it. A separate service costs one string and keeps that query meaning
 * exactly one thing.
 *
 * It also means the two are forgotten independently, which is the behaviour a
 * person expects: unpairing a Mac must not sign them out of GitHub, and
 * disconnecting GitHub must not cost them their machines.
 *
 * ## Accessibility, chosen rather than defaulted
 *
 * `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the same as the pairings
 * next door and for a sharper reason. A **read** — a fetch, a pull, a clone — is
 * answered silently, with nobody looking at the phone, and a `git fetch` on a
 * laptop must not stall because the phone in a pocket has locked itself.
 * `WhenUnlocked` would make exactly those requests fail, at the moment the
 * feature is most useful, with a sentence about the device not being reachable
 * that is true and completely misleading.
 *
 * `ThisDeviceOnly` because the alternative puts a GitHub token with `repo` scope
 * into an iCloud Keychain backup and onto every other device on the account. The
 * whole claim of this feature is that the token is on *this* device; an item that
 * syncs quietly makes that false.
 *
 * ## What is not here
 *
 * No cache of which repositories have been approved. The desktop remembers that
 * — in memory, for as long as its app is running — and a copy on this side would
 * be a second answer to "has this been approved" with no way to reconcile the
 * two. What this phone remembers is one account; what it consents to is one
 * request at a time.
 */

import Foundation
import Security

/**
 * The account, minus the secret.
 *
 * Split from the token deliberately: everything on screen reads this, and
 * nothing on screen has any business holding the bytes that grant a push. The
 * token is fetched, by name, at the one call site that answers a request.
 */
struct GitHubAccount: Equatable, Codable {
    /// How the token got here. Recorded rather than inferred, because the two
    /// have different failure modes and the fix a person needs is different:
    /// a device-flow token is revoked in GitHub's application settings, and a
    /// personal access token is revoked in its own list and expires on a date.
    enum Source: String, Codable {
        /// Signed in through GitHub's device flow, in a browser on this phone.
        case signIn
        /// A personal access token, pasted in. The fallback the design keeps on
        /// purpose, for somebody who wants one repository and an expiry date.
        case token
    }

    /// The login, as GitHub itself reported it. Never typed by the user — a
    /// name somebody typed is a name the prompt could get wrong, and the prompt
    /// is the whole explanation of this feature.
    let login: String
    let source: Source
    let connectedAt: Date
}

@MainActor
protocol GitHubAccountStore: AnyObject {
    /// The account on screen, or nil when nothing is connected.
    var account: GitHubAccount? { get }

    /**
     * The secret, read from the Keychain at the moment it is needed.
     *
     * Deliberately a function rather than a property on `GitHubAccount`: the
     * bytes exist in this process for the length of one reply, and a struct that
     * carried them would be copied into every view that draws the account name.
     */
    func token() -> String?

    /// Connect, or replace what is connected. One account at a time — a phone
    /// with two GitHub logins would need a picker on the approval prompt, and a
    /// prompt with a picker on it is no longer a question with an obvious answer.
    func connect(login: String, token: String, source: GitHubAccount.Source)

    /// Forget the account and the token. The revocation that works from here:
    /// nothing on this phone can answer a credential request afterwards.
    func disconnect()
}

/* -------------------------------------------------------------------------- */
/* Keychain                                                                    */
/* -------------------------------------------------------------------------- */

@MainActor
final class KeychainGitHubStore: GitHubAccountStore {

    private let service: String
    /// Two items, not one. The description is read on every draw of the account
    /// screen and the secret is read once per credential request, so keeping
    /// them apart means the common read never has the token in a buffer at all.
    private let accountItem = "github-account.v1"
    private let tokenItem = "github-token.v1"

    /// Read once and kept, because `account` is read by SwiftUI on every
    /// rebuild and a Keychain round trip per frame is not free. The token is
    /// **not** cached; see `token()`.
    private var cached: GitHubAccount?
    private var loaded = false

    /// `service` is a parameter so the tests use their own drawer rather than
    /// the one a person's real GitHub login is in.
    init(service: String = "\(Brand.bundleID).github") {
        self.service = service
    }

    /// Only the tests read this, to open a second store over the same drawer and
    /// prove a write really reached the Keychain rather than the cache.
    var serviceForTesting: String { service }

    var account: GitHubAccount? {
        if !loaded {
            loaded = true
            if let data = read(account: accountItem) {
                cached = try? JSONDecoder().decode(GitHubAccount.self, from: data)
            }
        }
        return cached
    }

    /**
     * Read the token, every time, and never keep it.
     *
     * The Keychain read costs microseconds and happens at most once per `git`
     * invocation. What it buys is that the bytes are not sitting in this
     * process's heap between pushes, which is the difference between a token
     * that lives on the device and a token that lives in an app.
     */
    func token() -> String? {
        guard let data = read(account: tokenItem) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func connect(login: String, token: String, source: GitHubAccount.Source) {
        let record = GitHubAccount(login: login, source: source, connectedAt: Date())
        // The secret first. A process killed between the two writes comes back
        // with a token nothing describes, which reads as "not connected" and is
        // recoverable by connecting again — where the other order would show an
        // account whose every answer fails with no way to tell why.
        write(account: tokenItem, data: Data(token.utf8))
        guard let data = try? JSONEncoder().encode(record) else { return }
        write(account: accountItem, data: data)
        cached = record
        loaded = true
    }

    func disconnect() {
        // The secret first here as well, and for the mirror-image reason: an
        // interrupted disconnect must never leave a token behind that no screen
        // in this app knows about.
        delete(account: tokenItem)
        delete(account: accountItem)
        cached = nil
        loaded = true
    }

    // MARK: - The four lines of Security.framework this needs

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(account: String, data: Data) {
        // Update first, add if there was nothing. `SecItemAdd` on an account
        // that exists returns `errSecDuplicateItem` and writes nothing, which is
        // how a token silently stops being refreshed after the first sign-in —
        // the same trap `KeychainCredentialStore` documents next door.
        let updated = SecItemUpdate(query(account: account) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }

        var request = query(account: account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(request as CFDictionary, nil)
    }

    private func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
