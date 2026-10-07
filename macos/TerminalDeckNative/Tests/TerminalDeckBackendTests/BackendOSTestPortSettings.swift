import Foundation
import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

class BackendOSTestPortFixture: XCTestCase {
    func scratch(_ name: String = "case") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSTestPort-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func disk(_ file: URL) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: file)) }
    func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func put(_ file: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func names(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }
}

final class BackendOSTestPortSettings: BackendOSTestPortFixture {
    func testSettingsStore60PrimitiveKinds() {
        let raw: NativeRPCValue = .object([.init("a", .bool(true)), .init("b", .number(12)), .init("c", .string("text")), .init("d", .object([.init("nested", .bool(true))])), .init("e", .array([.number(1), .number(2)])), .init("f", .null), .init("g", .number(.nan))])
        XCTAssertEqual(BackendAppSettingsStore.sanitize(raw), .object([.init("a", .bool(true)), .init("b", .number(12)), .init("c", .string("text"))]))
    }
    func testSettingsStore74PrototypeKey() {
        XCTAssertEqual(BackendAppSettingsStore.sanitize(.object([.init("__proto__", .string("x")), .init("ok", .number(1))])), .object([.init("ok", .number(1))]))
    }
    func testSettingsStore80Caps() {
        XCTAssertEqual(BackendAppSettingsStore.sanitize(.object([.init(String(repeating: "k", count: BackendAppSettingsStore.maxKeyLength + 1), .number(1))])), .object([]))
        XCTAssertEqual(BackendAppSettingsStore.sanitize(.object([.init("a", .string(String(repeating: "x", count: BackendAppSettingsStore.maxStringLength + 100)))]))["a"].string?.utf16.count, BackendAppSettingsStore.maxStringLength)
        XCTAssertEqual(BackendAppSettingsStore.sanitize(.object((0..<(BackendAppSettingsStore.maxKeys + 20)).map { .init("k\($0)", .number(Double($0))) })).fields?.count, BackendAppSettingsStore.maxKeys)
    }
    func testSettingsStore92Junk() { for raw in [NativeRPCValue.null, .missing, .number(4), .string("x"), .array([])] { XCTAssertEqual(BackendAppSettingsStore.sanitize(raw), .object([])) } }
    func testSettingsStore98PatchMerges() { XCTAssertEqual(BackendAppSettingsStore.applyPatch(.object([.init("a", .number(1)), .init("b", .string("two"))]), .object([.init("b", .string("three"))])), .object([.init("a", .number(1)), .init("b", .string("three"))])) }
    func testSettingsStore102NullDeletesOnlyOneKey() { XCTAssertEqual(BackendAppSettingsStore.applyPatch(.object([.init("a", .number(1)), .init("b", .number(2))]), .object([.init("a", .null)])), .object([.init("b", .number(2))])) }
    func testSettingsStore106InvalidPatchRetainsOldValue() { XCTAssertEqual(BackendAppSettingsStore.applyPatch(.object([.init("a", .number(1))]), .object([.init("a", .object([.init("nested", .bool(true))]))])), .object([.init("a", .number(1))])) }
    func testSettingsStore112RoundTrip() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("general.copyOnSelect", .bool(true))])); await store.resetCache()
        let result = await store.get(); XCTAssertEqual(result["values"], .object([.init("general.copyOnSelect", .bool(true))]))
    }
    func testSettingsStore118EnvelopeAndNoTemporaryFile() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("a", .number(1))]))
        XCTAssertEqual(try disk(root.appendingPathComponent("settings.json")), .object([.init("version", .number(1)), .init("values", .object([.init("a", .number(1))]))]))
        XCTAssertEqual(try names(root).filter { $0.hasSuffix(".tmp") }, [])
    }
    func testSettingsStore124LegacyBareMap() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("settings.json"), #"{"general.copyOnSelect":true}"#)
        let store = BackendAppSettingsStore(userData: root); let result = await store.get()
        XCTAssertEqual(result["values"], .object([.init("general.copyOnSelect", .bool(true))]))
    }
    func testSettingsStore130UnknownTopLevelKeys() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("settings.json"), #"{"version":1,"values":{"a":1},"futureThing":{"keep":true}}"#)
        let store = BackendAppSettingsStore(userData: root, writable: true); _ = try await store.patch(.object([.init("b", .number(2))]))
        XCTAssertEqual(try disk(root.appendingPathComponent("settings.json"))["futureThing"], .object([.init("keep", .bool(true))]))
    }
    func testSettingsStore141CorruptBackup() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("settings.json"), "{ this is not json")
        let store = BackendAppSettingsStore(userData: root, writable: true, now: { 1234 }); let read = await store.get(); XCTAssertEqual(read["values"], .object([]))
        _ = try await store.patch(.object([.init("a", .number(1))])); let backups = try names(root).filter { $0.contains(".bak-") }
        XCTAssertEqual(backups.count, 1); XCTAssertTrue(try text(root.appendingPathComponent(backups[0])).contains("this is not json"))
        XCTAssertEqual(try disk(root.appendingPathComponent("settings.json"))["values"], .object([.init("a", .number(1))]))
    }
    func testSettingsStore154FutureVersionBackup() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("settings.json"), #"{"version":99,"values":{"a":1}}"#)
        let store = BackendAppSettingsStore(userData: root, writable: true, now: { 1234 }); _ = try await store.patch(.object([.init("b", .number(2))]))
        XCTAssertEqual(try names(root).filter { $0.contains(".bak-") }.count, 1)
    }
    func testSettingsStore161FirstRunHasNoBackup() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("a", .number(1))])); XCTAssertEqual(try names(root).filter { $0.contains(".bak-") }, [])
    }
    func testSettingsStore166ResetForgetsEveryKey() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("a", .number(1)), .init("b", .number(2))])); let reset = try await store.reset(); XCTAssertEqual(reset["values"], .object([]))
        await store.resetCache(); let read = await store.get(); XCTAssertEqual(read["values"], .object([]))
    }
    func testSettingsStore173ResetPreservesUnreadableBytes() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("settings.json"), "{ this is not json")
        let store = BackendAppSettingsStore(userData: root, writable: true, now: { 1234 }); let read = await store.get(); XCTAssertEqual(read["values"], .object([]))
        _ = try await store.reset(); let backups = try names(root).filter { $0.contains(".bak-") }; XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(try text(root.appendingPathComponent(backups[0])).contains("this is not json")); XCTAssertEqual(try disk(root.appendingPathComponent("settings.json"))["values"], .object([]))
    }
    func testSettingsStore188ResetKeepsSettingsFilePresent() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("a", .number(1))])); _ = try await store.reset(); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
    }
    func testSettingsStore196CreatesDataDirectoryOnDemand() async throws {
        let root = try scratch().appendingPathComponent("missing"), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("a", .number(1))])); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
    }
    func testSettingsStore223SnapshotCopiesBothStoresAndProvenance() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true, now: { 1234 })
        _ = try await store.patch(.object([.init("appearance.density", .string("compact"))])); let wrote = try await store.snapshot(preferences: .object([.init("theme", .string("dark"))]), reason: "copilot settings.write")
        let snapshot = root.appendingPathComponent(BackendAppSettingsStore.snapshotFile), saved = try disk(snapshot)
        XCTAssertEqual(wrote["path"].string, snapshot.path); XCTAssertEqual(saved["reason"].string, "copilot settings.write")
        XCTAssertEqual(saved["at"].string, "1970-01-01T00:00:01.234Z"); XCTAssertEqual(saved["preferences"], .object([.init("theme", .string("dark"))]))
        XCTAssertEqual(saved["settings"]["values"]["appearance.density"], .string("compact")); XCTAssertEqual(saved["fromCache"].bool, false)
    }
    func testSettingsStore236SnapshotPreservesFutureFields() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("settings.json"), #"{"version":99,"values":{"appearance.density":"compact"},"fromTheFuture":{"a":1}}"#)
        let store = BackendAppSettingsStore(userData: root, writable: true); _ = try await store.snapshot(preferences: .object([]), reason: "copilot settings.write")
        XCTAssertEqual(try disk(root.appendingPathComponent(BackendAppSettingsStore.snapshotFile))["settings"]["fromTheFuture"], .object([.init("a", .number(1))]))
    }
    func testSettingsStore252SnapshotReportsCacheFallback() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("appearance.density", .string("compact"))])); try FileManager.default.removeItem(at: root.appendingPathComponent("settings.json"))
        _ = try await store.snapshot(preferences: .object([]), reason: "copilot settings.write"); let saved = try disk(root.appendingPathComponent(BackendAppSettingsStore.snapshotFile))
        XCTAssertEqual(saved["fromCache"].bool, true); XCTAssertEqual(saved["settings"]["values"]["appearance.density"], .string("compact"))
    }
    func testSettingsStore267SnapshotIsOneReplacedGeneration() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.snapshot(preferences: .object([.init("theme", .string("dark"))]), reason: "first")
        _ = try await store.snapshot(preferences: .object([.init("theme", .string("light"))]), reason: "second")
        XCTAssertEqual(try disk(root.appendingPathComponent(BackendAppSettingsStore.snapshotFile))["reason"].string, "second")
        XCTAssertEqual(try names(root).filter { $0.contains("last-good") }, [BackendAppSettingsStore.snapshotFile])
    }
    func testSettingsStore279SnapshotWriteFailureThrows() async throws {
        let root = try scratch().appendingPathComponent("blocked"); try Data("file where folder belongs".utf8).write(to: root)
        let store = BackendAppSettingsStore(userData: root, writable: true)
        do { _ = try await store.snapshot(preferences: .object([]), reason: "copilot settings.write"); XCTFail("Snapshot failure was hidden") } catch {}
    }
}

