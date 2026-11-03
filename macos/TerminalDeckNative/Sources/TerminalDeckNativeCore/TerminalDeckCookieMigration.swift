import Foundation
import CryptoKit
import SQLite3

/// A one-time handover of Terminal Deck's own embedded-browser cookies.
/// There is deliberately no browser discovery or caller-supplied source path.
/// SQLite's backup API reads the committed WAL into memory; no cookie snapshot
/// or decrypted value is ever written to a temporary file.
public enum TerminalDeckCookieMigration {
    public static let markerName = "native-browser-cookie-migration.json"
    private static let markerVersion = 1
    private static let maximumRows = 100_000
    private static let maximumDatabaseBytes: Int64 = 128 * 1024 * 1024

    public struct Source: Sendable {
        public let profileID: String
        fileprivate let database: URL?
        public let alreadyCompleted: Bool
        public var hasDatabase: Bool { database != nil }
    }

    public enum SameSite: String, Sendable {
        case unspecified, none, lax, strict
    }

    /// In-memory transfer data. Never encode or log this type: `value` is secret.
    public struct Cookie: Sendable {
        public let host: String
        public let domainCookie: Bool
        public let name: String
        public let value: String
        public let path: String
        public let expires: Date?
        public let secure: Bool
        public let httpOnly: Bool
        public let sameSite: SameSite
    }

    public struct Snapshot: Sendable {
        fileprivate let rows: [Row]
        fileprivate let databaseVersion: Int
        public var count: Int { rows.count }
        public var needsKey: Bool {
            let now = Date().timeIntervalSince1970
            return rows.contains {
                !$0.invalid && !$0.partitioned && $0.encryptedValue.starts(with: Data("v10".utf8)) &&
                (!$0.persistent || Double($0.expiresMicros) / 1_000_000 - 11_644_473_600 > now)
            }
        }
    }

    public enum Rejection: String, Sendable, CaseIterable {
        case invalidRow, unsupportedEncryption, decryptionFailed, domainBindingMismatch
        case invalidUTF8, keyUnavailable, partitionedCookie, unsupportedSameSite

        public var message: String {
            switch self {
            case .invalidRow: "A source cookie has invalid attributes."
            case .unsupportedEncryption: "A source cookie uses an unsupported encryption version."
            case .decryptionFailed: "A source cookie could not be decrypted with the original key."
            case .domainBindingMismatch: "A source cookie's encrypted domain binding did not match."
            case .invalidUTF8: "A source cookie's decrypted value is not valid UTF-8."
            case .keyUnavailable: "An encrypted source cookie needs the original Safe Storage key."
            case .partitionedCookie: "Safari's cookie API cannot preserve a partitioned source cookie."
            case .unsupportedSameSite: "A source cookie uses an unsupported SameSite policy."
            }
        }
    }

    public struct Plan: Sendable {
        public fileprivate(set) var cookies: [Cookie] = []
        public fileprivate(set) var expired = 0
        public fileprivate(set) var rejected: [Rejection: Int] = [:]
        public var failed: Int { rejected.values.reduce(0, +) }
    }

    public struct Completion: Codable, Sendable {
        public let completedAt: Date
        public let imported: Int
        public let keptExisting: Int
        public let expired: Int

        public init(completedAt: Date = Date(), imported: Int, keptExisting: Int, expired: Int) {
            self.completedAt = completedAt
            self.imported = imported
            self.keptExisting = keptExisting
            self.expired = expired
        }
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case invalidRoot, outsideRoot, invalidProfiles, invalidMarker, invalidProfile
        case fileRead, fileTooLarge, database(Int32), schema, unsupportedSchema, tooManyRows, markerWrite

        public var errorDescription: String? {
            switch self {
            case .invalidRoot: "Cookie migration needs Terminal Deck's own absolute data folder."
            case .outsideRoot: "Cookie migration refused a source outside Terminal Deck's own data folder."
            case .invalidProfiles: "Terminal Deck's browser profile file is invalid; cookie migration can be retried after it is repaired."
            case .invalidMarker: "The native cookie migration record is invalid; no source data was changed."
            case .invalidProfile: "Cookie migration refused an unrecognized Terminal Deck profile."
            case .fileRead: "Terminal Deck's source cookie files could not be read."
            case .fileTooLarge: "Terminal Deck's source cookie data exceeds the migration size limit."
            case .database(let status): "The source cookie database could not be snapshotted or read (SQLite status \(status))."
            case .schema: "The source cookie database has missing or invalid cookie fields."
            case .unsupportedSchema: "The source cookie database needs a newer migration format."
            case .tooManyRows: "The source cookie database exceeds the migration row limit."
            case .markerWrite: "Cookies were handed over, but the completion record could not be saved. The next attempt will keep existing Safari cookies."
            }
        }
    }

