/**
 * Face ID and Touch ID, offered rather than imposed.
 *
 * ## The requirement
 *
 * > *"Also give the face or fingerprint login there if somebody wants to have
 * > that, also for the next time."*
 *
 * Three words in that sentence carry the whole design. **"if somebody wants"** —
 * it is an offer, and a person who declines keeps typing their password and is
 * never asked twice. **"there"** — at the moment a login succeeds, not buried in
 * a settings screen somebody has to go and find. **"for the next time"** — the
 * point is getting back in, so what biometry protects is the credential already
 * in the Keychain, not a second copy of anything.
 *
 * ## What is actually protected, and by whom
 *
 * Nothing in this file decides whether somebody gets in. The credential item in
 * `ServerStore` is rewritten with a `SecAccessControl` on it, and from that
 * moment **the Keychain** refuses to hand it back without a successful
 * authentication — in the Secure Enclave, on the far side of a boundary this
 * process cannot reach around. A flag in this app saying "unlocked" would be a
 * flag an attacker with the phone could flip; an access control is not.
 *
 * That is also why there is no "biometry is on" boolean living only here. The
 * truth is the ACL on the Keychain item. `StoredServer.biometricLock` mirrors it
 * so a list of servers can be *drawn* — reading the record must never prompt —
 * and the record is written in the same breath as the item, or not at all.
 *
 * ## `.biometryCurrentSet`, and why not `.userPresence`
 *
 * **`.biometryCurrentSet`, composed with `.devicePasscode`.** Said out loud
 * because the two candidates fail differently and the difference is the whole
 * point of turning this on:
 *
 *  - `.userPresence` is "biometry, or the passcode, whichever". It survives a
 *    new face being enrolled — which is exactly the event where the person
 *    holding the phone may no longer be its owner. Somebody who can add their
 *    own face to a phone can then open every server on it, and the app would
 *    never notice.
 *  - `.biometryAny` invalidates on nothing either.
 *  - `.biometryCurrentSet` binds the item to **the set of faces and fingers
 *    enrolled right now**. Adding one, or removing one, invalidates it. That is
 *    a real cost — an enrolment change means signing in to those servers again —
 *    and it is the correct one for an SSH credential that opens somebody's
 *    production machine.
 *
 * The passcode is composed in with `.or` rather than left out, and that is not a
 * weakening of the above: a passcode is what the phone already trusts to *change
 * the enrolment*, so it is not a lower bar than biometry — and without it, a
 * Face ID locked out after five failed attempts is a person locked out of their
 * own server with no route back except forgetting it and typing a password they
 * may not have with them. `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`
 * pairs with it: the item cannot exist on a phone with no passcode at all, and
 * never leaves this device.
 *
 * ## Asking once, not once per round trip
 *
 * A server page runs a look, an install and a start in a row, and each opens an
 * SSH connection and each reads the credential. Prompting four times for one
 * visit would make this feature something people switch off. So the `LAContext`
 * that succeeded is kept for the length of the app session and handed to the
 * Keychain as `kSecUseAuthenticationContext`: the first read prompts, the ones
 * behind it ride the same authentication. It is dropped when the app goes to the
 * background, which is the moment the phone left the person's attention.
 */

import Foundation
import LocalAuthentication
import Observation
import UIKit

/// Which biometry this phone has, so the screen can say the right name. Apple's
/// own words: a screen that says "Face ID" to somebody holding an iPhone SE is
/// telling them about a sensor their phone does not have.
enum BiometryKind: Equatable {
    case none, faceID, touchID, opticID

    /// What it is called on this device. `nil` when there is nothing to name.
    var name: String? {
        switch self {
        case .none: return nil
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        }
    }

    init(_ type: LABiometryType) {
        switch type {
        case .faceID: self = .faceID
        case .touchID: self = .touchID
        case .opticID: self = .opticID
        default: self = .none
        }
    }
}

/**
 * What this phone can do about biometry **right now**, which is four different
 * situations and not one boolean.
 *
 * Each of them gets a true sentence and a way through, because every one of them
 * is a real phone somebody is holding: a device with no sensor, a device whose
 * owner has never set a face up, a device where five wrong faces have locked the
 * sensor until the passcode is entered, and one that is simply ready.
 */
