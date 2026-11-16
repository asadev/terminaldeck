import Foundation
import UniformTypeIdentifiers
import TerminalDeckNativeCore

/// Open files with every Mac off (15 Nov; design `macos/night/codex/cloud-open-files-design.md`, contract C). A Cloud
/// folder or artifact FILE on the shelf (a picture, a PDF, any binary, a text over 1 MB) carries `fileHash`, `fileBytes`
/// and `fileType`; the service answers which files it still needs (`needFiles`) and the Mac sends their bytes in 1 MiB
/// pieces to `POST /v1/shelf/files`, one file at a time, oldest request first, inside the Cloud folder's own daily send
/// allowance. Safe with the service live before this: no `limits.fileKinds` in its answer = no file fields on any row,
/// nothing hashed, nothing sent; a missing route or any refusal = nothing more until the next daily put, never an error.
extension BackendCloudShelf {
    /// The kinds whose files go up (the brief: the Cloud folder and artifacts).
    public static let fileKinds: Set<BackendCloudContents.Kind> = [.cloudFolder, .artifacts]
    public static let filePieceBytes = 1_048_576
    /// The Cloud folder's own cap (`CloudFolderFormat.maximumFileBytes`) = the service's.
    public static let fileMaxBytes: Int64 = CloudFolderFormat.maximumFileBytes
    /// At most this much is sent in one round (the shelf looks every 30 s); the first piece of a round always goes.
    public static let filesRoundBytes = 8 * 1_048_576
    /// Files count in the Cloud folder's daily send allowance (shared with artifacts) and stop at half of it, so his
    /// own new and changed files always keep at least the other half of the day.
    public static let filesDayShare: Int64 = CloudFolderFormat.dailySendBytes / 2
    /// At most this much is read for hashes in one round (the first fill spreads over a few rounds).
    public static let hashRoundBytes: Int64 = 256_000_000
    /// The service's type check (`FILE_TYPE`): anything else is sent as `application/octet-stream`.
    static let typePattern = #"^[a-z0-9][a-z0-9.+-]{0,63}/[a-z0-9][a-z0-9.+-]{0,63}$"#

    /// One file the service still needs: its hash and the pieces it does not hold yet.
    public struct NeedFile: Codable, Sendable, Equatable {
        public var hash: String
        public var pieces: [Int]
        public init(hash: String, pieces: [Int]) { self.hash = hash; self.pieces = pieces }
    }
    /// What one file is, once read. `hash` nil = never sent (over 25 MB, or it holds a known secret).
    public struct FileFact: Codable, Sendable, Equatable {
        public let hash: String?
        public let bytes: Int64
        public let type: String
        public init(hash: String?, bytes: Int64, type: String) { self.hash = hash; self.bytes = bytes; self.type = type }
    }
    /// One listed item that may be a file: where it is on this Mac and whether the page calls it text.
    public struct FileAsk: Sendable {
        public let item: String
        public let kind: BackendCloudContents.Kind
        public let root: URL
        public let relative: String
        public let isText: Bool
        public init(item: String, kind: BackendCloudContents.Kind, root: URL, relative: String, isText: Bool) {
            self.item = item; self.kind = kind; self.root = root; self.relative = relative; self.isText = isText
        }
    }
    /// What `fileFacts` found: per page item its cache key and fact, the facts to keep, and whether hashing is unfinished.
    public struct FilesFound: Sendable {
        public var byItem: [String: (key: String, fact: FileFact)] = [:]
        public var keep: [String: FileFact] = [:]
        public var pending = false
        /// How many files were read for a hash this round (0 when everything was known).
        public var read = 0
        public init() {}
    }

