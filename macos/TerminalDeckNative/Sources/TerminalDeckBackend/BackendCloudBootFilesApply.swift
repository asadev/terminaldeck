import Foundation
import TerminalDeckNativeCore

/// One line of lane F's list: a boot file that waits (for a folder, for the person), that could not be written,
/// or that the person should know about. Lane A's sheet shows these; lane F never shows anything itself.
/// One tracked instruction file (names only), for the delete rule's AI tool targets.
public struct BackendCloudBootFilesTracked: Sendable, Equatable {
    public let sourceId: String
    public let place: CloudBootFilesPlaceKind
    public let identity: String?
    public let relative: String
}

public struct BackendCloudBootFilesItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Its project has no folder on this Mac, or its AI account is not on this Mac. Written by itself later.
        case waitingFolder = "waiting-folder"
        /// It can run a command or grant tools. Written only by `accept`.
        case needsAccept = "needs-accept"
        /// A newer version arrived, but this Mac's file is not the one this Mac last saw. Both are kept.
        case keptVersion = "kept-version"
        /// A version that is not a successor of this Mac's file arrived. Both are kept.
        case otherVersion = "other-version"
        /// A link, a folder or a name differing only in letter case is in the way. Clears by itself.
        case blocked
        /// Legacy display value retained for decoding old page rows; new removals apply into the keeper Bin.
        case removedElsewhere = "removed-elsewhere"
        /// This Mac's earlier file, kept when the person accepted another version over it.
        case replacedLocal = "replaced-local"
    }
    public let id: String
    public let kind: Kind
    public let place: CloudBootFilesPlaceKind
    /// The project id or the account home's identity, when known.
    public let identity: String?
    public let relative: String
    /// Fingerprint of the version this line is about.
    public let hash: String
    public let bytes: Int64
    /// The device whose signature the sync core checked for the pack that brought it. "" when not known.
    public let originDevice: String
    /// Short codes: `header:allowed-tools`, `script-or-settings`, `script`, `inline-command`, `local-differs`,
    /// `removed-here`, `newer-version`, `link`, `twin`, `in-the-way`, `changed`, `unreachable`, `no-folder`,
    /// `no-chosen-folder` (the project has folders here but none chosen for boot files), `home-folder` (the chosen
    /// folder is the home folder or holds an AI account home), `header:<key>`, `header:unclear`, `import:<path>`.
    public let reasons: [String]
    public let at: Int64
    let sourceId: String
    /// True when `accept` can write this version into the folder.
    public var canAccept: Bool { kind == .needsAccept || kind == .keptVersion || kind == .otherVersion }
}

/// One file lane F wrote from another device (Security Ruling 2, T13: seen afterwards, named one by one).
public struct BackendCloudBootFilesChange: Sendable, Equatable {
    public let place: CloudBootFilesPlaceKind
    public let identity: String?
    public let relative: String
    public let hash: String
    public let originDevice: String
    /// `created`, `updated`, `accepted`, or `newer` (the one rule: a newer version from another device replaced this
    /// Mac's own; this Mac's version is kept 30 days and can be restored).
    public let how: String
    public let at: Int64
    /// The fingerprint of what this Mac's file held just before this change replaced it; nil when nothing was
    /// replaced (`created`). `earlierVersion(hash:)` reads those bytes ("Show previous version").
    public let previousHash: String?
}

/// One older version of an instruction file kept on this Mac for 30 days (the one rule). Names and dates for the
/// page; `hash` is for reading it back only and is never shown.
public struct BackendCloudBootFilesKept: Sendable, Equatable {
    public let relative: String
    public let name: String
    public let at: Int64
    /// The Mac that made it (device id; the page shows its name).
    public let device: String
    public let bytes: Int64
    public let keptUntil: Int64
    public let hash: String
}

/// What "put the earlier version back" did (`putBackEarlierVersion`).
public enum BackendCloudBootFilesPutBack: Sendable, Equatable {
    /// The earlier version is in the file again; the version it replaced is kept.
    case putBack
    /// The earlier version is no longer held on this Mac. Nothing was changed.
    case earlierVersionGone
    /// The file is no longer the bytes that change wrote (edited or removed since). Nothing was changed.
    case changedSince
    /// Anything else that stops it (a link or a twin in the way, the place is gone, ...), by short code. Nothing was changed.
    case notPossible(String)
}

/// What the accept sheet shows for one line (security review M3): the EXACT bytes `accept` would write for it
/// (read back by the line's fingerprint), why it waits (worked out again from those bytes), and the lines to show.
public struct BackendCloudBootFilesReview: Sendable, Equatable {
    public let id: String
    public let relative: String
    public let hash: String
    public let bytes: Data
    public let reasons: [String]
    /// The header, every command or `@` line, the start of a script (`CloudBootFilesRules.shownLines`).
    public let lines: [CloudBootFilesShownLine]
    public let totalLines: Int
}

// MARK: In (apply): the dangerous half

extension BackendCloudBootFiles: CloudDomainAdapter {
    static let notBootFile = "Refused: not a boot file record."
    static let unreadableRecord = "Refused: the record cannot be read."
    static let tooLarge = "Refused: larger than 1 MB."
    static let notText = "Refused: not a text file."
    static let twinName = "Refused: the name differs only in letter case from a file this Mac already holds."
    static let engineRefusal = "Refused: the record does not match its own description."

    /// What a record claims about itself, checked against lane F's rules BEFORE lane A's engine stages a byte.
    struct Incoming: Sendable {
        let operation: CloudOperation
        let archive: Bool
        let sourceId: String
        let kind: CloudBootFilesPlaceKind
        let token: String
        let relative: String
        let hash: String
        let bytes: Int64
        let version: String
        let parents: [String]
    }

