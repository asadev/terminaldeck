import Foundation
import TerminalDeckNativeCore

/// A native endpoint identity is minted for one actual app-owned WebKit store.
/// Constructors are for the native owner, never for decoding a tool argument.
public struct BackendBrowserSessionLiftEndpoint: Sendable, Equatable {
    public let id: UUID
    public let profileID: String
    public let profileName: String
    public let sessionID: String?
    public init(id: UUID, profileID: String, profileName: String, sessionID: String? = nil) {
        self.id = id; self.profileID = profileID; self.profileName = profileName; self.sessionID = sessionID
    }
}
public struct BackendBrowserSessionLiftSource: Sendable, Equatable {
    public let endpoint: BackendBrowserSessionLiftEndpoint
    public let tabID: String
    public let documentID: String
    public let origin: String
    public init(endpoint: BackendBrowserSessionLiftEndpoint, tabID: String, documentID: String, origin: String) {
        self.endpoint = endpoint; self.tabID = tabID; self.documentID = documentID; self.origin = origin
    }
}
public struct BackendBrowserSessionLiftTarget: Sendable, Equatable {
    public let endpoint: BackendBrowserSessionLiftEndpoint
    public let origin: String
    public let tabID: String?
    public let documentID: String?
    public init(endpoint: BackendBrowserSessionLiftEndpoint, origin: String, tabID: String? = nil, documentID: String? = nil) {
        self.endpoint = endpoint; self.origin = origin; self.tabID = tabID; self.documentID = documentID
    }
}
public enum BackendBrowserSessionLiftConflict: String, Sendable { case preserveTarget, replaceMatching }

/// Frozen, human-approved source/origin/destination/policy scope. The authority
/// rechecks current profile, tab, session, device and cancellation facts for
/// every read/write; seed use provides its actual future live tab as a target.
public struct BackendBrowserSessionLiftPermit: Sendable {
    public let id: UUID
    public let holder: String
    public let source: BackendBrowserSessionLiftSource
    public let targets: [BackendBrowserSessionLiftTarget]
    public let conflict: BackendBrowserSessionLiftConflict
    public let ownerAnswered: Bool
    public let expiresAt: Double
    public let cancellation: BackendMCPCancellation
    public let stillPermitted: @Sendable () async -> Bool
    public let authorizeUse: @Sendable (BackendBrowserSessionLiftTarget?) async throws -> Void
    public init(id: UUID = UUID(), holder: String, source: BackendBrowserSessionLiftSource,
                targets: [BackendBrowserSessionLiftTarget], conflict: BackendBrowserSessionLiftConflict,
                ownerAnswered: Bool, expiresAt: Double, cancellation: BackendMCPCancellation,
                stillPermitted: @escaping @Sendable () async -> Bool,
                authorizeUse: @escaping @Sendable (BackendBrowserSessionLiftTarget?) async throws -> Void) {
        self.id = id; self.holder = holder; self.source = source; self.targets = targets; self.conflict = conflict
        self.ownerAnswered = ownerAnswered; self.expiresAt = expiresAt; self.cancellation = cancellation
        self.stillPermitted = stillPermitted; self.authorizeUse = authorizeUse
    }
    public func check(_ target: BackendBrowserSessionLiftTarget? = nil, now: Double = Date().timeIntervalSince1970 * 1000) async throws {
        try Task.checkCancellation()
        guard ownerAnswered, expiresAt > now, !cancellation.isCancelled, await stillPermitted() else {
            throw NativeRPCError(code: "lift-permission-expired", message: "This session-transfer approval expired or was revoked. No further data will be copied.")
        }
        if let target {
            guard target.origin == source.origin, targets.contains(where: {
                $0.endpoint == target.endpoint && $0.origin == target.origin
                && ($0.tabID == nil || $0.tabID == target.tabID)
                && ($0.documentID == nil || $0.documentID == target.documentID)
            }) else { throw NativeRPCError(code: "lift-scope", message: "The session-transfer destination is outside the approved scope.") }
        }
        try await authorizeUse(target)
        try Task.checkCancellation()
        guard !cancellation.isCancelled, expiresAt > Date().timeIntervalSince1970 * 1000 else { throw CancellationError() }
    }
}

