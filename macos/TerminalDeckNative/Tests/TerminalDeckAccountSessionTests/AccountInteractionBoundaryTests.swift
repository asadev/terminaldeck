import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U175: exercise UI decisions without opening windows, signing in or typing into sessions.
@MainActor final class AccountInteractionBoundaryTests: XCTestCase {
    func testPermissionReplyMustMatchOptionLabelsAsWellAsTheQuestion() throws {
        let menu = try XCTUnwrap(NativePermissionDesk.permissionMenu(in: " Run command?\n ❯ 1. Yes\n   2. No\n"))
        let item = NativePermissionDesk.Item(id: "session:fixture", source: .session("fixture"), asker: "Fixture", what: menu.question, options: menu.options, at: .now)
        let changed = try XCTUnwrap(NativePermissionDesk.permissionMenu(in: " Run command?\n ❯ 1. Yes, always allow\n   2. No\n"))
        XCTAssertFalse(NativePermissionDesk.sameMenu(changed, as: item))
        XCTAssertTrue(NativePermissionDesk.sameMenu(menu, as: item))
    }

    func testClosingSignInClearsTheCodeAndErrorWithoutStartingAnotherFlow() {
        let model = NativeAccountSignInModel()
        model.active = .init(id: "fixture", accountID: "account", accountName: "Fixture", provider: "claude", state: "needs-code", message: "Enter code", namesItself: false, createdHere: false)
        model.code = "fixture-code"; model.problem = "Fixture failure"
        model.close()
        XCTAssertNil(model.active); XCTAssertEqual(model.code, ""); XCTAssertNil(model.problem)
    }

    func testEasySignInIsOfferedOnlyForSupportedProviders() {
        XCTAssertTrue(NativeAccountSignInModel.canDrive(nil))
        XCTAssertTrue(NativeAccountSignInModel.canDrive("claude"))
        XCTAssertTrue(NativeAccountSignInModel.canDrive("codex"))
        XCTAssertFalse(NativeAccountSignInModel.canDrive("gemini"))
        XCTAssertFalse(NativeAccountSignInModel.canDrive("unknown"))
    }

    func testSwitchErrorsKeepTheActualReason() {
        struct Refused: LocalizedError { var errorDescription: String? { "The selected account is locked." } }
        XCTAssertTrue(NativeAccountSwitcher.plain(Refused()).contains("The selected account is locked."))
    }
}