    /// Throws `CloudRecordRefusal` (the sync core parks that record and moves on) for: another domain, an
    /// unreadable payload, a key that is not `file/<place>/<path>`, a path that is not a boot file (a way out of the
    /// folder, settings, hooks, MCP, sign-in files, hidden names, a provider's memory or chats), a file over the
    /// size cap, and bytes that are not text.
    static func describe(_ operation: CloudOperation) throws -> Incoming {
        func refuse(_ reason: String) -> CloudRecordRefusal { CloudRecordRefusal(operationIds: [operation.opId], reason: reason) }
        guard operation.domain == CloudBootFilesFormat.domain else { throw refuse(notBootFile) }
        let key: String, hash: String, size: Int64, archive: Bool, body: Data, version: String, parents: [String]
        do {
            let payload = try CloudWire.canonical(operation.payload)
            switch operation.kind {
            case .put:
                let part = try CloudWire.decode(CloudBrainMemoryPart.self, from: payload, allowedKeys: BackendCloudBrainFiles.partKeys, maximumBytes: 65_536)
                guard let declared = Int64(part.bytes), declared >= 0, let data = Data(base64Encoded: part.data) else { throw CloudFailure.invalidRequest }
                key = part.key; hash = part.resourceHash; size = declared; archive = false; body = data
                version = part.version; parents = part.parents
            case .archive:
                let marker = try CloudWire.decode(CloudBrainFilesArchiveMarker.self, from: payload, allowedKeys: BackendCloudBrainFiles.markerKeys, maximumBytes: 65_536)
                key = marker.key; hash = marker.resourceHash; size = 0; archive = true; body = Data()
                version = marker.version; parents = marker.parents
            default: throw CloudFailure.unsupportedFormat
            }
        } catch { throw refuse(unreadableRecord) }
        // `file/project/<id>/<path>` or `file/home/<provider>/<id>/<path>`, split at slash BYTES.
        guard let fields = CloudBootFilesRules.parts(key), fields.count >= 4, fields[0] == "file" else { throw refuse(notBootFile) }
        let head = fields[1] == "project" ? 3 : 4
        guard fields.count > head else { throw refuse(notBootFile) }
        let sourceId = fields[1..<head].joined(separator: "/")
        guard BackendCloudBrainFilesSource.validSourceId(sourceId), let place = parse(sourceId: sourceId) else { throw refuse(notBootFile) }
        let relative = fields[head...].joined(separator: "/")
        if let refusal = CloudBootFilesRules.refusal(kind: place.kind, relative: relative) { throw refuse(refusal.sentence) }
        guard size <= Int64(CloudBootFilesFormat.maximumFileBytes) else { throw refuse(tooLarge) }
        guard !body.contains(0) else { throw refuse(notText) }
        return Incoming(operation: operation, archive: archive, sourceId: sourceId, kind: place.kind, token: place.token, relative: relative, hash: hash,
                        bytes: size, version: version, parents: parents)
    }

    /// Lane A's engine says "this record is wrong" with a plain failure. The sync core needs that as a refusal, or
    /// it retries the whole pack for ever. Failures that mean "try again later" stay as they are.
    static func refusal(_ failure: CloudFailure) -> CloudRecordRefusal? {
        switch failure {
        case .invalidRequest, .unsupportedFormat, .checksumMismatch, .idReused: return CloudRecordRefusal(reason: engineRefusal)
        default: return nil
        }
    }

