import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Docker approved terminal lifecycle", .timeLimit(.minutes(1)))
struct BackendDockerExecTests {
    @Test func activationPreventsEarlyCallbacksAndMasksSplitEnvAndStoreSecrets() async throws {
        let transport = BackendDockerExecFixtureTransport()
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { handle, data in
            await output.data(handle, data)
        }, onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one", secretValues: ["store-secret"])
        transport.pipe.send(Data("\u{1b}[2Jenv-".utf8))
        #expect(await output.bytes.isEmpty)
        try await exec.activate(sessionID: handle.sessionID)
        transport.pipe.send(Data("secret store-sec".utf8))
        transport.pipe.send(Data("ret 🐳\r\n".utf8))
        transport.pipe.finish()
        await output.waitForEnd()
        #expect(await output.bytes == Data("\u{1b}[2J•••••• •••••• 🐳\r\n".utf8))
        #expect(await output.handles.allSatisfy { $0 == handle })
        #expect(await output.ends.first?.reason == "eof")
        #expect(await output.ends.first?.exitCode == 7)
        #expect(await exec.activeSessionCount == 0)
        let requests = await transport.requests
        let created = try #require(requests.first { $0.path.hasSuffix("/containers/container-one/exec") })
        let body = try NativeRPCValue.parseJSON(created.body)
        #expect(body["Tty"].bool == true && body["Privileged"].bool == false)
        #expect(body["AttachStdin"].bool == true && body["Cmd"].elements == [.string("/bin/sh")])
        #expect(requests.contains { $0.path.contains("/exec/exec-one/resize?") && $0.path.contains("h=24") && $0.path.contains("w=80") })
    }

    @Test func explicitCloseAndShutdownEmitOnceWithoutInventingRemoteExit() async throws {
        let transport = BackendDockerExecFixtureTransport()
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { handle, data in await output.data(handle, data) },
                                     onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        let input = Data([0, 0x1b, 0xff, 13])
        try await exec.write(sessionID: handle.sessionID, data: input)
        #expect(await transport.written == [input])
        try await exec.resize(sessionID: handle.sessionID, columns: 132, rows: 40)
        await exec.close(sessionID: handle.sessionID)
        await exec.close(sessionID: handle.sessionID)
        await exec.shutdown()
        let ends = await output.ends
        #expect(ends.count == 1)
        #expect(ends.first?.reason == "closed" && ends.first?.exitCode == nil)
        #expect(!((await transport.requests).contains { $0.path.hasSuffix("/exec/exec-one/json") }))
        #expect(transport.pipe.closed)
        do { try await exec.write(sessionID: handle.sessionID, data: Data("x".utf8)); Issue.record("Closed terminal accepted input") }
        catch let error as NativeRPCError { #expect(error.code == "docker-resource-missing") }
    }

    @Test func EOFDoesNotClaimExitWhenEngineSaysCommandStillRuns() async throws {
        let transport = BackendDockerExecFixtureTransport(running: true)
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { handle, data in await output.data(handle, data) },
                                     onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        transport.pipe.finish()
        await output.waitForEnd()
        let end = await output.ends.first
        #expect(end?.reason == "eof" && end?.exitCode == nil)
    }

    @Test func rejectedHijackClosesTheConnectionAndExposesNoEngineErrorBody() async throws {
        let transport = BackendDockerExecFixtureTransport(hijackStatus: 409)
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { handle, data in await output.data(handle, data) },
                                     onEnd: { handle, end in await output.end(handle, end) })
        do { _ = try await exec.open(containerID: "container-one"); Issue.record("Rejected hijack was accepted") }
        catch let error as NativeRPCError {
            #expect(error.code == "docker-api" && !error.message.contains("env-secret"))
        }
        #expect(transport.pipe.closed)
        #expect(await exec.activeSessionCount == 0)
        #expect(await output.ends.isEmpty)
    }

