import CryptoKit
import Foundation
import TerminalDeckNativeCore

/// Mac shelf (owner, 15 Nov: "phones show his Cloud content when no Mac is on"; "I need every single thing in cloud").
/// Each Mac keeps a small shelf of what is in his Cloud NOW and puts it to the Cloud service, so his phones and the web
/// can list it (and read his notes and instruction files) when every Mac is off. Contract: Servers note
/// `2026-11-15-cloud-readable-with-no-mac.md` part 7.
///
/// ONE source of truth: the shelf is made from the very model the Your Cloud page draws (`BackendCloudContents`, with
/// the delete rule's marks applied), so a phone lists exactly what the Mac's page lists. What never leaves: the Bin,
/// "Only on this Mac" / "Not on this Mac" items, items still sending or refused, saved passwords, a secret setting's value
/// (slice 2: other settings are listed with their value in plain words), the "Other" kind and anything secrets-class
/// (`servedKinds` is the only door). Names are his words, never ids.
///
/// 15 Nov: saved passwords and project secret files join in a SEALED form the service cannot open: `sealedKinds`, made by
/// the saved-passwords owner (`BackendCloudSecretsGraph.shelfSealed`), sealed and put by `BackendCloudShelfSealed` /
/// `BackendCloudShelfSealedPutter` on their own routes (`/v1/shelf/sealed/*`). They never pass through this putter.
public enum BackendCloudShelf {
    typealias Kind = BackendCloudContents.Kind
    /// Contract §7.1: the kinds the service serves, in the phones' own order. Nothing else is ever put.
    /// Slice 2 (15 Nov): `.settings` joins, one row per setting (name, its Settings page, its value in plain words; never a
    /// secret value).
    public static let servedKinds: [BackendCloudContents.Kind] = [.memory, .instructionFiles, .tasks, .projects, .agents, .cloudFolder, .artifacts, .settings]
    /// The sealed kinds (15 Nov): saved passwords (MCP server sign-ins included) and project secret files.
    public static let sealedKinds: [CloudSecretsShelfSeal.Kind] = CloudSecretsShelfSeal.Kind.allCases
    /// Kinds whose items carry a text. Slice 2 (15 Nov): a task's description and comments, and the Cloud folder's and
    /// artifacts' text files up to `textMaxBytes` (binary files stay listed with `binary = true`, without a text).
    public static let textKinds: Set<BackendCloudContents.Kind> = [.memory, .instructionFiles, .tasks, .cloudFolder, .artifacts]
    /// The standings that count as "its newest version is in the Cloud" (contract §7.2).
    public static let shownStandings: Set<CloudSyncContents.Standing> = [.inCloud, .waitingHere]
    public static let pieceBytes = 262_144
    public static let textMaxBytes = 1_048_576
    public static let partMaxRows = 500
    public static let partsMax = 40
    /// Under the service's 1 MiB body, with room for the envelope.
    public static let bodyBytes = 900_000
    public static let textsPerCall = 64
    /// Contract §7.6: a kind is put again 30 s after its view settles, never more often than every 30 s.
    public static let settleMs: Int64 = 30_000
    public static let dayMs: Int64 = 86_400_000
    /// 15 Nov (MacBook short shelf): a round that has not finished after this long no longer blocks the next one.
    public static let roundStuckMs: Int64 = 600_000

    /// 15 Nov (MacBook short shelf): a changed view goes up only once it has stayed the same for `settleMs`, at launch
    /// too. The launch view used to go up at once, and on the MacBook at 07:47:20Z it was taken while the Mac mini's
    /// 21 tasks were still arriving (07:47:35-44Z), so it put 12. nil `held` (or a different fingerprint) starts the wait.
    public static func settled(held: (fingerprint: String, since: Int64)?, fingerprint: String, now: Int64) -> Bool {
        guard let held, held.fingerprint == fingerprint else { return false }
        return now - held.since >= settleMs
    }
    /// 15 Nov (MacBook short shelf): whether a new round may start while `running` (its start) is still marked. A
    /// round that never returns (a read or call that hangs) must not stop the shelf for the rest of the launch.
    public static func roundMayStart(running: Int64?, now: Int64) -> Bool {
        guard let running else { return true }
        return now - running >= roundStuckMs
    }

