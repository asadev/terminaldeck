import XCTest
@testable import TerminalDeckBackend

final class HOSTReadyBarrierTests: XCTestCase {
    func testReadyBeforeWaitAndRepeatedWait() async throws {
        let barrier = BackendHOSTReadyBarrier()
        barrier.finish(nil)
        try await barrier.wait(timeout: 0)
        try await barrier.wait(timeout: 0)
    }
    func testReadyWakesAllWaiters() async throws {
        let barrier = BackendHOSTReadyBarrier()
        async let first: Void = barrier.wait(timeout: 2)
        async let second: Void = barrier.wait(timeout: 2)
        Task { barrier.finish(nil) }
        _ = try await (first, second)
    }
    func testTimeoutDoesNotPoisonLaterReady() async throws {
        let barrier = BackendHOSTReadyBarrier()
        do { try await barrier.wait(timeout: 0.01); XCTFail("unready helper reported success") }
        catch { XCTAssertTrue(error is BackendHOSTFailure) }
        barrier.finish(nil)
        try await barrier.wait(timeout: 0)
    }
    func testDisconnectWinsOverLateReady() async {
        let barrier = BackendHOSTReadyBarrier()
        barrier.finish(BackendHOSTFailure.unavailable); barrier.finish(nil)
        do { try await barrier.wait(timeout: 1); XCTFail("disconnected helper reported success") }
        catch { XCTAssertTrue(error is BackendHOSTFailure) }
    }
}
