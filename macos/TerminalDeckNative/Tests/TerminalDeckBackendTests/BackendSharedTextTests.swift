import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedTextTests: XCTestCase {
    func testByteUnitsAndPasteBoundary() {
        XCTAssertEqual(BackendSharedText.byteSize(1048576), "1.0 MB")
        XCTAssertEqual(BackendSharedText.byteSize(3400000), "3.4 MB")
        XCTAssertEqual(BackendSharedText.byteSize(512000000), "512 MB")
        XCTAssertEqual(BackendSharedText.byteSize(1), "1 bytes")
        XCTAssertEqual(BackendSharedText.byteSize(1250), "1.3 KB")
        XCTAssertEqual(BackendSharedText.byteSize(2250), "2.3 KB")
        XCTAssertEqual(BackendSharedText.byteSize(1150), "1.1 KB")
        XCTAssertFalse(BackendSharedText.overPasteCap(String(repeating: "x", count: 1048576)))
        XCTAssertTrue(BackendSharedText.overPasteCap(String(repeating: "x", count: 1048577)))
        XCTAssertTrue(BackendSharedText.overPasteCap(String(repeating: "😀", count: 300000)))
    }
    func testQuoteOpeningAndEscapeOrder() {
        let escape = "\u{1b}"
        XCTAssertEqual(BackendSharedText.stripAnsi("\(escape)]0;a title\u{7}\(escape)(B\(escape)[32mready\(escape)[m"), "ready")
        XCTAssertEqual(BackendSharedText.needleOf("\n\n  the failing line  \nand more"), "the failing line")
        XCTAssertEqual(BackendSharedText.needleOf(String(repeating: "x", count: 200)).count, 64)
        XCTAssertTrue(BackendSharedText.containsQuote("the heading is here\nsomething else", "the heading is here\nmissing tail"))
        XCTAssertFalse(BackendSharedText.containsQuote("line two\nline three", "a forged heading\nline two"))
        XCTAssertTrue(BackendSharedText.containsQuote("spinner...\rfinal answer here", "final answer here"))
        XCTAssertFalse(BackendSharedText.containsQuote("ERROR", "error"))
        XCTAssertFalse(BackendSharedText.containsQuote("anything", " \n\t"))
    }
    func testHeldWindowsDropsBadNumbersAndCapsAfterValidRows() {
        let many = NativeRPCValue.array([.null, .object([.init("n", .number(1e21))])] + (1...30).map { .object([.init("n", .number(Double($0)))]) })
        let read = BackendSharedHeldWindows.read(many)
        XCTAssertEqual(read.count, 16); XCTAssertEqual(read.first?.n, 1)
        XCTAssertEqual(read.first?.title, "")
        XCTAssertEqual(BackendSharedHeldWindows.heldLabel(.string("a\r\nb\u{2028}c")), "a b c")
        XCTAssertEqual(BackendSharedHeldWindows.heldLabel(.string(String(repeating: "x", count: 2000))).utf16.count, 512)
        XCTAssertTrue(BackendSharedHeldWindows.same(read, read))
        XCTAssertFalse(BackendSharedHeldWindows.same(read, []))
        XCTAssertEqual(BackendSharedHeldWindows.read(.string("B1")), [])
    }
    func testNotifyDecisionOrderAndExactCooldown() {
        func decide(_ status: String = "completed", previous: String? = "working", enabled: Bool = true, watching: Bool = false, last: Double? = nil, now: Double = 10000) -> BackendSharedNotifyRule.Verdict {
            BackendSharedNotifyRule.decide(status: status, previous: previous, enabled: enabled, watching: watching, lastFiredAt: last, now: now, cooldownMs: 4000)
        }
        XCTAssertEqual(decide(enabled: false), .suppressed("disabled"))
        XCTAssertEqual(decide(previous: nil), .suppressed("first-sight"))
        XCTAssertEqual(decide(previous: "completed"), .suppressed("unchanged"))
        XCTAssertEqual(decide("working", previous: "waiting"), .suppressed("not-notifying"))
        XCTAssertEqual(decide(watching: true), .suppressed("watching"))
        XCTAssertEqual(decide(last: 6001), .suppressed("cooldown"))
        XCTAssertEqual(decide(last: 6000), .fire)
        XCTAssertEqual(decide("input"), .fire)
    }
    func testNotPagesUsesProcessNames() {
        for name in ["sshd", "adb", "sharingd", "systemd-resolve", "Google Chrome", "ControlCenter"] { XCTAssertTrue(BackendSharedText.isExcluded(name)) }
        for name in ["", "node", "python3", "ruby", "caddy", "nginx", "bun", "deno", "gunicorn", "unicorn"] { XCTAssertFalse(BackendSharedText.isExcluded(name)) }
    }
}
