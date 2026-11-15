import Foundation
import Darwin
import TerminalDeckNativeCore

extension BackendCloudBootFiles: CloudDeleteOwning {
    static let binKind = "boot"
    func deleteState() throws -> CloudDeleteState {
        if let deleteStateMade { return deleteStateMade }
        let made = try CloudDeleteState(files: state())
        deleteStateMade = made
        return made
    }
    func rootAvailable(_ place: BackendCloudBootFilesPlace) -> Bool {
        guard let descriptor = BackendCloudBootFilesDisk.openRoot(place.root) else { return false }
        defer { close(descriptor) }
        guard let names = BackendCloudBootFilesDisk.names(in: descriptor) else { return false }
        let known = (try? state().first("SELECT 1 FROM boot_base WHERE source_id=? LIMIT 1", [.text(place.sourceId)])) != nil
        return !names.isEmpty || !known
    }
    static func deletePlace(_ sourceId: String, _ relative: String) -> String { sourceId + "\n" + relative }
    func deleteItem(_ sourceId: String, _ relative: String) -> CloudDeleteItem {
        let key = Self.deletePlace(sourceId, relative)
        return .init(id: key, kind: Self.binKind, name: CloudVersionReplacedLine.fileName(relative), place: key)
    }
    func route(_ item: CloudDeleteItem) throws -> (String, String) {
        let bits = item.id.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard bits.count == 2, let parsed = Self.parse(sourceId: bits[0]),
              CloudBootFilesRules.refusal(kind: parsed.kind, relative: bits[1]) == nil else { throw CloudFailure.invalidRequest }
        return (bits[0], bits[1])
    }
    func target(_ item: CloudDeleteItem) throws -> (BackendCloudBootFilesPlace, String) {
        let (sourceId, relative) = try route(item)
        guard let place = places[sourceId] else { throw CloudFailure.invalidRequest }
        return (place, relative)
    }
    func binGroup(_ intent: CloudDeleteIntent, sourceId: String, relative: String) async -> CloudBinGroup {
        let name = await macName(intent.mac.lowercased()) ?? (intent.mac.lowercased() == deviceId ? "This Mac" : "Another of your devices")
        return .init(id: intent.group, by: intent.by, macName: name, session: intent.session, agent: intent.agent, at: intent.at,
                     items: [deleteItem(sourceId, relative)])
    }
    /// One safety copy of the carried instruction files, not the rest of a project or AI home.
    func ensureBootSafety(_ place: BackendCloudBootFilesPlace) throws -> Bool {
        let key = "delete-safety:" + place.sourceId
        if let made = try state().first("SELECT value FROM boot_meta WHERE key=?", [.text(key)])?.int(0) {
            let stamp = BackendCloudFolder.safetyStamp.string(from: Date(timeIntervalSince1970: Double(made) / 1000))
            if FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("safety/" + stamp + "/" + place.sourceId).path) { return true }
        }
        let walk = BackendCloudBootFilesDisk.walk(root: place.root, kind: place.kind)
        guard walk.reliable, rootAvailable(place) else { return false }
        let stamp = BackendCloudFolder.safetyStamp.string(from: Date(timeIntervalSince1970: Double(now()) / 1000))
        let top = stateRoot.appendingPathComponent("safety/" + stamp, isDirectory: true)
        let target = top.appendingPathComponent(place.sourceId, isDirectory: true)
        let fm = FileManager.default
        do {
            for entry in walk.files {
                guard case .file(let bytes) = BackendCloudBootFilesDisk.read(root: place.root, relative: entry.relative),
                      BackendCloudBrainMemoryHash.bytes(bytes) == entry.hash else { return false }
                let file = target.appendingPathComponent(entry.relative)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try bytes.write(to: file, options: .atomic)
            }
            // Even an empty carried set gets a real safety directory before the completion mark.
            try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try state().run("INSERT OR REPLACE INTO boot_meta(key,value) VALUES (?,?)", [.text(key), .int(now())])
            return true
        } catch {
            CloudSyncDiagnostics.shared.info("instruction files: safety copy could not be made; files kept")
            return false
        }
    }
    func deleteOutbox(_ base: any CloudOutboxPort) -> CloudFileDeleteOutbox {
        CloudFileDeleteOutbox(base: base, expand: { [weak self] operations in
            guard let self else { throw CloudFailure.unavailable }
            return try await self.travelOperations(operations)
        })
    }
    /// Review 15 Nov (decision 6 as changed): the gate is read again at send time and the queue never waits for it.
    /// Closed: "Everywhere" goes now in the old compatible form; "Cloud" is withdrawn (`withdrawBootCloudRemovals`).
    func travelOperations(_ operations: [CloudOperation]) async throws -> [CloudOperation] {
        var expanded: [CloudOperation] = []
        for operation in operations {
            if operation.kind == .archive {
                let item = try Self.describe(operation), key = Self.deletePlace(item.sourceId, item.relative)
                let intent = try CloudFileDeleteRecords.intent(for: operation, place: key, in: state())
                if intent == nil, try state().first("SELECT 1 FROM file_delete_sending WHERE place=?", [.text(key)]) != nil {
                    // Never attach a newer delete's intent to an older journal entry at the same path.
                    // The owner wakes this same pump again as soon as the exact operation id is bound.
                    throw CloudFailure.unavailable
                }
                if let intent {
                    if try CloudFileDeleteRecords.isWithdrawn(operation, in: state()) { continue }
                    if await deleteRuleOpen() { expanded.append(try CloudFileDeleteRecords.operation(operation, intent: intent)) }
                    else if intent.scope == .cloud {
                        try CloudFileDeleteRecords.withdraw(operation, place: key, parents: item.parents, in: state())
                        continue
                    }
                }
            }
            expanded.append(operation)
        }
        return expanded
    }
    func rememberBootRemoval(_ place: BackendCloudBootFilesPlace, _ relative: String, engine: BackendCloudBrainFiles) async throws {
        let key = Self.deletePlace(place.sourceId, relative)
        if let row = try state().first("SELECT body,after_seq FROM file_delete_sending WHERE place=?", [.text(key)]), let bytes = row.data(0) {
            let intent = try JSONDecoder().decode(CloudDeleteIntent.self, from: bytes)
            var sequence = row.int(1), found = false
            while let resource = try await engine.journalResource(after: sequence) {
                sequence = resource.sequence
                guard resource.sourceId == place.sourceId, resource.relative == relative, resource.kind == .archive else { continue }
                let (operation, _) = try await engine.operation(resource, index: 0)
                try CloudFileDeleteRecords.saveAbout(CloudFileDeleteRecords.operation(operation, intent: intent), signer: deviceId, in: state())
                found = true
                break
            }
            guard found else { throw CloudFailure.unavailable }
        }
        try state().run("DELETE FROM file_delete_sending WHERE place=?", [.text(key)])
        engine.hub.post()
    }
    /// The single-item removal (review 15 Nov, MUST 1): its intent is written HERE; any failure before the engine has
    /// journaled the removal clears it and undoes what was done, so a press that showed an error can never delete
    /// anything afterwards. Only a crash past the Bin step leaves an intent that a restart resumes.
    /// `wasHere`: his file was there when the act began (false for a removal an AI already made in the folder).
    func removeBoot(_ place: BackendCloudBootFilesPlace, _ relative: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles,
                    wasHere: Bool = true) async throws {
        guard rootAvailable(place), CloudBootFilesRules.refusal(kind: place.kind, relative: relative) == nil else { throw CloudFailure.unavailable }
        if intent.scope == .cloud, !(await deleteRuleOpen()) { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        let key = Self.deletePlace(place.sourceId, relative)
        try CloudFileDeleteRecords.forgetCleared(key, in: state())
        try deleteState().putIntent(intent)
        do { try await journalBoot(place, relative, intent: intent, engine: engine) }
        catch {
            if try await engine.currentVersion(sourceId: place.sourceId, relative: relative) == nil,
               try CloudFileDeleteRecords.binned(place: key, in: state()) != nil {
                await finishBootJournaled(place, relative, intent: intent, engine: engine)
                return
            }
            await abandonBoot(place, relative, scope: intent.scope, engine: engine, restoreLocal: wasHere)
            throw error
        }
    }
    func abandonBoot(_ place: BackendCloudBootFilesPlace, _ relative: String, scope: CloudDeleteScope, engine: BackendCloudBrainFiles,
                     restoreLocal: Bool) async {
        let key = Self.deletePlace(place.sourceId, relative)
        // Final look (point 2): markers cleared LAST; a failed undo is recorded and run again by the next recovery.
        do {
            try state().run("INSERT OR REPLACE INTO file_delete_undo(place,scope,restore) VALUES (?,?,?)",
                            [.text(key), .text(scope.rawValue), .int(restoreLocal ? 1 : 0)])
            let binned = try CloudFileDeleteRecords.binned(place: key, in: state())
            if let binned, try await engine.currentVersion(sourceId: place.sourceId, relative: relative) != nil {
                let bytes = keeper().content(kind: Self.binKind, sha256: binned)
                if case .absent = BackendCloudBootFilesDisk.read(root: copy(place.sourceId), relative: relative), let bytes {
                    try BackendCloudBootFilesDisk.create(root: copy(place.sourceId), relative: relative, bytes: bytes)
                }
                if scope == .everywhere, restoreLocal, case .absent = BackendCloudBootFilesDisk.read(root: place.root, relative: relative), let bytes {
                    try BackendCloudBootFilesDisk.create(root: place.root, relative: relative, bytes: bytes)
                }
                if case .file = BackendCloudBootFilesDisk.read(root: place.root, relative: relative),
                   try keeper().bin(itemKey: Self.itemKey(place.sourceId, relative))?.sha256 == binned {
                    try keeper().binTake(itemKey: Self.itemKey(place.sourceId, relative), now: now())
                    try state().run("DELETE FROM file_delete_bin WHERE place=?", [.text(key)])
                }
            }
            try deleteState().clearIntent(at: key)
            try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(key)])
            try state().run("DELETE FROM file_delete_sending WHERE place=?", [.text(key)])
            try state().run("DELETE FROM file_delete_undo WHERE place=?", [.text(key)])
        } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
    }
    func journalBoot(_ place: BackendCloudBootFilesPlace, _ relative: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles) async throws {
        let modern = await deleteRuleOpen()
        if intent.scope == .cloud, !modern { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        let key = Self.deletePlace(place.sourceId, relative)
        if let current = try await engine.currentVersion(sourceId: place.sourceId, relative: relative) {
            var retained: Data?
            if case .file(let copy) = BackendCloudBootFilesDisk.read(root: self.copy(place.sourceId), relative: relative) { retained = copy }
            else if let binned = try keeper().bin(itemKey: Self.itemKey(place.sourceId, relative)), binned.sha256 == current.rawHash,
                    let bytes = keeper().content(kind: Self.binKind, sha256: binned.sha256) {
                retained = bytes
                try BackendCloudBootFilesDisk.create(root: self.copy(place.sourceId), relative: relative, bytes: bytes)
            }
            guard let copy = retained, BackendCloudBrainMemoryHash.bytes(copy) == current.rawHash else { throw CloudFailure.unavailable }
            let local = BackendCloudBootFilesDisk.read(root: place.root, relative: relative)
            if case .blocked = local { throw CloudFailure.unsafeConfiguration }
            if intent.scope == .everywhere, case .file(let bytes) = local, BackendCloudBrainMemoryHash.bytes(bytes) != current.rawHash { throw CloudFailure.versionChanged }
            guard try ensureBootSafety(place) else { throw CloudFailure.unavailable }
            try keeper().binPut(kind: Self.binKind, itemKey: Self.itemKey(place.sourceId, relative), name: CloudVersionReplacedLine.fileName(relative),
                place: nil, path: key, removedAt: intent.at, device: intent.mac, content: copy, shown: true, now: now())
            try CloudFileDeleteRecords.rememberBin(await binGroup(intent, sourceId: place.sourceId, relative: relative), place: key, in: state())
            try state().run("INSERT OR REPLACE INTO file_delete_binned(place,hash) VALUES (?,?)", [.text(key), .text(current.rawHash)])
            try crashPointForTests?("press:afterBin")
            if modern {
                let after = try await engine.snapshotBegin()
                try state().run("INSERT OR REPLACE INTO file_delete_sending(place,body,after_seq) VALUES (?,?,?)", [.text(key), .blob(try JSONEncoder().encode(intent)), .int(after)])
            }
            if intent.scope == .everywhere, case .file = local {
                try BackendCloudBootFilesDisk.removeCopy(root: place.root, relative: relative, expecting: current.rawHash)
            }
            try BackendCloudBootFilesDisk.removeCopy(root: self.copy(place.sourceId), relative: relative, expecting: current.rawHash)
            try crashPointForTests?("press:afterCopy")
            while try await engine.reconcile(sourceId: place.sourceId, paths: [relative], limit: 4096).remaining {}
            guard try await engine.currentVersion(sourceId: place.sourceId, relative: relative) == nil else { throw CloudFailure.unavailable }
        } else {
            // Nothing in the Cloud: only a journaled removal of this act is finished; an item never in the Cloud is refused.
            guard try CloudFileDeleteRecords.binned(place: key, in: state()) != nil else { throw CloudFailure.unavailable }
        }
        await finishBootJournaled(place, relative, intent: intent, engine: engine)
    }
    /// After the engine journaled the removal. Never an error for the person; what fails stays for the next refresh.
    func finishBootJournaled(_ place: BackendCloudBootFilesPlace, _ relative: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles) async {
        let key = Self.deletePlace(place.sourceId, relative)
        do {
            try await rememberBootRemoval(place, relative, engine: engine)
            try setBase(place.sourceId, relative, nil)
            // Point 9: "Only on this Mac" only where this Mac has the file.
            if intent.scope == .cloud, case .file = BackendCloudBootFilesDisk.read(root: place.root, relative: relative) {
                try deleteState().putMark(.init(place: key, mark: .onlyOnThisMac, at: intent.at))
            } else { try deleteState().clearMark(at: key) }
            try deleteState().clearIntent(at: key)
            try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(key)])
        } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
    }
    /// One press or tool call, one group; each item on its own (one that fails never stops the rest). Throws only when
    /// nothing could be removed.
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        await enter(); defer { leave() }
        if scope == .cloud, !(await deleteRuleOpen()) { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        let engine = try core()
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count else { throw CloudFailure.invalidRequest }
        await finishBootArrivals(engine: engine)
        var removed: [CloudDeleteItem] = [], failed: [String] = [], first: Error?
        for item in items {
            do {
                try CloudFileDeleteRecords.setRowError(item.id, nil, at: now(), in: state())
                let (place, path) = try target(item)
                // An explicit delete names this Mac's current bytes, including an edit that has not travelled yet.
                if scope == .everywhere, case .file(let local) = BackendCloudBootFilesDisk.read(root: place.root, relative: path) {
                    let mirror = copy(place.sourceId)
                    switch BackendCloudBootFilesDisk.read(root: mirror, relative: path) {
                    case .blocked: throw CloudFailure.unsafeConfiguration
                    case .absent: try BackendCloudBootFilesDisk.create(root: mirror, relative: path, bytes: local)
                    case .file(let bytes):
                        let hash = BackendCloudBrainMemoryHash.bytes(bytes)
                        if bytes != local {
                            try keep(bytes, hash: hash, sourceId: place.sourceId, relative: path, device: deviceId, at: now())
                            try BackendCloudBootFilesDisk.replace(root: mirror, relative: path, bytes: local, expecting: hash)
                        }
                    }
                    while try await engine.reconcile(sourceId: place.sourceId, paths: [path], limit: 4096).remaining {}
                }
                try deleteState().clearMark(at: Self.deletePlace(place.sourceId, path))
                try await removeBoot(place, path, intent: actor.intent(place: Self.deletePlace(place.sourceId, path), scope: scope), engine: engine)
                removed.append(item)
            } catch {
                first = first ?? error
                failed.append(item.name)
                // The answer names what was not removed: the page reads it per row from `rowErrors()`.
                try? CloudFileDeleteRecords.setRowError(item.id, CloudFileDeleteRecords.notRemovedLine, at: now(), in: state())
            }
        }
        if !failed.isEmpty {
            CloudSyncDiagnostics.shared.info("instruction files delete: \(removed.count) removed, not removed: " + CloudFolderFormat.names(failed))
        }
        if removed.isEmpty, let first { throw first }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: removed)
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        try deleteState().marks().compactMap { mark in
            let bits = mark.place.split(separator: "\n", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { return nil }
            return .init(item: deleteItem(bits[0], bits[1]), mark: mark.mark, at: mark.at)
        }
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        await enter(); defer { leave() }
        let engine = try core()
        await finishBootArrivals(engine: engine)
        for item in items {
            let (place, relative) = try target(item)
            guard rootAvailable(place) else { throw CloudFailure.unavailable }
            try CloudFileDeleteRecords.setRowError(item.id, nil, at: now(), in: state())
            try CloudFileDeleteRecords.forgetCleared(item.id, in: state())
            let mirror = copy(place.sourceId)
            if to == .cloud {
                guard case .file(let bytes) = BackendCloudBootFilesDisk.read(root: place.root, relative: relative) else { throw CloudFailure.unavailable }
                if case .file(let held) = BackendCloudBootFilesDisk.read(root: mirror, relative: relative) {
                    try BackendCloudBootFilesDisk.replace(root: mirror, relative: relative, bytes: bytes, expecting: BackendCloudBrainMemoryHash.bytes(held))
                } else { try BackendCloudBootFilesDisk.create(root: mirror, relative: relative, bytes: bytes) }
                try setBase(place.sourceId, relative, BackendCloudBrainMemoryHash.bytes(bytes))
                let before = try await engine.currentVersion(sourceId: place.sourceId, relative: relative)?.version
                while try await engine.reconcile(sourceId: place.sourceId, paths: [relative], limit: 4096).remaining {}
                if try await engine.currentVersion(sourceId: place.sourceId, relative: relative)?.version == before {
                    _ = try await engine.resend(sourceId: place.sourceId, relative: relative)
                }
                try deleteState().clearMark(at: item.id)
            } else {
                guard case .file(let bytes) = BackendCloudBootFilesDisk.read(root: mirror, relative: relative) else { throw CloudFailure.unavailable }
                switch BackendCloudBootFilesDisk.read(root: place.root, relative: relative) {
                case .blocked: throw CloudFailure.unsafeConfiguration
                case .absent: try BackendCloudBootFilesDisk.create(root: place.root, relative: relative, bytes: bytes)
                case .file(let held):
                    guard try ensureBootSafety(place) else { throw CloudFailure.unavailable }
                    try keep(held, hash: BackendCloudBrainMemoryHash.bytes(held), sourceId: place.sourceId, relative: relative, device: deviceId, at: now())
                    try BackendCloudBootFilesDisk.replace(root: place.root, relative: relative, bytes: bytes, expecting: BackendCloudBrainMemoryHash.bytes(held))
                }
                try deleteState().clearMark(at: item.id)
                try setBase(place.sourceId, relative, BackendCloudBrainMemoryHash.bytes(bytes))
            }
            try keeper().binTake(itemKey: Self.itemKey(place.sourceId, relative), now: now())
        }
        return items
    }
    /// One line per row whose delete did not happen, by item id (see `BackendCloudFolder.rowErrors`).
    public func rowErrors() throws -> [String: String] { try CloudFileDeleteRecords.rowErrors(in: state()) }
    /// Decision 6 as changed: a "Cloud" removal withdrawn at send time; the file is put back in sync (copy and engine on
    /// top of the version the other Macs hold), its mark, Bin entry and intent go. A place not mapped now waits.
    func withdrawBootCloudRemovals(engine: BackendCloudBrainFiles) async {
        do {
            for row in try state().rows("SELECT operation,place,parents FROM file_delete_withdrawn WHERE done=0") {
                let key = row.text(1)
                let bits = key.split(separator: "\n", maxSplits: 1).map(String.init)
                do {
                    guard bits.count == 2, let place = places[bits[0]], rootAvailable(place) else { continue }
                    let relative = bits[1], mirror = copy(place.sourceId)
                    if try await engine.currentVersion(sourceId: place.sourceId, relative: relative) == nil {
                        var bytes: Data?, here = false
                        if case .file(let local) = BackendCloudBootFilesDisk.read(root: place.root, relative: relative) { bytes = local; here = true }
                        else if let kept = try keeper().bin(itemKey: Self.itemKey(place.sourceId, relative)) { bytes = keeper().content(kind: Self.binKind, sha256: kept.sha256) }
                        if let bytes {
                            if case .absent = BackendCloudBootFilesDisk.read(root: mirror, relative: relative) {
                                try BackendCloudBootFilesDisk.create(root: mirror, relative: relative, bytes: bytes)
                            }
                            await engine.setNextParents(sourceId: place.sourceId, relative: relative, parents: BackendCloudBrainFiles.strings(row.text(2)))
                            try setBase(place.sourceId, relative, BackendCloudBrainMemoryHash.bytes(bytes))
                            if here { try deleteState().clearMark(at: key) }
                            else { try deleteState().putMark(.init(place: key, mark: .notOnThisMac, at: now())) }
                            while try await engine.reconcile(sourceId: place.sourceId, paths: [relative], limit: 4096).remaining {}
                        }
                        if try keeper().bin(itemKey: Self.itemKey(place.sourceId, relative)) != nil {
                            try keeper().binTake(itemKey: Self.itemKey(place.sourceId, relative), now: now())
                        }
                        try state().run("DELETE FROM file_delete_bin WHERE place=?", [.text(key)])
                    }
                    try deleteState().clearIntent(at: key)
                    try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(key)])
                    try CloudFileDeleteRecords.setRowError(key, CloudDeleteWords.cloudNeedsUpdatedMacs, at: now(), in: state())
                    try state().run("UPDATE file_delete_withdrawn SET done=1 WHERE operation=?", [.text(row.text(0))])
                } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
            }
        } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
    }
    public func binGroups() async throws -> [CloudBinGroup] {
        var groups: [CloudBinGroup] = []
        for item in try keeper().binList(kind: Self.binKind) {
            if let group = try CloudFileDeleteRecords.group(place: item.path, in: state()) { groups.append(group) }
            else {
                let name = await macName(item.device.lowercased()) ?? "Another of your devices"
                let bits = item.path.split(separator: "\n", maxSplits: 1).map(String.init)
                guard bits.count == 2 else { continue }
                groups.append(CloudFileDeleteRecords.legacyGroup(item: deleteItem(bits[0], bits[1]), mac: item.device, macName: name,
                    at: item.removedAt, era: .beforeNewRule))
            }
        }
        return CloudFileDeleteRecords.merge(groups)
    }
    /// "Put back all" (review 15 Nov, point 11): every item of the group; a project that is not mapped here (or whose
    /// folder is not reachable) fails for its own items only, named in the log, and the rest go on. A project folder
    /// that moved is reached through its mapping (the source id names the project, not the folder). Answers what came back.
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        await enter(); defer { leave() }
        guard let held = try await binGroups().first(where: { $0.id == group }) else { return [] }
        let engine = try core()
        var restored: [CloudDeleteItem] = [], failed: [String] = []
        for item in held.items {
            do {
                let (place, relative) = try target(item)
                guard rootAvailable(place), let kept = try keeper().bin(itemKey: Self.itemKey(place.sourceId, relative)),
                      let bytes = keeper().content(kind: Self.binKind, sha256: kept.sha256) else { throw CloudFailure.unavailable }
                switch BackendCloudBootFilesDisk.read(root: place.root, relative: relative) {
                case .blocked: throw CloudFailure.unsafeConfiguration
                case .absent: try BackendCloudBootFilesDisk.create(root: place.root, relative: relative, bytes: bytes)
                case .file(let current):
                    guard try ensureBootSafety(place) else { throw CloudFailure.unavailable }
                    try keep(current, hash: BackendCloudBrainMemoryHash.bytes(current), sourceId: place.sourceId, relative: relative, device: deviceId, at: now())
                    try BackendCloudBootFilesDisk.replace(root: place.root, relative: relative, bytes: bytes, expecting: BackendCloudBrainMemoryHash.bytes(current))
                }
                try deleteState().clearMark(at: item.id)
                try await settlePaths(place, [relative], engine: engine)
                try keeper().binTake(itemKey: Self.itemKey(place.sourceId, relative), now: now())
                restored.append(item)
            } catch { failed.append(item.name) }
        }
        if !failed.isEmpty {
            CloudSyncDiagnostics.shared.info("instruction files Put back all: \(restored.count) back, not back: " + CloudFolderFormat.names(failed))
        }
        return restored
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        await enter(); defer { leave() }
        for item in items {
            let (sourceId, relative) = try route(item)
            try CloudFileDeleteRecords.deleteForGood(keeper(), itemKey: Self.itemKey(sourceId, relative))
            try state().run("DELETE FROM file_delete_bin WHERE place=?", [.text(item.id)])
        }
    }
    /// Resumes ONLY removals already past the Bin step; drops one that never reached it, one whose file or Cloud version
    /// changed since (his newer bytes win), and one whose place no longer exists. Each on its own (MUST 1, 2).
    func recoverBootIntents(engine: BackendCloudBrainFiles) async {
        let rows: [DeckMemoryRow]
        do { rows = try state().rows("SELECT place FROM cloud_delete_intents") }
        catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error); return }
        for row in rows {
            let key = row.text(0)
            let bits = key.split(separator: "\n", maxSplits: 1).map(String.init)
            do {
                guard let intent = try deleteState().intent(at: key) else { continue }
                guard bits.count == 2, let place = places[bits[0]], CloudBootFilesRules.refusal(kind: place.kind, relative: bits[1]) == nil,
                      let binned = try CloudFileDeleteRecords.binned(place: key, in: state()) else {
                    try deleteState().clearIntent(at: key)
                    try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(key)])
                    CloudSyncDiagnostics.shared.info("instruction files delete rule: an unfinished delete that cannot be finished here was dropped; nothing was removed")
                    continue
                }
                guard rootAvailable(place) else { continue }
                // An undo that failed half-way is finished, never the delete it undoes.
                if let undo = try CloudFileDeleteRecords.undoPending(key, in: state()) {
                    await abandonBoot(place, bits[1], scope: undo.scope, engine: engine, restoreLocal: undo.restore); continue
                }
                let local = BackendCloudBootFilesDisk.read(root: place.root, relative: bits[1])
                if case .blocked = local { continue }
                if let current = try await engine.currentVersion(sourceId: place.sourceId, relative: bits[1]) {
                    var changed = current.rawHash != binned
                    if intent.scope == .everywhere, case .file(let bytes) = local, BackendCloudBrainMemoryHash.bytes(bytes) != binned { changed = true }
                    if case .file(let copy) = BackendCloudBootFilesDisk.read(root: self.copy(place.sourceId), relative: bits[1]),
                       BackendCloudBrainMemoryHash.bytes(copy) != binned { changed = true }
                    if changed {
                        await abandonBoot(place, bits[1], scope: intent.scope, engine: engine, restoreLocal: false)
                        CloudSyncDiagnostics.shared.info("instruction files delete rule: an unfinished delete was dropped because the file changed since; it is kept")
                        continue
                    }
                }
                do { try await journalBoot(place, bits[1], intent: intent, engine: engine) }
                catch {
                    if (try? await engine.currentVersion(sourceId: place.sourceId, relative: bits[1])) == nil { continue }
                    await abandonBoot(place, bits[1], scope: intent.scope, engine: engine, restoreLocal: false)
                    CloudSyncDiagnostics.shared.info("instruction files delete rule: an unfinished delete could not be finished and was dropped; nothing more was removed")
                }
            } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
        }
    }
    /// A removal that arrived without a mapped/reachable root is retried when that root comes back. Each on its own:
    /// one that fails waits, one that can never apply is dropped with one log line (MUST 2).
    func retryBootRemovals(_ place: BackendCloudBootFilesPlace, engine: BackendCloudBrainFiles) async {
        guard rootAvailable(place) else { return }
        do {
            for head in try CloudFileDeleteRecords.heads(in: state(), label: "instruction files") {
                let bits = head.place.split(separator: "\n", maxSplits: 1).map(String.init)
                guard bits.count == 2, bits[0] == place.sourceId else { continue }
                do { try await applyBootHead(head, place: place, relative: bits[1], engine: engine) }
                catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
            }
        } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
    }
    func applyBootHead(_ head: CloudFileDeleteRecords.Head, place: BackendCloudBootFilesPlace, relative: String, engine: BackendCloudBrainFiles) async throws {
        func drop(_ why: String) throws {
            try CloudFileDeleteRecords.dropHead(place: head.place, in: state())
            CloudSyncDiagnostics.shared.info("instruction files delete rule: an arrived removal was dropped (\(why)); nothing was removed")
        }
        guard CloudBootFilesRules.refusal(kind: place.kind, relative: relative) == nil else { return try drop("not an instruction file") }
        guard let current = try await engine.currentVersion(sourceId: place.sourceId, relative: relative) else {
            return try drop("it was never in the Cloud on this Mac")
        }
        guard head.parents.contains(current.version) else { return }
        let travel: CloudDeleteTravelRemoval
        do { travel = try head.travel } catch { return try drop("it could not be read") }
        let mirror = copy(place.sourceId)
        var cloudOnly = false
        if case .intent(let intent) = travel { cloudOnly = intent.scope == .cloud }
        let local = BackendCloudBootFilesDisk.read(root: place.root, relative: relative)
        if case .blocked = local { return }
        if !cloudOnly, case .file(let bytes) = local, BackendCloudBrainMemoryHash.bytes(bytes) != current.rawHash { return }
        guard try ensureBootSafety(place), let bytes = await engine.retainedBytes(current.rawHash) else { return }
        try keeper().binPut(kind: Self.binKind, itemKey: Self.itemKey(place.sourceId, relative), name: CloudVersionReplacedLine.fileName(relative),
            place: nil, path: head.place, removedAt: head.at, device: head.mac, content: bytes, shown: true, now: now())
        let group: CloudBinGroup
        if case .intent(let intent) = travel { group = await binGroup(intent, sourceId: place.sourceId, relative: relative) }
        else {
            let name = await macName(head.mac.lowercased()) ?? "Another of your devices"
            group = CloudFileDeleteRecords.legacyGroup(item: deleteItem(place.sourceId, relative), mac: head.mac, macName: name, at: head.at, era: .olderVersion)
        }
        try CloudFileDeleteRecords.rememberBin(group, place: head.place, in: state())
        if cloudOnly {
            // Point 9: "Only on this Mac" only where this Mac has the file.
            if case .file = local { try deleteState().putMark(.init(place: head.place, mark: .onlyOnThisMac, at: head.at)) }
            else { try deleteState().clearMark(at: head.place) }
        } else {
            if case .file = local { try BackendCloudBootFilesDisk.removeCopy(root: place.root, relative: relative, expecting: current.rawHash) }
            try deleteState().clearMark(at: head.place)
        }
        // MUST 7: the private copy's removal and the engine's "removed" are one step (finished before any reconcile).
        try state().run("INSERT OR REPLACE INTO file_delete_applying(place) VALUES (?)", [.text(head.place)])
        try crashPointForTests?("arrival:beforeCopy")
        if case .file(let copy) = BackendCloudBootFilesDisk.read(root: mirror, relative: relative) {
            guard BackendCloudBrainMemoryHash.bytes(copy) == current.rawHash else {
                try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(head.place)]); return
            }
            try BackendCloudBootFilesDisk.removeCopy(root: mirror, relative: relative, expecting: current.rawHash)
        }
        try crashPointForTests?("arrival:afterCopy")
        try await finishBootHead(head, sourceId: place.sourceId, relative: relative, engine: engine)
    }
    func finishBootHead(_ head: CloudFileDeleteRecords.Head, sourceId: String, relative: String, engine: BackendCloudBrainFiles) async throws {
        try await engine.adoptRemoval(sourceId: sourceId, relative: relative, version: head.version, parents: head.parents,
            createdAt: head.at, originDevice: head.mac)
        try setBase(sourceId, relative, nil)
        try CloudFileDeleteRecords.dropHead(place: head.place, in: state())
        try state().run("DELETE FROM boot_items WHERE source_id=? AND path=?", [.text(sourceId), .text(relative)])
    }
    /// Arrived removals whose private copy was being removed when the app stopped: finished before anything reconciles.
    /// Works on the private copy only, so it needs no reachable project folder.
    func finishBootArrivals(engine: BackendCloudBrainFiles) async {
        do {
            for row in try state().rows("SELECT place FROM file_delete_applying") {
                let key = row.text(0)
                let bits = key.split(separator: "\n", maxSplits: 1).map(String.init)
                do {
                    guard bits.count == 2, let head = try CloudFileDeleteRecords.head(place: key, in: state()) else {
                        try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(key)]); continue
                    }
                    guard let current = try await engine.currentVersion(sourceId: bits[0], relative: bits[1]) else {
                        try setBase(bits[0], bits[1], nil)
                        try CloudFileDeleteRecords.dropHead(place: key, in: state())
                        continue
                    }
                    guard head.parents.contains(current.version) else {
                        try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(key)]); continue
                    }
                    let mirror = copy(bits[0])
                    if case .file(let held) = BackendCloudBootFilesDisk.read(root: mirror, relative: bits[1]) {
                        guard BackendCloudBrainMemoryHash.bytes(held) == current.rawHash else {
                            try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(key)]); continue
                        }
                        try BackendCloudBootFilesDisk.removeCopy(root: mirror, relative: bits[1], expecting: current.rawHash)
                    }
                    try await finishBootHead(head, sourceId: bits[0], relative: bits[1], engine: engine)
                } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
            }
        } catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
    }
}
