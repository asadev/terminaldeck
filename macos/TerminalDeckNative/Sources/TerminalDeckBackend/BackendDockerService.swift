import Foundation
import TerminalDeckNativeCore

/// One service per composition. It opens nothing until an authorized invoke.
public actor BackendDockerService {
    private struct StreamEntry: Sendable {
        let owner: String, target: String, records: BackendDockerRecordStream
        var sequence: Int = 0
        var task: Task<Void, Never>?
    }
    private struct ExecEntry: Sendable {
        let owner: String, target: String, manager: BackendDockerExec
        var sequence: Int = 0
    }
    private let dependencies: BackendDockerDependencies
    private var registry: NativeChannelRegistry?
    private var streams: [String: StreamEntry] = [:]
    private var sessions: [String: ExecEntry] = [:]
    private var generations: [String: Int] = [:]
    private var pendingStreams: [String: Int] = [:]
    private var pendingSessions: [String: Int] = [:]
    private struct InFlight: Sendable {
        let context: NativeRPCContext
        let task: Task<NativeRPCValue, Error>
    }
    private var inFlight: [UUID: InFlight] = [:]
    private var closed = false
    public init(dependencies: BackendDockerDependencies) { self.dependencies = dependencies }
    public func attach(registry: NativeChannelRegistry) throws {
        guard !closed else { throw unavailable() }
        if let current = self.registry, current !== registry { throw NativeRPCError(code: "unavailable", message: "Docker must share the app's existing channel registry.") }
        self.registry = registry
    }

    public func handle(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        guard !closed, registry != nil else { throw unavailable() }
        if Task.isCancelled { throw Self.safeFailure(CancellationError()) }
        guard inFlight.count < 64, inFlight.values.filter({ $0.context.ownerID == context.ownerID }).count < 16 else {
            throw NativeRPCError(code: "docker-stream-overflow", message: "Too many Docker requests are pending. Wait for one to finish.")
        }
        let generation = generations[context.ownerID, default: 0]
        let token = UUID()
        // Task (rather than Task.detached) inherits caller TaskLocal values,
        // including the app's actor/grant attribution. The unique admission
        // token is independent of a potentially reused RPC request ID.
        let task = Task {
            try await self.perform(channel, context: context, arguments: arguments, generation: generation)
        }
        inFlight[token] = InFlight(context: context, task: task)
        defer { inFlight.removeValue(forKey: token) }
        do {
            return try await withTaskCancellationHandler {
                let result = try await task.value
                try current(owner: context.ownerID, generation: generation)
                return result
            } onCancel: { task.cancel() }
        }
        catch { throw Self.safeFailure(error) }
    }

    private func perform(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue], generation: Int) async throws -> NativeRPCValue {
        try current(owner: context.ownerID, generation: generation)
        guard registry != nil else { throw unavailable() }
        guard BackendDockerChannels.invokeChannels.contains(channel) else { throw unavailable() }
        try context.requireCount(arguments, 1...1)
        let payload = arguments[0]
        guard let fields = payload.fields else { throw NativeRPCError.invalidArguments("Docker needs one request object.") }
        let allowed = BackendDockerChannels.requestFields(channel)
        guard fields.count <= allowed.count, Set(fields.map(\.key)).count == fields.count,
              fields.allSatisfy({ allowed.contains($0.key) }) else {
            throw NativeRPCError.invalidArguments("This Docker request contains an unsupported field.")
        }
        let target = channel == "docker:targets" ? (try optionalText(payload, "target") ?? "") : try text(payload, "target")
        try validate(channel, payload: payload)
        guard let authorize = dependencies.authorize else { throw NativeRPCError(code: "unavailable", message: "Docker's existing approval and access adapter is unavailable.") }
        let destructive = BackendDockerChannels.destructiveChannels.contains(channel)
        let writes = BackendDockerChannels.writeChannels.contains(channel)
        let resource = payload["id"].string ?? payload["name"].string
        // Access precedes preflight I/O. Consent follows availability/argument
        // checks, so a broken or unsupported action never asks for approval.
        try await authorize(.init(channel: channel, target: target, resourceID: resource), context)
        try current(owner: context.ownerID, generation: generation)

        if channel == "docker:targets" {
            let targets = try await dependencies.targets(context)
            try current(owner: context.ownerID, generation: generation)
            return .object([.init("targets", .array(targets.map(\.value)))])
        }
        if channel == "docker:stream:close" {
            let id = try text(payload, "streamId")
            try ownedStream(id, target: target, owner: context.ownerID)
            await finishStream(id, reason: "closed")
            return success
        }
        if channel.hasPrefix("docker:exec:"), channel != "docker:exec:open" {
            let id = try text(payload, "sessionId")
            let entry = try ownedSession(id, target: target, owner: context.ownerID)
            switch channel {
            case "docker:exec:write":
                let encoded = try text(payload, "data", maximum: 1_398_104, allowEmpty: true)
                guard let bytes = Data(base64Encoded: encoded), bytes.count <= BackendDockerExec.maximumInputBytes else {
                    throw NativeRPCError.invalidArguments("Terminal input must be bounded base64 bytes.")
                }
                try await entry.manager.write(sessionID: id, data: bytes)
            case "docker:exec:resize":
                try await entry.manager.resize(sessionID: id, columns: integer(payload, "columns", default: nil, range: 1...1000),
                                               rows: integer(payload, "rows", default: nil, range: 1...1000))
            case "docker:exec:close": await entry.manager.close(sessionID: id)
            default: throw unavailable()
            }
            return success
        }
        if channel == "docker:install:preview" || channel == "docker:install" {
            guard let row = try await dependencies.targets(context).first(where: { $0.id == target }) else {
                throw NativeRPCError(code: "unavailable", message: "That saved server is unavailable.")
            }
            try BackendDockerInstall.requireLinux(row)
            try current(owner: context.ownerID, generation: generation)
            if channel == "docker:install:preview" { return BackendDockerInstall.preview }
            guard let install = dependencies.install else { throw NativeRPCError(code: "unavailable", message: "The server's approved administrator command runner is unavailable.") }
            try current(owner: context.ownerID, generation: generation)
            try await authorize(.init(channel: channel, target: target, writesServer: true), context)
            try current(owner: context.ownerID, generation: generation)
            do { try await install(target, BackendDockerInstall.command, context) }
            catch is CancellationError { throw CancellationError() }
            catch { throw NativeRPCError(code: "docker-api", message: "Docker could not be installed. Check the server's administrator access and try again.") }
            try current(owner: context.ownerID, generation: generation)
            let client = try await dependencies.resolve(target, context)
            try current(owner: context.ownerID, generation: generation)
            return success.setting("status", try await client.status().value)
        }

        let client = try await dependencies.resolve(target, context)
        try current(owner: context.ownerID, generation: generation)
        if destructive {
            let id: String, name: String
            switch channel {
            case "docker:containers:remove":
                let row = try await client.inspectContainer(text(payload, "id")); id = row.id; name = row.name
            case "docker:images:remove":
                let row = try await client.inspectImage(text(payload, "id")); id = row.id
                name = row.tags.first(where: { !$0.hasPrefix("<none>") }) ?? row.id
            case "docker:volumes:remove":
                id = try text(payload, "name")
                guard let row = try await client.listVolumes().first(where: { $0.name == id }) else {
                    throw NativeRPCError(code: "docker-resource-missing", message: "That volume no longer exists.")
                }
                name = row.name
            case "docker:networks:remove":
                let row = try await client.inspectNetwork(text(payload, "id")); id = row.id; name = row.name
            default: throw unavailable()
            }
            try current(owner: context.ownerID, generation: generation)
            guard payload["confirmName"].string == name else {
                throw NativeRPCError(code: "confirmation-required", message: "Confirm removal by naming the current item exactly.", details: .object([.init("name", .string(name))]))
            }
            try current(owner: context.ownerID, generation: generation)
            try await authorize(.init(channel: channel, target: target, resourceID: id, confirmationName: name,
                                      writesServer: true, destructive: true, parameters: actionParameters(payload)), context)
            try current(owner: context.ownerID, generation: generation)
            // Mutate the canonical inspected ID, never the submitted name alias.
            switch channel {
            case "docker:containers:remove": try await client.removeContainer(id, force: boolean(payload, "force"), removeVolumes: boolean(payload, "removeVolumes"))
            case "docker:images:remove": try await client.removeImage(id, force: boolean(payload, "force"))
            case "docker:volumes:remove": try await client.removeVolume(id, force: boolean(payload, "force"))
            case "docker:networks:remove": try await client.removeNetwork(id)
            default: throw unavailable()
            }
            return success
        }

        if writes {
            var parameters = actionParameters(payload)
            if channel == "docker:exec:open" {
                let config = try await client.containerStreamConfiguration(id: text(payload, "id"))
                try current(owner: context.ownerID, generation: generation)
                let knownSecrets = try await dependencies.secretValues(target, context) + config.secretValues
                try current(owner: context.ownerID, generation: generation)
                let safeCommand = try safeCommandPreview(command(payload), secretValues: knownSecrets)
                parameters = parameters.setting("command", .array(safeCommand.map(NativeRPCValue.string)))
            }
            try current(owner: context.ownerID, generation: generation)
            try await authorize(.init(channel: channel, target: target, resourceID: resource,
                                      writesServer: true, parameters: parameters), context)
            try current(owner: context.ownerID, generation: generation)
        }

        switch channel {
        case "docker:status": return try await client.status().value
        case "docker:containers:list":
            return .object([.init("containers", .array(try await client.listContainers(all: boolean(payload, "all", default: true), filters: optional(payload, "filters")).map(\.value)))])
        case "docker:containers:inspect": return try await client.inspectContainer(text(payload, "id")).value
        case "docker:containers:start": try await client.startContainer(text(payload, "id")); return success
        case "docker:containers:stop": try await client.stopContainer(text(payload, "id"), timeoutSeconds: optionalInteger(payload, "timeoutSeconds", range: 0...600)); return success
        case "docker:containers:restart": try await client.restartContainer(text(payload, "id"), timeoutSeconds: optionalInteger(payload, "timeoutSeconds", range: 0...600)); return success
        case "docker:images:list": return .object([.init("images", .array(try await client.listImages().map(\.value)))])
        case "docker:volumes:list": return .object([.init("volumes", .array(try await client.listVolumes().map(\.value)))])
        case "docker:volumes:create": return try await client.createVolume(name: text(payload, "name"), driver: optionalText(payload, "driver") ?? "local", labels: labels(payload)).value
        case "docker:networks:list": return .object([.init("networks", .array(try await client.listNetworks().map(\.value)))])
        case "docker:networks:create": return try await client.createNetwork(name: text(payload, "name"), driver: optionalText(payload, "driver") ?? "bridge", internalNetwork: boolean(payload, "internal"), labels: labels(payload)).value
        case "docker:compose:list": return .object([.init("projects", .array(try await client.listComposeProjects().map(\.value)))])
        case "docker:compose:inspect": return try await client.inspectComposeProject(text(payload, "name")).value
        case "docker:logs:open", "docker:stats:open", "docker:events:open":
            guard streams.count + pendingStreams.values.reduce(0, +) < 32,
                  streams.values.filter({ $0.owner == context.ownerID }).count + pendingStreams[context.ownerID, default: 0] < 8 else {
                throw NativeRPCError(code: "docker-stream-overflow", message: "Close an existing Docker stream before opening another.")
            }
            pendingStreams[context.ownerID, default: 0] += 1
            defer { pendingStreams[context.ownerID, default: 0] -= 1 }
            let recordStream: BackendDockerRecordStream
            let event: String
            let resourceID: String?
            let extraSecrets = try await dependencies.secretValues(target, context)
            try current(owner: context.ownerID, generation: generation)
            if channel == "docker:events:open" {
                var query: [String: String] = [:]
                if let filters = optional(payload, "filters") { query["filters"] = try filterJSON(filters) }
                if let since = try optionalText(payload, "since") { query["since"] = since }
                let request = try await client.requestDescriptor("GET", path: "/events", query: query)
                let response = try await client.transport.stream(request)
                recordStream = try BackendDockerStreams.events(response: response, secretValues: extraSecrets)
                event = "docker:events:data"; resourceID = nil
            } else {
                let id = try text(payload, "id")
                resourceID = id
                if channel == "docker:logs:open" {
                    let config = try await client.containerStreamConfiguration(id: id)
                    try current(owner: context.ownerID, generation: generation)
                    let tail = try integer(payload, "tail", default: 200, range: 0...5000)
                    let query = ["follow": "true", "stdout": "true", "stderr": "true", "tail": String(tail),
                                 "timestamps": try boolean(payload, "timestamps", default: true) ? "true" : "false"]
                    let request = try await client.requestDescriptor("GET", path: "/containers/\(try BackendDockerClient.pathComponent(id))/logs", query: query)
                    let response = try await client.transport.stream(request)
                    recordStream = try BackendDockerStreams.logs(response: response, tty: config.tty, secretValues: config.secretValues + extraSecrets)
                    event = "docker:logs:data"
                } else {
                    let request = try await client.requestDescriptor("GET", path: "/containers/\(try BackendDockerClient.pathComponent(id))/stats", query: ["stream": "true"])
                    let response = try await client.transport.stream(request)
                    recordStream = try BackendDockerStreams.stats(response: response)
                    event = "docker:stats:data"
                }
            }
            do { try current(owner: context.ownerID, generation: generation) }
            catch { recordStream.cancel(); throw error }
            let id = UUID().uuidString
            streams[id] = StreamEntry(owner: context.ownerID, target: target, records: recordStream)
            let task = Task { [weak self] in
                do {
                    for try await record in recordStream.records {
                        try Task.checkCancellation()
                        try await self?.streamData(id, event: event, resourceID: resourceID, record: record)
                    }
                    await self?.finishStream(id, reason: "eof", cancelReader: false)
                } catch is CancellationError { await self?.finishStream(id, reason: "closed", cancelReader: false) }
                catch { await self?.finishStream(id, reason: "error", error: BackendDockerService.safeError(error), cancelReader: false) }
            }
            streams[id]?.task = task
            return .object([.init("streamId", .string(id))])
        case "docker:exec:open":
            guard sessions.count + pendingSessions.values.reduce(0, +) < 8,
                  sessions.values.filter({ $0.owner == context.ownerID }).count + pendingSessions[context.ownerID, default: 0] < 4 else {
                throw NativeRPCError(code: "docker-stream-overflow", message: "Close an existing container terminal before opening another.")
            }
            pendingSessions[context.ownerID, default: 0] += 1
            defer { pendingSessions[context.ownerID, default: 0] -= 1 }
            let manager = BackendDockerExec(client: client, onData: { [weak self] handle, data in
                guard let self else { throw CancellationError() }
                try await self.execData(handle, target: target, owner: context.ownerID, data: data)
            }, onEnd: { [weak self] handle, end in await self?.execEnd(handle, target: target, owner: context.ownerID, end: end) })
            let secrets = try await dependencies.secretValues(target, context)
            try current(owner: context.ownerID, generation: generation)
            let handle = try await manager.open(containerID: text(payload, "id"), command: command(payload),
                                                columns: integer(payload, "columns", default: 80, range: 1...1000),
                                                rows: integer(payload, "rows", default: 24, range: 1...1000),
                                                secretValues: secrets)
            do { try current(owner: context.ownerID, generation: generation) }
            catch { await manager.shutdown(); throw error }
            sessions[handle.sessionID] = ExecEntry(owner: context.ownerID, target: target, manager: manager)
            do { try await manager.activate(sessionID: handle.sessionID) }
            catch { await manager.shutdown(); sessions.removeValue(forKey: handle.sessionID); throw error }
            do { try current(owner: context.ownerID, generation: generation) }
            catch { await manager.shutdown(); throw error }
            return .object([.init("sessionId", .string(handle.sessionID)), .init("execId", .string(handle.execID))])
        default: throw unavailable()
        }
    }

    public func disconnect(ownerID: String) async {
        generations[ownerID, default: 0] += 1
        let calls = inFlight.values.filter { $0.context.ownerID == ownerID }
        // Cancel every owned task before the first await, including direct
        // handle calls that have no pending entry in the channel registry.
        for call in calls { call.task.cancel() }
        for call in calls {
            await registry?.cancelRequest(call.context.requestID, ownerID: ownerID)
        }
        for id in streams.keys.filter({ streams[$0]?.owner == ownerID }) { await finishStream(id, reason: "closed") }
        for entry in sessions.values.filter({ $0.owner == ownerID }) { await entry.manager.shutdown() }
    }
    public func shutdown() async {
        guard !closed else { return }; closed = true
        let calls = Array(inFlight.values)
        for call in calls { call.task.cancel() }
        for call in calls { await registry?.cancelRequest(call.context.requestID, ownerID: call.context.ownerID) }
        for id in Array(streams.keys) { await finishStream(id, reason: "closed") }
        for entry in Array(sessions.values) { await entry.manager.shutdown() }
        sessions = [:]; registry = nil
    }
    public func activeCounts() -> (streams: Int, sessions: Int) { (streams.count, sessions.count) }

    private func streamData(_ id: String, event: String, resourceID: String?, record: NativeRPCValue) async throws {
        try Task.checkCancellation()
        guard var entry = streams[id], let registry else { throw CancellationError() }
        entry.sequence += 1; streams[id] = entry
        var value = record.setting("target", .string(entry.target)).setting("streamId", .string(id)).setting("sequence", .number(Double(entry.sequence)))
        if let resourceID { value = value.setting("id", .string(resourceID)) }
        try Task.checkCancellation()
        try await registry.publish(event, arguments: [value], ownerID: entry.owner)
        if event == "docker:events:data" { BackendDockerMCPReceiver.docker(value) }
    }
    private func finishStream(_ id: String, reason: String, error: NativeRPCError? = nil, cancelReader: Bool = true) async {
        guard let entry = streams.removeValue(forKey: id) else { return }
        entry.records.cancel()
        if cancelReader { entry.task?.cancel() }
        var value: NativeRPCValue = .object([.init("target", .string(entry.target)), .init("streamId", .string(id)),
            .init("sequence", .number(Double(entry.sequence + 1))), .init("reason", .string(reason))])
        if let error { value = value.setting("error", error.wireValue) }
        try? await registry?.publish("docker:stream:end", arguments: [value], ownerID: entry.owner)
    }
    private func execData(_ handle: BackendDockerExecHandle, target: String, owner: String, data: Data) async throws {
        try Task.checkCancellation()
        guard var entry = sessions[handle.sessionID], entry.owner == owner, entry.target == target, let registry else { throw CancellationError() }
        entry.sequence += 1; sessions[handle.sessionID] = entry
        let value: NativeRPCValue = .object([.init("target", .string(target)), .init("sessionId", .string(handle.sessionID)),
            .init("execId", .string(handle.execID)), .init("sequence", .number(Double(entry.sequence))), .init("data", .string(data.base64EncodedString()))])
        try Task.checkCancellation()
        try await registry.publish("docker:exec:data", arguments: [value], ownerID: owner)
    }
    private func execEnd(_ handle: BackendDockerExecHandle, target: String, owner: String, end: BackendDockerExecEnd) async {
        guard let entry = sessions.removeValue(forKey: handle.sessionID) else { return }
        let value = end.value.setting("target", .string(target)).setting("sessionId", .string(handle.sessionID))
            .setting("execId", .string(handle.execID)).setting("sequence", .number(Double(entry.sequence + 1)))
        try? await registry?.publish("docker:exec:end", arguments: [value], ownerID: owner)
    }
    private func ownedStream(_ id: String, target: String, owner: String) throws {
        guard let row = streams[id], row.owner == owner, row.target == target else { throw forbidden() }
    }
    private func ownedSession(_ id: String, target: String, owner: String) throws -> ExecEntry {
        guard let row = sessions[id], row.owner == owner, row.target == target else { throw forbidden() }; return row
    }
    private func current(owner: String, generation: Int) throws {
        try Task.checkCancellation()
        guard !closed, generations[owner, default: 0] == generation else { throw CancellationError() }
    }
    private var success: NativeRPCValue { .object([.init("ok", .bool(true))]) }
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "Docker server control is unavailable in this connection.") }
    private func forbidden() -> NativeRPCError { .init(code: "forbidden", message: "That Docker stream or terminal belongs to another connection, or is closed.") }
    private static func safeError(_ error: Error) -> NativeRPCError {
        if let error = error as? NativeRPCError {
            let codes: Set<String> = ["docker-stream-overflow", "docker-protocol", "docker-resource-missing", "docker-permission", "docker-not-found", "cancelled"]
            return .init(code: codes.contains(error.code) ? error.code : "docker-api", message: "The Docker stream ended. Open it again to reconnect.")
        }
        return .init(code: error is CancellationError ? "cancelled" : "docker-api", message: "The Docker stream ended. Open it again to reconnect.")
    }
    /// Provider errors can contain SSH stderr or secret-store diagnostics. Only
    /// safe codes cross the channel boundary; no provider text/details do.
    private static func safeFailure(_ failure: Error) -> NativeRPCError {
        if failure is CancellationError { return .init(code: "cancelled", message: "The Docker request was cancelled.") }
        let error = failure as? NativeRPCError
        let messages: [String: String] = [
            "unavailable": "Docker server control is unavailable in this connection.",
            "invalid-arguments": "Check the Docker request fields and try again.",
            "approval-required": "This Docker action needs the person's approval.",
            "confirmation-required": "Confirm removal by naming the current item exactly.",
            "forbidden": "This connection cannot access that Docker stream or terminal.",
            "access-denied": "This connection does not have access to that Docker action.",
            "docker-not-found": "Docker is not available on this server or local socket.",
            "docker-permission": "This account does not have access to Docker.",
            "docker-api": "Docker could not complete this action.",
            "docker-protocol": "Docker returned an invalid response.",
            "docker-api-version": "This Docker Engine API version is not supported.",
            "docker-stream-overflow": "Docker output exceeded the view's limit. Close it and open it again.",
            "docker-resource-missing": "That Docker item no longer exists.",
            "cancelled": "The Docker request was cancelled.",
        ]
        let code = error.flatMap { messages[$0.code] == nil ? nil : $0.code } ?? "unavailable"
        // A canonical item name is the one deliberate detail needed for the
        // destructive confirmation UI. Never carry arbitrary supplied details.
        let name = code == "confirmation-required" ? error?.details["name"].string : nil
        let details: NativeRPCValue = name.map { .object([.init("name", .string($0))]) } ?? .missing
        return .init(code: code, message: messages[code]!, details: details)
    }
    private func text(_ payload: NativeRPCValue, _ key: String, maximum: Int = 256, allowEmpty: Bool = false) throws -> String {
        guard let value = payload[key].string, (allowEmpty || !value.isEmpty), value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw NativeRPCError.invalidArguments("\(key) must be bounded text.")
        }; return value
    }
    private func optionalText(_ payload: NativeRPCValue, _ key: String) throws -> String? {
        guard optional(payload, key) != nil else { return nil }; return try text(payload, key)
    }
    private func optional(_ payload: NativeRPCValue, _ key: String) -> NativeRPCValue? {
        switch payload[key] { case .missing, .null: return nil; default: return payload[key] }
    }
    private func boolean(_ payload: NativeRPCValue, _ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = optional(payload, key) else { return fallback }
        guard let result = value.bool else { throw NativeRPCError.invalidArguments("\(key) must be true or false.") }; return result
    }
    private func integer(_ payload: NativeRPCValue, _ key: String, default fallback: Int?, range: ClosedRange<Int>) throws -> Int {
        guard let value = optional(payload, key) else {
            if let fallback { return fallback }; throw NativeRPCError.invalidArguments("\(key) is required.")
        }
        guard let number = value.number, number.isFinite, number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw NativeRPCError.invalidArguments("\(key) must be a whole number in \(range.lowerBound)...\(range.upperBound).")
        }; return Int(number)
    }
    private func optionalInteger(_ payload: NativeRPCValue, _ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard optional(payload, key) != nil else { return nil }; return try integer(payload, key, default: nil, range: range)
    }
    private func labels(_ payload: NativeRPCValue) throws -> [String: String] {
        guard let raw = optional(payload, "labels") else { return [:] }
        guard let fields = raw.fields, fields.count <= 64 else { throw NativeRPCError.invalidArguments("Labels must be a small text map.") }
        var result: [String: String] = [:]
        for field in fields {
            guard !field.key.isEmpty, field.key.utf8.count <= 256, let value = field.value.string, value.utf8.count <= 4096 else { throw NativeRPCError.invalidArguments("Labels must contain bounded text.") }
            result[field.key] = value
        }; return result
    }
    private func command(_ payload: NativeRPCValue) throws -> [String] {
        guard let raw = optional(payload, "command") else { return ["/bin/sh"] }
        guard let elements = raw.elements, !elements.isEmpty, elements.count <= 64 else { throw NativeRPCError.invalidArguments("A terminal command must be a bounded argument array.") }
        return try elements.map { value in
            guard let text = value.string, text.utf8.count <= 4096, !text.contains("\0") else { throw NativeRPCError.invalidArguments("Terminal arguments must be bounded text.") }; return text
        }
    }
    private func filterJSON(_ raw: NativeRPCValue) throws -> String {
        guard let fields = raw.fields, fields.count <= 32 else { throw NativeRPCError.invalidArguments("Filters must be a bounded map of text arrays.") }
        for field in fields {
            guard !field.key.isEmpty, field.key.utf8.count <= 128, let elements = field.value.elements, elements.count <= 64,
                  elements.allSatisfy({ ($0.string?.utf8.count ?? 1025) <= 1024 }) else { throw NativeRPCError.invalidArguments("Filters must be a bounded map of text arrays.") }
        }
        return String(decoding: try raw.encodedJSON(), as: UTF8.self)
    }

    private func validate(_ channel: String, payload: NativeRPCValue) throws {
        if let id = optional(payload, "id") {
            _ = try BackendDockerClient.pathComponent(try id.requireString("id", nonempty: true), allowSlash: channel.hasPrefix("docker:images:"))
        }
        switch channel {
        case "docker:containers:inspect", "docker:containers:start", "docker:containers:stop", "docker:containers:restart", "docker:containers:remove",
             "docker:images:remove", "docker:networks:remove", "docker:logs:open", "docker:stats:open", "docker:exec:open":
            _ = try text(payload, "id")
        case "docker:volumes:create", "docker:volumes:remove", "docker:networks:create", "docker:compose:inspect":
            try BackendDockerClient.validateName(text(payload, "name"))
        default: break
        }
        for key in ["all", "force", "removeVolumes", "internal", "timestamps"] where optional(payload, key) != nil { _ = try boolean(payload, key) }
        if optional(payload, "timeoutSeconds") != nil { _ = try integer(payload, "timeoutSeconds", default: nil, range: 0...600) }
        if optional(payload, "tail") != nil { _ = try integer(payload, "tail", default: nil, range: 0...5000) }
        for key in ["columns", "rows"] where optional(payload, key) != nil { _ = try integer(payload, key, default: nil, range: 1...1000) }
        if let driver = try optionalText(payload, "driver") { try BackendDockerClient.validateDriver(driver) }
        if optional(payload, "labels") != nil { try BackendDockerClient.validateLabels(labels(payload)) }
        if let filters = optional(payload, "filters") {
            if channel == "docker:events:open" { _ = try filterJSON(filters) }
            else { _ = try BackendDockerClient.validatedFilters(filters) }
        }
        if optional(payload, "since") != nil { _ = try optionalText(payload, "since") }
        if optional(payload, "confirmName") != nil { _ = try text(payload, "confirmName") }
        if channel == "docker:stream:close" { _ = try text(payload, "streamId") }
        if channel.hasPrefix("docker:exec:"), channel != "docker:exec:open" { _ = try text(payload, "sessionId") }
        if channel == "docker:exec:resize" {
            _ = try integer(payload, "columns", default: nil, range: 1...1000)
            _ = try integer(payload, "rows", default: nil, range: 1...1000)
        }
        if channel == "docker:exec:write" {
            let encoded = try text(payload, "data", maximum: 87_384, allowEmpty: true)
            guard let bytes = Data(base64Encoded: encoded), bytes.count <= BackendDockerExec.maximumInputBytes else {
                throw NativeRPCError.invalidArguments("Terminal input must be bounded base64 bytes.")
            }
        }
        if channel == "docker:exec:open" {
            let command = try command(payload)
            guard command.allSatisfy({ !$0.isEmpty }), command.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
                throw NativeRPCError.invalidArguments("A terminal command must be a bounded argument array.")
            }
        }
    }
    private func actionParameters(_ payload: NativeRPCValue) -> NativeRPCValue {
        let safe = Set(["force", "removeVolumes", "timeoutSeconds", "driver", "internal", "columns", "rows"])
        return .object((payload.fields ?? []).filter { safe.contains($0.key) })
    }
    private func safeCommandArgument(_ argument: String, secretValues: [String]) throws -> String {
        var masker = try BackendDockerStreams.SecretMasker(secretValues: secretValues)
        let masked = try masker.consume(Data(argument.utf8)) + masker.finish()
        return BackendSharedRedact.redact(String(decoding: masked, as: UTF8.self), options: .init(keepIdentity: true))
    }

    /// This is an approval display only. The original argv still goes to the
    /// Engine unchanged. Shared secret-key recognition also protects values
    /// that are not yet present in the existing store or container env.
    private func safeCommandPreview(_ arguments: [String], secretValues: [String]) throws -> [String] {
        var maskNext = false
        let executable = ((arguments.first ?? "") as NSString).lastPathComponent.lowercased()
        let shortPassword = ["mysql", "mariadb", "mysqldump", "mongosh", "mongo"].contains(executable)
        return try arguments.map { argument in
            if maskNext {
                maskNext = false
                return BackendSharedRedact.redacted
            }
            // These clients use -p as a password, optionally attached. Other
            // commands (for example psql) use -p for a port; leave that flag
            // to the existing value/structure masker instead of guessing.
            if shortPassword, argument.hasPrefix("-p"), !argument.hasPrefix("--") {
                if argument == "-p" {
                    maskNext = true
                    return try safeCommandArgument(argument, secretValues: secretValues)
                }
                return "-p" + BackendSharedRedact.redacted
            }
            if let equal = argument.firstIndex(of: "=") {
                let prefix = String(argument[..<equal])
                let key = String(prefix.drop(while: { $0 == "-" }))
                if BackendSharedRedact.isSecretKey(key) {
                    return try safeCommandArgument(prefix, secretValues: secretValues) + "=" + BackendSharedRedact.redacted
                }
            }
            if argument.hasPrefix("-") {
                let key = String(argument.drop(while: { $0 == "-" }))
                maskNext = BackendSharedRedact.isSecretKey(key)
            }
            return try safeCommandArgument(argument, secretValues: secretValues)
        }
    }
}
