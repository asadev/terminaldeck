import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedTestPortAddressModels: XCTestCase {
    private let hostID = "ABCDEFGHJKLMNPQRSTUVWXYZ23"
    private let key = Data(repeating: 7, count: 32)
    private let relay = "wss://relay.terminaldeck.dev"
    private func token() throws -> String { try XCTUnwrap(BackendSharedServerAddresses.format(url: relay, hostId: hostID, hostKey: key.base64EncodedString())) }
    func testPairingAlphabetAndRelayAddresses() {
        XCTAssertTrue(BackendSharedServerAddresses.isHostId(hostID))
        for prefix in ["0", "1", "I", "O"] { XCTAssertFalse(BackendSharedServerAddresses.isHostId(prefix + String(hostID.dropFirst()))) }
        XCTAssertFalse(BackendSharedServerAddresses.isHostId(hostID.lowercased())); XCTAssertFalse(BackendSharedServerAddresses.isHostId(String(hostID.dropLast())))
        for url in ["ws://localhost:1234", "wss://relay.example", "WSS://relay.example"] { XCTAssertTrue(BackendSharedServerAddresses.isRelayUrl(url)) }
        for url in ["https://relay.example", "wss://", "wss://relay example", "wss://relay.example\u{7}", "wss://relay.example\u{7f}", "wss://relay.example\u{a0}"] { XCTAssertFalse(BackendSharedServerAddresses.isRelayUrl(url)) }
    }
    func testAddressEveryValidationAndDamagedEnvelope() throws {
        XCTAssertEqual(hostID.count, 26)
        XCTAssertEqual(BackendSharedServerAddresses.hostKeyBytes(BackendSharedServerAddresses.toBase64Url(key)), key)
        let printed = try token()
        XCTAssertTrue(BackendSharedText.matches(printed, "^srv1\\.[A-Za-z0-9_-]+$")); XCTAssertTrue(printed.hasPrefix(BackendSharedServerAddresses.prefix))
        for url in ["", "https://relay.example"] { XCTAssertNil(BackendSharedServerAddresses.format(url: url, hostId: hostID, hostKey: key.base64EncodedString())) }
        for host in ["", "0" + String(hostID.dropFirst())] { XCTAssertNil(BackendSharedServerAddresses.format(url: relay, hostId: host, hostKey: key.base64EncodedString())) }
        for hostKey in ["", Data(repeating: 7, count: 31).base64EncodedString()] { XCTAssertNil(BackendSharedServerAddresses.format(url: relay, hostId: hostID, hostKey: hostKey)) }
        let split = printed.index(printed.startIndex, offsetBy: 20)
        let broken = String(printed[..<split]) + " " + String(printed[split...])
        for bad in ["", hostID, "wss://relay.example", broken] { XCTAssertNil(BackendSharedServerAddresses.parse(bad)) }
        func wrap(_ value: NativeRPCValue) -> String { BackendSharedServerAddresses.prefix + BackendSharedServerAddresses.toBase64Url(Data(value.compact.utf8)) }
        let address = NativeRPCValue.object([.init("kind", .string("relay")), .init("url", .string(relay)), .init("hostId", .string(hostID)), .init("hostKey", .string(key.base64EncodedString()))])
        for invalid in [NativeRPCValue.object([.init("kind", .string("direct"))]), .array([address]), address.setting("hostKey", .string("not-a-key")), .string("a string")] { XCTAssertNil(BackendSharedServerAddresses.parse(wrap(invalid))) }
        XCTAssertTrue(BackendSharedServerAddresses.isServerAddress(printed)); XCTAssertFalse(BackendSharedServerAddresses.isServerAddress("srv1."))
        XCTAssertEqual(BackendSharedServerAddresses.asAddress(address), BackendSharedServerAddresses.parse(printed)); XCTAssertNil(BackendSharedServerAddresses.asAddress(.null))
        XCTAssertTrue(BackendSharedServerAddresses.addressIsNotASecret.contains("not a secret")); XCTAssertTrue(BackendSharedServerAddresses.addressIsNotASecret.contains("login"))
        let elsewhere = try XCTUnwrap(BackendSharedServerAddresses.format(url: "wss://relay.example.org", hostId: hostID, hostKey: key.base64EncodedString()))
        let json = String(decoding: BackendSharedServerAddresses.fromBase64Url(String(elsewhere.dropFirst(5))), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("terminaldeck")); XCTAssertFalse(BackendSharedServerAddresses.prefix.lowercased().contains("deck"))
    }
    func testAddressCrossLanguageFixtureFields() throws {
        let bytes = Data((1...32).map { UInt8(($0 * 7) % 256) })
        let encodedKey = BackendSharedServerAddresses.toBase64Url(bytes)
        XCTAssertTrue(encodedKey.contains("-")); XCTAssertTrue(encodedKey.contains("_")); XCTAssertEqual(Set(bytes).count, 32)
        let printed = try XCTUnwrap(BackendSharedServerAddresses.format(url: relay, hostId: "KZ2J9AWGK8BWGQUEZDYKW5RS22", hostKey: encodedKey))
        XCTAssertTrue(BackendSharedText.matches(printed, "^srv\(BackendSharedServerAddresses.version)\\.[A-Za-z0-9_-]+$"))
        XCTAssertTrue(String(decoding: BackendSharedServerAddresses.fromBase64Url(String(printed.dropFirst(5))), as: UTF8.self).contains(encodedKey))
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent(); for _ in 0..<4 { root.deleteLastPathComponent() }
        let swift = try String(contentsOf: root.appendingPathComponent("ios/Tests/ServerAddressFixture.swift"), encoding: .utf8)
        let kotlin = try String(contentsOf: root.appendingPathComponent("android/app/src/test/java/dev/terminaldeck/android/signin/ServerAddressFixture.kt"), encoding: .utf8)
        XCTAssertEqual(swift, BackendSharedTestPortFixtureSnapshots.swiftSource)
        XCTAssertEqual(kotlin, BackendSharedTestPortFixtureSnapshots.kotlinSource)
        XCTAssertTrue(swift.contains("static let printedByAHost = \"\(printed)\""))
        XCTAssertTrue(kotlin.contains("const val PRINTED_BY_A_HOST = \"\(printed)\""))
        XCTAssertTrue(swift.contains("static let version = \(BackendSharedServerAddresses.version)"))
        XCTAssertTrue(kotlin.contains("const val VERSION = \(BackendSharedServerAddresses.version)"))
    }
    func testServerWhereAllDefaultAndAbsentShapes() {
        XCTAssertEqual(BackendSharedServerWhere.address("192.0.2.11", port: 22), "192.0.2.11")
        XCTAssertEqual(BackendSharedServerWhere.address("example.com"), "example.com")
        XCTAssertEqual(BackendSharedServerWhere.address("example.com", port: Double(BackendSharedServerWhere.defaultSSHPort)), "example.com")
        XCTAssertEqual(BackendSharedServerWhere.address("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(BackendSharedServerWhere.address("[2001:db8::1]", port: 2222), "[2001:db8::1]:2222")
        XCTAssertEqual(BackendSharedServerWhere.whereLine(address: "example.com", username: "admin"), "admin at example.com")
        XCTAssertEqual(BackendSharedServerWhere.whereLine(address: "example.com", port: 2222, username: ""), "example.com:2222")
    }
    func testModelExactResolvedRowsAliasesAndFolding() throws {
        let rows = try XCTUnwrap(BackendSharedModelCatalog.readModelPicker(BackendSharedModelFixtures.macPicker))
        XCTAssertEqual(rows.map { "\($0.name) → \($0.model)" }, ["Default (recommended) → Opus 5 with 1M context", "Opus (1M context) → Opus 5 with 1M context", "Fable → Fable 5", "Sonnet → Sonnet 5", "Haiku → Haiku 4.5", "Opus → Opus 5"])
        XCTAssertEqual(rows.map(\.alias), ["default", "opus[1m]", "fable", "sonnet", "haiku", "opus"])
        let folded = BackendSharedModelCatalog.foldDefaultRow(rows)
        XCTAssertEqual(folded.map(\.name), ["Opus (1M context)", "Fable", "Sonnet", "Haiku", "Opus"])
        XCTAssertEqual(folded.filter(\.recommended).map(\.name), ["Opus (1M context)"])
        XCTAssertTrue(folded.contains(where: \.current))
        for (name, alias) in [("Fable", "fable"), ("Sonnet", "sonnet"), ("Haiku", "haiku")] { XCTAssertEqual(BackendSharedModelCatalog.aliasForRow(name), alias) }
        for value in ["default", "opus", "opus[1m]", "fable", "sonnet", "haiku", "opusplan"] { XCTAssertTrue(BackendSharedModelCatalog.isTypeableModelValue(value)) }
        for row in BackendSharedModelCatalog.fallbackModels + BackendSharedModelCatalog.previousModels where row.alias != "opusplan" { XCTAssertTrue(BackendSharedText.matches(row.model, "[0-9]")) }
        let current = Set(BackendSharedModelCatalog.fallbackModels.map(\.model))
        for row in BackendSharedModelCatalog.previousModels { XCTAssertFalse(current.contains(row.model)) }
    }
}
