import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U29 (#35, #36, #681): an absurd number from an AI, a request or a helper answer is
/// refused or held in range. Before, each of these ended the whole app.
@Suite("Huge numbers from tools and answers never end the app")
struct BackendHugeNumbersTests {
    @Test func alertSettingsRefuseAbsurdNumbersAndTheToolSchemaBoundsThresholds() {
        for huge in [1e300, -1e300, 9.3e18] {
            #expect(throws: NativeRPCError.self) {
                try BackendAppsServerSettings.alerts(.object([.init("thresholds", .object([.init("diskPercent", .number(huge))]))]))
            }
            #expect(throws: NativeRPCError.self) { try BackendAppsServerSettings.alerts(.object([.init("remindMinutes", .number(huge))])) }
        }
        do {
            try BackendAppsMCP.validate(tool: "apps.server.alerts.save", arguments: .object([.init("serverId", .string("s1")),
                .init("thresholds", .object([.init("diskPercent", .number(1e300))]))]))
            Issue.record("a huge threshold passed the tool schema")
        } catch { #expect((error as? NativeRPCError)?.message.contains("thresholds.diskPercent") == true) }
    }

    @Test func coverageComparisonHoldsHugeCountsInRange() {
        let check = BackendS4AssetsCoverage.compare(.object([.init("captured", .number(1e30)), .init("stated", .number(1e300)), .init("tolerance", .number(1e300))]), defaultNow: 0)
        #expect(check["captured"].number == Double(BackendS4AssetsCoverage.largestCount))
        #expect(check["stated"].number == Double(BackendS4AssetsCoverage.largestCount))
        let negative = BackendS4AssetsCoverage.compare(.object([.init("captured", .number(3)), .init("stated", .number(-1e300))]), defaultNow: 0)
        #expect(negative["verdict"].string == "over")
    }

    @Test func shortTitlesSkipAHugeItemNumber() throws {
        let titles = try DeckMemoryShortTitles.parse(#"{"titles": [{"n": 1e300, "short": "x"}, {"n": 2, "short": "Second item"}]}"#, count: 2)
        #expect(titles[0] == nil)
        #expect(titles[1] == "Second item")
        #expect(try DeckMemoryShortTitles.parse(#"{"titles": [{"n": 1, "short": "x"}]}"#, count: 0).isEmpty)
    }
}
