import Foundation
import TerminalDeckNativeCore

/// A named-field projection. Store clocks, starting folder, credentials and
/// later store fields cannot cross simply because the store grows.
public struct BackendServersSummary: Codable, Equatable, Sendable {
    public let id: String; public let name: String; public let address: String; public let port: Int
    public let username: String; public let credential: BackendServersCredentialKind; public let hostKey: BackendServersHostKeyRecord?; public let drivesWindows: Bool
    public init(_ row: BackendServersStoredServer) {
        id = row.id; name = row.name; address = row.address; port = row.port; username = row.username
        credential = row.credential; hostKey = row.hostKey; drivesWindows = row.drivesWindows
    }
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("name", .string(name)), .init("address", .string(address)), .init("port", .number(Double(port))), .init("username", .string(username)), .init("credential", .string(credential.rawValue)), .init("drivesWindows", .bool(drivesWindows))]
        if let hostKey { fields.append(.init("hostKey", .object([.init("algorithm", .string(hostKey.algorithm)), .init("fingerprint", .string(hostKey.fingerprint)), .init("firstSeenAt", .number(hostKey.firstSeenAt))]))) }
        return .object(fields)
    }
}
