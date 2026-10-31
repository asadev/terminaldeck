import Foundation
import Observation
import TerminalDeckNativeCore

// SRV2 owns the screens for SRV1's server duties. Shared plumbing first (used
// by the server page and the per-app sections), then the server-level model.

typealias NativeAppsSRV2Transport = @MainActor (String, [String: Any]) async throws -> NativeRPCValue

enum NativeAppsSRV2Engine {
    /// How long any Apps screen waits for the server before giving up.
    static let timeout: TimeInterval = 120

    /// The one engine path for every Apps screen; writes meet the approval gate there.
    @MainActor static func invoke(_ channel: String, _ payload: [String: Any]) async throws -> NativeRPCValue {
        let answer = try await EngineBridge.shared.invoke(channel, [payload], timeout: timeout)
        return try NativeRPCValue.fromFoundation(answer)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: NativeRPCValue, what: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: value.encodedJSON()) }
        catch { throw NativeRPCError.malformed("The server returned \(what) in an unexpected form.") }
    }

    /// The server duties' own plain sentences are shown as written (they are
    /// fixed text in Terminal Deck, never server output); anything else uses the
    /// Apps screen's known safe copy.
    static func problem(_ error: Error) -> String {
        if let rpc = error as? NativeRPCError,
           ["invalid-arguments", "unavailable", "not-installed", "confirmation-required", "conflict", "not-found", "busy"].contains(rpc.code),
           !rpc.message.isEmpty, rpc.message.count <= 300, !rpc.message.contains(where: \.isNewline) {
            return rpc.message
        }
        return NativeAppsContract.problem(error)
    }

    static func notInstalled(_ error: Error) -> Bool { (error as? NativeRPCError)?.code == "not-installed" }

    static func date(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    /// systemd's "Sun 2026-10-11 04:00:00 UTC", kept on the server's clock (as
    /// schedules are) and written plainly: "Sun 11 Oct, 04:00 UTC".
    static func systemdDate(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count >= 3, parts[1].count == 10, parts[2].count == 8 else { return text }
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(identifier: "UTC")
        reader.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = reader.date(from: parts[1] + " " + parts[2]) else { return text }
        let writer = DateFormatter()
        writer.locale = Locale(identifier: "en_GB")
        writer.timeZone = TimeZone(identifier: "UTC")
        writer.dateFormat = "EEE d MMM, HH:mm"
        return writer.string(from: date) + (parts.count > 3 ? " " + parts[3] : "")
    }

    static func bytes(_ count: Double?) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, count ?? 0)), countStyle: .file)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
}

/// A systemd calendar schedule in plain words, with simple presets.
struct NativeAppsSRV2Schedule: Equatable {
    enum Preset: String, CaseIterable, Identifiable { case hourly, daily, weekly, custom; var id: String { rawValue } }
    static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var preset: Preset
    var time: String
    var day: String
    var custom: String
    /// The saved text a preset was read from ("daily" is "*-*-* 00:00:00"), given back by
    /// `calendar` while the choice is untouched, so a short form never reads as an edit.
    private var savedText: String?
    private var savedChoice: [String]?
    private var choice: [String] { [preset.rawValue, time, day] }

    init(preset: Preset = .daily, time: String = "03:00", day: String = "Sun", custom: String = "") {
        self.preset = preset; self.time = time; self.day = day; self.custom = custom
    }

