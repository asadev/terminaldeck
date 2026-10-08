import Foundation
import CryptoKit
import TerminalDeckNativeCore

public enum BackendStaysFixedWhere {
    public static let configNames = ["staysfixed.config.js", "staysfixed.config.mjs", "staysfixed.config.json", ".staysfixed/config.js", ".staysfixed/config.mjs", ".staysfixed/config.json"]
    public static func config(_ root: String) -> String? { configNames.first { FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent($0).path) } }
    public static func root(_ cwd: String, home: String?) -> String? {
        var folder = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<12 {
            if config(folder.path) != nil { return folder.path }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) || folder.path == home { return nil }
            let up = folder.deletingLastPathComponent(); if up == folder { return nil }; folder = up
        }
        return nil
    }
    public static func git(_ root: String) -> Bool {
        var folder = URL(fileURLWithPath: root).standardizedFileURL
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            let up = folder.deletingLastPathComponent(); if up == folder { return false }; folder = up
        }
        return false
    }
    public static func folder(_ value: NativeRPCValue) throws -> String {
        guard let path = value.string, path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("That is not a project folder.") }
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &directory), directory.boolValue else { throw NativeRPCError.invalidArguments("That project folder is not there any more.") }
        return root
    }
}

/// Same instance is shared by the page, fixed tools and launch definition factory.
public actor BackendStaysFixedService {
    public typealias DriverFactory = @Sendable (BackendStaysFixedEngineHome, String, String?, String, [String: String]) -> any BackendStaysFixedEngineRunning
    private let userData: URL, home: String, executable: String?, inherited: [String: String]
    private let locate: @Sendable () throws -> BackendStaysFixedEngineHome
    private let loginPath: @Sendable () async throws -> String
    private let changed: @Sendable (String) async -> Void, now: @Sendable () -> Double, factory: DriverFactory
    private let checkJoined: @Sendable (String, String) async -> Void
    private var preferences: NativeRPCValue?
    private var runner: (any BackendStaysFixedEngineRunning)?, pathCache: String?
    /// D2: Stays Fixed's own on-demand Node (nil = transitional bundled Node).
    private let provisioning: (any BackendStaysFixedProvisioning)?
    private var runnerNode: String?
    private struct Running { let id: UUID, task: Task<NativeRPCValue, any Error>; var progress: NativeRPCValue }
    private var running: [String: Running] = [:], ownLast: [String: NativeRPCValue] = [:]
    private var readinessCache: [String: (Double, NativeRPCValue)] = [:], describeCache: [String: (Double, NativeRPCValue)] = [:]
    private var resultsCache: [String: (String, NativeRPCValue)] = [:]
    public init(userData: URL, home: String, executable: String?, inheritedEnvironment: [String: String],
                locate: @escaping @Sendable () throws -> BackendStaysFixedEngineHome,
                loginPath: @escaping @Sendable () async throws -> String,
                changed: @escaping @Sendable (String) async -> Void = { _ in },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                driverFactory: @escaping DriverFactory = { BackendStaysFixedEngine(home: $0, executable: $1, shim: $2, path: $3, environment: $4) },
                checkJoined: @escaping @Sendable (String, String) async -> Void = { _, _ in },
                provisioning: (any BackendStaysFixedProvisioning)? = nil) {
        self.userData = userData; self.home = home; self.executable = executable; inherited = inheritedEnvironment
        self.locate = locate; self.loginPath = loginPath; self.changed = changed; self.now = now; factory = driverFactory
        self.checkJoined = checkJoined; self.provisioning = provisioning
    }
    private func normalize(_ root: String) -> String { URL(fileURLWithPath: root).standardizedFileURL.path }
    private var base: URL { userData.appendingPathComponent("staysfixed", isDirectory: true) }
    private func prefs() -> NativeRPCValue {
        if let preferences { return preferences }
        let raw = (try? Data(contentsOf: userData.appendingPathComponent("staysfixed.json"))).flatMap { try? NativeRPCValue.parseJSON($0) }
        let value = BackendStaysFixedRead.object([("version", .number(1)), ("projects", raw?["projects"].fields != nil ? raw!["projects"] : .object([]))])
        preferences = value; return value
    }
    private func agentsOn(_ root: String, setup: Bool) -> Bool { setup && (prefs()["projects"][root]["agents"].bool ?? true) }
    /// `download: false` (status rows) never fetches; Set up/Check/agents do.
    private func engine(download: Bool = true) async throws -> any BackendStaysFixedEngineRunning {
        if let runner { return runner }
        let found: BackendStaysFixedEngineHome, node: String
        if let provisioning {
            let install: BackendNodelessStaysFixedInstall
            if download { install = try await provisioning.prepare() }
            else if let ready = await provisioning.installed() { install = ready }
            else { throw BackendStaysFixedNotDownloaded(note: provisioning.pendingNote) }
            found = try install.engineHome(); node = install.node.path
        } else {
            found = try locate()
            guard let executable else { throw NativeRPCError(code: "unavailable", message: "The Stays Fixed Node runtime is unavailable in this build.") }
            node = executable
        }
        if let runner { return runner } // another caller finished while this one awaited
        let shim = BackendStaysFixedEngineFiles.ensureShim(base.appendingPathComponent("bin"), executable: node)
        if pathCache == nil { pathCache = try await loginPath() }
        if let runner { return runner }
        let driver = factory(found, node, shim, pathCache ?? "", inherited); runner = driver; runnerNode = node; return driver
    }
    public func status(_ project: String) async -> NativeRPCValue {
        let root = normalize(project), config = BackendStaysFixedWhere.config(root), setup = config != nil
        var unavailable: String?, version = "", description = BackendStaysFixedRead.description(.object([]))
        do {
            let driver = try await engine(download: false); version = driver.home.versionNote
            if setup { description = await describe(root, driver: driver) }
        } catch let pending as BackendStaysFixedNotDownloaded { version = pending.note } // still usable: Set up/Check download it
        catch { unavailable = error.localizedDescription }
        return BackendStaysFixedRead.object([("projectPath", .string(root)), ("available", .bool(unavailable == nil)), ("unavailable", BackendStaysFixedRead.nullable(unavailable)), ("versionNote", .string(version)), ("setUp", .bool(setup)), ("configFile", BackendStaysFixedRead.nullable(config)), ("git", .bool(BackendStaysFixedWhere.git(root))), ("agents", .bool(agentsOn(root, setup: setup))), ("guards", description["guards"]), ("guardProblem", description["guardProblem"]), ("reference", description["reference"]), ("last", setup ? results(root) : .null), ("running", progress(root))])
    }
    private func describe(_ root: String, driver: any BackendStaysFixedEngineRunning) async -> NativeRPCValue {
        if let cached = describeCache[root], now() - cached.0 < 30_000 { return cached.1 }
        let result = await driver.script(BackendStaysFixedScripts.describe, args: [root], cwd: root, timeout: 30_000, keep: nil, onEvent: { _ in })
        let value = BackendStaysFixedRead.description(BackendStaysFixedEngineFiles.lastJSON(result.stdout) ?? .null)
        describeCache[root] = (now(), value); return value
    }
    public func readiness(_ project: String, refresh: Bool = false) async throws -> NativeRPCValue {
        let root = normalize(project)
        if !refresh, let cached = readinessCache[root], now() - cached.0 < 600_000 { return cached.1 }
        // D2: the screen loads this on open, which must never download the runtime;
        // only the person's "Look again" (refresh), Set up and Check fetch it.
        let driver = try await engine(download: refresh), setup = BackendStaysFixedWhere.config(root) != nil
        let result = await driver.cli(setup ? ["init", "--dry-run", "--json"] : ["doctor", "--json"], cwd: root, timeout: 120_000, keep: nil, onEvent: { _ in })
        guard let raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout) else { throw NativeRPCError(code: "failed", message: failure(result, "looking at what Stays Fixed can check here")) }
        var value = BackendStaysFixedRead.readiness(raw, plan: setup)
        if setup { value = value.setting("git", .bool(BackendStaysFixedWhere.git(root))) }; readinessCache[root] = (now(), value); return value
    }
    public func setup(_ project: String) async throws -> NativeRPCValue {
        let root = normalize(project), driver = try await engine()
        let result = await driver.cli(["init", "--json", "--offline"], cwd: root, timeout: 120_000, keep: nil, onEvent: { _ in })
        let raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout)
        let failed = result.cancelled || result.timedOut || result.code != 0 || raw?["ok"].bool != true
        // Keep partial written-file evidence, but never turn failed execution or
        // error JSON into a success-shaped setup answer.
        let normalized = failed ? (raw ?? .object([])).setting("ok", .bool(false)) : raw!
        let outcome = BackendStaysFixedRead.setup(normalized, roots: [root, BackendPluginsFiles.real(root)],
            failure: failed ? failure(result, "setting up") : nil)
        readinessCache[root] = nil; describeCache[root] = nil
        if !outcome["readiness"].isNullish { readinessCache[root] = (now(), outcome["readiness"].setting("git", .bool(BackendStaysFixedWhere.git(root)))) }
        await changed(root); return outcome
    }
    public func progress(_ project: String) -> NativeRPCValue { running[normalize(project)]?.progress ?? .null }
    public func check(_ project: String, by: String) async throws -> NativeRPCValue {
        let root = normalize(project)
        if let going = running[root] { await checkJoined(root, by); return try await going.task.value }
        guard BackendStaysFixedWhere.config(root) != nil else { throw NativeRPCError(code: "not-set-up", message: "This project is not set up for Stays Fixed yet. Set it up first.") }
        let id = UUID(), startedAt = now()
        let task = Task {
            do { let driver = try await self.engine(); let result = await self.runCheck(root, id: id, driver: driver, startedAt: startedAt); await self.finish(root, id: id); return result }
            catch { await self.finish(root, id: id); throw error }
        }
        running[root] = Running(id: id, task: task, progress: BackendStaysFixedRead.object([("startedAt", .number(startedAt)), ("step", .string("Starting the check.")), ("steps", .number(0)), ("by", .string(by))]))
        await changed(root); return try await task.value
    }
    private func finish(_ root: String, id: UUID) async { if running[root]?.id == id { running[root] = nil }; describeCache[root] = nil; await changed(root) }
    private func step(_ root: String, id: UUID, _ event: NativeRPCValue) async {
        guard running[root]?.id == id else { return }
        var progress = running[root]!.progress
        if let message = event["message"].string, !message.isEmpty { progress = progress.setting("step", .string(message)) }
        progress = progress.setting("steps", .number((progress["steps"].number ?? 0) + 1)); running[root]?.progress = progress; await changed(root)
    }
    private func runCheck(_ root: String, id: UUID, driver: any BackendStaysFixedEngineRunning, startedAt: Double) async -> NativeRPCValue {
        let pictures = picturesRoot(root), pending = pictures.appendingPathComponent("pending-" + BackendStaysFixedRead.format(now()))
        let event: @Sendable (NativeRPCValue) -> Void = { [weak self] event in Task { await self?.step(root, id: id, event) } }
        var result = await driver.script(BackendStaysFixedScripts.check, args: [root, "stored"], cwd: root, timeout: 1_200_000, keep: pending.path, onEvent: event)
        var raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout)
        if raw?["unsupported"].string != nil && !result.cancelled {
            if var progress = running[root]?.progress { progress = progress.setting("step", .string("Checking.")); running[root]?.progress = progress }
            result = await driver.cli(["check", "--json"], cwd: root, timeout: 1_200_000, keep: pending.path, onEvent: event); raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout)
        }
        if raw == nil || result.cancelled || result.timedOut {
            try? FileManager.default.removeItem(at: pending)
            let shown = BackendStaysFixedRead.results(BackendStaysFixedRead.object([("error", BackendStaysFixedRead.object([("message", .string(failure(result, "the check")))]))]), at: iso(startedAt)).setting("pictures", .object([]))
            ownLast[root] = shown; return shown
        }
        let output = BackendStaysFixedRead.results(raw!), runID = output["runId"].string ?? ""
        if validRunID(runID), FileManager.default.fileExists(atPath: pending.path) {
            let target = pictures.appendingPathComponent(runID); try? FileManager.default.removeItem(at: target); try? FileManager.default.moveItem(at: pending, to: target)
        } else { try? FileManager.default.removeItem(at: pending) }
        prune(pictures); resultsCache[root] = nil
        let shown = withPictures(root, value: output, raw: raw!)
        ownLast[root] = shown["verdict"].string == "could-not-run" ? shown : nil; return shown
    }
    public func stop(_ project: String) async -> Bool {
        let root = normalize(project); guard var going = running[root] else { return false }
        going.progress = going.progress.setting("step", .string("Stopping.")); running[root] = going; going.task.cancel(); await changed(root); return true
    }
    public func waitFor(_ project: String, milliseconds: Int) async -> NativeRPCValue {
        if let going = running[normalize(project)], milliseconds > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let gate = BackendStaysFixedWaitGate(continuation)
                let finish = Task { _ = try? await going.task.value; gate.finish() }
                let deadline = Task { do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }; gate.finish(); finish.cancel() }
                gate.onFinish { deadline.cancel() }
            }
        }
        return results(project)
    }
    public func results(_ project: String, full: Bool = false) -> NativeRPCValue {
        let root = normalize(project), file = URL(fileURLWithPath: root).appendingPathComponent(".staysfixed/v2/last-check.json")
        var disk = NativeRPCValue.null
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let date = attrs[.modificationDate] as? Date {
            let stamp = String(date.timeIntervalSince1970) + (full ? ":full" : ":short")
            if let cache = resultsCache[root], cache.0 == stamp { disk = cache.1 }
            else if let bytes = try? String(contentsOf: file, encoding: .utf8), let (value, raw) = BackendStaysFixedRead.lastRun(bytes, full: full) { disk = withPictures(root, value: value, raw: raw); resultsCache[root] = (stamp, disk) }
        }
        if let own = ownLast[root], disk.isNullish || ((StaysFixedRules.parse(own["at"].string ?? "") ?? -.infinity) >= (StaysFixedRules.parse(disk["at"].string ?? "") ?? .infinity)) { return own }
        return disk
    }
    private func validRunID(_ id: String) -> Bool { !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.contains("\0") }
    private func picturesRoot(_ root: String) -> URL {
        let slug = BackendPluginsFiles.digest(Data(normalize(root).utf8)).prefix(16); return base.appendingPathComponent("pictures/" + slug)
    }
    private func withPictures(_ root: String, value: NativeRPCValue, raw: NativeRPCValue) -> NativeRPCValue {
        let runID = value["runId"].string ?? ""; var pictures = NativeRPCValue.object([])
        if validRunID(runID) {
            let folder = picturesRoot(root).appendingPathComponent(runID), files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for difference in BackendStaysFixedRead.list(value["differences"]) {
                let found = BackendStaysFixedRead.pictures(difference, files: files, candidate: raw["candidate"]["id"].string ?? "", reference: raw["reference"]["id"].string.flatMap { $0.isEmpty ? nil : $0 }).map { journey, before, after in
                    BackendStaysFixedRead.object([("journey", .string(journey)), ("before", picture(before.map { folder.appendingPathComponent($0) })), ("after", picture(after.map { folder.appendingPathComponent($0) }))])
                }.filter { !$0["before"].isNullish || !$0["after"].isNullish }
                if !found.isEmpty { pictures = pictures.setting(difference["id"].string ?? "", .array(found)) }
            }
        }
        return value.setting("pictures", pictures)
    }
    private func picture(_ file: URL?) -> NativeRPCValue {
        guard let file, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let size = attrs[.size] as? NSNumber, size.intValue <= 3 * 1024 * 1024, let data = try? Data(contentsOf: file) else { return .null }
        return .string("data:image/png;base64," + data.base64EncodedString())
    }
    private func prune(_ folder: URL) {
        let runs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { !$0.lastPathComponent.hasPrefix("pending-") }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in runs.dropFirst(3) { try? FileManager.default.removeItem(at: file) }
    }
    public func markGood(_ project: String, anyway: Bool) async throws -> NativeRPCValue {
        let root = normalize(project), driver = try await engine()
        if running[root] != nil { return BackendStaysFixedRead.object([("ok", .bool(false)), ("marked", .bool(false)), ("already", .bool(false)), ("refused", .null), ("refusedFor", .null), ("summary", .string("A check is running. Mark the build as good once it has finished."))]) }
        if let refusal = BackendSFXReferenceGuard.refusal(root) { return refusal }
        func ask(_ force: Bool) async -> NativeRPCValue {
            let result = await driver.cli(["ship", "--why", "Marked as good in Terminal Deck", "--json"] + (force ? ["--force"] : []), cwd: root, timeout: 60_000, keep: nil, onEvent: { _ in })
            let raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout); return BackendStaysFixedRead.mark(raw ?? .object([]), failure: raw == nil ? failure(result, "marking the build as good") : nil)
        }
        var outcome = await ask(false); if anyway && outcome["refusedFor"].string == "differences" { outcome = await ask(true) }
        describeCache[root] = nil; await changed(root); return outcome
    }
    public func setAgents(_ project: String, on: Bool) async throws -> NativeRPCValue {
        let root = normalize(project), value = prefs(), projects = value["projects"].setting(root, value["projects"][root].merging(BackendStaysFixedRead.object([("agents", .bool(on))])))
        let next = value.setting("projects", projects); var data = try next.encodedJSON(pretty: true); data.append(10)
        try BackendAccountFiles.writeAtomic(data, to: userData.appendingPathComponent("staysfixed.json")); preferences = next; await changed(root); return await status(root)
    }
    public func projectSource() throws -> BackendStaysFixedProjectSource {
        try BackendStaysFixedProjectSource(userData: userData, home: home, readiness: .ready) { [weak self] root, _, path in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Stays Fixed is unavailable.") }; return try await self.serverDefinition(root, path: path)
        }
    }
    private func serverDefinition(_ root: String, path: String) async throws -> BackendProjectMCPDefinition {
        let driver = try await engine(); guard let executable = runnerNode ?? self.executable else { throw NativeRPCError(code: "unavailable", message: "The Stays Fixed Node runtime is unavailable in this build.") }
        let shim = BackendStaysFixedEngineFiles.ensureShim(base.appendingPathComponent("bin"), executable: executable)
        var env = ["ELECTRON_RUN_AS_NODE": "1"]
        if let shim { env["TD_SF_EXEC_PATH"] = shim }
        let path = [path, shim.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ""].filter { !$0.isEmpty }.joined(separator: ":")
        if !path.isEmpty { env["PATH"] = path }
        let server = try BackendProjectMCPServerSpec(name: "staysfixed", command: executable, arguments: ["--import", BackendStaysFixedScripts.preloadURL, driver.home.bin.path, "mcp", "--cwd", root], environment: env, implementation: .suppliedSourceBridge)
        return .stdio(root: root, server: server)
    }
    public func dispose() { for going in running.values { going.task.cancel() } }
    private func failure(_ result: BackendStaysFixedRunResult, _ what: String) -> String {
        if result.cancelled { return "You stopped \(what)." }
        let capital = what.prefix(1).uppercased() + what.dropFirst()
        if result.timedOut { return "\(capital) took too long and was stopped." }
        let said = result.stderr.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.suffix(4).joined(separator: " ")
        return said.isEmpty ? "\(capital) did not finish." : said
    }
    private func iso(_ ms: Double) -> String { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.string(from: Date(timeIntervalSince1970: ms / 1000)) }
}

private final class BackendStaysFixedWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var callback: (@Sendable () -> Void)?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func onFinish(_ callback: @escaping @Sendable () -> Void) {
        let done = lock.withLock { if continuation == nil { return true }; self.callback = callback; return false }; if done { callback() }
    }
    func finish() {
        let result = lock.withLock { let result = (continuation, callback); continuation = nil; callback = nil; return result }; result.0?.resume(); result.1?()
    }
}
