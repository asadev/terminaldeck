import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor Devices20Service: BackendDeckToolsMachinesDeviceService {
    var devices: [NativeRPCValue]
    var listCount = 0
    var race = false
    var gate: CheckedContinuation<Void, Never>?
    var dieOnOpen = false
    var bootCount = 0
    init(_ devices: [NativeRPCValue]) { self.devices = devices }
    func set(_ rows: [NativeRPCValue]) { devices = rows }
    func armRace() { race = true; listCount = 0 }
    func die() { dieOnOpen = true }
    func unavailable() -> String? { nil }
    func emptyReason() -> String? { nil }
    func list() async -> [NativeRPCValue] {
        listCount += 1
        // The first inventory refresh is shared. Race the two direct attach reads after it.
        if race && listCount == 2 { await withCheckedContinuation { gate = $0 } }
        else if race && listCount == 3 { gate?.resume(); gate = nil }
        return devices
    }
    func boot(_ id: String) -> NativeRPCValue {
        bootCount += 1
        let live = "android:emulator-5580"
        devices = [Devices20Tests.row(live, avd: String(id.dropFirst(4)))]
        return .object([.init("ok", .bool(true)), .init("id", .string(live))])
    }
    func boots() -> Int { bootCount }
    func shutDown(_ id: String) -> NativeRPCValue { devices = []; return .object([.init("ok", .bool(true))]) }
    func open(_ id: String) throws -> NativeRPCValue {
        if dieOnOpen { devices = []; throw NativeRPCError(code: "device-fault", message: "The emulator exited.") }
        return .object([.init("id", .string(id))])
    }
    func screenshot(_ id: String) -> NativeRPCValue { .object([]) }
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) {}
    func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int) {}
    func type(_ id: String, text: String) {}
    func key(_ id: String, key: String, modifiers: [String]) {}
    func button(_ id: String, button: String) {}
    func rotate(_ id: String, to: String) -> String { to }
    func tree(_ id: String, scope: String) throws -> BackendDeckToolsMachinesDeviceTreeAnswer { throw NativeRPCError(code: "unused", message: "Unused") }
    func rounds() -> [NativeRPCValue] { [] }
}
private actor Devices20Commands: BackendAppSessionCommandExecuting {
    var calls: [[String]] = []
    let start: BackendAppSessionCommandResult
    let foreground: String
    let resolve: BackendAppSessionCommandResult
    init(start: BackendAppSessionCommandResult, foreground: String = "", resolve: BackendAppSessionCommandResult = .init(stdout: "com.example.app/.Launcher\n", exitCode: 0)) {
        self.start = start; self.foreground = foreground; self.resolve = resolve
    }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) -> BackendAppSessionCommandResult {
        calls.append(arguments)
        if arguments.contains("resolve-activity") { return resolve }
        if arguments.contains("dumpsys") { return .init(stdout: foreground, exitCode: 0) }
        return start
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) {}
    func captured() -> [[String]] { calls }
}
private actor Devices20BootCommands: BackendAppSessionCommandExecuting {
    var launched = false
    var modes: [String] = []
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) -> BackendAppSessionCommandResult {
        if arguments == ["devices"] { return .init(stdout: launched ? "emulator-5580 device\n" : "", exitCode: 0) }
        if arguments.contains("sys.boot_completed") { return .init(stdout: "1\n", exitCode: 0) }
        return .init(exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) throws {
        let mode = arguments.last ?? ""; modes.append(mode)
        if mode == "host" { throw NativeRPCError(code: "fixture", message: "Hardware unavailable") }
        launched = true
    }
    func captured() -> [String] { modes }
}
private actor Devices20InventoryState {
    var engine: [NativeRPCValue]?
    var live: Set<String>
    init(_ row: NativeRPCValue) { engine = [row]; live = [row["id"].string!] }
    func rows() -> [NativeRPCValue]? { engine }
    func ids() -> Set<String> { live }
    func exit() { engine = nil; live = [] }
}

