/**
 * The passwords this phone typed into this machine's pages, and where they live.
 *
 * Asad, drawing the line the whole browser lane is built on:
 *
 *   > *"it is just linking this to the server side. Whatever cannot be linked,
 *   > it can be only here also — like for example password saving and stuff like
 *   > that, whatever is not possible to do through that, that can be native only
 *   > for this application, for that server only specific."*
 *
 * A profile, a cookie jar and a site's storage are facts about **the machine's**
 * Chromium, and they cross the wire because they are already over there. A
 * password typed into `WKWebView` on this phone is not. There is nothing on the
 * machine to link it to — its browser never saw the keystrokes — and pushing it
 * across would take a secret out of the Secure Enclave, put it through a socket
 * and write it into somebody's `%APPDATA%` for no gain at all.
 *
 * So this is the *"native only for this application, for that server only
 * specific"* half, and both halves of that sentence are load-bearing: it is on
 * the phone, and it is **keyed per machine** — the same `DeckEndpoint.hostId`
 * `PortBook` and `BrowserHistory` key theirs on. `localhost:3000` on his Mac and
 * `localhost:3000` on a Hetzner box are two unrelated sign-ins that happen to
 * share a number, and a store that offered one while the other was connected
 * would be handing somebody's password to a stranger's page.
 *
 * ## The desktop's shape, not the desktop's storage
 *
 * `src/main/browser-passwords.ts` is the model: a login is a `(profile, origin,
 * username)` key with a password against it, an upsert replaces the row for the
 * same three, and an offer that duplicates something already stored is not worth
 * showing. All of that is ported. What is **not** ported is where the bytes go.
 * Electron encrypts a JSON file with `safeStorage` and spends six paragraphs on
 * the fact that a file with an unauthenticated cipher can be edited by anything
 * running as that user. iOS has no such problem to solve: the Keychain is the
 * store, it is in the Secure Enclave's key hierarchy, there is no file to edit
 * and there is no digest to invent.
 *
 * `UserDefaults` — which is where `PortBook` and `BrowserHistory` live, and the
 * obvious thing to copy — is **wrong here and not by a small margin**. It is a
 * plist in the container, it is in the unencrypted device backup, and anything
 * that gets a look at the sandbox reads it. Port names and page titles can live
 * there. A password cannot. `CredentialStore` already argues this for the
 * pairing tokens and this file follows it exactly, down to the one-item-per-key
 * layout and the reason for it.
 *
 * ## One item per login, and no index beside it
 *
 * The account name is `login.v1.<machine>.<origin>.<username>`, each part
 * base64url so the dots that separate them cannot appear inside one. That makes
 * the Keychain itself the list — `CredentialStore`'s rule, worth quoting because
 * it is the whole reason there is no second structure here: *"there is no index
 * item either… so there is no second structure that can disagree with the first
 * about which hosts exist."* An index would be a file saying a password exists
 * where none does, or hiding one that does.
 *
 * It also makes failure local. One item this build cannot read is one sign-in,
 * not every sign-in on the phone.
 *
 * ## The list draws without asking; the password does not exist until it does
 *
 * This is the requirement, and it is why the split above is the way it is: the
 * **origin and the username are attributes**, and the **password is the data**.
 * `SecItemCopyMatching` decrypts and returns item data; asking only for
 * attributes has nothing to decrypt and nothing to authenticate, so
 * {@link hydrate} builds the whole list with no prompt and no `LAContext`. The
 * password comes back from exactly one function, {@link reveal}, which cannot be
 * called without an `LAContext` because the parameter is not optional — the type
 * system carrying a rule that a comment would only describe.
 *
 * Nothing here caches a password. The summaries are cached, because they are
 * drawn on every redraw of a screen and a Keychain sweep per frame is not free;
 * a password is read from the Keychain on each reveal, behind each
 * authentication, and is never held by this object at all.
 *
 * ## `.biometryCurrentSet` **or** `.devicePasscode`
 *
 * The same access control `ServerStore` puts on an SSH credential, and the
 * argument is written out in full in `BiometricGate.swift`. The short version:
 * `.biometryCurrentSet` binds the item to the faces and fingers enrolled *right
 * now*, so somebody who adds their own face to an unattended phone does not
 * thereby get every password on it; and the passcode is composed in because it
 * is not a lower bar — it is the secret the phone already trusts to change that
 * enrolment — and without it a sensor locked out after five bad attempts would
 * be a person permanently locked out of a password only this phone has.
 *
 * That last point is why this store can afford the strict biometric flag at all.
 * A saved website password has no other copy anywhere; if an enrolment change
 * made it unreadable, adding a fingerprint would be data loss. It does not,
 * because the passcode branch of the `.or` still opens the item.
 *
 * ## A password gets *in* here by being typed into a page
 *
 * A manager that can only forget things nobody could save is the complaint the
 * desktop file opens with — *"shipping a passwords screen that does not save
 * passwords was not one of them"* — so the capture lives here too, at the bottom
 * of this file. {@link SavedLoginCapture} is a script in the client content
 * world (the page cannot see it, cannot call it, and cannot reach the message
 * handler) that notices a sign-in and posts the pair; this object holds it in
 * **one** pending slot and publishes only its {@link SavedLoginSummary}. The
 * screen that asks *save this?* is told an offer exists and answers yes or no.
 * The password never reaches a SwiftUI view until somebody has authenticated for
 * it, which is the same discipline the desktop applies to its renderer.
 */

