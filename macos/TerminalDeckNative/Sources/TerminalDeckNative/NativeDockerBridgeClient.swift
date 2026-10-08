import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// CONTRACT-docker.md v1. Every request is one object; writes stay behind DKA's
/// existing grant/approval broker. This adapter never opens a socket or runs a shell.
extension NativeDockerClient {
    static func bridge(target: NativeDockerTarget) -> Self {
        let wireTarget: String
        switch target { case .thisMac: wireTarget = "local"; case .server(let id, _): wireTarget = id }
        let bridge = NativeDockerBridgeCalls(target: wireTarget)
        return Self(
            probe: {
                if target.isLocal, !(try await hasLocalSocket()) { return .noLocalSocket }
                do {
                    let reply = try await bridge.call("docker:status")
                    guard reply["available"].isTrue, let version = reply["version"].text else {
                        throw NativeRPCError.malformed("Docker returned an unreadable status.")
                    }
                    return .available(version: version)
                } catch let error as NativeRPCError where error.code == "docker-not-found" {
                    return target.isLocal ? .noLocalSocket : .missingDocker
                }
            },
            list: { section in
                let channel = section == .projects ? "docker:compose:list" : "docker:\(section.rawValue):list"
                return try NativeDockerContractProjection.items(section: section, reply: await bridge.call(channel))
            },
            inspect: { section, id in
                switch section {
                case .containers:
                    return try NativeDockerContractProjection.container(await bridge.call("docker:containers:inspect", ["id": id]))
                case .projects:
                    return try NativeDockerContractProjection.project(await bridge.call("docker:compose:inspect", ["name": id]))
                case .images, .volumes, .networks:
                    let rows = try NativeDockerContractProjection.items(section: section,
                                                                         reply: await bridge.call("docker:\(section.rawValue):list"))
                    guard let row = rows.first(where: { $0.id == id }) else {
                        throw NativeRPCError(code: "docker-resource-missing", message: "This Docker resource no longer exists.")
                    }
                    return row
                }
            },
            change: { section, id, action, confirmation in
                guard section == .containers || (action == .remove && section != .projects) else {
                    throw NativeDockerUnavailable("This Docker action")
                }
                var payload: [String: Any] = [section == .volumes ? "name" : "id": id]
                if action == .remove {
                    guard let confirmation, !confirmation.isEmpty else {
                        throw NativeRPCError(code: "confirmation-required", message: "Confirm the name before removing this Docker resource.")
                    }
                    payload["confirmName"] = confirmation
                    // Do not force removal or remove attached data implicitly.
                    if section == .containers { payload["removeVolumes"] = false }
                    if section != .networks { payload["force"] = false }
                }
                try await bridge.success("docker:\(section.rawValue):\(action.rawValue)", payload)
            },
            installation: {
                guard !target.isLocal else { throw NativeDockerUnavailable("The Linux Docker installer on this Mac") }
                let reply = try await bridge.call("docker:install:preview")
                let official = BackendDockerInstall.command
                guard reply["command"].text == official, reply["source"].text == BackendDockerInstall.source,
                      reply["requiresApproval"].isTrue, reply["requiresAdministrator"].isTrue else {
                    throw NativeRPCError.malformed("Docker did not return its official installation plan.")
                }
                return NativeDockerInstallation(command: official,
                                                explanation: "Docker’s official installer from get.docker.com will run on this Linux server.",
                                                reference: "https://get.docker.com")
            },
            install: { _ in
                guard !target.isLocal else { throw NativeDockerUnavailable("The Linux Docker installer on this Mac") }
                try await bridge.success("docker:install")
            },
            stream: { id, kind, update in
                let stream = NativeDockerBridgeStream(calls: bridge, containerID: id, kind: kind, update: update)
                try await stream.open()
                return NativeDockerStream(stop: { try await stream.close() }, openingFailure: stream.openingFailure)
            },
            terminal: { id in
                NativeDockerBridgeTerminal(calls: bridge, containerID: id).transport
            })
    }

