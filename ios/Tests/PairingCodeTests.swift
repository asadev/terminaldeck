/**
 * Pairing codes: the one input to this app that arrives from outside it.
 *
 * A code decides which machine the phone talks to *and* which key it will
 * accept an answer from, so the failures worth testing are the ones where a
 * wrong code becomes a connection rather than a refusal.
 */

import XCTest
@testable import TerminalDeck

final class PairingCodeTests: XCTestCase {

    private let hostId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private let key = "uf77Z4vuXGfNAdb7WR5yDwll8f70x_nB4wAamjFi_DU"
    private let token = "RFjbL6xO5rsZ0zRr7NpMJ7D7lmNl7fp04xZ5RzN-kFs"

    private func relayCode(host: String? = nil, key overrideKey: String? = nil,
                           relay: String = "ws%3A%2F%2F127.0.0.1%3A8787") -> String {
        "terminaldeck://pair?v=1&r=\(relay)&h=\(host ?? hostId)&k=\(overrideKey ?? key)&t=\(token)"
    }

    private func parse(_ raw: String) -> Result<PairingCode, PairingCodeError> {
        PairingCodeParser.parse(raw)
    }

    // MARK: - The relay shape

    func testReadsARelayCode() throws {
        guard case let .success(code) = parse(relayCode()) else { return XCTFail("should parse") }
        XCTAssertEqual(code.token, token)
        guard case let .relay(url, id, hostKey) = code.endpoint else { return XCTFail("expected a relay endpoint") }
        XCTAssertEqual(url.absoluteString, "ws://127.0.0.1:8787")
        XCTAssertEqual(id, hostId)
        XCTAssertEqual(hostKey.count, 32)
        XCTAssertTrue(code.endpoint.isSealed)
    }

    func testTheSocketURLIsTheGuestEndpoint() throws {
        guard case let .success(code) = parse(relayCode()) else { return XCTFail("should parse") }
        // `/v1/join?host=…` — the contract in relay/src/rendezvous.ts. Anything
        // else connects to a 404 and closes.
        XCTAssertEqual(code.endpoint.socketURL.absoluteString, "ws://127.0.0.1:8787/v1/join?host=\(hostId)")
    }

    func testTheFingerprintIsTheOneTheMacShows() throws {
        guard case let .success(code) = parse(relayCode()) else { return XCTFail("should parse") }
        let raw = try XCTUnwrap(PairingCodeParser.base64url(key))
        XCTAssertEqual(code.fingerprint, sealedFingerprint(raw))
    }

    func testTranslatesAnHttpsRelayIntoAWebSocketOne() throws {
        let encoded = "https%3A%2F%2Frelay.example%2Fsomething"
        guard case let .success(code) = parse(relayCode(relay: encoded)) else { return XCTFail("should parse") }
        // The path is dropped: the endpoint is fixed by the relay's contract,
        // not by whatever page the link was copied from.
        XCTAssertEqual(code.endpoint.socketURL.absoluteString, "wss://relay.example/v1/join?host=\(hostId)")
    }

    // MARK: - Refusals

    func testRefusesAHostIdInTheWrongAlphabet() {
        // `0`, `1`, `O` and `I` are not in the alphabet precisely so nobody
        // misreads one; a code containing them is not a code.
        guard case let .failure(error) = parse(relayCode(host: "M9G95TNJT64Q928VW3HVRYDR80")) else {
            return XCTFail("should refuse")
        }
        XCTAssertEqual(error, .badHostId)
    }

    func testRefusesAHostIdOfTheWrongLength() {
        guard case .failure(.badHostId) = parse(relayCode(host: "M9G95TNJT64Q928VW3HVRYDR8")) else {
            return XCTFail("should refuse a 25-character id")
        }
    }

    func testRefusesAKeyThatIsNot32Bytes() {
        guard case .failure(.badKey) = parse(relayCode(key: "c2hvcnQ")) else {
            return XCTFail("should refuse a short key")
        }
    }

    func testRefusesARelayThatIsNotAWebSocketAddress() {
        guard case .failure(.badRelay) = parse(relayCode(relay: "ftp%3A%2F%2Fexample.com")) else {
            return XCTFail("should refuse")
        }
    }

    func testRefusesSomethingThatIsNotACodeAtAll() {
        XCTAssertEqual(refusal(parse("")), .empty)
        XCTAssertEqual(refusal(parse("   ")), .empty)
        XCTAssertEqual(refusal(parse("hello")), .notACode)
        XCTAssertEqual(refusal(parse("terminaldeck://session/abc")), .notACode)
    }

    func testRefusesATokenThatHasBeenMangled() {
        // Whitespace and control characters are what a token looks like after a
        // messaging app has wrapped it.
        guard case .failure(.badToken) = parse("terminaldeck://pair?h=\(hostId)&k=\(key)&r=ws%3A%2F%2Fa.b&t=one%20two") else {
            return XCTFail("should refuse a token with a space in it")
        }
    }

    // MARK: - The tailnet shape

    func testReadsATailnetLinkWithTheTokenInTheFragment() throws {
        guard case let .success(code) = parse("https://mac.tail1234.ts.net/#t=\(token)") else {
            return XCTFail("should parse")
        }
        XCTAssertEqual(code.token, token)
        // `/ws` is WS_PATH in src/main/remote/server.ts; the link points at the
        // PWA the same server hosts, not at the socket.
        XCTAssertEqual(code.endpoint.socketURL.absoluteString, "wss://mac.tail1234.ts.net/ws")
        XCTAssertFalse(code.endpoint.isSealed)
        XCTAssertNil(code.fingerprint)
    }

    func testReadsABareFragmentToken() throws {
        guard case let .success(code) = parse("https://mac.tail1234.ts.net/#\(token)") else {
            return XCTFail("should parse")
        }
        XCTAssertEqual(code.token, token)
    }

    func testATailnetLinkWithoutATokenIsNotAPairingCode() {
        guard case .failure(.badToken) = parse("https://mac.tail1234.ts.net/") else {
            return XCTFail("should refuse")
        }
    }

    // MARK: - Endpoint description

    func testTheSummarySaysWhoCanReadTheSession() throws {
        guard case let .success(relay) = parse(relayCode()),
              case let .success(direct) = parse("https://mac.tail1234.ts.net/#t=\(token)") else {
            return XCTFail("should parse")
        }
        XCTAssertTrue(relay.endpoint.summary.contains("sealed"))
        XCTAssertTrue(direct.endpoint.summary.contains("direct"))
    }

    func testAnEndpointSurvivesTheKeychainRoundTrip() throws {
        guard case let .success(code) = parse(relayCode()) else { return XCTFail("should parse") }
        let data = try JSONEncoder().encode(code.endpoint)
        XCTAssertEqual(try JSONDecoder().decode(DeckEndpoint.self, from: data), code.endpoint)
    }

    private func refusal(_ result: Result<PairingCode, PairingCodeError>) -> PairingCodeError? {
        guard case let .failure(error) = result else { return nil }
        return error
    }
}
