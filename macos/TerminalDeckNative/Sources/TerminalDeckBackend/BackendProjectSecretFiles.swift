import CryptoKit
import Darwin
import Foundation
import TerminalDeckNativeCore

/// Project secret files (owner, 13/14 Nov: his Cloud account carries "project secret files"). The `.env`-style and
/// credential files inside a project folder travel INSIDE saved passwords: sealed with the saved-passwords key, one
/// record per file under the secrets-class domain `project`, readable only by his computers that hold that key, only
/// while saved passwords are on. Design: team/security/notes/2026-11-14-project-secret-files.md.
///
/// What the service sees of a pack: class secrets, purpose secret, domain `project`, the key generation, size and count.
/// The record id (`file/<projectId>/<64 hex>`, an account-keyed HMAC of folder name and path), the path, the bytes, the
/// permissions and dates are all inside the seal.
public enum BackendProjectSecretFilesRules {
    public static let sourceId = "project-files"
    public static let inventoryRow = "I25"
    /// The "every Mac understands" gate (`DeckMemoryStore.cloudFeatureAnnounce`); no dot allowed in it.
    public static let feature = "projectsecrets"
    public static let format = 1
    /// A sealed record must fit the sync core's 64 KB record payload (the bytes go base64 twice: about 1.8 times).
    /// Every cap holds on send AND on arrival (review 14 Nov, F4).
    public static let fileBytes = 32 * 1024
    public static let projectFiles = 40
    public static let projectBytes = 512 * 1024
    public static let allFiles = 400
    /// Arrivals kept sealed on this Mac until they can be placed: at most `projectFiles` per project, `allFiles` in all
    /// and this many bytes of sealed text. Over a cap: refused and counted.
    public static let waitingBytes = 8 * 1024 * 1024
    /// The local ledger file is never read into memory when it is larger than this (it cannot grow past it by itself).
    static let ledgerBytes = 12 * 1024 * 1024
    static let depth = 6
    static let walkEntries = 20_000
    /// Personal SSH keys are a person's or a machine's credentials, not a project's (saved SSH keys travel on their own).
    static let personalKeyPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    /// Review 14 Nov (F2): tool settings that run programs never travel and are never created on arrival: `.envrc` is a
    /// shell script (direnv), `.yarnrc.yml` names the program yarn runs (`yarnPath`).
    public static let runsPrograms: Set<String> = [".envrc", ".yarnrc.yml"]
    /// Review 14 Nov (F3): the temporary file of an arrival is named like a `.env.*.local` file, so the Code page's own
    /// secret check (and the Cloud folder's never-send list) holds it back if a crash ever leaves one behind. Stale ones
    /// are cleared by the next look.
    static let temporaryPrefix = ".env.td-cloud-"
    static let temporarySuffix = ".local"
    static func temporaryName() -> String { temporaryPrefix + UUID().uuidString.lowercased() + temporarySuffix }
    /// Only the exact form `.env.td-cloud-<UUID>.local` (review 14 Nov, R4): a file of his with a similar name is never his loss.
    static func isTemporary(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix),
              name.utf8.count == temporaryPrefix.utf8.count + 36 + temporarySuffix.utf8.count else { return false }
        return UUID(uuidString: String(name.dropFirst(temporaryPrefix.count).dropLast(temporarySuffix.count))) != nil
    }
    /// A temporary file older than this is a crash's leftover (a write takes milliseconds).
    static let staleTemporaryMs: Int64 = 120_000

    /// `travels`: it goes. `staysHere`: a secret file that never travels (it runs programs, or an `.npmrc` with lines
    /// other than registry and sign-in lines) and is named as staying on this Mac. `never`: not a project secret file.
    public enum Verdict: Sendable, Equatable { case travels, staysHere, never }

    /// The ONE decision, the Code page's (`BackendCodeBackupGitReader.secretKind`, kinds A and C, and B only when the
    /// bytes hold a private key), narrowed: never inside a hidden folder (`.ssh`, `.aws`, `.gnupg`, `.kube`, `.docker`,
    /// `.azure`, `.git`) or a package/build folder, never a personal SSH key, never an unclean path, never a file that runs
    /// programs. `bytes` nil: by name only (a `.pem`/`.key`/`.asc` or `.npmrc` then counts as a candidate whose bytes
    /// decide). The same check runs on the sending Mac and on the receiving one.
    public static func verdict(_ relative: String, bytes: Data?) -> Verdict {
        guard CloudBootFilesRules.cleanRelative(relative), let parts = CloudBootFilesRules.parts(relative), parts.count <= depth + 1,
              let name = parts.last?.lowercased() else { return .never }
        for folder in parts.dropLast() {
            if folder.hasPrefix(".") || CloudFolderRules.rebuildableFolders.contains(folder.lowercased()) { return .never }
        }
        if personalKeyPrefixes.contains(where: { name.hasPrefix($0) }) || isTemporary(name) { return .never }
        switch BackendCodeBackupGitReader.secretKind(relative) {
        case .none: return .never
        case .maybeKey: if let bytes, !BackendCodeBackupGitReader.privateKey(bytes) { return .never }
        case .credential, .leaveOut: break
        }
        if runsPrograms.contains(name) { return .staysHere }
        if let bytes, !contentTravels(name, bytes) { return .staysHere }
        return .travels
    }
    public static func travels(_ relative: String, bytes: Data?) -> Bool { verdict(relative, bytes: bytes) == .travels }

    /// Files whose CONTENT can make a program run: `.npmrc` only with registry and sign-in lines; `.netrc` without a
    /// `macdef` (a macro its tools run at log-in); an AWS-style `credentials` file without `credential_process`.
    static func contentTravels(_ name: String, _ bytes: Data) -> Bool {
        switch name {
        case ".npmrc": return npmrcTravels(bytes)
        case ".netrc", "_netrc":
            // Review 14 Nov (R2): netrc readers also split on ',' and undo '"' and '\': anywhere at all, it stays.
            return !String(decoding: bytes, as: UTF8.self).lowercased().filter({ $0 != "\\" && $0 != "\"" }).contains("macdef")
        case "credentials": return !String(decoding: bytes, as: UTF8.self).lowercased().contains("credential_process")
        default: return true
        }
    }
    /// Every line a registry or sign-in line (`registry`, `@scope:registry`, `//host/...:_authToken`, `:_auth`,
    /// `:username`, `:_password`, `:email`, `always-auth`); comments and blank lines allowed. Anything else (a
    /// `script-shell`, `node-options`, `onload-script`, a section, an array) and the file stays on its Mac.
    public static func npmrcTravels(_ bytes: Data) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            guard let equals = line.firstIndex(of: "=") else { return false }
            guard npmrcKeyAllowed(line[..<equals].trimmingCharacters(in: .whitespaces)) else { return false }
        }
        return true
    }
    static let npmrcHostKeys = [":_authToken", ":_auth", ":username", ":_password", ":email", ":always-auth"]
    static func npmrcKeyAllowed(_ key: String) -> Bool {
        if key == "registry" || key == "always-auth" { return true }
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" || $0 == "=" }) else { return false }
        if key.hasPrefix("@"), key.hasSuffix(":registry") {
            let scope = key.dropFirst().dropLast(":registry".count)
            return !scope.isEmpty && !scope.contains(":")
        }
        if key.hasPrefix("//"), let ending = npmrcHostKeys.first(where: { key.hasSuffix($0) }) {
            return key.count > 2 + ending.count
        }
        return false
    }
    /// A project folder's own name as it travels: one plain name, nothing that climbs.
    static func cleanFolderName(_ name: String) -> Bool {
        CloudBootFilesRules.cleanRelative(name) && !name.contains("/")
    }

    /// Review 14 Nov (F6, F7): a project's registered folder resolved ONCE to its real folder (his projects are
    /// registered through links, `~/Projects/<name>` -> `code/<name>`); links below it stay refused. `forbidden`: the
    /// real folder is the home folder, a folder above it, or a whole disk: nothing travels from it, nothing is written
    /// into it.
    enum Root: Equatable { case ok(URL), missing, forbidden }
    static func realRoot(_ registered: String, home: String) -> Root {
        guard let real = realpath(registered, nil) else { return .missing }
        let resolved = String(cString: real); free(real)
        var info = stat()
        guard lstat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .missing }
        let realHome: String = {
            guard let made = realpath(home, nil) else { return home }
            defer { free(made) }
            return String(cString: made)
        }()
        // Review 14 Nov (R5): the same folder under another path (`/System/Volumes/Data/...`) is the same device and
        // file number, so the home folder and every folder above it are compared by those, not by path text.
        if resolved == "/" { return .forbidden }
        for start in [home, realHome] {
            var up = start
            while !up.isEmpty {
                var other = stat()
                if stat(up, &other) == 0, other.st_dev == info.st_dev, other.st_ino == info.st_ino { return .forbidden }
                if up == "/" { break }
                up = (up as NSString).deletingLastPathComponent
            }
        }
        var disk = statfs()
        if statfs(resolved, &disk) == 0 {
            let mount = withUnsafeBytes(of: &disk.f_mntonname) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if mount == resolved { return .forbidden }
        }
        return .ok(URL(fileURLWithPath: resolved, isDirectory: true))
    }
}

/// Whether every Mac of the account can take project secret files yet, and if not, the true reason.
public enum BackendProjectSecretFilesGate: Sendable, Equatable {
    case open
    /// A Mac of the account has not announced it yet (an older build, or Cloud memory off on that Mac).
    case waitingForMacs
    /// Cloud memory is off on this Mac: the "understands" mark travels with Cloud memory, so nothing can be agreed.
    case cloudMemoryOff
}

