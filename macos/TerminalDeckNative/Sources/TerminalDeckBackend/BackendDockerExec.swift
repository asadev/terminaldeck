import Foundation
import TerminalDeckNativeCore

public struct BackendDockerExecHandle: Equatable, Sendable {
    public let sessionID: String
    public let execID: String
    public init(sessionID: String, execID: String) { self.sessionID = sessionID; self.execID = execID }
    public var value: NativeRPCValue {
        .object([.init("sessionId", .string(sessionID)), .init("execId", .string(execID))])
    }
}

public struct BackendDockerExecEnd: Equatable, Sendable {
    public let reason: String
    public let exitCode: Int?
    public let error: NativeRPCError?
    public init(reason: String, exitCode: Int? = nil, error: NativeRPCError? = nil) {
        self.reason = reason; self.exitCode = exitCode; self.error = error
    }
    public var value: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("reason", .string(reason))]
        if let exitCode { fields.append(.init("exitCode", .number(Double(exitCode)))) }
        if let error { fields.append(.init("error", .object([.init("code", .string(error.code)), .init("message", .string(error.message))]))) }
        return .object(fields)
    }
}

/// This owns Docker's approved exec connections, not another local PTY process
/// or terminal renderer. The channel owner routes the callbacks into the app's
/// existing terminal/session bridge and enforces caller ownership before entry.
/// The data callback must honor task cancellation before delayed publishing;
/// close cannot retract bytes a callback has already delivered to a listener.
/// Docker exec/start uses raw PTY bytes when Tty is true:
/// https://docs.docker.com/reference/api/engine/version/v1.47/#tag/Exec
/// https://raw.githubusercontent.com/moby/moby/v27.5.1/docs/api/v1.47.yaml
public actor BackendDockerExec {
    public static let maximumSessions = 8
    public static let maximumInputBytes = 65_536
    public static let maximumPendingOperations = 64
    private struct Session: Sendable {
        let handle: BackendDockerExecHandle
        let duplex: BackendDockerDuplex
        let secrets: [String]
        var task: Task<Void, Never>?
        var active = false
    }
    private let client: BackendDockerClient
    private let onData: @Sendable (BackendDockerExecHandle, Data) async throws -> Void
    private let onEnd: @Sendable (BackendDockerExecHandle, BackendDockerExecEnd) async -> Void
    private var sessions: [String: Session] = [:]
    private var finishing: [String: Session] = [:]
    private var opening: [String: Task<BackendDockerExecHandle, Error>] = [:]
    private var openingDuplexes: [String: BackendDockerDuplex] = [:]
    private struct Operation: Sendable {
        let sessionID: String
        let task: Task<Void, Error>
    }
    private var operations: [UUID: Operation] = [:]
    private var accepting = true

    public init(client: BackendDockerClient,
                onData: @escaping @Sendable (BackendDockerExecHandle, Data) async throws -> Void,
                onEnd: @escaping @Sendable (BackendDockerExecHandle, BackendDockerExecEnd) async -> Void) {
        self.client = client; self.onData = onData; self.onEnd = onEnd
    }

    /// Call only after the existing approval path approves this terminal. It
    /// opens the Engine connection but emits no data until activate(sessionID:).
    /// This lets the channel owner register the handle before any callback.
    public func open(containerID: String, command: [String] = ["/bin/sh"], columns: Int = 80, rows: Int = 24,
                     secretValues: [String] = []) async throws -> BackendDockerExecHandle {
        guard accepting else { throw closed() }
        guard sessions.count + finishing.count + opening.count < Self.maximumSessions else {
            throw NativeRPCError(code: "docker-stream-overflow", message: "Close a container terminal before opening another.")
        }
        try dimensions(columns: columns, rows: rows)
        let container = try resourceID(containerID)
        guard !command.isEmpty, command.count <= 128,
              command.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              command.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw NativeRPCError.invalidArguments("The container terminal command is invalid or too large.")
        }
        let sessionID = "docker-exec-" + UUID().uuidString
        let task = Task {
            try await self.openConnection(sessionID: sessionID, containerID: containerID, container: container,
                                          command: command, columns: columns, rows: rows, secretValues: secretValues)
        }
        opening[sessionID] = task
        defer { opening.removeValue(forKey: sessionID) }
        do {
            return try await withTaskCancellationHandler {
                let handle = try await task.value
                try Task.checkCancellation()
                guard accepting, sessions[sessionID] != nil else { throw closed() }
                return handle
            } onCancel: { task.cancel() }
        } catch {
            // Caller cancellation can arrive after the child transferred its
            // connection to sessions but before the handle reaches its owner.
            await close(sessionID: sessionID)
            throw error as? NativeRPCError ?? BackendDockerStreams.safeError(error)
        }
    }

    private func openConnection(sessionID: String, containerID: String, container: String, command: [String],
                                columns: Int, rows: Int, secretValues: [String]) async throws -> BackendDockerExecHandle {
        try checkOpening(sessionID)
        let configuration = try await client.containerStreamConfiguration(id: containerID)
        let secrets = secretValues + configuration.secretValues
        _ = try BackendDockerStreams.SecretMasker(secretValues: secrets)
        try checkOpening(sessionID)
        let created = try await client.request("POST", path: "/containers/\(container)/exec", body: .object([
            .init("AttachStdin", .bool(true)), .init("AttachStdout", .bool(true)), .init("AttachStderr", .bool(true)),
            .init("ConsoleSize", .array([.number(Double(rows)), .number(Double(columns))])),
            .init("Tty", .bool(true)), .init("Privileged", .bool(false)), .init("Cmd", .array(command.map(NativeRPCValue.string)))
        ]))
        try requireStatus(created.status, allowed: [201])
        let raw: NativeRPCValue
        do { raw = try NativeRPCValue.parseJSON(created.body, maximumBytes: 65_536) }
        catch { throw NativeRPCError(code: "docker-protocol", message: "Docker returned an invalid terminal identifier.") }
        guard let execID = raw["Id"].string else {
            throw NativeRPCError(code: "docker-protocol", message: "Docker did not return a terminal identifier.")
        }
        let exec = try resourceID(execID)
        try checkOpening(sessionID)
        let start = try await client.requestDescriptor("POST", path: "/exec/\(exec)/start", body: .object([
            .init("Detach", .bool(false)), .init("Tty", .bool(true)),
            .init("ConsoleSize", .array([.number(Double(rows)), .number(Double(columns))]))
        ]), headers: ["Connection": "Upgrade", "Upgrade": "tcp"])
        try checkOpening(sessionID)
        let duplex = try await client.transport.hijack(start)
        do {
            try requireStatus(duplex.status, allowed: [101, 200])
            try checkOpening(sessionID)
            openingDuplexes[sessionID] = duplex
            let resized = try await client.request("POST", path: "/exec/\(exec)/resize", query: ["h": String(rows), "w": String(columns)])
            try requireStatus(resized.status, allowed: [200, 204])
            try checkOpening(sessionID)
        } catch {
            openingDuplexes.removeValue(forKey: sessionID)
            duplex.close(); throw BackendDockerStreams.safeError(error)
        }
        openingDuplexes.removeValue(forKey: sessionID)
        let handle = BackendDockerExecHandle(sessionID: sessionID, execID: execID)
        sessions[sessionID] = Session(handle: handle, duplex: duplex, secrets: secrets)
        return handle
    }

    public func activate(sessionID: String) throws {
        guard accepting, var session = sessions[sessionID] else { throw missing() }
        guard !session.active else { return }
        session.active = true
        let handle = session.handle, duplex = session.duplex, secrets = session.secrets
        session.task = Task { [weak self] in
            guard let self else { return }
            await self.consume(handle: handle, duplex: duplex, secrets: secrets)
        }
        sessions[sessionID] = session
    }

    public func write(sessionID: String, data: Data) async throws {
        guard let session = sessions[sessionID], session.active else { throw missing() }
        guard data.count <= Self.maximumInputBytes else { throw NativeRPCError.invalidArguments("The terminal input is too large.") }
        try Task.checkCancellation()
        let task = Task { try await session.duplex.write(data) }
        do { try await runOperation(sessionID: sessionID, task: task) }
        catch {
            let safe = BackendDockerStreams.safeError(error)
            await finish(sessionID: sessionID, end: BackendDockerExecEnd(reason: "error", error: safe))
            throw safe
        }
    }

    public func resize(sessionID: String, columns: Int, rows: Int) async throws {
        try Task.checkCancellation()
        try dimensions(columns: columns, rows: rows)
        guard let session = sessions[sessionID] else { throw missing() }
        let exec = try resourceID(session.handle.execID)
        let task = Task {
            let response = try await self.client.request("POST", path: "/exec/\(exec)/resize", query: ["h": String(rows), "w": String(columns)])
            try self.requireStatus(response.status, allowed: [200, 204])
        }
        try await runOperation(sessionID: sessionID, task: task)
    }

    public func close(sessionID: String) async {
        if let session = finishing.removeValue(forKey: sessionID) {
            cancelOperations(sessionID: sessionID)
            session.task?.cancel(); session.duplex.close()
            await onEnd(session.handle, BackendDockerExecEnd(reason: "closed"))
            return
        }
        await finish(sessionID: sessionID, end: BackendDockerExecEnd(reason: "closed"))
    }

    public func shutdown() async {
        accepting = false
        let pending = Array(opening.values); opening.removeAll()
        for task in pending { task.cancel() }
        let duplexes = Array(openingDuplexes.values); openingDuplexes.removeAll()
        for duplex in duplexes { duplex.close() }
        // Snapshot keys because every finish removes its entry before awaiting.
        for id in Array(sessions.keys) { await close(sessionID: id) }
        for id in Array(finishing.keys) { await close(sessionID: id) }
        for operation in operations.values { operation.task.cancel() }
        operations.removeAll()
    }

    public var activeSessionCount: Int { sessions.count + finishing.count }

    private func runOperation(sessionID: String, task: Task<Void, Error>) async throws {
        guard operations.count < Self.maximumPendingOperations else {
            task.cancel()
            throw NativeRPCError(code: "docker-stream-overflow", message: "The container terminal has too much pending input.")
        }
        let id = UUID()
        operations[id] = Operation(sessionID: sessionID, task: task)
        defer { operations.removeValue(forKey: id) }
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
                guard sessions[sessionID] != nil else { throw closed() }
            } onCancel: { task.cancel() }
        } catch { throw BackendDockerStreams.safeError(error) }
    }

    private func cancelOperations(sessionID: String) {
        for id in operations.keys.filter({ operations[$0]?.sessionID == sessionID }) {
            operations.removeValue(forKey: id)?.task.cancel()
        }
    }

    private func consume(handle: BackendDockerExecHandle, duplex: BackendDockerDuplex, secrets: [String]) async {
        do {
            var masker = try BackendDockerStreams.SecretMasker(secretValues: secrets)
            for try await bytes in duplex.incoming {
                try Task.checkCancellation()
                guard sessions[handle.sessionID] != nil else { return }
                let safe = try masker.consume(bytes)
                try await emit(handle: handle, data: safe)
            }
            try Task.checkCancellation()
            guard sessions[handle.sessionID] != nil else { return }
            let tail = masker.finish()
            try await emit(handle: handle, data: tail)
            await finish(sessionID: handle.sessionID, end: BackendDockerExecEnd(reason: "eof"), confirmExit: true, cancelReader: false)
        } catch {
            guard sessions[handle.sessionID] != nil else { return }
            await finish(sessionID: handle.sessionID,
                         end: BackendDockerExecEnd(reason: "error", error: BackendDockerStreams.safeError(error)), cancelReader: false)
        }
    }

    private func emit(handle: BackendDockerExecHandle, data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            guard sessions[handle.sessionID] != nil else { throw CancellationError() }
            let end = min(offset + Self.maximumInputBytes, data.endIndex)
            try await onData(handle, Data(data[offset..<end]))
            offset = end
        }
    }

    private func finish(sessionID: String, end: BackendDockerExecEnd, confirmExit: Bool = false, cancelReader: Bool = true) async {
        // Remove before closing/callback: concurrent EOF, close and shutdown
        // cannot emit a second end or accept input into a closed connection.
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        cancelOperations(sessionID: sessionID)
        if cancelReader { session.task?.cancel() }
        session.duplex.close()
        var result = end
        if confirmExit {
            // Retain the reader until the confirmation request ends. A close
            // or disconnect can cancel that request and publish closed now.
            finishing[sessionID] = session
            let code = await confirmedExitCode(session.handle.execID)
            guard finishing.removeValue(forKey: sessionID) != nil else { return }
            if let code { result = BackendDockerExecEnd(reason: end.reason, exitCode: code, error: end.error) }
        }
        await onEnd(session.handle, result)
    }

    private func confirmedExitCode(_ execID: String) async -> Int? {
        // One inspection after EOF is evidence; tunnel closure alone does not
        // mean the process exited. There is deliberately no polling loop.
        do {
            let exec = try resourceID(execID)
            let response = try await client.request("GET", path: "/exec/\(exec)/json")
            guard response.status == 200 else { return nil }
            let raw = try NativeRPCValue.parseJSON(response.body, maximumBytes: 65_536)
            guard raw["Running"].bool == false, let code = raw["ExitCode"].number,
                  code.rounded() == code, code >= Double(Int32.min), code <= Double(Int32.max) else { return nil }
            return Int(code)
        } catch { return nil }
    }

    private func checkOpening(_ id: String) throws {
        try Task.checkCancellation()
        guard accepting && opening[id] != nil else { throw closed() }
    }
    private func resourceID(_ id: String) throws -> String {
        try BackendDockerClient.pathComponent(id)
    }
    private func dimensions(columns: Int, rows: Int) throws {
        guard (1...1_000).contains(columns), (1...1_000).contains(rows) else {
            throw NativeRPCError.invalidArguments("Terminal columns and rows must be between 1 and 1000.")
        }
    }
    private func requireStatus(_ status: Int, allowed: Set<Int>) throws {
        guard allowed.contains(status) else {
            throw NativeRPCError(code: status == 404 ? "docker-resource-missing" : "docker-api", message: "Docker could not complete the terminal request.")
        }
    }
    private func closed() -> NativeRPCError { NativeRPCError(code: "cancelled", message: "The Docker terminal connection is closed.") }
    private func missing() -> NativeRPCError { NativeRPCError(code: "docker-resource-missing", message: "That container terminal is no longer open.") }
}