    /// Validate ids against the old app's metadata; only its built-in default
    /// profile may exist without a metadata entry.
    public static func sources(dataRoot: URL) throws -> [Source] {
        let root = try ownedRoot(dataRoot)
        let profileFile = try ownedPath(root.appendingPathComponent("browser-profiles.json"), root: root)
        var ids = ["default"]
        if FileManager.default.fileExists(atPath: profileFile.path) {
            let data = try readBounded(profileFile, maximum: 2 * 1024 * 1024)
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let state = object as? [String: Any], let profiles = state["profiles"] as? [[String: Any]] else {
                throw Failure.invalidProfiles
            }
            for profile in profiles {
                guard let id = profile["id"] as? String, validProfileID(id) else { continue }
                // Like browser-profiles.ts, derive the partition rather than
                // trusting a persisted partition string as a filesystem path.
                if !ids.contains(id) { ids.append(id) }
            }
        }
        let completed = try readMarker(root: root).profiles
        return try ids.map { id in
            let partition = id == "default" ? "terminaldeck-browser" : "terminaldeck-browser-" + id
            let directory = root.appendingPathComponent("Partitions", isDirectory: true)
                .appendingPathComponent(partition, isDirectory: true)
            var database: URL?
            // Old and current layouts of Terminal Deck's own Chromium store.
            for suffix in ["Network/Cookies", "Cookies"] {
                let candidate = try ownedPath(directory.appendingPathComponent(suffix), root: root)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    database = candidate
                    break
                }
            }
            return Source(profileID: id, database: database, alreadyCompleted: completed[id] != nil)
        }
    }

    /// Call off the main actor. The live source connection is read-only; the
    /// in-memory destination owns a coherent committed snapshot, including WAL.
    public static func snapshot(_ source: Source, dataRoot: URL) throws -> Snapshot {
        guard validProfileID(source.profileID) else { throw Failure.invalidProfile }
        let root = try ownedRoot(dataRoot)
        // Revalidate metadata and paths immediately before opening the source.
        guard let current = try sources(dataRoot: root).first(where: { $0.profileID == source.profileID }),
              let database = current.database, database == source.database else { throw Failure.invalidProfile }
        let path = try ownedPath(database, root: root)
        for suffix in ["-wal", "-shm", "-journal"] {
            _ = try ownedPath(URL(fileURLWithPath: path.path + suffix), root: root)
        }
        var live: OpaquePointer?
        let open = sqlite3_open_v2(path.path, &live, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard open == SQLITE_OK, let live else {
            if let live { sqlite3_close(live) }
            throw Failure.database(open)
        }
        defer { sqlite3_close(live) }
        sqlite3_busy_timeout(live, 2_000)
        let pages = try integer(live, sql: "PRAGMA page_count")
        let pageSize = try integer(live, sql: "PRAGMA page_size")
        guard pages > 0, pageSize > 0, pages <= maximumDatabaseBytes / pageSize else { throw Failure.fileTooLarge }

        var memory: OpaquePointer?
        let memoryOpen = sqlite3_open_v2(":memory:", &memory, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard memoryOpen == SQLITE_OK, let memory else {
            if let memory { sqlite3_close(memory) }
            throw Failure.database(memoryOpen)
        }
        defer { sqlite3_close(memory) }
        guard let backup = sqlite3_backup_init(memory, "main", live, "main") else { throw Failure.database(sqlite3_errcode(memory)) }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.database(step == SQLITE_DONE ? finish : step) }
        return try readSnapshot(memory)
    }

    /// Encryption stays in memory. A v24+ database requires the SHA-256 domain
    /// binding; an older database may also contain bound rows from an upgrade.
    public static func plan(_ snapshot: Snapshot, password: Data?, now: Date = Date()) -> Plan {
        var result = Plan()
        for row in snapshot.rows {
            do {
                if row.invalid { throw Rejected(reason: .invalidRow) }
                if row.partitioned { throw Rejected(reason: .partitionedCookie) }
                guard !row.host.isEmpty, row.host == row.host.trimmingCharacters(in: .whitespacesAndNewlines),
                      row.path.hasPrefix("/"), !row.path.contains(where: { $0.isNewline || $0 == ";" }),
                      !row.name.contains(where: { $0.isNewline || $0 == ";" || $0 == "=" }) else {
                    throw Rejected(reason: .invalidRow)
                }
                let isDomain = row.host.hasPrefix(".")
                let host = isDomain ? String(row.host.dropFirst()) : row.host
                guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == ";" }),
                      let origin = URL(string: "\(row.secure ? "https" : "http")://\(host)/"),
                      origin.host?.lowercased() == host.lowercased(), origin.user == nil, origin.password == nil,
                      origin.port == nil else { throw Rejected(reason: .invalidRow) }
                var expiry: Date?
                if row.persistent {
                    let seconds = Double(row.expiresMicros) / 1_000_000 - 11_644_473_600
                    guard row.expiresMicros > 0, seconds.isFinite else { throw Rejected(reason: .invalidRow) }
                    expiry = Date(timeIntervalSince1970: seconds)
                    if expiry! <= now { result.expired += 1; continue }
                }
                let site: SameSite
                switch row.sameSite {
                case -1: site = .unspecified
                case 0:
                    guard row.secure else { throw Rejected(reason: .unsupportedSameSite) }
                    site = .none
                case 1: site = .lax
                case 2: site = .strict
                default: throw Rejected(reason: .unsupportedSameSite)
                }
                let value: String
                if !row.encryptedValue.isEmpty {
                    guard row.encryptedValue.starts(with: Data("v10".utf8)) else { throw Rejected(reason: .unsupportedEncryption) }
                    guard let password, !password.isEmpty else { throw Rejected(reason: .keyUnavailable) }
                    var plaintext: Data
                    do { plaintext = try ChromiumSafeStorageCipher.decryptData(row.encryptedValue, password: password) }
                    catch { throw Rejected(reason: .decryptionFailed) }
                    let digest = Data(SHA256.hash(data: Data(row.host.utf8)))
                    let bound = plaintext.count >= digest.count && plaintext.prefix(digest.count) == digest
                    if snapshot.databaseVersion >= 24 && !bound { throw Rejected(reason: .domainBindingMismatch) }
                    if bound { plaintext = Data(plaintext.dropFirst(digest.count)) }
                    guard let text = String(data: plaintext, encoding: .utf8) else { throw Rejected(reason: .invalidUTF8) }
                    value = text
                } else {
                    guard let text = row.clearValue else { throw Rejected(reason: .invalidRow) }
                    value = text
                }
                guard !value.contains(where: { $0.isNewline || $0 == ";" || $0 == "\0" }),
                      !row.name.contains("\0") else { throw Rejected(reason: .invalidRow) }
                if row.name.hasPrefix("__Secure-") && !row.secure { throw Rejected(reason: .invalidRow) }
                if row.name.hasPrefix("__Host-") && (!row.secure || isDomain || row.path != "/") { throw Rejected(reason: .invalidRow) }
                result.cookies.append(Cookie(host: host, domainCookie: isDomain, name: row.name, value: value,
                                             path: row.path, expires: expiry, secure: row.secure,
                                             httpOnly: row.httpOnly, sameSite: site))
            } catch let failure as Rejected {
                result.rejected[failure.reason, default: 0] += 1
            } catch {
                result.rejected[.invalidRow, default: 0] += 1
            }
        }
        return result
    }

    /// Call only after every eligible cookie was retained or an existing Safari
    /// cookie won. No completion record is written for any rejected source row.
    public static func recordCompletion(dataRoot: URL, profileID: String, completion: Completion) throws {
        let root = try ownedRoot(dataRoot)
        guard try sources(dataRoot: root).contains(where: { $0.profileID == profileID }) else { throw Failure.invalidProfile }
        var marker = try readMarker(root: root)
        marker.profiles[profileID] = completion
        let file = try ownedPath(root.appendingPathComponent(markerName), root: root)
        do { try JSONEncoder().encode(marker).write(to: file, options: .atomic) }
        catch { throw Failure.markerWrite }
    }

    private struct Marker: Codable {
        var version = markerVersion
        var profiles: [String: Completion] = [:]
    }

    fileprivate struct Row: Sendable {
        var host: String
        var name: String
        var clearValue: String?
        var encryptedValue: Data
        var path: String
        var expiresMicros: Int64
        var secure: Bool
        var httpOnly: Bool
        var persistent: Bool
        var sameSite: Int64
        var partitioned: Bool
        var invalid: Bool
    }

    private struct Rejected: Error { let reason: Rejection }

    private static func validProfileID(_ id: String) -> Bool {
        if id == "default" { return true }
        return id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    private static func ownedRoot(_ raw: URL) throws -> URL {
        guard raw.isFileURL, raw.path.hasPrefix("/"), raw.path != "/" else { throw Failure.invalidRoot }
        return raw.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func ownedPath(_ raw: URL, root: URL) throws -> URL {
        let path = raw.standardizedFileURL
        let resolved = path.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { throw Failure.outsideRoot }
        // A source or SQLite sidecar symlink is never followed, even if its
        // current target happens to be inside the root.
        var cursor = path
        while cursor.path != root.path && cursor.path.hasPrefix(root.path + "/") {
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.outsideRoot }
            cursor.deleteLastPathComponent()
        }
        return path
    }

    private static func readBounded(_ file: URL, maximum: Int) throws -> Data {
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximum + 1
            guard size <= maximum else { throw Failure.fileTooLarge }
            let data = try Data(contentsOf: file)
            guard data.count <= maximum else { throw Failure.fileTooLarge }
            return data
        } catch let error as Failure { throw error }
        catch { throw Failure.fileRead }
    }

    private static func readMarker(root: URL) throws -> Marker {
        let file = try ownedPath(root.appendingPathComponent(markerName), root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return Marker() }
        let data = try readBounded(file, maximum: 2 * 1024 * 1024)
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.version == markerVersion,
              marker.profiles.keys.allSatisfy(validProfileID) else { throw Failure.invalidMarker }
        return marker
    }

    private static func statement(_ db: OpaquePointer, sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &query, nil)
        guard status == SQLITE_OK, let query else { throw Failure.database(status) }
        return query
    }

    private static func integer(_ db: OpaquePointer, sql: String) throws -> Int64 {
        let query = try statement(db, sql: sql)
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW, sqlite3_column_type(query, 0) == SQLITE_INTEGER else { throw Failure.database(status) }
        return sqlite3_column_int64(query, 0)
    }

    private static func text(_ query: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(query, column) == SQLITE_TEXT else { return nil }
        let length = Int(sqlite3_column_bytes(query, column))
        guard length > 0 else { return "" }
        guard let bytes = sqlite3_column_blob(query, column) else { return nil }
        return String(data: Data(bytes: bytes, count: length), encoding: .utf8)
    }

    private static func metaVersion(_ db: OpaquePointer, key: String) throws -> Int {
        // The key is selected from these two literals, never from user data.
        guard ["version", "last_compatible_version"].contains(key) else { throw Failure.schema }
        let query = try statement(db, sql: "SELECT value FROM meta WHERE key='\(key)'")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw Failure.schema }
        let version: Int?
        if sqlite3_column_type(query, 0) == SQLITE_INTEGER { version = Int(exactly: sqlite3_column_int64(query, 0)) }
        else { version = text(query, 0).flatMap(Int.init) }
        guard let version, version > 0 else { throw Failure.schema }
        return version
    }

    private static func readSnapshot(_ db: OpaquePointer) throws -> Snapshot {
        let version = try metaVersion(db, key: "version")
        let compatible = try metaVersion(db, key: "last_compatible_version")
        guard compatible <= 24, compatible <= version else { throw Failure.unsupportedSchema }
        let count = try integer(db, sql: "SELECT count(*) FROM cookies")
        guard count >= 0, count <= Int64(maximumRows) else { throw Failure.tooManyRows }
        let query = try statement(db, sql: "SELECT * FROM cookies")
        defer { sqlite3_finalize(query) }
        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(query) {
            if let name = sqlite3_column_name(query, i) { columns[String(cString: name)] = i }
        }
        let required = ["host_key", "name", "value", "encrypted_value", "path", "expires_utc", "is_secure", "is_httponly", "is_persistent", "samesite"]
        guard required.allSatisfy({ columns[$0] != nil }) else { throw Failure.schema }
        var rows: [Row] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Failure.database(status) }
            guard rows.count < maximumRows else { throw Failure.tooManyRows }
            var invalid = false
            func string(_ name: String) -> String {
                guard let value = text(query, columns[name]!) else { invalid = true; return "" }
                return value
            }
            func number(_ name: String) -> Int64 {
                let i = columns[name]!
                guard sqlite3_column_type(query, i) == SQLITE_INTEGER else { invalid = true; return 0 }
                return sqlite3_column_int64(query, i)
            }
            func boolean(_ name: String) -> Bool {
                let value = number(name)
                if value != 0 && value != 1 { invalid = true }
                return value == 1
            }
            let encryptedColumn = columns["encrypted_value"]!
            let byteCount = Int(sqlite3_column_bytes(query, encryptedColumn))
            var encrypted = Data()
            if sqlite3_column_type(query, encryptedColumn) != SQLITE_BLOB { invalid = true }
            if byteCount > 0, let bytes = sqlite3_column_blob(query, encryptedColumn) { encrypted = Data(bytes: bytes, count: byteCount) }
            let host = string("host_key"), name = string("name"), path = string("path")
            let clearValue = text(query, columns["value"]!)
            let expiry = number("expires_utc"), secure = boolean("is_secure"), httpOnly = boolean("is_httponly")
            let persistent = boolean("is_persistent"), sameSite = number("samesite")
            var partitioned = false
            if let column = columns["top_frame_site_key"] {
                guard let site = text(query, column) else { throw Failure.schema }
                partitioned = !site.isEmpty
            }
            rows.append(Row(host: host, name: name, clearValue: clearValue, encryptedValue: encrypted,
                            path: path, expiresMicros: expiry, secure: secure, httpOnly: httpOnly,
                            persistent: persistent, sameSite: sameSite, partitioned: partitioned, invalid: invalid))
        }
        return Snapshot(rows: rows, databaseVersion: version)
    }
}