enum BiometryAvailability: Equatable {
    /// Enrolled and usable. The only state in which the offer is made.
    case ready(BiometryKind)
    /// The hardware is there and nothing is enrolled on it.
    case notEnrolled(BiometryKind)
    /// Too many failed attempts. The phone's own passcode clears it.
    case lockedOut(BiometryKind)
    /// No sensor, or this app has been denied it.
    case unavailable

    var kind: BiometryKind {
        switch self {
        case let .ready(kind), let .notEnrolled(kind), let .lockedOut(kind): return kind
        case .unavailable: return .none
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The name to print, or a neutral one when there is nothing to name. Never
    /// "Face ID" on a phone that has a fingerprint reader.
    var name: String { kind.name ?? "biometric unlock" }

    /// Why the offer is not being made, in the person's terms — or nil when it is.
    var refusal: String? {
        switch self {
        case .ready:
            return nil
        case let .notEnrolled(kind):
            let name = kind.name ?? "Biometric unlock"
            return "\(name) is not set up on this iPhone yet. Set it up in Settings › "
                + "\(name) & Passcode, then turn this on."
        case let .lockedOut(kind):
            let name = kind.name ?? "Biometric unlock"
            return "\(name) is locked after too many failed attempts. Unlock this iPhone with its "
                + "passcode once and it comes back."
        case .unavailable:
            return "This iPhone has no Face ID or Touch ID, so there is nothing to unlock with. "
                + "Your sign-in stays in the Keychain either way."
        }
    }
}

/// How an unlock ended. Nothing here is a dead end: every case the screen can
/// receive has a sentence and something to press.
enum BiometryOutcome {
    /// Authenticated. The context rides along so the Keychain read behind this
    /// does not prompt a second time.
    case unlocked(LAContext)
    /// The person pressed Cancel, or the system took the prompt away. Not a
    /// failure and never reported as one.
    case cancelled
    /// Five wrong attempts. The passcode is the way out and the sentence says so.
    case lockedOut(BiometryKind)
    /// Nothing enrolled — including "enrolment changed", which invalidates the
    /// item and is reported as needing the password once more.
    case notEnrolled(BiometryKind)
    case unavailable
    /// Anything else, in the system's own words rather than this app's guess.
    case failed(String)
}

@MainActor
@Observable
final class BiometricGate {

    /**
     * How long one authentication covers subsequent Keychain reads.
     *
     * A visit to a server page is a look, then maybe an install, then a start,
     * then a connect — four SSH connections and four credential reads inside a
     * couple of minutes. `touchIDAuthenticationAllowableReuseDuration` is
     * capped by the system at `LATouchIDAuthenticationMaximumAllowableReuseDuration`
     * (five minutes), and asking for the maximum is asking for exactly the
     * window one visit occupies.
     */
    private static let reuse = LATouchIDAuthenticationMaximumAllowableReuseDuration

    /// The authentication that succeeded, kept for this app session only.
    @ObservationIgnored private var authenticated: LAContext?

    /// Watches for the app leaving the foreground, so the context can be dropped.
    @ObservationIgnored private var background: NSObjectProtocol?

    /// Swappable so tests can walk every branch without a Secure Enclave. The
    /// real one makes a fresh `LAContext`; nothing in this file caches one for
    /// asking questions, because a context remembers its last evaluation.
    @ObservationIgnored var makeContext: () -> LAContext = { LAContext() }

    init() {
        background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `assumeIsolated` rather than a hop: this queue is the main queue,
            // and a hop would drop the context one runloop after the app is
            // already off screen.
            MainActor.assumeIsolated { self?.forget() }
        }
    }

    deinit {
        if let background { NotificationCenter.default.removeObserver(background) }
    }

    /* ----------------------------------------------------------- the state -- */

    /**
     * What this phone can do, asked fresh every time.
     *
     * Never cached. Biometry can be enrolled, removed or locked out while this
     * app is in the background, and a cached answer is how a screen ends up
     * offering Face ID to somebody who turned it off ten seconds ago.
     */
    func look() -> BiometryAvailability {
        let context = makeContext()
        var error: NSError?
        // `.deviceOwnerAuthenticationWithBiometrics`, not `.deviceOwnerAuthentication`:
        // the second one answers "can this phone authenticate at all", which is
        // true on any phone with a passcode, and would have this screen offering
        // Face ID on a device that has none.
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .ready(BiometryKind(context.biometryType))
        }
        let kind = BiometryKind(context.biometryType)
        switch LAError.Code(rawValue: error?.code ?? 0) {
        case .biometryNotEnrolled: return .notEnrolled(kind)
        case .biometryLockout: return .lockedOut(kind)
        default: return kind == .none ? .unavailable : .notEnrolled(kind)
        }
    }

