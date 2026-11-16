import Foundation
import TerminalDeckNativeCore

public protocol BackendCloudBackupWatching: Sendable {
  func watch(folder: String, context: NativeRPCContext) async throws
  func unwatch(folder: String, ownerId: String) async
}
public struct BackendCloudBackupFileEvents: BackendCloudBackupWatching {
  private let service: BackendFileWatchService
  public init(_ service: BackendFileWatchService) { self.service = service }
  public func watch(folder: String, context: NativeRPCContext) async throws { _ = try await service.watchGit(cwd: folder, context: context) }
  public func unwatch(folder: String, ownerId: String) async { await service.unwatch(cwd: folder, ownerID: ownerId) }
}

/// One shared debounce task for all project roots. Uses fs:changed, so ignored-file edits are not lost
/// when Git's visible status stays identical. The existing shared scheduler calls databaseSafetyTick.
public actor BackendCloudBackupWatcher {
  public enum State: String, Sendable { case queued, savedLocally, partial, blocked }
  private let registry: NativeChannelRegistry
  private let events: any BackendCloudBackupWatching
  private let context: NativeRPCContext
  private let allowed: @Sendable () async -> Bool
  private let capture: @Sendable (CloudBackupRoot, String) async throws -> CloudBackupSnapshot
  private let report: @Sendable (String, State) async -> Void
  private let debounce: Duration
  private let clock = ContinuousClock()
  private let epoch = UUID().uuidString
  private var roots: [String: CloudBackupRoot] = [:]
  private var pending: [String: (at: ContinuousClock.Instant, cursor: String)] = [:]
  private var listener: NativeRPCSubscription?
  private var worker: Task<Void, Never>?
  private var generation = UUID()
  private var active: String?
  private var paused = false
  private var stopped = false
  public init(registry: NativeChannelRegistry, events: any BackendCloudBackupWatching, context: NativeRPCContext,
              allowed: @escaping @Sendable () async -> Bool,
              capture: @escaping @Sendable (CloudBackupRoot, String) async throws -> CloudBackupSnapshot,
              report: @escaping @Sendable (String, State) async -> Void, debounce: Duration = .seconds(2)) throws {
    guard context.ownerID.hasPrefix("cloud-backup:") else { throw CloudBackupError.unsafePath }
    self.registry = registry; self.events = events; self.context = context; self.allowed = allowed
    self.capture = capture; self.report = report; self.debounce = debounce
  }
  public func replaceProjectRoots(_ values: [CloudBackupRoot]) async throws {
    guard !stopped, await allowed() else { throw CloudFailure.gateClosed }
    var next: [String: CloudBackupRoot] = [:]
    for root in values {
      guard root.directory.isFileURL, !root.projectId.isEmpty, !root.rootId.isEmpty, root.includedPaths == nil else { throw CloudFailure.unsupportedFormat }
      let key = try CloudBackupDigest.of([root.projectId, root.rootId])
      guard next[key] == nil else { throw CloudFailure.idReused }
      next[key] = root
    }
    if listener == nil {
      listener = try await registry.subscribe("fs:changed", ownerID: context.ownerID) { [weak self] event in
        await self?.changed(event)
      }
    }
    for (key, old) in roots where next[key]?.directory != old.directory {
      await events.unwatch(folder: old.directory.path, ownerId: context.ownerID)
      pending[key] = nil
      if active == key { worker?.cancel() }
      roots[key] = nil
    }
    for (key, root) in next {
      if roots[key] == nil {
        try await events.watch(folder: root.directory.path, context: context)
        roots[key] = root
        await enqueue(key, cursor: epoch + ":initial")
      } else { roots[key] = root }
    }
  }
  /// One existing 15-minute scheduler calls this for active projects; this actor adds no periodic timer.
  public func databaseSafetyTick(activeProjectIds: Set<String>) async {
    for (key, root) in roots where activeProjectIds.contains(root.projectId) { await enqueue(key, cursor: epoch + ":database") }
  }
  public func pendingCount() -> Int { pending.count + (active == nil ? 0 : 1) }
  public func resume() { guard !stopped else { return }; paused = false; arm() }
  public func stop() async {
    stopped = true; worker?.cancel(); generation = UUID(); pending.removeAll()
    await listener?.cancelAndWait(); listener = nil
    for root in roots.values { await events.unwatch(folder: root.directory.path, ownerId: context.ownerID) }
    roots.removeAll()
  }
  private func changed(_ event: NativeRPCEvent) async {
    guard !stopped, let path = event.arguments.first?.string else { return }
    for (key, root) in roots where root.directory.path == path { await enqueue(key, cursor: epoch + ":" + String(event.sequence)) }
  }
  private func enqueue(_ key: String, cursor: String) async {
    guard !stopped else { return }
    pending[key] = (clock.now.advanced(by: debounce), cursor)
    await report(key, .queued)
    if active == nil { worker?.cancel(); worker = nil; generation = UUID(); arm() }
  }
  private func arm() {
    guard !stopped, !paused, active == nil, worker == nil, let first = pending.values.map(\.at).min() else { return }
    let id = generation, clock = clock
    worker = Task { [weak self] in
      do { try await clock.sleep(until: first); await self?.drain(id) }
      catch { }
    }
  }
  private func drain(_ id: UUID) async {
    guard id == generation, !stopped, active == nil else { return }
    guard let key = pending.min(by: { $0.value.at < $1.value.at })?.key,
      let item = pending[key], let root = roots[key] else { worker = nil; arm(); return }
    guard item.at <= clock.now else { worker = nil; arm(); return }
    active = key
    guard await allowed() else { paused = true; active = nil; worker = nil; return }
    pending[key] = nil
    do {
      try Task.checkCancellation()
      let value = try await capture(root, item.cursor)
      if !stopped, roots[key]?.directory == root.directory { await report(key, value.manifest.scanComplete ? .savedLocally : .partial) }
    } catch {
      if !stopped, roots[key]?.directory == root.directory { await report(key, .blocked) }
    }
    active = nil; worker = nil
    arm()
  }
}