    /// DKA calls once when the existing Machines page is shown. No timer/daemon.
    static func hasLocalSocket() async throws -> Bool {
        let reply = try await NativeDockerBridgeCalls(target: "local").call("docker:targets")
        guard let rows = reply["targets"].array else { throw NativeRPCError.malformed("Docker returned unreadable targets.") }
        var ids: Set<String> = []
        var local = false
        for row in rows {
            guard let id = row["id"].text, row["name"].text != nil, row["kind"].text != nil,
                  let available = row["available"].bool, ids.insert(id).inserted else {
                throw NativeRPCError.malformed("Docker returned unreadable targets.")
            }
            if id == "local" { local = available }
        }
        return local
    }
}

@MainActor
private struct NativeDockerBridgeCalls {
    let target: String
    func call(_ channel: String, _ fields: [String: Any] = [:]) async throws -> CodingAIJSON {
        var payload = fields; payload["target"] = target
        do {
            let reply = CodingAIJSON(try await EngineBridge.shared.invoke(channel, [payload]))
            if reply["ok"].bool == false {
                throw NativeRPCError(code: reply["failure"]["code"].text ?? "docker-api",
                                     message: reply["error"].text ?? "Docker could not finish this request.")
            }
            guard reply.isObject else { throw NativeRPCError.malformed("Docker returned an unreadable reply.") }
            return reply
        } catch let error as NativeRPCError where error.code == "missing-handler" {
            throw NativeDockerUnavailable("Docker server controls")
        }
    }
    func success(_ channel: String, _ fields: [String: Any] = [:]) async throws {
        let reply = try await call(channel, fields)
        guard reply["ok"].isTrue else { throw NativeRPCError.malformed("Docker did not confirm this action completed.") }
    }
}

/// UI-side ownership of one injected exec transport. Each subscription has its
/// own state; a cancelled subscription cannot mutate a later open attempt.
@MainActor
private final class NativeDockerBridgeTerminal {
    private let calls: NativeDockerBridgeCalls
    private let containerID: String
    private var subscription: NativeDockerBridgeTerminalSubscription?
    private var sessions: [String: NativeDockerBridgeTerminalSubscription] = [:]

    init(calls: NativeDockerBridgeCalls, containerID: String) {
        self.calls = calls
        self.containerID = containerID
    }

    var transport: NativeDockerTerminalTransport {
        NativeDockerTerminalTransport(
            open: { [self] columns, rows in try await open(columns: columns, rows: rows) },
            write: { [self] id, bytes in
                guard let state = sessions[id], state.active, state.sessionID == id, !state.finished,
                      !state.malformed.contains(id), !state.overflowed else {
                    throw NativeRPCError(code: "unavailable", message: "This container terminal is disconnected.")
                }
                guard bytes.count <= BackendDockerExec.maximumInputBytes else {
                    throw NativeRPCError.invalidArguments("The terminal input is too large.")
                }
                try await calls.success("docker:exec:write", ["sessionId": id, "data": bytes.base64EncodedString()])
            },
            resize: { [self] id, columns, rows in
                guard let state = sessions[id], state.active, state.sessionID == id, !state.finished else {
                    throw NativeRPCError(code: "unavailable", message: "This container terminal is disconnected.")
                }
                try await calls.success("docker:exec:resize", ["sessionId": id, "columns": columns, "rows": rows])
            },
            close: { [self] id in try await close(id) },
            subscribe: { [self] output, closed in subscribe(output: output, closed: closed) }
        )
    }

