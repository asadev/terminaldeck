/**
 * The servers this phone has signed into, and the sign-ins that reach them.
 *
 * ## The split, and why it is kept on a phone that does not need it
 *
 * `src/main/servers/store.ts` holds a server's *visible* record in one file and
 * its password or key in another, because on the desktop the first crosses the
 * bridge to the renderer and the second must never be anywhere near it. There is
 * no such bridge here — every view is in this process — so the split buys
 * nothing structural and is kept anyway, as two Keychain items rather than one:
 * drawing the list of servers then never reads a secret into memory at all, and
 * a screenshot of a debugger sitting on the list has nothing in it to leak.
 *
 * ## One item per server, and no index
 *
 * `CredentialStore` states the argument and this file follows it exactly: a
 * single blob holding every server has a single decode, so one bad record reads
 * as *no servers at all* and everything disappears at once. One item each makes
 * that failure local — the unreadable one is skipped, the rest are untouched.
 * The list is read back with `kSecMatchLimitAll`, so there is no second
 * structure that can disagree about which servers exist.
 *
 * ## What the host key is doing in here
 *
 * It is not a secret — it is public by construction, and the whole point of
 * showing it is that somebody can check it against `ssh-keyscan` — but it is
 * what the identity check in `SSHSession` compares against. Anything that can
 * rewrite this record can silently retarget somebody's server at a machine that
 * is not theirs and the check would still pass. In the Keychain it inherits the
 * same protection as the credential beside it, which is the cheapest correct
 * answer available on this platform.
 */

import Foundation
import LocalAuthentication
import Security

/// Which kind of sign-in is stored for a server, without any of it.
enum ServerCredentialKind: String, Codable, Equatable {
    case password, key, none
}

/// One server, as a screen is allowed to see it.
struct StoredServer: Codable, Equatable, Identifiable {
    let id: String
    /// The person's own name for it. Never an internal id.
    var name: String
    var address: String
    var port: Int
    var username: String
    var credential: ServerCredentialKind
    /// What it answered with the first time, and every time since.
    var hostKey: SSHHostKey?
    var addedAt: Date
    var lastConnectedAt: Date?
    /**
     * The machine row this server is currently connected as, or nil.
     *
     * The one field with no counterpart on the desktop, and it is what makes
     * **Disconnect** a real control rather than a second Forget: connecting
     * signs this phone in to the host running *on* that server, which produces
     * an ordinary machine in the machines list. Remembering which one lets the
     * server's own page say "connected" and take it away again without touching
     * the server record — so reconnecting is one press, not a whole sign-in.
     */
    var linkedHostId: String?

    /**
     * Whether this server's password or key is behind Face ID / Touch ID.
     *
     * **A mirror of the truth, not the truth.** What actually refuses a read is
     * the `SecAccessControl` on the credential item, enforced by the Secure
     * Enclave; this flag exists so the servers list can be *drawn* without
     * touching it. Reading the record must never raise a prompt — a list of six
     * servers would otherwise be six Face ID sheets to scroll past one row.
     *
     * Optional rather than a defaulted `Bool` because records written before
     * this existed have no such key, and a synthesised `Decodable` throws on a
     * missing non-optional — which would read as *no servers at all* on the
     * first launch after an update. See the header on one item per server.
     */
    var biometricLock: Bool?

    var isBiometricLocked: Bool { biometricLock == true }

    /// `address:port`, with the port shown only when it is not the usual one.
    var where_: String {
        port == ServerStore.defaultPort ? address : "\(address):\(port)"
    }
}

/// Why a server could not be added. Every case is something the form can point at.
enum ServerDraftProblem: Error, Equatable {
    case noAddress
    case noUsername
    case badPort
    case tooMany

    var sentence: String {
        switch self {
        case .noAddress: return "A server needs an address."
        case .noUsername: return "A server needs the username you would sign in with."
        case .badPort: return "A port is a number from 1 to 65535. Leave it empty for 22."
        case .tooMany: return "This phone is holding as many servers as it will hold."
        }
    }
}

final class ServerStore {

    /// The port a server is reached on when nobody says otherwise.
    static let defaultPort = 22
    /// Names are shown on this screen and go into logs, so they are bounded.
    private static let maxName = 64
    /// Longer than this cannot resolve, so accepting it would only move the failure.
    private static let maxAddress = 255
    private static let maxUsername = 64
    /// Refuses to grow without bound if adding ever runs in a loop.
    private static let maxServers = 64

    private let service: String
    private let recordPrefix = "server."
    private let secretPrefix = "serversecret."

    /// A parameter so the tests use their own drawer rather than the real one.
    init(service: String = "\(Brand.bundleID).servers") {
        self.service = service
    }

    /* -------------------------------------------------------------- reading -- */

