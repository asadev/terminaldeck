/**
 * What this phone holds about **every** machine it is paired with, and where it
 * holds it.
 *
 * Three kinds of secret, and they are not the same kind:
 *
 *  1. **The credentials.** Bearer tokens, each granting a shell on somebody's
 *     machine. Whoever has the bytes is the device, so they live in the Keychain
 *     and nowhere else — not `UserDefaults`, not a plist, not a file in
 *     Documents, all of which are in the unencrypted backup and readable by
 *     anything that gets a look at the container.
 *
 *     There used to be a **fourth**: a per-machine *copilot credential*, in this
 *     same item, minted by redeeming a six-digit code and worth exactly what the
 *     pairing one is worth. It is gone — pairing a device as **My device** is
 *     the copilot's authorisation now, so nothing is minted and nothing is kept
 *     — and `hydrate()` scrubs the field out of any record an older build wrote,
 *     because a secret nobody can revoke is worse than one nobody is using.
 *  2. **The device's static X25519 private key.** The other half of the sealed
 *     channel's identity. Generated once, never leaves the device, never sent —
 *     only its public half goes to a host at pairing time. **One key for all
 *     hosts**, deliberately: it is this phone's name, and a per-host key would
 *     mean re-approving the same physical phone on a machine it is already
 *     paired with.
 *  3. **Each host's static public key.** Not secret at all, and stored beside
 *     its credential anyway: it is what stops the relay answering in that host's
 *     place, so losing it is losing the authentication of the desktop.
 *
 * ## One item per host, not one item holding all of them
 *
 * The obvious design is a single Keychain item holding a JSON array. It is the
 * wrong one, and the reason is the failure this whole feature has to be designed
 * against: **a phone that appears to have forgotten a machine**. A single blob
 * has a single decode, so one record written by an older shape of this struct —
 * or one truncated write — reads as *no pairings at all*, and every paired Mac
 * and PC disappears at once. One item per host makes that failure local: the
 * unreadable one is skipped and named, and the others are untouched.
 *
 * There is no index item either, for the same reason. The list is read back out
 * of the Keychain itself with `kSecMatchLimitAll`, so there is no second
 * structure that can disagree with the first about which hosts exist.
 *
 * ## Accessibility, chosen rather than defaulted
 *
 * `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
 *
 *  - *AfterFirstUnlock* because a reconnect has to work with the phone in a
 *    pocket. `WhenUnlocked` would make every background reconnect fail, and the
 *    app would look broken exactly when it is most useful.
 *  - *ThisDeviceOnly* because the alternative puts shell credentials in an
 *    iCloud Keychain backup and onto every other device on the account. Pairing
 *    is per device on purpose — each host approves *this* phone by name — and an
 *    item that syncs quietly undoes that.
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
 * credential that gets refused means the host has not approved the device yet
 * and the right move is to keep waiting. Guessing wrong sends the user to the
 * wrong screen at the worst moment.
 */
struct StoredCredential: Equatable, Codable {
    enum Kind: String, Codable {
        /// Single-use, from a QR code. Worth 60 seconds and one redemption.
        case pairing
        /// Durable, minted by the host in the `welcome` that answered a pairing.
        case device
    }

    let endpoint: DeckEndpoint
    /// Opaque here: this app never parses it.
    let token: String
    let kind: Kind
    let deviceId: String
    let deviceName: String
    let pairedAt: Date

    /**
     * What the user calls this machine, if they have renamed it.
     *
     * Nil is the normal state and the label falls back to the endpoint. It
     * exists because a host id is 26 characters of base32 and a relay address is
     * the same for every host behind it — neither is something a person can pick
     * their laptop out of a list by, and picking the right machine out of a list
     * is the whole of this feature.
     *
     * Optional with a default so that a record written before this field existed
     * still decodes. A `StoredCredential` that fails to decode is a host that has
     * vanished from the phone, which is precisely the outcome this design is for
     * avoiding.
     */
    var nickname: String?