import Foundation
import LocalAuthentication
import Observation
import Security
import WebKit

/* -------------------------------------------------------------------------- */
/* Shape                                                                       */
/* -------------------------------------------------------------------------- */

/**
 * One saved sign-in, without the password.
 *
 * The direct port of the desktop's `SavedLoginSummary`, and it exists for the
 * same reason: *"note the absence of `password`"*. Every value that crosses into
 * a view is one of these, so there is no field to forget to strip.
 *
 * There is no `profileId`. The desktop keys on one because Electron gives its
 * browser several Chromium profiles; this phone's browser is a single
 * `WKWebView` on `WKWebsiteDataStore.default()`, so the machine takes the place
 * of the profile in the key and inventing a second axis would be a column that
 * is always `"default"`.
 */
struct SavedLoginSummary: Identifiable, Equatable {
    /// Which machine's pages this sign-in is for — `DeckEndpoint.hostId`, the
    /// same key `PortBook` and `BrowserHistory` store against.
    let host: String
    /// `http://localhost:<port>`, normalised by ``SavedLogins/originOf(_:)``.
    let origin: String
    /// What was in the username field, or empty. Empty is normal: plenty of
    /// sign-in forms are a password and nothing else.
    let username: String
    /// When the item was last written, off the Keychain's own modification
    /// date — see ``SavedLogins/hydrate()`` for why it is not stored twice.
    let updatedAt: Date

    /// Unique within one machine, which is what an upsert means here.
    var id: String { "\(origin)\u{1F}\(username)" }

    /**
     * What a row draws: `localhost:3000`.
     *
     * The scheme is dropped because it is eleven identical characters on every
     * row — every page this browser can reach is plain `http` on the machine's
     * loopback — and because it is exactly how `PortRow` and `BrowserHistory`
     * already spell an address. Two screens describing the same thing two ways
     * is two things to learn.
     */
    var site: String {
        origin.hasPrefix("http://") ? String(origin.dropFirst("http://".count)) : origin
    }

    /// What to call the account on a row. Never empty, so a row is never a blank
    /// line somebody has to guess at.
    var account: String { username.isEmpty ? "No username" : username }
}

/// How a save ended. A refusal carries the sentence to show, because every one
/// of them is something the person can do something about.
enum SavedLoginOutcome: Equatable {
    case saved
    case refused(String)
}

/* -------------------------------------------------------------------------- */
/* The store                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Deliberately **not** `@MainActor`, for the reason `PortBook` writes out at
 * length: a screen holds one of these as `var logins: SavedLogins = .shared`,
 * that is a default argument on a memberwise initialiser, and default arguments
 * are evaluated in a non-isolated context — so a main-actor `shared` could not
 * be named there at all. Nothing in here touches UIKit; it is a handful of
 * `Security.framework` calls, and every caller is a view already on the main
 * thread.
 */
@Observable
final class SavedLogins {

    /**
     * The one the screens read.
     *
     * A singleton beside `PortBook.shared` and `BrowserHistory.shared`, and for
     * the same reason: this is a property of *this phone* rather than of a live
     * connection. A model rebuilt on a reconnect must not take somebody's saved
     * passwords down with it.
     */
    static let shared = SavedLogins()

    /**
     * The longest username or password this will store, and it **refuses**
     * rather than cuts.
     *
     * The desktop truncates at the same number. It should not, and here it must
     * not: a truncated password is a *wrong* password that looks exactly like a
     * right one, saved under the right site, and the person finds out weeks
     * later at a sign-in screen. Anything past this is a paste accident or a
     * page being strange, and not saving it is the honest outcome.
     */
    static let maxField = 512