final class Devices20Tests: XCTestCase, @unchecked Sendable {
    static func row(_ id: String, state: String = "ready", avd: String? = nil) -> NativeRPCValue {
        let ios = id.hasPrefix("ios:")
        var value = BackendDeckToolsMachinesPortObject(["id": .string(id), "platform": .string(ios ? "ios" : "android"), "kind": .string(ios ? "simulator" : "emulator"), "state": .string(state), "available": .bool(state == "ready"), "name": .string(avd ?? id), "canBoot": .bool(state == "shutdown")])
        if let avd { value = value.setting("avd", .string(avd)) }; return value
    }
    private func attachments() -> BackendUIGSessionSimulatorAttachments {
        .init(resolveLocalSession: { .init(sessionID: $0, incarnation: "one") })
    }
    private func call(_ tool: String, attachments: BackendUIGSessionSimulatorAttachments, service: Devices20Service, args: NativeRPCValue = .object([])) async throws -> BackendMCPToolReply {
        let environment = BackendDeckToolsMachinesPortEnvironment(BackendDeckToolsMachinesPortContext(.session, session: "s"))
        let definitions = try BackendUIGSessionSimulatorMCP(service: service, attachments: attachments).definitions(environment: environment)
            + BackendANDROIDPhoneOpenApp(service: service, attachments: attachments).definitions(environment: environment)
        return try await XCTUnwrap(definitions.first { $0.spec.id == tool }).handler(BackendDeckToolsMachinesPortNativeContext(), args)
    }
    func testDeadSlotsAreFreedByAttachedToolAndSameAVDCanOpenAgain() async throws {
        let a = attachments(), service = Devices20Service([Self.row("android:emulator-5580"), Self.row("android:emulator-5582")])
        let old = try await a.attach(sessionID: "s", deviceID: "android:emulator-5580", service: service)
        _ = try await a.attach(sessionID: "s", deviceID: "android:emulator-5582", slot: 1, service: service)
        await service.set([Self.row("avd:Scratch", state: "shutdown", avd: "Scratch")])
        let read = try await call("devices.attached", attachments: a, service: service)
        XCTAssertFalse(read.isError); XCTAssertEqual(read.structuredContent?["devices"].elements?.count, 0)
        do { try await a.validate(old); XCTFail("Dead ticket still accepted") } catch {}
        let opened = try await call("devices.open_app", attachments: a, service: service, args: BackendDeckToolsMachinesPortObject(["platform": .string("android"), "deviceId": .string("avd:Scratch")]))
        XCTAssertFalse(opened.isError, "\(opened)")
        let held = try await a.attached(sessionID: "s"), boots = await service.boots()
        XCTAssertEqual(held.count, 1); XCTAssertEqual(held.first?.slot, 0); XCTAssertEqual(held.first?.deviceID, "android:emulator-5580"); XCTAssertEqual(boots, 1)
    }
    func testConfirmedExitClearsDeviceAcrossSessions() async throws {
        let a = attachments(), id = "android:emulator-5580", service = Devices20Service([Self.row("android:emulator-5580")])
        _ = try await a.attach(sessionID: "s", deviceID: id, service: service)
        _ = try await a.attach(sessionID: "other", deviceID: id, service: service)
        await BackendAppDeviceLifecycle.shared.exited([id])
        let one = try await a.attached(sessionID: "s"), two = try await a.attached(sessionID: "other")
        XCTAssertTrue(one.isEmpty); XCTAssertTrue(two.isEmpty)
    }
    func testShutdownAndDeletedIOSSimulatorFreeItsSlot() async throws {
        let a = attachments(), id = "ios:" + UUID().uuidString, service = Devices20Service([])
        await service.set([Self.row(id)])
        _ = try await a.attach(sessionID: "s", deviceID: id, service: service)
        await service.set([Self.row(id, state: "shutdown")]); try await a.refresh(service: service)
        let off = try await a.attached(sessionID: "s"); XCTAssertTrue(off.isEmpty)
        await service.set([Self.row(id)]); _ = try await a.attach(sessionID: "s", deviceID: id, service: service)
        await service.set([]); try await a.refresh(service: service)
        let deleted = try await a.attached(sessionID: "s"); XCTAssertTrue(deleted.isEmpty)
    }
    func testOfflineGuestKeepsSlotWhileItStillExists() async throws {
        let a = attachments(), id = "android:emulator-5580", service = Devices20Service([Self.row("android:emulator-5580")])
        _ = try await a.attach(sessionID: "s", deviceID: id, service: service)
        await service.set([Self.row(id, state: "offline")]); try await a.refresh(service: service)
        let held = try await a.attached(sessionID: "s"); XCTAssertEqual(held.count, 1)
    }
    func testConcurrentAttachCannotFillBothSlotsWithSameDevice() async throws {
        let a = attachments(), id = "android:emulator-5580", service = Devices20Service([Self.row("android:emulator-5580")])
        await service.armRace()
        let successes = await withTaskGroup(of: Bool.self) { group in
            for slot in 0...1 { group.addTask { do { _ = try await a.attach(sessionID: "s", deviceID: id, slot: slot, service: service); return true } catch { return false } } }
            var count = 0; for await ok in group { if ok { count += 1 } }; return count
        }
        let held = try await a.attached(sessionID: "s"); XCTAssertEqual(successes, 1); XCTAssertEqual(held.count, 1)
    }
    func testBootRekeyMergesIntoAlreadyAttachedSerial() async throws {
        let a = attachments(), serial = "android:emulator-5580", service = Devices20Service([Self.row("avd:Scratch", state: "shutdown"), Self.row("android:emulator-5580")])
        let live = try await a.attach(sessionID: "s", deviceID: serial, service: service)
        let reservation = try await a.attach(sessionID: "s", deviceID: "avd:Scratch", slot: 1, service: service)
        let merged = try await a.booted(reservation, as: serial), held = try await a.attached(sessionID: "s")
        XCTAssertEqual(merged, live); XCTAssertEqual(held.count, 1)
    }
    func testAVDAliasCannotAttachBesideItsLiveSerial() async throws {
        let a = attachments(), service = Devices20Service([Self.row("android:emulator-5580", avd: "Scratch"), Self.row("avd:Scratch", state: "shutdown", avd: "Scratch")])
        _ = try await a.attach(sessionID: "s", deviceID: "android:emulator-5580", service: service)
        do { _ = try await a.attach(sessionID: "s", deviceID: "avd:Scratch", slot: 1, service: service); XCTFail("Duplicate AVD") } catch {}
        let held = try await a.attached(sessionID: "s"); XCTAssertEqual(held.count, 1)
    }
    func testDeviceDyingDuringOpenIsClearedOnThatCall() async throws {
        let a = attachments(), id = "android:emulator-5580", service = Devices20Service([Self.row("android:emulator-5580")])
        let ticket = try await a.attach(sessionID: "s", deviceID: id, service: service)
        let scoped = BackendUIGSessionSimulatorDeviceService(base: service, attachments: a, ticket: ticket)
        await service.die()
        do { _ = try await scoped.open(id); XCTFail("Expected exit") } catch {}
        let held = try await a.attached(sessionID: "s"); XCTAssertTrue(held.isEmpty)
    }
    func testCachedAndroidRowIsRemovedWhenADBAndProcessNoLongerSeeIt() async throws {
        let row = Self.row("android:emulator-5580", avd: "Scratch"), state = Devices20InventoryState(Self.row("android:emulator-5580", avd: "Scratch"))
        let sources = BackendAppDeviceInventorySources(engineDevices: { await state.rows() }, diskSimulators: { [] }, avds: { ["Scratch"] }, avdName: { _ in "Scratch" }, liveEmulatorIDs: { await state.ids() })
        let inventory = BackendAppDeviceInventory(sources: sources)
        let initial = await inventory.list(); XCTAssertTrue(initial.contains { $0["id"] == row["id"] })
        await state.exit()
        let after = await inventory.list(); XCTAssertEqual(after.map { $0["id"].string }, ["avd:Scratch"])
        XCTAssertEqual(after.first?["canBoot"].bool, true)
    }
    func testDeadProcessWinsOverStaleADBEntry() async {
        let sources = BackendAppDeviceInventorySources(engineDevices: { [Self.row("android:emulator-5580", avd: "Scratch")] }, diskSimulators: { [] }, avds: { ["Scratch"] }, avdName: { _ in "Scratch" }, liveEmulatorIDs: { ["android:emulator-5580"] }, liveAVDs: { [] })
        let rows = await BackendAppDeviceInventory(sources: sources).list()
        XCTAssertEqual(rows.map { $0["id"].string }, ["avd:Scratch"])
    }
    func testDeletedSimulatorCannotSurviveEngineCache() async {
        let sources = BackendAppDeviceInventorySources(engineDevices: { [Self.row("ios:" + "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")] }, diskSimulators: { [] }, avds: { [] }, avdName: { _ in "" }, authoritativeDisk: true)
        let rows = await BackendAppDeviceInventory(sources: sources).list(); XCTAssertTrue(rows.isEmpty)
    }
    func testActivityManagerConfirmationDoesNotDependOnCommandExitCode() async throws {
        let executor = Devices20Commands(start: .init(stdout: "Status: ok\nActivity: com.example.app/.Home\n", exitCode: 1))
        let outcome = try await BackendANDROIDPhoneOpenApp.launchAndroid("com.example.app", serial: "emulator-5580", executable: "/fixture/adb", executor: executor)
        XCTAssertEqual(outcome, "opened com.example.app")
        let calls = await executor.captured(); XCTAssertFalse(calls.flatMap { $0 }.contains("monkey")); XCTAssertTrue(calls[1].contains("com.example.app/.Launcher"))
    }
    func testSlowLaunchAcceptsRedirectedActivityInSamePackage() async throws {
        let executor = Devices20Commands(start: .init(killed: true), foreground: "mResumedActivity: ActivityRecord{abc u0 com.example.app/.SignedInHome t1}")
        let outcome = try await BackendANDROIDPhoneOpenApp.launchAndroid("com.example.app", serial: "emulator-5580", executable: "/fixture/adb", executor: executor)
        XCTAssertEqual(outcome, "opened com.example.app")
    }
    func testUnconfirmedSlowGuestReportsUncertainty() async throws {
        let executor = Devices20Commands(start: .init(stdout: "Starting: Intent\n", killed: true))
        let outcome = try await BackendANDROIDPhoneOpenApp.launchAndroid("com.example.app", serial: "emulator-5580", executable: "/fixture/adb", executor: executor)
        XCTAssertTrue(outcome.contains("may be open")); XCTAssertFalse(outcome.contains("could not be opened"))
    }
    func testMissingLauncherReportsRealFailure() async {
        let executor = Devices20Commands(start: .init(exitCode: 0), resolve: .init(stdout: "No activity found\n", exitCode: 0))
        do { _ = try await BackendANDROIDPhoneOpenApp.launchAndroid("com.example.app", serial: "emulator-5580", executable: "/fixture/adb", executor: executor); XCTFail("No launcher") }
        catch { XCTAssertTrue(String(describing: error).contains("opening screen")) }
    }
    func testUnrelatedForegroundCannotConfirmLaunch() async {
        let executor = Devices20Commands(start: .init(stdout: "Error: Activity not started\n", exitCode: 1), foreground: "mResumedActivity: ActivityRecord{abc u0 com.example.app.other/.Home t1}")
        do { _ = try await BackendANDROIDPhoneOpenApp.launchAndroid("com.example.app", serial: "emulator-5580", executable: "/fixture/adb", executor: executor); XCTFail("Wrong foreground") } catch {}
    }
    func testNewEmulatorFallsBackToSoftwareIfHardwareCannotStart() async throws {
        let sdk = FileManager.default.temporaryDirectory.appendingPathComponent("devices20-sdk-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sdk) }
        for relative in ["emulator/emulator", "platform-tools/adb"] {
            let file = sdk.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let executor = Devices20BootCommands()
        let platform = BackendAppDevicePlatform(environment: ["ANDROID_HOME": sdk.path], home: "/fixture", executor: executor)
        let result = await platform.boot("avd:UnitScratch"), modes = await executor.captured()
        XCTAssertEqual(result["ok"].bool, true); XCTAssertEqual(result["gpu"].string, "swiftshader")
        XCTAssertEqual(modes, ["host", "swiftshader"])
    }
    func testOwnedProcessExitPublishesItsDeviceID() async throws {
        let observed = expectation(description: "Owned process exit"), listener = UUID()
        await BackendAppDeviceLifecycle.shared.observe(listener) { ids in if ids.contains("android:emulator-5588") { observed.fulfill() } }
        let token = try await BackendAppDeviceEmulatorLauncher.shared.launch("/bin/sh", arguments: ["-c", "sleep 0.1"], environment: [:], cwd: "/tmp", avd: "UnitScratch")
        await BackendAppDeviceEmulatorLauncher.shared.identified(token, as: "android:emulator-5588")
        await fulfillment(of: [observed], timeout: 3)
        await BackendAppDeviceLifecycle.shared.remove(listener)
    }
}
