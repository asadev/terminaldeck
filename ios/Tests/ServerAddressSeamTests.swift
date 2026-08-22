/**
 * The seam: what a host **prints**, read by what this app **runs**.
 *
 * ## Why this file is separate from `ServerAddressTests`
 *
 * Because that file is thorough, was green throughout, and this parser still
 * refused every real address. Its fixtures are assembled from the three facts —
 * which is the right instinct and is still an assembly from *that file's idea*
 * of the encoding. It even spells a `td1:` prefix, a label nothing in this
 * product has ever printed. Meanwhile `formatServerAddress` writes `srv1.` in
 * front of the base64, `Data(base64Encoded:)` refuses the `.`, and the Add-server
 * screen said "that is not a server address" about the only string a server
 * emits.
 *
 * So the rule here is the one that could have caught it: **no address in this
 * file was typed by a person.** Every string under test comes out of
 * `ServerAddressFixture.printedByAHost`, which is generated from the encoder
 * itself by `src/shared/server-address-fixture.test.ts` and re-checked against
 * that encoder on every `vitest run`. A hand-typed fixture is what let this bug
 * exist, so a hand-typed fixture cannot be what pins the fix.
 */

import XCTest
@testable import TerminalDeck

final class ServerAddressSeamTests: XCTestCase {

    /// The real encoder's real output. Generated — see the file's own header.
    private var printed: String { ServerAddressFixture.printedByAHost }

    private func expectTheFixtureMachine(_ result: Result<DeckEndpoint, ServerAddressError>,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard case let .success(endpoint) = result else {
            return XCTFail("this app refused the address a host prints: \(result)", file: file, line: line)
        }
        guard case let .relay(url, id, key) = endpoint else {
            return XCTFail("expected a relay endpoint, got \(endpoint)", file: file, line: line)
        }
        XCTAssertEqual(url.absoluteString, ServerAddressFixture.relayURL, file: file, line: line)
        XCTAssertEqual(id, ServerAddressFixture.hostId, file: file, line: line)
        // The bytes, not the spelling. The key inside that token is base64url and
        // contains both `-` and `_`, which is the pair a decoder that folds the
        // alphabet wrongly drops — leaving a key two bytes short and a handshake
        // that fails with nothing on screen.
        XCTAssertEqual(key, ServerAddressFixture.hostKey, file: file, line: line)
    }

    // MARK: - The address itself

    func testTheFixtureIsTheShapeAHostPrints() {
        XCTAssertTrue(printed.hasPrefix("srv\(ServerAddress.version)."),
                      "the generated fixture does not announce the version this build reads")
    }

    func testTheAddressAHostPrintsIsAccepted() {
        expectTheFixtureMachine(ServerAddress.parse(printed))
    }

    // MARK: - The ways that address survives being moved by hand

    func testWithTheNewlineATerminalPasteBrings() {
        expectTheFixtureMachine(ServerAddress.parse("  \(printed)\n"))
    }

    /// The paste this app's whole scanning section exists for: what
    /// `renderAddress` in `src/headless/cli.ts` puts on a console, selected with
    /// a finger, heading and closing sentences included.
    func testInsideTheBlockAConsolePrintsAroundIt() {
        let block = """
        Server address

          \(printed)

          Paste it into the app on a phone or another computer: Add a server, then
          sign in with a username and password or key this machine already accepts.

          This address is not a secret. It holds a public key and a public name at a
          relay, and it grants nothing on its own.
        """
        expectTheFixtureMachine(ServerAddress.parse(block))
    }

    /// A terminal that wrapped one long token at eighty columns. The first line
    /// is `srv1.` and seventy-five characters of body — a token by every rule
    /// this parser has, and one that decodes to nothing — so this is also the
    /// case that proves candidates are tried rather than the first one taken.
    func testWrappedAtEightyColumns() {
        var lines: [String] = []
        var rest = Substring(printed)
        while !rest.isEmpty {
            let end = rest.index(rest.startIndex, offsetBy: min(80, rest.count))
            lines.append(String(rest[rest.startIndex..<end]))
            rest = rest[end...]
        }
        expectTheFixtureMachine(ServerAddress.parse(lines.joined(separator: "\n")))
    }

    func testWithTheQuotesACopyTakesWithIt() {
        expectTheFixtureMachine(ServerAddress.parse("\"\(printed)\""))
        expectTheFixtureMachine(ServerAddress.parse("<\(printed)>"))
    }

    // MARK: - What this build cannot read

    /// Base64 decoding ignores what it does not recognise, so a shortened token
    /// decodes to *something*. Refused, not half-read into an endpoint that
    /// dials nothing.
    func testATokenWhoseTailASelectionLeftBehind() {
        XCTAssertEqual(ServerAddress.parse(String(printed.dropLast(6))), .failure(.notAnAddress))
    }

    /// The whole point of a version in the prefix. An address from a newer host
    /// is a diagnosable situation — update this app — and it must not arrive as
    /// the sentence a line of prose gets, which sends somebody back to a
    /// clipboard that was never the problem.
    func testAnAddressFromANewerServerNamesTheVersion() {
        let future = "srv\(ServerAddress.version + 1)." + printed.dropFirst("srv\(ServerAddress.version).".count)
        XCTAssertEqual(ServerAddress.parse(future), .failure(.wrongVersion(ServerAddress.version + 1)))

        guard case let .failure(error) = ServerAddress.parse(future) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(error.detail.contains("older than that server"),
                      "the sentence has to name which of the two is behind: \(error.detail)")
    }

    func testTheSameInsideABlock() {
        let future = "srv9." + printed.dropFirst("srv\(ServerAddress.version).".count)
        let block = "Server address\n  \(future)\n\n  Paste it into the app."
        XCTAssertEqual(ServerAddress.parse(block), .failure(.wrongVersion(9)))
    }

    /// A full stop in ordinary prose is not a version announcement. "Your app is
    /// too old", told to somebody who pasted the wrong thing, is worse than no
    /// sentence at all.
    func testProseIsNotAVersionAnnouncement() {
        XCTAssertEqual(ServerAddress.parse("srv1."), .failure(.notAnAddress))
        XCTAssertEqual(ServerAddress.parse("srv2.zip"), .failure(.notAnAddress))
        XCTAssertEqual(ServerAddress.parse("the file is at srv1.example.com/thing"), .failure(.notAnAddress))
    }

    /// A paste that also held something readable was never a version problem.
    func testAReadableAddressBeatsAForeignTokenInTheSamePaste() {
        let future = "srv9." + printed.dropFirst("srv\(ServerAddress.version).".count)
        expectTheFixtureMachine(ServerAddress.parse("\(future)\n\(printed)"))
    }
}
