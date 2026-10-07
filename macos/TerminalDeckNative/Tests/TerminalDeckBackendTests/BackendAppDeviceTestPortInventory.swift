import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private let BackendAppDeviceTestPortA = "CD9C5A1C-ADD5-4E46-AF81-EAAADDCE9402"
private let BackendAppDeviceTestPortB = "AE0835B7-3AC6-467D-AB49-EF48CE064D22"
private let BackendAppDeviceTestPortButtons = ["home", "lock", "volume-up", "volume-down", "action"]
private let BackendAppDeviceTestPortIOS = BackendAppSessionTestPortObject([("id", .string("ios:427403DD-17A1-46DD-897E-1ABEF8851785")), ("kind", .string("simulator")), ("name", .string("td-annotate-test")), ("platform", .string("ios")), ("runtime", .string("com.apple.CoreSimulator.SimRuntime.iOS-27-0")), ("state", .string("ready")), ("available", .bool(true)), ("capabilities", BackendAppSessionTestPortObject([("input", BackendAppSessionTestPortObject([("buttons", .array(BackendAppDeviceTestPortButtons.map(NativeRPCValue.string))), ("text", .string("unicode"))])), ("orientation", .bool(true))]))])
private let BackendAppDeviceTestPortEmulator = BackendAppSessionTestPortObject([("id", .string("android:emulator-5554")), ("platform", .string("android")), ("kind", .string("emulator")), ("state", .string("ready")), ("available", .bool(true)), ("name", .string("emulator-5554")), ("runtime", .string("Android 16 (API 36)")), ("capabilities", BackendAppSessionTestPortObject([("input", BackendAppSessionTestPortObject([("buttons", .array([.string("back"), .string("home")])), ("text", .string("ascii"))]))]))])
private let BackendAppDeviceTestPortDisk = [BackendAppDeviceDiskSimulator(udid: BackendAppDeviceTestPortA, name: "iPhone 18 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", state: "ready"), .init(udid: BackendAppDeviceTestPortB, name: "iPhone 17 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", state: "shutdown")]
private actor BackendAppDeviceTestPortInventorySource {
    var current: [NativeRPCValue]?
    var slow = false
    var asks = 0
    var waiting: CheckedContinuation<[NativeRPCValue]?, Never>?
    var notifications: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ rows: [NativeRPCValue]?) { current = rows }
    func engine() async -> [NativeRPCValue]? {
        asks += 1; let ready = notifications.filter { $0.0 <= asks }; notifications.removeAll { $0.0 <= asks }; for row in ready { row.1.resume() }
        if slow { return await withCheckedContinuation { waiting = $0 } }; return current
    }
    func set(_ rows: [NativeRPCValue]?) { current = rows }
    func makeSlow() { slow = true }
    func release(_ rows: [NativeRPCValue]) { waiting?.resume(returning: rows); waiting = nil }
    func whenAsked(_ count: Int) async { if asks >= count { return }; await withCheckedContinuation { notifications.append((count, $0)) } }
}
final class BackendAppDeviceTestPortInventory: XCTestCase, @unchecked Sendable {
    typealias P = BackendAppDeviceInventoryParsing
    private func plist(_ udid: String, _ name: String, _ state: Int, deleted: Bool = false) -> String { "<?xml version=\"1.0\"?><plist><dict><key>UDID</key><string>\(udid)</string><key>isDeleted</key><\(deleted ? "true" : "false")/><key>name</key><string>\(name)</string><key>runtime</key><string>com.apple.CoreSimulator.SimRuntime.iOS-27-0</string><key>state</key><integer>\(state)</integer></dict></plist>" }
    private func sources(_ source: BackendAppDeviceTestPortInventorySource, avds: [String] = []) -> BackendAppDeviceInventorySources { .init(engineDevices: { await source.engine() }, diskSimulators: { BackendAppDeviceTestPortDisk }, avds: { avds }, avdName: { _ in "IMATCH_Pixel8" }) }
    private var iosA: NativeRPCValue { BackendAppDeviceTestPortIOS.setting("id", .string("ios:" + BackendAppDeviceTestPortA)).setting("name", .string("iPhone 18 Pro")) }
    func testRunningSimulatorFieldsAndHomeButton() throws {
        let row = try XCTUnwrap(P.engineDevice(BackendAppDeviceTestPortIOS))
        for (key, expected) in [("id", "ios:427403DD-17A1-46DD-897E-1ABEF8851785"), ("platform", "ios"), ("kind", "simulator"), ("state", "ready"), ("name", "td-annotate-test"), ("runtime", "iOS 27.0"), ("text", "unicode")] { XCTAssertEqual(row[key].string, expected) }
        XCTAssertEqual(row["available"].bool, true); XCTAssertEqual(row["canBoot"].bool, false); XCTAssertEqual(row["canShutDown"].bool, true); XCTAssertEqual(row["canRotate"].bool, true); XCTAssertTrue(row["buttons"].elements?.contains(.string("home")) == true)
    }
    func testShutdownSimulatorOfferedBootNotShutdown() { let row = P.engineDevice(BackendAppDeviceTestPortIOS.setting("state", .string("shutdown")).setting("available", .bool(false))); XCTAssertEqual(row?["canBoot"].bool, true); XCTAssertEqual(row?["canShutDown"].bool, false) }
    func testPhysicalUnauthorizedPhoneHasNoPowerControls() { let raw = BackendAppSessionTestPortObject([("id", .string("android:R5CT20")), ("platform", .string("android")), ("kind", .string("physical")), ("state", .string("unauthorized")), ("name", .string("Galaxy"))]); let row = P.engineDevice(raw); XCTAssertEqual(row?["canBoot"].bool, false); XCTAssertEqual(row?["canShutDown"].bool, false); XCTAssertTrue(row?["note"].string?.contains("allow this computer") == true) }
    func testMalformedRowsDroppedRatherThanBlank() { XCTAssertNil(P.engineDevice(BackendAppDeviceTestPortIOS.setting("id", .string("")))); XCTAssertNil(P.engineDevice(BackendAppDeviceTestPortIOS.setting("platform", .string("windows-phone")))); XCTAssertNil(P.engineDevice(.string("nonsense"))) }
    func testRuntimeAndStateWordsExact() { XCTAssertEqual(P.plainRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-5"), "iOS 26.5"); XCTAssertEqual(P.plainRuntime("Android 16"), "Android 16"); XCTAssertEqual(P.stateWords("shutdown"), "off") }
    func testEnginePlatformAndArchitectureRefusal() { XCTAssertEqual(BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: "/fixture", cwd: "/fixture", environment: [:], platform: "win32", arch: "x64", exists: { _ in false }, executable: { _ in false }), .unavailable("Simulators open on a Mac. This computer is not one.")); XCTAssertEqual(BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: "/fixture", cwd: "/fixture", environment: [:], arch: "x64", exists: { _ in false }, executable: { _ in false }), .unavailable("Simulators need a Mac with Apple silicon.")) }
    func testPackagedCandidatesLeadAndDevelopmentRemains() { let list = BackendAppDeviceEngineLocator.candidates(resourcesPath: "/Applications/X.app/Contents/Resources", appPath: "/Applications/X.app/Contents/Resources/app.asar", cwd: "/tmp"); XCTAssertEqual(list.first, "/Applications/X.app/Contents/Resources/app.asar.unpacked/node_modules/@toolingtools/simview/bin"); XCTAssertTrue(list.contains("/tmp/node_modules/@toolingtools/simview/bin")) }
    func testExecutableEngineNamesItsCompanionResources() throws {
        let bin = "/fixture/node_modules/@toolingtools/simview/bin", files = Set(["simview-core", "simview-android-agent.jar", "xctest-provider/SimViewXCTestProvider.xctestrun"].map { bin + "/" + $0 })
        let answer = BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: "/fixture", cwd: "/fixture", environment: [:], arch: "arm64", exists: { files.contains($0) }, executable: { $0 == bin + "/simview-core" })
        guard case .available(let engine) = answer else { XCTFail("Expected executable engine"); return }
        XCTAssertEqual(engine.core, bin + "/simview-core"); XCTAssertEqual(engine.environment["SIMVIEW_ANDROID_AGENT_PATH"], bin + "/simview-android-agent.jar"); XCTAssertEqual(engine.environment["SIMVIEW_XCTEST_PROVIDER_XCTESTRUN"], bin + "/xctest-provider/SimViewXCTestProvider.xctestrun")
    }
    func testMissingEngineHasReadableReason() { let answer = BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: "/missing", cwd: "/missing", environment: [:], arch: "arm64", exists: { _ in false }, executable: { _ in false }); guard case .unavailable(let reason) = answer else { XCTFail("Expected missing engine"); return }; XCTAssertTrue(reason.contains("missing its simulator engine")) }
    func testPlistBootedShutdownAndBootingStates() { XCTAssertEqual(P.plist(plist(BackendAppDeviceTestPortA, "iPhone 18 Pro", 3)), .init(udid: BackendAppDeviceTestPortA, name: "iPhone 18 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", state: "ready")); XCTAssertEqual(P.plist(plist(BackendAppDeviceTestPortB, "iPhone 17 Pro", 1))?.state, "shutdown"); XCTAssertEqual(P.plist(plist(BackendAppDeviceTestPortB, "iPhone 17 Pro", 2))?.state, "booting") }
    func testPlistAmpersandDecoded() { XCTAssertEqual(P.plist(plist(BackendAppDeviceTestPortA, "Tom &amp; Jerry", 1))?.name, "Tom & Jerry") }
    func testDeletedBinaryAndInvalidPlistsRefused() { XCTAssertNil(P.plist(plist(BackendAppDeviceTestPortA, "Gone", 1, deleted: true))); XCTAssertNil(P.plist("bplist00\0\u{1}")); XCTAssertNil(P.plist(plist("not-a-udid", "Odd", 1))) }
    func testDiskListingSkipsNonSimulatorAndUnreadableFolders() {
        let root = "/fixture/simulators", records = [BackendAppDeviceTestPortA: plist(BackendAppDeviceTestPortA, "iPhone 18 Pro", 3), BackendAppDeviceTestPortB: plist(BackendAppDeviceTestPortB, "iPhone 17 Pro", 1)]
        let sims = BackendAppDevicePlatform(environment: [:], home: "/fixture").diskSimulators(folder: root, entries: { $0 == root ? [BackendAppDeviceTestPortA, BackendAppDeviceTestPortB, "device_set.plist", "11111111-2222-3333-4444-555555555555"] : nil }, contents: { records[URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent] })
        XCTAssertEqual(sims.map(\.name).sorted(), ["iPhone 17 Pro", "iPhone 18 Pro"])
        XCTAssertEqual(BackendAppDevicePlatform(environment: [:], home: "/fixture").diskSimulators(folder: root + "/missing", entries: { _ in nil }, contents: { _ in nil }), [])
    }
    func testEngineIOSAnswerWinsAndIsNotChecking() async {
        let source = BackendAppDeviceTestPortInventorySource([iosA]), inventory = BackendAppDeviceInventory(sources: sources(source), waitMilliseconds: 50, clock: BackendAppSessionTestPortClock())
        let list = await inventory.list(); XCTAssertEqual(list.map { $0["id"].string }, ["ios:" + BackendAppDeviceTestPortA]); XCTAssertEqual(list[0]["checking"], .missing)
    }
    func testNoIOSAnswerKeepsEveryDiskSimulatorAndPriorCapabilities() async {
        let source = BackendAppDeviceTestPortInventorySource([iosA, BackendAppDeviceTestPortEmulator]), inventory = BackendAppDeviceInventory(sources: sources(source), waitMilliseconds: 50, clock: BackendAppSessionTestPortClock())
        _ = await inventory.list(); await source.set([BackendAppDeviceTestPortEmulator]); let list = await inventory.list()
        let a = list.first { $0["id"].string == "ios:" + BackendAppDeviceTestPortA }, b = list.first { $0["id"].string == "ios:" + BackendAppDeviceTestPortB }
        XCTAssertEqual(a?["name"].string, "iPhone 18 Pro"); XCTAssertEqual(a?["state"].string, "ready"); XCTAssertEqual(a?["available"].bool, true); XCTAssertEqual(a?["checking"].bool, true); XCTAssertEqual(a?["runtime"].string, "iOS 27.0"); XCTAssertEqual(a?["buttons"].elements, BackendAppDeviceTestPortButtons.map(NativeRPCValue.string))
        XCTAssertEqual(b?["state"].string, "shutdown"); XCTAssertEqual(b?["canBoot"].bool, true); XCTAssertEqual(b?["available"].bool, false); XCTAssertEqual(b?["checking"].bool, true)
        XCTAssertEqual(list.first { $0["id"].string == "android:emulator-5554" }?["name"].string, "IMATCH Pixel8")
    }
    func testLateEngineAnswersFromDiskAndReusesLateResult() async {
        let clock = BackendAppSessionTestPortClock(), source = BackendAppDeviceTestPortInventorySource([iosA, BackendAppDeviceTestPortEmulator]), inventory = BackendAppDeviceInventory(sources: sources(source, avds: ["IMATCH_Pixel8", "ASAD_Pixel8"]), waitMilliseconds: 30, clock: clock)
        _ = await inventory.list(); await source.makeSlow(); let registrations = clock.registeredCount(); let started = clock.now()
        let pending = Task { await inventory.list() }; await source.whenAsked(2); await clock.whenRegistered(registrations + 1); clock.advance(30)
        let list = await pending.value; XCTAssertLessThan(clock.now().timeIntervalSince(started) * 1000, 1000)
        XCTAssertTrue(list.filter { $0["platform"].string == "ios" }.allSatisfy { $0["checking"].bool == true }); XCTAssertEqual(list.first { $0["id"].string == "android:emulator-5554" }?["checking"].bool, true)
        let avds = list.filter { $0["id"].string?.hasPrefix("avd:") == true }; XCTAssertEqual(avds.map { $0["id"].string }, ["avd:ASAD_Pixel8"]); XCTAssertEqual(avds[0]["canBoot"].bool, true); XCTAssertEqual(avds[0]["checking"].bool, true)
        let asksBefore = await source.asks; XCTAssertEqual(asksBefore, 2); await source.release([iosA, BackendAppDeviceTestPortEmulator]); let next = await inventory.list(); let asksAfter = await source.asks; XCTAssertEqual(asksAfter, 2); XCTAssertEqual(next.first { $0["id"].string == "ios:" + BackendAppDeviceTestPortA }?["checking"], .missing)
    }
    func testEngineFailureIsSameDiskFallbackAsLate() async {
        let inventory = BackendAppDeviceInventory(sources: sources(BackendAppDeviceTestPortInventorySource(nil)), waitMilliseconds: 50, clock: BackendAppSessionTestPortClock())
        let list = await inventory.list(); XCTAssertEqual(list.compactMap { $0["id"].string }.sorted(), ["ios:" + BackendAppDeviceTestPortB, "ios:" + BackendAppDeviceTestPortA].sorted()); XCTAssertTrue(list.allSatisfy { $0["checking"].bool == true })
    }
}
