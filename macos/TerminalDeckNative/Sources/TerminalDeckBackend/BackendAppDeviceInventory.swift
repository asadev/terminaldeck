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
    public init(engineDevices: @escaping @Sendable () async -> [NativeRPCValue]?,
                diskSimulators: @escaping @Sendable () async -> [BackendAppDeviceDiskSimulator],
                avds: @escaping @Sendable () async -> [String], avdName: @escaping @Sendable (String) async -> String) {
        self.engineDevices = engineDevices; self.diskSimulators = diskSimulators; self.avds = avds; self.avdName = avdName
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
        let engine = await engineRows(), rows = (engine.rows ?? []).compactMap(BackendAppDeviceInventoryParsing.engineDevice)
        let ios = rows.filter { $0["platform"].string == "ios" }, androidRows = rows.filter { $0["platform"].string == "android" }
        let answered = engine.rows != nil
        var devicesIOS: [NativeRPCValue]
        if answered, !ios.isEmpty {
            devicesIOS = ios
            for row in ios { lastIOS[row["id"].string!] = row }
        } else { devicesIOS = (await disk).map { BackendAppDeviceInventoryParsing.diskEntry($0, last: lastIOS["ios:" + $0.udid]) } }
        var android: [NativeRPCValue], running = Set<String>()
        if answered {
            android = androidRows
            for i in android.indices where android[i]["kind"].string == "emulator" {
                let serial = String((android[i]["id"].string ?? "").dropFirst("android:".count)), avd = await sources.avdName(serial)
                if !avd.isEmpty {
                    running.insert(avd)
                    if android[i]["name"].string == serial { android[i] = android[i].setting("name", .string(avd.replacingOccurrences(of: "_", with: " "))) }
                }
            }
            lastAndroid = android; lastRunningAVDs = running
        } else { android = lastAndroid.map { $0.setting("checking", .bool(true)) }; running = lastRunningAVDs }
        for name in await sources.avds() where !running.contains(name) {
            var entry = BackendAppDeviceParsing.object([("id", .string("avd:" + name)), ("platform", .string("android")), ("kind", .string("emulator")), ("state", .string("shutdown")),
                ("available", .bool(false)), ("name", .string(name.replacingOccurrences(of: "_", with: " "))), ("runtime", .string("")), ("canBoot", .bool(true)), ("canShutDown", .bool(false)),
                ("buttons", .array([])), ("keys", .array([])), ("text", .string("none")), ("canRotate", .bool(false)), ("note", .string(""))])
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
/// Actual inventory and platform commands. The caller passes the user's home,
/// login PATH and engine; construction performs no process or filesystem effect.
public struct BackendAppDevicePlatform: Sendable {
    public let environment: [String: String]
    public let home: String
    public let executor: any BackendAppSessionCommandExecuting
    public init(environment: [String: String], home: String, executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor()) {
        self.environment = environment; self.home = home; self.executor = executor
    }
    private func run(_ command: String, _ args: [String], _ timeout: Int, extra: [String: String] = [:]) async -> BackendAppSessionCommandResult {
        await executor.run(command, arguments: args, environment: environment.merging(extra) { _, new in new }, cwd: home, timeoutMilliseconds: timeout, maximumBytes: 16 * 1024 * 1024)
    }
    public func androidSDK() -> String? {
        [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], URL(fileURLWithPath: home).appendingPathComponent("Library/Android/sdk").path].compactMap { $0 }.first { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }
    private func tool(_ relative: String) -> String? {
        guard let sdk = androidSDK() else { return nil }; let path = URL(fileURLWithPath: sdk).appendingPathComponent(relative).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
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
    public func avdName(_ serial: String) async -> String {
        guard let adb = tool("platform-tools/adb") else { return "" }
        let out = await run(adb, ["-s", serial, "emu", "avd", "name"], 5_000)
        return out.ok ? (out.stdout.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    public func sources(engine: BackendAppDeviceEngine) -> BackendAppDeviceInventorySources {
        .init(engineDevices: {
            let out = await run(engine.core, ["devices"], 20_000, extra: engine.environment)
            guard out.ok, let parsed = try? NativeRPCValue.parseJSON(Data(out.stdout.utf8)) else { return nil }
            return parsed.elements
        }, diskSimulators: { diskSimulators() }, avds: { await avds() }, avdName: { await avdName($0) })
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
    public func boot(_ id: String) async -> NativeRPCValue {
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
            let before = Set(await serials(adb))
            do { try await executor.detach(emulator, arguments: ["-avd", String(id.dropFirst(4)), "-no-boot-anim", "-no-window"], environment: environment, cwd: home) }
            catch { return failure("The emulator did not start.") }
            // Value kept inside a Sendable actor because boot conditions cross suspension.
            let appeared = BackendAppDeviceBootSerial()
            let starts = await until(budget: 90_000, interval: 1_000) {
                let serial = (await serials(adb)).first { !before.contains($0) } ?? ""
                await appeared.set(serial); return !serial.isEmpty
            }
            guard starts else { return failure("The emulator did not start.") }
            let serial = await appeared.value
            let ready = await until(budget: 240_000, interval: 2_000) {
                let out = await run(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"], 5_000)
                return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            }
            return ready ? BackendAppDeviceParsing.object([("ok", .bool(true)), ("id", .string("android:" + serial))]) : failure("The emulator started but did not finish booting.")
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