    init(calendar: String) {
        let text = calendar.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ").map(String.init)
        func clock(_ value: String) -> String? {
            let pieces = value.split(separator: ":").map(String.init)
            guard pieces.count >= 2, pieces.count <= 3, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
                  (0...23).contains(hour), (0...59).contains(minute), pieces.count == 2 || pieces[2] == "00" else { return nil }
            return String(format: "%02d:%02d", hour, minute)
        }
        switch parts.count {
        case 1 where text == "hourly": self.init(preset: .hourly)
        case 1 where text == "daily": self.init(preset: .daily, time: "00:00")
        case 1 where text == "weekly": self.init(preset: .weekly, time: "00:00", day: "Mon")
        case 2 where parts[0] == "*-*-*" && clock(parts[1]) != nil: self.init(preset: .daily, time: clock(parts[1])!)
        case 3 where Self.days.contains(parts[0]) && parts[1] == "*-*-*" && clock(parts[2]) != nil:
            self.init(preset: .weekly, time: clock(parts[2])!, day: parts[0])
        default: self.init(preset: .custom, custom: text)
        }
        if preset != .custom { savedText = text; savedChoice = choice }
    }

    var validTime: Bool { NativeAppsSRV2Engine.matches(time, #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#) }

    /// The systemd calendar text, or nil while it isn't valid yet.
    var calendar: String? {
        if preset != .custom, let savedText, savedChoice == choice { return savedText }
        switch preset {
        case .hourly: return "hourly"
        case .daily: return validTime ? "*-*-* \(time):00" : nil
        case .weekly: return validTime && Self.days.contains(day) ? "\(day) *-*-* \(time):00" : nil
        case .custom:
            let text = custom.trimmingCharacters(in: .whitespaces)
            return NativeAppsSRV2Engine.matches(text, #"\A[A-Za-z0-9 *:,./~+-]{1,128}\z"#) ? text : nil
        }
    }

    var problem: String? {
        guard calendar == nil else { return nil }
        if preset == .custom { return "Use a schedule such as daily, hourly, \"Mon *-*-* 03:00:00\" or \"*-*-* 02:30:00\"." }
        return "Enter a time from 00:00 to 23:59."
    }

    static func words(_ calendar: String) -> String {
        let schedule = NativeAppsSRV2Schedule(calendar: calendar)
        switch schedule.preset {
        case .hourly: return "Every hour"
        case .daily: return "Every day at \(schedule.time)"
        case .weekly: return "Every \(dayNames[days.firstIndex(of: schedule.day) ?? 6]) at \(schedule.time)"
        case .custom: return "Custom schedule: \(calendar)"
        }
    }
}

/// The server's Apps duties: setup, keeping addresses after a restart, alerts,
/// and cleanup. One instance per server page; every read is one SSH call made
/// by the engine, and the server keeps working with this Mac off.
@MainActor
@Observable
final class NativeAppsSRV2ServerModel {
    enum Part: String, Sendable { case setup, persist, alerts, test, cleanup, preview, remove }

    struct Status: Decodable, Equatable {
        struct Duties: Decodable, Equatable { var watch: String?; var checks: String?; var cleanup: String?; var endpoint: String?; var hooksHost: String? }
        var hostname: String?
        var administrator: Bool?
        var supported: Bool?
        var docker: String?
        var installedVersion: String?
        var helperVersion: String?
        var router: String?
        var routerSummary: String?
        var publicIPv4: String?
        var diskPercent: Double?
        var memoryMB: Double?
        var duties: Duties?
        var installed: Bool { installedVersion?.isEmpty == false }
        var needsUpdate: Bool { installed && helperVersion != nil && installedVersion != helperVersion }
    }

    struct Plan: Decodable, Equatable {
        struct Step: Decodable, Equatable, Identifiable { var title: String; var detail: String; var id: String { title } }
        var steps: [Step]?
        var blockedReason: String?
        var routerSummary: String?
        var version: String?
        var upgrade: Bool?
        var removable: String?
    }

    enum ChannelKind: String, CaseIterable, Identifiable, Sendable {
        case telegram, email, webhook, receiver
        var id: String { rawValue }
        var title: String {
            switch self {
            case .telegram: "Telegram bot"
            case .email: "Email"
            case .webhook: "Webhook"
            case .receiver: "Receiver"
            }
        }
        var symbol: String {
            switch self {
            case .telegram: "paperplane"
            case .email: "envelope"
            case .webhook: "link"
            case .receiver: "antenna.radiowaves.left.and.right"
            }
        }
        var secretKey: String {
            switch self {
            case .telegram: "botToken"
            case .email: "password"
            case .webhook: "secret"
            case .receiver: "token"
            }
        }
    }

    /// One alert channel as edited. `secret` is only a newly typed value; a
    /// saved one stays on the server and is never read back.
    struct AlertChannel: Identifiable, Equatable {
        let uid = UUID()
        var name: String
        var kind: ChannelKind
        var enabled = true
        /// Saved on the server: its name can't change (saved secrets follow the name).
        var saved = false
        var hasSecret = false
        var secret = ""
        var chatId = ""
        var smtpUrl = ""
        var username = ""
        var from = ""
        var to = ""
        var url = ""
        var id: UUID { uid }
    }

    struct Alerts: Equatable {
        var enabled = true
        var channels: [AlertChannel] = []
        var diskPercent = 85
        var memoryPressure = 20
        var certDays = 14
        var remindMinutes = 1440
        var watch = ""
    }

    struct AlertEntry: Identifiable, Equatable {
        var id: Int
        var severity: String
        var title: String
        var message: String
        var app: String?
        var at: String?
        var delivered: [(id: String, ok: Bool)]
        static func == (a: AlertEntry, b: AlertEntry) -> Bool { a.id == b.id && a.title == b.title && a.at == b.at }
    }

    struct Cleanup: Decodable, Equatable {
        var enabled: Bool
        var schedule: String
        var removeOldVersions: Bool
        var keepVersions: Int
        var buildCache: Bool
        var unnamedStorage: Bool
        init(enabled: Bool = true, schedule: String = "Sun *-*-* 04:00:00", removeOldVersions: Bool = false, keepVersions: Int = 3,
             buildCache: Bool = false, unnamedStorage: Bool = false) {
            self.enabled = enabled; self.schedule = schedule; self.removeOldVersions = removeOldVersions
            self.keepVersions = keepVersions; self.buildCache = buildCache; self.unnamedStorage = unnamedStorage
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? "Sun *-*-* 04:00:00"
            removeOldVersions = try c.decodeIfPresent(Bool.self, forKey: .removeOldVersions) ?? false
            keepVersions = Int(try c.decodeIfPresent(Double.self, forKey: .keepVersions) ?? 3)
            buildCache = try c.decodeIfPresent(Bool.self, forKey: .buildCache) ?? false
            unnamedStorage = try c.decodeIfPresent(Bool.self, forKey: .unnamedStorage) ?? false
        }
        private enum CodingKeys: String, CodingKey { case enabled, schedule, removeOldVersions, keepVersions, buildCache, unnamedStorage }
    }

    struct CleanupResult: Decodable, Equatable {
        struct Item: Decodable, Equatable, Identifiable {
            var kind: String?
            var id: String?
            var app: String?
            var reason: String?
            var result: String?
            var bytes: Double?
            var identity: String { (kind ?? "") + ":" + (id ?? "") }
        }
        var dryRun: Bool?
        var finishedAt: Double?
        var freedBytes: Double?
        var items: [Item]?
    }

    private struct CleanupRead: Decodable { var settings: Cleanup?; var last: CleanupResult?; var nextRun: String? }

    let serverID: String
    let serverName: String

    private(set) var status: Status?
    private(set) var plan: Plan?
    private(set) var persistence: NativeAppsRouterPersistence?
    private(set) var persistenceProblem: String?
    private(set) var alerts: Alerts?
    var alertsDraft = Alerts()
    private(set) var alertsProblem: String?
    private(set) var testResults: [String: Bool] = [:]
    private(set) var history: [AlertEntry] = []
    private(set) var cleanup: Cleanup?
    var cleanupDraft = Cleanup()
    var cleanupSchedule = NativeAppsSRV2Schedule(preset: .weekly, time: "04:00", day: "Sun")
    private(set) var cleanupLast: CleanupResult?
    private(set) var cleanupPreview: CleanupResult?
    private(set) var cleanupNextRun: String?
    private(set) var cleanupProblem: String?

    private(set) var loading = true
    private(set) var loadProblem: String?
    let changes = NativeAppsChangeRunner<Part>()
    var busy: String? { changes.busy }
    var resultPart: Part? { changes.resultPart }
    var note: String? { changes.note }
    var problem: String? { changes.problem }

    @ObservationIgnored private let transport: NativeAppsSRV2Transport
    @ObservationIgnored private var started = false
    @ObservationIgnored private var readTask: Task<Void, Never>?

    init(serverID: String, serverName: String, transport: NativeAppsSRV2Transport? = nil) {
        self.serverID = serverID
        self.serverName = serverName
        self.transport = transport ?? { try await NativeAppsSRV2Engine.invoke($0, $1) }
    }

    /// Hidden render/test fixture: seeded facts and a transport that can never
    /// reach the engine, SSH, installed data or an AI provider.
    init(fixtureServerID: String, serverName: String, status: Status,
         plan: Plan? = nil, alerts: Alerts = Alerts(), cleanup: Cleanup = Cleanup()) {
        self.serverID = fixtureServerID
        self.serverName = serverName
        self.status = status; self.plan = plan
        self.alerts = alerts; self.alertsDraft = alerts
        self.cleanup = cleanup; self.cleanupDraft = cleanup
        self.transport = { _, _ in throw CancellationError() }
        self.started = true; self.loading = false
    }

    /// The name a person types to remove Terminal Deck: the server's own host
    /// name when known (the engine accepts it or the saved server ID).
    var confirmationName: String {
        if let host = status?.hostname, !host.isEmpty { return host }
        return serverID
    }

    private func call(_ channel: String, _ additional: [String: Any] = [:]) async throws -> NativeRPCValue {
        var payload = additional
        payload["serverId"] = serverID
        return try await transport(channel, payload)
    }

    // MARK: reading

    func loadIfNeeded() { if !started { load() } }

    func load() {
        started = true
        readTask?.cancel()
        let mine = changes.advance()
        loading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try NativeAppsSRV2Engine.decode(Status.self, try await call("apps:server:status"), what: "its status")
                guard !Task.isCancelled, changes.isCurrent(mine) else { return }
                status = next; loadProblem = nil
                async let planRead = readPlan()
                async let persistRead = readPersistence()
                async let alertsRead = next.installed ? readAlerts() : nil
                async let cleanupRead = next.installed ? readCleanup() : nil
                let (plan, persist, alertsResult, cleanupResult) = await (planRead, persistRead, alertsRead, cleanupRead)
                guard !Task.isCancelled, changes.isCurrent(mine) else { return }
                self.plan = plan
                switch persist {
                case .success(let value): persistence = value; persistenceProblem = nil
                case .failure(let error):
                    persistence = nil
                    let code = (error as? NativeRPCError)?.code
                    persistenceProblem = code == "unknown-channel" || code == "not-implemented" ? nil
                        : "Could not check whether addresses are kept after a restart."
                }
                if let alertsResult { applyAlertsRead(alertsResult) } else { alerts = nil; history = []; alertsProblem = nil }
                if let cleanupResult { applyCleanupRead(cleanupResult) } else { cleanup = nil; cleanupProblem = nil }
            } catch {
                guard !Task.isCancelled, changes.isCurrent(mine) else { return }
                loadProblem = NativeAppsSRV2Engine.problem(error)
            }
            loading = false
        }
    }

    private func readPlan() async -> Plan? {
        try? NativeAppsSRV2Engine.decode(Plan.self, try await call("apps:server:setup:plan"), what: "its setup plan")
    }

    private func readPersistence() async -> Result<NativeAppsRouterPersistence, Error> {
        do { return .success(try NativeAppsRouterPersistence.from(try await call("apps:router:persist:plan"))) }
        catch { return .failure(error) }
    }

    private func readAlerts() async -> Result<(NativeRPCValue, NativeRPCValue?), Error> {
        do {
            let settings = try await call("apps:server:alerts:read")
            let history = try? await call("apps:server:alerts:history", ["limit": 20])
            return .success((settings, history))
        } catch { return .failure(error) }
    }

    private func readCleanup() async -> Result<NativeRPCValue, Error> {
        do { return .success(try await call("apps:server:cleanup:read")) }
        catch { return .failure(error) }
    }

    private func applyAlertsRead(_ result: Result<(NativeRPCValue, NativeRPCValue?), Error>) {
        switch result {
        case .success(let (settings, history)):
            adoptAlerts(Self.alerts(settings))
            if let history { self.history = Self.history(history) }
            alertsProblem = nil
        case .failure(let error):
            alerts = nil
            alertsProblem = NativeAppsSRV2Engine.problem(error)
        }
    }

    private func applyCleanupRead(_ result: Result<NativeRPCValue, Error>) {
        switch result {
        case .success(let value):
            do { adoptCleanup(try NativeAppsSRV2Engine.decode(CleanupRead.self, value, what: "its cleanup settings")); cleanupProblem = nil }
            catch { cleanupProblem = NativeAppsSRV2Engine.problem(error) }
        case .failure(let error):
            cleanup = nil
            cleanupProblem = NativeAppsSRV2Engine.problem(error)
        }
    }

    private func adoptAlerts(_ next: Alerts) {
        alerts = next
        alertsDraft = next
    }

    private func adoptCleanup(_ read: CleanupRead) {
        let settings = read.settings ?? Cleanup()
        cleanup = settings
        cleanupDraft = settings
        cleanupSchedule = NativeAppsSRV2Schedule(calendar: settings.schedule)
        cleanupLast = read.last
        // The server's stored preview may be days old, while a run removes whatever qualifies
        // now; only a check made here lists what would go and enables "Run cleanup now".
        cleanupNextRun = read.nextRun
    }

    static func alerts(_ value: NativeRPCValue) -> Alerts {
        var result = Alerts()
        result.enabled = value["enabled"].bool ?? true
        result.channels = (value["channels"].elements ?? []).compactMap { row in
            guard let name = row["id"].string, let kind = ChannelKind(rawValue: row["kind"].string ?? "") else { return nil }
            var channel = AlertChannel(name: name, kind: kind, enabled: row["enabled"].bool ?? true, saved: true)
            let flag = "has" + kind.secretKey.prefix(1).uppercased() + kind.secretKey.dropFirst()
            channel.hasSecret = row[flag].bool ?? (row[kind.secretKey].string == NativeAppsVariable.mask)
            channel.chatId = row["chatId"].string ?? ""
            channel.smtpUrl = row["smtpUrl"].string ?? ""
            channel.username = row["username"].string ?? ""
            channel.from = row["from"].string ?? ""
            channel.to = (row["to"].elements ?? []).compactMap(\.string).joined(separator: ", ")
            channel.url = row["url"].string ?? ""
            return channel
        }
        // A damaged settings file on the server must never end the app: each number is held in the range saving accepts.
        result.diskPercent = NativeNumber.clamped(value["thresholds"]["diskPercent"].number, to: 50...99, fallback: 85)
        result.memoryPressure = NativeNumber.clamped(value["thresholds"]["memoryPressure"].number, to: 1...100, fallback: 20)
        result.certDays = NativeNumber.clamped(value["thresholds"]["certDays"].number, to: 1...60, fallback: 14)
        result.remindMinutes = NativeNumber.clamped(value["remindMinutes"].number, to: 10...10_080, fallback: 1440)
        result.watch = (value["watch"]["containers"].elements ?? []).compactMap(\.string).joined(separator: ", ")
        return result
    }

    static func history(_ value: NativeRPCValue) -> [AlertEntry] {
        (value.elements ?? []).prefix(50).enumerated().map { index, row in
            AlertEntry(id: index, severity: row["severity"].string ?? "info",
                       title: String((row["title"].string ?? "Alert").prefix(200)),
                       message: String((row["message"].string ?? "").prefix(600)),
                       app: row["app"].string, at: NativeAppsSRV2Engine.date(row["at"].number),
                       delivered: (row["delivered"].elements ?? []).compactMap { item in
                           item["id"].string.map { ($0, item["ok"].bool == true) }
                       })
        }
    }

    // MARK: setup

    func install(writesDisabled: Bool) {
        guard let plan, plan.blockedReason == nil else { return }
        let upgrade = plan.upgrade == true
        changes.run(.setup, upgrade ? "Updating the helper set" : "Setting up this server", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:server:setup:install")
            guard reply["installed"].bool == true else { throw NativeRPCError.malformed("Setup was not confirmed.") }
            let version = reply["version"].string.map { " (helper set \($0))" } ?? ""
            return (upgrade ? "The helper set is up to date" : "This server is set up for Apps") + version + "."
        } after: { [self] in load() }
    }

    func remove(typedName: String, addressManager: Bool, importUndo: NativeAppsRouterPersistence.OwnedImport? = nil, writesDisabled: Bool) {
        changes.run(.remove, "Removing Terminal Deck from this server", writesDisabled: writesDisabled) { [self] in
            var payload: [String: Any] = ["confirmation": typedName, "addressManager": addressManager]
            if let importUndo { payload["importUndo"] = ["file": importUndo.file, "line": importUndo.line, "folder": importUndo.folder] }
            let reply = try await call("apps:server:setup:remove", payload)
            guard reply["removed"].bool == true else { throw NativeRPCError.malformed("Removal was not confirmed.") }
            var text = "Terminal Deck’s helpers were removed from this server. Your apps, their data and backups stay."
            switch reply["addressManager"].string {
            case "removed"?: text += " The address manager was removed too."
            case let kept? where kept.hasPrefix("kept"): text += " The address manager was kept because apps still use it."
            default: break
            }
            if let warning = reply["warning"].string, warning.count <= 300 { text += " " + warning }
            if let undone = reply["importUndo"]["note"].string, undone.count <= 400 { text += " " + undone }
            return text
        } after: { [self] in load() }
    }

    func applyPersistence(file: String, line: String, writesDisabled: Bool) {
        changes.run(.persist, "Adding the line", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:router:persist:apply", ["file": file, "line": line])
            if reply["ready"].bool == true, var next = persistence {
                next.ready = true; next.line = nil; next.file = nil
                next.note = reply["note"].string ?? next.note
                persistence = next
            }
            return reply["note"].string ?? "Addresses are kept after a restart."
        } after: { [self] in
            Task { [self] in if case .success(let next) = await readPersistence() { persistence = next } }
        }
    }

    // MARK: alerts

    var alertsChanged: Bool { alerts != nil && alertsDraft != alerts }

    func addChannel(_ kind: ChannelKind) {
        let taken = Set(alertsDraft.channels.map(\.name))
        var name = kind.rawValue, number = 2
        while taken.contains(name) { name = kind.rawValue + "-\(number)"; number += 1 }
        alertsDraft.channels.append(AlertChannel(name: name, kind: kind))
    }

    func removeChannel(_ id: UUID) { alertsDraft.channels.removeAll { $0.id == id } }

    func revertAlerts() {
        if let alerts { alertsDraft = alerts }
        changes.clear(.alerts)
    }

    /// The first thing that blocks saving, in plain words.
    var alertsMessage: String? {
        var names = Set<String>()
        for channel in alertsDraft.channels {
            let name = channel.name
            guard NativeAppsSRV2Engine.matches(name, #"\A[A-Za-z0-9_-]{1,48}\z"#) else { return "Name each channel with letters, numbers, dashes or underscores." }
            guard names.insert(name).inserted else { return "Each alert channel needs its own name." }
            if let message = Self.channelProblem(channel) { return "\(name): \(message)" }
        }
        let watch = Self.watchNames(alertsDraft.watch)
        guard watch.count <= 50 else { return "Watch at most 50 other containers." }
        guard watch.allSatisfy({ NativeAppsSRV2Engine.matches($0, #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z"#) }) else {
            return "Container names may use letters, numbers, dots, dashes and underscores."
        }
        return nil
    }

    static func channelProblem(_ channel: AlertChannel) -> String? {
        let secret = channel.secret
        func ok(_ text: String, _ pattern: String) -> Bool { NativeAppsSRV2Engine.matches(text, pattern) }
        switch channel.kind {
        case .telegram:
            if secret.isEmpty { if !channel.hasSecret { return "Enter the bot token." } }
            else if !ok(secret, #"\A[0-9]{5,16}:[A-Za-z0-9_-]{30,64}\z"#) { return "That Telegram bot token does not look right." }
            if !ok(channel.chatId, #"\A(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})\z"#) { return "Use the numeric Telegram chat ID or @channel name." }
        case .email:
            if !ok(channel.smtpUrl, #"\Asmtps?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?/?\z"#) { return "Use an smtp:// or smtps:// server address." }
            if !channel.username.isEmpty, !ok(channel.username, #"\A[^\x00-\x1f\x7f]{1,256}\z"#) { return "The email user name is invalid." }
            if !secret.isEmpty, !ok(secret, #"\A[^\x00-\x1f\x7f]{1,256}\z"#) { return "The email password is invalid." }
            let email = #"\A[^\s<>,@]{1,64}@[A-Za-z0-9.-]{1,253}\z"#
            if !ok(channel.from, email) { return "Use a plain sender email address." }
            let to = recipients(channel.to)
            if !(1...10).contains(to.count) { return "Send email alerts to 1–10 addresses." }
            if !to.allSatisfy({ ok($0, email) }) { return "One recipient address is invalid." }
        case .webhook:
            if !ok(channel.url, #"\A(https://[^\s"\\]{4,2000}|http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/[^\s"\\]*)?)\z"#) { return "Webhooks must use an https:// address." }
            if !secret.isEmpty, !ok(secret, #"\A[^\x00-\x1f\x7f]{8,256}\z"#) { return "The webhook signing secret must be 8–256 characters." }
        case .receiver:
            if !ok(channel.url, #"\Ahttps://[^\s"\\]{4,2000}\z"#) { return "The Receiver address must use https://." }
            if secret.isEmpty { if !channel.hasSecret { return "Enter the Receiver secret." } }
            else if !ok(secret, #"\A[A-Za-z0-9_.~-]{16,256}\z"#) { return "The Receiver secret does not look right." }
        }
        return nil
    }

    static func recipients(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }

    static func watchNames(_ text: String) -> [String] { recipients(text) }

    /// The request for apps:server:alerts:save. Saved secrets are left out, so
    /// the server keeps them; a newly typed one replaces it.
    var alertsPayload: [String: Any] {
        let channels: [[String: Any]] = alertsDraft.channels.map { channel in
            var row: [String: Any] = ["id": channel.name, "kind": channel.kind.rawValue, "enabled": channel.enabled]
            switch channel.kind {
            case .telegram: row["chatId"] = channel.chatId
            case .email:
                row["smtpUrl"] = channel.smtpUrl
                if !channel.username.isEmpty { row["username"] = channel.username }
                row["from"] = channel.from
                row["to"] = Self.recipients(channel.to)
            case .webhook, .receiver: row["url"] = channel.url
            }
            if !channel.secret.isEmpty { row[channel.kind.secretKey] = channel.secret }
            return row
        }
        return ["enabled": alertsDraft.enabled, "channels": channels,
                "thresholds": ["diskPercent": alertsDraft.diskPercent, "memoryPressure": alertsDraft.memoryPressure, "certDays": alertsDraft.certDays],
                "remindMinutes": alertsDraft.remindMinutes, "watch": ["containers": Self.watchNames(alertsDraft.watch)]]
    }

    func saveAlerts(writesDisabled: Bool) {
        guard alertsChanged else { return }
        if let message = alertsMessage { changes.report(.alerts, message); return }
        let payload = alertsPayload
        changes.run(.alerts, "Saving alerts", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:server:alerts:save", payload)
            adoptAlerts(Self.alerts(reply))
            testResults = [:]
            return "Alert settings saved on the server."
        }
    }

    var canTestAlerts: Bool { alerts?.channels.contains(where: \.enabled) == true && !alertsChanged }

    func testAlerts(writesDisabled: Bool) {
        changes.run(.test, "Sending a test alert", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:server:alerts:test")
            let rows = (reply["channels"].elements ?? []).compactMap { row in row["id"].string.map { ($0, row["ok"].bool == true) } }
            testResults = Dictionary(rows, uniquingKeysWith: { $1 })
            let reached = rows.filter { $0.1 }.count
            if rows.isEmpty { return "No channel is turned on, so nothing was sent." }
            return reached == rows.count ? "The test alert reached every channel." : "The test alert reached \(reached) of \(rows.count) channels."
        } after: { [self] in
            Task { [self] in
                if let value = try? await call("apps:server:alerts:history", ["limit": 20]) { history = Self.history(value) }
            }
        }
    }

    // MARK: cleanup

    var proposedCleanup: Cleanup {
        var next = cleanupDraft
        if let calendar = cleanupSchedule.calendar { next.schedule = calendar }
        return next
    }

    var cleanupChanged: Bool { cleanup != nil && (proposedCleanup != cleanup || cleanupSchedule.calendar == nil) }

    func revertCleanup() {
        if let cleanup { cleanupDraft = cleanup; cleanupSchedule = NativeAppsSRV2Schedule(calendar: cleanup.schedule) }
        changes.clear(.cleanup)
    }

    func saveCleanup(writesDisabled: Bool) {
        guard cleanupChanged else { return }
        if let message = cleanupSchedule.problem { changes.report(.cleanup, message); return }
        let next = proposedCleanup
        let payload: [String: Any] = ["enabled": next.enabled, "schedule": next.schedule, "removeOldVersions": next.removeOldVersions,
                                      "keepVersions": next.keepVersions, "buildCache": next.buildCache, "unnamedStorage": next.unnamedStorage]
        changes.run(.cleanup, "Saving cleanup", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:server:cleanup:save", payload)
            adoptCleanup(try NativeAppsSRV2Engine.decode(CleanupRead.self, reply, what: "its cleanup settings"))
            return "Cleanup settings saved on the server."
        }
    }

    /// A read: lists what cleanup would remove now, removing nothing.
    func previewCleanup() {
        let mine = changes.generation
        changes.run(.preview, "Checking what cleanup would remove") { [self] in
            let result = try NativeAppsSRV2Engine.decode(CleanupResult.self, try await call("apps:server:cleanup:preview"), what: "its cleanup preview")
            if changes.isCurrent(mine) { cleanupPreview = result }
            return nil
        }
    }

    func runCleanup(writesDisabled: Bool) {
        changes.run(.preview, "Running cleanup", writesDisabled: writesDisabled) { [self] in
            let result = try NativeAppsSRV2Engine.decode(CleanupResult.self, try await call("apps:server:cleanup:run"), what: "its cleanup result")
            cleanupLast = result
            cleanupPreview = nil
            let removed = (result.items ?? []).filter { ["removed", "trimmed"].contains($0.result ?? "") }.count
            return removed == 0 ? "Cleanup finished. Nothing needed removing."
                : "Cleanup finished: \(removed) item\(removed == 1 ? "" : "s") removed, \(NativeAppsSRV2Engine.bytes(result.freedBytes)) freed."
        }
    }
}
