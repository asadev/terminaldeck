import Foundation
import XCTest
import CryptoKit
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsAccountsParsing: XCTestCase, @unchecked Sendable {
    typealias P = BackendAccountShimParsing
    private let slot = "keychain:Claude Code-credentials"
    private func hex(_ value: String) -> String { Data(value.utf8).map { String(format: "%02x", $0) }.joined() }
    private func request(_ args: [String], stdin: String = "") throws -> BackendAccountKeychainRequest {
        let requests = try XCTUnwrap(P.call(args, stdin: stdin)); XCTAssertEqual(requests.count, 1)
        return try XCTUnwrap(requests.first)
    }
    // keychain-requests.test.ts:16
    func testServiceVariantsKeepSlotAndDirectorySuffix() throws {
        let services: [(String, String, String?)] = [("Claude Code-credentials", slot, nil), ("Claude Code-credentials-70e2e799", slot, "70e2e799"), ("Claude Code-staging-oauth-credentials-8e404012", "keychain:Claude Code-staging-oauth-credentials", "8e404012"), ("Claude Code-70e2e799", "keychain:Claude Code", "70e2e799")]
        for (name, expectedSlot, suffix) in services {
            let result = try XCTUnwrap(P.service(name)); XCTAssertEqual(result.slot, expectedSlot); XCTAssertEqual(result.suffix, suffix)
        }
    }
    // keychain-requests.test.ts:29
    func testDirectoryHashMatchesShippedCLIAndCanonicalUnicode() {
        func sha(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description }
        let directory = "/Users/x/Library/Application Support/terminaldeck/profiles/work"
        XCTAssertEqual(P.suffixes(directory), Set<String?>([sha(directory)]))
        XCTAssertTrue(P.suffixes("/p/Cafe\u{301}").contains(sha("/p/Caf\u{e9}")))
    }
    // keychain-requests.test.ts:37
    func testUnrelatedServicesAreUntouched() {
        for name in ["Claude Code-device-keys", "Apple Development: Someone", "Claude Code-credentials-NOTHEX!!", "gemini-cli-oauth"] { XCTAssertNil(P.service(name), name) }
    }
    // keychain-requests.test.ts:46
    func testLookupArguments() throws {
        guard case let .find(found, suffix, password) = try request(["find-generic-password", "-a", "imatch", "-w", "-s", "Claude Code-credentials-70e2e799"]) else { return XCTFail("Expected a find request") }
        XCTAssertEqual(found, slot); XCTAssertEqual(suffix, "70e2e799"); XCTAssertTrue(password)
    }
    // keychain-requests.test.ts:55
    func testInteractiveHexWrite() throws {
        let login = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-X"}}"#
        guard case let .add(found, suffix, value) = try request(["-i"], stdin: "add-generic-password -U -a \"imatch\" -s \"Claude Code-credentials-70e2e799\" -X \"\(hex(login))\"\n") else { return XCTFail("Expected an add request") }
        XCTAssertEqual(found, slot); XCTAssertEqual(suffix, "70e2e799"); XCTAssertEqual(value, login)
    }
    // keychain-requests.test.ts:64
    func testLongArgumentHexWrite() throws {
        let login = String(repeating: "x", count: 5_000)
        guard case let .add(found, suffix, value) = try request(["add-generic-password", "-U", "-a", "imatch", "-s", "Claude Code-credentials-70e2e799", "-X", hex(login)]) else { return XCTFail("Expected an add request") }
        XCTAssertEqual(found, slot); XCTAssertEqual(suffix, "70e2e799"); XCTAssertEqual(value, login)
    }
    // keychain-requests.test.ts:77
    func testDeleteAndLockCheck() throws {
        guard case let .delete(found, suffix) = try request(["delete-generic-password", "-a", "imatch", "-s", "Claude Code-credentials-1a2b3c4d"]) else { return XCTFail("Expected a delete request") }
        XCTAssertEqual(found, slot); XCTAssertEqual(suffix, "1a2b3c4d")
        guard case .locked = try request(["show-keychain-info"]) else { return XCTFail("Expected a lock check") }
    }
    // keychain-requests.test.ts:85
    func testNonLoginAndMixedBatchPassThroughWhole() {
        XCTAssertNil(P.call(["find-identity", "-v", "-p", "codesigning"], stdin: ""))
        XCTAssertNil(P.call(["find-generic-password", "-a", "imatch", "-w", "-s", "Claude Code-device-keys"], stdin: ""))
        let mixed = "add-generic-password -U -a \"imatch\" -s \"Claude Code-credentials\" -X \"61\"\nadd-generic-password -U -a \"imatch\" -s \"Claude Code-device-keys\" -X \"62\"\n"
        XCTAssertNil(P.call(["-i"], stdin: mixed)); XCTAssertNil(P.call(["show-keychain-info", "login.keychain-db"], stdin: ""))
    }
    // keychain-requests.test.ts:98
    func testUndecodableWriteAndPromptPassThrough() {
        XCTAssertNil(P.call(["add-generic-password", "-U", "-a", "imatch", "-s", "Claude Code-credentials", "-X", "zz"], stdin: ""))
        XCTAssertNil(P.call(["add-generic-password", "-a", "imatch", "-s", "Claude Code-credentials", "-w"], stdin: ""))
    }
    // keychain-requests.test.ts:110
    func testQuotedInteractiveWords() {
        XCTAssertEqual(P.words("add-generic-password -U -a \"a b\" -s \"x\\\"y\" -X \"00\""), ["add-generic-password", "-U", "-a", "a b", "-s", "x\"y", "-X", "00"])
    }
    // keychain-requests.test.ts:123. Hex decoding is exercised through the real
    // command parser because native has no separate decodeHex export.
    func testHexIsUTF8AndRequiresNonemptyEvenLength() throws {
        guard case let .add(_, _, value) = try request(["add-generic-password", "-s", "Claude Code-credentials", "-X", hex("héllo")]) else { return XCTFail("Expected decoded text") }
        XCTAssertEqual(value, "héllo")
        for invalid in ["abc", ""] { XCTAssertNil(P.command(["add-generic-password", "-s", "Claude Code-credentials", "-X", invalid])) }
    }
    // Supplementary persisted-cipher format checks; no Keychain calls.
    func testChromiumSafeStorageRoundTripsSyntheticUnicodeWithV10Prefix() throws {
        let value = "fixture-only héllo 😀", password = Data("synthetic-key".utf8)
        let encrypted = try ChromiumSafeStorageCipher.encrypt(value, password: password)
        XCTAssertTrue(encrypted.starts(with: Data("v10".utf8))); XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains(value))
        XCTAssertEqual(try ChromiumSafeStorageCipher.decrypt(encrypted, password: password), value)
    }
    func testChromiumSafeStoragePreservesEmptyAndRefusesMalformedBlob() throws {
        let password = Data("synthetic-key".utf8)
        XCTAssertEqual(try ChromiumSafeStorageCipher.encrypt("", password: password), Data())
        XCTAssertEqual(try ChromiumSafeStorageCipher.decrypt(Data(), password: password), "")
        for blob in [Data("v11invalid".utf8), Data("v10".utf8), Data("v10bad-block".utf8)] { XCTAssertThrowsError(try ChromiumSafeStorageCipher.decrypt(blob, password: password)) }
    }
}
