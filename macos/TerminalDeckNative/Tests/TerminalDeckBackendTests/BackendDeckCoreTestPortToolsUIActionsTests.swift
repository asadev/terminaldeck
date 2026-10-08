import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckCoreTestPortToolsSource {
    static func text(_ relative: String,file: StaticString = #filePath) throws -> String { var root = URL(fileURLWithPath:String(describing:file)); for _ in 0..<5 { root.deleteLastPathComponent() }; return try String(contentsOf:root.appendingPathComponent(relative),encoding:.utf8) }
    static func capture(_ source: String,pattern: String) throws -> [String] { let regex = try NSRegularExpression(pattern:pattern); return regex.matches(in:source,range:NSRange(source.startIndex...,in:source)).compactMap { match in Range(match.range(at:1),in:source).map { String(source[$0]) } } }
    static func uiCommands() throws -> Set<String> {
        let app = try text("src/renderer/App.tsx"),start = try XCTUnwrap(app.range(of:"const commands = useMemo<PaletteCommand[]>")),end = try XCTUnwrap(app.range(of:"window.deck.onMenuCommand",range:start.upperBound..<app.endIndex)),region = String(app[start.lowerBound..<end.lowerBound])
        XCTAssertGreaterThan(app.distance(from:app.startIndex,to:start.lowerBound),0)
        var found = Set(try capture(region,pattern:#"\bid: '([a-z][\w.]*)'"#)+capture(region,pattern:#"\bcase '([a-z][\w.]*)':"#))
        found.formUnion(try capture(text("src/main/menu.ts"),pattern:#"\bsend\('([a-z][\w.]*)'\)"#)); found.formUnion(try capture(text("src/renderer/keymap.ts"),pattern:#"\bid: '([a-z]+\.[\w.]+)'"#))
        if region.contains("`features.install.") { found.insert("features.install.*") }; return found
    }
}

@MainActor
final class BackendDeckCoreTestPortToolsUIActionsTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias Source = BackendDeckCoreTestPortToolsSource
    private var windowRows: [BackendDeckCoreCatalogueCoverageRow] { BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area == "window" } }
    private var commandRows: [BackendDeckCoreCatalogueCoverageRow] { windowRows.filter { !$0.action.contains(" ") } }
    private var devices: [BackendDeckCoreCatalogueCoverageRow] { BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area == "devices" } }
    private var fixed: [BackendDeckCoreCatalogueCoverageRow] { BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area == "fixed" } }
    private func ui(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppUI.definitions(service:fake,access:F.access(audit)) }
    // TSCASE ui-tools.test.ts:86
    func testUIL86CompatibilityGlobalMatchesSourceWindowBridge() throws { let source = try Source.text("src/renderer/driving/ui-bridge.ts"),actual = try XCTUnwrap(Source.capture(source,pattern:#"UI_GLOBAL\s*=\s*'([^']+)'"#).first); XCTAssertEqual(BackendDeckToolsAppUI.global,actual) }
    // TSCASE ui-tools.test.ts:90
    func testUIL90PaletteRoutesExactCommandAndReply() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(); await fake.set("uiPerform",try F.json(#"{"ok":true,"did":"ran view.files"}"#)); let value = try F.value(await F.call(ui(fake),"ui.do",#"{"action":"run","target":"view.files"}"#)),calls = await fake.calls(); XCTAssertEqual(value,try F.json(#"{"done":true,"did":"ran view.files"}"#)); XCTAssertEqual(calls[0]["args"],try F.json(#"["run","view.files"]"#)) }
    // TSCASE ui-tools.test.ts:101
    func testUIL101FocusAndSettingsExactDispatch() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(); await fake.set("uiPerform",try F.json(#"{"ok":true,"did":"shown"}"#)); let defs = try ui(fake); _ = try await F.call(defs,"ui.do",#"{"action":"focus","target":"s1"}"#); _ = try await F.call(defs,"ui.do",#"{"action":"settings","target":"copilot"}"#); let calls = await fake.calls(); XCTAssertEqual(calls.map { $0["args"] },try F.json(#"[["focus","s1"],["settings","copilot"]]"#).elements) }
    // TSCASE ui-tools.test.ts:110
    func testUIL110UnknownSessionAndSectionAreRefused() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try ui(fake); await fake.set("uiPerform",try F.json(#"{"ok":false,"why":"no session nope"}"#)); F.error(try await F.call(defs,"ui.do",#"{"action":"focus","target":"nope"}"#),contains:"no session nope"); await fake.set("uiPerform",try F.json(#"{"ok":false,"why":"no section secrets"}"#)); F.error(try await F.call(defs,"ui.do",#"{"action":"settings","target":"secrets"}"#),contains:"no section") }
    // TSCASE ui-tools.test.ts:117
    func testUIL117InjectionTargetStaysLiteralDataAndU2028Escaped() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(),sneaky = "x\"}); globalThis.pwned = true; ({\"a\":\""; await fake.set("uiPerform",try F.json(#"{"ok":false,"why":"no command"}"#)); let defs = try ui(fake),tool = try XCTUnwrap(defs.first { $0.spec.id == "ui.do" }); F.error(try await tool.handler(F.caller(),F.object([("action",.string("run")),("target",.string(sneaky))])),contains:"no command"); let calls = await fake.calls(); XCTAssertEqual(calls[0]["args"],.array([.string("run"),.string(sneaky)])); XCTAssertTrue(BackendDeckToolsAppUI.doCall(kind:"run",target:"\u{2028}").contains("\\u2028")); XCTAssertFalse(calls.contains { $0["operation"].string == "pwned" }) }
    // TSCASE ui-tools.test.ts:129
    func testUIL129UnpublishedNativeWindowIsSaid() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try ui(fake),list = try F.value(await F.call(defs,"ui.list")),done = try F.value(await F.call(defs,"ui.do",#"{"action":"run","target":"view.files"}"#)); XCTAssertEqual(list["window"],.null); XCTAssertEqual(done["done"],.bool(false)) }
    // TSCASE ui-tools.test.ts:136
    func testUIL136RefusedCommandsFilteredAndSessionsRetained() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(); await fake.set("uiList",try F.json(#"{"commands":[{"id":"view.files","title":"Files","group":"View","enabled":true},{"id":"session.new","title":"New session…","group":"Session","enabled":true}],"sessions":[{"id":"s1","title":"api"}]}"#)); let value = try F.value(await F.call(ui(fake),"ui.list")); XCTAssertEqual(value["commands"].elements?.map { $0["id"] },[.string("view.files")]); XCTAssertEqual(value["refused"]["session.new"],.string("sessions.start")); XCTAssertEqual(value["sessions"],try F.json(#"[{"id":"s1","title":"api"}]"#)) }
    // TSCASE ui-tools.test.ts:150
    func testUIL150DialogsRefusedBeforeAnyMove() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try ui(fake); F.error(try await F.call(defs,"ui.do",#"{"action":"run","target":"project.open"}"#),contains:"opens something"); F.error(try await F.call(defs,"ui.do",#"{"action":"run","target":"session.close"}"#),contains:"sessions.stop"); let calls = await fake.calls(); XCTAssertTrue(calls.isEmpty) }
    // TSCASE ui-tools.test.ts:158
    func testUIL158OnlyFeatureInstallEscalates() throws { XCTAssertEqual(BackendDeckToolsAppUI.effectiveTier(try F.json(#"{"action":"run","target":"features.install.split"}"#)),.alter); XCTAssertEqual(BackendDeckToolsAppUI.effectiveTier(try F.json(#"{"action":"run","target":"view.files"}"#)),.act) }
    // TSCASE ui-tools.test.ts:165
    func testUIL165RefusedCommandsAgreeWithCoverageTable() throws { for (id,instead) in BackendDeckToolsAppUI.refused { let row = try XCTUnwrap(commandRows.first { $0.action == id },id); if instead == .null { XCTAssertNotNil(row.skip,id) } else { XCTAssertTrue(row.tools?.contains(instead.string!) == true,id) } } }
    // TSCASE ui-tools.test.ts:181
    func testUIL181CommandsMappedToUIDoAreNotRefused() { for row in commandRows where row.tools?.contains("ui.do") == true { XCTAssertNil(BackendDeckToolsAppUI.refused[row.action],row.action) } }
    // TSCASE actions/actions.test.ts:21
    func testActionsL21BelievablePreloadInventory() throws { let actual = Set(try Source.capture(Source.text("src/preload/index.ts"),pattern:#"ipcRenderer\.(?:invoke|send)\('([^']+)'"#)); XCTAssertGreaterThan(actual.count,300) }
    // TSCASE actions/actions.test.ts:25
    func testActionsL25EveryChannelExactlyOneAreaAndNoStaleRow() throws { let actual = Set(try Source.capture(Source.text("src/preload/index.ts"),pattern:#"ipcRenderer\.(?:invoke|send)\('([^']+)'"#)),rows = BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area != "window" },listed = rows.map(\.action); XCTAssertEqual(actual.subtracting(listed),[]); XCTAssertEqual(Set(listed).subtracting(actual),[]); XCTAssertEqual(Set(listed).count,listed.count) }
    // TSCASE actions/actions.test.ts:36
    func testActionsL36EveryChannelDecided() { let rows = BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area != "window" }; XCTAssertTrue(rows.allSatisfy { $0.tools != nil || $0.skip != nil }) }
    // TSCASE actions/actions.test.ts:45
    func testActionsL45RealSkipSentencesAndDottedToolIDs() { for row in BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter({ $0.area != "window" }) { if let skip = row.skip { XCTAssertGreaterThanOrEqual(skip.trimmingCharacters(in:.whitespacesAndNewlines).utf16.count,20,row.action) } else { XCTAssertFalse(row.tools?.isEmpty != false,row.action); for id in row.tools ?? [] { XCTAssertNotNil(id.range(of:#"^[a-z]+(\.[a-zA-Z_]+)+$"#,options:.regularExpression),row.action+id) } } } }
    // TSCASE actions/devices.test.ts:41
    func testDeviceActionsL41ChannelsExactlyOnce() throws { let source = try Source.text("src/main/deck-control/actions/devices.ts"),start = try XCTUnwrap(source.range(of:"DEVICE_CHANNELS")),end = try XCTUnwrap(source.range(of:"]",range:start.upperBound..<source.endIndex)),region = String(source[start.upperBound..<end.lowerBound]),names = try Source.capture(region,pattern:#"'([^']+)'"#); XCTAssertEqual(devices.map(\.action).sorted(),names.sorted()); XCTAssertEqual(Set(names).count,names.count) }
    // TSCASE actions/devices.test.ts:46
    func testDeviceActionsL46JoinedIntoCoverageAreas() throws { let output = try BackendDeckCoreCatalogueCoverage.answer(.object([])).value; XCTAssertEqual(output["counts"]["devices"]["actions"].number,Double(devices.count)) }
    // TSCASE actions/devices.test.ts:50
    func testDeviceActionsL50NoOtherAreaOwnsThoseChannels() { let elsewhere = Set(BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area != "devices" }.map(\.action)); XCTAssertTrue(devices.allSatisfy { !elsewhere.contains($0.action) }) }
    // TSCASE actions/devices.test.ts:57
    func testDeviceActionsL57EveryChannelDecided() { XCTAssertTrue(devices.allSatisfy { $0.tools != nil || $0.skip != nil }) }
    private func deviceIDs() throws -> Set<String> { let environment = BackendDeckToolsMachinesEnvironmentAdapter(resolve:{ _ in throw NativeRPCError(code:"unexpected",message:"Factory metadata must not resolve a caller") },execute:{ _,_,_ in throw NativeRPCError(code:"unexpected",message:"Factory metadata must not run an operation") },failed:{ _,_,_,_,error in .failure(error.localizedDescription) }); return Set(try BackendDeckToolsMachinesDevices(service:BackendDeckToolsMachinesUnavailableDevices()).definitions(environment:environment).map { $0.spec.id }) }
    // TSCASE actions/devices.test.ts:61
    func testDeviceActionsL61OnlyRealDevicesToolIDs() throws { let ids = try deviceIDs(); for row in devices { for id in row.tools ?? [] where id.hasPrefix("devices.") { XCTAssertTrue(ids.contains(id),row.action+id) } } }
    // TSCASE actions/devices.test.ts:70
    func testDeviceActionsL70OtherIDsAreRealBuiltinAndBrowserVerbs() throws { let others = Set(try BackendDeckCoreCatalogueLiterals.builtins().map { $0.tool.id } + BrowserDriverVerb.allCases.map { $0.rawValue.replacingOccurrences(of:"_",with:".") }); for row in devices { for id in row.tools ?? [] where !id.hasPrefix("devices.") { XCTAssertTrue(others.contains(id),row.action+id) } } }
    // TSCASE actions/devices.test.ts:79
    func testDeviceActionsL79SkipSentencesAtLeastTwenty() { for row in devices { if let skip = row.skip { XCTAssertGreaterThanOrEqual(skip.trimmingCharacters(in:.whitespacesAndNewlines).utf16.count,20,row.action) } } }
    // TSCASE actions/devices.test.ts:87
    func testDeviceActionsL87OnlyTwoBookkeepingSkips() { XCTAssertEqual(devices.filter { $0.skip != nil }.map(\.action),["devices:watch","annotate:sent"]) }
    // TSCASE actions/devices.test.ts:97
    func testDeviceActionsL97AllDeviceToolsReachableExceptTwoNarrowReaders() throws { let reached = Set(devices.flatMap { $0.tools ?? [] }); XCTAssertEqual(try deviceIDs().subtracting(reached).sorted(),["devices.annotations","devices.find"]) }
    // TSCASE actions/fixed.test.ts:20
    func testFixedActionsL20ExactlyHandlerRegisteredChannels() throws { let actual = try Source.capture(Source.text("src/main/staysfixed/ipc.ts"),pattern:#"ipcMain\.handle\('([^']+)'"#); XCTAssertEqual(fixed.map(\.action).sorted(),actual.sorted()) }
    // TSCASE actions/fixed.test.ts:24
    func testFixedActionsL24EveryChannelNamesRealFixedTool() throws { let ids = Set(try BackendDeckToolsAppMetadata.entries().filter { $0.module == "fixed-tools" }.map { $0.spec.id }); for row in fixed { XCTAssertNil(row.skip,row.action); XCTAssertNotNil(row.tools,row.action); for id in row.tools ?? [] { XCTAssertTrue(ids.contains(id),row.action+id) } } }
    // TSCASE actions/fixed.test.ts:34
    func testFixedActionsL34JoinedIntoCoverageAreas() throws { let value = try BackendDeckCoreCatalogueCoverage.answer(.object([])).value; XCTAssertEqual(value["counts"]["fixed"]["actions"].number,Double(BackendStaysFixedChannels.channels.count + BackendSFXSetupChannels.channels.count)) }
    // TSCASE actions/ui.test.ts:53
    func testUIActionsL53BelievableSourceCommands() throws { XCTAssertGreaterThan(try Source.uiCommands().count,40) }
    // TSCASE actions/ui.test.ts:57
    func testUIActionsL57NoMissingOrStaleCommands() throws { let actual = try Source.uiCommands(),listed = Set(commandRows.map(\.action)); XCTAssertEqual(actual.subtracting(listed),[]); XCTAssertEqual(listed.subtracting(actual),[]) }
    // TSCASE actions/ui.test.ts:65
    func testUIActionsL65EveryCommandAndGestureDecidedWithValidReasonOrTools() { for row in windowRows { if let skip = row.skip { XCTAssertGreaterThanOrEqual(skip.trimmingCharacters(in:.whitespacesAndNewlines).utf16.count,20,row.action) } else { XCTAssertFalse(row.tools?.isEmpty != false,row.action); for id in row.tools ?? [] { XCTAssertNotNil(id.range(of:#"^[a-z]+(\.[a-zA-Z_]+)+$"#,options:.regularExpression),row.action+id) } } } }
}
