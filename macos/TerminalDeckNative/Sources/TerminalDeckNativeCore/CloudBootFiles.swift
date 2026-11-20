import Foundation

/// Lean first version, item 8 (inventory row I09): the small text files an AI session boots from.
/// Pure rules only; nothing here opens a file. The same rules are used when this Mac reads its own folders, when a
/// record arrives, and again at the moment a file is written. In plain words: `macos/night/codex/cloud-files-scope.md`.
public enum CloudBootFilesFormat {
    public static let inventoryRow = "I09"
    /// The file engine's own lower-case name for this row. Nothing else sends or admits records under it.
    public static var domain: String { CloudBrainFilesFormat.domain(inventoryRow) }
    /// One boot file is at most this large. A larger one stays on its Mac and is named in coverage.
    public static let maximumFileBytes = 1_048_576
    public static let maximumFilesPerPlace = 2_000
    public static let maximumFolderDepth = 12
    public static let maximumPathBytes = 512
    /// A project has ONE folder per Mac in this version; every record of a project names it so.
    public static let projectRoot = "primary"
}

/// Where boot files live: a project's folder, or the settings folder ("home") of one AI account.
public enum CloudBootFilesPlaceKind: String, Codable, Sendable, CaseIterable {
    case project, claude, codex, gemini, agents
}

/// Why a path is not a boot file. Each is a refusal for a record and an exclusion (or a gap) for a local file.
public enum CloudBootFilesRefusal: String, Codable, Sendable, CaseIterable {
    case path
    case notListed = "not-listed"
    case hidden
    case never
    case rebuildable
    public var sentence: String {
        switch self {
        case .path: return "Refused: the file's path is not one plain path inside its folder."
        case .notListed: return "Refused: not a boot file. Only instruction files, agents, skills and commands travel."
        case .hidden: return "Refused: hidden files never travel."
        case .never: return "Refused: this file belongs to one Mac only, or is a sign-in or key file; it never travels."
        case .rebuildable: return "Refused: installed packages are not boot files."
        }
    }
}

/// What to do with one path, decided from three fingerprints only.
public enum CloudBootFilesStep: String, Sendable, Equatable {
    /// The folder and this Mac's Cloud copy agree.
    case nothing
    /// A new or edited local file: it becomes this Mac's newest version.
    case captureLocal
    /// The file was removed here: recorded as removed (other Macs list it; they never remove it).
    case captureRemoval
    /// A version from Cloud over nothing, or over the very bytes this Mac last saw: written.
    case write
    /// The same, but the file can run a command or grant tools: listed, written only when the person accepts it here.
    case needsAccept
    /// The local file was removed here and a version arrived: it stays removed; the arrived version is kept and
    /// listed. Removals are not part of the one rule's first slice (14 Nov), so this stays as it was.
    case keepBoth
    /// The one rule (owner, 14 Nov): both changed, this Mac's version is newer. It is recorded as the newest version
    /// and travels; the arrived one is kept 30 days on this Mac.
    case useLocal
    /// The one rule: both changed, the arrived version is newer. It is written over this Mac's file (only if the file
    /// still holds the bytes just read); this Mac's version is kept 30 days and one line says so.
    case useArrived
}

/// Which of two versions of one file is used everywhere.
public enum CloudBootFilesNewest: String, Sendable, Equatable { case local, arrived }

/// One version's place in time, for the one rule. `at` is the version's own stamp: for a version another device made, the
/// time that travelled with it; for this Mac's file not yet recorded, its modification time.
public struct CloudBootFilesVersionTime: Sendable, Equatable {
    public let at: Int64
    /// Device id of the Mac that made it. Only breaks an exact tie.
    public let device: String
    /// Rule J: the first saved copy of a Mac that never held this file's Cloud history (no parent version). It loses
    /// to a version that is part of that history, so a joining or rebuilt Mac never overwrites the account.
    public let firstCopy: Bool
    public init(at: Int64, device: String, firstCopy: Bool = false) { self.at = at; self.device = device; self.firstCopy = firstCopy }
}