/// The only exported capture value. The opaque ID refers to private in-memory
/// native data, and is bound to a caller/permit. It is not a credential itself.
public struct BackendBrowserSessionLiftSummary: Sendable {
    public let id: UUID
    public let takenAt: Double
    public let expiresAt: Double
    public let source: BackendBrowserSessionLiftSource
    public let cookieCount: Int
    public let cookieNames: [String]
    public let localKeys: Int
    public let sessionKeys: Int
    public let storageTruncated: Bool
    public let storageUnavailable: Bool
    public init(id: UUID, takenAt: Double, expiresAt: Double, source: BackendBrowserSessionLiftSource,
                cookieCount: Int, cookieNames: [String], localKeys: Int, sessionKeys: Int,
                storageTruncated: Bool, storageUnavailable: Bool) {
        self.id = id; self.takenAt = takenAt; self.expiresAt = expiresAt; self.source = source
        self.cookieCount = cookieCount; self.cookieNames = Array(cookieNames.prefix(24)); self.localKeys = localKeys; self.sessionKeys = sessionKeys
        self.storageTruncated = storageTruncated; self.storageUnavailable = storageUnavailable
    }
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id.uuidString.lowercased())), .init("takenAt", .number(takenAt)), .init("expiresAt", .number(expiresAt)),
            .init("sourceProfileId", .string(source.endpoint.profileID)), .init("sourceProfileName", .string(source.endpoint.profileName)),
            .init("host", .string(URL(string: source.origin)?.host ?? "")), .init("origin", .string(source.origin)),
            .init("cookieCount", .number(Double(cookieCount))), .init("cookieNames", .array(cookieNames.map(NativeRPCValue.string))),
            .init("cookieNamesTruncated", .bool(cookieCount > 24)), .init("localKeys", .number(Double(localKeys))),
            .init("sessionKeys", .number(Double(sessionKeys))), .init("storageTruncated", .bool(storageTruncated)),
            .init("storageUnavailable", .bool(storageUnavailable))])
    }
}
public struct BackendBrowserSessionLiftReport: Sendable {
    public let target: BackendBrowserSessionLiftTarget
    public let cookiesSet: Int
    public let cookiesRefused: Int
    public let cookiesPreserved: Int
    public let cookiesAlreadyMatching: Int
    public let storageSet: Int
    public let storageRefused: Int
    public let storagePreserved: Int
    public let storageAlreadyMatching: Int
    public let storageQueued: Int
    public let note: String
    public init(target: BackendBrowserSessionLiftTarget, cookiesSet: Int = 0, cookiesRefused: Int = 0,
                cookiesPreserved: Int = 0, cookiesAlreadyMatching: Int = 0, storageSet: Int = 0,
                storageRefused: Int = 0, storagePreserved: Int = 0, storageAlreadyMatching: Int = 0, storageQueued: Int = 0, note: String) {
        self.target = target; self.cookiesSet = cookiesSet; self.cookiesRefused = cookiesRefused; self.cookiesPreserved = cookiesPreserved
        self.cookiesAlreadyMatching = cookiesAlreadyMatching; self.storageSet = storageSet; self.storageRefused = storageRefused
        self.storagePreserved = storagePreserved; self.storageAlreadyMatching = storageAlreadyMatching; self.storageQueued = storageQueued; self.note = note
    }
    /// Queued keys alone never count as an injected worker.
    public var injected: Bool { cookiesSet > 0 || storageSet > 0 }
    public var wireValue: NativeRPCValue {
        .object([.init("profileId", .string(target.endpoint.profileID)), .init("name", .string(target.endpoint.profileName)),
            .init("cookiesSet", .number(Double(cookiesSet))), .init("cookiesRefused", .number(Double(cookiesRefused))),
            .init("cookiesPreserved", .number(Double(cookiesPreserved))), .init("cookiesAlreadyMatching", .number(Double(cookiesAlreadyMatching))),
            .init("storageSet", .number(Double(storageSet))), .init("storageRefused", .number(Double(storageRefused))),
            .init("storagePreserved", .number(Double(storagePreserved))), .init("storageAlreadyMatching", .number(Double(storageAlreadyMatching))),
            .init("storageQueued", .number(Double(storageQueued))),
            .init("injected", .bool(injected)), .init("signInVerified", .bool(false)), .init("note", .string(note))])
    }
}