    private func subscribe(output: @escaping @MainActor (String, Data) -> Void,
                           closed: @escaping @MainActor (String, String?) -> Void) -> (() -> Void) {
        subscription?.cancel()
        let state = NativeDockerBridgeTerminalSubscription(output: output, closed: closed)
        subscription = state
        state.listeners = [
            EngineBridge.shared.on("docker:exec:data") { [weak self, weak state] args in
                MainActor.assumeIsolated {
                    guard let self, let state, self.subscription === state, state.active else { return }
                    self.receive(CodingAIJSON(args.first), state: state, ending: false)
                }
            },
            EngineBridge.shared.on("docker:exec:end") { [weak self, weak state] args in
                MainActor.assumeIsolated {
                    guard let self, let state, self.subscription === state, state.active else { return }
                    self.receive(CodingAIJSON(args.first), state: state, ending: true)
                }
            },
        ]
        return { [weak self, state] in
            MainActor.assumeIsolated {
                state.cancel() // EngineSubscription removal is queued; invalidate now.
                if self?.subscription === state { self?.subscription = nil }
            }
        }
    }

    private func open(columns: Int, rows: Int) async throws -> String {
        guard let state = subscription, state.active, !state.opening, state.sessionID == nil else {
            throw NativeRPCError(code: "unavailable", message: "The terminal must be visible before opening it.")
        }
        state.opening = true
        defer { state.opening = false }
        let reply = try await calls.call("docker:exec:open", ["id": containerID, "columns": columns, "rows": rows])
        guard let id = identifier(reply["sessionId"]) else {
            throw NativeRPCError.malformed("Docker did not return a terminal session.")
        }
        // Retain this request's state even if the screen disappeared while open
        // waited. Its model will close this exact late id in an uncancelled task.
        sessions[id] = state
        guard let execID = identifier(reply["execId"]) else {
            try await close(id)
            throw NativeRPCError.malformed("Docker did not return a terminal exec ID.")
        }
        if state.ended.contains(id), state.execIDs[id] == nil || state.execIDs[id] == execID {
            state.engineConfirmed = true
        }
        guard subscription === state, state.active else { return id }
        state.sessionID = id
        state.execID = execID
        let pending = state.pending
        state.pending = []
        state.pendingBytes = 0
        if state.overflowed || state.malformed.contains(id) ||
            (state.execIDs[id] != nil && state.execIDs[id] != execID) {
            releaseMalformed(id, state: state)
        } else {
            // Only this open request's session/exec may reach the terminal.
            // Other same-owner terminals can emit while approval is pending.
            for event in pending {
                guard !state.finished else { break }
                switch event {
                case .output(let session, let exec, let bytes) where session == id && exec == execID:
                    state.output(id, bytes)
                case .ended(let session, let exec, let message) where session == id && (exec == nil || exec == execID):
                    complete(id, state: state, message: message, confirmed: true)
                default:
                    break
                }
            }
        }
        state.sequences = state.sequences.filter { $0.key == id }
        state.execIDs = state.execIDs.filter { $0.key == id }
        state.malformed = state.malformed.contains(id) ? [id] : []
        state.ended = state.ended.contains(id) ? [id] : []
        return id
    }

    private func identifier(_ value: CodingAIJSON) -> String? {
        guard let id = value.string, !id.isEmpty, id.utf8.count <= 256 else { return nil }
        return id
    }

