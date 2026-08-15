/**
 * The credential proxy's frames, in both directions.
 *
 * Half of this file is about refusals, and that is the design rather than
 * thoroughness for its own sake. A `credential.request` becomes a prompt that
 * somebody reads before approving a `git push`, so the decoder's job is not
 * "produce a value" — it is to make it impossible for the prompt to name
 * something other than what the desktop said. Anything that could put a wrong or
 * unbounded string on that screen is a bug with a person's repository on the
 * other end of it.
 *
 * The other half is the outbound shape, checked field by field against
 * `parseClientMessage` in `src/main/remote/protocol.ts`. That parser answers a
 * frame it cannot read by **closing the socket**, so a mistake here does not
 * cost one push, it costs the connection.
 */

import XCTest
@testable import TerminalDeck

final class CredentialWireTests: XCTestCase {

    // MARK: - Inbound

    private func request(_ raw: String) -> ServerMessage? {
        guard case let .ok(message, _) = WireCodec.decode(raw) else { return nil }
        return message
    }

    func testAWriteRequestArrivesWithEverythingThePromptNeeds() {
        let raw = #"""
        {"t":"credential.request","id":"r1","host":"github.com","repo":"asadev/terminaldeck",
         "operation":"write","prompt":true}
        """#
        guard case let .credentialRequest(id, host, repo, operation, prompt) = request(raw) else {
            return XCTFail("expected a credential.request")
        }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(host, "github.com")
        XCTAssertEqual(repo, "asadev/terminaldeck")
        XCTAssertEqual(operation, .write)
        XCTAssertTrue(prompt)
    }

    /**
     * A read is a read even when the desktop says nothing about prompting.
     *
     * `prompt` absent means false, which means answer silently. Reading it the
     * other way round would put a prompt on somebody's phone for every `git
     * fetch`, which is the fatigue this policy exists to avoid.
     */
    func testAnAbsentPromptFieldIsSilent() {
        let raw = #"{"t":"credential.request","id":"r2","host":"github.com","repo":"a/b","operation":"read"}"#
        guard case let .credentialRequest(_, _, _, operation, prompt) = request(raw) else {
            return XCTFail("expected a credential.request")
        }
        XCTAssertEqual(operation, .read)
        XCTAssertFalse(prompt)
    }

    /// Anything that is not the JSON literal `true` is not an instruction to
    /// interrupt somebody. A string "true" is what a broken encoder sends.
    func testPromptIsOnlyHonouredAsABoolean() {
        let raw = #"{"t":"credential.request","id":"r3","host":"github.com","repo":"a/b","operation":"write","prompt":"true"}"#
        guard case let .credentialRequest(_, _, _, _, prompt) = request(raw) else {
            return XCTFail("expected a credential.request")
        }
        XCTAssertFalse(prompt)
    }

    /**
     * A null repository is a real answer and is carried as nil.
     *
     * The desktop sends it when git gave no path to derive a name from — a gist,
     * a wiki, a self-hosted layout. Refusing the frame would turn "this machine
     * does not know what the repository is called" into a push that cannot be
     * answered at all; the prompt says so instead.
     */
    func testANullRepositoryIsCarriedRatherThanRefused() {
        let raw = #"{"t":"credential.request","id":"r4","host":"github.com","repo":null,"operation":"write","prompt":true}"#
        guard case let .credentialRequest(_, _, repo, _, _) = request(raw) else {
            return XCTFail("expected a credential.request")
        }
        XCTAssertNil(repo)
    }

    func testAnUnknownOperationIsRefused() {
        // Not a value in `CREDENTIAL_OPERATIONS`. Guessing at one would mean
        // guessing whether to prompt.
        let raw = #"{"t":"credential.request","id":"r5","host":"github.com","repo":"a/b","operation":"amend","prompt":true}"#
        XCTAssertNil(request(raw))
    }

    func testARequestWithNoHostIsRefused() {
        let raw = #"{"t":"credential.request","id":"r6","repo":"a/b","operation":"write","prompt":true}"#
        XCTAssertNil(request(raw))
    }

    func testARequestWithNoIdIsRefused() {
        // Without the id there is nothing to answer, so the frame is not a
        // question — it is a prompt that could never be replied to.
        let raw = #"{"t":"credential.request","id":"","host":"github.com","operation":"read"}"#
        XCTAssertNil(request(raw))
    }

    /**
     * An absurd hostname does not reach the prompt.
     *
     * The desktop bounds what it will say with the same number, so this only
     * fires against something that is not the desktop — but the string it would
     * carry lands on the one screen in this feature that must not be able to
     * lie about what it is naming.
     */
    func testAnOverlongHostIsRefused() {
        let host = String(repeating: "a", count: Wire.maxCredentialHostLength + 1)
        let raw = #"{"t":"credential.request","id":"r7","host":"\#(host)","operation":"write","prompt":true}"#
        XCTAssertNil(request(raw))
    }

    /// An overlong repository is dropped to nil rather than failing the frame:
    /// the push is still answerable, and the prompt says it cannot name the
    /// repository — which is exactly true.
    func testAnOverlongRepoBecomesNil() {
        let repo = String(repeating: "b", count: Wire.maxCredentialRepoLength + 1)
        let raw = #"{"t":"credential.request","id":"r8","host":"github.com","repo":"\#(repo)","operation":"write","prompt":true}"#
        guard case let .credentialRequest(_, _, parsed, _, _) = request(raw) else {
            return XCTFail("expected a credential.request")
        }
        XCTAssertNil(parsed)
    }

    // MARK: - Outbound

    private func encoded(_ message: ClientMessage) -> [String: Any] {
        let text = WireCodec.encode(message)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("not JSON: \(text)")
            return [:]
        }
        return object
    }

    func testTheAcknowledgementIsTheFrameTheDesktopWaitsFourSecondsFor() {
        let object = encoded(.credentialAck(id: "r1"))
        XCTAssertEqual(object["t"] as? String, "credential.ack")
        XCTAssertEqual(object["id"] as? String, "r1")
    }

    func testAnAnswerCarriesTheLoginAndTheSecretUnderTheNamesGitReads() {
        let object = encoded(.credentialAnswer(id: "r1", username: "asadev", password: "gho_x", remember: false))
        XCTAssertEqual(object["t"] as? String, "credential.answer")
        XCTAssertEqual(object["username"] as? String, "asadev")
        XCTAssertEqual(object["password"] as? String, "gho_x")
    }

    /**
     * `remember` is written only when it is true.
     *
     * `parseClientMessage` reads it as `remember === true`, so a `false` on the
     * wire would be a field that says nothing while carrying somebody's standing
     * consent as its name. On the frame that grants a repository a permanent
     * approval, the literal shape is worth being exact about.
     */
    func testRememberIsAbsentUnlessItWasChosen() {
        XCTAssertNil(encoded(.credentialAnswer(id: "r", username: "u", password: "p", remember: false))["remember"])
        XCTAssertEqual(
            encoded(.credentialAnswer(id: "r", username: "u", password: "p", remember: true))["remember"] as? Bool,
            true)
    }

    func testADenialCarriesACodeRatherThanASentence() {
        // The desktop writes the words that go into its own terminal; this end
        // says which of two things happened. See `CredentialDenial`.
        XCTAssertEqual(encoded(.credentialDeny(id: "r", reason: .denied))["reason"] as? String, "denied")
        XCTAssertEqual(encoded(.credentialDeny(id: "r", reason: .noAccount))["reason"] as? String, "no-account")
    }

    /**
     * The `hello` says this client can answer.
     *
     * Both halves of the negotiation are load bearing: a desktop that asked a
     * phone which had never heard of the frame would sit there until a timer
     * gave up, which is the thirty-second stall on a push that the whole feature
     * exists to not have.
     */
    func testHelloAdvertisesTheCredentialCapability() {
        let object = encoded(WireCodec.hello(token: "t", device: DeviceDescriptor(name: "iPhone", platform: "iOS")))
        let claimed = object["capabilities"] as? [String]
        XCTAssertEqual(claimed, [WireCapability.credential])
    }

    /**
     * And it claims nothing it does not serve.
     *
     * `create`, `localhost` and `upload` run the other way — they are things
     * this phone asks a desktop for, gated by what the desktop advertised — so
     * naming them here would be a claim about frames this client never answers.
     */
    func testHelloDoesNotClaimTheDesktopsOwnCapabilities() {
        for name in [WireCapability.create, WireCapability.localhost, WireCapability.upload] {
            XCTAssertFalse(WireCapability.claimed.contains(name), "should not claim \(name)")
        }
    }
}
