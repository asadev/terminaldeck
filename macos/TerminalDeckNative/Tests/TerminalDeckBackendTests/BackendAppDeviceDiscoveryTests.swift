import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Device discovery (Devices seat, 13 Oct): devices_list from a session answered "this computer has no iOS
// Simulator, no Android emulator…" while 22 simulators and two headless emulators (emulator-5554
// IMATCH_Pixel8, emulator-5556 ASAD_Pixel8) were running. These pin the SDK lookup, adopting running
// emulators without ever starting a second copy, and an empty reason that says what is really missing.

private final class DiscoveryFiles: @unchecked Sendable {
    var executables: Set<String> = []
    var folders: [String: [String]] = [:]
    var texts: [String: String] = [:]
    var links: [String: String] = [:]
    var files: BackendAppDeviceAndroidSDK.Files {
        .init(isExecutable: { [self] in executables.contains($0) }, entries: { [self] in folders[$0] }, read: { [self] in texts[$0] }, resolve: { [self] in links[$0] ?? $0 })
    }
}

private final class DiscoveryExecutor: BackendAppSessionCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var ran: [[String]] = []
    private var started: [[String]] = []
    let answer: @Sendable (String, [String]) -> BackendAppSessionCommandResult
    init(_ answer: @escaping @Sendable (String, [String]) -> BackendAppSessionCommandResult) { self.answer = answer }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        lock.withLock { ran.append([command] + arguments) }; return answer(command, arguments)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { lock.withLock { started.append([command] + arguments) } }
    var commands: [[String]] { lock.withLock { ran } }
    var launches: [[String]] { lock.withLock { started } }
}

private struct DiscoveryDevices: BackendDeckToolsMachinesDeviceService {
    let rows: [NativeRPCValue]
    let why: String?
    private func never() -> NativeRPCError { NativeRPCError(code: "test", message: "not used by this test") }
    func unavailable() async -> String? { nil }
    func list() async throws -> [NativeRPCValue] { rows }
    func emptyReason() async -> String? { why }
    func boot(_ id: String) async throws -> NativeRPCValue { throw never() }
    func shutDown(_ id: String) async throws -> NativeRPCValue { throw never() }
    func open(_ id: String) async throws -> NativeRPCValue { throw never() }
    func screenshot(_ id: String) async throws -> NativeRPCValue { throw never() }
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) async throws { throw never() }
    func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int) async throws { throw never() }
    func type(_ id: String, text: String) async throws { throw never() }
    func key(_ id: String, key: String, modifiers: [String]) async throws { throw never() }
    func button(_ id: String, button: String) async throws { throw never() }
    func rotate(_ id: String, to: String) async throws -> String { throw never() }
    func tree(_ id: String, scope: String) async throws -> BackendDeckToolsMachinesDeviceTreeAnswer { throw never() }
    func rounds() async throws -> [NativeRPCValue] { [] }
}

/// Answers every check, records the question it would put to the person, and declines: nothing is ever run.
private actor DiscoveryDecliningEnvironment: BackendDeckToolsMachinesEnvironment {
    let source: BackendDeckToolsMachinesContext
    var sentences: [String] = []
    var ran = false
    init(_ source: BackendDeckToolsMachinesContext) { self.source = source }
    func context(for call: BackendMCPCallContext) -> BackendDeckToolsMachinesContext { source }
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) throws { try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: arguments) }
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy, operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        sentences.append(policy.sentence); throw NativeRPCError(code: "not-permitted", message: "declined in the test")
    }
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?, loggedArguments: NativeRPCValue, error: any Error) -> BackendMCPToolReply {
        BackendDeckToolsMachinesFactory.failureReply(error)
    }
}

final class BackendAppDeviceDiscoveryTests: XCTestCase, @unchecked Sendable {
    typealias SDK = BackendAppDeviceAndroidSDK
    private let home = "/Users/someone"
    private func row(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendAppDeviceParsing.object(fields) }
    private var imatch: NativeRPCValue { BackendAppDeviceRunningEmulators.adoptedRow(serial: "emulator-5554", avd: "IMATCH_Pixel8") }
    private var asad: NativeRPCValue { BackendAppDeviceRunningEmulators.adoptedRow(serial: "emulator-5556", avd: "ASAD_Pixel8") }
    private let udid = "AE0835B7-3AC6-467D-AB49-EF48CE064D22"
    private var simulator: NativeRPCValue { row([("id", .string("ios:" + udid)), ("platform", .string("ios")), ("kind", .string("simulator")), ("state", .string("shutdown")), ("available", .bool(false)), ("name", .string("iPhone 17 Pro")), ("canBoot", .bool(true))]) }
    private var offAVD: NativeRPCValue { row([("id", .string("avd:Pixel_8_API_36")), ("platform", .string("android")), ("kind", .string("emulator")), ("state", .string("shutdown")), ("available", .bool(false)), ("name", .string("Pixel 8 API 36")), ("avd", .string("Pixel_8_API_36")), ("canBoot", .bool(true))]) }

