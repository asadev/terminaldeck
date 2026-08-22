/**
 * A pasted server address, in every shape one arrives in — and the four ways it
 * can be wrong.
 *
 * The refusals matter as much as the acceptances here. Every one of them is a
 * sentence somebody reads while holding a blob they believe is right, and the
 * common case is a paste that stopped one line short — so "the key is short" and
 * "that is not an address" have to be different answers, not one.
 */

import XCTest
@testable import TerminalDeck

final class ServerAddressTests: XCTestCase {

    private let hostId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private let relay = "wss://relay.terminaldeck.dev"
    /// 32 bytes, as standard base64 — the alphabet `machines/ipc.ts` produces.
    private var keyBase64: String { Data(repeating: 7, count: 32).base64EncodedString() }
    private var keyBase64URL: String {
        keyBase64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func expectRelay(_ result: Result<DeckEndpoint, ServerAddressError>,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case let .success(endpoint) = result else {
            return XCTFail("expected an endpoint, got \(result)", file: file, line: line)
        }
        guard case let .relay(url, id, key) = endpoint else {
            return XCTFail("expected a relay endpoint", file: file, line: line)
        }
        XCTAssertEqual(url.absoluteString, relay, file: file, line: line)
        XCTAssertEqual(id, hostId, file: file, line: line)
        XCTAssertEqual(key, Data(repeating: 7, count: 32), file: file, line: line)
    }

    // MARK: - The shapes

    /// `asEndpoint`'s own shape, in `pwa/src/endpoint.ts`. The contract.
    func testTheEndpointJSONTheBrowserClientAlreadyReads() {
        let blob = """
        {"kind":"relay","url":"\(relay)","hostId":"\(hostId)","hostKey":"\(keyBase64URL)"}
        """
        expectRelay(ServerAddress.parse(blob))
    }

    /// The rendezvous offer's field names, which are the same three facts under
    /// different spellings. Handling one and not the other would be a server
    /// address that works and one that does not, for the same machine.
    func testTheOfferSpellingOfTheSameThreeFacts() {
        let blob = """
        {"t":"machine","relayUrl":"\(relay)","hostId":"\(hostId)","publicKey":"\(keyBase64)"}
        """
        expectRelay(ServerAddress.parse(blob))
    }

    func testAKeyPrintedAsHex() {
        let hex = Data(repeating: 7, count: 32).map { String(format: "%02x", $0) }.joined()
        let blob = """
        {"url":"\(relay)","hostId":"\(hostId)","hostKey":"\(hex)"}
        """
        expectRelay(ServerAddress.parse(blob))
    }

    /// One unbroken token survives a paste; four lines of JSON do not.
    func testTheOneLineBlob() {
        let json = """
        {"kind":"relay","url":"\(relay)","hostId":"\(hostId)","hostKey":"\(keyBase64URL)"}
        """
        let packed = Data(json.utf8).base64EncodedString()
        expectRelay(ServerAddress.parse(packed))
        expectRelay(ServerAddress.parse("td1:\(packed)"))
    }

    func testTheURLShape() {
        let url = "terminaldeck://server?v=1&r=\(relay)&h=\(hostId)&k=\(keyBase64URL)"
        expectRelay(ServerAddress.parse(url))
    }

    /**
     * A labelled block, pasted with its heading.
     *
     * The case that makes the difference between a screen somebody can use and
     * one that teaches them to trim their selection: what a server prints to a
     * terminal has a title on it, and a finger on a phone selects the title.
     */
    func testALabelledBlockPastedWhole() {
        let printed = """
        Terminal Deck — server address

          relay:  \(relay)
          host:   \(hostId)
          key:    \(keyBase64)

        Paste this into the phone app.
        """
        expectRelay(ServerAddress.parse(printed))
    }

    func testWhitespaceAroundABlobIsNotAnError() {
        let json = """
        {"kind":"relay","url":"\(relay)","hostId":"\(hostId)","hostKey":"\(keyBase64URL)"}
        """
        expectRelay(ServerAddress.parse("\n  \(json)  \n"))
    }

    // MARK: - The refusals

    func testNothingPastedSaysSo() {
        XCTAssertEqual(ServerAddress.parse("   \n "), .failure(.empty))
    }

    func testAPairingCodeIsNotAServerAddress() {
        XCTAssertEqual(ServerAddress.parse("123456"), .failure(.notAnAddress))
    }

    /// A host id alone is the exact thing that could not be made to work — see
    /// `ServerAddress`'s header — so it must refuse rather than half-accept.
    func testAHostIdAloneIsRefused() {
        XCTAssertEqual(ServerAddress.parse(hostId), .failure(.notAnAddress))
    }

    func testARelayThatIsNotAWebSocketAddress() {
        let blob = """
        {"kind":"relay","url":"https://relay.terminaldeck.dev","hostId":"\(hostId)","hostKey":"\(keyBase64URL)"}
        """
        XCTAssertEqual(ServerAddress.parse(blob), .failure(.relay))
    }

    func testAHostIdInTheWrongAlphabet() {
        // `0` and `1` are not in the relay alphabet: they are the characters it
        // drops so that ids can be compared by eye.
        let blob = """
        {"kind":"relay","url":"\(relay)","hostId":"01G95TNJT64Q928VW3HVRYDR8J","hostKey":"\(keyBase64URL)"}
        """
        XCTAssertEqual(ServerAddress.parse(blob), .failure(.hostId))
    }

    /// The failure a wrapped line actually produces: a key that lost its end.
    func testAKeyThatIsShort() {
        let short = Data(repeating: 7, count: 24).base64EncodedString()
        let blob = """
        {"kind":"relay","url":"\(relay)","hostId":"\(hostId)","hostKey":"\(short)"}
        """
        XCTAssertEqual(ServerAddress.parse(blob), .failure(.hostKey))
    }

    func testAPasteTooLargeToBeAnAddress() {
        XCTAssertEqual(ServerAddress.parse(String(repeating: "a", count: 5000)), .failure(.notAnAddress))
    }

    /// Every refusal names something to do. A sentence that only describes the
    /// parser is a sentence nobody can act on.
    func testEveryRefusalSaysSomething() {
        for error in [ServerAddressError.empty, .notAnAddress, .relay, .hostId, .hostKey] {
            XCTAssertFalse(error.detail.isEmpty)
            XCTAssertTrue(error.detail.hasSuffix("."), "\(error) should read as a sentence")
        }
    }
}