final class BackendOSTestPortSettingsExtra: BackendOSTestPortFixture {
    actor Browser: BackendAppSettingsBrowserData { var count = 0; func clearStorageCacheAndAuthentication() { count += 1 }; func value() -> Int { count } }
    func environment(_ root: URL, browser: Browser? = nil) -> BackendAppSettingsEnvironment {
        .init(userData: root, logs: root.appendingPathComponent("Logs"), trace: root.appendingPathComponent("ipc-trace.log"), browser: browser, about: { .null }, publish: { _, _ in })
    }
    func testSettingsExtra76AllPathsAndExistence() async throws {
        let root = try scratch(), store = BackendAppSettingsStore(userData: root, writable: true); _ = try await store.patch(.object([.init("a", .number(1))]))
        let paths = BackendAppSettingsChannels.paths(environment(root)).elements ?? []
        XCTAssertEqual(paths.first { $0["key"].string == "settings" }?["exists"].bool, true)
        XCTAssertEqual(paths.first { $0["key"].string == "profiles" }?["exists"].bool, false)
        XCTAssertTrue(paths.contains { $0["key"].string == "logs" }); for entry in paths { XCTAssertFalse(entry["purpose"].string?.isEmpty ?? true) }
    }
    func testSettingsExtra88AbsentPersistenceKeepsData() async throws {
        let root = try scratch(), browser = Browser(), store = BackendAppSettingsStore(userData: root, writable: true)
        let result = await BackendAppSettingsChannels.clearIfNotPersisting(store: store, environment: environment(root, browser: browser))
        XCTAssertEqual(result["cleared"].bool, false); let count = await browser.value(); XCTAssertEqual(count, 0)
    }
    func testSettingsExtra94ExplicitFalseClearsOnce() async throws {
        let root = try scratch(), browser = Browser(), store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init(BackendAppSettingsStore.browserPersistKey, .bool(false))])); let stored = await store.value(BackendAppSettingsStore.browserPersistKey); XCTAssertEqual(stored, .bool(false))
        let result = await BackendAppSettingsChannels.clearIfNotPersisting(store: store, environment: environment(root, browser: browser))
        XCTAssertEqual(result["cleared"].bool, true); let count = await browser.value(); XCTAssertEqual(count, 1)
    }
    func testSettingsExtra104RepositoryShapes() {
        for value in [NativeRPCValue.string("asadev/terminaldeck"), .object([.init("type", .string("git")), .init("url", .string("git+https://github.com/asadev/terminaldeck.git"))]), .string("git@github.com:asadev/terminaldeck.git")] {
            XCTAssertEqual(BackendAppSettingsChannels.repositoryURL(value), "https://github.com/asadev/terminaldeck")
        }
    }
    func testSettingsExtra112InvalidRepositoryIsNil() { for value in [NativeRPCValue.missing, .object([]), .string("not a repo")] { XCTAssertNil(BackendAppSettingsChannels.repositoryURL(value)) } }
    func testSettingsExtra120SnapshotListedBeforeItExists() throws {
        let root = try scratch(), paths = BackendAppSettingsChannels.paths(environment(root)).elements ?? []
        let entry = try XCTUnwrap(paths.first { $0["key"].string == "settingsLastGood" })
        XCTAssertEqual(entry["path"].string, root.appendingPathComponent(BackendAppSettingsStore.snapshotFile).path); XCTAssertEqual(entry["exists"].bool, false)
    }
    func testSettingsExtra218RetainedNativeAboutFields() async throws {
        actor Supplier {
            var calls = 0
            func about() -> NativeRPCValue { calls += 1; return .object([.init("version", .string("0.0.0-test")), .init("packaged", .bool(false))]) }
            func count() -> Int { calls }
        }
        let root = try scratch(), supplier = Supplier(), registry = NativeChannelRegistry()
        let environment = BackendAppSettingsEnvironment(userData: root, logs: root, trace: root, browser: nil, about: { await supplier.about() }, publish: { _, _ in })
        _ = try await BackendAppSettingsChannels.register(registry: registry, ownerID: "test", store: BackendAppSettingsStore(userData: root), environment: environment)
        let about = try await registry.invoke("settings:about", context: .init(caller: .nativeApp, ownerID: "window"), arguments: []), calls = await supplier.count()
        XCTAssertEqual(about["version"].string, "0.0.0-test"); XCTAssertEqual(about["packaged"].bool, false); XCTAssertEqual(calls, 1)
        // Electron/Chrome/V8/Node fields in the mixed source case are retired.
        // The final root must still connect its actual Bundle metadata supplier.
    }
}

