import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The sealed part of the shelf (owner, 15 Nov: "saved password and secret files ... I want them to be in cloud as well.
/// I need every single thing in cloud"). Two more kinds go on the Cloud service's shelf so his phones show them with
/// every Mac off: `savedPasswords` (every saved password, saved MCP server sign-ins included) and `projectSecretFiles`.
/// Unlike the rest of the shelf, the Mac seals EVERYTHING about them first (names, places, dates, values, file bytes)
/// with the shelf root derived from the saved-passwords key (`CloudSecretsShelfSealer`), in pieces a phone opens one at a
/// time. The service stores pieces it cannot open and cannot name.
///
/// What goes on it is exactly what his Macs sync today: the records each saved-passwords source hands to the sync core
/// (`CloudSecretsLogicalAdapter.exportRecords`, the same call the sync's own inventory makes). The Bin and "Only on this
/// Mac" are already left out there (the delete-rule owners), project files only while they travel (not under "Keep
/// project secret files on this Mac only"), and a record too large to sync is too large here as well.
///
/// Never in the clear on disk, in a log line, a tool answer or an error: the records live in memory for one round, the
/// state file keeps only keyed fingerprints, and nothing here logs or returns a name or a value.
public enum BackendCloudShelfSealed {
    public typealias Kind = CloudSecretsShelfSeal.Kind
    /// Per kind on the service (Servers contract): at most this many items; more stay off the shelf (the oldest first).
    public static let maximumItems: [Kind: Int] = [.savedPasswords: 2_000, .projectSecretFiles: 400]
    public static let piecesPerCall = 64
    public static let bodyBytes = 900_000

    /// One item ready to seal: its own key (never sent), what the list says about it, and its value's bytes.
    public struct Made: Sendable, Equatable {
        public let itemKey: String
        public let password: Listed?
        public let file: FileListed?
        public let value: Data
    }
    /// A saved password's list line before it gets its ref and value id.
    public struct Listed: Sendable, Equatable { public let name: String; public let purpose: String; public let place: String?; public let changedAt: Int64?; public let labels: [String] }
    public struct FileListed: Sendable, Equatable { public let project: String; public let file: String; public let place: String; public let changedAt: Int64?; public let changedBy: String? }

    /// What one kind's put is made of.
    public struct Pieces: Sendable {
        public let kind: Kind
        public let index: [CloudSecretsShelfSeal.Piece]
        public let values: [CloudSecretsShelfSeal.Piece]
        public let count: Int
        /// Keyed (holds no name or value): put again only when it changes.
        public let fingerprint: String
        /// 15 Nov fix: the source ids ("api", "servers", ...) with at least one item in this list. Kept beside the
        /// fingerprint, so a later round knows which sources his phones show (a failed read of one of them keeps the list).
        public var sources: [String] = []
        /// Review S1: this list's lines per source (names and value ids, never a value), so a later round can carry the
        /// lines of ONE source that cannot be read while every other source is put fresh. In memory only.
        public var bySource: [String: Carried] = [:]
        /// Value pieces already on the service that this list names without sending them again (carried lines).
        public var carriedIds: [String] = []
    }
    /// One source's lines in a list put before: carried over unchanged while that source cannot be read.
    public struct Carried: Sendable {
        public var passwords: [CloudSecretsShelfSeal.SavedPassword] = []
        public var files: [CloudSecretsShelfSeal.SecretFile] = []
        public var valueIds: [String] { passwords.map(\.value) + files.map(\.value) }
        public init() {}
    }

    /// The kind a source's items go to.
    public static func kind(ofSource sourceId: String) -> Kind {
        sourceId == BackendProjectSecretFilesRules.sourceId ? .projectSecretFiles : .savedPasswords
    }
    /// Fixed words for why a source could not be read this round. Never a name, a path or a value.
    public static func reason(_ error: any Error) -> String {
        switch error as? CloudFailure {
        case .secretsLocked?: return "not ready yet on this Mac"
        case .gateClosed?: return "Cloud is closed for it on this Mac"
        case .invalidRequest?: return "holds an item this Mac cannot read"
        case .idReused?: return "holds two items under one id"
        case .unavailable?: return "could not be read"
        default: return "could not be read"
        }
    }

    // MARK: From the records his Macs sync to what the phone lists

    /// The two kinds' items from the synced records. `projectNames`: project id -> his name for it.
    public static func items(_ records: [CloudSecretRecord], projectNames: [String: String]) -> [Kind: [Made]] {
        var made: [Kind: [Made]] = [.savedPasswords: [], .projectSecretFiles: []]
        // Keys travel (15 Nov): two Macs that hold the same item under two ids (an API key made on each) show ONE line.
        var shown = Set<Data>()
        for record in records {
            let key = record.sourceId + "\n" + record.recordId
            if record.sourceId == BackendProjectSecretFilesRules.sourceId {
                guard let file = try? BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, record, source: record.sourceId, domain: .project),
                      let bytes = Data(base64Encoded: file.data) else { continue }
                let place = file.folder.isEmpty ? file.path : file.folder + "/" + file.path
                let name = (file.path as NSString).lastPathComponent
                made[.projectSecretFiles, default: []].append(Made(itemKey: key, password: nil,
                    file: FileListed(project: clip(projectNames[file.projectId], 128) ?? "A project", file: clip(name, 128) ?? "File",
                                     place: clip(place, 512) ?? name, changedAt: file.at > 0 ? file.at : nil, changedBy: clip(file.from, 64)),
                    value: bytes))
                continue
            }
            guard let line = password(record) else { continue }
            // Sorted keys (review fixes 3): a plain JSONEncoder writes a struct's keys in a different order from one
            // encoding to the next (Swift dictionaries are seeded per instance), so the value's bytes, its piece id and
            // the list's fingerprint changed every round: an unchanged list went up again, whole, every 30 seconds.
            guard let value = try? JSONEncoder.shelfSorted.encode(CloudSecretsShelfSeal.Value(fields: line.fields)) else { continue }
            var same = Data((record.sourceId + "\n" + line.name + "\n" + line.purpose + "\n").utf8); same.append(value)
            guard shown.insert(Data(SHA256.hash(data: same))).inserted else { continue }
            made[.savedPasswords, default: []].append(Made(itemKey: key,
                password: Listed(name: line.name, purpose: line.purpose, place: line.place, changedAt: nil, labels: line.fields.map(\.label)),
                file: nil, value: value))
        }
        for kind in Kind.allCases { made[kind]?.sort { $0.itemKey < $1.itemKey } }
        return made
    }

    /// One saved password in the words the phone shows: name, what it is for, where, and its fields.
    struct Line { let name: String; let purpose: String; let place: String?; let fields: [CloudSecretsShelfSeal.Field] }
    static func password(_ record: CloudSecretRecord) -> Line? {
        switch record.sourceId {
        case "servers":
            guard let value = try? BackendCloudSecretsRecords.decode(BackendCloudSecretsServerValue.self, record, source: record.sourceId, domain: .server) else { return nil }
            var fields: [CloudSecretsShelfSeal.Field] = []
            var place: String?
            if let server = value.server {
                if !server.username.isEmpty { fields.append(.init(label: "User", value: server.username, secret: false)) }
                if !server.address.isEmpty {
                    let address = server.port == 22 || server.port <= 0 ? server.address : server.address + ":" + String(server.port)
                    fields.append(.init(label: "Address", value: address, secret: false)); place = address
                }
            }
            if let password = value.password, !password.isEmpty { fields.append(.init(label: "Password", value: password, secret: true)) }
            if let key = value.privateKey, !key.isEmpty { fields.append(.init(label: "Private key", value: key, secret: true)) }
            if let phrase = value.passphrase, !phrase.isEmpty { fields.append(.init(label: "Passphrase", value: phrase, secret: true)) }
            guard fields.contains(where: \.secret) else { return nil }
            return Line(name: clip(value.server?.name, 128) ?? "Server sign-in", purpose: "Server", place: clip(place, 512), fields: fields)
        case "voice":
            guard let value = try? BackendCloudSecretsRecords.decode(BackendCloudSecretsVoiceValue.self, record, source: record.sourceId, domain: .app),
                  !value.key.isEmpty else { return nil }
            return Line(name: "Voice key", purpose: clip(value.provider, 64) ?? "Voice", place: nil,
                        fields: [.init(label: "Key", value: value.key, secret: true), .init(label: "Service", value: value.endpoint, secret: false)])
        case "api":
            // Keys travel: an API account's key, by the account's name.
            guard let value = try? BackendCloudSecretsRecords.decode(BackendCloudKeysAPIValue.self, record, source: record.sourceId, domain: .apiKey),
                  !value.key.isEmpty else { return nil }
            var fields: [CloudSecretsShelfSeal.Field] = [.init(label: "Key", value: value.key, secret: true),
                                                         .init(label: "Service", value: value.baseURL, secret: false)]
            if let model = value.model, !model.isEmpty { fields.append(.init(label: "Model", value: model, secret: false)) }
            if let workspace = value.workspaceID, !workspace.isEmpty { fields.append(.init(label: "Workspace", value: workspace, secret: false)) }
            return Line(name: clip(value.name, 128) ?? "API key", purpose: "API key", place: nil, fields: fields)
        case "tasks":
            guard let value = try? BackendCloudSecretsRecords.decode(BackendCloudSecretsTaskStore.Value.self, record, source: record.sourceId, domain: .taskConnection),
                  !value.token.isEmpty else { return nil }
            return Line(name: clip(value.name, 128) ?? "Task connection", purpose: "Task connection", place: nil,
                        fields: [.init(label: "Token", value: value.token, secret: true)])
        case "ssh":
            // Keys travel: what one server that signs in through his SSH settings needs, by the server's name.
            guard let value = try? BackendCloudSecretsRecords.decode(BackendCloudKeysSSHValue.self, record, source: record.sourceId, domain: .ssh) else { return nil }
            let address = value.port == 22 ? value.hostname : value.hostname + ":" + String(value.port)
            var fields: [CloudSecretsShelfSeal.Field] = [.init(label: "User", value: value.user, secret: false),
                                                         .init(label: "Address", value: address, secret: false)]
            for key in value.keys {
                fields.append(.init(label: "Key file " + (clip(key.name, 48) ?? "key"), value: String(decoding: key.bytes, as: UTF8.self), secret: true))
            }
            return Line(name: "Server key · " + (clip(value.server.name, 110) ?? "server"), purpose: "Server key", place: clip(address, 512), fields: fields)
        case "receiver":
            // The Receiver's own key is not a password he reads; each source's secrets are, by the source's name.
            guard let value = try? BackendCloudSecretsRecords.decode(BackendCloudKeysReceiverValue.self, record, source: record.sourceId, domain: .receiver),
                  let source = value.source, let secrets = value.secrets, !secrets.secret.isEmpty else { return nil }
            var fields: [CloudSecretsShelfSeal.Field] = [.init(label: "Secret", value: secrets.secret, secret: true)]
            if let reply = secrets.reply, !reply.isEmpty { fields.append(.init(label: "Reply token", value: reply, secret: true)) }
            return Line(name: clip(source.name, 128) ?? "Receiver source", purpose: "Receiver", place: nil, fields: fields)
        default:
            // MCP server sign-ins and any other saved password: every setting it holds, a secret-looking one hidden.
            var raw = record.payload.raw
            if record.sourceId == "mcp-user", case .object = raw["definition"] { raw = raw["definition"] }
            var fields: [CloudSecretsShelfSeal.Field] = []
            flatten(raw, path: "", into: &fields)
            guard !fields.isEmpty else { return nil }
            let name = record.sourceId == "mcp-user" ? clip(record.recordId, 128) ?? "MCP server" : noun(record.domain)
            return Line(name: name, purpose: record.sourceId == "mcp-user" ? "MCP server" : noun(record.domain), place: nil, fields: fields)
        }
    }
    static func noun(_ domain: String) -> String {
        switch CloudSecretsDomain(rawValue: domain) {
        case .apiKey: return "API key"
        case .server: return "Server sign-in"
        case .ssh: return "SSH key"
        case .mcp: return "MCP server"
        case .taskConnection: return "Task connection"
        case .receiver: return "Receiver sign-in"
        case .project: return "Project password"
        case .app: return "App password"
        default: return "Saved password"
        }
    }
    static let secretWords = ["key", "token", "secret", "password", "passwd", "passphrase", "auth", "credential", "cookie", "session", "bearer"]
    static func flatten(_ value: NativeRPCValue, path: String, into fields: inout [CloudSecretsShelfSeal.Field]) {
        guard fields.count < 64 else { return }
        func add(_ text: String) {
            let label = clip(path.isEmpty ? "Value" : path, 64) ?? "Value"
            let lower = label.lowercased()
            fields.append(.init(label: label, value: text, secret: secretWords.contains { lower.contains($0) }))
        }
        switch value {
        case .object(let items): for item in items { flatten(item.value, path: path.isEmpty ? item.key : path + "." + item.key, into: &fields) }
        case .array(let items): for (index, item) in items.enumerated() { flatten(item, path: path + "[" + String(index) + "]", into: &fields) }
        case .string(let text): add(text)
        case .number(let number): add(number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number))
        case .bool(let flag): add(flag ? "true" : "false")
        default: return
        }
    }
    static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text = text?.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: Sealing

    /// One kind sealed for a put: one value piece per item (its id stays while its bytes stay), the list in index pieces.
    /// An item whose value cannot fit one piece is left off (it is too large to sync as well).
    /// `carried` (review S1): per source that cannot be read this round, its lines from the list put before; they are
    /// named again (their value pieces are already on the service) and nothing of theirs is sealed or sent again.
    public static func pieces(_ kind: Kind, items: [Made], sealer: CloudSecretsShelfSealer, putId: String, madeAt: Int64, madeBy: String,
                              carried: [String: Carried] = [:]) throws -> Pieces {
        var values: [CloudSecretsShelfSeal.Piece] = [], passwords: [CloudSecretsShelfSeal.SavedPassword] = [], files: [CloudSecretsShelfSeal.SecretFile] = []
        var bySource: [String: Carried] = [:]
        let limit = maximumItems[kind] ?? 0
        for item in items.prefix(limit) {
            guard CloudSecretsShelfSeal.step(item.value.count + 4) != nil else { continue }
            let source = item.itemKey.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let id = sealer.valueId(kind: kind, itemKey: item.itemKey, bytes: item.value)
            let ref = sealer.ref(kind: kind, itemKey: item.itemKey)
            values.append(try sealer.seal(item.value, kind: kind, role: .value, pieceId: id))
            if let listed = item.password {
                let line = CloudSecretsShelfSeal.SavedPassword(ref: ref, name: listed.name, purpose: listed.purpose, place: listed.place, changedAt: listed.changedAt,
                                       value: id, valueBytes: item.value.count, labels: listed.labels)
                passwords.append(line); bySource[source, default: Carried()].passwords.append(line)
            } else if let listed = item.file {
                let line = CloudSecretsShelfSeal.SecretFile(ref: ref, project: listed.project, file: listed.file, place: listed.place, changedAt: listed.changedAt,
                                   changedBy: listed.changedBy, sizeBytes: item.value.count, value: id)
                files.append(line); bySource[source, default: Carried()].files.append(line)
            }
        }
        var carriedIds: [String] = []
        let fresh = Set(values.map(\.pieceId))
        for source in carried.keys.sorted() where bySource[source] == nil {
            guard let lines = carried[source] else { continue }
            var kept = Carried()
            for line in lines.passwords where passwords.count + files.count < limit && !fresh.contains(line.value) { passwords.append(line); kept.passwords.append(line) }
            for line in lines.files where passwords.count + files.count < limit && !fresh.contains(line.value) { files.append(line); kept.files.append(line) }
            bySource[source] = kept
            carriedIds += kept.valueIds
        }
        // One order whatever was carried (by the keyed ref), so a carried list equal to the last one is "unchanged".
        passwords.sort { $0.ref < $1.ref }
        files.sort { $0.ref < $1.ref }
        // The keyed fingerprint of the list itself (refs, names, value ids): unchanged list = no put.
        let steady = try JSONEncoder.shelfSorted.encode(Steady(passwords: passwords, files: files))
        let fingerprint = sealer.fingerprint(steady)
        // The list in parts of at most `indexPartBytes` of JSON each.
        let encoder = JSONEncoder.shelfSorted
        var chunks: [([CloudSecretsShelfSeal.SavedPassword], [CloudSecretsShelfSeal.SecretFile])] = []
        var current: ([CloudSecretsShelfSeal.SavedPassword], [CloudSecretsShelfSeal.SecretFile]) = ([], []), size = 0
        func width<T: Encodable>(_ value: T) -> Int { ((try? encoder.encode(value))?.count ?? 0) + 1 }
        for line in passwords {
            let w = width(line)
            if size + w > CloudSecretsShelfSeal.indexPartBytes, !current.0.isEmpty { chunks.append(current); current = ([], []); size = 0 }
            current.0.append(line); size += w
        }
        for line in files {
            let w = width(line)
            if size + w > CloudSecretsShelfSeal.indexPartBytes, !current.1.isEmpty { chunks.append(current); current = ([], []); size = 0 }
            current.1.append(line); size += w
        }
        if !current.0.isEmpty || !current.1.isEmpty || chunks.isEmpty { chunks.append(current) }
        let count = passwords.count + files.count
        let index = try chunks.enumerated().map { part, chunk in
            let body = CloudSecretsShelfSeal.Index(kind: kind, putId: putId, part: part, parts: chunks.count, madeAt: madeAt, madeBy: madeBy, count: count,
                                                   passwords: kind == .savedPasswords ? chunk.0 : nil, files: kind == .projectSecretFiles ? chunk.1 : nil)
            return try sealer.seal(try encoder.encode(body), kind: kind, role: .index, pieceId: UUID().uuidString.lowercased())
        }
        var made = Pieces(kind: kind, index: index, values: values, count: count, fingerprint: fingerprint)
        made.sources = bySource.filter { !$0.value.passwords.isEmpty || !$0.value.files.isEmpty }.keys.sorted()
        made.bySource = bySource
        made.carriedIds = Array(Set(carriedIds)).sorted()
        return made
    }
    struct Steady: Encodable { let passwords: [CloudSecretsShelfSeal.SavedPassword]; let files: [CloudSecretsShelfSeal.SecretFile] }
}

