import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Owner, 13 Nov: no pairing anywhere. The local web version with its one-time address was a way to add a browser, so
/// no tool offers it any more; a call for it is answered with how devices join now, and nothing is opened or minted.
@MainActor
final class WEBOpenMCPTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport

    func testOpenWebIsRetiredAndAnswersHowDevicesJoin() async throws {
        let fixtureURL = "http://localhost:18443/#pair=" + String(repeating: "p", count: 43) + "&endpoint=ws://localhost:18443/ws"
        let channels = BackendDeckCoreTestPortSessionsChannels(["remote:web:open": .object([.init("url", .string(fixtureURL))]), "link:system": .bool(true)])
        let tool = BackendDeckToolsMachinesRemote(channels: channels)
        let spec = try S.spec("remote.manage")
        XCTAssertFalse(spec.inputSchema["properties"]["do"]["enum"].elements?.contains(.string("open-web")) == true)
        for args in [V.object([.init("do", .string("open-web"))]), V.object([.init("do", .string("open-web")), .init("openBrowser", .bool(false))])] {
            do { _ = try await tool.policy(spec, args, S.context()); XCTFail("open-web is retired") }
            catch { XCTAssertEqual((error as? BackendDeckCoreSecurityRefusal)?.message, DevicesPage.joinBySigningIn) }
            do { _ = try await tool.run("remote.manage", args, S.context()); XCTFail("open-web is retired") }
            catch { XCTAssertEqual((error as? BackendDeckCoreSecurityRefusal)?.message, DevicesPage.joinBySigningIn) }
        }
        let calls = await channels.calls
        XCTAssertTrue(calls.isEmpty, "nothing was opened or minted")
    }
}
