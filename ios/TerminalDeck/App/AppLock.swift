/**
 * The lock on the front door of the app — one switch, and it asks once.
 *
 * ## The requirement, and what it replaced
 *
 * There was a lock before this one and it was in the wrong place. It hung off a
 * *server*: sign in to a machine, and the screen offered to put that machine's
 * password behind Face ID. Which meant every visit to that server asked — and
 * because this app connects to the server it was last on the moment it opens,
 * "every visit to that server" is "every time you open the app". Asad, having
 * lived with it:
 *
 * > *"For the face lock for the application we added — I don't want it to come
 * > every time when we open the application. If it is that way then remove the
 * > face lock. I wanted this face lock actually not just for one specific server
 * > — make it for the overall application. On the main page of settings just
 * > give it there, as optional for the overall application. If somebody wants to
 * > keep it they can."*
 *
 * Four instructions in one paragraph. **Not per server** — so this object knows
 * nothing about servers and nothing about the Keychain. **On the main Settings
 * page** — one row, `AppLockRow`, beside Machines and Alerts. **Optional, off
 * unless somebody turns it on** — the defaults key is absent on every install
 * that exists today and absent reads as off. And **not every time** — which is
 * the whole of the next section.
 *
 * ## Five minutes, and why five
 *
 * A lock that asks on every return to the foreground is not security, it is a
 * toll booth: switch to 1Password for the key, come back — asked. Open a link,
 * come back — asked. Answer a call, come back — asked. That is the behaviour he
 * threw out, and a rebuild that kept it would deserve the same fate.
 *
 * So the lock asks in exactly two situations: when the app **starts** (a fresh
 * process — this object is constructed locked), and when it comes back after
 * being away for **more than five minutes**. Anything shorter — the app
 * switcher, a share sheet, a glance at Messages, the system's own Face ID sheet
 * — is not "away" and does not ask.
 *
 * Five is a chosen number and here is the case for it rather than the taste:
 *
 *  - It is the same window Apple settled on for
 *    `LATouchIDAuthenticationMaximumAllowableReuseDuration`, which is the
 *    platform's own published opinion of how long one authentication should keep
 *    covering the person who gave it. Being *more* suspicious than the Secure
 *    Enclave's own reuse window is a number invented to look careful.
 *  - It covers the errands people actually leave this app for: fetching a
 *    one-time code, copying a key out of a password manager, reading the mail a
 *    deploy just sent. All of those are seconds to a minute or two.
 *  - It is short enough that a phone left on a desk and picked up by somebody
 *    else is locked by the time they get to it, which is the threat this feature
 *    is for.
 *
 * And it is **said on screen** in both places it applies — under the switch in
 * Settings and on the lock screen itself — because a rule about when an app will
 * challenge you is one you should be able to read rather than discover.
 *
 * ## Where the "on" flag lives, and why that is enough
 *
 * `UserDefaults`, like `Appearance` and `TextSize` — the other two settings that
 * belong to this phone rather than to a machine. It is a preference, not a
 * secret, and the protection is not the flag: it is that **turning it off asks
 * for biometry first**. Somebody holding a borrowed unlocked phone cannot switch
 * this off, because the switch itself is behind the sensor. Hiding the flag in
 * the Keychain would guard it against an attacker with the phone's *filesystem*,
 * who by construction already has a phone they cannot unlock.
 *
 * There is deliberately no Keychain item and no `SecAccessControl` here. This
 * lock opens the app; it does not stand in front of a server's password. Those
 * stay exactly where they were — `ServerStore` writes them and reads them back
 * as it always has.
 *
 * ## Every way it can fail, and the way through each
 *
 * A lock with a dead end in it is an app you have to delete to get back into, so
 * each of these has a true sentence and something to press:
 *
 * | What is true of the phone | What happens |
 * |---|---|
 * | Face ID or Touch ID enrolled | the switch names it; the prompt uses it |
 * | Sensor there, nothing enrolled | the switch says *passcode*, and the lock asks for the passcode |
 * | Biometry locked out after five failures | the passcode sheet is what iOS shows; the screen says so |
 * | No sensor at all | the switch says *passcode*; everything else is the same |
 * | The person cancels the prompt | a sentence, and an **Unlock** button that asks again |
 * | **No passcode on the phone at all** | the lock cannot be turned on — and if it is somehow already on, it **lifts itself** |
 *
 * That last row is the one that would otherwise be unrecoverable. `.deviceOwnerAuthentication`
 * on a phone with no passcode throws `passcodeNotSet` forever: no biometry, no
 * passcode, no way in, and the only remaining move is deleting the app and every
 * server in it. So the lock screen checks *can anybody be asked* before it asks,
 * and when the answer is no it says why and opens the app.
 */

