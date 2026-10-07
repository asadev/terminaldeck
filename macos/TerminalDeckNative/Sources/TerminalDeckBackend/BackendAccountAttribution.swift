import Foundation
import Dispatch
import TerminalDeckNativeCore

public struct BackendAccountHookEvidence: Sendable {
    public let provider: String
    public let configDirectory: String?
    public let home: String?
    public let environmentWasRead: Bool
    public init(provider: String, configDirectory: String?, home: String?, environmentWasRead: Bool) {
        self.provider = provider; self.configDirectory = configDirectory; self.home = home; self.environmentWasRead = environmentWasRead
    }
}

public struct BackendAccountSessionReading: Sendable {
    public let provider: String?
    public let configDir: String?
    public let profileId: String?
    public let profileName: String?
    public let source: String?
    public let email: String?
    public let reason: String?
    public var wireValue: NativeRPCValue {
        if let reason { return .object([.init("kind", .string("withheld")), .init("reason", .string(reason))]) }
        return .object([.init("kind", .string("known")), .init("provider", provider.map(NativeRPCValue.string) ?? .null),
            .init("configDir", configDir.map(NativeRPCValue.string) ?? .null), .init("profileId", profileId.map(NativeRPCValue.string) ?? .null),
            .init("profileName", profileName.map(NativeRPCValue.string) ?? .null), .init("source", source.map(NativeRPCValue.string) ?? .null),
            .init("email", email.map(NativeRPCValue.string) ?? .null)])
    }
    static func withheld(_ message: String) -> Self { Self(provider: nil, configDir: nil, profileId: nil, profileName: nil, source: nil, email: nil, reason: message) }
}

/// One row of `ps -Ao pid=,ppid=,command=` (session-account.ts `ProcessRow`).
public struct BackendAccountProcessRow: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let command: String
    public init(pid: Int32, ppid: Int32, command: String) { self.pid = pid; self.ppid = ppid; self.command = command }
}

