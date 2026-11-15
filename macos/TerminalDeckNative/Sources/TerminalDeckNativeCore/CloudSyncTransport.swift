import Foundation
import Network

/// Blob IO is separate from the frozen control port. A injects the same transport instance into both.
public protocol CloudSyncObjectIO: Sendable {
  func upload(_ bytes: Data, ticket: CloudBlobTicket) async throws
  func download(_ url: URL, maximumBytes: Int) async throws -> Data
}

/// Local binding seam; authentication remains owned by the shared account manager.
/// A transport that can tell its owner when the network returned or the Mac woke, also after its event stream ended.
public protocol CloudSyncWakePort: Sendable {
  func onWake(_ handler: @escaping @Sendable () async -> Void) async
}
public protocol CloudSyncRegistrationPort: Sendable {
  func currentDeviceId() async throws -> String
}

public struct CloudSyncEndpoint: Sendable {
  public enum Environment: Sendable { case production, test }
  let base: URL
  let environment: Environment
  let objectHosts: Set<String>
  public init(base: URL, environment: Environment, objectHosts: Set<String>) throws {
    guard base.scheme == "https", let host = base.host, base.user == nil, base.password == nil,
      base.query == nil, base.fragment == nil, base.path == "/v1", !objectHosts.isEmpty else { throw CloudFailure.unsafeConfiguration }
    switch environment {
    case .production:
      guard base.absoluteString == CloudWire.productionBase else { throw CloudFailure.unsafeConfiguration }
    case .test:
      guard host != URL(string: CloudWire.productionBase)?.host,
        host.hasSuffix(".test") || host.contains("td-cloud-test") else { throw CloudFailure.unsafeConfiguration }
      guard objectHosts.allSatisfy({ $0.hasSuffix(".test") || $0.contains("td-cloud-test") }) else { throw CloudFailure.unsafeConfiguration }
    }
    self.base = base
    self.environment = environment
    self.objectHosts = objectHosts
  }
  func permitSubject(_ subject: CloudSubject) throws {
    switch environment {
    case .production:
      guard subject.issuer == CloudWire.issuer else { throw CloudFailure.unsafeConfiguration }
    case .test:
      guard let issuer = URL(string: subject.issuer), issuer.scheme == "https", let host = issuer.host,
        host.hasSuffix(".test") || (host.hasPrefix("td-cloud-test.") && host.hasSuffix(".workers.dev")) else { throw CloudFailure.unsafeConfiguration }
    }
  }
  func permitObject(_ url: URL) throws {
    guard url.scheme == "https", let host = url.host, host == base.host, url.port == base.port, url.path.hasPrefix(base.path + "/transfers/"), url.user == nil, url.password == nil,
      url.fragment == nil else { throw CloudFailure.unsafeConfiguration }
  }
}

private final class CloudSyncNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor CloudSyncTransport: CloudTransportPort, CloudSyncObjectIO, CloudSyncRegistrationPort, CloudSyncWakePort {
  private let endpoint: CloudSyncEndpoint
  private let auth: any CloudAuthenticationPort
  private let signer: CloudSyncSigner
  private let store: CloudSyncStore
  private let budget: CloudSyncBudget
  private let session: URLSession
  private var stopped = false
  private var socket: (any CloudSyncSocketConnection)?
  private let socketFactory: CloudSyncSocketFactory?
  private let heartbeatInterval: Duration
  private let socketRetryBase: Duration
  private var eventGeneration: UUID?
  private var eventTask: Task<Void, Never>?
  private var transfers = 0
  private var refreshingSocket = false
  /// X5: bulk reads and sends, spread under the service's per-device limits (CloudSyncServicePace).
  private var bulkPacer = CloudSyncTransferPacer(perSecond: CloudSyncServicePace.bulkReadsPerSecond)
  private var sendPacer = CloudSyncTransferPacer(perSecond: CloudSyncServicePace.sendsPerSecond)
  private func pace(_ method: String, _ path: String) async throws {
    if (method == "GET" && path.hasPrefix("/changes")) || (method == "POST" && path.hasPrefix("/applied")) { try await bulkPacer.take() }
    else if method == "POST" && path.hasPrefix("/changes") { try await sendPacer.take() }
  }
  private func slowDown(_ status: Int) async {
    guard status == 429 else { return }
    await bulkPacer.slowDown(); await sendPacer.slowDown()
  }