    public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
        await enter()
        defer { leave() }
        let engine = try core()
        var incoming: [Incoming] = [], refused: [String] = [], reason: String?
        for operation in operations {
            do {
                if CloudFileDeleteRecords.isAbout(operation) {
                    // Review 15 Nov (MUST 3): a refusal of the one about-record (parked by the sync core; the pack goes on).
                    guard operation.domain == CloudBootFilesFormat.domain else {
                        throw CloudRecordRefusal(operationIds: [operation.opId], reason: CloudFileDeleteRecords.aboutRefusal)
                    }
                    do { _ = try CloudFileDeleteRecords.read(operation) }
                    catch { CloudFileDeleteRecords.noteRefused(operation, in: try state()); throw error }
                    continue
                }
                try incoming.append(Self.describe(operation))
            }
            catch let refusal as CloudRecordRefusal {
                if reason == nil { reason = refusal.reason }
                if refusal.reason == reason { refused += refusal.operationIds }
            }
        }
        if let reason { throw CloudRecordRefusal(operationIds: refused, reason: reason) }
        // A name that differs only in letter case from one this Mac already holds for the same place.
        for item in incoming where !item.archive && places[item.sourceId] != nil {
            if BackendCloudBootFilesDisk.twin(root: copy(item.sourceId), relative: item.relative) {
                throw CloudRecordRefusal(operationIds: [item.operation.opId], reason: Self.twinName)
            }
        }
        do { return try await CloudFileDeleteRecords.prepare(operations, files: files, engine: engine) }
        catch let failure as CloudFailure {
            if let refusal = Self.refusal(failure) { throw refusal }
            throw failure
        }
    }

    /// 1. This Mac's own unsent edits to the same files are recorded first, so an arriving version can never pass
    ///    for a successor of an edit it never saw. 2. The engine checks, assembles and keeps the records, in this
    ///    Mac's private copy only. 3. What waits is listed. 4. Each touched path is settled by the rules; a file is
    ///    written into a folder the person owns only by `write` below.
    public func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
        await enter()
        defer { leave() }
        let engine = try core()
        // Review 15 Nov (MUST 4, 5): this pack's about-records are saved first, each against the VERIFIED signer.
        try CloudFileDeleteRecords.takeAbouts(prepared.operations, signer: origin.deviceId, domain: CloudBootFilesFormat.domain, in: state())
        await finishBootArrivals(engine: engine)
        let incoming = try prepared.operations.filter { !CloudFileDeleteRecords.isAbout($0) }.map { try Self.describe($0) }
        let announced = await deleteRuleAnnounced(origin.deviceId.lowercased())
        var travels: [String: CloudDeleteTravelRemoval] = [:], cloudOnly: Set<String> = []
        for item in incoming where item.archive {
            let key = Self.deletePlace(item.sourceId, item.relative)
            let travel = CloudFileDeleteRecords.arrivedRemoval(item.operation, place: key, signer: origin.deviceId, announced: announced, in: try state())
            travels[item.operation.opId] = travel
            if case .intent(let intent) = travel, intent.scope == .cloud { cloudOnly.insert(key) }
        }
        var touched: [String: [String]] = [:]
        for item in incoming where places[item.sourceId] != nil {
            if touched[item.sourceId]?.contains(item.relative) != true { touched[item.sourceId, default: []].append(item.relative) }
        }
        for (sourceId, paths) in touched {
            guard let place = places[sourceId] else { continue }
            // Review 15 Nov (MUST 3): a disk stop on a person's file (a link, a twin, a folder that cannot be written) is a
            // refusal of this place's records in the sync core's own terms, never a plain error that replays the pack.
            do { try await settlePaths(place, paths.filter { !cloudOnly.contains(Self.deletePlace(sourceId, $0)) }, engine: engine) }
            catch let stop as BackendCloudBootFilesDisk.Stop {
                throw CloudRecordRefusal(operationIds: incoming.filter { $0.sourceId == sourceId }.map(\.operation.opId),
                                         reason: Self.diskStopRefusal + " (" + stop.reason + ")")
            }
        }
        let receipt: CloudImportReceipt
        do { receipt = try await CloudFileDeleteRecords.apply(prepared, origin: origin, engine: engine, db: state(), row: CloudBootFilesFormat.inventoryRow) }
        catch let failure as CloudFailure {
            if let refusal = Self.refusal(failure) { throw refusal }
            throw failure
        }
        try await note(incoming, receipt: receipt, origin: origin, engine: engine, travels: travels)
        for (sourceId, paths) in touched {
            guard let place = places[sourceId] else { continue }
            // The records are kept either way; a write that fails now is tried again at the next look.
            do { try await settlePaths(place, paths, engine: engine) } catch {}
        }
        if !incoming.isEmpty, let arrivalNotice { Task { await arrivalNotice() } }
        return receipt
    }

    public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification {
        let engine = try core()
        return try await CloudFileDeleteRecords.verify(receipt, db: state(), engine: engine, keeper: keeper(), kind: Self.binKind)
    }

    /// Who sent what (the VERIFIED signer, never a field inside the record), and what now waits.
    static let diskStopRefusal = "Waiting: an instruction file here could not be read or written safely. It is tried again later."
    func note(_ incoming: [Incoming], receipt: CloudImportReceipt, origin: CloudImportOrigin, engine: BackendCloudBrainFiles,
              travels: [String: CloudDeleteTravelRemoval] = [:]) async throws {
        let db = try state(), at = now()
        var kept: Set<String> = []
        for result in receipt.results where result.status == .keptBoth { kept.insert(result.entityId) }
        for item in incoming {
            let mapped = places[item.sourceId]
            let identity = mapped?.identity ?? item.operation.projectId ?? BackendCloudBrainFilesNames.untoken(item.token)
            try db.run("INSERT OR REPLACE INTO boot_versions(source_id,path,version,hash) VALUES (?,?,?,?)",
                       [.text(item.sourceId), .text(item.relative), .text(item.version), .text(item.hash)])
            if item.archive {
                // A file removed on another device no longer waits for a folder here (13 Nov leftover: count only what waits).
                try db.run("DELETE FROM boot_items WHERE kind='waiting-folder' AND source_id=? AND path=?", [.text(item.sourceId), .text(item.relative)])
                let key = item.sourceId + "\n" + item.relative
                let travel = travels[item.operation.opId]
                    ?? .intent(CloudFileDeleteRecords.safeIntent(item.operation, place: key, signer: origin.deviceId))
                try CloudFileDeleteRecords.saveHead(in: db, place: key, version: item.version, parents: item.parents,
                    at: item.operation.createdAt, mac: origin.deviceId.lowercased(), travel: travel)
                // Applied by the place's next settle in this same job (never an error of the pack; MUST 2).
                if let mapped { await retryBootRemovals(mapped, engine: engine) }
                continue
            }
            let key = item.sourceId + "\n" + item.relative
            // A new version from another device: the place is in the Cloud again, its old "Cloud" choice is forgotten.
            try CloudFileDeleteRecords.forgetCleared(key, in: state())
            if try deleteState().mark(at: key)?.mark == .onlyOnThisMac,
               try await engine.currentVersion(sourceId: item.sourceId, relative: item.relative)?.version == item.version {
                if let mapped, case .file(let bytes) = BackendCloudBootFilesDisk.read(root: mapped.root, relative: item.relative) {
                    try keep(bytes, hash: BackendCloudBrainMemoryHash.bytes(bytes), sourceId: item.sourceId, relative: item.relative,
                        device: deviceId, at: now())
                    try setBase(item.sourceId, item.relative, BackendCloudBrainMemoryHash.bytes(bytes))
                }
                try deleteState().clearMark(at: key)
                try keeper().binTake(itemKey: Self.itemKey(item.sourceId, item.relative), now: now())
            }
            try db.run("INSERT OR REPLACE INTO boot_origin(source_id,path,hash,origin) VALUES (?,?,?,?)",
                       [.text(item.sourceId), .text(item.relative), .text(item.hash), .text(origin.deviceId)])
            guard let place = mapped else {
                try put(.waitingFolder, sourceId: item.sourceId, identity: identity, relative: item.relative, hash: item.hash, bytes: item.bytes,
                        origin: origin.deviceId, reasons: [refusedPlaces[item.sourceId] ?? "no-folder"], at: at)
                continue
            }
            // The engine kept this version beside this Mac's file.
            guard kept.contains(item.operation.entityId) else { continue }
            let bytes = try? await retained(engine, hash: item.hash)
            let runs = bytes.map { CloudBootFilesRules.runReasons(relative: item.relative, bytes: $0) } ?? []
            if let bytes, try successor(place, item, bytes: bytes, runs: runs, origin: origin.deviceId) { continue }
            // The one rule (owner, 14 Nov): not the next version of this Mac's file, so the newer of the two is used.
            let version = BackendCloudBrainFiles.VersionInfo(version: item.version, parents: item.parents, createdAt: item.operation.createdAt,
                                                             rawHash: item.hash, originDevice: item.operation.originDevice)
            if let bytes, try await useNewest(place, item.relative, arrived: version, bytes: bytes, runs: runs, origin: origin.deviceId, engine: engine) {
                // Recorded at once, so a Restore pressed in the next seconds is made on top of it and travels.
                try await settlePaths(place, [item.relative], engine: engine)
                continue
            }
            try put(.otherVersion, sourceId: item.sourceId, identity: identity, relative: item.relative, hash: item.hash, bytes: item.bytes,
                    origin: origin.deviceId, reasons: ["local-differs"] + runs, at: at)
        }
    }

    /// Lane A's engine keeps a version beside this Mac's file whenever that version does not name the engine's own
    /// current version as its parent. Two Macs that each recorded the same bytes before they met take each
    /// other's version of them, and from then on neither names the other's as a parent: every later edit would be
    /// "kept beside" for ever. So lane F looks at the BYTES. A version whose parent had exactly the bytes this
    /// Mac's file has now, while this Mac has not changed the file since the folder and the copy last agreed, is
    /// the next version of this Mac's file. It is written over those bytes and nothing else (and waits for the
    /// person if it can run); the next look records it as this Mac's newest version, after which both Macs name
    /// the same version again. A parent this Mac never saw, or any local change, leaves it a kept version.
    func successor(_ place: BackendCloudBootFilesPlace, _ item: Incoming, bytes: Data, runs: [String], origin: String) throws -> Bool {
        guard BackendCloudBrainMemoryHash.bytes(bytes) == item.hash, CloudBootFilesRules.isText(bytes), bytes.count <= CloudBootFilesFormat.maximumFileBytes,
              CloudBootFilesRules.refusal(kind: place.kind, relative: item.relative) == nil,
              case .file(let local) = BackendCloudBootFilesDisk.read(root: place.root, relative: item.relative),
              case .file(let copied) = BackendCloudBootFilesDisk.read(root: copy(place.sourceId), relative: item.relative) else { return false }
        let held = BackendCloudBrainMemoryHash.bytes(local)
        guard try agreed(place.sourceId, item.relative) == held, BackendCloudBrainMemoryHash.bytes(copied) == held else { return false }
        let db = try state()
        var follows = false
        for parent in item.parents {
            let known = try db.first("SELECT 1 FROM boot_versions WHERE source_id=? AND path=? AND version=? AND hash=?",
                                     [.text(place.sourceId), .text(item.relative), .text(parent), .text(held)])
            if known != nil { follows = true }
        }
        guard follows else { return false }
        let accepted = try isAccepted(place.sourceId, item.relative, item.hash)
        if !runs.isEmpty && !accepted {
            try put(.otherVersion, sourceId: place.sourceId, identity: place.identity, relative: item.relative, hash: item.hash, bytes: item.bytes,
                    origin: origin, reasons: ["newer-version"] + runs, at: now())
            return true
        }
        try keep(local, hash: held, sourceId: place.sourceId, relative: item.relative, device: deviceId, at: now())
        do { try BackendCloudBootFilesDisk.replace(root: place.root, relative: item.relative, bytes: bytes, expecting: held) }
        catch is BackendCloudBootFilesDisk.Stop { return false }
        try madeAgain(place.sourceId, item.relative)
        // What both sides agree on stays the copy's bytes, so the next look records the new file as this Mac's version.
        try applied(place.sourceId, item.relative, hash: item.hash, origin: origin, how: "updated", replaced: held)
        return true
    }

    // MARK: The one rule (owner, 14 Nov: "the newest used everywhere")

    /// A version arrived that is not the next version of this Mac's file, and this Mac's file is its own recorded
    /// version (no edit waiting to be recorded). The newer of the two is used, by the same rule on every Mac
    /// (`CloudBootFilesRules.newest`), so both Macs end with the same file:
    /// - arrived newer: written over this Mac's file (only over the exact bytes just read); this Mac's version is kept
    ///   30 days and one line says so ("newer" in `changedFromOtherDevices`, with Show and Restore). A file that can run
    ///   a command waits for Accept instead, only under "Ask me for each new device".
    /// - this Mac's newer: nothing is written; it already travelled as the newest; the arrived one is kept 30 days.
    /// false when this cannot be decided now (an edit not recorded yet, something in the way); the caller lists it.
    /// `resendIfMine`: when this Mac's version wins, send it again as the newest (first-launch settling: the other Mac
    /// may no longer list the clash, so it must be told again to decide it).
    func useNewest(_ place: BackendCloudBootFilesPlace, _ relative: String, arrived: BackendCloudBrainFiles.VersionInfo, bytes: Data, runs: [String],
                   origin: String, engine: BackendCloudBrainFiles, resendIfMine: Bool = false) async throws -> Bool {
        guard BackendCloudBrainMemoryHash.bytes(bytes) == arrived.rawHash, CloudBootFilesRules.isText(bytes), bytes.count <= CloudBootFilesFormat.maximumFileBytes,
              CloudBootFilesRules.refusal(kind: place.kind, relative: relative) == nil,
              case .file(let local) = BackendCloudBootFilesDisk.read(root: place.root, relative: relative),
              case .file(let copied) = BackendCloudBootFilesDisk.read(root: copy(place.sourceId), relative: relative) else { return false }
        let held = BackendCloudBrainMemoryHash.bytes(local)
        guard try agreed(place.sourceId, relative) == held, BackendCloudBrainMemoryHash.bytes(copied) == held else { return false }
        // The same bytes: nothing to choose.
        if arrived.rawHash == held { try settled(place.sourceId, relative, arrived.rawHash); return true }
        guard let mine = try await engine.currentVersion(sourceId: place.sourceId, relative: relative), mine.rawHash == held else { return false }
        let pick = CloudBootFilesRules.newest(local: .init(at: mine.createdAt, device: mine.originDevice, firstCopy: mine.parents.isEmpty),
                                              arrived: .init(at: arrived.createdAt, device: arrived.originDevice, firstCopy: arrived.parents.isEmpty),
                                              now: now())
        if pick == .local {
            try keep(bytes, hash: arrived.rawHash, sourceId: place.sourceId, relative: relative, device: arrived.originDevice, at: arrived.createdAt)
            try settled(place.sourceId, relative, arrived.rawHash)
            if resendIfMine, try await engine.resend(sourceId: place.sourceId, relative: relative) { try await recordJournal(engine) }
            return true
        }
        // Swap-loop guard: replaced twice within the hour already: stop replacing; both stay, listed as before.
        if try swapping(place.sourceId, relative) {
            try put(.otherVersion, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: arrived.rawHash, bytes: Int64(bytes.count),
                    origin: origin, reasons: ["local-differs"] + runs, at: now())
            return true
        }
        if !runs.isEmpty, !(try isAccepted(place.sourceId, relative, arrived.rawHash)) {
            try put(.otherVersion, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: arrived.rawHash, bytes: Int64(bytes.count),
                    origin: origin, reasons: ["newer-version", "local-differs"] + runs, at: now())
            return true
        }
        try keep(local, hash: held, sourceId: place.sourceId, relative: relative, device: mine.originDevice, at: mine.createdAt)
        do { try BackendCloudBootFilesDisk.replace(root: place.root, relative: relative, bytes: bytes, expecting: held) }
        catch is BackendCloudBootFilesDisk.Stop { return false }
        // The file carries the arrived version's time, so recording it here does not make it look newer than it is.
        setModified(root: place.root, relative: relative, at: arrived.createdAt)
        try madeAgain(place.sourceId, relative)
        try settled(place.sourceId, relative, arrived.rawHash)
        // What both sides agree on stays the copy's bytes, so the next look records the file as this Mac's newest version.
        try applied(place.sourceId, relative, hash: arrived.rawHash, origin: origin, how: "newer", replaced: held)
        return true
    }
    /// The line that listed this arrived version as "kept beside" is done.
    func settled(_ sourceId: String, _ relative: String, _ hash: String) throws {
        try state().run("DELETE FROM boot_items WHERE kind='other-version' AND source_id=? AND path=? AND hash=?", [.text(sourceId), .text(relative), .text(hash)])
    }
    /// Never later than now: a version stamped by a clock that runs ahead does not put a future time on his file.
    func setModified(root: URL, relative: String, at: Int64) {
        let when = min(at, now())
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(when) / 1000)],
                                               ofItemAtPath: root.appendingPathComponent(relative).path)
    }
    /// True when this file was already replaced by a newer version twice within the last hour (two Macs swapping).
    func swapping(_ sourceId: String, _ relative: String) throws -> Bool {
        let count = try state().first("SELECT COUNT(*) FROM boot_applied WHERE source_id=? AND path=? AND how='newer' AND at>?",
                                      [.text(sourceId), .text(relative), .int(now() - 3_600_000)])?.int(0) ?? 0
        return count >= 2
    }

    /// Versions "kept beside" before this build (and any an earlier pass could not settle) follow the same rule, once
    /// each, with no question: the newer in use, the older kept 30 days, one line each. A runnable file that already
    /// waits for Accept under "Ask me" (`newer-version`) keeps waiting. A version kept beside because the file was
    /// removed here is left as it was (removals are not in this slice).
    func resolveKeptBeside(_ engine: BackendCloudBrainFiles) async throws {
        let rows = try state().rows("SELECT id,kind,source_id,identity,path,hash,bytes,origin,reasons,at FROM boot_items WHERE kind='other-version' ORDER BY at,id")
        for line in rows.compactMap(Self.line) where !line.reasons.contains("newer-version") {
            guard let place = places[line.sourceId] else { continue }
            guard let bytes = try? await retained(engine, hash: line.hash), BackendCloudBrainMemoryHash.bytes(bytes) == line.hash else { continue }
            // Without the arrived version's own record its real time is unknown: never guessed (the other Mac would decide
            // the same pair with the real times and could choose differently). The line stays exactly as it was.
            guard let version = try await engine.arrivedVersion(sourceId: line.sourceId, relative: line.relative, rawHash: line.hash) else { continue }
            let runs = CloudBootFilesRules.runReasons(relative: line.relative, bytes: bytes)
            // A file written here is recorded as this Mac's newest version at once, so it travels; the line goes.
            if try await useNewest(place, line.relative, arrived: version, bytes: bytes, runs: runs, origin: line.originDevice, engine: engine, resendIfMine: true) {
                try await settlePaths(place, [line.relative], engine: engine)
            }
        }
    }

    /// The 30-day keeper, once a day at most: kept versions older than 30 days are deleted on this Mac.
    func sweepDaily() throws {
        // Only on the service clock: a Mac clock that jumps forward must not delete everything kept.
        guard sweepOnLocalClock || outbox?.serviceTime() != nil else { return }
        let db = try state(), at = now()
        let last = try db.first("SELECT value FROM boot_meta WHERE key='versions-sweep'")?.int(0) ?? 0
        guard at - last >= 86_400_000 || at < last else { return }
        try keeper().sweep(before: at)
        let safety = stateRoot.appendingPathComponent("safety", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: safety.path)) ?? [] {
            guard let made = BackendCloudFolder.safetyStamp.date(from: name),
                  at - Int64(made.timeIntervalSince1970 * 1000) > CloudFolderFormat.safetyKeptFor else { continue }
            try? FileManager.default.removeItem(at: safety.appendingPathComponent(name))
        }
        try db.run("INSERT INTO boot_meta(key,value) VALUES ('versions-sweep',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(at)])
    }

    /// The versions this Mac keeps of one instruction file, newest first (for Show, and for lane L4's file manager).
    public func keptVersions(place: CloudBootFilesPlaceKind, identity: String, relative: String) throws -> [BackendCloudBootFilesKept] {
        let sourceId = Self.sourceId(kind: place, identity: identity)
        return try keeper().versions(itemKey: Self.itemKey(sourceId, relative)).map {
            BackendCloudBootFilesKept(relative: relative, name: $0.name, at: $0.at, device: $0.device, bytes: $0.bytes, keptUntil: $0.keptUntil, hash: $0.sha256)
        }
    }

    // MARK: The list

    func put(_ kind: BackendCloudBootFilesItem.Kind, sourceId: String, identity: String?, relative: String, hash: String, bytes: Int64,
             origin: String, reasons: [String], at: Int64) throws {
        let db = try state()
        let id = BackendCloudBrainMemoryHash.uuid([kind.rawValue, sourceId, relative, hash].joined(separator: "\n"))
        let waitsInCopy = kind == .needsAccept || kind == .keptVersion || kind == .blocked
        try db.transaction {
            // At most one line says what waits in the copy for a path; a newer arrival replaces the older line.
            if waitsInCopy {
                try db.run("DELETE FROM boot_items WHERE source_id=? AND path=? AND kind IN ('needs-accept','kept-version','blocked') AND id<>?",
                           [.text(sourceId), .text(relative), .text(id)])
            } else if kind != .replacedLocal {
                try db.run("DELETE FROM boot_items WHERE source_id=? AND path=? AND kind=? AND id<>?",
                           [.text(sourceId), .text(relative), .text(kind.rawValue), .text(id)])
            }
            try db.run("""
                INSERT INTO boot_items(id,kind,source_id,identity,path,hash,bytes,origin,reasons,at) VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET reasons=excluded.reasons, origin=excluded.origin
                """, [.text(id), .text(kind.rawValue), .text(sourceId), .optional(identity), .text(relative), .text(hash), .int(bytes), .text(origin),
                      .text(reasons.joined(separator: "\n")), .int(at)])
        }
    }

    static func line(_ row: DeckMemoryRow) -> BackendCloudBootFilesItem? {
        guard let kind = BackendCloudBootFilesItem.Kind(rawValue: row.text(1)), let parsed = parse(sourceId: row.text(2)) else { return nil }
        let reasons = row.text(8).isEmpty ? [] : row.text(8).components(separatedBy: "\n")
        return BackendCloudBootFilesItem(id: row.text(0), kind: kind, place: parsed.kind, identity: row.string(3), relative: row.text(4), hash: row.text(5),
                                         bytes: row.int(6), originDevice: row.text(7), reasons: reasons, at: row.int(9), sourceId: row.text(2))
    }

    /// Delete rule (integration): every instruction file this Mac and the Cloud agree on, read only, for the AI tools'
    /// targets (place, project id / account identity when known, path in its place). No Bin entry is here.
    public func trackedFiles() throws -> [BackendCloudBootFilesTracked] {
        try state().rows("SELECT source_id,path FROM boot_base ORDER BY source_id,path").compactMap { row in
            guard let parsed = Self.parse(sourceId: row.text(0)) else { return nil }
            return BackendCloudBootFilesTracked(sourceId: row.text(0), place: parsed.kind, identity: places[row.text(0)]?.identity, relative: row.text(1))
        }
    }
    /// Everything that waits or that the person should know about, oldest first.
    public func items() throws -> [BackendCloudBootFilesItem] {
        try state().rows("SELECT id,kind,source_id,identity,path,hash,bytes,origin,reasons,at FROM boot_items ORDER BY at,id").compactMap(Self.line)
    }
    func find(_ id: String) throws -> BackendCloudBootFilesItem? {
        try state().first("SELECT id,kind,source_id,identity,path,hash,bytes,origin,reasons,at FROM boot_items WHERE id=?", [.text(id)]).flatMap(Self.line)
    }

    /// Files written from other devices, newest first (for the "changed from your other devices" list that
    /// Security Ruling 2 / T13 requires on screen: every file applied by itself, and every accepted one).
    public func changedFromOtherDevices(limit: Int = 200) throws -> [BackendCloudBootFilesChange] {
        let sql = """
            SELECT a.source_id,a.path,a.hash,a.origin,a.how,a.at,r.hash FROM boot_applied a LEFT JOIN boot_replaced r ON r.seq=a.seq
            ORDER BY a.seq DESC LIMIT ?
            """
        return try state().rows(sql, [.int(Int64(max(1, min(limit, 1_000))))]).compactMap { row in
            guard let parsed = Self.parse(sourceId: row.text(0)) else { return nil }
            return BackendCloudBootFilesChange(place: parsed.kind, identity: places[row.text(0)]?.identity ?? BackendCloudBrainFilesNames.untoken(parsed.token),
                                               relative: row.text(1), hash: row.text(2), originDevice: row.text(3), how: row.text(4), at: row.int(5),
                                               previousHash: row.string(6))
        }
    }

    /// "Show previous version" for a line of `changedFromOtherDevices`: the bytes this Mac's file held before that
    /// change replaced them (pass `change.previousHash`). Only a version some change replaced can be read; read from
    /// this Mac's kept copy or the file engine's history, checked by fingerprint. nil when no longer held.
    public func earlierVersion(hash: String) async throws -> Data? {
        guard BackendCloudBrainFiles.isHash(hash) else { throw CloudFailure.invalidRequest }
        await enter()
        defer { leave() }
        guard try state().first("SELECT 1 FROM boot_replaced WHERE hash=?", [.text(hash)]) != nil else { throw CloudFailure.invalidRequest }
        return try await held(hash: hash)
    }

    /// The bytes of one version, from this Mac's kept copies or the file engine's history, checked by fingerprint.
    func held(hash: String) async throws -> Data? {
        if let held = keeper().content(kind: BackendCloudVersionKeeper.instructionFiles, sha256: hash) { return held }
        if let held = keeper().content(kind: Self.binKind, sha256: hash) { return held }
        let kept = stateRoot.appendingPathComponent("kept", isDirectory: true).appendingPathComponent(hash)
        if let held = try? Data(contentsOf: kept), BackendCloudBrainMemoryHash.bytes(held) == hash { return held }
        let engine = try core()
        guard let held = try? await retained(engine, hash: hash), BackendCloudBrainMemoryHash.bytes(held) == hash else { return nil }
        return held
    }

    /// "Put the earlier version back" for one line of `changedFromOtherDevices`. ONLY the Cloud page calls this,
    /// after the person read the earlier version and pressed the button; no tool and no feature action does.
    /// Writes the bytes the file held before that change, through `BackendCloudBootFilesDisk.replace` (no link
    /// followed, never outside the chosen folder, the same path rules as `accept`), and only over exactly the bytes
    /// that change wrote. The file it replaces is kept first (and listed as `replacedLocal`), so the put-back can
    /// itself be undone. Afterwards it is an ordinary edit made on this Mac: captured and sent like any other.
    public func putBackEarlierVersion(_ change: BackendCloudBootFilesChange) async throws -> BackendCloudBootFilesPutBack {
        let answer = try await putBackHeld(change)
        await coverageChanged()
        return answer
    }
    private func putBackHeld(_ change: BackendCloudBootFilesChange) async throws -> BackendCloudBootFilesPutBack {
        guard let previous = change.previousHash, BackendCloudBrainFiles.isHash(previous), BackendCloudBrainFiles.isHash(change.hash) else {
            return .notPossible("no-earlier-version")
        }
        await enter()
        defer { leave() }
        // The change must be one lane F wrote here, for a place still on this Mac.
        let rows = try state().rows("""
            SELECT a.source_id FROM boot_applied a JOIN boot_replaced r ON r.seq=a.seq WHERE a.path=? AND a.hash=? AND r.hash=? ORDER BY a.seq DESC
            """, [.text(change.relative), .text(change.hash), .text(previous)])
        var found: BackendCloudBootFilesPlace?
        for row in rows {
            if let candidate = places[row.text(0)], candidate.kind == change.place, candidate.identity == change.identity { found = candidate; break }
        }
        guard let place = found else { return .notPossible("not-listed") }
        guard CloudBootFilesRules.refusal(kind: place.kind, relative: change.relative) == nil else { return .notPossible("not-a-boot-file") }
        guard let earlier = try await held(hash: previous), CloudBootFilesRules.isText(earlier),
              earlier.count <= CloudBootFilesFormat.maximumFileBytes else { return .earlierVersionGone }
        let current: Data
        switch BackendCloudBootFilesDisk.read(root: place.root, relative: change.relative) {
        case .file(let bytes): current = bytes
        case .absent: return .changedSince
        case .blocked(let reason): return .notPossible(reason)
        }
        // Someone edited the file since that change wrote it: never overwritten.
        guard BackendCloudBrainMemoryHash.bytes(current) == change.hash else { return .changedSince }
        try keep(current, hash: change.hash, sourceId: place.sourceId, relative: change.relative, device: change.originDevice, at: now())
        do { try BackendCloudBootFilesDisk.replace(root: place.root, relative: change.relative, bytes: earlier, expecting: change.hash) }
        catch let stop as BackendCloudBootFilesDisk.Stop { return stop.reason == "changed" ? .changedSince : .notPossible(stop.reason) }
        try put(.replacedLocal, sourceId: place.sourceId, identity: place.identity, relative: change.relative, hash: change.hash,
                bytes: Int64(current.count), origin: change.originDevice, reasons: [], at: now())
        // What both sides agreed on is left as it was, so the next look sees this as a local edit and sends it.
        try await settlePaths(place, [change.relative], engine: try core())
        return .putBack
    }

    /// What the accept sheet shows before the person accepts one line (security review M3): the exact bytes
    /// `accept(_:)` would write for it, why it waits, and the lines to show. nil when the line is gone or cannot be
    /// accepted (a newer version replaced it: its id changed, and `accept` of the old id writes nothing).
    public func review(_ id: String) async throws -> BackendCloudBootFilesReview? {
        await enter()
        defer { leave() }
        guard let item = try find(id), item.canAccept else { return nil }
        let engine = try core()
        let bytes = try await retained(engine, hash: item.hash)
        guard BackendCloudBrainMemoryHash.bytes(bytes) == item.hash, CloudBootFilesRules.isText(bytes) else { return nil }
        let total = String(decoding: bytes, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).count
        return BackendCloudBootFilesReview(id: item.id, relative: item.relative, hash: item.hash, bytes: bytes,
                                           reasons: CloudBootFilesRules.runReasons(relative: item.relative, bytes: bytes),
                                           lines: CloudBootFilesRules.shownLines(relative: item.relative, bytes: bytes), totalLines: total)
    }

    func isAccepted(_ sourceId: String, _ relative: String, _ hash: String) throws -> Bool {
        if autoAccept { return true }
        return try state().first("SELECT 1 FROM boot_accepted WHERE source_id=? AND path=? AND hash=?", [.text(sourceId), .text(relative), .text(hash)]) != nil
    }
    func sender(_ sourceId: String, _ relative: String, _ hash: String) throws -> String {
        try state().first("SELECT origin FROM boot_origin WHERE source_id=? AND path=? AND hash=?", [.text(sourceId), .text(relative), .text(hash)])?.string(0) ?? ""
    }
    /// A place that is on this Mac now: nothing of it waits for a folder any more.
    func arrivalsHaveAFolder() throws {
        let db = try state()
        for id in order { try db.run("DELETE FROM boot_items WHERE kind='waiting-folder' AND source_id=?", [.text(id)]) }
    }
    /// The folder and the copy agree on this path: nothing waits for it.
    func inStep(_ place: BackendCloudBootFilesPlace, _ relative: String, hash: String?) throws {
        try state().run("DELETE FROM boot_items WHERE source_id=? AND path=? AND (kind IN ('needs-accept','kept-version','blocked') OR (kind='other-version' AND hash=?))",
                        [.text(place.sourceId), .text(relative), .text(hash ?? "")])
    }
    /// A newer version is in the folder now: "removed on another device" no longer describes this path.
    func madeAgain(_ sourceId: String, _ relative: String) throws {
        try state().run("DELETE FROM boot_items WHERE source_id=? AND path=? AND kind='removed-elsewhere'", [.text(sourceId), .text(relative)])
    }
    /// Something lane F will not read through or write over stands where the file would be.
    func obstructed(_ place: BackendCloudBootFilesPlace, _ relative: String, reason: String, copy: Data?, base: String?) throws {
        guard let copy else { return }
        let hash = BackendCloudBrainMemoryHash.bytes(copy)
        guard hash != base else { return }
        try put(.blocked, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: hash, bytes: Int64(copy.count),
                origin: sender(place.sourceId, relative, hash), reasons: [reason], at: now())
    }

    // MARK: Copy -> folder

    func arrive(_ place: BackendCloudBootFilesPlace, _ relative: String, step: CloudBootFilesStep, bytes: Data, hash: String, local: String?, runs: [String],
                localAt: Int64 = 0, arrivedAt: Int64? = nil) throws {
        let origin = try sender(place.sourceId, relative, hash)
        switch step {
        case .needsAccept:
            // Over a file edited here (the one rule picked the arrived version), the sheet says this Mac's file is replaced.
            let seen = try agreed(place.sourceId, relative)
            let differs = local != nil && local != seen
            try put(.needsAccept, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: hash, bytes: Int64(bytes.count),
                    origin: origin, reasons: (differs ? ["newer-version", "local-differs"] : []) + runs, at: now())
        case .useArrived:
            if try swapping(place.sourceId, relative) {
                try put(.keptVersion, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: hash, bytes: Int64(bytes.count),
                        origin: origin, reasons: ["local-differs"] + CloudBootFilesRules.runReasons(relative: relative, bytes: bytes), at: now())
                return
            }
            try write(place, relative, bytes: bytes, hash: hash, replacing: local, origin: origin, how: "newer", replacedAt: localAt, arrivedAt: arrivedAt)
        case .keepBoth:
            let reasons = [local == nil ? "removed-here" : "local-differs"] + CloudBootFilesRules.runReasons(relative: relative, bytes: bytes)
            try put(.keptVersion, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: hash, bytes: Int64(bytes.count),
                    origin: origin, reasons: reasons, at: now())
        case .write:
            try write(place, relative, bytes: bytes, hash: hash, replacing: local, origin: origin, how: local == nil ? "created" : "updated")
        case .nothing, .captureLocal, .captureRemoval, .useLocal:
            break
        }
    }

    /// THE ONLY PLACE a file from another device is written into a folder the person owns.
    /// The destination is the place's root plus a path the rules accept, walked without following any link;
    /// a new file is created only where nothing is; an existing one is replaced only if it still holds exactly
    /// `replacing`. Anything else stops the write and is listed. Nothing is run; a script (`#!`) is written runnable.
    func write(_ place: BackendCloudBootFilesPlace, _ relative: String, bytes: Data, hash: String, replacing: String?, origin: String, how: String,
               replacedAt: Int64? = nil, arrivedAt: Int64? = nil) throws {
        func stopped(_ reason: String) throws {
            try put(.blocked, sourceId: place.sourceId, identity: place.identity, relative: relative, hash: hash, bytes: Int64(bytes.count),
                    origin: origin, reasons: [reason], at: now())
        }
        // Asked again at the point of writing: what lane A's engine let through is not taken on trust.
        guard CloudBootFilesRules.refusal(kind: place.kind, relative: relative) == nil, bytes.count <= CloudBootFilesFormat.maximumFileBytes,
              CloudBootFilesRules.isText(bytes), BackendCloudBrainMemoryHash.bytes(bytes) == hash else {
            try stopped("not-a-boot-file")
            return
        }
        // A setup file that holds a password or key is never written from plain records (the sender holds it back too).
        if BackendCloudBootFilesDisk.setupHoldsSecret(kind: place.kind, relative: relative, bytes: bytes) {
            try stopped("holds-secret")
            return
        }
        // The bytes about to be replaced are kept, so "Show previous version" can read them (security review M4).
        if let replacing, case .file(let held) = BackendCloudBootFilesDisk.read(root: place.root, relative: relative),
           BackendCloudBrainMemoryHash.bytes(held) == replacing {
            var who = deviceId
            if how != "newer" { who = try sender(place.sourceId, relative, replacing) }
            try keep(held, hash: replacing, sourceId: place.sourceId, relative: relative, device: who.isEmpty ? deviceId : who, at: replacedAt ?? now())
        }
        do {
            if let replacing { try BackendCloudBootFilesDisk.replace(root: place.root, relative: relative, bytes: bytes, expecting: replacing) }
            else { try BackendCloudBootFilesDisk.create(root: place.root, relative: relative, bytes: bytes) }
        } catch let stop as BackendCloudBootFilesDisk.Stop {
            try stopped(stop.reason)
            return
        }
        // The file carries the arrived version's time, so recording it here does not make it look newer than it is.
        if let arrivedAt { setModified(root: place.root, relative: relative, at: arrivedAt) }
        try setBase(place.sourceId, relative, hash)
        try inStep(place, relative, hash: hash)
        try madeAgain(place.sourceId, relative)
        try applied(place.sourceId, relative, hash: hash, origin: origin, how: how, replaced: replacing)
    }

    /// One line of the "changed from your other devices" list, with the fingerprint of what it replaced.
    func applied(_ sourceId: String, _ relative: String, hash: String, origin: String, how: String, replaced: String?) throws {
        let db = try state()
        let seq = try db.run("INSERT INTO boot_applied(source_id,path,hash,origin,how,at) VALUES (?,?,?,?,?,?)",
                             [.text(sourceId), .text(relative), .text(hash), .text(origin), .text(how), .int(now())])
        if let replaced, replaced != hash {
            try db.run("INSERT OR REPLACE INTO boot_replaced(seq,hash) VALUES (?,?)", [.int(seq), .text(replaced)])
        }
    }

    /// The kept bytes of one version, read back from lane A's engine by fingerprint.
    func retained(_ engine: BackendCloudBrainFiles, hash: String) async throws -> Data {
        var data = Data()
        let slice = 262_144
        while data.count <= CloudBootFilesFormat.maximumFileBytes {
            let chunk = try await engine.readRetained(rawHash: hash, offset: Int64(data.count), limit: slice)
            data.append(chunk)
            if chunk.count < slice { break }
        }
        return data
    }

    // MARK: The person's two answers (lane A's sheet calls these; no tool does)

    /// "Use this version on this Mac." For a file that can run a command or grant tools, and for a version kept
    /// beside this Mac's file. Writes exactly the bytes the line named (checked by fingerprint), by the same rules
    /// as `write`. If this Mac's file differs, it is kept first and listed as `replacedLocal`.
    /// Returns the ids that were written.
    @discardableResult
    public func accept(_ ids: [String]) async throws -> [String] {
        let written = try await acceptHeld(ids)
        await coverageChanged()
        return written
    }
    private func acceptHeld(_ ids: [String]) async throws -> [String] {
        await enter()
        defer { leave() }
        let engine = try core(), db = try state()
        var written: [String] = [], touched: [String: BackendCloudBootFilesPlace] = [:]
        for id in ids {
            guard let item = try find(id), item.canAccept, let place = places[item.sourceId] else { continue }
            let bytes = try await retained(engine, hash: item.hash)
            guard BackendCloudBrainMemoryHash.bytes(bytes) == item.hash, CloudBootFilesRules.refusal(kind: place.kind, relative: item.relative) == nil,
                  bytes.count <= CloudBootFilesFormat.maximumFileBytes, CloudBootFilesRules.isText(bytes),
                  !BackendCloudBootFilesDisk.setupHoldsSecret(kind: place.kind, relative: item.relative, bytes: bytes) else { continue }
            let previous: Data?
            var replaced: String?
            switch BackendCloudBootFilesDisk.read(root: place.root, relative: item.relative) {
            case .absent: previous = nil
            case .file(let found): previous = found
            case .blocked(let reason):
                try put(.blocked, sourceId: item.sourceId, identity: item.identity, relative: item.relative, hash: item.hash, bytes: item.bytes,
                        origin: item.originDevice, reasons: [reason], at: now())
                continue
            }
            do {
                if let previous {
                    let old = BackendCloudBrainMemoryHash.bytes(previous)
                    if old != item.hash {
                        replaced = old
                        // This Mac's own version (not merely the older one it last saw from Cloud) is kept before it is replaced.
                        let seen = try agreed(item.sourceId, item.relative)
                        let merelyOlder = old == seen && (item.kind == .needsAccept || item.reasons.contains("newer-version"))
                        let own = !merelyOlder
                        try keep(previous, hash: old, sourceId: item.sourceId, relative: item.relative, device: deviceId, at: now())
                        try BackendCloudBootFilesDisk.replace(root: place.root, relative: item.relative, bytes: bytes, expecting: old)
                        if own {
                            try put(.replacedLocal, sourceId: item.sourceId, identity: item.identity, relative: item.relative, hash: old, bytes: Int64(previous.count),
                                    origin: deviceId, reasons: [], at: now())
                        }
                    }
                } else {
                    try BackendCloudBootFilesDisk.create(root: place.root, relative: item.relative, bytes: bytes)
                }
            } catch let stop as BackendCloudBootFilesDisk.Stop {
                try put(.blocked, sourceId: item.sourceId, identity: item.identity, relative: item.relative, hash: item.hash, bytes: item.bytes,
                        origin: item.originDevice, reasons: [stop.reason], at: now())
                continue
            }
            try db.run("INSERT OR REPLACE INTO boot_accepted(source_id,path,hash,at) VALUES (?,?,?,?)",
                       [.text(item.sourceId), .text(item.relative), .text(item.hash), .int(now())])
            // What both sides agree on is what the copy holds: if that is not the accepted version, the next look
            // records the accepted file as this Mac's newest version.
            var agreedHash = item.hash
            if case .file(let held) = BackendCloudBootFilesDisk.read(root: copy(item.sourceId), relative: item.relative) { agreedHash = BackendCloudBrainMemoryHash.bytes(held) }
            try setBase(item.sourceId, item.relative, agreedHash)
            try madeAgain(item.sourceId, item.relative)
            try db.run("DELETE FROM boot_items WHERE id=?", [.text(id)])
            try applied(item.sourceId, item.relative, hash: item.hash, origin: item.originDevice, how: "accepted", replaced: replaced)
            written.append(id)
            touched[item.sourceId] = place
        }
        for place in touched.values { try await settlePlace(place, engine: engine) }
        return written
    }

    /// "Keep this Mac's file" for a version that waits in the copy (this Mac's file, or its absence, becomes the
    /// newest version; the other one stays readable in history), or "hide this line" for the lines that only inform.
    /// A line that waits for a folder cannot be dismissed.
    public func dismiss(_ ids: [String]) async throws {
        try await dismissHeld(ids)
        await coverageChanged()
    }
    private func dismissHeld(_ ids: [String]) async throws {
        await enter()
        defer { leave() }
        let engine = try core(), db = try state()
        var touched: [String: BackendCloudBootFilesPlace] = [:]
        for id in ids {
            guard let item = try find(id), item.kind != .waitingFolder else { continue }
            if item.kind == .needsAccept || item.kind == .keptVersion, let place = places[item.sourceId] {
                try setBase(item.sourceId, item.relative, item.hash)
                touched[item.sourceId] = place
            }
            try db.run("DELETE FROM boot_items WHERE id=?", [.text(id)])
        }
        for place in touched.values {
            // Twice: a file that is absent here is recorded as removed only at the second look.
            try await settlePlace(place, engine: engine)
            try await settlePlace(place, engine: engine)
        }
    }

    /// Bytes about to be replaced (or a version that lost under the one rule), kept 30 days in the versions place
    /// (`archive/versions`, contracts section 2) with what they were: which file, which Mac made them, when.
    func keep(_ bytes: Data, hash: String, sourceId: String, relative: String, device: String, at: Int64) throws {
        guard BackendCloudBrainMemoryHash.bytes(bytes) == hash else { throw CloudFailure.checksumMismatch }
        try keeper().keep(kind: BackendCloudVersionKeeper.instructionFiles, itemKey: Self.itemKey(sourceId, relative),
                          name: CloudVersionReplacedLine.fileName(relative), place: places[sourceId]?.identity, at: at, device: device, content: bytes, now: now())
    }
    /// The versions table's key for one instruction file. Never shown.
    static func itemKey(_ sourceId: String, _ relative: String) -> String {
        BackendCloudContents.Kind.instructionFiles.rawValue + "|" + sourceId + "|" + relative
    }
    /// Reads one kept local version (a `replacedLocal` line).
    public func keptLocal(hash: String) throws -> Data {
        guard BackendCloudBrainFiles.isHash(hash) else { throw CloudFailure.invalidRequest }
        if let held = keeper().content(kind: BackendCloudVersionKeeper.instructionFiles, sha256: hash) { return held }
        if let held = keeper().content(kind: Self.binKind, sha256: hash) { return held }
        return try Data(contentsOf: stateRoot.appendingPathComponent("kept", isDirectory: true).appendingPathComponent(hash))
    }
}
