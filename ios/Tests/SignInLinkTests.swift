/**
 * The sign-in driver: the fixed frame sequence, and the two ways it can end.
 *
 * A port of `pwa/src/signin.test.ts`. `SignIn` opens with `enroll`, takes an
 * `enrolled`, replies with a `hello` carrying the minted credential on the same
 * socket, and settles on the `welcome` — or on an `error` at either step.
 * Anything else before the welcome is dropped, because a sign-in in flight is
 * not an authenticated socket yet.
 */

import XCTest
@testable import TerminalDeck

final class SignInLinkTests: XCTestCase {

    private let device = DeviceDescriptor(name: "iPhone", platform: "ios")

    private func input() -> SignInInput {
        SignInInput(username: "asad", secret: "hunter2", method: .password, device: device)
    }

    func testTheHappyPathMintsAndReconnects() {
        var sent: [ClientMessage] = []
        var outcome: SignInOutcome?
        let signIn = SignIn(send: { sent.append($0) }, onOutcome: { outcome = $0 })

        signIn.start(input())
        // Opens with enroll.
        guard case .enroll = sent.first else { return XCTFail("expected enroll first") }

        signIn.receive(.enrolled(deviceId: "dev-9", deviceName: "iPhone", credential: "dev-9.secret"))
        // Answers with a hello carrying the minted credential, on the same socket.
        guard case let .hello(_, token, _, capabilities) = sent.last else { return XCTFail("expected hello") }
        XCTAssertEqual(token, "dev-9.secret")
        XCTAssertTrue(capabilities.contains(WireCapability.watch))

        signIn.receive(makeWelcome())
        guard case let .ok(token2, id, name) = outcome else { return XCTFail("expected ok") }
        XCTAssertEqual(token2, "dev-9.secret")
        XCTAssertEqual(id, "dev-9")
        XCTAssertEqual(name, "iPhone")
    }

    func testARefusalEndsItInTheHostsOwnWords() {
        var outcome: SignInOutcome?
        let signIn = SignIn(send: { _ in }, onOutcome: { outcome = $0 })
        signIn.start(input())
        signIn.receive(.error(code: .unauthorized, message: "That login was not accepted."))
        XCTAssertEqual(outcome, .failed(message: "That login was not accepted."))
    }

    func testAStrayFrameBeforeTheWelcomeIsIgnored() {
        var outcome: SignInOutcome?
        var sent: [ClientMessage] = []
        let signIn = SignIn(send: { sent.append($0) }, onOutcome: { outcome = $0 })
        signIn.start(input())
        // A sessions list before enrolled: nothing this exchange asked for can
        // legitimately arrive first, and acting on one would act on an
        // unauthenticated socket.
        signIn.receive(.sessions([]))
        XCTAssertNil(outcome)
        XCTAssertEqual(sent.count, 1) // still just the enroll

        signIn.receive(.enrolled(deviceId: "dev-9", deviceName: "iPhone", credential: "dev-9.secret"))
        signIn.receive(makeWelcome())
        guard case .ok = outcome else { return XCTFail("expected ok after the real sequence") }
    }

    func testItSettlesOnlyOnce() {
        var outcomes: [SignInOutcome] = []
        let signIn = SignIn(send: { _ in }, onOutcome: { outcomes.append($0) })
        signIn.start(input())
        signIn.receive(.enrolled(deviceId: "d", deviceName: "iPhone", credential: "d.s"))
        signIn.receive(makeWelcome())
        signIn.receive(makeWelcome())
        XCTAssertEqual(outcomes.count, 1)
    }

    private func makeWelcome() -> ServerMessage {
        .welcome(protocolVersion: 1, deviceId: "dev-9", deviceName: "iPhone", token: nil,
                 sessions: [], capabilities: [], hostPlatform: .mac, hostName: nil,
                 folders: nil, copilot: .silent, appVersion: "0.10.0", hostKind: .headless)
    }
}
