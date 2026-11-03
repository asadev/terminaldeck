import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class INT2TAGOwnerPresenceTests: XCTestCase {
    func testAttachReadsActualPresenceAndOnlyAttachedOwnerCanChangeIt() async throws {
        let active = BackendDeckCoreSecurityTestBox(false)
        let clock = BackendDeckCoreTestPortSecurityClock()
        let first = expectation(description: "inactive request")
        let asks = BackendDeckCoreSecurityTestBox(0)
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 45_000, clock: clock, ask: { _ in
            asks.edit { $0 += 1 }
            if asks.get() == 1 { first.fulfill() }
            return true
        })
        let window = BackendDeckCoreWindowConsent(isApprover: { $0.caller == .nativeApp && $0.ownerID == "owner" },
            send: { _, _, _ in true }, broadcast: { _, _ in }, ownerIsActive: { active.get() })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "owner")
        _ = try await window.attach(context: context, broker: broker)
        let batch = BackendTAGProfileConsentBatch(keyID: "key-A", keyName: "Commander", items: ["inspector"])
        let request = Task { await broker.request(tool: "tasks.agents", tier: .alter, summary: "Save", arguments: .object([]),
                                                  origin: "key:key-A", profileBatch: batch) }
        await fulfillment(of: [first], timeout: 1)
        let initial = await broker.list()
        XCTAssertEqual(initial.first?.profileBatch?.waitsWhileOwnerActive, false)
        do {
            try await window.noteOwnerActive(context: .init(caller: .nativeApp, ownerID: "forged"), broker: broker, active: true)
            XCTFail("A different window cannot declare the owner present")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        active.edit { $0 = true }
        _ = try await window.attach(context: context, broker: broker)
        let present = await broker.list()
        XCTAssertEqual(present.first?.profileBatch?.waitsWhileOwnerActive, true)
        XCTAssertEqual(clock.pending(), 0)
        let closed = await window.gone(ownerID: "owner", broker: broker)
        XCTAssertTrue(closed)
        let outcome = await request.value
        XCTAssertFalse(outcome.granted)
        await broker.stop()
    }
}