public enum CloudBootFilesRules {
    // MARK: The list

    /// Files at the top of the place, by exact name.
    public static func files(_ kind: CloudBootFilesPlaceKind) -> [String] {
        switch kind {
        case .project: return ["CLAUDE.md", "AGENTS.md", "GEMINI.md"]
        case .claude: return ["CLAUDE.md"]
        case .codex: return ["AGENTS.md"]
        case .gemini: return ["GEMINI.md"]
        case .agents: return []
        }
    }
    /// Folders of the place whose text files travel, by exact path.
    public static func folders(_ kind: CloudBootFilesPlaceKind) -> [String] {
        switch kind {
        // Setup travels (Asad, 19 Nov: "the guard should be traveling"): the hooks, rules and each AI's agents too, and
        // the whole shared `.agents` folder (Codex and Gemini read skills from `.agents/skills`).
        case .project: return [".claude/agents", ".claude/skills", ".claude/commands", ".claude/hooks", ".claude/rules", ".agents",
                               ".codex/agents", ".codex/skills", ".gemini/agents", ".gemini/commands", ".gemini/hooks", ".gemini/skills"]
        case .claude: return ["agents", "skills", "commands"]
        case .codex, .gemini, .agents: return ["skills"]
        }
    }
    /// Setup files of the place by exact path: each AI's project settings (where its hooks, the guards, live) and the
    /// project's Codex configuration. They travel like any boot file; one that holds a password or key stays on its Mac
    /// (`setupHoldsSecret`, asked on the sending Mac and again at the moment of writing).
    public static func setupFiles(_ kind: CloudBootFilesPlaceKind) -> [String] {
        kind == .project ? [".claude/settings.json", ".codex/hooks.json", ".codex/config.toml", ".gemini/settings.json"] : []
    }
    /// Paths whose content is checked for secrets before they travel: the setup files and everything under the hook folders
    /// and the Codex folder (scripts and settings, where a key is most likely to be written).
    public static func secretChecked(kind: CloudBootFilesPlaceKind, relative: String) -> Bool {
        guard kind == .project else { return false }
        if setupFiles(kind).contains(where: { same($0, relative) }) { return true }
        return [".claude/hooks/", ".claude/rules/", ".codex/", ".gemini/hooks/", ".gemini/commands/"].contains { relative.hasPrefix($0) }
    }
    /// The same list as patterns, for the file engine's own check of a record's path.
    public static func patterns(_ kind: CloudBootFilesPlaceKind) -> [String] { files(kind) + setupFiles(kind) + folders(kind).map { $0 + "/**" } }

    /// Settings, hooks, MCP, permissions and sign-in files, by name (letter case ignored), also inside a listed folder.
    public static let neverFileNames: Set<String> = [
        "settings.json", "settings.local.json", "managed-settings.json", "hooks.json", "mcp.json", "mcp_config.json", "mcp-config.json",
        "config.toml", "permissions.json", "auth.json", "credentials.json", "oauth_creds.json", "google_accounts.json",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"
    ]
    /// Key material, environment files, and the running-state files lane A's engine leaves out of every file row.
    public static let neverFileEndings = [".pem", ".key", ".p12", ".pfx", ".p8", ".jks", ".keystore", ".ppk", ".keychain", ".keychain-db", ".env",
                                          ".lock", ".pid", ".sock", ".socket"]
    /// Parts of a name that mark a secret (security review S1): `token.json`, `secrets.yaml`, `apikey.txt`,
    /// `service-account-x.json`, `my-password.md`, `prod.env.local`. A harmless file with such a name stays on its
    /// Mac and is named among the exclusions: over-matching is the safe direction.
    public static let neverNameParts = ["credential", "secret", "token", "apikey", "api_key", "api-key", "service-account", "service_account",
                                        "password", "passwd", "private_key", "private-key", ".env."]
    /// Name beginnings of SSH and similar keys: `id_rsa`, `id_ed25519.pub`, `id_anything`.
    public static let neverNamePrefixes = ["id_"]
    public static let neverFolderNames: Set<String> = ["hooks"]
    public static let rebuildableFolderNames: Set<String> = ["node_modules", "__pycache__", "venv"]

