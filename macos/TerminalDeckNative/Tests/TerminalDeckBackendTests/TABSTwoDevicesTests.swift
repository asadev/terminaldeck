import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// TABS (#58): a session can show TWO devices at once (iOS + Android, or two of a kind), each by its own slot.
// Runs with TD_WIP=TABS.

private actor TABSSessions {
    var generations = ["s1": "first", "s2": "second"]
    func resolve(_ id: String) throws -> BackendUIGSessionSimulatorIdentity {
        guard let generation = generations[id] else { throw NativeRPCError(code: "not-permitted", message: "Session exited") }
        return .init(sessionID: id, incarnation: generation)
    }
    func replace(_ id: String) { generations[id] = UUID().uuidString }
}

final class TABSTwoDevicesTests: XCTestCase, @unchecked Sendable {
    private let ios = "ios:AAAA-1111", android = "android:R58M123"
    private func rig() throws -> (BackendUIGSessionSimulatorAttachments, BackendDeckToolsMachinesPortDevices, TABSSessions) {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_WIP"]?.contains("TABS") == true, "WIP TABS")
        let sessions = TABSSessions()
        return (BackendUIGSessionSimulatorAttachments(resolveLocalSession: { try await sessions.resolve($0) }), BackendDeckToolsMachinesPortDevices(), sessions)
    }
    private func call(_ tool: String, _ args: NativeRPCValue, attachments: BackendUIGSessionSimulatorAttachments,
                      service: BackendDeckToolsMachinesPortDevices, session: String = "s1") async throws -> BackendMCPToolReply {
        let environment = BackendDeckToolsMachinesPortEnvironment(BackendDeckToolsMachinesPortContext(.session, session: session))
        let definitions = try BackendUIGSessionSimulatorMCP(service: service, attachments: attachments).definitions(environment: environment)
        return try await XCTUnwrap(definitions.first { $0.spec.id == tool }).handler(BackendDeckToolsMachinesPortNativeContext(), args)
    }

    func testTwoSlotsHoldTwoDevicesAndNeverMoreOrTheSameTwice() async throws {
        let (attachments, service, _) = try rig()
        let first = try await attachments.attach(sessionID: "s1", deviceID: ios, slot: 0, service: service)
        let second = try await attachments.attach(sessionID: "s1", deviceID: android, slot: 1, service: service)
        XCTAssertEqual(first.slot, 0); XCTAssertEqual(second.slot, 1)
        let held = try await attachments.attached(sessionID: "s1")
        XCTAssertEqual(held.compactMap(\.deviceID), [ios, android])
        // The same device cannot fill both places; a third place does not exist.
        do { _ = try await attachments.attach(sessionID: "s1", deviceID: ios, slot: 1, service: service); XCTFail("same device twice") } catch {}
        do { _ = try await attachments.snapshot(sessionID: "s1", slot: 2); XCTFail("third place") } catch {}
        // Each place validates on its own; detaching one leaves the other.
        try await attachments.validate(first); try await attachments.validate(second)
        _ = try await attachments.detach(sessionID: "s1", slot: 1, expected: second)
        let after = try await attachments.attached(sessionID: "s1"); XCTAssertEqual(after.compactMap(\.deviceID), [ios])
        try await attachments.validate(first)
        do { try await attachments.validate(second); XCTFail("detached ticket") } catch {}
    }

    func testReplacedSessionInvalidatesBothPlaces() async throws {
        let (attachments, service, sessions) = try rig()
        let a = try await attachments.attach(sessionID: "s1", deviceID: ios, slot: 0, service: service)
        let b = try await attachments.attach(sessionID: "s1", deviceID: android, slot: 1, service: service)
        await sessions.replace("s1")
        do { try await attachments.validate(a); XCTFail("stale first") } catch {}
        do { try await attachments.validate(b); XCTFail("stale second") } catch {}
        let fresh = try await attachments.attached(sessionID: "s1"); XCTAssertTrue(fresh.isEmpty)
    }

    func testTheSessionsAgentSeesBothDevicesAndDrivesEachByIdOrName() async throws {
        let (attachments, service, _) = try rig()
        _ = try await attachments.attach(sessionID: "s1", deviceID: ios, slot: 0, service: service)
        _ = try await attachments.attach(sessionID: "s1", deviceID: android, slot: 1, service: service)
        let listed = try await call("devices.list", .object([]), attachments: attachments, service: service)
        XCTAssertEqual(Set(listed.structuredContent?["devices"].elements?.filter { $0["inThisPanel"].bool == true }.compactMap { $0["id"].string } ?? []), [ios, android])
        let attached = try await call("devices.attached", .object([]), attachments: attachments, service: service)
        XCTAssertEqual(attached.structuredContent?["devices"].elements?.count, 2)
        await service.clear()
        // By id, and by name (case-insensitive).
        let byId = try await call("devices.tap", BackendDeckToolsMachinesPortObject(["deviceId": .string(android), "x": .number(0.5), "y": .number(0.5)]), attachments: attachments, service: service)
        let byName = try await call("devices.tap", BackendDeckToolsMachinesPortObject(["deviceId": .string("iphone 17 pro"), "x": .number(0.5), "y": .number(0.5)]), attachments: attachments, service: service)
        XCTAssertFalse(byId.isError, "\(byId)"); XCTAssertFalse(byName.isError, "\(byName)")
        let seen = await service.names(); XCTAssertEqual(seen.filter { $0 == "tap" }.count, 2)
        // A device that is not attached is refused, and another session sees none.
        let stranger = try await call("devices.tap", BackendDeckToolsMachinesPortObject(["deviceId": .string("avd:Pixel_9"), "x": .number(0.5), "y": .number(0.5)]), attachments: attachments, service: service)
        XCTAssertTrue(stranger.isError)
        let other = try await call("devices.list", .object([]), attachments: attachments, service: service, session: "s2")
        XCTAssertEqual(other.structuredContent?["devices"].elements?.filter { $0["inThisPanel"].bool == true }.count, 0)
    }
}