import Foundation
import LocalAuthentication
import Observation

/**
 * What this phone can do about locking the app, right now — asked fresh every
 * time, never cached, because a passcode can be removed and a face can be
 * enrolled while this app is in the background.
 */
enum AppLockAvailability: Equatable {
    /// A face or a finger is enrolled and usable. The passcode is behind it.
    case biometry(BiometryKind)
    /// No usable biometry, but the phone has a passcode — which is a real lock.
    /// The payload is *why* biometry is not being used, so the screen can say.
    case passcode(BiometryAvailability)
    /// No passcode. Nothing can be locked and nothing could unlock it.
    case impossible

    var canLock: Bool {
        if case .impossible = self { return false }
        return true
    }

    /// The name of the thing that will actually be asked for on this phone.
    /// Never "Face ID" on a device with a fingerprint reader, and never a
    /// biometric name at all on one with neither.
    var noun: String {
        switch self {
        case let .biometry(kind): return kind.name ?? "biometric unlock"
        case .passcode, .impossible: return "this iPhone’s passcode"
        }
    }

    /// What the switch in Settings reads.
    var title: String {
        switch self {
        case let .biometry(kind): return "Lock the app with \(kind.name ?? "biometrics")"
        case .passcode: return "Lock the app with a passcode"
        case .impossible: return "Lock the app"
        }
    }

    /// The SF Symbol beside it — the sensor this phone has, or a padlock when
    /// there is no sensor to draw.
    var symbol: String {
        switch self {
        case let .biometry(kind): return kind == .touchID ? "touchid" : "faceid"
        case .passcode, .impossible: return "lock"
        }
    }

    /// The one line under the switch when the lock is available but biometry is
    /// not the thing doing the asking. `nil` when there is nothing to explain.
    var caveat: String? {
        guard case let .passcode(why) = self else { return nil }
        switch why {
        case let .notEnrolled(kind):
            let name = kind.name ?? "Biometric unlock"
            return "\(name) is not set up on this iPhone, so the lock asks for its passcode. "
                + "Set \(name) up in Settings › \(name) & Passcode and the lock uses that instead."
        case let .lockedOut(kind):
            let name = kind.name ?? "Biometric unlock"
            return "\(name) is locked after too many failed attempts, so the lock asks for this "
                + "iPhone’s passcode. Unlocking this iPhone with its passcode once brings \(name) back."
        case .unavailable:
            return "This iPhone has no Face ID or Touch ID, so the lock asks for its passcode."
        case .ready:
            return nil
        }
    }

    /// Why the lock cannot be turned on, in the person’s terms — or nil when it can.
    var refusal: String? {
        guard case .impossible = self else { return nil }
        return "This iPhone has no passcode, so there is nothing to lock the app with. Set one in "
            + "Settings › Face ID & Passcode, then turn this on."
    }
}

@MainActor
@Observable
final class AppLock {

    /**
     * The defaults key, versioned like `Appearance.key` and for the same reason:
     * a stored preference outlives the build that wrote it, and a key that never
     * changes is how a new build inherits a value that used to mean something
     * else. Absent means off, which is what every install in the world has today.
     */
    nonisolated static let defaultsKey = "terminaldeck.applock.v1"

    /// Five minutes. The argument is at the top of this file; the number is here
    /// once so the screen that states it and the rule that enforces it cannot
    /// drift apart.
    nonisolated static let grace: TimeInterval = 300

    /// "five minutes", spelled the way the two screens say it out loud.
    nonisolated static let graceWords = "five minutes"

    /* --------------------------------------------------------------- state -- */

    /// Whether the person has turned the lock on. Off on every fresh install.
    private(set) var enabled: Bool

    /// Whether the lock screen is up right now.
    private(set) var isLocked: Bool

    /// Whether the app’s content should be covered without the lock screen being
    /// up — the moment between "you pressed the home button" and the app
    /// switcher taking its snapshot. Only ever true when the lock is on.
    private(set) var isShielded = false

    /// The one thing both screens draw over the top: the lock screen when an
    /// unlock did not work, the Settings row when the switch would not move.
    /// They are never on screen at the same time, so one property is honest.
    private(set) var trouble: String?

    /// Something the app did on the person’s behalf that they should know about
    /// — today, exactly one thing: the lock turning itself off because the phone
    /// stopped having a passcode.
    private(set) var notice: String?

    /// A prompt is up, or a Keychain-free authentication is in flight.
    private(set) var working = false