    /// The type from the name's ending (UTType), lower case; unknown or unusual = `application/octet-stream`.
    public static func fileType(_ relative: String) -> String {
        let ending = (relative as NSString).pathExtension
        guard !ending.isEmpty, let mime = UTType(filenameExtension: ending)?.preferredMIMEType?.lowercased(),
              mime.range(of: typePattern, options: .regularExpression) != nil else { return "application/octet-stream" }
        return mime
    }
    public static func filePieces(_ bytes: Int64) -> Int { max(1, Int((bytes + Int64(filePieceBytes) - 1) / Int64(filePieceBytes))) }
    /// Piece `index` of `data`: bytes [index * 1 MiB, min((index + 1) * 1 MiB, size)); nil when out of range.
    public static func filePiece(_ data: Data, _ index: Int) -> Data? {
        guard index >= 0, index < filePieces(Int64(data.count)) else { return nil }
        let start = data.startIndex + index * filePieceBytes
        return data.subdata(in: start..<min(start + filePieceBytes, data.endIndex))
    }
    static func fileKey(_ kind: Kind, _ relative: String, _ stamp: CloudFolderDisk.Stamp) -> String {
        kind.rawValue + "|" + relative + "|" + String(stamp.bytes) + "|" + String(stamp.modified)
    }
    /// The same secret check the shelf's texts use.
    static func fileHoldsSecret(_ relative: String, _ data: Data) -> Bool {
        CloudArtifactsFormat.holdsSecret(relative, data) || BackendSharedRedact.containsKnownSecret(String(decoding: data, as: UTF8.self))
    }

    /// The facts of the listed files, read with the Cloud folder's own reader (never through a link). A file whose size
    /// and change time are in `known` is never read again. Text items up to 1 MB are not files (they go as texts). At most
    /// `budget` bytes are read; the rest waits for the next round (`pending`). Call it off the main thread.
    public static func fileFacts(_ asks: [FileAsk], known: [String: FileFact], budget: Int64 = hashRoundBytes) -> FilesFound {
        var found = FilesFound()
        var spent: Int64 = 0
        for ask in asks {
            guard !ask.relative.isEmpty, let stamp = CloudFolderDisk.stamp(ask.root, ask.relative) else { continue }
            if ask.isText, stamp.bytes <= Int64(textMaxBytes) { continue }
            let key = fileKey(ask.kind, ask.relative, stamp)
            let type = fileType(ask.relative)
            var fact = known[key]
            if fact == nil, stamp.bytes > fileMaxBytes { fact = FileFact(hash: nil, bytes: stamp.bytes, type: type) }
            if fact == nil {
                guard spent == 0 || spent + stamp.bytes <= budget else { found.pending = true; continue }
                guard case .file(let data) = CloudFolderDisk.read(ask.root, ask.relative), Int64(data.count) == stamp.bytes,
                      CloudFolderDisk.stamp(ask.root, ask.relative) == stamp else { continue }   // a link, gone, or changing now
                spent += stamp.bytes
                found.read += 1
                fact = FileFact(hash: fileHoldsSecret(ask.relative, data) ? nil : hash(data), bytes: stamp.bytes, type: type)
            }
            guard let fact else { continue }
            found.keep[key] = fact
            found.byItem[ask.item] = (key, fact)
        }
        return found
    }
    /// The bytes of a file the service asked for, read again from disk: only when they are still exactly `hash` (a file
    /// changed since the list is skipped; the next list put names its new bytes). nil = do not send.
    public static func fileBytes(root: URL, relative: String, hash expected: String) -> Data? {
        guard let stamp = CloudFolderDisk.stamp(root, relative), stamp.bytes <= fileMaxBytes,
              case .file(let data) = CloudFolderDisk.read(root, relative), Int64(data.count) == stamp.bytes,
              hash(data) == expected, !fileHoldsSecret(relative, data) else { return nil }
        return data
    }
    /// A row with its file's three fields (only a file with a hash: one over 25 MB or holding a secret gets none).
    public static func withFile(_ row: Row, _ fact: FileFact?) -> Row {
        guard let fact, let hash = fact.hash, fact.bytes <= fileMaxBytes else { return row }
        var made = row
        made.fileHash = hash; made.fileBytes = fact.bytes; made.fileType = fact.type
        return made
    }

