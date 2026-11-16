import Foundation
import TerminalDeckNativeCore

/// The one Cloud status line in the main window (owner, 14 Nov: "everything arrives on any machine" and he must SEE
/// that it has without opening a page). It sits in the side panel's bottom bar, above his profile and the gear, with
/// one "Sync now". Exactly ONE state in plain words, made from what the account, the sync core and the Cloud page's
/// one summary (`BackendCloudOverview`) already report: never a guess, never an id or a code.
///
/// "Everything is on your other devices" is said only when the Cloud page's summary is "Up to date" (every kind that
/// travels is level with the Cloud, nothing is queued, held back or waiting) and no memory question waits. A part the
/// sync core has not confirmed yet is "Checking…", never "not complete" (the "Settings: Not complete" race, 14 Nov).
public struct BackendCloudStatusLine: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case level, sending, getting, checking, offline, signedOut, signingIn, needsYou, problem, paused, off
    }
    public let kind: Kind
    /// The words on screen, exactly.
    public let text: String
    /// What needs him, in a few words each (only for `needsYou`); the line names the first.
    public let needs: [String]
    /// "Sync now" is offered (signed in, online, Cloud on and not paused).
    public let canSyncNow: Bool
    /// When this Mac last saw everything level (the time said after "Everything is on your other devices").
    public let levelAt: Date?
    public let opensBin: Bool

    public init(kind: Kind, text: String, needs: [String] = [], canSyncNow: Bool = false, levelAt: Date? = nil, opensBin: Bool = false) {
        self.kind = kind
        self.text = text
        self.needs = needs
        self.canSyncNow = canSyncNow
        self.levelAt = levelAt
        self.opensBin = opensBin
    }

    /// The same state for `cloud.status`, so an AI reads exactly what he sees.
    public var wireValue: NativeRPCValue {
        .object([.init("state", .string(kind.rawValue)), .init("line", .string(text)),
                 .init("needsYou", .array(needs.map(NativeRPCValue.string))),
                 .init("canSyncNow", .bool(canSyncNow)),
                 .init("levelAt", levelAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null)])
    }
}

/// Everything the line is made from. All of it is already in hand on the Mac; nothing here asks the network.
public struct BackendCloudStatusLineInput: Sendable {
    public var snapshot: CloudAccountSnapshot
    /// A saved sign-in exists while Cloud cannot be reached ("reaching"): not signed out.
    public var savedSignIn: Bool
    /// The network path (`NWPathMonitor`): false = no internet at all.
    public var online: Bool
    /// The Cloud page's one summary (nil while Cloud is not open or nothing is switched on).
    public var overview: BackendCloudOverview?
    /// Memory's held removals / missing notes that wait for "They are gone" / "Keep them" (memory seat, 14 Nov).
    public var memoryAnswer: DeckMemoryAnswer?
    /// Lane L3 slice 1 (merge): the Cloud folder's own question ("They are gone" / "Keep them"), pointed to the same way,
    /// so the line never says "Everything is on your other devices" while it waits.
    public var folderAnswer: CloudFolderAnswer? = nil
    /// Lane L3 slice 2: the artifacts' question, pointed to the same way.
    public var artifactsAnswer: CloudFolderAnswer? = nil
    /// A "Sync now" pass is running.
    public var syncingNow: Bool
    /// The page's own first read of this Mac's progress is done (`NativeCloudAccount.progressRead`).
    public var progressRead: Bool
    public var levelAt: Date?
    /// Review fix 3: memory's waiting question has been read at least once since start-up. Until then the line never
    /// says "Everything is on your other devices".
    public var memoryChecked: Bool = true
    /// Manual status notice only; the wire reply never lists Bin contents.
    public var binGroups: [CloudBinGroup] = []
    /// Open files (15 Nov): files still going up to the shelf so his phones can open them (done of total; 0 of 0 = none).
    public var shelfFilesDone = 0
    public var shelfFilesTotal = 0
    public init(snapshot: CloudAccountSnapshot, savedSignIn: Bool = false, online: Bool = true, overview: BackendCloudOverview? = nil,
                memoryAnswer: DeckMemoryAnswer? = nil, syncingNow: Bool = false, progressRead: Bool = true, levelAt: Date? = nil) {
        self.snapshot = snapshot
        self.savedSignIn = savedSignIn
        self.online = online
        self.overview = overview
        self.memoryAnswer = memoryAnswer
        self.syncingNow = syncingNow
        self.progressRead = progressRead
        self.levelAt = levelAt
    }
}