    /// One row of a kind's list, exactly the contract's fields (nil fields are left out of the JSON).
    public struct Row: Codable, Sendable, Equatable {
        public var key: String
        public var name: String
        public var changedAt: Int64
        public var place: String?
        public var changedBy: String?
        public var sizeBytes: Int64?
        public var status: String?
        public var binary: Bool?
        public var textHash: String?
        public var textBytes: Int?
        public var textPieces: Int?
        /// Open files (15 Nov): a Cloud folder or artifact FILE (a picture, a PDF, any binary, a text over 1 MB) carries
        /// the SHA-256 of its bytes, their count and its type, so the service can ask for the bytes (`BackendCloudShelfFiles`).
        /// Filled only while the service says it keeps files (`limits.fileKinds`): an older service refuses unknown fields.
        public var fileHash: String?
        public var fileBytes: Int64?
        public var fileType: String?
        /// A grouped memory table (the diary): its date, size and count move with every message, so they never make
        /// a put by themselves (`fingerprint`); they ride along with the next real change or the daily put. Not sent.
        public var grouped = false
        enum CodingKeys: String, CodingKey { case key, name, changedAt, place, changedBy, sizeBytes, status, binary, textHash, textBytes, textPieces, fileHash, fileBytes, fileType }
        public init(key: String, name: String, changedAt: Int64, place: String? = nil, changedBy: String? = nil, sizeBytes: Int64? = nil,
                    status: String? = nil, binary: Bool? = nil) {
            self.key = key; self.name = name; self.changedAt = changedAt; self.place = place; self.changedBy = changedBy
            self.sizeBytes = sizeBytes; self.status = status; self.binary = binary
        }
    }
    /// One item going on the shelf: its row, and (for a text kind) which page item its text is read from.
    public struct Entry: Sendable, Equatable {
        public var row: Row
        /// The page item whose text goes with the row; nil = no text (not a text kind, not readable, a grouped table).
        public let textItem: String?
        /// Changes whenever the item's text can have changed (its newest change and size): the hash cache's key.
        public let textStamp: String?
        /// Open files (15 Nov): the page item whose file can go with the row (a Cloud folder or artifact item); whether it
        /// IS a file (binary, or a text over 1 MB) is decided when its size is read. nil = never a file.
        public var fileItem: String? = nil
    }
    /// What one text is, once read: kept by `textStamp` so an unchanged note is never read or hashed again.
    public struct TextFact: Codable, Sendable, Equatable {
        public let hash: String
        public let bytes: Int
        public let pieces: Int
    }