/// Spawn evidence first, then an agent's hook, then its actual process env.
/// A folder default or transcript text is never treated as account evidence.
/// Port of src/main/session-account.ts (macOS rungs; the Windows rung is not built here).
public actor BackendAccountAttribution {
    /// session-account.ts `SessionAccountDeps.pidOf` / `describeSession`: the synchronous lookups
    /// `sessionAccount(sessionID:)` and `establishedAccount(sessionID:)` resolve a session id through.
    public struct Sessions: Sendable {
        public let pidOf: @Sendable (String) -> Int32?
        public let describe: @Sendable (String) -> BackendSessionMeta?
        public init(pidOf: @escaping @Sendable (String) -> Int32?, describe: @escaping @Sendable (String) -> BackendSessionMeta?) {
            self.pidOf = pidOf; self.describe = describe
        }
        /// The production wiring: the PTY manager owns every session's record (which a switch made in
        /// place rewrites through `setAccount`) and its live pid.
        public init(manager: BackendPTYManager) {
            self.init(pidOf: { manager.pidOf($0) }, describe: { id in manager.list().first { $0.id == id } })
        }
    }
    /// Runs `ps` with these arguments and resolves with its stdout; throws the way the bounded run fails
    /// (session-account.ts `exec`).
    public typealias ProcessRunner = @Sendable ([String]) async throws -> String

    /// The sentences, as session-account.ts writes them.
    static let noSession = "That session is not running on this computer, so there is no process to read an account from."
    static let noAgent = "No agent is running in this session, so there is no login to name. Start one and this will say which account it is on."
    static let unreadable = "This session was started outside the app and its account could not be read, so no account is named rather than this computer’s default being shown."
    static let foreignHome = "The agent in this session is running under a different home directory, so its login is one this app has no record of."
    /// session-account.ts PROBE_TTL_MS.
    static let probeLifetime: TimeInterval = 15

    private struct Cached: Sendable { let pid: Int32?; let expires: Date; let value: BackendAccountSessionReading }
    private struct Flight: Sendable { let token: UInt64; let task: Task<BackendAccountSessionReading, Never> }
    private let configuration: BackendAccountConfiguration
    private let profiles: BackendAccountProfileStore
    private let sessions: Sessions?
    private let runPS: ProcessRunner
    private let now: @Sendable () -> Date
    private var hooks: [String: BackendAccountHookEvidence] = [:]
    private var cache: [String: Cached] = [:]
    private var inFlight: [String: Flight] = [:]
    private var flights: UInt64 = 0
    public init(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore, sessions: Sessions? = nil,
                ps: @escaping ProcessRunner = BackendAccountAttribution.boundedPS, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.profiles = profiles; self.sessions = sessions; self.runPS = ps; self.now = now
    }

    /* ---------------------------------------------------------- hook reports -- */

    /// session-account.ts `noteHookEvent`: the latest report wins; a cached probed answer is dropped
    /// only when the evidence actually changed.
    public func recordHook(sessionID: String, evidence: BackendAccountHookEvidence) {
        guard BackendAccountProfile.signInProviders.contains(evidence.provider) else { return }
        let held = hooks[sessionID]
        hooks[sessionID] = evidence
        let changed = held == nil || held?.provider != evidence.provider || held?.environmentWasRead != evidence.environmentWasRead
            || held?.home != evidence.home || held?.configDirectory != evidence.configDirectory
        if changed { dropProbedAnswer(sessionID) }
    }
    /// session-account.ts `dropProbedAnswer`: a spawn answer is this app's own record and no hook's to
    /// move; anything else is forgotten and its in-flight probe detached (not cancelled — its waiters
    /// still get the answer it finds, it just is not cached).
    private func dropProbedAnswer(_ id: String) {
        if let held = cache[id], held.value.reason == nil, held.value.source == "spawn" { return }
        cache[id] = nil; inFlight[id] = nil
    }
    /// session-account.ts `dropSessionAccount(id)`.
    public func drop(sessionID: String) { hooks[sessionID] = nil; cache[sessionID] = nil; inFlight[sessionID] = nil }

    /* ---------------------------------------------------------------- answers -- */

    /// session-account.ts `sessionAccount(id)`, through the configured session lookups.
    public func sessionAccount(sessionID: String) async -> BackendAccountSessionReading {
        guard let sessions else { return .withheld(Self.noSession) }
        return await answer(sessionID: sessionID, session: sessions.describe(sessionID), pid: sessions.pidOf(sessionID))
    }
    /// The same answer for a caller that has already looked the session and its pid up.
    public func read(_ session: BackendSessionMeta, pid: Int32?) async -> BackendAccountSessionReading {
        await answer(sessionID: session.id, session: session, pid: pid)
    }
    /// session-account.ts `establishedAccount`: whatever has already been established, without waiting.
    /// A miss is nil and kicks one probe so the next read has it.
    public func establishedAccount(sessionID: String) -> BackendAccountSessionReading? {
        let pid = sessions?.pidOf(sessionID)
        if let held = cache[sessionID], held.pid == pid, held.expires > now(),
           sessions == nil || Self.stillSpawned(held.value, as: sessions?.describe(sessionID)) {
            return held.value.reason == nil ? held.value : nil
        }
        if sessions != nil { Task { _ = await self.sessionAccount(sessionID: sessionID) } }
        return nil
    }
    /// session-account.ts `establishedConfigDir`: the directory one session's agent is reading, when that
    /// is established and belongs to the agent asked about; nil otherwise, so the caller keeps its fallback.
    public func establishedConfigDir(sessionID: String, provider: String = "claude") -> String? {
        guard let account = establishedAccount(sessionID: sessionID), account.provider == provider else { return nil }
        return account.configDir
    }

    /// session-account.ts `stillSpawnedAs`: a spawn answer stands only while the record still names it,
    /// because a switch made in place keeps the pid and changes the account.
    private static func stillSpawned(_ value: BackendAccountSessionReading, as session: BackendSessionMeta?) -> Bool {
        guard value.reason == nil, value.source == "spawn" else { return true }
        return session != nil && session?.profileId == value.profileId
    }
    private func answer(sessionID: String, session: BackendSessionMeta?, pid: Int32?) async -> BackendAccountSessionReading {
        if let held = cache[sessionID], held.pid == pid, held.expires > now(), Self.stillSpawned(held.value, as: session) { return held.value }
        if let running = inFlight[sessionID] { return await running.task.value }
        flights &+= 1
        let token = flights
        let work = Task { () -> BackendAccountSessionReading in
            let value = await self.establish(sessionID: sessionID, session: session, pid: pid)
            await self.settle(sessionID, token: token, pid: pid, value: value)
            return value
        }
        inFlight[sessionID] = Flight(token: token, task: work)
        return await work.value
    }
    /// Cached only while this is still the registered probe: evidence that arrived mid-flight detached it.
    private func settle(_ id: String, token: UInt64, pid: Int32?, value: BackendAccountSessionReading) {
        guard inFlight[id]?.token == token else { return }
        let spawn = value.reason == nil && value.source == "spawn"
        cache[id] = Cached(pid: pid, expires: spawn ? .distantFuture : now().addingTimeInterval(Self.probeLifetime), value: value)
        inFlight[id] = nil
    }
    private func establish(sessionID: String, session: BackendSessionMeta?, pid: Int32?) async -> BackendAccountSessionReading {
        guard let session else { return .withheld(Self.noSession) }
        if let spawned = await fromSpawn(session) { return spawned }
        if let reported = await fromHook(sessionID) { return reported }
        guard let pid, pid > 0 else { return .withheld(Self.noSession) }
        return await fromProcess(pid)
    }

    /* ------------------------------------------------------------------ rungs -- */

    private func fromSpawn(_ session: BackendSessionMeta) async -> BackendAccountSessionReading? {
        guard ["claude", "codex"].contains(session.provider), let id = session.profileId,
              let profile = try? await profiles.find(id), profile.provider == session.provider else { return nil }
        return await known(provider: session.provider, directory: profile.configDir, source: "spawn", profile: (profile.id, profile.name))
    }
    private func fromHook(_ sessionID: String) async -> BackendAccountSessionReading? {
        guard let hook = hooks[sessionID] else { return nil }
        if let directory = hook.configDirectory { return await known(provider: hook.provider, directory: directory, source: "hook") }
        // An absence is believed only when the environment provably arrived.
        guard hook.environmentWasRead else { return nil }
        if let home = hook.home, URL(fileURLWithPath: home).standardizedFileURL.path != configuration.homeDirectory.path {
            return .withheld(Self.foreignHome)
        }
        return await known(provider: hook.provider, directory: configuration.systemDirectory(hook.provider, environment: [:]), source: "hook")
    }
    private func fromProcess(_ pid: Int32) async -> BackendAccountSessionReading {
        let agents = BackendAccountProfile.signInProviders   // catalog bins are the provider ids
        let table: [BackendAccountProcessRow]
        do { table = Self.parseProcessTable(try await runPS(["-Ao", "pid=,ppid=,command="])) } catch { return .withheld(Self.unreadable) }
        guard let agent = Self.agentUnder(table, root: pid, binaries: agents) else { return .withheld(Self.noAgent) }
        guard let provider = agents.first(where: { $0 == Self.basename(Self.firstWord(agent.command)) }) else { return .withheld(Self.noAgent) }
        let dump: String
        do { dump = try await runPS(["eww", "-p", String(agent.pid)]) } catch { return .withheld(Self.unreadable) }
        // The environment has to have actually arrived before its absences mean anything (SIP scrub).
        guard Self.environmentWasRead(dump) else { return .withheld(Self.unreadable) }
        if let key = BackendAccountProfile.configEnvironment(provider), let declared = Self.environmentValue(dump, name: key) {
            return await known(provider: provider, directory: declared, source: "process")
        }
        if let home = Self.environmentValue(dump, name: "HOME"), URL(fileURLWithPath: home).standardizedFileURL.path != configuration.homeDirectory.path {
            return .withheld(Self.foreignHome)
        }
        // The agent's own default store, asked with an empty environment — not this app's inherited one.
        return await known(provider: provider, directory: configuration.systemDirectory(provider, environment: [:]), source: "process")
    }
    /// The profile record is the spawn's own when given; otherwise looked up by directory
    /// (session-account.ts `profileForDir`, the system profile first).
    private func known(provider: String, directory: String, source: String, profile: (id: String, name: String)? = nil) async -> BackendAccountSessionReading {
        guard directory.hasPrefix("/"), !directory.contains("\0") else { return .withheld("The agent reported a relative or invalid account directory, so its login cannot be named safely.") }
        let resolved = URL(fileURLWithPath: directory).standardizedFileURL.path
        let named: (id: String, name: String)?
        if let profile { named = profile }
        else { named = (try? await profiles.list(provider: provider))?.first { URL(fileURLWithPath: $0.configDir).standardizedFileURL.path == resolved }.map { ($0.id, $0.name) } }
        let email = provider == "claude" ? await accountEmail(directory: resolved) : nil
        return BackendAccountSessionReading(provider: provider, configDir: directory, profileId: named?.id, profileName: named?.name, source: source, email: email, reason: nil)
    }
    private func accountEmail(directory: String) async -> String? {
        let home = configuration.homeDirectory
        let candidates = directory == home.appendingPathComponent(".claude").path
            ? [home.appendingPathComponent(".claude.json"), URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")]
            : [URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")]
        return await Task.detached(priority: .utility) {
            for candidate in candidates {
                if let data = try? BackendAccountFiles.boundedRead(candidate, maximum: 4 * 1024 * 1024),
                   let raw = try? NativeRPCValue.parseJSON(data), let email = raw["oauthAccount"]["emailAddress"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { return email }
            }
            return nil
        }.value
    }

    /* --------------------------------------------------------- process table -- */

    /// session-account.ts `parseProcessTable`: every line shaped `pid ppid command`; anything else skipped.
    public static func parseProcessTable(_ stdout: String) -> [BackendAccountProcessRow] {
        let row = try! NSRegularExpression(pattern: #"^\s*([0-9]+)\s+([0-9]+)\s+(.*)$"#)
        var rows: [BackendAccountProcessRow] = []
        for line in stdout.components(separatedBy: "\n") {
            guard let match = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let pidRange = Range(match.range(at: 1), in: line), let parentRange = Range(match.range(at: 2), in: line),
                  let commandRange = Range(match.range(at: 3), in: line),
                  let pid = Int32(line[pidRange]), let parent = Int32(line[parentRange]) else { continue }
            rows.append(.init(pid: pid, ppid: parent, command: String(line[commandRange])))
        }
        return rows
    }
    /// session-account.ts `agentUnder`: the first descendant of `root` running one of `binaries`,
    /// breadth-first, matched on the basename of the command's first word.
    public static func agentUnder(_ rows: [BackendAccountProcessRow], root: Int32, binaries: [String]) -> BackendAccountProcessRow? {
        let wanted = Set(binaries)
        var children: [Int32: [BackendAccountProcessRow]] = [:]
        for row in rows { children[row.ppid, default: []].append(row) }
        var queue = children[root] ?? [], seen: Set<Int32> = [root], cursor = 0
        while cursor < queue.count {
            let row = queue[cursor]; cursor += 1
            guard seen.insert(row.pid).inserted else { continue }
            if wanted.contains(basename(firstWord(row.command))) { return row }
            queue.append(contentsOf: children[row.pid] ?? [])
        }
        return nil
    }
    static func firstWord(_ command: String) -> String {
        String(command.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first ?? "")
    }
    /// Node's POSIX `path.basename`: trailing slashes ignored, `/` alone has no basename.
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return "" }
        return String(trimmed.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }

    /* ----------------------------------------------------------- environment -- */

    public static func environmentValue(_ output: String, name: String) -> String? {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        let regex = try! NSRegularExpression(pattern: "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "=")
        guard let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range, in: output) else { return nil }
        let remaining = String(output[range.upperBound...])
        let boundary = try! NSRegularExpression(pattern: #"\s[A-Za-z_][A-Za-z0-9_]*="#)
        let end = boundary.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)).flatMap { Range($0.range, in: remaining)?.lowerBound } ?? remaining.endIndex
        let value = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    /// session-account.ts `environmentWasRead`: did `ps eww` print an environment, or only a command
    /// line (a SIP-scrubbed binary)? `PATH` is the probe.
    public static func environmentWasRead(_ output: String) -> Bool { environmentValue(output, name: "PATH") != nil }

    /// The production `ps`: bounded to four seconds and 8 MiB, like session-account.ts `shell`.
    public static func boundedPS(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let child = Process(), output = Pipe(), errors = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/ps"); child.arguments = arguments
            child.standardOutput = output; child.standardError = errors
            try child.run()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 4); timer.setEventHandler { if child.isRunning { child.terminate() } }; timer.resume()
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard data.count + chunk.count <= 8 * 1024 * 1024 else { child.terminate(); timer.cancel(); throw BackendAccountFailure("The bounded process-account probe exceeded its output limit.") }
                data.append(chunk)
            }
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit(); timer.cancel()
            guard child.terminationStatus == 0, data.count <= 8 * 1024 * 1024 else { throw BackendAccountFailure("The bounded process-account probe was unavailable.") }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