public enum BackendCloudStatusLineWords {
    public static let levelWords = "Everything is on your other devices"
    /// Open files (15 Nov): the one line while files still go up for his phones; nothing when idle.
    public static func sendingFiles(_ done: Int, of total: Int) -> String {
        "Sending your files so your phones can open them: " + String(done) + " of " + String(total)
    }
    public static let signedOut = "Signed out"
    public static let signingIn = "Signing in…"
    public static let offline = "Waiting for the internet"
    public static let checking = "Checking…"
    public static let checkingNow = "Checking with your Cloud…"
    public static let firstCopy = "Sending this Mac's first copy…"
    public static let paused = "Paused on this Mac · Resume in Settings → Cloud"
    public static let off = "Cloud is off on this Mac"
    public static let dormant = "Cloud is not open for this account"
    public static let unreachable = "Can't reach your Cloud right now · Sync now tries again"
    public static let reaching = "Can't reach your Cloud right now · it tries again by itself"
    public static let refused = "Some changes were refused · Sync now tries again"
    /// Parked memory (14 Nov): changes this Mac could not save yet. Nothing was refused by the Cloud and nothing needs
    /// him: "2 changes could not be saved on this Mac yet · it tries again by itself".
    public static func notSavedHere(_ count: Int) -> String {
        (count == 1 ? "1 change" : BackendCloudPageCounts.number(count) + " changes") + " could not be saved on this Mac yet · it tries again by itself"
    }
    public static let syncNow = "Sync now"
    /// The short form in the window's toolbar while the side panel is hidden: the Cloud mark alone when everything is
    /// on his other devices, else the state in one or two words beside it.
    public static func short(_ kind: BackendCloudStatusLine.Kind) -> String? {
        switch kind {
        case .level: return nil
        case .sending: return "Sending…"
        case .getting: return "Getting…"
        case .checking: return "Checking…"
        case .signingIn: return "Signing in…"
        case .offline: return "Offline"
        case .signedOut: return "Signed out"
        case .needsYou: return "Needs you"
        case .problem: return "Can't sync"
        case .paused: return "Paused"
        case .off: return "Off"
        }
    }
    /// "Something needs you: a new device to allow" / "…: 3 notes missing here, and 1 more".
    public static func needsYou(_ needs: [String]) -> String {
        guard let first = needs.first else { return "Something needs you" }
        return "Something needs you: " + first + (needs.count > 1 ? ", and \(needs.count - 1) more" : "")
    }
    public static func sending(_ count: Int) -> String {
        count <= 0 ? "Sending changes…" : count == 1 ? "Sending 1 change…" : "Sending " + BackendCloudPageCounts.number(count) + " changes…"
    }
    public static func getting(_ count: Int?) -> String {
        guard let count, count > 0 else { return "Getting changes…" }
        return count == 1 ? "Getting 1 change…" : "Getting " + BackendCloudPageCounts.number(count) + " changes…"
    }
    /// "Everything is on your other devices · 16:22"; on another day "· 13 Nov 16:22"; no time while none is known.
    public static func level(_ at: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let at else { return levelWords }
        let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
        if calendar.isDate(at, inSameDayAs: now) { return levelWords + " · " + time }
        let day = at.formatted(Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated))
        return levelWords + " · " + day + " " + time
    }
    // Compatibility DTO readers are inert. Missing roots have quiet lines on their own page.
    public static func memory(_ answer: DeckMemoryAnswer) -> String? { nil }
    public static func folder(_ answer: CloudFolderAnswer) -> String? { nil }
    public static func artifacts(_ answer: CloudFolderAnswer) -> String? { nil }
    public static func removedTonight(_ groups: [CloudBinGroup], now: Date) -> String? {
        let time = Int64(now.timeIntervalSince1970 * 1000)
        let recent = BackendCloudDeletePage.merge(groups).filter {
            $0.by == .ai && $0.era == .current && $0.count > 20 && $0.at <= time && time - $0.at < 86_400_000
        }
        guard let latest = recent.first else { return nil }
        return BackendCloudPageCounts.number(latest.count) + " removed by an AI tonight · Bin"
    }
    public static let device = "a new device to allow"
    public static let passwordsRequest = "a device asks for saved passwords"
    public static let passwords = "saved passwords"
    public static let checkAgain = "changes to check again"
    public static let heldForOK = "changes wait for your OK"
    public static let other = "open Cloud to see"
}

