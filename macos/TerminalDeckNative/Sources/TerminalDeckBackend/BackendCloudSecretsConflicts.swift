import Foundation
import TerminalDeckNativeCore

/// Permanent local conflict copies contain only the original sealed operation.
/// They survive SYNC cursor advancement and never materialize a remote secret.
public actor BackendCloudSecretsConflicts {
    private let directory: URL
    private let requireWriter: @Sendable () throws -> Void
    public init(dataRoot: URL, requireWriter: @escaping @Sendable () throws -> Void) {
        directory = dataRoot.appendingPathComponent("cloud-secret-conflicts", isDirectory: true)
        self.requireWriter = requireWriter
    }
    public func retain(_ operation: CloudOperation) throws {
        try requireWriter()
        let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(operation.payload), maximumBytes: CloudWire.maximumBlobBytes)
        guard envelope.storageClass == .secrets,
              operation.payloadHash == (try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(operation.payload))) else { throw CloudFailure.invalidRequest }
        let bytes = try CloudSecretsCanonical.encode(operation)
        let file = directory.appendingPathComponent(CloudSecretsCrypto.hash(bytes) + ".json")
        if let old = try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumBlobBytes) {
            guard old == bytes else { throw CloudFailure.checksumMismatch }
            return
        }
        try BackendAccountFiles.writeAtomic(bytes, to: file)
        guard try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumBlobBytes) == bytes else { throw CloudFailure.checksumMismatch }
    }
}
