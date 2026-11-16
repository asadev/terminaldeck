import CryptoKit
import Darwin
import Foundation
import TerminalDeckNativeCore

/// One local holding format, shared by all three owners. It is the SAME AES-GCM combined form and device-local
/// key already used by project-file waiting arrivals. No credential database, Keychain item or second key is made.
/// Only ciphertext is persisted; names, dates, old bytes and removal metadata are inside it too.
final class BackendProjectSecretFilesDeleteState {
    /// Decision 4 (review 15 Nov): a removal dated after 1 Jan 2100 (service ms) is not a real one. Checked when a
    /// removal arrives and when one is made, so it can never pass the check and then fail later.
    static let latestAt: Int64 = 4_102_444_800_000
    /// Decision 8: safety copies kept per item and in all (the newest ones).
    static let safetyPerItem = 3
    static let safetyInAll = 200
    /// Decision 5: copies that arrive only inside a removal (never on this Mac) fill at most this much of the Bin.
    static let carriedRows = 2_000
    static let carriedBytes = 8 * 1024 * 1024

    struct Binned: Codable, Equatable {
        let item: CloudDeleteItem
        let actor: CloudDeleteActor
        let record: CloudSecretRecord
        let until: Int64
        /// When THIS Mac put it into the Bin (service clock); nil until that clock is known here (filled in then).
        var binnedAt: Int64?
    }
    struct Version: Codable, Equatable {
        let version: String
        let digest: String?
        let fileMark: String?
    }
    struct Safety: Codable {
        let record: CloudSecretRecord
        let at: Int64
    }
    /// One entry that cannot be read is skipped on its own (decision 8): it never makes the whole holding unreadable.
    struct Lossy<T: Codable>: Codable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
    struct Held: Codable {
        // Earlier versions need only keyed fingerprints for J-7. Old secret bytes live only in the Bin.
        var history: [String: [Version]] = [:]
        var wireHeads: [String: String]? = [:]
        var safety: [String: Safety]? = [:]
        var newest: [String: CloudSecretRecord] = [:]
        var removals: [String: CloudSecretRemoval] = [:]
        var republications: [String: String]? = [:]
        var localRemovals: [String: CloudDeleteScope]? = [:]
        var sendable: Set<String>? = []
        var bin: [String: Binned] = [:]
        /// Decision 6: only these go out in the new (versioned) form: a deliberate Put back / Put in Cloud again made
        /// here, until the item's content changes or it is removed again.
        var deliberate: Set<String>? = []
        /// Decision 10: an Everywhere removal applied while the item's project folder was not on this Mac.
        var unplaced: Set<String>? = []
        /// A "Not on this Mac" mark made by hand that an arriving removal covered; it comes back when that removal ends.
        var byHand: Set<String>? = []
        /// Entries skipped while reading (not stored).
        var skipped = 0
        enum CodingKeys: String, CodingKey {
            case history, wireHeads, safety, newest, removals, republications, localRemovals, sendable, bin, deliberate, unplaced, byHand
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var skipped = 0
            func map<T: Codable>(_ key: CodingKeys, _ type: T.Type) -> [String: T] {
                guard c.contains(key) else { return [:] }
                guard let raw = try? c.decode([String: Lossy<T>].self, forKey: key) else { skipped += 1; return [:] }
                let kept = raw.compactMapValues { $0.value }
                skipped += raw.count - kept.count
                return kept
            }
            func names(_ key: CodingKeys) -> Set<String> {
                guard c.contains(key) else { return [] }
                guard let value = try? c.decode(Set<String>.self, forKey: key) else { skipped += 1; return [] }
                return value
            }
            history = map(.history, [Version].self)
            wireHeads = map(.wireHeads, String.self)
            safety = map(.safety, Safety.self)
            newest = map(.newest, CloudSecretRecord.self)
            removals = map(.removals, CloudSecretRemoval.self)
            republications = map(.republications, String.self)
            localRemovals = map(.localRemovals, CloudDeleteScope.self)
            sendable = names(.sendable)
            bin = map(.bin, Binned.self)
            deliberate = names(.deliberate)
            unplaced = names(.unplaced)
            byHand = names(.byHand)
            self.skipped = skipped
        }
    }
    let root: URL
    let source: String
    private var keys: CloudSecretsStoreKeys?
    private var file: URL?
    private var held = Held()
    private var db: BackendCloudBrainFilesDatabase?
    private(set) var problem = false
    /// Decision 8: one fixed line when part of the Bin could not be read and was set aside.
    private(set) var notice: String?
    /// Tests only: makes the next sealed saves fail (decision 2's failing case).
    var failSaves = false
    init(root: URL, source: String) { self.root = root; self.source = source }

