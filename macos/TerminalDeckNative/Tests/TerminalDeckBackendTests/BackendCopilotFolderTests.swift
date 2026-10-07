import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendCopilotFolderTests: XCTestCase {
    func testFolderValidationRefusalsAndDefaultCarveOut() {
        let data = "/app/data"
        let present: (String) -> Bool = { _ in true }
        for raw: NativeRPCValue in [.missing, .null, .number(42), .string(""), .string("   ")] {
            XCTAssertEqual(BackendCopilotFolder.validate(raw, userData: data, checks: present).problem, "No folder was chosen.")
        }
        XCTAssertTrue(BackendCopilotFolder.validate(.string("projects/thing"), userData: data, checks: present).problem!.contains("full path"))
        XCTAssertTrue(BackendCopilotFolder.validate(.string("/"), userData: data, checks: present).problem!.contains("root of the disk"))
        for path in [data, data + "/routines", data + "/copilot-log", data + "/remote"] {
            XCTAssertTrue(BackendCopilotFolder.validate(.string(path), userData: data, checks: present).problem!.contains("this app’s own storage"))
        }
        for path in [data + "/copilot", data + "/copilot/memory", data + "-backup", "/somebody/work"] {
            XCTAssertTrue(BackendCopilotFolder.validate(.string(path), userData: data, checks: present).ok)
        }
        XCTAssertTrue(BackendCopilotFolder.validate(.string("/somebody/work"), userData: data, checks: { _ in false }).problem!.contains("no folder there"))
    }
    func testChoiceNormalizationFallbackAndRestartAreVisible() {
        XCTAssertEqual(BackendCopilotFolder.chosenHome(.string("  /Volumes/Work/./folder/../Hoot  ")), "/Volumes/Work/Hoot")
        XCTAssertNil(BackendCopilotFolder.chosenHome(.number(3)))
        let missing = BackendCopilotFolder.report(stored: .string("/unmounted"), userData: "/app/data", runningIn: "/old", checks: { _ in false })
        XCTAssertEqual(missing.home, "/app/data/copilot")
        XCTAssertEqual(missing.chosen, "/unmounted")
        XCTAssertTrue(missing.isDefault); XCTAssertTrue(missing.restartNeeded); XCTAssertNotNil(missing.problem)
        XCTAssertEqual(BackendCopilotFolder.pickerStart(missing, home: "/Users/person"), "/Users/person")
        let chosen = BackendCopilotFolder.report(stored: .string("/chosen"), userData: "/app/data", runningIn: "/chosen", checks: { _ in true })
        XCTAssertFalse(chosen.restartNeeded)
        XCTAssertEqual(BackendCopilotFolder.pickerStart(chosen, home: "/Users/person"), "/chosen")
        XCTAssertEqual(chosen.wireValue["problem"], .null)
    }
    func testFolderPickerStoresOnlyItsNativeSelectionAndDoesNotMoveFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotFolder-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), chosen = root.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try Data("# person's assistant\n".utf8).write(to: chosen.appendingPathComponent("CLAUDE.md"))
        let deps = BackendCopilotFolderTestDependencies(userData: data.path, chosen: chosen.path)
        let service = BackendCopilotFolderService(dependencies: deps)
        let result = try await service.pick()
        XCTAssertFalse(result.cancelled); XCTAssertNil(result.problem); XCTAssertEqual(result.report.home, chosen.path)
        let stored = await deps.stored
        XCTAssertEqual(stored.string, chosen.path)
        let rows = await deps.logged
        XCTAssertEqual(rows.first?.action, "folder.chosen")
        XCTAssertTrue(rows.first!.detail!.contains("Nothing of this app’s is written there"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), ["CLAUDE.md"])
        let cleared = try await service.clear()
        XCTAssertEqual(cleared.report.home, data.path + "/copilot")
        XCTAssertEqual(try String(contentsOf: chosen.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "# person's assistant\n")
        await deps.setPicked(nil)
        let cancelled = try await service.pick()
        XCTAssertTrue(cancelled.cancelled); XCTAssertNil(cancelled.problem)
        await deps.setPicked(data.path)
        let refused = try await service.pick()
        XCTAssertNotNil(refused.problem)
        let finalStored = await deps.stored
        XCTAssertEqual(finalStored, .null)
    }
    func testChoosingTextSaysActualAccessAndRestart() {
        XCTAssertEqual(BackendCopilotFolder.homeSetting, "copilot.home")
        XCTAssertTrue(BackendDeckCoreCatalogueRules.isProtectedSetting(BackendCopilotFolder.homeSetting))
        XCTAssertTrue(BackendCopilotFolder.choosing.contains("including any credentials kept there"))
        XCTAssertTrue(BackendCopilotFolder.choosing.contains("same access any session you start in that folder already has"))
        XCTAssertTrue(BackendCopilotFolder.needsRestart.contains("The one running now keeps working where it began."))
    }
    func testMissingPickerIsAnExplicitUnavailableError() async {
        do { _ = try await BackendCopilotFolderService(dependencies: BackendCopilotFolderUnavailable()).pick(); XCTFail("Should refuse unavailable folder settings") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
    }
    func testRegistrationHasExactlyThreeNoArgumentNativeOnlyChannels() async throws {
        let deps = BackendCopilotFolderTestDependencies(userData: "/data", chosen: "/picked")
        let registry = NativeChannelRegistry(), service = BackendCopilotFolderService(dependencies: deps)
        let channels = try await service.register(registry: registry, ownerID: "app")
        XCTAssertEqual(channels.sorted(), ["copilot:folder", "copilot:folder:clear", "copilot:folder:pick"].sorted())
        let registered = await registry.channels()
        XCTAssertEqual(registered, channels.sorted())
        do {
            _ = try await registry.invoke("copilot:folder:pick", context: .init(caller: .nativeApp, ownerID: "app"), arguments: [.string("/page-path")])
            XCTFail("Page arguments may not choose the working folder")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        do {
            _ = try await registry.invoke("copilot:folder:clear", context: .init(caller: .pairedDevice, ownerID: "phone"), arguments: [])
            XCTFail("A remote caller may not choose the working folder")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        let stored = await deps.stored
        XCTAssertEqual(stored, .null)
    }
}

private actor BackendCopilotFolderTestDependencies: BackendCopilotFolderDependencies {
    let data: String
    var stored: NativeRPCValue = .null
    var picked: String?
    var logged: [BackendCopilotAction] = []
    init(userData: String, chosen: String) { data = userData; picked = chosen }
    func setPicked(_ value: String?) { picked = value }
    func userData() -> String { data }
    func read() -> NativeRPCValue { stored }
    func write(_ value: String?) { stored = value.map(NativeRPCValue.string) ?? .null }
    func runningIn() -> String? { nil }
    func pick(defaultPath: String) -> String? { picked }
    func homeDir() -> String { "/Users/person" }
    func log(_ entry: BackendCopilotAction) { logged.append(entry) }
}
