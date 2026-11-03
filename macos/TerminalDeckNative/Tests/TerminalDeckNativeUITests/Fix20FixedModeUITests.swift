import Foundation
import XCTest

final class Fix20FixedModeUITests: XCTestCase {
    func testNoSessionButtonOrLocalToolOffersAModeChange() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources/TerminalDeckNative")
        // A source entry-point audit complements the backend refusal test: no live app or personal session is needed.
        for file in ["NativeSessionHeader.swift", "NativeTerminalSession.swift", "NativeCompositionSessionChats.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for retired in ["Open as Chat", "Open as Terminal", "session:reopen", "sessions_reopen", "BackendSessionModeHandover", "reopen(asChat:"] {
                XCTAssertFalse(source.contains(retired), "\(file) still offers \(retired)")
            }
        }
    }
}