    /**
     * The sentence shown wherever a password cannot be kept at all.
     *
     * One string, in one place, because the save path and the manager's empty
     * state both need it — and a person told two different things about the same
     * phone will reasonably conclude one of them is a bug. The desktop's
     * `NO_SECURE_STORE` exists for exactly this and says so.
     */
    static let noPasscode =
        "This iPhone has no passcode, so there is nothing to lock a password to and nothing "
        + "that could ever unlock it. Set one in Settings › Face ID & Passcode and sign in again."

    private let service: String

    /**
     * host id → sign-ins, ordered for drawing. Summaries only — **never** a
     * password.
     *
     * Cached because a list redraws constantly and a Keychain sweep per frame is
     * not free; it is safe to cache because there is nothing secret in it. The
     * password has no cache and no home in this object: it is read from the
     * Keychain inside {@link reveal}, handed to the one screen that asked for
     * it, and forgotten here.
     */
    private var byHost: [String: [SavedLoginSummary]] = [:]

    /**
     * The offer waiting on an answer — **without its password**, which stays in
     * the private field below.
     *
     * The desktop's arrangement, ported for the same reason it exists there: the
     * prompt can name the site and the account without the secret ever reaching
     * a view. One slot rather than a queue, and that is also the desktop's
     * word — two sign-in forms submitted before either is answered is not a real
     * sequence, and a queue would raise a prompt about a page somebody left
     * three navigations ago.
     */
    private(set) var offer: SavedLoginSummary?

    /// The half of the offer that must not be observable, and must not be drawn.
    @ObservationIgnored private var offeredPassword: String?

    /// `service` is a parameter so tests use their own drawer rather than the
    /// one the running app saves into — the same seam `CredentialStore`,
    /// `ServerStore` and `GitHubAccount` all take, and for the same reason.
    init(service: String = "\(Brand.bundleID).browser-logins") {
        self.service = service
        hydrate()
    }

    /// Only the tests read this, to open a second store over the same drawer and
    /// prove a write really reached the Keychain rather than the cache.
    var serviceForTesting: String { service }

    // MARK: - What this phone can promise

    /**
     * Whether a password can be protected on this device at all.
     *
     * `.deviceOwnerAuthentication` — *"is there anybody to ask"* — rather than
     * the biometric policy, because the access control below accepts the
     * passcode as well as a face. An iPhone SE with no Touch ID enrolled can
     * still keep a password properly; a phone with no passcode cannot keep one
     * at all, and this refuses rather than quietly writing it somewhere weaker.
     *
     * Asked fresh every time and never cached: a passcode can be set or removed
     * while this app is in the background, and a cached answer is how a screen
     * ends up refusing to save on a phone that was made ready ten seconds ago.
     */
    var canProtect: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    // MARK: - Reading (no authentication, and none needed)

    /// One machine's sign-ins, by site and then by account.
    func summaries(host: String) -> [SavedLoginSummary] {
        byHost[host] ?? []
    }

