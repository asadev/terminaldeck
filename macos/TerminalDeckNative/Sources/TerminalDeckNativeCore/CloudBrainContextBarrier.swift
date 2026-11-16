import Foundation

/// Full context requires all brain sources, never just the adapters that happened to register tonight.
public actor CloudBrainContextBarrier {
    public static let requiredInventoryRows: Set<String> = ["I01","I02","I03","I04","I05","I06","I08","I09","I10","I11","I12","I17","I18","I19","I20"]
    public struct Probe: Sendable {
        public let sourceId: String
        public let verify: @Sendable () async throws -> CloudVerification
        public init(sourceId: String, verify: @escaping @Sendable () async throws -> CloudVerification) { self.sourceId = sourceId; self.verify = verify }
    }
    private let paths: any CloudPathPort
    private let outbox: any CloudOutboxPort
    private let deviceId: String
    private let probes: [Probe]
    private let expectedInventory: @Sendable () async throws -> [CloudSourceInventory]
    public init(paths: any CloudPathPort, outbox: any CloudOutboxPort, deviceId: String, probes: [Probe], expectedInventory: @escaping @Sendable () async throws -> [CloudSourceInventory]) throws {
        guard UUID(uuidString: deviceId) != nil, !probes.isEmpty else { throw CloudFailure.invalidRequest }
        self.paths = paths; self.outbox = outbox; self.deviceId = deviceId; self.probes = probes; self.expectedInventory = expectedInventory
    }
    public func context(projectId: String, rootId: String, throughSeq: CloudSequence) async throws -> CloudContextReady {
        let progress = try await outbox.restoreProgress(), remote = try await outbox.contextReady(projectId: projectId)
        var missing = Set(remote.missingSources)
        let inventory = try await expectedInventory() // complete catalog from the verified Cloud checkpoint, not only installed adapters
        for row in Self.requiredInventoryRows {
            let expected = inventory.filter { $0.inventoryRow == row }
            if expected.isEmpty || expected.contains(where: { !$0.complete || !$0.blockedReasons.isEmpty }) { missing.insert(row) }
            for source in expected {
                let matches = progress.coverage.filter { $0.inventoryRow == row && $0.sourceId == source.sourceId }
                if matches.count != 1 || matches.contains(where: { !$0.complete || !$0.blockedReasons.isEmpty || $0.items != source.items || $0.bytes != source.bytes }) { missing.insert(source.sourceId) }
            }
        }
        if progress.brainSeq < throughSeq || remote.throughSeq < throughSeq || !remote.verified || progress.blocked != 0 || remote.sourceCounts.blocked != 0 { missing.insert("Cloud catch-up") }
        if let map = try await paths.map(projectId: projectId, rootId: rootId, deviceId: deviceId), map.deviceId == deviceId,
           map.projectId == projectId, map.rootId == rootId, !map.localAbsolutePath.isEmpty {
            var directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: map.localAbsolutePath, isDirectory: &directory) || !directory.boolValue ||
                URL(fileURLWithPath: map.localAbsolutePath).standardizedFileURL.resolvingSymlinksInPath().path != map.canonicalPath { missing.insert("Project folder") }
        } else { missing.insert("Project folder") }
        for probe in probes {
            do { let verification = try await probe.verify(); if !verification.verified || verification.counts.blocked != 0 { missing.insert(probe.sourceId) } }
            catch { missing.insert(probe.sourceId) }
        }
        return .init(projectId: projectId, throughSeq: min(progress.brainSeq, remote.throughSeq), sourceCounts: remote.sourceCounts, verified: missing.isEmpty, missingSources: missing.sorted())
    }
}