    /// A list put's answer: what the service still needs of this kind's files. Nothing (or an answer without
    /// `needFiles`) = nothing owed. Files already done in an unfinished fill keep counting ("12 of 80").
    static func ask(_ known: inout BackendCloudShelfPutter.KindState, kind: Kind, needFiles: [NeedFile]?, now: Int64) {
        guard fileKinds.contains(kind) else { return }
        var seen: Set<String> = []
        let need = (needFiles ?? []).compactMap { file -> NeedFile? in
            guard file.hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, seen.insert(file.hash).inserted else { return nil }
            let pieces = Array(Set(file.pieces.filter { $0 >= 0 && $0 < filePieces(fileMaxBytes) })).sorted()
            return pieces.isEmpty ? nil : NeedFile(hash: file.hash, pieces: pieces)
        }
        guard !need.isEmpty else {
            known.filesOwed = nil; known.filesAsked = nil; known.filesDone = nil; known.filesAskedAt = nil
            return
        }
        let unfinished = !(known.filesOwed ?? []).isEmpty
        let done = unfinished ? (known.filesDone ?? 0) : 0
        known.filesOwed = need
        known.filesDone = done
        known.filesAsked = done + need.count
        if !unfinished || known.filesAskedAt == nil { known.filesAskedAt = now }
    }
}

extension BackendCloudShelfPutter {
    struct FileBody: Encodable { let kind: String; let hash: String; let piece: Int; let data: String }
    struct FileAnswer: Decodable { let stored: Bool?; let complete: Bool?; let code: String? }

    /// The service keeps files of this kind (its `limits.fileKinds`) and the setting is on.
    public func filesLive(_ kind: Kind) -> Bool {
        state.on && !missing && BackendCloudShelf.fileKinds.contains(kind) && (state.fileKinds ?? []).contains(kind.rawValue)
    }
    /// The service's file kinds are asked once a day (`GET /v1/shelf`), so a service updated later is found by itself.
    public func filesLookDue(now: Int64) -> Bool { now - (state.fileKindsAt ?? 0) >= BackendCloudShelf.dayMs }
    public func knownFiles() -> [String: BackendCloudShelf.FileFact] { state.files ?? [:] }
    /// Keeps only the facts of files still listed, so the cache never grows past the shelf.
    public func rememberFiles(_ facts: [String: BackendCloudShelf.FileFact]) {
        guard facts != (state.files ?? [:]) else { return }
        state.files = facts.isEmpty ? nil : facts
        save()
    }
    /// "12 of 80" while files are still going up; nil when nothing is owed.
    public func filesProgress() -> (done: Int, total: Int)? {
        var done = 0, total = 0
        for kind in BackendCloudShelf.fileKinds where filesLive(kind) {
            guard let known = state.kinds[kind.rawValue], !(known.filesOwed ?? []).isEmpty else { continue }
            done += known.filesDone ?? 0; total += known.filesAsked ?? 0
        }
        return total > done ? (done, total) : nil
    }

    func update(_ kind: Kind, save persist: Bool = true, _ change: (inout KindState) -> Void) {
        var known = state.kinds[kind.rawValue] ?? KindState()
        change(&known)
        state.kinds[kind.rawValue] = known
        if persist { save() }
    }
    /// A refusal: nothing is owed and nothing is sent for a day (the next daily put asks again).
    func holdFiles(_ kinds: Set<Kind>, now: Int64) {
        for kind in kinds {
            update(kind) { $0.filesOwed = nil; $0.filesAsked = nil; $0.filesDone = nil; $0.filesAskedAt = nil; $0.filesHoldUntil = now + BackendCloudShelf.dayMs }
        }
    }
    /// One file is finished (sent, or not to be sent: changed, gone, refused): it leaves the owed list.
    func finishFile(_ kind: Kind, _ hash: String, sent: Bool) {
        update(kind) { known in
            known.filesOwed?.removeAll { $0.hash == hash }
            if sent { known.filesDone = (known.filesDone ?? 0) + 1 } else { known.filesAsked = max(known.filesDone ?? 0, (known.filesAsked ?? 1) - 1) }
            if known.filesOwed?.isEmpty == true { known.filesOwed = nil; known.filesAsked = nil; known.filesDone = nil; known.filesAskedAt = nil }
        }
    }

