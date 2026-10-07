import Foundation
import TerminalDeckNativeCore

/// Desk Hoot uses the existing MCP door and private token/registration leases.
/// It does not create a second server or reuse an ordinary session's token.
public actor BackendCopilotSessionMCPDoor: BackendCopilotSessionToolProviding {
    private let endpoint: BackendCopilotSessionSecurityEndpoint
    private let leases: BackendSessionToolLeases
    /// Source catalogue titles are not part of BackendMCPTool. The deck-core
    /// owner supplies the same live title projection it uses for Hoot's layer.
    private let titleCatalogue: @Sendable () async throws -> [BackendCopilotLayerTool]
    private let machineID: String
    public init(endpoint: BackendCopilotSessionSecurityEndpoint, userData: URL,
                machineID: String = "", titles: @escaping @Sendable () async throws -> [BackendCopilotLayerTool]) throws {
        self.endpoint = endpoint; self.leases = try BackendSessionToolLeases(endpoint: endpoint, userData: userData)
        titleCatalogue = titles; self.machineID = machineID
    }
    public func prepare() async throws -> BackendCopilotSessionTools? {
        guard try await endpoint.description() != nil else { return nil }
        let tools = try await endpoint.catalogue().filter(\.advertised)
        let titles = try await titleCatalogue()
        var projection: [BackendCopilotLayerTool] = []
        var names: Set<String> = []
        for spec in tools {
            guard let title = titles.first(where: { $0.wire == spec.wireName && $0.tier == spec.tier.rawValue }) else {
                throw NativeRPCError(code: "unavailable", message: "Hoot's live tool catalogue title is unavailable: \(spec.wireName).")
            }
            projection.append(title); names.insert(spec.id); names.insert(spec.wireName)
        }
        let prepared = try await leases.prepare(serverName: "deck-control", allowed: names, projectRoot: nil)
        guard prepared.arguments.count == 2, prepared.arguments[0] == "--mcp-config" else {
            await leases.abandon(prepared.id)
            throw NativeRPCError(code: "unavailable", message: "Hoot's per-session MCP configuration is unavailable.")
        }
        return .init(configPath: prepared.arguments[1], tools: projection, leaseID: prepared.id)
    }
    public func bind(_ tools: BackendCopilotSessionTools, sessionID: String) async throws {
        try await leases.bind(tools.leaseID, sessionID: sessionID, machineID: machineID)
    }
    public func abandon(_ tools: BackendCopilotSessionTools) async { await leases.abandon(tools.leaseID) }
    public func release(sessionID: String) async { await leases.release(sessionID: sessionID) }
    public func stop() async { await leases.stop() }
}
