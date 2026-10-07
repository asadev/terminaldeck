import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteServeSessionGrant: Equatable, Sendable {
    public let deviceID: String
    public let all: Bool
    public let sessions: [String]
    public var wireValue: NativeRPCValue { .object([.init("deviceId", .string(deviceID)), .init("mode", .string(all ? "all" : "selected")), .init("sessions", .array(sessions.map(NativeRPCValue.string)))]) }
}
extension BackendRemoteTrustStore {
    public func remoteServeSessionGrant(_ deviceID: String) -> BackendRemoteServeSessionGrant? {
        guard !deviceID.isEmpty, let row = sessionGrants[deviceID] else { return nil }
        return .init(deviceID: deviceID, all: row.all, sessions: row.ids)
    }
    public func remoteServeSessionGrants() -> [BackendRemoteServeSessionGrant] {
        sessionGrants.sorted { $0.key < $1.key }.map { .init(deviceID: $0.key, all: $0.value.all, sessions: $0.value.ids) }
    }
    @discardableResult public func remoteServeSetSessionGrants(_ deviceID: String, mode: NativeRPCValue, sessions: [NativeRPCValue]) throws -> BackendRemoteServeSessionGrant {
        let all = mode.string == "all", ids = mode.string == "all" ? [] : BackendRemoteServeAccountGrantStorage.clean(sessions, maximum: 256, length: 128)
        let answer = BackendRemoteServeSessionGrant(deviceID: deviceID, all: all, sessions: ids)
        guard !deviceID.isEmpty, sessionGrants[deviceID] != nil || sessionGrants.count < 64 else { return answer }
        try requireOpen(); var next = sessionGrants; next[deviceID] = Share(all: all, ids: ids)
        try remoteServePersistSessions(next); sessionGrants = next; return answer
    }
    @discardableResult public func remoteServeIncludeStartedSession(_ deviceID: String, sessionID: String) throws -> Bool {
        guard !deviceID.isEmpty, !sessionID.isEmpty, sessionID.utf16.count <= 128,
              let row = sessionGrants[deviceID], !row.all, !row.ids.contains(sessionID), row.ids.count < 256 else { return false }
        try requireOpen(); var next = sessionGrants; next[deviceID] = Share(all: false, ids: row.ids + [sessionID])
        try remoteServePersistSessions(next); sessionGrants = next; return true
    }
    @discardableResult public func remoteServeForgetSessionGrants(_ deviceID: String) throws -> Bool {
        guard sessionGrants[deviceID] != nil else { return false }
        try requireOpen(); var next = sessionGrants; next[deviceID] = nil
        try remoteServePersistSessions(next); sessionGrants = next; return true
    }
    @discardableResult public func remoteServeDropSession(_ sessionID: String) throws -> Bool {
        guard !sessionID.isEmpty, sessionGrants.values.contains(where: { $0.ids.contains(sessionID) }) else { return false }
        try requireOpen(); var next = sessionGrants
        for (id, row) in next where row.ids.contains(sessionID) { next[id] = Share(all: row.all, ids: row.ids.filter { $0 != sessionID }) }
        try remoteServePersistSessions(next); sessionGrants = next; return true
    }
    private func remoteServePersistSessions(_ rows: [String: Share]) throws {
        try BackendRemoteServeAccountGrantStorage.write(devices: rows.sorted { $0.key < $1.key }.map { .init($0.key, .object([
            .init("mode", .string($0.value.all ? "all" : "selected")), .init("sessions", .array($0.value.ids.map(NativeRPCValue.string)))])) }, directory: directory, name: "remote-sessions.json")
    }
}