public enum BackendCloudStatusLineBuilder {
    /// A coverage gap of one part (`memory:0`, `projects:1`, `bootFiles:0`): the sync core's own "not confirmed yet",
    /// which is never something he can do. Never "needs you" on the line.
    static func isGap(_ id: String) -> Bool { id.range(of: "^[A-Za-z]+:[0-9]+$", options: .regularExpression) != nil }
    /// A real, lasting refusal said in plain words by the page (`BackendCloudPageWords.plainFailure`).
    static func isRefusal(_ text: String) -> Bool {
        text.contains("refused by your Cloud") || text.contains("your Cloud refused")
    }
    /// Parked memory (14 Nov): the page's "N changes could not be saved on this Mac yet" is NOT a refusal (it said
    /// "Some changes were refused" on the MacBook all day). The count said there, or nil when the sentence is not there.
    static func notSavedHere(_ text: String) -> Int? {
        guard let range = text.range(of: "[0-9][0-9,.' ]* changes? could not be saved on this Mac", options: .regularExpression) else { return nil }
        let digits = text[range].prefix { !$0.isLetter }.filter(\.isNumber)
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }
    /// What one waiting entry of the Cloud page's summary is, in a few words; nil = not something he must do.
    static func need(_ item: BackendCloudOverview.Waiting) -> String? {
        if isGap(item.id) { return nil }
        if ["memory:missing", "memory:held", "cloudFolder:missing", "cloudFolder:held", "artifacts:missing", "artifacts:held"].contains(item.id) { return nil }
        if item.id == "choose-devices" || item.id.hasPrefix("device:") || item.id.hasPrefix("key:") { return BackendCloudStatusLineWords.device }
        if item.id.hasPrefix("passwords:approval:") { return BackendCloudStatusLineWords.passwordsRequest }
        if item.id.hasPrefix("passwords:") { return BackendCloudStatusLineWords.passwords }
        if item.id == "refused" { return BackendCloudStatusLineWords.checkAgain }
        if item.id.hasSuffix(":held") || item.id == "held-unlisted" { return BackendCloudStatusLineWords.heldForOK }
        return BackendCloudStatusLineWords.other
    }
    /// What needs him, distinct, in order: the memory question first, then the page's own waiting entries.
    public static func needs(_ input: BackendCloudStatusLineInput) -> [String] {
        var said: [String] = []
        for item in input.overview?.waiting ?? [] {
            if let need = need(item), !said.contains(need) { said.append(need) }
        }
        return said
    }