    /**
     * One machine's sign-ins, filtered by what somebody typed.
     *
     * **Every whitespace-separated word has to appear somewhere** — in the site
     * or in the username — rather than the whole query having to match as one
     * substring. Somebody looking for the admin account on port 3000 types
     * `3000 admin`, and no single string on that row contains that: the number
     * is in the site and the word is in the username. The same rule
     * `BrowserHistory.visits(host:matching:)` follows, and for the same reason.
     */
    func summaries(host: String, matching query: String) -> [SavedLoginSummary] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return summaries(host: host) }
        return summaries(host: host).filter { row in
            terms.allSatisfy { term in
                row.site.localizedStandardContains(term)
                    || row.username.localizedStandardContains(term)
            }
        }
    }

    /// Every sign-in saved for one site on one machine. The desktop's
    /// `loginsFor`, which a fill path would ask and which the manager uses to
    /// group its rows.
    func summaries(host: String, origin: String) -> [SavedLoginSummary] {
        summaries(host: host).filter { $0.origin == origin }
    }

    // MARK: - Reading the password itself

    /**
     * The password, or nil.
     *
     * **`context` is not optional, and that is the design.** A password is never
     * drawn until the person has authenticated, and the cheapest way to make
     * that true is to make it impossible to ask for one without the thing an
     * authentication produces. `BiometricGate.authenticateOnce` returns
     * `.unlocked(LAContext)`; that context is what gets passed here, and handing
     * it to the Keychain as `kSecUseAuthenticationContext` is also what stops
     * the system raising a *second* prompt of its own for the same read.
     *
     * `authenticateOnce` rather than `BiometricGate.unlock` is the caller's job
     * and worth saying here because it is the subtle half: `unlock` keeps the
     * context for the whole app session, which is right for four SSH reads
     * inside one visit to a server page and wrong for this — it would mean a
     * password revealed with no prompt because somebody opened a server screen
     * ten minutes earlier.
     *
     * Nil means the item is gone, or the authentication did not satisfy the
     * item's access control. Both are said on screen rather than swallowed: a
     * reveal that silently does nothing is a button that reads as broken.
     */
    func reveal(_ row: SavedLoginSummary, context: LAContext) -> String? {
        var request = query(account: Self.account(row))
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // The authentication that already happened, so the Keychain does not ask
        // again for the read behind it.
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Writing

    /**
     * Put a sign-in in, replacing the one for the same machine, site and
     * username.
     *
     * The desktop's `upsertLogin`, ported: *"same username means the same
     * account, so a changed password updates the row rather than adding a second
     * one that will be offered alongside the stale one forever."* A different
     * username on the same site is a different account and gets its own row.
     *
     * The Keychain does the replacing for free, because the account name is
     * built from exactly those three things — which is the second reason the key
     * is in the account name rather than in the data.
     */
    @discardableResult
    func save(host: String, origin: String, username: String, password: String)
        -> SavedLoginOutcome
    {
        guard !host.isEmpty else { return .refused("This phone is not connected to a machine.") }
        guard let origin = Self.originOf(origin) else {
            return .refused("That is not a page on this machine, so there is nothing to save it "
                            + "against.")
        }
        guard let password = Self.clean(password), !password.isEmpty else {
            return .refused("That password is longer than this app will store, so it has not "
                            + "been saved. A cut-off password would be the wrong password.")
        }
        let username = Self.clean(username) ?? ""
        guard canProtect else { return .refused(Self.noPasscode) }

        let row = SavedLoginSummary(host: host, origin: origin, username: username,
                                    updatedAt: Date())
        guard write(account: Self.account(row), password: password) else {
            return .refused("This iPhone would not store the password. Nothing has been changed.")
        }
        var list = (byHost[host] ?? []).filter { $0.id != row.id }
        list.append(row)
        byHost[host] = Self.ordered(list)
        return .saved
    }

    /// Forget one sign-in. The swipe on the row, and the one in the row's menu.
    func forget(_ row: SavedLoginSummary) {
        delete(account: Self.account(row))
        guard var list = byHost[row.host] else { return }
        list.removeAll { $0.id == row.id }
        if list.isEmpty { byHost.removeValue(forKey: row.host) } else { byHost[row.host] = list }
    }

    /**
     * Forget every sign-in this phone saved for **one** machine.
     *
     * One machine, not all of them, and the screen names which one on the button
     * that does it — the same rule `BrowserHistory.clear(host:)` states: a
     * Clear that silently also wiped the logins of a laptop that is not even
     * connected would be the app doing something nobody could see it do.
     */
    func forgetAll(host: String) {
        for row in summaries(host: host) { delete(account: Self.account(row)) }
        byHost.removeValue(forKey: host)
    }

    // MARK: - The ask

    /**
     * A page just signed in. Hold it, and publish that there is something to
     * ask about.
     *
     * Nothing is written yet — this is the *offer*, and the answer comes from a
     * person.
     *
     * ## What is suppressed, and the one thing that cannot be
     *
     * The desktop drops an offer whose username **and password** it already
     * holds: *"a page that submits the same credentials it was just filled with
     * produces a 'save this password?' prompt for a password that is already
     * saved, every time anybody signs in."* That check needs to compare against
     * the stored password, and comparing here would mean reading one — which
     * this store cannot do without an authentication, and raising Face ID to
     * decide whether to *ask a question* would be worse than the question.
     *
     * So the noise is taken out at the two places that cost nothing. The script
     * posts one message per distinct pair per page, so a form submitted twice is
     * one offer. And an identical offer already on screen is left standing
     * rather than replaced, so a `submit` and the `pagehide` behind it do not
     * make the card blink.
     *
     * What is left is the case the desktop keeps too, and keeps deliberately: a
     * stored username with a different password. That is a password change, and
     * it is the one moment this store has to be updated or it goes stale
     * forever. Answering yes to an offer that turns out to be identical is
     * harmless — it rewrites one item with the same bytes.
     */
    func received(_ body: Any, host: String) {
        guard !host.isEmpty,
              let capture = SavedLoginCapture.parse(body),
              let origin = Self.originOf(capture.origin),
              let password = Self.clean(capture.password), !password.isEmpty
        else { return }
        let username = Self.clean(capture.username) ?? ""

        let pending = SavedLoginSummary(host: host, origin: origin, username: username,
                                        updatedAt: Date())
        // Already asking about this exact sign-in. Leave the card where it is
        // rather than tearing it down and building it again underneath a thumb.
        if offer?.id == pending.id, offer?.host == host, offeredPassword == password { return }

        offeredPassword = password
        offer = pending
    }

    /**
     * The person answered.
     *
     * Returns nil when there was nothing to answer, which happens when a card is
     * dismissed twice or when a second page loaded while it was up.
     *
     * **No** empties the slot immediately: a password kept in memory after
     * somebody declined to save it is a secret held for a reason nobody asked
     * for. **Yes** empties it only if the save actually happened — a refusal
     * leaves the offer standing so the card can stay up and say why, and so the
     * Save button still has something to try again with. A card that vanished on
     * a refusal would be indistinguishable from one that vanished on a success.
     */
    @discardableResult
    func answer(keep: Bool) -> SavedLoginOutcome? {
        guard let pending = offer, let password = offeredPassword else { return nil }
        guard keep else {
            offer = nil
            offeredPassword = nil
            return nil
        }
        let outcome = save(host: pending.host, origin: pending.origin,
                           username: pending.username, password: password)
        if case .saved = outcome {
            offer = nil
            offeredPassword = nil
        }
        return outcome
    }

    // MARK: - Normalising

    /**
     * The site a sign-in is filed under, or nil when the address is not one a
     * password may be saved for.
     *
     * The desktop's `originOf` refuses everything but `http:` and `https:` and
     * keeps the URL's own origin. This is narrower, and for a reason that is
     * specific to the phone: the address the web view reports is
     * `http://127.0.0.1:3000` — or `http://[::1]:3000`, because `PortTunnel`
     * binds whichever loopback family won the race, and in the Simulator that is
     * routinely the v6 one. Two spellings of one machine's port. Filing under
     * the raw string would save a password against `127.0.0.1:3000` and then
     * fail to find it the next morning when the v6 bind won, and neither entry
     * would be wrong.
     *
     * So the identity is the **port on the machine**, exactly as
     * `BrowserHistory` files a visit under a port and a path rather than a URL,
     * and the canonical spelling is `http://localhost:<port>`. `LocalhostAddress`
     * is the one place in this app that decides what a loopback address is, and
     * anything it refuses is refused here: a `data:` URL, `about:blank` and the
     * error page a failed load leaves behind are all things that happen in this
     * browser and none of them is somewhere a password belongs.
     */
    static func originOf(_ address: String) -> String? {
        guard case let .address(port, _) = LocalhostAddress.parse(address) else { return nil }
        return "http://localhost:\(port)"
    }

    /**
     * A field as it will be stored, or nil when it is not storable.
     *
     * Control characters go because they cannot be typed into a form field, so
     * their presence means something other than a person produced this — and a
     * newline inside a stored username would break the one-line rows in the
     * manager. Anything past {@link maxField} is refused outright rather than
     * cut; see that constant for why cutting a password is the worse of the two.
     */
    static func clean(_ raw: String) -> String? {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return stripped.count > maxField ? nil : stripped
    }

    /// By site, then by account, both the way the phone's language sorts. The
    /// order a list is learned by; a manager that reshuffled itself between
    /// redraws is a manager people delete the wrong row in.
    private static func ordered(_ rows: [SavedLoginSummary]) -> [SavedLoginSummary] {
        rows.sorted { left, right in
            if left.origin != right.origin {
                return left.origin.localizedStandardCompare(right.origin) == .orderedAscending
            }
            return left.username.localizedStandardCompare(right.username) == .orderedAscending
        }
    }

    // MARK: - The Keychain

    /**
     * Every login in the drawer, read as **attributes only**.
     *
     * This is the function the "the list draws without asking" promise rests on.
     * `kSecReturnData` is absent, so there is nothing for the Keychain to
     * decrypt, nothing for the access control to guard and no authentication to
     * raise — the account names and the modification dates are metadata, and
     * metadata is not what the ACL protects. The password stays where it is
     * until {@link reveal} asks for it with a context in its hand.
     *
     * `updatedAt` comes off `kSecAttrModificationDate` rather than being stored
     * a second time inside the item. The Keychain already keeps it, it is
     * already correct, and a second copy is a second thing that can disagree —
     * the same argument this file makes against an index item, one field
     * smaller. It is exact, too: an item carrying an access control cannot be
     * updated in place (`kSecAttrAccessControl` is not an attribute `SecItemUpdate`
     * may change), so every save deletes and re-adds, and the modification date
     * is therefore the moment the password was written.
     */
    private func hydrate() {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }

        var found: [String: [SavedLoginSummary]] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let key = Self.decode(account)
            else { continue }
            let stamp = item[kSecAttrModificationDate as String] as? Date
                ?? item[kSecAttrCreationDate as String] as? Date
                ?? .distantPast
            found[key.host, default: []].append(
                SavedLoginSummary(host: key.host, origin: key.origin,
                                  username: key.username, updatedAt: stamp))
        }
        byHost = found.mapValues(Self.ordered)
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /**
     * Write one password, under the access control this file's header argues
     * for.
     *
     * Delete first and add, never update: `kSecAttrAccessControl` is not an
     * attribute `SecItemUpdate` may change, and an update that appears to
     * succeed would leave the previous item's ACL standing — which for a store
     * that has just been told to protect something is a lock somebody thinks
     * they turned and did not. `ServerStore.setBiometricLock` makes the same
     * move for the same reason.
     */
    private func write(account: String, password: String) -> Bool {
        var error: Unmanaged<CFError>?
        let control = SecAccessControlCreateWithFlags(
            nil,
            // Paired with the flags below: the item cannot exist on a phone with
            // no passcode, and never leaves this device — so a saved password is
            // not in an iCloud Keychain backup on somebody's other machines.
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.biometryCurrentSet, .or, .devicePasscode],
            &error)
        error?.release()
        guard let control else { return false }

        delete(account: account)
        var insert = query(account: account)
        insert[kSecValueData as String] = Data(password.utf8)
        // `kSecAttrAccessControl` and `kSecAttrAccessible` are mutually
        // exclusive — an item carrying both is refused with `errSecParam`, and
        // the protection class is already inside the control.
        insert[kSecAttrAccessControl as String] = control
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    // MARK: - The account name, which is also the key

    /**
     * `login.v1.<machine>.<site>.<account>`, each part base64url.
     *
     * Encoded rather than written plainly for one reason that matters and one
     * that is a bonus. The one that matters: a username is text somebody typed
     * and a site is text a page reported, and either could contain the separator
     * — so a plain spelling would make `a.b` and `a` + `b` the same account name
     * and one sign-in would silently overwrite another. base64url has no `.` in
     * its alphabet, so the split is exact at any length. The bonus: the Keychain
     * item names in a device backup no longer read as a list of the sites
     * somebody has accounts on.
     *
     * Unpadded, because `=` at the end of a component is noise, and the decoder
     * pads it back.
     */
    private static func account(_ row: SavedLoginSummary) -> String {
        "login.v1.\(encode(row.host)).\(encode(row.origin)).\(encode(row.username))"
    }

    private static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodePart(_ text: String) -> String? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /**
     * The three parts back out, or nil for anything that is not one of ours.
     *
     * Nil rather than a guess: an item in this service that this build cannot
     * read is left exactly where it is and simply not listed. `CredentialStore`
     * states the rule — *"a record this build cannot read may be one a newer
     * build can"* — and deleting it here would be this version destroying a
     * password it merely could not name.
     */
    private static func decode(_ account: String) -> (host: String, origin: String, username: String)? {
        let parts = account.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "login", parts[1] == "v1" else { return nil }
        guard let host = decodePart(parts[2]),
              let origin = decodePart(parts[3]),
              let username = decodePart(parts[4]),
              !host.isEmpty, !origin.isEmpty
        else { return nil }
        return (host, origin, username)
    }

    // MARK: - Tests

    /// Only the tests call this, and only against their own drawer.
    func eraseEverythingForTesting() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        byHost = [:]
        offer = nil
        offeredPassword = nil
    }

    /// Only the tests call this: re-reads the drawer, which is the only way to
    /// prove a write reached the Keychain rather than the cache.
    func reloadForTesting() {
        byHost = [:]
        hydrate()
    }
}