    /**
     * What the machine calls **itself** — its hostname, off `welcome.hostName`.
     *
     * Not a nickname and must not be confused with one: a nickname is the
     * person's word and always wins; this is the machine's own and is only ever
     * a default. It exists because the fallback below is `endpoint.shortName`,
     * which for a relay pairing is the relay slot code — `2JJGF8`, `9ZA6K3` —
     * and those name nothing anybody owns.
     *
     * Written on **every** connection rather than at pairing, which is the whole
     * point: a machine paired before this field existed has nil here, and the
     * pairing link that would have supplied a name is read once, at the desk. So
     * the name arrives on the next socket instead of the next pairing.
     *
     * Optional with a default so a record written before this field existed
     * still decodes — the same rule `nickname` above states, and for the same
     * reason: a `StoredCredential` that fails to decode is a host that has
     * vanished from the phone.
     */
    var hostName: String?

    /*
     * **`copilotCredential` used to be here, and is deliberately not any more.**
     *
     * It was a second secret with a separate life: minted by redeeming six
     * digits read off that machine, revoked separately from the pairing, and
     * sent exactly once because the desktop kept only a scrypt hash of it.
     * `COPILOT-REMOTE.md` §6 argued the separation at length.
     *
     * Asad deleted the ceremony on 2026-08-19 — *"if we are connecting as my
     * device copilot automatically comes, if we connect as guest then copilot
     * don't come"* — so there is nothing to mint, nothing to type and nothing to
     * store. Dropping the field from this struct is safe in both directions:
     * `JSONDecoder` ignores a key it has no property for, so a record written by
     * the previous build still decodes and still names its machine, which is the
     * one failure this whole file is designed against.
     *
     * The bytes do **not** stay in the Keychain, though — see the scrub in
     * `KeychainCredentialStore.hydrate()`. A live-looking credential sitting in
     * an item with no code left in the app that reads it is a secret nobody
     * would think to revoke.
     */

    /// Which machine this is. Stable across re-pairings with the same host.
    var hostId: String { endpoint.hostId }

    /// What the switcher shows: the user's name for it, then the machine's own,
    /// then the endpoint's — which for a relay pairing is a slot code.
    var label: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespaces).isEmpty { return nickname }
        if let hostName, !hostName.trimmingCharacters(in: .whitespaces).isEmpty { return hostName }
        return endpoint.shortName
    }

    /// The durable credential, from a redeemed pairing. A re-pair mints a new
    /// device id, so nothing about the old device — including whether its owner
    /// had approved it as his own — is carried across; that question is answered
    /// again, at the machine, on the approval screen.
    func redeemed(token: String, deviceId: String, deviceName: String) -> StoredCredential {
        StoredCredential(endpoint: endpoint, token: token, kind: .device,
                         deviceId: deviceId, deviceName: deviceName, pairedAt: Date(),
                         nickname: nickname, hostName: hostName)
    }

    func renamed(_ name: String?) -> StoredCredential {
        StoredCredential(endpoint: endpoint, token: token, kind: kind,
                         deviceId: deviceId, deviceName: deviceName, pairedAt: pairedAt,
                         nickname: name, hostName: hostName)
    }

    /// The machine said what it calls itself. The person's nickname is untouched.
    func hostNamed(_ name: String) -> StoredCredential {
        StoredCredential(endpoint: endpoint, token: token, kind: kind,
                         deviceId: deviceId, deviceName: deviceName, pairedAt: pairedAt,
                         nickname: nickname, hostName: name)
    }
}

@MainActor
protocol CredentialStore: AnyObject {

    /**
     * Every machine this phone is paired with, oldest pairing first.
     *
     * Order is stable rather than "most recent", because it is the order of a
     * list somebody learns the shape of — a switcher that reshuffles itself is a
     * switcher people tap the wrong row in.
     */
    func all() -> [StoredCredential]