    @Test func outputCallbackFailureClosesInsteadOfDroppingDataAndMasksErrorDetails() async throws {
        let transport = BackendDockerExecFixtureTransport()
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in
            throw NativeRPCError(code: "docker-api", message: "untrusted env-secret")
        }, onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        transport.pipe.send(Data("ready\n".utf8))
        await output.waitForEnd()
        #expect(await output.ends.first?.reason == "error")
        #expect(await output.ends.first?.error?.code == "docker-api")
        #expect(await output.ends.first?.error?.message.contains("env-secret") == false)
        #expect(transport.pipe.closed)
    }

    @Test func invalidCommandDimensionsAndResourcePathsDoNotTouchEngine() async throws {
        let transport = BackendDockerExecFixtureTransport()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in }, onEnd: { _, _ in })
        for id in ["../container", "container?force=true", ""] {
            do { _ = try await exec.open(containerID: id); Issue.record("Unsafe resource path was accepted") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        do { _ = try await exec.open(containerID: "container-one", command: []); Issue.record("Empty command was accepted") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        do { _ = try await exec.open(containerID: "container-one", rows: 0); Issue.record("Zero rows were accepted") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(await transport.requests.isEmpty)
    }

    @Test func terminalCapFailsBeforeAnotherEngineRequestAndShutdownDrainsAllHandles() async throws {
        let transport = BackendDockerExecFixtureTransport()
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in },
                                     onEnd: { handle, end in await output.end(handle, end) })
        for _ in 0..<BackendDockerExec.maximumSessions { _ = try await exec.open(containerID: "container-one") }
        let requestCount = await transport.requests.count
        do { _ = try await exec.open(containerID: "container-one"); Issue.record("The terminal limit was exceeded") }
        catch let error as NativeRPCError { #expect(error.code == "docker-stream-overflow") }
        #expect(await transport.requests.count == requestCount)
        await exec.shutdown()
        #expect(await exec.activeSessionCount == 0)
        #expect(await output.ends.count == BackendDockerExec.maximumSessions)
        #expect(await output.ends.allSatisfy { $0.reason == "closed" && $0.exitCode == nil })
    }

    @Test func shutdownCancelsBlockedExitInspectionAndPublishesClosedOnce() async throws {
        let transport = BackendDockerExecFixtureTransport(blockInspection: true)
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in },
                                     onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        transport.pipe.finish()
        await transport.inspectionStarted.wait()
        #expect(await exec.activeSessionCount == 1)
        await exec.shutdown()
        await transport.inspectionCancelled.wait()
        let ends = await output.ends
        #expect(ends.count == 1 && ends.first?.reason == "closed" && ends.first?.exitCode == nil)
        #expect(await exec.activeSessionCount == 0)
        #expect(transport.pipe.closed)
    }

    @Test func shutdownCancelsBlockedHijackBeforeAnOpenedSessionCanEscape() async throws {
        let transport = BackendDockerExecFixtureTransport(blockHijack: true)
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in },
                                     onEnd: { handle, end in await output.end(handle, end) })
        let opening = Task { try await exec.open(containerID: "container-one") }
        await transport.openingStarted.wait()
        await exec.shutdown()
        await transport.openingCancelled.wait()
        do { _ = try await opening.value; Issue.record("Shutdown allowed a pending terminal to open") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await exec.activeSessionCount == 0)
        #expect(await output.ends.isEmpty)
    }

    @Test func shutdownClosesAcquiredDuplexWhileInitialResizeIsBlocked() async throws {
        let transport = BackendDockerExecFixtureTransport(blockInitialResize: true)
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in }, onEnd: { _, _ in })
        let opening = Task { try await exec.open(containerID: "container-one") }
        await transport.openingStarted.wait()
        await exec.shutdown()
        #expect(transport.pipe.closed)
        await transport.openingCancelled.wait()
        do { _ = try await opening.value; Issue.record("Shutdown allowed a resized terminal to escape") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await exec.activeSessionCount == 0)
    }

    @Test func callerCancellationPropagatesIntoPendingHijack() async throws {
        let transport = BackendDockerExecFixtureTransport(blockHijack: true)
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in }, onEnd: { _, _ in })
        let opening = Task { try await exec.open(containerID: "container-one") }
        await transport.openingStarted.wait()
        opening.cancel()
        await transport.openingCancelled.wait()
        do { _ = try await opening.value; Issue.record("Cancelled caller received a terminal handle") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await exec.activeSessionCount == 0)
        await exec.shutdown()
    }

    @Test func closeCancelsBlockedDataCallbackAndPreventsSecondEnd() async throws {
        let transport = BackendDockerExecFixtureTransport()
        let output = BackendDockerExecFixtureOutput()
        let started = BackendDockerExecFixtureSignal()
        let cancelled = BackendDockerExecFixtureSignal()
        let gate = BackendDockerExecFixtureCancellationGate()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { handle, data in
            await started.mark()
            do { try await gate.wait() }
            catch { await cancelled.mark(); throw error }
            await output.data(handle, data)
        }, onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        transport.pipe.send(Data("ready\n".utf8))
        await started.wait()
        await exec.close(sessionID: handle.sessionID)
        await cancelled.wait()
        transport.pipe.finish()
        await exec.shutdown()
        let ends = await output.ends
        #expect(ends.count == 1 && ends.first?.reason == "closed")
        #expect(await output.bytes.isEmpty)
        #expect(transport.pipe.closed)
    }

    @Test func closeCancelsInFlightResizeRequest() async throws {
        let transport = BackendDockerExecFixtureTransport(blockResize: true)
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in },
                                     onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        let resize = Task { try await exec.resize(sessionID: handle.sessionID, columns: 100, rows: 40) }
        await transport.operationStarted.wait()
        await exec.close(sessionID: handle.sessionID)
        await transport.operationCancelled.wait()
        do { try await resize.value; Issue.record("A closed terminal completed a pending resize") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await output.ends.count == 1)
        #expect(transport.pipe.closed)
    }

    @Test func closeCancelsInFlightTerminalInput() async throws {
        let transport = BackendDockerExecFixtureTransport(blockWrite: true)
        let output = BackendDockerExecFixtureOutput()
        let exec = BackendDockerExec(client: BackendDockerClient(transport: transport), onData: { _, _ in },
                                     onEnd: { handle, end in await output.end(handle, end) })
        let handle = try await exec.open(containerID: "container-one")
        try await exec.activate(sessionID: handle.sessionID)
        let write = Task { try await exec.write(sessionID: handle.sessionID, data: Data("input".utf8)) }
        await transport.operationStarted.wait()
        await exec.close(sessionID: handle.sessionID)
        await transport.operationCancelled.wait()
        do { try await write.value; Issue.record("A closed terminal completed pending input") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        let ends = await output.ends
        #expect(ends.count == 1 && ends.first?.reason == "closed")
        #expect(await transport.written.isEmpty)
    }
}

