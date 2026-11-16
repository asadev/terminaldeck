import Foundation

/// "See what is in your Cloud" (owner, 13 Nov): what this Mac's sync store already knows about every item of the
/// account, read in one pass from local state only. Nothing here asks the network or reads content: every record
/// keeps its author device and the service's commit time (`records`, `op_receipts`), so the history of each item,
/// what is still going up, what waits here and what could not be used are all on this Mac already.
///
/// The ONE fact that was not recorded is when this Mac received a pack: `pack_arrivals` keeps that time per feed
/// position (written where a pack is applied, `noteArrival`). Ids and devices stay raw here; the page's model turns
/// them into names and never shows an id.
public struct CloudSyncContents: Sendable, Equatable {
    /// One version of an item: which device wrote it and when (the service's commit time when known, else the time
    /// the device stamped it).
    public struct Change: Sendable, Equatable {
        public let deviceId: String
        public let at: Int64
        public init(deviceId: String, at: Int64) { self.deviceId = deviceId; self.at = at }
    }
    /// Where the item's newest version stands on this Mac.
    public enum Standing: String, Sendable, Equatable {
        /// In Cloud and on this Mac.
        case inCloud
        /// Made on this Mac, still going up.
        case sending
        /// Made on this Mac, refused or held back on the send side (`reason`).
        case notSent
        /// From another device, kept on this Mac but not used yet (`reason`).
        case waitingHere
    }
    /// The identity of an item as its adapter names it. Raw: never shown.
    public struct Key: Sendable, Hashable {
        public let domain: String
        public let sourceId: String
        public let recordId: String
        public let projectId: String?
        public init(domain: String, sourceId: String, recordId: String, projectId: String?) {
            self.domain = domain; self.sourceId = sourceId; self.recordId = recordId; self.projectId = projectId
        }
    }
    public struct Item: Sendable, Equatable {
        public let key: Key
        /// Newest first, one entry per version (the parts of one version count once).
        public let changes: [Change]
        public let standing: Standing
        /// The sync core's reason word for `notSent` and `waitingHere`.
        public let reason: String?
        /// The item's size in bytes when its record says so.
        public let bytes: Int64?
        /// Proof 2 (13 Nov): the feed position of the newest version Cloud took (nil while it is not in Cloud). A device
        /// whose reported read position is at or past it has this version.
        public let seq: CloudSequence?
        public init(key: Key, changes: [Change], standing: Standing, reason: String? = nil, bytes: Int64? = nil, seq: CloudSequence? = nil) {
            self.key = key; self.changes = changes; self.standing = standing; self.reason = reason; self.bytes = bytes; self.seq = seq
        }
    }
    /// One pack in the account's feed that this Mac holds: who sent it, when it was committed, when it arrived here.
    public struct Pack: Sendable, Equatable {
        public let deviceId: String
        public let at: Int64
        /// This Mac's clock when the pack was applied here; nil for this Mac's own packs and packs from before the
        /// arrival time was recorded.
        public let arrivedAt: Int64?
        /// Distinct items of the pack, at most `keyLimit` of them (enough to name a pack of one).
        public let keys: [Key]
        /// Distinct items per domain.
        public let count: [String: Int]
        public init(deviceId: String, at: Int64, arrivedAt: Int64?, keys: [Key], count: [String: Int]) {
            self.deviceId = deviceId; self.at = at; self.arrivedAt = arrivedAt; self.keys = keys; self.count = count
        }
        public static let keyLimit = 3
    }
    /// Records this Mac could not send, by reason.
    public struct NotSent: Sendable, Equatable {
        public let reason: String
        public let count: Int
        public let since: Int64
        public init(reason: String, count: Int, since: Int64) { self.reason = reason; self.count = count; self.since = since }
    }
    public let thisDevice: String
    public let items: [Item]
    /// Newest first.
    public let packs: [Pack]
    public let held: [CloudHeldDevice]
    public let refused: [CloudRefusedPack]
    public let notSent: [NotSent]
    /// Records of this Mac still going up.
    public let queued: Int
    public init(thisDevice: String, items: [Item] = [], packs: [Pack] = [], held: [CloudHeldDevice] = [], refused: [CloudRefusedPack] = [],
                notSent: [NotSent] = [], queued: Int = 0) {
        self.thisDevice = thisDevice; self.items = items; self.packs = packs; self.held = held; self.refused = refused
        self.notSent = notSent; self.queued = queued
    }
    public static let empty = CloudSyncContents(thisDevice: "")
}

