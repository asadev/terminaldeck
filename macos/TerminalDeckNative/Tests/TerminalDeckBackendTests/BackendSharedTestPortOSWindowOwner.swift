import XCTest
@testable import TerminalDeckBackend

/// Pure routing only. The caller still owes full session+machine binding lookup
/// and both holder-desk subscriptions; no native integration is invented here.
final class BackendSharedTestPortOSWindowOwner: XCTestCase {
    func testUnspawnedSessionRoutesToDeviceHoldingItsWindow() async {
        let owners = BackendOSWindowOwners()
        let absent = await owners.owner(of: "sess-1"); XCTAssertNil(absent)
        let route = await owners.route(sessionID: "sess-1", attachedHere: false, deviceHolders: ["mac"])
        XCTAssertEqual(route, .peer(.init(kind: .device, id: "mac")))
    }
    func testUnspawnedSessionRoutesToOutboundMachineHolder() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "sess-1", attachedHere: false, deviceHolders: [], machineHolders: ["office-pc"])
        XCTAssertEqual(route, .peer(.init(kind: .machine, id: "office-pc")))
    }
    func testAbsentMachineDeskMeansNoMachineHolder() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "sess-1", attachedHere: false, deviceHolders: [])
        XCTAssertEqual(route, .here)
    }
    func testSpawnedGuestNeverFallsBackToLocalWindow() async {
        let owners = BackendOSWindowOwners(); await owners.note(sessionID: "guest-session", deviceID: "phone-1")
        let route = await owners.route(sessionID: "guest-session", attachedHere: true, deviceHolders: ["mac"])
        XCTAssertEqual(route, .peer(.init(kind: .device, id: "phone-1")))
    }
    func testSpawnedGuestNeverFallsBackToOutboundMachine() async {
        let owners = BackendOSWindowOwners(); await owners.note(sessionID: "guest-session", deviceID: "phone-1")
        let route = await owners.route(sessionID: "guest-session", attachedHere: false, deviceHolders: [], machineHolders: ["office-pc"])
        XCTAssertEqual(route, .peer(.init(kind: .device, id: "phone-1")))
    }
    func testLocalWindowWinsOverOtherClaimsForLocalSession() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "sess-1", attachedHere: true, deviceHolders: ["mac"])
        XCTAssertEqual(route, .here)
    }
    func testNoAttachedWindowUsesLocalRefusalPath() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "sess-1", attachedHere: false, deviceHolders: [])
        XCTAssertEqual(route, .here)
    }
    func testTwoDeviceHoldersAreAmbiguousInOriginalOrder() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "sess-1", attachedHere: false, deviceHolders: ["mac", "laptop"])
        XCTAssertEqual(route, .ambiguous([.init(kind: .device, id: "mac"), .init(kind: .device, id: "laptop")]))
    }
    func testDeviceAndMachineClaimsKeepBothIDSpaces() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "sess-1", attachedHere: false, deviceHolders: ["mac"], machineHolders: ["office-pc"])
        XCTAssertEqual(route, .ambiguous([.init(kind: .device, id: "mac"), .init(kind: .machine, id: "office-pc")]))
    }
    func testEmptySessionNeverRoutesOnAnUnknownClaim() async {
        let owners = BackendOSWindowOwners()
        let route = await owners.route(sessionID: "", attachedHere: false, deviceHolders: ["mac"])
        XCTAssertEqual(route, .here)
    }
    func testOwnershipEmptyIDsAndForgetSupplement() async {
        let owners = BackendOSWindowOwners()
        await owners.note(sessionID: "", deviceID: "phone"); await owners.note(sessionID: "session", deviceID: "")
        let absent = await owners.owner(of: "session"); XCTAssertNil(absent)
        await owners.note(sessionID: "session", deviceID: "phone")
        let known = await owners.owner(of: "session"); XCTAssertEqual(known, "phone")
        await owners.forget("session")
        let forgotten = await owners.owner(of: "session"); XCTAssertNil(forgotten)
    }
}