    /// One host, by id. Nil when this phone is not paired with it.
    func load(_ hostId: String) -> StoredCredential?

    /**
     * Add a host, or update the one with this id.
     *
     * **Never touches any other host.** This is the whole of the multi-host
     * requirement and the one thing that must not regress: a phone that pairs
     * with a second machine and loses the first looks exactly like a phone that
     * forgot your Mac.
     */
    func save(_ credential: StoredCredential)

    /// Forget one machine. The others, and the device key, survive.
    func remove(_ hostId: String)

    /// Forget every machine. The device key survives — see `deviceKeys`.
    func clearAll()

    /**
     * This device's static identity for the sealed channel, made on first use.
     *
     * Kept here rather than in a transport because it must outlive every
     * connection, every host and every re-pair: a host remembers the device by
     * this public key, and regenerating it turns a known phone into a stranger
     * that has to be approved again — on *all* of them at once.
     */
    func deviceKeys() -> StaticKeyPair
}

/* -------------------------------------------------------------------------- */
/* Keychain                                                                    */
/* -------------------------------------------------------------------------- */

@MainActor
final class KeychainCredentialStore: CredentialStore {

    private let service: String
    /// One account per host. The id is appended, so the list can be recovered
    /// from the Keychain without a second structure to keep in step.
    private let hostPrefix = "host.v1."
    /// The single-host account this store used before it could hold more than
    /// one. Read once and folded in; see `migrate`.
    private let legacyAccount = "credential.v1"
    private let deviceKeyAccount = "device-static-key.v1"

    /// Read once per launch and kept, because the list is consulted on every
    /// reconnect of every host and a Keychain sweep while the app is coming out
    /// of the background is not free. Writes go through both.
    private var cached: [String: StoredCredential] = [:]
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

    /**
     * Records that are in the Keychain and could not be decoded.
     *
     * Surfaced rather than swallowed. A host that silently disappears is the
     * exact complaint this design exists to prevent, so when one cannot be read
     * the app is able to say "one pairing could not be read" instead of quietly
     * showing a shorter list.
     */
    private(set) var unreadable = 0

