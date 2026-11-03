import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// DKA2: the three fixes from Commander's live iMatch checks (9 Oct).
@Suite("Docker targets per key, readable logs, Look only windows off")
struct BackendDKA2CommanderFixesTests {
    @Test func dockerTargetsListOnlyWhatTheKeyMayReachAndNeverRefuse() {
        let given = BackendServersStoredServer(id: "imatch", name: "iMatch", address: "a", username: "u", aiKeyIDs: ["ClaudeiMatch"])
        let other = BackendServersStoredServer(id: "other", name: "Other", address: "b", username: "u", aiKeyIDs: [])
        let rows = [given, other]
        #expect(BackendDockerMCPServerKeyScope.visible(rows, caller: nil).map(\.id) == ["imatch", "other"])
        #expect(BackendDockerMCPServerKeyScope.visible(rows, caller: .local).map(\.id) == ["imatch", "other"])
        #expect(BackendDockerMCPServerKeyScope.visible(rows, caller: .init(kind: .key, tiers: [.read], keyID: "ClaudeiMatch")).map(\.id) == ["imatch"])
        #expect(BackendDockerMCPServerKeyScope.visible(rows, caller: .init(kind: .key, tiers: [.read], keyID: "Dot")).isEmpty)
        #expect(BackendDockerMCPServerKeyScope.visible(rows, caller: .init(kind: .remote, tiers: [.read])).isEmpty)
    }

    @Test func onlyRealSecretsAreMaskedInLiveOutput() {
        for (name, value) in [("POSTGRES_PASSWORD", "hunter2pass"), ("DATABASE_URL", "postgres://app:s3cret@db:5432/app"),
                              ("STRIPE_SECRET", "sk_live_51HxQ2abc"), ("NEUTRAL", "aZ3kP9qL2mX8vB7nC4wT6yR1"), ("API_TOKEN", "abcd")] {
            #expect(BackendDockerSecretFilter.isSecret(name: name, value: value), "\(name)")
        }
        for (name, value) in [("NODE_ENV", "production"), ("REPLICAS", "1"), ("PORT", "3000"), ("APP_VERSION", "2026.10.08"),
                              ("SESSION_TIMEOUT", "3600"), ("TZ", "Asia/Dubai"), ("DEBUG", "true"), ("PATH", "/usr/local/bin:/usr/bin"),
                              ("STARTED", "2026-10-09T08:50:00.123456789Z"), ("PUBLIC_URL", "https://imatch.ae"), ("EMPTY", "")] {
            #expect(!BackendDockerSecretFilter.isSecret(name: name, value: value), "\(name)")
        }
    }

    @Test func aLogLineKeepsItsTimestampWhileTheSecretIsHidden() throws {
        let env = NativeRPCValue.array(["REPLICAS=1", "NODE_ENV=production", "PORT=0", "POSTGRES_PASSWORD=hunter2pass", "TZ=Asia/Dubai"].map(NativeRPCValue.string))
        let secrets = try BackendDockerClient.streamSecrets(env)
        #expect(secrets == ["hunter2pass"])
        var masker = try BackendDockerStreams.SecretMasker(secretValues: secrets)
        let line = "2026-10-09T08:50:00.123456789549000030Z [worker:outreach-tick] production ok 1 login with hunter2pass\n"
        let out = String(decoding: try masker.consume(Data(line.utf8)) + masker.finish(), as: UTF8.self)
        #expect(out.hasPrefix("2026-10-09T08:50:00.123456789549000030Z [worker:outreach-tick] production ok 1 login with "))
        #expect(!out.contains("hunter2pass"))
    }

    @Test func lookOnlyServersStartWithWindowDrivingOff() throws {
        let root = BackendServersS4RealTemp.directory().appendingPathComponent("dka2-windows-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let lookOnly = try store.add(.init(name: "iMatch", address: "a.example", username: "u"), sshAlias: "imza-server", lookOnly: true)
        let normal = try store.add(.init(name: "Box", address: "b.example", username: "u"))
        let reloaded = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        #expect(try reloaded.drivesWindows(lookOnly.id) == false)
        #expect(BackendServersSummary(try #require(try reloaded.get(lookOnly.id))).wireValue["drivesWindows"].bool == false)
        #expect(try reloaded.drivesWindows(normal.id) == true)
        // The owner can still turn it on explicitly.
        #expect(try reloaded.setDrivesWindows(lookOnly.id, allowed: true))
        // Choosing Look only later turns it off again.
        #expect(try reloaded.setLookOnly(normal.id, true))
        #expect(try reloaded.drivesWindows(normal.id) == false)
    }
}
