import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class WEBOpenMCPTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport

    func testOpenWebHasEquivalentOwnerApprovedToolAndNeverLogsBootstrapURL() async throws {
        let fixtureURL = "http://localhost:18443/#pair=" + String(repeating: "p", count: 43) + "&endpoint=ws://localhost:18443/ws"
        let channels = BackendDeckCoreTestPortSessionsChannels(["remote:web:open": .object([.init("url", .string(fixtureURL))]), "link:system": .bool(true)])
        let tool = BackendDeckToolsMachinesRemote(channels: channels)
        let spec = try S.spec("remote.manage")
        XCTAssertTrue(spec.inputSchema["properties"]["do"]["enum"].elements?.contains(.string("open-web")) == true)
        let args = V.object([.init("do", .string("open-web"))])
        let policy = try await tool.policy(spec, args, S.context())
        XCTAssertEqual(policy.tier, .alter)
        XCTAssertTrue(policy.ownerMustAnswer)
        let opened = try await tool.run("remote.manage", args, S.context())
        XCTAssertEqual(opened.value["opened"].bool, true)
        XCTAssertFalse(opened.value.compact.contains("pair="))
        XCTAssertFalse(opened.summary.compact.contains("pair="))
        let calls = await channels.calls
        XCTAssertTrue(calls.contains { $0.channel == "link:system" && $0.args == [.string(fixtureURL)] })
        do {
            _ = try await tool.policy(spec, args, S.context(.remote))
            XCTFail("A paired browser cannot grant a new browser access")
        } catch {}
    }

    /// Review install-24 S2: the one-time address pairs any browser at Full, so an AI never receives it.
    func testOpenWebNeverHandsTheAddressToAnAI() async throws {
        let fixtureURL = "http://localhost:18443/#pair=" + String(repeating: "q", count: 43) + "&endpoint=ws://localhost:18443/ws"
        let channels = BackendDeckCoreTestPortSessionsChannels(["remote:web:open": .object([.init("url", .string(fixtureURL))]), "link:system": .bool(true)])
        let tool = BackendDeckToolsMachinesRemote(channels: channels)
        let spec = try S.spec("remote.manage")
        // The tool offers no way to ask for the bare address.
        XCTAssertTrue(spec.inputSchema["properties"]["openBrowser"].isNullish)
        XCTAssertFalse(spec.description.contains("openBrowser"))
        // Asking anyway is refused before the owner is asked, with the reason.
        let headless = V.object([.init("do", .string("open-web")), .init("openBrowser", .bool(false))])
        do {
            _ = try await tool.policy(spec, headless, S.context())
            XCTFail("openBrowser:false must be refused")
        } catch { XCTAssertEqual((error as? BackendDeckCoreSecurityRefusal)?.message, BackendDeckToolsMachinesRemote.openWebOnlyHere) }
        // Even straight to run, it opens this Mac's browser and answers only that it opened.
        let ran = try await tool.run("remote.manage", headless, S.context())
        XCTAssertEqual(ran.value, V.object([.init("opened", .bool(true))]))
        XCTAssertFalse(ran.value.compact.contains("pair=") || ran.summary.compact.contains("pair=") || ran.summary.compact.contains("urlIssued"))
        let calls = await channels.calls
        XCTAssertEqual(calls.filter { $0.channel == "link:system" }.map(\.args), [[.string(fixtureURL)]])
    }
}