    /// Every server, oldest first — the order they were added, which is the order
    /// somebody remembers adding them in.
    func all() -> [StoredServer] {
        readAll()
            .filter { $0.0.hasPrefix(recordPrefix) }
            .compactMap { try? JSONDecoder().decode(StoredServer.self, from: $0.1) }
            .sorted { $0.addedAt < $1.addedAt }
    }

    func load(_ id: String) -> StoredServer? {
        guard let data = read(account: recordPrefix + id) else { return nil }
        return try? JSONDecoder().decode(StoredServer.self, from: data)
    }

    /**
     * The password or key for one server.
     *
     * Read at the moment a connection is opened and never held: `SSHSession`
     * spends it in the handshake and the caller drops it. Nothing keeps this in
     * a property.
     */
    func secret(for id: String, context: LAContext? = nil) -> String? {
        guard let data = read(account: secretPrefix + id, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /* -------------------------------------------------------------- writing -- */

    /**
     * Add a server, or throw the reason it cannot be added.
     *
     * The checks are the desktop's, in the same order, and the port one is the
     * one with a history: it used to be absent from the phone's form entirely,
     * defaulted to 22, and the one machine Asad tried to add listens on **2222**
     * — so the app told him his server was off or firewalled about a number this
     * app had chosen without telling him.
     */
    @discardableResult
    func add(name: String,
             address: String,
             port: Int?,
             username: String,
             secret: String,
             kind: ServerCredentialKind,
             hostKey: SSHHostKey?) throws -> StoredServer {
        let cleanAddress = String(address.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxAddress))
        guard !cleanAddress.isEmpty else { throw ServerDraftProblem.noAddress }
        let cleanUser = String(username.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxUsername))
        guard !cleanUser.isEmpty else { throw ServerDraftProblem.noUsername }
        let realPort = port ?? Self.defaultPort
        guard realPort >= 1, realPort <= 65535 else { throw ServerDraftProblem.badPort }
        guard all().count < Self.maxServers else { throw ServerDraftProblem.tooMany }

        /*
         * The same login twice is the **same server**, not a second one.
         *
         * Photographed and then obvious: three logins to one box left three
         * identical rows on the machines list, each with the same name, the same
         * `root@…` under it and the same everything. Signing in again is a
         * normal thing to do — after a revoke, after changing the password, or
         * simply because somebody was not sure it had worked — and it must not
         * cost a duplicate row. `DeckModel.adoptSignedIn` makes exactly this
         * argument for machines: *"a machine already in the list is restarted
         * rather than added twice."*
         *
         * Identity is address, port and account, because that triple is what a
         * connection is made of. Two accounts on one box are two servers and
         * stay two rows. What is refreshed is the credential and the host key —
         * the two things the new sign-in just proved — and what is kept is the
         * id and the person's own name for it, so a page open on that server
         * and a name they typed both survive.
         */
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if var already = all().first(where: {
            $0.address == cleanAddress && $0.port == realPort && $0.username == cleanUser
        }) {
            already.credential = secret.isEmpty ? already.credential : kind
            if let hostKey { already.hostKey = hostKey }
            if !secret.isEmpty, let data = secret.data(using: .utf8) {
                /*
                 * A re-login must not quietly unlock a locked server.
                 *
                 * The new credential is written plainly first — the old item's
                 * ACL is gone with it, which is what makes this writable at all
                 * without a prompt — and then the lock is put straight back on
                 * with `setBiometricLock`, using the secret still in hand. It is
                 * two writes for one save and that is the cost of not asking for
                 * Face ID in the middle of a password login.
                 *
                 * If putting the lock back fails, the flag follows the item down
                 * rather than claiming a protection that is not there. A lock
                 * that reads "on" over an unprotected item is worse than no lock.
                 */
                delete(account: secretPrefix + already.id)
                write(account: secretPrefix + already.id, data: data)
                if already.isBiometricLocked {
                    do { try setBiometricLock(true, for: already.id) }
                    catch { already.biometricLock = false }
                }
            }
            save(already)
            return already
        }

        let server = StoredServer(
            id: UUID().uuidString,
            name: String((cleanName.isEmpty ? cleanAddress : cleanName).prefix(Self.maxName)),
            address: cleanAddress,
            port: realPort,
            username: cleanUser,
            credential: secret.isEmpty ? .none : kind,
            hostKey: hostKey,
            addedAt: Date(),
            lastConnectedAt: nil,
            linkedHostId: nil,
            biometricLock: false)
        save(server)
        if !secret.isEmpty, let data = secret.data(using: .utf8) {
            write(account: secretPrefix + server.id, data: data)
        }
        return server
    }

    func save(_ server: StoredServer) {
        guard let data = try? JSONEncoder().encode(server) else { return }
        write(account: recordPrefix + server.id, data: data)
    }

