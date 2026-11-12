import Foundation
import XCTest
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

/// Release review 0614, finding 3: while screenshots stand in for a simulator's direct screen, a still screen must not
/// be screenshotted back to back (one screenshot takes about as long as a 0.25 s slice, so the still stream's own
/// pause never came).
@MainActor final class PhoneStillPauseTests: XCTestCase {
    private actor Counter { var count = 0; func add() { count += 1 } }
    override func setUp() async throws { NativeCompositionRoot.noteSink = { _ in } }
    override func tearDown() async throws { NativeCompositionRoot.noteSink = nil }

    func testAStillScreenPausesBetweenScreenshots() async {
        let counter = Counter()
        // A screenshot takes 0.3 s and the screen never changes (the bytes are not a picture, so never "new").
        let still = BackendPhoneDeviceStillStream(capture: {
            await counter.add()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return Data([1, 2, 3])
        })
        // No device id: the direct screen is never found, so screenshots stand in at once.
        let stream = NativePhoneSwitchingStream(id: "still", row: .object([]), screens: NativePhoneDeviceScreens(), still: still)
        let span = 3.0, start = Date()
        while Date().timeIntervalSince(start) < span {
            if case .ended = await stream.pixels(within: 0.5) { break }
        }
        await stream.stop()
        let count = await counter.count
        // Back to back: about span / 0.3 = 10. With the 0.2 s pause: about span / 0.5 = 6.
        XCTAssertGreaterThanOrEqual(count, 2, "screenshots still stand in")
        XCTAssertLessThanOrEqual(count, 7, "a still screen waits \(NativePhoneSwitchingStream.stillPause) s between screenshots (got \(count) in \(span) s)")
    }
}