private extension JSONEncoder {
    static var shelfSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// The sealed putter: the shelf's own quiet rules for the two sealed kinds (only what changed, resume by asking the service
/// which pieces it lacks, the shelf setting, nothing while saved passwords are locked or kept off his phones). Every call
/// goes through the shelf's own door on the transport (never sync's back-off). Keeps beside the shelf state only keyed
/// fingerprints, when each kind was put and its key generation: `shelf-sealed.json`.
public actor BackendCloudShelfSealedPutter {
    public typealias Send = BackendCloudShelfPutter.Send
    public typealias Kind = CloudSecretsShelfSeal.Kind
    public struct KindState: Codable, Sendable, Equatable {
        public var fingerprint: String?
        public var epoch: Int?
        public var putAt: Int64?
        /// 15 Nov fix: the sources that had items in the list last put (source ids only; nil in an older file).
        public var sources: [String]?
        /// Review S1: per source on the shelf that cannot be read, when it first failed (ms). Cleared when it reads again
        /// or leaves the list; after 24 hours the list goes up without it.
        public var failingSince: [String: Int64]?
    }
    public struct State: Codable, Sendable, Equatable {
        public var kinds: [String: KindState] = [:]
        /// Set once both kinds were cleared from the shelf (his phones setting): not cleared again every round.
        public var cleared = false
        public init() {}
    }
    public enum Outcome: Sendable, Equatable { case put(count: Int, pieces: Int), unchanged, behind, off, missing, later, cleared }

    let send: Send
    let file: URL?
    public private(set) var state: State
    public private(set) var missing = false
    var retryAt: [Kind: Int64] = [:]
    /// 15 Nov fix: the service's last refusal in fixed words ("status 403 not_approved", "no answer"), for the round's
    /// log line. Holds only the status and the service's short code; nil after an answer that went through.
    public private(set) var lastRefusal: String?

    public init(send: @escaping Send, file: URL?) {
        self.send = send; self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
        else { state = State() }
    }
    func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: file, options: .atomic) }
    }

    struct Failure: Decodable {
        struct Detail: Decodable { let code: String; let retryAfterMs: Int?; let missing: [String]? }
        let error: Detail
    }
    enum Answer { case ok(Data), refused(status: Int, code: String?, retryAfterMs: Int?), lost }
    /// Never carries the request's body into anything it returns: only the status and the service's short code.
    func call(_ method: String, _ path: String, _ body: Data = Data()) async -> Answer {
        guard !missing else { return .refused(status: 404, code: "not_found", retryAfterMs: nil) }
        guard let answered = try? await send(method, path, body) else { lastRefusal = "no answer"; return .lost }
        if (200..<300).contains(answered.status) { lastRefusal = nil; return .ok(answered.data) }
        let failure = try? JSONDecoder().decode(Failure.self, from: answered.data)
        lastRefusal = "status " + String(answered.status) + (failure.map { " " + Self.code($0.error.code) } ?? "")
        if answered.status == 404 { missing = true }
        return .refused(status: answered.status, code: failure?.error.code, retryAfterMs: failure?.error.retryAfterMs)
    }

    /// The service's short code, kept to its own alphabet (never more than 40 of a-z, 0-9 and "_").
    static func code(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }.prefix(40).map(Character.init))
    }

    struct MissingBody: Encodable { let kind: String; let epoch: Int; let pieceIds: [String] }
    struct MissingAnswer: Decodable { let missing: [String] }
    struct PiecesBody: Encodable { let kind: String; let epoch: Int; let pieces: [CloudSecretsShelfSeal.Piece] }
    struct IndexBody: Encodable {
        let kind: String; let putId: String; let epoch: Int; let throughSeq: String; let count: Int
        let valueIds: [String]; let index: [CloudSecretsShelfSeal.Piece]
    }
    struct IndexAnswer: Decodable { let accepted: Bool?; let asOf: Int64? }

    /// Puts one sealed kind when its keyed fingerprint changed (or `force`: the daily put, or a new key generation).
    /// Order: the value pieces the service lacks first, then the list (the commit). A crash in between resumes by itself:
    /// the next round asks again which pieces are missing.
    public func put(_ made: BackendCloudShelfSealed.Pieces, epoch: Int, throughSeq: String, force: Bool = false,
                    now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async -> Outcome {
        let kind = made.kind
        guard !missing else { return .missing }
        if let wait = retryAt[kind], now < wait { return .later }
        var known = state.kinds[kind.rawValue] ?? KindState()
        guard force || known.fingerprint != made.fingerprint || known.epoch != epoch else { return .unchanged }
        // 1. Which value pieces are missing (ids only).
        var need: [String] = []
        let ids = made.values.map(\.pieceId)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            guard let body = try? JSONEncoder().encode(MissingBody(kind: kind.rawValue, epoch: epoch, pieceIds: slice)) else { return .later }
            switch await call("POST", "/shelf/sealed/missing", body) {
            case .ok(let data): need += (try? JSONDecoder().decode(MissingAnswer.self, from: data))?.missing ?? slice
            case .lost: return .later
            case .refused(let status, let code, let retry): return stop(kind, status, code, retry, now)
            }
        }
        // 2. Send exactly those, at most 64 pieces and `bodyBytes` per call.
        let wanted = Set(need)
        var batch: [CloudSecretsShelfSeal.Piece] = [], size = 0, sent = 0
        for piece in made.values where wanted.contains(piece.pieceId) {
            let width = ((try? JSONEncoder().encode(piece))?.count ?? 0) + 1
            if !batch.isEmpty, batch.count >= BackendCloudShelfSealed.piecesPerCall || size + width > BackendCloudShelfSealed.bodyBytes {
                let pieces = batch; batch = []; size = 0
                if let halted = await postPieces(kind, epoch, pieces, now) { return halted }
                sent += pieces.count
            }
            batch.append(piece); size += width
        }
        if !batch.isEmpty {
            if let halted = await postPieces(kind, epoch, batch, now) { return halted }
            sent += batch.count
        }
        // 3. The list: the commit. The service sweeps every value piece this list does not name.
        guard let body = try? JSONEncoder().encode(IndexBody(kind: kind.rawValue, putId: UUID().uuidString.lowercased(), epoch: epoch,
                                                            throughSeq: throughSeq, count: made.count, valueIds: ids + made.carriedIds, index: made.index)) else { return .later }
        switch await call("POST", "/shelf/sealed/index", body) {
        case .ok(let data):
            guard (try? JSONDecoder().decode(IndexAnswer.self, from: data))?.accepted == true else { return .later }
            known.fingerprint = made.fingerprint; known.epoch = epoch; known.putAt = now; known.sources = made.sources
            state.kinds[kind.rawValue] = known; state.cleared = false; save()
            return .put(count: made.count, pieces: sent)
        case .lost: return .later
        case .refused(let status, let code, let retry):
            if status == 409, code == "shelf_behind" { known.fingerprint = made.fingerprint; known.epoch = epoch; known.putAt = now; known.sources = made.sources; state.kinds[kind.rawValue] = known; save() }
            return stop(kind, status, code, retry, now)
        }
    }
    /// One `POST /shelf/sealed/pieces` call: nil when it went, else the outcome that stops the put (was a local flush()
    /// capturing batch/size/sent: Swift 6 region check).
    private func postPieces(_ kind: Kind, _ epoch: Int, _ pieces: [CloudSecretsShelfSeal.Piece], _ now: Int64) async -> Outcome? {
        guard let body = try? JSONEncoder().encode(PiecesBody(kind: kind.rawValue, epoch: epoch, pieces: pieces)) else { return .later }
        switch await call("POST", "/shelf/sealed/pieces", body) {
        case .ok: return nil
        case .lost: return .later
        case .refused(let status, let code, let retry): return stop(kind, status, code, retry, now)
        }
    }
    private func stop(_ kind: Kind, _ status: Int, _ code: String?, _ retry: Int?, _ now: Int64) -> Outcome {
        switch (status, code) {
        case (404, _): return .missing
        case (409, "shelf_behind"?): return .behind
        case (409, "shelf_off"?), (409, "sealed_off"?): return .off
        case (429, _): retryAt[kind] = now + Int64(max(retry ?? 0, Int(BackendCloudShelf.settleMs))); return .later
        default: retryAt[kind] = now + BackendCloudShelf.settleMs; return .later
        }
    }

    /// His phones setting went on (or saved passwords were started anew): both sealed kinds leave the shelf now. Once.
    public func clear() async -> Outcome {
        guard !state.cleared else { return .unchanged }
        guard !missing else { return .missing }
        for kind in Kind.allCases {
            guard let body = try? JSONEncoder().encode(["kind": kind.rawValue]) else { return .later }
            switch await call("POST", "/shelf/sealed/clear", body) {
            case .ok: continue
            case .lost: return .later
            case .refused(let status, _, _): if status == 404 { return .missing }; return .later
            }
        }
        state = State(); state.cleared = true; save()
        return .cleared
    }
    /// Due for the daily put.
    /// Review S1: keeps when each failing source of a kind first failed (saved only when it changes).
    public func setFailing(_ kind: Kind, _ since: [String: Int64]) {
        var known = state.kinds[kind.rawValue] ?? KindState()
        let next: [String: Int64]? = since.isEmpty ? nil : since
        guard known.failingSince != next, state.kinds[kind.rawValue] != nil || next != nil else { return }
        known.failingSince = next; state.kinds[kind.rawValue] = known; save()
    }
    public func due(_ kind: Kind, now: Int64) -> Bool { now - (state.kinds[kind.rawValue]?.putAt ?? 0) >= BackendCloudShelf.dayMs }
}

