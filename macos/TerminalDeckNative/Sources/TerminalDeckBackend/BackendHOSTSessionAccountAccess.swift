#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Only the account facts needed by the existing session lifecycle. The
/// frontend never exposes a helper broker, vault, credential or file writer.
public protocol BackendHOSTSessionAccountLifecycle: BackendLaunchCapability {
    func bindProcessIfNeeded(sessionID: String, pid: Int32, createdAt: Double) async throws
    func transcriptConfiguration(sessionID: String) async -> String?
}
public protocol BackendHOSTSessionAccountAttributing: Sendable {
    func read(_ session: BackendSessionMeta, pid: Int32?) async -> BackendAccountSessionReading
    func drop(sessionID: String) async
}
public struct BackendHOSTLocalSessionAccountLifecycle: BackendHOSTSessionAccountLifecycle {
    public var readiness: BackendLaunchReadiness { accounts.readiness }
    private let accounts: BackendAccountLaunchAdapter
    public init(accounts: BackendAccountLaunchAdapter) { self.accounts = accounts }
    public func bindProcessIfNeeded(sessionID: String, pid: Int32, createdAt: Double) async throws {
        let broker = await accounts.broker
        if await broker.seatSnapshot(sessionID: sessionID) != nil { try await broker.bindProcess(sessionID: sessionID, pid: pid) }
    }
    public func transcriptConfiguration(sessionID: String) async -> String? { await accounts.transcriptConfiguration(sessionID: sessionID) }
}
extension BackendAccountAttribution: BackendHOSTSessionAccountAttributing {}

public actor BackendHOSTSessionAccountAccess: BackendHOSTSessionAccountLifecycle, BackendHOSTSessionAccountAttributing {
    public nonisolated let readiness: BackendLaunchReadiness
    private let client: BackendHOSTClient
    private var failures: [String] = []
    public init(client: BackendHOSTClient) async throws {
        let value = try await client.resource("account.status", arguments: .object([]))
        guard value["ready"].bool == true else { throw BackendSessionFailure.missingCapability("the actual managed helper account owner") }
        self.client = client; readiness = .ready
    }
    public func bindProcessIfNeeded(sessionID: String, pid: Int32, createdAt: Double) async throws {
        let value = try await client.resource("account.pid-bound", arguments: .object([
            .init("id", .string(sessionID)), .init("pid", .number(Double(pid))), .init("expectedCreatedAt", .number(createdAt))]))
        guard value.bool == true else { throw BackendSessionFailure.missingCapability("the helper's actual pre-exec account/pid binding") }
    }
    public func transcriptConfiguration(sessionID: String) async -> String? {
        do {
            let value = try await client.resource("account.transcript", arguments: .object([.init("id", .string(sessionID))]))
            if value.isNullish { return nil }
            let path = try value.requireString("established helper transcript configuration")
            guard path.hasPrefix("/"), !path.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid established transcript path.") }
            return path
        } catch { note("The helper's established session transcript attribution could not be read."); return nil }
    }
    public func read(_ session: BackendSessionMeta, pid: Int32?) async -> BackendAccountSessionReading {
        do {
            let value = try await client.resource("account.attribution", arguments: .object([
                .init("id", .string(session.id)), .init("pid", pid.map { .number(Double($0)) } ?? .null),
                .init("expectedCreatedAt", .number(session.createdAt))]))
            if value["kind"].string == "withheld" { return .withheld(try value["reason"].requireString("account attribution reason")) }
            guard value["kind"].string == "known", let provider = value["provider"].string,
                  let directory = value["configDir"].string, directory.hasPrefix("/"), !directory.contains("\0"),
                  let source = value["source"].string, ["spawn", "hook", "process"].contains(source) else {
                throw BackendHOSTFailure.invalid("The helper did not return original established account evidence.")
            }
            return .init(provider: provider, configDir: directory, profileId: value["profileId"].string,
                profileName: value["profileName"].string, source: source, email: value["email"].string, reason: nil)
        } catch { note("The helper's actual session account evidence could not be read."); return .withheld("The running session's established account could not be read from its host.") }
    }
    public func drop(sessionID: String) async {
        do { _ = try await client.resource("account.attribution.drop", arguments: .object([.init("id", .string(sessionID))])) }
        catch { note("Account evidence remains owned by the helper until it confirms this process exit.") }
    }
    public func diagnostics() -> [String] { failures }
    private func note(_ value: String) { failures.append(value); if failures.count > 16 { failures.removeFirst() } }
}
#endif
