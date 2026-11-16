import Foundation
import TerminalDeckNativeCore

public struct BackendCloudConversationContinueRequest: Sendable {
  public let manifestID: String
  public let conversationID: String
  public let projectID: String
  public let rootID: String
  public let provider: CloudConversationProvider
  public let oldPath: String
  public let newPath: String
  public let expectedGeneration: CloudSequence
  /// Continuing a superseded version leaves out later turns; it needs this explicit choice.
  public let allowOlderVersion: Bool
  public init(manifestID: String, conversationID: String, projectID: String, rootID: String, provider: CloudConversationProvider,
              oldPath: String, newPath: String, expectedGeneration: CloudSequence, allowOlderVersion: Bool = false) {
    self.manifestID = manifestID; self.conversationID = conversationID; self.projectID = projectID; self.rootID = rootID
    self.provider = provider; self.oldPath = oldPath; self.newPath = newPath; self.expectedGeneration = expectedGeneration
    self.allowOlderVersion = allowOlderVersion
  }
}
public struct BackendCloudConversationLaunchReceipt: Sendable {
  public let conversationID: String
  public let sessionID: String
  public let resumed: Bool
  public init(conversationID: String, sessionID: String, resumed: Bool) {
    self.conversationID = conversationID; self.sessionID = sessionID; self.resumed = resumed
  }
}
public struct BackendCloudConversationContinueReceipt: Sendable {
  public let launch: BackendCloudConversationLaunchReceipt
  public let lease: BackendCloudConversationLeaseHolder
  public let projectedFile: BackendCloudConversationProjectedFile
}

/// Holds one conversation lease for the life of the continued session: renews every 25 s (spec: at most 30 s),
/// releases when the session ends. A failed renewal is recorded; the running session is never stopped by it.
public actor BackendCloudConversationLeaseHolder {
  public static let renewSeconds = 25
  public private(set) var lease: CloudLease
  public private(set) var renewals = 0
  public private(set) var lost = false
  public private(set) var released = false
  private let deviceID: String
  private let acquire: @Sendable (CloudLeaseRequest) async throws -> CloudLease
  private let release: @Sendable (CloudLease) async throws -> Void
  private let sleep: @Sendable (Int) async throws -> Void
  private let now: @Sendable () -> Int64
  private var loop: Task<Void, Never>?
  private var watcher: Task<Void, Never>?
  init(lease: CloudLease, deviceID: String, acquire: @escaping @Sendable (CloudLeaseRequest) async throws -> CloudLease,
       release: @escaping @Sendable (CloudLease) async throws -> Void, sleep: @escaping @Sendable (Int) async throws -> Void,
       now: @escaping @Sendable () -> Int64) {
    self.lease = lease; self.deviceID = deviceID; self.acquire = acquire; self.release = release; self.sleep = sleep; self.now = now
  }
  func start(sessionEnded: @escaping @Sendable () async -> Void) {
    guard loop == nil, !released else { return }
    let sleep = self.sleep, interval = Self.renewSeconds
    // Both tasks hold the holder until the session ends, so dropping the receipt cannot end the renewals early.
    loop = Task {
      while !Task.isCancelled {
        do { try await sleep(interval) } catch { return }
        guard !Task.isCancelled else { return }
        let renewed = await self.renew()
        if !renewed { return }
      }
    }
    watcher = Task {
      await sessionEnded()
      await self.stop()
    }
  }
  /// Same call as the first take, with the current generation, while the session actually runs.
  func renew() async -> Bool {
    guard !released, !lost else { return false }
    do {
      let next = try await acquire(.init(resourceId: lease.resourceId, expectedGeneration: lease.generation, ttlSeconds: 60))
      // The session ended while this renewal was in flight: give back what was just taken.
      if released { if next.deviceId == deviceID { try? await release(next) }; return false }
      guard next.resourceId == lease.resourceId, next.deviceId == deviceID, next.until > now(),
        next.generation >= lease.generation else { lost = true; return false }
      lease = next; renewals += 1
      return true
    } catch { lost = true; return false }
  }
  public func stop() async {
    guard !released else { return }
    released = true
    loop?.cancel(); loop = nil; watcher = nil
    try? await release(lease)
  }
}

