import Foundation
import TerminalDeckNativeCore

extension BackendRemoteTrustStore {
    public func remoteServeFolderGrants() -> NativeRPCValue {
        .array(folderGrants.sorted { $0.key < $1.key }.map { .object([.init("deviceId", .string($0.key)), .init("folders", .array($0.value.map(NativeRPCValue.string)))]) })
    }
    @discardableResult public func remoteServeSetFolderGrants(_ deviceID: String, folders: [NativeRPCValue]) throws -> [String] {
        guard !deviceID.isEmpty else { return [] }
        let cleaned = BackendRemoteServeSessionPolicy.cleanFolders(folders)
        guard folderGrants[deviceID] != nil || folderGrants.count < 64 else { return cleaned }
        try requireOpen(); var next = folderGrants; next[deviceID] = cleaned
        try remoteServePersistFolders(next); folderGrants = next; return cleaned
    }
    @discardableResult public func remoteServeForgetFolderGrants(_ deviceID: String) throws -> Bool {
        guard folderGrants[deviceID] != nil else { return false }
        try requireOpen(); var next = folderGrants; next[deviceID] = nil
        try remoteServePersistFolders(next); folderGrants = next; return true
    }
    private func remoteServePersistFolders(_ rows: [String: [String]]) throws {
        try BackendRemoteServeAccountGrantStorage.write(devices: rows.sorted { $0.key < $1.key }.map { .init($0.key, .array($0.value.map(NativeRPCValue.string))) }, directory: directory, name: "remote-folders.json")
    }
}