    /// Set while the system’s own sheet is on screen. Load-bearing: the biometric
    /// prompt makes this app *inactive*, and shielding on inactivity without this
    /// guard would paint the privacy cover over the person’s own Face ID sheet.
    private(set) var isAuthenticating = false

    /// True in the one state that cannot authenticate anybody: no biometry, no
    /// passcode. The screen offers a way in rather than a locked door.
    private(set) var stranded = false

    /// Bumped whenever the lock screen should raise a prompt by itself. The
    /// screen watches it with `.task(id:)`, so a cold start asks once and a
    /// return to a locked app asks again — and a cancelled prompt does **not**
    /// loop, because nothing bumps this when the app merely goes inactive.
    private(set) var promptToken = 0

    /// What the window presenter watches: anything the person must not see.
    var isCovered: Bool { isLocked || isShielded }

    /* ---------------------------------------------------------- collaborators -- */

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gate: BiometricGate

    /// The clock. A parameter, so the five-minute rule is tested in microseconds
    /// against a made-up `Date` rather than by sleeping for five minutes or by
    /// testing a shortened rule that is not the one that ships. Same shape as
    /// `ConnectionGrace`.
    @ObservationIgnored var now: () -> Date = Date.init

    /// One authentication. Swapped in tests so every branch below can be walked
    /// on a machine with no Secure Enclave.
    @ObservationIgnored var ask: (String) async -> BiometryOutcome = { _ in .unavailable }

    /// What this phone can do, asked fresh. Swapped in tests for the same reason.
    @ObservationIgnored var look: () -> AppLockAvailability = { .impossible }

    /* --------------------------------------------------------------- lifetime -- */

    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var wasBackgrounded = false

    init(defaults: UserDefaults = .standard, gate: BiometricGate? = nil) {
        let gate = gate ?? BiometricGate()
        self.defaults = defaults
        self.gate = gate
        let on = defaults.bool(forKey: Self.defaultsKey)
        self.enabled = on
        // **A fresh process is locked.** Set here rather than in an `onAppear`
        // so the very first body this app evaluates already knows, and there is
        // no frame in which the session list is on screen before the lock is.
        self.isLocked = on
        self.ask = { reason in await gate.authenticateOnce(reason: reason) }
        self.look = { Self.availability(of: gate) }
    }

    /// Compose the two questions LocalAuthentication answers separately: is
    /// there a face or a finger, and failing that is there anybody to ask at all.
    static func availability(of gate: BiometricGate) -> AppLockAvailability {
        let biometry = gate.look()
        if case let .ready(kind) = biometry { return .biometry(kind) }
        guard gate.canAskForPasscode() else { return .impossible }
        return .passcode(biometry)
    }

    /* ----------------------------------------------------------- scene phase -- */

    /**
     * The app is going inactive — the app switcher is opening, a call is coming
     * in, a system sheet is going up.
     *
     * This is where the privacy cover goes on, and it is *not* where the lock
     * goes on: inactive is not away. The `isAuthenticating` guard is the one
     * that matters, because the Face ID sheet itself makes this app inactive and
     * covering the screen underneath it would be this app hiding from its own
     * prompt.
     */
    func wentInactive() {
        guard enabled, !isAuthenticating, !isLocked else { return }
        isShielded = true
    }

    /// The app has actually left the screen. The clock starts here and nowhere
    /// else — the biometric sheet never sends the app to the background, which
    /// is exactly why the grace is measured from this moment rather than from
    /// inactivity.
    func wentToBackground() {
        leftAt = now()
        wasBackgrounded = true
        guard enabled, !isAuthenticating, !isLocked else { return }
        isShielded = true
    }

    /**
     * The app is back in front of the person.
     *
     * Three outcomes and the middle one is the requirement: away longer than the
     * grace locks it, away for less does nothing at all, and coming back to an
     * app that was already locked raises the prompt again so somebody who left
     * mid-unlock is not staring at a screen waiting for them to find the button.
     */
    func becameActive() {
        isShielded = false
        guard wasBackgrounded else { return }
        wasBackgrounded = false
        let away = leftAt.map { now().timeIntervalSince($0) } ?? 0
        leftAt = nil
        guard enabled else { return }
        if !isLocked, away >= Self.grace {
            lockNow()
        } else if isLocked {
            promptToken += 1
        }
    }

    private func lockNow() {
        isLocked = true
        trouble = nil
        stranded = false
        promptToken += 1
    }

    /* --------------------------------------------------------------- unlock -- */

