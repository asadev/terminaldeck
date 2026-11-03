import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortSessionsDevicesTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport
    typealias F = BackendDeckCoreTestPortSessionsDeviceFixture
    private var ios: String { S.ios }
    private func args(_ fields: [(String, V)] = []) -> V { S.o([("deviceId", .string(ios))] + fields) }
    private func call(_ id: String, _ arguments: V, _ fixture: F, context: BackendDeckToolsMachinesContext = S.context()) async throws -> BackendDeckCoreSecurityCallResult { try await S.call(id, args: arguments, fixture: fixture, context: context) }
    private func assertSubset(_ expected: V, _ actual: V, file: StaticString = #filePath, line: UInt = #line) {
        if let fields = expected.fields { for field in fields { assertSubset(field.value, actual[field.key], file: file, line: line) } }
        else if let array = expected.elements { XCTAssertEqual(actual.elements?.count, array.count, file: file, line: line); for (index, entry) in array.enumerated() { if let actual = actual.elements, index < actual.count { assertSubset(entry, actual[index], file: file, line: line) } } }
        else { XCTAssertEqual(expected, actual, file: file, line: line) }
    }
    func testExactElevenToolsTiersWiresIndexesDescriptionsAndNoBuiltinCollision() throws {
        let rows = try BackendDeckToolsMachinesCatalogue.rows().filter { ($0["id"].string ?? "").hasPrefix("devices.") }
        let tiers = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"].string!, $0["tier"].string!) })
        XCTAssertEqual(tiers, ["devices.list":"read", "devices.open":"act", "devices.shutdown":"act", "devices.screenshot":"read", "devices.tap":"act", "devices.swipe":"act", "devices.type":"act", "devices.button":"act", "devices.tree":"read", "devices.find":"read", "devices.annotations":"read"])
        let builtins = Set(try BackendDeckCoreCatalogueLiterals.builtins().map { $0.tool.id })
        for row in rows {
            let id = row["id"].string!, wire = row["wire"].string!, index = row["index"].string ?? ""
            XCTAssertEqual(wire, id.replacingOccurrences(of: ".", with: "_")); XCTAssertNotNil(wire.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression))
            XCTAssertGreaterThan(index.utf16.count, 60); XCTAssertLessThan(index.utf16.count, 200); XCTAssertNotEqual(index, row["title"].string)
            XCTAssertTrue(index.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")); XCTAssertFalse(builtins.contains(id))
            if ["devices.list", "devices.tap", "devices.swipe", "devices.tree"].contains(id) { XCTAssertTrue(row["description"].string?.contains("fractions of the screen") == true) }
        }
        let allSpecs = try BackendDeckCoreCatalogueLiterals.builtins().map(\.tool) + rows.map { try S.spec($0["id"].string!) }
        let policies = allSpecs.map { spec in BackendDeckCoreSecurityToolPolicy(tool: spec, summary: { _, _ in spec.id }, run: { _, _ in throw NativeRPCError(code: "unused", message: "Definition-only test must not run a handler") }) }
        XCTAssertNoThrow(try BackendDeckCoreSecurityControl(log: .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortSessions-definition-only")),
            consent: .init(ask: { _ in false }), policies: policies))
    }
    func testInputBudgetIsOnlyForFourFingerTools() async throws {
        let f = F(), devices = BackendDeckToolsMachinesDevices(service: f)
        for id in BackendDeckToolsMachinesDevices.ids {
            let sample: V
            switch id {
            case "devices.tap": sample = args([("x", .number(0.5)), ("y", .number(0.5))])
            case "devices.swipe": sample = args([("direction", .string("up"))])
            case "devices.type": sample = args([("text", .string("hi"))])
            case "devices.button": sample = args([("button", .string("home"))])
            case "devices.find": sample = args([("name", .string("Pay"))])
            default: sample = args()
            }
            let policy = try await devices.policy(S.spec(id), sample, S.context())
            XCTAssertEqual(policy.spends, ["devices.tap", "devices.swipe", "devices.type", "devices.button"].contains(id) ? "device-input" : "changes", id)
        }
    }
    private var engineTools: [(String, V)] { [
        ("devices.open", args()), ("devices.shutdown", args()), ("devices.screenshot", args()), ("devices.tap", args([("x", .number(0.5)), ("y", .number(0.5))])),
        ("devices.swipe", args([("direction", .string("up"))])), ("devices.type", args([("text", .string("hello"))])), ("devices.button", args([("button", .string("home"))])),
        ("devices.tree", args()), ("devices.find", args([("name", .string("Pay"))])) ] }
    func testEveryEngineToolRefusesUnavailableEngineBeforeAnyEffect() async throws {
        for (id, args) in engineTools {
            let f = F(); f.reason = "Simulators need a Mac with Apple silicon."
            let result = try await call(id, args, f)
            XCTAssertFalse(result.ok, id); XCTAssertEqual(result.refusal?.rawValue, "not-permitted", id)
            XCTAssertTrue(result.error?.contains(f.reason!) == true, id); XCTAssertTrue(result.error?.contains("do not retry") == true, id); XCTAssertTrue(f.calls.isEmpty, id)
        }
    }
    func testEveryEngineToolRejectsBadIDBeforeAnyEffectAndMissingIDIsNamed() async throws {
        for (id, args) in engineTools {
            let f = F(), result = try await call(id, args.setting("deviceId", .string("iPhone 17; rm -rf ~")), f)
            XCTAssertFalse(result.ok, id); XCTAssertEqual(result.refusal?.rawValue, "not-permitted", id); XCTAssertTrue(result.error?.contains("Call devices.list first") == true, id); XCTAssertTrue(f.calls.isEmpty, id)
        }
        let missing = try await call("devices.tap", S.o([("x", .number(0.5)), ("y", .number(0.5))]), F())
        XCTAssertFalse(missing.ok); XCTAssertTrue(missing.error?.contains("deviceId is required") == true)
    }
    func testUnavailableListIsEmptyWithReasonAndAnnotationsStillWork() async throws {
        let f = F(); f.reason = "Simulators need a Mac with Apple silicon."
        let list = try await call("devices.list", .object([]), f)
        XCTAssertTrue(list.ok); assertSubset(S.o([("available", .bool(false)), ("devices", .array([])), ("empty", .bool(true))]), list.value)
        XCTAssertTrue(list.value["emptyReason"].string?.contains(f.reason!) == true); XCTAssertTrue(f.calls.isEmpty)
        f.stored = [S.round("r1", kind: "browser")]
        let annotations = try await call("devices.annotations", .object([]), f)
        XCTAssertTrue(annotations.ok); XCTAssertEqual(annotations.value["rounds"].elements?.count, 1)
    }
    func testListStatesUsabilityCapabilitiesAndSlowEngineNote() async throws {
        let f = F(), result = try await call("devices.list", .object([]), f)
        XCTAssertTrue(result.ok); XCTAssertEqual(result.value["empty"], .bool(false)); XCTAssertEqual(result.value["usable"], .number(1))
        let rows = try XCTUnwrap(result.value["devices"].elements)
        XCTAssertEqual(rows.map { $0["id"].string }, [ios, "avd:Pixel_9", "android:R58M123"])
        assertSubset(S.o([("name", .string("iPhone 17 Pro")), ("platform", .string("ios")), ("kind", .string("simulator")), ("state", .string("running")), ("usable", .bool(true)), ("runtime", .string("iOS 27.0")), ("buttons", .array(["home", "lock", "volume-up", "volume-down", "action"].map(V.string))), ("text", .string("unicode"))]), rows[0])
        assertSubset(S.o([("state", .string("off")), ("canStart", .bool(true))]), rows[1])
        assertSubset(S.o([("state", .string("waiting for you to allow this computer on the phone")), ("note", .string("Unlock the phone and allow this computer when it asks."))]), rows[2])
        f.devices = [S.entry().setting("checking", .bool(true)), S.entry("ios:BBBB-2222", name: "iPhone Air")]
        let slow = try await call("devices.list", .object([]), f), checking = try XCTUnwrap(slow.value["devices"].elements)
        assertSubset(S.o([("checking", .bool(true)), ("usable", .bool(true))]), checking[0]); XCTAssertTrue(checking[0]["checkingNote"].string?.contains("can still be opened") == true); XCTAssertFalse(checking[1].has("checking"))
        f.devices = []
        let empty = try await call("devices.list", .object([]), f)
        XCTAssertEqual(empty.value["devices"], .array([])); XCTAssertEqual(empty.value["empty"], .bool(true))
        XCTAssertTrue(empty.value["emptyReason"].string?.contains("Xcode") == true); XCTAssertTrue(empty.value["emptyReason"].string?.contains("Android Studio") == true)
    }
    func testOpenRunningSimulatorAndStartOffEmulatorUseExactCallsAndNewID() async throws {
        let f = F(), running = try await call("devices.open", args(), f)
        XCTAssertTrue(running.ok); assertSubset(S.o([("id", .string(ios)), ("started", .bool(false)), ("device", .object([.init("name", .string("iPhone 17 Pro"))]))]), running.value); XCTAssertEqual(f.names, ["list", "open"])
        let off = F(), started = try await call("devices.open", args().setting("deviceId", .string("avd:Pixel_9")), off)
        XCTAssertTrue(started.ok); assertSubset(S.o([("id", .string("android:emulator-5554")), ("started", .bool(true))]), started.value)
        XCTAssertTrue(started.value["note"].string?.contains("Use that id for every call from here on") == true)
        XCTAssertEqual(off.names, ["list", "boot", "open"]); XCTAssertEqual(off.calls[1].args, [.string("avd:Pixel_9")]); XCTAssertEqual(off.calls[2].args, [.string("android:emulator-5554")])
    }
    func testOpenRefusesGoneUnauthorizedAndFailedBootWithoutOpening() async throws {
        let f = F(), gone = try await call("devices.open", args().setting("deviceId", .string("ios:GONE")), f)
        XCTAssertFalse(gone.ok); XCTAssertEqual(gone.refusal?.rawValue, "not-permitted"); XCTAssertTrue(gone.error?.contains("Call devices.list") == true); XCTAssertEqual(f.names, ["list"])
        let denied = try await call("devices.open", args().setting("deviceId", .string("android:R58M123")), F())
        XCTAssertFalse(denied.ok); XCTAssertTrue(denied.error?.contains("Unlock the phone") == true)
        let broken = F(); broken.bootAnswer = S.o([("ok", .bool(false)), ("message", .string("The emulator did not start."))])
        let failed = try await call("devices.open", args().setting("deviceId", .string("avd:Pixel_9")), broken)
        XCTAssertFalse(failed.ok); XCTAssertNil(failed.refusal); XCTAssertEqual(failed.error, "The emulator did not start."); XCTAssertFalse(broken.names.contains("open"))
    }
    func testShutdownSimulatorEmulatorPhoneAndAlreadyOffHaveExactOutcomes() async throws {
        let f = F(), stopped = try await call("devices.shutdown", args(), f)
        XCTAssertTrue(stopped.ok); assertSubset(S.o([("id", .string(ios)), ("shutDown", .bool(true)), ("empty", .bool(false))]), stopped.value)
        XCTAssertEqual(f.names, ["shutDown"]); XCTAssertEqual(f.calls[0].args, [.string(ios)])
        let phone = F(), refused = try await call("devices.shutdown", args().setting("deviceId", .string("android:R58M123")), phone)
        XCTAssertFalse(refused.ok); XCTAssertEqual(refused.refusal?.rawValue, "not-permitted"); XCTAssertTrue(refused.error?.contains("turned off on the phone itself") == true); XCTAssertTrue(phone.calls.isEmpty)
        let emulator = F(), shut = try await call("devices.shutdown", args().setting("deviceId", .string("android:emulator-5554")), emulator)
        XCTAssertTrue(shut.ok); XCTAssertEqual(emulator.names, ["shutDown"])
        let off = F(), empty = try await call("devices.shutdown", args().setting("deviceId", .string("avd:Pixel_9")), off)
        XCTAssertTrue(empty.ok); assertSubset(S.o([("alreadyOff", .bool(true)), ("empty", .bool(true))]), empty.value); XCTAssertTrue(off.calls.isEmpty)
        let broken = F(); broken.shutAnswer = S.o([("ok", .bool(false)), ("message", .string("The simulator would not shut down."))])
        let failed = try await call("devices.shutdown", args(), broken); XCTAssertFalse(failed.ok); XCTAssertEqual(failed.error, "The simulator would not shut down.")
    }
    func testScreenshotReturnsPathAndSizeAndNarrowsFarSession() async throws {
        let result = try await call("devices.screenshot", args(), F())
        XCTAssertTrue(result.ok); assertSubset(S.o([("deviceId", .string(ios)), ("path", .string("/Users/someone/Pictures/App/iPhone-17-Pro-20261003-142233.png")), ("width", .number(1206)), ("height", .number(2622))]), result.value)
        XCTAssertEqual(result.value.fields?.count, 4)
        let f = F(), elsewhere = try await call("devices.screenshot", args(), f, context: S.context(.session, machine: "server-1"))
        XCTAssertFalse(elsewhere.ok); XCTAssertEqual(elsewhere.refusal?.rawValue, "not-permitted"); XCTAssertTrue(elsewhere.error?.contains("Use devices.tree") == true); XCTAssertFalse(elsewhere.error?.contains("browser.read") == true); XCTAssertTrue(f.calls.isEmpty)
        let phone = try await call("devices.screenshot", args(), F(), context: S.context(.remote))
        XCTAssertTrue(phone.ok); XCTAssertTrue(phone.value["note"].string?.contains("not a file you can open") == true)
    }
    func testTapPositionAndLongPressUseGivenCoordinatesAndCappedHold() async throws {
        let f = F(), tap = try await call("devices.tap", args([("x", .number(0.25)), ("y", .number(0.75))]), f)
        XCTAssertTrue(tap.ok); assertSubset(S.o([("tapped", S.o([("x", .number(0.25)), ("y", .number(0.75))])), ("longPress", .bool(false)), ("element", .null)]), tap.value)
        XCTAssertEqual(f.calls[0].args, [.string(ios), .number(0.25), .number(0.75), .missing])
        let hold = F(), long = try await call("devices.tap", args([("x", .number(0.5)), ("y", .number(0.5)), ("holdMs", .number(60_000))]), hold)
        XCTAssertTrue(long.ok); assertSubset(S.o([("longPress", .bool(true)), ("holdMs", .number(5000))]), long.value)
        XCTAssertEqual(hold.calls[0].args, [.string(ios), .number(0.5), .number(0.5), .number(5000)]); XCTAssertTrue(long.row["detail"].string?.contains("Long-press") == true)
    }
    func testBadTapShapesRefuseBeforeAnyInput() async throws {
        for (arguments, sentence) in [(args([("x", .number(540)), ("y", .number(0.5))]), "looks like pixels"), (args([("x", .number(0.5))]), "both x and y"),
            (args([("x", .number(0.5)), ("y", .number(0.5)), ("name", .string("Pay"))]), "not both"), (args(), "Say where to tap")] {
            let f = F(), result = try await call("devices.tap", arguments, f)
            XCTAssertFalse(result.ok); XCTAssertTrue(result.error?.contains(sentence) == true); XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testFreshNamedTapAndNestedButtonDeduplicateToOnePlace() async throws {
        let f = F(), result = try await call("devices.tap", args([("identifier", .string("password-field"))]), f)
        XCTAssertTrue(result.ok); XCTAssertEqual(f.names, ["tree", "tap"]); XCTAssertEqual(f.calls[0].args, [.string(ios), .string("visible")])
        XCTAssertEqual(f.calls[1].args, [.string(ios), .number(0.5), .number(0.23), .missing])
        assertSubset(S.o([("tapped", S.o([("x", .number(0.5)), ("y", .number(0.23))])), ("element", S.o([("role", .string("text field")), ("name", .string("Password")), ("identifier", .string("password-field")), ("secret", .bool(true))]))]), result.value)
        let pay = try await call("devices.tap", args([("name", .string("pay"))]), F())
        assertSubset(S.o([("tapped", S.o([("x", .number(0.5)), ("y", .number(0.84))])), ("element", S.o([("role", .string("button")), ("identifier", .string("pay-button"))]))]), pay.value)
    }
    func testNamedTapAmbiguityCapsCandidatesAndMissingOrHiddenNeverTap() async throws {
        let f = F(); f.screen = S.node("root", role: "AXApplication", x: 0, y: 0, w: 1, h: 1, children: (0..<8).map { S.node("b\($0)", role: "AXButton", name: "Delete", id: "delete-\($0)", x: 0.8, y: 0.1 * Double($0), w: 0.15, h: 0.05) })
        let many = try await call("devices.tap", args([("name", .string("Delete"))]), f)
        XCTAssertFalse(many.ok); XCTAssertEqual(many.refusal?.rawValue, "not-permitted")
        for sentence in ["8 different elements", "Nothing was tapped", "delete-0", "delete-4", "at x 0.875, y 0.025"] { XCTAssertTrue(many.error?.contains(sentence) == true) }
        XCTAssertFalse(many.error?.contains("delete-5") == true); XCTAssertEqual(f.names, ["tree"])
        for (name, sentence) in [("Canc", "Close: button \"Cancel\""), ("Secret menu", "hidden or scrolled away")] {
            let f = F(), out = try await call("devices.tap", args([("name", .string(name))]), f)
            XCTAssertFalse(out.ok); XCTAssertTrue(out.error?.contains(sentence) == true); XCTAssertEqual(f.names, ["tree"])
            if name == "Canc" { XCTAssertTrue(out.error?.contains("Nothing on the screen matches") == true) }
        }
    }
    func testDeviceVocabularyMatchesPageIDButtonsKeysAndModifiers() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("src/main/devices/ipc.ts"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"const ID = /^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$/"#))
        func values(_ name: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: "const " + name + #" = new Set\(\[([^\]]*)\]"#)
            let match = try XCTUnwrap(regex.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)))
            let range = try XCTUnwrap(Range(match.range(at: 1), in: source)), body = String(source[range])
            let entries = try NSRegularExpression(pattern: "'([^']+)'")
            return entries.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)).compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }.sorted()
        }
        XCTAssertEqual(try values("BUTTONS"), BackendDeckToolsMachinesDeviceRules.buttons.sorted())
        XCTAssertEqual(try values("KEYS"), BackendDeckToolsMachinesDeviceRules.keys.sorted())
        let modifiers = try S.spec("devices.type").inputSchema["properties"]["modifiers"]["items"]["enum"].elements?.compactMap(\.string) ?? []
        XCTAssertEqual(try values("MODIFIERS"), modifiers.sorted())
    }
    func testSwipeDirectionsDefaultSpeedAndClampedExplicitPath() async throws {
        let expected: [(String, [Double])] = [("up", [0.5,0.75,0.5,0.25]), ("down", [0.5,0.25,0.5,0.75]), ("left", [0.75,0.5,0.25,0.5]), ("right", [0.25,0.5,0.75,0.5])]
        for (direction, points) in expected {
            let path = BackendDeckToolsMachinesDeviceRules.directionPath(direction)
            assertSubset(S.o([("x", .number(points[0])), ("y", .number(points[1]))]), path.from)
            assertSubset(S.o([("x", .number(points[2])), ("y", .number(points[3]))]), path.to)
        }
        let f = F(), up = try await call("devices.swipe", args([("direction", .string("up"))]), f)
        XCTAssertTrue(up.ok); XCTAssertEqual(f.names, ["swipe"])
        XCTAssertEqual(f.calls[0].args, [.string(ios), S.o([("x", .number(0.5)), ("y", .number(0.75))]), S.o([("x", .number(0.5)), ("y", .number(0.25))]), .number(300)])
        XCTAssertTrue(up.row["detail"].string?.contains("Swipe up") == true)
        let explicit = F()
        _ = try await call("devices.swipe", args([("from", S.o([("x", .number(0.1)), ("y", .number(0.5))])), ("to", S.o([("x", .number(0.9)), ("y", .number(0.5))])), ("durationMs", .number(10))]), explicit)
        XCTAssertEqual(explicit.calls[0].args, [.string(ios), S.o([("x", .number(0.1)), ("y", .number(0.5))]), S.o([("x", .number(0.9)), ("y", .number(0.5))]), .number(50)])
    }
    func testSwipeRejectsMixedHalfAndPixelPathsBeforeInput() async throws {
        let from = S.o([("x", .number(0.1)), ("y", .number(0.5))]), to = S.o([("x", .number(0.9)), ("y", .number(0.5))])
        for (input, text) in [(args([("direction", .string("up")), ("from", from), ("to", to)]), "not both"),
            (args([("from", from)]), "Say how to swipe"), (args([("from", from.setting("x", .number(100))), ("to", to)]), "from.x")] {
            let f = F(), result = try await call("devices.swipe", input, f)
            XCTAssertFalse(result.ok); XCTAssertTrue(result.error?.contains(text) == true); XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testDeviceTextThenKeyOrderingAndExactResult() async throws {
        let f = F(), result = try await call("devices.type", args([("text", .string("hello")), ("key", .string("return"))]), f)
        XCTAssertTrue(result.ok); XCTAssertEqual(f.names, ["open", "type", "key"])
        XCTAssertEqual(f.calls[0].args, [.string(ios)]); XCTAssertEqual(f.calls[1].args, [.string(ios), .string("hello")]); XCTAssertEqual(f.calls[2].args, [.string(ios), .string("return"), .array([])])
        assertSubset(S.o([("typedCharacters", .number(5)), ("pressed", .string("return"))]), result.value)
    }
    func testTypedSecretReachesDeviceButNeverLogDialogOrResult() async throws {
        let sentinel = "correct-horse-battery-staple-7731", f = F(), result = try await call("devices.type", args([("text", .string(sentinel))]), f)
        XCTAssertTrue(result.ok); XCTAssertTrue(f.calls.contains { $0.name == "type" && $0.args == [.string(ios), .string(sentinel)] })
        XCTAssertFalse(f.logText.contains(sentinel)); XCTAssertTrue(f.logText.contains("[\(sentinel.utf16.count) characters]"))
        XCTAssertFalse(result.row["detail"].string?.contains(sentinel) == true); XCTAssertTrue(result.row["detail"].string?.contains("\(sentinel.utf16.count) characters") == true)
        XCTAssertFalse(result.value.compact.contains(sentinel)); XCTAssertFalse(result.row.compact.contains(sentinel))
    }
    func testTypingRejectsModifiersWithoutKeyEmptyUnknownKeyAndOverlongText() async throws {
        for (input, text) in [(args([("text", .string("a")), ("modifiers", .array([.string("command")]))]), "need a key"),
            (args(), "text to type, a key to press"), (args([("key", .string("f13"))]), "key must be one of"),
            (args([("text", .string(String(repeating: "x", count: 2001)))]), "Send it in parts")] {
            let f = F(), result = try await call("devices.type", input, f)
            XCTAssertFalse(result.ok); XCTAssertTrue(result.error?.contains(text) == true); XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testDeviceTextAndKeyCapabilitiesRefuseBeforeTyping() async throws {
        for (capability, input, text) in [("ascii", args([("text", .string("café"))]), "plain ASCII"),
            ("none", args([("text", .string("hi"))]), "does not accept typed text"), ("unicode", args([("key", .string("escape"))]), "It takes: return, delete, tab")] {
            let f = F(); f.details = f.details.setting("text", .string(capability))
            let result = try await call("devices.type", input, f)
            XCTAssertFalse(result.ok); XCTAssertTrue(result.error?.contains(text) == true); XCTAssertEqual(f.names, ["open"])
        }
    }
    func testButtonsAndUnknownCapabilityListKeepActualDeviceCallsExact() async throws {
        let f = F(), home = try await call("devices.button", args([("button", .string("home"))]), f)
        XCTAssertTrue(home.ok); XCTAssertEqual(home.value["pressed"], .string("home")); XCTAssertEqual(f.names, ["open", "button"])
        XCTAssertEqual(f.calls[0].args, [.string(ios)]); XCTAssertEqual(f.calls[1].args, [.string(ios), .string("home")])
        let denied = F(), back = try await call("devices.button", args([("button", .string("back"))]), denied)
        XCTAssertFalse(back.ok); XCTAssertEqual(back.refusal?.rawValue, "not-permitted"); XCTAssertTrue(back.error?.contains("has no back button") == true); XCTAssertTrue(back.error?.contains("It has: home, lock") == true); XCTAssertEqual(denied.names, ["open"])
        let unspecified = F(); unspecified.details = unspecified.details.setting("buttons", .array([]))
        let allowed = try await call("devices.button", args([("button", .string("back"))]), unspecified)
        XCTAssertTrue(allowed.ok); XCTAssertEqual(unspecified.names, ["open", "button"])
        let invalid = try await call("devices.button", args([("button", .string("power"))]), F())
        XCTAssertFalse(invalid.ok); XCTAssertTrue(invalid.error?.contains("button must be one of") == true)
    }
    func testRotationAndMutuallyExclusiveButtonArgs() async throws {
        let f = F(), turn = try await call("devices.button", args([("rotate", .string("landscape-right"))]), f)
        XCTAssertTrue(turn.ok); XCTAssertEqual(turn.value["orientation"], .string("landscape-right")); XCTAssertTrue(f.calls.contains { $0.name == "rotate" && $0.args == [.string(ios), .string("landscape-right")] })
        let fixed = F(); fixed.details = fixed.details.setting("canRotate", .bool(false))
        let refused = try await call("devices.button", args([("rotate", .string("portrait"))]), fixed)
        XCTAssertFalse(refused.ok); XCTAssertTrue(refused.error?.contains("does not turn") == true); XCTAssertEqual(fixed.names, ["open"])
        for (input, text) in [(args([("button", .string("home")), ("rotate", .string("portrait"))]), "not both"), (args(), "Give a button")] {
            let out = try await call("devices.button", input, F()); XCTAssertFalse(out.ok); XCTAssertTrue(out.error?.contains(text) == true)
        }
    }
    func testTreeHasExactSixRowsAndNeverScaffoldingHiddenOrRefs() async throws {
        let f = F(), result = try await call("devices.tree", args(), f)
        XCTAssertTrue(result.ok); XCTAssertEqual(result.value["source"], .string("accessibility")); XCTAssertEqual(f.names, ["tree"]); XCTAssertEqual(f.calls[0].args, [.string(ios), .string("visible")])
        XCTAssertEqual(result.value["foreground"], S.o([("app", .string("com.example.Shop")), ("screen", .string(""))]))
        let frame: (Double,Double,Double,Double) -> V = { S.o([("x", .number($0)), ("y", .number($1)), ("width", .number($2)), ("height", .number($3))]) }
        let centre: (Double,Double) -> V = { S.o([("x", .number($0)), ("y", .number($1))]) }
        let expected: [V] = [S.o([("depth", .number(0)), ("role", .string("static text")), ("name", .string("Checkout")), ("frame", frame(0.1,0.05,0.8,0.05)), ("centre", centre(0.5,0.075))]),
            S.o([("depth", .number(0)), ("role", .string("text field")), ("name", .string("Password")), ("identifier", .string("password-field")), ("secret", .bool(true)), ("focused", .bool(true)), ("frame", frame(0.1,0.2,0.8,0.06)), ("centre", centre(0.5,0.23))]),
            S.o([("depth", .number(0)), ("role", .string("button")), ("name", .string("Pay")), ("identifier", .string("pay-button")), ("frame", frame(0.1,0.8,0.8,0.08)), ("centre", centre(0.5,0.84))]),
            S.o([("depth", .number(1)), ("role", .string("static text")), ("name", .string("Pay")), ("frame", frame(0.4,0.82,0.2,0.04)), ("centre", centre(0.5,0.84))]),
            S.o([("depth", .number(0)), ("role", .string("button")), ("name", .string("Cancel")), ("enabled", .bool(false)), ("frame", frame(0.1,0.9,0.3,0.06)), ("centre", centre(0.25,0.93))]),
            S.o([("depth", .number(0)), ("role", .string("button")), ("frame", frame(0.9,0.05,0.08,0.05)), ("centre", centre(0.94,0.075))])]
        let actual = try XCTUnwrap(result.value["elements"].elements); XCTAssertEqual(actual.count, 6)
        let wantedJSON = try JSONSerialization.data(withJSONObject: V.array(expected).foundation!, options: [.sortedKeys])
        let actualJSON = try JSONSerialization.data(withJSONObject: V.array(actual).foundation!, options: [.sortedKeys])
        XCTAssertEqual(actualJSON, wantedJSON)
        assertSubset(S.o([("shown", .number(6)), ("total", .number(6)), ("truncated", .bool(false)), ("empty", .bool(false))]), result.value)
        XCTAssertFalse(result.value.compact.contains("Secret menu")); XCTAssertFalse(result.value.compact.contains("\"ref\""))
    }
    func testTreeWithholdsPasswordAndReportsBothBoundsAndEngineTruncation() async throws {
        let password = F(); password.screen = S.node("r", role: "AXTextField", name: "PIN", x: 0.1, y: 0.1, w: 0.5, h: 0.1); password.screen.value = "4821"; password.screen.valueRedacted = true
        let secret = try await call("devices.tree", args(), password)
        XCTAssertFalse(secret.value.compact.contains("4821")); XCTAssertEqual(secret.value["elements"].elements?.first?["secret"], .bool(true))
        let f = F(); f.screen = S.node("root", role: "AXApplication", x: 0,y: 0,w: 1,h: 1, children: (0..<500).map { S.node("n\($0)", role: "AXStaticText", name: "Row \($0)", x: 0,y: Double($0)/500,w: 1,h: 1.0/500) })
        let first = try await call("devices.tree", args(), f)
        XCTAssertEqual(first.value["elements"].elements?.count, 150); assertSubset(S.o([("shown", .number(150)), ("total", .number(500)), ("truncated", .bool(true))]), first.value); XCTAssertTrue(first.value["note"].string?.contains("Showing 150 of 500") == true)
        let most = try await call("devices.tree", args([("limit", .number(10_000))]), f); XCTAssertEqual(most.value["elements"].elements?.count, 400)
        let few = try await call("devices.tree", args([("limit", .number(3))]), f); XCTAssertEqual(few.value["elements"].elements?.map { $0["name"].string }, ["Row 0", "Row 1", "Row 2"])
        let engine = F(); engine.engineTruncated = true
        let partial = try await call("devices.tree", args(), engine)
        XCTAssertEqual(partial.value["truncated"], .bool(true)); XCTAssertTrue(partial.value["note"].string?.contains("stopped reading the screen early") == true)
    }
    func testReactNativeComponentSourceScopeAndFallbackAndEmptyScreenAdvice() async throws {
        let f = F(); f.source = "react-native-fiber"; f.screen = S.node("r", role: "button", name: "Buy now", x: 0.1,y: 0.8,w: 0.8,h: 0.1)
        f.screen.testID = "buy"; f.screen.component = "BuyButton"; f.screen.sourceLocation = .init(file: "src/screens/Product.tsx", line: 42, column: 7)
        let result = try await call("devices.tree", args([("scope", .string("interactive"))]), f)
        XCTAssertEqual(result.value["source"], .string("react-native-fiber"))
        assertSubset(S.o([("name", .string("Buy now")), ("identifier", .string("buy")), ("component", .string("BuyButton")), ("source", .string("src/screens/Product.tsx:42:7"))]), result.value["elements"].elements?.first ?? .missing)
        XCTAssertEqual(f.names, ["tree"]); XCTAssertEqual(f.calls[0].args, [.string(ios), .string("interactive")])
        let fallback = F(); fallback.fallback = "Metro answered but the app is not connected to it."
        let native = try await call("devices.tree", args(), fallback); XCTAssertTrue(native.value["note"].string?.contains(fallback.fallback) == true)
        let blank = F(); blank.screen = S.node("r", role: "AXApplication", x: 0,y: 0,w: 1,h: 1)
        let empty = try await call("devices.tree", args(), blank)
        XCTAssertEqual(empty.value["empty"], .bool(true)); XCTAssertTrue(empty.value["emptyReason"].string?.contains("devices.screenshot") == true)
    }
    func testFindWholePartialRoleHiddenAndScopeRules() async throws {
        let result = try await call("devices.find", args([("name", .string("cancel"))]), F())
        XCTAssertTrue(result.ok); assertSubset(S.o([("count", .number(1)), ("truncated", .bool(false)), ("empty", .bool(false)),
            ("matches", .array([S.o([("role", .string("button")), ("name", .string("Cancel")), ("enabled", .bool(false)), ("centre", S.o([("x", .number(0.25)), ("y", .number(0.93))]))])]))]), result.value)
        let whole = try await call("devices.find", args([("name", .string("Check"))]), F())
        XCTAssertEqual(whole.value["count"], .number(0)); XCTAssertEqual(whole.value["empty"], .bool(true)); XCTAssertTrue(whole.value["emptyReason"].string?.contains("partial: true") == true)
        let part = try await call("devices.find", args([("name", .string("Check")), ("partial", .bool(true))]), F())
        XCTAssertEqual(part.value["count"], .number(1)); XCTAssertEqual(part.value["matches"].elements?.first?["name"], .string("Checkout"))
        let buttons = try await call("devices.find", args([("role", .string("button"))]), F())
        XCTAssertEqual(buttons.value["matches"].elements?.map { $0["name"] }, [.string("Pay"), .string("Cancel"), .missing])
        let f = F(), missing = try await call("devices.find", args(), f)
        XCTAssertFalse(missing.ok); XCTAssertTrue(missing.error?.contains("name, an identifier or a role") == true); XCTAssertTrue(f.calls.isEmpty)
        let scope = F(); _ = try await call("devices.find", args([("name", .string("Pay")), ("scope", .string("full"))]), scope)
        XCTAssertEqual(scope.names, ["tree"]); XCTAssertEqual(scope.calls[0].args, [.string(ios), .string("full")])
    }
    func testAnnotationEmptyNewestWholeRoundKindsAndTenRoundCap() async throws {
        let f = F(), empty = try await call("devices.annotations", .object([]), f)
        XCTAssertTrue(empty.ok); assertSubset(S.o([("rounds", .array([])), ("total", .number(0)), ("empty", .bool(true))]), empty.value)
        XCTAssertTrue(empty.value["emptyReason"].string?.contains("nobody has annotated anything since the app started") == true)
        f.stored = [S.round("newest", kind: "device"), S.round("older", kind: "browser")]
        let result = try await call("devices.annotations", .object([]), f)
        XCTAssertEqual(result.value["total"], .number(2)); XCTAssertEqual(result.value["rounds"].elements?.count, 1)
        let round = try XCTUnwrap(result.value["rounds"].elements?.first)
        assertSubset(S.o([("id", .string("newest")), ("where", S.o([("kind", .string("device")), ("deviceId", .string(ios)), ("app", .string("com.example.Shop"))])),
            ("picture", .object([.init("path", .string("/Users/someone/Pictures/App/newest-annotated.png"))])), ("sentTo", .null), ("note", .string("Make #1 green and put #2 on the left.")),
            ("markers", .array([S.o([("n", .number(1)), ("element", S.o([("role", .string("button")), ("name", .string("Pay")), ("identifier", .string("pay-button"))])), ("described", .string("button \"Pay\" (id pay-button)"))]), S.o([("n", .number(2)), ("element", .null), ("described", .string("blank space"))])]))]), round)
        XCTAssertTrue((round["markers"].elements ?? []).allSatisfy { !$0.has("note") })
        f.stored = [S.round("d1", kind: "device"), S.round("b1", kind: "browser"), S.round("d2", kind: "device")]
        let browser = try await call("devices.annotations", S.o([("kind", .string("browser")), ("count", .number(5))]), f)
        XCTAssertEqual(browser.value["rounds"].elements?.map { $0["id"].string }, ["b1"])
        f.stored = [S.round("d1", kind: "device")]
        let none = try await call("devices.annotations", .object([.init("kind", .string("browser"))]), f)
        XCTAssertEqual(none.value["empty"], .bool(true)); XCTAssertTrue(none.value["emptyReason"].string?.contains("1 round on device screens") == true)
        f.stored = (0..<15).map { S.round("r\($0)", kind: "device") }
        let capped = try await call("devices.annotations", .object([.init("count", .number(50))]), f)
        XCTAssertEqual(capped.value["rounds"].elements?.count, 10)
    }
}
