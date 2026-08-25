/**
 * The localhost page wears the platform's chrome, and these are the three
 * decisions that make it so.
 *
 * Asad, after the page had already been changed from a `fullScreenCover` into a
 * push: *"Localhost browsing is still not native on iOS."* He was right twice
 * over, and both halves were the same mistake — the screen had taken over the
 * two pieces of a pushed screen that belong to iOS:
 *
 *  1. **The left edge.** `allowsBackForwardNavigationGestures` handed the
 *     standard back gesture to the web view's own history, so the one gesture
 *     everybody reaches for to leave a pushed screen walked the page's history
 *     instead and the screen never left.
 *  2. **The navigation bar**, hidden so a custom row could carry back, reload,
 *     where-you-are, inspect and Done. The reasoning was sound — a system bar
 *     above that row is 94 points of chrome in two rows with two back buttons
 *     eleven points apart meaning different things — and the price was the whole
 *     platform: no chevron, no standard title, no interactive pop.
 *
 * The fix is Safari's: keep the navigation bar, move the browser's controls to a
 * **bottom** toolbar. Done stays last, because he said so — *"last button I
 * think is on its correct place."*
 *
 * ## Why two of these read the source
 *
 * The same reason `AppearanceTests` reads it, and the reason is worth stating
 * because a source-reading test looks lazy until you try the alternatives. There
 * is nothing to ask at runtime: a `.toolbar` modifier on a screen nobody has
 * navigated to has not run, and SwiftUI exposes no way to interrogate a view's
 * toolbar content from a unit test. The honest runtime answer needs a paired
 * phone, a machine serving a port and a finger — that is
 * `LocalhostUITests.testTheChromeIsThePlatformsAndDoneIsLast`, which measures the
 * real bar on a real page and is the *proof*. This file is the **tripwire**: it
 * runs on a laptop with nothing listening, in the suite that always runs, so
 * that putting `.toolbar(.hidden, for: .navigationBar)` back — or quietly
 * dropping Done to the middle of the bar — fails immediately rather than
 * surviving until somebody next has a desktop to test against.
 *
 * `#filePath` is the compile-time location of this file, which gives the
 * checkout; a Simulator process can read the Mac's filesystem, which is how
 * `LiveTransferUITests` already checks uploads that landed on the Mac.
 */

import WebKit
import XCTest
@testable import TerminalDeck

@MainActor
final class LocalhostChromeTests: XCTestCase {

    // MARK: - The gesture

    /**
     * **The left edge belongs to the navigation stack.**
     *
     * This is the one of the three that can be asked at runtime, and it is asked
     * of a real `WKWebView` rather than of the source, because what matters is
     * the state of the object the gesture recogniser is installed on.
     *
     * `false` is also `WKWebView`'s default, so this assertion would pass if the
     * line were deleted entirely — and that is fine and deliberate. What must
     * never come back is the `true`, and nothing else here can tell the
     * difference between a default and a decision. The line in `BrowserBridge`
     * is written out explicitly with its reasoning; this makes the value load
     * bearing.
     */
    func testTheWebViewDoesNotTakeTheEdgeSwipe() {
        let bridge = BrowserBridge()
        defer { bridge.tearDown() }

        XCTAssertFalse(bridge.webView.allowsBackForwardNavigationGestures,
                       "the left-edge swipe is how a pushed screen is left on iOS; a web view that "
                       + "takes it makes the one gesture everybody knows do something else")
    }

    /**
     * Forward exists, and it starts off with nowhere to go.
     *
     * It is here because turning the gesture off took it away: that one property
     * buys back on the left edge *and forward on the right*, so replacing only
     * the back half would have left a Back button that strands you — tap it once
     * by accident and the page you were reading is unreachable.
     *
     * The live half of this — a real history walked forwards again — is
     * `BrowserBackTests`, which has a real document to push entries onto.
     */
    func testForwardStartsWithNowhereToGo() {
        let bridge = BrowserBridge()
        defer { bridge.tearDown() }

        XCTAssertFalse(bridge.canGoForward,
                       "a fresh web view has no forward history, and the button must say so by "
                       + "being disabled rather than by doing nothing when pressed")
    }

