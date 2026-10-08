import Foundation
import TerminalDeckNativeCore

/// Copilot frames enter the existing authenticated BackendRemoteHost. Owns
/// per-socket hello/watch state, while run ownership remains per paired device.
public actor BackendCopilotRemoteFrames {
    public typealias Send = @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    private struct Connection: Sendable { let deviceID: String; var open = false; var watcher: UUID? }
    public let runs: BackendCopilotRemoteRuns
    private let files: (any BackendCopilotFilesProviding)?
    private let send: Send
    private var connections: [UUID: Connection] = [:]
    public init(runs: BackendCopilotRemoteRuns, files: (any BackendCopilotFilesProviding)? = nil, send: @escaping Send) {
        self.runs = runs; self.files = files; self.send = send
    }
    public func features() -> [BackendRemoteHostFeature] {
        let filesTags = Set(["copilot.files", "copilot.file.read", "copilot.file.write", "copilot.file.reset", "copilot.memory.delete"])
        let coreTags = Set(BackendCopilotRemoteSurface.frameTier.keys).subtracting(filesTags).union(BackendCopilotRemoteSurface.untiered)
        var result = [BackendRemoteHostFeature(capability: "copilot", messageTypes: coreTags, policy: .ownerOnly) { [weak self] message, context in
            guard let self else { return [try .error(code: "unavailable", message: "Hoot is not available on this machine.")] }
            return await self.handle(message, context: context)
        }]
        if files != nil {
            result.append(.init(capability: "copilot.files", messageTypes: filesTags, policy: .ownerOnly) { [weak self] message, context in
                guard let self else { return [try .error(code: "unavailable", message: "Hoot’s files cannot be reached on this machine.")] }
                return await self.handle(message, context: context)
            })
        }
        return result
    }
    /// Call after authenticated hello, before composing the welcome. Guests get
    /// no copilot key. Registering a socket starts no process and spends nothing.
    public func connected(_ context: BackendRemoteHostContext) async -> NativeRPCValue? {
        connections[context.connectionID] = Connection(deviceID: context.deviceID)
        guard await runs.linked(context.deviceID) else { return nil }
        return await link(context.deviceID, open: false)
    }
    public func welcomeLink(deviceID: String) async -> NativeRPCValue? {
        guard await runs.linked(deviceID) else { return nil }; return await link(deviceID, open: false)
    }
    private func link(_ deviceID: String, open: Bool) async -> NativeRPCValue {
        .object([.init("linked", .bool(await runs.linked(deviceID))), .init("open", .bool(open)), .init("grant", await runs.granted(deviceID).wireValue)])
    }
    public func disconnected(_ connectionID: UUID) async {
        guard let row = connections.removeValue(forKey: connectionID) else { return }
        if let watcher = row.watcher { await runs.unwatch(watcher) }
        if row.open && !connections.values.contains(where: { $0.deviceID == row.deviceID && $0.open }) { await runs.closed(row.deviceID) }
    }
    public func revoked(_ deviceID: String) async {
        // Caller store is already written by the trust owner before this event.
        await runs.revoked(deviceID)
        let linked = await runs.linked(deviceID), grant = await runs.granted(deviceID)
        for (id, row) in Array(connections) where row.deviceID == deviceID {
            if !linked || !grant.read {
                if let watcher = row.watcher { await runs.unwatch(watcher) }
                connections[id]?.watcher = nil
            }
            if !linked { connections[id]?.open = false }
            if let frame = try? BackendRemoteServerMessage(.copilotGrant, fields: [.init("link", await link(deviceID, open: connections[id]?.open == true))]) {
                try? await send(id, frame)
            }
        }
    }
    public func stop() async {
        for id in Array(connections.keys) { await disconnected(id) }
        await runs.stopAll()
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async -> [BackendRemoteServerMessage] {
        let message = BackendRemoteClientMessage(RNMHootWireCompatibility.incomingClientEnvelope(message.value))
        let id = context.connectionID, deviceID = context.deviceID
        if connections[id] == nil { connections[id] = Connection(deviceID: deviceID) }
        guard connections[id]?.deviceID == deviceID else { return refusal("unauthorized", "This device does not have Hoot.") }
        do {
            if message.type == "copilot.bye" {
                let wasOpen = connections[id]?.open == true
                connections[id]?.open = false
                if let watcher = connections[id]?.watcher { await runs.unwatch(watcher); connections[id]?.watcher = nil }
                if wasOpen && !connections.values.contains(where: { $0.deviceID == deviceID && $0.open }) { await runs.closed(deviceID) }
                return [try .init(.copilotGrant, fields: [.init("link", await link(deviceID, open: false))])]
            }
            if message.type == "copilot.hello" {
                guard await runs.linked(deviceID) else { return refusal("unauthorized", "Hoot is not shared with guest devices. Pair this device again as your own to use it.") }
                let outcome = await runs.open(deviceID)
                guard connections[id] != nil else { return [] }
                if !outcome.ok { await disconnected(id); return failure(outcome) }
                connections[id]?.open = true
                return [try .init(.copilotGrant, fields: [.init("link", await link(deviceID, open: true))])]
            }
            guard connections[id]?.open == true else {
                return refusal("unauthorized", "This device is not connected to Hoot. Connect it on the Mac itself, in Settings → Remote.")
            }
            guard await runs.linked(deviceID) else { return refusal("unauthorized", "Hoot is not shared with guest devices.") }
            guard BackendCopilotRemoteSurface.allowed(await runs.granted(deviceID), verb: message.type) else {
                return refusal("unauthorized", "This device has not been given that much access to Hoot. Change it on the Mac itself, in Settings → Remote.")
            }
            switch message.type {
            case "copilot.attach":
                if let old = connections[id]?.watcher { await runs.unwatch(old); connections[id]?.watcher = nil }
                let sender = send
                let watcher = await runs.watch(deviceID) { frame in try? await sender(id, frame) }
                guard connections[id]?.open == true else { await runs.unwatch(watcher); return [] }
                connections[id]?.watcher = watcher
                return [try .init(.copilotState, fields: [.init("state", try await runs.state(deviceID))])]
            case "copilot.detach":
                if let old = connections[id]?.watcher { await runs.unwatch(old); connections[id]?.watcher = nil }; return []
            case "copilot.state": return [try .init(.copilotState, fields: [.init("state", try await runs.state(deviceID))])]
            case "copilot.sessions": return [try .init(.copilotSessions, fields: [.init("sessions", .array(try await runs.sessions()))])]
            case "copilot.pending": return [try .init(.copilotPending, fields: [.init("questions", .array(await runs.pending(deviceID)))])]
            case "copilot.answer":
                let accepted = await runs.answer(deviceID, id: message["id"].string!, approved: message["approved"].bool!)
                var result = accepted ? [] : refusal("unavailable", "That confirmation is no longer waiting for this device.")
                result.append(try .init(.copilotPending, fields: [.init("questions", .array(await runs.pending(deviceID)))])); return result
            case "copilot.log":
                let tail = try await runs.log(limit: message["limit"].number, before: message["before"].string)
                return [try .init(.copilotLog, fields: [.init("rows", .array(tail.rows)), .init("more", .bool(tail.more))])]
            case "copilot.start":
                let outcome = await runs.start(deviceID)
                guard connections[id] != nil else { return [] }
                if !outcome.ok { return failure(outcome) }
                return [try .init(.copilotState, fields: [.init("state", try await runs.state(deviceID))])]
            case "copilot.say":
                let outcome = await runs.say(deviceID, text: message["text"].string!)
                return connections[id] == nil || outcome.ok ? [] : failure(outcome)
            case "copilot.cancel", "copilot.stop":
                let outcome = message.type == "copilot.cancel" ? await runs.cancel(deviceID) : await runs.stop(deviceID)
                if !outcome.ok { return failure(outcome) }
                return [try .init(.copilotState, fields: [.init("state", try await runs.state(deviceID))])]
            case "copilot.interactive":
                try await runs.setInteractive(message["on"].bool!)
                return [try .init(.copilotState, fields: [.init("state", try await runs.state(deviceID))])]
            case "copilot.files", "copilot.file.read", "copilot.file.write", "copilot.file.reset", "copilot.memory.delete":
                return try await serveFiles(message)
            default: return refusal("unauthorized", "This device has not been given that much access to Hoot. Change it on the Mac itself, in Settings → Remote.")
            }
        } catch { return refusal("unavailable", message.type.hasPrefix("copilot.file") || message.type == "copilot.memory.delete" ? "Hoot’s files could not be reached just now." : "Hoot could not complete that request just now.") }
    }
    private func serveFiles(_ message: BackendRemoteClientMessage) async throws -> [BackendRemoteServerMessage] {
        guard let files else { return refusal("unauthorized", "Hoot’s files cannot be reached on this machine.") }
        func rows() async throws -> BackendRemoteServerMessage {
            let list = try await files.list()
            return try .init(.copilotFileRows, fields: [.init("files", .array(list))])
        }
        switch message.type {
        case "copilot.files": return [try await rows()]
        case "copilot.file.read":
            let id = message["id"].string!
            guard let target = BackendRemoteProtocol.copilotFileTarget(id) else {
                return [try .init(.copilotFileText, fields: [.init("id", .string(id)), .init("text", .string("")), .init("error", .string("That is not a file Hoot keeps."))])]
            }
            let read = try await files.read(target)
            var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("text", .string(read.text))]
            if let error = read.error { fields.append(.init("error", .string(error))) }
            return [try .init(.copilotFileText, fields: fields)]
        case "copilot.file.write":
            guard let target = BackendRemoteProtocol.copilotFileTarget(message["id"].string!) else { return refusal("unavailable", "That is not a file Hoot keeps.") }
            let written = try await files.write(target, text: message["text"].string!)
            return (written.ok ? [] : refusal("unavailable", written.error ?? "It could not be saved just now.")) + [try await rows()]
        case "copilot.file.reset":
            guard message["id"].string == "yours" else {
                return refusal("unavailable", "Only Hoot’s own instructions have a version this build can put back. The other files are either generated on every start or yours to write.") + [try await rows()]
            }
            let written = try await files.reset()
            return (written.ok ? [] : refusal("unavailable", written.error ?? "The instructions could not be restored just now.")) + [try await rows()]
        case "copilot.memory.delete":
            let written = try await files.forget(message["name"].string!)
            return (written.ok ? [] : refusal("unavailable", written.error ?? "That memory could not be deleted just now.")) + [try await rows()]
        default: return refusal("unavailable", "Hoot’s files cannot be reached on this machine.")
        }
    }
    private func refusal(_ code: String, _ message: String) -> [BackendRemoteServerMessage] { (try? .error(code: code, message: message)).map { [$0] } ?? [] }
    private func failure(_ outcome: BackendCopilotRemoteOutcome) -> [BackendRemoteServerMessage] { refusal(outcome.code ?? "unavailable", outcome.message ?? "Hoot could not complete that request just now.") }
}
