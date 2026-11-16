import Foundation
import TerminalDeckNativeCore

/// Durable "already uploaded" marks for Cloud secrets (L7): one small owner-only
/// file per keyed slot (device id + source) in the app's data folder. It holds
/// only root-keyed HMACs of record ids and records; the file name is a keyed
/// slot too, so not even a source name can be confirmed from it. A lost or
/// damaged file only means those records upload once more.
public actor BackendCloudSecretsKnown: CloudSecretsKnownStore {
    private struct File: Codable { let v: Int; let epoch: Int; let entries: [String: String]; let pending: [String: String]? }
    static let maximumBytes = 16 * 1024 * 1024
    private let directory: URL
    private let requireWriter: @Sendable () throws -> Void
    public init(dataRoot: URL, requireWriter: @escaping @Sendable () throws -> Void) {
        directory = dataRoot.appendingPathComponent("cloud-secret-known", isDirectory: true)
        self.requireWriter = requireWriter
    }
    private func file(_ slot: String) throws -> URL {
        guard slot.count == 64, slot.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw CloudFailure.invalidRequest }
        return directory.appendingPathComponent(slot + ".json")
    }
    public func load(slot: String, epoch: Int) throws -> (entries: [String: String], pending: [String: String]) {
        guard let bytes = try BackendAccountFiles.boundedRead(file(slot), maximum: Self.maximumBytes) else { return ([:], [:]) }
        let saved = try JSONDecoder().decode(File.self, from: bytes)
        guard saved.v == 1, saved.epoch == epoch else { return ([:], [:]) }
        return (saved.entries, saved.pending ?? [:])
    }
    public func save(slot: String, epoch: Int, entries: [String: String], pending: [String: String]) throws {
        try requireWriter()
        guard entries.allSatisfy({ $0.key.count == 64 && $0.value.count == 64 }),
              pending.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.count == 129 }) else { throw CloudFailure.invalidRequest }
        let bytes = try JSONEncoder().encode(File(v: 1, epoch: epoch, entries: entries, pending: pending))
        guard bytes.count <= Self.maximumBytes else { throw CloudFailure.invalidRequest }
        try BackendAccountFiles.writeAtomic(bytes, to: file(slot))
    }
}
