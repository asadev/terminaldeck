import XCTest
import Foundation
import Network
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// One bounded direct Network.framework probe against DKT's existing private
/// AF_UNIX fake. No process, real socket, raw response or secret diagnostics.
final class BackendDockerMCPUnixDiagnosticTests: XCTestCase {
    func testProductionLocalTransportRequestAndFixtureObservation() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        var limits = BackendDockerTransportLimits()
        limits.maximumReadBytes = 64 // Match the still-failing contract fixture.
        limits.openTimeoutMilliseconds = 1500
        limits.requestTimeoutMilliseconds = 1500
        limits.writeTimeoutMilliseconds = 1000
        let transport = BackendDockerLocalTransport(socketPath: fake.socketPath, limits: limits)
        var status = 0, responseBytes = 0
        var errorCode = "none"
        do {
            let reply = try await transport.request(.init(path: "/version"))
            status = reply.status; responseBytes = reply.body.count
        } catch let failure as NativeRPCError {
            let safeCodes: Set<String> = ["unavailable", "docker-not-found", "docker-permission", "docker-protocol", "docker-stream-overflow", "cancelled", "invalid-arguments", "docker-api-version"]
            errorCode = safeCodes.contains(failure.code) ? failure.code : "unclassified-native-code"
        } catch is CancellationError { errorCode = "cancelled" }
        catch { errorCode = "non-native-error" }
        let requests = fake.requests.count
        let versionHits = fake.requests.filter { $0.method == "GET" && $0.enginePath == "/version" && $0.body.isEmpty }.count
        let exactVersionHits = fake.requests.filter { $0.method == "GET" && $0.target == "/version" }.count
        let activeBeforeStop = fake.activeConnectionCount
        fake.stop()
        let activeAfterStop = fake.activeConnectionCount
        let phase = requests == 0 ? "before-recorded-request" : "request-recorded-response-path"
        let summary = "production local unix: errorCode=\(errorCode); phase=\(phase); status=\(status); responseBytes=\(responseBytes)"
            + "; fixtureRequests=\(requests); methodVersionHits=\(versionHits); exactVersionHits=\(exactVersionHits)"
            + "; peersBeforeStop=\(activeBeforeStop); peersAfterStop=\(activeAfterStop)"
        XCTAssertTrue(errorCode == "none" && status == 200 && responseBytes > 0
            && requests == 1 && versionHits == 1 && exactVersionHits == 1 && activeAfterStop == 0, summary)
    }

    func testRawNetworkUnixStateAndFixtureObservation() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        let connection = NWConnection(to: .unix(path: fake.socketPath), using: .tcp)
        let observation = BackendDockerMCPUnixObservation()
        let outcome = BackendServersSSHOnce<BackendDockerMCPUnixObservation.Snapshot>()
        let cancelled = BackendServersSSHOnce<Bool>()
        let queue = DispatchQueue(label: "terminaldeck.test.docker.unix-diagnostic")
        connection.stateUpdateHandler = { state in
            let kind = BackendDockerMCPUnixObservation.Kind(state)
            observation.record(kind)
            switch state {
            case .ready:
                let request = Data("GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error {
                        outcome.finish(.success(observation.snapshot(phase: "send-failed", error: .init(error))))
                        return
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { bytes, _, complete, error in
                        outcome.finish(.success(observation.snapshot(phase: error == nil ? "received" : "receive-failed",
                            error: error.map(BackendDockerMCPUnixObservation.Failure.init), receivedBytes: bytes?.count ?? 0, eof: complete)))
                    }
                })
            case .failed(let error):
                outcome.finish(.success(observation.snapshot(phase: "state-failed", error: .init(error))))
            case .cancelled:
                cancelled.finish(.success(true))
                outcome.finish(.success(observation.snapshot(phase: "cancelled")))
            default: break
            }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            outcome.finish(.success(observation.snapshot(phase: "deadline")))
            connection.cancel()
        }
        defer { deadline.cancel(); connection.cancel(); fake.stop() }
        connection.start(queue: queue)
        let result = try await withTaskCancellationHandler { try await outcome.value() } onCancel: { connection.cancel() }
        deadline.cancel()
        let requestsBeforeCancel = fake.requests.count
        let activeBeforeCancel = fake.activeConnectionCount
        connection.cancel()
        let closeDeadline = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            cancelled.finish(.success(false))
        }
        defer { closeDeadline.cancel() }
        let cancellationObserved = try await cancelled.value()
        fake.stop()
        let closedPeers = fake.activeConnectionCount
        let versionRequests = fake.requests.filter { $0.method == "GET" && $0.target == "/version" && $0.body.isEmpty }.count
        let summary = "raw NW unix: " + result.safeDescription
            + "; fixtureRequests=\(requestsBeforeCancel); versionRequests=\(versionRequests)"
            + "; peersBeforeCancel=\(activeBeforeCancel); peersAfterStop=\(closedPeers); cancelledObserved=\(cancellationObserved)"
        // A failure exposes only the concrete state family/code and counts.
        // Ready still requires the existing fake to see the request and close.
        XCTAssertTrue(result.phase == "received" && result.receivedBytes > 0 && result.state == .ready
            && versionRequests == 1 && cancellationObserved && closedPeers == 0, summary)
    }
}

