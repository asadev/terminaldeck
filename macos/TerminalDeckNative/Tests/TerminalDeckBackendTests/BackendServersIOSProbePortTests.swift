import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("ios-probe-scripts.test.ts byte parity; read-only artifacts")
struct BackendServersIOSProbePortTests {
    @Test("is the same script on both sides") func iosBothScriptsMatchNative() throws {
        let text = try BackendServersSetupPortFixtures.read("ios/TerminalDeck/Servers/ProbeScripts.swift")
        #expect(try BackendServersSetupPortFixtures.rawSwiftLiteral("server", from: text) == BackendServersProbe.script)
        #expect(try BackendServersSetupPortFixtures.rawSwiftLiteral("host", from: text) == BackendServersHostScripts.probe)
    }
    @Test("is the same host probe in the Android assets") func androidHostAssetMatchesNative() throws {
        #expect(try BackendServersSetupPortFixtures.read("android/app/src/main/assets/probe-host.sh") == BackendServersHostScripts.probe)
    }
    @Test("carries nothing a raw Swift literal cannot hold") func rawSwiftDelimiterIsAbsent() {
        #expect(!BackendServersProbe.script.contains("\"\"\"#")); #expect(!BackendServersHostScripts.probe.contains("\"\"\"#"))
    }
}
