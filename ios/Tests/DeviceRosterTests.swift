/**
 * The device roster: the three sentences a row is drawn from, and the link that
 * lists, revokes, and hears the unsolicited change.
 *
 * A port of the pure half of `pwa/src/devices.ts` and the client behaviour. The
 * roster is offered only to one of the owner's own devices, so a client that
 * sees the capability may manage it; there is no approve — revoke doubles as
 * deny.
 */

import XCTest
@testable import TerminalDeck

final class DeviceRosterTests: XCTestCase {

    private func row(_ id: String, kind: DeviceRosterRow.Kind = .mine,
                     status: DeviceRosterRow.Status = .approved, connected: Bool = false,
                     lastSeen: Double? = nil, fingerprint: String? = "AA BB CC") -> DeviceRosterRow {
        DeviceRosterRow(id: id, name: "Device \(id)", kind: kind, status: status,
                        addedAt: 1000, lastSeenAt: lastSeen, connected: connected, fingerprint: fingerprint)
    }

    func testStandingLeadsWithTheWaitForAPendingDevice() {
        XCTAssertEqual(DeviceRosterText.standing(row("d", status: .pending)), "Waiting to be approved")
        XCTAssertEqual(DeviceRosterText.standing(row("d", kind: .mine)), "Your device")
        XCTAssertEqual(DeviceRosterText.standing(row("d", kind: .guest)), "Guest")
    }

    func testLastSeenPrefersConnectedNowAndNamesNever() {
        XCTAssertEqual(DeviceRosterText.lastSeen(row("d", connected: true)), "Connected now")
        XCTAssertEqual(DeviceRosterText.lastSeen(row("d", lastSeen: nil)), "Never connected")
        let now = Date(timeIntervalSince1970: 10_000)
        // 90 minutes ago → "Seen 1h ago".
        let seen = row("d", lastSeen: (10_000 - 90 * 60) * 1000)
        XCTAssertEqual(DeviceRosterText.lastSeen(seen, now: now), "Seen 1h ago")
    }

    func testFingerprintFallsBackToASentence() {
        XCTAssertEqual(DeviceRosterText.fingerprint(row("d", fingerprint: nil)),
                       "No key — paired before this host kept them")
        XCTAssertEqual(DeviceRosterText.fingerprint(row("d", fingerprint: "AA BB CC")), "AA BB CC")
    }

    @MainActor
    func testNothingIsAskedOfAMachineThatDidNotOfferTheRoster() {
        let wire = TapWire()
        let link = DeviceRosterLink(wire: wire)
        link.welcomed(capabilities: [])
        link.ensureRead()
        XCTAssertTrue(wire.sent.isEmpty)

        link.welcomed(capabilities: [WireCapability.devices])
        link.ensureRead()
        guard case .devicesList = wire.sent.first else { return XCTFail("expected a devices.list") }
    }

    @MainActor
    func testARevokeMarksTheDeviceBusyThenSettlesOnTheNewRoster() {
        let wire = TapWire()
        let link = DeviceRosterLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.devices])
        link.ensureRead()
        guard case let .devicesList(listRid) = wire.sent.first else { return XCTFail() }
        _ = link.receive(.devicesRows(rid: listRid, devices: [row("d1"), row("d2", kind: .guest)]))
        XCTAssertEqual(link.rows?.count, 2)

        link.revoke("d2")
        XCTAssertEqual(link.busy, "d2")
        guard case let .devicesRevoke(revokeRid, device) = wire.sent.last else { return XCTFail() }
        XCTAssertEqual(device, "d2")
        _ = link.receive(.devicesRevoked(rid: revokeRid, ok: true, message: "Removed.", devices: [row("d1")]))
        XCTAssertNil(link.busy)
        XCTAssertEqual(link.rows?.map(\.id), ["d1"])
    }

    @MainActor
    func testAChangedPushKeepsTheRosterFresh() {
        let wire = TapWire()
        let link = DeviceRosterLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.devices])
        link.ensureRead()
        guard case let .devicesList(listRid) = wire.sent.first else { return XCTFail() }
        _ = link.receive(.devicesRows(rid: listRid, devices: [row("d1")]))
        // A device joined — pushed without a request.
        _ = link.receive(.devicesChanged(devices: [row("d1"), row("d2", status: .pending)]))
        XCTAssertEqual(link.rows?.count, 2)
    }
}

@MainActor
private final class TapWire: CopilotWire {
    var sent: [ClientMessage] = []
    @discardableResult
    func send(_ message: ClientMessage) -> Bool { sent.append(message); return true }
}
