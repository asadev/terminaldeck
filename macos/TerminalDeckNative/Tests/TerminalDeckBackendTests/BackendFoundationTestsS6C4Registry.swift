import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane S6 / cluster C4: the registry.test.ts cases BackendFoundationTestsBRegistryWire does not cover.
final class BackendFoundationTestsS6C4Registry: XCTestCase {
    // registry.test.ts:131 refuses the two channels that need a Chromium window, in plain words
    func testRefusesTheTwoChannelsThatNeedAChromiumWindowInPlainWords() {
        XCTAssertEqual(BackendOSNativeMode.refusedChannels.keys.sorted(), ["browser-view:claim", "browser:create"])
        for sentence in BackendOSNativeMode.refusedChannels.values { XCTAssertTrue(sentence.contains("native shell"), sentence) }
    }
}