    /**
     * Ask, once, and say exactly what happened if it did not work.
     *
     * Nothing here can leave the person outside: every outcome except success
     * leaves the **Unlock** button on screen, and the one outcome where pressing
     * it again could never help — a phone with no passcode — opens the app and
     * turns the lock off instead of pretending.
     */
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }

        let availability = look()
        guard availability.canLock else {
            stranded = true
            trouble = "This iPhone has no passcode any more, so there is nothing left to unlock "
                + "with. Continue into \(Brand.name) — the lock is off until you set a passcode and "
                + "turn it back on."
            return
        }

        isAuthenticating = true
        working = true
        trouble = nil
        let outcome = await ask("Unlock \(Brand.name)")
        isAuthenticating = false
        working = false

        switch outcome {
        case .unlocked:
            isLocked = false
            leftAt = nil
            wasBackgrounded = false
            trouble = nil
        case .cancelled:
            // Not a failure and never reported as one. The button is still there.
            trouble = "Cancelled — nothing was opened. Press Unlock when you are ready."
        case let .lockedOut(kind):
            let name = kind.name ?? "Biometric unlock"
            trouble = "\(name) is locked after too many failed attempts. Press Unlock and enter "
                + "this iPhone’s passcode — that clears it."
        case let .notEnrolled(kind):
            let name = kind.name ?? "Biometric unlock"
            trouble = "\(name) is no longer set up on this iPhone. Press Unlock and use this "
                + "iPhone’s passcode instead."
        case .unavailable:
            trouble = "That sensor is not available. Press Unlock and use this iPhone’s passcode "
                + "instead."
        case let .failed(said):
            trouble = "\(said) Press Unlock to try again."
        }
    }

    /**
     * The way out of the one state nothing can authenticate: the lock goes off,
     * the app opens, and Settings says why rather than leaving somebody to
     * wonder where their switch went.
     */
    func continueWithoutLock() {
        enabled = false
        defaults.set(false, forKey: Self.defaultsKey)
        isLocked = false
        stranded = false
        trouble = nil
        leftAt = nil
        wasBackgrounded = false
        notice = "The lock turned itself off: this iPhone no longer has a passcode, so there was "
            + "nothing left to unlock with."
    }

    /* --------------------------------------------------------- the switch -- */

    /**
     * Turn the lock on or off. Both directions cost exactly one prompt, and both
     * of those prompts earn their place:
     *
     *  - **On** proves the sensor this phone claims to have actually works,
     *    right now, with the person holding it. Switching a lock on without ever
     *    testing it is how somebody discovers at the airport that their Face ID
     *    was never enrolled.
     *  - **Off** is the one that matters. Without it, a phone handed over
     *    unlocked for thirty seconds is a phone whose lock can be switched off
     *    by the person holding it, and the feature protects nothing. After it,
     *    nothing asks again — off is off.
     *
     * A cancelled prompt changes nothing and says nothing: the switch springs
     * back, which is the whole of the message.
     */
    func setEnabled(_ wanted: Bool) async {
        guard !working, wanted != enabled else { return }
        trouble = nil
        notice = nil

        let availability = look()
        if wanted, !availability.canLock {
            trouble = availability.refusal
            return
        }

        isAuthenticating = true
        working = true
        let outcome = await ask(wanted ? "Turn on the lock for \(Brand.name)"
                                       : "Turn off the lock for \(Brand.name)")
        isAuthenticating = false
        working = false

        switch outcome {
        case .unlocked:
            enabled = wanted
            defaults.set(wanted, forKey: Self.defaultsKey)
            // Whoever just authenticated is in. Turning the lock **on** must not
            // then drop its own lock screen over the Settings page they are
            // standing on.
            isLocked = false
            leftAt = nil
            wasBackgrounded = false
        case .cancelled:
            break
        case let .lockedOut(kind):
            let name = kind.name ?? "Biometric unlock"
            trouble = "\(name) is locked after too many failed attempts. Unlock this iPhone with "
                + "its passcode once and try again — the passcode works on the prompt itself too."
        case let .notEnrolled(kind):
            let name = kind.name ?? "Biometric unlock"
            trouble = "\(name) is not set up on this iPhone. Set it up in Settings › \(name) & "
                + "Passcode, or use this iPhone’s passcode on the prompt."
        case .unavailable:
            trouble = "That sensor is not available on this iPhone."
        case let .failed(said):
            trouble = said
        }
    }

    /// Clears whatever sentence is on screen. The Settings row calls it when the
    /// person leaves, so a refusal from ten minutes ago is not still there.
    func clearTrouble() {
        trouble = nil
    }
}