extension CloudSyncStore {
    static let arrivalsTable = "CREATE TABLE IF NOT EXISTS pack_arrivals (seq TEXT PRIMARY KEY, arrivedAt INTEGER NOT NULL)"
    /// The one fact recorded for the Cloud contents page: when this Mac applied the pack at `seq`. First time wins.
    func noteArrival(_ seq: CloudSequence, at: Int64 = CloudSyncBytes.now()) throws {
        try execute(Self.arrivalsTable)
        try execute("INSERT OR IGNORE INTO pack_arrivals(seq,arrivedAt) VALUES (?,CAST(? AS INTEGER))", [Data(seq.rawValue.utf8), Data(String(at).utf8)])
    }

    /// Everything the contents page shows, from this store alone. `limit` bounds the records read (newest first).
    func contents(thisDevice: String, held: [CloudHeldDevice], limit: Int = 20_000) throws -> CloudSyncContents {
        try execute(Self.arrivalsTable)
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        func int(_ data: Data) -> Int64? { data.isEmpty ? nil : Int64(text(data)) }
        func size(_ payload: CloudValue) -> Int64? {
            let value = payload.raw["bytes"]
            if let string = value.string, let number = Int64(string) { return number }
            if let number = value.number { return Int64(number) }
            return nil
        }
        struct Building { var changes: [String: CloudSyncContents.Change] = [:]; var newest: (at: Int64, opId: String)?; var bytes: Int64?; var seq: CloudSequence? }
        var building: [CloudSyncContents.Key: Building] = [:]
        var keyOfOp: [String: CloudSyncContents.Key] = [:]
        var packRows: [String: (device: String, at: Int64, ops: [String])] = [:]
        var cursor = Int64.max, read = 0
        while read < limit {
            let page = try rows("""
              SELECT r.rowid,r.opId,r.bytes,rc.seq,rc.committedAt FROM records r LEFT JOIN op_receipts rc ON rc.opId=r.opId
              WHERE r.rowid<CAST(? AS INTEGER) ORDER BY r.rowid DESC LIMIT 512
              """, [Data(String(cursor).utf8)])
            if page.isEmpty { break }
            for row in page {
                read += 1
                guard let op = try? JSONDecoder().decode(CloudOperation.self, from: row[2]) else { continue }
                let key = CloudSyncContents.Key(domain: op.domain, sourceId: op.source.sourceId, recordId: op.source.recordId, projectId: op.projectId)
                let at = int(row[4]) ?? op.createdAt
                var entry = building[key] ?? Building()
                // The parts of one version share their author and stamp: one change.
                entry.changes[op.originDevice + "|" + String(op.createdAt)] = .init(deviceId: op.originDevice, at: at)
                if entry.newest == nil || at > entry.newest!.at { entry.newest = (at, op.opId) }
                if !row[3].isEmpty, let seq = try? CloudSequence(rawValue: text(row[3])), entry.seq.map({ seq > $0 }) ?? true { entry.seq = seq }
                if entry.bytes == nil { entry.bytes = size(op.payload) }
                building[key] = entry
                keyOfOp[op.opId] = key
                if !row[3].isEmpty {
                    let seq = text(row[3])
                    var pack = packRows[seq] ?? (op.originDevice, at, [])
                    pack.ops.append(op.opId)
                    packRows[seq] = pack
                }
            }
            guard let last = page.last, let next = int(last[0]) else { break }
            cursor = next
        }
        // What is not in Cloud yet: this Mac's own queue and refusals, and records kept here but not used.
        var queuedOps: Set<String> = [], parkedSend: [String: String] = [:], parkedHere: [String: String] = [:]
        for row in try rows("SELECT opId FROM outbox WHERE state='queued'") { queuedOps.insert(text(row[0])) }
        var notSent: [String: (count: Int, since: Int64)] = [:]
        for row in try rows("SELECT o.opId,coalesce(p.reason,'refused'),coalesce(p.parkedAt,0) FROM outbox o LEFT JOIN parked_sends p ON p.opId=o.opId WHERE o.state='parked'") {
            let reason = text(row[1])
            parkedSend[text(row[0])] = reason
            let since = int(row[2]) ?? 0
            let old = notSent[reason] ?? (0, since)
            notSent[reason] = (old.count + 1, min(old.since == 0 ? since : old.since, since == 0 ? old.since : since))
        }
        for row in try rows("SELECT opId,bytes,reason,parkedAt FROM parked_ops") {
            let opId = text(row[0])
            parkedHere[opId] = text(row[2])
            // A record parked for an identity conflict never entered `records`: it is shown from its parked copy.
            if keyOfOp[opId] == nil, let op = try? JSONDecoder().decode(CloudOperation.self, from: row[1]) {
                let key = CloudSyncContents.Key(domain: op.domain, sourceId: op.source.sourceId, recordId: op.source.recordId, projectId: op.projectId)
                var entry = building[key] ?? Building()
                let at = op.createdAt
                entry.changes[op.originDevice + "|" + String(op.createdAt)] = .init(deviceId: op.originDevice, at: at)
                if entry.newest == nil || at >= entry.newest!.at { entry.newest = (at, opId) }
                building[key] = entry
                keyOfOp[opId] = key
            }
        }
        var opsOfKey: [CloudSyncContents.Key: [String]] = [:]
        for (op, key) in keyOfOp { opsOfKey[key, default: []].append(op) }
        var items: [CloudSyncContents.Item] = []
        items.reserveCapacity(building.count)
        for (key, entry) in building {
            let changes = entry.changes.values.sorted { $0.at != $1.at ? $0.at > $1.at : $0.deviceId < $1.deviceId }
            // Any version still waiting decides the standing: the newest version is not settled while one waits.
            let ops = opsOfKey[key] ?? []
            var standing = CloudSyncContents.Standing.inCloud, reason: String?
            if let op = ops.first(where: { parkedHere[$0] != nil }) { standing = .waitingHere; reason = parkedHere[op] }
            else if let op = ops.first(where: { parkedSend[$0] != nil }) { standing = .notSent; reason = parkedSend[op] }
            else if ops.contains(where: queuedOps.contains) { standing = .sending }
            items.append(.init(key: key, changes: changes, standing: standing, reason: reason, bytes: entry.bytes, seq: entry.seq))
        }
        items.sort { ($0.changes.first?.at ?? 0) > ($1.changes.first?.at ?? 0) }
        var arrivals: [String: Int64] = [:]
        for row in try rows("SELECT seq,arrivedAt FROM pack_arrivals") { arrivals[text(row[0])] = int(row[1]) }
        var packs: [CloudSyncContents.Pack] = []
        for (seq, pack) in packRows {
            var keys: [CloudSyncContents.Key] = [], count: [String: Int] = [:], seen: Set<CloudSyncContents.Key> = []
            for op in pack.ops {
                guard let key = keyOfOp[op], seen.insert(key).inserted else { continue }
                count[key.domain, default: 0] += 1
                if keys.count < CloudSyncContents.Pack.keyLimit { keys.append(key) }
            }
            packs.append(.init(deviceId: pack.device, at: pack.at, arrivedAt: pack.device == thisDevice ? nil : arrivals[seq], keys: keys, count: count))
        }
        packs.sort { max($0.at, $0.arrivedAt ?? 0) > max($1.at, $1.arrivedAt ?? 0) }
        let notSentRows = notSent.map { CloudSyncContents.NotSent(reason: $0.key, count: $0.value.count, since: $0.value.since) }
            .sorted { $0.since > $1.since }
        return .init(thisDevice: thisDevice, items: items, packs: Array(packs.prefix(500)), held: held, refused: try refusedRows(),
                     notSent: notSentRows, queued: queuedOps.count)
    }
}