    func all() -> [StoredCredential] {
        hydrate()
        return cached.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    func load(_ hostId: String) -> StoredCredential? {
        hydrate()
        return cached[hostId]
    }

    func save(_ credential: StoredCredential) {
        hydrate()
        cached[credential.hostId] = credential
        guard let data = try? JSONEncoder().encode(credential) else { return }
        write(account: account(for: credential.hostId), data: data)
    }

    func remove(_ hostId: String) {
        hydrate()
        cached.removeValue(forKey: hostId)
        delete(account: account(for: hostId))
    }

    func clearAll() {
        hydrate()
        for hostId in cached.keys { delete(account: account(for: hostId)) }
        cached = [:]
        // The device key deliberately survives. It is not a credential — it is
        // this phone's name in the sealed channel — and keeping it means
        // re-pairing with the same machine does not create a second entry in its
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

    // MARK: - Reading the drawer

    private func account(for hostId: String) -> String { "\(hostPrefix)\(hostId)" }

    private func hydrate() {
        if loaded { return }
        loaded = true

        for (account, data) in readAll() {
            guard account.hasPrefix(hostPrefix) else { continue }
            guard let record = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
                // Kept on disk rather than deleted. A record this build cannot
                // read may be one a *newer* build can — a phone rolled back for
                // an afternoon should not permanently lose the pairing it made
                // while it was ahead.
                unreadable += 1
                continue
            }
            cached[record.hostId] = record
            scrubCopilotCredential(account: account, raw: data, record: record)
        }

        migrate()
    }

    /**
     * **Erase a copilot credential an older build left in this item.**
     *
     * Between 2026-08-17 and 2026-08-19 a `StoredCredential` carried a second
     * secret beside the pairing one: the credential a six-digit connect code was
     * redeemed for. That ceremony is deleted — pairing a device as **My device**
     * is the copilot's authorisation now — and the property is gone from the
     * struct, which is enough for the app to stop *using* it: `JSONDecoder`
     * ignores a key it has no property for.
     *
     * It is **not** enough to stop it existing. Dropping the property leaves the
     * bytes sitting in the Keychain item forever, because nothing rewrites a
     * record that has not changed, and a live-looking credential nobody can
     * revoke because nobody knows it is there is precisely the thing the old
     * code was careful about in the other direction. So the raw JSON is checked
     * for the key on the way in, and one re-encode — of the record this build
     * has just decoded, which no longer has the field — replaces the item.
     *
     * Cheap by construction: `JSONSerialization` runs only when the substring is
     * present at all, which is once per machine on one launch after an upgrade
     * and never again. A failed write is not retried and not reported — the
     * record in memory is already correct either way, and this is a tidy-up of
     * something that has stopped being reachable, not a step somebody is waiting
     * on.
     */
    private func scrubCopilotCredential(account: String, raw: Data, record: StoredCredential) {
        guard let text = String(data: raw, encoding: .utf8), text.contains("copilotCredential"),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              object["copilotCredential"] != nil,
              let clean = try? JSONEncoder().encode(record) else { return }
        write(account: account, data: clean)
    }

    /**
     * Fold the single-host record into the collection.
     *
     * Runs once. The legacy item is removed only after the new one is written,
     * so a process killed between the two comes back with the pairing still
     * readable from the old account rather than from neither.
     *
     * A legacy record that will not decode is left exactly where it is: deleting
     * it would be this build destroying a pairing it merely could not read.
     */
    private func migrate() {
        guard let data = read(account: legacyAccount) else { return }
        guard let record = try? JSONDecoder().decode(StoredCredential.self, from: data) else { return }
        if cached[record.hostId] == nil {
            cached[record.hostId] = record
            if let encoded = try? JSONEncoder().encode(record) {
                write(account: account(for: record.hostId), data: encoded)
            } else {
                return
            }
        }
        delete(account: legacyAccount)
    }

    // MARK: - The five lines of Security.framework this needs

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

    /// Every item in this service, account name and all. The list of paired hosts
    /// *is* this query — there is no index to fall out of step with it.
    private func readAll() -> [(String, Data)] {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
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
        hydrate()
        for hostId in cached.keys { delete(account: account(for: hostId)) }
        cached = [:]
        cachedKeys = nil
        loaded = false
        unreadable = 0
        delete(account: legacyAccount)
        delete(account: deviceKeyAccount)
    }

    /// Only the tests call this: writes a record at the pre-multi-host account,
    /// so the migration can be exercised against a real Keychain.
    func writeLegacyRecordForTesting(_ credential: StoredCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        write(account: legacyAccount, data: data)
        loaded = false
        cached = [:]
    }

    /// Only the tests call this: writes one host's record as raw bytes, so a
    /// record in the shape an *older* build wrote — one carrying the copilot
    /// credential this struct no longer has a property for — can be put in the
    /// drawer and read back through the real code path. Composing it as JSON
    /// rather than as a string is what keeps it the format rather than a test's
    /// idea of the format.
    func writeRawRecordForTesting(hostId: String, data: Data) {
        write(account: account(for: hostId), data: data)
        loaded = false
        cached = [:]
    }

    /// Only the tests call this: the bytes actually in the drawer for one host,
    /// which is the only way to prove the scrub rewrote the item rather than
    /// merely declining to read a field.
    func rawRecordForTesting(hostId: String) -> Data? {
        read(account: account(for: hostId))
    }

    /// Only the tests call this: replaces one host's record with bytes that are
    /// not a `StoredCredential`, which is what a struct written by another build
    /// looks like from here.
    func corruptForTesting(hostId: String) {
        write(account: account(for: hostId), data: Data("not a credential".utf8))
        loaded = false
        cached = [:]
    }
}