/// One project secret file, as sealed. Plain fields only; `data` is base64.
public struct BackendProjectSecretFileValue: Codable, Equatable, Sendable {
    public let v: Int
    public let projectId: String
    /// The project folder's own name on the sending Mac when the project has several folders; empty when it has one.
    public let folder: String
    public let path: String
    /// Permission bits only (0600 stays 0600).
    public let mode: Int
    public let data: String
    /// Account-keyed fingerprint of the bytes (the same on every Mac holding the key).
    public let mark: String
    /// The version this one was made on top of; absent for a first version.
    public let base: String?
    public let at: Int64
    /// The Mac where this version was made (its name, plain).
    public let from: String
}

/// What this Mac knows about each project secret file, per account key (the file name carries a keyed slot, so another
/// account or a new key generation starts its own). Local only, 0600, inside the app's data folder.
public struct BackendProjectSecretFileTarget: Sendable, Equatable {
    public let item: CloudDeleteItem
    public let folder: String
}

struct BackendProjectSecretFilesLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var projectId: String
        var folder: String
        var path: String
        /// The last version this Mac and Cloud agreed on (sent from here, or placed from another device).
        var mark: String
        var base: String?
        var at: Int64
        var from: String
        var mode: Int
        var bytes: Int
        /// Set when a version from another device was different from his own here: his stays.
        var differsFrom: String?
        var differsAt: Int64?
        /// Placed here from another device (ms).
        var arrivedAt: Int64?
        var lastSeenAt: Int64?
    }
    struct Waiting: Codable, Equatable {
        var projectId: String
        var path: String
        var from: String
        var at: Int64
        var why: String
        /// The record, sealed with this device's own holding key (AES-GCM combined, base64).
        var sealed: String
    }
    var files: [String: Entry] = [:]
    var waiting: [String: Waiting] = [:]
}

/// The tool's and the pages' view: names, sizes, dates and plain words. Never a secret's content, never an id.
public struct BackendProjectSecretFilesStatus: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let folder: String
        public let path: String
        public let bytes: Int
        public let at: Int64?
        public let from: String?
        /// "travels with your saved passwords", "arrived from <Mac>", "different on <Mac>, yours kept",
        /// "waiting for the project's folder on this Mac", "too large to travel", ...
        public let state: String
        public let travels: Bool
    }
    public struct Project: Sendable, Equatable {
        public let id: String
        public let name: String
        public let files: [File]
    }
    public var projects: [Project] = []
    public var keepOnThisMac = false
    /// Not every Mac of the account runs a build that takes project secret files yet: nothing is sent meanwhile.
    public var waitingForMacs = false
    /// The true reason nothing is sent yet (nil when files are sent).
    public var waitingWhy: String?
    /// Arrivals from another device this Mac refused since the app started (over a cap, or a file that runs programs).
    public var refusedArrivals = 0
    public var lookedAt: Int64?
    /// One fixed line when part of this Mac's Bin could not be read and was set aside (review 15 Nov, decision 8).
    public var binNotice: String?
}

public enum BackendProjectSecretFilesWords {
    public static let travels = "travels with your saved passwords"
    public static let keepSwitch = "Keep project secret files on this Mac only"
    public static func arrived(_ from: String) -> String { "arrived from " + from }
    public static func differs(_ from: String) -> String { "different on " + from + ", yours kept" }
    public static let waitingFolder = "waiting for the project's folder on this Mac"
    public static let waitingSetting = "waiting: kept on this Mac only is on"
    public static let waitingBlocked = "waiting: a link or another file is in its place"
    public static let tooLarge = "too large to travel (over 32 KB)"
    public static let tooMany = "not sent: this project has more than 40 secret files or 512 KB"
    public static let keptHere = "kept on this Mac only"
    /// Review 14 Nov (F11): the mark that says "this Mac takes them" travels with Cloud memory, so the wait names that.
    public static let waitingMacs = "waits until each of your Macs runs the new version with Cloud memory on"
    public static let waitingMemory = "waits: Cloud memory is off on this Mac (turn it on so your Macs can agree)"
    public static func waiting(_ gate: BackendProjectSecretFilesGate) -> String? {
        switch gate { case .open: nil; case .waitingForMacs: waitingMacs; case .cloudMemoryOff: waitingMemory }
    }
    /// Review 14 Nov (F2): a file that runs programs, or an `.npmrc` with other lines than registry and sign-in lines.
    public static let staysHere = "stays on this Mac: it can make a program run"
    public static let refusedPrograms = "not placed: it can make a program run"
    public static let refusedCaps = "not placed: this project already has 40 secret files or 512 KB here (or 400 in all)"
    public static let refusedWaitingFull = "not kept: too many files are already waiting on this Mac"
    /// Review 15 Nov (decision 5): the Bin is no side door; a copy that fails the arrival rules stays sealed in the Bin.
    public static let putBackPrograms = "not put back: it can make a program run (it stays in the Bin)"
    public static let putBackCaps = "not put back: this project already has 40 secret files or 512 KB here (or 400 in all)"
    /// Review 15 Nov (decision 11): a removal from another device whose project folder here cannot be used.
    public static let notRemovedWholeFolder = "not removed here: this project's folder here is your home folder or a whole disk"
    public static func notRemovedSameName(_ folder: String) -> String {
        "not removed here: two folders of this project here are both called \u{201C}" + folder + "\u{201D} (rename one)"
    }
    /// Review 15 Nov (decision 8).
    public static let binDamaged = "Part of the Bin on this Mac could not be read. It was set aside; everything else works as before."
    /// Review 14 Nov (F5): two folders of one project with the same name cannot be told apart between Macs.
    public static func sameName(_ folder: String) -> String {
        "not sent: two folders of this project are both called \u{201C}" + folder + "\u{201D} (rename one)"
    }
    public static func waitingSameName(_ folder: String) -> String {
        "waiting: two folders of this project here are both called \u{201C}" + folder + "\u{201D} (rename one)"
    }
    /// Review 14 Nov (F7).
    public static let wholeFolder = "nothing travels: this project's folder is your home folder or a whole disk"
    public static let waitingWholeFolder = "waiting: this project's folder here is your home folder or a whole disk"
    /// The switch's sub-line (review 14 Nov, F9).
    public static let keepSwitchDetail = "Stops sending this Mac's project secret files and placing arriving ones here. It does not take back copies your other computers already have."
    public static let keepNotSaved = "Could not save this setting, so nothing changed. Try again."
    /// A file that goes between his computers (sent from here, or arrived from another device): not "not sent to GitHub".
    public static func travelling(_ state: String) -> Bool { state == travels || state.hasPrefix("arrived from ") }

    /// The Code page: the held-back secret files of a project whose files travel say so (names and words only).
    public static func decorate(_ report: BackendCodeBackupReport, status: BackendProjectSecretFilesStatus?) -> BackendCodeBackupReport {
        guard let status else { return report }
        var report = report
        report.projects = report.projects.map { project in
            guard let known = status.projects.first(where: { $0.id == project.id }) else { return project }
            var project = project
            func lines(_ files: [BackendProjectSecretFilesStatus.File]) -> [String: String] {
                var result: [String: String] = [:]
                for file in files where file.travels || file.state.hasPrefix("different") { result[file.path] = file.state }
                return result
            }
            if project.parts.isEmpty {
                project.secretsTravel = lines(known.files)
            } else {
                project.parts = project.parts.map { part in
                    var part = part
                    part.secretsTravel = lines(known.files.filter { $0.folder == (part.folderName ?? part.id) })
                    return part
                }
                project.secretsTravel = project.parts.reduce(into: [String: String]()) { $0.merge($1.secretsTravel) { first, _ in first } }
            }
            return project
        }
        return report
    }
}