private final class BackendDockerMCPUnixObservation: @unchecked Sendable {
    enum Failure: Sendable, Equatable {
        case posix(Int32), dns(Int32), tls(Int32), unknown
        init(_ error: NWError) {
            switch error {
            case .posix(let value): self = .posix(value.rawValue)
            case .dns(let value): self = .dns(value)
            case .tls(let value): self = .tls(value)
            @unknown default: self = .unknown
            }
        }
        var safeDescription: String {
            switch self {
            case .posix(let code): "posix(\(code))"
            case .dns(let code): "dns(\(code))"
            case .tls(let code): "tls(\(code))"
            case .unknown: "unknown-error-family"
            }
        }
    }
    enum Kind: Sendable, Equatable {
        case setup, preparing, ready, waiting(Failure), failed(Failure), cancelled, unknown
        init(_ state: NWConnection.State) {
            switch state {
            case .setup: self = .setup
            case .preparing: self = .preparing
            case .ready: self = .ready
            case .waiting(let error): self = .waiting(.init(error))
            case .failed(let error): self = .failed(.init(error))
            case .cancelled: self = .cancelled
            @unknown default: self = .unknown
            }
        }
        var safeDescription: String {
            switch self {
            case .setup: "setup"
            case .preparing: "preparing"
            case .ready: "ready"
            case .waiting(let error): "waiting(" + error.safeDescription + ")"
            case .failed(let error): "failed(" + error.safeDescription + ")"
            case .cancelled: "cancelled"
            case .unknown: "unknown-state"
            }
        }
    }
    struct Snapshot: Sendable {
        let state: Kind, phase: String, error: Failure?, receivedBytes: Int, eof: Bool, trace: [Kind]
        var safeDescription: String {
            "state=" + state.safeDescription + "; phase=" + phase
                + (error.map { "; error=" + $0.safeDescription } ?? "")
                + "; receivedBytes=\(receivedBytes); eof=\(eof); trace=" + trace.map(\.safeDescription).joined(separator: ",")
        }
    }
    private let lock = NSLock()
    private var current: Kind = .setup
    private var trace: [Kind] = [.setup]
    func record(_ kind: Kind) { lock.withLock { current = kind; if trace.count < 12 { trace.append(kind) } } }
    func snapshot(phase: String, error: Failure? = nil, receivedBytes: Int = 0, eof: Bool = false) -> Snapshot {
        lock.withLock { .init(state: current, phase: phase, error: error, receivedBytes: receivedBytes, eof: eof, trace: trace) }
    }
}
