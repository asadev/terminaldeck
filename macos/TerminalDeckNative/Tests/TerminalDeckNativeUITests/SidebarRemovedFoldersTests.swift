import Foundation
import XCTest
@testable import TerminalDeckNative

@MainActor
final class SidebarRemovedFoldersTests: XCTestCase {
    func testRemovalSurvivesReloadAndExplicitReopenRestoresTheRow() throws {
        let name = "sidebar-removal-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = "/tmp/owned-project", child = root + "/scratch"
        let first = SIDEBARProjectStore(defaults: defaults)
        first.updateOpenFolders([root, child])
        first.updateOpenFolders([root])
        XCTAssertTrue(first.folderIsRemoved(child))
        XCTAssertFalse(first.folderIsRemoved(root))
        let restored = SIDEBARProjectStore(defaults: defaults)
        restored.updateOpenFolders([root])
        XCTAssertTrue(restored.folderIsRemoved(child))
        restored.updateOpenFolders([root, child])
        XCTAssertFalse(restored.folderIsRemoved(child))
        XCTAssertFalse(restored.folderIsRemoved(root))
    }
}