    func use(_ keys: CloudSecretsStoreKeys?) {
        guard let keys else {
            self.keys = nil; file = nil; held = Held(); db = nil; problem = false; notice = nil
            return
        }
        let slot = keys.shared(Data(("delete-rule\n" + source).utf8))
        let file = root.appendingPathComponent(slot + ".sealed")
        if self.file == file, self.keys != nil { return }
        self.keys = keys; self.file = file; held = Held(); db = nil; problem = false; notice = nil
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { problem = true; return }
        // Decision 8: a sealed holding that cannot be opened is set aside (renamed beside it, never deleted) and a fresh
        // one starts; single entries that cannot be read are skipped. Neither ever looks like "locked".
        do {
            if let data = try BackendAccountFiles.boundedRead(file, maximum: Int.max) {
                held = try JSONDecoder().decode(Held.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: keys.local))
                if held.skipped > 0 { notice = BackendProjectSecretFilesWords.binDamaged }
            }
        } catch {
            held = Held(); Self.setAside(file); notice = BackendProjectSecretFilesWords.binDamaged
        }
        let path = root.appendingPathComponent(slot + ".sqlite")
        if let made = Self.openState(path) { db = made }
        else {
            for suffix in ["", "-wal", "-shm", "-journal"] { Self.setAside(URL(fileURLWithPath: path.path + suffix)) }
            db = Self.openState(path)
            notice = BackendProjectSecretFilesWords.binDamaged
        }
        guard db != nil else { problem = true; return }
        // Decision 2: an intent never outlives the action that wrote it. One left by a crash or a sign-out in the
        // middle of a delete is dropped here, so a later disappearance of that file is only ever a by-hand mark.
        var places = Set(held.newest.keys).union(held.removals.keys)
        for row in held.bin.values { places.insert(row.item.id) }
        for place in places { try? state().clearIntent(at: place) }
    }
    private static func openState(_ path: URL) -> BackendCloudBrainFilesDatabase? {
        guard let made = try? BackendCloudBrainFilesDatabase(path: path.path, engineTables: false),
              chmod(path.path, 0o600) == 0, (try? CloudDeleteState(files: made)) != nil else { return nil }
        return made
    }
    private static func setAside(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        _ = rename(url.path, url.path + ".unreadable-" + String(Int64(Date().timeIntervalSince1970 * 1000)))
    }
    /// Locked only when the saved-passwords key is not here. A Bin that could not be made at all is "unavailable".
    func ready() throws {
        guard keys != nil, file != nil else { throw CloudFailure.secretsLocked }
        guard !problem, db != nil else { throw CloudFailure.unavailable }
    }
    private func state() throws -> CloudDeleteState {
        try ready()
        guard let db else { throw CloudFailure.unavailable }
        return try CloudDeleteState(files: db)
    }
    func save() throws {
        try ready()
        guard !failSaves else { throw CloudFailure.unavailable }
        guard let keys, let file, let combined = try AES.GCM.seal(JSONEncoder().encode(held), using: keys.local).combined else { throw CloudFailure.secretsLocked }
        try BackendProjectSecretFilesStore.writePrivate(combined, to: file, root: root)
        // Durably sealed and read back BEFORE a caller may unlink or forget its live value.
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CloudFailure.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0, try Data(contentsOf: file) == combined else { throw CloudFailure.checksumMismatch }
        try BackendCloudBrainMemoryHash.synchronizeDirectory(root)
    }
    func version(_ record: CloudSecretRecord) throws -> String {
        if held.newest[record.recordId] == record, let version = held.wireHeads?[record.recordId] { return version }
        return try fingerprint(record)
    }
    private func fingerprint(_ record: CloudSecretRecord) throws -> String {
        try ready()
        guard let keys else { throw CloudFailure.secretsLocked }
        return keys.shared(Data("removed-version\n".utf8) + (try CloudSecretsCanonical.encode(record)))
    }
    func remember(_ record: CloudSecretRecord) throws {
        try ready()
        let id = record.recordId
        if held.newest[id] == record { return }
        if let old = held.newest[id] {
            let mark = Version(version: try version(old), digest: try fingerprint(old), fileMark: old.payload.raw["mark"].string)
            if !(held.history[id] ?? []).contains(mark) { held.history[id, default: []].append(mark) }
            // Changed content is an ordinary edit again: it goes out in the old form (decision 6).
            let before = old.payload.raw["mark"].string, after = record.payload.raw["mark"].string
            if before == nil || before != after { held.deliberate?.remove(id) }
        }
        held.newest[id] = record
        held.wireHeads?[id] = nil
        try save()
    }
    /// The same sealed holding, before a J-7 replacement or an ordinary incoming replacement. Not a second
    /// credential store and never a tool-readable history. A person's Bin purge also removes its matching copies.
    /// Decision 8: only the newest `safetyPerItem` per item and `safetyInAll` in all are kept.
    func keepSafety(_ record: CloudSecretRecord, at: Int64) throws {
        try ready()
        var kept = held.safety ?? [:]
        kept[try fingerprint(record)] = .init(record: record, at: at)
        for (_, rows) in Dictionary(grouping: kept, by: { $0.value.record.recordId }) where rows.count > Self.safetyPerItem {
            for row in rows.sorted(by: { $0.value.at > $1.value.at }).dropFirst(Self.safetyPerItem) { kept[row.key] = nil }
        }
        if kept.count > Self.safetyInAll {
            for row in kept.sorted(by: { $0.value.at > $1.value.at }).dropFirst(Self.safetyInAll) { kept[row.key] = nil }
        }
        held.safety = kept
        try save()
    }
    func newest(_ id: String) -> CloudSecretRecord? { held.newest[id] }
    func knownIds() -> [String] { Array(held.newest.keys).sorted() }
    func hasVersion(_ record: CloudSecretRecord) throws -> Bool {
        if held.newest[record.recordId] == record { return true }
        let value = try fingerprint(record)
        return (held.history[record.recordId] ?? []).contains { ($0.digest ?? $0.version) == value }
    }
    /// Decision 6: a version id only for a deliberate Put back / Put in Cloud again; every other upload keeps the form
    /// build 5e1ecbae2 reads (nil).
    func uploadVersion(_ record: CloudSecretRecord) throws -> String? {
        guard held.deliberate?.contains(record.recordId) == true else { return nil }
        try remember(record)
        guard held.deliberate?.contains(record.recordId) == true else { return nil }
        if let version = held.wireHeads?[record.recordId] { return version }
        if held.wireHeads == nil { held.wireHeads = [:] }
        let version = UUID().uuidString.lowercased()
        held.wireHeads?[record.recordId] = version
        try save()
        return version
    }
    func markDeliberate(_ id: String) throws {
        if held.deliberate == nil { held.deliberate = [] }
        guard held.deliberate?.insert(id).inserted == true else { return }
        try save()
    }
    func earlierVersion(_ id: String, _ version: String) -> Bool {
        held.wireHeads?[id] != version && (held.history[id] ?? []).contains { $0.version == version }
    }
    func newVersion(_ id: String, _ version: String) -> Bool { held.wireHeads?[id] != version }
    func adoptVersion(_ record: CloudSecretRecord, _ version: String) throws {
        try remember(record)
        if let old = held.wireHeads?[record.recordId], old != version {
            held.history[record.recordId, default: []].append(.init(version: old, digest: try fingerprint(record), fileMark: record.payload.raw["mark"].string))
        }
        if held.wireHeads == nil { held.wireHeads = [:] }
        held.wireHeads?[record.recordId] = version
        try save()
    }
    func matches(_ record: CloudSecretRecord, _ removal: CloudSecretRemoval) throws -> Bool {
        // A leaked password must go everywhere (lead, 15 Nov): the removal applies whenever the CURRENT value here equals
        // the removed value, whatever happened in between (X, Y and back to X). Only a different current value refuses.
        if held.newest[record.recordId] == record, let version = held.wireHeads?[record.recordId], version == removal.version { return true }
        let digest = try fingerprint(record)
        return removal.version == digest || removal.removedDigest == digest
    }
    func fileMarks(_ id: String) -> [String] {
        (held.history[id] ?? []).compactMap(\.fileMark) + (held.newest[id]?.payload.raw["mark"].string.map { [$0] } ?? [])
    }
    func mark(_ id: String) throws -> CloudDeleteMark? { try state().mark(at: id) }
    func mark(_ id: String, _ mark: CloudLocalMark, at: Int64) throws { try state().putMark(.init(place: id, mark: mark, at: at)) }
    func clearMark(_ id: String) throws { try state().clearMark(at: id) }
    func intent(_ id: String) throws -> CloudDeleteIntent? { try state().intent(at: id) }
    /// Keeps a by-hand "Not on this Mac" mark in mind while an arriving removal covers it (see `restored`).
    func keepHandMark(_ id: String) throws {
        if held.byHand == nil { held.byHand = [] }
        guard held.byHand?.insert(id).inserted == true else { return }
        try save()
    }
    /// The Bin row and the removal are saved (sealed) first; the intent is written LAST, only after that save
    /// succeeded (decision 2). Any failure leaves the holding as it was and no intent.
    func prepare(_ record: CloudSecretRecord, item: CloudDeleteItem, scope: CloudDeleteScope, actor: CloudDeleteActor, travel: Bool = true,
                 binnedAt: Int64? = nil) throws -> CloudSecretRemoval {
        try ready()
        guard UUID(uuidString: actor.group) != nil, actor.at > 0, actor.at <= Self.latestAt else { throw CloudDeleteRuleError.invalidState }
        let intent = actor.intent(place: record.recordId, scope: scope)
        let before = held
        var fields: [String: String] = [:]
        CloudDeleteTravel.write(intent, into: &fields)
        let removal = CloudSecretRemoval(sourceId: record.sourceId, recordId: record.recordId, domain: record.domain,
            version: try version(record), fields: fields, mac: actor.mac, macName: actor.macName, at: actor.at, removed: record, removedDigest: try fingerprint(record))
        held.republications?[record.recordId] = nil
        held.deliberate?.remove(record.recordId)
        held.removals[record.recordId] = removal
        if held.sendable == nil { held.sendable = [] }
        if travel { held.sendable?.insert(record.recordId) } else { held.sendable?.remove(record.recordId) }
        held.bin[binKey(actor.group, record.recordId)] = .init(item: item, actor: actor, record: record,
            until: actor.at + CloudBinGroup.retentionMilliseconds, binnedAt: binnedAt)
        do { try save() } catch { held = before; throw error }
        do { try state().putIntent(intent) } catch { held = before; try? save(); throw error }
        return removal
    }
    /// Decision 2: the intent is cleared whatever happens here. When this cannot be completed, the Bin copy (sealed
    /// by `prepare`) stays, but the removal neither travels nor counts as done on this Mac.
    func finish(_ removal: CloudSecretRemoval, unplaced: Bool = false) throws {
        let id = removal.recordId
        defer { try? state().clearIntent(at: id) }
        let before = held
        held.removals[id] = removal
        if held.localRemovals == nil { held.localRemovals = [:] }
        let cloud = removal.fields[CloudDeleteTravel.scope] == "cloud"
        held.localRemovals?[id] = cloud ? .cloud : .everywhere
        if held.unplaced == nil { held.unplaced = [] }
        if unplaced && !cloud { held.unplaced?.insert(id) } else { held.unplaced?.remove(id) }
        do {
            try save()
            try mark(id, cloud ? .onlyOnThisMac : .notOnThisMac, at: removal.at)
        } catch {
            held = before; held.sendable?.remove(id); try? save()
            throw error
        }
    }
    /// What `prepare` replaces, so a removal that could not be completed (the value changed, a link in the
    /// way, the owner refused) is undone exactly: no stray Bin row, no leftover intent that a later look could
    /// mistake for this delete, and an earlier removal of the same item stays as it was.
    struct Undo { let id: String; let before: Held }
    func undo(for id: String, group: String) -> Undo { .init(id: id, before: held) }
    /// Decision 2: the intent goes FIRST, whether or not the rest can be saved.
    func cancel(_ undo: Undo) throws {
        try? state().clearIntent(at: undo.id)
        held = undo.before
        try save()
    }
    func pending() throws -> [CloudSecretRemoval] {
        try ready()
        return try held.removals.values.filter { removal in
            guard held.sendable?.contains(removal.recordId) == true, held.localRemovals?[removal.recordId] != nil else { return false }
            return try state().intent(at: removal.recordId) == nil
        }
    }
    func removal(_ id: String) -> CloudSecretRemoval? { held.removals[id] }
    func isDeleted(_ id: String) -> Bool { held.localRemovals?[id] == .everywhere }
    func isUnplaced(_ id: String) -> Bool { held.unplaced?.contains(id) == true }
    /// The file of an unplaced removal went into the Bin after all: from now on it counts as applied here.
    func placedUnplaced(_ id: String) throws {
        guard held.unplaced?.remove(id) != nil else { return }
        try save()
    }
    func superseded(_ removal: CloudSecretRemoval) -> Bool {
        held.republications?[removal.recordId] == removal.fields[CloudDeleteTravel.group]
    }
    func validate(_ removal: CloudSecretRemoval) throws {
        guard removal.at > 0, removal.at <= Self.latestAt else { throw CloudFailure.invalidRequest }
        if let removed = removal.removed {
            guard removed.sourceId == removal.sourceId, removed.recordId == removal.recordId,
                  removed.domain == removal.domain,
                  try fingerprint(removed) == (removal.removedDigest ?? removal.version) else { throw CloudFailure.invalidRequest }
        }
    }
    /// Decision 5: room in the Bin for one more copy that arrived only inside a removal.
    func roomForCarried(_ record: CloudSecretRecord) -> Bool {
        guard held.bin.count < Self.carriedRows, let size = try? CloudSecretsCanonical.encode(record).count else { return false }
        var total = size
        for row in held.bin.values {
            total += (try? CloudSecretsCanonical.encode(row.record).count) ?? 0
            if total > Self.carriedBytes { return false }
        }
        return true
    }
    func republication(_ id: String) -> String? { held.republications?[id] }
    func reintroduces(_ id: String, group: String) -> Bool {
        held.removals[id]?.fields[CloudDeleteTravel.group] == group
    }
    /// The item is back in sync. `keepHandMark`: an arrival ended a removal that had covered his own by-hand mark, so
    /// that mark stays (it never comes back by itself). His own press or his own file passes false.
    func restored(_ id: String, keepHandMark: Bool = true) throws {
        if let group = held.removals[id]?.fields[CloudDeleteTravel.group] {
            if held.republications == nil { held.republications = [:] }
            held.republications?[id] = group
            if let record = held.newest[id], let version = held.wireHeads?[id] {
                held.history[id, default: []].append(.init(version: version, digest: try fingerprint(record), fileMark: record.payload.raw["mark"].string))
                held.wireHeads?[id] = nil
            }
        }
        held.removals[id] = nil
        held.sendable?.remove(id)
        held.localRemovals?[id] = nil
        held.unplaced?.remove(id)
        let hand = held.byHand?.remove(id) != nil
        try save()
        try? state().clearIntent(at: id)
        if hand && keepHandMark {
            let at = (try mark(id))?.at ?? 0
            try mark(id, .notOnThisMac, at: at)
        } else {
            try clearMark(id)
        }
    }
    /// Decision 8: rows gone for good after 30 days; then the Bin's live rows. `now` is the SERVICE clock (nil while
    /// it is not known here: nothing ages).
    func entries(now: Int64?) throws -> [Binned] {
        try ready()
        try expire(now: now)
        return try held.bin.values.filter { try state().intent(at: $0.item.id) == nil }
    }
    /// The Bin never empties early (lead, 15 Nov): a row goes only when BOTH the removal's date and the date this Mac put
    /// it into the Bin are 30 days old by the service clock. A wall clock set forward, or an old removal applied late by a
    /// Mac that was off for weeks, never shortens its 30 days here. A row binned while the clock was unknown counts from
    /// the first moment it is known.
    func expire(now: Int64?) throws {
        try ready()
        guard let now, now > 0 else { return }
        var filled = false
        for (key, row) in held.bin where row.binnedAt == nil { held.bin[key]?.binnedAt = now; filled = true }
        let window = CloudBinGroup.retentionMilliseconds
        let old = held.bin.filter { $0.value.until <= now && ($0.value.binnedAt ?? now) <= now - window }
        guard !old.isEmpty else { if filled { try save() }; return }
        try drop(Set(old.keys), safetyToo: false)
    }
    func groups(now: Int64?) throws -> [CloudBinGroup] {
        let grouped = Dictionary(grouping: try entries(now: now), by: { $0.actor.group })
        return grouped.values.compactMap { entries in
            guard let first = entries.first else { return nil }
            let a = first.actor
            return .init(id: a.group, by: a.by, macName: a.macName, session: a.session, agent: a.agent, at: a.at,
                         items: entries.map(\.item).sorted { $0.name < $1.name })
        }.sorted { $0.at > $1.at }
    }
    /// Decision 8: a row that was put back is no longer listed.
    func putBackDone(group: String, id: String) throws {
        guard held.bin.removeValue(forKey: binKey(group, id)) != nil else { return }
        try save()
    }
    func forgetBin(_ items: [CloudDeleteItem]) throws {
        try ready()
        let ids = Set(items.map(\.id))
        try drop(Set(held.bin.filter { ids.contains($0.value.item.id) }.keys), safetyToo: true)
    }
    private func drop(_ keys: Set<String>, safetyToo: Bool) throws {
        let gone = keys.compactMap { held.bin[$0] }
        for key in keys { held.bin[key] = nil }
        if safetyToo {
            let ids = Set(gone.map(\.item.id))
            held.safety = held.safety?.filter { !ids.contains($0.value.record.recordId) }
        }
        for row in gone where !held.bin.values.contains(where: { $0.item.id == row.item.id }) {
            let record = row.record
            // Do not retain a second copy of a gone Bin row in the J-7 history or the cached head.
            if held.newest[record.recordId] == record, try mark(record.recordId)?.mark == .notOnThisMac {
                held.newest[record.recordId] = nil
            }
            if let removal = held.removals[record.recordId] {
                held.removals[record.recordId] = .init(sourceId: removal.sourceId, recordId: removal.recordId, domain: removal.domain,
                    version: removal.version, fields: removal.fields, mac: removal.mac, macName: removal.macName, at: removal.at, removedDigest: removal.removedDigest)
            }
        }
        try save()
    }
    func marks() throws -> [CloudDeleteMark] { try state().marks() }
    private func binKey(_ group: String, _ id: String) -> String { group + "/" + id }
}

