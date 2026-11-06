import CoreVideo
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("fix-29a sign-in and capture handover", .serialized)
struct Fix29aMacReachTests {
    private actor Gate {
        var entered = false
        var released = false
        var calls = 0
        var cancelled = false
        var finished = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { waiter = $0 } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
        func called() { calls += 1 }
        func cancel() { cancelled = true }
        func finish() { finished = true }
    }
    private actor Frames {
        var values: [NativeRPCValue] = []
        func add(_ text: String) throws { values.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func hasError(_ rid: String) -> Bool {
            values.contains { $0["t"].string == "error" && $0["rid"].string == rid && $0["message"].string == BackendMacSignInAttempt.failureWords }
        }
    }
    private func until(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeRPCError(code: "fixture-timeout", message: "The regression fixture did not finish.")
    }
    @Test func signInRefusesABusyHostWithoutWaitingOrReplaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fix29a-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root)
        try await trust.open()
        let device = try await trust.redeem(try await trust.createPairingOffer().token, name: "Fixture", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let gate = Gate(), frames = Frames()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: root.path, hostName: "Fixture", appVersion: "test", privateRoots: [])
        try await host.register(.init(capability: "sims", messageTypes: ["sims.list", "sims.unlock"], policy: .ownerOnly) { message, _ in
            if message.type == "sims.list" { await gate.wait() } else { await gate.called() }
            return []
        })
        try await host.start()
        let id = try #require(await host.accept(.init(address: "fixture", send: { try await frames.add($0) }, close: { _, _ in })))
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Fixture")), .init("platform", .string("ios"))])),
            .init("capabilities", .array([.string("device.access")]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        let slow = try #require(await host.take(id, text: #"{"t":"sims.list","rid":"slow"}"#))
        try await until { await gate.entered }
        let signIn = try #require(await host.take(id, text: #"{"t":"sims.unlock","rid":"busy","id":"mac:main","password":"fixture"}"#))
        await signIn.answered.value
        #expect(await frames.hasError("busy"))
        #expect(await gate.calls == 0)
        await gate.release(); await slow.answered.value
        #expect(await gate.calls == 0)
        // A fresh attempt when idle still reaches the feature.
        await host.receive(id, text: #"{"t":"sims.unlock","rid":"fresh","id":"mac:main","password":"fixture"}"#)
        #expect(await gate.calls == 1)
        await host.stop(); await trust.close()
    }

    private func context() -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "fixture", kind: .mine, address: "fixture", peerPublicKey: nil, claimedCapabilities: [],
            reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .full)
    }
    private func devices(_ gate: Gate) -> BackendPhoneDevices {
        var source = BackendPhoneDevices.Source(list: { .object([]) }, power: { _, _ in .object([]) },
            stream: { _, _ in throw BackendMacSignInAttempt.failure }, input: { _, _ in await gate.wait() },
            shot: { _ in throw BackendMacSignInAttempt.failure }, deliver: { _ in "" }, visibleSessions: { _ in [] }, send: { _, _ in })
        source.macSignIn = { _, _ in
            let attempt = try #require(BackendMacSignInAttempt.current)
            try attempt.check(); await gate.called()
        }
        return BackendPhoneDevices(source: source)
    }
    private func unlock() -> BackendRemoteClientMessage {
        .init(.object([.init("t", .string("sims.unlock")), .init("rid", .string("fixture")), .init("id", .string("mac:main")), .init("password", .string("fixture"))]))
    }
    @Test func signInRefusesPendingDisplayInputAndDoesNotReplay() async throws {
        let gate = Gate(), devices = devices(gate), context = context()
        await devices.fix29aOpen(context)
        _ = try await devices.handle(.init(.object([.init("t", .string("sims.input")), .init("id", .string("mac:main")),
            .init("do", .string("key")), .init("key", .string("tab"))])), context: context)
        try await until { await gate.entered }
        await #expect(throws: (any Error).self) { try await devices.handle(unlock(), context: context) }
        #expect(await gate.calls == 0)
        await gate.release()
        try await until { await devices.fix29aInputIdle() }
        _ = try await devices.handle(unlock(), context: context)
        #expect(await gate.calls == 1)
        await devices.stopAll()
    }
    @Test func expiryAndCancellationReachTheSecureFieldBoundary() async throws {
        let gate = Gate(), devices = devices(gate), context = context()
        await devices.fix29aOpen(context)
        let expired = BackendMacSignInAttempt(expiresAt: ProcessInfo.processInfo.systemUptime - 1)
        await #expect(throws: (any Error).self) {
            try await BackendMacSignInAttempt.$current.withValue(expired) { try await devices.handle(unlock(), context: context) }
        }
        let attempt = BackendMacSignInAttempt()
        try attempt.check()
        attempt.cancel()
        #expect(throws: (any Error).self) { try attempt.check() }
        #expect(await gate.calls == 0)
        await devices.stopAll()
    }

    private final class XPCFixture: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let receiver: BackendMacReachRequest
        init(_ handler: @escaping @Sendable (String, Data) async throws -> Data) {
            receiver = BackendMacReachRequest(handler: handler)
            super.init(); listener.delegate = self; listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: BackendMacReachRPC.self)
            connection.exportedObject = receiver
            connection.resume()
            return true
        }
        func client() -> BackendMacReachClient {
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: BackendMacReachRPC.self)
            connection.resume()
            return BackendMacReachClient(connection: connection)
        }
    }
    @Test func expiredPasswordNeverReachesTheHelperHandler() async throws {
        let gate = Gate()
        let receiver = BackendMacReachRequest { _, _ in await gate.called(); return Data() }
        let payload = try NativeRPCValue.object([.init("expiresAt", .number(ProcessInfo.processInfo.systemUptime - 1)),
            .init("password", .string("fixture"))]).encodedJSON()
        let refused: Bool = await withCheckedContinuation { continuation in
            receiver.request("password", id: UUID().uuidString, payload: payload) { data, problem in
                continuation.resume(returning: data == nil && problem == BackendMacSignInAttempt.failureWords)
            }
        }
        #expect(refused)
        #expect(await gate.calls == 0)
    }

    @Test func helperTimeoutCancelsItsRemoteRequest() async throws {
        let gate = Gate()
        let fixture = XPCFixture { _, _ in
            await gate.called()
            return try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
                return Data()
            } onCancel: { Task { await gate.cancel() } }
        }
        defer { fixture.listener.invalidate() }
        let client = fixture.client()
        await #expect(throws: (any Error).self) { try await client.request("fixture", timeout: 0.15) }
        try await until { await gate.cancelled }
        #expect(await gate.calls == 1)
        client.close()
    }
    @Test func cancellingAForwardedPasswordCannotTypeAfterTheCallerLeaves() async throws {
        let gate = Gate()
        let agent = XPCFixture { _, _ in
            try await withTaskCancellationHandler {
                defer { Task { await gate.finish() } }
                await gate.wait()
                let attempt = try #require(BackendMacSignInAttempt.current)
                try attempt.check()
                await gate.called()
                return Data()
            } onCancel: { Task { await gate.cancel() } }
        }
        let agentClient = agent.client()
        let daemon = XPCFixture { command, payload in try await agentClient.request(command, payload: payload) }
        defer { agent.listener.invalidate(); daemon.listener.invalidate() }
        let client = daemon.client()
        let request = Task { try await client.value("password", .object([.init("password", .string("fixture"))])) }
        try await until { await gate.entered }
        request.cancel()
        _ = await request.result
        // The fake keystroke deliberately ignores cancellation until it is ready to post.
        try await until { await gate.cancelled }
        await gate.release()
        try await until { await gate.finished }
        #expect(await gate.calls == 0)
        client.close(); agentClient.close()
    }
    @Test func passwordIsRefusedAtTheHelperWhileOtherWorkRuns() async throws {
        let gate = Gate()
        let fixture = XPCFixture { command, _ in
            if command == "fixture" { await gate.wait() } else { await gate.called() }
            return Data()
        }
        defer { fixture.listener.invalidate() }
        let client = fixture.client()
        let busy = Task { try await client.request("fixture") }
        try await until { await gate.entered }
        await #expect(throws: (any Error).self) { try await client.value("password", .object([])) }
        #expect(await gate.calls == 0)
        await gate.release(); _ = try await busy.value
        client.close()
    }

    private actor CaptureFixture {
        var selected: Int? = 0
        var opens: [Int] = []
        var cursors: [Int] = []
        let ids = [UUID(), UUID()]
        func select(_ index: Int?) { selected = index }
        func agent() -> BackendMacReachScreenAgent? {
            guard let index = selected else { return nil }
            return .init(id: ids[index]) { command, value, _ in try await self.request(index, command, value) }
        }
        func request(_ index: Int, _ command: String, _ value: NativeRPCValue) throws -> Data {
            if command == "close" { return Data() }
            guard selected == index else { throw BackendMacSignInAttempt.failure }
            if command == "open" { opens.append(index); return Data() }
            if command == "cursor" { if value["phone"].bool == true { cursors.append(index) }; return Data() }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { throw BackendMacSignInAttempt.failure }
            return try BackendMacReachPixels.encode(buffer, capturedAt: Double(index + 1))
        }
    }
    @Test func watchFollowsReplacementCaptureAgentWithoutEnding() async throws {
        let fixture = CaptureFixture()
        let stream = BackendMacReachStream(display: "mac:main", agent: { await fixture.agent() })
        await stream.drawsPointer(true)
        guard case .pixels(let first) = await stream.pixels(within: 0) else { Issue.record("Initial capture missing"); return }
        #expect(first.capturedAt == 1)
        await fixture.select(nil)
        guard case .unchanged = await stream.pixels(within: 0) else { Issue.record("Handover ended the watch"); return }
        #expect(await stream.isStarting())
        await fixture.select(1)
        guard case .pixels(let next) = await stream.pixels(within: 0) else { Issue.record("Replacement capture missing"); return }
        #expect(next.capturedAt == 2)
        #expect(await !stream.isStarting())
        #expect(await fixture.opens == [0, 1])
        #expect(await fixture.cursors == [0, 1])
        await stream.stop()
        guard case .ended = await stream.pixels(within: 0) else { Issue.record("Stopped watch restarted"); return }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 100.0
        func now() -> Double { lock.withLock { value } }
        func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    }
    @Test func missingCaptureAgentHasABoundedStartingInterval() async throws {
        let clock = Clock()
        let stream = BackendMacReachStream(display: "mac:main", agent: { nil }, clock: { clock.now() })
        guard case .unchanged = await stream.pixels(within: 0) else { Issue.record("No starting interval"); return }
        clock.advance(10.1)
        guard case .ended = await stream.pixels(within: 0) else { Issue.record("Starting interval was unbounded"); return }
        #expect(await stream.endReason() == "The Mac screen couldn't start. Try again.")
    }
}

extension BackendPhoneDevices {
    fileprivate func fix29aOpen(_ context: BackendRemoteHostContext) {
        watches[WatchKey(connection: context.connectionID, device: "mac:main")] = Watch(fps: 20, started: 0, name: "Fixture", deviceName: "Mac")
    }
    fileprivate func fix29aInputIdle() -> Bool { pendingInputs["mac:main", default: 0] == 0 }
}