final class BackendOSTestPortProjectMenus: XCTestCase {
    private let home = "/Users/apple"
    func only(_ dirs: [String]) -> (String) -> Bool { { dirs.contains($0) } }
    func testProjectPicker23NewestProjectParent() { XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["/Users/apple/Projects/terminaldeck", "/Users/apple/Code/thing"], home: home, exists: only(["/Users/apple/Projects", "/Users/apple/Code"])), "/Users/apple/Projects") }
    func testProjectPicker32ParentHasProjectChild() {
        let project = "/Users/apple/Tclaude/untitled folder", dir = BackendAppProjectPicker.startDirectory(projects: [project], home: home, exists: only(["/Users/apple/Tclaude"]))
        XCTAssertEqual(dir, "/Users/apple/Tclaude"); XCTAssertTrue(project.hasPrefix(dir + "/"))
    }
    func testProjectPicker45MissingVolumeSkipped() { XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["/Volumes/Archive/old-app", "/Users/apple/Projects/terminaldeck"], home: home, exists: only(["/Users/apple/Projects"])), "/Users/apple/Projects") }
    func testProjectPicker56HomeFallback() { for projects in [["/Volumes/Gone/x"], []] { XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: projects, home: home, exists: only([])), home) } }
    func testProjectPicker61RelativeRefused() { XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["terminaldeck"], home: home, exists: only(["."])), home) }
    func testProjectPicker67JunkRowsSkipped() { XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["", "/Users/apple/Projects/x"], home: home, exists: only(["/Users/apple/Projects"])), "/Users/apple/Projects") }
    @MainActor final class BrowserMenu: BackendAppSessionRowBrowserMenu {
        func bindingMenu(sessionID: String, machineID: String) -> NSMenu { NSMenu() }
    }
    /// TS session-row-menu.test.ts:12-24 mocks Electron's Menu so a press calls the item's `click`
    /// directly. AppKit's press (`performActionForItem`) is delivered by `NSApp.sendAction`, which is a
    /// no-op while a bare xctest process has no application object; the app always has one. (S1g)
    @MainActor private func pressable() { _ = NSApplication.shared }
    @MainActor func testSessionRowMenu36MainMoveChoice() throws {
        pressable()
        let popup = try XCTUnwrap(BackendAppSessionRowMenu.buildMenu(.object([.init("sessionId", .string("s1")), .init("name", .string("Session 1")), .init("promoted", .bool(true)), .init("window", .string("main"))]), browser: BrowserMenu()))
        let labels = popup.menu.items.map(\.title); XCTAssertTrue(labels.contains("Move to New Window")); XCTAssertFalse(labels.contains("Move Back to Main Window"))
        let index = try XCTUnwrap(popup.menu.items.firstIndex { $0.title == "Move to New Window" }); popup.menu.performActionForItem(at: index); XCTAssertEqual(popup.value, .string("popout"))
    }
    @MainActor func testSessionRowMenu44OwnWindowChoices() throws {
        pressable()
        let popup = try XCTUnwrap(BackendAppSessionRowMenu.buildMenu(.object([.init("sessionId", .string("s1")), .init("name", .string("Session 1")), .init("promoted", .bool(true)), .init("window", .string("own"))]), browser: BrowserMenu()))
        let labels = popup.menu.items.map(\.title); XCTAssertTrue(labels.contains("Show Its Window")); XCTAssertTrue(labels.contains("Move Back to Main Window")); XCTAssertFalse(labels.contains("Move to New Window"))
        let index = try XCTUnwrap(popup.menu.items.firstIndex { $0.title == "Move Back to Main Window" }); popup.menu.performActionForItem(at: index); XCTAssertEqual(popup.value, .string("dock"))
    }
    func testSessionRowMenu52NonPoppableHasNoWindowChoice() { XCTAssertFalse(BackendAppSessionRowMenu.items(.object([.init("sessionId", .string("copilot")), .init("promoted", .bool(false))])).contains { $0.label.contains("Window") }) }
}