/// A saved-password owner uses its existing capture/merge writers. `remove` is compare-and-remove, supplied by
/// the real owner; it must not remove a changed value. Tools receive only CloudDeleteOwning's ordinary actions.
/// Review fix 1: who removed an item outside the app, and this Mac's own id and name for an AI removal's record.
public struct BackendCloudKeysVanished: Sendable {
    public let who: @Sendable (_ id: String, _ lastSeen: Int64, _ goneAt: Int64) async -> CloudDeleteWitnessAnswer
    public let device: @Sendable () async -> String?
    public let deviceName: @Sendable () async -> String
    /// false: only this Mac's id and name are given (a Cloud-only retire); an absent item is never judged.
    public let judgesAbsence: Bool
    public init(who: @escaping @Sendable (_ id: String, _ lastSeen: Int64, _ goneAt: Int64) async -> CloudDeleteWitnessAnswer,
                device: @escaping @Sendable () async -> String?, deviceName: @escaping @Sendable () async -> String, judgesAbsence: Bool = true) {
        self.who = who; self.device = device; self.deviceName = deviceName; self.judgesAbsence = judgesAbsence
    }
    /// Only this Mac's id and name (review fix D: API keys retire an old id from Cloud; nothing is judged).
    public static func identityOnly(device: @escaping @Sendable () async -> String?, deviceName: @escaping @Sendable () async -> String) -> Self {
        .init(who: { _, _, _ in .cannotKnow }, device: device, deviceName: deviceName, judgesAbsence: false)
    }
}

