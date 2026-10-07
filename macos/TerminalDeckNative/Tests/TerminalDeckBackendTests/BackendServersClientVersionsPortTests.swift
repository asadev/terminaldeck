import Foundation
import Testing

/// Port of src/main/servers/client-versions.test.ts (0.19.0 on: the Mac ships
/// alone, so a Mac ahead of the phones is valid). What keeps installs and
/// pairing working: the lock agrees with package.json; both phones name the
/// same version, none ahead of the Mac, and it is a cut release (a phone
/// installs `releases/download/v<its version>/terminaldeck-<its version>.tgz`);
/// pairing compares one protocol number, the same on every side.
@Suite("client-versions.test.ts case parity")
struct BackendServersClientVersionsPortTests {
    private typealias F = BackendServersSetupPortFixtures
    private func version() throws -> String {
        let json = try JSONSerialization.jsonObject(with: Data(try F.read("package.json").utf8)) as? [String: Any]
        return try #require(json?["version"] as? String)
    }
    private func ios() throws -> String { try #require(F.capture(#"MARKETING_VERSION:\s*"([^"]+)""#, try F.read("ios/project.yml"))) }
    private func android() throws -> String { try #require(F.capture(#"versionName\s*=\s*"([^"]+)""#, try F.read("android/app/build.gradle.kts"))) }
    private func notAhead(_ phone: String, _ mac: String) -> Bool {
        let a = phone.split(separator: ".").map { Int($0) ?? 0 }, b = mac.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<3 where a[i] != b[i] { return a[i] < b[i] }
        return true
    }
    private func threePart(_ text: String) -> Bool { text.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }

    @Test("is a three-part version, and package-lock.json says the same") func threePartVersionAndLock() throws {
        let version = try version()
        #expect(threePart(version))
        let lock = try JSONSerialization.jsonObject(with: Data(try F.read("package-lock.json").utf8)) as? [String: Any]
        #expect(lock?["version"] as? String == version)
        #expect(((lock?["packages"] as? [String: Any])?[""] as? [String: Any])?["version"] as? String == version)
    }
    @Test("both phones declare a three-part version, and the same one") func phonesAgree() throws {
        let ios = try ios(), android = try android()
        #expect(threePart(ios)); #expect(threePart(android))
        #expect(ios == android)
    }
    @Test("no phone is ahead of the Mac") func noPhoneAhead() throws {
        let mac = try version()
        #expect(notAhead(try ios(), mac), "iOS is ahead of package.json")
        #expect(notAhead(try android(), mac), "Android is ahead of package.json")
    }
    @Test("the phones name a release that was cut") func phonesNameACutRelease() throws {
        #expect(try F.read("CHANGELOG.md").contains("## [\(try ios())]"), "the phones would fetch a release that was never made")
    }
    @Test("pairing checks one protocol number, and it is the same on every side") func oneProtocolNumber() throws {
        let ts = try #require(F.capture(#"export const PROTOCOL_VERSION = (\d+)"#, try F.read("src/main/remote/protocol.ts")))
        let iosProtocol = try #require(F.capture(#"static let protocolVersion = (\d+)"#, try F.read("ios/TerminalDeck/Protocol/WireProtocol.swift")))
        let androidProtocol = try #require(F.capture(#"const val VERSION = (\d+)"#, try F.read("android/app/src/main/java/dev/terminaldeck/android/protocol/Protocol.kt")))
        #expect(iosProtocol == ts); #expect(androidProtocol == ts)
        let swift = try ["BackendRemoteHost.swift", "BackendRemoteGuest.swift", "BackendRemoteGuestChannel.swift"]
            .map { try F.read("macos/TerminalDeckNative/Sources/TerminalDeckBackend/" + $0) }.joined(separator: "\n")
        let numbers = { (pattern: String) -> [String] in
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: swift, range: NSRange(swift.startIndex..., in: swift)).compactMap { Range($0.range(at: 1), in: swift).map { String(swift[$0]) } }
        }
        let said = numbers(#""protocol", \.number\((\d+)\)"#), checked = numbers(#"\["protocol"\]\.number == (\d+)"#)
        #expect(!said.isEmpty, "the Swift host no longer says its protocol number where this test looks")
        #expect(!checked.isEmpty, "the Swift host no longer checks the protocol number where this test looks")
        #expect(Set(said + checked) == [ts])
    }
}
