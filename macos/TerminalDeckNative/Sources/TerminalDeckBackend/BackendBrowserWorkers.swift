import Foundation
import TerminalDeckNativeCore

public struct BackendBrowserWorkerProfile: Codable, Sendable {
    public let id: String
    public let name: String
    public let partition: String?
    public init(id: String, name: String, partition: String? = nil) { self.id = id; self.name = name; self.partition = partition }
}

public struct BackendBrowserWorkerHooks: Sendable {
    /// Enumerate only profiles visible to this authenticated caller.
    public let profiles: @Sendable (BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile]
    public let createProfile: @Sendable (BackendBrowserScrapingCaller, String) async throws -> BackendBrowserWorkerProfile
    /// Pages and queued storage are metadata only, never cookie values.
    public let pages: @Sendable (BackendBrowserScrapingCaller, String) async throws -> NativeRPCValue
    public let authorize: BackendBrowserScrapingAuthorize
    public init(profiles: @escaping @Sendable (BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile],
                createProfile: @escaping @Sendable (BackendBrowserScrapingCaller, String) async throws -> BackendBrowserWorkerProfile,
                pages: @escaping @Sendable (BackendBrowserScrapingCaller, String) async throws -> NativeRPCValue,
                authorize: @escaping BackendBrowserScrapingAuthorize) {
        self.profiles = profiles; self.createProfile = createProfile; self.pages = pages; self.authorize = authorize
    }
}

