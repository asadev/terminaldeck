import Foundation
import TerminalDeckNativeCore

/// Device paths are a Cloud-owned store, separate from the existing project registry's writer.
/// Construction is inert. The account assembly must hold its instance's data-folder ownership.
public actor BackendCloudBrainPaths: CloudPathPort {
    public typealias RestoreVerifier = @Sendable (CloudPathPlan, CloudVerification) async throws -> Bool
    private struct Pending: Codable { let plan: CloudPathPlan; let generation: CloudSequence; let createdAt: Int64 }
    private struct Completed: Codable { let map: CloudPathMap; let receiptHash: String }
    private struct State: Codable {
        let v: Int
        let subject: CloudSubject
        var generation: CloudSequence
        var maps: [CloudPathMap]
        var operations: [CloudOperation]
        var pending: [Pending]
        var completed: [String:Completed]
        var pendingLocal: [CloudOperation]?
    }
    private let file: URL, roots: [URL], subject: CloudSubject, deviceId: String
    private let outbox: any CloudOutboxPort
    private let verifyRestore: RestoreVerifier
    private let now: @Sendable () -> Int64
    private var state: State?
    private var lease: BackendAccountWriterLease?
    private var committing = false
    public init(file: URL, allowedRoots: [URL], subject: CloudSubject, deviceId: String, outbox: any CloudOutboxPort,
                verifyRestore: @escaping RestoreVerifier, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard file.isFileURL, !allowedRoots.isEmpty, allowedRoots.allSatisfy(\.isFileURL), UUID(uuidString: deviceId) != nil,
              UUID(uuidString: subject.sub) != nil, !subject.issuer.isEmpty else { throw CloudFailure.invalidRequest }
        self.file = file; roots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.subject = subject; self.deviceId = deviceId; self.outbox = outbox; self.verifyRestore = verifyRestore; self.now = now
    }
    private func load() throws -> State {
        if let state { return state }
        let lease = try BackendAccountWriterLease(file: file)
        let loaded: State
        if FileManager.default.fileExists(atPath: file.path) {
            loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard loaded.v == 1, loaded.subject == subject else { throw CloudFailure.unsafeConfiguration }
        } else { loaded = .init(v: 1, subject: subject, generation: .zero, maps: [], operations: [], pending: [], completed: [:], pendingLocal: nil) }
        self.lease = lease; state = loaded; return loaded
    }
    private func persist(_ next: State) throws {
        try BackendAccountFiles.writeAtomic(CloudWire.canonical(next), to: file)
        try BackendCloudBrainMemoryHash.synchronize(file)
        state = next
    }
    private func canonicalDestination(_ destination: String) throws -> URL {
        guard destination.hasPrefix("/"), !destination.contains("\0") else { throw CloudFailure.invalidRequest }
        let canonical = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: { canonical.path.hasPrefix($0.path + "/") }), canonical.path != file.deletingLastPathComponent().path else { throw CloudFailure.unsafeConfiguration }
        return canonical
    }
    public func map(projectId: String, rootId: String, deviceId: String) async throws -> CloudPathMap? {
        try load().maps.last { $0.projectId == projectId && $0.rootId == rootId && $0.deviceId == deviceId }
    }
    public func planMapping(projectId: String, rootId: String, destination: String) async throws -> CloudPathPlan {
        guard !projectId.isEmpty, projectId.utf8.count <= 256, UUID(uuidString: rootId) != nil else { throw CloudFailure.invalidRequest }
        var next = try load()
        let target = try canonicalDestination(destination)
        var directory: ObjCBool = false, conflicts: [String] = []
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &directory) {
            if !directory.boolValue { conflicts = ["There is already a file here."] }
            else if !(try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty { conflicts = ["This folder already has files."] }
        }
        let id = UUID().uuidString.lowercased()
        let unsigned = CloudPathPlan(planId: id, projectId: projectId, rootId: rootId, destination: target.path, digest: "", conflicts: conflicts)
        let digest = BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(unsigned))
        let plan = CloudPathPlan(planId: id, projectId: projectId, rootId: rootId, destination: target.path, digest: digest, conflicts: conflicts)
        next.pending.append(.init(plan: plan, generation: next.generation, createdAt: now())); try persist(next)
        return plan
    }
    public func commitMapping(planDigest: String, receipt: CloudVerification) async throws -> CloudPathMap {
        guard !committing else { throw CloudFailure.unavailable }; committing = true; defer { committing = false }
        let initial = try load()
        let receiptHash = BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(receipt))
        if let completed = initial.completed[planDigest] {
            guard completed.receiptHash == receiptHash else { throw CloudFailure.idReused }; return completed.map
        }
        guard let pending = initial.pending.first(where: { $0.plan.digest == planDigest }), pending.generation == initial.generation,
              pending.plan.conflicts.isEmpty, receipt.verified, receipt.counts.blocked == 0 else { throw CloudFailure.versionChanged }
        let plan = pending.plan, target = try canonicalDestination(plan.destination)
        guard target.path == plan.destination, try await verifyRestore(plan, receipt) else { throw CloudFailure.checksumMismatch }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue else { throw CloudFailure.unavailable }
        var next = try load()
        guard next.generation == initial.generation, (try canonicalDestination(plan.destination)).path == target.path else { throw CloudFailure.versionChanged }
        let map = CloudPathMap(v: 1, deviceId: deviceId, projectId: plan.projectId, rootId: plan.rootId, logicalRoot: "project/" + plan.projectId + "/roots/" + plan.rootId,
                               localAbsolutePath: target.path, canonicalPath: target.path, aliases: [target.path], providerHomes: [:], updatedAt: pending.createdAt)
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(map))
        let id = BackendCloudBrainMemoryHash.operationId(deviceId + "\n" + plan.planId), key = map.deviceId + ":" + map.projectId + ":" + map.rootId
        let entity = BackendCloudBrainMemoryHash.uuid(key)
        let previous = next.operations.last { $0.entityId == entity }
        let op = CloudOperation(v: 1, opId: id, originDevice: deviceId, domain: "machines/paths", entityId: entity, revision: id, parents: previous.map { [$0.revision] } ?? [], kind: .put,
                                projectId: map.projectId, rootId: map.rootId, source: .init(sourceId: "paths/" + deviceId, recordId: key), createdAt: map.updatedAt,
                                payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        let saved = try await outbox.enqueue([op], files: [])
        guard saved.operationIds == [id], (try load()).generation == initial.generation else { throw CloudFailure.versionChanged }
        next = try load(); next.maps.removeAll { $0.deviceId == deviceId && $0.projectId == map.projectId && $0.rootId == map.rootId }
        next.maps.append(map); next.operations.append(op); next.completed[planDigest] = .init(map: map, receiptHash: receiptHash); next.pending.removeAll { $0.plan.digest == planDigest }
        guard let generation = UInt64(next.generation.rawValue), generation < UInt64.max else { throw CloudFailure.invalidRequest }
        next.generation = .init(generation + 1); try persist(next)
        return map
    }
    /// Incoming paths are historical facts about their named machine. They never move or overwrite project files.
    public func importMaps(_ operations: [CloudOperation]) async throws -> CloudVerification {
        var next = try load(), applied = 0
        for op in operations {
            guard op.v == 1, op.domain == "machines/paths", op.opId == op.revision,
                  BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(op.payload)) == op.payloadHash else { throw CloudFailure.checksumMismatch }
            if let old = next.operations.first(where: { $0.opId == op.opId }) { guard old == op else { throw CloudFailure.idReused }; continue }
            let map = try CloudWire.decode(CloudPathMap.self, from: CloudWire.canonical(op.payload), allowedKeys: ["v","deviceId","projectId","rootId","logicalRoot","localAbsolutePath","canonicalPath","aliases","providerHomes","updatedAt"])
            guard map.v == 1, map.deviceId == op.originDevice, UUID(uuidString: map.deviceId) != nil, UUID(uuidString: map.rootId) != nil,
                  map.projectId == op.projectId, map.rootId == op.rootId, map.providerHomes.isEmpty else { throw CloudFailure.invalidRequest }
            next.operations.append(op)
            // Existing maps stay active until an explicit verified local plan changes them. Other devices retain their own paths.
            if map.deviceId != deviceId, !next.maps.contains(where: { $0.deviceId == map.deviceId && $0.projectId == map.projectId && $0.rootId == map.rootId }) { next.maps.append(map) }
            applied += 1
        }
        if applied > 0 { try persist(next) }
        return .init(verified: true, counts: .init(domains: 1, records: applied, files: 0, bytes: 0, blocked: 0), reasons: [])
    }
    public func retainedOperations() throws -> [CloudOperation] { try load().operations }

    /// Publishes where an EXISTING project folder lives on this Mac (§5.3), so other devices keep the association.
    /// Reads only; never creates, moves or writes project files. Unchanged paths replay nothing.
    public func publishLocal(projectId: String, rootId: String, path: String) async throws -> CloudPathMap {
        guard !committing else { throw CloudFailure.unavailable }; committing = true; defer { committing = false }
        guard !projectId.isEmpty, projectId.utf8.count <= 256, UUID(uuidString: rootId) != nil, path.hasPrefix("/"), !path.contains("\0") else { throw CloudFailure.invalidRequest }
        let given = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let canonical = given.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory), directory.boolValue else { throw CloudFailure.unavailable }
        let initial = try load()
        if let current = initial.maps.last(where: { $0.deviceId == deviceId && $0.projectId == projectId && $0.rootId == rootId }),
           current.canonicalPath == canonical.path, current.localAbsolutePath == given.path { return current }
        let key = deviceId + ":" + projectId + ":" + rootId, entity = BackendCloudBrainMemoryHash.uuid(key)
        // A retry after a failed outbox save replays the identical saved operation, never new bytes under the same id.
        if let saved = initial.pendingLocal?.first(where: { $0.entityId == entity }),
           let pendingMap = try? CloudWire.decode(CloudPathMap.self, from: CloudWire.canonical(saved.payload)),
           pendingMap.canonicalPath == canonical.path, pendingMap.localAbsolutePath == given.path {
            return try await finishLocal(saved, map: pendingMap, generation: initial.generation)
        }
        let aliases = Array(Set([given.path, canonical.path])).sorted()
        let map = CloudPathMap(v: 1, deviceId: deviceId, projectId: projectId, rootId: rootId, logicalRoot: "project/" + projectId + "/roots/" + rootId,
                               localAbsolutePath: given.path, canonicalPath: canonical.path, aliases: aliases, providerHomes: [:], updatedAt: now())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(map))
        let id = BackendCloudBrainMemoryHash.operationId(deviceId + "\nlocal\n" + key + "\n" + canonical.path + "\n" + given.path + "\n" + initial.generation.rawValue)
        let previous = initial.operations.last { $0.entityId == entity }
        let op = CloudOperation(v: 1, opId: id, originDevice: deviceId, domain: "machines/paths", entityId: entity, revision: id, parents: previous.map { [$0.revision] } ?? [], kind: .put,
                                projectId: projectId, rootId: rootId, source: .init(sourceId: "paths/" + deviceId, recordId: key), createdAt: map.updatedAt,
                                payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        var staged = initial
        staged.pendingLocal = (staged.pendingLocal ?? []).filter { $0.entityId != entity } + [op]
        try persist(staged)
        return try await finishLocal(op, map: map, generation: initial.generation)
    }
    /// Durable outbox first; the local map becomes active only after its LocalReceipt (§5.2).
    private func finishLocal(_ op: CloudOperation, map: CloudPathMap, generation expected: CloudSequence) async throws -> CloudPathMap {
        let saved = try await outbox.enqueue([op], files: [])
        guard saved.operationIds == [op.opId] else { throw CloudFailure.checksumMismatch }
        var next = try load()
        guard next.generation == expected else { throw CloudFailure.versionChanged }
        next.maps.removeAll { $0.deviceId == map.deviceId && $0.projectId == map.projectId && $0.rootId == map.rootId }
        next.maps.append(map); next.operations.append(op)
        next.pendingLocal = (next.pendingLocal ?? []).filter { $0.opId != op.opId }
        guard let generation = UInt64(next.generation.rawValue), generation < UInt64.max else { throw CloudFailure.invalidRequest }
        next.generation = .init(generation + 1); try persist(next)
        return map
    }

    /// §5.3 runtime default for a project restored onto a new Mac: an existing configured development root wins,
    /// otherwise `~/Terminal Deck Projects/<safe-name>/<rootId-short>`; an occupied path gets a new sibling.
    /// Never derived from a basename match, lossy provider path encoding or a remote URL. Creates nothing.
    public nonisolated static func defaultDestination(projectName: String, rootId: String, home: URL, developmentRoot: URL?,
                                                      occupied: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> String {
        guard UUID(uuidString: rootId) != nil, home.isFileURL else { throw CloudFailure.invalidRequest }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        var cleaned = ""
        for scalar in projectName.unicodeScalars { cleaned.unicodeScalars.append(allowed.contains(scalar) ? scalar : "-") }
        var safe = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if safe.isEmpty { safe = "Project" }
        safe = String(safe.prefix(80))
        let parent = (developmentRoot ?? home.appendingPathComponent("Terminal Deck Projects", isDirectory: true)).appendingPathComponent(safe, isDirectory: true)
        let short = String(rootId.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
        let first = parent.appendingPathComponent(short, isDirectory: true).standardizedFileURL.path
        if !occupied(first) { return first }
        for n in 2...999 {
            let sibling = parent.appendingPathComponent(short + "-" + String(n), isDirectory: true).standardizedFileURL.path
            if !occupied(sibling) { return sibling }
        }
        throw CloudFailure.unavailable
    }
}