    /// What is left out on purpose, named. Shown with coverage; never a gap.
    public static let exclusions = [
        "Each AI's project settings and guards travel; a settings or guard file that holds a password or key stays on this Mac. MCP servers travel with your saved passwords.",
        "Files named for one Mac only (\"local\" in the name) stay on that Mac.",
        "Sign-in and credential files never travel.",
        "The AI's own memory and conversation folders are not boot files.",
        "Hidden files, links and anything that is not text stay on this Mac.",
        "Files larger than 1 MB stay on this Mac."
    ]

    // MARK: Paths

    static func same(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }

    /// The parts of a path, split at every slash BYTE. nil when a mark attached to a slash would give the same text
    /// two readings (Swift compares whole characters; the disk compares bytes).
    public static func parts(_ path: String) -> [String]? {
        let byBytes = path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard byBytes.count == path.split(separator: "/", omittingEmptySubsequences: false).count else { return nil }
        return byBytes
    }

    private static func plain(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x20 || (0x7f...0x9f).contains(value) || scalar == "\\" { return false }
        // Invisible and direction characters: a name must read the way it is spelled.
        if (0x200b...0x200f).contains(value) || (0x202a...0x202e).contains(value) || (0x2060...0x2069).contains(value) || value == 0xfeff { return false }
        return true
    }

    /// One plain spelling of a path below a folder: no way up or out, no second spelling of the same name.
    public static func cleanRelative(_ relative: String) -> Bool {
        guard !relative.isEmpty, relative.utf8.count <= CloudBootFilesFormat.maximumPathBytes, relative.unicodeScalars.allSatisfy(plain) else { return false }
        // Accented letters in the composed form only. Compared as bytes: Swift's == calls both forms equal.
        guard same(relative, relative.precomposedStringWithCanonicalMapping), let pieces = parts(relative) else { return false }
        return pieces.allSatisfy { !$0.isEmpty && !same($0, ".") && !same($0, "..") && $0.utf8.count <= 255 }
    }

    /// The app's one never-send list by file name (keys, environment, sign-in and settings files), for every kind of
    /// file that travels (lane L3: the Cloud folder uses it too). Letter case ignored.
    public static func neverTravels(_ name: String) -> Bool { neverFile(name.lowercased()) }
    static func neverFile(_ lowerName: String) -> Bool {
        if neverFileNames.contains(lowerName) || neverFileEndings.contains(where: { lowerName.hasSuffix($0) }) { return true }
        return neverNameParts.contains(where: { lowerName.contains($0) }) || neverNamePrefixes.contains(where: { lowerName.hasPrefix($0) })
    }

    /// nil when `relative` is a boot file of this kind of place. Letter case counts for the listed names
    /// (`.Claude/skills` is not `.claude/skills`); it is ignored for the names that never travel.
    public static func refusal(kind: CloudBootFilesPlaceKind, relative: String) -> CloudBootFilesRefusal? {
        guard cleanRelative(relative), let pieces = parts(relative) else { return .path }
        // One Mac's own files by name (`settings.local.json`, `CLAUDE.local.md`, `x.local`): never travel.
        if let last = pieces.last?.lowercased(), last.contains(".local.") || last.hasSuffix(".local") { return .never }
        if pieces.count == 1, files(kind).contains(where: { same($0, pieces[0]) }) { return nil }
        if setupFiles(kind).contains(where: { same($0, relative) }) { return nil }
        var below: [String]?
        for folder in folders(kind) {
            let lead = folder.split(separator: "/").map(String.init)
            if pieces.count > lead.count, zip(lead, pieces).allSatisfy({ same($0, $1) }) { below = Array(pieces.dropFirst(lead.count)); break }
        }
        guard let rest = below else { return .notListed }
        for (offset, name) in rest.enumerated() {
            if name.utf8.first == UInt8(ascii: ".") { return .hidden }
            let lower = name.lowercased()
            if offset < rest.count - 1 {
                if neverFolderNames.contains(lower) { return .never }
                if rebuildableFolderNames.contains(lower) { return .rebuildable }
            } else if neverFile(lower) { return .never }
        }
        return nil
    }

