import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Cookie-store callbacks cannot be cancelled by WebKit. This bridge releases
/// a waiting task on cancellation/deadline and ignores a late completion. An
/// already-submitted cookie write may still land; no rollback is claimed.
private final class NativeSafariSessionLiftReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var finished = false
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let cached: Result<Value, Error>? = lock.withLock {
            if finished { let cached = result; result = nil; return cached }
            self.continuation = continuation; return nil
        }
        if let cached { continuation.resume(with: cached) }
    }
    func finish(_ result: Result<Value, Error>) {
        let pending: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if let pending = continuation { continuation = nil; return pending }
            self.result = result; return nil
        }
        pending?.resume(with: result)
    }
}

/// Independent of a request's cancelled/timed-out waiter. Only the actual
/// public WebKit completion marks a submitted writer finished.
private final class NativeSafariSessionLiftCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [UUID: NativeSafariSessionLiftReply<Bool>] = [:]
    var isFinished: Bool { lock.withLock { finished } }
    func complete() {
        let pending = lock.withLock { () -> [NativeSafariSessionLiftReply<Bool>] in
            finished = true
            let pending = Array(waiters.values); waiters.removeAll(); return pending
        }
        for waiter in pending { waiter.finish(.success(true)) }
    }
    func wait() async throws {
        let id = UUID(), reply = NativeSafariSessionLiftReply<Bool>()
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                let done = lock.withLock { () -> Bool in
                    if finished { return true }; waiters[id] = reply; return false
                }
                if done { reply.finish(.success(true)) }
            }
        } onCancel: {
            self.lock.withLock { self.waiters[id] = nil }
            reply.finish(.failure(CancellationError()))
        }
    }
}