/// All fixtures are Swift. They deliberately create no sockets or processes.
private actor BackendDockerExecFixtureTransport: BackendDockerTransport {
    nonisolated let pipe = BackendDockerExecFixturePipe()
    nonisolated let inspectionStarted = BackendDockerExecFixtureSignal()
    nonisolated let inspectionCancelled = BackendDockerExecFixtureSignal()
    nonisolated let inspectionGate = BackendDockerExecFixtureCancellationGate()
    nonisolated let openingStarted = BackendDockerExecFixtureSignal()
    nonisolated let openingCancelled = BackendDockerExecFixtureSignal()
    nonisolated let openingGate = BackendDockerExecFixtureCancellationGate()
    nonisolated let operationStarted = BackendDockerExecFixtureSignal()
    nonisolated let operationCancelled = BackendDockerExecFixtureSignal()
    nonisolated let operationGate = BackendDockerExecFixtureCancellationGate()
    private(set) var requests: [BackendDockerRequest] = []
    private(set) var written: [Data] = []
    let running: Bool
    let hijackStatus: Int
    let blockInspection: Bool
    let blockHijack: Bool
    let blockInitialResize: Bool
    let blockResize: Bool
    let blockWrite: Bool
    private var resizeCount = 0
    init(running: Bool = false, hijackStatus: Int = 101, blockInspection: Bool = false,
         blockHijack: Bool = false, blockInitialResize: Bool = false, blockResize: Bool = false, blockWrite: Bool = false) {
        self.running = running; self.hijackStatus = hijackStatus; self.blockInspection = blockInspection
        self.blockHijack = blockHijack; self.blockInitialResize = blockInitialResize
        self.blockResize = blockResize; self.blockWrite = blockWrite
    }
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        requests.append(request)
        let text: String
        let status: Int
        if request.path == "/version" {
            text = #"{"Version":"27.5.1","ApiVersion":"1.47","MinAPIVersion":"1.41","Os":"linux","Arch":"amd64"}"#; status = 200
        } else if request.path.hasSuffix("/containers/container-one/json") {
            text = #"{"Id":"container-one","Name":"/demo","Config":{"Tty":false,"Env":["TOKEN=env-secret"]},"State":{"Status":"running"}}"#; status = 200
        } else if request.path.hasSuffix("/containers/container-one/exec") {
            text = #"{"Id":"exec-one"}"#; status = 201
        } else if request.path.contains("/exec/exec-one/resize?") {
            resizeCount += 1
            if blockInitialResize { try await blockOpening() }
            if blockResize && resizeCount > 1 { try await blockOperation() }
            text = ""; status = 200
        } else if request.path.hasSuffix("/exec/exec-one/json") {
            if blockInspection {
                await inspectionStarted.mark()
                do { try await inspectionGate.wait() }
                catch { await inspectionCancelled.mark(); throw error }
            }
            text = running ? #"{"Running":true,"ExitCode":7}"# : #"{"Running":false,"ExitCode":7}"#; status = 200
        } else { throw NativeRPCError(code: "docker-api", message: "Unexpected fixture request") }
        return BackendDockerResponse(status: status, headers: [:], body: Data(text.utf8))
    }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream {
        throw NativeRPCError(code: "unavailable", message: "This terminal fixture has no ordinary HTTP stream")
    }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex {
        requests.append(request)
        if blockHijack { try await blockOpening() }
        return BackendDockerDuplex(status: hijackStatus, headers: ["content-type": "application/vnd.docker.raw-stream"], incoming: pipe.stream,
                                   write: { data in try await self.recordWrite(data) }, close: { self.pipe.close() })
    }
    private func recordWrite(_ data: Data) async throws {
        if blockWrite { try await blockOperation() }
        written.append(data)
    }
    private func blockOpening() async throws {
        await openingStarted.mark()
        do { try await openingGate.wait() }
        catch { await openingCancelled.mark(); throw error }
    }
    private func blockOperation() async throws {
        await operationStarted.mark()
        do { try await operationGate.wait() }
        catch { await operationCancelled.mark(); throw error }
    }
}

private final class BackendDockerExecFixturePipe: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var isClosed = false
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        stream = pair.stream; continuation = pair.continuation
    }
    func send(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
    func close() { lock.lock(); isClosed = true; lock.unlock(); continuation.finish() }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
}

private actor BackendDockerExecFixtureOutput {
    private(set) var bytes = Data()
    private(set) var handles: [BackendDockerExecHandle] = []
    private(set) var ends: [BackendDockerExecEnd] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func data(_ handle: BackendDockerExecHandle, _ data: Data) { handles.append(handle); bytes.append(data) }
    func end(_ handle: BackendDockerExecHandle, _ end: BackendDockerExecEnd) {
        handles.append(handle); ends.append(end)
        let waiters = waiters; self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitForEnd() async {
        if !ends.isEmpty { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor BackendDockerExecFixtureSignal {
    private var marked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func mark() {
        marked = true
        let waiters = waiters; self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        if marked { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class BackendDockerExecFixtureCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in install(continuation) }
        } onCancel: { self.cancel() }
    }
    private func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); let alreadyCancelled = cancelled
        if !alreadyCancelled { self.continuation = continuation }
        lock.unlock()
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