    /// Text: valid UTF-8 with no zero byte.
    public static func isText(_ bytes: Data) -> Bool { !bytes.contains(0) && String(data: bytes, encoding: .utf8) != nil }

    // MARK: The decision

    /// `local` = the file in the folder, `copy` = this Mac's copy of the Cloud's newest version, `base` = the bytes
    /// both last agreed on (nil = never, or the file did not exist). Fingerprints only; nil = no file.
    /// The caller passes `local == nil` only when it SAW that the file is absent (never for "could not read").
    /// `newest`: when both changed, which one the one rule picks (`newest(local:arrived:now:)`); nil when the
    /// times could not be read, and then both are kept as before. `runs`/`accepted` apply to whatever would be written.
    public static func step(local: String?, copy: String?, base: String?, runs: Bool, accepted: Bool,
                            newest: CloudBootFilesNewest? = nil) -> CloudBootFilesStep {
        if local == copy { return .nothing }
        // Nothing arrived since both last agreed: whatever differs is this Mac's own change.
        guard let copy else { return .captureLocal }
        if copy == base { return local == nil ? .captureRemoval : .captureLocal }
        // A version arrived. It may replace only what this Mac last saw (or nothing at all).
        if local == base { return runs && !accepted ? .needsAccept : .write }
        // Both changed. A removal here is left as it was (not in this slice).
        guard local != nil, let newest else { return .keepBoth }
        if newest == .local { return .useLocal }
        // A file that can run a command waits for the person only under "Ask me for each new device" (`accepted`).
        return runs && !accepted ? .needsAccept : .useArrived
    }

    // MARK: The one rule (owner, 14 Nov): the newest change is used on every device

    /// How long the older version is kept on each device.
    public static let keptFor: Int64 = 30 * 24 * 3_600_000

    /// A file's time when its version is MADE, never later than now and never earlier than the version it was made on
    /// top of (that one capped at now too, so a parent stamped in the future by a wrong clock is not inherited). So a
    /// wrong clock cannot win by being ahead, and an edit made offline at 10:00 does not beat an 11:00 edit because its
    /// Mac reconnected later (the time is when the file was changed, not when it was sent).
    public static func clamp(_ at: Int64, agreedAt: Int64?, now: Int64) -> Int64 {
        max(min(at, now), min(agreedAt ?? at, now))
    }

    /// The one rule for two versions of one file that were made apart (neither on top of the other). Rule J first:
    /// a first saved copy loses to a version with history. Then the later time wins; an exact tie goes to the larger
    /// device id, then to `arrived` (every Mac decides the same way, since both see the same two pairs).
    /// Each time is the version's own stamp, already bounded below when it was made (`clamp`); here it is only capped
    /// at now. The agreed version's time is NOT applied again here: a parent with a future stamp would otherwise raise
    /// both to "now" and leave every clash to the device order.
    public static func newest(local: CloudBootFilesVersionTime, arrived: CloudBootFilesVersionTime, now: Int64) -> CloudBootFilesNewest {
        if local.firstCopy != arrived.firstCopy { return local.firstCopy ? .arrived : .local }
        let mine = min(local.at, now), theirs = min(arrived.at, now)
        if mine != theirs { return mine > theirs ? .local : .arrived }
        return local.device.lowercased() > arrived.device.lowercased() ? .local : .arrived
    }
}