public struct BackendBrowserSessionLiftHooks: Sendable {
    public let source: @Sendable (BackendBrowserScrapingCaller, String?, String?) async throws -> BackendBrowserSessionLiftSource
    public let targets: @Sendable (BackendBrowserScrapingCaller, [String]?, String) async throws -> [BackendBrowserSessionLiftTarget]
    public let approve: @Sendable (BackendBrowserScrapingCaller, BackendBrowserSessionLiftSource, [BackendBrowserSessionLiftTarget]) async throws -> BackendBrowserSessionLiftPermit
    public let capture: @Sendable (BackendBrowserSessionLiftSource, BackendBrowserSessionLiftPermit) async throws -> BackendBrowserSessionLiftSummary
    public let inject: @Sendable (UUID, BackendBrowserSessionLiftTarget, BackendBrowserSessionLiftPermit) async throws -> BackendBrowserSessionLiftReport
    public let reapprove: @Sendable (UUID, BackendBrowserSessionLiftPermit) async throws -> Void
    public let forget: @Sendable (UUID) async -> Void
    public let revoke: @Sendable (UUID) async -> Void
    public let revokeHolder: @Sendable (String) async -> Void
    public let pending: @Sendable (String) async throws -> NativeRPCValue
    public init(source: @escaping @Sendable (BackendBrowserScrapingCaller, String?, String?) async throws -> BackendBrowserSessionLiftSource,
                targets: @escaping @Sendable (BackendBrowserScrapingCaller, [String]?, String) async throws -> [BackendBrowserSessionLiftTarget],
                approve: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserSessionLiftSource, [BackendBrowserSessionLiftTarget]) async throws -> BackendBrowserSessionLiftPermit,
                capture: @escaping @Sendable (BackendBrowserSessionLiftSource, BackendBrowserSessionLiftPermit) async throws -> BackendBrowserSessionLiftSummary,
                inject: @escaping @Sendable (UUID, BackendBrowserSessionLiftTarget, BackendBrowserSessionLiftPermit) async throws -> BackendBrowserSessionLiftReport,
                reapprove: @escaping @Sendable (UUID, BackendBrowserSessionLiftPermit) async throws -> Void,
                forget: @escaping @Sendable (UUID) async -> Void, revoke: @escaping @Sendable (UUID) async -> Void,
                revokeHolder: @escaping @Sendable (String) async -> Void,
                pending: @escaping @Sendable (String) async throws -> NativeRPCValue) {
        self.source = source; self.targets = targets; self.approve = approve; self.capture = capture; self.inject = inject; self.reapprove = reapprove
        self.forget = forget; self.revoke = revoke; self.revokeHolder = revokeHolder; self.pending = pending
    }
}

