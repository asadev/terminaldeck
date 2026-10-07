import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsAccountsVaultGuards: XCTestCase, @unchecked Sendable {
    // store.test.ts:199. Invalid attributes are rejected before open/encrypt,
    // so constructing this cipher does not read or modify the real Keychain.
    func testVaultRejectsUnknownSlotNamesBeforeCipherAccess() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendAccountVault(configuration: f.configuration, stateStore: f.state, cipher: .init(appName: "fixture-never-read"))
        do {
            for slot in ["../../etc/passwd", "keychain:a/b"] {
                do { _ = try await vault.put(accountID: "a", provider: "claude", slot: slot, value: "x", source: "sign-in"); XCTFail("Expected invalid slot refusal: " + slot) }
                catch { XCTAssertTrue(error.localizedDescription.contains("invalid attributes")) }
            }
            let invalid = try await vault.read(accountID: "a", slot: "../x"); XCTAssertNil(invalid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vault.file.path)); await vault.close()
        } catch { await vault.close(); throw error }
    } }
    // profiles.windows.test.ts:43. These portable ids are persisted on Mac,
    // so the Windows filename rule remains applicable without Windows APIs.
    func testPortableProfileIDsAvoidMSDOSDeviceNames() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        for (name, expected) in [("CON", "con-profile"), ("aux", "aux-profile"), ("LPT1", "lpt1-profile"), ("nul", "nul-profile")] { let p = try await f.create(name); XCTAssertEqual(p.id, expected) }
    } }
    // profiles.windows.test.ts:53
    func testPortableProfileIDsLeaveNonReservedPrefixesAlone() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        for (name, expected) in [("console", "console"), ("Com10", "com10"), ("Aux Work", "aux-work")] { let p = try await f.create(name); XCTAssertEqual(p.id, expected) }
    } }
    // profiles.windows.test.ts:61
    func testPortableIDRuleAppliesToMacStateFiles() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("prn"); XCTAssertEqual(p.id, "prn-profile"); XCTAssertEqual(try f.disk()["profiles"].elements?.first?["id"].string, "prn-profile") } }
}