/// Profiles survive unregister/relaunch; leases are memory only. Actor
/// serialization prevents two callers reserving the same cookie jar at once.
public actor BackendBrowserWorkers {
    public static let maximum = 16
    public static let maximumPaceMS = 30_000
    private let paths: BackendBrowserScrapingPaths
    private let hooks: BackendBrowserWorkerHooks
    private let changed: @Sendable () async -> Void
    private var loaded = false
    private var ids: [String] = []
    private var pace = NativeRPCValue.object([.init("maxConcurrent", .number(3)), .init("minDelayMs", .number(1_500)), .init("jitterMs", .number(1_000))])
    private struct Lease: Sendable { let token: UUID; let holder: String; let takenAt: Double; var expiresAt: Double }
    private var leases: [String: Lease] = [:]
    private var released: [String: Double] = [:]
    // Reservations block mutations while an injected async profile creator runs.
    private var minting = false
    public init(dataRoot: URL, hooks: BackendBrowserWorkerHooks, changed: @escaping @Sendable () async -> Void) {
        paths = .init(dataRoot: dataRoot); self.hooks = hooks; self.changed = changed
    }
    private func load() throws {
        guard !loaded else { return }
        let url = try paths.checked(paths.dataRoot.appendingPathComponent("browser-workers.json"))
        if FileManager.default.fileExists(atPath: url.path) {
            let raw = try NativeRPCValue.parseJSON(BackendBrowserScrapingIO.read(url, maxBytes: 1_048_576))
            ids = []
            for value in raw["workers"].elements ?? [] {
                guard let id = value.string, id != "default", (try? BackendBrowserScrapingPaths.component(id)) != nil,
                      !ids.contains(id), ids.count < Self.maximum else { continue }
                ids.append(id)
            }
            pace = Self.cleanPace(raw["pace"])
        }
        loaded = true
    }
    private func save() throws {
        try BackendBrowserScrapingIO.write(.object([.init("workers", .array(ids.map(NativeRPCValue.string))), .init("pace", pace)]),
                                          to: paths.dataRoot.appendingPathComponent("browser-workers.json"), paths: paths)
    }
    public static func cleanPace(_ raw: NativeRPCValue) -> NativeRPCValue {
        let minimum = BackendBrowserScrapingIO.integer(raw["minDelayMs"], default: 1_500, max: maximumPaceMS)
        return .object([.init("maxConcurrent", .number(Double(BackendBrowserScrapingIO.integer(raw["maxConcurrent"], default: 3, min: 1, max: maximum)))),
                        .init("minDelayMs", .number(Double(minimum))),
                        .init("jitterMs", .number(Double(BackendBrowserScrapingIO.integer(raw["jitterMs"], default: 1_000, max: maximumPaceMS - minimum))))])
    }
    private func sweep() {
        let now = BackendBrowserScrapingIO.now()
        for (id, lease) in leases where lease.expiresAt <= now { leases[id] = nil; released[id] = now }
    }
    public func view(_ caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await hooks.authorize(caller, "browser.workers", nil, nil, .object([])); try load(); sweep()
        let profiles = try await hooks.profiles(caller)
        var rows: [NativeRPCValue] = []
        for id in ids {
            guard let profile = profiles.first(where: { $0.id == id }) else { continue }
            try await hooks.authorize(caller, "browser.workers", id, nil, .object([]))
            let pages = try await hooks.pages(caller, id), lease = leases[id], now = BackendBrowserScrapingIO.now()
            // Another caller's identity is private. Only publish the fact busy.
            rows.append(.object([.init("profileId", .string(id)), .init("name", .string(profile.name)),
                .init("partition", profile.partition.map(NativeRPCValue.string) ?? .null), .init("busy", .bool(lease != nil)),
                .init("holder", .string(lease?.holder == caller.holder ? caller.holder : "")),
                .init("heldMs", .number(lease.map { max(0, now - $0.takenAt) } ?? 0)),
                .init("readyInMs", .number(max(0, (released[id] ?? 0) + (pace["minDelayMs"].number ?? 0) - now))),
                .init("lastReleasedAt", .number(released[id] ?? 0)), .init("pages", pages), .init("queued", .array([]))]))
        }
        return .object([.init("workers", .array(rows)), .init("pace", pace), .init("paceNote", .string("")),
            .init("lifts", .array([])), .init("canSeedStorage", .bool(false)), .init("max", .number(Double(Self.maximum))),
            .init("liftLimitation", .string("Authorized WebKit cookie/storage transfer is not wired; no Chrome fallback is used."))])
    }
    /// Compose ONLY a freshly queried, caller-authorized lift service view.
    /// Neither a tool argument nor cached UI metadata is a transfer state source.
    public static func applyingTransferState(_ state: NativeRPCValue, to view: NativeRPCValue) throws -> NativeRPCValue {
        _ = try state.requireObject("current session transfer state")
        let lifts = try state["lifts"].requireArray("current held lift summaries")
        let pending = try state["queued"].requireArray("current queued storage summaries")
        guard let canSeed = state["canSeedStorage"].bool else { throw BackendBrowserScrapingError.invalid("The supplied transfer service did not report its current storage capability.") }
        let workers = try view["workers"].requireArray("worker rows")
        let visible = Set(workers.compactMap { $0["profileId"].string })
        let queued = pending.filter { row in row["profileId"].string.map { visible.contains($0) } == true }
        let rows = workers.map { worker -> NativeRPCValue in
            let profile = worker["profileId"].string
            let summaries = queued.filter { $0["profileId"].string == profile }.map { row in
                NativeRPCValue.object([.init("origin", row["origin"]), .init("keys", row["keys"]),
                    .init("expiresAt", row["expiresAt"]), .init("pending", row["pending"])])
            }
            return worker.setting("queued", .array(summaries))
        }
        var result = view.removing("liftLimitation").setting("workers", .array(rows)).setting("lifts", .array(lifts))
            .setting("queued", .array(queued)).setting("canSeedStorage", .bool(canSeed))
        if !state["seedTiming"].isNullish { result = result.setting("seedTiming", state["seedTiming"]) }
        if !canSeed { result = result.setting("liftLimitation", .string("The supplied transfer service reports storage seeding unavailable.")) }
        return result
    }
    public func ensure(_ count: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await hooks.authorize(caller, "browser.scraping.workers", nil, nil, count); try load()
        guard !minting else { throw NativeRPCError(code: "busy", message: "Worker profile creation is already in progress.") }
        minting = true; defer { minting = false }
        let wanted = BackendBrowserScrapingIO.integer(count, default: 0, max: Self.maximum)
        let profiles = try await hooks.profiles(caller)
        // Stale rows never cause an invisible worker to count as usable.
        let visible = Set(profiles.map(\.id)); var current = ids.filter { visible.contains($0) }.count
        let numbers = profiles.compactMap { profile -> Int? in
            guard profile.name.hasPrefix("Worker ") else { return nil }; return Int(profile.name.dropFirst(7))
        }
        var number = (numbers.max() ?? 0) + 1
        while current < wanted && ids.count < Self.maximum {
            try Task.checkCancellation()
            let profile = try await hooks.createProfile(caller, "Worker \(number)")
            _ = try BackendBrowserScrapingPaths.component(profile.id)
            guard profile.id != "default", !ids.contains(profile.id) else { throw BackendBrowserScrapingError.invalid("A new worker needs a distinct non-default profile.") }
            try await hooks.authorize(caller, "browser.scraping.addworker", profile.id, nil, .object([]))
            ids.append(profile.id); try save(); current += 1; number += 1
        }
        await changed(); return try await view(caller)
    }
    public func register(_ id: String, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await hooks.authorize(caller, "browser.scraping.addworker", id, nil, .object([])); try load()
        guard !minting else { throw NativeRPCError(code: "busy", message: "Worker profile creation is in progress.") }
        guard id != "default", try await hooks.profiles(caller).contains(where: { $0.id == id }) else {
            throw BackendBrowserScrapingError.invalid("Only an existing non-default profile can become a worker.")
        }
        if !ids.contains(id) {
            guard ids.count < Self.maximum else { throw BackendBrowserScrapingError.invalid("There are already 16 worker profiles.") }
            ids.append(id); do { try save() } catch { ids.removeAll { $0 == id }; throw error }
            await changed()
        }
        return try await view(caller)
    }
    public func unregister(_ id: String, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await hooks.authorize(caller, "browser.scraping.removeworker", id, nil, .object([])); try load()
        guard !minting else { throw NativeRPCError(code: "busy", message: "Worker profile creation is in progress.") }
        let previous = ids; ids.removeAll { $0 == id }
        do { try save() } catch { ids = previous; throw error }
        leases[id] = nil; released[id] = nil
        await changed(); return try await view(caller)
    }
    public func setPace(_ value: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await hooks.authorize(caller, "browser.scraping.pace", nil, nil, value); try load()
        let old = pace; pace = Self.cleanPace(value)
        do { try save() } catch { pace = old; throw error }
        await changed()
        let note = ["maxConcurrent", "minDelayMs", "jitterMs"].contains { value[$0].number != nil && value[$0].number != pace[$0].number }
            ? "Pace is bounded to 16 workers and a total wait of 30000 ms." : ""
        return try await view(caller).setting("paceNote", .string(note))
    }
    public func take(worker: String?, holdMS: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await hooks.authorize(caller, "browser.worker.take", nil, nil, .object([])); try load(); sweep()
        let profiles = try await hooks.profiles(caller).filter { ids.contains($0.id) }
        guard !profiles.isEmpty else { throw NativeRPCError(code: "no-workers", message: "There are no worker profiles granted to this caller.") }
        guard leases.count < Int(pace["maxConcurrent"].number ?? 3) else { throw NativeRPCError(code: "at-capacity", message: "The worker concurrency limit is reached. Release a worker or raise the pace limit.") }
        let chosen: BackendBrowserWorkerProfile
        if let worker {
            let candidates = profiles.filter { $0.id == worker || $0.name == worker }
            guard candidates.count == 1, let profile = candidates.first else { throw BackendBrowserScrapingError.invalid("Name one unambiguous worker from browser.workers.") }
            guard leases[profile.id] == nil else { throw NativeRPCError(code: "busy", message: "That worker is held by another caller.") }; chosen = profile
        } else {
            guard let profile = profiles.filter({ leases[$0.id] == nil }).min(by: { (released[$0.id] ?? 0) < (released[$1.id] ?? 0) }) else {
                throw NativeRPCError(code: "all-busy", message: "Every available worker is held. Release one when its page is done.")
            }
            chosen = profile
        }
        try await hooks.authorize(caller, "browser.worker.take", chosen.id, nil, .object([]))
        // Authorization awaited: recheck the pool after actor reentrancy.
        sweep()
        guard leases[chosen.id] == nil, ids.contains(chosen.id), leases.count < Int(pace["maxConcurrent"].number ?? 3) else {
            throw NativeRPCError(code: "busy", message: "The worker became busy while permission was being checked.")
        }
        let now = BackendBrowserScrapingIO.now(), token = UUID()
        let minimum = pace["minDelayMs"].number ?? 1_500, jitter = pace["jitterMs"].number ?? 1_000
        let wait = released[chosen.id].map { max(0, $0 + minimum + (Double.random(in: 0...1) * jitter).rounded() - now) } ?? 0
        let hold = Double(BackendBrowserScrapingIO.integer(holdMS, default: 120_000, min: 1_000, max: 600_000))
        leases[chosen.id] = Lease(token: token, holder: caller.holder, takenAt: now, expiresAt: now + wait + hold)
        await changed()
        do {
            if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
            try Task.checkCancellation()
            try await hooks.authorize(caller, "browser.worker.take", chosen.id, nil, .object([]))
            sweep()
            guard leases[chosen.id]?.token == token else { throw NativeRPCError(code: "lease-expired", message: "The paced worker lease expired or was removed.") }
            return .object([.init("ok", .bool(true)), .init("profileId", .string(chosen.id)), .init("name", .string(chosen.name)),
                .init("pacedMs", .number(wait)), .init("expiresAt", .number(leases[chosen.id]!.expiresAt))])
        } catch {
            if leases[chosen.id]?.token == token { leases[chosen.id] = nil; released[chosen.id] = BackendBrowserScrapingIO.now(); await changed() }
            throw error
        }
    }
    public func release(worker: String, renew: Bool = false, holdMS: NativeRPCValue = .missing, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        let action = renew ? "renew" : "release"
        let profiles = try await hooks.profiles(caller)
        let candidates = profiles.filter { $0.id == worker || $0.name == worker }
        guard candidates.count == 1, let profile = candidates.first else { throw BackendBrowserScrapingError.invalid("Name one unambiguous worker.") }
        try await hooks.authorize(caller, "browser.worker." + action, profile.id, nil, .object([])); try load(); sweep()
        guard var lease = leases[profile.id], lease.holder == caller.holder else {
            throw BackendBrowserScrapingError.denied("This caller does not hold that worker.")
        }
        if renew {
            lease.expiresAt = BackendBrowserScrapingIO.now() + Double(BackendBrowserScrapingIO.integer(holdMS, default: 120_000, min: 1_000, max: 600_000))
            leases[profile.id] = lease
        } else { leases[profile.id] = nil; released[profile.id] = BackendBrowserScrapingIO.now() }
        await changed()
        return .object([.init("worker", .string(profile.name)), .init(renew ? "renewed" : "released", .bool(true))])
    }
    /// Invoke from the session/caller disconnect path, not a polling timer.
    public func releaseAll(holder: String) async {
        for (id, lease) in leases where lease.holder == holder { leases[id] = nil; released[id] = BackendBrowserScrapingIO.now() }
        await changed()
    }
}
