import Foundation
import TerminalDeckNativeCore

public struct BackendPluginsServices: Sendable {
    public var projects: @Sendable () async -> [String]
    public var tasks: (@Sendable () async throws -> [NativeRPCValue])?
    public var goals: (@Sendable (String?) async throws -> [NativeRPCValue])?
    public var knowledge: (@Sendable (String, String, Int) async throws -> NativeRPCValue)?
    public var notify: (@Sendable (String, String, String) async throws -> Bool)?
    public init(projects: @escaping @Sendable () async -> [String], tasks: (@Sendable () async throws -> [NativeRPCValue])? = nil,
                goals: (@Sendable (String?) async throws -> [NativeRPCValue])? = nil,
                knowledge: (@Sendable (String, String, Int) async throws -> NativeRPCValue)? = nil,
                notify: (@Sendable (String, String, String) async throws -> Bool)? = nil) {
        self.projects = projects; self.tasks = tasks; self.goals = goals; self.knowledge = knowledge; self.notify = notify
    }
}
public struct BackendPluginsConsentRequest: Sendable {
    public let id, name, version, hash: String
    public let capabilities, projects, tools: [String]
    public let message, detail: String
}
public struct BackendPluginsConsentOutcome: Sendable {
    public let granted: Bool, reason: String, at: Double
    public init(granted: Bool, reason: String = "declined", at: Double = Date().timeIntervalSince1970 * 1000) {
        self.granted = granted; self.reason = reason; self.at = at
    }
}
public protocol BackendPluginsConsent: Sendable {
    func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome
    func shutdown() async
}
/// The app assembly supplies real Finder/Trash operations. Missing UI is refused.
public struct BackendPluginsDesktop: Sendable {
    public let openFolder: @Sendable (URL) async throws -> Void
    public let trash: @Sendable (URL) async throws -> Void
    public init(openFolder: @escaping @Sendable (URL) async throws -> Void, trash: @escaping @Sendable (URL) async throws -> Void) { self.openFolder = openFolder; self.trash = trash }
}
public protocol BackendPluginsCallerAuthority: Sendable {
    func isLocalHoot(_ context: BackendMCPCallContext) async -> Bool
    /// The real shared action dispatcher enforces tier consent, budgets and
    /// action logging; a caller grant alone is not that dispatcher.
    func authorize(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws
}

/// One host for Settings, plugin child requests and Hoot's contributed tools.
public actor BackendPluginsHost {
    private struct Entry {
        let id: String, folder: URL
        var manifest: BackendPluginsManifest?, broken: String?, hash: String?
        var process: (any BackendPluginsRunningProcess)?, runningHash: String?, starting: Task<Void, any Error>?, stopped: String?
        var notified: [Double] = []
        var generation: UUID?
    }
    public let folder: URL
    private let userData: URL, runtime: String?, environment: [String: String]
    private let consent: any BackendPluginsConsent, services: BackendPluginsServices, desktop: BackendPluginsDesktop?
    private let changed: @Sendable () async -> Void, now: @Sendable () -> Double
    private let processFactory: BackendPluginsProcessFactory
    private let requestTimeoutMilliseconds, handshakeTimeoutMilliseconds, maximumMessageBytes: Int
    private let folderLimits: BackendPluginsFiles.Limits
    private let grants: BackendPluginsGrants
    private var entries: [String: Entry] = [:], order: [String] = []
    private var asking = false, closed = false
    public init(userData: URL, runtime: String?, environment: [String: String], consent: any BackendPluginsConsent,
                services: BackendPluginsServices, desktop: BackendPluginsDesktop? = nil,
                changed: @escaping @Sendable () async -> Void = {}, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                processFactory: @escaping BackendPluginsProcessFactory = BackendPluginsRuntime.native,
                requestTimeoutMilliseconds: Int = 30_000, handshakeTimeoutMilliseconds: Int = 10_000,
                maximumMessageBytes: Int = 256 * 1024, folderLimits: BackendPluginsFiles.Limits = .init()) {
        self.userData = userData; folder = userData.appendingPathComponent("plugins", isDirectory: true)
        self.runtime = runtime; self.environment = environment; self.consent = consent; self.services = services; self.desktop = desktop
        self.changed = changed; self.now = now; grants = BackendPluginsGrants(userData: userData)
        self.processFactory = processFactory; self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.handshakeTimeoutMilliseconds = handshakeTimeoutMilliseconds; self.maximumMessageBytes = maximumMessageBytes; self.folderLimits = folderLimits
    }
    private func look(_ id: String) async -> Entry {
        let dir = folder.appendingPathComponent(id)
        var entry = entries[id] ?? Entry(id: id, folder: dir)
        entry.manifest = nil; entry.broken = nil; entry.hash = nil
        do { entry.manifest = try BackendPluginsManifestReader.read(dir, folder: id) } catch { entry.broken = error.localizedDescription }
        do { entry.hash = try BackendPluginsFiles.hash(dir, limits: folderLimits).hash } catch { if entry.broken == nil { entry.broken = error.localizedDescription } }
        entries[id] = entry; if !order.contains(id) { order.append(id) }
        if let process = entry.process, await process.alive, entry.runningHash != entry.hash { await process.stop("its files changed while it was running") }
        return entries[id] ?? entry
    }
    private func lookNew(_ id: String) async throws -> Entry {
        guard BackendPluginsManifestReader.matches(id, #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#), FileManager.default.fileExists(atPath: folder.appendingPathComponent(id).path) else {
            throw BackendPluginsManifestReader.refusal("There is no plugin by that name in the plugins folder.")
        }
        return await look(id)
    }
    public func scan() async {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            guard !name.hasPrefix(".") else { return false }
            return (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.type] as? FileAttributeType) == .typeDirectory
        }.sorted()
        for id in order where !names.contains(id) {
            if let process = entries[id]?.process { await process.stop("its folder is gone") }; entries[id] = nil
        }
        order.removeAll { !names.contains($0) }
        for name in names { _ = await look(name) }
    }
    private func view(_ entry: Entry) async -> NativeRPCValue {
        let record = grants.record(entry.id), grant = grants.valid(entry.id, hash: entry.hash), manifest = entry.manifest
        let state: String, note: String
        if manifest == nil || entry.broken != nil { state = "broken"; note = "This folder cannot be used as a plugin: \(entry.broken ?? "it could not be read")." }
        else if record["grant"].isNullish { state = "needs-ok"; note = "Not allowed yet. Nothing in it has run." }
        else if grant == nil { state = "changed"; note = "Its files changed since you allowed it, so it is not running. Look at what it asks for and allow it again." }
        else if record["enabled"].bool != true { state = "off"; note = "Off. It is not started." }
        else if let process = entry.process, await process.alive { state = "running"; note = "Running." }
        else {
            state = "stopped"
            let again = strings(grant?["capabilities"] ?? .missing).contains("tools.contribute") ? "It starts again the next time Hoot uses one of its tools, or when you turn it off and on." : "Turn it off and on to start it again."
            note = entry.stopped.map { "Not running: \($0). \(again)" } ?? "Not running. \(again)"
        }
        let declared = manifest?.capabilities ?? []
        return .object([.init("id", .string(entry.id)), .init("name", .string(manifest?.name ?? entry.id)), .init("summary", .string(manifest?.summary ?? "")), .init("version", .string(manifest?.version ?? "")), .init("enabled", record["enabled"]), .init("state", .string(state)), .init("note", .string(note)), .init("declared", array(declared)), .init("granted", array(strings(grant?["capabilities"] ?? .missing).filter(declared.contains))), .init("projects", grant?["projects"] ?? .array([])), .init("allowed", .bool(grant != nil)), .init("tools", .array((manifest?.tools ?? []).map { .object([.init("name", .string($0.name)), .init("wire", .string($0.wire(entry.id))), .init("title", .string($0.title)), .init("tier", .string($0.tier))]) }))])
    }
    public func state() async -> NativeRPCValue {
        await scan(); var views: [NativeRPCValue] = []
        for id in order { if let entry = entries[id] { views.append(await view(entry)) } }
        return .object([.init("folder", .string(folder.path)), .init("confinement", .string(BackendPluginsSandbox.confinement)), .init("projects", array(await services.projects())), .init("plugins", .array(views))])
    }
    private func result(_ message: String? = nil) async -> NativeRPCValue {
        .object([.init("ok", .bool(message == nil)), .init("message", message.map(NativeRPCValue.string) ?? .missing), .init("state", await state())])
    }
    public func allow(_ id: String, input: NativeRPCValue) async -> NativeRPCValue {
        do {
            guard !closed else { throw BackendPluginsManifestReader.refusal("The app is closing, so nothing was allowed.") }
            let entry = try await (entries[id] == nil ? lookNew(id) : look(id))
            guard let manifest = entry.manifest, entry.broken == nil, let hash = entry.hash else { throw BackendPluginsManifestReader.refusal("That folder cannot be used as a plugin: \(entry.broken ?? "it could not be read").") }
            let wanted = unique(strings(input["capabilities"]).filter(PluginCatalog.capabilities.contains))
            if let odd = wanted.first(where: { !manifest.capabilities.contains($0) }) { throw BackendPluginsManifestReader.refusal("“\(manifest.name)” does not ask for \(odd), so it cannot be given it.") }
            let scoped = wanted.contains("knowledge.read"), known = await services.projects().map(BackendPluginsFiles.real)
            let projects = scoped ? unique(strings(input["projects"]).filter { !$0.isEmpty }.map(BackendPluginsFiles.real)) : []
            guard !closed else { throw BackendPluginsManifestReader.refusal("The app is closing, so nothing was allowed.") }
            if let unknown = projects.first(where: { !known.contains($0) }) { throw BackendPluginsManifestReader.refusal("\(unknown) is not one of your projects in this app.") }
            if scoped && projects.isEmpty { throw BackendPluginsManifestReader.refusal("Choose at least one project for it to read about, or leave that one off.") }
            if let current = grants.valid(id, hash: hash), wanted.allSatisfy(strings(current["capabilities"]).contains), projects.allSatisfy(strings(current["projects"]).contains) {
                try grants.grant(id, current.setting("capabilities", array(wanted)).setting("projects", array(projects)), enabled: grants.record(id)["enabled"].bool == true)
                await changed(); return await result()
            }
            guard !asking else { throw BackendPluginsManifestReader.refusal("Another plugin question is already on screen. Answer that one first.") }
            asking = true
            let outcome = await consent.ask(question(entry, manifest: manifest, hash: hash, wanted: wanted, projects: projects)); asking = false
            guard !closed else { throw BackendPluginsManifestReader.refusal("The app is closing, so nothing was allowed.") }
            guard outcome.granted else { throw BackendPluginsManifestReader.refusal(refusal(outcome.reason)) }
            let after = await look(id)
            guard after.hash == hash else { throw BackendPluginsManifestReader.refusal("Its files changed while you were deciding, so nothing was allowed. Look again and allow it again.") }
            try grants.grant(id, .object([.init("hash", .string(hash)), .init("capabilities", array(wanted)), .init("projects", array(projects)), .init("grantedAt", .number(outcome.at))]), enabled: true)
            entries[id]?.stopped = nil; await changed(); await tryStart(id); return await result()
        } catch { return await result((error as? NativeRPCError)?.message ?? "That did not work: \(error.localizedDescription)") }
    }
    private func question(_ entry: Entry, manifest: BackendPluginsManifest, hash: String, wanted: [String], projects: [String]) -> BackendPluginsConsentRequest {
        let tools = wanted.contains("tools.contribute") ? manifest.tools.map { $0.wire(entry.id) } : []
        var lines = ["\(manifest.name) \(manifest.version) — Runs a program on this machine.", "", wanted.isEmpty ? "It would run, and be allowed nothing else." : "It would be allowed to:"]
        lines += wanted.map { "• " + PluginCatalog.words($0) + ($0 == "knowledge.read" ? ": " + projects.joined(separator: ", ") : "") }
        if !tools.isEmpty { lines += ["", "Tools: " + tools.joined(separator: ", ")] }
        lines += ["", BackendPluginsSandbox.confinement, "If its files change, it stops until you allow it again.", "", "Code fingerprint " + hash.prefix(12)]
        return BackendPluginsConsentRequest(id: entry.id, name: manifest.name, version: manifest.version, hash: hash, capabilities: wanted, projects: projects, tools: tools, message: "Allow the plugin “\(manifest.name)” to run on this computer?", detail: lines.joined(separator: "\n"))
    }
    private func refusal(_ reason: String) -> String {
        switch reason {
        case "declined": return "You said no, so nothing was allowed."
        case "timeout": return "Nobody answered in time, so nothing was allowed."
        case "shutting-down": return "The app is closing, so nothing was allowed."
        default: return "The question could not be shown, so nothing was allowed."
        }
    }
    public func setEnabled(_ id: String, _ enabled: Bool) async -> NativeRPCValue {
        do {
            let entry = try await (entries[id] == nil ? lookNew(id) : look(id))
            if !enabled {
                try grants.enabled(id, false); await entry.process?.stop("you turned it off"); entries[id]?.stopped = nil
            } else {
                guard grants.valid(id, hash: entry.hash) != nil else { throw BackendPluginsManifestReader.refusal("Allow it first: it has not been allowed for the files that are in its folder now.") }
                try grants.enabled(id, true); entries[id]?.stopped = nil
            }
            await changed(); if enabled { await tryStart(id) }; return await result()
        } catch { return await result((error as? NativeRPCError)?.message ?? "That did not work: \(error.localizedDescription)") }
    }
    public func remove(_ id: String) async -> NativeRPCValue {
        do {
            let entry = try await (entries[id] == nil ? lookNew(id) : look(id)); await entry.process?.stop("it was removed")
            guard let desktop else { throw NativeRPCError(code: "unavailable", message: "The native Trash service is unavailable.") }
            if FileManager.default.fileExists(atPath: entry.folder.path) { try await desktop.trash(entry.folder) }
            let data = userData.appendingPathComponent("plugin-data/" + id)
            if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
            try grants.forget(id); entries[id] = nil; order.removeAll { $0 == id }; await changed(); return await result()
        } catch { return await result((error as? NativeRPCError)?.code == "plugin-refusal" ? error.localizedDescription : "It could not be removed: \(error.localizedDescription)") }
    }
    public func openFolder() async throws {
        guard let desktop else { throw NativeRPCError(code: "unavailable", message: "The native Finder service is unavailable.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try await desktop.openFolder(folder)
    }
    public func startAll() async { await scan(); for id in order { await tryStart(id) } }
    public func stopAll() async { closed = true; await consent.shutdown(); for entry in entries.values { await entry.process?.stop("the app quit") } }
    private func tryStart(_ id: String) async { do { try await ensureRunning(id) } catch { if entries[id]?.stopped == nil { entries[id]?.stopped = error.localizedDescription } } }
    private func ensureRunning(_ id: String) async throws {
        if let process = entries[id]?.process, await process.alive { return }
        if let starting = entries[id]?.starting { return try await starting.value }
        let task = Task { try await self.start(id) }; entries[id]?.starting = task
        defer { entries[id]?.starting = nil }; try await task.value
    }
    private func start(_ id: String) async throws {
        guard !closed else { throw BackendPluginsManifestReader.refusal("the app is closing") }
        guard let entry = entries[id], let manifest = entry.manifest, entry.broken == nil else { throw BackendPluginsManifestReader.refusal("it cannot be used: \(entries[id]?.broken ?? "unreadable")") }
        guard grants.record(id)["enabled"].bool == true else { throw BackendPluginsManifestReader.refusal("it is turned off") }
        let hash = try? BackendPluginsFiles.hash(entry.folder, limits: folderLimits).hash; entries[id]?.hash = hash
        guard let grant = grants.valid(id, hash: hash) else { throw BackendPluginsManifestReader.refusal("its files are not the files it was allowed for") }
        guard let runtime else { throw NativeRPCError(code: "unavailable", message: "The plugin Node runtime is unavailable in this build.") }
        let data = userData.appendingPathComponent("plugin-data/" + id)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        let launch = BackendPluginsSandbox.command(runtime: runtime, main: BackendPluginsFiles.real(entry.folder.path) + "/" + manifest.main, folder: entry.folder.path, data: data.path)
        let generation = UUID()
        let process = processFactory(.init(command: launch.0, arguments: launch.1, cwd: entry.folder.path, environment: BackendPluginsSandbox.environment(home: BackendPluginsFiles.real(data.path), parent: environment), requestTimeoutMilliseconds: requestTimeoutMilliseconds, maximumMessageBytes: maximumMessageBytes), { [weak self] method, params in
            guard let self else { throw BackendPluginsError(-32000, "the app is closing") }; return try await self.answer(id, generation: generation, method: method, params: params)
        }, { [weak self] why in await self?.processExited(id, generation: generation, why: why) })
        entries[id]?.process = process; entries[id]?.generation = generation; entries[id]?.runningHash = hash; entries[id]?.stopped = nil
        try await process.start()
        do {
            let answer = try await process.request("initialize", params: .object([.init("protocol", .number(1)), .init("id", .string(id)), .init("version", .string(manifest.version)), .init("granted", grant["capabilities"]), .init("projects", grant["projects"]), .init("dataFolder", .string(BackendPluginsFiles.real(data.path)))]), timeoutMilliseconds: handshakeTimeoutMilliseconds)
            guard answer["protocol"].number == 1 else { await process.kill("it does not speak protocol 1"); throw BackendPluginsManifestReader.refusal("it does not speak protocol 1") }
        } catch {
            if (error as? NativeRPCError)?.message == "it does not speak protocol 1" { throw error }
            await process.kill("it did not finish starting (\(error.localizedDescription))"); throw BackendPluginsManifestReader.refusal("it did not finish starting: \(error.localizedDescription)")
        }
        await changed()
    }
    private func processExited(_ id: String, generation: UUID, why: String) async {
        if entries[id]?.generation == generation { entries[id]?.process = nil; entries[id]?.generation = nil; entries[id]?.runningHash = nil; entries[id]?.stopped = why }; await changed()
    }
    private func param(_ params: NativeRPCValue, _ key: String, _ max: Int) throws -> String {
        guard let raw = params[key].string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendPluginsError(-32602, "\(key) is required") }
        guard raw.utf16.count <= max else { throw BackendPluginsError(-32602, "\(key) must be \(max) characters or fewer") }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func answer(_ id: String, generation: UUID, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        let needs = ["tasks.list": "tasks.read", "goals.list": "goals.read", "knowledge.search": "knowledge.read", "notify": "notify"]
        guard let need = needs[method] else { throw BackendPluginsError(-32601, "there is no \(method)") }
        guard let entry = entries[id], let manifest = entry.manifest, manifest.capabilities.contains(need) else { throw BackendPluginsError(-32001, "\(method) needs \(need), which this plugin’s manifest does not ask for") }
        guard entry.generation == generation, let child = entry.process else { throw BackendPluginsError(-32002, "\(method) needs \(need), which the person has not allowed") }
        let alive = await child.alive
        guard alive, let current = entries[id], current.generation == generation, current.process != nil,
              grants.record(id)["enabled"].bool == true, let grant = grants.valid(id, hash: current.runningHash),
              strings(grant["capabilities"]).contains(need) else { throw BackendPluginsError(-32002, "\(method) needs \(need), which the person has not allowed") }
        guard let currentManifest = current.manifest, currentManifest.capabilities.contains(need) else { throw BackendPluginsError(-32001, "\(method) needs \(need), which this plugin’s manifest does not ask for") }
        func unavailable(_ what: String) -> BackendPluginsError { .init(-32003, "\(what) are not available in this build") }
        switch method {
        case "tasks.list":
            guard let tasks = services.tasks else { throw unavailable("tasks") }; return .object([.init("tasks", .array(Array(try await tasks().prefix(500))))])
        case "goals.list":
            guard let goals = services.goals else { throw unavailable("goals") }; return .object([.init("goals", .array(try await goals(params["project"].string)))])
        case "knowledge.search":
            let project = BackendPluginsFiles.real(try param(params, "project", 1024))
            guard strings(grant["projects"]).contains(project) else { throw BackendPluginsError(-32002, "knowledge.read was not allowed for \(project)") }
            let query = try param(params, "query", 500), limit = Int(min(max(params["limit"].number ?? 5, 1), 20).rounded(.towardZero))
            guard let knowledge = services.knowledge else { throw unavailable("project records") }; let found = try await knowledge(project, query, limit)
            return .object([.init("text", found["text"]), .init("records", found["records"])])
        default:
            let title = try param(params, "title", 80), body = BackendPluginsText.prefix(params["body"].string ?? "", 300), time = now()
            entries[id]?.notified.removeAll { time - $0 >= 60_000 }
            guard (entries[id]?.notified.count ?? 0) < 5 else { throw BackendPluginsError(-32004, "at most 5 notifications a minute") }
            guard let notify = services.notify else { throw unavailable("notifications") }; entries[id]?.notified.append(time)
            return .object([.init("delivered", .bool(try await notify(currentManifest.name, title, body)))])
        }
    }
    public func contributors() -> [(String, BackendPluginsManifest)] {
        order.compactMap { id in
            guard let entry = entries[id], let manifest = entry.manifest, entry.broken == nil, grants.record(id)["enabled"].bool == true, let grant = grants.valid(id, hash: entry.hash), strings(grant["capabilities"]).contains("tools.contribute") else { return nil }
            return (id, manifest)
        }
    }
    public func pidOf(_ id: String) async -> Int32? {
        guard let child = entries[id]?.process, await child.alive else { return nil }; return await child.pid
    }
    public func callTool(_ id: String, tool: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard let entry = entries[id], let manifest = entry.manifest, manifest.tools.contains(where: { $0.name == tool }) else { throw BackendPluginsError(-32000, "there is no plugin tool plugin_\(id)_\(tool)") }
        guard grants.record(id)["enabled"].bool == true else { throw BackendPluginsError(-32000, "the plugin “\(manifest.name)” is turned off") }
        guard let grant = grants.valid(id, hash: entry.hash), strings(grant["capabilities"]).contains("tools.contribute") else { throw BackendPluginsError(-32000, "the plugin “\(manifest.name)” is not allowed to give tools right now") }
        do { try await ensureRunning(id) } catch { throw BackendPluginsError(-32000, "the plugin “\(manifest.name)” could not be started: \(error.localizedDescription)") }
        guard let child = entries[id]?.process else { throw BackendPluginsError(-32000, "the plugin “\(manifest.name)” is not running") }
        return try await child.request("tools/call", params: .object([.init("name", .string(tool)), .init("arguments", arguments)]))
    }
    private func strings(_ value: NativeRPCValue) -> [String] { (value.elements ?? []).compactMap(\.string) }
    private func array(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    private func unique(_ values: [String]) -> [String] { var result: [String] = []; for value in values where !result.contains(value) { result.append(value) }; return result }
}
