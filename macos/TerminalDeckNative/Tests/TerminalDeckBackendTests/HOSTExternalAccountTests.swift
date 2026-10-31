#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTExternalAccountTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_WIP"]?.contains("HOST") == true, "WIP HOST")
    }
    private func fixture() async throws -> (URL, BackendHOSTAccountService, BackendPTYManager) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-external-" + UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true), home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [data, home] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "HOST External Scratch", appID: "terminaldeck",
            helperExecutable: root.appendingPathComponent("unused-helper"), inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "USER": "scratch"])
        let service = try await BackendHOSTAccountService.start(configuration: configuration, nativeAccountOwnerDisabled: true,
            vaultCipher: HOSTExternalFixtureCipher(), brokerFactory: { configuration, profiles, vault in
                try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault, runner: { _, _ in .init(code: 44, stdout: "", stderr: "") })
            })
        addTeardownBlock { try? await service.stop(afterProcessDrain: true) }
        return (root, service, BackendPTYManager(inheritedEnvironment: configuration.inheritedEnvironment, onEvent: { _ in }))
    }
    private func child() throws -> Process {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        addTeardownBlock { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        return child
    }
    private func payload(_ owner: BackendHOSTAccountService, root: URL, deferred: Bool, child: Process, chat: Bool = false) async throws -> Data {
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); if deferred { input.origin = .copilot }
        input.chat = chat
        let account: BackendHOSTAccountWire
        if chat {
            let request = NativeRPCValue.object([.init("input", try NativeRPCValue.parseJSON(JSONEncoder().encode(input))),
                .init("scope", try NativeRPCValue.parseJSON(JSONEncoder().encode(BackendHOSTProtocol.Scope(.init(rememberTab: false, isAppComposed: deferred))))),
                .init("provider", .object([.init("id", .string("claude")), .init("command", .string("/bin/sleep")),
                    .init("args", .array([.string("60")])), .init("resumeArgs", .array([]))])), .init("path", .string("/usr/bin:/bin"))])
            account = try JSONDecoder().decode(BackendHOSTAccountWire.self, from: await owner.invoke("account.chat.resolve", payload: request.encodedJSON(), manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })))
        } else {
            account = try await owner.resolve(input: input, provider: .init(id: "claude", command: "/bin/sleep", args: ["60"], resumeArgs: []),
                loginPath: "/usr/bin:/bin", scope: .init(.init(rememberTab: false, isAppComposed: deferred)))
        }
        let meta = BackendSessionMeta(id: UUID().uuidString, input: input, spawn: .init(provider: "claude", command: "/bin/sleep", args: ["60"],
            path: account.path, env: account.environment, removeEnv: Set(account.removeEnvironment), profile: account.launch.profile, homeProfileId: account.homeProfileID))
        return try NativeRPCValue.object([.init("handle", .string(account.handle)), .init("session", NativeRPCValue.parseJSON(JSONEncoder().encode(meta))),
            .init("pid", .number(Double(child.processIdentifier)))]).encodedJSON()
    }
    func testDeferredOriginalAppChildBindsWithoutJoiningHelperPtyAndRetainsResourcesUntilExit() async throws {
        let (root, owner, manager) = try await fixture(), process = try child()
        let data = try await payload(owner, root: root, deferred: true, child: process)
        _ = try await owner.invoke("account.external.bind", payload: data, manager: manager, appPID: getpid())
        XCTAssertTrue(manager.list().isEmpty)
        let live = await owner.counts(); XCTAssertEqual(live.live, 1)
        do { try await owner.stop(afterProcessDrain: true); XCTFail("The app's live child must retain its original account resource.") } catch {}
        XCTAssertTrue(process.isRunning)
        process.terminate(); process.waitUntilExit()
        let drained = try await owner.externalSessionsDrained(); XCTAssertTrue(drained)
        let ended = await owner.counts(); XCTAssertEqual(ended.live, 0)
        try await owner.stop(afterProcessDrain: true)
    }
    func testVerify20UserChatBindsOnlyItsActualAppChildAndDrains() async throws {
        let (root, owner, manager) = try await fixture(), process = try child()
        let data = try await payload(owner, root: root, deferred: false, child: process, chat: true)
        do { _ = try await owner.invoke("account.external.bind", payload: data, manager: manager, appPID: process.processIdentifier); XCTFail("A chat still requires its actual app parent.") } catch {}
        _ = try await owner.invoke("account.external.bind", payload: data, manager: manager, appPID: getpid())
        XCTAssertTrue(manager.list().isEmpty)
        let live = await owner.counts(); XCTAssertEqual(live.live, 1)
        process.terminate(); process.waitUntilExit()
        let drained = try await owner.externalSessionsDrained(); XCTAssertTrue(drained)
        let ended = await owner.counts(); XCTAssertEqual(ended.live, 0)
    }
    func testChatResolutionOperationRejectsATerminalBeforeReservingAnyAccount() async throws {
        let (_, owner, manager) = try await fixture()
        let input = BackendCreateSessionInput(cwd: "/tmp", provider: "claude")
        let request = try NativeRPCValue.object([.init("input", NativeRPCValue.parseJSON(JSONEncoder().encode(input)))]).encodedJSON()
        do {
            _ = try await owner.invoke("account.chat.resolve", payload: request, manager: manager)
            XCTFail("A terminal cannot claim the Chat reservation operation.")
        } catch { XCTAssertEqual(error.localizedDescription, BackendHOSTFailure.authentication.localizedDescription) }
        let counts = await owner.counts(); XCTAssertEqual(counts.pending, 0); XCTAssertEqual(counts.live, 0)
    }
    func testOrdinaryReservationOrAnotherParentCannotBeBoundAsDeferredAppChild() async throws {
        let (root, owner, manager) = try await fixture(), process = try child()
        let ordinary = try await payload(owner, root: root, deferred: false, child: process)
        do { _ = try await owner.invoke("account.external.bind", payload: ordinary, manager: manager, appPID: getpid()); XCTFail("An ordinary hosted reservation cannot be relabeled as app-owned.") } catch {}
        let deferred = try await payload(owner, root: root, deferred: true, child: process)
        do { _ = try await owner.invoke("account.external.bind", payload: deferred, manager: manager, appPID: process.processIdentifier); XCTFail("The supplied parent must be the actual authenticated app ancestor.") } catch {}
        XCTAssertTrue(process.isRunning); let counts = await owner.counts(); XCTAssertEqual(counts.live, 0)
        process.terminate(); process.waitUntilExit(); try await owner.stop(afterProcessDrain: true)
    }
}
private struct HOSTExternalFixtureCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ data: Data) throws -> String { String(decoding: data, as: UTF8.self) }
}
#endif
