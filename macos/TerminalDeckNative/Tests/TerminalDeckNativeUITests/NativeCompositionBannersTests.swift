import XCTest
@testable import TerminalDeckNative

final class NativeCompositionBannersTests: XCTestCase {
    @MainActor func testDismissReleasesCallbacksWithoutClicking() throws {
        let owner = NativeCompositionBanners()
        let banner = try XCTUnwrap(owner.make(title: "Done", body: "Answer", silent: true) as? NativeCompositionBanner)
        var clicks = 0, closes = 0
        banner.clicked { clicks += 1 }
        banner.closed { closes += 1 }
        owner.hold(banner)
        owner.dismissed(banner.identifier)
        owner.dismissed(banner.identifier)
        XCTAssertFalse(owner.clicked(banner.identifier))
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(closes, 1)
    }
}
