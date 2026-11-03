import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor GHMCPStreamSource: BackendGHJobLogStreaming {
    private var continuations: [AsyncThrowingStream<NativeRPCValue, Error>.Continuation] = []
    private let began: @Sendable (Int) -> Void
    private let ended: @Sendable (Int) -> Void
    init(began: @escaping @Sendable (Int) -> Void = { _ in }, ended: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.began = began; self.ended = ended
    }
    func streamJobLogs(arguments: NativeRPCValue) async -> AsyncThrowingStream<NativeRPCValue, Error> {
        let pair = AsyncThrowingStream<NativeRPCValue, Error>.makeStream()
        let index = continuations.count
        pair.continuation.onTermination = { [ended] _ in ended(index) }
        continuations.append(pair.continuation)
        began(index)
        return pair.stream
    }
    func emit(_ index: Int, text: String) {
        continuations[index].yield(.object([.init("text", .string(text)), .init("complete", .bool(false))]))
    }
    func count() -> Int { continuations.count }
}
private actor GHMCPStreamEvents {
    private var values: [NativeRPCEvent] = []
    func append(_ value: NativeRPCEvent) { values.append(value) }
    func events() -> [NativeRPCEvent] { values }
}

@MainActor
final class GHMCPLogChannelTests: XCTestCase {
    private func context(_ owner: String = "viewer-one", caller: NativeRPCContext.Caller = .nativeApp) -> NativeRPCContext {
        .init(caller: caller, ownerID: owner)
    }
    private func arguments(_ id: String = UUID().uuidString) -> NativeRPCValue {
        .object([.init("repo", .string("sample/deck")), .init("jobId", .number(10)), .init("streamId", .string(id))])
    }
    func testNonNativeCallersCannotOpenOrCloseAnyLogStream() async throws {
        let source = GHMCPStreamSource(), registry = NativeChannelRegistry(), logs = BackendGHLogChannels(service: source, registry: registry)
        try await logs.register(ownerID: "github-owner")
        let id = UUID().uuidString
        for caller in [NativeRPCContext.Caller.page, .pairedDevice, .internalEngine] {
            for (channel, payload) in [("github:logs:open", arguments(id)), ("github:logs:close", NativeRPCValue.string(id))] {
                do { _ = try await registry.invoke(channel, context: context(caller: caller), arguments: [payload]); XCTFail("Non-native caller reached log service") }
                catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "access-denied") }
            }
        }
        let started = await source.count(); XCTAssertEqual(started, 0)
        await logs.shutdown()
    }
    func testMalformedStreamAndJobInputsFailBeforeWorkStarts() async throws {
        let source = GHMCPStreamSource(), registry = NativeChannelRegistry(), logs = BackendGHLogChannels(service: source, registry: registry)
        try await logs.register(ownerID: "github-owner")
        for payload in [arguments("not-a-uuid"), arguments().setting("jobId", .number(0)), arguments().setting("repo", .string("../outside"))] {
            do { _ = try await registry.invoke("github:logs:open", context: context(), arguments: [payload]); XCTFail("Malformed stream ran") }
            catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "invalid-arguments") }
        }
        let started = await source.count(); XCTAssertEqual(started, 0)
        await logs.shutdown()
    }
    func testPrivateLogEventsReachOnlyTheOwningViewer() async throws {
        let started = expectation(description: "stream began"), received = expectation(description: "own viewer received text")
        let foreign = expectation(description: "other owner receives no private logs"); foreign.isInverted = true
        let source = GHMCPStreamSource(began: { _ in started.fulfill() }), registry = NativeChannelRegistry()
        let logs = BackendGHLogChannels(service: source, registry: registry), events = GHMCPStreamEvents()
        try await logs.register(ownerID: "github-owner")
        let own = try await registry.subscribe(BackendGHLogChannels.event, ownerID: "viewer-one") { event in await events.append(event); received.fulfill() }
        let other = try await registry.subscribe(BackendGHLogChannels.event, ownerID: "viewer-two") { _ in foreign.fulfill() }
        let id = UUID().uuidString
        _ = try await registry.invoke("github:logs:open", context: context(), arguments: [arguments(id)])
        await fulfillment(of: [started], timeout: 1)
        await source.emit(0, text: "private CI output")
        await fulfillment(of: [received, foreign], timeout: 0.1)
        let values = await events.events()
        XCTAssertEqual(values.first?.ownerID, "viewer-one"); XCTAssertEqual(values.first?.arguments.first?["streamId"], .string(id))
        await own.cancelAndWait(); await other.cancelAndWait(); await logs.shutdown()
    }
    func testForeignOwnerCannotReplaceOrCloseStreamAndOwnerCloseCancelsIt() async throws {
        let started = expectation(description: "stream began"), ended = expectation(description: "stream cancelled")
        let source = GHMCPStreamSource(began: { _ in started.fulfill() }, ended: { _ in ended.fulfill() })
        let registry = NativeChannelRegistry(), logs = BackendGHLogChannels(service: source, registry: registry)
        try await logs.register(ownerID: "github-owner")
        let id = UUID().uuidString
        _ = try await registry.invoke("github:logs:open", context: context(), arguments: [arguments(id)])
        await fulfillment(of: [started], timeout: 1)
        for (channel, payload) in [("github:logs:open", arguments(id)), ("github:logs:close", NativeRPCValue.string(id))] {
            do { _ = try await registry.invoke(channel, context: context("viewer-two"), arguments: [payload]); XCTFail("Another owner changed a stream") }
            catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "access-denied") }
        }
        let beforeClose = await source.count(); XCTAssertEqual(beforeClose, 1)
        _ = try await registry.invoke("github:logs:close", context: context(), arguments: [.string(id)])
        await fulfillment(of: [ended], timeout: 1)
        await logs.shutdown()
    }
    func testStreamLimitReplacementAndShutdownKeepOneCurrentGeneration() async throws {
        let firstFour = expectation(description: "four viewers started"); firstFour.expectedFulfillmentCount = 4
        let replacement = expectation(description: "replacement started"), current = expectation(description: "current generation received")
        let ended = expectation(description: "all five generations cancelled"); ended.expectedFulfillmentCount = 5
        let source = GHMCPStreamSource(began: { index in if index < 4 { firstFour.fulfill() } else { replacement.fulfill() } }, ended: { _ in ended.fulfill() })
        let registry = NativeChannelRegistry(), logs = BackendGHLogChannels(service: source, registry: registry), events = GHMCPStreamEvents()
        try await logs.register(ownerID: "github-owner")
        let listener = try await registry.subscribe(BackendGHLogChannels.event, ownerID: "viewer-one") { event in await events.append(event); current.fulfill() }
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids { _ = try await registry.invoke("github:logs:open", context: context(), arguments: [arguments(id)]) }
        await fulfillment(of: [firstFour], timeout: 1)
        do { _ = try await registry.invoke("github:logs:open", context: context(), arguments: [arguments()]); XCTFail("A fifth simultaneous stream opened") }
        catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "too-many-streams") }
        let limitedCount = await source.count(); XCTAssertEqual(limitedCount, 4)
        _ = try await registry.invoke("github:logs:open", context: context(), arguments: [arguments(ids[0])])
        await fulfillment(of: [replacement], timeout: 1)
        await source.emit(0, text: "stale old generation")
        await source.emit(4, text: "current generation")
        await fulfillment(of: [current], timeout: 1)
        let values = await events.events()
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.arguments.first?["text"], .string("current generation"))
        await logs.shutdown()
        await fulfillment(of: [ended], timeout: 1)
        do { _ = try await registry.invoke("github:logs:open", context: context(), arguments: [arguments()]); XCTFail("Stopped owner opened new work") }
        catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "unavailable") }
        await listener.cancelAndWait()
    }
}
