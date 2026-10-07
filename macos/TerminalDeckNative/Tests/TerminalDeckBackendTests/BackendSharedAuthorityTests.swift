import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedAuthorityTests: XCTestCase {
    func testAddressMatchesHostEncoderFixtureAndRefusesDamage() throws {
        // Literal encoder output from ios/Tests/ServerAddressFixture.swift;
        // fixture generation was read only, never run by this worker.
        let key = Data((1...32).map { UInt8(($0 * 7) % 256) })
        let printed = try XCTUnwrap(BackendSharedServerAddresses.format(url: "wss://relay.terminaldeck.dev", hostId: "KZ2J9AWGK8BWGQUEZDYKW5RS22", hostKey: key.base64EncodedString()))
        XCTAssertEqual(printed, "srv1.eyJraW5kIjoicmVsYXkiLCJ1cmwiOiJ3c3M6Ly9yZWxheS50ZXJtaW5hbGRlY2suZGV2IiwiaG9zdElkIjoiS1oySjlBV0dLOEJXR1FVRVpEWUtXNVJTMjIiLCJob3N0S2V5IjoiQnc0VkhDTXFNVGdfUmsxVVcySnBjSGQtaFl5VG1xR29yN2E5eE12UzJlQSJ9")
        let expected = BackendSharedServerAddress(url: "wss://relay.terminaldeck.dev", hostId: "KZ2J9AWGK8BWGQUEZDYKW5RS22", hostKey: BackendSharedServerAddresses.toBase64Url(key))
        XCTAssertEqual(BackendSharedServerAddresses.parse("  " + printed + "\n"), expected)
        XCTAssertEqual(BackendSharedServerAddresses.format(url: expected.url, hostId: expected.hostId, hostKey: expected.hostKey), printed)
        for bad in [printed + "*", String(printed.dropLast(6)), printed.replacingOccurrences(of: "srv1.", with: "srv2."), "srv1." + String(repeating: "A", count: 5000)] { XCTAssertNil(BackendSharedServerAddresses.parse(bad)) }
        XCTAssertNil(BackendSharedServerAddresses.format(url: "https://relay.example", hostId: expected.hostId, hostKey: expected.hostKey))
        XCTAssertNil(BackendSharedServerAddresses.hostKeyBytes(Data(repeating: 1, count: 31).base64EncodedString()))
        XCTAssertFalse(BackendSharedServerAddresses.isHostId("0" + expected.hostId.dropFirst()))
        XCTAssertFalse(BackendSharedServerAddresses.isRelayUrl("wss://relay.example\u{7}"))
    }
    func testServerWhereAlwaysShowsNondefaultPort() {
        XCTAssertEqual(BackendSharedServerWhere.whereLine(address: "192.0.2.11", port: 2222, username: "admin"), "admin at 192.0.2.11:2222")
        XCTAssertEqual(BackendSharedServerWhere.address("2001:db8::1", port: 2222), "[2001:db8::1]:2222")
        XCTAssertEqual(BackendSharedServerWhere.address("[::1]", port: 2222), "[::1]:2222")
        for port in [Double.nan, 0, -1, 65536, 22.5, 22] { XCTAssertEqual(BackendSharedServerWhere.address("example.com", port: port), "example.com") }
        XCTAssertEqual(BackendSharedServerWhere.whereLine(address: "example.com", username: ""), "example.com")
    }
    func testStoreOverridePrecedenceAndRefusal() {
        let variable = BackendSharedStoreApi.environmentKey
        let fallback = BackendSharedStoreApi.resolve(environment: [variable: "http://evil.example"], configured: "https://staging.terminaldeck.dev/")
        XCTAssertEqual(fallback.base, "https://staging.terminaldeck.dev")
        XCTAssertTrue(fallback.overridden)
        XCTAssertEqual(fallback.ignored, "http://evil.example is plain http, which is only allowed on this machine")
        for base in ["http://127.0.0.1:8931", "http://localhost:8931", "http://[::1]:8931"] { XCTAssertEqual(BackendSharedStoreApi.base(environment: [variable: base]), base) }
        XCTAssertEqual(BackendSharedStoreApi.resolve(environment: [variable: " "]).ignored, "it was empty")
        XCTAssertEqual(BackendSharedStoreApi.base(environment: [:]), "https://terminaldeck.dev")
        XCTAssertEqual(BackendSharedStoreApi.indexUrl("http://localhost:8931/"), "http://localhost:8931/store/index.json")
        XCTAssertEqual(BackendSharedStoreApi.resolve(environment: [variable: "file:///tmp/index.json"]).ignored, "file:///tmp/index.json is not http or https")
    }
    func testDevelopmentKeyRequiresExactOptInAndUnpackagedRun() {
        XCTAssertEqual(BackendSharedStoreKeys.slots.count, 2); XCTAssertNil(BackendSharedStoreKeys.slots[1])
        let key = BackendSharedStoreKeys.environmentKey
        XCTAssertEqual(BackendSharedStoreKeys.keys(environment: [key: "1"], packaged: true), BackendSharedStoreKeys.live)
        for value in ["true", "yes", "on", "0", "", " 1", "1 "] { XCTAssertEqual(BackendSharedStoreKeys.keys(environment: [key: value], packaged: false), BackendSharedStoreKeys.live) }
        XCTAssertEqual(BackendSharedStoreKeys.keys(environment: [key: "1"], packaged: false), BackendSharedStoreKeys.live + [BackendSharedStoreKeys.development])
    }
    func testCapabilityLimitsMatchTheWholeMatrix() {
        typealias C = BackendSharedAgentCapabilities
        for family in C.Family.allCases { for setting in C.Setting.allCases { let cell = C.capabilities[family]![setting]!; XCTAssertFalse(cell.how.isEmpty); XCTAssertFalse(cell.evidence.isEmpty) } }
        XCTAssertEqual(C.familiesEnforcing(.blockedTools), [.claude])
        XCTAssertEqual(C.familiesEnforcing(.instructions), [.claude, .codex])
        XCTAssertEqual(C.capabilityFor(nil, setting: .instructions).support, .advisory)
        XCTAssertTrue(C.enforces(nil, setting: .blockedTools)); XCTAssertFalse(C.enforces("codex", setting: .model))
        XCTAssertEqual(C.familyOf("custom:aider"), .custom)
        XCTAssertEqual(C.agentLabel("codex"), "Codex CLI")
        XCTAssertEqual(BackendSharedAgentTools.mcpServerTool("name with space"), "mcp__name_with_space")
        XCTAssertFalse(BackendSharedAgentTools.isToolName("--allowedTools"))
        XCTAssertNil(BackendSharedAgentTools.mcpServerTool(String(repeating: "x", count: 65)))
    }
}
