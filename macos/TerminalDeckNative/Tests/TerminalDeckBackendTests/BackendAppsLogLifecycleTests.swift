import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APE log source lifecycle: Swift tasks, no remote processes")
struct BackendAppsLogLifecycleTests {
    @Test func eofFlushesSplitSecretsAndCompletesSourceCancellation() async throws {
        let fixture = BackendAppsLogLifecycleFixture()
        let service = fixture.service()
        _ = try await service.invoke("apps:logs:watch", request: request(app: "td-test-one", stream: "td-test-view-one"), context: context("td-test-window-one"))
        let source = try #require(await fixture.source(app: "td-test-one"))
        await source.emit(.text("pending protected-"))
        await source.emit(.text("secret and image-"))
        await source.emit(.text("secret"))
        await source.emit(.ended(failed: false))

        let finished = await eventually {
            let state = await source.snapshot()
            let events = await fixture.events
            return state.cancellationCompleted && state.finished &&
                events.contains { $0.channel == "apps:logs:end" && $0.value["reason"].string == "eof" }
        }
        #expect(finished, "EOF callback waited on the source task that was executing it")
        let events = await fixture.events
        let text = events.filter { $0.channel == "apps:logs" }.compactMap { $0.value["text"].string }.joined()
        #expect(text.contains("pending "))
        #expect(text.contains("[redacted]"))
        #expect(!text.contains("protected-secret"))
        #expect(!text.contains("image-secret"))
        #expect(events.filter { $0.channel == "apps:logs:end" }.count == 1)
        #expect(events.allSatisfy { $0.owner == "td-test-window-one" })
        let state = await source.snapshot()
        #expect(state.closeCalls == 1)
        await service.shutdown()
    }

    @Test func oversizedPendingLineClosesWithoutPublishingRawSecrets() async throws {
        let fixture = BackendAppsLogLifecycleFixture()
        let service = fixture.service()
        _ = try await service.invoke("apps:logs:watch", request: request(app: "td-test-one", stream: "td-test-overflow"), context: context("td-test-window-one"))
        let source = try #require(await fixture.source(app: "td-test-one"))
        await source.emit(.text(String(repeating: "x", count: 262_145) + "protected-secret"))
        let finished = await eventually {
            let state = await source.snapshot()
            let events = await fixture.events
            return state.cancellationCompleted && state.finished &&
                events.contains { $0.channel == "apps:logs:end" && $0.value["reason"].string == "overflow" }
        }
        #expect(finished, "Overflow callback waited on its own source task")
        let events = await fixture.events
        #expect(!events.contains { $0.channel == "apps:logs" })
        #expect(events.allSatisfy { !$0.value.compact.contains("protected-secret") })
        #expect(events.filter { $0.channel == "apps:logs:end" }.count == 1)
        let state = await source.snapshot()
        #expect(state.closeCalls == 1)
        await service.shutdown()
    }

    @Test func ownerDisconnectWaitsForOnlyItsOwnSource() async throws {
        let fixture = BackendAppsLogLifecycleFixture()
        let service = fixture.service()
        _ = try await service.invoke("apps:logs:watch", request: request(app: "td-test-one", stream: "td-test-view-one"), context: context("td-test-window-one"))
        _ = try await service.invoke("apps:logs:watch", request: request(app: "td-test-two", stream: "td-test-view-two"), context: context("td-test-window-two"))
        let first = try #require(await fixture.source(app: "td-test-one"))
        let second = try #require(await fixture.source(app: "td-test-two"))
        await service.disconnect(ownerID: "td-test-window-one")
        let firstState = await first.snapshot()
        let secondState = await second.snapshot()
        #expect(firstState.cancellationCompleted && firstState.finished && firstState.closeCalls == 1)
        #expect(secondState.closeCalls == 0 && !secondState.finished)

        await second.emit(.text("still serving protected-secret\n"))
        let received = await eventually {
            let events = await fixture.events
            return events.contains { $0.owner == "td-test-window-two" && $0.channel == "apps:logs" }
        }
        #expect(received)
        let events = await fixture.events
        #expect(events.allSatisfy { $0.owner == "td-test-window-two" })
        #expect(events.allSatisfy { !$0.value.compact.contains("protected-secret") })
        await service.disconnect(ownerID: "td-test-window-two")
        let final = await second.snapshot()
        #expect(final.cancellationCompleted && final.finished && final.closeCalls == 1)
        #expect(fixture.remoteProcessesStillRunning)
        #expect(await fixture.dockerMutations == 0)
    }

    @Test func cancelledCallerCleanupClosesReadAndDoesNotClaimRemoteExit() async throws {
        let gate = BackendAppsLogLifecycleGate()
        let fixture = BackendAppsLogLifecycleFixture(startGate: gate)
        let service = fixture.service()
        let request = request(app: "td-test-one", stream: "td-test-cancelled-view")
        let context = context("td-test-cancelled-window")
        let caller = Task { try await service.invoke("apps:logs:watch", request: request, context: context) }
        let opened = await eventually { await gate.hasWaiter() }
        #expect(opened)
        let source = try #require(await fixture.source(app: "td-test-one"))
        caller.cancel()
        // This is the owner's existing lifecycle cleanup, not a remote process operation.
        await service.disconnect(ownerID: context.ownerID)
        await gate.release()
        switch await caller.result {
        case .success: Issue.record("A cancelled, closed view claimed that its watch was still open")
        case .failure(let error): #expect((error as? NativeRPCError)?.code == "cancelled")
        }
        let state = await source.snapshot()
        #expect(state.cancellationCompleted && state.finished && state.closeCalls == 1)
        #expect(fixture.remoteProcessesStillRunning)
        #expect(await fixture.dockerMutations == 0)
        let events = await fixture.events
        #expect(!events.contains { $0.value["reason"].string == "eof" })
        #expect(!events.contains { $0.value.has("exitCode") || $0.value.has("processExited") })
        await service.shutdown()
    }

