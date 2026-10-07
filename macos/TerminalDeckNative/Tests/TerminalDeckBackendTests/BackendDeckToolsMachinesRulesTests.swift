import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsMachinesRulesTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias R = BackendDeckToolsMachinesDeviceRules
    private func object(_ fields: [String: V]) -> V { BackendDeckToolsMachinesShared.object(fields) }
    private func context(_ kind: BackendDeckToolsMachinesContext.Kind = .local, attended: Bool = true,
                         session: String? = nil, machine: String = "", key: String? = nil, folders: [String]? = nil) -> BackendDeckToolsMachinesContext {
        .init(kind: kind, attended: attended, sessionID: session, machineID: machine, keyID: key, folders: folders,
              rpc: .init(caller: .nativeApp, ownerID: "fixture"), startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    private func node(_ name: String, id: String = "", x: Double = 0.1, y: Double = 0.2) -> DeviceNode {
        DeviceNode(ref: id, role: "AXButton", label: name, identifier: id, frame: .init(x: x, y: y, width: 0.2, height: 0.1))
    }
    func testCatalogueContainsExact25IDsAndWireNames() throws {
        let rows = try BackendDeckToolsMachinesCatalogue.rows()
        XCTAssertEqual(rows.count, 25)
        XCTAssertEqual(Set(rows.compactMap { $0["id"].string }).count, 25)
        for row in rows { XCTAssertEqual(row["wire"].string, row["id"].string?.replacingOccurrences(of: ".", with: "_")); XCTAssertEqual(row["inputSchema"]["additionalProperties"], .bool(false)) }
        XCTAssertEqual(rows.first { $0["id"].string == "servers.shell" }?["tier"], .string("alter"))
        XCTAssertFalse(rows.contains { ["browser.lift", "browser.inject"].contains($0["id"].string ?? "") })
    }
    func testCoordinatesRefusePixelsAndHalfPositionsBeforeInput() throws {
        XCTAssertThrowsError(try R.tapTarget(object(["x": .number(540), "y": .number(0.5)]))) { XCTAssertTrue($0.localizedDescription.contains("looks like pixels")) }
        XCTAssertThrowsError(try R.tapTarget(object(["x": .number(0.5)])))
        XCTAssertThrowsError(try R.tapTarget(object(["x": .number(0.5), "y": .number(0.5), "name": .string("Pay")])))
        XCTAssertThrowsError(try R.point("from", object(["x": .number(0.5), "y": .number(0.5), "z": .number(1)])))
    }
    func testDeviceIDsRejectShellSyntaxAndOverlongIDs() {
        for id in ["iPhone; rm -rf ~", "ios:", "ios:" + String(repeating: "x", count: 121), "windows:device"] { XCTAssertThrowsError(try R.id(object(["deviceId": .string(id)]))) }
        XCTAssertNoThrow(try R.id(object(["deviceId": .string("android:emulator-5554")])))
    }
    func testTapDeduplicatesButtonAndItsTextButRefusesDistinctPlaces() throws {
        var button = node("Pay", id: "pay"); button.children = [DeviceNode(ref: "label", role: "AXStaticText", label: "Pay", frame: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.1))]
        let query = try XCTUnwrap(R.selector(object(["name": .string("pay")])))
        XCTAssertEqual(try R.resolveOne(button, query).identifier, "pay")
        let root = DeviceNode(ref: "root", role: "AXApplication", children: [button, node("Pay", id: "other", y: 0.8)])
        XCTAssertThrowsError(try R.resolveOne(root, query)) { XCTAssertTrue($0.localizedDescription.contains("2 different elements")) }
    }
    func testHiddenParentsAndOffScreenCentresNeverProduceTapTargets() throws {
        var hidden = DeviceNode(ref: "sheet", role: "AXGroup", hidden: true, children: [node("Secret", id: "secret")])
        let query = try XCTUnwrap(R.selector(object(["name": .string("Secret")])))
        XCTAssertEqual(R.find(hidden, query).count, 0)
        XCTAssertThrowsError(try R.resolveOne(hidden, query)) { XCTAssertTrue($0.localizedDescription.contains("hidden or scrolled away")) }
        hidden.hidden = false; hidden.children[0].frame = .init(x: 0.1, y: 2, width: 0.2, height: 0.1)
        XCTAssertNil(R.element(hidden.children[0])["centre"].fields)
        XCTAssertEqual(R.element(hidden.children[0])["offScreen"], .bool(true))
    }
    func testPasswordValuesAndSnapshotRefsNeverLeaveElementView() {
        var password = DeviceNode(ref: "ephemeral", role: "AXTextField", label: "PIN", value: "4821")
        password.valueRedacted = true
        let value = R.element(password)
        XCTAssertEqual(value["secret"], .bool(true)); XCTAssertEqual(value["value"], .missing); XCTAssertEqual(value["ref"], .missing)
        XCTAssertFalse(value.compact.contains("4821"))
    }
    func testTreeSkipsScaffoldingAndLimitsRowsWhileCountingAll() {
        let root = DeviceNode(ref: "root", role: "AXApplication", children: (0..<500).map { node("Row \($0)", id: "row-\($0)") })
        let answer = R.listElements(root, limit: 150)
        XCTAssertEqual(answer.rows.count, 150); XCTAssertEqual(answer.total, 500)
        XCTAssertEqual(answer.rows[0]["depth"], .number(0))
    }
    func testSwipeBoundsAndDirectionsKeepAwayFromSystemEdges() throws {
        let up = try R.swipe(object(["direction": .string("up"), "durationMs": .number(10)]))
        XCTAssertEqual(up.from["y"], .number(0.75)); XCTAssertEqual(up.to["y"], .number(0.25)); XCTAssertEqual(up.duration, 50)
        XCTAssertEqual(try R.hold(object(["holdMs": .number(60_000)])), 5_000)
        XCTAssertThrowsError(try R.swipe(object(["direction": .string("up"), "from": object(["x": .number(0), "y": .number(0)])])))
    }
    func testTypedTextLimitUsesUTF16AndModifiersNeedAKey() {
        XCTAssertThrowsError(try R.typing(object(["text": .string(String(repeating: "😀", count: 1_001))])))
        XCTAssertThrowsError(try R.typing(object(["text": .string("hi"), "modifiers": .array([.string("command")])])))
        XCTAssertNoThrow(try R.typing(object(["text": .string("hi"), "key": .string("return")])))
    }
    func testFileUploadNeverLeavesCredentialOrAppDataFolders() {
        let home = URL(fileURLWithPath: "/fixture/home"), data = URL(fileURLWithPath: "/fixture/data")
        for path in ["relative.txt", "/fixture/home/.ssh/id_ed25519", "/fixture/home/.aws/credentials", "/fixture/data/machines.json", "/fixture/home/Documents/../../home/.config/gh/hosts.yml"] { XCTAssertThrowsError(try BackendDeckToolsMachinesShared.sendable(path, dataRoot: data, home: home)) }
        XCTAssertNoThrow(try BackendDeckToolsMachinesShared.sendable("/fixture/home/Documents/report.txt", dataRoot: data, home: home))
    }
    func testRemoteStartFailsClosedAndKeySubfoldersDoNotCoverNeighbor() async throws {
        do { _ = try await BackendDeckToolsMachinesRemoteStart.requireDeviceFolder(nil, deviceID: "phone", folder: "/private/secret"); XCTFail("missing grants were accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("not available")); XCTAssertFalse(error.localizedDescription.contains("/private/secret")) }
        let key = context(.key, key: "app", folders: ["/work/project"])
        XCTAssertEqual(try BackendDeckToolsMachinesRemoteStart.requireKeyFolder(key, folder: "/work/project/packages/web"), "/work/project/packages/web")
        XCTAssertThrowsError(try BackendDeckToolsMachinesRemoteStart.requireKeyFolder(key, folder: "/work/project-other"))
        XCTAssertFalse(BackendDeckToolsMachinesRemoteStart.sameFolder("/Work", "/work"))
        XCTAssertTrue(BackendDeckToolsMachinesRemoteStart.sameFolder("/work/", "/work"))
    }
    func testWorkersRefuseRemoteAndUnattendedAndKeepOwnHoldersDistinct() {
        XCTAssertThrowsError(try BackendDeckToolsMachinesWorkers.mayUse(context(.remote), tool: "browser.worker"))
        XCTAssertThrowsError(try BackendDeckToolsMachinesWorkers.mayUse(context(.session, attended: false, session: "s1"), tool: "browser.worker")) { XCTAssertTrue($0.localizedDescription.contains("Do not retry")) }
        XCTAssertEqual(context(.session, session: "s1").holder, "session::s1")
        XCTAssertEqual(context(.key, key: "app").holder, "key:app")
        XCTAssertTrue(BackendDeckToolsMachinesWorkers.noWindow(context(), one: false).contains("Hoot’s tab is not one"))
    }
    private func message(_ id: String, _ role: String, _ text: String) -> V { object(["id": .string(id), "role": .string(role), "text": .string(text), "at": .number(0)]) }
    func testReplyNeedsNewQuestionAndNewAgentAnswer() {
        let old = [message("1", "you", "old"), message("2", "agent", "old answer")]
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter(old, since: "2"))
        XCTAssertTrue(BackendDeckToolsMachinesWatch.answeredAfter(old + [message("3", "you", "new"), message("4", "agent", "answer")], since: "2"))
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter([message("3", "you", "new"), message("4", "agent", " ")], since: nil))
    }
    func testConversationResetAndLateRunFramesAreBounded() async {
        let watch = BackendDeckToolsMachinesWatch()
        await watch.pushed("machines:copilot:chat", object(["machineId": .string("m1"), "chat": object(["run": .string("new"), "reset": .bool(true), "messages": .array([message("1", "you", "new question")])])]))
        await watch.pushed("machines:copilot:chat", object(["machineId": .string("m1"), "chat": object(["run": .string("old"), "messages": .array([message("9", "agent", "late wrong reply")])])]))
        var conversation = await watch.conversation("m1"); XCTAssertEqual(conversation["messages"].elements?.count, 1)
        await watch.pushed("machines:copilot:chat", object(["machineId": .string("m1"), "chat": object(["run": .string("new"), "messages": .array((0..<300).map { message("n\($0)", "agent", "row \($0)") })])]))
        conversation = await watch.conversation("m1"); XCTAssertEqual(conversation["messages"].elements?.count, 200)
        await watch.dispose()
    }
    func testScreenAttachResetsReplayAndDetachMarksStale() async {
        let watch = BackendDeckToolsMachinesWatch(maximumScreens: 2)
        let attach: [V] = [.string("m1"), .string("s1"), .number(40), .number(5)]
        await watch.invoked("machines:attach", attach)
        let frame = object(["machineId": .string("m1"), "sessionId": .string("s1"), "data": .string("first line")])
        await watch.pushed("machines:output", frame)
        await watch.invoked("machines:attach", attach)
        await watch.pushed("machines:output", frame)
        await watch.invoked("machines:detach", [.string("m1"), .string("s1")])
        let screen = await watch.screen("m1", "s1")
        XCTAssertEqual(screen["cols"], .number(40)); XCTAssertEqual(screen["live"], .bool(false))
        XCTAssertEqual((screen["text"].string ?? "").components(separatedBy: "first line").count - 1, 1)
        await watch.dispose()
    }
}