    // MARK: SDK path resolution

    func testAndroidHomeWinsThenStudioSettingThenDefaultFolder() {
        let fs = DiscoveryFiles(), google = home + "/Library/Application Support/Google"
        fs.executables = ["/sdk/env/platform-tools/adb", "/Volumes/Dev/AndroidSDK/platform-tools/adb", "/Volumes/Dev/AndroidSDK/emulator/emulator", home + "/Library/Android/sdk/platform-tools/adb"]
        fs.folders[google] = ["Chrome", "AndroidStudio2024.3", "AndroidStudio2026.1.4"]
        fs.texts[google + "/AndroidStudio2026.1.4/options/android.sdk.path.xml"] = #"<application><component name="AndroidSdkPathStore"><option name="androidSdkAbsolutePath" value="/Volumes/Dev/AndroidSDK" /></component></application>"#
        fs.texts[google + "/AndroidStudio2024.3/options/other.xml"] = #"<application><component name="PropertiesComponent"><property name="android.sdk.path" value="$USER_HOME$/OldSdk" /></component></application>"#
        XCTAssertEqual(SDK.root(environment: ["ANDROID_HOME": "/sdk/env"], home: home, files: fs.files), "/sdk/env")
        // No ANDROID_HOME (a GUI app never sees the shell's): Android Studio's own setting, newest Studio first.
        XCTAssertEqual(SDK.studioPaths(home: home, files: fs.files), ["/Volumes/Dev/AndroidSDK", home + "/OldSdk"])
        XCTAssertEqual(SDK.root(environment: [:], home: home, files: fs.files), "/Volumes/Dev/AndroidSDK")
        XCTAssertEqual(SDK.tool(SDK.emulator, environment: [:], home: home, files: fs.files), "/Volumes/Dev/AndroidSDK/emulator/emulator")
        // Neither: the default folder Android Studio installs to.
        fs.folders[google] = []
        XCTAssertEqual(SDK.root(environment: [:], home: home, files: fs.files), home + "/Library/Android/sdk")
        XCTAssertEqual(SDK.candidates(environment: ["ANDROID_SDK_ROOT": "~/sdk2"], home: home, files: fs.files).first, home + "/sdk2")
    }
    func testAdbOnPathFindsItsSdkAndNothingAnywhereIsNil() {
        let fs = DiscoveryFiles()
        fs.executables = ["/opt/homebrew/bin/adb"]; fs.links["/opt/homebrew/bin/adb"] = "/opt/homebrew/Caskroom/android-platform-tools/36.0.0/platform-tools/adb"
        let path = ["PATH": "/usr/bin:/opt/homebrew/bin"]
        XCTAssertEqual(SDK.tool(SDK.adb, environment: path, home: home, files: fs.files), "/opt/homebrew/bin/adb")
        XCTAssertEqual(SDK.root(environment: path, home: home, files: fs.files), "/opt/homebrew/Caskroom/android-platform-tools/36.0.0")
        XCTAssertNil(SDK.tool(SDK.emulator, environment: path, home: home, files: fs.files))
        let empty = DiscoveryFiles()
        XCTAssertNil(SDK.root(environment: [:], home: home, files: empty.files)); XCTAssertNil(SDK.tool(SDK.adb, environment: [:], home: home, files: empty.files))
    }
    func testDeviceCommandsAreToldWhereTheSdkIsButNothingSetIsReplaced() {
        let fs = DiscoveryFiles(); fs.executables = [home + "/Library/Android/sdk/platform-tools/adb"]
        let told = SDK.engineEnvironment(["PATH": "/usr/bin"], home: home, files: fs.files)
        XCTAssertEqual(told["ANDROID_HOME"], home + "/Library/Android/sdk"); XCTAssertEqual(told["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"); XCTAssertEqual(told["PATH"], "/usr/bin")
        XCTAssertEqual(told["LC_CTYPE"], "UTF-8")
        let kept = SDK.engineEnvironment(["ANDROID_SDK_ROOT": "/mine"], home: home, files: fs.files)
        XCTAssertNil(kept["ANDROID_HOME"]); XCTAssertEqual(kept["ANDROID_SDK_ROOT"], "/mine")
        XCTAssertTrue(told.keys.allSatisfy { !$0.uppercased().contains("SIM" + "VIEW") })
    }

    // MARK: Ids as people type them

    func testIdsAsTypedResolveToTheListedOnes() {
        let ids = BackendAppDeviceIDs.self
        XCTAssertEqual(ids.normalize("emulator-5554"), "android:emulator-5554"); XCTAssertEqual(ids.normalize(" Android:emulator-5556 "), "android:emulator-5556")
        XCTAssertEqual(ids.normalize(udid.lowercased()), "ios:" + udid); XCTAssertEqual(ids.normalize("ios:" + udid.lowercased()), "ios:" + udid)
        XCTAssertEqual(ids.normalize("avd:IMATCH_Pixel8"), "avd:IMATCH_Pixel8"); XCTAssertEqual(ids.normalize("iPhone 17 Pro"), "iPhone 17 Pro")
        for typed in ["emulator-5554", "android:emulator-5554", "IMATCH_Pixel8", "imatch pixel8", "avd:IMATCH_Pixel8"] { XCTAssertTrue(ids.matches(imatch, typed), typed) }
        for typed in ["emulator-5556", "ASAD_Pixel8", "", "Pixel"] { XCTAssertFalse(ids.matches(imatch, typed), typed) }
        // The tool rules take the same spellings before their own id check.
        XCTAssertEqual(try BackendDeckToolsMachinesDeviceRules.id(.object([.init("deviceId", .string("emulator-5554"))])), "android:emulator-5554")
    }

    // MARK: Running emulators are adopted, never started twice

    func testRunningHeadlessEmulatorsAreReadFromTheProcessList() {
        let ps = """
        /Users/imatch/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd ASAD_Pixel8 -no-boot-anim -no-window -no-snapshot-load
        /Users/imatch/Library/Android/sdk/emulator/crashpad_handler --no-rate-limit --monitor-pid=53571 --annotation=prod=AndroidEmulator
        /Users/imatch/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd IMATCH_Pixel8 -no-boot-anim -no-window
        /Users/imatch/Library/Android/sdk/emulator/emulator @Work_Phone -no-window
        grep -avd Not_An_Emulator
        """
        XCTAssertEqual(BackendAppDeviceRunningEmulators.avds(processList: ps), ["ASAD_Pixel8", "IMATCH_Pixel8", "Work_Phone"])
        XCTAssertEqual(BackendAppDeviceRunningEmulators.avdName(output: "IMATCH_Pixel8\r\nOK\r\n"), "IMATCH_Pixel8")
        XCTAssertEqual(BackendAppDeviceRunningEmulators.avdName(output: "KO: authentication required\n"), "")
        XCTAssertEqual(BackendAppDeviceRunningEmulators.avdName(output: "OK\n"), ""); XCTAssertEqual(BackendAppDeviceRunningEmulators.avdName(output: "Android Console: type help\n"), "")
        let table = BackendAppDeviceRunningEmulators.serials(adbDevices: "* daemon started\nList of devices attached\nemulator-5554\tdevice\nR58M123\tunauthorized\n\n")
        XCTAssertEqual(table.map(\.serial), ["emulator-5554", "R58M123"]); XCTAssertEqual(table.map(\.state), ["device", "unauthorized"])
    }
    func testInventoryNamesRunningEmulatorsByAvdAndNeverOffersThemAsOff() async {
        let engine = row([("id", .string("android:emulator-5554")), ("platform", .string("android")), ("kind", .string("emulator")), ("state", .string("ready")), ("available", .bool(true)), ("name", .string("sdk_gphone64_arm64"))])
        let inventory = BackendAppDeviceInventory(sources: .init(engineDevices: { [engine] }, diskSimulators: { [] },
            avds: { ["ASAD_Pixel8", "IMATCH_Pixel8", "Pixel_8_API_36"] }, avdName: { $0 == "emulator-5554" ? "IMATCH_Pixel8" : "" },
            runningAVDs: { ["IMATCH_Pixel8", "ASAD_Pixel8"] }), waitMilliseconds: 1_000, clock: BackendAppSessionTestPortClock())
        let list = await inventory.list(), byID = Dictionary(uniqueKeysWithValues: list.map { ($0["id"].string ?? "", $0) })
        XCTAssertEqual(byID["android:emulator-5554"]?["name"].string, "IMATCH Pixel8"); XCTAssertEqual(byID["android:emulator-5554"]?["avd"].string, "IMATCH_Pixel8")
        XCTAssertNil(byID["avd:IMATCH_Pixel8"], "a running emulator offered as off invites a second copy")
        // Running (ps) but not yet seen by the engine: starting, and it cannot be started again.
        XCTAssertEqual(byID["avd:ASAD_Pixel8"]?["state"].string, "booting"); XCTAssertEqual(byID["avd:ASAD_Pixel8"]?["canBoot"].bool, false)
        XCTAssertEqual(byID["avd:Pixel_8_API_36"]?["state"].string, "shutdown"); XCTAssertEqual(byID["avd:Pixel_8_API_36"]?["canBoot"].bool, true)
        let answered = await inventory.engineAnswered; XCTAssertTrue(answered)
    }
    func testEngineFailingFirstStillAdoptsWhatAdbSees() async {
        let inventory = BackendAppDeviceInventory(sources: .init(engineDevices: { nil }, diskSimulators: { [] },
            avds: { ["ASAD_Pixel8", "IMATCH_Pixel8"] }, avdName: { _ in "" }, runningAVDs: { ["IMATCH_Pixel8", "ASAD_Pixel8"] },
            adbEmulators: { [(serial: "emulator-5554", avd: "IMATCH_Pixel8"), (serial: "emulator-5556", avd: "ASAD_Pixel8")] }), waitMilliseconds: 1_000, clock: BackendAppSessionTestPortClock())
        let list = await inventory.list()
        XCTAssertEqual(list.compactMap { $0["id"].string }, ["android:emulator-5556", "android:emulator-5554"])
        XCTAssertTrue(list.allSatisfy { $0["state"].string == "ready" && $0["available"].bool == true && $0["checking"].bool == true })
        let answered = await inventory.engineAnswered; XCTAssertFalse(answered)
    }
    func testStartingAnAvdThatIsAlreadyRunningAdoptsItAndLaunchesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for tool in ["platform-tools/adb", "emulator/emulator"] {
            let file = root.appendingPathComponent("sdk").appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let executor = DiscoveryExecutor { command, args in
            if command == "/bin/ps" { return .init(stdout: "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd Busy_AVD -no-window\n", exitCode: 0) }
            if args == ["devices"] { return .init(stdout: "List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n", exitCode: 0) }
            if args == ["-s", "emulator-5554", "emu", "avd", "name"] { return .init(stdout: "IMATCH_Pixel8\nOK\n", exitCode: 0) }
            if args == ["-s", "emulator-5556", "emu", "avd", "name"] { return .init(stderr: "could not connect", exitCode: 1) }
            if args == ["-s", "emulator-5556", "shell", "getprop", "ro.boot.qemu.avd_name"] { return .init(stdout: "ASAD_Pixel8\n", exitCode: 0) }
            return .init(exitCode: 1)
        }
        let platform = BackendAppDevicePlatform(environment: ["ANDROID_HOME": root.appendingPathComponent("sdk").path], home: root.appendingPathComponent("home").path, executor: executor)
        let first = await platform.boot("avd:IMATCH_Pixel8"), second = await platform.boot("avd:ASAD_Pixel8"), busy = await platform.boot("avd:Busy_AVD")
        XCTAssertEqual(first["ok"].bool, true); XCTAssertEqual(first["id"].string, "android:emulator-5554"); XCTAssertEqual(first["adopted"].bool, true)
        XCTAssertEqual(second["id"].string, "android:emulator-5556", "the console needs a token; getprop answers without it")
        XCTAssertEqual(busy["ok"].bool, false); XCTAssertTrue(busy["message"].string?.contains("already running") == true)
        XCTAssertEqual(executor.launches, [], "no emulator may be started, restarted or cold-booted")
        XCTAssertFalse(executor.commands.contains { $0.contains("kill") || $0.contains("-wipe-data") || $0.contains("-no-snapshot-load") })
    }

    // MARK: The empty reason is true

    func testEmptyReasonSaysWhatIsReallyMissing() {
        let none = BackendAppDeviceDiagnosis(simulatorTool: false, simulatorsOnDisk: 0, sdk: nil, adb: false, avds: 0, engineAnswered: true).sentence(home: home)
        XCTAssertTrue(none.contains("Xcode is not installed")); XCTAssertTrue(none.contains("Android Studio’s SDK was not found")); XCTAssertTrue(none.contains("ANDROID_HOME"))
        XCTAssertFalse(none.contains("phone is plugged in"), "without adb a phone cannot be seen, so do not tell them to plug one in")
        let bare = BackendAppDeviceDiagnosis(simulatorTool: true, simulatorsOnDisk: 0, sdk: home + "/Library/Android/sdk", adb: true, avds: 0, engineAnswered: true).sentence(home: home)
        XCTAssertTrue(bare.contains("Xcode is installed but has no iOS Simulator yet")); XCTAssertTrue(bare.contains("~/Library/Android/sdk but no Android emulator has been made yet")); XCTAssertTrue(bare.contains("USB debugging"))
        XCTAssertFalse(bare.contains("not installed")); XCTAssertFalse(bare.contains("did not answer"))
        let slow = BackendAppDeviceDiagnosis(simulatorTool: true, simulatorsOnDisk: 22, sdk: "/sdk", adb: true, avds: 3, engineAnswered: false).sentence(home: home)
        XCTAssertTrue(slow.contains("this Mac has 22 iOS Simulators")); XCTAssertTrue(slow.contains("3 Android emulators are set up")); XCTAssertTrue(slow.contains("did not answer in time"))
        XCTAssertFalse(slow.contains("no iOS Simulator")); XCTAssertFalse(slow.contains("not installed"))
    }
    func testPlatformDiagnosisReadsThisMacsFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("sdk/platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: adb); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let executor = DiscoveryExecutor { command, args in command == "/usr/bin/xcrun" ? .init(stdout: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl\n", exitCode: 0) : .init(exitCode: 1) }
        let platform = BackendAppDevicePlatform(environment: ["ANDROID_HOME": root.appendingPathComponent("sdk").path, "PATH": ""], home: root.appendingPathComponent("home").path, executor: executor)
        let facts = await platform.diagnosis(engineAnswered: true)
        XCTAssertEqual(facts, BackendAppDeviceDiagnosis(simulatorTool: true, simulatorsOnDisk: 0, sdk: root.appendingPathComponent("sdk").path, adb: true, avds: 0, engineAnswered: true))
    }
    func testListUsesTheServicesOwnReasonOnlyWhenNothingIsListed() async throws {
        let context = BackendDeckToolsMachinesPortContext(.session, session: "s1")
        let said = "Xcode is installed but has no iOS Simulator yet (add one in Xcode › Window › Devices and Simulators); the Android SDK is at ~/Library/Android/sdk but no Android emulator has been made yet (Android Studio › Device Manager)."
        let empty = try await BackendDeckToolsMachinesDevices(service: DiscoveryDevices(rows: [], why: said)).run("devices.list", .object([]), context)
        XCTAssertEqual(empty.value["emptyReason"].string, said); XCTAssertEqual(empty.value["empty"], .bool(true))
        let unknown = try await BackendDeckToolsMachinesDevices(service: DiscoveryDevices(rows: [], why: nil)).run("devices.list", .object([]), context)
        XCTAssertFalse(unknown.value["emptyReason"].string?.contains("this computer has no") == true, "never claim the computer has none when nothing checked it")
        let full = try await BackendDeckToolsMachinesDevices(service: DiscoveryDevices(rows: [imatch, asad, simulator], why: said)).run("devices.list", .object([]), context)
        XCTAssertEqual(full.value["emptyReason"].string, ""); XCTAssertEqual(full.value["devices"].elements?.compactMap { $0["id"].string }, ["android:emulator-5554", "android:emulator-5556", "ios:" + udid])
        XCTAssertEqual(full.value["devices"].elements?.first?["avd"].string, "IMATCH_Pixel8")
    }

    // MARK: Live, read only: this Mac's real devices, listed exactly as a session's devices_list lists them

    /// TD_LIVE_DEVICES=1 TD_LIVE_RESOURCES=<an app's Contents/Resources>. Runs the real engine and SDK lookup
    /// with a GUI app's bare environment (no ANDROID_HOME), through the session wrapper with an empty panel.
    /// It only lists: no device is attached, started, stopped or restarted.
    func testLiveSessionListOnThisMac() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TD_LIVE_DEVICES"] == "1", "live device listing runs only when asked for")
        let bare = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        let engine = BackendCompositionDevices.engine(helper: env["TD_LIVE_HELPER"], dataFolder: FileManager.default.temporaryDirectory.appendingPathComponent("td-live-devices"))
        let manager = BackendAppDeviceManager(locate: { engine }, platform: BackendAppDevicePlatform(environment: bare, home: NSHomeDirectory()),
                                              picturesDirectory: { FileManager.default.temporaryDirectory })
        let attachments = BackendUIGSessionSimulatorAttachments(resolveLocalSession: { .init(sessionID: $0, incarnation: "live") })
        let environment = BackendDeckToolsMachinesPortEnvironment(BackendDeckToolsMachinesPortContext(.session, session: "live-session"))
        let tools = try BackendUIGSessionSimulatorMCP(service: BackendAppDeviceToolService(manager: manager), attachments: attachments).definitions(environment: environment)
        let reply = try await XCTUnwrap(tools.first { $0.spec.id == "devices.list" }).handler(BackendDeckToolsMachinesPortNativeContext(), .object([]))
        let value = try XCTUnwrap(reply.structuredContent), rows = value["devices"].elements ?? []
        print("LIVE devices.list: \(rows.count) devices, usable \(value["usable"].compact), inThisPanel \(value["inThisPanel"].compact), emptyReason \(value["emptyReason"].compact)")
        for row in rows where row["state"].string != "off" || row["platform"].string == "android" { print("LIVE   \(row["id"].string ?? "") | \(row["name"].string ?? "") | \(row["state"].string ?? "") | avd \(row["avd"].string ?? "-")") }
        print("LIVE   iOS simulators: \(rows.filter { $0["platform"].string == "ios" }.count)")
        XCTAssertFalse(reply.isError); XCTAssertFalse(rows.isEmpty, value["emptyReason"].string ?? "")
        await manager.closeAll()
    }

    // MARK: devices_open_app picks the running emulator by any spelling (declined here, so nothing runs)

    private func openApp(_ args: [(String, NativeRPCValue)]) async throws -> (reply: BackendMCPToolReply, asked: [String]) {
        let attachments = BackendUIGSessionSimulatorAttachments(resolveLocalSession: { .init(sessionID: $0, incarnation: "first") })
        let environment = DiscoveryDecliningEnvironment(BackendDeckToolsMachinesPortContext(.session, session: "s1"))
        let tool = try XCTUnwrap(BackendANDROIDPhoneOpenApp(service: DiscoveryDevices(rows: [simulator, asad, imatch, offAVD], why: nil), attachments: attachments).definitions(environment: environment).first)
        let reply = try await tool.handler(BackendDeckToolsMachinesPortNativeContext(), .object(args.map { .init($0.0, $0.1) }))
        return (reply, await environment.sentences)
    }
    func testOpenAppAdoptsTheRunningEmulatorByAnySpelling() async throws {
        for typed in ["emulator-5554", "android:emulator-5554", "IMATCH_Pixel8", "avd:IMATCH_Pixel8"] {
            let (_, asked) = try await openApp([("platform", .string("android")), ("deviceId", .string(typed)), ("app", .string("ae.imatch.app"))])
            XCTAssertEqual(asked, ["Show IMATCH Pixel8 in this session’s phone panel and open ae.imatch.app"], typed)
        }
    }
    func testOpenAppNamesAMissingOrWrongPlatformDeviceTruthfully() async throws {
        let missing = try await openApp([("platform", .string("android")), ("deviceId", .string("emulator-5999"))])
        let text = missing.reply.content.compactMap { $0["text"].string }.joined()
        XCTAssertTrue(missing.reply.isError); XCTAssertTrue(text.contains("There is no Android emulator emulator-5999"), text); XCTAssertEqual(missing.asked, [])
        let wrong = try await openApp([("platform", .string("android")), ("deviceId", .string(udid))])
        let said = wrong.reply.content.compactMap { $0["text"].string }.joined()
        XCTAssertTrue(said.contains("platform ios"), said); XCTAssertEqual(wrong.asked, [])
    }
}
