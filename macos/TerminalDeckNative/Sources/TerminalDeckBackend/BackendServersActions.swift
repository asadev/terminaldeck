import Foundation
import TerminalDeckNativeCore

public enum BackendServersActionID: String, Codable, Sendable, CaseIterable {
    case open, logs, start, restart, stop, update, backup
    case copyAddress = "copy-address", goBack = "go-back"
    public static let ordered: [Self] = [.open, .copyAddress, .logs, .start, .restart, .stop, .update, .goBack, .backup]
    public static let control: [Self] = [.start, .restart, .stop, .update, .goBack, .backup]
}
public enum BackendServersActionClass: String, Codable, Sendable, CaseIterable { case safe, reversible, kept }
public struct BackendServersActionFailed: Error, LocalizedError, Sendable {
    public let sentence: String; public let detail: String
    public var errorDescription: String? { sentence }
    public init(_ sentence: String, detail: String) { self.sentence = sentence; self.detail = detail }
}
public struct BackendServersActionRefused: Error, LocalizedError, Sendable {
    public let sentence: String; public var errorDescription: String? { sentence }
    public init(_ sentence: String) { self.sentence = sentence }
}
public struct BackendServersActionTarget: Sendable {
    public let serverId: String; public let card: BackendServersCard; public let facts: BackendServersActionFacts
    public init(serverId: String, card: BackendServersCard, facts: BackendServersActionFacts) { self.serverId = serverId; self.card = card; self.facts = facts }
}
public struct BackendServersWayBackButton: Codable, Equatable, Sendable { public let actionId: BackendServersActionID; public let label: String }
public struct BackendServersActionOutcome: Sendable {
    public let done: String; public let detail: [String: NativeRPCValue]; public let wayBack: BackendServersWayBackButton?; public let value: NativeRPCValue?
    public init(done: String, detail: [String: NativeRPCValue] = [:], wayBack: BackendServersWayBackButton? = nil, value: NativeRPCValue? = nil) { self.done = done; self.detail = detail; self.wayBack = wayBack; self.value = value }
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("done", .string(done)), .init("detail", .object(detail.map { .init($0.key, $0.value) })), .init("wayBack", wayBack.map { .object([.init("actionId", .string($0.actionId.rawValue)), .init("label", .string($0.label))]) } ?? .null)]
        if let value { fields.append(.init("value", value)) }; return .object(fields)
    }
}
public enum BackendServersWayBack: Equatable, Sendable {
    case containerImage(at: Double, container: String, imageId: String, imageRef: String, compose: BackendServersComposeRef, backupPath: String?)
    case repoCommit(at: Double, dir: String, commit: String, managedBy: BackendServersManagedBy?, backupPath: String?)
}
public protocol BackendServersWayBackJournal: Sendable {
    func put(serverId: String, cardId: String, record: BackendServersWayBack) async throws
    func get(serverId: String, cardId: String) async throws -> BackendServersWayBack?
    func clear(serverId: String, cardId: String) async throws
}
public actor BackendServersMemoryJournal: BackendServersWayBackJournal {
    private struct Key: Hashable { var serverId: String; var cardId: String }
    private var rows: [Key: BackendServersWayBack] = [:]
    public init() {}
    public func put(serverId: String, cardId: String, record: BackendServersWayBack) { rows[.init(serverId: serverId, cardId: cardId)] = record }
    public func get(serverId: String, cardId: String) -> BackendServersWayBack? { rows[.init(serverId: serverId, cardId: cardId)] }
    public func clear(serverId: String, cardId: String) { rows[.init(serverId: serverId, cardId: cardId)] = nil }
}
/// Run is an internal typed transport dependency. It is never an MCP tool.
public struct BackendServersActionDeps: Sendable {
    public let run: @Sendable (String, [String]) async throws -> BackendServersRunResult
    public let journal: any BackendServersWayBackJournal
    public let download: (@Sendable (String, String, String) async throws -> Int)?
    public let backupDir: String?; public let now: @Sendable () -> Double; public let logLines: Double
    public init(run: @escaping @Sendable (String, [String]) async throws -> BackendServersRunResult, journal: any BackendServersWayBackJournal, download: (@Sendable (String, String, String) async throws -> Int)? = nil, backupDir: String? = nil, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, logLines: Double = 200) {
        self.run = run; self.journal = journal; self.download = download; self.backupDir = backupDir; self.now = now; self.logLines = logLines
    }
    public init(connections: BackendServersConnections, journal: any BackendServersWayBackJournal, download: (@Sendable (String, String, String) async throws -> Int)? = nil, backupDir: String? = nil, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, logLines: Double = 200) {
        self.init(run: { try await connections.run($0, argv: $1) }, journal: journal, download: download, backupDir: backupDir, now: now, logLines: logLines)
    }
}
public struct BackendServersAbsentAction: Codable, Equatable, Sendable { public let actionId: BackendServersActionID; public let because: String }
public struct BackendServersAvailability: Codable, Equatable, Sendable { public let offered: [BackendServersActionID]; public let absent: [BackendServersAbsentAction] }
public struct BackendServersActionPreview: Codable, Equatable, Sendable {
    public let actionId: BackendServersActionID; public let klass: BackendServersActionClass; public let label: String; public let target: String; public let sentence: String; public let wayBack: String?; public let keeps: String?
    public func wireValue() throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(self)) }
}

