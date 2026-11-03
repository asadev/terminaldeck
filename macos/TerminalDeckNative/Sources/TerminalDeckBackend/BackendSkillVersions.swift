import Foundation
import TerminalDeckNativeCore

/// Private local history. No discovery, script execution, provider call or
/// automatic adoption. Every source-tree mutation receives a current guard.
public actor BackendSkillVersions {
    public let root: URL
    private let writable: Bool
    private var busy = false
    private struct Adoption: Codable { let version: String, digest: String, at: Double }
    private struct Swap: Codable { let target: String, stage: String; let existed: Bool; let before: String, after: String; var beforeMarker: String? = nil, afterMarker: String? = nil }
    private struct Journal: Codable { let source: String, swaps: [Swap], previous: Adoption?; var committed: Bool }
    public init(root: URL, writable: Bool) { self.root = root; self.writable = writable }
    private func fail(_ message: String) -> NativeRPCError { .init(code: "skill-version-refused", message: message) }
    private func read<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
    private func put<T: Encodable>(_ value: T, _ file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try BackendAccountFiles.writeAtomic(try encoder.encode(value), to: file)
    }
    private func exists(_ path: URL) -> Bool { FileManager.default.fileExists(atPath: path.path) }
    private func registry() throws -> [String: String] { exists(root.appendingPathComponent("registry.json")) ? try read([String: String].self, root.appendingPathComponent("registry.json")) : [:] }
    private func identity(_ source: URL, create: Bool) throws -> String? {
        let storePath = BackendROUTINESSkillsScope.canonical(root.path), sourcePath = BackendROUTINESSkillsScope.canonical(source.path)
        guard storePath != sourcePath, !storePath.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(storePath + "/") else { throw fail("Skill history must be stored outside the skill folders.") }
        var map = try registry(); let path = BackendROUTINESSkillsScope.canonical(source.path)
        if let id = map[path] { guard UUID(uuidString: id) != nil else { throw fail("The skill history registry is invalid.") }; return id }
        guard create else { return nil }
        guard writable else { throw fail("This copy can only read skill history.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString.lowercased(); map[path] = id; try put(map, root.appendingPathComponent("registry.json")); return id
    }
    private func directory(_ identity: String) -> URL { root.appendingPathComponent(identity) }
    private func version(_ id: String, in home: URL) throws -> (SkillVersionRevision, URL) {
        guard UUID(uuidString: id) != nil else { throw fail("Choose a saved version id.") }
        let folder = home.appendingPathComponent("versions/" + id)
        let record = try read(SkillVersionRevision.self, folder.appendingPathComponent("revision.json"))
        guard record.id == id, record.files.count <= BackendSkillVersionFiles.maxFiles else { throw fail("The saved version metadata is damaged.") }
        return (record, folder.appendingPathComponent("tree"))
    }
    private func verified(_ id: String, in home: URL) throws -> (SkillVersionRevision, BackendSkillVersionFiles.Tree) {
        let (record, folder) = try version(id, in: home), tree = try BackendSkillVersionFiles.inspect(folder)
        guard tree.digest == record.digest, tree.manifest == record.files else { throw fail("Saved version integrity failed. No active files were changed.") }
        return (record, tree)
    }
    private func adoption(_ home: URL) throws -> Adoption? { exists(home.appendingPathComponent("adopted.json")) ? try read(Adoption.self, home.appendingPathComponent("adopted.json")) : nil }
    private func save(_ tree: BackendSkillVersionFiles.Tree, label: String, command: String, home: URL) throws -> SkillVersionRevision {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 100, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw fail("Give the version a one-line name under 100 bytes.") }
        let versions = home.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString.lowercased(), stage = versions.appendingPathComponent(".staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let record = SkillVersionRevision(id: id, label: label, digest: tree.digest, commandName: command, createdAt: Date().timeIntervalSince1970 * 1000, files: tree.manifest)
        try BackendSkillVersionFiles.write(tree, to: stage.appendingPathComponent("tree"))
        guard try BackendSkillVersionFiles.inspect(stage.appendingPathComponent("tree")).digest == tree.digest else { throw fail("The complete snapshot could not be verified.") }
        try put(record, stage.appendingPathComponent("revision.json"))
        try FileManager.default.moveItem(at: stage, to: versions.appendingPathComponent(id))
        return record
    }
    public func retarget(from source: URL, to target: URL) throws {
        guard writable, !busy else { throw fail("Skill history is read-only or busy.") }
        var map = try registry(); let old = BackendROUTINESSkillsScope.canonical(source.path), new = BackendROUTINESSkillsScope.canonical(target.path)
        guard let id = map[old] else { return }
        guard map[new] == nil else { throw fail("The renamed folder already has separate version history.") }
        map[new] = id; map[old] = nil; try put(map, root.appendingPathComponent("registry.json"))
    }
    public func info(source: URL, selected: String? = nil) throws -> NativeRPCValue {
        let current = try BackendSkillVersionFiles.inspect(source)
        var result = NativeRPCValue.object([.init("ok", .bool(true)), .init("currentDigest", .string(current.digest)), .init("versions", .array([])), .init("checks", .array([])), .init("dirty", .bool(true))])
        guard let id = try identity(source, create: false) else { return result }
        let home = directory(id), files = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("versions").path)) ?? []
        let records = try files.filter { UUID(uuidString: $0) != nil }.map { try version($0, in: home).0 }.sorted { $0.createdAt > $1.createdAt }
        let adopted = try adoption(home)
        result = result.setting("versions", .array(records.map(\.wire))).setting("adoptedVersion", adopted.map { .string($0.version) } ?? .null).setting("dirty", .bool(adopted?.digest != current.digest))
        let checks = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("checks"), includingPropertiesForKeys: nil)) ?? []
        let rows = try checks.filter { $0.pathExtension == "json" }.map { try read(SkillVersionCheck.self, $0) }.filter { selected == nil || $0.version == selected }.sorted { $0.at > $1.at }
        if let selected { let record = try version(selected, in: home).0; result = result.setting("selected", record.wire) }
        return result.setting("checks", .array(rows.map(\.wire))).setting("recoveryPending", .bool(exists(home.appendingPathComponent("operation.json"))))
    }
    public func snapshot(source: URL, label: String, expected: String, guard effect: BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue {
        guard writable, !busy else { throw fail("Skill history is read-only or another version change is saving.") }; busy = true; defer { busy = false }
        try await effect.verify()
        let tree = try BackendSkillVersionFiles.inspect(source)
        guard tree.digest == expected else { throw fail("The skill changed. Refresh its versions before saving.") }
        let command = SkillCommandNames.headerName(String(decoding: tree.data["SKILL.md"] ?? Data(), as: UTF8.self)) ?? source.lastPathComponent
        try await effect.verify()
        guard try BackendSkillVersionFiles.inspect(source).digest == expected else { throw fail("The skill changed while saving. Refresh and try again.") }
        let home = directory(try identity(source, create: true)!)
        let saved = try save(tree, label: label, command: command, home: home)
        return .object([.init("ok", .bool(true)), .init("version", saved.wire)])
    }
    public func check(source: URL, version id: String, guard effect: BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue {
        guard writable, !busy else { throw fail("Skill history is read-only or busy.") }; busy = true; defer { busy = false }
        try await effect.verify()
        guard let identity = try identity(source, create: false) else { throw fail("Save a version first.") }
        let home = directory(identity), record = try version(id, in: home).0
        var findings: [String]
        do { let (_, tree) = try verified(id, in: home); findings = BackendSkillVersionFiles.findings(tree, command: record.commandName) }
        catch { findings = [error.localizedDescription] }
        let check = SkillVersionCheck(id: UUID().uuidString.lowercased(), version: id, digest: record.digest, validator: "package-v1", at: Date().timeIntervalSince1970 * 1000, passed: findings.isEmpty, findings: findings)
        try await effect.verify()
        let folder = home.appendingPathComponent("checks"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try put(check, folder.appendingPathComponent(check.id + ".json"))
        return .object([.init("ok", .bool(true)), .init("check", check.wire)])
    }
    private func recover(_ home: URL, source: URL, mirror: URL?) throws {
        let file = home.appendingPathComponent("operation.json"); guard exists(file) else { return }
        let journal = try read(Journal.self, file)
        let allowed = [source.path, mirror?.path].compactMap { $0 }
        guard journal.source == source.path, journal.swaps.allSatisfy({ item in
            let target = URL(fileURLWithPath: item.target), stage = URL(fileURLWithPath: item.stage)
            return allowed.contains(item.target) && stage.deletingLastPathComponent() == target.deletingLastPathComponent() && stage.lastPathComponent.hasPrefix(".td-skill-version-")
        }) else { throw fail("The interrupted adoption journal needs manual review; its paths do not match this skill.") }
        func markerMatches(_ target: URL, _ expected: String?) throws -> Bool {
            guard let expected else { return true }
            return try BackendSkillVersionFiles.markerIdentity(target) == expected
        }
        for item in journal.swaps.reversed() {
            let target = URL(fileURLWithPath: item.target), stage = URL(fileURLWithPath: item.stage)
            if journal.committed {
                guard exists(target), try BackendSkillVersionFiles.inspect(target).digest == item.after, try markerMatches(target, item.afterMarker) else { throw fail("An adopted folder was edited during recovery. Its staged backup was kept for review.") }
                if exists(stage), item.existed {
                    guard try BackendSkillVersionFiles.inspect(stage).digest == item.before, try markerMatches(stage, item.beforeMarker) else { throw fail("The adoption backup was edited. It was kept for review.") }
                }
            } else if item.existed {
                if try BackendSkillVersionFiles.inspect(target).digest == item.after, exists(stage), try BackendSkillVersionFiles.inspect(stage).digest == item.before {
                    guard try markerMatches(target, item.afterMarker), try markerMatches(stage, item.beforeMarker) else { throw fail("Mirror ownership changed during recovery. Both folders were kept.") }
                    try BackendSkillVersionFiles.exchange(target, stage)
                }
                guard try BackendSkillVersionFiles.inspect(target).digest == item.before, try markerMatches(target, item.beforeMarker) else { throw fail("An interrupted skill was edited. Its operation and backup were kept for review.") }
            } else if exists(target) {
                guard item.afterMarker != nil, try markerMatches(target, item.afterMarker), try BackendSkillVersionFiles.inspect(target).digest == item.after else { throw fail("The new mirror is not owned by this adoption. It was kept for review.") }
                try FileManager.default.removeItem(at: target)
            }
            if exists(stage) { try FileManager.default.removeItem(at: stage) }
        }
        if !journal.committed {
            if let previous = journal.previous { try put(previous, home.appendingPathComponent("adopted.json")) }
            else if exists(home.appendingPathComponent("adopted.json")) { try FileManager.default.removeItem(at: home.appendingPathComponent("adopted.json")) }
        }
        try FileManager.default.removeItem(at: file)
    }
    public func adopt(source: URL, version id: String, expected: String, guard effect: BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue {
        guard writable, !busy else { throw fail("Skill history is read-only or busy.") }; busy = true; defer { busy = false }
        try await effect.verify()
        guard let identity = try identity(source, create: false) else { throw fail("Save a version first.") }
        let home = directory(identity), mirror = BackendSkillsMirror.counterpart(of: source)
        guard try BackendSkillVersionFiles.inspect(source).digest == expected else { throw fail("The skill changed. Refresh before adopting; nothing was overwritten.") }
        let recovering = exists(home.appendingPathComponent("operation.json"))
        try recover(home, source: source, mirror: mirror)
        let current = try BackendSkillVersionFiles.inspect(source), (record, tree) = try verified(id, in: home)
        guard current.digest == expected else { throw fail(recovering ? "The interrupted adoption was rolled back. Refresh before choosing a version." : "The skill changed. Refresh before adopting; nothing was overwritten.") }
        let findings = BackendSkillVersionFiles.findings(tree, command: source.lastPathComponent)
        guard findings.isEmpty else { throw fail("This saved package cannot be adopted: " + findings.joined(separator: " ")) }
        let currentName = SkillCommandNames.headerName(String(decoding: current.data["SKILL.md"] ?? Data(), as: UTF8.self)) ?? source.lastPathComponent
        guard record.commandName == currentName else { throw fail("This version uses a different skill name. History is retained after rename. Use a version saved after the rename, or rename back before adopting this one.") }
        var targets = [source]
        var mirrorMarker: String?
        if let mirror {
            // Refuse linked ancestors and any unowned or edited AI copy.
            for parent in [mirror.deletingLastPathComponent().deletingLastPathComponent(), mirror.deletingLastPathComponent()] where exists(parent) {
                guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw fail("The shared AI skills folder is linked; adoption was refused.") }
            }
            if exists(mirror) {
                mirrorMarker = try BackendSkillVersionFiles.markerIdentity(mirror)
                let marker = mirror.appendingPathComponent(BackendSkillsMirror.marker)
                guard exists(marker), try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true, try marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      try BackendSkillVersionFiles.inspect(mirror).digest == current.digest else { throw fail("The AI mirror is unowned or differs from this skill. Reconcile it first; neither copy was overwritten.") }
            }
            targets.append(mirror)
        }
        let previous = try adoption(home)
        let checkpoint = current.digest == tree.digest ? nil : try save(current, label: "Before adoption · " + String(record.id.prefix(8)), command: currentName, home: home).id
        var swaps: [Swap] = []
        defer { if !exists(home.appendingPathComponent("operation.json")) { for item in swaps { try? FileManager.default.removeItem(atPath: item.stage) } } }
        for target in targets {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stage = target.deletingLastPathComponent().appendingPathComponent(".td-skill-version-" + UUID().uuidString)
            try BackendSkillVersionFiles.write(tree, to: stage)
            if target != source { try Data("Terminal Deck version mirror of \(source.path)\n".utf8).write(to: stage.appendingPathComponent(BackendSkillsMirror.marker)) }
            swaps.append(.init(target: target.path, stage: stage.path, existed: exists(target), before: exists(target) ? current.digest : "", after: tree.digest, beforeMarker: target == source ? nil : mirrorMarker, afterMarker: target == source ? nil : try BackendSkillVersionFiles.markerIdentity(stage)))
        }
        try await effect.verify()
        guard try BackendSkillVersionFiles.inspect(source).digest == expected else { throw fail("The skill changed during adoption; its current edits were kept.") }
        for item in swaps {
            let target = URL(fileURLWithPath: item.target)
            guard exists(target) == item.existed else { throw fail("A skill or mirror appeared or disappeared during adoption. Nothing was replaced.") }
            if item.existed {
                guard try BackendSkillVersionFiles.inspect(target).digest == item.before else { throw fail("A skill or mirror changed during adoption. Nothing was replaced.") }
                if let expectedMarker = item.beforeMarker {
                    guard try BackendSkillVersionFiles.markerIdentity(target) == expectedMarker else { throw fail("The AI mirror ownership marker changed. Neither copy was replaced.") }
                }
            }
        }
        var journal = Journal(source: source.path, swaps: swaps, previous: previous, committed: false)
        let journalFile = home.appendingPathComponent("operation.json"); try put(journal, journalFile)
        do {
            for item in swaps {
                if item.existed { try BackendSkillVersionFiles.exchange(URL(fileURLWithPath: item.target), URL(fileURLWithPath: item.stage)) }
                else { try FileManager.default.moveItem(atPath: item.stage, toPath: item.target) }
            }
            try put(Adoption(version: id, digest: record.digest, at: Date().timeIntervalSince1970 * 1000), home.appendingPathComponent("adopted.json"))
            journal.committed = true; try put(journal, journalFile)
            try recover(home, source: source, mirror: mirror)
        } catch {
            do { try recover(home, source: source, mirror: mirror) }
            catch { throw fail("Adoption needs recovery. The operation and old files were kept at " + journalFile.path) }
            throw error
        }
        return .object([.init("ok", .bool(true)), .init("adoptedVersion", .string(id)), .init("checkpointVersion", checkpoint.map(NativeRPCValue.string) ?? .null)])
    }
}