/// Backend metadata/authorization facade. All secret values stay in the native
/// app's WebKit adapter. No file root, browser discovery or Keychain access.
public actor BackendBrowserSessionLift {
    private struct Held: Sendable { let summary: BackendBrowserSessionLiftSummary; let permit: BackendBrowserSessionLiftPermit }
    private let hooks: BackendBrowserSessionLiftHooks
    private let authorize: BackendBrowserScrapingAuthorize
    private let changed: @Sendable () async -> Void
    private var held: [UUID: Held] = [:]
    private var injecting: Set<UUID> = []
    public init(hooks: BackendBrowserSessionLiftHooks, authorize: @escaping BackendBrowserScrapingAuthorize,
                changed: @escaping @Sendable () async -> Void) {
        self.hooks = hooks; self.authorize = authorize; self.changed = changed
    }
    private func nativeOwner(_ caller: BackendBrowserScrapingCaller) throws {
        guard caller.rpc?.caller == .nativeApp, caller.attended, !caller.remote, caller.sessionID == nil else {
            throw NativeRPCError(code: "lift-human-only", message: "Only the person in the attended native app may lift or inject a session. An agent may file a request and wait for an answer.")
        }
    }
    public func lift(viewID: String?, fromProfileID: String? = nil, intoProfileIDs: [String]? = nil,
                     caller: BackendBrowserScrapingCaller) async throws -> BackendBrowserSessionLiftSummary {
        try nativeOwner(caller)
        try await authorize(caller, "browser-worker:lift", nil, nil, .object([]))
        let source = try await hooks.source(caller, viewID, fromProfileID)
        guard BackendBrowserPasswords.origin(source.origin) == source.origin else { throw NativeRPCError.invalidArguments("The source must be bound to an exact HTTP(S) origin.") }
        let targets = try await hooks.targets(caller, intoProfileIDs, source.origin).filter { $0.endpoint.id != source.endpoint.id && $0.endpoint.profileID != source.endpoint.profileID }
        guard !targets.isEmpty, Set(targets.map { $0.endpoint.id }).count == targets.count,
              targets.allSatisfy({ $0.origin == source.origin }) else { throw NativeRPCError.invalidArguments("Choose distinct worker profiles on the approved origin.") }
        try await authorize(caller, "browser-worker:lift", source.endpoint.profileID, URL(string: source.origin), .object([.init("viewId", .string(source.tabID))]))
        for target in targets { try await authorize(caller, "browser-worker:lift", target.endpoint.profileID, URL(string: source.origin), .object([])) }
        let permit = try await hooks.approve(caller, source, targets)
        guard permit.holder == caller.holder, permit.source == source, permit.targets == targets else {
            throw NativeRPCError(code: "lift-consent-scope", message: "The native approval did not match this source page and these worker destinations.")
        }
        try await permit.check()
        let summary = try await hooks.capture(source, permit)
        guard summary.source == source, summary.expiresAt <= summary.takenAt + 15 * 60_000,
              summary.expiresAt > Date().timeIntervalSince1970 * 1000,
              summary.cookieCount + summary.localKeys + summary.sessionKeys > 0 else {
            await hooks.forget(summary.id); throw NativeRPCError(code: "lift-empty", message: "No eligible session data was captured from the approved page.")
        }
        do { try await permit.check() } catch { await hooks.forget(summary.id); throw error }
        held[summary.id] = Held(summary: summary, permit: permit); await changed(); return summary
    }
    public func inject(id: UUID, profileIDs: [String]? = nil, caller: BackendBrowserScrapingCaller) async throws -> [BackendBrowserSessionLiftReport] {
        try nativeOwner(caller); try await authorize(caller, "browser-worker:inject", nil, nil, .object([]))
        await sweep()
        guard var entry = held[id], entry.permit.holder == caller.holder, !injecting.contains(id) else {
            throw NativeRPCError(code: "lift-missing", message: "This lifted session expired, was forgotten, belongs to another caller, or is already being injected.")
        }
        injecting.insert(id); defer { injecting.remove(id) }
        let targets = try await hooks.targets(caller, profileIDs, entry.summary.source.origin).filter { $0.endpoint.id != entry.summary.source.endpoint.id }
        guard !targets.isEmpty, Set(targets.map { $0.endpoint.id }).count == targets.count else { throw NativeRPCError.invalidArguments("There are no distinct worker destinations.") }
        if !targets.allSatisfy({ candidate in entry.permit.targets.contains(where: { $0 == candidate }) }) {
            // A newly minted worker can receive the held source session while
            // its original 15-minute lifetime remains. The native Inject press
            // must authorize the expanded exact target list; it is not inferred
            // from an agent string or the previous permission's scope.
            try await entry.permit.check()
            let next = try await hooks.approve(caller, entry.summary.source, targets)
            guard next.holder == caller.holder, next.source == entry.summary.source, next.targets == targets else {
                throw NativeRPCError(code: "lift-consent-scope", message: "The new worker approval did not match the held source and current destinations.")
            }
            try await next.check()
            try await hooks.reapprove(id, next)
            guard held[id] != nil else {
                await hooks.forget(id)
                throw NativeRPCError(code: "lift-forgotten", message: "The held session was forgotten while its worker scope was being approved.")
            }
            entry = Held(summary: entry.summary, permit: next); held[id] = entry
        }
        for target in targets { try await entry.permit.check(target) }
        var reports: [BackendBrowserSessionLiftReport] = []
        for target in targets {
            try await authorize(caller, "browser-worker:inject", entry.summary.source.endpoint.profileID, URL(string: target.origin), .object([]))
            try await authorize(caller, "browser-worker:inject", target.endpoint.profileID, URL(string: target.origin), .object([]))
            try await entry.permit.check(target)
            let report = try await hooks.inject(id, target, entry.permit)
            guard report.target == target else { throw NativeRPCError(code: "lift-report-scope", message: "The native transfer report named another destination.") }
            reports.append(report)
        }
        await changed(); return reports
    }
    /// Supply directly to BackendBrowserWorkersLiftRequests.transfer. The row
    /// is the actor's saved ask, and source/targets are resolved anew by native
    /// ownership. Cookies/keys are never present in the request or result.
    public func approveRequest(_ caller: BackendBrowserScrapingCaller, request: NativeRPCValue) async throws -> Int {
        try nativeOwner(caller)
        let source = try request["fromProfileId"].requireString("fromProfileId", nonempty: true)
        let targets = try request["intoProfileIds"].requireArray("intoProfileIds").map { try $0.requireString("worker profile", nonempty: true) }
        let summary = try await lift(viewID: nil, fromProfileID: source, intoProfileIDs: targets, caller: caller)
        do {
            let reports = try await inject(id: summary.id, profileIDs: targets, caller: caller)
            await forgetInternal(summary.id)
            return reports.filter(\.injected).count
        } catch { await forgetInternal(summary.id); throw error }
    }
    public func forget(id: UUID, caller: BackendBrowserScrapingCaller) async throws {
        try await authorize(caller, "browser-worker:forget-lift", nil, nil, .object([.init("liftId", .string(id.uuidString.lowercased()))]))
        guard let entry = held[id], entry.permit.holder == caller.holder else { throw NativeRPCError(code: "lift-missing", message: "There is no lifted session owned by this caller.") }
        try await authorize(caller, "browser-worker:forget-lift", entry.summary.source.endpoint.profileID, URL(string: entry.summary.source.origin), .object([]))
        await forgetInternal(id); await changed()
    }
    public func view(_ caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await authorize(caller, "browser.workers", nil, nil, .object([])); await sweep()
        var rows: [NativeRPCValue] = []
        for entry in held.values where entry.permit.holder == caller.holder {
            try await authorize(caller, "browser.workers", entry.summary.source.endpoint.profileID, URL(string: entry.summary.source.origin), .object([]))
            rows.append(entry.summary.wireValue.setting("expiresAt", .number(min(entry.summary.expiresAt, entry.permit.expiresAt))))
        }
        return .object([.init("lifts", .array(rows)), .init("queued", try await hooks.pending(caller.holder)),
            .init("canSeedStorage", .bool(true)), .init("seedTiming", .string("Storage is applied only to an authorized live main-frame page on the exact origin. Page boot may already have run; reload after the reported writes if needed."))])
    }
    public func disconnect(holder: String) async {
        let permits = held.values.filter { $0.permit.holder == holder }.map { $0.permit.id }
        let ids = held.filter { $0.value.permit.holder == holder }.map(\.key)
        for id in ids { held[id] = nil; await hooks.forget(id) }
        for id in Set(permits) { await hooks.revoke(id) }
        // Queued seeds outlive an approved request's immediately forgotten
        // lift; revoke by holder as well so those cannot survive disconnect.
        await hooks.revokeHolder(holder)
        await changed()
    }
    private func sweep() async {
        let now = Date().timeIntervalSince1970 * 1000
        let stale = held.filter { $0.value.summary.expiresAt <= now || $0.value.permit.cancellation.isCancelled || $0.value.permit.expiresAt <= now }.map(\.key)
        for id in stale { await forgetInternal(id) }
    }
    private func forgetInternal(_ id: UUID) async { held[id] = nil; await hooks.forget(id) }
}