/// Lane V's logical store for project secret files. One per identity (built with the other stores), keyed by the
/// adapter before every capture and every arrival (`CloudSecretsKeyedStore`).
public actor BackendProjectSecretFilesStore: CloudSecretsLogicalStore, CloudSecretsKeyedStore, CloudSecretsDeletingStore, CloudDeleteOwning {
    public struct Project: Sendable, Equatable {
        public let id: String
        public let name: String
        public let folders: [String]
        public init(id: String, name: String, folders: [String]) { self.id = id; self.name = name; self.folders = folders }
    }
    public nonisolated let sourceId = BackendProjectSecretFilesRules.sourceId
    public nonisolated let inventoryRow = BackendProjectSecretFilesRules.inventoryRow
    public nonisolated let domain = CloudSecretsDomain.project
    private let stateRoot: URL
    private let projects: @Sendable () async -> [Project]
    private let deviceName: @Sendable () async -> String
    private let gate: @Sendable () async -> BackendProjectSecretFilesGate
    private let now: @Sendable () -> Int64
    /// The app's writer check (a read-only copy of the app never writes into his project folders).
    private let requireWriter: @Sendable () throws -> Void
    /// His home folder: a project whose folder is this or above it never takes part (review 14 Nov, F7).
    private let home: String
    /// Review 14 Nov (F10): one folder scan is reused for this long by every caller (coverage refresh, a conflict, a
    /// finished import); a file placed here forgets its folder's scan at once.
    private let walkReuse: Int64
    private var walks: [String: (at: Int64, found: [Found])] = [:]
    private var keys: CloudSecretsStoreKeys?
    private var ledger = BackendProjectSecretFilesLedger()
    private var ledgerSlot: String?
    /// The last look's held-back files (too large, too many, stays here), per project id, for the status.
    private var heldBack: [String: [BackendProjectSecretFilesStatus.File]] = [:]
    /// Arrivals refused since start (names for the status, at most `allFiles`; the count keeps going).
    private var refused: [String: (projectId: String, file: BackendProjectSecretFilesStatus.File)] = [:]
    private var refusedCount = 0
    private var gateState = BackendProjectSecretFilesGate.open
    /// This Mac's name as versions made here carry it (refreshed at each capture and arrival).
    private var myName = "another device"
    private var lookedAt: Int64?
    let deletion: BackendProjectSecretFilesDeleteState
    private let deleteGate: @Sendable () async -> Bool
    private let deleteStamp: @Sendable () async -> Int64?
    private let deleteDevice: @Sendable () async -> String
    private let deleteMacName: @Sendable (String) async -> String?
    private let witness: CloudDeleteWitnessSlot
    private var gone: [String: Int64] = [:]
    private var lastSeen: [String: Int64] = [:]
    private var deleteBusy = false
    private var deleteWaiters: [CheckedContinuation<Void, Never>] = []
    /// One look or delete action at a time; a second one waits its turn (never "busy", so nothing stalls or is dropped).
    private func enterDelete() async {
        guard deleteBusy else { deleteBusy = true; return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in deleteWaiters.append(waiter) }
    }
    private func leaveDelete() {
        if deleteWaiters.isEmpty { deleteBusy = false } else { deleteWaiters.removeFirst().resume() }
    }

    public init(stateRoot: URL, projects: @escaping @Sendable () async -> [Project], deviceName: @escaping @Sendable () async -> String,
                gate: @escaping @Sendable () async -> BackendProjectSecretFilesGate, requireWriter: @escaping @Sendable () throws -> Void = {},
                home: String = NSHomeDirectory(), walkReuse: Int64 = 60_000,
                deleteGate: @escaping @Sendable () async -> Bool = { false },
                deleteStamp: @escaping @Sendable () async -> Int64? = { Int64(Date().timeIntervalSince1970 * 1000) },
                deleteDevice: @escaping @Sendable () async -> String = { "" },
                deleteMacName: @escaping @Sendable (String) async -> String? = { _ in nil },
                witness: CloudDeleteWitnessSlot = .shared,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.stateRoot = stateRoot; self.projects = projects; self.deviceName = deviceName
        self.gate = gate; self.requireWriter = requireWriter; self.home = home; self.walkReuse = walkReuse; self.now = now
        self.deleteGate = deleteGate; self.deleteStamp = deleteStamp; self.deleteDevice = deleteDevice; self.deleteMacName = deleteMacName; self.witness = witness
        deletion = .init(root: stateRoot.appendingPathComponent("sealed-bin", isDirectory: true), source: BackendProjectSecretFilesRules.sourceId)
    }

    // MARK: Keys and the local ledger

    public func use(keys: CloudSecretsStoreKeys?) async {
        self.keys = keys
        deletion.use(keys)
        guard let keys else { ledgerSlot = nil; ledger = .init(); walks = [:]; gone = [:]; lastSeen = [:]; heldBack = [:]; refused = [:]; return }
        let slot = String(keys.shared(Data("ledger\n".utf8)).prefix(24))
        guard slot != ledgerSlot else { return }
        ledgerSlot = slot
        ledger = Self.readLedger(ledgerURL(slot)) ?? .init()
    }
    /// Never read whole when it is larger than it can grow by itself (review 14 Nov, F4).
    static func readLedger(_ url: URL) -> BackendProjectSecretFilesLedger? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= BackendProjectSecretFilesRules.ledgerBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BackendProjectSecretFilesLedger.self, from: data)
    }
    private func ledgerURL(_ slot: String) -> URL { stateRoot.appendingPathComponent("files-" + slot + ".json") }
    private func saveLedger() {
        guard let slot = ledgerSlot, let data = try? JSONEncoder().encode(ledger) else { return }
        try? Self.writePrivate(data, to: ledgerURL(slot), root: stateRoot)
    }
    /// The app's own small files: folder 0700, file 0600, written whole.
    static func writePrivate(_ data: Data, to url: URL, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw CloudFailure.unavailable }
    }

    // MARK: The stricter setting (his press only; default off)

    public nonisolated static func keepsOnThisMac(stateRoot: URL) -> Bool {
        guard let data = try? Data(contentsOf: stateRoot.appendingPathComponent("setting.json")),
              let value = try? JSONDecoder().decode([String: Bool].self, from: data) else { return false }
        return value["keepOnThisMac"] == true
    }
    /// Saved, then read back: true only when the setting on disk now says `on` (review 14 Nov, F9: never silently).
    public nonisolated static func saveKeepOnThisMac(_ on: Bool, stateRoot: URL) throws {
        try writePrivate(try JSONEncoder().encode(["keepOnThisMac": on]), to: stateRoot.appendingPathComponent("setting.json"), root: stateRoot)
        guard keepsOnThisMac(stateRoot: stateRoot) == on else { throw CloudFailure.unavailable }
    }
    public func keepOnThisMac() -> Bool { Self.keepsOnThisMac(stateRoot: stateRoot) }
    /// 15 Nov (the sealed shelf): his names for the projects, by id, so a phone lists "<project>: <file>".
    public func projectNames() async -> [String: String] {
        Dictionary(await projects().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
    public func setKeepOnThisMac(_ on: Bool) throws { try Self.saveKeepOnThisMac(on, stateRoot: stateRoot) }

    // MARK: Names and fingerprints

    private func recordId(_ keys: CloudSecretsStoreKeys, projectId: String, folder: String, path: String) -> String {
        "file/" + projectId + "/" + keys.shared(Data(("id\n" + projectId + "\n" + folder + "\n" + path).utf8))
    }
    private func mark(_ keys: CloudSecretsStoreKeys, _ bytes: Data) -> String { keys.shared(Data("content\n".utf8) + bytes) }

    // MARK: CloudSecretsLogicalStore

    public func capture() async throws -> [CloudSecretRecord] {
        guard let keys else { throw CloudFailure.secretsLocked }
        try deletion.ready()
        await enterDelete(); defer { leaveDelete() }
        try deletion.expire(now: await deleteStamp())
        let list = await projects().filter { PROJProjects.isValidID($0.id) && $0.id != PROJProjects.independentID }
        let keep = keepOnThisMac()
        if !keep { try await noticeMissing(list, keys: keys); await placeWaiting(list, keys: keys) }
        lookedAt = now()
        // Review 14 Nov (R3): nothing can be sent, so the kept scan (it holds contents) is not kept either.
        guard !keep else { heldBack = [:]; walks = [:]; return [] }
        gateState = await gate()
        guard gateState == .open else { walks = [:]; return [] }
        let name = Self.plainName(await deviceName())
        myName = name
        let rules = BackendProjectSecretFilesRules.self
        var records: [CloudSecretRecord] = [], seen: Set<String> = [], held: [String: [BackendProjectSecretFilesStatus.File]] = [:], changed = false
        var roots: Set<String> = []
        // One project's trouble (a clash, a forbidden folder, a file that cannot be sealed) never stops the others.
        for project in list.sorted(by: { $0.id < $1.id }) {
            var count = 0, bytes = 0
            let names = project.folders.map { URL(fileURLWithPath: $0).lastPathComponent }
            for (index, registered) in project.folders.enumerated() {
                // A project with one folder names none (each Mac has its own folder name for it); with several, the
                // folder's own name tells them apart.
                let folder = project.folders.count == 1 ? "" : names[index]
                func holdBack(_ path: String, _ size: Int, _ at: Int64?, _ state: String) {
                    held[project.id, default: []].append(.init(folder: folder, path: path, bytes: size, at: at, from: nil, state: state, travels: false))
                }
                guard folder.isEmpty || rules.cleanFolderName(folder) else { continue }
                // Two folders with one name: their records would share names, and no Mac could tell them apart.
                if !folder.isEmpty, names.filter({ $0.caseInsensitiveCompare(folder) == .orderedSame }).count > 1 {
                    holdBack(folder + "/", 0, nil, BackendProjectSecretFilesWords.sameName(folder)); continue
                }
                let root: URL
                switch rules.realRoot(registered, home: home) {
                case .missing: continue
                case .forbidden: holdBack(names[index] + "/", 0, nil, BackendProjectSecretFilesWords.wholeFolder); continue
                case .ok(let url): root = url
                }
                roots.insert(root.path)
                for found in walked(root) {
                    if found.stays { holdBack(found.path, found.size, found.at, BackendProjectSecretFilesWords.staysHere); continue }
                    guard found.size <= rules.fileBytes, found.data.count <= rules.fileBytes else {
                        holdBack(found.path, found.size, found.at, BackendProjectSecretFilesWords.tooLarge); continue
                    }
                    guard count < rules.projectFiles, bytes + found.data.count <= rules.projectBytes, records.count < rules.allFiles else {
                        holdBack(found.path, found.size, found.at, BackendProjectSecretFilesWords.tooMany); continue
                    }
                    let id = recordId(keys, projectId: project.id, folder: folder, path: found.path)
                    // Never two records with one name (the adapter would refuse the whole batch).
                    guard !seen.contains(id) else { continue }
                    let current = mark(keys, found.data)
                    gone[id] = nil; lastSeen[id] = now()
                    if let localMark = try deletion.mark(id) {
                        if localMark.mark == .onlyOnThisMac { continue }
                        if let newest = deletion.newest(id), let newestPair = try? decoded(newest), deletion.isDeleted(id) {
                            if current == newestPair.0.mark {
                                if deletion.isUnplaced(id) {
                                    // Decision 10: the removal reached this Mac while this project folder was not here. The
                                    // same bytes in the folder now are that removed file: into the Bin (its sealed copy
                                    // exists). Refused (a link, a change in the way): kept, tried at the next look, no stall.
                                    if (try? removeFile(newest, projects: list)) == true {
                                        try deletion.placedUnplaced(id); ledger.files[id] = nil; changed = true
                                    }
                                    continue
                                }
                                // Decision 10: removed here, and the same bytes are back at that place: he put it back
                                // himself. It is his new version: it syncs and beats the removal on his other computers.
                                try deletion.restored(id, keepHandMark: false)
                                try deletion.markDeliberate(id)
                                ledger.files[id] = .init(projectId: project.id, folder: folder, path: found.path, mark: current,
                                    base: newestPair.0.base, at: newestPair.0.at, from: newestPair.0.from, mode: found.mode,
                                    bytes: found.data.count, differsFrom: nil, differsAt: nil, arrivedAt: nil)
                                changed = true
                            } else {
                                try deletion.restored(id, keepHandMark: false)
                            }
                        } else if let newest = deletion.newest(id), let newestPair = try? decoded(newest) {
                            if current == newestPair.0.mark {
                                try deletion.restored(id, keepHandMark: false)
                                _ = place(newestPair.0, bytes: newestPair.1, id: id, keys: keys, projects: list, keep: false)
                                continue
                            }
                            if deletion.fileMarks(id).contains(current) {
                                // J-7: a branch switch brought old bytes back. Keep them sealed, write the Cloud's newest
                                // FIRST and clear the mark only after (decision 3). A failed write keeps the mark: the old
                                // bytes are never captured as a new version over the newer one; the next look tries again.
                                let before = BackendProjectSecretFileValue(v: 1, projectId: project.id, folder: folder, path: found.path,
                                    mode: found.mode, data: found.data.base64EncodedString(), mark: current, base: nil, at: found.at, from: name)
                                guard let safety = try? BackendCloudSecretsRecords.record(sourceId, id, domain, before),
                                      (try? deletion.keepSafety(safety, at: now())) != nil else { continue }
                                do { try Self.write(root, found.path, bytes: newestPair.1, expecting: found.data, at: newestPair.0.at) }
                                catch { continue }
                                walks[root.path] = nil
                                try deletion.restored(id, keepHandMark: false)
                                _ = place(newestPair.0, bytes: newestPair.1, id: id, keys: keys, projects: list, keep: false)
                                continue
                            }
                            try deletion.restored(id, keepHandMark: false)
                        } else {
                            try deletion.restored(id, keepHandMark: false)
                        }
                    }
                    var known = ledger.files[id]
                    if known?.mark != current {
                        // A new version made here, on top of the last agreed one.
                        known = .init(projectId: project.id, folder: folder, path: found.path, mark: current,
                                      base: deletion.newest(id)?.payload.raw["mark"].string ?? known?.mark, at: found.at,
                                      from: name, mode: found.mode, bytes: found.data.count, differsFrom: nil, differsAt: nil, arrivedAt: nil)
                        ledger.files[id] = known; changed = true
                    } else if known?.mode != found.mode {
                        known?.mode = found.mode; ledger.files[id] = known; changed = true
                    }
                    guard let entry = known else { continue }
                    let value = BackendProjectSecretFileValue(v: 1, projectId: project.id, folder: folder, path: found.path, mode: entry.mode,
                        data: found.data.base64EncodedString(), mark: entry.mark, base: entry.base, at: entry.at, from: entry.from)
                    guard let record = try? BackendCloudSecretsRecords.record(sourceId, id, domain, value) else {
                        holdBack(found.path, found.size, found.at, BackendProjectSecretFilesWords.tooLarge); continue
                    }
                    count += 1; bytes += found.data.count
                    try deletion.remember(record)
                    seen.insert(id); records.append(record)
                }
            }
        }
        // A folder no project uses any more is forgotten (with its bytes).
        walks = walks.filter { roots.contains($0.key) }
        heldBack = held
        if changed { saveLedger() }
        return records
    }

    /// The kept scan of one folder when it is recent enough, else a new one.
    private func walked(_ root: URL) -> [Found] {
        let at = now()
        if let kept = walks[root.path], at >= kept.at, at - kept.at < walkReuse { return kept.found }
        let found = Self.walk(root, now: at)
        walks[root.path] = (at, found)
        return found
    }

    public func validate(_ record: CloudSecretRecord) async throws { _ = try decoded(record) }

    /// What a record must be to be looked at at all; anything else is refused whole. A file that runs programs passes
    /// here and is refused, counted and named at merge (one bad file never stops a batch).
    private func decoded(_ record: CloudSecretRecord) throws -> (BackendProjectSecretFileValue, Data) {
        guard let keys else { throw CloudFailure.secretsLocked }
        let value = try BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, record, source: sourceId, domain: domain)
        guard value.v == 1, PROJProjects.isValidID(value.projectId), value.projectId != PROJProjects.independentID,
              value.folder.isEmpty || BackendProjectSecretFilesRules.cleanFolderName(value.folder), (0...0o777).contains(value.mode), value.at >= 0,
              !value.from.isEmpty, value.from.utf8.count <= 80, value.from.rangeOfCharacter(from: .controlCharacters) == nil,
              let bytes = Data(base64Encoded: value.data), bytes.count <= BackendProjectSecretFilesRules.fileBytes,
              BackendProjectSecretFilesRules.verdict(value.path, bytes: bytes) != .never,
              value.mark == mark(keys, bytes), value.base.map({ $0.count == 64 }) ?? true,
              record.recordId == recordId(keys, projectId: value.projectId, folder: value.folder, path: value.path) else { throw CloudFailure.invalidRequest }
        return (value, bytes)
    }

    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let pair = try decoded(record)
        let value = pair.0, bytes = pair.1
        guard let keys else { throw CloudFailure.secretsLocked }
        try requireWriter()
        myName = Self.plainName(await deviceName())
        // Checked again here, on this Mac's own rule: a file that runs programs is never created or replaced.
        guard BackendProjectSecretFilesRules.verdict(value.path, bytes: bytes) == .travels else {
            refuse(value, id: record.recordId, why: BackendProjectSecretFilesWords.refusedPrograms)
            return .alreadyPresent
        }
        let list = await projects()
        if let localMark = try deletion.mark(record.recordId) {
            if localMark.mark == .notOnThisMac, !deletion.isDeleted(record.recordId) {
                try deletion.remember(record)
                ledger.files[record.recordId] = .init(projectId: value.projectId, folder: value.folder, path: value.path,
                    mark: value.mark, base: value.base, at: value.at, from: value.from, mode: value.mode, bytes: bytes.count,
                    differsFrom: nil, differsAt: nil, arrivedAt: now(), lastSeenAt: ledger.files[record.recordId]?.lastSeenAt)
                saveLedger(); return .alreadyPresent
            }
            if try deletion.hasVersion(record) { return .alreadyPresent }
            // A new put on top of a travelling removal brings the item back into sync.
            try deletion.restored(record.recordId)
        }
        try deletion.remember(record)
        let outcome = place(value, bytes: bytes, id: record.recordId, keys: keys, projects: list, keep: keepOnThisMac())
        switch outcome {
        case .wait(let why):
            if !hold(record, value: value, why: why, keys: keys) { refuse(value, id: record.recordId, why: BackendProjectSecretFilesWords.refusedWaitingFull) }
            saveLedger()
            return .alreadyPresent
        case .refused(let why):
            refuse(value, id: record.recordId, why: why)
            ledger.waiting[record.recordId] = nil
            saveLedger()
            return .alreadyPresent
        case .applied, .keptBoth, .same:
            ledger.waiting[record.recordId] = nil
            refused[record.recordId] = nil
            saveLedger()
            return outcome == .applied ? .applied : outcome == .keptBoth ? .keptBoth : .alreadyPresent
        }
    }

    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        guard outcome == .applied else { return true }
        let pair = try decoded(record)
        let value = pair.0, bytes = pair.1
        guard case .ok(let root) = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: await projects()) else { return false }
        if case .file(let held) = CloudFolderDisk.read(root, value.path) { return held == bytes }
        return false
    }

    // MARK: Arrival

    enum Placed: Equatable { case applied, same, keptBoth, wait(String), refused(String) }
    /// `wait`: the folder is not on this Mac (missing, unreadable, or EMPTY: decision 11 treats an empty folder like a
    /// missing one). `unusable`: it is here but can never be used (the home-folder refusal, two same-named folders);
    /// `removal` names that for an arriving removal, which is then not recorded as done.
    enum ArrivalRoot: Equatable { case ok(URL), wait(String), unusable(waiting: String, removal: String) }

    /// A folder with nothing in it (Finder's own `.DS_Store` aside), or one that cannot be read.
    static func emptyFolder(_ url: URL) -> Bool {
        guard let dir = opendir(url.path) else { return true }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if name != ".", name != "..", name != ".DS_Store" { return false }
        }
        return true
    }

    /// The project's folder on this Mac for a record: its only folder, else the ONE folder with that name (never "the
    /// first" of two with one name), resolved once to its real folder. A record from a one-folder project waits on a Mac
    /// where that project has several. `allowEmpty`: his own press (Put back, Bring back, the bin buttons) may use an
    /// empty folder; nothing automatic does.
    private func arrivalRoot(projectId: String, folder: String, projects: [Project], allowEmpty: Bool = false) -> ArrivalRoot {
        guard let project = projects.first(where: { $0.id == projectId }), !project.folders.isEmpty else {
            return .wait(BackendProjectSecretFilesWords.waitingFolder)
        }
        let chosen: String
        if project.folders.count == 1 {
            // Review 14 Nov (R1): a record that names a folder lands only in a folder of that name, never in another one.
            guard folder.isEmpty || URL(fileURLWithPath: project.folders[0]).lastPathComponent.caseInsensitiveCompare(folder) == .orderedSame else {
                return .wait(BackendProjectSecretFilesWords.waitingFolder)
            }
            chosen = project.folders[0]
        } else {
            guard !folder.isEmpty else { return .wait(BackendProjectSecretFilesWords.waitingFolder) }
            let matches = project.folders.filter { URL(fileURLWithPath: $0).lastPathComponent.caseInsensitiveCompare(folder) == .orderedSame }
            guard matches.count <= 1 else {
                return .unusable(waiting: BackendProjectSecretFilesWords.waitingSameName(folder), removal: BackendProjectSecretFilesWords.notRemovedSameName(folder))
            }
            guard let only = matches.first else { return .wait(BackendProjectSecretFilesWords.waitingFolder) }
            chosen = only
        }
        switch BackendProjectSecretFilesRules.realRoot(chosen, home: home) {
        case .ok(let url): return allowEmpty || !Self.emptyFolder(url) ? .ok(url) : .wait(BackendProjectSecretFilesWords.waitingFolder)
        case .missing: return .wait(BackendProjectSecretFilesWords.waitingFolder)
        case .forbidden: return .unusable(waiting: BackendProjectSecretFilesWords.waitingWholeFolder, removal: BackendProjectSecretFilesWords.notRemovedWholeFolder)
        }
    }

    /// Review 14 Nov (F4): the caps hold on arrival too. Counted over what this Mac knows is on its disk now (the ledger's
    /// files that are still there), plus this one.
    private func withinCaps(_ value: BackendProjectSecretFileValue, size: Int, id: String, projects: [Project]) -> Bool {
        let rules = BackendProjectSecretFilesRules.self
        var roots: [String: URL] = [:], noRoot: Set<String> = []
        var projectCount = 0, projectBytes = 0, all = 0
        for (other, entry) in ledger.files where other != id {
            let key = entry.projectId + "\n" + entry.folder
            if roots[key] == nil, !noRoot.contains(key) {
                if case .ok(let url) = arrivalRoot(projectId: entry.projectId, folder: entry.folder, projects: projects) { roots[key] = url }
                else { noRoot.insert(key) }
            }
            guard let root = roots[key] else { continue }
            var info = stat()
            guard lstat(root.appendingPathComponent(entry.path).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            all += 1
            if entry.projectId == value.projectId { projectCount += 1; projectBytes += Int(info.st_size) }
        }
        return projectCount < rules.projectFiles && projectBytes + size <= rules.projectBytes && all < rules.allFiles
    }

    private func place(_ value: BackendProjectSecretFileValue, bytes: Data, id: String, keys: CloudSecretsStoreKeys, projects: [Project], keep: Bool) -> Placed {
        if keep { return .wait(BackendProjectSecretFilesWords.waitingSetting) }
        let root: URL
        switch arrivalRoot(projectId: value.projectId, folder: value.folder, projects: projects) {
        case .wait(let why), .unusable(waiting: let why, removal: _): return .wait(why)
        case .ok(let url): root = url
        }
        if (try? deletion.mark(id)) != nil { return .same }
        // A removal applied here drops the item from this list (decision 1), so a put back or a newer version arriving
        // after it is placed like any arrival. A listed file that is absent was removed outside the app: the next look
        // marks it "Not on this Mac" (and drops this waiting arrival); only that mark keeps arrivals away.
        let entry = ledger.files[id]
        func agreed() {
            ledger.files[id] = .init(projectId: value.projectId, folder: value.folder, path: value.path, mark: value.mark, base: value.base,
                                     at: value.at, from: value.from, mode: Self.modeOnDisk(root, value.path), bytes: bytes.count, differsFrom: nil,
                                     differsAt: nil, arrivedAt: now())
        }
        if CloudFolderDisk.caseClash(root, value.path) { return differs(value, id: id, local: nil, keys: keys) }
        switch CloudFolderDisk.read(root, value.path) {
        case .blocked:
            return .wait(BackendProjectSecretFilesWords.waitingBlocked)
        case .absent:
            // A known file is between absent looks, or removed by hand. Never let an arrival undo that:
            // keep the newest sealed until the look records the mark or the person explicitly brings it back.
            if entry != nil { return .wait(CloudDeleteWords.notOnThisMac) }
            guard withinCaps(value, size: bytes.count, id: id, projects: projects) else { return .refused(BackendProjectSecretFilesWords.refusedCaps) }
            do { try Self.write(root, value.path, bytes: bytes, expecting: nil, at: value.at) }
            catch { return .wait(BackendProjectSecretFilesWords.waitingBlocked) }
            walks[root.path] = nil
            agreed(); return .applied
        case .file(let local):
            let localMark = mark(keys, local)
            if localMark == value.mark { if entry?.mark != value.mark { agreed() }; return .same }
            // Made on top of exactly what is here, and what is here is the last agreed version: the newer one wins.
            if let entry, entry.mark == localMark, value.base == localMark {
                guard withinCaps(value, size: bytes.count, id: id, projects: projects) else { return .refused(BackendProjectSecretFilesWords.refusedCaps) }
                do {
                    let before = BackendProjectSecretFileValue(v: 1, projectId: entry.projectId, folder: entry.folder, path: entry.path,
                        mode: Self.modeOnDisk(root, value.path), data: local.base64EncodedString(), mark: localMark,
                        base: entry.base, at: entry.at, from: entry.from)
                    try deletion.keepSafety(BackendCloudSecretsRecords.record(sourceId, id, domain, before), at: now())
                    try Self.write(root, value.path, bytes: bytes, expecting: local, at: value.at)
                }
                catch { return differs(value, id: id, local: local, keys: keys) }
                walks[root.path] = nil
                agreed(); return .applied
            }
            return differs(value, id: id, local: local, keys: keys)
        }
    }

    static func modeOnDisk(_ root: URL, _ relative: String) -> Int {
        var info = stat()
        guard lstat(root.appendingPathComponent(relative).path, &info) == 0 else { return 0o600 }
        return Int(info.st_mode & 0o777)
    }

    /// His own text wins: nothing here changes. The other version stays sealed in the kept-conflicts store (the adapter
    /// keeps it) and on the other Mac; the line says so.
    private func differs(_ value: BackendProjectSecretFileValue, id: String, local: Data?, keys: CloudSecretsStoreKeys) -> Placed {
        var entry = ledger.files[id] ?? .init(projectId: value.projectId, folder: value.folder, path: value.path,
            mark: local.map { mark(keys, $0) } ?? "", base: nil, at: now(), from: myName, mode: 0o600, bytes: local?.count ?? 0,
            differsFrom: nil, differsAt: nil, arrivedAt: nil)
        entry.differsFrom = value.from; entry.differsAt = value.at
        ledger.files[id] = entry
        return .keptBoth
    }

    /// Kept sealed with this Mac's own key until it can be placed; false when the waiting list is full (its caps:
    /// `projectFiles` per project, `allFiles` and `waitingBytes` in all).
    private func hold(_ record: CloudSecretRecord, value: BackendProjectSecretFileValue, why: String, keys: CloudSecretsStoreKeys) -> Bool {
        guard let plain = try? CloudSecretsCanonical.encode(record), let sealed = try? AES.GCM.seal(plain, using: keys.local).combined else { return false }
        let text = sealed.base64EncodedString()
        let rules = BackendProjectSecretFilesRules.self
        var count = 0, project = 0, size = 0
        for (other, waiting) in ledger.waiting where other != record.recordId {
            count += 1; size += waiting.sealed.utf8.count
            if waiting.projectId == value.projectId { project += 1 }
        }
        guard count < rules.allFiles, project < rules.projectFiles, size + text.utf8.count <= rules.waitingBytes else { return false }
        ledger.waiting[record.recordId] = .init(projectId: value.projectId, path: value.path, from: value.from, at: value.at, why: why, sealed: text)
        return true
    }

    /// Counted, and named in the status (at most `allFiles` names; the count keeps going).
    private func refuse(_ value: BackendProjectSecretFileValue, id: String, why: String) {
        refusedCount += 1
        guard refused[id] != nil || refused.count < BackendProjectSecretFilesRules.allFiles else { return }
        refused[id] = (value.projectId, .init(folder: value.folder, path: value.path, bytes: 0, at: value.at, from: value.from, state: why, travels: false))
    }

    /// Arrivals that waited (no folder yet, the stricter setting, a link in the way) are placed when they can be.
    private func placeWaiting(_ list: [Project], keys: CloudSecretsStoreKeys) async {
        guard !ledger.waiting.isEmpty, (try? requireWriter()) != nil else { return }
        var changed = false
        for (id, waiting) in ledger.waiting.sorted(by: { $0.key < $1.key }) {
            guard let combined = Data(base64Encoded: waiting.sealed), let box = try? AES.GCM.SealedBox(combined: combined),
                  let plain = try? AES.GCM.open(box, using: keys.local),
                  let record = try? CloudWire.decode(CloudSecretRecord.self, from: plain, maximumBytes: CloudWire.maximumPlainChunkBytes),
                  record.recordId == id, let pair = try? decoded(record),
                  BackendProjectSecretFilesRules.verdict(pair.0.path, bytes: pair.1) == .travels else {
                ledger.waiting[id] = nil; changed = true; continue
            }
            switch place(pair.0, bytes: pair.1, id: id, keys: keys, projects: list, keep: false) {
            case .wait(let why): if why != waiting.why { ledger.waiting[id]?.why = why; changed = true }
            case .refused(let why): refuse(pair.0, id: id, why: why); ledger.waiting[id] = nil; changed = true
            default: ledger.waiting[id] = nil; changed = true
            }
        }
        if changed { saveLedger() }
    }

    /// Writes one secret file safely: the folders on the way are checked (never through a link); a temporary file (named
    /// so the Code page holds it back) opened 0600 with O_EXCL|O_NOFOLLOW beside it, filled and synced, then linked in
    /// (nothing there) or renamed over exactly the bytes `expecting`. Permission (review 14 Nov, F1): the sender's is
    /// never believed. A new file is owner-only (0600); a replaced file keeps his own permission.
    static func write(_ root: URL, _ relative: String, bytes: Data, expecting: Data?, at: Int64) throws {
        guard CloudFolderDisk.parents(root, relative, make: true) == .ready else { throw CloudFailure.unsafeConfiguration }
        let target = root.appendingPathComponent(relative)
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(BackendProjectSecretFilesRules.temporaryName())
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CloudFailure.unsafeConfiguration }
        var isOpen = true
        defer {
            if isOpen { close(fd) }
            unlink(temporary.path)
        }
        var ok = true
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { ok = false; break }
                offset += written
            }
        }
        guard ok, fsync(fd) == 0 else { throw CloudFailure.unavailable }
        var mode: mode_t = 0o600
        switch CloudFolderDisk.read(root, relative) {
        case .absent:
            guard expecting == nil else { throw CloudFailure.versionChanged }
        case .file(let held):
            guard let expecting, held == expecting else { throw CloudFailure.versionChanged }
            var info = stat()
            guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CloudFailure.versionChanged }
            mode = info.st_mode & 0o777
        case .blocked:
            throw CloudFailure.unsafeConfiguration
        }
        guard fchmod(fd, mode) == 0 else { throw CloudFailure.unavailable }
        let seconds = at / 1000
        var times = [timespec(tv_sec: Int(seconds), tv_nsec: Int((at % 1000) * 1_000_000)),
                     timespec(tv_sec: Int(seconds), tv_nsec: Int((at % 1000) * 1_000_000))]
        _ = futimens(fd, &times)
        close(fd); isOpen = false
        if expecting == nil {
            guard link(temporary.path, target.path) == 0 else { throw CloudFailure.versionChanged }
        } else {
            guard rename(temporary.path, target.path) == 0 else { throw CloudFailure.unavailable }
        }
        try? BackendCloudBrainMemoryHash.synchronizeDirectory(folder)
    }

    // MARK: Delete rule (the Bin calls below belong to the person's UI only)

    /// Code-page/tool routing by a project's visible file name. No bytes or Bin entries are returned.
    public func deleteItem(projectId: String, folder: String, path: String) throws -> CloudDeleteItem? {
        guard let keys else { throw CloudFailure.secretsLocked }
        let id = recordId(keys, projectId: projectId, folder: folder, path: path)
        guard !deletion.isDeleted(id) else { return nil }
        return try deletion.newest(id).map { try deleteItem($0) }
    }
    /// Integration (AI tools' targets): every tracked project secret file by name with its folder; never bytes, never
    /// a Bin entry.
    public func deleteListing() throws -> [BackendProjectSecretFileTarget] {
        guard keys != nil else { throw CloudFailure.secretsLocked }
        return ledger.files.values.sorted { ($0.projectId, $0.path) < ($1.projectId, $1.path) }.compactMap { entry in
            (try? deleteItem(projectId: entry.projectId, folder: entry.folder, path: entry.path)).flatMap { $0 }
                .map { BackendProjectSecretFileTarget(item: $0, folder: entry.folder) }
        }
    }
    private func deleteItem(_ record: CloudSecretRecord) throws -> CloudDeleteItem {
        let value = try decoded(record).0
        return .init(id: record.recordId, kind: "project-secret-files", name: value.path, place: value.projectId)
    }
    /// Tests only: the sealed Bin's saves fail while this is on (decision 2's failing case).
    func failSavesForTesting(_ on: Bool) { deletion.failSaves = on }
    /// Decision 7: whether "Everywhere" (and "Cloud") can be honoured right now; pages hide both buttons when false.
    public func canDeleteEverywhere() async -> Bool {
        guard keys != nil, (try? deletion.ready()) != nil else { return false }
        return await deleteGate()
    }
    enum Unlinked { case removed, absent, kept }
    /// Decision 12: removes exactly `expected` at `relative` without following a link swapped in between the check and
    /// the removal. Every folder on the way is opened from the one above it with O_NOFOLLOW (as the placing code never
    /// writes through a link), the file is opened O_NOFOLLOW and compared by its bytes, its name is checked to still be
    /// that very file, and it is removed with unlinkat inside the folder that was opened.
    static func unlinkExactly(_ root: URL, _ relative: String, expected: Data) throws -> Unlinked {
        guard let parts = CloudBootFilesRules.parts(relative), let name = parts.last, !name.isEmpty, name != ".", name != ".." else { return .kept }
        var folder = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return .kept }
        defer { close(folder) }
        for part in parts.dropLast() {
            guard !part.isEmpty, part != ".", part != ".." else { return .kept }
            let next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { return errno == ENOENT ? .absent : .kept }
            close(folder); folder = next
        }
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? .absent : .kept }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, Int(opened.st_size) <= BackendProjectSecretFilesRules.fileBytes else { return .kept }
        var held = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { return .kept }
            if count == 0 { break }
            held.append(contentsOf: buffer[0..<count])
            if held.count > BackendProjectSecretFilesRules.fileBytes { return .kept }
        }
        guard held == expected else { return .kept }
        var named = stat()
        guard fstatat(folder, name, &named, AT_SYMLINK_NOFOLLOW) == 0, named.st_mode & S_IFMT == S_IFREG,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { return .kept }
        guard unlinkat(folder, name, 0) == 0 else { throw CloudFailure.unavailable }
        _ = fsync(folder)
        return .removed
    }
    private func removeFile(_ record: CloudSecretRecord, projects: [Project]) throws -> Bool {
        let (value, bytes) = try decoded(record)
        guard case .ok(let root) = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: projects, allowEmpty: true) else { return false }
        try requireWriter()
        switch try Self.unlinkExactly(root, value.path, expected: bytes) {
        case .removed: walks[root.path] = nil; return true
        case .absent: return true
        case .kept: return false
        }
    }
    private func noticeMissing(_ list: [Project], keys: CloudSecretsStoreKeys) async throws {
        let open = await deleteGate()
        for (id, entry) in ledger.files {
            // A missing, unreadable or EMPTY root is never evidence of anything (rule 7, decision 11): no mark, no removal.
            guard try deletion.mark(id) == nil,
                  case .ok(let root) = arrivalRoot(projectId: entry.projectId, folder: entry.folder, projects: list),
                  access(root.path, R_OK | X_OK) == 0 else { continue }
            switch CloudFolderDisk.read(root, entry.path) {
            case .file: gone[id] = nil; lastSeen[id] = now(); ledger.files[id]?.lastSeenAt = now(); continue
            case .blocked: continue
            case .absent: break
            }
            let at = now()
            guard let first = gone[id] else { gone[id] = at; continue }
            guard at >= first, at - first >= 3_000 else { continue }
            gone[id] = nil
            ledger.waiting[id] = nil
            if let intent = try deletion.intent(id), let record = deletion.newest(id) {
                // An app delete of this very action (an intent is written last and cleared first, decision 2).
                let actor = CloudDeleteActor(by: intent.by, mac: intent.mac, macName: myName, session: intent.session,
                    agent: intent.agent, at: intent.at, group: intent.group)
                do {
                    let removal = try deletion.prepare(record, item: deleteItem(record), scope: intent.scope, actor: actor, travel: open, binnedAt: await deleteStamp())
                    try deletion.finish(removal)
                    if intent.scope == .everywhere { ledger.files[id] = nil }
                } catch { try? deletion.mark(id, .notOnThisMac, at: at) }
                continue
            }
            let answer = await witness.who(removed: root.appendingPathComponent(entry.path),
                lastSeen: Date(timeIntervalSince1970: Double(lastSeen[id] ?? entry.lastSeenAt ?? entry.at) / 1000),
                seenGoneAt: Date(timeIntervalSince1970: Double(at) / 1000))
            guard self.keys != nil else { throw CloudFailure.secretsLocked }
            let device = await deleteDevice()
            // Without the gate (decision 7), this Mac's id, the service clock or a proper command group it cannot be an
            // attributed Everywhere removal: it stays by hand (a mark), the safe side.
            if open, case .ai(let session, let agent, _, let group) = answer, UUID(uuidString: group) != nil, !device.isEmpty,
               let record = deletion.newest(id), let stamp = await deleteStamp() {
                let actor = CloudDeleteActor(by: .ai, mac: device, macName: Self.plainName(await deviceName()),
                    session: session, agent: agent, at: stamp, group: group)
                do {
                    let removal = try deletion.prepare(record, item: deleteItem(record), scope: .everywhere, actor: actor, travel: true, binnedAt: stamp)
                    try deletion.finish(removal)
                    ledger.files[id] = nil
                } catch { try? deletion.mark(id, .notOnThisMac, at: at) }
            } else {
                try deletion.mark(id, .notOnThisMac, at: at)
            }
        }
        saveLedger()
    }
    /// Decision 6: nil (the old form build 5e1ecbae2 reads) for every ordinary upload, also while the gate is open.
    public func versionForUpload(_ record: CloudSecretRecord) async throws -> String? {
        try deletion.ready()
        guard await deleteGate() else { return nil }
        return try deletion.uploadVersion(record)
    }
    public func mergeVersioned(_ record: CloudSecretRecord, version: String, removalGroup: String?) async throws -> CloudApplyStatus {
        try deletion.ready()
        guard UUID(uuidString: version) != nil else { throw CloudFailure.invalidRequest }
        if deletion.earlierVersion(record.recordId, version) { return .alreadyPresent }
        if deletion.newVersion(record.recordId, version), let mark = try deletion.mark(record.recordId),
           mark.mark == .onlyOnThisMac || deletion.isDeleted(record.recordId) { try deletion.restored(record.recordId) }
        if let removalGroup, deletion.reintroduces(record.recordId, group: removalGroup) { try deletion.restored(record.recordId) }
        let outcome = try await merge(record)
        if outcome != .keptBoth { try deletion.adoptVersion(record, version) }
        return outcome
    }
    public func republication(recordId: String) async throws -> String? {
        try deletion.ready()
        return await deleteGate() ? deletion.republication(recordId) : nil
    }
    public func mergeReintroduced(_ record: CloudSecretRecord, removalGroup: String) async throws -> CloudApplyStatus {
        try deletion.ready()
        if deletion.reintroduces(record.recordId, group: removalGroup) { try deletion.restored(record.recordId) }
        return try await merge(record)
    }
    public func captureRemovals() async throws -> [CloudSecretRemoval] {
        guard await deleteGate() else { return [] }
        return try deletion.pending()
    }
    public func validateRemoval(_ removal: CloudSecretRemoval) async throws {
        try deletion.ready()
        guard removal.sourceId == sourceId, removal.domain == domain.rawValue, (removal.version.count == 64 || UUID(uuidString: removal.version) != nil),
              removal.recordId.hasPrefix("file/"), removal.at > 0, removal.at <= BackendProjectSecretFilesDeleteState.latestAt,
              case .intent = try CloudDeleteTravel.read(removal.fields, place: removal.recordId, mac: removal.mac, at: removal.at) else { throw CloudFailure.invalidRequest }
        try deletion.validate(removal)
        if let removed = removal.removed { _ = try decoded(removed) }
    }
    public func mergeRemoval(_ removal: CloudSecretRemoval) async throws -> CloudApplyStatus {
        await enterDelete(); defer { leaveDelete() }
        try await validateRemoval(removal)
        if deletion.superseded(removal) { return .alreadyPresent }
        guard let keys else { throw CloudFailure.secretsLocked }
        guard case .intent(let intent) = try CloudDeleteTravel.read(removal.fields, place: removal.recordId, mac: removal.mac, at: removal.at) else { throw CloudFailure.invalidRequest }
        let list = await projects()
        let known = deletion.newest(removal.recordId)
        guard let record = known ?? removal.removed, try deletion.matches(record, removal) else { return .keptBoth }
        let (value, bytes) = try decoded(record)
        // Only over exactly the removed version: a different file here (a later edit) wins; a link or unsafe
        // folder on the way is never followed. Both close the removal as not applied, without stalling the feed.
        let root = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: list)
        var unplaced = false
        switch root {
        case .unusable(waiting: _, removal: let why):
            // Decision 11: a folder that is here but cannot be used is named, and the removal is not recorded as done.
            refuse(value, id: removal.recordId, why: why)
            return .keptBoth
        case .wait:
            // The project folder is not on this Mac (or empty): nothing to unlink. Kept in the sealed Bin and marked.
            unplaced = intent.scope == .everywhere
        case .ok(let folder):
            switch CloudFolderDisk.read(folder, value.path) {
            case .file(let local): if mark(keys, local) != value.mark { return .keptBoth }
            case .blocked: return .keptBoth
            case .absent: break
            }
        }
        if known == nil {
            // Decision 5: a copy that never was on this Mac is checked like any arriving file. It stays sealed in the Bin
            // (never written by itself; Put back checks it again), it is named when it may never be written here, and a
            // full Bin refuses it.
            guard deletion.roomForCarried(record) else { return .keptBoth }
            if BackendProjectSecretFilesRules.verdict(value.path, bytes: bytes) != .travels {
                refuse(value, id: removal.recordId, why: BackendProjectSecretFilesWords.putBackPrograms)
            }
        }
        try deletion.remember(record)
        let undo = deletion.undo(for: record.recordId, group: intent.group)
        if let mark = try deletion.mark(record.recordId), mark.mark == .notOnThisMac, !deletion.isDeleted(record.recordId) {
            try deletion.keepHandMark(record.recordId)
        }
        let resolvedName = await deleteMacName(intent.mac)
        let actor = CloudDeleteActor(by: intent.by, mac: intent.mac, macName: resolvedName ?? "another device", session: intent.session,
            agent: intent.agent, at: intent.at, group: intent.group)
        let binnedAt = await deleteStamp()
        do { _ = try deletion.prepare(record, item: deleteItem(record), scope: intent.scope, actor: actor, travel: false, binnedAt: binnedAt) }
        catch { try? deletion.cancel(undo); throw error }
        if intent.scope == .everywhere, case .ok = root {
            // The sealed keeper copy exists; the file goes only if it is still exactly that version.
            let removed = (try? removeFile(record, projects: list)) ?? false
            guard removed else { try? deletion.cancel(undo); return .keptBoth }
        }
        try deletion.finish(removal, unplaced: unplaced)
        // Decision 1: the item leaves this Mac's list of known files, so a put back or a newer version arriving later is
        // placed like any arrival, never held as "Not on this Mac".
        if intent.scope == .everywhere { ledger.files[removal.recordId] = nil }
        ledger.waiting[removal.recordId] = nil; saveLedger()
        return .applied
    }
    public func verifyRemoval(_ removal: CloudSecretRemoval, outcome: CloudApplyStatus) async throws -> Bool {
        guard outcome == .applied else { return true }
        guard try deletion.mark(removal.recordId) != nil else { return false }
        guard removal.fields[CloudDeleteTravel.scope] != "cloud", let record = deletion.newest(removal.recordId) else { return true }
        let value = try decoded(record).0
        // No project folder here: nothing could be on disk, the sealed Bin entry and the mark are the result.
        guard case .ok(let root) = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: await projects()) else { return true }
        if case .absent = CloudFolderDisk.read(root, value.path) { return true }
        return false
    }
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        await enterDelete(); defer { leaveDelete() }
        try deletion.ready(); try requireWriter()
        // Decision 7: while an older Mac exists, neither "Everywhere" nor "Cloud" can be honoured for project secret files.
        guard await deleteGate() else { throw BackendCloudSecretsWaiting(reason: CloudDeleteWords.cloudNeedsUpdatedMacs) }
        let list = await projects()
        var done: [CloudDeleteItem] = []
        for item in items {
            guard item.kind == "project-secret-files", !deletion.isDeleted(item.id), let previous = deletion.newest(item.id) else { throw CloudFailure.invalidRequest }
            var record = previous
            let (value, _) = try decoded(previous)
            guard let keys else { throw CloudFailure.secretsLocked }
            let root = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: list, allowEmpty: true)
            if case .unusable(waiting: _, removal: let why) = root { throw BackendCloudSecretsWaiting(reason: why) }
            if case .ok(let folder) = root, case .file(let bytes) = CloudFolderDisk.read(folder, value.path) {
                // Delete exactly this Mac's current bytes, even when the last 10-minute look predates an edit.
                let current = BackendProjectSecretFileValue(v: 1, projectId: value.projectId, folder: value.folder, path: value.path,
                    mode: Self.modeOnDisk(folder, value.path), data: bytes.base64EncodedString(), mark: mark(keys, bytes),
                    base: value.mark == mark(keys, bytes) ? value.base : value.mark,
                    at: value.mark == mark(keys, bytes) ? value.at : actor.at, from: value.mark == mark(keys, bytes) ? value.from : actor.macName)
                record = try BackendCloudSecretsRecords.record(sourceId, item.id, domain, current)
            }
            try deletion.remember(record)
            let undo = deletion.undo(for: item.id, group: actor.group)
            let removal = try deletion.prepare(record, item: deleteItem(record), scope: scope, actor: actor, travel: true, binnedAt: await deleteStamp())
            // Its project folder not on this Mac: nothing to unlink here; the removal still travels.
            if scope == .everywhere, case .ok = root {
                let removed: Bool
                do { removed = try removeFile(record, projects: list) } catch { try? deletion.cancel(undo); throw CloudFailure.unavailable }
                guard removed else { try? deletion.cancel(undo); throw CloudFailure.versionChanged }
            }
            try deletion.finish(removal)
            if scope == .everywhere { ledger.files[item.id] = nil }
            ledger.waiting[item.id] = nil
            saveLedger()
            done.append(try deleteItem(record))
        }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: done)
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        try deletion.marks().compactMap { marked in
            guard !deletion.isDeleted(marked.place), let record = deletion.newest(marked.place) else { return nil }
            return .init(item: try deleteItem(record), mark: marked.mark, at: marked.at)
        }
    }
    /// Decision 5: a file comes out of this Mac's keeping only under the SAME rules as any arriving secret file (files
    /// that run programs never; the `.npmrc` line rule; the size and count caps). What fails stays sealed and is named.
    private func mayWrite(_ value: BackendProjectSecretFileValue, bytes: Data, id: String, projects: [Project]) -> Bool {
        guard bytes.count <= BackendProjectSecretFilesRules.fileBytes,
              BackendProjectSecretFilesRules.verdict(value.path, bytes: bytes) == .travels else {
            refuse(value, id: id, why: BackendProjectSecretFilesWords.putBackPrograms); return false
        }
        guard withinCaps(value, size: bytes.count, id: id, projects: projects) else {
            refuse(value, id: id, why: BackendProjectSecretFilesWords.putBackCaps); return false
        }
        return true
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        await enterDelete(); defer { leaveDelete() }
        guard let keys else { throw CloudFailure.secretsLocked }
        let list = await projects()
        var done: [CloudDeleteItem] = []
        for item in items {
            guard !deletion.isDeleted(item.id) else { throw CloudFailure.invalidRequest }
            guard let record = deletion.newest(item.id), let pair = try? decoded(record) else { continue }
            let (value, bytes) = pair
            if to == .thisMac {
                guard case .ok(let root) = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: list, allowEmpty: true) else { throw CloudFailure.unavailable }
                try requireWriter()
                switch CloudFolderDisk.read(root, value.path) {
                case .file(let local): guard local == bytes else { throw CloudFailure.versionChanged }
                case .blocked: throw CloudFailure.unsafeConfiguration
                case .absent:
                    guard mayWrite(value, bytes: bytes, id: item.id, projects: list) else { continue }
                    try Self.write(root, value.path, bytes: bytes, expecting: nil, at: value.at)
                }
                walks[root.path] = nil
                try deletion.restored(item.id, keepHandMark: false)
            } else {
                // Put in Cloud again captures THIS Mac's bytes on the next adapter snapshot, in the versioned form.
                guard case .ok(let root) = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: list, allowEmpty: true),
                      case .file = CloudFolderDisk.read(root, value.path) else { throw CloudFailure.unavailable }
                try deletion.restored(item.id, keepHandMark: false)
                try deletion.markDeliberate(item.id)
            }
            _ = place(value, bytes: bytes, id: item.id, keys: keys, projects: list, keep: false)
            done.append(try deleteItem(record))
        }
        return done
    }
    /// The Bin ages by the service clock only (`deleteStamp`), never by this Mac's wall clock.
    public func binGroups() async throws -> [CloudBinGroup] { try deletion.groups(now: await deleteStamp()) }
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        await enterDelete(); defer { leaveDelete() }
        guard let keys else { throw CloudFailure.secretsLocked }
        let list = await projects()
        var done: [CloudDeleteItem] = []
        for entry in try deletion.entries(now: await deleteStamp()).filter({ $0.actor.group == group }) {
            // An entry that cannot be read is skipped (decision 8); it never stops the rest.
            guard let pair = try? decoded(entry.record) else { continue }
            let (value, bytes) = pair
            guard case .ok(let root) = arrivalRoot(projectId: value.projectId, folder: value.folder, projects: list, allowEmpty: true) else { continue }
            try requireWriter()
            switch CloudFolderDisk.read(root, value.path) {
            case .file(let local): guard local == bytes else { continue }
            case .blocked: continue
            case .absent:
                guard mayWrite(value, bytes: bytes, id: entry.item.id, projects: list) else { continue }
                do { try Self.write(root, value.path, bytes: bytes, expecting: nil, at: value.at) } catch { continue }
            }
            walks[root.path] = nil
            try deletion.remember(entry.record)
            try deletion.restored(entry.item.id, keepHandMark: false)
            // Decision 1/6: his deliberate Put back travels in the versioned form and is written on his other computers.
            try deletion.markDeliberate(entry.item.id)
            try deletion.putBackDone(group: group, id: entry.item.id)
            _ = place(value, bytes: bytes, id: entry.item.id, keys: keys, projects: list, keep: false)
            done.append(entry.item)
        }
        return done
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        await enterDelete(); defer { leaveDelete() }
        try requireWriter(); try deletion.forgetBin(items)
    }

    // MARK: The walk

    /// `stays`: a secret file that never travels (named in the status as staying here); its bytes are not kept.
    struct Found: Equatable { let path: String; let data: Data; let mode: Int; let at: Int64; let size: Int; let stays: Bool }
    /// The secret files of one (real) project folder: no link followed, hidden and package folders skipped, as deep as a
    /// path may travel and 20,000 entries at most. Bytes are read only for files whose NAME is a candidate, and only up
    /// to the cap + 1. A temporary file a crash left behind (older than two minutes) is removed on the way.
    static func walk(_ root: URL, now: Int64) -> [Found] {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return [] }
        let base = root.standardizedFileURL.path
        var found: [Found] = [], seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > BackendProjectSecretFilesRules.walkEntries { break }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                let name = url.lastPathComponent
                // A file at most `depth + 1` names deep travels, so folders are opened down to `depth` levels.
                if name.hasPrefix(".") || CloudFolderRules.rebuildableFolders.contains(name.lowercased()) || walker.level > BackendProjectSecretFilesRules.depth {
                    walker.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let at = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
            if BackendProjectSecretFilesRules.isTemporary(url.lastPathComponent) {
                // Review 14 Nov (R4): a write sets the sender's date as the last-changed date, so age is the time the
                // file's details last changed (that moves to now at the write).
                let changed = Int64(info.st_ctimespec.tv_sec) * 1000 + Int64(info.st_ctimespec.tv_nsec) / 1_000_000
                if now - changed > BackendProjectSecretFilesRules.staleTemporaryMs { unlink(path) }
                continue
            }
            let byName = BackendProjectSecretFilesRules.verdict(relative, bytes: nil)
            guard byName != .never else { continue }
            let mode = Int(info.st_mode & 0o777), size = Int(info.st_size)
            if byName == .staysHere {
                found.append(.init(path: relative, data: Data(), mode: mode, at: at, size: size, stays: true)); continue
            }
            let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // An empty file reads as nil: nothing to carry.
            guard let read = try? handle.read(upToCount: BackendProjectSecretFilesRules.fileBytes + 1) else { continue }
            let bytes: Data = read
            // The bytes decide a .pem/.key/.asc (a private key heads the file, well inside what is read) and an .npmrc.
            switch BackendProjectSecretFilesRules.verdict(relative, bytes: bytes) {
            case .never: continue
            case .staysHere: found.append(.init(path: relative, data: Data(), mode: mode, at: at, size: size, stays: true))
            case .travels: found.append(.init(path: relative, data: bytes, mode: mode, at: at, size: max(size, bytes.count), stays: false))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func plainName(_ raw: String) -> String {
        let flat = raw.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? "another device" : String(flat.prefix(60))
    }

    // MARK: Status (names, sizes, dates, plain words)

    public func status() async -> BackendProjectSecretFilesStatus? {
        guard keys != nil else { return nil }
        let list = await projects()
        let keep = keepOnThisMac()
        let waitingWhy = BackendProjectSecretFilesWords.waiting(gateState)
        var status = BackendProjectSecretFilesStatus()
        status.keepOnThisMac = keep; status.waitingForMacs = gateState != .open; status.waitingWhy = keep ? nil : waitingWhy
        status.lookedAt = lookedAt; status.refusedArrivals = refusedCount; status.binNotice = deletion.notice
        let mine = Self.plainName(await deviceName())
        for project in list.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            var files: [BackendProjectSecretFilesStatus.File] = []
            for (id, entry) in ledger.files where entry.projectId == project.id {
                guard !deletion.isDeleted(id) else { continue }
                let state: String, travels: Bool
                if let localMark = try? deletion.mark(id) { state = localMark.mark.title; travels = false }
                else if let other = entry.differsFrom { state = BackendProjectSecretFilesWords.differs(other); travels = false }
                else if keep { state = BackendProjectSecretFilesWords.keptHere; travels = false }
                else if let waitingWhy { state = waitingWhy; travels = false }
                else if entry.arrivedAt != nil, entry.from != mine { state = BackendProjectSecretFilesWords.arrived(entry.from); travels = true }
                else { state = BackendProjectSecretFilesWords.travels; travels = true }
                files.append(.init(folder: entry.folder, path: entry.path, bytes: entry.bytes, at: entry.at, from: entry.from, state: state, travels: travels))
            }
            for waiting in ledger.waiting.values where waiting.projectId == project.id {
                files.append(.init(folder: "", path: waiting.path, bytes: 0, at: waiting.at, from: waiting.from, state: waiting.why, travels: false))
            }
            files += refused.values.filter { $0.projectId == project.id }.map { $0.file }
            files += heldBack[project.id] ?? []
            guard !files.isEmpty else { continue }
            status.projects.append(.init(id: project.id, name: project.name, files: files.sorted { $0.path < $1.path }))
        }
        return status
    }
}

/// The one live store, for the Code page, the Cloud page's switch and the read tool. Set by the app when saved
/// passwords are wired; cleared at sign-out.
public final class BackendProjectSecretFilesHolder: @unchecked Sendable {
    public static let shared = BackendProjectSecretFilesHolder()
    private let lock = NSLock()
    private var held: BackendProjectSecretFilesStore?
    private var root: URL?
    public init() {}
    public var store: BackendProjectSecretFilesStore? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    /// Where the stricter setting lives on this Mac (known even before saved passwords open).
    public var stateRoot: URL? {
        get { lock.withLock { root } }
        set { lock.withLock { root = newValue } }
    }
}
