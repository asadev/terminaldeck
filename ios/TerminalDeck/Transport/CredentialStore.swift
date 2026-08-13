/**
 * What this phone holds about a Mac, and where it holds it.
 *
 * Three secrets, and they are not the same kind of secret:
 *
 *  1. **The credential.** A bearer token that grants a shell on someone's Mac.
 *     Whoever has the bytes is the device, so it lives in the Keychain and
 *     nowhere else — not `UserDefaults`, not a plist, not a file in Documents,
 *     all of which are in the unencrypted backup and readable by anything that
 *     gets a look at the container.
 *  2. **The device's static X25519 private key.** The other half of the sealed
 *     channel's identity. Generated once, never leaves the device, never sent —
 *     only its public half goes to the Mac at pairing time.
 *  3. **The Mac's static public key.** Not secret at all, and stored beside the
 *     credential anyway: it is what stops the relay answering in the Mac's
 *     place, so losing it is losing the authentication of the desktop.
 *
 * ## Accessibility, chosen rather than defaulted
 *
 * `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
 *
 *  - *AfterFirstUnlock* because a reconnect has to work with the phone in a
 *    pocket. `WhenUnlocked` would make every background reconnect fail, and the
 *    app would look broken exactly when it is most useful.
 *  - *ThisDeviceOnly* because the alternative puts a shell credential in an
 *    iCloud Keychain backup and onto every other device on the account. Pairing
 *    is per device on purpose — the Mac approves *this* phone by name — and an
 *    item that syncs quietly undoes that.
 *
 * ## Why the whole record is one item
 *
 * The credential and the endpoint it belongs to are only meaningful together: a
 * token for a host id that is not stored beside it is a secret nobody can spend,
 * and an endpoint without its token sends the app to a Mac it cannot greet. One
 * item, written and cleared atomically, cannot be half of a pairing.
 */

import Foundation
import Security

/**
 * A credential and where to spend it.
 *
 * `kind` is recorded rather than sniffed. `device-auth.ts` decides what a token
 * is by looking for a `.` in it, which is true of the credentials it mints today
 * and is not this app's business to depend on: what matters here is whether this
 * token has already been redeemed, because a *pairing* token that gets refused
 * means the pairing failed and the user must scan again, while a *device*
 * credential that gets refused means the Mac has not approved the device yet and
 * the right move is to keep waiting. Guessing wrong sends the user to the wrong
 * screen at the worst moment.
 */
struct StoredCredential: Equatable, Codable {
    enum Kind: String, Codable {
        /// Single-use, from a QR code. Worth 60 seconds and one redemption.
        case pairing
        /// Durable, minted by the Mac in the `welcome` that answered a pairing.
        case device
    }

    let endpoint: DeckEndpoint
    /// Opaque here: this app never parses it.
    let token: String
    let kind: Kind
    let deviceId: String
    let deviceName: String
    let pairedAt: Date

    func redeemed(token: String, deviceId: String, deviceName: String) -> StoredCredential {
        StoredCredential(endpoint: endpoint, token: token, kind: .device,
                         deviceId: deviceId, deviceName: deviceName, pairedAt: Date())
    }
}

@MainActor
protocol CredentialStore: AnyObject {
    func load() -> StoredCredential?
    func save(_ credential: StoredCredential)
    /// Called when the desktop says the credential is no longer good. Clearing
    /// it is what turns the next launch into a pairing flow rather than five
    /// more refused attempts against a lockout counter.
    func clear()

    /**
     * This device's static identity for the sealed channel, made on first use.
     *
     * Kept here rather than in the transport because it must outlive every
     * connection and every re-pair against the same Mac: the Mac remembers the
     * device by this public key, and regenerating it turns a known phone into a
     * stranger that has to be approved again.
     */
    func deviceKeys() -> StaticKeyPair
}

/* -------------------------------------------------------------------------- */
/* Keychain                                                                    */
/* -------------------------------------------------------------------------- */

@MainActor
final class KeychainCredentialStore: CredentialStore {

    private let service: String
    private let credentialAccount = "credential.v1"
    private let deviceKeyAccount = "device-static-key.v1"

    /// Read once per launch and kept, because `load()` is called on every
    /// reconnect and a Keychain lookup while the app is coming out of the
    /// background is not free. Writes go through both.
    private var cached: StoredCredential?
    private var cachedKeys: StaticKeyPair?
    private var loaded = false

    /// `service` is a parameter so the tests can use their own drawer instead of
    /// the one the running app pairs into.
    init(service: String = "\(Brand.bundleID).remote") {
        self.service = service
    }

    /// Only the tests read this, to open a second store over the same drawer and
    /// prove a write really reached the Keychain rather than the cache.
    var serviceForTesting: String { service }

    func load() -> StoredCredential? {
        if loaded { return cached }
        loaded = true
        guard let data = read(account: credentialAccount) else { return nil }
        // A record written by an older shape of this struct decodes to nothing,
        // which reads as unpaired — the honest answer, and it sends the user to
        // the pairing screen rather than into a login that fails forever.
        cached = try? JSONDecoder().decode(StoredCredential.self, from: data)
        return cached
    }

    func save(_ credential: StoredCredential) {
        cached = credential
        loaded = true
        guard let data = try? JSONEncoder().encode(credential) else { return }
        write(account: credentialAccount, data: data)
    }

    func clear() {
        cached = nil
        loaded = true
        delete(account: credentialAccount)
        // The device key deliberately survives. It is not a credential — it is
        // this phone's name in the sealed channel — and keeping it means
        // re-pairing with the same Mac does not create a second entry in its
        // device list for the same physical phone.
    }

    func deviceKeys() -> StaticKeyPair {
        if let cachedKeys { return cachedKeys }
        if let raw = read(account: deviceKeyAccount), let keys = StaticKeyPair(privateKey: raw) {
            cachedKeys = keys
            return keys
        }
        let fresh = StaticKeyPair.generate()
        write(account: deviceKeyAccount, data: fresh.privateKey)
        cachedKeys = fresh
        return fresh
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
        // Update first, add if there was nothing: `SecItemAdd` on an existing
        // account returns `errSecDuplicateItem` and writes nothing, which is how
        // a credential silently stops being refreshed after the first pairing.
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

    /// Only the tests call this: it removes the device key as well, which the
    /// app must never do to a phone somebody has paired.
    func eraseEverything() {
        cached = nil
        cachedKeys = nil
        loaded = false
        delete(account: credentialAccount)
        delete(account: deviceKeyAccount)
    }
}
