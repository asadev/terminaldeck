import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor RepeatedCheckCounts {
    var checks = 0
    func checked() { checks += 1 }
}
private actor RepeatedCheckDevices: BackendDeckToolsMachinesDeviceService {
    typealias V = NativeRPCValue
    var lists = 0, taps = 0
    var present = true
    let id = "ios:AAAA-1111"
    func unavailable() -> String? { nil }
    func list() -> [V] {
        lists += 1
        return present ? [.object([.init("id", .string(id)), .init("state", .string("ready"))])] : []
    }
    func remove() { present = false }
    func boot(_ id: String) -> V { .object([]) }
    func shutDown(_ id: String) -> V { .object([]) }
    func open(_ id: String) -> V { .object([]) }
    func screenshot(_ id: String) -> V { .object([]) }
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) { taps += 1 }
    func swipe(_ id: String, from: V, to: V, durationMS: Int) {}
    func type(_ id: String, text: String) {}
    func key(_ id: String, key: String, modifiers: [String]) {}
    func button(_ id: String, button: String) {}
    func rotate(_ id: String, to: String) -> String { to }
    func tree(_ id: String, scope: String) throws -> BackendDeckToolsMachinesDeviceTreeAnswer { throw BackendHOSTFailure.unavailable }
    func rounds() -> [V] { [] }
}
final class SessionRepeatedChecksTests: XCTestCase {
    func testHootChangesReadEachAccountOnceAndReturnTheSavedChoice() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        root.appendPathComponent(".part51-hoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root
        let settings = BackendAppSettingsStore(userData: root, writable: true), counts = RepeatedCheckCounts()
        _ = try await settings.patch(.object([.init("hoot.model.codex", .string("gpt-test"))]))
        let defaults = BackendHootReadyDefaults(settings: settings, enabled: true, profiles: { provider, _ in
            [.init(id: "system:" + provider.rawValue, name: provider.rawValue, provider: provider.rawValue,
                   configDir: home.path, system: true, color: "#000000", createdAt: 0)]
        }, available: { _ in true }, signedIn: { _, _ in await counts.checked(); return true })
        await defaults.setModelHome(root)
        let changes: [NativeRPCValue] = [
            .object([.init("model", .string("codex:gpt-test")), .init("permissionMode", .string("changes"))]),
            .object([.init("effort", .string("high"))]),
            .object([.init("permissionMode", .string("plan"))]),
        ]
        for patch in changes {
            let before = await counts.checks
            let response = try await defaults.setChatOptions(patch, projectPath: root.path)
            let after = await counts.checks
            XCTAssertEqual(after - before, 3, "one sign-in check per account, per change")
            XCTAssertEqual(response["model"].string, "codex:gpt-test")
            XCTAssertTrue(response["ready"].bool == true)
        }
        let saved = try await defaults.read(projectPath: root.path)
        XCTAssertEqual(saved.provider, .codex); XCTAssertEqual(saved.preferences.effort, "high")
        XCTAssertEqual(saved.preferences.permissionMode, "read-only")
    }
    func testRepeatedTapsReuseInventoryAndDeviceExitStillInvalidatesImmediately() async throws {
        let devices = RepeatedCheckDevices()
        let attachments = BackendUIGSessionSimulatorAttachments { .init(sessionID: $0, incarnation: "one") }
        let ticket = try await attachments.attach(sessionID: "s", deviceID: devices.id, service: devices)
        let scoped = BackendUIGSessionSimulatorDeviceService(base: devices, attachments: attachments, ticket: ticket)
        let before = await devices.lists
        for _ in 0..<5 { try await scoped.tap(devices.id, x: 1, y: 1, holdMS: nil) }
        let after = await devices.lists
        XCTAssertEqual(after, before, "tap validation must not enumerate the whole device inventory")
        await BackendAppDeviceLifecycle.shared.exited([devices.id])
        do { try await scoped.tap(devices.id, x: 1, y: 1, holdMS: nil); XCTFail("exited device accepted") } catch {}
        let taps = await devices.taps; XCTAssertEqual(taps, 5)
    }
    func testFreshInventoryStillCatchesAMissedExitEvent() async throws {
        let devices = RepeatedCheckDevices()
        let attachments = BackendUIGSessionSimulatorAttachments { .init(sessionID: $0, incarnation: "one") }
        let ticket = try await attachments.attach(sessionID: "s", deviceID: devices.id, service: devices)
        await devices.remove()
        try await attachments.refresh(service: devices)
        do { try await attachments.validate(ticket); XCTFail("absent device accepted") } catch {}
    }
}