    private func receive(_ event: CodingAIJSON, state: NativeDockerBridgeTerminalSubscription, ending: Bool) {
        guard !state.finished, !state.overflowed, event["target"].text == calls.target,
              let id = identifier(event["sessionId"]), state.sessionID == nil || state.sessionID == id,
              !state.ended.contains(id) else { return }
        guard state.sequences[id] != nil || state.sequences.count < 512 else {
            state.overflowed = true
            state.cancelListeners()
            if let ownID = state.sessionID { releaseMalformed(ownID, state: state) }
            return
        }
        guard let next = event["sequence"].number, next.isFinite, next >= 0, next.rounded(.down) == next else {
            markMalformed(id, state: state)
            return
        }
        guard next > (state.sequences[id] ?? -1) else { return }
        // v1 exec:end binds by owned sessionId and does not require execId.
        // Newer producers may supply it; data packets always require it.
        let execID: String?
        if ending, event.object?["execId"] == nil {
            execID = nil
        } else {
            guard let supplied = identifier(event["execId"]),
                  state.execID == nil || state.execID == supplied,
                  state.execIDs[id] == nil || state.execIDs[id] == supplied else {
                markMalformed(id, state: state)
                return
            }
            execID = supplied
        }
        state.sequences[id] = next
        if let execID { state.execIDs[id] = execID }
        if ending {
            guard let reason = event["reason"].text, ["closed", "eof", "error"].contains(reason) else {
                markMalformed(id, state: state)
                return
            }
            state.ended.insert(id)
            let message = state.malformed.contains(id) ? "Docker returned unreadable terminal output." : event["error"]["message"].text
            if state.sessionID == id {
                complete(id, state: state, message: message, confirmed: true)
            } else {
                hold(.ended(id, execID, message), bytes: id.utf8.count + (execID?.utf8.count ?? 0) + (message?.utf8.count ?? 0), state: state)
            }
            return
        }
        guard !state.malformed.contains(id) else { return }
        guard let execID else { markMalformed(id, state: state); return }
        let maximumEncoded = 4 * ((BackendDockerExec.maximumInputBytes + 2) / 3)
        guard let encoded = event["data"].string, encoded.utf8.count <= maximumEncoded,
              let bytes = Data(base64Encoded: encoded), bytes.count <= BackendDockerExec.maximumInputBytes else {
            markMalformed(id, state: state)
            return
        }
        if state.sessionID == id { state.output(id, bytes) }
        else { hold(.output(id, execID, bytes), bytes: id.utf8.count + execID.utf8.count + bytes.count, state: state) }
    }

    private func markMalformed(_ id: String, state: NativeDockerBridgeTerminalSubscription) {
        guard state.malformed.contains(id) || state.malformed.count < 512 else {
            state.overflowed = true
            state.cancelListeners()
            if let ownID = state.sessionID { releaseMalformed(ownID, state: state) }
            return
        }
        state.malformed.insert(id)
        if state.sessionID == id { releaseMalformed(id, state: state) }
    }

    private func hold(_ event: NativeDockerBridgeTerminalSubscription.Event, bytes: Int,
                      state: NativeDockerBridgeTerminalSubscription) {
        guard state.pending.count < 512, bytes <= 1_048_576 - state.pendingBytes else {
            state.overflowed = true
            state.pending = []
            state.pendingBytes = 0
            state.cancelListeners()
            return
        }
        state.pending.append(event)
        state.pendingBytes += bytes
    }

    private func releaseMalformed(_ id: String, state: NativeDockerBridgeTerminalSubscription) {
        guard !state.releasing, !state.finished else { return }
        state.releasing = true
        let message = state.overflowed ? "Too much terminal output arrived before it opened." : "Docker returned unreadable terminal output."
        Task { [self, state] in
            do {
                try await close(id)
                complete(id, state: state, message: message, confirmed: true)
            } catch {
                // Keep the id available for the model's teardown to try closing;
                // an unconfirmed cleanup must never be presented as Engine EOF.
                complete(id, state: state, message: "\(message) Docker could not confirm the terminal closed.", confirmed: false)
            }
        }
    }

    private func complete(_ id: String, state: NativeDockerBridgeTerminalSubscription, message: String?, confirmed: Bool) {
        guard subscription === state, state.active, !state.finished else { return }
        state.finished = true
        state.engineConfirmed = confirmed
        state.cancelListeners()
        state.closed(id, message)
    }

    private func close(_ id: String) async throws {
        guard let state = sessions[id] else { return } // No arbitrary or duplicate closes.
        if state.engineConfirmed {
            sessions[id] = nil
            return
        }
        // Keep cleanup independent of a cancelled opening/input task. A second
        // caller shares the same in-flight close, so one id is not closed twice.
        let cleanup: Task<Void, Error>
        if let existing = state.closeTask { cleanup = existing }
        else {
            let calls = calls
            cleanup = Task { try await calls.success("docker:exec:close", ["sessionId": id]) }
            state.closeTask = cleanup
        }
        do {
            try await cleanup.value
            state.engineConfirmed = true
            if sessions[id] === state { sessions[id] = nil }
        } catch {
            // An authoritative end may beat the close reply. That observation
            // is sufficient confirmation even if the now-missing id is refused.
            if state.engineConfirmed {
                if sessions[id] === state { sessions[id] = nil }
                return
            }
            state.closeTask = nil
            throw error
        }
    }
}