    // MARK: - The bars

    /// **The navigation bar is not hidden.** The line that hid it is the whole
    /// of what he asked to be undone, so its absence is what is checked — and
    /// checked against real code rather than the prose, because this file talks
    /// about that modifier at length and so does the screen's own header.
    func testTheScreenDoesNotHideTheNavigationBar() throws {
        let source = try Self.browserSource()
        let offenders = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".toolbar(.hidden, for: .navigationBar)") }

        XCTAssertTrue(offenders.isEmpty,
                      "the localhost page is hiding the system navigation bar again — that costs "
                      + "the chevron, the title and the interactive pop, which is exactly what "
                      + "\"still not native\" was about")
        XCTAssertTrue(source.contains(".navigationBarTitleDisplayMode(.inline)"),
                      "the bar is kept, so it has to be told to stay one row high; a large title "
                      + "over a web page is 96 points of nothing")
    }

    /**
     * **The controls are in a bottom toolbar, in his order, with Done last.**
     *
     * The order is asserted as a whole sequence rather than by picking out the
     * last one, because "Done is last" is only half of what he blessed: the row
     * he was looking at read back, reload, where-you-are, inspect, Done, and the
     * two that moved — Forward joining Back, and the address going up into the
     * title — are the only differences this pass is allowed to have made. A test
     * that only checked the last item would let the other four be shuffled.
     */
    func testTheBrowserControlsAreInTheBottomBarAndDoneIsLast() throws {
        let source = try Self.browserSource()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let opens = try XCTUnwrap(lines.firstIndex { $0.contains("ToolbarItemGroup(placement: .bottomBar)") },
                                  "the browser's controls are not in a bottom toolbar at all")
        /*
         * Fenced by the file's own `MARK`, which is the first thing after the
         * body. Brace matching would be the precise answer and it is not worth
         * the machinery: everything between those two points is one view body,
         * and the only accessibility identifiers in it are the ones being
         * counted. Without a fence the walk would run on into `header` and
         * `inspectHint`, whose identifiers are real and are not toolbar items.
         */
        let closes = try XCTUnwrap(lines[opens...].firstIndex { $0.contains("// MARK: - Chrome") },
                                   "the Chrome mark that fences this walk has been renamed")

        var found: [String] = []
        for line in lines[opens..<closes] {
            guard let range = line.range(of: ".accessibilityIdentifier(\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            found.append(String(rest[..<end]))
        }

        XCTAssertEqual(found,
                       ["localhost.back",
                        "localhost.forward",
                        "localhost.reload",
                        // Find-in-page joined the bar on 2026-08-24, when the
                        // Browser tab absorbed the desktop's browser features.
                        // Placed after the page's own history and before
                        // Inspect, which keeps the blessed rule intact: the
                        // three navigation controls lead and Done is last.
                        "localhost.find",
                        "localhost.inspect",
                        "localhost.done"],
                       "the bottom bar's order changed. He blessed this one — \"last button I "
                       + "think is on its correct place\" — so Done is last and the page's own "
                       + "history leads")
    }

    // MARK: - Helpers

    /// The screen's source, from the checkout this test was compiled in.
    private static func browserSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)   // …/ios/Tests/LocalhostChromeTests.swift
            .deletingLastPathComponent()             // …/ios/Tests
            .deletingLastPathComponent()             // …/ios
            .appendingPathComponent("TerminalDeck/Screens/LocalhostBrowser.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        // A file that could not be found reads as an empty string in some of the
        // obvious spellings of this, and every assertion below then passes for
        // the wrong reason. Cheap to refuse.
        XCTAssertGreaterThan(source.count, 5_000,
                             "read almost nothing at \(file.path) — this walk is measuring nothing")
        return source
    }
}