    private func request(app: String, stream: String) -> NativeRPCValue {
        BackendAppsValidation.object([("serverId", .string("td-test-server")), ("appId", .string(app)), ("streamId", .string(stream))])
    }
    private func context(_ owner: String) -> NativeRPCContext { .init(caller: .nativeApp, ownerID: owner) }
    /// A regression must fail promptly rather than hang SwiftPM on a self-awaiting source.
    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor BackendAppsLogLifecycleFixture {
    struct Event: Sendable { let channel: String; let value: NativeRPCValue; let owner: String }
    private let startGate: BackendAppsLogLifecycleGate?
    private var sources: [String: BackendAppsLogLifecycleSource] = [:]
    private(set) var events: [Event] = []
    private(set) var dockerMutations = 0
    // This fixture owns only log subscriptions. A stopped read cannot imply a remote exit.
    let remoteProcessesStillRunning = true
    init(startGate: BackendAppsLogLifecycleGate? = nil) { self.startGate = startGate }
    nonisolated func service() -> BackendAppsChannels {
        let runtime = BackendAppsRuntime(execute: { [self] _, command, _, _, _ in try await execute(command) },
            docker: { [self] _, method, path, _ in try await inspect(method, path) },
            watchLogs: { [self] _, container, callback in await open(container, receive: callback) },
            privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps")
        return BackendAppsChannels(runtime: runtime, authorize: { _, _ in },
                                   publish: { [self] channel, value, owner in await receive(channel, value, owner) })
    }
    func source(app: String) -> BackendAppsLogLifecycleSource? { sources[Self.container(app)] }
    private static func container(_ app: String) -> String { String(repeating: app == "td-test-one" ? "a" : "b", count: 64) }
    private func execute(_ command: String) throws -> BackendServersRunResult {
        for app in ["td-test-one", "td-test-two"] {
            if command.contains("/\(app)/state.json"), command.contains("cat --") {
                let record = BackendAppsValidation.object([("id", .string(app)), ("name", .string(app)), ("kind", .string("app")), ("status", .string("running")), ("containerId", .string(Self.container(app)))])
                return .init(code: 0, stdout: record.compact)
            }
            if command.contains("/\(app)/.env"), command.contains("cat --") {
                return .init(code: 0, stdout: "TOKEN=protected-secret\n")
            }
        }
        throw NativeRPCError(code: "unavailable", message: "The log fixture received an unexpected server operation.")
    }
    private func inspect(_ method: String, _ path: String) throws -> BackendAppsHTTPResponse {
        guard method == "GET" else {
            dockerMutations += 1
            throw NativeRPCError(code: "access-denied", message: "This log fixture never changes a remote process.")
        }
        let app = path.contains(Self.container("td-test-one")) ? "td-test-one" : "td-test-two"
        let value = BackendAppsValidation.object([("Config", BackendAppsValidation.object([
            ("Labels", BackendAppsValidation.object([("io.terminaldeck.app", .string(app)), ("io.terminaldeck.managed", .string("true"))])),
            ("Env", .array([.string("TOKEN=image-secret")]))
        ]))])
        return .init(status: 200, body: try value.encodedJSON())
    }
    private func open(_ container: String, receive: @escaping @Sendable (BackendAppsLogEvent) async -> Void) async -> NativeRPCSubscription {
        let source = BackendAppsLogLifecycleSource()
        sources[container] = source
        let subscription = await source.start(receive)
        if let startGate { await startGate.wait() }
        return subscription
    }
    private func receive(_ channel: String, _ value: NativeRPCValue, _ owner: String) {
        events.append(Event(channel: channel, value: value, owner: owner))
    }
}

/// Deliberately matches DKA's source: cancellation waits for the task that awaits callbacks.
/// Calling cancelAndWait from inside such a callback is a cycle; calling cancel is safe.
private actor BackendAppsLogLifecycleSource {
    struct Snapshot: Sendable { let closeCalls: Int; let finished: Bool; let cancellationCompleted: Bool }
    private let input: AsyncStream<BackendAppsLogEvent>
    private let continuation: AsyncStream<BackendAppsLogEvent>.Continuation
    private var task: Task<Void, Never>?
    private var closeCalls = 0
    private var finished = false
    private var cancellationCompleted = false
    init() {
        let pair = AsyncStream<BackendAppsLogEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        input = pair.stream; continuation = pair.continuation
    }
    func start(_ receive: @escaping @Sendable (BackendAppsLogEvent) async -> Void) -> NativeRPCSubscription {
        let input = self.input
        let task: Task<Void, Never> = Task { [weak self] in
            for await event in input {
                await receive(event)
                if case .ended = event { break }
            }
            await self?.didFinish()
        }
        self.task = task
        return NativeRPCSubscription { [self] in await close() }
    }
    func emit(_ event: BackendAppsLogEvent) { continuation.yield(event) }
    func snapshot() -> Snapshot { Snapshot(closeCalls: closeCalls, finished: finished, cancellationCompleted: cancellationCompleted) }
    private func didFinish() { finished = true }
    private func close() async {
        closeCalls += 1
        continuation.finish()
        task?.cancel()
        await task?.value
        cancellationCompleted = true
    }
}

private actor BackendAppsLogLifecycleGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hasWaiter() -> Bool { waiter != nil }
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