    /// Sends what the service asked for: one file at a time (oldest request first, the service's own order within a
    /// kind), piece by piece, each stored piece written off at once so a quit resumes where it stopped (the first round
    /// after a launch asks `GET /v1/shelf?kind=` what is still missing). `maySend` is the day's allowance, `spent` books
    /// what went, `bytes` reads a file for its hash again (nil = changed or gone: skipped). Returns the pieces sent.
    @discardableResult
    public func sendFiles(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                          maySend: @Sendable (Int64) -> Bool, spent: @Sendable (Int64) -> Void,
                          bytes: @Sendable (Kind, String) async -> Data?) async -> Int {
        var sentBytes = 0, sentPieces = 0
        // A stored piece is written off in memory and saved once when this call ends (not per piece): after a quit the
        // first round asks the service which pieces are still missing, so nothing is sent twice either way.
        defer { if sentPieces > 0 { save() } }
        while sentBytes < BackendCloudShelf.filesRoundBytes, state.on, !missing {
            let waiting = BackendCloudShelf.fileKinds.filter { kind in
                guard filesLive(kind), let known = state.kinds[kind.rawValue], !(known.filesOwed ?? []).isEmpty else { return false }
                return (known.filesHoldUntil ?? 0) <= now && (filesRetryAt[kind] ?? 0) <= now
            }
            guard let kind = waiting.min(by: { (state.kinds[$0.rawValue]?.filesAskedAt ?? 0, $0.rawValue) < (state.kinds[$1.rawValue]?.filesAskedAt ?? 0, $1.rawValue) })
            else { break }
            // After a launch: what is really still missing (pieces sent before a quit are not sent again).
            if !filesFresh.contains(kind) {
                filesFresh.insert(kind)
                guard let status = await status(kind: kind) else { return sentPieces }
                guard let need = status.needFiles else { holdFiles([kind], now: now); continue }   // a service without files
                update(kind) { BackendCloudShelf.ask(&$0, kind: kind, needFiles: need, now: now) }
                continue
            }
            guard let file = state.kinds[kind.rawValue]?.filesOwed?.first else { break }
            guard let data = await bytes(kind, file.hash), Int64(data.count) <= BackendCloudShelf.fileMaxBytes else {
                finishFile(kind, file.hash, sent: false); continue
            }
            var whole = true
            for piece in file.pieces {
                guard let chunk = BackendCloudShelf.filePiece(data, piece) else { whole = false; break }
                if sentBytes > 0, sentBytes + chunk.count > BackendCloudShelf.filesRoundBytes { return sentPieces }
                guard maySend(Int64(chunk.count)),
                      let body = try? JSONEncoder().encode(FileBody(kind: kind.rawValue, hash: file.hash, piece: piece, data: chunk.base64EncodedString()))
                else { return sentPieces }
                switch await call("POST", "/shelf/files", body, quiet404: true) {
                case .ok(let answered):
                    let answer = try? JSONDecoder().decode(FileAnswer.self, from: answered)
                    guard answer?.stored == true else {
                        // not_on_shelf (the list changed), bad_piece, file_mismatch (bytes changed since the hash: it is
                        // read and hashed again), anything unknown: this file is left; the next list put asks afresh.
                        if answer?.code == "file_mismatch" { state.files = state.files?.filter { $0.value.hash != file.hash } }
                        whole = false
                        break
                    }
                    spent(Int64(chunk.count))
                    sentBytes += chunk.count; sentPieces += 1
                    update(kind, save: false) { known in
                        guard let at = known.filesOwed?.firstIndex(where: { $0.hash == file.hash }) else { return }
                        known.filesOwed?[at].pieces.removeAll { $0 == piece }
                    }
                case .lost:
                    return sentPieces
                case .refused(let status, let code, let retryAfterMs):
                    if status == 429 {
                        filesRetryAt[kind] = now + Int64(max(retryAfterMs ?? 0, Int(BackendCloudShelf.settleMs)))
                        return sentPieces
                    }
                    // A service without the route (404), the shelf turned off, or any other refusal: nothing more is
                    // sent until the next daily put; a 404 also leaves the file fields off until the next daily look.
                    if status == 404 || code == "not_found" { state.fileKinds = []; state.fileKindsAt = now }
                    holdFiles(BackendCloudShelf.fileKinds, now: now)
                    return sentPieces
                }
                if !whole { break }
            }
            finishFile(kind, file.hash, sent: whole)
        }
        return sentPieces
    }
}
