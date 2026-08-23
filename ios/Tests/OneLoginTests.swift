/**
 * **One login screen**, the field that can hold a key, and the lock in front of
 * the credential — the three things this lane changed, checked without a
 * simulator.
 *
 * What a unit test can prove here is narrow and worth having: that a seven-line
 * key read back through the app's own reader is described as seven lines, that a
 * flattened one is caught *before* the login rather than as a refusal from the
 * server, that the address field can tell the two things it accepts apart, and
 * that a server record written before biometry existed still decodes. The rest —
 * whether the screen is the first thing the app shows, whether the paste
 * survives a real pasteboard — needs a finger, and `UITests/OneLoginUITests`
 * is the finger.
 */

import XCTest
@testable import TerminalDeck

final class OneLoginTests: XCTestCase {

    /* ------------------------------------------------------------ the key -- */

    /**
     * A real `ssh-keygen -t ed25519` key. Seven lines, generated once and
     * thrown away — it opens nothing and never did.
     *
     * It is a **real** one rather than the synthesised block the reader tests
     * use, and that is the whole point: the synthesised one puts its base64 on a
     * single line, so it is three lines long and could never have caught the bug
     * this fixture exists for. What ships out of `ssh-keygen` wraps at 70
     * characters, which is what a person actually pastes.
     */
    private static let ed25519 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAGoGillv8DoBPMBZpKK7bifOdw2DDnTv0K6TiHU3+z8gAAAKCqC4pRqguK
        UQAAAAtzc2gtZWQyNTUxOQAAACAGoGillv8DoBPMBZpKK7bifOdw2DDnTv0K6TiHU3+z8g
        AAAEDv1xwg1SSJJZx0fHxXagl2laUOOcOIe1h/k89KaD3zeQagaKWW/wOgE8wFmkortuJ8
        53DYMOdO/QrpOIdTf7PyAAAAGWZpeHR1cmVAdGVybWluYWxkZWNrLnRlc3QBAgME
        -----END OPENSSH PRIVATE KEY-----
        """

    func testARealSevenLineKeyReadsBackAsSevenLines() {
        let readback = PrivateKeyReadback.of(Self.ed25519)
        XCTAssertTrue(readback.isGood, "a real ed25519 key was not readable: \(readback)")
        let said = readback.sentence ?? ""
        XCTAssertTrue(said.contains("7 lines"), said)
        XCTAssertTrue(said.contains("BEGIN and END are both here"), said)
        XCTAssertTrue(said.contains("OpenSSH"), said)
    }

    /// A trailing newline is what a copied *file* carries, and counting it would
    /// report eight lines for a seven-line key — a number that does not match
    /// what somebody sees in their editor, on the one screen whose job is to
    /// convince them the paste was whole.
    func testATrailingNewlineIsNotAnEighthLine() {
        let readback = PrivateKeyReadback.of(Self.ed25519 + "\n")
        XCTAssertTrue(readback.sentence?.contains("7 lines") == true,
                      readback.sentence ?? "nothing was said")
    }

    /**
     * The bug, as a test.
     *
     * A single-line secure field eats the newlines, and the *character count*
     * the old field reported is identical either way — which is how a mangled
     * key was announced as "ready" and then refused by the server as a bad
     * password. Caught here, on the form, with its own sentence.
     */
    func testAFlattenedKeyIsCaughtBeforeTheLogin() {
        let flattened = Self.ed25519.replacingOccurrences(of: "\n", with: " ")
        let readback = PrivateKeyReadback.of(flattened)
        XCTAssertFalse(readback.isGood, "a key with no newlines in it was accepted")
        guard case let .bad(headline, advice) = readback else {
            return XCTFail("expected a refusal, got \(readback)")
        }
        XCTAssertFalse(headline.isEmpty)
        XCTAssertFalse(advice.isEmpty, "a refusal with no next move is a dead end")
    }

    /// One line and nothing else is the shape a flattened paste actually takes,
    /// and it gets a sentence about *the paste* rather than about the key.
    func testOneLineOfNonsenseIsCalledOutAsOneLine() {
        guard case let .bad(headline, advice) = PrivateKeyReadback.of("not a key at all") else {
            return XCTFail("nonsense was accepted as a key")
        }
        XCTAssertTrue(headline.contains("one line"), headline)
        XCTAssertTrue(advice.contains("BEGIN"), advice)
    }

    /// The mistake worth naming: the two files sit beside each other and only
    /// one of them can sign.
    func testThePublicHalfIsNamedAsThePublicHalf() {
        let pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAagaKWW/wOgE8wFmkortuJ8 fixture@test"
        guard case let .bad(_, advice) = PrivateKeyReadback.of(pub) else {
            return XCTFail("a public key was accepted as a private one")
        }
        XCTAssertTrue(advice.contains(".pub"), advice)
    }

    func testNothingPastedSaysNothing() {
        XCTAssertEqual(PrivateKeyReadback.of(""), .nothing)
        XCTAssertEqual(PrivateKeyReadback.of("   \n  "), .nothing)
        XCTAssertNil(PrivateKeyReadback.of("").sentence)
    }

    /* ------------------------------------------------- one field, two things -- */

    /**
     * The address field takes either thing, and the fork is in the transport.
     *
     * This is what let two screens become one: a hostname and a printed server
     * address cannot be mistaken for each other, so one field can hold either
     * and the screen can say which it recognised before anything is pressed.
     */
    func testAHostnameIsNotAServerAddress() {
        for typed in ["example.com", "10.0.0.4", "asad.dev", "192.168.1.9", "srv.local"] {
            guard case .failure = ServerAddress.parse(typed) else {
                return XCTFail("\(typed) was read as a printed server address")
            }
        }
    }

    func testWhatAHostPrintsIsAServerAddress() {
        guard case .success = ServerAddress.parse(ServerAddressFixture.printedByAHost) else {
            return XCTFail("the address a host prints was not recognised")
        }
    }

    /* ----------------------------------------------------------- the lock -- */

    /**
     * A server written before biometry existed still decodes.
     *
     * `biometricLock` is optional for exactly this reason: one item per server
     * means one bad decode is one lost server, but a *field* added as a
     * non-optional `Bool` would fail every record at once — which reads as "no
     * servers at all" on the first launch after an update.
     */
    func testAServerRecordFromBeforeTheLockStillDecodes() throws {
        let old = """
        {"id":"a","name":"box","address":"example.com","port":2222,"username":"root",
         "credential":"password","addedAt":770000000}
        """
        let server = try JSONDecoder().decode(StoredServer.self, from: Data(old.utf8))
        XCTAssertEqual(server.port, 2222)
        XCTAssertNil(server.biometricLock)
        XCTAssertFalse(server.isBiometricLocked, "an absent flag is not a lock")
    }

    func testALockedRecordSaysSo() throws {
        let raw = """
        {"id":"a","name":"box","address":"example.com","port":22,"username":"root",
         "credential":"key","addedAt":770000000,"biometricLock":true}
        """
        let server = try JSONDecoder().decode(StoredServer.self, from: Data(raw.utf8))
        XCTAssertTrue(server.isBiometricLocked)
    }

    /* ------------------------------------------------------- what it says -- */

    /// The name on screen is the name that phone has. A screen saying "Face ID"
    /// to somebody holding a device with a fingerprint reader is telling them
    /// about a sensor their phone does not have.
    func testBiometryIsCalledWhatTheDeviceCallsIt() {
        XCTAssertEqual(BiometryAvailability.ready(.faceID).name, "Face ID")
        XCTAssertEqual(BiometryAvailability.ready(.touchID).name, "Touch ID")
        XCTAssertEqual(BiometryAvailability.ready(.opticID).name, "Optic ID")
        XCTAssertNil(BiometryKind.none.name)
        // A phone with nothing still gets a sentence rather than a blank.
        XCTAssertFalse(BiometryAvailability.unavailable.name.isEmpty)
    }

    /// Every state a real phone can be in gets a true sentence and a way
    /// through. `ready` is the only one with nothing to say, because it is the
    /// only one that is not in anybody's way.
    func testEveryRefusalNamesAWayThrough() {
        XCTAssertNil(BiometryAvailability.ready(.faceID).refusal)
        for state in [BiometryAvailability.notEnrolled(.faceID),
                      .notEnrolled(.touchID),
                      .lockedOut(.faceID),
                      .unavailable] {
            let refusal = state.refusal ?? ""
            XCTAssertFalse(refusal.isEmpty, "\(state) has no sentence")
            XCTAssertTrue(refusal.count > 30, "\(state): \(refusal)")
        }
        XCTAssertTrue(BiometryAvailability.notEnrolled(.touchID).refusal?.contains("Touch ID") == true)
        XCTAssertTrue(BiometryAvailability.lockedOut(.faceID).refusal?.contains("passcode") == true,
                      "a locked-out sensor must name the passcode as the way back")
    }

    /// Only `ready` offers anything, because a control that cannot act is not
    /// drawn.
    func testOnlyAReadySensorIsOffered() {
        XCTAssertTrue(BiometryAvailability.ready(.faceID).isReady)
        XCTAssertFalse(BiometryAvailability.notEnrolled(.faceID).isReady)
        XCTAssertFalse(BiometryAvailability.lockedOut(.faceID).isReady)
        XCTAssertFalse(BiometryAvailability.unavailable.isReady)
    }

    /* -------------------------------------------------------- the trouble -- */

    /// An SSH failure keeps its own two sentences on the way through the new
    /// wrapper — nothing above it had to learn a different shape.
    func testAnSSHFailureKeepsItsOwnWords() {
        let trouble = ServerTrouble(.noAnswer)
        XCTAssertEqual(trouble.headline, SSHProblem.noAnswer.headline)
        XCTAssertEqual(trouble.advice, SSHProblem.noAnswer.advice)
        XCTAssertTrue(trouble.advice.contains("port"),
                      "the no-answer advice has to mention the port; that is the field that fixes it")
    }

    /// The lock's own failures are sentences, never bare codes.
    func testALockFailureIsASentence() {
        for problem in [ServerStore.LockProblem.noSecret, .noPasscode, .notWritten] {
            XCTAssertFalse(problem.sentence.isEmpty)
            XCTAssertTrue(problem.sentence.hasSuffix("."), problem.sentence)
        }
        XCTAssertTrue(ServerStore.LockProblem.noPasscode.sentence.contains("passcode"))
    }
}
