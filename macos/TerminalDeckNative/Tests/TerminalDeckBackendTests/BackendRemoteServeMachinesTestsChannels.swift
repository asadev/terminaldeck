import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendRemoteServeMachinesTestsChannels: XCTestCase {
    private typealias F = BackendRemoteServeMachinesTestsFixture
    private struct Rig {
        let directory: URL
        let registry: NativeChannelRegistry
        let store: BackendMachineStore
        let coordinator: BackendMachineCoordinator
        func invoke(_ channel: String, _ args: [NativeRPCValue] = []) async -> NativeRPCValue {
            do { return try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: args) }
            catch { return .object([.init("$thrown", .string(error.localizedDescription))]) }
            // A thrown marker is deliberately not a synthesized outcome. TS
            // expects actual null/false/refusal values, so a native throw fails.
        }
        func close() async { await coordinator.stop(); await registry.shutdown(); F.remove(directory) }
    }
    private func rig(blocked: String? = nil, localName: String = "Fixture Mac") async throws -> Rig {
        let directory = try F.scratch(), registry = NativeChannelRegistry(), store = BackendMachineStore(directory: directory)
        let coordinator = BackendMachineCoordinator(store: store, registry: registry, localName: localName, relayURL: "wss://relay.example.invalid",
            uploadAuthorize: { url, _ in url }, ownPorts: BackendDevOwnPorts(), pairingBlocked: { blocked })
        try await coordinator.open(connectSaved: false)
        _ = try await BackendMachineChannels.register(registry: registry, coordinator: coordinator, localHost: nil)
        return .init(directory: directory, registry: registry, store: store, coordinator: coordinator)
    }
    private func remember(_ rig: Rig) async throws -> String {
        try await rig.store.remember(name: "Studio PC", secrets: F.secrets(), platform: "darwin").id
    }
    func testEmptySavedRosterDialsNothing() async throws {
        let rig = try await rig(), view = await rig.invoke("machines:list")
        XCTAssertEqual(view["machines"].elements, []); XCTAssertEqual(view["links"].elements, []); await rig.close()
    }
    func testRegistersExactlyEverySourceMachineChannel() async throws {
        let rig = try await rig()
        let expected = ["machines:account:read", "machines:account:switch", "machines:attach", "machines:close", "machines:code", "machines:code:cancel",
            "machines:connect", "machines:controls:apply", "machines:controls:read", "machines:copilot:attach", "machines:copilot:refresh", "machines:copilot:say", "machines:copilot:start",
            "machines:create", "machines:detach", "machines:disconnect", "machines:drive-windows", "machines:forget", "machines:github:cancel", "machines:github:connect", "machines:github:disconnect", "machines:github:read",
            "machines:host:read", "machines:host:restart", "machines:host:stop", "machines:input", "machines:list", "machines:logins:read", "machines:logins:signin", "machines:logins:signout",
            "machines:open", "machines:pair", "machines:ports", "machines:reach", "machines:reach:close", "machines:rename", "machines:resize", "machines:send", "machines:session:rename",
            "machines:upload", "machines:upload:cancel", "machines:usage:read"]
        let actual = await rig.registry.channels(); XCTAssertEqual(actual, expected.sorted()); await rig.close()
    }
    func testCodeUnavailableWhenNoPublishingHostSupplied() async throws {
        let rig = try await rig(), outcome = await rig.invoke("machines:code")
        let view = try await rig.coordinator.view()
        XCTAssertEqual(outcome["ok"].bool, false); XCTAssertEqual(view["links"].elements, [])
        await rig.close()
    }
    func testBlockedReasonVisibleAndAvailableMachineHasNullReason() async throws {
        let offline = try await rig(blocked: "This machine is not connected to the relay."), blocked = await offline.invoke("machines:list")
        XCTAssertTrue(blocked["blocked"].string?.contains("relay") == true); await offline.close()
        let available = try await rig(), view = await available.invoke("machines:list")
        XCTAssertEqual(view["blocked"], .null); await available.close()
    }
    func testOwnMachineNameUsedInsteadOfStandIn() async throws {
        let name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: #"\.local$"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        let rig = try await rig(localName: name), view = await rig.invoke("machines:list")
        XCTAssertEqual(view["here"].string, name); XCTAssertNotEqual(view["here"].string, "A desktop"); await rig.close()
    }
    func testNonStringPairingInputReturnsBadCodeBeforeDial() async throws {
        let rig = try await rig(), outcome = await rig.invoke("machines:pair", [.number(42)])
        XCTAssertEqual(outcome["ok"].bool, false); XCTAssertEqual(outcome["reason"].string, "bad-code")
        let view = await rig.invoke("machines:list"); XCTAssertEqual(view["links"].elements, []); await rig.close()
    }
    func testBadTypedCodeStopsBeforeAnyDialAndReturnsBadCodeReason() async throws {
        let rig = try await rig(), outcome = await rig.invoke("machines:pair", [.string("nope")])
        XCTAssertEqual(outcome["ok"].bool, false); XCTAssertEqual(outcome["reason"].string, "bad-code")
        let view = await rig.invoke("machines:list"); XCTAssertEqual(view["machines"].elements, []); XCTAssertEqual(view["links"].elements, [])
        await rig.close()
    }
    func testRenameRepliesWithStoredMachineView() async throws {
        let rig = try await rig(), id = try await remember(rig)
        let result = await rig.invoke("machines:rename", [.string(id), .string("The loud one")])
        XCTAssertEqual(result["machines"].elements?.first?["name"].string, "The loud one"); await rig.close()
    }
    func testUnknownAndMalformedHostGitHubMachineReturnsNull() async throws {
        let rig = try await rig()
        for (channel, id) in [("machines:host:restart", NativeRPCValue.string("nobody")), ("machines:github:connect", .string("nobody")),
                              ("machines:host:read", .number(42)), ("machines:github:read", .number(42))] {
            let answer = await rig.invoke(channel, [id]); XCTAssertEqual(answer, .null)
        }
        await rig.close()
    }
    func testBrowserOffSwitchAcceptsOnlyLiteralBooleans() async throws {
        let rig = try await rig(), id = try await remember(rig)
        let before = await rig.invoke("machines:list"); XCTAssertEqual(before["machines"].elements?.first?["drivesWindows"].bool, true)
        let denied = await rig.invoke("machines:drive-windows", [.string(id), .bool(false)]); XCTAssertEqual(denied["machines"].elements?.first?["drivesWindows"].bool, false)
        let malformed = await rig.invoke("machines:drive-windows", [.string(id), .string("yes")]); XCTAssertEqual(malformed["machines"].elements?.first?["drivesWindows"].bool, false)
        let restored = await rig.invoke("machines:drive-windows", [.string(id), .bool(true)]); XCTAssertEqual(restored["machines"].elements?.first?["drivesWindows"].bool, true)
        let number = await rig.invoke("machines:drive-windows", [.string(id), .number(0)]); XCTAssertEqual(number["machines"].elements?.first?["drivesWindows"].bool, true)
        // Store restart durability is independently pinned in the store tests.
        await rig.close()
    }
    func testLegacyBrowserGrantIsOpenAtTheDispatcherStoreSeam() async throws {
        let rig = try await rig(), id = try await remember(rig)
        await rig.store.close()
        let saved = try F.readMachines(rig.directory), row = try XCTUnwrap(saved["machines"].elements?.first)
        try F.writeMachines(saved.setting("machines", .array([row.removing("drivesWindows")])), rig.directory)
        try await rig.store.open()
        let allowed = try await rig.store.drivesWindows(id), view = await rig.invoke("machines:list")
        XCTAssertTrue(allowed); XCTAssertEqual(view["machines"].elements?.first?["drivesWindows"].bool, true)
        _ = await rig.invoke("machines:drive-windows", [.string(id), .bool(false)])
        let denied = try await rig.store.drivesWindows(id); XCTAssertFalse(denied); await rig.close()
    }
    func testGrantWriteBroadcastsCurrentViewToOtherWindows() async throws {
        let rig = try await rig(), id = try await remember(rig), events = BackendRemoteServeMachinesTestsEvents()
        let subscription = try await rig.registry.subscribe("machines:state", ownerID: "observer") { event in await events.receive(event) }
        _ = await rig.invoke("machines:drive-windows", [.string(id), .bool(true)])
        let pushed = await events.values(); XCTAssertGreaterThan(pushed.count, 0)
        XCTAssertEqual(pushed.last?.arguments.first?["machines"].elements?.first?["drivesWindows"].bool, true)
        await subscription.cancelAndWait(); await rig.close()
    }
    func testMalformedReachRequestReturnsSourceSentence() async throws {
        let rig = try await rig()
        for args in [[NativeRPCValue.number(7), .number(3000)], [.string("machine"), .string("3000")], [.string("machine"), .missing]] {
            let answer = await rig.invoke("machines:reach", args)
            XCTAssertEqual(answer, .object([.init("ok", .bool(false)), .init("message", .string("That is not a machine and a port."))]))
        }
        await rig.close()
    }
    func testUnknownReachMachineReturnsSourceSentence() async throws {
        let rig = try await rig(), answer = await rig.invoke("machines:reach", [.string("no-such-machine"), .number(3000)])
        XCTAssertEqual(answer, .object([.init("ok", .bool(false)), .init("message", .string("This desktop is not connected to that machine."))]))
        await rig.close()
    }
    func testInvalidPortRefusedWithoutDialOrBind() async throws {
        let rig = try await rig()
        for port in [0.0, 70000, 1.5] {
            let answer = await rig.invoke("machines:reach", [.string("unknown-machine"), .number(port)])
            XCTAssertEqual(answer["ok"].bool, false)
        }
        let reach = BackendRemoteGuestReach(guest: F.guest(), ownPorts: BackendDevOwnPorts())
        for port in [0, 70000] {
            do { _ = try await reach.open(port: port); XCTFail("Invalid port was accepted") }
            catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        }
        await reach.stop()
        let view = await rig.invoke("machines:list"); XCTAssertEqual(view["links"].elements, []); await rig.close()
    }
    func testReachHandBackReturnsBooleanForAbsentListener() async throws {
        let rig = try await rig(), id = try await remember(rig)
        for machine in [id, "no-such-machine"] { let answer = await rig.invoke("machines:reach:close", [.string(machine), .number(5173)]); XCTAssertEqual(answer, .bool(true)) }
        await rig.close()
    }
    func testMalformedReachHandBackReturnsFalse() async throws {
        let rig = try await rig()
        for args in [[NativeRPCValue.number(7), .number(3000)], [.string("machine"), .string("3000")]] {
            let answer = await rig.invoke("machines:reach:close", args); XCTAssertEqual(answer, .bool(false))
        }
        await rig.close()
    }
    func testForgetBroadcastsNewEmptyRoster() async throws {
        let rig = try await rig(), id = try await remember(rig), events = BackendRemoteServeMachinesTestsEvents()
        let subscription = try await rig.registry.subscribe("machines:state", ownerID: "observer") { event in await events.receive(event) }
        _ = await rig.invoke("machines:forget", [.string(id)])
        let pushed = await events.values(); XCTAssertEqual(pushed.count, 1); XCTAssertEqual(pushed.first?.arguments.first?["machines"].elements, [])
        await subscription.cancelAndWait(); await rig.close()
    }
    func testRenameBroadcastsNewRosterName() async throws {
        let rig = try await rig(), id = try await remember(rig), events = BackendRemoteServeMachinesTestsEvents()
        let subscription = try await rig.registry.subscribe("machines:state", ownerID: "observer") { event in await events.receive(event) }
        _ = await rig.invoke("machines:rename", [.string(id), .string("the other one")])
        let pushed = await events.values(); XCTAssertEqual(pushed.count, 1); XCTAssertEqual(pushed.first?.arguments.first?["machines"].elements?.first?["name"].string, "the other one")
        await subscription.cancelAndWait(); await rig.close()
    }
}