    /**
     * Whether this phone can ask its owner to prove who they are **at all** —
     * biometry or the passcode, whichever it has.
     *
     * `.deviceOwnerAuthentication` rather than the biometric policy `look()`
     * uses, and the difference is the whole reason this exists. `look()` answers
     * "is there a face or a finger to offer", which is the right question for a
     * Keychain item bound to an enrolment. This answers "is there anybody to
     * ask", which is the right question for a lock on the front door of the app:
     * an iPhone SE with no Touch ID set up still has a passcode, and a lock that
     * asks for it is a real lock.
     *
     * False means the phone has no passcode either — and then there is nothing
     * to lock with and nothing that could ever unlock it, which is a state
     * `AppLock` refuses to enter and lifts itself out of if it is ever found in.
     */
    func canAskForPasscode() -> Bool {
        var error: NSError?
        return makeContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Whether there is already an authentication this session, so a caller can
    /// tell "will not prompt" from "will".
    var isUnlocked: Bool { authenticated != nil }

    /* ---------------------------------------------------------- unlocking -- */

    /**
     * Authenticate, or say exactly why not.
     *
     * `.deviceOwnerAuthentication` — biometry **with the passcode behind it** —
     * matching the `.biometryCurrentSet .or .devicePasscode` on the item this
     * unlocks. A policy narrower than the ACL would refuse a person the Keychain
     * itself would have let through, which is this app inventing a lockout that
     * does not exist.
     */
    func unlock(reason: String) async -> BiometryOutcome {
        if let already = authenticated { return .unlocked(already) }

        if case .unavailable = look() { return .unavailable }

        let outcome = await authenticateOnce(reason: reason)
        if case let .unlocked(context) = outcome { authenticated = context }
        return outcome
    }

    /**
     * One authentication, with nothing kept.
     *
     * The evaluation `unlock` is built out of, split out because the app-level
     * lock needs the same LocalAuthentication plumbing and none of the caching:
     * `AppLock` decides for itself how long an unlock lasts (five minutes of
     * absence, stated on its own screen) and a second cache underneath it would
     * be a second answer to the same question. Both callers get the same error
     * mapping, which is the part that is easy to get subtly wrong twice.
     *
     * Deliberately **without** `unlock`'s `.unavailable` early return: a phone
     * with no sensor cannot protect a Keychain item with biometry, but it can
     * still ask its owner for the passcode, and that is a real app lock. The
     * caller that must not accept a passcode-only device is the one that keeps
     * that early return.
     */
    func authenticateOnce(reason: String) async -> BiometryOutcome {
        let availability = look()
        let context = makeContext()
        context.localizedReason = reason
        // "Use passcode", not the default "Enter Password" — this app has no
        // password of its own and that wording sends people looking for one.
        context.localizedFallbackTitle = "Use passcode"
        context.touchIDAuthenticationAllowableReuseDuration = Self.reuse

        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: reason)
            guard ok else { return .cancelled }
            return .unlocked(context)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                return .cancelled
            case .biometryLockout:
                return .lockedOut(availability.kind)
            case .biometryNotEnrolled:
                return .notEnrolled(availability.kind)
            case .biometryNotAvailable:
                return .unavailable
            case .passcodeNotSet:
                return .failed("This iPhone has no passcode, so nothing can be locked to it. "
                    + "Set one in Settings › Face ID & Passcode.")
            case .userFallback:
                // Only reachable under `.deviceOwnerAuthenticationWithBiometrics`,
                // where there is no passcode sheet to fall back *to*. Under the
                // policy above the system shows it itself, so this is a cancel.
                return .cancelled
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /**
     * Drop the authentication.
     *
     * Called when the app leaves the foreground, and by the switch that turns
     * the lock off — so the next read prompts again rather than riding a context
     * that outlived the reason it was granted. `invalidate()` rather than
     * dropping the reference, because an `LAContext` holds the Enclave's
     * authorisation and letting it be collected quietly leaves that standing
     * until it does.
     */
    func forget() {
        authenticated?.invalidate()
        authenticated = nil
    }
}
