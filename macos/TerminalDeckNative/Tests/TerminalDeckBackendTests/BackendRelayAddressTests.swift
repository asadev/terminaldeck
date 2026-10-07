import XCTest
@testable import TerminalDeckBackend

/// relay-client.ts relayUrl/relayEnabled: on by default, compiled-in address,
/// the environment may rename or switch it off. 0.19.0/0.19.1 dialled no relay at
/// all (they read a settings key that never exists), so phones could not connect.
final class BackendRelayAddressTests: XCTestCase {
    func testDefaultsToTheCompiledInRelay() {
        XCTAssertEqual(BackendRelayAddress.resolve(environment: [:]), "wss://relay.terminaldeck.dev")
        XCTAssertEqual(BackendRelayAddress.resolve(environment: ["TERMINALDECK_RELAY_URL": "  "]), "wss://relay.terminaldeck.dev")
    }
    func testEnvironmentNamesAnotherRelay() {
        XCTAssertEqual(BackendRelayAddress.resolve(environment: ["TERMINALDECK_RELAY_URL": " wss://relay.example "]), "wss://relay.example")
    }
    func testEnvironmentSwitchesItOff() {
        for off in ["off", "0", "false", "NO"] { XCTAssertNil(BackendRelayAddress.resolve(environment: ["TERMINALDECK_RELAY": off])) }
        XCTAssertEqual(BackendRelayAddress.resolve(environment: ["TERMINALDECK_RELAY": "on"]), "wss://relay.terminaldeck.dev")
    }
    func testNoProductionPathReadsTheNonexistentSetting() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
        for name in ["NativeCompositionProductionRemote.swift", "NativeCompositionProductionMachines.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("BackendRelayAddress.resolve()"), "\(name) must dial the relay by default")
            XCTAssertFalse(text.contains("[\"remote.relay" + "Url\"]"), "\(name) reads a settings key that does not exist")
        }
    }
}
