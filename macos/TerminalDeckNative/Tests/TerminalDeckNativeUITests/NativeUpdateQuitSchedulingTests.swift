import AppKit
import XCTest
@testable import TerminalDeckNative

@MainActor
final class NativeUpdateQuitSchedulingTests: XCTestCase {
    func testUpdateQuitCanReceiveMainActorRepliesInsideAppKitsNestedEventLoop() {
        let replied = expectation(description: "the main actor can answer the nested quit loop")
        NativeAppUpdater.scheduleQuit {
            var answered = false
            Task { @MainActor in answered = true }
            let deadline = Date().addingTimeInterval(1)
            while !answered, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(answered, "a quit inside DispatchQueue.main.async holds the main queue and cannot receive this reply")
            replied.fulfill()
        }
        wait(for: [replied], timeout: 3)
    }
}
