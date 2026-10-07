import Foundation
import TerminalDeckNativeCore

public protocol BackendMacAppSetupDiagnosticSource: Sendable {
    func about() async throws -> NativeRPCValue
    /// locale, uptimeSeconds and system os/release/arch/memoryTotalMb/
    /// memoryFreeMb/processRssMb are actual process/platform measurements.
    func runtime() async throws -> NativeRPCValue
    func logStatus() async throws -> NativeRPCValue
    func logTail(_ count: Int) async throws -> [String]
    func prerequisites() async throws -> NativeRPCValue
    func loginPath() async throws -> String
    func paths() async throws -> NativeRPCValue
    func preferences() async throws -> NativeRPCValue
    func environment() async throws -> [String: String]
}
public struct BackendMacAppSetupNativeDiagnosticSource: BackendMacAppSetupDiagnosticSource, Sendable {
    private let providers: BackendNativeProviders, log: BackendOSAppLog, state: NativeStateStore
    private let detection: any BackendMacAppSetupDetection
    private let appAbout: @Sendable () async throws -> NativeRPCValue
    private let measuredRuntime: @Sendable () async throws -> NativeRPCValue
    private let measuredPaths: @Sendable () async throws -> NativeRPCValue
    private let env: [String: String]
    public init(providers: BackendNativeProviders, log: BackendOSAppLog, state: NativeStateStore, detection: any BackendMacAppSetupDetection,
                environment: [String: String], about: @escaping @Sendable () async throws -> NativeRPCValue,
                runtime: @escaping @Sendable () async throws -> NativeRPCValue, paths: @escaping @Sendable () async throws -> NativeRPCValue) {
        self.providers = providers; self.log = log; self.state = state; self.detection = detection; env = environment
        appAbout = about; measuredRuntime = runtime; measuredPaths = paths
    }
    public func about() async throws -> NativeRPCValue { try await appAbout() }
    public func runtime() async throws -> NativeRPCValue { try await measuredRuntime() }
    public func logStatus() async throws -> NativeRPCValue { await log.status() }
    public func logTail(_ count: Int) async throws -> [String] { try await log.tail(count) }
    public func prerequisites() async throws -> NativeRPCValue { try await BackendMacAppSetupPrerequisites.check(detection) }
    public func loginPath() async throws -> String { try await providers.loginPath() }
    public func paths() async throws -> NativeRPCValue { try await measuredPaths() }
    public func preferences() async throws -> NativeRPCValue { await state.getPreferences() }
    public func environment() async throws -> [String: String] { env }
}
public enum BackendMacAppSetupDiagnostics {
    public static let channels: Set<String> = ["debug:about", "debug:diagnostics", "debug:diagnostics-text", "debug:ipc-log", "debug:ipc-clear", "debug:subscribe", "debug:unsubscribe"]
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    /// Compatibility field names stay stable after Node/Electron retirement.
    /// A transitional runtime may supply its measured versions; a native-only
    /// process reports n/a rather than inventing those runtimes.
    public static func aboutInfo(version: String, arch: String, packaged: Bool, runtimeVersions: [String: String] = [:]) -> NativeRPCValue {
        o([("name", .string("Terminal Deck")), ("tagline", .string("Run your coding agents on one deck")), ("version", .string(version)),
           ("electron", .string(runtimeVersions["electron"] ?? "n/a")), ("chrome", .string(runtimeVersions["chrome"] ?? "n/a")),
           ("node", .string(runtimeVersions["node"] ?? "n/a")), ("v8", .string(runtimeVersions["v8"] ?? "n/a")),
           ("platform", .string("darwin")), ("arch", .string(arch)), ("packaged", .bool(packaged))])
    }
    public static func number(_ value: NativeRPCValue) -> Double? {
        if let number = value.number { return number }
        if value == .null { return 0 }
        if let bool = value.bool { return bool ? 1 : 0 }
        func primitive(_ value: NativeRPCValue) -> String {
            if value.isNullish { return "" }
            if let string = value.string { return string }
            if let elements = value.elements { return elements.map(primitive).joined(separator: ",") }
            if value.fields != nil { return "[object Object]" }
            return value.compact
        }
        guard value.string != nil || value.elements != nil else { return nil }
        let text = primitive(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where text.lowercased().hasPrefix(prefix) {
            let digits = text.dropFirst(2)
            guard !digits.isEmpty else { return nil }
            var result = 0.0
            for char in digits {
                guard let digit = char.hexDigitValue, digit < radix else { return nil }
                result = result * Double(radix) + Double(digit)
            }
            return result.isFinite ? result : nil
        }
        return Double(text).flatMap { $0.isFinite ? $0 : nil }
    }
    public static func pathEntries(_ raw: String, separator: String = ":") -> [String] { raw.components(separatedBy: separator).filter { !$0.isEmpty } }
    public static func shellName(_ environment: [String: String]) -> String { environment["SHELL"] ?? "" }
    public static func groupChannels(_ channels: [String]) -> [NativeRPCValue] {
        var grouped: [String: [String]] = [:]
        for channel in channels.sorted() { let name = channel.firstIndex(of: ":").map { String(channel[..<$0]) } ?? "app"; grouped[name, default: []].append(channel) }
        return grouped.keys.sorted().map { o([("name", .string($0)), ("channels", .array(grouped[$0]!.map(NativeRPCValue.string)))]) }
    }
    public static func ipcInfo(invoke: [String], send: [String], instrumented: Bool) -> NativeRPCValue {
        o([("modules", .array(groupChannels(Array(Set(invoke + send))))), ("invokeChannels", .number(Double(invoke.count))), ("sendChannels", .number(Double(send.count))), ("instrumented", .bool(instrumented))])
    }
    public static func requestOptions(_ raw: NativeRPCValue) -> (includeClis: Bool, logLines: Int) {
        let value = raw["logLines"]
        let asked = value.isNullish ? nil : number(value)
        return (raw["includeClis"].bool != false, asked.map { Int(min(2000, max(1, $0.rounded(.down)))) } ?? 200)
    }
    public static func collect(source: any BackendMacAppSetupDiagnosticSource, ipc: NativeRPCValue, includeClis: Bool = true, logLines: Int = 200,
                               redaction: BackendSharedRedactOptions, now: Double) async throws -> NativeRPCValue {
        let environment = try await source.environment()
        var options = redaction; options.extraSecrets = BackendSharedRedact.secretsFromEnv(environment) + options.extraSecrets
        var count = 0
        func clean(_ text: String) -> NativeRPCValue { let result = BackendSharedRedact.redactWithCount(text, options: options); count += result.count; return .string(result.text) }
        let about = try await source.about(), runtime = try await source.runtime()
        let status = (try? await source.logStatus()) ?? o([("dir", .string("")), ("file", .string("")), ("bytes", .number(0))])
        let tools: [NativeRPCValue]
        if includeClis {
            do { tools = try await source.prerequisites()["tools"].elements ?? [] }
            catch let error as NativeRPCError where error.code == "unavailable" { throw error }
            catch { tools = [] }
        } else { tools = [] }
        let rawPath: String
        do { rawPath = try await source.loginPath() } catch { rawPath = environment["PATH"] ?? "" }
        let paths = try await source.paths()
        let preferences = BackendSharedRedact.redactValue((try? await source.preferences()) ?? .object([]), options: options)
        let logLinesValue = ((try? await source.logTail(logLines)) ?? []).map(clean)
        let clis = tools.map { tool -> NativeRPCValue in
            var cli = o([("id", tool["id"]), ("label", tool["label"]), ("state", tool["state"])])
            if let version = tool["version"].string, !version.isEmpty { cli = cli.setting("version", clean(version)) }; return cli
        }
        let pathValues = NativeRPCValue.object((paths.fields ?? []).map { NativeRPCValue.Field($0.key, clean($0.value.string ?? "")) })
        let pathEntriesValue = pathEntries(rawPath).map(clean), shell = clean(shellName(environment)), logFile = clean(status["file"].string ?? "")
        return o([("generatedAt", .number(now)), ("app", about.merging(o([("locale", runtime["locale"]), ("uptimeSeconds", runtime["uptimeSeconds"])]))), ("system", runtime["system"]), ("clis", .array(clis)), ("ipc", ipc), ("paths", pathValues), ("preferences", preferences), ("environment", o([("path", .array(pathEntriesValue)), ("shell", shell), ("term", .string(environment["TERM"] ?? "")), ("lang", .string(environment["LANG"] ?? "")), ("secretsPresent", .array(BackendSharedRedact.secretEnvNames(environment).map(NativeRPCValue.string)))])), ("log", o([("file", logFile), ("bytes", status["bytes"]), ("lines", .array(logLinesValue))])), ("redaction", o([("count", .number(Double(count)))]))])
    }
    public static func format(_ bundle: NativeRPCValue) -> String {
        func text(_ value: NativeRPCValue) -> String { if let text = value.string { return text }; if value == .missing { return "undefined" }; return value.compact }
        let app = bundle["app"], system = bundle["system"], environment = bundle["environment"], log = bundle["log"], ipc = bundle["ipc"]
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["# \(text(app["name"])) diagnostics", "Generated \(date.string(from: Date(timeIntervalSince1970: (bundle["generatedAt"].number ?? 0) / 1000)))", "All values below were passed through redaction (\(text(bundle["redaction"]["count"])) substitutions)."]
        func section(_ name: String) { lines.append(contentsOf: ["", "## " + name]) }
        func row(_ label: String, _ value: String) { lines.append("- \(label): \(value)") }
        section("App"); for key in ["version", "packaged", "locale"] { row(key, text(app[key])) }; row("uptime", text(app["uptimeSeconds"]) + "s")
        section("Runtime"); for key in ["electron", "chrome", "node", "v8"] { row(key, text(app[key])) }
        row("os", "\(text(system["os"])) \(text(system["release"])) (\(text(system["arch"])))"); row("memory", "\(text(system["memoryFreeMb"])) MB free of \(text(system["memoryTotalMb"])) MB"); row("process rss", "\(text(system["processRssMb"])) MB")
        section("Agent CLIs"); let clis = bundle["clis"].elements ?? []; if clis.isEmpty { lines.append("- not probed") }
        let states = ["ready": "ready", "installed-not-authed": "installed, not signed in", "missing": "not found", "unknown": "unknown"]
        for cli in clis { row(text(cli["label"]), (states[cli["state"].string ?? ""] ?? "unknown") + (cli["version"].string.map { $0.isEmpty ? "" : " — " + $0 } ?? "")) }
        section("IPC"); row("instrumented", text(ipc["instrumented"])); row("invoke channels", text(ipc["invokeChannels"])); row("send channels", text(ipc["sendChannels"]))
        for module in ipc["modules"].elements ?? [] { let count = module["channels"].elements?.count ?? 0; row(text(module["name"]), "\(count) channel\(count == 1 ? "" : "s")") }
        section("Paths"); for field in bundle["paths"].fields ?? [] { row(field.key, text(field.value)) }
        section("Preferences"); for field in bundle["preferences"].fields ?? [] { row(field.key, text(field.value)) }
        section("Environment"); row("shell", text(environment["shell"])); row("term", environment["term"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "unset"); row("lang", environment["lang"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "unset")
        let secrets = environment["secretsPresent"].elements?.compactMap(\.string) ?? []; row("secret-looking vars set", secrets.isEmpty ? "none" : secrets.joined(separator: ", ")); lines.append("- PATH:"); for entry in environment["path"].elements ?? [] { lines.append("  - " + text(entry)) }
        section("Log (\(text(log["file"])), \(text(log["bytes"])) bytes)"); lines.append("```"); let tail = log["lines"].elements?.compactMap(\.string) ?? []; lines.append(contentsOf: tail.isEmpty ? ["(empty)"] : tail); lines.append("```")
        return lines.joined(separator: "\n")
    }
}

public protocol BackendMacAppSetupDiagnosticSubscriber: Sendable {
    func destroyed() async throws -> Bool
    func send(_ record: NativeRPCValue) async throws
    func observeDestroyed(_ callback: @escaping @Sendable () async -> Void) async throws -> @Sendable () async throws -> Void
}
/// diagnostics.ts timing observer. Unlike the independent BackendOSTrace,
/// this NEVER receives arguments/results and cannot change a handler outcome.
public actor BackendMacAppSetupIPCMetrics {
    public static let maxRecords = 500
    private var records: [NativeRPCValue] = [], sequence = 0, instrumented = false
    private struct Subscriber: Sendable { let id: UUID; let client: any BackendMacAppSetupDiagnosticSubscriber; var release: (@Sendable () async throws -> Void)? }
    private var subscribers: [String: Subscriber] = [:]
    private let now: @Sendable () -> Double, monotonic: @Sendable () -> Double
    private let redaction: BackendSharedRedactOptions
    private let failed: @Sendable (String, String) async throws -> Void
    public init(now: @escaping @Sendable () -> Double, monotonic: @escaping @Sendable () -> Double, redaction: BackendSharedRedactOptions,
                logFailure: @escaping @Sendable (String, String) async throws -> Void) { self.now = now; self.monotonic = monotonic; self.redaction = redaction; failed = logFailure }
    public func activate(sharedDispatcherUsesThisObserver: Bool) { instrumented = sharedDispatcherUsesThisObserver }
    public func isInstrumented() -> Bool { instrumented }
    public static func ignored(_ channel: String) -> Bool { channel.hasPrefix("debug:") || channel == "log:recent" }
    public func started(_ channel: String) -> Double? { instrumented && !Self.ignored(channel) ? monotonic() : nil }
    public func finish(_ channel: String, kind: String, started: Double?, error: Error? = nil) async {
        guard let started else { return }; sequence += 1
        let message = error.map { String(decoding: BackendSharedRedact.redact($0.localizedDescription, options: redaction).utf16.prefix(300), as: UTF16.self) }
        var record = NativeRPCValue.object([.init("seq", .number(Double(sequence))), .init("channel", .string(channel)), .init("kind", .string(kind)), .init("at", .number(now())), .init("ms", .number(((monotonic() - started) * 10).rounded() / 10)), .init("ok", .bool(error == nil))])
        if let message { record = record.setting("error", .string(message)) }
        records.append(record); if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
        for (owner, subscription) in Array(subscribers) {
            do { if try await subscription.client.destroyed() { await drop(owner, expectedID: subscription.id); continue }; try await subscription.client.send(record) }
            catch { await drop(owner, expectedID: subscription.id) }
        }
        if let message { try? await failed(channel, message) }
    }
    public func recent(_ limit: Double = 500) -> [NativeRPCValue] { let wanted = limit.isFinite ? Int(min(500, max(1, limit.rounded(.towardZero)))) : 500; return Array(records.suffix(wanted)) }
    public func clear() { records.removeAll() }
    public func subscribe(_ owner: String, client: any BackendMacAppSetupDiagnosticSubscriber) async throws -> Bool {
        if subscribers[owner] != nil { return true }
        let id = UUID(); subscribers[owner] = Subscriber(id: id, client: client, release: nil)
        do {
            let release = try await client.observeDestroyed { [weak self] in await self?.drop(owner, expectedID: id) }
            if subscribers[owner]?.id == id { subscribers[owner]?.release = release } else { try? await release() }
            return true
        } catch { if subscribers[owner]?.id == id { subscribers[owner] = nil }; throw error }
    }
    public func unsubscribe(_ owner: String) async { await drop(owner, expectedID: nil) }
    private func drop(_ owner: String, expectedID: UUID?) async {
        guard expectedID == nil || subscribers[owner]?.id == expectedID else { return }
        let saved = subscribers.removeValue(forKey: owner); try? await saved?.release?()
    }
    public func subscriberCount() -> Int { subscribers.count }
}
public struct BackendMacAppSetupDiagnosticsDispatcher: Sendable {
    public let existing: BackendOSTraceDispatcher, metrics: BackendMacAppSetupIPCMetrics
    public typealias SendObserver = @Sendable (String, [NativeRPCValue], NativeRPCContext, BackendMacAppSetupIPCMetrics) async throws -> Bool
    private let sendObserver: SendObserver?
    public init(existing: BackendOSTraceDispatcher, metrics: BackendMacAppSetupIPCMetrics, sendPerListener: SendObserver? = nil) { self.existing = existing; self.metrics = metrics; sendObserver = sendPerListener }
    public func invoke(channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        let start = await metrics.started(channel)
        do { let result = try await existing.invoke(channel: channel, arguments: arguments, context: context); await metrics.finish(channel, kind: "invoke", started: start); return result }
        catch { await metrics.finish(channel, kind: "invoke", started: start, error: error); throw error }
    }
    public func send(channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> Bool {
        guard let sendObserver else { throw NativeRPCError(code: "unavailable", message: "Per-listener native send timing has not been supplied by the shared channel registry.") }
        // Source ipcMain.on measures EACH listener, including its thrown error.
        // The native registry owns that loop; an aggregate success around send
        // would conceal a listener failure and is deliberately not substituted.
        return try await sendObserver(channel, arguments, context, metrics)
    }
}
public enum BackendMacAppSetupDiagnosticsChannels {
    public static func register(registry: NativeChannelRegistry, metrics: BackendMacAppSetupIPCMetrics, source: any BackendMacAppSetupDiagnosticSource,
                                ownerID: String, authorize: @escaping NativeChannelRegistry.Policy, redaction: BackendSharedRedactOptions,
                                now: @escaping @Sendable () -> Double, subscriber: @escaping @Sendable (NativeRPCContext) async throws -> any BackendMacAppSetupDiagnosticSubscriber) async throws {
        for channel in BackendMacAppSetupDiagnostics.channels {
            try await registry.register(channel, ownerID: ownerID, policy: authorize) { context, args in
                switch channel {
                case "debug:about": return try await source.about()
                case "debug:ipc-log": let value = BackendMacAppSetupDiagnostics.number(args.first ?? .missing) ?? 500; return .array(await metrics.recent(value == 0 ? 500 : value))
                case "debug:ipc-clear": await metrics.clear(); return .missing
                case "debug:subscribe": return .bool(try await metrics.subscribe(context.ownerID, client: subscriber(context)))
                case "debug:unsubscribe": await metrics.unsubscribe(context.ownerID); return .missing
                default:
                    let options = BackendMacAppSetupDiagnostics.requestOptions(args.first ?? .missing), invokes = await registry.channels(), sends = await registry.sends()
                    let ipc = BackendMacAppSetupDiagnostics.ipcInfo(invoke: invokes, send: sends, instrumented: await metrics.isInstrumented())
                    let result = try await BackendMacAppSetupDiagnostics.collect(source: source, ipc: ipc, includeClis: options.includeClis, logLines: options.logLines, redaction: redaction, now: now())
                    return channel == "debug:diagnostics-text" ? .string(BackendMacAppSetupDiagnostics.format(result)) : result
                }
            }
        }
    }
}
