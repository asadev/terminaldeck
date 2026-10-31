import Foundation
import TerminalDeckNativeCore

/// A named-field projection. Store clocks, starting folder, credentials and
/// later store fields cannot cross simply because the store grows.
public struct BackendServersSummary: Codable, Equatable, Sendable {
    public let id: String; public let name: String; public let address: String; public let port: Int
    public let username: String; public let credential: BackendServersCredentialKind; public let hostKey: BackendServersHostKeyRecord?; public let drivesWindows: Bool
    /// Named on purpose: the SSH settings name and the look-only choice are not secrets.
    public let sshAlias: String?; public let lookOnly: Bool?
    public let projectId: String
    public let projectIdInferred: Bool
    public let startIn: String?
    public init(_ row: BackendServersStoredServer) {
        projectId = row.resolvedProjectId; projectIdInferred = row.projectIdInferred
        startIn = row.projectIdInferred ? row.startIn : nil
        id = row.id; name = row.name; address = row.address; port = row.port; username = row.username
        credential = row.credential; hostKey = row.hostKey; drivesWindows = row.drivesWindows
        sshAlias = row.sshAlias; lookOnly = row.isLookOnly ? true : nil
    }
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("projectId", .string(projectId)), .init("projectName", .string(PROJProjects.name(for: projectId))), .init("id", .string(id)), .init("name", .string(name)), .init("address", .string(address)), .init("port", .number(Double(port))), .init("username", .string(username)), .init("credential", .string(credential.rawValue)), .init("drivesWindows", .bool(drivesWindows))]
        if projectIdInferred {
            fields.append(.init("projectIdInferred", .bool(true)))
            if let startIn { fields.append(.init("startIn", .string(startIn))) }
        }
        if let hostKey { fields.append(.init("hostKey", .object([.init("algorithm", .string(hostKey.algorithm)), .init("fingerprint", .string(hostKey.fingerprint)), .init("firstSeenAt", .number(hostKey.firstSeenAt))]))) }
        if let sshAlias { fields.append(.init("sshAlias", .string(sshAlias))) }
        if lookOnly == true { fields.append(.init("lookOnly", .bool(true))) }
        return .object(fields)
    }
}
