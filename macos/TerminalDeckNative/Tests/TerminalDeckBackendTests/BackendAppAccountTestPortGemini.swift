import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppAccountTestPortGemini: XCTestCase, @unchecked Sendable {
    typealias P = BackendAppAccountSignInParsing
    private func state(files: [String: NativeRPCValue] = [:], nonempty: Set<String> = [], environment: [String: String] = [:], keychain: Bool = false) async throws -> BackendAppAccountGeminiSignIn {
        let deps = try BackendAppAccountTestPortDependencies(profile: BackendAppAccountTestPortProfile("gemini", system: true), files: files, nonempty: nonempty, environment: environment)
        let e = BackendAppSessionTestPortExecutor([.init(exitCode: keychain ? 0 : 44)])
        return await BackendAppAccountTestPortService(deps, executor: e).gemini()
    }
    func testHomeVariableNamesRootRatherThanConfigDirectory() {
        XCTAssertEqual(P.geminiDirectory(environment: ["GEMINI_CLI_HOME": "/tmp/alt"], home: "/Users/asad"), "/tmp/alt/.gemini")
        XCTAssertEqual(P.geminiDirectory(environment: [:], home: "/Users/asad"), "/Users/asad/.gemini")
        XCTAssertEqual(P.geminiDirectory(environment: ["GEMINI_CLI_HOME": "   "], home: "/Users/asad"), "/Users/asad/.gemini")
    }
    func testActiveGoogleAccountExactShapeAndEmptyCases() {
        for (raw, expected) in [(BackendAppSessionTestPortObject([("active", .string("a@b.com")), ("old", .array([]))]), "a@b.com" as String?), (BackendAppSessionTestPortObject([("active", .string("  "))]), nil), (.object([]), nil), (.null, nil)] {
            XCTAssertEqual(P.gemini(environment: [:], accounts: raw, settings: .null, credentialsFilePresent: false, keychainPresent: false).account, expected)
        }
    }
    func testSelectedAuthTypeReadsExactNestedShapeAndPartialFiles() {
        let settings = BackendAppSessionTestPortObject([("security", BackendAppSessionTestPortObject([("auth", BackendAppSessionTestPortObject([("selectedType", .string("oauth-personal"))]))]))])
        XCTAssertEqual(P.text(settings["security"]["auth"]["selectedType"]), "oauth-personal")
        for raw in [BackendAppSessionTestPortObject([("security", .object([]))]), BackendAppSessionTestPortObject([("security", .null)]), .string("nonsense")] { XCTAssertNil(P.text(raw["security"]["auth"]["selectedType"])) }
    }
    func testEmptyMachineIsSignedOutAndNamesSignInAction() async throws { let s = try await state(); XCTAssertFalse(s.signedIn); XCTAssertTrue(s.description.contains("Press Sign in")) }
    func testSelectedMethodSurvivesSignOutWithoutPretendingLogin() async throws {
        let settings = BackendAppSessionTestPortObject([("security", BackendAppSessionTestPortObject([("auth", BackendAppSessionTestPortObject([("selectedType", .string("oauth-personal"))]))]))])
        let s = try await state(files: ["/fixture/home/.gemini/settings.json": settings]); XCTAssertFalse(s.signedIn); XCTAssertEqual(s.method, "Google account")
    }
    func testCLIWrittenAddressCountsAndIsDescribed() async throws { let s = try await state(files: ["/fixture/home/.gemini/google_accounts.json": BackendAppSessionTestPortObject([("active", .string("asad@example.com")), ("old", .array([]))])]); XCTAssertTrue(s.signedIn); XCTAssertTrue(s.description.contains("asad@example.com")) }
    func testKeychainAttributePresenceCountsWithoutPasswordRead() async throws {
        let deps = try BackendAppAccountTestPortDependencies(profile: BackendAppAccountTestPortProfile("gemini", system: true)), e = BackendAppSessionTestPortExecutor([.init(exitCode: 0)])
        let s = await BackendAppAccountTestPortService(deps, executor: e).gemini(), calls = await e.calls
        XCTAssertTrue(s.signedIn); XCTAssertEqual(s.evidence, "keychain")
        XCTAssertEqual(calls[0].arguments, ["find-generic-password", "-s", "gemini-cli-oauth", "-a", "main-account"]); XCTAssertFalse(calls[0].arguments.contains("-w"))
    }
    func testTokenFilePresenceCountsWithoutReadingToken() async throws { let s = try await state(nonempty: ["/fixture/home/.gemini/oauth_creds.json"]); XCTAssertTrue(s.signedIn); XCTAssertEqual(s.evidence, "oauth_creds.json") }
    func testEnvironmentAPIKeyCountsAndNamesOnlyVariable() async throws { let s = try await state(environment: ["GEMINI_API_KEY": "abc"]); XCTAssertTrue(s.signedIn); XCTAssertTrue(s.method?.contains("GEMINI_API_KEY") == true); XCTAssertFalse(s.description.contains("abc")) }
    func testHalfWrittenSettingsAreNotEvidence() async throws { let s = try await state(files: ["/fixture/home/.gemini/settings.json": .string("{ \"security\": ")]); XCTAssertFalse(s.signedIn) }
}