    /// Both items, always together: a record with no secret beside it is a server
    /// that asks for a password nobody typed, and a secret with no record is a
    /// password for a machine nothing can name.
    func forget(_ id: String) {
        delete(account: recordPrefix + id)
        delete(account: secretPrefix + id)
    }

    /* ------------------------------------------------------------ biometry -- */

    /// Why a lock could not be turned on or off. Each is a sentence a screen prints.
    enum LockProblem: Error, Equatable {
        /// The credential could not be read back, so there is nothing to rewrite.
        /// On a locked server this is what a refused or cancelled unlock looks like.
        case noSecret
        /// The platform refused to build the access control — no passcode set.
        case noPasscode
        /// The rewritten item would not go back in. The old one is already gone,
        /// so the server is left needing a fresh sign-in and the sentence says so.
        case notWritten

        var sentence: String {
            switch self {
            case .noSecret:
                return "That sign-in could not be read, so nothing was changed."
            case .noPasscode:
                return "This iPhone has no passcode, so nothing can be locked to it. Set one in "
                    + "Settings › Face ID & Passcode."
            case .notWritten:
                return "That sign-in could not be written back. Log in to this server again."
            }
        }
    }

    /**
     * Put the credential behind biometry, or take it back out.
     *
     * Delete and re-add rather than `SecItemUpdate`, because `kSecAttrAccessControl`
     * is not an attribute an update may change — an update that appears to
     * succeed leaves the old ACL in place, which is a lock somebody switched on
     * and that does not exist.
     *
     * The order is: read (which prompts when it is already locked), write the new
     * item, then the record. A failure at any step leaves the previous state
     * intact except the one in `notWritten`, which is stated rather than hidden.
     *
     * `context` is the authentication that has already happened, so turning a
     * lock **off** costs one prompt rather than two.
     */
    func setBiometricLock(_ on: Bool, for id: String, context: LAContext? = nil) throws {
        guard var server = load(id) else { throw LockProblem.noSecret }
        guard let secret = read(account: secretPrefix + id, context: context) else {
            throw LockProblem.noSecret
        }

        var control: SecAccessControl?
        if on {
            var error: Unmanaged<CFError>?
            /*
             * `.biometryCurrentSet` **or** `.devicePasscode` — the decision, in
             * one line, argued in full in `BiometricGate.swift`.
             *
             * `.biometryCurrentSet` binds this credential to the faces and
             * fingers enrolled at this moment: adding one invalidates it. That
             * is the property `.userPresence` and `.biometryAny` do not have,
             * and it is the one that matters for a credential that opens
             * somebody's production machine — a person who can add their own
             * face to an unattended phone must not thereby get every server on
             * it.
             *
             * The passcode is composed in because it is not a lower bar: it is
             * the same secret the phone already trusts to *change the
             * enrolment*. Without it, a sensor locked out after five failures
             * would be a locked-out person with no route back but forgetting the
             * server. `WhenPasscodeSetThisDeviceOnly` pairs with that — the item
             * cannot exist on a phone with no passcode, and never leaves it.
             */
            control = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                [.biometryCurrentSet, .or, .devicePasscode],
                &error)
            error?.release()
            guard control != nil else { throw LockProblem.noPasscode }
        }

        delete(account: secretPrefix + id)
        guard write(account: secretPrefix + id, data: secret, control: control) else {
            throw LockProblem.notWritten
        }
        server.biometricLock = on
        save(server)
    }

    /* ------------------------------------------------------------- keychain -- */

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String, context: LAContext? = nil) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            // The authentication that already happened, handed to the Keychain
            // so a read behind an unlock does not raise a second prompt.
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func readAll() -> [(String, Data)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let rows = items as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data
            else { return nil }
            return (account, data)
        }
    }

    @discardableResult
    private func write(account: String, data: Data, control: SecAccessControl? = nil) -> Bool {
        let query = query(account: account)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let control {
            // `kSecAttrAccessControl` and `kSecAttrAccessible` are mutually
            // exclusive — an item carrying both is refused with errSecParam, and
            // the protection class is already inside the control.
            attributes[kSecAttrAccessControl as String] = control
        } else {
            // AfterFirstUnlock so a connection opened from a pocket works;
            // ThisDeviceOnly so an SSH password is never in an iCloud backup on
            // somebody's other devices. `CredentialStore` argues both in full.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        if control == nil,
           SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }
        var insert = query
        insert.merge(attributes) { current, _ in current }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    /// Only the tests call this: it writes a record this build cannot decode,
    /// which is the thing one-item-per-server exists to survive.
    func saveRawForTesting(id: String, data: Data) {
        write(account: recordPrefix + id, data: data)
    }

    /// Only the tests call this, and only against their own drawer.
    func eraseEverythingForTesting() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }
}
