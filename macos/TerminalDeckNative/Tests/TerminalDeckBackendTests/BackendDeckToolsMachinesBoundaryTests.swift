import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDeckToolsMachinesFakeChannels: BackendDeckToolsMachinesChannels {
    private let answers: [String: NativeRPCValue]
    private(set) var calls: [String] = []
    init(_ answers: [String: NativeRPCValue]) { self.answers = answers }
    func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) throws -> NativeRPCValue {
        calls.append(channel)
        guard let answer = answers[channel] else { throw BackendDeckToolsSupport.unavailable(channel) }; return answer
    }
}
private struct BackendDeckToolsMachinesFakeShells: BackendDeckToolsMachinesServerShells {
    func openShells() -> [NativeRPCValue] { [.object([.init("shellId", .string("s1 shell")), .init("serverId", .string("s1")), .init("openedAt", .number(1))])] }
    func shellScreen(_ shellID: String) -> String? { "me@web-1:~$ " }
}
final class BackendDeckToolsMachinesBoundaryTests: XCTestCase {
    typealias V = NativeRPCValue
    private func o(_ fields: [String: V]) -> V { BackendDeckToolsMachinesShared.object(fields) }
    private func spec(_ id: String) throws -> BackendMCPTool {
        let row = try XCTUnwrap(BackendDeckToolsMachinesCatalogue.rows().first { $0["id"].string == id })
        return try .init(id: id, wireName: row["wire"].string!, description: row["description"].string!, inputSchema: row["inputSchema"], tier: BackendMCPTier(rawValue: row["tier"].string!)!)
    }
    private func context(own: Bool = false, kind: BackendDeckToolsMachinesContext.Kind = .local) -> BackendDeckToolsMachinesContext {
        .init(kind: kind, attended: true, rpc: .init(caller: .nativeApp, ownerID: "fixture"), startedByCopilot: { _ in own }, noteStarted: { _ in })
    }
    private func machines(_ channels: BackendDeckToolsMachinesFakeChannels) -> BackendDeckToolsMachinesArea {
        .init(channels: channels, stateWaiter: .init(registry: .init()), watch: .init(), dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"))
    }
    private var view: V { o(["here": .string("Mac mini"), "blocked": .null, "machines": .array([o(["id": .string("m1"), "name": .string("Office PC"), "platform": .string("linux"), "lastConnectedAt": .number(2)])]), "links": .array([o(["id": .string("m1"), "state": .string("online"), "reason": .null, "sessions": .array([]), "folders": .array([.string("/work")]), "ports": .array([]), "copilot": .null, "hostVersion": .string("0.15.0")])])]) }
    func testSessionOwnershipAndPermissionEscalationsMatchSource() async throws {
        let area = machines(.init([:])), tool = try spec("machines.session"), args = o(["machineId": .string("m1"), "sessionId": .string("s1"), "do": .string("send"), "text": .string("go")])
        let mine = try await area.policy(tool, args, context(own: true)), theirs = try await area.policy(tool, args, context())
        XCTAssertEqual(mine.tier, .act); XCTAssertEqual(theirs.tier, .alter)
        let permission = try await area.policy(tool, args.setting("do", .string("set")).removing("text").setting("control", .string("permission")).setting("value", .string("x")), context(own: true))
        XCTAssertEqual(permission.tier, .alter)
        let rename = try await area.policy(tool, args.setting("do", .string("rename")).removing("text").setting("title", .string("new")), context())
        XCTAssertEqual(rename.tier, .act)
    }
    func testMachineManageAlwaysNeedsOwnerAnswerAndPairingDropsSecrets() async throws {
        let channels = BackendDeckToolsMachinesFakeChannels(["machines:list": view, "machines:pair": o(["ok": .bool(true), "offer": o(["hostId": .string("m1"), "name": .string("Office PC")]), "credential": .string("BEARER-SECRET"), "guestKeys": o(["secretKey": .string("PRIVATE-SECRET")])])])
        let area = machines(channels), args = o(["do": .string("pair"), "code": .string("123456")])
        let policy = try await area.policy(spec("machines.manage"), args, context())
        XCTAssertTrue(policy.ownerMustAnswer)
        let out = try await area.run("machines.manage", args, context())
        XCTAssertEqual(out.value["machineId"], .string("m1")); XCTAssertFalse(out.value.compact.contains("BEARER")); XCTAssertFalse(out.value.compact.contains("PRIVATE")); XCTAssertFalse(out.summary.compact.contains("123456"))
    }
    func testMachineManageDoesNotAskRemoteCaller() async throws {
        do { _ = try await machines(.init([:])).policy(spec("machines.manage"), o(["do": .string("forget"), "machineId": .string("m1")]), context(kind: .remote)); XCTFail("remote machine manage admitted") } catch { XCTAssertTrue(error.localizedDescription.contains("A paired device cannot")) }
    }
    func testCodeReturnedOnlyToCallerNeverLogSummary() async throws {
        let area = machines(.init(["machines:code": o(["ok": .bool(true), "code": o(["token": .string("424242"), "expiresAt": .number(99)])])]))
        let out = try await area.run("machines.manage", o(["do": .string("show-code")]), context())
        XCTAssertEqual(out.value["code"], .string("424242")); XCTAssertFalse(out.summary.compact.contains("424242"))
    }
    func testShellShowsWholeCommandAndRejectsTooLongAndMultiline() async throws {
        let server = BackendDeckToolsMachinesServers(channels: BackendDeckToolsMachinesFakeChannels([:]), shells: BackendDeckToolsMachinesFakeShells(), dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"))
        let tool = try spec("servers.shell"), line = "sudo systemctl restart nginx && journalctl -u nginx -n 50", args = o(["do": .string("type"), "shellId": .string("s1 shell"), "text": .string(line)])
        let policy = try await server.policy(tool, args, context()); XCTAssertEqual(policy.tier, .alter); XCTAssertTrue(policy.sentence.contains(line))
        for text in [String(repeating: "x", count: 1_001), "ls\nrm -rf /"] { do { _ = try await server.policy(tool, args.setting("text", .string(text)), context()); XCTFail("unsafe shell input admitted") } catch {} }
    }
    func testRemoteDeviceRowsDoNotDescribeOwnersAsHavingNoFolders() {
        let mine = o(["id": .string("mine"), "name": .string("iPhone"), "status": .string("approved")]), guest = o(["id": .string("guest"), "name": .string("Guest"), "status": .string("pending")])
        let rows = BackendDeckToolsMachinesRemote.rows(devices: [mine, guest], kinds: [o(["deviceId": .string("mine"), "kind": .string("mine")]), o(["deviceId": .string("guest"), "kind": .string("guest")])], folders: [], accounts: [], sessions: [], windows: ["mine"], connected: ["mine"])
        XCTAssertEqual(rows[0]["folders"], .missing); XCTAssertEqual(rows[1]["folders"], .array([])); XCTAssertEqual(rows[0]["drivesWindows"], .bool(true)); XCTAssertEqual(rows[1]["connected"], .bool(false))
    }
    func testAnnotationsPreserveOneRoundNoteAndBrowserSelector() {
        let round = o(["id": .string("r1"), "createdAt": .number(0), "where": o(["kind": .string("browser"), "url": .string("https://shop.example/cart")]), "note": .string("make #1 green\nkeep #2"), "annotations": .array([o(["n": .number(1), "element": o(["role": .string("button"), "name": .string("Pay"), "selector": .string("#pay")]), "rect": o(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])])])])
        let out = BackendDeckToolsMachinesAnnotationRules.round(round)
        XCTAssertEqual(out["note"], .string("make #1 green keep #2")); XCTAssertEqual(out["sentTo"], .null)
        XCTAssertTrue(out["markers"].elements?.first?["described"].string?.contains("selector #pay") == true)
        XCTAssertEqual(out["markers"].elements?.first?["note"], .missing)
    }
}
