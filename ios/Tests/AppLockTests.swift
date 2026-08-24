/**
 * The app lock, one test per sentence of the requirement — and nothing here
 * sleeps for five minutes.
 *
 * > *"For the face lock for the application we added — I don't want it to come
 * > every time when we open the application. If it is that way then remove the
 * > face lock. I wanted this face lock actually not just for one specific server
 * > — make it for the overall application. On the main page of settings just
 * > give it there, as optional for the overall application. If somebody wants to
 * > keep it they can."*
 *
 * ## Why the clock and the prompt are both parameters
 *
 * The same reason `ConnectionGraceTests` gives: a test that proved a five-minute
 * rule by waiting five minutes would add five minutes to every future run, and
 * one that proved it against a rule shortened to fifty milliseconds would be
 * proving a different rule. `AppLock.now` is a closure and `AppLock.ask` is a
 * closure, so every branch below — including the ones that need a locked-out
 * sensor and a phone with no passcode, neither of which a simulator can be
 * talked into on demand — runs in microseconds against values this file makes up.
 *
 * The number under test is the number that ships: `AppLock.grace`, read rather
 * than restated.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class AppLockTests: XCTestCase {

    // MARK: - Fixtures

    private var defaults: UserDefaults!
    private let suite = "dev.terminaldeck.applock.tests"
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// A lock with a made-up clock and a made-up sensor. `answers` is what the
    /// prompt does, in order; the last one repeats.
    private func make(enabled: Bool = false,
                      availability: AppLockAvailability = .biometry(.faceID),
                      answers: [BiometryOutcome] = [.unlocked(.init())]) -> AppLock {
        defaults.set(enabled, forKey: AppLock.defaultsKey)
        let lock = AppLock(defaults: defaults)
        var queue = answers
        lock.now = { self.start }
        lock.look = { availability }
        lock.ask = { _ in queue.count > 1 ? queue.removeFirst() : (queue.first ?? .cancelled) }
        return lock
    }

    /// A lock that is on and already unlocked for this session — the state the
    /// app is in whenever somebody is actually using it. Reached the real way,
    /// through an authentication that succeeds, rather than by writing to a
    /// property from outside.
    private func running(_ availability: AppLockAvailability = .biometry(.faceID)) async -> AppLock {
        let lock = make(enabled: true, availability: availability)
        await lock.unlock()
        XCTAssertFalse(lock.isLocked, "the fixture itself failed to unlock")
        return lock
    }

    /// Walk the app away and back, `seconds` apart, the way `TerminalDeckApp`
    /// does it: inactive, background, then active.
    private func leaveAndReturn(_ lock: AppLock, for seconds: TimeInterval) {
        var clock = start
        lock.now = { clock }
        lock.wentInactive()
        lock.wentToBackground()
        clock = start.addingTimeInterval(seconds)
        lock.becameActive()
    }

    // MARK: - Off unless somebody asks for it

    /**
     * **"Optional for the overall application."**
     *
     * A fresh install has no key at all, and absent has to read as off — an app
     * that shipped this feature switched on would be an app that locked people
     * out of their own servers on an update they did not ask for.
     */
    func testAFreshInstallIsNotLockedAndTheSwitchIsOff() {
        let lock = AppLock(defaults: defaults)
        XCTAssertFalse(lock.enabled)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isCovered)
    }

    /// With the lock off, nothing is ever covered, however long the app is away.
    func testWithTheLockOffAnAbsenceOfAnHourLocksNothing() {
        let lock = make(enabled: false)
        leaveAndReturn(lock, for: 3600)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isShielded)
    }

    // MARK: - When it asks

    /**
     * **A cold start asks.** The whole feature in one line: a fresh process is
     * constructed locked, before any view has drawn, so there is no frame in
     * which the session list is on screen for somebody who has not authenticated.
     */
    func testAColdStartIsLocked() {
        let lock = make(enabled: true)
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.isCovered)
    }

    /**
     * **"I don't want it to come every time when we open the application."**
     *
     * The app switcher, a share sheet, a glance at Messages. Four seconds away
     * is not away, and this is the test that would have failed against the
     * behaviour he threw out.
     */
    func testComingBackAfterAFewSecondsDoesNotAsk() async {
        let lock = await running()
        leaveAndReturn(lock, for: 4)
        XCTAssertFalse(lock.isLocked, "four seconds away must not re-ask")
    }

    /// One second under the grace is still inside it. The boundary is stated
    /// rather than assumed, because "about five minutes" is how a rule becomes
    /// two rules.
    func testJustUnderTheGraceDoesNotAsk() async {
        let lock = await running()
        leaveAndReturn(lock, for: AppLock.grace - 1)
        XCTAssertFalse(lock.isLocked)
    }

    /// And past it, it does.
    func testPastTheGraceItLocks() async {
        let lock = await running()
        leaveAndReturn(lock, for: AppLock.grace + 1)
        XCTAssertTrue(lock.isLocked)
    }

    /**
     * **Inactive is not away.**
     *
     * Going inactive is the app switcher opening, a call arriving — and, most
     * importantly, the system's own Face ID sheet, which makes this app inactive
     * while it is up. None of them may lock anything. What inactivity does do is
     * raise the privacy cover, so the snapshot iOS takes for the app switcher is
     * not somebody's terminal.
     */
    func testGoingInactiveShieldsButNeverLocks() async {
        let lock = await running()
        lock.wentInactive()
        XCTAssertFalse(lock.isLocked)
        XCTAssertTrue(lock.isShielded)
        XCTAssertTrue(lock.isCovered)
        lock.becameActive()
        XCTAssertFalse(lock.isShielded)
        XCTAssertFalse(lock.isCovered)
    }

    /**
     * The cover does **not** go over the app's own Face ID sheet.
     *
     * `evaluatePolicy` makes this app inactive for as long as its sheet is on
     * screen. Shielding there would paint a padlock over the prompt the person
     * is looking at, which is the app hiding from itself.
     */
    func testTheShieldStaysDownWhileTheSystemSheetIsUp() async {
        let lock = make(enabled: false, answers: [.cancelled])
        var duringPrompt = false
        lock.ask = { _ in
            lock.wentInactive()
            duringPrompt = lock.isShielded
            return .cancelled
        }
        await lock.setEnabled(true)
        XCTAssertFalse(duringPrompt, "the privacy cover must not go over the biometric sheet")
    }

    // MARK: - The prompt raises itself, exactly twice

    /**
     * `promptToken` is what the lock screen watches, and the two things it must
     * do are opposites: bump when the app comes back from the **background** to
     * a locked screen, and never bump when the app merely goes inactive.
     *
     * The second half is not tidiness. The biometric sheet makes this app
     * inactive; a token bumped there would re-raise the prompt the instant
     * somebody cancelled it, for ever, which is a Face ID sheet you cannot get
     * rid of without force-quitting.
     */
    func testTheTokenMovesOnAReturnFromBackgroundAndNeverOnInactivity() {
        let lock = make(enabled: true)
        let atStart = lock.promptToken

        lock.wentInactive()
        lock.becameActive()
        XCTAssertEqual(lock.promptToken, atStart, "inactivity must not re-raise the prompt")

        leaveAndReturn(lock, for: 2)
        XCTAssertGreaterThan(lock.promptToken, atStart,
                             "coming back to a locked app should ask again")
    }

    /// Locking after the grace also asks, without waiting for a second visit.
    func testLockingAfterTheGraceRaisesThePrompt() async {
        let lock = await running()
        let atStart = lock.promptToken
        leaveAndReturn(lock, for: AppLock.grace + 1)
        XCTAssertGreaterThan(lock.promptToken, atStart)
    }

    // MARK: - Unlocking, and every way it does not work

    func testASuccessfulUnlockOpensTheApp() async {
        let lock = make(enabled: true, answers: [.unlocked(.init())])
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.trouble)
        XCTAssertFalse(lock.isCovered)
    }

    /**
     * **Cancelling is not a dead end.** It stays locked — that is the point of a
     * lock — and it says so in a sentence, with the button still there.
     */
    func testCancellingLeavesItLockedWithASentenceAndAWayThrough() async {
        let lock = make(enabled: true, answers: [.cancelled])
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue((lock.trouble ?? "").contains("Unlock"),
                      "the sentence has to name what to press: \(lock.trouble ?? "nothing")")
        XCTAssertFalse(lock.stranded, "a cancel is not a phone that cannot authenticate")
    }

    /// Five wrong faces. The way out is this iPhone's passcode, and iOS offers it
    /// on the prompt itself — so the sentence says passcode rather than "locked".
    func testALockedOutSensorPointsAtThePasscode() async {
        let lock = make(enabled: true,
                        availability: .passcode(.lockedOut(.faceID)),
                        answers: [.lockedOut(.faceID)])
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue((lock.trouble ?? "").contains("passcode"),
                      "a lockout must point at the passcode: \(lock.trouble ?? "nothing")")
    }

    /// Face ID switched off in the phone's own Settings while this app was away.
    /// Still not a dead end: the passcode opens it.
    func testAnUnenrolledSensorPointsAtThePasscode() async {
        let lock = make(enabled: true,
                        availability: .passcode(.notEnrolled(.faceID)),
                        answers: [.notEnrolled(.faceID)])
        await lock.unlock()
        XCTAssertTrue((lock.trouble ?? "").contains("passcode"))
    }

    /// The system's own words rather than this app's guess, plus what to press.
    func testAnUnexpectedFailureIsQuotedAndOffersARetry() async {
        let lock = make(enabled: true, answers: [.failed("Authentication failed.")])
        await lock.unlock()
        XCTAssertTrue((lock.trouble ?? "").contains("Authentication failed."))
        XCTAssertTrue((lock.trouble ?? "").contains("Unlock"))
    }

    /**
     * **The one state that would otherwise need the app deleted.**
     *
     * A phone whose passcode has been removed can authenticate nobody:
     * `.deviceOwnerAuthentication` throws `passcodeNotSet` for ever, biometry
     * needs a passcode to exist at all, and a lock that keeps asking is a person
     * locked out of their own servers with no route back. So the screen checks
     * whether anybody *can* be asked before asking, says why, and opens.
     */
    func testAPhoneWithNoPasscodeIsNotLockedOutOfItsOwnApp() async {
        let lock = make(enabled: true, availability: .impossible)
        await lock.unlock()
        XCTAssertTrue(lock.isLocked, "it does not simply open — it explains first")
        XCTAssertTrue(lock.stranded)
        XCTAssertTrue((lock.trouble ?? "").contains("passcode"))

        lock.continueWithoutLock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.enabled, "the lock turns itself off rather than asking again next time")
        XCTAssertFalse(defaults.bool(forKey: AppLock.defaultsKey))
        XCTAssertNotNil(lock.notice, "Settings has to say what happened to their switch")
    }

    // MARK: - The switch

    func testTurningItOnAsksOnceAndSticks() async {
        let lock = make(enabled: false, answers: [.unlocked(.init())])
        await lock.setEnabled(true)
        XCTAssertTrue(lock.enabled)
        XCTAssertTrue(defaults.bool(forKey: AppLock.defaultsKey), "it has to survive a relaunch")
        XCTAssertNil(lock.trouble)
    }

    /**
     * Turning it on must not then drop its own lock screen over the Settings
     * page the person is standing on. They authenticated one second ago.
     */
    func testTurningItOnDoesNotImmediatelyLockTheScreenItWasPressedOn() async {
        let lock = make(enabled: false, answers: [.unlocked(.init())])
        await lock.setEnabled(true)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isCovered)
    }

    /// A cancelled prompt changes nothing and says nothing: the switch springing
    /// back is the whole of the message.
    func testCancellingTheSwitchChangesNothingAndSaysNothing() async {
        let lock = make(enabled: false, answers: [.cancelled])
        await lock.setEnabled(true)
        XCTAssertFalse(lock.enabled)
        XCTAssertNil(lock.trouble)
        XCTAssertFalse(defaults.bool(forKey: AppLock.defaultsKey))
    }

    /**
     * **Turning it off is behind the sensor, and that is the point of the
     * feature.** Without this, a phone handed over unlocked for thirty seconds
     * is a phone whose lock can be switched off by whoever is holding it.
     */
    func testTurningItOffWithoutAuthenticatingIsRefused() async {
        let lock = make(enabled: true, answers: [.cancelled])
        await lock.setEnabled(false)
        XCTAssertTrue(lock.enabled, "a cancelled prompt must not switch the lock off")
        XCTAssertTrue(defaults.bool(forKey: AppLock.defaultsKey))
    }

    /// And with an authentication it goes off — once, and then never asks again.
    func testTurningItOffAsksOnceAndThenNeverAgain() async {
        let lock = await running()
        var asked = 0
        lock.ask = { _ in asked += 1; return .unlocked(.init()) }

        await lock.setEnabled(false)
        XCTAssertFalse(lock.enabled)
        XCTAssertEqual(asked, 1)

        // A relaunch, and a long absence. Neither asks anything of anybody.
        let next = AppLock(defaults: defaults)
        XCTAssertFalse(next.isLocked)
        next.ask = { _ in asked += 1; return .unlocked(.init()) }
        next.look = { .biometry(.faceID) }
        leaveAndReturn(next, for: 3600)
        XCTAssertFalse(next.isLocked)
        XCTAssertEqual(asked, 1, "off is off")
    }

    /// A phone with no passcode cannot be asked to lock anything, and the row
    /// says why rather than failing silently or hiding itself.
    func testAPhoneWithNoPasscodeIsRefusedWithAReason() async {
        let lock = make(enabled: false, availability: .impossible)
        var asked = false
        lock.ask = { _ in asked = true; return .unlocked(.init()) }
        await lock.setEnabled(true)
        XCTAssertFalse(lock.enabled)
        XCTAssertFalse(asked, "there is nobody to ask")
        XCTAssertTrue((lock.trouble ?? "").contains("passcode"))
    }

    // MARK: - What the screen calls it

    /**
     * The name on screen is the name that phone actually has. Never "Face ID" to
     * somebody holding an iPhone SE, and never a biometric name at all on a
     * device that has no sensor — where the honest word is *passcode*, and the
     * lock is a real lock all the same.
     */
    func testTheSwitchIsNamedAfterTheSensorThePhoneHas() {
        XCTAssertEqual(AppLockAvailability.biometry(.faceID).title, "Lock the app with Face ID")
        XCTAssertEqual(AppLockAvailability.biometry(.touchID).title, "Lock the app with Touch ID")
        XCTAssertEqual(AppLockAvailability.passcode(.unavailable).title,
                       "Lock the app with a passcode")
        XCTAssertEqual(AppLockAvailability.biometry(.touchID).symbol, "touchid")
        XCTAssertEqual(AppLockAvailability.biometry(.faceID).symbol, "faceid")
    }

    /// A device with a sensor and nothing enrolled is offered the lock anyway —
    /// on the passcode — and told how to get the sensor back into it.
    func testAnUnenrolledPhoneIsStillOfferedTheLockOnItsPasscode() {
        let availability = AppLockAvailability.passcode(.notEnrolled(.faceID))
        XCTAssertTrue(availability.canLock)
        let caveat = availability.caveat ?? ""
        XCTAssertTrue(caveat.contains("Face ID is not set up"), caveat)
        XCTAssertTrue(caveat.contains("passcode"), caveat)
        XCTAssertNil(availability.refusal)
    }

    /// The one line that states the rule, on both screens, naming the mechanism
    /// this phone will actually use and the window it applies to.
    func testTheRuleIsStatedInPlainWordsOnScreen() {
        let said = AppLockText.rule(.biometry(.faceID))
        XCTAssertTrue(said.contains("Face ID"), said)
        XCTAssertTrue(said.contains("when it starts"), said)
        XCTAssertTrue(said.contains(AppLock.graceWords), said)
        XCTAssertTrue(said.contains("app switcher"), said)
        XCTAssertEqual(AppLock.grace, 300, "the words on screen and the rule must agree")
    }

    // MARK: - The lock screen's own window follows the theme setting

    /**
     * The lock screen is in a `UIWindow` of its own, which is outside every
     * modifier `RootView` applies — including the one place in this app allowed
     * to state a colour scheme. So the same preference reaches it as
     * `overrideUserInterfaceStyle`, and `system` has to stay *unspecified*
     * rather than being resolved to whatever the phone happened to be when the
     * window was made.
     */
    func testTheLockWindowFollowsTheAppearanceSetting() {
        XCTAssertEqual(Appearance.system.interfaceStyle, .unspecified)
        XCTAssertEqual(Appearance.light.interfaceStyle, .light)
        XCTAssertEqual(Appearance.dark.interfaceStyle, .dark)
    }

    // MARK: - The old lock is gone from the source, not merely from the screen

    /**
     * A source walk, in the shape `AppearanceTests` uses, and for the same kind
     * of reason: this is a defect that looks perfectly correct until somebody
     * opens the one screen it is on.
     *
     * The per-server lock was offered in two places — a card after a login and a
     * switch on the server's own page — and both are gone. What must not come
     * back is a control that puts *one server's credential* behind biometry,
     * because that is what asked on every launch. The read path stays: a phone
     * upgrading from the previous build may still be holding a locked item, and
     * `ServerConnector.secret` lifts it the first time it is opened.
     */
    func testNothingOffersAPerServerBiometricLockAnyMore() throws {
        let sources = URL(fileURLWithPath: #filePath)      // …/ios/Tests/AppLockTests.swift
            .deletingLastPathComponent()                   // …/ios/Tests
            .deletingLastPathComponent()                   // …/ios
            .appendingPathComponent("TerminalDeck")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Prose talks about the old design at length on purpose — the
                // history is the reason the rule exists — so only real calls
                // count.
                guard !trimmed.hasPrefix("*"), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*")
                else { continue }
                if trimmed.contains("BiometricOfferCard") || trimmed.contains("BiometricLockRow") {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
                // Turning one *on* is what must never come back. `false` is the
                // lift, and it has two callers by design.
                if trimmed.contains("setBiometricLock(true") {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 30, "the source walk found almost nothing to read")
        XCTAssertTrue(offenders.isEmpty,
                      "the per-server lock is back, and it is what asked on every launch:\n"
                      + offenders.joined(separator: "\n"))
    }
}
