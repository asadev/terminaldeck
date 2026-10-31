import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("SSH discovery lists names without reading private keys")
struct BackendDockerMCPServerKeyDiscoveryTests {
    @Test func defaultKeyIsOfferedWithoutReadingItsContents() {
        let read = BackendDeckCoreSecurityTestBox<[String]>([])
        let reader = BackendServersKeyFolderReader(entries: { _ in
            ["id_ed25519", "id_ed25519.pub", "known_hosts", "known_hosts.old", "config", "authorized_keys"]
        }, read: { path in read.edit { $0.append(path) }; throw CancellationError() },
        size: { path in path.hasSuffix("/config") ? 0 : 100 })
        let offers = BackendServersKeyFileOffers(keyRoot: URL(fileURLWithPath: "/synthetic/home/.ssh"), reader: reader, nameOnlyDiscovery: true)
        #expect(offers.list().map(\.name) == ["id_ed25519"])
        #expect(read.get().allSatisfy { $0.hasSuffix("/config") })
    }

    @Test func identityFileOutsideSSHDirectoryIsNamedAndDeduplicated() {
        let read = BackendDeckCoreSecurityTestBox<[String]>([])
        let reader = BackendServersKeyFolderReader(entries: { _ in ["config", "id_ed25519"] }, read: { path in
            read.edit { $0.append(path) }
            guard path.hasSuffix("/config") else { throw CancellationError() }
            return "Host imza-server\n IdentityFile ~/keys/production\n IdentityFile ~/.ssh/id_ed25519\n IdentityFile none\n"
        }, size: { _ in 100 })
        let offers = BackendServersKeyFileOffers(keyRoot: URL(fileURLWithPath: "/synthetic/home/.ssh"), reader: reader, nameOnlyDiscovery: true)
        #expect(Set(offers.list().map(\.path)) == ["/synthetic/home/.ssh/id_ed25519", "/synthetic/home/keys/production"])
        #expect(read.get() == ["/synthetic/home/.ssh/config"])
        #expect(offers.read("/synthetic/home/not-offered")["ok"].bool == false)
    }
}