/// Route these three cases from the existing scraping facade instead of its
/// unsupported placeholders; do not double-register the same IPC names.
public enum BackendBrowserSessionLiftChannels {
    public static let channels: Set<String> = ["browser-worker:lift", "browser-worker:inject", "browser-worker:forget-lift"]
    public static func invoke(_ channel: String, arguments: [NativeRPCValue], context: NativeRPCContext,
                              service: BackendBrowserSessionLift,
                              workersView: @escaping @Sendable (BackendBrowserScrapingCaller) async throws -> NativeRPCValue) async throws -> NativeRPCValue {
        try context.requireCount(arguments, 1...1)
        let caller = BackendBrowserScrapingCaller.native(context), input = arguments[0]
        do {
        switch channel {
        case "browser-worker:lift":
            let summary = try await service.lift(viewID: try input["viewId"].requireString("viewId", nonempty: true), caller: caller)
            return .object([.init("ok", .bool(true)), .init("summary", summary.wireValue)])
        case "browser-worker:inject":
            guard let id = UUID(uuidString: try input["liftId"].requireString("liftId")) else { throw NativeRPCError.invalidArguments("liftId must name a held native lift.") }
            let chosen = input["profileIds"] == .missing || input["profileIds"] == .null ? nil : try input["profileIds"].requireArray("profileIds").map { try $0.requireString("worker profile", nonempty: true) }
            let reports = try await service.inject(id: id, profileIDs: chosen, caller: caller)
            var value = NativeRPCValue.object([.init("ok", .bool(reports.contains(where: \.injected))), .init("reports", .array(reports.map(\.wireValue))),
                .init("injectedWorkers", .number(Double(reports.filter(\.injected).count))), .init("signInVerified", .bool(false)),
                .init("line", .string("The reports count actual copied cookies and storage writes separately from queued or preserved data. Website sign-in was not verified."))])
            if !reports.contains(where: \.injected) { value = value.setting("reason", .string("No new cookies or storage keys were written. Some keys may be queued or existing data preserved; inspect the per-worker reports.")) }
            return value
        case "browser-worker:forget-lift":
            guard let id = UUID(uuidString: try input.requireString("liftId")) else { throw NativeRPCError.invalidArguments("liftId must name a held native lift.") }
            try await service.forget(id: id, caller: caller)
            let workers = try await workersView(caller), lifts = try await service.view(caller)
            return workers.merging(lifts)
        default: throw NativeRPCError.invalidArguments("Unknown native session-lift channel.")
        }
        } catch {
            guard channel == "browser-worker:lift" || channel == "browser-worker:inject" else { throw error }
            let message = (error as? NativeRPCError)?.message ?? (error is CancellationError ? "The session transfer was cancelled." : "The native session transfer could not complete.")
            return .object([.init("ok", .bool(false)), .init("reason", .string(message))])
        }
    }
}