public actor BackendProjectSecretFilesSavedDeleteOwner: CloudSecretsLogicalStore, CloudSecretsDeletingStore, CloudDeleteOwning {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow: String
    public nonisolated let domain: CloudSecretsDomain
    private let store: any CloudSecretsLogicalStore
    public nonisolated let mcpStore: BackendCloudSecretsMCPStore?
    private let remove: @Sendable (CloudSecretRecord) async throws -> Bool
    private let restore: @Sendable (CloudSecretRecord) async throws -> CloudApplyStatus
    private let name: @Sendable (CloudSecretRecord) -> String
    private let gate: @Sendable () async -> Bool
    private let now: @Sendable () -> Int64
    private let macName: @Sendable (String) async -> String?
    /// The service clock (nil while unknown); the Bin ages only by it.
    private let serviceClock: @Sendable () async -> Int64?
    /// Keys travel (15 Nov): the same VALUE although the record differs (the sending Mac's name or his own account name
    /// rides inside it). A removal applies when the value here equals the removed one, as for every saved password.
    private let sameValue: (@Sendable (CloudSecretRecord, CloudSecretRecord) -> Bool)?
    /// Review fix 1 (15 Nov): an item that disappears OUTSIDE the app (`claude mcp remove`) follows the delete rule:
    /// done by an AI session = everywhere; by his own hand = "Not on this Mac" here, never brought back by sync.
    /// nil = the kind cannot be removed outside the app (nothing is inferred from an absent record).
    private let vanished: BackendCloudKeysVanished?
    /// When this owner last saw each item in a capture (memory only); the witness looks from then to now.
    private var seenAt: [String: Int64] = [:]
    let keeper: BackendProjectSecretFilesDeleteState
    private var active = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(store: any CloudSecretsLogicalStore, stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                name: @escaping @Sendable (CloudSecretRecord) -> String,
                remove: @escaping @Sendable (CloudSecretRecord) async throws -> Bool,
                restore: (@Sendable (CloudSecretRecord) async throws -> CloudApplyStatus)? = nil,
                macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sameValue: (@Sendable (CloudSecretRecord, CloudSecretRecord) -> Bool)? = nil,
                vanished: BackendCloudKeysVanished? = nil) {
        self.store = store; self.remove = remove; self.name = name; self.gate = gate; self.now = now; self.macName = macName
        self.serviceClock = serviceClock; self.sameValue = sameValue; self.vanished = vanished
        self.restore = restore ?? { try await store.merge($0) }
        mcpStore = store as? BackendCloudSecretsMCPStore
        sourceId = store.sourceId; inventoryRow = store.inventoryRow; domain = store.domain
        keeper = .init(root: stateRoot.appendingPathComponent("sealed-bin", isDirectory: true), source: store.sourceId)
    }
    public func use(keys: CloudSecretsStoreKeys?) async {
        active = keys != nil
        keeper.use(keys)
        await (store as? any CloudSecretsKeyedStore)?.use(keys: keys)
    }
    /// Decision 7: whether "Everywhere" (and "Cloud") can be honoured right now; pages hide both buttons when false.
    public func canDeleteEverywhere() async -> Bool {
        guard active, (try? keeper.ready()) != nil else { return false }
        return await gate()
    }
    /// Decision 8's one fixed line, nil when the Bin was read whole.
    public func binNotice() -> String? { keeper.notice }
    // Store/CLI refusals can contain echoed input. Only fixed errors cross this owner's page/tool boundary.
    private func rawCapture() async throws -> [CloudSecretRecord] {
        do { return try await store.capture() } catch { throw CloudFailure.unavailable }
    }
    private func rawMerge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        do { return try await store.merge(record) } catch { throw CloudFailure.unavailable }
    }
    /// Decision 9: "locked right now" stays locked (the arrival is retried when it opens); anything else is a refusal.
    private func rawValidate(_ record: CloudSecretRecord) async throws {
        do { try await store.validate(record) }
        catch CloudFailure.secretsLocked { throw CloudFailure.secretsLocked }
        catch { throw CloudFailure.invalidRequest }
    }
    private func rawVerify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        do { return try await store.verify(record, outcome: outcome) } catch { throw CloudFailure.unavailable }
    }
    private func rawRestore(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        do { return try await restore(record) } catch { throw CloudFailure.unavailable }
    }
    private func rawRemove(_ record: CloudSecretRecord) async throws -> Bool {
        do { return try await remove(record) } catch { throw CloudFailure.unavailable }
    }
    /// One action at a time; a second one waits its turn (it never fails as "busy", so nothing is dropped or stalls).
    private func lock() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in waiters.append(waiter) }
    }
    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private func enter() async throws {
        await lock()
        do { try keeper.ready() } catch { unlock(); throw error }
    }
    private func item(_ record: CloudSecretRecord) -> CloudDeleteItem {
        .init(id: record.recordId, kind: domain == .mcp ? "mcp-servers" : "saved-passwords", name: name(record), place: sourceId)
    }
    public func capture() async throws -> [CloudSecretRecord] {
        try await enter(); defer { unlock() }
        let all: [CloudSecretRecord]
        let fileFound: Bool?
        if let mcpStore {
            do { let read = try await mcpStore.captureRead(); all = read.records; fileFound = read.fileFound }
            catch { throw CloudFailure.unavailable }
        } else { all = try await rawCapture(); fileFound = nil }
        guard active else { throw CloudFailure.secretsLocked }
        try keeper.expire(now: await serviceClock())
        var rows: [CloudSecretRecord] = []
        for record in all {
            if let mark = try keeper.mark(record.recordId) {
                if mark.mark == .onlyOnThisMac { continue }
                // A value this owner already knows is ALWAYS kept away (lead, 15 Nov): a deleted password can come back
                // without anyone saving it (a restore of the data folder, converting sign-ins from the earlier app, the
                // store adopting a restored copy) and must never undo his Everywhere delete. A password comes back only by
                // Put back from the Bin (it travels) or by saving a NEW value. Decision 10 holds for project files only.
                if try keeper.hasVersion(record) { continue }
                // A value made anew by its owner wins.
                try keeper.restored(record.recordId, keepHandMark: false)
            }
            try keeper.remember(record); rows.append(record)
        }
        try await settleVanished(present: all, fileFound: fileFound)
        return rows
    }
    /// Review fix 1: known items missing from this capture, never marked yet and not in the middle of an app delete.
    /// `fileFound`: whether the source file was there (nil = this kind cannot say; an empty read then judges nothing).
    private func settleVanished(present: [CloudSecretRecord], fileFound: Bool?) async throws {
        let at = now()
        let here = Set(present.map(\.recordId))
        for id in here { seenAt[id] = at }
        guard let vanished, vanished.judgesAbsence else { return }
        // Review N1 / fix 4: a missing file says nothing about any one item (unreadable or invalid already threw).
        if fileFound == false { return }
        var gone: [(id: String, record: CloudSecretRecord)] = []
        for id in keeper.knownIds() where !here.contains(id) {
            guard try keeper.mark(id) == nil, !keeper.isDeleted(id), try keeper.intent(id) == nil, let record = keeper.newest(id) else { continue }
            gone.append((id, record))
        }
        // Review fix 4: an empty list is his choice only when exactly ONE known item went (his last one). Two or more
        // gone at once with nothing left looks like a damaged or replaced file: cannot tell, nothing changes.
        if here.isEmpty, gone.count >= 2 || fileFound == nil { return }
        for (id, record) in gone {
            // Seen in this run: the witness judges the time since. Not seen since the app started: nobody can tell.
            let since = seenAt.removeValue(forKey: id)
            var who = CloudDeleteWitnessAnswer.cannotKnow
            if let since { who = await vanished.who(id, since, at) }
            if await gate(), case .ai(let session, let agent, _, let group) = who, UUID(uuidString: group) != nil,
               let device = await vanished.device(), !device.isEmpty, let stamp = await serviceClock() {
                let actor = CloudDeleteActor(by: .ai, mac: device, macName: await vanished.deviceName(), session: session, agent: agent, at: stamp, group: group)
                do {
                    let removal = try keeper.prepare(record, item: item(record), scope: .everywhere, actor: actor, travel: true, binnedAt: stamp)
                    try keeper.finish(removal)
                    continue
                } catch {}
            }
            // His own hand (or nobody can tell): this Mac only, the safe side; sync never brings it back here.
            try keeper.mark(id, .notOnThisMac, at: at)
        }
    }
    /// Review fix 3: the value this Mac last took from or sent to Cloud for `id` (sealed state; nil when none).
    public func lastExchanged(_ id: String) -> CloudSecretRecord? { keeper.newest(id) }
    /// Review fix 3: an id this Mac no longer uses in Cloud (two Macs agreed on the other one) leaves Cloud only. Called
    /// from inside this owner's own merge, so it takes no turn of its own. No Bin row (nothing of his went away).
    public func retireFromCloud(_ id: String) async {
        guard active, await gate(), let vanished, let record = keeper.newest(id), (try? keeper.mark(id)) == nil,
              let device = await vanished.device(), !device.isEmpty, let stamp = await serviceClock() else { return }
        let actor = CloudDeleteActor(by: .person, mac: device, macName: await vanished.deviceName(), at: stamp, group: UUID().uuidString.lowercased())
        guard let removal = try? keeper.prepare(record, item: item(record), scope: .cloud, actor: actor, travel: true, binnedAt: stamp) else { return }
        try? keeper.finish(removal)
        try? keeper.forgetBin([item(record)])
    }
    public func validate(_ record: CloudSecretRecord) async throws { try await rawValidate(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        try await enter(); defer { unlock() }
        let mark = try keeper.mark(record.recordId)
        // A cloud-only tombstone is superseded only by a new put; record equality alone never supersedes it.
        if mark?.mark == .notOnThisMac, !keeper.isDeleted(record.recordId) { try keeper.remember(record); return .alreadyPresent }
        if mark != nil, try keeper.hasVersion(record) { return .alreadyPresent }
        let outcome = try await rawMerge(record)
        guard active else { throw CloudFailure.secretsLocked }
        if outcome != .keptBoth { try keeper.remember(record); try keeper.restored(record.recordId) }
        return outcome
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        if try keeper.mark(record.recordId) != nil { return true }
        if outcome == .alreadyPresent, try keeper.hasVersion(record) { return true }
        return try await rawVerify(record, outcome: outcome)
    }
    /// Decision 6: nil (the old form) for every ordinary upload, also while the gate is open.
    public func versionForUpload(_ record: CloudSecretRecord) async throws -> String? {
        try keeper.ready()
        guard await gate() else { return nil }
        return try keeper.uploadVersion(record)
    }
    public func mergeVersioned(_ record: CloudSecretRecord, version: String, removalGroup: String?) async throws -> CloudApplyStatus {
        try keeper.ready()
        guard UUID(uuidString: version) != nil else { throw CloudFailure.invalidRequest }
        if keeper.earlierVersion(record.recordId, version) { return .alreadyPresent }
        if keeper.newVersion(record.recordId, version), let mark = try keeper.mark(record.recordId),
           mark.mark == .onlyOnThisMac || keeper.isDeleted(record.recordId) { try keeper.restored(record.recordId) }
        if let removalGroup, keeper.reintroduces(record.recordId, group: removalGroup) { try keeper.restored(record.recordId) }
        let outcome = try await merge(record)
        if outcome != .keptBoth { try keeper.adoptVersion(record, version) }
        return outcome
    }
    public func republication(recordId: String) async throws -> String? {
        try keeper.ready()
        return await gate() ? keeper.republication(recordId) : nil
    }
    public func mergeReintroduced(_ record: CloudSecretRecord, removalGroup: String) async throws -> CloudApplyStatus {
        try keeper.ready()
        if keeper.reintroduces(record.recordId, group: removalGroup) { try keeper.restored(record.recordId) }
        return try await merge(record)
    }
    public func captureRemovals() async throws -> [CloudSecretRemoval] {
        guard await gate() else { return [] }
        return try keeper.pending()
    }
    public func validateRemoval(_ removal: CloudSecretRemoval) async throws {
        try keeper.ready()
        guard removal.sourceId == sourceId, removal.domain == domain.rawValue, (removal.version.count == 64 || UUID(uuidString: removal.version) != nil),
              !removal.recordId.isEmpty, removal.at > 0, removal.at <= BackendProjectSecretFilesDeleteState.latestAt,
              case .intent = try CloudDeleteTravel.read(removal.fields, place: removal.recordId, mac: removal.mac, at: removal.at) else { throw CloudFailure.invalidRequest }
        try keeper.validate(removal)
        if let removed = removal.removed { try await rawValidate(removed) }
    }
    public func mergeRemoval(_ removal: CloudSecretRemoval) async throws -> CloudApplyStatus {
        try await enter(); defer { unlock() }
        try await validateRemoval(removal)
        if keeper.superseded(removal) { return .alreadyPresent }
        guard case .intent(let intent) = try CloudDeleteTravel.read(removal.fields, place: removal.recordId, mac: removal.mac, at: removal.at) else { throw CloudFailure.invalidRequest }
        let found = try await rawCapture().first { $0.recordId == removal.recordId }
        guard active else { throw CloudFailure.secretsLocked }
        guard let local = found ?? removal.removed else { return .alreadyPresent }
        guard try keeper.matches(local, removal) || removal.removed.map({ sameValue?(local, $0) ?? false }) == true else { return .keptBoth }
        // Decision 5: a copy that never was on this Mac fills only a bounded part of the Bin; put back runs it through
        // the owner's own arrival rules (its merge) like any arriving value.
        if found == nil, !keeper.roomForCarried(local) { return .keptBoth }
        let resolvedName = await macName(intent.mac)
        let actor = CloudDeleteActor(by: intent.by, mac: intent.mac, macName: resolvedName ?? "another device",
            session: intent.session, agent: intent.agent, at: intent.at, group: intent.group)
        try keeper.remember(local)
        let undo = keeper.undo(for: local.recordId, group: intent.group)
        _ = try keeper.prepare(local, item: item(local), scope: intent.scope, actor: actor, travel: false, binnedAt: await serviceClock())
        if intent.scope == .everywhere, found != nil {
            // Compare-and-remove by the owner's own writer. Changed meanwhile or refused: his value stays,
            // the removal is closed as not applied, and nothing of it is left behind.
            let removed: Bool
            do { removed = try await rawRemove(local) } catch { removed = false }
            guard removed else { try? keeper.cancel(undo); return .keptBoth }
        }
        guard active else { throw CloudFailure.secretsLocked }
        try keeper.finish(removal, unplaced: intent.scope == .everywhere && found == nil)
        return .applied
    }
    public func verifyRemoval(_ removal: CloudSecretRemoval, outcome: CloudApplyStatus) async throws -> Bool {
        if outcome != .applied { return true }
        return try keeper.mark(removal.recordId) != nil
    }
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        try await enter(); defer { unlock() }
        // Decision 7: while an older Mac exists, neither "Everywhere" nor "Cloud" can be honoured for these kinds.
        guard await gate() else { throw BackendCloudSecretsWaiting(reason: CloudDeleteWords.cloudNeedsUpdatedMacs) }
        let records = try await rawCapture()
        guard active else { throw CloudFailure.secretsLocked }
        var done: [CloudDeleteItem] = []
        for wanted in items {
            guard let record = records.first(where: { $0.recordId == wanted.id }), wanted.kind == item(record).kind else { throw CloudFailure.invalidRequest }
            try keeper.remember(record)
            let undo = keeper.undo(for: record.recordId, group: actor.group)
            let removal = try keeper.prepare(record, item: item(record), scope: scope, actor: actor, travel: true, binnedAt: await serviceClock())
            if scope == .everywhere {
                let removed: Bool
                do { removed = try await rawRemove(record) } catch { try? keeper.cancel(undo); throw error }
                guard removed else { try? keeper.cancel(undo); throw CloudFailure.versionChanged }
            }
            // Signed out meanwhile: the holding is closed; its intent is dropped when it opens again (decision 2).
            guard active else { throw CloudFailure.secretsLocked }
            try keeper.finish(removal); done.append(item(record))
        }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: done)
    }
    /// Names for ordinary page rows. This never returns a Bin row or a saved value.
    public func items() async throws -> [CloudDeleteItem] {
        try keeper.ready()
        return try await rawCapture().map { item($0) }
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        try keeper.marks().compactMap { mark in
            guard !keeper.isDeleted(mark.place), let record = keeper.newest(mark.place) else { return nil }
            return .init(item: item(record), mark: mark.mark, at: mark.at)
        }
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        try await enter(); defer { unlock() }
        var done: [CloudDeleteItem] = []
        for wanted in items {
            guard !keeper.isDeleted(wanted.id) else { throw CloudFailure.invalidRequest }
            guard let record = keeper.newest(wanted.id) else { continue }
            if to == .thisMac {
                let outcome = try await rawRestore(record)
                guard outcome != .keptBoth, try await rawVerify(record, outcome: outcome) else { throw CloudFailure.versionChanged }
            }
            guard active else { throw CloudFailure.secretsLocked }
            try keeper.restored(wanted.id, keepHandMark: false)
            if to == .cloud { try keeper.markDeliberate(wanted.id) }
            done.append(item(record))
        }
        return done
    }
    public func binGroups() async throws -> [CloudBinGroup] { try keeper.groups(now: await serviceClock()) }
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        try await enter(); defer { unlock() }
        var done: [CloudDeleteItem] = []
        for entry in try keeper.entries(now: await serviceClock()).filter({ $0.actor.group == group }) {
            // The owner's own writer and its own arrival rules decide (the same as any arriving value).
            let outcome: CloudApplyStatus
            do { outcome = try await rawRestore(entry.record) } catch { continue }
            guard active else { throw CloudFailure.secretsLocked }
            guard outcome != .keptBoth, try await rawVerify(entry.record, outcome: outcome) else { continue }
            try keeper.remember(entry.record); try keeper.restored(entry.item.id, keepHandMark: false)
            try keeper.markDeliberate(entry.item.id)
            try keeper.putBackDone(group: group, id: entry.item.id)
            done.append(entry.item)
        }
        return done
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        try await enter(); defer { unlock() }
        try keeper.forgetBin(items)
    }
}

extension DeckMemoryStore {
    /// L3 uses the same identity and service clock as the shared gate; no second clock or device id store.
    public func projectSecretDeleteIdentity() -> (mac: String, at: Int64)? {
        guard let mac = cloudDeviceId, let at = DeckMemoryCloudClocks.shared.now(for: self), at > 0 else { return nil }
        return (mac, at)
    }
}