    public static func build(_ input: BackendCloudStatusLineInput, now: Date = Date(), calendar: Calendar = .current) -> BackendCloudStatusLine {
        let snapshot = input.snapshot
        typealias W = BackendCloudStatusLineWords
        switch snapshot.phase {
        case .signingIn: return .init(kind: .signingIn, text: W.signingIn)
        // Review fix 1: right after launch the account is not read yet while a sign-in is saved: "Checking…", never a
        // flash of "Signed out". "Signed out" only when no sign-in is saved at all.
        case .signedOut: return input.savedSignIn ? .init(kind: .checking, text: W.checking) : .init(kind: .signedOut, text: W.signedOut)
        case .needsSignIn:
            guard input.savedSignIn else { return .init(kind: .signedOut, text: W.signedOut) }
            if !input.online { return .init(kind: .offline, text: W.offline) }
            // Still being reached (no failure said yet): checking; a failure: can't reach.
            return snapshot.problem == nil ? .init(kind: .checking, text: W.checking) : .init(kind: .problem, text: W.reaching)
        case .dormant: return .init(kind: .problem, text: W.dormant)
        case .paused: return .init(kind: .paused, text: W.paused)
        case .signedIn: break
        }
        if let overview = input.overview, overview.notUsedHere, overview.rows.isEmpty { return .init(kind: .off, text: W.off) }
        let canSync = input.online
        // 1. What only he can do (never hidden behind a network state: it is all on this Mac).
        let needs = needs(input)
        if !needs.isEmpty { return .init(kind: .needsYou, text: W.needsYou(needs), needs: needs, canSyncNow: canSync) }
        // 2. No internet at all.
        if !input.online { return .init(kind: .offline, text: W.offline) }
        // 3. The service cannot be reached, or refused changes for good.
        if snapshot.problem != nil { return .init(kind: .problem, text: W.unreachable, canSyncNow: true) }
        let refusals = (input.overview?.waiting.map(\.text) ?? []) + (input.overview?.rows.flatMap(\.notes) ?? [])
        if refusals.contains(where: isRefusal) { return .init(kind: .problem, text: W.refused, canSyncNow: true) }
        // A quiet notice, never "needs you". The page says it once per part that waits (one waiting entry each): their
        // counts add up; a row note alone (no waiting entry) gives its own count.
        let notSavedWaiting = (input.overview?.waiting.map(\.text) ?? []).compactMap(notSavedHere).reduce(0, +)
        let notSaved = notSavedWaiting > 0 ? notSavedWaiting : ((input.overview?.rows.flatMap(\.notes) ?? []).compactMap(notSavedHere).max() ?? 0)
        if notSaved > 0 { return .init(kind: .checking, text: W.notSavedHere(notSaved), canSyncNow: true) }
        // 4. Moving: this Mac's own changes first, then what the Cloud holds for it.
        if input.progressRead {
            if snapshot.baseline != nil { return .init(kind: .sending, text: W.firstCopy, canSyncNow: true) }
            if snapshot.waitingRecords > 0 || (snapshot.blockedRecords > 0) {
                return .init(kind: .sending, text: W.sending(snapshot.waitingRecords), canSyncNow: true)
            }
            if snapshot.catchingUp == true { return .init(kind: .getting, text: W.getting(snapshot.behindBy), canSyncNow: true) }
        }
        if let standing = input.overview?.standing, [.catchingUp, .savingAndCatchingUp].contains(standing) {
            return .init(kind: .getting, text: W.getting(snapshot.behindBy), canSyncNow: true)
        }
        // 5. A pass he asked for, with nothing moving that has a number yet.
        if input.syncingNow { return .init(kind: .checking, text: W.checkingNow, canSyncNow: true) }
        // 6. Level: the Cloud page's own "Up to date" (every kind complete, nothing queued, held or waiting), and the
        // memory question read since start-up.
        if let notice = W.removedTonight(input.binGroups, now: now) {
            return .init(kind: .level, text: notice, canSyncNow: true, levelAt: input.levelAt, opensBin: true)
        }
        if input.overview?.standing == .upToDate, input.memoryChecked {
            if input.shelfFilesTotal > input.shelfFilesDone {
                return .init(kind: .level, text: W.sendingFiles(input.shelfFilesDone, of: input.shelfFilesTotal), canSyncNow: true, levelAt: input.levelAt)
            }
            return .init(kind: .level, text: W.level(input.levelAt, now: now, calendar: calendar), canSyncNow: true, levelAt: input.levelAt)
        }
        // 7. Anything not confirmed yet: "Checking…", never "not complete".
        return .init(kind: .checking, text: W.checking, canSyncNow: true)
    }
}

