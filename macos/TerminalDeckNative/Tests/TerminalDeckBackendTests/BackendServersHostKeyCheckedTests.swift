import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("SSH has one checked door")
struct BackendServersHostKeyCheckedTests {
    @Test func fingerprintMatchesTheIndependentSourceFixture() throws {
        let key = try #require(Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIPUEO0mZueAVQxh2emvO8ztX7nRK0Eb6O6vD8/W+hSV9"))
        #expect(BackendServersConnections.fingerprintOf(key) == "SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0")
        #expect(BackendServersConnections.algorithmOf(key) == "ssh-ed25519")
        #expect(BackendServersSSH.scannedKeys("box ssh-ed25519 \(key.base64EncodedString())\n").count == 1)
        #expect(BackendServersSSH.scannedKeys("box ssh-rsa \(key.base64EncodedString())\n").isEmpty)
    }
    @Test func everyMasterUsesPrivateStrictPinsAndNoAgentOrConfiguration() {
        let server = BackendServersStoredServer(id: "one", name: "one", address: "box", username: "root")
        let options = BackendServersSSH.strictOptions(server: server, alias: "only-one", keyAlgorithm: "ssh-ed25519", knownHosts: URL(fileURLWithPath: "/explicit/private/known_hosts"))
        #expect(options.contains("StrictHostKeyChecking=yes") && options.contains("UserKnownHostsFile=/explicit/private/known_hosts") && options.contains("HostKeyAlias=only-one"))
        #expect(options.contains("GlobalKnownHostsFile=/dev/null") && options.contains("IdentityAgent=none") && options.contains("IdentitiesOnly=yes") && options.contains("ForwardAgent=no"))
        #expect(options.contains("ServerAliveInterval=0") && options.contains("TCPKeepAlive=no") && options.contains("ProxyCommand=none"))
        #expect(Array(options.prefix(2)) == ["-F", "/dev/null"])
        #expect(!options.contains(where: { $0.contains("StrictHostKeyChecking=no") || $0.contains("accept-new") }))
        let env = BackendServersSSH.environment()
        #expect(env["SSH_AUTH_SOCK"] == nil && env["password"] == nil && env["passphrase"] == nil && env["privateKey"] == nil)
    }
    @Test func noPermissionOrHelperDoesNotTouchScratchOrLaunch() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("servers-denied-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ssh = BackendServersSSH(scratchRoot: scratch, policy: .init(mayConnect: false, helperExecutable: URL(fileURLWithPath: "/explicit/helper"), helperDispatchInstalled: false))
        do { _ = try await ssh.dial(server: .init(id: "one", name: "one", address: "box", username: "root"), credential: .password("test-only"), verifyHostKey: { _ in }); Issue.record("Started without native permission") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }
    @Test func sourceOnlyConnectionConsumesCredentialAndNoOtherModuleSpawnsSSH() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend")
        let paths = try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("BackendServers") && $0.pathExtension == "swift" }
        #expect(!paths.isEmpty)
        for file in paths {
            let body = try String(contentsOf: file, encoding: .utf8)
            if body.contains("credentials.read(") { #expect(file.lastPathComponent == "BackendServersConnection.swift") }
            if body.contains("/usr/bin/ssh\"") || body.contains("/usr/bin/ssh-keyscan\"") || body.contains("/usr/bin/ssh-keygen\"") { #expect(file.lastPathComponent.hasPrefix("BackendServersSSH")) }
            if ["BackendServersIPC.swift", "BackendServersTools.swift", "BackendServersCoordinator.swift"].contains(file.lastPathComponent) {
                #expect(!body.contains("credentials.read("))
            }
        }
    }
    @Test func askpassDispatchWithoutSocketRefusesWithoutOutput() { #expect(BackendServersSSHAskpass.run(arguments: ["helper", "--servers-askpass", "challenge"], environment: [:]) == 1) }
    @Test func keyParsingAndAuthenticationNeverWritePrivateKeyText() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend")
        let adapter = try String(contentsOf: sourceRoot.appendingPathComponent("BackendServersSSH.swift"), encoding: .utf8)
        let agent = try String(contentsOf: sourceRoot.appendingPathComponent("BackendServersSSHAgent.swift"), encoding: .utf8)
        #expect(!adapter.contains("contents: Data(text.utf8)") && !adapter.contains("/usr/bin/ssh-keygen"))
        #expect(adapter.contains("agent.publicIdentity") && adapter.contains("identity.pub"))
        #expect(agent.contains("load.collect(stdin: keyBytes") && agent.contains("privateKey.hasSuffix") && agent.contains("arguments: [\"-\"]"))
        #expect(agent.contains("arguments: [\"-L\"]") && agent.contains("APPLE_SSH_ADD_BEHAVIOR"))
        #expect(!agent.contains("contents: Data(privateKey") && !agent.contains("contents: Data(passphrase"))
    }
}
