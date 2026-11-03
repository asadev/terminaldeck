import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class SharedBackendRulesTests: XCTestCase {
    func testRelayCodecUsesWireContract() {
        for count in [0, 1, 32, 64] {
            let secret = Data(repeating: 42, count: count)
            XCTAssertEqual(BackendRelayPacketCodec.hostID(for: secret), Rendezvous.slotName(for: secret))
        }
        let sealed = RelayWire.withSealedVersion(Data([1, 2, 3]))
        XCTAssertEqual(BackendRelayPacketCodec.readSealedHandshake(sealed, expected: sealed.count), .message(Data([1, 2, 3])))
        XCTAssertEqual(BackendRelayPacketCodec.readSealedHandshake(sealed, expected: 99), .malformed)
        XCTAssertEqual(BackendRelayPacketCodec.readSealedHandshake(Data([255, 1]), expected: 2), .wrongVersion)
    }

    func testCanonicalFolderScopeResolvesAliasesAndRejectsTraversal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: allowed)
        XCTAssertTrue(BackendCompositionAuthority.within(alias.path, allowed.path))
        XCTAssertFalse(BackendCompositionAuthority.within(allowed.path + "/../other", allowed.path))
        XCTAssertFalse(BackendCompositionAuthority.within(allowed.path + "-sibling", allowed.path))
    }

    func testSettingsProtectionAndEffortCatalogueAreShared() {
        for key in BackendDeckCoreCatalogueRules.protectedKeys + BackendDeckCoreCatalogueRules.protectedPrefixes.map({ $0 + "future" }) + ["appearance.theme"] {
            XCTAssertEqual(BackendDeckToolsAppApplication.isProtected(key), BackendDeckCoreCatalogueRules.isProtectedSetting(key))
        }
        XCTAssertEqual(BackendCompositionDeckToolsAgentControls.effortLevels.map(\.id), AGSCapabilities.claudeEffortOptions.map(\.id))
    }
}
