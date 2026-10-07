import Foundation
import TerminalDeckNativeCore

public enum BackendOSPowerRules {
    static func firstLine(_ text: String) -> String { text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    public struct Battery: Equatable, Sendable {
        public let present: Bool, discharging: Bool
        public let percent: Int?
        public init(present: Bool, discharging: Bool, percent: Int?) { self.present = present; self.discharging = discharging; self.percent = percent }
        public var wireValue: NativeRPCValue { .object([.init("present", .bool(present)), .init("discharging", .bool(discharging)), .init("percent", percent.map { .number(Double($0)) } ?? .null)]) }
    }
    public static func sleepDisabled(_ text: String) -> Bool? {
        guard let match = BackendUsageIO.matches("(?m)^\\s*SleepDisabled\\s+(\\S+)\\s*$", text).first, let raw = BackendUsageIO.group(match, 1, text) else { return nil }
        return ["1", "true", "yes"].contains(raw.lowercased())
    }
    public static func registrySleepDisabled(_ text: String) -> Bool? {
        guard let match = BackendUsageIO.matches("\"SleepDisabled\"\\s*=\\s*(\\w+)", text).first, let raw = BackendUsageIO.group(match, 1, text) else { return nil }
        return ["1", "true", "yes"].contains(raw.lowercased())
    }
    public static func battery(_ text: String) -> Battery {
        let present = !BackendUsageIO.matches("present:\\s*true", text, insensitive: true).isEmpty
        let drawing = BackendUsageIO.matches("Now drawing from '([^']+)'", text).first.flatMap { BackendUsageIO.group($0, 1, text) } ?? ""
        let percent = BackendUsageIO.matches("(\\d{1,3})%", text).first.flatMap { BackendUsageIO.group($0, 1, text).flatMap(Int.init) }.map { min(100, $0) }
        return Battery(present: present, discharging: present && drawing.localizedCaseInsensitiveContains("battery power"), percent: percent)
    }
    public static func warning(_ battery: Battery?, hasLid: Bool) -> String? {
        guard let battery, battery.present, battery.discharging else { return nil }
        let place = hasLid ? "with the lid shut" : "awake"
        guard let percent = battery.percent else { return "This machine is running on battery and is being kept \(place). Nothing will let it sleep to save power." }
        if percent > 20 { return "On battery at \(percent)%, and being kept \(place) — it will drain faster than usual." }
        return "Battery is at \(percent)% and this machine is being kept \(place). Plug it in, or turn this off."
    }
    public static func appleScriptLiteral(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    public static func changeScript(on: Bool) -> String { "do shell script " + appleScriptLiteral("/usr/bin/pmset -a disablesleep \(on ? 1 : 0)") + " with administrator privileges" }
    public static func cancelled(_ stderr: String) -> Bool { !BackendUsageIO.matches("-128\\b", stderr).isEmpty || stderr.localizedCaseInsensitiveContains("user canceled") }
}

/// Bind to the existing App NativeOSBridge's assertion table and IOPS source.
/// No second assertion owner or duplicate power monitor is created here.
public struct BackendOSPowerBindings: Sendable {
    public let startIdleBlocker: @Sendable () async throws -> Int
    public let isIdleBlockerStarted: @Sendable (Int) async -> Bool
    public let stopIdleBlocker: @Sendable (Int) async throws -> Void
    /// Native IOPS emits battery-capacity changes as well as source changes,
    /// replacing Electron's narrowly gated two-minute fallback poll.
    public let observePower: @Sendable (@escaping @Sendable () async -> Void) async throws -> (@Sendable () async -> Void)
    public let notify: @Sendable (String, String) async throws -> Void
    public init(startIdleBlocker: @escaping @Sendable () async throws -> Int, isIdleBlockerStarted: @escaping @Sendable (Int) async -> Bool,
                stopIdleBlocker: @escaping @Sendable (Int) async throws -> Void,
                observePower: @escaping @Sendable (@escaping @Sendable () async -> Void) async throws -> (@Sendable () async -> Void),
                notify: @escaping @Sendable (String, String) async throws -> Void) {
        self.startIdleBlocker = startIdleBlocker; self.isIdleBlockerStarted = isIdleBlockerStarted; self.stopIdleBlocker = stopIdleBlocker
        self.observePower = observePower; self.notify = notify
    }
}
public actor BackendOSPowerControl {
    public static let channels: Set<String> = ["power:lid-awake:get", "power:lid-awake:set"]
    private let power: BackendOSPowerBindings
    private let executor: any BackendOSCommandRunning
    private let home: String
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    private let push: @Sendable (String, NativeRPCValue) async -> Void
    private var blocker: Int?, unsubscribe: (@Sendable () async -> Void)?
    private var preexisting = false, lastKnownOn = false, warned = false, initialRead = true
    private var started = false, generation = 0
    private var last: NativeRPCValue = .null, failures: [String] = []
    private var refreshing: Task<NativeRPCValue, any Error>?
    private var holding: Task<Int?, Never>?
    public init(power: BackendOSPowerBindings, executor: any BackendOSCommandRunning, home: String,
                authorizeChange: @escaping @Sendable (NativeRPCContext) throws -> Void,
                push: @escaping @Sendable (String, NativeRPCValue) async -> Void) {
        self.power = power; self.executor = executor; self.home = home; authorize = authorizeChange; self.push = push
    }
    private struct Reading: Sendable { let on: Bool, known: Bool; let battery: BackendOSPowerRules.Battery?; let detail: String? }
    private func run(_ command: String, _ arguments: [String], timeout: Int = 5000) async throws -> BackendGitOutcome {
        try await executor.run(command: command, arguments: arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "LANG": "en_US.UTF-8"], cwd: home, timeoutMilliseconds: timeout, maximumBytes: 1_048_576)
    }
    private func read() async -> Reading {
        do {
            async let settings = run("/usr/bin/pmset", ["-g"])
            async let battery = run("/usr/bin/pmset", ["-g", "batt"])
            let outputs = try await (settings, battery), batt = outputs.1.ok ? BackendOSPowerRules.battery(outputs.1.stdout) : nil
            guard outputs.0.ok else { let first = BackendOSPowerRules.firstLine(outputs.0.stderr); return Reading(on: false, known: false, battery: batt, detail: "This Mac would not report its power settings: " + (first.isEmpty ? "pmset exited \(outputs.0.exitCode)" : first)) }
            if let value = BackendOSPowerRules.sleepDisabled(outputs.0.stdout) { return Reading(on: value, known: true, battery: batt, detail: nil) }
            let registry = try await run("/usr/sbin/ioreg", ["-n", "IOPMrootDomain", "-r", "-d", "1"])
            if registry.ok {
                let value = BackendOSPowerRules.registrySleepDisabled(registry.stdout)
                if value == true { return Reading(on: true, known: false, battery: batt, detail: "This Mac is being held awake according to the kernel, but pmset did not list the setting — so the app cannot say whether turning it off here would work.") }
                return Reading(on: false, known: true, battery: batt, detail: nil)
            }
            return Reading(on: false, known: false, battery: batt, detail: "pmset did not list the sleep setting, and the app could not confirm it another way.")
        } catch { return Reading(on: false, known: false, battery: nil, detail: "This Mac's power settings could not be read: " + error.localizedDescription) }
    }
    private func hold() async {
        if let blocker, await power.isIdleBlockerStarted(blocker) { return }; blocker = nil
        if let holding { let epoch = generation; let id = await holding.value; if epoch == generation && started { blocker = id }; return }
        let epoch = generation, bindings = power
        let work = Task<Int?, Never> {
            do { let id = try await bindings.startIdleBlocker(); return await bindings.isIdleBlockerStarted(id) ? id : nil }
            catch { await self.recordFailure(error.localizedDescription); return nil }
        }
        holding = work
        let id = await work.value; holding = nil
        if epoch == generation && started { blocker = id }
        else if let id { try? await power.stopIdleBlocker(id) }
        if id == nil { failures.append("macOS did not confirm the idle-sleep assertion.") }
        if failures.count > 20 { failures.removeFirst(failures.count - 20) }
    }
    private func recordFailure(_ message: String) { failures.append(message) }
    public func start() async throws {
        guard !started else { return }; started = true; generation += 1
        let epoch = generation
        await hold() // Take the weak idle assertion before the first OS read.
        guard started && epoch == generation else { throw NativeRPCError(code: "unavailable", message: "The native power owner stopped during startup.") }
        do {
            let subscription = try await power.observePower { [weak self] in _ = try? await self?.refresh() }
            guard started && epoch == generation else { await subscription(); throw NativeRPCError(code: "unavailable", message: "The native power owner stopped during observer registration.") }
            unsubscribe = subscription
        } catch { if epoch == generation { started = false; if let blocker { try? await power.stopIdleBlocker(blocker); self.blocker = nil } }; throw error }
        _ = try await refresh()
    }
    public func refresh() async throws -> NativeRPCValue {
        if let refreshing { return try await refreshing.value }
        let epoch = generation
        let work = Task { try await self.readAndPublish(epoch: epoch) }; refreshing = work
        defer { refreshing = nil }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func readAndPublish(epoch: Int) async throws -> NativeRPCValue {
        let reading = await read()
        try Task.checkCancellation()
        guard epoch == generation else { throw NativeRPCError(code: "unavailable", message: "The native power owner stopped during this read.") }
        if initialRead { preexisting = reading.known && reading.on; initialRead = false }
        if reading.known { lastKnownOn = reading.on }
        if started { await hold() }
        try Task.checkCancellation()
        guard epoch == generation else { throw NativeRPCError(code: "unavailable", message: "The native power owner stopped before this read could be published.") }
        let warning = lastKnownOn ? BackendOSPowerRules.warning(reading.battery, hasLid: reading.battery?.present != false) : nil
        last = .object([.init("supported", .bool(true)), .init("platform", .string("darwin")), .init("needsAuthorization", .bool(true)), .init("on", .bool(reading.on)), .init("known", .bool(reading.known)), .init("preexisting", .bool(preexisting)), .init("battery", reading.battery?.wireValue ?? .null), .init("detail", reading.detail.map(NativeRPCValue.string) ?? .null), .init("warning", warning.map(NativeRPCValue.string) ?? .null), .init("idleBlocked", .bool(blocker != nil))])
        let urgent = warning != nil && reading.battery?.discharging == true && (reading.battery?.percent == nil || reading.battery!.percent! <= 20)
        if urgent && !warned { warned = true; do { try await power.notify("This machine is being kept awake", warning ?? "") } catch { failures.append(error.localizedDescription) } }
        else if reading.battery?.discharging != true { warned = false }
        try Task.checkCancellation()
        guard epoch == generation else { throw NativeRPCError(code: "unavailable", message: "The native power owner stopped before state delivery.") }
        await push("power:lid-awake:state", last); return last
    }
    public func set(on: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        try authorize(context)
        guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Only the owner can change this Mac's system power setting.") }
        let before = await read()
        try Task.checkCancellation()
        var outcome = "changed", message = on ? "On. This machine will keep running with the lid closed." : "Off. The lid puts this machine to sleep again."
        if before.known && before.on == on { outcome = "unchanged"; message = on ? "It was already on." : "It was already off." }
        else {
            do {
                let result = try await run("/usr/bin/osascript", ["-e", BackendOSPowerRules.changeScript(on: on)], timeout: 300_000)
                if !result.ok { outcome = BackendOSPowerRules.cancelled(result.stderr) ? "cancelled" : "failed"; let first = BackendOSPowerRules.firstLine(result.stderr); message = outcome == "cancelled" ? "Nothing changed — the password prompt was dismissed." : "macOS would not change the setting: " + (first.isEmpty ? "osascript exited \(result.exitCode)" : first) }
            } catch is CancellationError { throw CancellationError() }
            catch { outcome = "failed"; message = "macOS would not change the setting: " + error.localizedDescription }
        }
        let state = try await refresh()
        if outcome == "changed", !(state["known"].bool == true && state["on"].bool == on) { outcome = "failed"; message = state["known"].bool == true ? "The command ran and the setting did not change." : state["detail"].string ?? "The setting could not be read back afterwards." }
        return .object([.init("outcome", .string(outcome)), .init("state", state), .init("message", .string(message))])
    }
    /// Deliberately releases only the app assertion, never the system switch.
    public func stop() async { started = false; generation += 1; refreshing?.cancel(); refreshing = nil; if let unsubscribe { await unsubscribe() }; unsubscribe = nil; if let blocker { do { try await power.stopIdleBlocker(blocker) } catch { failures.append(error.localizedDescription) } }; blocker = nil }
    public func errors() -> [String] { failures }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw NativeRPCError(code: "unavailable", message: "The native power channel is not registered.") }
        if channel == "power:lid-awake:get" { return try await refresh() }
        return try await set(on: args.first?.bool == true, context: context)
    }
}