/// Direct public-WebKit transfer between exact app-owned stores and live pages.
/// No browser discovery, hidden page creation, global cookie jar, disk cache,
/// Keychain, Node bridge or raw credential RPC exists in this adapter.
@MainActor
final class NativeSafariSessionLift {
    private final class Profile {
        let endpoint: BackendBrowserSessionLiftEndpoint
        let store: WKWebsiteDataStore
        init(endpoint: BackendBrowserSessionLiftEndpoint, store: WKWebsiteDataStore) { self.endpoint = endpoint; self.store = store }
    }
    private final class Page {
        weak var view: WKWebView?
        let tabID: String
        let profileID: String
        var documentID = UUID().uuidString.lowercased()
        var committedOrigin: String?
        init(view: WKWebView, tabID: String, profileID: String) { self.view = view; self.tabID = tabID; self.profileID = profileID }
    }
    private struct Storage {
        let local: [(String, String)]
        let session: [(String, String)]
        let truncated: Bool
        var count: Int { local.count + session.count }
    }
    private struct Lift {
        let summary: BackendBrowserSessionLiftSummary
        let cookies: [HTTPCookie]
        let storage: Storage?
        let permit: BackendBrowserSessionLiftPermit
    }
    private struct Seed {
        let id: UUID
        let target: BackendBrowserSessionLiftTarget
        let storage: Storage
        let permit: BackendBrowserSessionLiftPermit
        let expiresAt: Double
    }
    private struct StorageWrite { let set: Int; let refused: Int; let preserved: Int; let unchanged: Int }
    static let world = WKContentWorld.world(name: "TerminalDeckSessionLift")
    private var profiles: [String: Profile] = [:]
    private var pages: [String: Page] = [:]
    private var lifts: [UUID: Lift] = [:]
    private var seeds: [String: Seed] = [:]
    private var permissionObservers: [UUID: (BackendMCPCancellation, UUID, String)] = [:]
    private var activePermits: [UUID: Int] = [:]
    private var expiryTask: Task<Void, Never>?
    private var expiryGeneration: UInt64 = 0
    private var busyTargets: Set<UUID> = []
    private struct SubmittedWrite {
        let profileID: String
        let completion: NativeSafariSessionLiftCompletion
    }
    private var submittedWrites: [UUID: SubmittedWrite] = [:]
    private var retiredProfiles: Set<String> = []
    private var closed = false
    private let changed: @MainActor @Sendable () -> Void
    private let seedOutcome: @MainActor @Sendable (BackendBrowserSessionLiftReport) -> Void
    init(changed: @escaping @MainActor @Sendable () -> Void,
         seedOutcome: @escaping @MainActor @Sendable (BackendBrowserSessionLiftReport) -> Void) {
        self.changed = changed; self.seedOutcome = seedOutcome
    }
    /// Register only stores already owned by the native browser. Binding the
    /// same store as two different profiles is refused rather than faking an
    /// isolated destination. Root/session authorization is supplied separately.
    func bindProfile(profileID: String, name: String, store: WKWebsiteDataStore, sessionID: String? = nil) throws {
        let id = BackendBrowserProfiles.normalizedID(profileID)
        guard !closed, !retiredProfiles.contains(id), BackendBrowserProfiles.validID(id), store.isPersistent,
              !profiles.values.contains(where: { $0.store === store && $0.endpoint.profileID != id }) else {
            throw NativeRPCError(code: "lift-profile-binding", message: "Session transfer needs a distinct persistent app-owned store for each profile.")
        }
        if let old = profiles[id], old.store === store, old.endpoint.profileName == name, old.endpoint.sessionID == sessionID { return }
        if let old = profiles[id] { invalidateEndpoint(old.endpoint.id) }
        let endpoint = BackendBrowserSessionLiftEndpoint(id: UUID(), profileID: id, profileName: name, sessionID: sessionID)
        profiles[id] = Profile(endpoint: endpoint, store: store)
    }
    func unbindProfile(_ id: String) {
        let id = BackendBrowserProfiles.normalizedID(id)
        if let profile = profiles.removeValue(forKey: id) { invalidateEndpoint(profile.endpoint.id) }
        for (tab, page) in pages where page.profileID == id { pages[tab] = nil }
    }
    /// Revoke endpoints/seeds first, then require actual cookie/script writer
    /// completion. A cancelled caller wait is not evidence that WebKit stopped.
    func stop(profileID: String) async throws {
        let id = BackendBrowserProfiles.normalizedID(profileID)
        guard BackendBrowserProfiles.validID(id) else { throw NativeRPCError.invalidArguments("Session-transfer retirement needs its actual profile ID.") }
        retiredProfiles.insert(id); unbindProfile(id)
        try await drainSubmittedWrites(profileID: id)
    }
    func stop() async throws {
        closed = true
        for id in Array(profiles.keys) { retiredProfiles.insert(id); unbindProfile(id) }
        for observer in Array(permissionObservers.values) { observer.0.cancel() }
        lifts.removeAll(); seeds.removeAll()
        try await drainSubmittedWrites(profileID: nil)
    }
    private func drainSubmittedWrites(profileID: String?) async throws {
        let pending = submittedWrites.values.filter { profileID == nil || $0.profileID == profileID }
        let outstanding = pending.filter { !$0.completion.isFinished }
        guard !outstanding.isEmpty else { return }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for write in outstanding { group.addTask { try await write.completion.wait() } }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw NativeRPCError(code: "lift-writers-unverified", message: "Public WebKit session-transfer writers have not completed. No profile clear or completed shutdown can be claimed; retry after their actual callbacks arrive.")
                }
                defer { group.cancelAll() }
                for _ in outstanding { _ = try await group.next() }
            }
        } catch {
            // Keep receipts/tombstones. Late callbacks may still complete; no
            // timeout, cancelled waiter or zero-count report removes them.
            throw error
        }
    }
    func bindPage(_ view: WKWebView, tabID: String, profileID: String) throws {
        let id = BackendBrowserProfiles.normalizedID(profileID)
        guard let profile = profiles[id], view.configuration.websiteDataStore === profile.store else {
            throw NativeRPCError(code: "lift-page-binding", message: "The live page does not belong to this exact native profile store.")
        }
        pages[tabID] = Page(view: view, tabID: tabID, profileID: id)
    }
    /// Call from the existing WKNavigationDelegate; this does not replace it.
    func didCommit(_ view: WKWebView, tabID: String) {
        guard let page = pages[tabID], page.view === view else { return }
        page.documentID = UUID().uuidString.lowercased()
        page.committedOrigin = view.url.flatMap { BackendBrowserPasswords.origin($0.absoluteString) }
    }
    func unbindPage(_ id: String) { pages[id] = nil }
    func source(tabID: String) throws -> BackendBrowserSessionLiftSource {
        guard let page = pages[tabID], let view = page.view, let profile = profiles[page.profileID],
              view.configuration.websiteDataStore === profile.store, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
              let origin = page.committedOrigin else {
            throw NativeRPCError(code: "lift-source-page", message: "Open and show a live HTTP(S) page in the source profile before lifting its session.")
        }
        return .init(endpoint: profile.endpoint, tabID: tabID, documentID: page.documentID, origin: origin)
    }
    /// The UI resolver must choose the page explicitly if more than one
    /// visible source page exists. Never silently choose another logged-in site.
    func source(profileID: String) throws -> BackendBrowserSessionLiftSource {
        let id = BackendBrowserProfiles.normalizedID(profileID)
        let candidates = pages.values.filter { $0.profileID == id }.compactMap { try? self.source(tabID: $0.tabID) }
        guard candidates.count == 1, let source = candidates.first else {
            throw NativeRPCError(code: "lift-source-ambiguous", message: "Show one source page in this profile, or select its exact tab before approving the transfer.")
        }
        return source
    }
    func target(profileID: String, origin: String, tabID: String? = nil) throws -> BackendBrowserSessionLiftTarget {
        let id = BackendBrowserProfiles.normalizedID(profileID)
        guard let profile = profiles[id], BackendBrowserPasswords.origin(origin) == origin else {
            throw NativeRPCError(code: "lift-target-binding", message: "The transfer destination is not a bound native profile on an exact HTTP(S) origin.")
        }
        if let tabID {
            guard let page = pages[tabID], page.profileID == id, page.committedOrigin == origin, let view = page.view,
                  view.configuration.websiteDataStore === profile.store, view.window != nil, !view.isHiddenOrHasHiddenAncestor else {
                throw NativeRPCError(code: "lift-target-page", message: "The selected storage destination must be a live visible page on the exact approved origin.")
            }
            return .init(endpoint: profile.endpoint, origin: origin, tabID: tabID, documentID: page.documentID)
        }
        return .init(endpoint: profile.endpoint, origin: origin)
    }
    /// Returns summaries only. Cookie/storage values stay in this object.
    func capture(_ source: BackendBrowserSessionLiftSource, permit: BackendBrowserSessionLiftPermit) async throws -> BackendBrowserSessionLiftSummary {
        sweep()
        guard permit.source == source, let profile = currentProfile(source.endpoint), let page = currentSource(source), let view = page.view else {
            throw NativeRPCError(code: "lift-source-changed", message: "The approved source page or profile changed before its session could be read.")
        }
        try await checked(permit)
        let all = try await cookies(profile.store)
        try await checked(permit)
        guard currentSource(source)?.view === view else { throw NativeRPCError(code: "lift-source-changed", message: "The source page changed while its cookies were being read.") }
        let now = Self.now(), host = URL(string: source.origin)?.host?.lowercased() ?? ""
        let eligible = all.filter { Self.applies($0, host: host) && ($0.expiresDate.map { $0.timeIntervalSince1970 * 1000 > now } ?? true) }
        guard eligible.count <= 5000, eligible.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + $1.domain.utf8.count + $1.path.utf8.count }) <= 4 * 1024 * 1024 else {
            throw NativeRPCError(code: "lift-size", message: "This site's session cookies exceed the in-memory transfer limit. No partial cookie session was held.")
        }
        var storage: Storage?, storageUnavailable = false
        do {
            let nonce = try await documentNonce(view, origin: source.origin)
            guard currentSource(source)?.view === view else { throw NativeRPCError(code: "lift-source-changed", message: "The source document moved.") }
            let raw = try await view.callAsyncJavaScript(Self.readStorageScript, arguments: ["expectedOrigin": source.origin, "expectedNonce": nonce], in: nil, contentWorld: Self.world)
            guard currentSource(source)?.view === view, let result = raw as? [String: Any], result["origin"] as? String == source.origin,
                  result["nonce"] as? String == nonce else { throw NativeRPCError(code: "lift-source-changed", message: "The source storage document changed.") }
            let local = try readBundle(result["local"]), session = try readBundle(result["session"])
            storage = Storage(local: local.entries, session: session.entries, truncated: local.truncated || session.truncated)
        } catch is CancellationError { throw CancellationError() }
        catch { storageUnavailable = true }
        try await checked(permit)
        guard currentSource(source)?.view === view else { throw NativeRPCError(code: "lift-source-changed", message: "The source page changed before the session was held.") }
        let total = eligible.count + (storage?.count ?? 0)
        guard total > 0 else { throw NativeRPCError(code: "lift-empty", message: "No eligible cookies or stored keys were found on the source page. No lift was created.") }
        let summary = BackendBrowserSessionLiftSummary(id: UUID(), takenAt: now, expiresAt: min(now + 15 * 60_000, permit.expiresAt),
            source: source, cookieCount: eligible.count, cookieNames: eligible.map(\.name), localKeys: storage?.local.count ?? 0,
            sessionKeys: storage?.session.count ?? 0, storageTruncated: storage?.truncated ?? false, storageUnavailable: storageUnavailable)
        watch(permit); lifts[summary.id] = Lift(summary: summary, cookies: eligible, storage: storage, permit: permit)
        scheduleExpiry(); changed(); return summary
    }
    func inject(_ id: UUID, target: BackendBrowserSessionLiftTarget, permit: BackendBrowserSessionLiftPermit) async throws -> BackendBrowserSessionLiftReport {
        sweep()
        guard let lift = lifts[id], lift.permit.id == permit.id, lift.permit.holder == permit.holder,
              let profile = currentProfile(target.endpoint), target.endpoint.id != lift.summary.source.endpoint.id,
              target.origin == lift.summary.source.origin, !busyTargets.contains(target.endpoint.id) else {
            throw NativeRPCError(code: "lift-target-changed", message: "The lifted session or exact worker destination expired, changed or is already receiving a transfer.")
        }
        try await checked(permit, target: target); try requireHeld(id, permit: permit)
        activePermits[permit.id, default: 0] += 1
        defer { finishActive(permit.id) }
        busyTargets.insert(target.endpoint.id); defer { busyTargets.remove(target.endpoint.id) }
        var set = 0, refused = 0, preserved = 0, unchanged = 0
        for cookie in lift.cookies {
            try await checked(permit, target: target); try requireHeld(id, permit: permit)
            guard currentProfile(target.endpoint)?.store === profile.store else { throw NativeRPCError(code: "lift-target-changed", message: "The worker profile store changed during transfer.") }
            if cookie.expiresDate.map({ $0.timeIntervalSince1970 * 1000 <= Self.now() }) == true || Self.hasUnsupportedPartition(cookie) { refused += 1; continue }
            let current = try await cookies(profile.store)
            try await checked(permit, target: target); try requireHeld(id, permit: permit)
            if let sameKey = current.first(where: { Self.identity($0) == Self.identity(cookie) }) {
                if Self.sameCookie(sameKey, cookie) { unchanged += 1; continue }
                if permit.conflict == .preserveTarget { preserved += 1; continue }
            }
            // No destination clear. Replacement, when approved, affects only
            // the matching source name/domain/path key; unrelated cookies stay.
            try await put(cookie, into: profile.store, profileID: target.endpoint.profileID)
            try await checked(permit, target: target); try requireHeld(id, permit: permit)
            let after = try await cookies(profile.store)
            try await checked(permit, target: target); try requireHeld(id, permit: permit)
            if after.contains(where: { Self.identity($0) == Self.identity(cookie) && Self.sameCookie($0, cookie) }) { set += 1 }
            else { refused += 1 }
        }
        var written = StorageWrite(set: 0, refused: 0, preserved: 0, unchanged: 0), queued = 0
        if let storage = lift.storage, storage.count > 0 {
            try await checked(permit, target: target); try requireHeld(id, permit: permit)
            if let live = try? liveTarget(for: target) {
                written = try await writeStorage(storage, to: live, permit: permit, heldLiftID: id)
            } else {
                let key = Self.seedKey(target)
                if let old = seeds[key], old.permit.id != permit.id, permit.conflict == .preserveTarget {
                    written = StorageWrite(set: 0, refused: 0, preserved: storage.count, unchanged: 0)
                } else {
                    // One-shot seed is private memory only, scoped to this
                    // endpoint and exact origin. Never put values in a script
                    // shared with other profiles/origins or a source file.
                    seeds[key] = Seed(id: UUID(), target: target, storage: storage, permit: permit, expiresAt: min(Self.now() + 60 * 60_000, permit.expiresAt))
                    queued = storage.count; scheduleExpiry()
                }
            }
        }
        let note = "Copied data is counted after readback. Existing destination data followed the approved conflict policy. Queued keys have not been written; reload the exact-origin page after storage writes if its app already booted. Website sign-in was not verified."
        let report = BackendBrowserSessionLiftReport(target: target, cookiesSet: set, cookiesRefused: refused,
            cookiesPreserved: preserved, cookiesAlreadyMatching: unchanged, storageSet: written.set,
            storageRefused: written.refused, storagePreserved: written.preserved, storageAlreadyMatching: written.unchanged, storageQueued: queued, note: note)
        changed(); return report
    }
    /// Expanding a human-selected target list does not extend the original
    /// source snapshot's lifetime, and never reads another source document.
    func reapprove(_ id: UUID, permit: BackendBrowserSessionLiftPermit) async throws {
        sweep()
        guard let lift = lifts[id], lift.permit.holder == permit.holder, lift.summary.source == permit.source else {
            throw NativeRPCError(code: "lift-reapproval-scope", message: "The held session does not match this native owner and source scope.")
        }
        try await checked(permit)
        guard let still = lifts[id], still.summary.expiresAt > Self.now(), still.summary.source == permit.source else {
            throw NativeRPCError(code: "lift-expired", message: "The original held session expired before the new workers were approved.")
        }
        watch(permit)
        lifts[id] = Lift(summary: still.summary, cookies: still.cookies, storage: still.storage, permit: permit)
        cleanupObservers(); scheduleExpiry(); changed()
    }
    /// Invoke after a visible target page commits/finishes. Public WebKit does
    /// not guarantee an async native seed arrives before the site's boot code.
    /// Values are passed only to this checked page and never in a wire reply.
    func applyQueuedSeed(tabID: String) async throws -> BackendBrowserSessionLiftReport? {
        sweep()
        guard let page = pages[tabID], let origin = page.committedOrigin,
              let target = try? self.target(profileID: page.profileID, origin: origin, tabID: tabID),
              let seed = seeds[Self.seedKey(target)], !busyTargets.contains(target.endpoint.id) else { return nil }
        activePermits[seed.permit.id, default: 0] += 1
        defer { finishActive(seed.permit.id) }
        seeds[Self.seedKey(target)] = nil // consumed before handing values over
        scheduleExpiry(); changed()
        try await checked(seed.permit, target: target)
        busyTargets.insert(target.endpoint.id); defer { busyTargets.remove(target.endpoint.id) }
        let written = try await writeStorage(seed.storage, to: target, permit: seed.permit)
        let report = BackendBrowserSessionLiftReport(target: target, storageSet: written.set, storageRefused: written.refused,
            storagePreserved: written.preserved, storageAlreadyMatching: written.unchanged,
            note: "The one-shot seed was consumed on this exact live origin. Reload if the page read storage before the write. Website sign-in was not verified.")
        seedOutcome(report); changed(); return report
    }
    func pending(holder: String) async throws -> NativeRPCValue {
        sweep(); var rows: [NativeRPCValue] = []
        for seed in Array(seeds.values) where seed.permit.holder == holder {
            do { try await checked(seed.permit, target: seed.target) }
            catch { continue }
            rows.append(.object([.init("partition", .string(seed.target.endpoint.profileID == "default" ? "persist:terminaldeck-browser" : "persist:terminaldeck-browser-" + seed.target.endpoint.profileID)),
                .init("profileId", .string(seed.target.endpoint.profileID)), .init("origin", .string(seed.target.origin)), .init("keys", .number(Double(seed.storage.count))),
                .init("expiresAt", .number(seed.expiresAt)), .init("pending", .bool(true))]))
        }
        return .array(rows)
    }
    /// Dropping a completed request's lift does not drop its already-approved
    /// one-shot seeds. Explicit revocation/holder disconnect drops both.
    func forget(_ id: UUID) { lifts[id] = nil; cleanupObservers(); scheduleExpiry(); changed() }
    func revoke(_ permitID: UUID) {
        lifts = lifts.filter { $0.value.permit.id != permitID }; seeds = seeds.filter { $0.value.permit.id != permitID }
        if let observer = permissionObservers.removeValue(forKey: permitID) {
            observer.0.removeObserver(observer.1); observer.0.cancel()
        }
        scheduleExpiry(); changed()
    }
    func revokeHolder(_ holder: String) {
        let permits = Set(lifts.values.filter { $0.permit.holder == holder }.map { $0.permit.id }
            + seeds.values.filter { $0.permit.holder == holder }.map { $0.permit.id }
            + permissionObservers.filter { $0.value.2 == holder }.map(\.key))
        for permit in permits { revoke(permit) }
    }
    func shutdown() {
        closed = true
        expiryTask?.cancel(); expiryTask = nil; expiryGeneration &+= 1
        for observer in permissionObservers.values { observer.0.removeObserver(observer.1); observer.0.cancel() }
        permissionObservers.removeAll(); activePermits.removeAll(); lifts.removeAll(); seeds.removeAll(); pages.removeAll(); profiles.removeAll(); busyTargets.removeAll()
    }
    /// Only the native owner passes trusted resolver/consent/authority closures.
    /// Raw arguments select references; they never construct these endpoints.
    func makeHooks(source: @escaping @Sendable (BackendBrowserScrapingCaller, String?, String?) async throws -> BackendBrowserSessionLiftSource,
                   targets: @escaping @Sendable (BackendBrowserScrapingCaller, [String]?, String) async throws -> [BackendBrowserSessionLiftTarget],
                   approve: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserSessionLiftSource, [BackendBrowserSessionLiftTarget]) async throws -> BackendBrowserSessionLiftPermit) -> BackendBrowserSessionLiftHooks {
        BackendBrowserSessionLiftHooks(source: source, targets: targets, approve: approve,
            capture: { [weak self] source, permit in
                guard let self else { throw NativeRPCError(code: "lift-native-closed", message: "The native session-transfer owner is closed.") }
                return try await self.capture(source, permit: permit)
            }, inject: { [weak self] id, target, permit in
                guard let self else { throw NativeRPCError(code: "lift-native-closed", message: "The native session-transfer owner is closed.") }
                return try await self.inject(id, target: target, permit: permit)
            }, reapprove: { [weak self] id, permit in
                guard let self else { throw NativeRPCError(code: "lift-native-closed", message: "The native session-transfer owner is closed.") }
                try await self.reapprove(id, permit: permit)
            }, forget: { [weak self] id in await self?.forget(id) }, revoke: { [weak self] id in await self?.revoke(id) },
            revokeHolder: { [weak self] holder in await self?.revokeHolder(holder) },
            pending: { [weak self] holder in
                guard let self else { throw NativeRPCError(code: "lift-native-closed", message: "The native session-transfer owner is closed.") }
                return try await self.pending(holder: holder)
            })
    }
    private func currentProfile(_ endpoint: BackendBrowserSessionLiftEndpoint) -> Profile? {
        guard !closed, !retiredProfiles.contains(endpoint.profileID) else { return nil }
        guard let profile = profiles[endpoint.profileID], profile.endpoint == endpoint else { return nil }; return profile
    }
    private func currentSource(_ source: BackendBrowserSessionLiftSource) -> Page? {
        guard let profile = currentProfile(source.endpoint), let page = pages[source.tabID], let view = page.view,
              page.profileID == source.endpoint.profileID, page.documentID == source.documentID, page.committedOrigin == source.origin,
              view.configuration.websiteDataStore === profile.store, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }; return page
    }
    private func liveTarget(for target: BackendBrowserSessionLiftTarget) throws -> BackendBrowserSessionLiftTarget {
        if let tab = target.tabID { return try self.target(profileID: target.endpoint.profileID, origin: target.origin, tabID: tab) }
        let visible = pages.values.filter { $0.profileID == target.endpoint.profileID && $0.committedOrigin == target.origin }
            .compactMap { try? self.target(profileID: target.endpoint.profileID, origin: target.origin, tabID: $0.tabID) }
        guard visible.count == 1, let live = visible.first else { throw NativeRPCError(code: "lift-target-not-live", message: "Storage needs one exact live destination page; the keys remain queued.") }
        return live
    }
    private func checked(_ permit: BackendBrowserSessionLiftPermit, target: BackendBrowserSessionLiftTarget? = nil) async throws {
        do {
            try await permit.check(target)
            guard currentProfile(permit.source.endpoint) != nil, target.map({ currentProfile($0.endpoint) != nil }) ?? true else {
                throw NativeRPCError(code: "lift-endpoint-changed", message: "The approved source or target profile binding changed.")
            }
        } catch { revoke(permit.id); throw error }
    }
    private func writeStorage(_ storage: Storage, to target: BackendBrowserSessionLiftTarget,
                              permit: BackendBrowserSessionLiftPermit, heldLiftID: UUID? = nil) async throws -> StorageWrite {
        try await checked(permit, target: target)
        if let heldLiftID { try requireHeld(heldLiftID, permit: permit) }
        guard let tab = target.tabID, let document = target.documentID, let page = pages[tab], let view = page.view,
              page.documentID == document, page.committedOrigin == target.origin,
              view.configuration.websiteDataStore === currentProfile(target.endpoint)?.store else {
            throw NativeRPCError(code: "lift-storage-page-changed", message: "The exact destination storage document changed. No seed was delivered elsewhere.")
        }
        let nonce = try await documentNonce(view, origin: target.origin)
        try await checked(permit, target: target)
        if let heldLiftID { try requireHeld(heldLiftID, permit: permit) }
        guard pages[tab]?.documentID == document else { throw NativeRPCError(code: "lift-storage-page-changed", message: "The destination document moved before storage was seeded.") }
        let arguments: [String: Any] = ["expectedOrigin": target.origin, "expectedNonce": nonce, "replace": permit.conflict == .replaceMatching,
            "localEntries": storage.local.map { [$0.0, $0.1] }, "sessionEntries": storage.session.map { [$0.0, $0.1] }]
        let raw: Any?
        do { raw = try await submitStorageWrite(view, profileID: target.endpoint.profileID, arguments: arguments).foundation }
        catch { throw NativeRPCError(code: "lift-storage-failed", message: "The destination refused the storage seed. No stored values were returned.") }
        try await checked(permit, target: target)
        if let heldLiftID { try requireHeld(heldLiftID, permit: permit) }
        guard pages[tab]?.documentID == document, let result = raw as? [String: Any], result["matched"] as? Bool == true else {
            throw NativeRPCError(code: "lift-storage-page-changed", message: "The destination document changed while storage was being seeded. No completion was claimed.")
        }
        func count(_ name: String) -> Int { max(0, min(storage.count, (result[name] as? NSNumber)?.intValue ?? 0)) }
        return StorageWrite(set: count("set"), refused: count("refused"), preserved: count("preserved"), unchanged: count("unchanged"))
    }
    private func documentNonce(_ view: WKWebView, origin: String) async throws -> String {
        let raw = try await view.callAsyncJavaScript(Self.documentNonceScript, arguments: ["expectedOrigin": origin], in: nil, contentWorld: Self.world)
        guard let nonce = raw as? String, nonce.count == 32 else { throw NativeRPCError(code: "lift-document-origin", message: "The live document no longer has the approved origin.") }; return nonce
    }
    private func requireHeld(_ id: UUID, permit: BackendBrowserSessionLiftPermit) throws {
        guard let lift = lifts[id], lift.permit.id == permit.id, lift.summary.expiresAt > Self.now() else {
            throw NativeRPCError(code: "lift-expired", message: "The held session expired or was forgotten during transfer. No further values will be copied.")
        }
    }
    private func readBundle(_ raw: Any?) throws -> (entries: [(String, String)], truncated: Bool) {
        guard let raw = raw as? [String: Any], let rows = raw["entries"] as? [[String]] else { throw NativeRPCError(code: "lift-storage-malformed", message: "The native storage export was malformed.") }
        var bytes = 0, entries: [(String, String)] = [], truncated = raw["truncated"] as? Bool == true
        for row in rows {
            guard row.count == 2, !row[0].isEmpty else { continue }
            bytes += row[0].utf16.count + row[1].utf16.count
            if entries.count == 200 || bytes > 256 * 1024 { truncated = true; break }
            entries.append((row[0], row[1]))
        }
        return (entries, truncated)
    }
    private func watch(_ permit: BackendBrowserSessionLiftPermit) {
        guard permissionObservers[permit.id] == nil else { return }
        let id = permit.id
        let observer = permit.cancellation.observe { [weak self] in Task { @MainActor in self?.revoke(id) } }
        permissionObservers[id] = (permit.cancellation, observer, permit.holder)
    }
    private func cleanupObservers() {
        let used = Set(lifts.values.map { $0.permit.id } + seeds.values.map { $0.permit.id } + Array(activePermits.keys))
        for id in permissionObservers.keys where !used.contains(id) {
            if let observer = permissionObservers.removeValue(forKey: id) { observer.0.removeObserver(observer.1) }
        }
    }
    private func finishActive(_ permitID: UUID) {
        if let count = activePermits[permitID], count > 1 { activePermits[permitID] = count - 1 }
        else { activePermits[permitID] = nil }
        cleanupObservers()
    }
    private func invalidateEndpoint(_ id: UUID) {
        let permits = Set(lifts.values.filter { $0.summary.source.endpoint.id == id || $0.permit.targets.contains(where: { $0.endpoint.id == id }) }.map { $0.permit.id }
            + seeds.values.filter { $0.target.endpoint.id == id || $0.permit.source.endpoint.id == id }.map { $0.permit.id })
        for permit in permits { revoke(permit) }
    }
    private func sweep() {
        let now = Self.now()
        lifts = lifts.filter { $0.value.summary.expiresAt > now && $0.value.permit.expiresAt > now && !$0.value.permit.cancellation.isCancelled }
        seeds = seeds.filter { $0.value.expiresAt > now && $0.value.permit.expiresAt > now && !$0.value.permit.cancellation.isCancelled }
        cleanupObservers()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel(); expiryTask = nil; expiryGeneration &+= 1
        let deadlines = lifts.values.map { min($0.summary.expiresAt, $0.permit.expiresAt) } + seeds.values.map { min($0.expiresAt, $0.permit.expiresAt) }
        guard let deadline = deadlines.min() else { return }
        let generation = expiryGeneration, delay = max(1, min(3_600_000, deadline - Self.now()))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(Int64(delay))); try Task.checkCancellation() } catch { return }
            guard let self, self.expiryGeneration == generation else { return }
            self.sweep(); self.scheduleExpiry(); self.changed()
        }
    }
    private func cookies(_ store: WKWebsiteDataStore) async throws -> [HTTPCookie] {
        let reply = NativeSafariSessionLiftReply<[HTTPCookie]>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() } catch { return }
            reply.finish(.failure(NativeRPCError(code: "lift-cookie-timeout", message: "The native cookie read did not finish before its deadline.")))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                store.httpCookieStore.getAllCookies { reply.finish(.success($0)) }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
    private func put(_ cookie: HTTPCookie, into store: WKWebsiteDataStore, profileID: String) async throws {
        guard !closed, !retiredProfiles.contains(profileID) else { throw NativeRPCError(code: "lift-profile-retiring", message: "This session-transfer destination is being retired.") }
        let reply = NativeSafariSessionLiftReply<Bool>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() } catch { return }
            reply.finish(.failure(NativeRPCError(code: "lift-cookie-timeout", message: "The native cookie write did not finish before its deadline. Its in-flight outcome is unverified.")))
        }
        defer { deadline.cancel() }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                guard !closed, !retiredProfiles.contains(profileID) else {
                    reply.finish(.failure(NativeRPCError(code: "lift-profile-retiring", message: "This cookie writer's profile is being retired."))); return
                }
                let id = UUID(), completed = NativeSafariSessionLiftCompletion()
                submittedWrites[id] = SubmittedWrite(profileID: profileID, completion: completed)
                store.httpCookieStore.setCookie(cookie) { [weak self] in
                    completed.complete(); reply.finish(.success(true))
                    Task { @MainActor in self?.submittedWrites[id] = nil }
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
    private func submitStorageWrite(_ view: WKWebView, profileID: String, arguments: [String: Any]) async throws -> NativeRPCValue {
        guard !closed, !retiredProfiles.contains(profileID) else { throw NativeRPCError(code: "lift-profile-retiring", message: "This storage-seed destination is being retired.") }
        let reply = NativeSafariSessionLiftReply<NativeRPCValue>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() } catch { return }
            reply.finish(.failure(NativeRPCError(code: "lift-storage-timeout", message: "The storage writer did not finish before its deadline. Its in-flight outcome is unverified.")))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                guard !closed, !retiredProfiles.contains(profileID) else {
                    reply.finish(.failure(NativeRPCError(code: "lift-profile-retiring", message: "This storage writer's profile is being retired."))); return
                }
                let id = UUID(), completed = NativeSafariSessionLiftCompletion()
                submittedWrites[id] = SubmittedWrite(profileID: profileID, completion: completed)
                view.callAsyncJavaScript(Self.writeStorageScript, arguments: arguments, in: nil, in: Self.world) { [weak self] result in
                    completed.complete()
                    switch result {
                    case .success(let value):
                        do { reply.finish(.success(try NativeRPCValue.fromFoundation(value))) }
                        catch { reply.finish(.failure(error)) }
                    case .failure:
                        reply.finish(.failure(NativeRPCError(code: "lift-storage-failed", message: "The native storage writer failed. Its values were not returned.")))
                    }
                    Task { @MainActor in self?.submittedWrites[id] = nil }
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
    private static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    private static func seedKey(_ target: BackendBrowserSessionLiftTarget) -> String { target.endpoint.id.uuidString + "\0" + target.origin }
    private static func domain(_ cookie: HTTPCookie) -> String { cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    private static func applies(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = Self.domain(cookie)
        return !domain.isEmpty && (host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain)))
    }
    private static func identity(_ cookie: HTTPCookie) -> String { domain(cookie) + "\0" + cookie.path + "\0" + cookie.name }
    private static func hasUnsupportedPartition(_ cookie: HTTPCookie) -> Bool {
        (cookie.properties ?? [:]).keys.contains { ["partitioned", "partitionkey"].contains($0.rawValue.lowercased()) }
    }
    private static func sameCookie(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        guard identity(a) == identity(b), a.value == b.value, a.domain.hasPrefix(".") == b.domain.hasPrefix("."),
              a.isSecure == b.isSecure, a.isHTTPOnly == b.isHTTPOnly, a.isSessionOnly == b.isSessionOnly,
              a.sameSitePolicy?.rawValue.lowercased() == b.sameSitePolicy?.rawValue.lowercased() else { return false }
        switch (a.expiresDate, b.expiresDate) {
        case (nil, nil): return true
        case let (left?, right?): return abs(left.timeIntervalSince1970 - right.timeIntervalSince1970) < 1
        default: return false
        }
    }
    private static let documentNonceScript = #"""
    if (window.top !== window || location.origin !== expectedOrigin) return null;
    if (!globalThis.__terminalDeckLiftNonce) {
      const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
      const nonce = Array.from(bytes, x => x.toString(16).padStart(2, '0')).join('');
      Object.defineProperty(globalThis, '__terminalDeckLiftNonce', { value: nonce, configurable: false, writable: false });
    }
    return globalThis.__terminalDeckLiftNonce;
    """#
    private static let readStorageScript = #"""
    if (window.top !== window || location.origin !== expectedOrigin || globalThis.__terminalDeckLiftNonce !== expectedNonce) return null;
    const grab = store => {
      const entries = []; let size = 0;
      try {
        const length = store.length;
        for (let i = 0; i < length; i++) {
          if (entries.length >= 200) return { entries, truncated: true };
          const key = store.key(i), value = store.getItem(key);
          if (typeof key !== 'string' || !key || typeof value !== 'string') continue;
          size += key.length + value.length;
          if (size > 256 * 1024) return { entries, truncated: true };
          entries.push([key, value]);
        }
      } catch (_) { return { entries, truncated: true }; }
      return { entries, truncated: false };
    };
    let local, session;
    try { local = grab(localStorage); } catch (_) { local = { entries: [], truncated: true }; }
    try { session = grab(sessionStorage); } catch (_) { session = { entries: [], truncated: true }; }
    return { origin: location.origin, nonce: expectedNonce, local, session };
    """#
    private static let writeStorageScript = #"""
    if (window.top !== window || location.origin !== expectedOrigin || globalThis.__terminalDeckLiftNonce !== expectedNonce) return { matched: false };
    let set = 0, refused = 0, preserved = 0, unchanged = 0;
    const put = (storage, rows) => {
      for (const [key, value] of rows) {
        try {
          const prior = storage.getItem(key);
          if (prior === value) { unchanged++; continue; }
          if (prior !== null && !replace) { preserved++; continue; }
          storage.setItem(key, value);
          if (storage.getItem(key) === value) set++; else refused++;
        } catch (_) { refused++; }
      }
    };
    try { put(localStorage, localEntries); } catch (_) { refused += localEntries.length; }
    try { put(sessionStorage, sessionEntries); } catch (_) { refused += sessionEntries.length; }
    return { matched: true, set, refused, preserved, unchanged };
    """#
}