    /// The shelf's entries per served kind, from the page's own model. `status` gives a task's state or an agent's role
    /// in words, by page item id (the app's owners know them; nil = none).
    public static func entries(model: BackendCloudContents, status: [String: String] = [:]) -> [BackendCloudContents.Kind: [Entry]] {
        var made: [Kind: [Entry]] = [:]
        for kind in servedKinds { made[kind] = [] }
        var keys: [Kind: Set<String>] = [:]
        for item in model.items {
            guard servedKinds.contains(item.kind), shown(item), let name = clip(BackendCloudContentsWords.plain(item.name), 128) else { continue }
            let key = key(item.id)
            guard keys[item.kind, default: []].insert(key).inserted else { continue }
            var row = Row(key: key, name: name, changedAt: max(0, item.changedAt))
            row.place = clip(BackendCloudContentsWords.plain(item.place), 512)
            row.changedBy = clip(BackendCloudContentsWords.plain(item.changedBy), 64)
            row.sizeBytes = item.bytes.map { max(0, $0) }
            row.status = clip(BackendCloudContentsWords.plain(status[item.id] ?? statusWords(item)), 64)
            row.grouped = item.entries != nil
            if item.kind == .settings {
                // The Settings page it belongs to, and its value in plain words; a setting that holds a key, token or
                // password is listed by name with no value.
                row.place = clip(BackendCloudContentsWords.plain(item.folder.joined(separator: " › ")), 512) ?? row.place
                if item.entries == nil { row.status = holdsSecret(item) ? nil : shelfValue(item.value) }
            }
            if [Kind.cloudFolder, .artifacts, .instructionFiles].contains(item.kind), !item.isText { row.binary = true }
            let readable = textKinds.contains(item.kind) && item.entries == nil
                && (item.kind == .tasks || item.isText && (item.canOpen || item.kind == .cloudFolder || item.kind == .artifacts))
            made[item.kind, default: []].append(Entry(row: row, textItem: readable ? item.id : nil,
                                                      textStamp: readable ? item.id + "|" + String(item.changedAt) + "|" + String(item.bytes ?? -1) : nil,
                                                      fileItem: fileKinds.contains(item.kind) && item.entries == nil ? item.id : nil))
        }
        for kind in servedKinds { made[kind]?.sort { $0.row.key < $1.row.key } }
        return made
    }
    /// Only what stands in the Cloud now: never the Bin, never an item marked "Only on this Mac" / "Not on this Mac",
    /// never one still sending or refused.
    static func shown(_ item: BackendCloudContents.Item) -> Bool {
        !BackendCloudNoteIdentity.isBin(item.state) && item.localMark == nil && !item.id.hasPrefix("marked|")
            && shownStandings.contains(item.standing)
    }
    /// A setting whose name or record says it holds a key, token, password or other secret: its value never leaves.
    /// Review N2: whole words only ("API key", "apiKey", "auth_token" match; "Keyboard" does not).
    static func holdsSecret(_ item: BackendCloudContents.Item) -> Bool {
        let secret: Set<String> = ["key", "keys", "apikey", "token", "tokens", "password", "passwords", "passwd", "passphrase", "secret", "secrets",
                                   "credential", "credentials", "auth", "oauth", "bearer", "cookie", "cookies", "pin", "otp"]
        return words(item.id + " " + item.name).contains { secret.contains($0) }
    }
    /// Lower-case words of a name, split at spaces, punctuation and camelCase ("apiKey" -> api, key, apikey).
    static func words(_ text: String) -> [String] {
        var parts: [String] = [], current = ""
        func flush() { if !current.isEmpty { parts.append(current.lowercased()); current = "" } }
        var previousLower = false
        for ch in text {
            if !(ch.isLetter || ch.isNumber) { flush(); previousLower = false; continue }
            if ch.isUppercase && previousLower { flush() }
            current.append(ch); previousLower = ch.isLowercase
        }
        flush()
        // Two neighbours joined as well ("api" + "key" = "apikey").
        return parts + zip(parts, parts.dropFirst()).map { $0 + $1 }
    }
    /// Review N2: a setting's value leaves only when it is an on/off, a number or one of the app's fixed choices
    /// (`BackendCloudManagerSettings.words`). Anything typed (links, paths, addresses, free text) is listed by name only.
    static func shelfValue(_ said: String?) -> String? {
        guard let said = said?.trimmingCharacters(in: .whitespaces), !said.isEmpty else { return nil }
        let fixed: Set<String> = Set(["On", "Off", "Empty", "Not set", "None", "Set", "Saved text", "1 chosen"])
            .union(BackendCloudManagerSettings.choiceWords.values)
        if fixed.contains(said) { return said }
        if said.range(of: #"^[0-9][0-9,]* chosen$"#, options: .regularExpression) != nil { return said }
        if said.range(of: #"^-?[0-9][0-9,]*(\.[0-9]+)?$"#, options: .regularExpression) != nil { return said }
        return nil
    }
    /// A task's text (slice 2): its description, then each comment as "<who>: <words>", plain text.
    /// Review N2: nil when it holds a known secret (the same check file texts have).
    public static func taskText(_ task: TaskRow) -> String? {
        var parts: [String] = []
        let description = task.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { parts.append(description) }
        for note in task.notes.sorted(by: { $0.at < $1.at }) {
            let words = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            let who = BackendCloudContentsWords.plain(note.by)
            parts.append(who.map { $0 + ": " + words } ?? words)
        }
        let text = parts.joined(separator: "\n\n")
        return BackendSharedRedact.containsKnownSecret(text) ? nil : text
    }
    /// A Cloud folder or artifact file's text (slice 2): a normal file inside `root`, read without following a link
    /// (the folder sync's own reader), at most `textMaxBytes`; nil when larger, not text (a zero byte, not UTF-8), or
    /// holding a secret by the app's own rules.
    public static func fileText(root: URL, relative: String) -> String? {
        guard !relative.isEmpty, let stamp = CloudFolderDisk.stamp(root, relative), stamp.bytes <= Int64(textMaxBytes),
              case .file(let data) = CloudFolderDisk.read(root, relative), data.count <= textMaxBytes,
              !CloudArtifactsFormat.holdsSecret(relative, data), !BackendSharedRedact.containsKnownSecret(String(decoding: data, as: UTF8.self)) else { return nil }
        return BackendCloudFilesReadFence.text(data, limit: textMaxBytes)
    }
    /// The memory's own words for a row: "Put away", or how many entries a grouped table holds.
    static func statusWords(_ item: BackendCloudContents.Item) -> String? {
        if let state = BackendCloudFilesWords.state(item.state) { return state }
        return item.entries.map { BackendCloudContentsWords.entries($0) }
    }
    /// The Mac's own item key: the page's plain id (the same on every Mac for the same item), hashed only when long.
    static func key(_ id: String) -> String { id.utf8.count <= 512 ? id : "h:" + hash(Data(id.utf8)) }
    static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// The whole text's facts (contract §7.4): SHA-256 of its UTF-8, its length and how many pieces.
    public static func fact(_ text: String) -> TextFact {
        let data = Data(text.utf8)
        return TextFact(hash: hash(data), bytes: data.count, pieces: pieces(text).count)
    }
    /// The text in pieces of at most 256 KiB of UTF-8 each, cut between characters; an empty text is one piece "".
    public static func pieces(_ text: String) -> [String] {
        guard text.utf8.count > pieceBytes else { return [text] }
        var made: [String] = []
        var current = String.UnicodeScalarView()
        var size = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            if size + width > pieceBytes { made.append(String(current)); current = .init(); size = 0 }
            current.append(scalar); size += width
        }
        if !current.isEmpty || made.isEmpty { made.append(String(current)) }
        return made
    }
    /// One kind's view, as a fingerprint: put again only when it changed.
    public static func fingerprint(_ rows: [Row]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let steady = rows.map { row -> Row in
            guard row.grouped else { return row }
            var calm = row
            calm.changedAt = 0; calm.sizeBytes = nil; calm.status = nil
            return calm
        }
        return hash((try? encoder.encode(steady)) ?? Data())
    }
    /// The list in parts: at most 500 rows and `bodyBytes` each, at least one part (an empty kind is one empty part).
    public static func parts(_ rows: [Row]) -> [[Row]] {
        let encoder = JSONEncoder()
        var made: [[Row]] = []
        var current: [Row] = []
        var size = 0
        for row in rows {
            let width = ((try? encoder.encode(row))?.count ?? 0) + 1
            if !current.isEmpty, current.count >= partMaxRows || size + width > bodyBytes { made.append(current); current = []; size = 0 }
            current.append(row); size += width
        }
        if !current.isEmpty || made.isEmpty { made.append(current) }
        return made
    }
}

/// The putter: quiet, in the background, at low cost. One per signed-in identity; every call goes through `send`
/// (the sync transport's `shelf`, which never touches sync's own back-off). Keeps its small state beside the
/// identity's sync store (`shelf.json`): per kind the fingerprint last put, when, and whether texts are still owed; the
/// text hash cache; the setting; when the shelf was last put and from which Mac.
public actor BackendCloudShelfPutter {
    public typealias Send = @Sendable (_ method: String, _ path: String, _ body: Data) async throws -> (status: Int, data: Data)
    public typealias Kind = BackendCloudContents.Kind

    public struct KindState: Codable, Sendable, Equatable {
        public var fingerprint: String?
        public var putAt: Int64?
        public var count: Int?
        /// The last part was accepted but not every text it asked for was sent (a crash, a lost connection): resumed.
        public var textsOwed = false
        /// Open files (15 Nov), all optional so a saved state from before reads as it was: the files the service still
        /// asks for (in its order), when it asked, how many it asked for and how many are done; no file is sent before
        /// `filesHoldUntil` (a refusal waits for the next daily put).
        public var filesOwed: [BackendCloudShelf.NeedFile]?
        public var filesAskedAt: Int64?
        public var filesAsked: Int?
        public var filesDone: Int?
        public var filesHoldUntil: Int64?
    }
    public struct State: Codable, Sendable, Equatable {
        /// Contract §7.8: ON by default.
        public var on = true
        public var kinds: [String: KindState] = [:]
        public var texts: [String: BackendCloudShelf.TextFact] = [:]
        /// When the shelf was last put (by any Mac, as far as this Mac knows) and from which Mac, by name.
        public var asOf: Int64?
        public var from: String?
        /// Open files (15 Nov): what each file is, by kind + path + size + change time, so an unchanged file is never read
        /// again; the kinds the service says it keeps files for (`limits.fileKinds`; nil/empty = an older service: no file
        /// fields, nothing hashed, nothing sent) and when that was last asked (once a day).
        public var files: [String: BackendCloudShelf.FileFact]?
        public var fileKinds: [String]?
        public var fileKindsAt: Int64?
        public init() {}
    }
    /// What one put came to.
    public enum Outcome: Sendable, Equatable {
        case put(count: Int, texts: Int)
        /// Unchanged since the last put: nothing sent.
        case unchanged
        /// Contract §7.7: another Mac already put a newer view. Nothing is done.
        case behind
        /// Contract §7.8: the setting is off for the account. Putting stops.
        case off
        /// The service part is not live (404 on the route): silent, tried again at the next launch.
        case missing
        /// Not now (429, a lost connection, any other answer): tried again on a later round.
        case later
    }

    let send: Send
    let file: URL?
    public internal(set) var state: State
    /// Set by a 404: the routes do not exist yet. Nothing more is sent until the next launch.
    public internal(set) var missing = false
    var retryAt: [Kind: Int64] = [:]
    /// Open files (15 Nov): the kinds whose owed files were checked with the service since launch, and a 429's wait.
    var filesFresh: Set<Kind> = []
    var filesRetryAt: [Kind: Int64] = [:]

    public init(send: @escaping Send, file: URL?) {
        self.send = send
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
        else { state = State() }
    }

    // MARK: Wire

    struct Failure: Decodable {
        struct Detail: Decodable { let code: String; let retryAfterMs: Int? }
        let error: Detail
    }
    struct ListBody: Encodable {
        let kind: String; let putId: String; let part: Int; let parts: Int; let throughSeq: String; let items: [BackendCloudShelf.Row]
    }
    struct ListAnswer: Decodable { let accepted: Bool?; let asOf: Int64?; let count: Int?; let needTexts: [String]?; let needFiles: [BackendCloudShelf.NeedFile]? }
    struct TextBody: Encodable {
        struct Piece: Encodable { let hash: String; let piece: Int; let text: String }
        let kind: String; let texts: [Piece]
    }
    public struct Status: Decodable, Sendable {
        public struct KindRow: Decodable, Sendable { public let kind: String; public let putId: String?; public let asOf: Int64?; public let fromDevice: String?; public let count: Int?; public let throughSeq: String? }
        public let on: Bool?
        public let kinds: [KindRow]?
        public let needTexts: [String]?
        /// Open files (15 Nov): only from a service that keeps files.
        public let needFiles: [BackendCloudShelf.NeedFile]?
        public struct Limits: Decodable, Sendable { public let fileKinds: [String]? }
        public let limits: Limits?
    }
    enum Answer { case ok(Data), refused(status: Int, code: String?, retryAfterMs: Int?), lost }
    /// `quiet404`: a 404 on this call (the files route of an older service) never stops the shelf's other puts.
    func call(_ method: String, _ path: String, _ body: Data = Data(), quiet404: Bool = false) async -> Answer {
        guard !missing else { return .refused(status: 404, code: "not_found", retryAfterMs: nil) }
        guard let answered = try? await send(method, path, body) else { return .lost }
        let status = answered.status, data = answered.data
        if (200..<300).contains(status) { return .ok(data) }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        if status == 404, !quiet404 { missing = true }
        return .refused(status: status, code: failure?.error.code, retryAfterMs: failure?.error.retryAfterMs)
    }
    func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Reads

    /// `GET /v1/shelf` (or one kind's, with what texts it still needs). Keeps the account's setting and the newest put.
    public func status(kind: Kind? = nil) async -> Status? {
        guard case .ok(let data) = await call("GET", "/shelf" + (kind.map { "?kind=" + $0.rawValue } ?? "")),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        if let on = status.on, on != state.on { state.on = on }
        // Open files (15 Nov): the whole-shelf read says which kinds the service keeps files for. An answer without
        // `limits.fileKinds` is an older service: files stay off until the next daily look.
        if kind == nil {
            state.fileKinds = status.limits?.fileKinds ?? []
            state.fileKindsAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
        if let newest = status.kinds?.filter({ $0.asOf != nil }).max(by: { $0.asOf! < $1.asOf! }) {
            state.asOf = newest.asOf
            state.from = BackendCloudContentsWords.plain(newest.fromDevice) ?? state.from
        }
        save()
        return status
    }

    // MARK: The setting

    /// Contract §7.8: the switch. OFF deletes the whole shelf on the service and stops putting; ON puts again.
    @discardableResult
    public func setOn(_ on: Bool) async -> Bool {
        state.on = on
        if on { for key in state.kinds.keys { state.kinds[key]?.fingerprint = nil } }
        save()
        guard let body = try? JSONEncoder().encode(["on": on]), case .ok = await call("POST", "/shelf/setting", body) else { return false }
        if !on { state.kinds = [:]; state.asOf = nil; state.from = nil; save() }
        return true
    }

    // MARK: Texts

    public func knownText(_ stamp: String) -> BackendCloudShelf.TextFact? { state.texts[stamp] }
    /// Keeps only the facts of texts still listed, so the cache never grows past the shelf.
    public func remember(_ facts: [String: BackendCloudShelf.TextFact]) {
        guard facts != state.texts else { return }
        state.texts = facts
        save()
    }

    // MARK: Putting

    /// Puts one kind's list when it changed (or `force`, the daily put), then exactly the texts the service asks for.
    /// `text` hands the whole text for a hash (nil = not readable now: it stays owed to the next put).
    public func put(_ kind: Kind, rows: [BackendCloudShelf.Row], throughSeq: String, from: String?, force: Bool = false,
                    now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                    text: @escaping @Sendable (String) async -> String?) async -> Outcome {
        guard BackendCloudShelf.servedKinds.contains(kind) else { return .unchanged }
        guard state.on else { return .off }
        guard !missing else { return .missing }
        if let wait = retryAt[kind], now < wait { return .later }
        let fingerprint = BackendCloudShelf.fingerprint(rows)
        var known = state.kinds[kind.rawValue] ?? KindState()
        if known.textsOwed, known.fingerprint == fingerprint, !force {
            // Resume: the list is on the shelf; send what it still needs.
            guard let needed = await status(kind: kind)?.needTexts else { return missing ? .missing : .later }
            let sent = await sendTexts(kind, needed, text: text)
            if sent.complete { known.textsOwed = false; state.kinds[kind.rawValue] = known; save() }
            return .put(count: known.count ?? rows.count, texts: sent.count)
        }
        guard force || known.fingerprint != fingerprint else { return .unchanged }
        let parts = BackendCloudShelf.parts(rows)
        guard parts.count <= BackendCloudShelf.partsMax else { return .later }
        let putId = UUID().uuidString.lowercased()
        var answer: ListAnswer?
        for (index, part) in parts.enumerated() {
            guard let body = try? JSONEncoder().encode(ListBody(kind: kind.rawValue, putId: putId, part: index, parts: parts.count,
                                                                  throughSeq: throughSeq, items: part)) else { return .later }
            switch await call("POST", "/shelf/list", body) {
            case .ok(let data): if index == parts.count - 1 { answer = try? JSONDecoder().decode(ListAnswer.self, from: data) }
            case .lost: return .later
            case .refused(let status, let code, let retryAfterMs):
                switch (status, code) {
                case (404, _): return .missing
                case (409, "shelf_behind"?):
                    // Another Mac's view is newer: do nothing; this view is put again once it changes after a pull.
                    known.fingerprint = fingerprint; known.putAt = now; known.filesOwed = nil; state.kinds[kind.rawValue] = known; save()
                    return .behind
                case (409, "shelf_off"?):
                    state.on = false; save()
                    return .off
                case (429, _):
                    retryAt[kind] = now + Int64(max(retryAfterMs ?? 0, Int(BackendCloudShelf.settleMs)))
                    return .later
                default:
                    retryAt[kind] = now + BackendCloudShelf.settleMs
                    return .later
                }
            }
        }
        guard let answer, answer.accepted == true else { return .later }
        known.fingerprint = fingerprint
        known.putAt = now
        known.count = answer.count ?? rows.count
        let needed = answer.needTexts ?? []
        known.textsOwed = !needed.isEmpty
        // Open files (15 Nov): only a service that keeps files and names them in its answer gets any; an answer without
        // `needFiles` (the service live before this) owes nothing.
        BackendCloudShelf.ask(&known, kind: kind, needFiles: filesLive(kind) ? answer.needFiles : nil, now: now)
        state.kinds[kind.rawValue] = known
        state.asOf = answer.asOf ?? now
        state.from = from ?? state.from
        save()
        guard !needed.isEmpty else { return .put(count: known.count ?? 0, texts: 0) }
        let sent = await sendTexts(kind, needed, text: text)
        if sent.complete { state.kinds[kind.rawValue]?.textsOwed = false; save() }
        return .put(count: known.count ?? 0, texts: sent.count)
    }

    /// `POST /v1/shelf/texts`: the asked-for texts in pieces, at most 64 pieces and `bodyBytes` a call. A text whose
    /// bytes no longer match its hash (it changed since the list) is not sent: the next put lists the new one.
    func sendTexts(_ kind: Kind, _ hashes: [String], text: @escaping @Sendable (String) async -> String?) async -> (count: Int, complete: Bool) {
        guard BackendCloudShelf.textKinds.contains(kind) else { return (0, true) }
        var batch: [TextBody.Piece] = []
        var size = 0
        var sent = 0
        var complete = true
        for hash in Set(hashes).sorted() {
            guard let whole = await text(hash), BackendCloudShelf.hash(Data(whole.utf8)) == hash else { complete = false; continue }
            for (index, piece) in BackendCloudShelf.pieces(whole).enumerated() {
                let made = TextBody.Piece(hash: hash, piece: index, text: piece)
                let width = ((try? JSONEncoder().encode(made))?.count ?? 0) + 1
                if !batch.isEmpty, batch.count >= BackendCloudShelf.textsPerCall || size + width > BackendCloudShelf.bodyBytes {
                    let posted = await postTexts(kind, batch); batch = []; size = 0
                    guard posted else { return (sent, false) }
                }
                batch.append(made); size += width
            }
            sent += 1
        }
        if !batch.isEmpty { guard await postTexts(kind, batch) else { return (sent, false) } }
        return (sent, complete)
    }

    /// One `POST /v1/shelf/texts` call with these pieces (was a local flush() capturing the batch: Swift 6 region check).
    private func postTexts(_ kind: Kind, _ batch: [TextBody.Piece]) async -> Bool {
        guard let body = try? JSONEncoder().encode(TextBody(kind: kind.rawValue, texts: batch)), case .ok = await call("POST", "/shelf/texts", body) else { return false }
        return true
    }

    /// `cloud.status`: when the shelf was last put and from which Mac, and whether it is on. Nothing that changes it.
    public func wire() -> NativeRPCValue {
        .object([.init("on", .bool(state.on)),
                 .init("lastPut", state.asOf.map { .string(BackendCloudContentsWords.iso($0)) } ?? .null),
                 .init("from", state.from.map(NativeRPCValue.string) ?? .null)])
    }
}
