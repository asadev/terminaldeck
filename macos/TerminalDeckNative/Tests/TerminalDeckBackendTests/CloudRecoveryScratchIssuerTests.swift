import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Blocker 1 of the lean first version: saved passwords accept production's issuer only. The TEST issuer is
/// admitted in a debug build alone, and only through a permit that re-checks lane A's scratch-plan conditions.
/// Fixture service and fixture key store only; folders only under ~/Deck Dev/notes/cloud-test-20261112/v/.
@MainActor
final class CloudRecoveryScratchIssuerTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudRecoveryScratchIssuerTests assertions=\(assertions)") }
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(condition, "Scratch issuer assertion", file: file, line: line)
    }
    static let testIssuer = "https://td-cloud-test.terminaldeck.workers.dev/auth/v1"
    static let testBase = "https://td-cloud-test.terminaldeck.workers.dev/v1"

    private struct Client {
        let coordinator: CloudRecoveryCoordinator
        let local: CloudSecretsFixtureLocal
    }
    /// One identity under `issuer`, over the fixture service.
    private func client(issuer: String, server: CloudSecretsFixtureServer) async throws -> Client {
        let keys = CloudSecretsFixtureKeys()
        let device = try keys.registration(UUID().uuidString.lowercased())
        let caller = device.deviceId
        let control = BackendCloudSecretsControl(send: { method, path, body, requestId in
            try await server.handle(caller: caller, method: method, path: path, body: body, requestId: requestId)
        }, registeredDevice: { try await server.registration($0) })
        let policy = CloudSecretsPolicy(capabilities: {
            CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, expiresAt: CloudSecretsFixtureServer.now + 300_000)
        }, now: { CloudSecretsFixtureServer.now })
        let local = CloudSecretsFixtureLocal()
        let made = CloudRecoveryCoordinator(subject: CloudSubject(issuer: issuer, sub: CloudSecretsFixtureServer.sub), device: device,
            keys: keys, local: local, control: control, words: BackendCloudRecoveryMnemonic(), interaction: CloudSecretsFixtureUI(),
            policy: policy, resetTicket: { throw CloudFailure.unavailable })
        await server.register(device)
        return Client(coordinator: made, local: local)
    }
    private func refused(_ work: () async throws -> Void) async -> Bool {
        do { try await work(); return false } catch CloudFailure.invalidRequest { return true } catch { return false }
    }

    /// What a release build does for every caller (it has no permit to adopt): an identity that is not
    /// production's is refused at every entry, before any request leaves and before any key is touched.
    func testWithoutAPermitANonProductionIssuerIsRefusedAtEveryEntryBeforeAnyRequest() async throws {
        for issuer in [Self.testIssuer, "https://issuer.example.invalid/auth/v1", CloudWire.issuer + "/", ""] {
            let server = CloudSecretsFixtureServer()
            let made = try await client(issuer: issuer, server: server)
            let coordinator = made.coordinator
            check(await refused { _ = try await coordinator.status() })
            check(await refused { try await coordinator.setup() })
            check(await refused { _ = try await coordinator.requestApproval() })
            check(await refused { try await coordinator.approve(id: UUID().uuidString.lowercased()) })
            check(await refused { _ = try await coordinator.receiveApproval() })
            check(await refused { _ = try await coordinator.confirmPendingAcknowledgement() })
            check(await refused { try await coordinator.recover() })
            check(await refused { try await coordinator.reset() })
            let sent = await server.bodies.count, saves = await made.local.saves, epoch = await server.epoch
            check(sent == 0)
            check(saves == 0)
            check(epoch == 0)
        }
    }
    /// Production's own issuer keeps working with no permit at all (the unchanged path).
    func testProductionsIssuerNeedsNoPermit() async throws {
        let server = CloudSecretsFixtureServer()
        let made = try await client(issuer: CloudWire.issuer, server: server)
        try await made.coordinator.setup()
        let saves = await made.local.saves
        check(saves == 1)
        check(try await made.coordinator.status().recoveryReady)
    }
    /// A release build compiles none of the scratch path: in the coordinator's source every line that names it
    /// sits inside an `#if DEBUG` block (comments compile to nothing and are skipped).
    func testEveryScratchLineOfTheCoordinatorSitsInsideADebugOnlyBlock() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNativeCore/CloudRecoveryCoordinator.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        var blocks: [Bool] = []
        var outside: [Int] = []
        var guarded = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") { blocks.append(trimmed == "#if DEBUG"); continue }
            if trimmed.hasPrefix("#else") { if !blocks.isEmpty { blocks[blocks.count - 1] = false }; continue }
            if trimmed.hasPrefix("#endif") { _ = blocks.popLast(); continue }
            if trimmed.hasPrefix("//") { continue }
            guard line.lowercased().contains("scratch") else { continue }
            if blocks.contains(true) { guarded += 1 } else { outside.append(index + 1) }
        }
        check(outside.isEmpty)
        check(guarded > 0)
        check(blocks.isEmpty)
        // The one production comparison is still there, outside every conditional block.
        check(text.contains("if subject.issuer == CloudWire.issuer { return true }"))
    }

    #if DEBUG
    private func folder() throws -> URL {
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/v").resolvingSymlinksInPath()
        let made = approved.appendingPathComponent("scratch-issuer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    private func permit(_ dataRoot: URL, base: String? = nil, issuer: String? = nil) -> CloudSecretsScratchPermit? {
        guard let url = URL(string: base ?? Self.testBase) else { return nil }
        return CloudSecretsScratchPermit(dataRoot: dataRoot, base: url, issuer: issuer ?? Self.testIssuer)
    }
    /// The permit exists only under lane A's scratch-plan conditions, each checked again here.
    func testAPermitExistsOnlyForAScratchFolderTheExactTestServiceAndANonProductionIssuer() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("p3-a/data", isDirectory: true)
        check(permit(data)?.issuer == Self.testIssuer)
        check(CloudSecretsScratchPermit.testHost == "td-cloud-test.terminaldeck.workers.dev")
        // Never a data folder a person uses: under an Application Support folder (a stand-in inside the fixture
        // folder; the real one is never read), in another letter case, through a symbolic link, or a folder with
        // the real app's own name.
        let support = folder.appendingPathComponent("home/Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Terminal Deck Dev"), withIntermediateDirectories: true)
        check(permit(support.appendingPathComponent("Terminal Deck Dev")) == nil)
        check(permit(support) == nil)
        check(permit(folder.appendingPathComponent("home/library/application support/copy")) == nil)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: support.appendingPathComponent("Terminal Deck Dev"))
        check(permit(link) == nil)
        check(permit(link.appendingPathComponent("data")) == nil)
        check(permit(folder.appendingPathComponent("terminaldeck")) == nil)
        check(permit(folder.appendingPathComponent("TerminalDeck")) == nil)
        check(permit(URL(fileURLWithPath: "/")) == nil)
        check(CloudSecretsScratchPermit(dataRoot: URL(string: "https://example.invalid/data")!, base: URL(string: Self.testBase)!, issuer: Self.testIssuer) == nil)
        // Only the TEST worker, matched exactly.
        for base in ["https://api.terminaldeck.dev/v1", "http://td-cloud-test.terminaldeck.workers.dev/v1",
                     "https://td-cloud-test.terminaldeck.workers.dev.example.invalid/v1", "https://td-cloud-test-2.terminaldeck.workers.dev/v1",
                     "https://x.td-cloud-test.terminaldeck.workers.dev/v1", "https://td-cloud-test.terminaldeck.workers.dev:8443/v1",
                     "https://td-cloud-test.terminaldeck.workers.dev/v2", "https://td-cloud-test.terminaldeck.workers.dev/v1?x=1",
                     "https://user@td-cloud-test.terminaldeck.workers.dev/v1", "https://td-cloud-test.terminaldeck.workers.dev"] {
            check(permit(data, base: base) == nil)
        }
        // Never production's issuer in any spelling, nor anything on production's own domain.
        for issuer in [CloudWire.issuer, CloudWire.issuer + "/", CloudWire.issuer.uppercased(), "", "https://terminaldeck.dev/auth/v1",
                       "https://auth.terminaldeck.dev/v9", "https://API.TerminalDeck.dev./other"] {
            check(permit(data, issuer: issuer) == nil)
        }
    }
    /// With a permit, exactly that one issuer runs saved passwords; any other non-production issuer is still refused.
    func testAnAdoptedPermitAdmitsItsOwnIssuerAndNoOther() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let granted = try XCTUnwrap(permit(folder.appendingPathComponent("p3-a/data")))
        let server = CloudSecretsFixtureServer()
        let scratch = try await client(issuer: Self.testIssuer, server: server)
        await scratch.coordinator.adopt(scratch: granted)
        try await scratch.coordinator.setup()
        let saves = await scratch.local.saves
        check(saves == 1)
        check(try await scratch.coordinator.status().recoveryReady)
        // Another identity, another issuer, the same permit: refused, nothing sent for it.
        let otherServer = CloudSecretsFixtureServer()
        let other = try await client(issuer: "https://issuer.example.invalid/auth/v1", server: otherServer)
        await other.coordinator.adopt(scratch: granted)
        let otherCoordinator = other.coordinator
        check(await refused { _ = try await otherCoordinator.status() })
        check(await refused { try await otherCoordinator.setup() })
        let sent = await otherServer.bodies.count
        check(sent == 0)
        // The first permit stays: a later one for another issuer changes nothing.
        let second = try XCTUnwrap(permit(folder.appendingPathComponent("p3-b/data"), issuer: "https://issuer.example.invalid/auth/v1"))
        await scratch.coordinator.adopt(scratch: second)
        check(try await scratch.coordinator.status().recoveryReady)
        await other.coordinator.adopt(scratch: second)
        check(await refused { _ = try await otherCoordinator.status() })
    }
    #endif
}
