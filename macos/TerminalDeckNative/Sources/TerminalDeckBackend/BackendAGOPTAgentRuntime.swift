import Foundation
import TerminalDeckNativeCore

/// Supplied by the retained app owners. Login account ids and session titles
/// never establish standalone task-agent ownership.
public struct BackendAGOPTAgentRuntimeAccess: Sendable {
    public let standaloneSessions: (@Sendable (String) async throws -> [BackendSessionMeta])?
    public let stopStandalone: (@Sendable (String, String) async throws -> Void)?
    public let resetSession: (@Sendable (String, String) async throws -> Bool)?
    public let billing: (@Sendable (String, String?) async throws -> NativeRPCValue)?
    public let standingCheck: (@Sendable (String) async throws -> NativeRPCValue)?
    public init(standaloneSessions: (@Sendable (String) async throws -> [BackendSessionMeta])? = nil,
                stopStandalone: (@Sendable (String, String) async throws -> Void)? = nil,
                resetSession: (@Sendable (String, String) async throws -> Bool)? = nil,
                billing: (@Sendable (String, String?) async throws -> NativeRPCValue)? = nil,
                standingCheck: (@Sendable (String) async throws -> NativeRPCValue)? = nil) {
        self.standaloneSessions = standaloneSessions; self.stopStandalone = stopStandalone; self.resetSession = resetSession
        self.billing = billing; self.standingCheck = standingCheck
    }
}
