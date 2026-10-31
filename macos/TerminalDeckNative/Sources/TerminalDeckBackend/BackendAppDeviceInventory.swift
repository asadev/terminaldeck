import Foundation
import TerminalDeckNativeCore

public struct BackendAppDeviceDiskSimulator: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtime: String
    public let state: String
    public init(udid: String, name: String, runtime: String, state: String) { self.udid = udid; self.name = name; self.runtime = runtime; self.state = state }
}
public struct BackendAppDeviceInventorySources: Sendable {
    public let engineDevices: @Sendable () async -> [NativeRPCValue]?
    public let diskSimulators: @Sendable () async -> [BackendAppDeviceDiskSimulator]
    public let avds: @Sendable () async -> [String]
    public let avdName: @Sendable (String) async -> String
    /// AVDs whose emulator process is running now (headless ones too), read from the process list.
    public let runningAVDs: @Sendable () async -> Set<String>
    /// Emulators adb sees, serial → AVD name; asked only when the device listing did not answer.
    public let adbEmulators: @Sendable () async -> [(serial: String, avd: String)]
    public let liveEmulatorIDs: @Sendable () async -> Set<String>?
    public let authoritativeDisk: Bool
    public let liveAVDs: @Sendable () async -> Set<String>?
    public init(engineDevices: @escaping @Sendable () async -> [NativeRPCValue]?,
                diskSimulators: @escaping @Sendable () async -> [BackendAppDeviceDiskSimulator],
                avds: @escaping @Sendable () async -> [String], avdName: @escaping @Sendable (String) async -> String,
                runningAVDs: @escaping @Sendable () async -> Set<String> = { [] },
                adbEmulators: @escaping @Sendable () async -> [(serial: String, avd: String)] = { [] },
                liveEmulatorIDs: @escaping @Sendable () async -> Set<String>? = { nil }, authoritativeDisk: Bool = false,
                liveAVDs: @escaping @Sendable () async -> Set<String>? = { nil }) {
        self.engineDevices = engineDevices; self.diskSimulators = diskSimulators; self.avds = avds; self.avdName = avdName
        self.runningAVDs = runningAVDs; self.adbEmulators = adbEmulators
        self.liveEmulatorIDs = liveEmulatorIDs; self.authoritativeDisk = authoritativeDisk; self.liveAVDs = liveAVDs
    }
}
public enum BackendAppDeviceInventoryParsing {
    public static func plainRuntime(_ runtime: String) -> String {
        let re = try! NSRegularExpression(pattern: #"SimRuntime\.([A-Za-z]+)-(\d+)-(\d+)"#)
        guard let m = re.firstMatch(in: runtime, range: NSRange(runtime.startIndex..., in: runtime)) else { return runtime }
        func group(_ n: Int) -> String { String(runtime[Range(m.range(at: n), in: runtime)!]) }
        return "\(group(1)) \(group(2)).\(group(3))"
    }
    public static func stateWords(_ state: String) -> String {
        switch state {
        case "ready": "running"
        case "booting": "starting"
        case "shutdown": "off"
        case "unauthorized": "waiting for you to allow this computer on the phone"
        case "offline": "not answering"
        default: "unknown"
        }
    }
    public static func engineDevice(_ raw: NativeRPCValue) -> NativeRPCValue? {
        guard raw.fields != nil, let id = raw["id"].string, !id.isEmpty,
              let platform = raw["platform"].string, ["ios", "android"].contains(platform) else { return nil }
        let kind = ["simulator", "emulator", "physical"].contains(raw["kind"].string ?? "") ? raw["kind"].string! : "physical"
        let state = ["ready", "booting", "offline", "unauthorized", "shutdown", "unknown"].contains(raw["state"].string ?? "") ? raw["state"].string! : "unknown"
        let input = raw["capabilities"]["input"], virtual = kind != "physical"
        return BackendAppDeviceParsing.object([("id", .string(id)), ("platform", .string(platform)), ("kind", .string(kind)), ("state", .string(state)),
            ("available", .bool(raw["available"].bool == true)), ("name", .string(raw["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? id)),
            ("runtime", .string(plainRuntime(raw["runtime"].string ?? ""))), ("canBoot", .bool(virtual && state == "shutdown")),
            ("canShutDown", .bool(virtual && ["ready", "booting"].contains(state))), ("buttons", .array(BackendAppDeviceParsing.strings(input["buttons"]).map(NativeRPCValue.string))),
            ("keys", .array(BackendAppDeviceParsing.strings(input["keys"]).map(NativeRPCValue.string))), ("text", .string(input["text"].string ?? "none")),
            ("canRotate", .bool(raw["capabilities"]["orientation"].bool == true)),
            ("note", .string(state == "unauthorized" ? "Unlock the phone and allow this computer when it asks." : state == "offline" ? "Reconnect the cable, or restart the emulator." : ""))])
    }
    public static func plist(_ xml: String) -> BackendAppDeviceDiskSimulator? {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") else { return nil }
        func match(_ pattern: String, group: Int = 1) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(m.range(at: group), in: xml) else { return nil }
            return String(xml[range])
        }
        func text(_ key: String) -> String {
            let value = match("<key>\(key)</key>\\s*<string>([^<]*)</string>") ?? ""
            let re = try! NSRegularExpression(pattern: "&(amp|lt|gt|quot|apos);")
            let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
            var result = value
            for m in re.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                if let r = Range(m.range, in: value), let g = Range(m.range(at: 1), in: value) { result.replaceSubrange(r, with: entities[String(value[g])] ?? "") }
            }
            return result
        }
        let udid = text("UDID")
        guard udid.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil,
              match(#"<key>isDeleted</key>\s*<true\s*/>"#, group: 0) == nil else { return nil }
        let state = Int(match(#"<key>state</key>\s*<integer>(-?\d+)</integer>"#) ?? "")
        let name = text("name")
        return .init(udid: udid.uppercased(), name: name.isEmpty ? udid : name, runtime: text("runtime"), state: state == 3 ? "ready" : state == 2 ? "booting" : state == 1 ? "shutdown" : "unknown")
    }
    public static func diskEntry(_ sim: BackendAppDeviceDiskSimulator, last: NativeRPCValue? = nil) -> NativeRPCValue {
        let runtime = plainRuntime(sim.runtime)
        return BackendAppDeviceParsing.object([("id", .string("ios:" + sim.udid)), ("platform", .string("ios")), ("kind", .string("simulator")), ("state", .string(sim.state)),
            ("available", .bool(sim.state == "ready")), ("name", .string(sim.name)), ("runtime", .string(runtime.isEmpty ? last?["runtime"].string ?? "" : runtime)),
            ("canBoot", .bool(sim.state == "shutdown")), ("canShutDown", .bool(["ready", "booting"].contains(sim.state))),
            ("buttons", last?["buttons"] ?? .array(["home", "lock", "volume-up", "volume-down", "action"].map(NativeRPCValue.string))),
            ("keys", last?["keys"] ?? .array(["delete", "return", "enter", "tab", "escape", "arrow-up", "arrow-down", "arrow-left", "arrow-right", "select-all"].map(NativeRPCValue.string))),
            ("text", last?["text"] ?? .string("unicode")), ("canRotate", last?["canRotate"] ?? .bool(true)), ("note", .string("")), ("checking", .bool(true))])
    }
}
private final class BackendAppDeviceInventoryRace: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: CheckedContinuation<(rows: [NativeRPCValue]?, late: Bool), Never>?
    init(_ answer: CheckedContinuation<(rows: [NativeRPCValue]?, late: Bool), Never>) { self.answer = answer }
    func finish(_ result: (rows: [NativeRPCValue]?, late: Bool)) {
        lock.lock(); let sink = answer; answer = nil; lock.unlock(); sink?.resume(returning: result)
    }
}
public actor BackendAppDeviceInventory {
    public static let engineWaitMilliseconds = 5_000
    private struct Call { let id: UUID; let work: Task<[NativeRPCValue]?, Never>; var settledAt: Date? }
    private let sources: BackendAppDeviceInventorySources
    private let waitMilliseconds: Int
    private let now: @Sendable () -> Date
    private let clock: any BackendAppSessionClock
    private var call: Call?
    private var lastIOS: [String: NativeRPCValue] = [:]
    private var lastAndroid: [NativeRPCValue] = []
    private var lastRunningAVDs: Set<String> = []
    /// Whether the device listing answered in time (an empty list is explained with it).
    public private(set) var engineAnswered = true
    public init(sources: BackendAppDeviceInventorySources, waitMilliseconds: Int = 5_000, now: (@Sendable () -> Date)? = nil, clock: any BackendAppSessionClock = BackendAppSessionSystemClock()) {
        self.sources = sources; self.waitMilliseconds = waitMilliseconds; self.clock = clock; self.now = now ?? { clock.now() }
    }
    public func forgetPending() { if call?.settledAt != nil { call = nil } }
    private func settled(_ id: UUID) { if call?.id == id { call?.settledAt = now() } }
    private func engineRows() async -> (rows: [NativeRPCValue]?, late: Bool) {
        if let at = call?.settledAt, now().timeIntervalSince(at) > 15 { call = nil }
        if call == nil {
            let id = UUID(), source = sources.engineDevices
            let work = Task { [weak self] in let rows = await source(); await self?.settled(id); return rows }
            call = Call(id: id, work: work, settledAt: nil)
        }
        let current = call!, wait = waitMilliseconds, clock = self.clock
        var pendingTimer: Task<Void, Never>?
        let outcome: (rows: [NativeRPCValue]?, late: Bool) = await withCheckedContinuation { continuation in
            let race = BackendAppDeviceInventoryRace(continuation)
            let timer = Task { do { try await clock.sleep(milliseconds: wait); race.finish((nil, true)) } catch {} }; pendingTimer = timer
            Task { let rows = await current.work.value; timer.cancel(); race.finish((rows, false)) }
        }
        pendingTimer?.cancel(); await pendingTimer?.value
        if !outcome.late, call?.id == current.id { call = nil }
        return outcome
    }
    public func list() async -> [NativeRPCValue] {
        async let disk = sources.diskSimulators()
        async let processes = sources.runningAVDs()
        let engine = await engineRows(), rows = (engine.rows ?? []).compactMap(BackendAppDeviceInventoryParsing.engineDevice)
        let ios = rows.filter { $0["platform"].string == "ios" }, androidRows = rows.filter { $0["platform"].string == "android" }
        let answered = engine.rows != nil
        engineAnswered = answered
        var devicesIOS: [NativeRPCValue]
        if answered, !ios.isEmpty {
            devicesIOS = ios
            for row in ios { lastIOS[row["id"].string!] = row }
        } else { devicesIOS = (await disk).map { BackendAppDeviceInventoryParsing.diskEntry($0, last: lastIOS["ios:" + $0.udid]) } }
        let alive = await processes
        var android: [NativeRPCValue], running = Set<String>()
        if answered {
            android = androidRows
            for i in android.indices where android[i]["kind"].string == "emulator" {
                let id = android[i]["id"].string ?? "", serial = String(id.dropFirst("android:".count))
                let previous = lastAndroid.first { $0["id"].string == id }?["avd"].string
                let avd: String
                if let previous, alive.contains(previous) { avd = previous }
                else { let found = await sources.avdName(serial); avd = found.isEmpty ? previous ?? "" : found }
                if !avd.isEmpty {
                    running.insert(avd); android[i] = android[i].setting("avd", .string(avd))
                    let name = android[i]["name"].string ?? ""
                    // adb names it by serial or by model ("sdk_gphone64_arm64"): show the AVD the way off ones are shown.
                    if name == serial || name == avd || name.hasPrefix("sdk_g") { android[i] = android[i].setting("name", .string(avd.replacingOccurrences(of: "_", with: " "))) }
                }
            }
            lastAndroid = android; lastRunningAVDs = running
        } else if !lastAndroid.isEmpty { android = lastAndroid.map { $0.setting("checking", .bool(true)) }; running = lastRunningAVDs }
        else {
            // The listing is slow or failed and nothing was seen before: adopt what adb already sees, as it is.
            android = []
            for found in await sources.adbEmulators() {
                android.append(BackendAppDeviceRunningEmulators.adoptedRow(serial: found.serial, avd: found.avd))
                if !found.avd.isEmpty { running.insert(found.avd) }
            }
        }
        // A running emulator is never offered as "off, can start": that would start a second copy of it.
        let verifiedAVDs = await sources.liveAVDs()
        if let ids = await sources.liveEmulatorIDs() {
            android.removeAll { row in
                guard row["kind"].string == "emulator", let id = row["id"].string, id.hasPrefix("android:emulator-") else { return false }
                if let verifiedAVDs, let avd = row["avd"].string, !avd.isEmpty { return !verifiedAVDs.contains(avd) }
                return !ids.contains(id) && !alive.contains(row["avd"].string ?? "")
            }
            running = Set(android.compactMap { $0["avd"].string })
            lastAndroid = android; lastRunningAVDs = running
        }
        if sources.authoritativeDisk {
            devicesIOS = (await disk).map { sim in
                let previous = devicesIOS.first { $0["id"].string == "ios:" + sim.udid }
                return BackendAppDeviceInventoryParsing.diskEntry(sim, last: previous)
                    .setting("checking", .bool(!answered))
            }
        }
        for name in await sources.avds() where !running.contains(name) {
            let starting = alive.contains(name)
            var entry = BackendAppDeviceParsing.object([("id", .string("avd:" + name)), ("platform", .string("android")), ("kind", .string("emulator")), ("state", .string(starting ? "booting" : "shutdown")),
                ("available", .bool(false)), ("name", .string(name.replacingOccurrences(of: "_", with: " "))), ("avd", .string(name)), ("runtime", .string("")), ("canBoot", .bool(!starting)), ("canShutDown", .bool(false)),
                ("buttons", .array([])), ("keys", .array([])), ("text", .string("none")), ("canRotate", .bool(false)),
                ("note", .string(starting ? "It is running on this Mac but adb does not see it yet. It is listed again with its own id once adb does; it is never started twice." : ""))])
            if !answered { entry = entry.setting("checking", .bool(true)) }; android.append(entry)
        }
        func rank(_ row: NativeRPCValue) -> Int { row["available"].bool == true ? 0 : row["state"].string == "booting" ? 1 : 2 }
        return (devicesIOS + android).sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0["platform"].string != $1["platform"].string { return ($0["platform"].string ?? "") < ($1["platform"].string ?? "") }
            return ($0["name"].string ?? "").localizedCompare($1["name"].string ?? "") == .orderedAscending
        }
    }
}
/// Actual inventory and platform commands. The caller passes the user's home
/// and login PATH; construction performs no process or filesystem effect.
public struct BackendAppDevicePlatform: Sendable {
    public let environment: [String: String]
    public let home: String
    public let executor: any BackendAppSessionCommandExecuting
    /// How long past its own limit a device command is still waited for (BackendAppDeviceDeadline).
    public let commandGraceMilliseconds: Int
    public init(environment: [String: String], home: String, executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                commandGraceMilliseconds: Int = BackendAppDeviceDeadline.commandGraceMilliseconds) {
        self.environment = environment; self.home = home; self.executor = executor; self.commandGraceMilliseconds = commandGraceMilliseconds
    }
    /// Every device command (the device list's adb, ps and emulator calls, boot, shut down, the device tools) ends for its
    /// caller by its own limit plus a grace, even when the child's end is never reported (devices freeze, 26 Oct:
    /// an `adb devices` left unreaped held the device list, and with it every device tool, until a restart).
    func run(_ command: String, _ args: [String], _ timeout: Int, extra: [String: String] = [:]) async -> BackendAppSessionCommandResult {
        await BackendAppDeviceDeadline.command(executor, command, arguments: args, environment: deviceEnvironment.merging(extra) { _, new in new },
                                               cwd: home, timeoutMilliseconds: timeout, maximumBytes: 16 * 1024 * 1024,
                                               graceMilliseconds: commandGraceMilliseconds)
    }
    /// The environment every device command gets: the login one, plus where adb and the SDK
    /// are when the login environment does not say (a GUI app never sees the shell's ANDROID_HOME).
    public var deviceEnvironment: [String: String] { BackendAppDeviceAndroidSDK.engineEnvironment(environment, home: home) }
    /// The Android SDK folder: ANDROID_HOME, ANDROID_SDK_ROOT, Android Studio's own setting, the default folder, Homebrew, PATH.
    public func androidSDK() -> String? { BackendAppDeviceAndroidSDK.root(environment: environment, home: home) }
    func tool(_ relative: String) -> String? { BackendAppDeviceAndroidSDK.tool(relative, environment: environment, home: home) }
    public func diskSimulators(folder: String? = nil,
        entries: @Sendable (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
        contents: @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [BackendAppDeviceDiskSimulator] {
        let root = URL(fileURLWithPath: folder ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/CoreSimulator/Devices").path)
        return (entries(root.path) ?? []).filter { $0.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil }.compactMap {
            guard let xml = contents(root.appendingPathComponent($0).appendingPathComponent("device.plist").path) else { return nil }
            return BackendAppDeviceInventoryParsing.plist(xml)
        }
    }
    public func avds() async -> [String] {
        if let emulator = tool("emulator/emulator") {
            let out = await run(emulator, ["-list-avds"], 10_000)
            if out.ok { return out.stdout.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil } }
        }
        let folder = URL(fileURLWithPath: home).appendingPathComponent(".android/avd").path
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }
    }
    /// The AVD a running emulator was started from. The emulator console (`adb emu avd name`) needs the console
    /// token in this user's home; the system property answers without it. Both only read.
    public func avdName(_ serial: String) async -> String {
        guard let adb = tool("platform-tools/adb") else { return "" }
        let console = await run(adb, ["-s", serial, "emu", "avd", "name"], 5_000)
        if console.ok { let name = BackendAppDeviceRunningEmulators.avdName(output: console.stdout); if !name.isEmpty { return name } }
        for property in ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"] {
            let out = await run(adb, ["-s", serial, "shell", "getprop", property], 5_000)
            if out.ok { let name = BackendAppDeviceRunningEmulators.avdName(output: out.stdout); if !name.isEmpty { return name } }
        }
        return ""
    }
    /// AVDs with an emulator process running now, headless ones included (`ps`, read only).
    public func runningAVDs() async -> Set<String> {
        let out = await run("/bin/ps", ["-axo", "command="], 5_000)
        return out.ok ? BackendAppDeviceRunningEmulators.avds(processList: out.stdout) : []
    }
    /// Emulators adb sees and answers for ("device"), each with its AVD name.
    public func adbEmulators() async -> [(serial: String, avd: String)] {
        guard let adb = tool("platform-tools/adb") else { return [] }
        let out = await run(adb, ["devices"], 5_000)
        var found: [(serial: String, avd: String)] = []
        for row in BackendAppDeviceRunningEmulators.serials(adbDevices: out.stdout) where row.serial.hasPrefix("emulator-") && row.state == "device" {
            let name = await avdName(row.serial); found.append((row.serial, name))
        }
        return found
    }
    /// The running emulator started from this AVD, if there is one: its adb serial.
    public func runningSerial(avd: String) async -> String? {
        for found in await adbEmulators() where found.avd == avd { return found.serial }
        return nil
    }
    public func sources(engine: BackendAppDeviceEngine) -> BackendAppDeviceInventorySources {
        .init(engineDevices: {
            // Terminal Deck's own listing: Android devices as adb sees them (iOS Simulators come from CoreSimulator's
            // own device folders, the disk listing below). No adb on this Mac: no Android device, and that is an answer.
            guard let adb = tool("platform-tools/adb") else { return [] }
            let out = await run(adb, ["devices", "-l"], 8_000)
            guard out.ok else { return nil }
            return BackendAppDeviceAndroidParsing.devices(out.stdout).map(BackendAppDeviceAndroidParsing.row)
        }, diskSimulators: { diskSimulators() }, avds: { await avds() }, avdName: { await avdName($0) },
           runningAVDs: { await runningAVDs() }, adbEmulators: { await adbEmulators() },
           liveEmulatorIDs: {
               guard let adb = tool("platform-tools/adb") else { return nil }
               let out = await run(adb, ["devices"], 5_000)
               guard out.ok else { return nil }
               return Set(BackendAppDeviceRunningEmulators.serials(adbDevices: out.stdout)
                   .filter { $0.serial.hasPrefix("emulator-") }.map { "android:" + $0.serial })
           }, authoritativeDisk: true, liveAVDs: {
               let out = await run("/bin/ps", ["-axo", "command="], 5_000)
               return out.ok ? BackendAppDeviceRunningEmulators.avds(processList: out.stdout) : nil
           })
    }
    /// Why nothing is listed, from what is really on this Mac (asked only when a list comes back empty).
    public func diagnosis(engineAnswered: Bool) async -> BackendAppDeviceDiagnosis {
        let simctl = await run("/usr/bin/xcrun", ["--find", "simctl"], 10_000)
        let avdCount = await avds().count
        return .init(simulatorTool: simctl.ok && !simctl.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     simulatorsOnDisk: diskSimulators().count, sdk: androidSDK(), adb: tool("platform-tools/adb") != nil,
                     avds: avdCount, engineAnswered: engineAnswered)
    }
    private func serials(_ adb: String) async -> [String] {
        let out = await run(adb, ["devices"], 5_000)
        return out.stdout.components(separatedBy: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }.filter { $0.hasPrefix("emulator-") }
    }
    private func until(budget: Int, interval: Int, check: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(budget) / 1000)
        while Date() < deadline, !Task.isCancelled {
            if await check() { return true }; try? await Task.sleep(for: .milliseconds(interval))
        }
        return false
    }
    public func boot(_ id: String, coldStart: Bool = false, afterShutdownID: String? = nil) async -> NativeRPCValue {
        func failure(_ message: String) -> NativeRPCValue { BackendAppDeviceParsing.object([("ok", .bool(false)), ("message", .string(message))]) }
        if id.hasPrefix("ios:") {
            let udid = String(id.dropFirst(4)), out = await run("xcrun", ["simctl", "boot", udid], 120_000)
            if !out.ok, out.stderr.range(of: "current state: Booted", options: .caseInsensitive) == nil {
                return failure(firstLine(out.stderr).isEmpty ? "The simulator would not start." : firstLine(out.stderr))
            }
            let ready = await run("xcrun", ["simctl", "bootstatus", udid, "-b"], 240_000)
            return ready.ok ? BackendAppDeviceParsing.object([("ok", .bool(true)), ("id", .string(id))]) : failure("The simulator started but did not finish booting.")
        }
        if id.hasPrefix("avd:") {
            guard let emulator = tool("emulator/emulator"), let adb = tool("platform-tools/adb") else { return failure("Android Studio’s emulator is not installed on this Mac.") }
            if let afterShutdownID {
                guard afterShutdownID.hasPrefix("android:emulator-") else { return failure("The stopped emulator could not be identified.") }
                let old = String(afterShutdownID.dropFirst(8))
                let gone = await until(budget: 30_000, interval: 200) { !(await serials(adb)).contains(old) }
                guard gone else { return failure("The old emulator has not finished shutting down. Try again once it is off.") }
            }
            guard !Task.isCancelled else { return failure("Starting the emulator was cancelled.") }
            // Already running (headless ones too): adopt it exactly as it is. Never a second copy, never a restart.
            let avd = String(id.dropFirst(4))
            if let serial = await runningSerial(avd: avd) { return BackendAppDeviceParsing.object([("ok", .bool(true)), ("id", .string("android:" + serial)), ("adopted", .bool(true))]) }
            if afterShutdownID == nil, await runningAVDs().contains(avd) {
                return failure("\(avd.replacingOccurrences(of: "_", with: " ")) is already running on this Mac but adb does not see it yet. Wait a moment and list devices again; it was not started a second time.")
            }
            let before = Set(await serials(adb))
            // Explicit host works headless on Apple silicon; auto selects software with -no-window.
            // Only a process started by this call may fall back. Existing emulators are adopted above.
            for mode in ["host", "swiftshader"] {
                var token: UUID?
                let arguments = ["-avd", avd, "-no-boot-anim", "-no-window", "-gpu", mode] + (coldStart ? ["-no-snapshot-load"] : [])
                do {
                    if executor is BackendAppSessionCommandExecutor {
                        token = try await BackendAppDeviceEmulatorLauncher.shared.launch(emulator, arguments: arguments, environment: deviceEnvironment, cwd: home, avd: avd)
                    } else { try await executor.detach(emulator, arguments: arguments, environment: deviceEnvironment, cwd: home) }
                } catch { if mode == "host" { continue }; return failure("The emulator did not start.") }
                let appeared = BackendAppDeviceBootSerial()
                let ownedToken = token
                _ = await until(budget: 90_000, interval: 1_000) {
                    if let ownedToken, !(await BackendAppDeviceEmulatorLauncher.shared.isRunning(ownedToken)) { return true }
                    // Match the AVD, so an unrelated emulator starting at the same time is never adopted.
                    let serial: String
                    if executor is BackendAppSessionCommandExecutor { serial = await runningSerial(avd: avd) ?? "" }
                    else { serial = (await serials(adb)).first { !before.contains($0) } ?? "" }
                    await appeared.set(serial); return !serial.isEmpty
                }
                if let token, !(await BackendAppDeviceEmulatorLauncher.shared.isRunning(token)) { continue }
                let serial = await appeared.value
                guard !serial.isEmpty else { return failure("The emulator is still starting. List devices again before trying to open it.") }
                if let token { await BackendAppDeviceEmulatorLauncher.shared.identified(token, as: "android:" + serial) }
                var exited = false
                let ready = await until(budget: 240_000, interval: 2_000) {
                    if let ownedToken, !(await BackendAppDeviceEmulatorLauncher.shared.isRunning(ownedToken)) { return true }
                    let out = await run(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"], 5_000)
                    return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                }
                if let token { exited = !(await BackendAppDeviceEmulatorLauncher.shared.isRunning(token)) }
                if exited { continue }
                return ready ? BackendAppDeviceParsing.object([("ok", .bool(true)), ("id", .string("android:" + serial)), ("gpu", .string(mode))]) : failure("The emulator started but did not finish booting. It is still running; list devices before trying again.")
            }
            await BackendAppDeviceLifecycle.shared.exited([id])
            return failure("The emulator exited before it finished starting with hardware or software graphics.")
        }
        return failure("That device cannot be started from here.")
    }
    public func shutDown(_ id: String) async -> NativeRPCValue {
        func result(_ ok: Bool, _ message: String) -> NativeRPCValue { ok ? BackendAppDeviceParsing.object([("ok", .bool(true))]) : BackendAppDeviceParsing.object([("ok", .bool(false)), ("message", .string(message))]) }
        if id.hasPrefix("ios:") {
            let out = await run("xcrun", ["simctl", "shutdown", String(id.dropFirst(4))], 60_000)
            return result(out.ok || out.stderr.range(of: "current state: Shutdown", options: .caseInsensitive) != nil, firstLine(out.stderr).isEmpty ? "The simulator would not shut down." : firstLine(out.stderr))
        }
        if id.hasPrefix("android:emulator-") {
            guard let adb = tool("platform-tools/adb") else { return result(false, "adb is not installed on this Mac.") }
            let out = await run(adb, ["-s", String(id.dropFirst(8)), "emu", "kill"], 20_000); return result(out.ok, "The emulator would not shut down.")
        }
        return result(false, "A phone on a cable is turned off on the phone itself.")
    }
    private func firstLine(_ text: String) -> String { String((text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
}
private actor BackendAppDeviceBootSerial { var value = ""; func set(_ value: String) { self.value = value } }
