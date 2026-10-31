import Foundation
@testable import TerminalDeckBackend

/// A test endpoint whose every operation is a supplied closure.
struct BackendTestMCPEndpoint: BackendMCPToolEndpoint, Sendable {
    let readiness: BackendLaunchReadiness
    private let describe: @Sendable () async throws -> BackendMCPEndpointDescription?
    private let tools: @Sendable () async throws -> [BackendMCPTool]
    private let registerCaller: @Sendable (String, BackendMCPCallerGrant) async throws -> BackendMCPRegistration
    private let bindCaller: @Sendable (BackendMCPRegistration, String, String) async throws -> Void
    private let revokeCaller: @Sendable (BackendMCPRegistration) async -> Void
    init(readiness: BackendLaunchReadiness,
                description: @escaping @Sendable () async throws -> BackendMCPEndpointDescription?,
                catalogue: @escaping @Sendable () async throws -> [BackendMCPTool],
                register: @escaping @Sendable (String, BackendMCPCallerGrant) async throws -> BackendMCPRegistration,
                bind: @escaping @Sendable (BackendMCPRegistration, String, String) async throws -> Void,
                revoke: @escaping @Sendable (BackendMCPRegistration) async -> Void) {
        self.readiness = readiness; describe = description; tools = catalogue
        registerCaller = register; bindCaller = bind; revokeCaller = revoke
    }
    func description() async throws -> BackendMCPEndpointDescription? {
        guard readiness == .ready else { throw BackendSessionFailure.missingCapability("the test MCP endpoint") }
        return try await describe()
    }
    func catalogue() async throws -> [BackendMCPTool] { try await tools() }
    func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration { try await registerCaller(token, grant) }
    func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws { try await bindCaller(registration, sessionID, machineID) }
    func revoke(_ registration: BackendMCPRegistration) async { await revokeCaller(registration) }
}
