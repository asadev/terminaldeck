import XCTest
@testable import TerminalDeckNative

/// U112 (#98): a scraping worker's ask to borrow a signed-in session can be answered on a page the app shows.
final class ScrapingLiftAsksTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + file), encoding: .utf8)
    }
    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return text[a.lowerBound..<b.lowerBound]
    }

    func testBrowserSettingsShowWaitingLiftAsksWithApproveAndDecline() throws {
        // ⋮ ▸ Scraping opens the scraping route, which is the Browser page, which mounts the capture settings.
        XCTAssertTrue(try source("TerminalDeckNative/NativeScreens.swift").contains("case \"scraping\": return AnyView(NativeScrapingSettings())"))
        XCTAssertTrue(try source("TerminalDeckNative/NativeBrowserSettings.swift").contains("NativeBrowserCaptureSettings()"))
        let scraping = try source("TerminalDeckNative/NativeScrapingSettings.swift")
        XCTAssertTrue(scraping.contains("struct NativeScrapingSettings: View {\n    var body: some View { NativeBrowserSettings() }"))
        let shown = try slice(scraping, from: "struct NativeBrowserCaptureSettings: View", to: "private struct NativeScrapingLiftAsks")
        XCTAssertTrue(shown.contains("NativeScrapingLiftAsks(model: model)"), "the shown page lists the waiting asks")
        XCTAssertTrue(shown.contains("model.start()"), "the shown page loads the asks and follows new ones")
        let asks = try slice(scraping, from: "private struct NativeScrapingLiftAsks", to: "// MARK: - The body")
        XCTAssertTrue(asks.contains("model.answer(ask, approve: true)"))
        XCTAssertTrue(asks.contains("model.answer(ask, approve: false)"))
        let model = try slice(scraping, from: "final class NativeScrapingModel", to: "func install(")
        XCTAssertTrue(model.contains("\"browser-worker:lift-answer\""))
        XCTAssertTrue(model.contains("EngineBridge.shared.on(\"browser-worker:lift-request\")"))
    }
}
