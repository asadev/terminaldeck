import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane S2 (Machines): the source expectations of machine-tools.test.ts and
/// server-room-tools.test.ts that the existing Swift ports leave out. Every other
/// pending case already has an equivalent test (see macos/night/S2-Machines.md).
/// Fakes stand behind every channel; typing gaps go to a recording sleep, never a real one.
final class BackendDeckToolsS2MachinesTests: XCTestCase {
    typealias V = NativeRPCValue
    private let o = BackendDeckToolsMachinesPortObject

    // TSCASE machine-tools.test.ts:128 — the existing port checks the first row's link
    // fields; the source also pins the name and that the list is exactly this one machine.
    func testLookListsExactlyTheOneMachineByNameWithOnlyItsOwnSession() async throws {
        let area = BackendDeckToolsMachinesPortMachineArea(.init(["machines:list": BackendDeckToolsMachinesPortView()]))
        let out = try await area.run("machines.look", .object([]), BackendDeckToolsMachinesPortContext())
        XCTAssertEqual(out.value["thisComputer"], .string("Mac mini"))
        let machines = try XCTUnwrap(out.value["machines"].elements)
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines[0]["id"], .string("m1"))
        XCTAssertEqual(machines[0]["name"], .string("Office PC"))
        XCTAssertEqual(machines[0]["sessions"].elements?.count, 1)
        XCTAssertEqual(machines[0]["sessions"].elements?.first?["id"], .string("s-theirs"))
    }

    // TSCASE machine-tools.test.ts:173 — all four source escalations, including stop on
    // somebody else's session and start (which has no session yet).
    func testSessionIsActOnTheCopilotsOwnSessionAndAlterOnAnybodyElses() async throws {
        let ledger = BackendDeckToolsMachinesPortLedger()
        await ledger.note(BackendDeckToolsMachinesArea.startedKey("m1", "s-mine"))
        let area = BackendDeckToolsMachinesPortMachineArea(.init())
        let spec = try BackendDeckToolsMachinesPortSpec("machines.session"), context = BackendDeckToolsMachinesPortContext(ledger: ledger)
        let sendMine = try await area.policy(spec, o(["machineId": .string("m1"), "do": .string("send"), "sessionId": .string("s-mine"), "text": .string("go")]), context)
        let sendTheirs = try await area.policy(spec, o(["machineId": .string("m1"), "do": .string("send"), "sessionId": .string("s-theirs"), "text": .string("go")]), context)
        let stopTheirs = try await area.policy(spec, o(["machineId": .string("m1"), "do": .string("stop"), "sessionId": .string("s-theirs")]), context)
        let start = try await area.policy(spec, o(["machineId": .string("m1"), "do": .string("start")]), context)
        XCTAssertEqual(sendMine.tier, .act)
        XCTAssertEqual(sendTheirs.tier, .alter)
        XCTAssertEqual(stopTheirs.tier, .alter)
        XCTAssertEqual(start.tier, .act)
    }

    // TSCASE machine-tools.test.ts:230 — the whole result (value and summary) is
    // searched, as JSON.stringify(out) is: no credential, no issued private key in
    // either spelling, and not even the field names.
    func testPairingNeverHandsBackTheCredentialOrTheIssuedPrivateKey() async throws {
        let secret = Data("PRIVATE-KEY-BYTES".utf8).base64EncodedString()
        let pair = o(["ok": .bool(true), "offer": o(["hostId": .string("m1"), "name": .string("Office PC")]),
                      "credential": .string("BEARER-SECRET-123"), "deviceId": .string("d1"), "deviceName": .string("Mac mini"),
                      "guestKeys": o(["publicKey": .string(Data("PUB".utf8).base64EncodedString()), "secretKey": .string(secret)])])
        let area = BackendDeckToolsMachinesPortMachineArea(.init(["machines:list": BackendDeckToolsMachinesPortView(), "machines:pair": pair]))
        let out = try await area.run("machines.manage", o(["do": .string("pair"), "code": .string("123456")]), BackendDeckToolsMachinesPortContext())
        let seen = V.array([out.value, out.summary]).compact
        for banned in ["BEARER-SECRET-123", secret, "PRIVATE-KEY-BYTES", "secretKey", "credential"] {
            XCTAssertFalse(seen.contains(banned), "the pairing result carries \(banned)")
        }
        XCTAssertEqual(out.value["machineId"], .string("m1"))
    }

    // TSCASE server-room-tools.test.ts:109 — the line and its Enter are two writes to
    // the open terminal, with the real key gap handed to the injected sleep.
    func testServerShellTypesTheLineAndPressesReturnAsTwoWrites() async throws {
        let channels = BackendDeckCoreTestPortSessionsChannels(BackendDeckCoreTestPortSessionsMachineFixtureSupport.serverAnswers)
        let clock = BackendDeckToolsMachinesPortClockFake()
        let servers = BackendDeckToolsMachinesServers(channels: channels, shells: BackendDeckCoreTestPortSessionsShells(),
                                                      dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/home/me"),
                                                      sleep: { clock.sleep($0) })
        _ = try await servers.run("servers.shell", o(["do": .string("type"), "shellId": .string("s1 abc"), "text": .string("uptime")]),
                                  BackendDeckCoreTestPortSessionsDeviceFixtureSupport.context())
        let calls = await channels.calls
        let writes = calls.filter { $0.channel == "servers:shell:write" }.map(\.args)
        XCTAssertEqual(writes, [[.string("s1 abc"), .string("uptime")], [.string("s1 abc"), .string("\r")]])
        XCTAssertEqual(clock.sleepValues(), [BackendDeckToolsSessionsTyping.keyGapMilliseconds])
    }
}
