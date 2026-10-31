import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// profiles.test.ts / profiles.windows.test.ts `profileStatus` on the Mac, against the
/// real profile store (temporary folder) and BackendAccountProfileStatus (TS profileStatus +
/// credential-store.ts profileIsolation), which `profiles:status` answers with.
final class BackendFoundationTestsF4ProfileStatus: XCTestCase, @unchecked Sendable {
    private typealias Status = BackendAccountProfileStatus

    // profiles.test.ts:679
    func testReportsWhetherAProfileHasEverBeenUsedWithoutGuessingAtLogin() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let created = try await f.create("Work")
        let first = Status.status(created)
        XCTAssertEqual(first["exists"].bool, true); XCTAssertEqual(first["initialized"].bool, false)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: created.configDir).appendingPathComponent(".claude.json"))
        XCTAssertEqual(Status.status(created)["initialized"].bool, true)
    } }

    // profiles.windows.test.ts:69
    func testClaimsASeparateLoginOnMacOSWhereTheKeychainWasChecked() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let profile = try await f.create("Work")
        let status = Status.status(profile, platform: "darwin")
        XCTAssertEqual(status["isolation"]["isolated"].bool, true)
        XCTAssertEqual(status["isolation"]["store"].string, "macos-keychain")
    } }

    // profiles.windows.test.ts:93
    func testStillReportsTheFieldsThePickerAlreadyReads() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let profile = try await f.create("Work")
        let status = Status.status(profile, platform: "darwin")
        XCTAssertEqual(status["id"].string, profile.id); XCTAssertEqual(status["exists"].bool, true)
        XCTAssertEqual(status["initialized"].bool, false); XCTAssertEqual(status["configDir"].string, profile.configDir)
    } }

    // 18 Oct (#525): the note says where this account's login really is.
    func testLoginStoreNoteFollowsWhereTheLoginIsKept() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let profile = try await f.create("Work")
        let own = Status.status(profile, keptBy: .agent)["isolation"]
        XCTAssertEqual(own["store"].string, "macos-keychain")
        let app = Status.status(profile, keptBy: .app)["isolation"]
        XCTAssertEqual(app["store"].string, "terminal-deck-vault")
        XCTAssertFalse(app["note"].string?.contains("Keychain") ?? true)
        XCTAssertTrue(app["note"].string?.contains("encrypted store") ?? false)
        let api = BackendAccountProfile(id: "api-key-" + String(repeating: "b", count: 24), name: "Key", provider: "codex",
            configDir: profile.configDir, system: false, color: "--accent", createdAt: 0)
        let key = Status.status(api, keptBy: .agent)["isolation"]
        XCTAssertEqual(key["store"].string, "api-key-keychain")
        XCTAssertTrue(key["note"].string?.contains("its own Terminal Deck entry") ?? false)
    } }
}
