import Foundation

/// Stable plug-in contract shared with the deck-tools migration lane.
/// The same handlers must also be supplied to the central consent/logging gate;
/// direct registration is for trusted session endpoints that already gate calls.
public struct BackendDeckCoreToolArea: Sendable {
    public let id: String
    public let tools: [BackendMCPTool]
    public let describeText: String
    public let handlers: [String: BackendNativeMCPServer.Handler]

    public init(id: String, tools: [BackendMCPTool], describeText: String,
                handlers: [String: BackendNativeMCPServer.Handler]) throws {
        guard !id.isEmpty, !tools.isEmpty,
              Set(tools.map(\.id)).count == tools.count,
              Set(tools.map(\.wireName)).count == tools.count,
              tools.allSatisfy({ handlers[$0.id] != nil }) else {
            throw BackendSessionFailure.invalidInput("A tool area needs its real id, tools and handlers.")
        }
        var names = Set<String>()
        for tool in tools {
            for name in Set([tool.id, tool.wireName]) {
                guard names.insert(name).inserted else {
                    throw BackendSessionFailure.invalidInput("An MCP tool name is already registered in this area.")
                }
            }
        }
        self.id = id
        self.tools = tools
        self.describeText = describeText
        self.handlers = handlers
    }

    public func register(on server: BackendNativeMCPServer) async throws {
        let contribution = try tools.map { tool -> (BackendMCPTool, BackendNativeMCPServer.Handler) in
            guard let handler = handlers[tool.id] else {
                throw BackendSessionFailure.missingCapability("the \(tool.id) tool handler")
            }
            return (tool, handler)
        }
        try await server.replaceTools(ownerID: "backend.tool-area:" + id,
            tools: RNMHootMCPCompatibility.registrations(contribution))
    }
}