/// "Sync now" pressed twice (or by him and by a tool at once) is ONE pass: a press while a pass runs waits for that
/// same pass and starts nothing.
public actor BackendCloudSyncNowGate {
    private var running: Task<Void, Error>?
    /// How many passes were really started (tests).
    public private(set) var passes = 0
    /// How many presses joined a pass already running (tests).
    public private(set) var joined = 0
    public init() {}
    public var isRunning: Bool { running != nil }
    public func run(_ pass: @escaping @Sendable () async throws -> Void) async throws {
        if let running { joined += 1; return try await running.value }
        passes += 1
        let task = Task { try await pass() }
        running = task
        defer { running = nil }
        try await task.value
    }
}

/// Space used per kind (owner, 14 Nov: plain numbers, no chart): the sizes the sync core already records for each part
/// it carries (`CloudCoverage.bytes`), added up per kind of the Cloud page. A kind with nothing is not listed. The
/// account's room left is the service's own answer (`/state` budget `bytesLeft`); nil until it has answered.
public struct BackendCloudSpace: Sendable, Equatable {
    public struct Part: Sendable, Equatable, Identifiable {
        public let kind: BackendCloudOverview.Kind
        public let title: String
        public let bytes: Int64
        public var id: String { kind.rawValue }
        public init(kind: BackendCloudOverview.Kind, title: String, bytes: Int64) { self.kind = kind; self.title = title; self.bytes = bytes }
    }
    public let parts: [Part]
    public let bytesLeft: Int64?
    public init(parts: [Part], bytesLeft: Int64?) { self.parts = parts; self.bytesLeft = bytesLeft }
    public var total: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    /// The account's limit: what is used plus what is left, as the service counts it. nil until the service answered.
    public var limit: Int64? { bytesLeft.map { $0 + total } }

    public static let title = "Space used"
    public static func name(_ kind: BackendCloudOverview.Kind) -> String {
        kind == .bootFiles ? "Instruction files" : BackendCloudOverviewWords.title(kind)
    }
    /// The ONE source: this Mac's coverage of every part it carries, grouped by the Cloud page's kinds.
    public static func make(_ snapshot: CloudAccountSnapshot, bytesLeft: Int64?) -> BackendCloudSpace {
        let parts: [Part] = BackendCloudOverview.Kind.allCases.compactMap { kind in
            let rows = BackendCloudOverviewBuilder.inventory(kind)
            guard !rows.isEmpty else { return nil }
            let bytes = snapshot.coverage.filter { rows.contains($0.inventoryRow) }.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
            return bytes > 0 ? Part(kind: kind, title: name(kind), bytes: bytes) : nil
        }
        return BackendCloudSpace(parts: parts, bytesLeft: bytesLeft)
    }
    /// "120 MB", "2 KB", "1.2 GB".
    public static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
    /// "Memory 120 MB · Instruction files 2 MB · Settings 40 KB". nil when nothing is known.
    public var line: String? {
        parts.isEmpty ? nil : parts.map { $0.title + " " + Self.size($0.bytes) }.joined(separator: " · ")
    }
    /// "Total 122 MB of 10 GB", or "Total 122 MB" until the service has said its limit.
    public var totalLine: String {
        "Total " + Self.size(total) + (limit.map { " of " + Self.size($0) } ?? "")
    }
    public var wireValue: NativeRPCValue {
        .object([.init("kinds", .array(parts.map { part in
                    .object([.init("kind", .string(part.title)), .init("bytes", .number(Double(part.bytes))), .init("size", .string(Self.size(part.bytes)))])
                 })),
                 .init("totalBytes", .number(Double(total))), .init("total", .string(Self.size(total))),
                 .init("limitBytes", limit.map { .number(Double($0)) } ?? .null),
                 .init("limit", limit.map { .string(Self.size($0)) } ?? .null),
                 .init("line", line.map(NativeRPCValue.string) ?? .null), .init("totalLine", .string(totalLine))])
    }
}
