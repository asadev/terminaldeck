import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDockerMCPSSHConfigFixture {
    private var responses: [BackendServersRunResult]
    private var requests: [BackendDockerMCPServerSSHConfig.Evaluation] = []
    init(_ responses: [BackendServersRunResult]) { self.responses = responses }
    func evaluate(_ request: BackendDockerMCPServerSSHConfig.Evaluation) throws -> BackendServersRunResult {
        requests.append(request)
        guard !responses.isEmpty else { throw NativeRPCError(code: "unavailable", message: "Unexpected fixture evaluation") }
        return responses.removeFirst()
    }
    func recorded() -> [BackendDockerMCPServerSSHConfig.Evaluation] { requests }
}

private actor BackendDockerMCPSSHConfigEntry {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
final class BackendDockerMCPServerSSHConfigTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home", isDirectory: true)
    private let basic = "hostname example.invalid\nuser fixture-user\nport 2222\n"
    private func resolver(_ fixture: BackendDockerMCPSSHConfigFixture) -> BackendDockerMCPServerSSHConfig {
        .init(evaluate: { try await fixture.evaluate($0) })
    }

    func testEffectiveFieldsAndIdentityOrderComeFromSSHOutput() async throws {
        let fake = BackendDockerMCPSSHConfigFixture([.init(code: 0, stdout: basic + "identityfile ~/.ssh/team key\nidentityfile %d/.ssh/second\nidentityfile /fixture/custom/key\n")])
        let value = try await resolver(fake).resolve(alias: "fixture-prod", home: home)
        XCTAssertEqual(value.hostname, "example.invalid")
        XCTAssertEqual(value.user, "fixture-user")
        XCTAssertEqual(value.port, 2222)
        XCTAssertEqual(value.identityFiles, ["/fixture/home/.ssh/team key", "/fixture/home/.ssh/second", "/fixture/custom/key"])
        let requests = await fake.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executable.path, "/usr/bin/ssh")
        XCTAssertEqual(Array(requests[0].arguments.prefix(3)), ["-G", "-F", "/fixture/home/.ssh/config"])
        XCTAssertEqual(Array(requests[0].arguments.suffix(2)), ["--", "fixture-prod"])
        XCTAssertEqual(requests[0].environment["HOME"], home.path)
        XCTAssertNil(requests[0].environment["SSH_AUTH_SOCK"])
        XCTAssertEqual(requests[0].workingDirectory, home)
        XCTAssertTrue((1...5_000).contains(requests[0].timeoutMilliseconds))
        XCTAssertEqual(requests[0].maximumOutputBytes, 65_536)
    }

    func testExplicitConfigAndRelativeOrPercentPathsUseExplicitHome() async throws {
        let fake = BackendDockerMCPSSHConfigFixture([.init(code: 0, stdout: basic + "identityfile keys/relative\nidentityfile %d/.ssh/percent%%key\n")])
        let config = URL(fileURLWithPath: "/fixture/home/.ssh/team-config")
        let value = try await resolver(fake).resolve(alias: "fixture", home: home, configurationFile: config)
        XCTAssertEqual(value.identityFiles, ["/fixture/home/keys/relative", "/fixture/home/.ssh/percent%key"])
        let requests = await fake.recorded()
        XCTAssertEqual(requests[0].arguments[2], config.path)
    }

    func testMissingIdentityPreservesTheDefaultSSHIdentityOrder() async throws {
        let fake = BackendDockerMCPSSHConfigFixture([
            .init(code: 0, stdout: basic),
            .init(code: 0, stdout: "identityfile ~/.ssh/id_rsa\nidentityfile ~/.ssh/id_ed25519\nidentityfile ~/.ssh/id_ecdsa\n")
        ])
        let value = try await resolver(fake).resolve(alias: "fixture", home: home)
        XCTAssertEqual(value.identityFiles, ["/fixture/home/.ssh/id_rsa", "/fixture/home/.ssh/id_ed25519", "/fixture/home/.ssh/id_ecdsa"])
        XCTAssertEqual(value.hostname, "example.invalid")
        let requests = await fake.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].arguments[2], "/dev/null")
    }

    func testExplicitIdentityNoneDoesNotGuessAKeyOrRequestFallback() async throws {
        let fake = BackendDockerMCPSSHConfigFixture([.init(code: 0, stdout: basic + "identityfile none\n")])
        let value = try await resolver(fake).resolve(alias: "fixture", home: home)
        XCTAssertTrue(value.identityFiles.isEmpty)
        let requests = await fake.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testAliasOptionsWhitespaceShellSyntaxAndWildcardsFailBeforeEvaluator() async throws {
        let fake = BackendDockerMCPSSHConfigFixture([])
        for alias in ["", "-oProxyCommand=unsafe", "fixture\nother", "user@host", "fixture;command", "*", "fixture/other"] {
            do { _ = try await resolver(fake).resolve(alias: alias, home: home); XCTFail("Invalid alias accepted: \(alias)") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        }
        let requests = await fake.recorded()
        XCTAssertTrue(requests.isEmpty)
    }

    func testProxyCommandsHooksAndAgentSettingsAreNotReturnedOrForwarded() async throws {
        let fake = BackendDockerMCPSSHConfigFixture([.init(code: 0, stdout: basic + "identityfile ~/.ssh/key\nproxycommand unsafe-proxy-hook\nlocalcommand unsafe-local-hook\nremotecommand unsafe-remote-hook\nidentityagent unsafe-agent-socket\n")])
        let value = try await resolver(fake).resolve(alias: "fixture", home: home)
        XCTAssertEqual(value.identityFiles, ["/fixture/home/.ssh/key"])
        let requests = await fake.recorded()
        let request = try XCTUnwrap(requests.first)
        for value in ["unsafe-proxy-hook", "unsafe-local-hook", "unsafe-remote-hook", "unsafe-agent-socket"] {
            XCTAssertFalse(request.arguments.contains(value))
        }
        for option in ["ProxyCommand=none", "PermitLocalCommand=no", "LocalCommand=none", "RemoteCommand=none", "IdentityAgent=none"] {
            XCTAssertTrue(request.arguments.contains(option))
        }
    }

    func testFailureTruncationAndOversizedOutputNeverExposeStderrOrOutput() async throws {
        for response in [
            BackendServersRunResult(code: 255, stdout: "private-key-data", stderr: "private-secret-stderr"),
            .init(code: 0, stdout: basic, stderr: "private-secret-stderr", truncated: true),
            .init(code: 0, stdout: String(repeating: "private-output ", count: 8_000))
        ] {
            let fake = BackendDockerMCPSSHConfigFixture([response])
            do { _ = try await resolver(fake).resolve(alias: "fixture", home: home); XCTFail("Failed/bounded evaluation succeeded") }
            catch let error as NativeRPCError {
                XCTAssertEqual(error.code, "unavailable")
                XCTAssertFalse(error.message.contains("private-"))
            }
        }
    }

    func testMissingFieldsInvalidPortDuplicatesAndUnsupportedIdentityTokensRefuse() async throws {
        for output in [
            "hostname example.invalid\nport 22\nidentityfile ~/.ssh/key\n",
            "hostname example.invalid\nuser fixture\nport 65536\nidentityfile ~/.ssh/key\n",
            basic + "hostname other.invalid\nidentityfile ~/.ssh/key\n",
            basic + "identityfile ~other-user/.ssh/key\n",
            basic + "identityfile %x/.ssh/key\n"
        ] {
            let fake = BackendDockerMCPSSHConfigFixture([.init(code: 0, stdout: output)])
            do { _ = try await resolver(fake).resolve(alias: "fixture", home: home); XCTFail("Malformed/unresolved output succeeded") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        }
    }

    func testCancellationPropagatesThroughInjectedEvaluator() async throws {
        let entered = BackendDockerMCPSSHConfigEntry()
        let resolver = BackendDockerMCPServerSSHConfig(evaluate: { _ in
            await entered.arrive()
            try await Task.sleep(for: .seconds(30))
            return .init(code: 0, stdout: "unused")
        })
        let operation = Task { try await resolver.resolve(alias: "fixture", home: home) }
        await entered.wait()
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled alias evaluation succeeded") }
        catch is CancellationError { }
    }
}
