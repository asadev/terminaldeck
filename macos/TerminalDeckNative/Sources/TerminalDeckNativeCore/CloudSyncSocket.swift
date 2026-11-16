import Foundation

// The fixture implementation lives only in the test target. Production always constructs URLSession sockets.
protocol CloudSyncSocketConnection: Sendable {
  func start()
  func send(_ text: String) async throws
  func receive() async throws -> Data
  func cancel()
}
typealias CloudSyncSocketFactory = @Sendable (URLRequest) -> any CloudSyncSocketConnection

final class CloudSyncNativeSocket: CloudSyncSocketConnection, @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  init(session: URLSession, request: URLRequest) {
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 409_600
  }
  func start() { task.resume() }
  func send(_ text: String) async throws { try await task.send(.string(text)) }
  func receive() async throws -> Data {
    switch try await task.receive() {
    case .string(let text): return Data(text.utf8)
    case .data(let data): return data
    @unknown default: throw CloudFailure.unsupportedFormat
    }
  }
  func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

enum CloudSyncSocketFrames {
  struct Hello: Decodable { let socketId: String; let headSeq: CloudSequence; let authExpiresAt: Int64; let budget: CloudBudgetState }
  static func event(_ bytes: Data) throws -> CloudEvent? {
    guard bytes.count <= 409_600 else { throw CloudFailure.invalidRequest }
    if bytes == Data("td-pong".utf8) { return nil }
    let event = try CloudWire.decode(CloudEvent.self, from: bytes, allowedKeys: ["v", "type", "id", "payload"])
    guard event.v == 1 else { throw CloudFailure.unsupportedFormat }
    if event.type == "hello" { _ = try hello(event) }
    if event.type == "changed" {
      struct Changed: Decodable { let headSeq: CloudSequence; let classes: [CloudStorageClass] }
      _ = try CloudWire.decode(Changed.self, from: CloudSyncCanonical.encode(event.payload), allowedKeys: ["headSeq", "classes"])
    }
    return event
  }
  static func hello(_ event: CloudEvent) throws -> Hello {
    try CloudWire.decode(Hello.self, from: CloudSyncCanonical.encode(event.payload),
      allowedKeys: ["socketId", "headSeq", "authExpiresAt", "vaultVersion", "capabilityRevision", "budget"])
  }
}