/* -------------------------------------------------------------------------- */
/* Capture                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * How a password gets into the store: a script that notices a sign-in.
 *
 * ## Why it is in the client world
 *
 * `WKContentWorld.defaultClient`, the same world `InspectScript` uses and for
 * the same reason spelled out there: in the page's own world neither
 * `__terminaldeckLogins` nor `webkit.messageHandlers` exists, so a tunnelled
 * site cannot call this, cannot see that it is there, and cannot post a made-up
 * pair to the handler. A dev server is somebody's own code, but it is also
 * whatever npm put in it last Tuesday.
 *
 * ## Three moments, because a sign-in has three shapes
 *
 * **Submit** is the classic form post and the one that is never wrong.
 * **Pagehide** catches the form that navigated without a `submit` event.
 * **Click, then a wait** is the single-page app: no submit, no unload, a `fetch`
 * and a re-render. That last one cannot be answered by the event alone — a click
 * on Sign in happens whether the password was right or wrong — so it waits, and
 * then asks the page a question that separates the two: *is the password field
 * still sitting there with something in it?* A failed sign-in leaves it exactly
 * where it was, and offering to save a password that was just rejected is worse
 * than not offering at all. A successful one takes the form away or empties it.
 *
 * The isolated world is what makes the SPA case need this heuristic rather than
 * a patch on `history.pushState`: an isolated world shares the DOM but not the
 * JavaScript globals, so a `pushState` patched here would never see the page's
 * own calls. Better an honest heuristic than a hook that silently observes
 * nothing.
 *
 * ## Bounds, on the page's side as well as this one
 *
 * Everything is length-checked in the script *and* again in
 * `SavedLogins.clean`. The script's copy is not the guard — it is what stops a
 * page handing a megabyte across the bridge sixty times a second — and the
 * store's copy is what decides what is stored.
 */