/// 15 Nov fix (after 0220zh: no sealed list went up on either Mac, and nothing said why). One sealed round, moved here
/// from the app's shelf so it is tested: what the round may carry, which kind goes up, what is kept, and ONE plain log
/// line per round outcome (a repeat of the same line is not written again). Rules:
/// - A source that cannot be read does not hold back the list: the list goes up with the sources that could be read.
///   A source that has NEVER been on the shelf is simply left out for now; a source whose items his phones show now
///   (it had items in the last list put) keeps the whole kind as it is on the shelf until it reads again: a failed
///   read never takes anything off his phones.
/// - A failed source or a refused put is tried again 30 seconds later, then on the normal rhythm (every 10 minutes,
///   or when the feed moves). `soon()`: an owner became ready (API accounts after the session helper connected): the
///   next round runs at once and a source that joins the list goes up without the 30-second settle.
/// - The log line carries fixed words only: kind titles, counts, source titles, fixed reasons, the service's status
///   and short code. Never a name, a place or a value of his.
public actor BackendCloudShelfSealedRound {
    public typealias Kind = CloudSecretsShelfSeal.Kind
    public typealias Material = @Sendable () async -> BackendCloudSecretsGraph.ShelfSealed
    let putter: BackendCloudShelfSealedPutter
    let material: Material
    let note: @Sendable (String) -> Void
    let clock: @Sendable () -> Int64
    var seen: [Kind: (fingerprint: String, since: Int64)] = [:]
    var lastBuild: Int64 = 0
    var lastSignal: [String] = []
    /// When the next round is due before the normal rhythm (a failure's 30 s retry, or `soon()`).
    public private(set) var retryAt: Int64?
    /// The 30 s retry was used since the last clean round (then: the normal rhythm).
    var retried = false
    public private(set) var lastLine: String?
    /// Review S1: the lines of the list this Mac last put or found unchanged, per kind and source (names and value ids,
    /// never a value). In memory only, so a source that cannot be read keeps its own lines while the others go fresh.
    var lastLines: [Kind: [String: BackendCloudShelfSealed.Carried]] = [:]
    public typealias Carried = BackendCloudShelfSealed.Carried
    /// The normal rhythm: the sources are read again at least every 10 minutes (the app's shelf rebuild).
    public static let rebuildMs: Int64 = 600_000

    public init(putter: BackendCloudShelfSealedPutter, material: @escaping Material,
                note: @escaping @Sendable (String) -> Void,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.putter = putter; self.material = material; self.note = note; self.clock = clock
    }

    /// An owner a source waits for became ready: run the next round now.
    public func soon() { retryAt = clock(); retried = false }
    /// A retry is due (the app's shelf runs a sealed round even when nothing else moved).
    public func retryDue() -> Bool { retryAt.map { clock() >= $0 } ?? false }
    /// Something waits to settle (the app's shelf keeps looking every tick).
    public var settling: Bool { !seen.isEmpty }

    static func title(_ kind: Kind) -> String { kind == .savedPasswords ? "saved passwords" : "secret files" }

    /// One round. Returns false when nothing was due.
    @discardableResult
    public func run(throughSeq: String, from: String?, atLaunch: Bool, signal: [String]) async -> Bool {
        let now = clock()
        var daily = false
        for kind in Kind.allCases { if await putter.due(kind, now: now) { daily = true } }
        let retry = retryAt.map { now >= $0 } ?? false
        guard atLaunch || !seen.isEmpty || daily || retry || signal != lastSignal || now - lastBuild >= Self.rebuildMs else { return false }
        lastSignal = signal; lastBuild = now
        if retry { retryAt = nil }
        switch await material() {
        case .notNow:
            say("not now: saved passwords are locked, not set up or not open on this Mac")
        case .keptOff:
            seen = [:]
            let outcome = await putter.clear()
            say("kept off your phones by your setting" + (outcome == .later ? "; taking them off the shelf is tried again" : ""))
            if outcome == .later { again() } else { retried = false }
        case .ready(let sealer, let records, let names, let failed):
            let items = BackendCloudShelfSealed.items(records, projectNames: names)
            var parts: [String] = [], trouble = !failed.isEmpty
            for kind in Kind.allCases {
                let known = await putter.state.kinds[kind.rawValue]
                // Which failed sources his phones may show now. Review S2: a list was put before but this Mac's memory
                // of it names no sources (an older state file): every failed source counts as shown. Only when no list
                // was ever put for the kind is a failed source simply left out.
                let failedHere = failed.keys.filter { BackendCloudShelfSealed.kind(ofSource: $0) == kind }.sorted()
                let shown = failedHere.filter { source in
                    guard let known, known.putAt != nil else { return false }     // no list ever put: left out for now
                    guard let sources = known.sources else { return true }         // put before, sources unknown: shown
                    return sources.contains(source)
                }
                // Review S1: each shown source that keeps failing is carried for at most 24 hours, then left out.
                let now = clock()
                var since = (known?.failingSince ?? [:]).filter { shown.contains($0.key) }
                for source in shown where since[source] == nil { since[source] = now }
                await putter.setFailing(kind, since)
                let expired = shown.filter { now - (since[$0] ?? now) >= BackendCloudShelf.dayMs }
                var carry: [String: Carried] = [:], whole: [String] = []
                for source in shown where !expired.contains(source) {
                    if let lines = lastLines[kind]?[source] { carry[source] = lines } else { whole.append(source) }
                }
                // Not in memory (this Mac started since that list went up): the kind stays exactly as on the shelf.
                guard whole.isEmpty else {
                    seen[kind] = nil
                    parts.append(Self.title(kind) + ": kept as on your phones until " + whole.map(BackendCloudSecretsLeanCoverage.title).joined(separator: ", ") + " can be read")
                    continue
                }
                guard let made = try? BackendCloudShelfSealed.pieces(kind, items: items[kind] ?? [], sealer: sealer,
                        putId: UUID().uuidString.lowercased(), madeAt: clock(), madeBy: from ?? "Mac", carried: carry) else {
                    parts.append(Self.title(kind) + ": could not be sealed"); trouble = true; continue
                }
                if !carry.isEmpty { parts.append(Self.title(kind) + ": last entries carried for " + carry.keys.sorted().map(BackendCloudSecretsLeanCoverage.title).joined(separator: ", ")) }
                if !expired.isEmpty { parts.append(Self.title(kind) + ": left out after 24 hours: " + expired.map(BackendCloudSecretsLeanCoverage.title).joined(separator: ", ")) }
                let changed = known?.fingerprint != made.fingerprint || known?.epoch != sealer.epoch
                let due = await putter.due(kind, now: clock())
                guard changed || due else { seen[kind] = nil; lastLines[kind] = made.bySource; parts.append(Self.title(kind) + ": unchanged"); continue }
                // A source that joins the list (it was left out, or this is the first list) goes up at once; an edit settles 30 s.
                let joins = !Set(made.sources).isSubset(of: Set(known?.sources ?? []))
                if changed, !atLaunch, !joins {
                    guard let held = seen[kind], held.fingerprint == made.fingerprint else {
                        seen[kind] = (made.fingerprint, clock()); parts.append(Self.title(kind) + ": changed, settling"); continue
                    }
                    guard clock() - held.since >= BackendCloudShelf.settleMs else { parts.append(Self.title(kind) + ": changed, settling"); continue }
                }
                // The round's own clock for "when put" too: `due` above reads it with the same clock (a put stamped by
                // another clock read as a day old and was put again every round).
                let outcome = await putter.put(made, epoch: sealer.epoch, throughSeq: throughSeq, force: due && !changed, now: clock())
                let refusal = await putter.lastRefusal
                switch outcome {
                case .put(let count, _): seen[kind] = nil; lastLines[kind] = made.bySource; parts.append(Self.title(kind) + ": put " + String(count))
                case .unchanged: seen[kind] = nil; lastLines[kind] = made.bySource; parts.append(Self.title(kind) + ": unchanged")
                case .behind: seen[kind] = nil; parts.append(Self.title(kind) + ": a newer list from another Mac is there")
                case .off:
                    seen = [:]; say(Self.title(kind) + ": the service keeps the shelf off (" + (refusal ?? "off") + ")"); return true
                case .missing:
                    seen = [:]; say("the service has no sealed shelf (" + (refusal ?? "not found") + ")"); return true
                case .later, .cleared:
                    trouble = true
                    parts.append(Self.title(kind) + ": refused, tried again shortly (" + (refusal ?? "waiting") + ")")
                }
            }
            if !failed.isEmpty {
                parts.append("not read this round: " + failed.keys.sorted().map { BackendCloudSecretsLeanCoverage.title($0) + " (" + (failed[$0] ?? "could not be read") + ")" }.joined(separator: ", "))
            }
            say(parts.joined(separator: "; "))
            if trouble { again() } else { retried = false }
        }
        return true
    }
    /// 30 s after the first trouble, then the normal rhythm.
    private func again() {
        guard !retried else { return }
        retried = true
        retryAt = clock() + BackendCloudShelf.settleMs
    }
    private func say(_ text: String) {
        let line = "cloud shelf: sealed: " + text
        guard line != lastLine else { return }
        lastLine = line
        note(line)
    }
}
