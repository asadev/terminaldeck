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
    func dispatchTarget(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, validate: @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue
}

public extension BackendPluginsCallerAuthority {
    func dispatchTarget(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, validate: @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue { throw NativeRPCError(code: "unavailable", message: "The declared target dispatcher is unavailable") }
}

/// One host for Settings, plugin child requests and Hoot's contributed tools.
public actor BackendPluginsHost {
    private struct Entry {
        let id: String, folder: URL
        var manifest: BackendPluginsManifest?, broken: String?, hash: String?
        var process: (any BackendPluginsRunningProcess)?, runningHash: String?, starting: Task<Void, any Error>?, stopped: String?
        var notified: [Double] = []
        var extensionProblem: String?
        var methods = Set<String>()
        var generation: UUID?
    }
    public let folder: URL
    private let userData: URL, runtime: String?, environment: [String: String]
    private let consent: any BackendPluginsConsent, services: BackendPluginsServices, desktop: BackendPluginsDesktop?
    private let changed: @Sendable () async -> Void, now: @Sendable () -> Double
    private let processFactory: BackendPluginsProcessFactory
    private let requestTimeoutMilliseconds, handshakeTimeoutMilliseconds, maximumMessageBytes: Int
    private let folderLimits: BackendPluginsFiles.Limits
    private var fileHashes = BackendPluginsFiles.HashCache()
    private let grants: BackendPluginsGrants
    private var entries: [String: Entry] = [:], order: [String] = []
    private var asking = false, closed = false
    private let extensionStore: BackendPluginExtensionStore?
    private var cardCache: [String: NativeRPCValue] = [:]
    private var draining = Set<String>()
    private var stopping: [String: UUID] = [:]
    private var stoppingPeers: [String: any BackendPluginsRunningProcess] = [:]
    private var taskPulseTasks: (@Sendable () async throws -> [BackendTaskRecord])?
    public init(userData: URL, runtime: String?, environment: [String: String], consent: any BackendPluginsConsent,
                services: BackendPluginsServices, desktop: BackendPluginsDesktop? = nil,
                changed: @escaping @Sendable () async -> Void = {}, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                processFactory: @escaping BackendPluginsProcessFactory = BackendPluginsRuntime.native,
                requestTimeoutMilliseconds: Int = 30_000, handshakeTimeoutMilliseconds: Int = 10_000,
                maximumMessageBytes: Int = 256 * 1024, folderLimits: BackendPluginsFiles.Limits = .init(), extensionPersistence: BackendTaskPersistence? = nil) {
        let privateStore = extensionPersistence ?? (try? BackendTaskPersistence(directory: userData.appendingPathComponent("plugin-host-private"), ownership: .exclusive))
        extensionStore = privateStore.map { BackendPluginExtensionStore(persistence: $0) }
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
        do { entry.hash = try fileHashes.hash(dir, limits: folderLimits).hash } catch { if entry.broken == nil { entry.broken = error.localizedDescription } }
        entries[id] = entry; if !order.contains(id) { order.append(id) }
        if let process = entry.process, await process.alive, entry.runningHash != entry.hash { entries[id]?.generation = nil; entries[id]?.process = nil; entries[id]?.runningHash = nil; await interruptExtension(id, reason: "Plugin files changed; allow and resume explicitly."); await process.stop("its files changed while it was running") }
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
        return .object([.init("id", .string(entry.id)), .init("name", .string(manifest?.name ?? entry.id)), .init("summary", .string(manifest?.summary ?? "")), .init("version", .string(manifest?.version ?? "")), .init("enabled", record["enabled"]), .init("state", .string(state)), .init("note", .string(note)), .init("declared", array(declared)), .init("granted", array(strings(grant?["capabilities"] ?? .missing).filter(declared.contains))), .init("projects", grant?["projects"] ?? .array([])), .init("allowed", .bool(grant != nil)), .init("extension", extensionView(entry.id)), .init("contract", manifest?.contract ?? .null), .init("tools", .array((manifest?.tools ?? []).map { .object([.init("name", .string($0.name)), .init("wire", .string($0.wire(entry.id))), .init("title", .string($0.title)), .init("tier", .string($0.tier))]) }))])
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
            let scoped = wanted.contains(where: PluginCatalog.projectScoped.contains) || manifest.capabilities.contains(where: PluginContract.newCapabilities.contains) && wanted.contains(where: { ["tasks.read", "goals.read"].contains($0) }), known = await services.projects().map(BackendPluginsFiles.real)
            let projects = scoped ? unique(strings(input["projects"]).filter { !$0.isEmpty }.map(BackendPluginsFiles.real)) : []
            guard !closed else { throw BackendPluginsManifestReader.refusal("The app is closing, so nothing was allowed.") }
            if let unknown = projects.first(where: { !known.contains($0) }) { throw BackendPluginsManifestReader.refusal("\(unknown) is not one of your projects in this app.") }
            if scoped && projects.isEmpty { throw BackendPluginsManifestReader.refusal("Choose at least one project for it to read about, or leave that one off.") }
            if let current = grants.valid(id, hash: hash), wanted.allSatisfy(strings(current["capabilities"]).contains), projects.allSatisfy(strings(current["projects"]).contains) {
                await revokeExtension(id, reason: "Plugin access changed; resume explicitly.", projects: projects)
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
            await revokeExtension(id, reason: "Plugin was allowed again; resume explicitly.", projects: projects)
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
                await revokeExtension(id, reason: "Plugin was turned off; resume explicitly.")
                try grants.enabled(id, false); await entry.process?.stop("you turned it off"); entries[id]?.stopped = nil
            } else {
                guard grants.valid(id, hash: entry.hash) != nil else { throw BackendPluginsManifestReader.refusal("Allow it first: it has not been allowed for the files that are in its folder now.") }
                try grants.enabled(id, true); entries[id]?.stopped = nil
            }
            await changed(); if enabled { await tryStart(id, explicit: true) }; return await result()
        } catch { return await result((error as? NativeRPCError)?.message ?? "That did not work: \(error.localizedDescription)") }
    }
    public func remove(_ id: String) async -> NativeRPCValue {
        do {
            let entry = try await (entries[id] == nil ? lookNew(id) : look(id))
            await revokeExtension(id, reason: "Plugin was removed")
            if let stoppingPeer = stoppingPeers[id] { await stoppingPeer.kill("Plugin was removed"); guard !(await stoppingPeer.alive) else { throw PluginContract.invalid("Plugin has not stopped; removal is held") }; stopping[id] = nil; stoppingPeers[id] = nil }
            await entry.process?.stop("it was removed")
            guard let desktop else { throw NativeRPCError(code: "unavailable", message: "The native Trash service is unavailable.") }
            if FileManager.default.fileExists(atPath: entry.folder.path) { try await desktop.trash(entry.folder) }
            let data = userData.appendingPathComponent("plugin-data/" + id)
            if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
            try extensionStore?.forget(id); cardCache[id] = nil
            try grants.forget(id); entries[id] = nil; order.removeAll { $0 == id }; await changed(); return await result()
        } catch { return await result((error as? NativeRPCError)?.code == "plugin-refusal" ? error.localizedDescription : "It could not be removed: \(error.localizedDescription)") }
    }
    public func openFolder() async throws {
        guard let desktop else { throw NativeRPCError(code: "unavailable", message: "The native Finder service is unavailable.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try await desktop.openFolder(folder)
    }
    public func startAll() async { await scan(); for id in order { await tryStart(id) } }
    public func stopAll() async { closed = true; for id in order { await interruptExtension(id, reason: "App closed; resume explicitly.") }; await consent.shutdown(); for entry in entries.values { await entry.process?.stop("the app quit") }; for peer in stoppingPeers.values { await peer.kill("the app quit") } }
    private func tryStart(_ id: String, explicit: Bool = false) async { if !explicit, entries[id]?.manifest?.contract.isNullish == false { return }; do { try await ensureRunning(id) } catch { if entries[id]?.stopped == nil { entries[id]?.stopped = error.localizedDescription } } }
    private func ensureRunning(_ id: String) async throws {
        guard stopping[id] == nil else { throw PluginContract.invalid("The previous plugin generation is still stopping; no replacement job was admitted") }
        if let process = entries[id]?.process, await process.alive { return }
        if let starting = entries[id]?.starting { return try await starting.value }
        let task = Task { try await self.start(id) }; entries[id]?.starting = task
        defer { entries[id]?.starting = nil }; try await task.value
    }
    private func start(_ id: String) async throws {
        guard !closed else { throw BackendPluginsManifestReader.refusal("the app is closing") }
        guard let entry = entries[id], let manifest = entry.manifest, entry.broken == nil else { throw BackendPluginsManifestReader.refusal("it cannot be used: \(entries[id]?.broken ?? "unreadable")") }
        if manifest.capabilities.contains(where: PluginContract.newCapabilities.contains) { _ = try privateStore(id) }
        guard grants.record(id)["enabled"].bool == true else { throw BackendPluginsManifestReader.refusal("it is turned off") }
        let hash = try? fileHashes.hash(entry.folder, limits: folderLimits).hash; entries[id]?.hash = hash
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
            if answer.has("methods") { guard let methods = answer["methods"].elements, methods.count <= 32, methods.allSatisfy({ $0.string != nil }) else { throw PluginContract.invalid("Invalid supported extension method list") } }
            entries[id]?.methods = Set(strings(answer["methods"])).intersection(["ui/read", "jobs/start", "jobs/pause", "events/deliver"])
            guard answer["protocol"].number == 1 else { await process.kill("it does not speak protocol 1"); throw BackendPluginsManifestReader.refusal("it does not speak protocol 1") }
        } catch {
            if (error as? NativeRPCError)?.message == "it does not speak protocol 1" { throw error }
            await process.kill("it did not finish starting (\(error.localizedDescription))"); throw BackendPluginsManifestReader.refusal("it did not finish starting: \(error.localizedDescription)")
        }
        await changed()
    }
    private func processExited(_ id: String, generation: UUID, why: String) async {
        if entries[id]?.generation == generation { await interruptExtension(id, reason: "Plugin stopped; resume explicitly."); entries[id]?.process = nil; entries[id]?.generation = nil; entries[id]?.runningHash = nil; entries[id]?.stopped = why }; await changed()
    }
    private func param(_ params: NativeRPCValue, _ key: String, _ max: Int) throws -> String {
        guard let raw = params[key].string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendPluginsError(-32602, "\(key) is required") }
        guard raw.utf16.count <= max else { throw BackendPluginsError(-32602, "\(key) must be \(max) characters or fewer") }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func answer(_ id: String, generation: UUID, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        if method.hasPrefix("state/") || method.hasPrefix("jobs/") { return try await extensionAnswer(id, generation: generation, method: method, params: params) }
        if entries[id]?.manifest?.capabilities.contains(where: PluginContract.newCapabilities.contains) == true, ["tasks.list", "goals.list", "knowledge.search", "notify"].contains(method) { return try await scopedServiceAnswer(id, generation: generation, method: method, params: params) }
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
        try await BackendPluginTargetFence.verify()
        do { try await ensureRunning(id) } catch { throw BackendPluginsError(-32000, "the plugin “\(manifest.name)” could not be started: \(error.localizedDescription)") }
        if manifest.capabilities.contains(where: PluginContract.newCapabilities.contains) {
            let binding = try await fresh(id, needs: ["tools.contribute"])
            try await BackendPluginTargetFence.verify()
            let result = try await binding.peer.request("tools/call", params: .object([.init("name", .string(tool)), .init("arguments", arguments)]))
            _ = try await fresh(id, needs: ["tools.contribute"], expected: binding)
            try PluginContract.json(result, bytes: 32768); return result
        }
        guard let child = entries[id]?.process else { throw BackendPluginsError(-32000, "the plugin “\(manifest.name)” is not running") }
        return try await child.request("tools/call", params: .object([.init("name", .string(tool)), .init("arguments", arguments)]))
    }
    private func strings(_ value: NativeRPCValue) -> [String] { (value.elements ?? []).compactMap(\.string) }
    private func array(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    private func unique(_ values: [String]) -> [String] { var result: [String] = []; for value in values where !result.contains(value) { result.append(value) }; return result }
}

extension BackendPluginsHost {
    private struct ExtensionBinding {
        let id: String, hash: String, generation: UUID
        let capabilities, projects: [String]
        let manifest: BackendPluginsManifest
        let peer: any BackendPluginsRunningProcess
    }
    private func privateStore(_ id: String) throws -> BackendPluginExtensionStore {
        guard let store = extensionStore else { throw PluginContract.invalid("Private plugin storage is unavailable") }
        let path = BackendPluginsFiles.real(store.persistence.directory.path)
        for forbidden in BackendMacConfinement.systemReadRoots + [folder.path, userData.appendingPathComponent("plugin-data").path, runtime.map(BackendPluginsSandbox.runtimeRoot) ?? "/unavailable-runtime"] {
            let root = BackendPluginsFiles.real(forbidden)
            guard root != "/", path != root, !path.hasPrefix(root + "/") else { throw PluginContract.invalid("Host receipts must be outside child-readable and writable roots") }
        }
        _ = try store.read(id); return store
    }
    private func interruptExtension(_ id: String, reason: String, projects: [String]? = nil) async {
        cardCache[id] = nil
        guard entries[id]?.manifest?.capabilities.contains(where: PluginContract.newCapabilities.contains) == true else { return }
        do { try privateStore(id).interrupt(id, reason: reason, projects: projects) }
        catch { entries[id]?.extensionProblem = "Private extension records could not be saved: " + error.localizedDescription }
    }
    private func revokeExtension(_ id: String, reason: String, projects: [String]? = nil) async {
        guard entries[id]?.manifest?.capabilities.contains(where: PluginContract.newCapabilities.contains) == true else { return }
        if stopping[id] != nil { await interruptExtension(id, reason: reason, projects: projects); return }
        let peer = entries[id]?.process, token = UUID()
        stopping[id] = token; stoppingPeers[id] = peer
        entries[id]?.generation = nil; entries[id]?.process = nil; entries[id]?.runningHash = nil; entries[id]?.methods = []
        await interruptExtension(id, reason: reason, projects: projects)
        await peer?.stop(reason)
        if let peer, await peer.alive { await peer.kill("Plugin stop was not acknowledged") }
        if let peer, await peer.alive { entries[id]?.extensionProblem = "Plugin stop was not acknowledged; replacement work is held"; return }
        if stopping[id] == token { stopping[id] = nil; stoppingPeers[id] = nil }
    }
    private func fresh(_ id: String, needs: [String], project: String? = nil, expected: ExtensionBinding? = nil) async throws -> ExtensionBinding {
        guard !closed, let entry = entries[id], let manifest = entry.manifest, entry.broken == nil,
              let generation = entry.generation, let peer = entry.process else { throw PluginContract.invalid("Plugin is stopped; start it explicitly") }
        let hash: String
        do { hash = try fileHashes.hash(entry.folder, limits: folderLimits).hash }
        catch { await revokeExtension(id, reason: "Plugin files cannot be verified; allow and resume explicitly."); throw error }
        guard hash == entry.runningHash, let grant = grants.valid(id, hash: hash) else {
            await revokeExtension(id, reason: "Plugin files changed; allow and resume explicitly."); throw PluginContract.invalid("Plugin code changed; no new operation is allowed")
        }
        let caps = strings(grant["capabilities"]), projects = strings(grant["projects"])
        guard grants.record(id)["enabled"].bool == true, needs.allSatisfy({ caps.contains($0) && manifest.capabilities.contains($0) }),
              project.map({ projects.contains(BackendPluginsFiles.real($0)) }) ?? true else { throw PluginContract.invalid("The current plugin capability or selected project is not allowed") }
        if let expected { guard expected.generation == generation, expected.hash == hash, expected.capabilities == caps, expected.projects == projects else { throw PluginContract.invalid("Plugin access changed during the request") } }
        guard await peer.alive, entries[id]?.generation == generation else { throw PluginContract.invalid("Plugin generation is no longer running") }
        let known = await services.projects().filter { $0.hasPrefix("/") && !$0.contains("\0") }.map(BackendPluginsFiles.real)
        guard projects.allSatisfy(known.contains) else { throw PluginContract.invalid("A selected project is no longer available") }
        // alive and project lookup are awaits too. Verify actual disk bytes and grant again before
        // returning this point-in-time binding to a host mutation/request.
        let after: String
        do { after = try fileHashes.hash(entry.folder, limits: folderLimits).hash } catch { await revokeExtension(id, reason: "Plugin files became unreadable during verification."); throw error }
        guard after == hash, grants.record(id)["enabled"].bool == true,
              let latest = grants.valid(id, hash: after), strings(latest["capabilities"]) == caps, strings(latest["projects"]) == projects else {
            await revokeExtension(id, reason: "Plugin code or access changed while checking it."); throw PluginContract.invalid("Plugin binding changed")
        }
        return .init(id: id, hash: hash, generation: generation, capabilities: caps, projects: projects, manifest: manifest, peer: peer)
    }
    private func request(_ binding: ExtensionBinding, method: String, params: NativeRPCValue, needs: [String], project: String? = nil, timeout: Int? = nil) async throws -> NativeRPCValue {
        guard entries[binding.id]?.methods.contains(method) == true else { throw PluginContract.invalid("Unavailable: this protocol-1 plugin did not advertise " + method) }
        _ = try await fresh(binding.id, needs: needs, project: project, expected: binding)
        let reply = try await binding.peer.request(method, params: params, timeoutMilliseconds: timeout)
        _ = try await fresh(binding.id, needs: needs, project: project, expected: binding)
        try PluginContract.json(reply, bytes: 32768, depth: 12); return reply
    }
    private func extensionView(_ id: String) -> NativeRPCValue {
        guard entries[id]?.manifest?.capabilities.contains(where: PluginContract.newCapabilities.contains) == true else { return .null }
        do {
            let state = try privateStore(id).read(id)
            return .object([.init("problem", entries[id]?.extensionProblem.map(NativeRPCValue.string) ?? .null), .init("jobs", state["jobs"]), .init("events", state["events"]), .init("cards", cardCache[id] ?? .array([])), .init("methods", array(Array(entries[id]?.methods ?? []).sorted())), .init("note", .string("Saved checkpoints and plugin text are untrusted. Resume is explicit; external work is not exactly once."))])
        } catch { return .object([.init("problem", .string(error.localizedDescription))]) }
    }
    public func extensionChanged() async { await changed() }
    public func extensionTier(_ id: String, input: NativeRPCValue) throws -> BackendMCPTier {
        switch input["op"].string {
        case "read": return .read
        case "job-resume", "events-resume": return .alter
        case "start", "job-start", "job-pause", "events-pause": return .act
        case "card":
            let action = try cardAction(id, input: input)
            if action["kind"].string == "tool", let tool = entries[id]?.manifest?.tools.first(where: { $0.name == action["target"].string }) { return BackendMCPTier(rawValue: tool.tier)! }
            return .act
        default: throw PluginContract.invalid("Unknown plugin extension operation")
        }
    }
    public func nativeCardTarget(_ id: String, input: NativeRPCValue) throws -> String? {
        guard input["op"].string == "card" else { return nil }
        let action = try cardAction(id, input: input)
        guard action["kind"].string == "tool", let target = action["target"].string else { return nil }
        return "plugin." + id + "." + target
    }
    private func cardAction(_ id: String, input: NativeRPCValue) throws -> NativeRPCValue {
        guard let card = entries[id]?.manifest?.contract["cards"].elements?.first(where: { $0["id"] == input["card"] }),
              let action = card["actions"].elements?.first(where: { $0["id"] == input["action"] }) else { throw PluginContract.invalid("No such manifest-declared card action") }; return action
    }
    public func extensionContributors() -> [(String, BackendPluginsManifest)] {
        order.compactMap { id in
            guard let entry = entries[id], let manifest = entry.manifest, !manifest.contract.isNullish,
                  grants.record(id)["enabled"].bool == true, grants.valid(id, hash: entry.hash) != nil else { return nil }; return (id, manifest)
        }
    }
    /// Called only from the shared authorized tool/native dispatcher. The peer
    /// cannot invoke owner controls through child-to-host RPC.
    public func extensionControl(_ id: String, input: NativeRPCValue, targetDispatch: (@Sendable (String, NativeRPCValue, @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue)? = nil) async throws -> NativeRPCValue {
        try PluginContract.closed(input, ["op", "card", "action", "job", "project", "input", "request"], "plugin control")
        _ = try extensionTier(id, input: input)
        let op = input["op"].string ?? ""
        if op == "start" { try await ensureRunning(id); _ = try await fresh(id, needs: []); await changed(); return extensionView(id) }
        if op == "events-pause" {
            _ = try await fresh(id, needs: ["events.receive"])
            _ = try privateStore(id).change(id) { $0.setting("events", $0["events"].setting("paused", .bool(true))) }
            await pauseJob(id); await changed(); return extensionView(id)
        }
        if op == "job-pause" { await pauseJob(id); await changed(); return extensionView(id) }
        if op == "events-resume" {
            try await ensureRunning(id); _ = try await fresh(id, needs: ["events.receive", "tasks.read", "jobs.run"])
            _ = try privateStore(id).change(id) { $0.setting("events", $0["events"].setting("paused", .bool(false))) }
            await drainEvents(id); await changed(); return extensionView(id)
        }
        if op == "job-start" || op == "job-resume" {
            _ = try await startJob(id, job: input["job"].string ?? "", project: input["project"].string ?? "", input: input["input"].isNullish ? .object([]) : input["input"], receipt: try PluginContract.text(input["request"], limit: 100), resume: op == "job-resume")
            await changed(); return extensionView(id)
        }
        if op == "card" {
            let action = try cardAction(id, input: input), project = try PluginContract.text(input["project"], limit: 4096)
            let binding = try await fresh(id, needs: ["ui.contribute"], project: project)
            guard cardCache[id]?.elements?.contains(where: { $0["id"] == input["card"] && $0["project"].string == BackendPluginsFiles.real(project) }) == true else { throw PluginContract.invalid("Read a current card for this project before using its controls") }
            if action["kind"].string == "job" {
                _ = try await startJob(id, job: action["target"].string!, project: project, input: input["input"].isNullish ? .object([]) : input["input"], receipt: try PluginContract.text(input["request"], limit: 100), resume: false, expected: binding)
            } else {
                guard let tool = binding.manifest.tools.first(where: { $0.name == action["target"].string }) else { throw PluginContract.invalid("Unknown declared tool") }
                let args = input["input"].isNullish ? NativeRPCValue.object([]) : input["input"]
                try BackendDeckCoreCatalogueSchema.check(tool: .init(id: tool.actionID(id), wireName: tool.wire(id), description: tool.description, inputSchema: tool.inputSchema, tier: .init(rawValue: tool.tier)!), arguments: args)
                guard let targetDispatch else { throw PluginContract.invalid("Declared tool card actions require the shared target dispatcher") }
                let answer = try await targetDispatch(tool.actionID(id), args, { _ = try await self.fresh(id, needs: ["ui.contribute", "tools.contribute"], project: project, expected: binding) })
                _ = try await fresh(id, needs: ["ui.contribute", "tools.contribute"], project: project, expected: binding)
                try PluginContract.json(answer, bytes: 32768); return .object([.init("result", answer)])
            }
            await changed(); return extensionView(id)
        }
        let binding = try await fresh(id, needs: ["ui.contribute"])
        let reply = try await request(binding, method: "ui/read", params: .object([.init("projects", array(binding.projects))]), needs: ["ui.contribute"])
        try PluginContract.closed(reply, ["cards"], "ui/read")
        guard let cards = reply["cards"].elements, cards.count <= 4 else { throw PluginContract.invalid("At most four native cards") }
        var identities = Set<String>()
        for card in cards {
            guard identities.insert((card["id"].string ?? "") + "\0" + (card["project"].string ?? "")).inserted else { throw PluginContract.invalid("Repeated native card identity") }
            try PluginContract.closed(card, ["id", "project", "summary", "status", "fields"], "native card")
            guard let declared = binding.manifest.contract["cards"].elements?.first(where: { $0["id"] == card["id"] }), binding.projects.contains(card["project"].string ?? "") else { throw PluginContract.invalid("Card identity/project is not currently allowed") }
            _ = try PluginContract.text(card["summary"], limit: 500); _ = try PluginContract.text(card["status"], limit: 80)
            let allowed = Set((declared["fields"].elements ?? []).compactMap { $0["id"].string })
            try PluginContract.closed(card["fields"], allowed, "card fields")
            for field in card["fields"].fields ?? [] { guard field.value.string != nil || field.value.bool != nil || field.value.number != nil else { throw PluginContract.invalid("Card fields are scalar text, booleans or numbers") }; try PluginContract.json(field.value, bytes: 1024) }
        }
        _ = try await fresh(id, needs: ["ui.contribute"], expected: binding)
        cardCache[id] = .array(cards); return extensionView(id)
    }
    private func startJob(_ id: String, job: String, project rawProject: String, input: NativeRPCValue, receipt: String, resume: Bool, expected: ExtensionBinding? = nil) async throws -> NativeRPCValue {
        guard rawProject.hasPrefix("/"), !rawProject.contains("\0") else { throw PluginContract.invalid("A job needs an actual selected absolute project") }
        try PluginContract.json(input)
        try await ensureRunning(id)
        let project = BackendPluginsFiles.real(rawProject), binding = try await fresh(id, needs: ["jobs.run"], project: project, expected: expected)
        guard let definition = binding.manifest.contract["jobs"].elements?.first(where: { $0["id"].string == job }) else { throw PluginContract.invalid("No such declared job") }
        try BackendDeckCoreCatalogueSchema.check(tool: .init(id: "plugin.job", wireName: "plugin_job", description: "Job input", inputSchema: definition["inputSchema"], tier: .act), arguments: input)
        guard entries[id]?.methods.contains("jobs/start") == true else { throw PluginContract.invalid("Unavailable: plugin did not advertise jobs/start") }
        let store = try privateStore(id), prior = try store.read(id)["jobs"].elements ?? []
        if let replay = prior.first(where: { $0["request"].string == receipt || $0["resumeRequest"].string == receipt }) {
            guard replay["job"].string == job, replay["project"].string == project, PluginContract.equal(replay["input"], input) else { throw PluginContract.invalid("Request receipt already belongs to different job inputs") }; return replay
        }
        guard !prior.contains(where: { ["queued", "running", "pause-requested"].contains($0["state"].string ?? "") }) else { throw PluginContract.invalid("One active job per plugin; the new request was not admitted") }
        let attempt = UUID().uuidString.lowercased(), record: NativeRPCValue
        var jobs = prior
        if resume {
            guard let index = jobs.lastIndex(where: { $0["job"].string == job && $0["project"].string == project && ["paused", "interrupted"].contains($0["state"].string ?? "") }), PluginContract.equal(jobs[index]["input"], input), (jobs[index]["attempts"].elements?.count ?? 0) < 16 else { throw PluginContract.invalid("Only an unchanged paused/interrupted job can resume; inspect its input/checkpoint") }
            record = jobs[index].setting("attempt", .string(attempt)).setting("resumeRequest", .string(receipt)).setting("state", .string("queued")).setting("generation", .string(binding.generation.uuidString)).setting("hash", .string(binding.hash)).setting("attempts", .array((jobs[index]["attempts"].elements ?? []) + [.string(attempt)]))
            jobs[index] = record
        } else {
            // Review paperclip #2: finished jobs beyond a short history are dropped, so history never refuses forever,
            // and a new job needs room to finish inside the 1 MB state cap.
            jobs = Self.trimmedJobHistory(jobs)
            guard jobs.count < 100 else { throw PluginContract.invalid("Job history is full (100); no new job admitted") }
            guard try store.read(id).setting("jobs", .array(jobs)).encodedJSON().count <= 1024 * 1024 - Self.jobHeadroomBytes else {
                throw PluginContract.invalid("Plugin saved state is nearly full; clear old jobs or state before starting another job")
            }
            record = .object([.init("id", .string(UUID().uuidString.lowercased())), .init("job", .string(job)), .init("project", .string(project)), .init("input", input), .init("request", .string(receipt)), .init("attempt", .string(attempt)), .init("attempts", .array([.string(attempt)])), .init("generation", .string(binding.generation.uuidString)), .init("hash", .string(binding.hash)), .init("state", .string("queued")), .init("checkpoint", .null), .init("progress", .array([]))])
            jobs.append(record)
        }
        _ = try store.change(id) { $0.setting("jobs", .array(jobs)) } // durable before dispatch
        do {
            let accepted = try await request(binding, method: "jobs/start", params: .object([.init("job", .string(job)), .init("id", record["id"]), .init("attempt", .string(attempt)), .init("request", .string(receipt)), .init("project", .string(project)), .init("input", input), .init("checkpoint", record["checkpoint"]), .init("checkpointUntrusted", .bool(true))]), needs: ["jobs.run"], project: project)
            guard accepted["accepted"].bool == true, accepted["attempt"].string == attempt else { throw PluginContract.invalid("Job start was not acknowledged") }
            try updateJob(id, record["id"], attempt: attempt) { $0["state"].string == "queued" ? $0.setting("state", .string("running")) : $0 }
        } catch {
            let current = try store.read(id)["jobs"].elements?.first { $0["id"] == record["id"] && $0["attempt"].string == attempt }
            if ["queued", "running", "pause-requested"].contains(current?["state"].string ?? "") {
                try updateJob(id, record["id"], attempt: attempt) { $0.setting("state", .string("interrupted")).setting("reason", .string("Start outcome is uncertain; plugin stopped. Inspect and resume explicitly.")) }
                if entries[id]?.generation == binding.generation { await revokeExtension(id, reason: "Unacknowledged job start; old generation stopped before replacement.") }
            }
            throw error
        }
        return try store.read(id)["jobs"].elements?.first { $0["id"] == record["id"] } ?? record
    }
    static let finishedJobHistory = 20, progressBytesPerJob = 32 * 1024, jobHeadroomBytes = 128 * 1024
    /// Keeps every job that can still run or resume, and only the newest finished ones.
    static func trimmedJobHistory(_ jobs: [NativeRPCValue]) -> [NativeRPCValue] {
        let finished = jobs.indices.filter { ["completed", "failed"].contains(jobs[$0]["state"].string ?? "") }
        let dropped = Set(finished.dropLast(finishedJobHistory - 1))
        return jobs.indices.filter { !dropped.contains($0) }.map { jobs[$0] }
    }
    /// Plain progress notes are dropped oldest first past a per-job byte budget; checkpoints and the completion stay.
    static func trimmedProgress(_ progress: [NativeRPCValue]) throws -> [NativeRPCValue] {
        var rows = progress
        while try NativeRPCValue.array(rows).encodedJSON().count > progressBytesPerJob,
              let oldest = rows.dropLast().firstIndex(where: { $0["method"].string == "jobs/progress" }) { rows.remove(at: oldest) }
        return rows
    }
    private func updateJob(_ id: String, _ jobID: NativeRPCValue, attempt: String, _ update: (NativeRPCValue) throws -> NativeRPCValue) throws {
        _ = try privateStore(id).change(id) { state in
            guard let index = state["jobs"].elements?.firstIndex(where: { $0["id"] == jobID && $0["attempt"].string == attempt }) else { throw PluginContract.invalid("Old job attempt is no longer current") }
            var jobs = state["jobs"].elements!; jobs[index] = try update(jobs[index]); return state.setting("jobs", .array(jobs))
        }
    }
    private func pauseJob(_ id: String) async {
        do {
            let binding = try await fresh(id, needs: ["jobs.run"])
            guard let job = try privateStore(id).read(id)["jobs"].elements?.last(where: { ["queued", "running", "pause-requested"].contains($0["state"].string ?? "") }), let attempt = job["attempt"].string else { return }
            try updateJob(id, job["id"], attempt: attempt) { $0.setting("state", .string("pause-requested")) }
            let answer = try await request(binding, method: "jobs/pause", params: .object([.init("id", job["id"]), .init("attempt", .string(attempt))]), needs: ["jobs.run"], project: job["project"].string, timeout: 2000)
            guard answer["paused"].bool == true, answer["attempt"].string == attempt else { throw PluginContract.invalid("Pause was not acknowledged") }
            try updateJob(id, job["id"], attempt: attempt) { $0["state"].string == "pause-requested" ? $0.setting("state", .string("paused")) : $0 }
        } catch { await revokeExtension(id, reason: "Pause was not acknowledged; plugin stopped and job interrupted.") }
    }
    private func extensionAnswer(_ id: String, generation: UUID, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        let cap = method.hasPrefix("state/") ? (["state/get", "state/list"].contains(method) ? "state.read" : "state.write") : "jobs.run"
        let binding = try await fresh(id, needs: [cap])
        guard binding.generation == generation else { throw PluginContract.invalid("Old child generation cannot change extension state") }
        if method.hasPrefix("state/") { guard ["state/get", "state/list", "state/put", "state/delete"].contains(method) else { throw PluginContract.invalid("Unknown state method") }; return try privateStore(id).kv(id, method: method, input: params) }
        guard ["jobs/progress", "jobs/checkpoint", "jobs/complete"].contains(method) else { throw PluginContract.invalid("Children cannot start/resume/pause owner jobs") }
        try PluginContract.closed(params, ["id", "attempt", "receipt", "value", "failed"], method)
        let attempt = try PluginContract.text(params["attempt"], limit: 64), receipt = try PluginContract.text(params["receipt"], limit: 100)
        try PluginContract.json(params["value"])
        try updateJob(id, params["id"], attempt: attempt) { row in
            guard row["generation"].string == generation.uuidString, row["hash"].string == binding.hash, binding.projects.contains(row["project"].string ?? "") else { throw PluginContract.invalid("Job project/generation is not allowed") }
            var progress = row["progress"].elements ?? []
            if let old = progress.first(where: { $0["receipt"].string == receipt }) { guard old["method"].string == method, old["failed"].bool == params["failed"].bool, PluginContract.equal(old["value"], params["value"]) else { throw PluginContract.invalid("Progress receipt conflicts") }; return row }
            guard ["queued", "running", "pause-requested"].contains(row["state"].string ?? ""), progress.count < (method == "jobs/complete" ? 50 : 49) else { throw PluginContract.invalid("Job is held/finished or its progress limit is full") }
            progress.append(.object([.init("receipt", .string(receipt)), .init("method", .string(method)), .init("failed", params["failed"].bool.map(NativeRPCValue.bool) ?? .null), .init("value", params["value"])]))
            progress = try Self.trimmedProgress(progress)
            var next = row.setting("progress", .array(progress))
            if method == "jobs/checkpoint" { next = next.setting("checkpoint", params["value"]) }
            if method == "jobs/complete" { next = next.setting("state", .string(params["failed"].bool == true ? "failed" : "completed")) }
            return next
        }
        await changed()
        if method == "jobs/complete" { Task { await self.drainEvents(id) } }
        return .object([.init("acknowledged", .bool(true)), .init("receipt", .string(receipt))])
    }
    public func setTaskPulseSource(_ read: @escaping @Sendable () async throws -> [BackendTaskRecord]) { taskPulseTasks = read }
    public func noteTaskRows(_ rows: [BackendTaskRecord]) async {
        guard !closed else { return }
        do { for event in try extensionStore?.finished(rows) ?? [] { await taskFinished(event) } }
        catch { for id in order where entries[id]?.manifest?.contract.isNullish == false { entries[id]?.stopped = "Task pulse source held: " + error.localizedDescription }; await changed() }
    }
    private func eventGrant(_ id: String, project: String, expected: NativeRPCValue? = nil) async throws -> NativeRPCValue {
        guard project.hasPrefix("/"), !project.contains("\0"), !closed, let entry = entries[id], let manifest = entry.manifest else { throw PluginContract.invalid("No actual scoped event project") }
        let hash: String
        do { hash = try fileHashes.hash(entry.folder, limits: folderLimits).hash } catch { await revokeExtension(id, reason: "Plugin files cannot be verified for event admission."); throw error }
        guard let grant = grants.valid(id, hash: hash) else { await revokeExtension(id, reason: "Plugin code changed before event admission."); throw PluginContract.invalid("Event code hash changed") }
        let caps = strings(grant["capabilities"]), projects = strings(grant["projects"])
        guard grants.record(id)["enabled"].bool == true, ["events.receive", "tasks.read", "jobs.run"].allSatisfy({ caps.contains($0) && manifest.capabilities.contains($0) }), projects.contains(project) else { throw PluginContract.invalid("Event project/capabilities not allowed") }
        let stamp = NativeRPCValue.object([.init("hash", .string(hash)), .init("capabilities", grant["capabilities"]), .init("projects", grant["projects"])])
        if let expected { guard PluginContract.equal(expected, stamp) else { throw PluginContract.invalid("Event access changed") } }
        let known = await services.projects().filter { $0.hasPrefix("/") && !$0.contains("\0") }.map(BackendPluginsFiles.real)
        let afterHash: String
        do { afterHash = try fileHashes.hash(entry.folder, limits: folderLimits).hash } catch { await revokeExtension(id, reason: "Plugin files changed during event lookup."); throw error }
        guard known.contains(project), afterHash == hash,
              grants.record(id)["enabled"].bool == true, let current = grants.valid(id, hash: hash), current["capabilities"] == grant["capabilities"], current["projects"] == grant["projects"] else {
            await revokeExtension(id, reason: "Event code/project access changed during lookup."); throw PluginContract.invalid("Event access changed")
        }
        return stamp
    }
    private func taskFinished(_ event: NativeRPCValue) async {
        for id in order where entries[id]?.manifest?.contract["events"].elements?.isEmpty == false {
            guard !closed, grants.record(id)["enabled"].bool == true, strings(grants.record(id)["grant"]["projects"]).contains(event["project"].string ?? ""), ["events.receive", "tasks.read", "jobs.run"].allSatisfy(strings(grants.record(id)["grant"]["capabilities"]).contains) else { continue }
            do {
                let project = try PluginContract.text(event["project"], limit: 4096)
                let stamp = try await eventGrant(id, project: project)
                guard let read = taskPulseTasks else { continue }
                let rows = try await read()
                _ = try await eventGrant(id, project: project, expected: stamp)
                guard rows.contains(where: { $0.id == event["taskID"].string && BackendPluginsFiles.real($0.project) == event["project"].string }) else { continue }
                _ = try privateStore(id).change(id) { state in
                    let events = state["events"], pending = events["pending"].elements ?? [], acknowledged = events["acknowledged"].elements ?? []
                    guard !pending.contains(where: { $0["id"] == event["id"] }), !acknowledged.contains(event["id"]) else { return state }
                    if pending.count >= 50 { return state.setting("events", events.setting("overflow", .number((events["overflow"].number ?? 0) + 1)).setting("paused", .bool(true))) }
                    return state.setting("events", events.setting("pending", .array(pending + [event.setting("attempts", .number(0))])))
                }
                await drainEvents(id)
            } catch { entries[id]?.extensionProblem = "A task event was not admitted: " + error.localizedDescription }
        }
        await changed()
    }
    private func drainEvents(_ id: String) async {
        guard !draining.contains(id) else { return }; draining.insert(id); defer { draining.remove(id) }
        do {
            while true {
                let state = try privateStore(id).read(id)
                guard state["events"]["paused"].bool == false, let event = state["events"]["pending"].elements?.first else { return }
                guard !((state["jobs"].elements ?? []).contains { ["queued", "running", "pause-requested", "paused", "interrupted"].contains($0["state"].string ?? "") }) else { return }
                let binding = try await fresh(id, needs: ["events.receive", "tasks.read", "jobs.run"], project: event["project"].string)
                guard let read = taskPulseTasks else { throw PluginContract.invalid("Task source unavailable") }
                let rows = try await read()
                _ = try await fresh(id, needs: ["events.receive", "tasks.read", "jobs.run"], project: event["project"].string, expected: binding)
                guard rows.contains(where: { $0.id == event["taskID"].string && BackendPluginsFiles.real($0.project) == event["project"].string }) else { throw PluginContract.invalid("Task is no longer in the selected source scope") }
                let attempts = try privateStore(id).integer(event["attempts"])
                guard attempts < 3 else { throw PluginContract.invalid("Event retry limit reached; held for inspection") }
                _ = try privateStore(id).change(id) { state in
                    var pending = state["events"]["pending"].elements ?? []; guard pending.first?["id"] == event["id"] else { throw PluginContract.invalid("Event queue changed") }; pending[0] = event.setting("attempts", .number(Double(attempts + 1))); return state.setting("events", state["events"].setting("pending", .array(pending)))
                }
                let answer = try await request(binding, method: "events/deliver", params: event, needs: ["events.receive", "tasks.read", "jobs.run"], project: event["project"].string)
                guard answer["acknowledged"].bool == true, answer["id"] == event["id"] else { throw PluginContract.invalid("Event was not acknowledged") }
                if let subscription = binding.manifest.contract["events"].elements?.first {
                    _ = try await startJob(id, job: subscription["job"].string!, project: event["project"].string!, input: subscription["input"], receipt: "event-" + event["id"].string!, resume: false, expected: binding)
                }
                _ = try privateStore(id).change(id) { state in
                    let events = state["events"], pending = (events["pending"].elements ?? []).filter { $0["id"] != event["id"] }
                    let acknowledged = Array(((events["acknowledged"].elements ?? []) + [event["id"]]).suffix(100))
                    return state.setting("events", events.setting("pending", .array(pending)).setting("acknowledged", .array(acknowledged)))
                }
            }
        } catch {
            do { _ = try privateStore(id).change(id) { $0.setting("events", $0["events"].setting("paused", .bool(true)).setting("problem", .string(error.localizedDescription))) } }
            catch { entries[id]?.stopped = "Event queue persistence failed: " + error.localizedDescription }
        }
    }
}

extension BackendPluginsHost {
    private func scopedServiceAnswer(_ id: String, generation: UUID, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        let needed = ["tasks.list": "tasks.read", "goals.list": "goals.read", "knowledge.search": "knowledge.read", "notify": "notify"][method]!
        let scope: String?
        if ["goals.list", "knowledge.search"].contains(method) {
            let raw = try PluginContract.text(params["project"], limit: 4096)
            guard raw.hasPrefix("/"), !raw.contains("\0") else { throw PluginContract.invalid("Choose an actual absolute project") }; scope = BackendPluginsFiles.real(raw)
        } else { scope = nil }
        let binding = try await fresh(id, needs: [needed], project: scope)
        guard binding.generation == generation else { throw PluginContract.invalid("Old child generation") }
        switch method {
        case "tasks.list":
            try PluginContract.closed(params, [], method)
            let values: [NativeRPCValue]
            if let taskPulseTasks { values = try await taskPulseTasks().map(\.value) }
            else if let read = services.tasks { values = try await read() }
            else { throw PluginContract.invalid("Task pulse source is unavailable") }
            _ = try await fresh(id, needs: [needed], expected: binding)
            let selected = values.filter { row in
                guard let path = row["project"].string, path.hasPrefix("/"), !path.contains("\0") else { return false }
                return binding.projects.contains(BackendPluginsFiles.real(path))
            }
            let shown = selected.prefix(500).map { row in NativeRPCValue.object([.init("id", row["id"]), .init("title", .string(BackendPluginsText.prefix(row["title"].string ?? "Task", 120))), .init("project", .string(BackendPluginsFiles.real(row["project"].string!))), .init("status", row["crmStatus"].string.map(NativeRPCValue.string) ?? row["status"].string.map(NativeRPCValue.string) ?? .null), .init("updatedAt", row["updatedAt"].number.map(NativeRPCValue.number) ?? .null)]) }
            return .object([.init("tasks", .array(shown)), .init("truncated", .bool(selected.count > 500))])
        case "goals.list":
            try PluginContract.closed(params, ["project"], method)
            guard let read = services.goals else { throw PluginContract.invalid("Goals are unavailable") }
            let rows = try await read(scope)
            _ = try await fresh(id, needs: [needed], project: scope, expected: binding)
            return .object([.init("goals", .array(rows.filter { $0["project"].string.map(BackendPluginsFiles.real) == scope }.prefix(500).map { row in .object([.init("id", row["id"]), .init("title", .string(BackendPluginsText.prefix(row["title"].string ?? "Goal", 120))), .init("project", .string(scope!)), .init("status", row["status"].string.map(NativeRPCValue.string) ?? .null)]) }))])
        case "knowledge.search":
            try PluginContract.closed(params, ["project", "query", "limit"], method)
            guard let read = services.knowledge else { throw PluginContract.invalid("Knowledge is unavailable") }
            let query = try param(params, "query", 500), limit = Int(min(max(params["limit"].number ?? 5, 1), 20).rounded(.towardZero))
            let value = try await read(scope!, query, limit)
            _ = try await fresh(id, needs: [needed], project: scope, expected: binding)
            try PluginContract.json(value, bytes: 32768); return value
        default:
            try PluginContract.closed(params, ["title", "body"], method)
            let title = try param(params, "title", 80), body = BackendPluginsText.prefix(params["body"].string ?? "", 300), time = now()
            entries[id]?.notified.removeAll { time - $0 >= 60_000 }
            guard (entries[id]?.notified.count ?? 0) < 5, let notify = services.notify else { throw PluginContract.invalid("Notifications unavailable or five-per-minute bound reached") }
            entries[id]?.notified.append(time)
            let delivered = try await notify(binding.manifest.name, title, body)
            _ = try await fresh(id, needs: [needed], expected: binding)
            return .object([.init("delivered", .bool(delivered))])
        }
    }
}
