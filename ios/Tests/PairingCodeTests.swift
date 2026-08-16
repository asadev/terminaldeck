/**
 * Pairing codes: the one input to this app that arrives from outside it.
 *
 * A code decides which machine the phone talks to *and* which key it will accept
 * an answer from, so the failures worth testing are the ones where a wrong code
 * becomes a connection rather than a refusal.
 *
 * This file used to be about URLs — a `terminaldeck://pair?…` link off a QR code
 * and a tailnet link with a token in its fragment. Both are gone. What arrives
 * here now is six digits somebody read off the Mac's screen, so what is tested is
 * the reading of those and the endpoint the rendezvous hands back afterwards.
 */

import XCTest
@testable import TerminalDeck

final class PairingCodeTests: XCTestCase {

    private let hostId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private let key = "uf77Z4vuXGfNAdb7WR5yDwll8f70x_nB4wAamjFi_DU"

    // MARK: - The format

    func testReadsSixDigits() {
        guard case let .success(code) = PairingCodeParser.parse("482913") else {
            return XCTFail("six digits should parse")
        }
        XCTAssertEqual(code, "482913")
        XCTAssertEqual(PairingCodeParser.codeLength, 6)
    }

    func testKeepsALeadingZero() {
        /*
         * A code is six *digits*, not a number. `000042` is one the desktop mints
         * about one time in ten thousand, and anything on the path that treats it
         * as an integer turns it into `42` — which derives a different rendezvous
         * slot from every other client and reads on screen as a code that was
         * typed correctly and found nothing.
         */
        guard case let .success(code) = PairingCodeParser.parse("000042") else {
            return XCTFail("a leading zero is part of the code")
        }
        XCTAssertEqual(code, "000042")
    }

    func testDropsEverySeparatorSomethingMightHaveInserted() {
        // The string makes a journey: read off a screen, sometimes retyped into a
        // message, and messages insert things. Refusing these would mean refusing
        // the exact text somebody pasted.
        for typed in [" 482913 ", "482-913", "482 913", "482\u{2013}913", "4 8 2 9 1 3"] {
            guard case let .success(code) = PairingCodeParser.parse(typed) else {
                return XCTFail("\(typed) should read as a code")
            }
            XCTAssertEqual(code, "482913")
        }
    }

    func testRefusesALetterRatherThanFoldingIt() {
        /*
         * The eight-character format folded `O` onto `0` and `I`/`L` onto `1`,
         * because the screen was showing letters and three of them are unprintable
         * in the wrong face. The screen shows digits now, so a letter is a typo —
         * and folding a typo produces a *different valid code*, six characters
         * that read cleanly and belong to somebody else's pairing.
         */
        XCTAssertNil(PairingCodeParser.normalise("O82913"))
        XCTAssertNil(PairingCodeParser.normalise("48291I"))
        XCTAssertNil(PairingCodeParser.normalise("H4K9-2FQT"))
    }

    func testRefusesAnythingThatIsNotSixDigits() {
        XCTAssertNil(PairingCodeParser.normalise("48291"))
        XCTAssertNil(PairingCodeParser.normalise("4829131"))
        XCTAssertNil(PairingCodeParser.normalise("------"))
        XCTAssertNil(PairingCodeParser.normalise(""))
    }

    func testRefusesWithASentenceSomebodyCanActOn() {
        XCTAssertEqual(refusal(PairingCodeParser.parse("")), .empty)
        XCTAssertEqual(refusal(PairingCodeParser.parse("   ")), .empty)
        XCTAssertEqual(refusal(PairingCodeParser.parse("hello")), .notACode)
        XCTAssertEqual(refusal(PairingCodeParser.parse("terminaldeck://session/abc")), .notACode)
        // The old link shape is refused like any other typo, rather than parsed.
        XCTAssertEqual(refusal(PairingCodeParser.parse("terminaldeck://pair?v=1&t=x")), .notACode)
        XCTAssertTrue(PairingCodeError.notACode.detail.contains("six digits"))
    }

    func testDoesNotWalkAHostilePaste() {
        // Bounded before the scan, and bailing the moment there are too many
        // digits. Neither is a security boundary; both are what keeps a pasted
        // megabyte off the main thread.
        XCTAssertNil(PairingCodeParser.normalise(String(repeating: "1", count: 1_000_000)))
        XCTAssertEqual(PairingCodeParser.normalise("482913" + String(repeating: " ", count: 1_000)), "482913")
    }

    // MARK: - The endpoint the rendezvous hands back

    private var relayEndpoint: DeckEndpoint {
        .relay(url: URL(string: "ws://127.0.0.1:8787")!,
               hostId: hostId,
               hostKey: PairingCodeParser.base64url(key)!)
    }

    func testTheSocketURLIsTheGuestEndpoint() {
        // `/v1/join?host=…` — the contract in relay/src/rendezvous.ts. Anything
        // else connects to a 404 and closes.
        XCTAssertEqual(relayEndpoint.socketURL.absoluteString,
                       "ws://127.0.0.1:8787/v1/join?host=\(hostId)")
    }

    func testTheSummarySaysWhoCanReadTheSession() {
        let direct = DeckEndpoint.direct(url: URL(string: "wss://mac.tail1234.ts.net/ws")!)
        XCTAssertTrue(relayEndpoint.summary.contains("sealed"))
        XCTAssertTrue(direct.summary.contains("direct"))
        XCTAssertTrue(relayEndpoint.isSealed)
        XCTAssertFalse(direct.isSealed)
    }

    func testTheDirectCaseStillDecodes() throws {
        /*
         * Nothing produces a `.direct` endpoint any more — it came from the
         * tailnet link, which is gone with the QR. The case stays because it is
         * on disk: a phone paired over the tailnet before this change has one in
         * its Keychain, and dropping the case would make that record undecodable
         * and sign the person out of a machine they are still paired with.
         */
        let direct = DeckEndpoint.direct(url: URL(string: "wss://mac.tail1234.ts.net/ws")!)
        let data = try JSONEncoder().encode(direct)
        XCTAssertEqual(try JSONDecoder().decode(DeckEndpoint.self, from: data), direct)
    }

    func testAnEndpointSurvivesTheKeychainRoundTrip() throws {
        let data = try JSONEncoder().encode(relayEndpoint)
        XCTAssertEqual(try JSONDecoder().decode(DeckEndpoint.self, from: data), relayEndpoint)
    }

    private func refusal(_ result: Result<String, PairingCodeError>) -> PairingCodeError? {
        guard case let .failure(error) = result else { return nil }
        return error
    }
}
