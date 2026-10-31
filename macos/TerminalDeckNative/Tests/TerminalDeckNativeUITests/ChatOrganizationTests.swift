import XCTest
@testable import TerminalDeckNative

@MainActor final class ChatOrganizationTests: XCTestCase {
    func testArchiveAndExistingPinStorePersistIndependentlyWithoutDeletingIdentity() throws {
        let suite = "td-par-organization-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let pins = SIDEBARPins(defaults: defaults), archive = NativeChatArchives(defaults: defaults)
        pins.toggle("chat"); archive.set("chat", archived: true)
        XCTAssertTrue(SIDEBARPins(defaults: defaults).isPinned("chat"))
        XCTAssertTrue(NativeChatArchives(defaults: defaults).contains("chat"))
        archive.replaced("chat", with: "replacement")
        XCTAssertTrue(archive.contains("replacement")); XCTAssertFalse(archive.contains("chat"))
        archive.set("replacement", archived: false)
        XCTAssertTrue(pins.isPinned("chat")); XCTAssertTrue(archive.ids.isEmpty)
    }
}
