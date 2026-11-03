import Foundation
import TerminalDeckNativeCore

/// Named remote runs over the Deck remote worker protocol (see RemoteWorkerContract).
/// A remote run is NOT a terminal session: it has no PTY, session ID or conversation ID, and
/// local terminal sessions are untouched. Records are written before anything is sent, so a
/// lost answer stays "not known whether started" and is reconciled by its saved request ID,
/// never by sending a second Start.
public actor BackendRemoteWorkers {
    public typealias Sleep = @Sendable (UInt64) async throws -> Void
    public static let maxActivePerConnection = 8
    public static let maxRuns = 200
    public static let maxConnections = 20

    private let directory: URL
    private let transport: any BackendRemoteWorkerTransport
    private let secrets: any BackendConnectedTasksSecrets
    private let now: @Sendable () -> Date
    private let newID: @Sendable () -> String
    private let sleep: Sleep
    private let baseDelay: UInt64
    private let maxDelay: UInt64
    private var connectionsByID: [String: RemoteWorkerConnection] = [:]
    private var order: [String] = []
    private var runList: [RemoteWorkerRun] = []
    private var busy: Set<String> = []
    private var observer: Task<Void, Never>?
    /// Where the next read-back of active runs starts (#506).
    private var tickCursor = 0
    private var changed: (@Sendable () async -> Void)?
    private var loaded = false

    public init(root: URL, transport: any BackendRemoteWorkerTransport, secrets: any BackendConnectedTasksSecrets,
                now: @escaping @Sendable () -> Date = { Date() }, newID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) },
                baseDelaySeconds: Double = 5, maxDelaySeconds: Double = 60) {
        directory = root.appendingPathComponent("remote-workers", isDirectory: true)
        self.transport = transport; self.secrets = secrets; self.now = now; self.newID = newID; self.sleep = sleep
        baseDelay = UInt64(baseDelaySeconds * 1_000_000_000); maxDelay = UInt64(maxDelaySeconds * 1_000_000_000)
    }

    public func onChange(_ callback: @escaping @Sendable () async -> Void) { changed = callback }

    // MARK: Persistence (owner-only files, atomic, written before any request)

    private struct ConnectionFile: Codable { var connections: [RemoteWorkerConnection] }
    private struct RunFile: Codable { var runs: [RemoteWorkerRun] }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: directory.appendingPathComponent("connections.json")), let file = try? Self.decoder.decode(ConnectionFile.self, from: data) {
            for connection in file.connections where connectionsByID[connection.id] == nil { connectionsByID[connection.id] = connection; order.append(connection.id) }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("runs.json")), let file = try? Self.decoder.decode(RunFile.self, from: data) {
            runList = file.runs
        }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        try Self.encoder.encode(value).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func saveConnections() throws { try write(ConnectionFile(connections: order.compactMap { connectionsByID[$0] }), "connections.json") }
    private func saveRuns() throws {
        if runList.count > Self.maxRuns {
            var excess = runList.count - Self.maxRuns
            runList.removeAll { run in if excess > 0, run.state.isTerminal { excess -= 1; return true }; return false }
        }
        try write(RunFile(runs: runList), "runs.json")
    }
    private func notify() async { await changed?() }

    // MARK: Reading

    public func connections() -> [RemoteWorkerConnection] { load(); return order.compactMap { connectionsByID[$0] } }
    public func connection(_ id: String) throws -> RemoteWorkerConnection {
        load()
        guard let connection = connectionsByID[id] else { throw RemoteWorkerFailure("There is no remote worker connection called “\(id)”.") }
        return connection
    }
    public func hasCredential(_ id: String) -> Bool { ((try? secrets.read(id)) ?? nil) != nil }
    public func runs(connection: String? = nil) -> [RemoteWorkerRun] { load(); return runList.filter { connection == nil || $0.connectionID == connection }.reversed() }
    public func run(_ id: String) throws -> RemoteWorkerRun {
        load()
        guard let run = runList.first(where: { $0.id == id }) else { throw RemoteWorkerFailure("There is no remote run called “\(id)”.") }
        return run
    }

    // MARK: Connections and credentials

    @discardableResult
    public func saveConnection(id: String?, label: String, baseURL: String, profile: String?) throws -> RemoteWorkerConnection {
        load()
        let url = try RemoteWorkerContract.normalizedBase(baseURL)
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= RemoteWorkerContract.maxLabel else { throw RemoteWorkerFailure("Give the connection a short name (up to \(RemoteWorkerContract.maxLabel) characters).") }
        if let profile, !profile.isEmpty { guard profile.utf8.count <= 200 else { throw RemoteWorkerFailure("That agent name is too long.") } }
        let owner = (profile?.isEmpty ?? true) ? nil : profile
        if let id {
            var existing = try connection(id)
            if existing.baseURL != url.absoluteString {
                // Review paperclip #3: a new address would leave its runs uncontrollable for good.
                guard !runList.contains(where: { $0.connectionID == id && $0.state.isActive }) else {
                    throw RemoteWorkerFailure("This worker still has runs in progress. Stop or abandon them, or wait until they finish, before changing its address.")
                }
                existing.revision += 1; existing.lastCheck = nil
            }
            existing.label = name; existing.baseURL = url.absoluteString; existing.profile = owner
            connectionsByID[id] = existing
            try saveConnections()
            return existing
        }
        guard connectionsByID.count < Self.maxConnections else { throw RemoteWorkerFailure("There are already \(Self.maxConnections) remote worker connections. Remove one first.") }
        let created = RemoteWorkerConnection(id: "rwc-" + newID().prefix(12), label: name, baseURL: url.absoluteString, profile: owner, revision: 1)
        connectionsByID[created.id] = created; order.append(created.id)
        try saveConnections()
        return created
    }

    public func removeConnection(_ id: String) throws {
        _ = try connection(id)
        guard !runList.contains(where: { $0.connectionID == id && $0.state.isActive }) else {
            throw RemoteWorkerFailure("This worker still has runs in progress. Stop them or wait until they finish, then remove the connection.")
        }
        try secrets.remove(id)
        connectionsByID[id] = nil; order.removeAll { $0 == id }
        try saveConnections()
    }

    public func setCredential(_ id: String, token: String) throws {
        _ = try connection(id)
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 4096, !clean.contains(where: { $0.isNewline }) else { throw RemoteWorkerFailure("Paste the worker's access token on one line.") }
        try secrets.write(id, token: clean)
    }
    public func removeCredential(_ id: String) throws { _ = try connection(id); try secrets.remove(id) }

    // MARK: HTTP

    private enum Outcome { case answer(status: Int, json: [String: Any]), lost(String) }

    private static func lostText(_ failure: BackendRemoteWorkerTransportFailure) -> String {
        switch failure {
        case .timeout: "the worker did not answer in time"
        case .unreachable: "the worker could not be reached"
        case .tooLarge: "the worker's answer was too large"
        case .secureConnection: "the secure connection to the worker failed"
        }
    }

    private func call(_ connection: RemoteWorkerConnection, endpoint: String, method: String, path: String, body: [String: Any]? = nil, idempotency: String? = nil) async -> Outcome {
        guard let url = URL(string: endpoint + path) else { return .lost("the worker address is not valid") }
        var headers = ["Accept": "application/json", "User-Agent": "TerminalDeck-RemoteWorker/1"]
        // The token is read here, once, only to build this request. It never enters a record, prompt or error.
        if let token = (try? secrets.read(connection.id)) ?? nil { headers["Authorization"] = "Bearer " + token }
        var data: Data?
        if let body, let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) { data = encoded; headers["Content-Type"] = "application/json" }
        if let idempotency { headers["Idempotency-Key"] = idempotency }
        do {
            let response = try await transport.send(method: method, url: url, headers: headers, body: data, timeoutMilliseconds: 20_000)
            let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
            return .answer(status: response.status, json: json)
        } catch let failure as BackendRemoteWorkerTransportFailure { return .lost(Self.lostText(failure)) }
        catch { return .lost("the worker could not be reached") }
    }

    private static func refusal(_ status: Int) -> String {
        switch status {
        case 401, 403: "The worker refused the access token (HTTP \(status))."
        case 300..<400: "The worker tried to send the request somewhere else. That is refused."
        case 400..<500: "The worker refused the request (HTTP \(status))."
        default: "The worker had a problem (HTTP \(status))."
        }
    }

    // MARK: Check

    @discardableResult
    public func check(_ id: String) async throws -> RemoteWorkerCheck {
        let target = try connection(id)
        let outcome = await call(target, endpoint: target.baseURL, method: "GET", path: "/v1/capabilities")
        var result: RemoteWorkerCheck
        switch outcome {
        case .lost(let why): result = .init(at: now(), ok: false, capabilities: nil, error: "Not connected: " + why + ".")
        case .answer(let status, let json):
            if (200..<300).contains(status) {
                do { result = .init(at: now(), ok: true, capabilities: try RemoteWorkerCapabilities.decode(json), error: nil) }
                catch { result = .init(at: now(), ok: false, capabilities: nil, error: (error as? RemoteWorkerFailure)?.message ?? "The server's answer was not understood.") }
            } else { result = .init(at: now(), ok: false, capabilities: nil, error: Self.refusal(status)) }
        }
        // Keep only if the connection still has the same address (it may have been edited while waiting).
        if var current = connectionsByID[id], current.revision == target.revision { current.lastCheck = result; connectionsByID[id] = current; try saveConnections() }
        await notify()
        return result
    }

    // MARK: Start

    public func start(connectionID: String, prompt: String, model: String? = nil, workspace: String? = nil) async throws -> RemoteWorkerRun {
        var target = try connection(connectionID)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteWorkerFailure("Write what the remote worker should do.") }
        guard text.utf8.count <= RemoteWorkerContract.maxPromptBytes else { throw RemoteWorkerFailure("That request is too long for a remote run (limit \(RemoteWorkerContract.maxPromptBytes / 1024) KB).") }
        if let workspace, !workspace.isEmpty, !RemoteWorkerContract.validID(workspace) { throw RemoteWorkerFailure("The remote workspace name can only use letters, numbers, dots, dashes and underscores.") }
        if target.lastCheck?.ok != true { _ = try? await check(connectionID); target = try connection(connectionID) }
        guard let caps = target.lastCheck?.capabilities, target.lastCheck?.ok == true else {
            throw RemoteWorkerFailure(target.lastCheck?.error ?? "Check the connection first. It is not confirmed yet.")
        }
        if let model, !model.isEmpty {
            guard caps.models.isEmpty || caps.models.contains(model), RemoteWorkerContract.validID(model) else { throw RemoteWorkerFailure("The worker does not offer the model “\(model)”.") }
        }
        guard runList.filter({ $0.connectionID == connectionID && $0.state.isActive }).count < Self.maxActivePerConnection else {
            throw RemoteWorkerFailure("This worker already has \(Self.maxActivePerConnection) runs in progress.")
        }
        let titleLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        var run = RemoteWorkerRun(id: "rw-" + newID(), connectionID: connectionID, endpoint: target.baseURL, configRevision: target.revision, requestID: newID(),
                                  title: RemoteWorkerContract.boundedText(titleLine, bytes: 160).text, model: (model?.isEmpty ?? true) ? nil : model, now: now())
        runList.append(run); try saveRuns()           // prepared: saved before anything is sent
        run.state = .starting; run.updated = now(); replace(run); try saveRuns()
        busy.insert(run.id); defer { busy.remove(run.id) }
        var body: [String: Any] = ["protocol": RemoteWorkerContract.protocolVersion, "requestId": run.requestID, "idempotencyKey": run.requestID, "prompt": text]
        if let model = run.model { body["model"] = model }
        if let workspace, !workspace.isEmpty { body["workspace"] = workspace }
        let outcome = await call(target, endpoint: run.endpoint, method: "POST", path: "/v1/runs", body: body, idempotency: run.requestID)
        try finishStart(run.id, outcome)
        ensureObserver()
        await notify()
        return try self.run(run.id)
    }

    private func replace(_ run: RemoteWorkerRun) { if let index = runList.firstIndex(where: { $0.id == run.id }) { runList[index] = run } }

    private func finishStart(_ id: String, _ outcome: Outcome) throws {
        guard var run = runList.first(where: { $0.id == id }) else { return }
        run.updated = now()
        switch outcome {
        case .lost(let why):
            run.state = .unknown
            run.note = "Not known whether the worker started this run (" + why + "). Use Refresh to find out. Start is never repeated automatically."
        case .answer(let status, let json):
            if (200..<300).contains(status) {
                if let problem = acceptAnswer(&run, json, expectRequest: true) {
                    run.state = .unknown; run.note = problem + " Use Refresh to find out whether it started."
                }
            } else if status == 408 || status == 429 || status >= 500 {
                run.state = .unknown
                run.note = Self.refusal(status) + " Not known whether the worker started this run. Use Refresh to find out."
            } else { run.state = .failed; run.error = Self.refusal(status) + " Nothing was started." }
        }
        replace(run); try saveRuns()
    }

    /// Validates an answer to start/resume/lookup and merges its snapshot. Returns a problem sentence, or nil.
    private func acceptAnswer(_ run: inout RemoteWorkerRun, _ json: [String: Any], expectRequest: Bool, expectedRequest: String? = nil) -> String? {
        if expectRequest {
            guard let echoed = json["requestId"] as? String, echoed == (expectedRequest ?? run.requestID) else { return "The worker's answer did not match this request." }
        }
        guard let remote = json["runId"] as? String, RemoteWorkerContract.validID(remote) else { return "The worker's answer had no valid run identity." }
        if let existing = run.remoteID, existing != remote { return "The worker answered for a different run." }
        run.remoteID = remote
        guard let snapshot = Snapshot(json, fallbackRevision: run.revision) else { return "The worker's status answer was not understood." }
        return merge(&run, snapshot)
    }

    // MARK: Snapshots

    struct Snapshot {
        var state: RemoteWorkerState
        var revision: Int
        var result: String?
        var error: String?
        var usage: RemoteWorkerUsage?
        init?(_ json: [String: Any], fallbackRevision: Int) {
            guard let word = json["state"] as? String, let state = RemoteWorkerState.reported(word) else { return nil }
            self.state = state
            if let raw = json["revision"] {
                guard let number = raw as? Int, number >= 0, number < 1_000_000_000 else { return nil }
                revision = number
            } else { revision = fallbackRevision + 1 }
            if let text = json["result"] as? String { result = text }
            if let text = json["error"] as? String { error = RemoteWorkerContract.boundedText(text, bytes: 1000).text }
            usage = try? RemoteWorkerUsage.decode(json["usage"], revision: revision)
        }
    }

    /// Applies a snapshot. Stale or contradictory ones change nothing. Returns a problem sentence for protocol errors.
    private func merge(_ run: inout RemoteWorkerRun, _ snapshot: Snapshot) -> String? {
        if snapshot.revision < run.revision || (snapshot.revision == run.revision && snapshot.state == run.state && run.revision > 0) { return nil }
        var next = snapshot.state
        if run.state == .stopRequested, next == .running { next = .stopRequested }
        guard run.state.accepts(next) else { return "The worker reported “\(snapshot.state.rawValue)” for a run that already ended as “\(run.state.rawValue)”; ignored." }
        run.state = next; run.revision = snapshot.revision; run.updated = now()
        if let text = snapshot.result { let bounded = RemoteWorkerContract.boundedText(text, bytes: RemoteWorkerContract.maxResultBytes); run.result = bounded.text; run.resultTruncated = bounded.truncated }
        run.error = snapshot.state == .failed ? (snapshot.error ?? "The worker reported that the run failed.") : run.error
        if let usage = snapshot.usage { run.usage = usage }   // replaced by revision, never added
        if next.isTerminal { run.stopConfirmed = next == .stopped || run.stopConfirmed }
        if let note = run.note, note.hasPrefix("Observation interrupted") || next.isTerminal || note.hasPrefix("Not known") { run.note = nil }
        return nil
    }

    // MARK: Refresh

    private func guardEndpoint(_ run: RemoteWorkerRun) throws -> RemoteWorkerConnection {
        let target = try connection(run.connectionID)
        guard target.revision == run.configRevision, target.baseURL == run.endpoint else {
            throw RemoteWorkerFailure("The worker's address was changed after this run started, so this run can no longer be controlled from here. Start a new run.")
        }
        return target
    }

    @discardableResult
    public func refresh(_ id: String) async throws -> RemoteWorkerRun {
        _ = try await refreshOne(id)
        await notify()
        return try run(id)
    }

    /// Review paperclip #3: the owner gives up on a run that can no longer be controlled (its address changed, or
    /// its start answer was lost for good). It is ended here only; nothing is sent, and the worker may still run it.
    @discardableResult
    public func abandon(_ id: String) async throws -> RemoteWorkerRun {
        var run = try self.run(id)
        guard run.state.isActive else { throw RemoteWorkerFailure("This run has already ended.") }
        guard !busy.contains(id) else { throw RemoteWorkerFailure("Another action on this run is still waiting for the worker.") }
        run.state = .failed; run.stopConfirmed = false; run.notFound = nil; run.updated = now()
        run.error = "Abandoned here by the owner. Nothing was sent; the worker may still be running it."
        run.note = nil
        replace(run); try saveRuns(); await notify()
        return run
    }
    /// A run whose connection address changed cannot be read back; only Abandon can end it.
    private func detached(_ run: RemoteWorkerRun) -> Bool {
        guard let target = connectionsByID[run.connectionID] else { return true }
        return target.revision != run.configRevision || target.baseURL != run.endpoint
    }

    /// Review paperclip #4: a lookup can arrive before a slow worker registered the request. "Never started" needs
    /// several consecutive not-found answers AND some minutes since the start attempt, so a late start is not run twice.
    static let notFoundAnswers = 3, notFoundGrace: TimeInterval = 300

    /// Returns false when the worker could not be reached. `changed` is false when the answer changed nothing.
    private func refreshOne(_ id: String) async throws -> (reachable: Bool, changed: Bool) {
        let run = try self.run(id)
        guard run.state.isActive else { return (true, false) }
        guard !busy.contains(id) else { throw RemoteWorkerFailure("Another action on this run is still waiting for the worker.") }
        let target = try guardEndpoint(run)
        busy.insert(id); defer { busy.remove(id) }
        let path = run.remoteID.map { "/v1/runs/" + $0 } ?? "/v1/requests/" + run.requestID
        let outcome = await call(target, endpoint: run.endpoint, method: "GET", path: path)
        guard let before = runList.first(where: { $0.id == id }), connectionsByID[run.connectionID]?.revision == run.configRevision else { return (true, false) }
        var current = before
        let reachable: Bool
        switch outcome {
        case .lost(let why):
            current.note = "Observation interrupted: " + why + ". The run may still be going."
            reachable = false
        case .answer(let status, let json):
            if status != 404 { current.notFound = nil }
            if (200..<300).contains(status) {
                if let problem = acceptAnswer(&current, json, expectRequest: false) { current.note = problem }
                reachable = true
            } else if status == 404 {
                if current.remoteID == nil {
                    let count = (current.notFound ?? 0) + 1
                    if count >= Self.notFoundAnswers, now().timeIntervalSince(current.created) >= Self.notFoundGrace {
                        current.state = .failed; current.error = "The worker has no record of this request, so it was never started."; current.notFound = nil; current.note = nil
                    } else {
                        current.notFound = min(count, Self.notFoundAnswers)
                        current.note = "The worker has no record of this request yet. Checking again before calling it never started."
                    }
                }
                else { current.state = current.state.isActive ? .unknown : current.state; current.note = "The worker no longer knows this run." }
                reachable = true
            } else { current.note = "Observation interrupted: " + Self.refusal(status); reachable = status < 500 }
        }
        // Review paperclip #5: runs.json is written only when the run really changed.
        var unstamped = current; unstamped.updated = before.updated
        guard unstamped != before else { return (reachable, false) }
        current.updated = now()
        replace(current); try saveRuns()
        return (reachable, true)
    }

    // MARK: Stop

    @discardableResult
    public func stop(_ id: String) async throws -> RemoteWorkerRun {
        var run = try self.run(id)
        guard run.state.isActive else { throw RemoteWorkerFailure("This run has already ended.") }
        guard !busy.contains(id) else { throw RemoteWorkerFailure("Another action on this run is still waiting for the worker.") }
        let target = try guardEndpoint(run)
        guard target.lastCheck?.capabilities?.stop == true else { throw RemoteWorkerFailure("This worker did not say it can stop a run. Check the connection again.") }
        guard let remote = run.remoteID else { throw RemoteWorkerFailure("It is not known whether the worker started this run. Use Refresh first.") }
        let request = run.stopRequestID ?? newID()
        run.stopRequestID = request; run.updated = now(); replace(run); try saveRuns()   // saved before sending, reused on retry
        busy.insert(id); defer { busy.remove(id) }
        let outcome = await call(target, endpoint: run.endpoint, method: "POST", path: "/v1/runs/" + remote + "/stop", body: ["requestId": request], idempotency: request)
        guard var latest = runList.first(where: { $0.id == id }) else { return run }
        latest.updated = now()
        switch outcome {
        case .lost(let why):
            latest.state = .stopRequested; latest.stopConfirmed = false
            latest.note = "Stop is unconfirmed (" + why + "). The worker may still be running. Use Refresh to check."
        case .answer(let status, let json):
            if (200..<300).contains(status) {
                let reported = (json["state"] as? String).flatMap(RemoteWorkerState.reported)
                let acknowledged = (json["requestId"] as? String) == request && (json["runId"] as? String).map({ $0 == remote }) != false
                if !acknowledged { latest.state = .stopRequested; latest.stopConfirmed = false; latest.note = "The worker's stop answer did not match. The stop is unconfirmed. Use Refresh to check." }
                else {
                    var snap = json; if reported == nil || reported == .running { snap["state"] = "stop_requested" }
                    if snap["revision"] == nil { snap["revision"] = latest.revision + 1 }
                    if let snapshot = Snapshot(snap, fallbackRevision: latest.revision) { _ = merge(&latest, snapshot) }
                    if latest.state == .running { latest.state = .stopRequested }
                    latest.stopConfirmed = latest.state == .stopped
                    if latest.state == .stopRequested { latest.note = "Stop requested. The worker has not confirmed that it stopped yet." }
                }
            } else { latest.note = Self.refusal(status) + " The stop was not accepted." }
        }
        replace(latest); try saveRuns(); ensureObserver(); await notify()
        return latest
    }

    // MARK: Resume (a new linked attempt; the old record is kept)

    public func resume(_ id: String, message: String) async throws -> RemoteWorkerRun {
        let source = try run(id)
        guard source.state.isTerminal else { throw RemoteWorkerFailure("Only a finished or stopped run can be continued.") }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= RemoteWorkerContract.maxPromptBytes else { throw RemoteWorkerFailure("Write what the worker should do next (up to \(RemoteWorkerContract.maxPromptBytes / 1024) KB).") }
        let target = try guardEndpoint(source)
        guard target.lastCheck?.capabilities?.resume == true else { throw RemoteWorkerFailure("This worker did not say it can continue a run.") }
        guard let remote = source.remoteID else { throw RemoteWorkerFailure("This run never got a worker identity, so it cannot be continued.") }
        guard !runList.contains(where: { $0.previous == source.id && $0.state.isActive }) else { throw RemoteWorkerFailure("This run is already being continued.") }
        var run = RemoteWorkerRun(id: "rw-" + newID(), connectionID: source.connectionID, endpoint: source.endpoint, configRevision: source.configRevision, requestID: newID(),
                                  title: RemoteWorkerContract.boundedText(text.split(separator: "\n").first.map(String.init) ?? text, bytes: 160).text,
                                  model: source.model, now: now(), attempt: source.attempt + 1, previous: source.id)
        runList.append(run); try saveRuns()
        run.state = .starting; replace(run); try saveRuns()
        busy.insert(run.id); defer { busy.remove(run.id) }
        let outcome = await call(target, endpoint: run.endpoint, method: "POST", path: "/v1/runs/" + remote + "/resume",
                                 body: ["protocol": RemoteWorkerContract.protocolVersion, "requestId": run.requestID, "idempotencyKey": run.requestID, "message": text, "from": remote], idempotency: run.requestID)
        try finishStart(run.id, outcome)
        ensureObserver(); await notify()
        return try self.run(run.id)
    }

    // MARK: Restart and observation

    /// After a restart: nothing is ever started or resumed again. Runs caught mid-start become "unknown";
    /// every active run is then only read back from the worker.
    public func reconcile() async {
        load()
        var touched = false
        for index in runList.indices where runList[index].state == .prepared || runList[index].state == .starting {
            runList[index].state = .unknown; touched = true
            runList[index].note = "The app closed while this was starting. Not known whether the worker started it. Use Refresh to find out."
        }
        if touched { try? saveRuns() }
        ensureObserver()
        await notify()
    }

    public func stopObserving() { observer?.cancel(); observer = nil }

    /// One service-owned loop for all active runs: the worker has no push channel, so it reads each one
    /// back at a bounded, backed-off pace and ends itself when nothing is active. No timer per run.
    private func ensureObserver() {
        load()
        guard observer == nil, runList.contains(where: { $0.state.isActive && !busy.contains($0.id) && !detached($0) }) else { return }
        let base = baseDelay, limit = maxDelay
        observer = Task { [weak self] in
            var delay = base
            while !Task.isCancelled {
                guard let self, await self.hasActive() else { await self?.observerEnded(); return }
                do { try await self.sleepFor(delay) } catch { await self.observerEnded(); return }
                let reachable = await self.tick()
                delay = reachable ? base : min(delay * 2, limit)
            }
            await self?.observerEnded()
        }
    }
    private func hasActive() -> Bool { runList.contains { $0.state.isActive && !detached($0) } }
    private func observerEnded() { observer = nil }
    private func sleepFor(_ nanoseconds: UInt64) async throws { try await sleep(nanoseconds) }

    /// Reads back up to 16 active runs once (also used directly by tests and by Refresh all). #506: each read-back starts
    /// where the last one stopped, so with more active runs than that every run is still read in turn.
    /// Detached runs are skipped; a refused read counts as unreachable so the loop backs off; listeners hear only real changes.
    @discardableResult
    public func tick() async -> Bool {
        var reachable = true, changed = false
        let active = runList.filter { $0.state.isActive && !busy.contains($0.id) && !detached($0) }
        let start = active.isEmpty ? 0 : tickCursor % active.count
        let batch = Array((active[start...] + active[..<start]).prefix(Self.maxActivePerConnection * 2))
        tickCursor = start + batch.count
        for run in batch {
            do { let read = try await refreshOne(run.id); if !read.reachable { reachable = false }; if read.changed { changed = true } }
            catch { reachable = false }
        }
        if changed { await notify() }
        return reachable
    }
}