public enum BackendServersActions {
    public static let defaultLogLines = 200
    public static let maxLogLines = 2000
    public static let notYoursToStop = "We can’t tell whether you set this up, so this app doesn’t offer to start or stop it. The terminal under Advanced can, if you know you need to."
    public static let noManager = "We can’t tell how this server starts and stops things, so we’re not going to guess."
    public static let noRecord = "We didn’t manage to record a way back, so we haven’t changed anything."
    public static let noSavedRecord = "We couldn’t save a way back on this computer, so we haven’t changed anything."
    public static func klass(_ action: BackendServersActionID) -> BackendServersActionClass { switch action { case .open, .copyAddress, .logs, .backup: .safe; case .update: .kept; default: .reversible } }
    public static func label(_ action: BackendServersActionID) -> String { switch action { case .copyAddress: "Copy address"; case .goBack: "Go back"; default: action.rawValue.prefix(1).uppercased() + String(action.rawValue.dropFirst()) } }
    public static func wherePerformed(_ action: BackendServersActionID) -> String { action == .open || action == .copyAddress ? "here" : "server" }
    public static func elevate(_ argv: [String], facts: BackendServersActionFacts) -> [String] { facts.privilege.value == .yes ? argv : ["sudo", "-n"] + argv }
    public static func canAdminister(_ facts: BackendServersActionFacts) -> Bool { facts.privilege.value.map { [.yes, .sudoNoPassword, .sudoPassword].contains($0) } ?? false }
    public static func serviceCommand(_ managedBy: BackendServersManagedBy, verb: BackendServersActionID, facts: BackendServersActionFacts) -> [String]? {
        guard [.start, .stop, .restart].contains(verb) else { return nil }
        switch managedBy {
        case .systemd(let unit): guard BackendServersClassify.isSafeName(unit) else { return nil }; return elevate(["systemctl", verb.rawValue, unit], facts: facts)
        case .openrc(let service): guard BackendServersClassify.isSafeName(service) else { return nil }; return elevate(["rc-service", service, verb.rawValue], facts: facts)
        case .container(let runtime, let name, _): guard BackendServersClassify.isSafeName(name) else { return nil }; return [runtime.rawValue, verb.rawValue, name]
        }
    }
    public static func logCommand(_ managedBy: BackendServersManagedBy, lines: Double, facts: BackendServersActionFacts) -> [String]? {
        let n = lines.isNaN ? "NaN" : String(Int(min(max(lines.rounded(.towardZero), 1), Double(maxLogLines))))
        switch managedBy {
        case .systemd(let unit): guard BackendServersClassify.isSafeName(unit) else { return nil }; return elevate(["journalctl", "-u", unit, "-n", n, "--no-pager", "-o", "short-iso"], facts: facts)
        case .container(let runtime, let name, _): guard BackendServersClassify.isSafeName(name) else { return nil }; return [runtime.rawValue, "logs", "--tail", n, "--timestamps", name]
        case .openrc: return nil
        }
    }
    public static func failureSentence(_ result: BackendServersRunResult, what: String) -> BackendServersActionFailed {
        let said = (result.stderr + "\n" + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let ending = result.code.map { "The command ended with code \($0)." } ?? "The command was stopped by \(result.signal ?? "a signal")."
        let detail = said.isEmpty ? ending : said.components(separatedBy: "\n").prefix(20).joined(separator: "\n")
        let permissions = [#"\bpermission denied\b"#, #"\bmust be root\b"#, #"\boperation not permitted\b"#, #"a (?:password|terminal) is required"#, #"sudo: .*(?:no tty|askpass|not allowed|not in the sudoers)"#, #"interactive authentication required"#, #"\baccess denied\b"#, #"\bnot authori[sz]ed\b"#, #"got permission denied while trying to connect to the docker daemon"#]
        let missing = [#"\bcould not be found\b"#, #"\bnot found\b"#, #"\bno such (?:file|directory|container|object|service|unit)\b"#, #"\bunit .* not loaded\b"#]
        if permissions.contains(where: { BackendServersClassify.matches(said, "(?i)" + $0) }) { return .init("This sign-in isn’t allowed to do that on this server.", detail: detail) }
        if missing.contains(where: { BackendServersClassify.matches(said, "(?i)" + $0) }) { return .init("The server couldn’t find \(what) any more.", detail: detail) }
        return .init("The server refused to do that to \(what).", detail: detail)
    }
    @discardableResult private static func ok(_ result: BackendServersRunResult, _ what: String) throws -> BackendServersRunResult { guard result.code == 0 else { throw failureSentence(result, what: what) }; return result }
    public static func shellJoin(_ argv: [String]) -> String { argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") }
    private static func composeArgv(_ runtime: BackendServersContainerRuntime, _ compose: BackendServersComposeRef, _ rest: [String]) -> [String] {
        var argv = [runtime.rawValue, "compose"]; if !compose.workingDir.isEmpty { argv += ["--project-directory", compose.workingDir] }; return argv + ["-p", compose.project] + rest
    }
    public static func dumpCommand(_ engine: BackendServersKnownEngine, managedBy: BackendServersManagedBy) -> (probe: [String], dump: [String])? {
        guard case .container(let runtime, let name, _) = managedBy, BackendServersClassify.isSafeName(name) else { return nil }
        let exec = [runtime.rawValue, "exec", name, "sh", "-c"]
        if engine == .postgres { return (exec + ["command -v pg_dumpall"], exec + [#"exec pg_dumpall -U "${POSTGRES_USER:-postgres}""#]) }
        if engine == .mysql || engine == .mariadb {
            let tool = engine == .mariadb ? "mariadb-dump" : "mysqldump"
            return (exec + ["command -v \(tool) || command -v mysqldump"], exec + [#"export MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"; "# + "exec \(tool) -u root --all-databases 2>/dev/null || exec mysqldump -u root --all-databases"])
        }
        return nil
    }
    public static func canBackUp(_ engine: BackendServersKnownEngine?, managedBy: BackendServersManagedBy?) -> Bool { guard let engine, let managedBy else { return false }; return dumpCommand(engine, managedBy: managedBy) != nil }
    public enum UpdateKind: String, Sendable { case container, repository }
    public static func updateKind(_ card: BackendServersCard, composeAvailable: Bool) -> UpdateKind? {
        if let managed = card.managedBy, managed.runtime != nil { return managed.compose != nil && composeAvailable ? .container : nil }
        return card.repoDir == nil ? nil : .repository
    }
    public static func availableActions(_ card: BackendServersCard, facts: BackendServersActionFacts, canDownload: Bool, composeAvailable: Bool) -> BackendServersAvailability {
        var offered: [BackendServersActionID] = []; var absent: [BackendServersAbsentAction] = []
        func missing(_ id: BackendServersActionID, _ reason: String) { absent.append(.init(actionId: id, because: reason)) }
        if card.url != nil { offered += [.open, .copyAddress] }
        if card.kind == .other {
            if let managed = card.managedBy, logCommand(managed, lines: Double(defaultLogLines), facts: facts) != nil { offered.append(.logs) }
            missing(.restart, notYoursToStop); return .init(offered: offered, absent: absent)
        }
        if let managed = card.managedBy {
            if managed.runtime == nil && !canAdminister(facts) { missing(.restart, "This sign-in can’t start or stop things on this server.") }
            else {
                if logCommand(managed, lines: Double(defaultLogLines), facts: facts) != nil { offered.append(.logs) }
                else { missing(.logs, "This server doesn’t keep a log we can read for this.") }
                if card.running == false { offered.append(.start) } else { offered += [.restart, .stop] }
            }
        } else { missing(.restart, noManager) }
        if card.engine != nil {
            if canBackUp(card.engine, managedBy: card.managedBy) && canDownload { offered.append(.backup) }
            else if !canDownload { missing(.backup, "This app can’t copy files off a server yet.") }
            else { missing(.backup, "We can’t tell what kind of database this is, so we don’t know how to copy it safely.") }
        }
        if updateKind(card, composeAvailable: composeAvailable) == nil {
            missing(.update, card.managedBy?.runtime != nil && card.managedBy?.compose != nil && !composeAvailable ? "This server doesn’t have the tool we’d use to put a container back, so we won’t change one." : "We can’t tell how this was set up, so we don’t know how to put it back.")
        } else if card.engine != nil && !(canBackUp(card.engine, managedBy: card.managedBy) && canDownload) {
            missing(.update, "We can’t make a copy of what’s in here first, and updating a database without one isn’t something we can undo.")
        } else { offered.append(.update) }
        return .init(offered: offered, absent: absent)
    }
    /// Consequence words are produced here, on the backend, for UI and consent.
    public static func summary(_ action: BackendServersActionID, target: BackendServersActionTarget) -> String {
        let name = target.card.name
        switch action {
        case .open: return "Open \(name) in a browser"
        case .copyAddress: return "Copy the address of \(name)"
        case .logs: return "Show what \(name) has been saying"
        case .start: return "Start \(name). It’ll be running again in a few seconds."
        case .restart: return "Restart \(name). It’ll be offline for about five seconds while it starts again."
        case .stop: return "Stop \(name). It’ll be off until you start it again — anyone visiting will see an error."
        case .backup: return "Copy everything in \(name) to your computer. Nothing on the server changes."
        case .goBack: return "Put \(name) back on the version it was on before the last update. It’ll be offline for about ten seconds. Update will bring it forward again."
        case .update:
            if target.card.repoDir != nil && target.card.managedBy?.runtime == nil { return "Update \(name) to the latest code. It’ll restart, and be offline for about five seconds. We’ll remember where it is now so you can go back." }
            if target.card.engine != nil { return "Update \(name) to the newest version. We’ll copy everything in it to your computer first, and keep the current version so you can go back. This can take a minute or two." }
            return "Update \(name) to the newest version. It’ll be offline for about ten seconds. We’ll keep the current version so you can go back."
        }
    }
    public static func previewOf(_ action: BackendServersActionID, target: BackendServersActionTarget, composeAvailable: Bool = true) -> BackendServersActionPreview {
        let kind = updateKind(target.card, composeAvailable: composeAvailable); let wayBack: String?
        switch action { case .stop, .restart: wayBack = "Start"; case .start: wayBack = "Stop"; case .update: wayBack = kind == .repository ? "Go back" : "Go back to the previous version"; case .goBack: wayBack = "Update"; default: wayBack = nil }
        let keeps = klass(action) != .kept ? nil : kind == .repository ? "the exact version of the code that is on the server right now" : target.card.engine != nil ? "a copy of everything in this database, on your computer, and the version that is running now" : "the version that is running now"
        return .init(actionId: action, klass: klass(action), label: label(action), target: target.card.name, sentence: summary(action, target: target), wayBack: wayBack, keeps: keeps)
    }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func backUpDatabase(_ deps: BackendServersActionDeps, _ target: BackendServersActionTarget) async throws -> (path: String, bytes: Int) {
        guard let download = deps.download, let dir = deps.backupDir else { throw BackendServersActionRefused("This app can’t copy files off a server yet, so there’s no safe way to do this.") }
        guard let engine = target.card.engine, let managed = target.card.managedBy, let commands = dumpCommand(engine, managedBy: managed) else { throw BackendServersActionRefused("We can’t tell what kind of database this is, so we don’t know how to copy it safely.") }
        let probe = try await deps.run(target.serverId, commands.probe)
        guard probe.code == 0 else { throw BackendServersActionFailed("This database doesn’t come with the tool we’d use to copy it, so we can’t make a copy you could trust.", detail: trim(probe.stderr).isEmpty ? "The copy tool was not found on the server." : trim(probe.stderr)) }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: deps.now() / 1000)).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        let remote = "/tmp/td-backup-\(stamp).sql", local = "\(dir)/\(target.card.name)-\(stamp).sql"
        guard BackendServersClassify.isSafePath(remote), BackendServersClassify.isSafePath(local) else { throw BackendServersActionRefused("We couldn’t pick a safe place to put the copy.") }
        do {
            try ok(await deps.run(target.serverId, ["sh", "-c", "\(shellJoin(commands.dump)) > \(remote)"]), target.card.name)
            let size = try await deps.run(target.serverId, ["sh", "-c", "wc -c < \(remote)"])
            // Match parseInt: only the leading decimal integer matters.
            let digits = trim(size.stdout).prefix { $0.isASCII && $0.isNumber }
            guard let bytes = Int(digits), bytes > 0 else { throw BackendServersActionFailed("The copy came out empty, so we threw it away rather than leave you with a backup that isn’t one.", detail: trim(size.stderr).isEmpty ? "The dump produced zero bytes." : trim(size.stderr)) }
            let moved = try await download(target.serverId, remote, local)
            _ = try? await deps.run(target.serverId, ["rm", "-f", remote])
            return (local, moved)
        } catch {
            _ = try? await deps.run(target.serverId, ["rm", "-f", remote]); throw error
        }
    }
    private static func keep(_ deps: BackendServersActionDeps, _ target: BackendServersActionTarget) async throws -> BackendServersWayBack {
        guard let kind = updateKind(target.card, composeAvailable: true) else { throw BackendServersActionRefused("We can’t tell how this was set up, so we don’t know how to put it back.") }
        if target.card.engine != nil && (deps.download == nil || deps.backupDir == nil) { throw BackendServersActionRefused("This app can’t copy files off a server yet, so there’s no safe way to do this.") }
        let at = deps.now()
        if kind == .repository {
            guard let dir = target.card.repoDir, BackendServersClassify.isSafePath(dir) else { throw BackendServersActionRefused("We can’t tell where this is kept on the server, so we don’t know how to put it back.") }
            let dirty = try ok(await deps.run(target.serverId, ["git", "-C", dir, "status", "--porcelain"]), target.card.name)
            guard trim(dirty.stdout).isEmpty else { throw BackendServersActionRefused("Someone has changed this on the server itself. We won’t update it, because we couldn’t put those changes back afterwards.") }
            let head = try ok(await deps.run(target.serverId, ["git", "-C", dir, "rev-parse", "HEAD"]), target.card.name); let commit = trim(head.stdout)
            guard BackendServersClassify.matches(commit, #"^[0-9a-f]{7,64}$"#) else { throw BackendServersActionRefused("We couldn’t work out which version is on the server, so we didn’t change anything.") }
            return .repoCommit(at: at, dir: dir, commit: commit, managedBy: target.card.managedBy, backupPath: nil)
        }
        guard let managed = target.card.managedBy, case .container(let runtime, let name, let maybeCompose) = managed, let compose = maybeCompose else { throw BackendServersActionRefused("We can’t tell how this was set up, so we don’t know how to put it back.") }
        let inspect = try ok(await deps.run(target.serverId, [runtime.rawValue, "inspect", "--format", "{{.Image}}\t{{.Config.Image}}", name]), target.card.name)
        let columns = trim(inspect.stdout).components(separatedBy: "\t")
        guard columns.count > 1, !columns[0].isEmpty, !columns[1].isEmpty else { throw BackendServersActionRefused("We couldn’t work out which version is running, so we didn’t change anything.") }
        guard BackendServersClassify.isSafeName(columns[1]) else { throw BackendServersActionRefused("We can’t tell which version this uses, so we don’t know how to put it back.") }
        let backup = target.card.engine != nil ? try await backUpDatabase(deps, target) : nil
        return .containerImage(at: at, container: name, imageId: trim(columns[0]), imageRef: trim(columns[1]), compose: compose, backupPath: backup?.path)
    }
    public static func perform(_ deps: BackendServersActionDeps, actionId: BackendServersActionID, target: BackendServersActionTarget) async throws -> BackendServersActionOutcome {
        if klass(actionId) != .kept { return try await run(deps, actionId, target, nil) }
        let kept = try await keep(deps, target)
        do { try await deps.journal.put(serverId: target.serverId, cardId: target.card.id, record: kept) }
        catch { throw BackendServersActionRefused(noSavedRecord) }
        guard let readBack = try? await deps.journal.get(serverId: target.serverId, cardId: target.card.id) else { throw BackendServersActionRefused(noSavedRecord) }
        return try await run(deps, actionId, target, readBack)
    }
    /// Public string entrypoint rejects unknown vocabulary before transport.
    public static func perform(_ deps: BackendServersActionDeps, action: String, target: BackendServersActionTarget) async throws -> BackendServersActionOutcome {
        guard let id = BackendServersActionID(rawValue: action) else { throw BackendServersActionRefused("That isn’t something this app can do.") }
        return try await perform(deps, actionId: id, target: target)
    }
    private static func run(_ deps: BackendServersActionDeps, _ action: BackendServersActionID, _ target: BackendServersActionTarget, _ kept: BackendServersWayBack?) async throws -> BackendServersActionOutcome {
        let name = target.card.name, id = target.serverId
        switch action {
        case .open:
            guard let url = target.card.url, BackendServersClassify.matches(url, #"(?i)^https?://"#) else { throw BackendServersActionRefused("There isn’t an address we can open for this.") }
            return .init(done: "Opened \(name).", detail: ["url": .string(url)], value: .object([.init("url", .string(url))]))
        case .copyAddress:
            guard let url = target.card.url else { throw BackendServersActionRefused("There isn’t an address to copy for this.") }
            return .init(done: "Copied.", detail: ["url": .string(url)], value: .object([.init("url", .string(url))]))
        case .logs:
            guard let managed = target.card.managedBy else { throw BackendServersActionRefused("There’s nothing here we can read a log from.") }
            guard let argv = logCommand(managed, lines: deps.logLines, facts: target.facts) else { throw BackendServersActionRefused("This server doesn’t keep a log we can read for this.") }
            let result = try await deps.run(id, argv)
            if result.code != 0 && trim(result.stdout).isEmpty { throw failureSentence(result, what: name) }
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .init(done: "Read the last \(lines.count) lines from \(name).", detail: ["lines": .number(Double(lines.count))], value: .object([.init("lines", .array(lines.map(NativeRPCValue.string)))]))
        case .start, .restart, .stop:
            guard let managed = target.card.managedBy, let argv = serviceCommand(managed, verb: action, facts: target.facts) else { throw BackendServersActionRefused(noManager) }
            try ok(await deps.run(id, argv), name)
            let past = action == .start ? "Started" : action == .restart ? "Restarted" : "Stopped"
            return .init(done: "\(past) \(name).", detail: ["action": .string(action.rawValue)], wayBack: .init(actionId: action == .start ? .stop : .start, label: action == .start ? "Stop" : "Start"))
        case .backup:
            let copy = try await backUpDatabase(deps, target)
            return .init(done: "Copied \(name) to your computer.", detail: ["bytes": .number(Double(copy.bytes))], value: .object([.init("path", .string(copy.path)), .init("bytes", .number(Double(copy.bytes)))]))
        case .update:
            guard let kept else { throw BackendServersActionRefused(noRecord) }
            switch kept {
            case .repoCommit(_, let dir, let commit, let managed, _):
                try ok(await deps.run(id, ["git", "-C", dir, "fetch", "--quiet"]), name)
                try ok(await deps.run(id, ["git", "-C", dir, "merge", "--ff-only"]), name)
                if let managed, let argv = serviceCommand(managed, verb: .restart, facts: target.facts) { try ok(await deps.run(id, argv), name) }
                let head = try await deps.run(id, ["git", "-C", dir, "rev-parse", "HEAD"])
                return .init(done: trim(head.stdout) == commit ? "\(name) was already up to date." : "Updated \(name). You can still go back to the version it was on.", detail: ["from": .string(String(commit.prefix(12))), "to": .string(String(trim(head.stdout).prefix(12)))], wayBack: .init(actionId: .goBack, label: "Go back"))
            case .containerImage(_, _, let image, _, let compose, let backup):
                guard let runtime = target.card.managedBy?.runtime else { throw BackendServersActionRefused("We can’t reach the container this runs in any more.") }
                try ok(await deps.run(id, composeArgv(runtime, compose, ["pull", compose.service])), name)
                try ok(await deps.run(id, composeArgv(runtime, compose, ["up", "-d", compose.service])), name)
                return .init(done: "Updated \(name). You can still go back to the previous version.", detail: ["from": .string(String(image.prefix(19))), "backedUp": .bool(backup != nil)], wayBack: .init(actionId: .goBack, label: "Go back to the previous version"))
            }
        case .goBack:
            guard let saved = try await deps.journal.get(serverId: id, cardId: target.card.id) else { throw BackendServersActionRefused("We don’t have a previous version recorded for this, so there’s nothing to go back to.") }
            switch saved {
            case .repoCommit(_, let dir, let commit, let managed, _):
                try ok(await deps.run(id, ["git", "-C", dir, "reset", "--hard", commit]), name)
                if let managed, let argv = serviceCommand(managed, verb: .restart, facts: target.facts) { try ok(await deps.run(id, argv), name) }
                try await deps.journal.clear(serverId: id, cardId: target.card.id)
                return .init(done: "Put \(name) back.", detail: ["commit": .string(String(commit.prefix(12)))], wayBack: .init(actionId: .update, label: "Update"))
            case .containerImage(_, _, let image, let ref, let compose, _):
                guard let runtime = target.card.managedBy?.runtime else { throw BackendServersActionRefused("We can’t reach the container this runs in any more.") }
                let present = try await deps.run(id, [runtime.rawValue, "image", "inspect", image])
                guard present.code == 0 else { throw BackendServersActionFailed("The previous version isn’t on this server any more, so we can’t put it back.", detail: trim(present.stderr).isEmpty ? "The recorded image is no longer present." : trim(present.stderr)) }
                try ok(await deps.run(id, [runtime.rawValue, "tag", image, ref]), name)
                try ok(await deps.run(id, composeArgv(runtime, compose, ["up", "-d", "--force-recreate", compose.service])), name)
                try await deps.journal.clear(serverId: id, cardId: target.card.id)
                return .init(done: "Put \(name) back on the previous version.", detail: ["imageId": .string(String(image.prefix(19)))], wayBack: .init(actionId: .update, label: "Update"))
            }
        }
    }
}

public struct BackendServersView: Codable, Equatable, Sendable {
    public var cards: [BackendServersCard]; public var facts: BackendServersFacts; public var composeAvailable: Bool
    public var offered: [String: [BackendServersActionID]]; public var absent: [String: [BackendServersAbsentAction]]
    public var how: [String]; public var cannot: [BackendServersCannot]; public var measuredAt: Double
    public init(facts: BackendServersFacts, survey: BackendServersWayBackSurvey, canDownload: Bool) {
        self.facts = facts; cards = BackendServersClassify.classify(facts, survey: survey); composeAvailable = survey.composeAvailable
        offered = [:]; absent = [:]
        for card in cards { let a = BackendServersActions.availableActions(card, facts: facts.actionFacts, canDownload: canDownload, composeAvailable: survey.composeAvailable); offered[card.id] = a.offered; absent[card.id] = a.absent }
        how = BackendServersClassify.howOf(facts); cannot = BackendServersClassify.cannotOf(facts); measuredAt = facts.measuredAt
    }
    public func wireValue() throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(self)) }
}
