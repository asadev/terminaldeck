import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// MAC-NEXT-13b: the shipped candidate stopped at start with "Extra: devices.page, devices.remove". The Devices
/// window's tools were added to the app's composition but not to the registrar's exact tool set, and no test ran the
/// start-up check on the tools the app itself builds (the registrar's tests use fixture families). This one does.
final class DeckToolsStartupRegistrationTests: XCTestCase {
    private func access() -> BackendDeckToolsAppAccess {
        BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path },
            session: { _, _ in .null }, runnableProject: { _, path in path },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "startup-registration-fixture") },
            authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
    }

    @MainActor
    func testTheAppsOwnWindowToolsPassTheStartupCheck() throws {
        let window = try NativeCompositionProduction.windowToolDefinitions(access: access())
        let supplied = Set(window.map(\.spec.id))
        XCTAssertEqual(supplied.count, window.count, "each window tool once")
        XCTAssertTrue(BackendDeckToolsRegistration.devicesPageIDs.isSubset(of: supplied))
        // The same set `register` demands at start: an id outside it is the "Extra" that stopped the launch.
        let expected = try BackendDeckToolsRegistration.expectedIDs(supplied: supplied)
        XCTAssertEqual(supplied.subtracting(expected).sorted(), [], "tools the app builds that the start-up check refuses")
        // Their area, catalogue entry (what tools_describe serves) and permission class.
        _ = try BackendDeckCoreCatalogueRegistry(metadata: window.map(\.catalogueMetadata))
        XCTAssertNoThrow(try BackendDeckToolsSupport.areas(definitions: window))
        let tiers = Dictionary(uniqueKeysWithValues: window.map { ($0.spec.id, $0.spec.tier) })
        XCTAssertEqual(tiers["devices.page"], .read)
        XCTAssertEqual(tiers["devices.remove"], .alter, "Remove changes things and asks the person first")
        XCTAssertEqual(tiers["devices.rename"], .alter, "review-fixes 2: rename sits beside sign-out, same class")
        XCTAssertEqual(tiers["devices.sign_out"], .alter, "lost-device design B6: sign out by name asks the person as every removal")
        // L5: the Code page's read tool is part of the app's own window tools.
        XCTAssertTrue(BackendCodeBackupTools.pageIDs.isSubset(of: supplied))
        XCTAssertEqual(tiers["code.projects"], .read)
        // Delete rule (L6, 15 Nov): the Cloud tools the app builds are the new shape whole, with no Bin tool among them,
        // and deleting / bringing back is "act": no question, and it works while an AI is working alone overnight.
        let cloud = BackendCloudManagerTools.pageIDs.union(BackendCloudArtifactsTools.pageIDs).union(BackendCloudFolderTools.pageIDs)
        XCTAssertTrue(cloud.isSubset(of: supplied))
        XCTAssertEqual(cloud.count, 10, "7 Cloud page + 1 artifacts + 2 Cloud folder (was 4 + 3 + 2 = 9 in the app before the delete rule)")
        XCTAssertTrue(supplied.isDisjoint(with: BackendCloudManagerTools.retiredIDs), "no Bin tool is registered")
        XCTAssertTrue(expected.isDisjoint(with: BackendCloudManagerTools.retiredIDs))
        XCTAssertEqual(tiers["cloud.delete"], .act)
        XCTAssertEqual(tiers["cloud.bring_back"], .act)
        XCTAssertEqual(tiers["cloud.use_version"], .act)
        XCTAssertEqual(tiers["cloud.not_here"], .read)
    }

    func testHalfTheDevicesPairIsRefused() throws {
        let expected = try BackendDeckToolsRegistration.expectedIDs(supplied: ["devices.page"])
        XCTAssertTrue(expected.contains("devices.remove"), "the Devices pair is supplied whole or not at all")
        XCTAssertTrue(try BackendDeckToolsRegistration.expectedIDs(supplied: []).isDisjoint(with: BackendDeckToolsRegistration.devicesPageIDs))
    }
}