@MainActor
private final class NativeDockerBridgeTerminalSubscription {
    enum Event {
        case output(String, String, Data)
        case ended(String, String?, String?)
    }
    let output: @MainActor (String, Data) -> Void
    let closed: @MainActor (String, String?) -> Void
    var listeners: [EngineSubscription] = []
    var active = true
    var opening = false
    var sessionID: String?
    var execID: String?
    var sequences: [String: Double] = [:]
    var execIDs: [String: String] = [:]
    var malformed: Set<String> = []
    var ended: Set<String> = []
    var pending: [Event] = []
    var pendingBytes = 0
    var overflowed = false
    var releasing = false
    var finished = false
    var engineConfirmed = false
    var closeTask: Task<Void, Error>?

    init(output: @escaping @MainActor (String, Data) -> Void,
         closed: @escaping @MainActor (String, String?) -> Void) {
        self.output = output
        self.closed = closed
    }

    func cancelListeners() { listeners.forEach { $0.cancel() }; listeners = [] }
    func cancel() {
        active = false
        cancelListeners()
        pending = []
        pendingBytes = 0
    }
}

/// Listens before open so early chunks cannot fall between request and reply.
@MainActor
private final class NativeDockerBridgeStream {
    private(set) var openingFailure: String?
    private let calls: NativeDockerBridgeCalls
    private let containerID: String
    private let kind: NativeDockerStreamKind
    private let update: @MainActor (NativeDockerStreamUpdate) -> Void
    private var subscriptions: [EngineSubscription] = []
    private var streamID: String?
    private var pending: [(event: CodingAIJSON, ending: Bool)] = []
    private var pendingBytes = 0
    private var sequence: Double = -1
    private var closed = false
    private var ended = false
    private var overflowed = false
    private var closeTask: Task<Void, Error>?