enum SavedLoginCapture {

    /// The name the page-side script posts to. Registered in the client world
    /// only, so it does not exist in the page's own world.
    static let messageHandler = "terminaldeckLogins"

    /// The world the script and its handler share. Anything else and the handler
    /// is unreachable from the script — silently, which is the failure that eats
    /// an afternoon.
    static let world = WKContentWorld.defaultClient

    /// What one message carries. Nothing is trusted: the origin goes through
    /// `LocalhostAddress`, and both fields go through `SavedLogins.clean`.
    struct Capture: Equatable {
        let origin: String
        let username: String
        let password: String
    }

    /// A message body, or nil for anything that is not one of ours.
    static func parse(_ body: Any) -> Capture? {
        guard let payload = body as? [String: Any],
              let origin = payload["origin"] as? String,
              let password = payload["password"] as? String,
              !origin.isEmpty, !password.isEmpty
        else { return nil }
        return Capture(origin: origin,
                       username: payload["username"] as? String ?? "",
                       password: password)
    }

    /**
     * Put the script and its handler on a web view, and make it live on the page
     * that is already open.
     *
     * Both halves are needed and the second one is the part that is easy to
     * miss. A `WKUserScript` is injected at the *start of the next document*, so
     * a view that is already showing a sign-in form would not be watched until
     * somebody navigated away from it and back. Evaluating the same source once,
     * now, covers the page in front of the person — and the script's own
     * `if (window.__terminaldeckLogins) return` makes the double-install a
     * no-op on every page that gets both.
     */
    static func install(on webView: WKWebView, store: SavedLogins, host: @escaping () -> String) {
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: world))
        controller.removeScriptMessageHandler(forName: messageHandler, contentWorld: world)
        controller.add(SavedLoginRelay(store: store, host: host),
                       contentWorld: world,
                       name: messageHandler)
        webView.evaluateJavaScript(source, in: nil, in: world) { _ in
            // A page mid-teardown, or none loaded yet. The user script covers
            // the next one either way, so there is nothing to report and nothing
            // to retry.
        }
    }

    /**
     * Take the page's route back into this app away.
     *
     * Called when the browser screen goes, for the reason `BrowserBridge.tearDown`
     * gives about its own handler: `WKUserContentController` retains every
     * handler added to it, and a handler left registered keeps a web content
     * process — and the page it was showing — alive after the screen has gone.
     */
    static func remove(from webView: WKWebView) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: messageHandler, contentWorld: world)
    }

    /// Everything the page-side half of saved logins is.
    static let source = """
    'use strict';
    (function () {
      if (window.__terminaldeckLogins) return;
      window.__terminaldeckLogins = true;

      /* Matches SavedLogins.maxField. Past this the store refuses anyway, so
         this is only about not dragging a megabyte across the bridge. */
      var MAX = 512;
      /* How long a single-page sign-in is given to take its own form away. */
      var SETTLE = 1500;

      /* The pair most recently typed, so a form that navigates without a
         `submit` event still has something to offer at unload. */
      var recent = null;
      /* The last pair posted. One sign-in is one offer, however many of the
         three moments below happen to fire for it. */
      var sent = '';

      function post(payload) {
        try {
          window.webkit.messageHandlers.\(messageHandler).postMessage(payload);
        } catch (err) {
          /* The handler is torn down with the screen; a page mid-teardown must
             not throw. */
        }
      }

      function clean(value) {
        if (typeof value !== 'string') return '';
        var flat = value.replace(/[\\u0000-\\u001f\\u007f]/g, '');
        /* Refused, never cut. A truncated password is a wrong password that
           looks exactly like a right one. */
        return flat.length > MAX ? '' : flat;
      }

      function isPassword(el) {
        return !!el && el.tagName === 'INPUT'
          && String(el.type || '').toLowerCase() === 'password';
      }

      function looksLikeUsername(el) {
        if (!el || el.tagName !== 'INPUT') return false;
        if (el.disabled || el.readOnly) return false;
        var type = String(el.type || 'text').toLowerCase();
        return type === 'text' || type === 'email' || type === 'tel';
      }

      /* The page's own word first, then the field above the password, then the
         one below it. `autocomplete` is what a site uses to tell a password
         manager exactly this, so believing it beats guessing at the layout. */
      function usernameFor(pw) {
        var scope = pw.form || document;
        var marked = scope.querySelector(
          'input[autocomplete="username"], input[autocomplete="email"]');
        if (looksLikeUsername(marked) && marked.value) return marked.value;

        var all = [].slice.call(scope.querySelectorAll('input'));
        var at = all.indexOf(pw);
        for (var i = at - 1; i >= 0; i--) {
          if (looksLikeUsername(all[i]) && all[i].value) return all[i].value;
        }
        for (var j = at + 1; j < all.length; j++) {
          if (looksLikeUsername(all[j]) && all[j].value) return all[j].value;
        }
        return '';
      }

      function pairFrom(pw) {
        if (!isPassword(pw)) return null;
        var password = clean(pw.value);
        if (password === '') return null;
        return { username: clean(usernameFor(pw)), password: password };
      }

      function offer(pair) {
        if (!pair) return;
        var key = pair.username + '\\u001f' + pair.password;
        if (key === sent) return;
        sent = key;
        post({ origin: location.origin, username: pair.username, password: pair.password });
      }

      document.addEventListener('input', function (event) {
        if (isPassword(event.target)) recent = pairFrom(event.target);
      }, true);

      /* The classic form post, and the one that is never wrong. */
      document.addEventListener('submit', function (event) {
        var form = event.target;
        var pw = form && form.querySelector ? form.querySelector('input[type="password"]') : null;
        offer(pairFrom(pw) || recent);
      }, true);

      /* A form that navigated without telling anybody. */
      window.addEventListener('pagehide', function () { offer(recent); }, true);

      /* The single-page app: no submit, no unload, a fetch and a re-render.
         The click alone proves nothing — it happens for a wrong password too —
         so this waits and then asks whether the form went away. */
      document.addEventListener('click', function (event) {
        var el = event.target;
        while (el && el !== document && el.tagName !== 'FORM') {
          var tag = el.tagName;
          var type = String(el.type || '').toLowerCase();
          if (tag === 'BUTTON' || (tag === 'INPUT' && (type === 'submit' || type === 'button'))) {
            break;
          }
          el = el.parentNode;
        }
        if (!el || el === document || el.tagName === 'FORM') return;

        var scope = el.form || document;
        var pw = scope.querySelector('input[type="password"]');
        var pair = pairFrom(pw);
        if (!pair) return;
        setTimeout(function () {
          if (!document.contains(pw) || pw.value === '') offer(pair);
        }, SETTLE);
      }, true);
    })();
    """
}

/**
 * The message handler, holding its store weakly.
 *
 * The same shape as `ScriptRelay` in `LocalhostBrowser.swift`, which is private
 * to that file and therefore cannot be borrowed. Weak for the reason stated
 * there and one more that is specific here: a test hands in a store of its own,
 * and a controller that retained it would keep that test's Keychain drawer alive
 * past the test that made it.
 */
private final class SavedLoginRelay: NSObject, WKScriptMessageHandler {
    private weak var store: SavedLogins?
    private let host: () -> String

    init(store: SavedLogins, host: @escaping () -> String) {
        self.store = store
        self.host = host
    }

    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated { store?.received(message.body, host: host()) }
    }
}