  public init(endpoint: CloudSyncEndpoint, auth: any CloudAuthenticationPort, signer: @escaping CloudSyncSigner,
              store: CloudSyncStore, budget: CloudSyncBudget) throws {
    try endpoint.permitSubject(store.subject)
    self.socketFactory = nil; self.heartbeatInterval = .seconds(25); self.socketRetryBase = .seconds(1)
    self.endpoint = endpoint; self.auth = auth; self.signer = signer; self.store = store; self.budget = budget
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 120
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: configuration, delegate: CloudSyncNoRedirect(), delegateQueue: nil)
  }
  // Test-target callers can supply a URLProtocol-only session, but never a live endpoint.
  init(fixtureEndpoint: CloudSyncEndpoint, auth: any CloudAuthenticationPort, signer: @escaping CloudSyncSigner,
       store: CloudSyncStore, budget: CloudSyncBudget, fixtureSession: URLSession, fixtureSocketFactory: CloudSyncSocketFactory? = nil,
       fixtureHeartbeat: Duration = .seconds(25), fixtureSocketRetryBase: Duration = .seconds(1)) throws {
    guard fixtureEndpoint.base.host?.hasSuffix(".test") == true,
      fixtureSession.configuration.protocolClasses?.isEmpty == false else { throw CloudFailure.unsafeConfiguration }
    try fixtureEndpoint.permitSubject(store.subject)
    socketFactory = fixtureSocketFactory; heartbeatInterval = fixtureHeartbeat; socketRetryBase = fixtureSocketRetryBase
    endpoint = fixtureEndpoint; self.auth = auth; self.signer = signer; self.store = store; self.budget = budget
    session = fixtureSession
    bulkPacer = .instant(); sendPacer = .instant(); fixtureClock = true
  }
  /// MAC-NEXT-7 (5): fixture transports pace instantly, and the sync core's retry back-offs run 100 times faster.
  private var fixtureClock = false
  public func backoff(milliseconds: Int64) async throws {
    try await Task.sleep(for: .milliseconds(max(1, fixtureClock ? milliseconds / 100 : milliseconds)))
  }
  private struct Empty: Codable {}
  private struct Items<T: Codable & Sendable>: Codable, Sendable { let items: [T] }
  private struct BlobIDs: Codable { let blobIds: [String] }
  private struct Checkpoint: Decodable { let checkpoint: CloudCheckpoint? }
  private struct Verify: Codable { let checkpointId: String; let inventoryDigest: String; let counts: CloudCounts }
  private struct Verified: Decodable { let checkpointId: String; let verifiedBy: [String] }
  private struct Applied: Codable { let brainSeq: CloudSequence; let secretsSeq: CloudSequence; let checkpointId: String? }
  private struct Release: Codable { let resourceId: String; let generation: CloudSequence }
  private struct Released: Decodable { let released: Bool }
  private struct FailureBody: Decodable { let error: CloudErrorDetail }
  /// The service's `400 clock_skew` answer: this Mac's clock is more than a minute off, and the service says its
  /// own time. It is checked before the signature, so it tells nothing but the service's clock.
  private struct SkewBody: Decodable {
    struct Detail: Decodable { let code: String; let serverTime: Int64? }
    let error: Detail
  }
  private struct ClockSkew: Error { let serverTime: Int64 }
  /// What lane A shows when the service keeps refusing this Mac's clock (also a gap reason on every source).
  static let clockSkewReason = "Check this Mac's date and time."
  /// The time requests are signed with: this Mac's clock plus the correction learned from a `clock_skew` answer
  /// (kept in sync.sqlite, so a Mac with a wrong clock does not pay one refused request per launch).
  private var signingOffset: Int64?
  private func signingTime() -> Int64 {
    if signingOffset == nil { signingOffset = (try? store.value("signingClockOffset") as Int64?) ?? 0 }
    return CloudSyncBytes.now() + (signingOffset ?? 0)
  }
  /// Possibly noted in the store (unknown at launch): the first answered request clears it once.
  private var skewNoted = true

  private func request(method: String, path: String, body: Data, requestId: String) async throws -> URLRequest {
    guard !stopped, let url = URL(string: endpoint.base.absoluteString + path) else { throw CloudFailure.unavailable }
    let credentials = try await auth.credentials()
    guard credentials.user.id == store.subject.sub else { throw CloudFailure.unsafeConfiguration }
    let time = signingTime()
    let transmitted = url.path + (url.query.map { "?" + $0 } ?? "")
    let proof = try await auth.signRequest(method: method, pathAndQuery: transmitted, body: body, timestamp: time, requestId: requestId)
    guard proof.time == time, proof.requestId == requestId else { throw CloudFailure.invalidRequest }
    var request = URLRequest(url: url)
    request.httpMethod = method
    if method != "GET" { request.httpBody = body }
    request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    for (name, value) in proof.headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }
  private func call<Body: Encodable, Result: Decodable>(_ method: String, _ path: String, _ body: Body, id: String? = nil, fresh: Bool = false, packScoped: Bool = false, account: Bool = false, as type: Result.Type = Result.self) async throws -> Result {
    guard !stopped else { throw CloudFailure.unavailable }
    let bytes = method == "GET" ? Data() : try CloudSyncCanonical.encode(body)
    guard bytes.count <= 409_600 else { throw CloudFailure.invalidRequest }
    let registration = try await auth.deviceRegistration()
    let key = "request:" + registration.deviceId + ":" + CloudSyncBytes.hash(Data((method + path).utf8) + bytes)
    let requestId: String
    if let id { requestId = id }
    else if method != "GET" {
      if !fresh, let previous: String = try store.value(key) { requestId = previous }
      else { requestId = UUID().uuidString.lowercased(); try store.set(key, requestId) }
    } else { requestId = UUID().uuidString.lowercased() }
    try CloudSyncBytes.transportID(requestId)
    let data = try await send(method, path, bytes: bytes, requestId: requestId, deviceId: registration.deviceId, packScoped: packScoped, account: account)
    let result: Result
    do { result = try CloudWire.decode(Result.self, from: data) }
    catch { try await budget.failed(error); throw (error as? CloudFailure ?? .unavailable) }
    // An answered request ends its logical attempt: drop its saved id so metadata does not grow with
    // history. (Leases also need a fresh expiry next time.) A lost answer keeps the id for the retry.
    if method != "GET" && id == nil { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
    return result
  }
  /// ONE signed control request, the only way a control request leaves this Mac: this Mac's short waits (`CloudSyncBudget`), this
  /// transport's bearer token, the device proof over exactly `bytes` (X-TD-Request = `requestId`), and the answer's
  /// bytes. `call` (typed) and `control` (lane V's saved-password routes) both go through here.
  private func send(_ method: String, _ path: String, bytes: Data, requestId: String, deviceId: String, packScoped: Bool,
                    secretsScoped: Bool = false, account: Bool = false, ownRefusals: Bool = false) async throws -> Data {
    func attempt(skewRetry: Bool) async throws -> Data {
      try await pace(method, path)
      // 13 Nov: the account's own reads never wait on the upload's local blocks (see `reserveAccount`).
      if account { try await budget.reserveAccount() } else { try await budget.reserve(http: 1) }
      let request: URLRequest
      do {
        request = try await self.request(method: method, path: path, body: bytes, requestId: requestId)
        guard request.value(forHTTPHeaderField: "X-TD-Device") == deviceId else { throw CloudFailure.invalidRequest }
      }
      catch where Self.isCancellation(error) { throw CancellationError() }
      catch { try await budget.failed(error); throw (error as? CloudFailure ?? .unavailable) }
      return try await perform(request, packScoped: packScoped, secretsScoped: secretsScoped, ownRefusals: ownRefusals, skewRetry: skewRetry)
    }
    let sentAt = CloudSyncBytes.now()
    let data: Data
    do { data = try await attempt(skewRetry: true) }
    catch let skew as ClockSkew {
      // The service refused this Mac's clock and said its own time. The signing time is corrected from that
      // answer and the SAME request (same id, same bytes) is signed and sent again, ONCE. A second refusal is an
      // ordinary failed request: back-off, a reason lane A can show, never a loop and never a sign-out.
      let receivedAt = CloudSyncBytes.now()
      let offset = skew.serverTime - (sentAt + max(0, receivedAt - sentAt) / 2)
      signingOffset = offset
      try store.set("signingClockOffset", offset)
      try CloudSyncServiceClock.observe(store, serverTime: skew.serverTime, sentAt: sentAt, receivedAt: receivedAt)
      do { data = try await attempt(skewRetry: false) }
      catch {
        if case .remote(let detail)? = error as? CloudFailure, detail.code == "clock_skew" {
          try store.set("clockSkew", Self.clockSkewReason)
          skewNoted = true
        }
        throw error
      }
    }
    if skewNoted {
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("clockSkew".utf8)])
      skewNoted = false
    }
    return data
  }
  /// Lane V's control port for the saved-password routes. The caller's exact body bytes go out under THIS
  /// transport's bearer token and device proof, through the same budget and the same error handling as every other
  /// control call. The caller supplies no header, no host and no token, so nothing sent here can go without the
  /// device proof. Only `/secrets/…` paths. A retry with the same `requestId` and the same bytes is the same
  /// request to the service. Errors are CloudFailure values (`.remote(detail)` with the service's code;
  /// `.secretsLocked` for a locked answer). A refusal that concerns saved passwords only is the caller's to
  /// handle and never pauses memory sync; sign-in, device-proof, budget and rate answers count as for any call.
  public func control(method: String, path: String, body: Data, requestId: String) async throws -> Data {
    guard !stopped else { throw CloudFailure.unavailable }
    guard ["GET", "POST", "PUT", "DELETE"].contains(method), Self.isSecretsPath(path), method != "GET" || body.isEmpty,
      body.count <= 409_600 else { throw CloudFailure.invalidRequest }
    try CloudSyncBytes.transportID(requestId)
    let registration = try await auth.deviceRegistration()
    let data = try await send(method, path, bytes: body, requestId: requestId, deviceId: registration.deviceId, packScoped: false, secretsScoped: true)
    guard data.count <= 409_600 else { throw CloudFailure.invalidRequest }
    return data
  }
  /// Mac shelf (15 Nov): ONE signed request to the shelf routes (`/shelf`, `/shelf/list`, `/shelf/texts`,
  /// `/shelf/files`, `/shelf/setting`) under this transport's bearer token and device proof. The shelf is never sync itself: its answers
  /// (a 404 while the service part is not live, a 429 between two puts of one kind, `shelf_behind`, `shelf_off`) go back
  /// to the caller as (status, bytes) and NEVER reach the shared back-off, the refusal log or the person's "Try again"
  /// block; it takes no upload slot (the account's own reservation, which never waits). Body at most 1 MiB (the
  /// service's shelf limit).
  public func shelf(method: String, path: String, body: Data) async throws -> (status: Int, data: Data) {
    guard !stopped else { throw CloudFailure.unavailable }
    // Open files (15 Nov): one 1 MiB file piece, base64 inside JSON, is about 1.4 MB (the service's files limit 1.5 MB).
    guard method == "GET" || method == "POST", Self.isShelfPath(path), method != "GET" || body.isEmpty,
      body.count <= (path == "/shelf/files" ? 1_500_000 : 1_048_576) else { throw CloudFailure.invalidRequest }
    let registration = try await auth.deviceRegistration()
    try await budget.reserveAccount()
    let requestId = UUID().uuidString.lowercased()
    let request = try await self.request(method: method, path: path, body: body, requestId: requestId)
    guard request.value(forHTTPHeaderField: "X-TD-Device") == registration.deviceId else { throw CloudFailure.invalidRequest }
    do {
      let (data, response) = try await session.data(for: request)
      guard !stopped, let http = response as? HTTPURLResponse else { throw CloudFailure.unavailable }
      guard data.count <= 4_194_304 else { throw CloudFailure.invalidRequest }
      return (http.statusCode, data)
    } catch where Self.isCancellation(error) { throw CancellationError() }
    catch let failure as CloudFailure { throw failure }
    catch { throw CloudFailure.unavailable }
  }
  /// Sessions in the Cloud (15 Nov, step 1): ONE signed request to the session and chat routes (`/chats/tick`,
  /// `/chats/piece`, `/chats/snap`, `/chats/head`, `/chats/raw`, `/chats/read`, `/chats/bin`, `/sessions`) beside the
  /// shelf's door and like it: the same bearer token and device proof; its answers (404 while the service part is not
  /// live, 409, 429) go back to the caller and NEVER reach sync's back-off, the refusal log or "Try again"; no upload
  /// slot. Body at most 8 MiB (the service's chats limit), answer at most 8 MiB.
  public func chats(method: String, path: String, body: Data) async throws -> (status: Int, data: Data) {
    guard !stopped else { throw CloudFailure.unavailable }
    guard method == "GET" || method == "POST", Self.isChatsPath(path), method != "GET" || body.isEmpty,
      body.count <= 8_388_608 else { throw CloudFailure.invalidRequest }
    let registration = try await auth.deviceRegistration()
    try await budget.reserveAccount()
    let requestId = UUID().uuidString.lowercased()
    let request = try await self.request(method: method, path: path, body: body, requestId: requestId)
    guard request.value(forHTTPHeaderField: "X-TD-Device") == registration.deviceId else { throw CloudFailure.invalidRequest }
    do {
      let (data, response) = try await session.data(for: request)
      guard !stopped, let http = response as? HTTPURLResponse else { throw CloudFailure.unavailable }
      guard data.count <= 8_388_608 else { throw CloudFailure.invalidRequest }
      return (http.statusCode, data)
    } catch where Self.isCancellation(error) { throw CancellationError() }
    catch let failure as CloudFailure { throw failure }
    catch { throw CloudFailure.unavailable }
  }
  /// The session and chat routes, with a plain query only (letters, digits, `-_.=&%`): nothing that names another
  /// route, another host, a fragment or a parent folder.
  static func isChatsPath(_ path: String) -> Bool {
    guard path.utf8.count <= 1_024, !path.contains(".."), !path.contains("//") else { return false }
    let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let routes = ["/chats/tick", "/chats/piece", "/chats/snap", "/chats/head", "/chats/raw", "/chats/read", "/chats/bin", "/sessions",
                  "/sessions/move"]
    guard routes.contains(String(parts[0])) else { return false }
    guard parts.count == 2 else { return true }
    return parts[1].utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "-_.=&%".utf8.contains(byte)
    }
  }
  /// The four shelf routes and the shelf's one query (`?kind=<plain word>`), nothing else.
  static func isShelfPath(_ path: String) -> Bool {
    let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    guard ["/shelf", "/shelf/list", "/shelf/texts", "/shelf/files", "/shelf/setting"].contains(String(parts[0])) else { return false }
    guard parts.count == 2 else { return true }
    let query = parts[1]
    guard query.hasPrefix("kind="), query.utf8.count <= 40 else { return false }
    return query.dropFirst(5).utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
  }
  /// `/secrets/` followed by plain path segments and an optional plain query: nothing that could name another
  /// route, another host, a fragment or a parent folder.
  static func isSecretsPath(_ path: String) -> Bool {
    // D1 (lost-device review, 15 Nov): his "Yes, it's mine" for a machine another device signed out. This ONE exact
    // account route goes with the saved-passwords hand-over it unlocks; no other /devices route passes here.
    if path == "/devices/confirm-mine" { return true }
    guard path.hasPrefix("/secrets/"), path.utf8.count > "/secrets/".utf8.count, path.utf8.count <= 512,
      !path.contains(".."), !path.contains("//") else { return false }
    let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    func plain(_ text: Substring, _ extra: String) -> Bool {
      text.utf8.allSatisfy { byte in (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || extra.utf8.contains(byte) }
    }
    return plain(parts[0], "/-_.") && (parts.count == 1 || plain(parts[1], "-_.=&"))
  }
  /// Answers that concern the whole account whatever route gave them (the budget's own list).
  static let accountCodes: Set<String> = ["sign_in_required", "token_expired", "bad_device_proof", "device_revoked", "not_found"]
  static let notFoundCode = "not_found"
  /// True for the saved-password routes' own "not there" answer (`control`): nothing is there; not a failure.
  public static func isNotFound(_ error: any Error) -> Bool {
    if case .remote(let detail)? = error as? CloudFailure { return detail.code == notFoundCode }
    return false
  }
  /// Codes with which the service refuses ONE pack for good (its content, size or ids), not the account.
  static let packOnlyCodes: Set<String> = ["invalid_request", "unsupported_format", "payload_too_large", "checksum_mismatch", "id_reused"]
  /// `ownRefusals` (signing another device out, 14 Nov): that route's refusals for good (the device holds the
  /// saved-passwords key, a changed version, no such device) answer only that request, exactly as a saved-password
  /// route's do; they never put the whole account into a back-off or the person's "Try again" block.
  private func perform(_ request: URLRequest, packScoped: Bool = false, secretsScoped: Bool = false, ownRefusals: Bool = false, skewRetry: Bool = false) async throws -> Data {
    guard !stopped else { throw CloudFailure.unavailable }
    do {
      let (data, response) = try await session.data(for: request)
      guard !stopped, let http = response as? HTTPURLResponse else { throw CloudFailure.unavailable }
      if (200..<300).contains(http.statusCode) {
        try? await budget.served(deviceProven: request.value(forHTTPHeaderField: "X-TD-Device") != nil
          && request.value(forHTTPHeaderField: "X-TD-Signature") != nil)
      }
      guard (200..<300).contains(http.statusCode) else {
        // A first `clock_skew` answer that states the service's time is not a failure yet: the caller corrects
        // the signing time and sends once more. A wrong signature (`bad_device_proof`) never takes this path.
        if skewRetry, http.statusCode == 400, let skew = (try? CloudWire.decode(SkewBody.self, from: data))?.error,
          skew.code == "clock_skew", let serverTime = skew.serverTime, serverTime > 0 { throw ClockSkew(serverTime: serverTime) }
        let error = (try? CloudWire.decode(FailureBody.self, from: data))?.error
        // 14 Nov (the owner's first passkey spare key): service 7ff81baac answers every refused passkey check on the
        // spare routes with 401 bad_device_proof, the code of a failed device proof. It concerns that passkey only:
        // the request's own device proof passed (the routes run after it), so it is the saved-password caller's
        // answer and never pauses memory sync, starts a back-off or says "sign in again" on the Cloud page.
        if secretsScoped, let error, error.code == "bad_device_proof", Self.isSparePasskeyRoute(request.url) {
          throw RecordedFailure(.remote(error))
        }
        // A saved-password route's own refusal is said by the saved-passwords log; it is not kept for the next sync
        // step's line (which then read "fetch failed: budgetPaused / http 401 … at POST /v1/secrets/…").
        if !((secretsScoped || ownRefusals) && Self.routeOnly(error, status: http.statusCode)) {
          CloudSyncDiagnostics.shared.noteRefusal(method: request.httpMethod ?? "GET", url: request.url, status: http.statusCode, code: error?.code)
        }
        await slowDown(http.statusCode)
        // A protected-only refusal waits with saved passwords. It is not a failure of the account,
        // so it never reaches the shared back-off or the account-wide auth/remote blocks.
        if let code = error?.code, Self.protectedOnlyCodes.contains(code) { throw RecordedFailure(.secretsLocked) }
        // A pack refused for good is the engine's to repack or park; it must not block the whole account.
        if packScoped, let error, !error.retryable, Self.packOnlyCodes.contains(error.code) { throw RecordedFailure(.remote(error)) }
        // A saved-password route refusing for good (not approved, a changed version, a bad request) is lane V's to
        // handle: saved passwords never pause memory. Sign-in, device-proof, budget and rate answers still count.
        if secretsScoped || ownRefusals, let error, !error.retryable, ![401, 429].contains(http.statusCode), !Self.accountCodes.contains(error.code) {
          throw RecordedFailure(.remote(error))
        }
        // N1: on a saved-password route "not found" names that approval, challenge, device or route, never the
        // account. It goes back to the caller as its own answer (`isNotFound`) and is not counted: no back-off,
        // no "sign in again" block. An account that is really gone shows on the next ordinary call.
        if secretsScoped || ownRefusals, ![401, 429].contains(http.statusCode), error?.code == Self.notFoundCode || (error == nil && http.statusCode == 404) {
          throw RecordedFailure(.remote(error ?? CloudErrorDetail(code: Self.notFoundCode, message: "Not found.", retryable: false,
            requestId: request.value(forHTTPHeaderField: "X-TD-Request") ?? "")))
        }
        let failure = error.map(CloudFailure.remote) ?? .unavailable
        let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int64.init)
        let milliseconds = seconds.flatMap { value -> Int64? in
          let result = value.multipliedReportingOverflow(by: 1000)
          return result.overflow ? nil : result.partialValue
        } ?? error?.retryAfterMs.map(Int64.init)
        let delay = milliseconds.map { value -> Int64 in
          let result = CloudSyncBytes.now().addingReportingOverflow(max(0, value))
          return result.overflow ? Int64.max : result.partialValue
        }
        try await budget.failed(failure, httpStatus: http.statusCode, retryAfter: delay)
        throw RecordedFailure(failure)
      }
      // 13 Nov: an accepted pack ends the failure streak, so a long first upload that meets the service's
      // per-minute window every minute keeps short waits instead of a back-off that only grows.
      if packScoped { try? await budget.succeeded() }
      return data
    } catch let recorded as RecordedFailure { throw recorded.error }
    catch let skew as ClockSkew { throw skew }
    catch where Self.isCancellation(error) { throw CancellationError() }
    catch {
      if !(error is CloudFailure) { CloudSyncDiagnostics.shared.noteNetwork(method: request.httpMethod ?? "GET", url: request.url, error: error) }
      try await budget.failed(error); throw (error as? CloudFailure ?? .unavailable)
    }
  }
  /// 13 Nov (the owner's sign-in, third failure): a request THIS Mac cancelled (its task was cancelled, e.g. the Cloud
  /// page re-reading saved passwords while a read was in flight) is not a failure of the service or the network. It
  /// was counted as one, set a back-off of a second or more, and the sign-in's first /state was then refused locally
  /// (`budgetPaused`) and the whole sign-in rolled back. A cancellation is never counted.
  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let url = error as? URLError, url.code == .cancelled { return true }
    return (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
  }
  static let protectedOnlyCodes: Set<String> = ["secrets_locked", "rotation_required"]
  /// The passkey spare routes, whose own checks (the passkey, the spare's signature) can refuse after the device proof.
  static func isSparePasskeyRoute(_ url: URL?) -> Bool {
    guard let path = url?.path else { return false }
    return path.hasSuffix("/v1/secrets/spare/add") || path.hasSuffix("/v1/secrets/spare/open")
  }
  /// The same test as the route-only branch in `perform`: a refusal that concerns that one route.
  static func routeOnly(_ error: CloudErrorDetail?, status: Int) -> Bool {
    guard let error, ![401, 429].contains(status) else { return false }
    return protectedOnlyCodes.contains(error.code) || (!error.retryable && !accountCodes.contains(error.code)) || error.code == notFoundCode
  }
  private struct RecordedFailure: Error { let error: CloudFailure; init(_ error: CloudFailure) { self.error = error } }
  public func currentDeviceId() async throws -> String {
    let credentials = try await auth.credentials()
    guard credentials.user.id == store.subject.sub else { throw CloudFailure.unsafeConfiguration }
    return try await auth.deviceRegistration().deviceId
  }
  public func capabilities() async throws -> CloudGate {
    guard !stopped, let url = URL(string: endpoint.base.absoluteString + "/capabilities") else { throw CloudFailure.unavailable }
    try await budget.reserve(http: 1)
    var request = URLRequest(url: url)
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-TD-Request")
    // Capability discovery precedes device provisioning and has no DeviceAuth requirement.
    if let credentials = try? await auth.credentials() {
      guard credentials.user.id == store.subject.sub else { throw CloudFailure.unsafeConfiguration }
      request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
    }
    let data = try await perform(request)
    do { return try CloudWire.decode(CloudGate.self, from: data) }
    catch { try await budget.failed(error); throw (error as? CloudFailure ?? .unavailable) }
  }
  public func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt {
    let receipt: CloudDeviceRegistrationReceipt = try await call("POST", "/devices", request, account: true)
    // The service just answered this Mac's fresh registration: a back-off left by an earlier attempt or a parallel
    // request of the same sign-in no longer stands between the sign-in and its first status read.
    try? await budget.resume(networkOrWake: true)
    return receipt
  }
  /// Internal account/content plumbing only. Never register this key-bearing result as an MCP tool.
  public func brainKey(epoch: Int? = nil) async throws -> (epoch: Int, key: Data) {
    struct Request: Encodable { let epoch: Int? }
    struct Response: Decodable { let epoch: Int; let key: String }
    guard epoch.map({ $0 > 0 }) ?? true else { throw CloudFailure.invalidRequest }
    let response: Response = try await call("POST", "/brain-key", Request(epoch: epoch), id: UUID().uuidString.lowercased())
    let key = try CloudSyncBytes.unbase64(response.key)
    guard response.epoch > 0, epoch.map({ $0 == response.epoch }) ?? true, key.count == 32 else { throw CloudFailure.checksumMismatch }
    return (response.epoch, key)
  }
  public func devices() async throws -> CloudDeviceList { try await call("GET", "/devices", Empty(), account: true) }
  /// Sign-out (two-Mac proof, 13 Nov): `POST /devices/remove` for THIS device only, so the account no longer lists
  /// it and the next sign-in is one fresh entry. The service refuses (rotation_required) a device that holds the
  /// saved-passwords key; the caller then signs out locally all the same. Proof 2 (13 Nov): the service now takes a
  /// device's removal of ITSELF without the version (its envelope retired); the version is sent when known.
  public func removeOwnDevice(expectedVaultVersion: CloudSequence?) async throws {
    struct Request: Encodable { let deviceId: String; let expectedVaultVersion: CloudSequence? }
    struct Response: Decodable { let deviceId: String; let status: String }
    let deviceId = try await auth.deviceRegistration().deviceId
    let answer: Response = try await call("POST", "/devices/remove", Request(deviceId: deviceId, expectedVaultVersion: expectedVaultVersion),
                                          id: UUID().uuidString.lowercased())
    guard answer.deviceId == deviceId, answer.status == CloudDeviceStatus.revoked.rawValue else { throw CloudFailure.invalidRequest }
  }
  /// Settings → Devices "Sign out this device" (14 Nov): `POST /devices/remove` for ANOTHER device of the account. The
  /// service revokes it and deletes its sign-in session; it refuses (`rotation_required`) a device that holds the
  /// saved-passwords key and (`version_changed`) a stale vault version, and changes nothing then. Never this Mac's
  /// own id (that is `removeOwnDevice`, the person's own sign-out). Its refusals answer this request only.
  /// `browsersEnded` of the last `POST /devices/remove` answer (0 when absent).
  public private(set) var lastRemovalBrowsersEnded = 0
  public func removeDevice(deviceId: String, expectedVaultVersion: CloudSequence) async throws {
    struct Request: Encodable { let deviceId: String; let expectedVaultVersion: CloudSequence }
    struct Response: Decodable { let deviceId: String; let status: String; let browsersEnded: Int? }
    lastRemovalBrowsersEnded = 0
    let mine = try await auth.deviceRegistration().deviceId
    guard !deviceId.isEmpty, deviceId != mine else { throw CloudFailure.invalidRequest }
    guard !stopped else { throw CloudFailure.unavailable }
    let bytes = try CloudSyncCanonical.encode(Request(deviceId: deviceId, expectedVaultVersion: expectedVaultVersion))
    let requestId = UUID().uuidString.lowercased()
    try CloudSyncBytes.transportID(requestId)
    let data = try await send("POST", "/devices/remove", bytes: bytes, requestId: requestId, deviceId: mine, packScoped: false,
                              account: true, ownRefusals: true)
    let answer = try CloudWire.decode(Response.self, from: data)
    guard answer.deviceId == deviceId, answer.status == CloudDeviceStatus.revoked.rawValue else { throw CloudFailure.invalidRequest }
    // Lost-device service as built: how many of his browser sign-ins this sign-out also ended (display only).
    lastRemovalBrowsersEnded = max(0, min(answer.browsersEnded ?? 0, 1_000))
  }
  /// Settings → a device's page, "Name" (owner, 15 Nov): `POST /v1/devices/rename` with `{"device_id", "name"}` for
  /// ANY device of the account, under the same sign-in headers as the device sign-out; the service answers
  /// `{"ok": true}`. Any other answer throws (the page then shows the old name again and "Could not rename").
  public func renameDevice(deviceId: String, name: String) async throws {
    guard !stopped else { throw CloudFailure.unavailable }
    let bytes = try CloudDeviceRename.body(deviceId: deviceId, name: name)
    let mine = try await auth.deviceRegistration().deviceId
    let requestId = UUID().uuidString.lowercased()
    try CloudSyncBytes.transportID(requestId)
    let data = try await send("POST", CloudDeviceRename.path, bytes: bytes, requestId: requestId, deviceId: mine, packScoped: false,
                              account: true, ownRefusals: true)
    guard CloudDeviceRename.accepted(data) else { throw CloudFailure.invalidRequest }
  }
  /// MAC-NEXT-10 (one row per machine): `POST /devices/rename` for THIS device only, carrying its machine id and
  /// friendly name next to its unchanged label. Answers the friendly name (or machine id) the service echoes; nil
  /// when it echoes neither (an older service that ignores the fields).
  public func describeOwnDevice(label: String, machineId: String, displayName: String, hostName: String?) async throws -> String? {
    struct Request: Encodable { let deviceId: String; let label: String; let machineId: String; let displayName: String; let hostName: String? }
    struct Response: Decodable { let deviceId: String; let displayName: String?; let machineId: String? }
    let deviceId = try await auth.deviceRegistration().deviceId
    let answer: Response = try await call("POST", "/devices/rename", Request(deviceId: deviceId, label: label, machineId: machineId, displayName: displayName, hostName: hostName),
                                          id: UUID().uuidString.lowercased(), account: true)
    guard answer.deviceId == deviceId else { throw CloudFailure.invalidRequest }
    return answer.displayName ?? (answer.machineId == machineId ? displayName : nil)
  }
  public func state() async throws -> CloudRemoteState {
    let state: CloudRemoteState = try await call("GET", "/state", Empty(), account: true)
    try await budget.observe(state.budget)
    return state
  }
  public func commit(_ segment: CloudSegment) async throws -> CloudReceipt {
    let bytes = try CloudSyncBytes.unbase64(segment.ciphertext)
    guard bytes.count <= 262_144, segment.descriptor.opCount <= 256, segment.descriptor.opCount > 0,
      Int64(bytes.count) == segment.descriptor.bytes, CloudSyncBytes.hash(bytes) == segment.descriptor.sha256 else { throw CloudFailure.invalidRequest }
    return try await call("POST", "/changes", segment, id: segment.descriptor.requestId, packScoped: true)
  }
  public func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage {
    guard (1...128).contains(limit) else { throw CloudFailure.invalidRequest }
    return try await call("GET", "/changes?after=\(after.rawValue)&limit=\(limit)", Empty())
  }
  public func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket] {
    guard (1...16).contains(items.count) else { throw CloudFailure.invalidRequest }
    let renew = try items.contains { try store.value("refresh-upload:" + $0.uploadId) ?? false }
    var result: Items<CloudBlobTicket> = try await call("POST", "/blobs/prepare", Items(items: items), fresh: renew)
    if result.items.contains(where: { !$0.alreadyPresent && $0.expiresAt <= CloudSyncBytes.now() }) {
      result = try await call("POST", "/blobs/prepare", Items(items: items), fresh: true)
    }
    guard result.items.allSatisfy({ $0.alreadyPresent || $0.expiresAt > CloudSyncBytes.now() }), result.items.count == items.count else { throw CloudFailure.invalidRequest }
    for item in items {
      try store.set("refresh-upload:" + item.uploadId, false)
      try store.set("prepared-upload:" + item.uploadId, item)
    }
    return result.items
  }
  public func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult] {
    guard (1...16).contains(items.count) else { throw CloudFailure.invalidRequest }
    let result: Items<CloudBlobResult> = try await call("POST", "/blobs/finalize", Items(items: items))
    guard result.items.count == items.count, result.items.allSatisfy({ ($0.blob == nil) != ($0.error == nil) }) else { throw CloudFailure.invalidRequest }
    return result.items
  }
  public func readBlobs(ids: [String]) async throws -> [CloudBlobDownload] {
    guard (1...16).contains(ids.count) else { throw CloudFailure.invalidRequest }
    let result: Items<CloudBlobDownload> = try await call("POST", "/blobs/read", BlobIDs(blobIds: ids), id: UUID().uuidString.lowercased())
    guard result.items.count == ids.count, Set(result.items.map { $0.blob.blobId }) == Set(ids) else { throw CloudFailure.invalidRequest }
    return result.items
  }
  public func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt { try await call("POST", "/checkpoints", request) }
  public func checkpoint() async throws -> CloudCheckpoint? {
    let response: Checkpoint = try await call("GET", "/checkpoints/current", Empty())
    return response.checkpoint
  }
  public func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String] {
    let result: Verified = try await call("POST", "/checkpoints/verify", Verify(checkpointId: id, inventoryDigest: inventoryDigest, counts: counts))
    guard result.checkpointId == id else { throw CloudFailure.checksumMismatch }
    return result.verifiedBy
  }
  public func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt {
    let result: CloudAppliedReceipt = try await call("POST", "/applied", Applied(brainSeq: brainSeq, secretsSeq: secretsSeq, checkpointId: checkpointId))
    guard result.brainSeq >= brainSeq, result.secretsSeq >= secretsSeq else { throw CloudFailure.checksumMismatch }
    return result
  }
  public func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease { try await call("POST", "/leases/take", request) }
  public func releaseLease(resourceId: String, generation: CloudSequence) async throws {
    let result: Released = try await call("POST", "/leases/release", Release(resourceId: resourceId, generation: generation))
    guard result.released else { throw CloudFailure.unavailable }
  }
  // Transfer proofs are single-use. Build a new proof for every attempt, never persist its headers.
  func transferRequest(method: String, url: URL, bytes: Data) async throws -> URLRequest {
    try endpoint.permitObject(url)
    guard !stopped else { throw CloudFailure.unavailable }
    let credentials = try await auth.credentials()
    let registration = try await auth.deviceRegistration()
    guard credentials.user.id == store.subject.sub else { throw CloudFailure.unsafeConfiguration }
    let time = signingTime(), id = UUID().uuidString.lowercased()
    guard credentials.expiresAt > time else { throw CloudFailure.unavailable }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CloudFailure.invalidRequest }
    let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    let proof = try await auth.signRequest(method: method, pathAndQuery: path, body: bytes, timestamp: time, requestId: id)
    guard proof.deviceId == registration.deviceId, proof.time == time, proof.requestId == id else { throw CloudFailure.invalidRequest }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = min(60, max(1, Double(credentials.expiresAt - time) / 1000))
    request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    for (name, value) in proof.headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue(CloudSyncBytes.hash(bytes), forHTTPHeaderField: "X-TD-Content-SHA256")
    return request
  }
  public func upload(_ bytes: Data, ticket: CloudBlobTicket) async throws {
    guard !stopped, transfers < 2, bytes.count <= CloudWire.maximumBlobBytes, let url = ticket.putUrl else { throw CloudFailure.unavailable }
    if ticket.expiresAt <= CloudSyncBytes.now() {
      try store.set("refresh-upload:" + ticket.uploadId, true)
      throw CloudSyncTransferFailure.uploadExpired
    }
    try endpoint.permitObject(url)
    guard let prepared: CloudBlobUpload = try store.value("prepared-upload:" + ticket.uploadId), prepared.blobId == ticket.blobId,
      prepared.bytes == bytes.count, prepared.sha256 == CloudSyncBytes.hash(bytes), prepared.md5 == CloudSyncBytes.md5(bytes) else { throw CloudFailure.checksumMismatch }
    transfers += 1
    defer { transfers -= 1 }
    if url.path.hasPrefix("/v1/") { try await sendPacer.take() }
    try await budget.reserve(http: 1)
    var request = try await transferRequest(method: "PUT", url: url, bytes: bytes)
    request.timeoutInterval = min(request.timeoutInterval, max(1, Double(ticket.expiresAt - CloudSyncBytes.now()) / 1000))
    for (name, value) in ticket.headers {
      guard ["content-type", "content-md5"].contains(name.lowercased()) else { throw CloudFailure.unsafeConfiguration }
      request.setValue(value, forHTTPHeaderField: name)
    }
    guard request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream",
      request.value(forHTTPHeaderField: "Content-MD5") == CloudSyncBytes.md5(bytes) else { throw CloudFailure.checksumMismatch }
    request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
    do {
      guard !stopped else { throw CloudFailure.unavailable }
      let (answer, response) = try await session.upload(for: request, from: bytes)
      guard !stopped, let http = response as? HTTPURLResponse else { throw CloudFailure.unavailable }
      if (200..<300).contains(http.statusCode) { try? await budget.served() }
      guard (200..<300).contains(http.statusCode) else {
        if let code = (try? CloudWire.decode(FailureBody.self, from: answer))?.error.code, Self.protectedOnlyCodes.contains(code) {
          throw RecordedFailure(.secretsLocked)
        }
        CloudSyncDiagnostics.shared.noteRefusal(method: "PUT", url: request.url, status: http.statusCode, code: nil)
        await slowDown(http.statusCode)
        if http.statusCode == 404 {
          try store.set("refresh-upload:" + ticket.uploadId, true)
          throw CloudSyncTransferFailure.uploadExpired
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int64.init).flatMap { seconds -> Int64? in
          let ms = seconds.multipliedReportingOverflow(by: 1000)
          return ms.overflow ? nil : CloudSyncBytes.now().addingReportingOverflow(max(0, ms.partialValue)).partialValue
        }
        try await budget.failed(CloudFailure.unavailable, httpStatus: http.statusCode, retryAfter: retryAfter)
        throw RecordedFailure(.unavailable)
      }
    } catch let expired as CloudSyncTransferFailure { throw expired }
    catch let recorded as RecordedFailure { throw recorded.error }
    catch { try await budget.failed(error); throw (error as? CloudFailure ?? .unavailable) }
  }
  public func download(_ url: URL, maximumBytes: Int) async throws -> Data {
    guard !stopped, transfers < 2, maximumBytes > 0, maximumBytes <= CloudWire.maximumBlobBytes else { throw CloudFailure.unavailable }
    try endpoint.permitObject(url)
    transfers += 1
    defer { transfers -= 1 }
    if url.path.hasPrefix("/v1/") { try await bulkPacer.take() }
    try await budget.reserve(http: 1)
    do {
      guard !stopped else { throw CloudFailure.unavailable }
      let request = try await transferRequest(method: "GET", url: url, bytes: Data())
      let (stream, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw CloudFailure.unavailable }
      guard http.statusCode == 200 else {
        CloudSyncDiagnostics.shared.noteRefusal(method: "GET", url: request.url, status: http.statusCode, code: nil)
        await slowDown(http.statusCode)
        if http.statusCode == 404 { throw CloudSyncTransferFailure.readExpired }
        // X5: a "slow down" waits exactly what the service asks (Retry-After, seconds), not a guessed back-off.
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int64.init).flatMap { seconds -> Int64? in
          let ms = seconds.multipliedReportingOverflow(by: 1000)
          return ms.overflow ? nil : CloudSyncBytes.now().addingReportingOverflow(max(0, ms.partialValue)).partialValue
        }
        try await budget.failed(CloudFailure.unavailable, httpStatus: http.statusCode, retryAfter: retryAfter)
        throw RecordedFailure(.unavailable)
      }
      guard response.expectedContentLength <= maximumBytes else { throw CloudFailure.checksumMismatch }
      var data = Data()
      for try await byte in stream {
        guard !stopped, data.count < maximumBytes else { throw CloudFailure.checksumMismatch }
        data.append(byte)
      }
      return data
    } catch let expired as CloudSyncTransferFailure { throw expired }
    catch let recorded as RecordedFailure { throw recorded.error }
    catch { try await budget.failed(error); throw (error as? CloudFailure ?? .unavailable) }
  }
  /// Step 2: who is told when the socket says sessions are being moved (`{moves:[ref]}`); the sessions driver.
  private var sessionsHandler: (@Sendable ([String]) -> Void)?
  public func onSessionsMoved(_ handler: (@Sendable ([String]) -> Void)?) { sessionsHandler = handler }
  public func events() async -> AsyncThrowingStream<CloudEvent, Error> {
    closeSocket()
    let generation = UUID()
    eventGeneration = generation
    watchNetwork()
    return AsyncThrowingStream { continuation in
      self.eventTask = Task { await self.listen(continuation, generation: generation) }
      continuation.onTermination = { @Sendable _ in Task { await self.closeSocket(generation: generation) } }
    }
  }
  private func closeSocket(generation: UUID? = nil) {
    if let generation, generation != eventGeneration { return }
    eventGeneration = nil
    // The network monitor outlives the event stream (round 5 S4): it is cancelled only by stop().
    backoffSleep?.cancel()
    socket?.cancel()
    socket = nil
    eventTask?.cancel()
    eventTask = nil
  }
  public func stop() async {
    stopped = true
    pathMonitor?.cancel()
    pathMonitor = nil
    wakeHandler = nil
    closeSocket()
    session.invalidateAndCancel()
  }
  /// Doubling from the base, capped at 60 seconds (§4.5), with up to half a base of jitter. Beyond the cap the
  /// socket waits for a network or wake event (`networkOrWake()`), which ends the wait at once.
  func socketBackoff(_ streak: Int) -> Int64 {
    let parts = socketRetryBase.components
    let base = max(1, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    let doubled = base << Int64(min(max(streak - 1, 0), 20))
    return min(60_000, doubled) + Int64.random(in: 0...max(0, base / 2))
  }
  private var backoffSleep: Task<Void, Error>?
  private var pathMonitor: NWPathMonitor?
  /// The network came back or the Mac woke: clear the socket's reconnect streak, end any back-off wait now,
  /// and let transient HTTP failures resume. A's wake/sleep wiring may call this too.
  public func networkOrWake() async {
    try? store.execute("DELETE FROM metadata WHERE key=?", [Data("socketStreak".utf8)])
    backoffSleep?.cancel()
    try? await budget.resume(networkOrWake: true)
    // If the event stream already ended (e.g. after the five-failure pause), the owner restarts it.
    if let wakeHandler { await wakeHandler() }
  }
  private var wakeHandler: (@Sendable () async -> Void)?
  public func onWake(_ handler: @escaping @Sendable () async -> Void) { wakeHandler = handler }
  /// Production only: a path change to "satisfied" is the network-returned signal.
  private func watchNetwork() {
    guard socketFactory == nil, pathMonitor == nil else { return }
    final class LastStatus: @unchecked Sendable { var satisfied = true }
    let last = LastStatus(), monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      defer { last.satisfied = satisfied }
      guard satisfied, !last.satisfied, let self else { return }
      Task { await self.networkOrWake() }
    }
    monitor.start(queue: DispatchQueue(label: "cloud-sync-network"))
    pathMonitor = monitor
  }
  private func listen(_ continuation: AsyncThrowingStream<CloudEvent, Error>.Continuation, generation: UUID) async {
    while !stopped && !Task.isCancelled && eventGeneration == generation {
      var connectedAt: Int64 = 0
      do {
        var request = try await request(method: "GET", path: "/events", body: Data(), requestId: UUID().uuidString.lowercased())
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        request.url = url.url
        try await budget.reserve(http: 1)
        guard !stopped, !Task.isCancelled else { throw CloudFailure.unavailable }
        let task: any CloudSyncSocketConnection = socketFactory?(request) ?? CloudSyncNativeSocket(session: session, request: request)
        socket = task
        task.start()
        var heartbeat: Task<Void, Never>?
        var refresh: Task<Void, Never>?
        defer { heartbeat?.cancel(); refresh?.cancel(); task.cancel() }
        while !stopped && !Task.isCancelled {
          let data = try await task.receive()
          guard let event = try CloudSyncSocketFrames.event(data) else { continue }
          try await budget.reserve(frames: 1)
          if event.type == "gate" { continuation.yield(event); throw CloudFailure.gateClosed }
          if event.type == "error" {
            let detail = try CloudWire.decode(CloudErrorDetail.self, from: CloudSyncCanonical.encode(event.payload))
            throw CloudFailure.remote(detail)
          }
          if event.type == "hello" {
            // Stability is measured from the service's hello, not from a connect attempt that may hang.
            if connectedAt == 0 { connectedAt = CloudSyncBytes.now() }
            let hello = try CloudSyncSocketFrames.hello(event)
            try await budget.observe(hello.budget)
            if heartbeat == nil {
              heartbeat = Task {
                do {
                  while !Task.isCancelled {
                    try await Task.sleep(for: heartbeatInterval)
                    try Task.checkCancellation()
                    // Heartbeats are not paced like other messages.
                    try await task.send("td-ping")
                  }
                } catch { task.cancel() }
              }
            }
            refresh?.cancel()
            refresh = Task {
              do {
                try await Task.sleep(for: .milliseconds(max(1, hello.authExpiresAt - 60_000 - CloudSyncBytes.now())))
                try Task.checkCancellation()
                // Credentials use A's one shared refresh manager. A fresh signed upgrade avoids a second auth format.
                _ = try await self.auth.credentials()
                try Task.checkCancellation()
                guard self.eventGeneration == generation else { return }
                self.refreshingSocket = true
                task.cancel()
              } catch { task.cancel() }
            }
          }
          // Step 2 ("Switch to this Mac"): a session of the account is being moved; only a hint to look (`look`).
          if event.type == "sessions", let handler = sessionsHandler {
            struct Moves: Decodable { let moves: [String]? }
            if let moves = try? JSONDecoder().decode(Moves.self, from: CloudSyncCanonical.encode(event.payload)) { handler(moves.moves ?? []) }
          }
          // hello/changed are hints only. The engine always catches up from sync.sqlite.
          continuation.yield(event)
        }
      } catch {
        if error as? CloudFailure == .gateClosed || error as? CloudFailure == .deviceRevoked {
          await stop()
          continuation.finish(throwing: CloudFailure.gateClosed)
          return
        }
        if stopped || Task.isCancelled || eventGeneration != generation { break }
        if refreshingSocket { refreshingSocket = false; continue }
        // The socket keeps its own persisted reconnect streak. A successful HTTP pull resets the shared
        // failure count, so that count cannot pace a socket that says hello and drops again.
        let stable = connectedAt > 0 && CloudSyncBytes.now() - connectedAt >= 60_000
        // This Mac's own short wait (`budgetPaused`) is not a socket failure and does not lengthen the streak.
        let budgetWait = error as? CloudFailure == .budgetPaused
        let previous = (try? store.value("socketStreak") as Int?) ?? 0
        let streak = stable ? 1 : (budgetWait ? max(previous, 1) : previous + 1)
        try? store.set("socketStreak", min(streak, 1000))
        // Only the service's own stated refusals (auth, budget) feed the shared state; a dropped socket does not.
        if case CloudFailure.remote(_) = error { try? await budget.failed(error) }
        // A "slow down" is a short wait (it ends by itself at retryAt), not a reason to end the stream.
        guard let status = try? await budget.status(), status.blocked == nil || status.blocked == "rate" else { continuation.finish(throwing: CloudFailure.unavailable); return }
        let delay = max(socketBackoff(streak), status.retryAt - CloudSyncBytes.now())
        let sleeper = Task { try await Task.sleep(for: .milliseconds(delay)) }
        backoffSleep = sleeper
        _ = try? await sleeper.value
        backoffSleep = nil
        if stopped || Task.isCancelled || eventGeneration != generation { break }
      }
    }
    continuation.finish()
  }
}

/// The rename call's shape, in one place (the service lane writes its side to the same contract).
public enum CloudDeviceRename {
  public static let path = "/devices/rename"
  public static let maxName = 64
  struct Request: Encodable {
    let deviceId: String
    let name: String
    enum CodingKeys: String, CodingKey { case deviceId = "device_id", name }
  }
  struct Answer: Decodable { let ok: Bool }
  /// The trimmed name, or nil when there is nothing to send.
  public static func cleaned(_ name: String) -> String? {
    let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : String(text.prefix(maxName))
  }
  public static func body(deviceId: String, name: String) throws -> Data {
    guard !deviceId.isEmpty, let name = cleaned(name) else { throw CloudFailure.invalidRequest }
    return try CloudSyncCanonical.encode(Request(deviceId: deviceId, name: name))
  }
  /// Only `{"ok": true}` is a rename.
  public static func accepted(_ data: Data) -> Bool {
    (try? JSONDecoder().decode(Answer.self, from: data))?.ok == true
  }
}
