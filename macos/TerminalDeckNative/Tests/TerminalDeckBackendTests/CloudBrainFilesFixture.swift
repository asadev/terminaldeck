import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only. Every folder is under the agreed scratch root; no real data folder, provider home, Keychain or network.
struct CloudBrainFilesFixture: Sendable {
    let base: URL
    let deviceA = UUID().uuidString.lowercased()
    let deviceB = UUID().uuidString.lowercased()
    init() throws {
        base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("a-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func url(_ path: String) -> URL { base.appendingPathComponent(path) }
    func write(_ path: String, _ text: String) throws { try write(path, data: Data(text.utf8)) }
    func write(_ path: String, data: Data) throws {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    func read(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
    func close() { try? FileManager.default.removeItem(at: base) }

    /// A plain one-source engine for the shared statements.
    func notes(_ machine: String, device: String, projection: BackendCloudBrainFilesProjection = .createOnly(transform: nil), optional: Bool = true) throws -> BackendCloudBrainFiles {
        try BackendCloudBrainFiles(inventoryRow: "I08", deviceId: device, stateRoot: url(machine + "/state"),
                                   sources: [.init(sourceId: "notes", root: url(machine + "/notes"), include: ["**"], exclude: BackendCloudBrainFilesNames.locks,
                                                   optional: optional, projection: projection)])
    }

    static func snapshot(_ adapter: BackendCloudBrainFiles) async throws -> (operations: [CloudOperation], coverage: [CloudCoverage]) {
        var operations: [CloudOperation] = [], coverage: [CloudCoverage] = []
        for try await page in await adapter.snapshotPages(cut: .init(snapshotId: UUID().uuidString, at: 1000125, watermarks: [:])) {
            operations += page.operations
            if !page.coverage.isEmpty { coverage = page.coverage }
        }
        return (operations, coverage)
    }
    /// Everything journaled after the cursor, through the same path the pump uses.
    static func local(_ adapter: BackendCloudBrainFiles, after: String? = nil) async throws -> (operations: [CloudOperation], cursor: String?) {
        var cursor = after, operations: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        return (operations, cursor)
    }
    static func apply(_ adapter: BackendCloudBrainFiles, _ operations: [CloudOperation], device: String) async throws -> CloudImportReceipt {
        let prepared = try await adapter.validateIncoming(operations, files: [])
        let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: device, sequence: .init(1)))
        guard try await adapter.verify(receipt).verified else { throw CloudFailure.checksumMismatch }
        return receipt
    }
    static func part(_ op: CloudOperation) throws -> CloudBrainMemoryPart {
        try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
    }
    /// Same identity, different content, internally consistent payload hash: what a broken or hostile sender could produce.
    static func tampered(_ op: CloudOperation) throws -> CloudOperation {
        let p = try part(op)
        var data = Data(base64Encoded: p.data) ?? Data()
        if data.isEmpty { data = Data([1]) } else { data[0] ^= 0xff }
        let changed = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: p.key, version: p.version, resourceHash: p.resourceHash,
                                           bytes: p.bytes, index: p.index, count: p.count, parents: p.parents, data: data.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(changed))
        return CloudOperation(v: op.v, opId: op.opId, originDevice: op.originDevice, domain: op.domain, entityId: op.entityId, revision: op.revision,
                              parents: op.parents, kind: op.kind, projectId: op.projectId, rootId: op.rootId, source: op.source, createdAt: op.createdAt,
                              payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
    }
}
