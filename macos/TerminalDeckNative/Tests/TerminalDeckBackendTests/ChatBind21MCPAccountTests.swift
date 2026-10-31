import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private enum ChatBind21RequestScope { @TaskLocal static var id: String? }
final class ChatBind21MCPAccountTests: XCTestCase, @unchecked Sendable {
    private let profile = NativeRPCValue.object([.init("id", .string("scratch")), .init("name", .string("Scratch login")), .init("provider", .string("claude"))])
    func testSelectedAccountIsReadUnderTheOriginalRequestAndMatchesByNameOrID() async throws {
        let profile = profile
        try await ChatBind21RequestScope.$id.withValue("original-caller") {
            for name in ["scratch", "Scratch login"] {
                let result = try await BackendDeckCoreCatalogueBuiltins.chooseAccountForStart(arguments: .object([.init("account", .string(name)), .init("provider", .string("claude"))])) {
                    XCTAssertEqual(ChatBind21RequestScope.id, "original-caller"); return [profile]
                }
                XCTAssertEqual(result, profile)
            }
        }
    }
    func testAnUnspecifiedAccountDoesNotReadOrChangeTheDefault() async throws {
        let result = try await BackendDeckCoreCatalogueBuiltins.chooseAccountForStart(arguments: .object([])) {
            XCTFail("The default launch must not read an account choice."); return nil
        }
        XCTAssertNil(result)
    }
    func testAccountReadFailureAndWrongProviderRemainErrors() async throws {
        let profile = profile, args = NativeRPCValue.object([.init("account", .string("scratch")), .init("provider", .string("codex"))])
        do {
            _ = try await BackendDeckCoreCatalogueBuiltins.chooseAccountForStart(arguments: args) { throw BackendHOSTFailure.authentication }
            XCTFail("A refused account read reported success.")
        } catch { XCTAssertEqual(error.localizedDescription, BackendHOSTFailure.authentication.localizedDescription) }
        do {
            _ = try await BackendDeckCoreCatalogueBuiltins.chooseAccountForStart(arguments: args) { [profile] }
            XCTFail("A Claude login was accepted for Codex.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cannot run a codex session")) }
    }
}
