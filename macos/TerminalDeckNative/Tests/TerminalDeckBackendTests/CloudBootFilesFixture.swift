import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only. Every folder is under the agreed scratch root (`…/notes/cloud-test-20261112/files/`) and removed by
/// `close()`. No real project, provider home, data folder, Keychain or network.
struct CloudBootFilesFixture: Sendable {
    let base: URL
    let deviceA = UUID().uuidString.lowercased()
    let deviceB = UUID().uuidString.lowercased()
    init() throws {
        base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("files/f-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func close() { try? FileManager.default.removeItem(at: base) }
    func url(_ path: String) -> URL { base.appendingPathComponent(path) }
    @discardableResult func folder(_ path: String) throws -> URL {
        let made = url(path)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    func write(_ path: String, _ text: String) throws { try write(path, data: Data(text.utf8)) }
    func write(_ path: String, data: Data) throws {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    /// The file's text, or nil when nothing (or something that is not a readable file) is there.
    func text(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: url(path)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    /// True when the NAME exists (a link counts, whatever it points at).
    func exists(_ path: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url(path).path)) != nil }
    /// Every name under a folder (hidden ones too), sorted: to show a folder was left exactly as it was.
    func listing(_ path: String) -> [String] {
        guard let all = FileManager.default.enumerator(atPath: url(path).path) else { return [] }
        var names: [String] = []
        while let name = all.nextObject() as? String { names.append(name) }
        return names.sorted()
    }
    func seal(_ paths: [String]) throws {
        for path in paths { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url(path).path) }
    }
    func unseal(_ paths: [String]) {
        for path in paths { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(path).path) }
    }

    func project(_ id: String, _ path: String, chosen: Bool = true) -> BackendCloudBootFilesPlace {
        .init(kind: .project, identity: id, root: url(path), chosen: chosen)
    }
    func home(_ kind: CloudBootFilesPlaceKind, _ path: String, identity: String = "system") -> BackendCloudBootFilesPlace {
        .init(kind: kind, identity: identity, root: url(path))
    }
    /// One Mac: its own Cloud folder under `<name>/cloud/boot-files` and the places it has.
    func mac(_ name: String, device: String, places: [BackendCloudBootFilesPlace], announced: Bool = false) async throws -> BackendCloudBootFiles {
        let adapter = try BackendCloudBootFiles(deviceId: device, stateRoot: url(name + "/cloud/boot-files"))
        // Review 15 Nov (MUST 4): by default the sender is an older build (a removal without an about-record is Everywhere).
        await adapter.setDeleteRuleAnnounced { _ in announced }
        try await adapter.setPlaces(places)
        return adapter
    }

    static func prefix(project id: String) -> String { "file/project/" + BackendCloudBrainFilesNames.token(id) + "/" }
    static func prefix(home kind: CloudBootFilesPlaceKind, identity: String = "system") -> String {
        "file/home/" + kind.rawValue + "/" + BackendCloudBrainFilesNames.token(identity) + "/"
    }
    static func keys(_ operations: [CloudOperation]) -> Set<String> { Set(operations.map { $0.source.recordId }) }
    static func part(_ operation: CloudOperation) throws -> CloudBrainMemoryPart {
        let payload = try CloudWire.canonical(operation.payload)
        return try JSONDecoder().decode(CloudBrainMemoryPart.self, from: payload)
    }
    /// The file bytes a one-part record carries.
    static func body(_ operation: CloudOperation) throws -> String {
        let data = try Data(base64Encoded: part(operation).data) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func snapshot(_ adapter: BackendCloudBootFiles) async throws -> (operations: [CloudOperation], coverage: [CloudCoverage]) {
        var operations: [CloudOperation] = [], coverage: [CloudCoverage] = []
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1_000, watermarks: [:])
        for try await page in await adapter.snapshotPages(cut: cut) {
            operations += page.operations
            if !page.coverage.isEmpty { coverage = page.coverage }
        }
        return (operations, coverage)
    }
    /// Everything journaled after the cursor, the way lane A's pump reads it.
    static func local(_ adapter: BackendCloudBootFiles, after: String? = nil) async throws -> (operations: [CloudOperation], cursor: String?) {
        var cursor = after, operations: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) {
            operations.append(change.operation)
            cursor = change.cursor
        }
        return (operations, cursor)
    }
}