    init(calls: NativeDockerBridgeCalls, containerID: String, kind: NativeDockerStreamKind,
         update: @escaping @MainActor (NativeDockerStreamUpdate) -> Void) {
        self.calls = calls; self.containerID = containerID; self.kind = kind; self.update = update
    }
    func open() async throws {
        let dataChannel = kind == .logs ? "docker:logs:data" : "docker:stats:data"
        subscriptions = [
            EngineBridge.shared.on(dataChannel) { [weak self] args in
                MainActor.assumeIsolated { self?.receive(CodingAIJSON(args.first), ending: false) }
            },
            EngineBridge.shared.on("docker:stream:end") { [weak self] args in
                MainActor.assumeIsolated { self?.receive(CodingAIJSON(args.first), ending: true) }
            },
        ]
        do {
            let channel = kind == .logs ? "docker:logs:open" : "docker:stats:open"
            let reply = try await calls.call(channel, ["id": containerID])
            guard let id = reply["streamId"].string, !id.isEmpty, id.utf8.count <= 256 else {
                throw NativeRPCError.malformed("Docker did not return a live stream.")
            }
            streamID = id
            let held = pending; pending = []; pendingBytes = 0
            if closed || Task.isCancelled || overflowed {
                // Finite logs can reach EOF before open replies. Even when
                // cancelled, that exact owned end is already confirmation;
                // replay no data and do not close an id Engine has removed.
                if let end = held.first(where: { item in
                    guard item.ending, item.event["target"].string == calls.target,
                          item.event["streamId"].string == id,
                          let next = item.event["sequence"].number, next.isFinite, next >= 0,
                          next.rounded(.down) == next,
                          let reason = item.event["reason"].string else { return false }
                    return ["closed", "eof", "error"].contains(reason)
                }) {
                    consume(end.event, ending: true)
                }
                do { try await close() }
                catch {
                    // The screen may already be hidden, so its stale callback
                    // cannot carry this owner. Return the handle and typed
                    // metadata for an explicit cleanup retry, never retry here.
                    openingFailure = "Docker could not confirm the opening stream closed."
                    return
                }
                if overflowed { throw NativeRPCError(code: "docker-stream-overflow", message: "Docker output arrived faster than this view could open.") }
                throw CancellationError()
            }
            for item in held { consume(item.event, ending: item.ending) }
        } catch {
            closed = true
            pending = []
            pendingBytes = 0
            cancelListeners()
            throw error
        }
    }
    func close() async throws {
        closed = true; cancelListeners(); pending = []; pendingBytes = 0
        if let id = streamID {
            // Closing from a cancelled open task must still reach the owner.
            let cleanup: Task<Void, Error>
            if let existing = closeTask { cleanup = existing }
            else {
                let calls = calls
                cleanup = Task { try await calls.success("docker:stream:close", ["streamId": id]) }
                closeTask = cleanup
            }
            do {
                try await cleanup.value
                streamID = nil
            } catch {
                closeTask = nil // Preserve the unconfirmed id for owner teardown.
                throw error
            }
        }
    }
    private func cancelListeners() { subscriptions.forEach { $0.cancel() }; subscriptions = [] }
    private func receive(_ event: CodingAIJSON, ending: Bool) {
        guard !closed, !ended, event["target"].string == calls.target,
              let eventID = event["streamId"].string, !eventID.isEmpty, eventID.utf8.count <= 256 else { return }
        if streamID == nil {
            // Before the open reply, the stream id is unknown. Other containers'
            // data need not occupy this view's bounded early-event buffer.
            if !ending, event["id"].string != containerID { return }
            let bytes = event["text"].string?.utf8.count ?? 256
            guard pending.count < 128, pendingBytes + bytes <= 1_024 * 1_024 else {
                overflowed = true; pending = []; pendingBytes = 0; cancelListeners(); return
            }
            pending.append((event, ending)); pendingBytes += bytes
        } else { consume(event, ending: ending) }
    }
    private func consume(_ event: CodingAIJSON, ending: Bool) {
        guard !ended, event["streamId"].string == streamID else { return }
        guard let next = event["sequence"].number, next.isFinite, next >= 0, next.rounded(.down) == next else {
            malformed()
            return
        }
        guard next > sequence else { return } // A valid older duplicate can be ignored.
        sequence = next
        if ending {
            guard let reason = event["reason"].string, ["closed", "eof", "error"].contains(reason) else {
                malformed()
                return
            }
            ended = true; streamID = nil; cancelListeners()
            let why = event["error"]["message"].text ?? (reason == "eof" ? "The live stream ended." : "The live stream closed.")
            update(.ended(why, cleanupConfirmed: true)); return
        }
        guard event["id"].string == containerID else { malformed(); return }
        do {
            if kind == .logs {
                guard let text = event["text"].string, let source = event["source"].text,
                      ["stdout", "stderr", "console"].contains(source) else {
                    throw NativeRPCError.malformed("Docker returned unreadable log output.")
                }
                update(.log(text, stream: source))
            } else { update(.usage(try NativeDockerContractProjection.usage(event))) }
        } catch {
            malformed()
        }
    }

    private func malformed() {
        guard !ended else { return }
        ended = true
        cancelListeners()
        // A decoder error is local, so confirm owner cleanup before emitting
        // one completion; a failed cleanup stays visible and keeps its id.
        Task { [self] in
            do {
                try await close()
                update(.ended("Docker returned unreadable live output.", cleanupConfirmed: true))
            } catch {
                update(.ended("Docker returned unreadable live output. Docker could not confirm the stream closed.", cleanupConfirmed: false))
            }
        }
    }
}
