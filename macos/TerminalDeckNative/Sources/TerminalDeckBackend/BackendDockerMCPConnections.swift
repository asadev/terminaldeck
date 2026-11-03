import Foundation
import TerminalDeckNativeCore

/// Cached clients, not connections. All byte channels still open on demand
/// through the existing pool or a discovered provider's local unix socket.
public actor BackendDockerMCPConnections {
    private let servers: BackendServersFeature
    private let home: URL
    private var clients: [String: BackendDockerClient] = [:]
    private var localPath: String?
    private var platforms: [String: String] = [:]
    public init(servers: BackendServersFeature, home: URL) { self.servers = servers; self.home = home }

    public func client(_ target: String) async throws -> BackendDockerClient {
        if target == "local" {
            guard let path = BackendDockerLocalDiscovery.discover(home: home)?.socketPath else {
                clients["local"] = nil; localPath = nil
                throw NativeRPCError(code: "docker-not-found", message: "No local Docker provider socket was found.")
            }
            if localPath != path { clients["local"] = nil; localPath = path }
            if let client = clients[target] { return client }
            let client = BackendDockerClient(transport: BackendDockerLocalTransport(socketPath: path))
            clients[target] = client; return client
        }
        guard try await servers.room.knows(target) else {
            clients[target] = nil
            throw NativeRPCError(code: "access-denied", message: "That server is not saved in this app.")
        }
        if let client = clients[target] { return client }
        let pool = servers.connections
        let client = BackendDockerClient(transport: BackendDockerSSHTransport(openDialStdio: { command in
            guard command == BackendDockerSSHTransport.command else {
                throw NativeRPCError(code: "access-denied", message: "This connection only opens Docker's fixed byte transport.")
            }
            return try await pool.dockerDialStdio(target)
        }))
        clients[target] = client; return client
    }

    /// APE's private Engine HTTP seam retains non-success status codes so its
    /// transaction owner can distinguish missing resources from failed writes.
    public func appsHTTP(_ server: String, method: String, path: String, body: Data?) async throws -> BackendAppsHTTPResponse {
        guard server != "local" else { throw NativeRPCError(code: "access-denied", message: "Apps require a saved server connection.") }
        let client = try await self.client(server)
        return try await Self.appsHTTP(client: client, method: method, path: path, body: body)
    }
    /// Same checked request conversion for an issuer's pinned private client.
    public nonisolated static func appsHTTP(client: BackendDockerClient, method: String, path: String, body: Data?) async throws -> BackendAppsHTTPResponse {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in String(parts[1]).split(separator: "&") {
                let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(fields[0]).removingPercentEncoding, !key.isEmpty,
                      query[key] == nil, let value = (fields.count == 2 ? String(fields[1]) : "").removingPercentEncoding else {
                    throw NativeRPCError.invalidArguments("The app's private Engine request is invalid.")
                }
                query[key] = value
            }
        }
        let value = try body.map { try NativeRPCValue.parseJSON($0) }
        let request = try await client.requestDescriptor(method, path: String(parts[0]), query: query, body: value)
        let reply = try await client.transport.request(request)
        return .init(status: reply.status, body: reply.body)
    }
    public func platform(_ target: String) -> String? { platforms[target] }
    /// Called only after the actual caller's read access has been checked.
    /// This probes the one requested target, never all saved machines.
    public func prepareInstaller(_ target: String) async throws {
        guard target != "local", try await servers.room.knows(target) else {
            throw NativeRPCError(code: "unavailable", message: "Choose a saved Linux server for Docker installation.")
        }
        let facts = try await servers.room.measured(target)
        guard facts.kernel.value?.lowercased().hasPrefix("linux") == true else {
            throw NativeRPCError(code: "unavailable", message: "Docker's installer requires a Linux server.")
        }
        guard facts.privilege.value == .yes || facts.privilege.value == .sudoNoPassword else {
            throw NativeRPCError(code: "unavailable", message: "Installing Docker needs administrator access on this server.")
        }
        platforms[target] = "linux"
    }
    public func clear() { clients.removeAll(); platforms.removeAll(); localPath = nil }

    public func logs(_ server: String, container: String,
                     receive: @escaping @Sendable (BackendAppsLogEvent) async -> Void) async throws -> NativeRPCSubscription {
        let client = try await self.client(server)
        let config = try await client.containerStreamConfiguration(id: container)
        let request = try await client.requestDescriptor("GET", path: "/containers/\(try BackendDockerClient.pathComponent(container))/logs",
            query: ["follow": "true", "stdout": "true", "stderr": "true", "tail": "200", "timestamps": "true"])
        let response = try await client.transport.stream(request)
        let records = try BackendDockerStreams.logs(response: response, tty: config.tty, secretValues: config.secretValues)
        let task = Task {
            do {
                for try await record in records.records {
                    try Task.checkCancellation()
                    if let text = record["text"].string { await receive(.text(text)) }
                }
                if !Task.isCancelled { await receive(.ended(failed: false)) }
            } catch {
                if !Task.isCancelled { await receive(.ended(failed: true)) }
            }
            records.cancel()
        }
        // Closing is synchronous. A receive(.ended) callback may itself close
        // this subscription, so awaiting this delivery task would self-deadlock.
        return NativeRPCSubscription { records.cancel(); task.cancel() }
    }
}
