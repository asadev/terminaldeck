import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// DKA2 regression for Asad's 9 Oct false "different identity" on imza-server.
/// Root cause: ssh splits an unquoted -o value at spaces, so a scratch folder
/// under "Application Support" made UserKnownHostsFile two missing files and
/// every host check failed. Plus: type-aware host key checks, like OpenSSH.
@Suite("Host keys are checked like OpenSSH")
struct BackendDKA2HostKeyTests {
    private static func key(_ type: String, _ byte: UInt8) -> BackendServersSSH.ScannedKey {
        var blob = Data([0, 0, 0, UInt8(type.utf8.count)]) + Data(type.utf8) + Data([0, 0, 0, 32])
        blob.append(Data(repeating: byte, count: 32))
        return .init(algorithm: type, key: blob)
    }
    private let ed = key("ssh-ed25519", 1), ecdsa = key("ecdsa-sha2-nistp256", 2), rsa = key("ssh-rsa", 3)

    @Test func pathsWithSpacesStayOneOptionValueForRealSSH() throws {
        let file = URL(fileURLWithPath: "/private/tmp/Application Support/terminaldeck/servers/tmp/s.abc/known_hosts")
        let options = BackendServersSSH.strictOptions(server: .init(id: "s", name: "s", address: "198.51.100.7", username: "admin"),
            alias: "native-server-x", keyAlgorithm: "ssh-ed25519", knownHosts: file, identityAgent: URL(fileURLWithPath: "/private/tmp/agent dir/sock"))
        #expect(options.contains("UserKnownHostsFile=\"\(file.path)\""))
        #expect(options.contains("IdentityAgent=\"/private/tmp/agent dir/sock\""))
        // Live proof with a scratch folder containing a space: BackendDKA2IMatchAddPathTests.
    }

    @Test func ed25519OnlyKnownHostsAgainstAServerOfferingAllThreeUsesEd25519() {
        for order in [[ed, ecdsa, rsa], [rsa, ecdsa, ed], [ecdsa, ed, rsa]] {
            #expect(BackendServersSSH.chooseHostKey(scanned: order, pin: nil, trusted: [ed]) == .use(ed))
        }
    }
    @Test func aGenuinelyChangedKeyOfTheSameTypeIsStillRefused() {
        let other = Self.key("ssh-ed25519", 9)
        #expect(BackendServersSSH.chooseHostKey(scanned: [other, ecdsa, rsa], pin: nil, trusted: [ed]) == .changed(expected: ed, offered: other))
        let pin = BackendServersHostKeyRecord(algorithm: "ssh-ed25519", fingerprint: BackendServersConnections.fingerprintOf(ed.key), firstSeenAt: 1)
        if case .changed = BackendServersSSH.chooseHostKey(scanned: [other, ecdsa], pin: pin, trusted: []) {} else { Issue.record("changed pin not refused") }
    }
    @Test func aMissingRecordedTypeIsUnconfirmedNeverChanged() {
        #expect(BackendServersSSH.chooseHostKey(scanned: [ecdsa, rsa], pin: nil, trusted: [ed]) == .unconfirmed("ssh-ed25519"))
        let pin = BackendServersHostKeyRecord(algorithm: "ecdsa-sha2-nistp256", fingerprint: BackendServersConnections.fingerprintOf(ecdsa.key), firstSeenAt: 1)
        #expect(BackendServersSSH.chooseHostKey(scanned: [ed, rsa], pin: pin, trusted: []) == .unconfirmed("ecdsa-sha2-nistp256"))
        // The pinned ECDSA key is used even though ED25519 is preferred in general.
        #expect(BackendServersSSH.chooseHostKey(scanned: [ed, ecdsa, rsa], pin: pin, trusted: []) == .use(ecdsa))
        #expect(BackendServersSSH.chooseHostKey(scanned: [rsa, ecdsa, ed], pin: nil, trusted: []) == .use(ed))
    }
    @Test func scanAsksForRecordedTypesFirst() {
        #expect(BackendServersSSH.scanOrder(["ecdsa-sha2-nistp256"]) == ["ecdsa", "ed25519", "rsa"])
        #expect(BackendServersSSH.scanOrder([]) == ["ed25519", "ecdsa", "rsa"])
        #expect(BackendServersSSH.recordedTypes(pin: nil, trusted: [ed, ed, rsa]) == ["ssh-ed25519", "ssh-rsa"])
    }
    @Test func masterOutputNamesTheKeyItSaw() {
        let said = "debug1: loaded pubkey from /x: ED25519 SHA256:userkey\r\ndebug1: Server host key: ssh-ed25519 SHA256:32uDtQSuvo4FXFCrzpSyuh3DCbq6cYKsTgcoINHDAJY\r\nHost key verification failed.\r\n"
        let seen = BackendServersSSH.masterHostKey(said)
        #expect(seen?.0 == "ssh-ed25519" && seen?.1 == "SHA256:32uDtQSuvo4FXFCrzpSyuh3DCbq6cYKsTgcoINHDAJY")
        #expect(BackendServersSSH.masterHostKey("Host key verification failed.") == nil)
    }
    @Test func aPinOfAnotherTypeIsUnconfirmedButTheSameTypeIsChanged() async throws {
        let offeredType = BackendServersConnections.algorithmOf(BackendServersConnectionTestDialer.key)
        for (pinType, kind) in [("ecdsa-sha2-nistp384", "identity-unconfirmed"), (offeredType, "identity-changed")] {
            let app = try BackendServersIPCPortFixture(); defer { app.cleanup() }
            #expect(try app.store.rememberHostKey("s1", algorithm: pinType, fingerprint: "SHA256:somethingelse"))
            do { _ = try await app.pool.acquireLease("s1"); Issue.record("a mismatching pin connected") }
            catch let problem as BackendServersProblem { #expect(problem.kind == kind, "\(pinType)") }
            await app.stop()
        }
    }
}
