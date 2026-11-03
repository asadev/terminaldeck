import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

enum BackendRemoteServeAccountPortFixture {
    static func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("td-remote-port-" + UUID().uuidString) }
    static func withTrust<T: Sendable>(_ body: @Sendable (BackendRemoteTrustStore, URL) async throws -> T) async throws -> T {
        let root = root(), trust = BackendRemoteTrustStore(directory: root)
        try await trust.open()
        do { let answer = try await body(trust, root); await trust.close(); try? FileManager.default.removeItem(at: root); return answer }
        catch { await trust.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
    static func meta(id: String = "sess-new", cwd: String = "/Users/apple/Projects/terminaldeck", provider: String = "claude") throws -> BackendSessionMeta {
        let raw = NativeRPCValue.object([.init("id", .string(id)), .init("cwd", .string(cwd)), .init("title", .string("terminaldeck")), .init("provider", .string(provider)), .init("exitCode", .null), .init("createdAt", .number(1_760_000_000_000)), .init("resumed", .bool(false))])
        return try JSONDecoder().decode(BackendSessionMeta.self, from: raw.encodedJSON())
    }
    static func profile(_ id: String = "work", name: String = "work@example.com", system: Bool = false) -> BackendAccountProfile {
        .init(id: id, name: name, provider: "claude", configDir: "/test/account/" + id, system: system, color: "--accent", createdAt: 1)
    }
    static func context(kind: BackendRemoteDeviceKind = .mine) -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: kind == .mine ? "own" : "guest", kind: kind, address: "test", peerPublicKey: nil,
            claimedCapabilities: [], reach: .init(kind: kind, unrestricted: kind == .mine, folders: [], accounts: nil, drivesWindows: false))
    }
    static func message(_ raw: String) throws -> BackendRemoteClientMessage {
        switch BackendRemoteProtocol.parseClientMessage(raw) {
        case .message(let value): return value
        case .refused(let refusal): throw NativeRPCError(code: refusal.code, message: refusal.reason)
        }
    }
}
