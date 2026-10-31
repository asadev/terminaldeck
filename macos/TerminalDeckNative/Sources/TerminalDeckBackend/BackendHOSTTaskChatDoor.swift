import Foundation
import TerminalDeckNativeCore

/// A task's catalogue stays the same; its token, configuration and registration belong to the helper.
public actor BackendHOSTTaskChatDoor: BackendCopilotSessionToolProviding {
    private let source: any BackendCopilotSessionToolProviding
    private let leases: BackendHOSTToolLeaseProxy
    private let taskID: String
    public init(source: any BackendCopilotSessionToolProviding, client: BackendHOSTClient, taskID: String) async throws {
        self.source = source; self.taskID = taskID
        leases = try await BackendHOSTToolLeaseProxy(client: client)
    }
    public func catalogue() async throws -> [BackendCopilotLayerTool]? { try await source.catalogue() }
    public func prepare() async throws -> BackendCopilotSessionTools? {
        guard let tools = try await catalogue() else { return nil }
        guard let hosted = try await leases.prepareOrdinary(restricting: tools.map(\.wire), deniedTools: [], taskID: taskID, taskProject: nil),
              hosted.arguments.count == 2, hosted.arguments[0] == "--mcp-config" else {
            throw BackendSessionFailure.missingCapability("the task's helper-owned tool lease")
        }
        return .init(configPath: hosted.arguments[1], tools: tools, leaseID: hosted.id)
    }
    public func bind(_ tools: BackendCopilotSessionTools, sessionID: String) async throws {
        try await leases.bind(tools.leaseID, sessionID: sessionID, machineID: "")
    }
    public func abandon(_ tools: BackendCopilotSessionTools) async { await leases.abandon(tools.leaseID) }
    public func release(sessionID: String) async { await leases.release(sessionID: sessionID) }
}