/// A supplies the existing resolver/launcher and SYNC's lease port. No network or process is constructed here.
public actor BackendCloudConversationContinue {
  public struct Ports: Sendable {
    public let context: @Sendable (String) async throws -> CloudContextReady
    public let checkMappingAndProvider: @Sendable (BackendCloudConversationContinueRequest) async throws -> Void
    public let acquire: @Sendable (CloudLeaseRequest) async throws -> CloudLease
    public let release: @Sendable (CloudLease) async throws -> Void
    /// Starts the provider in the projected private home through the existing launcher; returns its session id.
    public let launchFile: @Sendable (BackendCreateSessionInput, BackendCloudConversationProjectedFile) async throws -> BackendCloudConversationLaunchReceipt
    /// Returns when that session has ended. Required: without a renewal owner nothing is launched.
    public let sessionEnded: @Sendable (String) async -> Void
    public let sleep: @Sendable (Int) async throws -> Void
    public init(context: @escaping @Sendable (String) async throws -> CloudContextReady,
                checkMappingAndProvider: @escaping @Sendable (BackendCloudConversationContinueRequest) async throws -> Void,
                acquire: @escaping @Sendable (CloudLeaseRequest) async throws -> CloudLease,
                release: @escaping @Sendable (CloudLease) async throws -> Void,
                launchFile: @escaping @Sendable (BackendCreateSessionInput, BackendCloudConversationProjectedFile) async throws -> BackendCloudConversationLaunchReceipt,
                sessionEnded: @escaping @Sendable (String) async -> Void,
                sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) }) {
      self.context = context; self.checkMappingAndProvider = checkMappingAndProvider; self.acquire = acquire; self.release = release
      self.launchFile = launchFile; self.sessionEnded = sessionEnded; self.sleep = sleep
    }
  }
  private let archive: BackendCloudConversationArchive
  private let branches: BackendCloudConversationBranches
  private let ports: Ports
  private let deviceID: String
  private let now: @Sendable () -> Int64
  private var active = Set<String>()
  public init(archive: BackendCloudConversationArchive, branches: BackendCloudConversationBranches, ports: Ports, deviceID: String,
              now: @escaping @Sendable () -> Int64 = { CloudSyncBytes.now() }) {
    self.archive = archive; self.branches = branches; self.ports = ports; self.deviceID = deviceID; self.now = now
  }
  public func explicitlyContinue(_ request: BackendCloudConversationContinueRequest) async throws -> BackendCloudConversationContinueReceipt {
    try Task.checkCancellation()
    let resource = "conversation:" + request.provider.rawValue + ":" + request.conversationID
    guard active.insert(resource).inserted else { throw CloudFailure.versionChanged }
    defer { active.remove(resource) }
    let context = try await ports.context(request.projectID)
    guard context.projectId == request.projectID, context.verified, context.sourceCounts.blocked == 0, context.missingSources.isEmpty else { throw CloudFailure.unavailable }
    try await ports.checkMappingAndProvider(request)
    let metadata = try await archive.metadata(manifestID: request.manifestID)
    guard metadata.payload.raw["provider"].string == request.provider.rawValue else { throw CloudFailure.invalidRequest }
    // Only the current version, unless an older one was chosen explicitly.
    let heads = try await archive.heads(fileID: metadata.entityId)
    if !request.allowOlderVersion { guard heads.map(\.opId) == [request.manifestID] else { throw CloudFailure.versionChanged } }
    if request.provider == .claude {
      guard let relative = metadata.payload.raw["relativePath"].string,
        URL(fileURLWithPath: relative).lastPathComponent == request.conversationID + ".jsonl" else { throw CloudFailure.unsupportedFormat }
    }
    let projected = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: request.manifestID,
      provider: request.provider, conversationID: request.conversationID, projectID: request.projectID, rootID: request.rootID,
      oldPath: request.oldPath, newPath: request.newPath, stagingDirectory: branches.directory)
    // Registered before launch: turns made from now on are in an approved, uploaded home with their branch link.
    try await branches.register(branchID: projected.branchID, provider: request.provider, providerHome: projected.providerHome,
      branch: .init(parentManifest: request.manifestID, conversationId: request.conversationID, deviceId: deviceID))
    try Task.checkCancellation()
    let lease = try await ports.acquire(.init(resourceId: resource, expectedGeneration: request.expectedGeneration, ttlSeconds: 60))
    let holder = BackendCloudConversationLeaseHolder(lease: lease, deviceID: deviceID, acquire: ports.acquire, release: ports.release,
      sleep: ports.sleep, now: now)
    do {
      guard lease.resourceId == resource, lease.deviceId == deviceID, lease.until > now(),
        lease.generation > request.expectedGeneration else { throw CloudFailure.versionChanged }
      var input = BackendCreateSessionInput(cwd: request.newPath, provider: request.provider.rawValue)
      input.projectId = request.projectID; input.resume = true; input.resumeConversationId = request.conversationID
      input.forkSession = false; input.pickConversation = false
      input.cloudContinue = .continuing
      try Task.checkCancellation()
      let launched = try await ports.launchFile(input, projected)
      guard launched.resumed, launched.conversationID == request.conversationID, !launched.sessionID.isEmpty else { throw CloudFailure.unsupportedFormat }
      let ended = ports.sessionEnded, session = launched.sessionID
      await holder.start(sessionEnded: { await ended(session) })
      return .init(launch: launched, lease: holder, projectedFile: projected)
    } catch {
      // Never release a lease this device does not hold.
      if lease.deviceId == deviceID, lease.resourceId == resource { await holder.stop() }
      throw error
    }
  }
}
