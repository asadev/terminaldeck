import Foundation
import TerminalDeckNativeCore

/// Private authenticated bootstrap DTO. The environment stays in memory;
/// it is never written into an inventory, UI event or tool projection.
public struct BackendHOSTConfiguration: Codable, Sendable {
    public var home: String
    public var appName: String
    public var appID: String
    public var environment: [String: String]
    public var tools: [Tool]
    public init(configuration: BackendAccountConfiguration, tools: [BackendMCPTool]) throws {
        home = configuration.homeDirectory.path; appName = configuration.appName; appID = configuration.appID
        environment = configuration.inheritedEnvironment
        self.tools = try tools.map(Tool.init)
    }
    public struct Tool: Codable, Sendable {
        public var id: String
        public var wireName: String
        public var description: String
        public var schema: Data
        public var tier: String
        public var advertised: Bool
        public var implementation: String
        public init(_ tool: BackendMCPTool) throws {
            id = tool.id; wireName = tool.wireName; description = tool.description; schema = try tool.inputSchema.encodedJSON()
            tier = tool.tier.rawValue; advertised = tool.advertised; implementation = tool.implementation.rawValue
        }
        public func spec() throws -> BackendMCPTool {
            guard let tier = BackendMCPTier(rawValue: tier), let implementation = BackendMCPImplementation(rawValue: implementation) else {
                throw BackendHOSTFailure.invalid("The app's real tool descriptor has an unsupported tier or implementation.")
            }
            return try .init(id: id, wireName: wireName, description: description,
                inputSchema: NativeRPCValue.parseJSON(schema, maximumBytes: 256 * 1024), tier: tier, advertised: advertised, implementation: implementation)
        }
    }
    public func accountConfiguration(paths: BackendHOSTPaths, hostVersion: String) throws -> BackendAccountConfiguration {
        guard hostVersion.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else { throw BackendHOSTFailure.invalid("Invalid pinned helper version.") }
        let helper = BackendHOSTLaunchAgent.keeperExecutable(in: paths.directory.appendingPathComponent(hostVersion, isDirectory: true))
        return try .init(dataDirectory: paths.dataDirectory, homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            appName: appName, appID: appID, helperExecutable: helper, inheritedEnvironment: environment)
    }
}

public enum BackendHOSTBootstrap {
    public static func configure(client: BackendHOSTClient, configuration: BackendHOSTConfiguration) async throws {
        let arguments = try NativeRPCValue.parseJSON(JSONEncoder().encode(configuration))
        let answer = try await client.resource("resources.configure", arguments: arguments)
        guard answer["configured"].bool == true else { throw BackendHOSTFailure.unavailable }
    }
}
