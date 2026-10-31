#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendHOSTAppAccountSignInTests: XCTestCase, @unchecked Sendable {
    struct Fixture: Sendable {
        let configuration: BackendAccountConfiguration, owner: Accounts18OldOwner, signer: BackendHOSTAppAccountSignIn
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "accounts18-test")
        func call(_ channel: String, _ args: [NativeRPCValue]) async throws -> NativeRPCValue {
            try await BackendHOSTProfileScope.withContext(context) {
                try await signer.invoke(channel, args: args, context: context, olderHost: true) ?? .null
            }
        }
    }
    func fixture(login: String = "printf 'https://claude.ai/oauth/authorize?test=accounts18\\n'; read answer", installed: Bool = true, signedIn: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("td-accounts18-" + UUID().uuidString)
        let home = root.appendingPathComponent("home"), data = root.appendingPathComponent("data"), bin = root.appendingPathComponent("bin")
        for directory in [home, data, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let state = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .exclusive)
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Accounts18 fixture", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/usr/bin/true"), inheritedEnvironment: ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin"])
        if installed {
            let status = signedIn ? #"{"loggedIn":true,"email":"same@accounts18.invalid"}"# : #"{"loggedIn":false}"#
            let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo '2.1.296 (Claude Code)'; exit 0; fi\nif [ \"$1 $2\" = 'auth status' ]; then printf '\(status)\\n'; exit 0; fi\nif [ \"$1 $2\" = 'auth login' ]; then \(login); exit 0; fi\nexit 1\n"
            let cli = bin.appendingPathComponent("claude"); try Data(script.utf8).write(to: cli); XCTAssertEqual(chmod(cli.path, 0o700), 0)
        }
        let providers = try BackendNativeProviders(store: state, dataRoot: data, inheritedEnvironment: configuration.inheritedEnvironment, home: home.path, runner: BackendCommandRunner(), loginPath: { bin.path })
        let owner = Accounts18OldOwner(configuration: configuration)
        let signer = BackendHOSTAppAccountSignIn(configuration: configuration, frontend: owner, providers: providers, sessionsUsing: { _ in [] }, authorizeMetadata: { _ in }, authorizeMutation: { _ in })
        addTeardownBlock { await state.close(); try? FileManager.default.removeItem(at: root) }
        return .init(configuration: configuration, owner: owner, signer: signer)
    }
    func testMissingBinaryDoesNotCreateAccountOrFolder() async throws {
        let f = try await fixture(installed: false)
        do { _ = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("Missing"))])]); XCTFail("Missing AI must refuse.") } catch {}
        let creates = await f.owner.creates; XCTAssertEqual(creates, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackendAccountSignInStorage.root(f.configuration).path))
    }
    func testOldHelperGetsAgentKeptAccountAndCancelRemovesEntryAndOnlyItsFolder() async throws {
        let f = try await fixture()
        let history = f.configuration.profilesRoot.appendingPathComponent("existing/history.jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: history)
        let added = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("Other"))])])
        let flow = try XCTUnwrap(added["flow"].string), id = try XCTUnwrap(added["profileId"].string)
        let foundProfile = try await f.owner.find(id, context: f.context)
        let profile = try XCTUnwrap(foundProfile); XCTAssertFalse(profile.promised)
        XCTAssertTrue(BackendAccountSignInStorage.ownsFolder(profile, configuration: f.configuration))
        var state = added
        for _ in 0..<100 where state["url"].string == nil { try await Task.sleep(for: .milliseconds(20)); state = try await f.call("profiles:signin-state", [.string(flow)]) }
        XCTAssertEqual(state["state"].string, "waiting"); XCTAssertNotNil(state["url"].string)
        XCTAssertEqual(added["loginStore"].string, "agent")
        _ = try await f.call("profiles:signin-cancel", [.string(flow)])
        let found = try await f.owner.find(id, context: f.context); XCTAssertNil(found)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.configDir))
        XCTAssertEqual(try Data(contentsOf: history), Data("preserved".utf8))
    }
    func testProcessExitZeroDoesNotInventSignedIn() async throws {
        let f = try await fixture(login: "exit 0")
        let added: NativeRPCValue
        do { added = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("No login"))])]) }
        catch { let profiles = await f.owner.profiles; XCTAssertTrue(profiles.isEmpty); return }
        XCTAssertNotEqual(added["state"].string, "done")
        let flow = try XCTUnwrap(added["flow"].string), id = try XCTUnwrap(added["profileId"].string)
        var state = added
        for _ in 0..<100 where state["state"].string == "waiting" { try await Task.sleep(for: .milliseconds(20)); state = try await f.call("profiles:signin-state", [.string(flow)]) }
        XCTAssertEqual(state["state"].string, "failed")
        let found = try await f.owner.find(id, context: f.context); XCTAssertNil(found)
    }
    func testOlderHostCannotStartMacsOwnLogin() async throws {
        let f = try await fixture()
        do { _ = try await f.call("profiles:signin-start", [.string("system")]); XCTFail("Mac install must remain untouched.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Add account")) }
        let creates = await f.owner.creates; XCTAssertEqual(creates, 0)
    }
    func testFallbackEnvironmentUsesOnlyTheAccountsLoginStore() throws {
        let removed = ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                       "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_ACCESS_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY"]
        var inherited = Dictionary(uniqueKeysWithValues: removed.map { ($0, "fixture-override") })
        inherited["CLAUDE_CONFIG_DIR"] = "/another/claude"; inherited["CODEX_HOME"] = "/another/codex"; inherited["HOME"] = "/fixture/home"
        let configuration = try BackendAccountConfiguration(dataDirectory: URL(fileURLWithPath: "/fixture/data"), homeDirectory: URL(fileURLWithPath: "/fixture/home"), appName: "Accounts18 environment fixture", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/usr/bin/true"), inheritedEnvironment: inherited)
        for provider in ["claude", "codex"] {
            let profile = BackendAccountProfile(id: "account", name: "Account", provider: provider, configDir: "/fixture/data/account-logins/account", system: false, color: "--accent", createdAt: 0)
            let environment = BackendAccountSignInStorage.environment(profile, configuration: configuration, path: "/fixture/bin")
            for key in removed { XCTAssertNil(environment[key], key) }
            XCTAssertEqual(environment[BackendAccountProfile.configEnvironment(provider)!], profile.configDir)
            XCTAssertEqual(environment["PATH"], "/fixture/bin"); XCTAssertEqual(environment["HOME"], "/fixture/home")
        }
    }
    func testShutdownDrainsPendingCommandsRemovesNewAccountAndPreservesSavedAccount() async throws {
        let f = try await fixture(login: "echo $$ > \"$CLAUDE_CONFIG_DIR/sign-in.pid\"; printf 'https://claude.ai/oauth/authorize?test=accounts18\\n'; read answer")
        let added = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("Pending"))])])
        let id = try XCTUnwrap(added["profileId"].string), pending = try await f.owner.find(id, context: f.context)
        let pendingProfile = try XCTUnwrap(pending)
        let savedFolder = BackendAccountSignInStorage.root(f.configuration).appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: savedFolder, withIntermediateDirectories: true)
        let history = savedFolder.appendingPathComponent("history.jsonl"); try Data("saved history".utf8).write(to: history)
        let saved = BackendAccountProfile(id: "saved", name: "Saved", provider: "claude", configDir: savedFolder.path, system: false, color: "--accent", createdAt: 0)
        await f.owner.put(saved)
        _ = try await f.call("profiles:signin-start", [.string(saved.id)])
        let pidFiles = [URL(fileURLWithPath: pendingProfile.configDir).appendingPathComponent("sign-in.pid"), savedFolder.appendingPathComponent("sign-in.pid")]
        for _ in 0..<100 where !pidFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { try await Task.sleep(for: .milliseconds(20)) }
        let pids = try pidFiles.map { file in try XCTUnwrap(Int32(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))) }
        try await f.signer.shutdown(context: f.context)
        let afterPending = try await f.owner.find(id, context: f.context), afterSaved = try await f.owner.find(saved.id, context: f.context)
        XCTAssertNil(afterPending); XCTAssertNotNil(afterSaved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingProfile.configDir)); XCTAssertEqual(try Data(contentsOf: history), Data("saved history".utf8))
        for pid in pids { let status = Darwin.kill(pid, 0), code = errno; XCTAssertEqual(status, -1); XCTAssertEqual(code, ESRCH) }
    }
    func testCompletedSignInNoLongerBlocksQuitAndItsReceiptStaysDone() async throws {
        let f = try await fixture(signedIn: true)
        let added = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("Finished"))])])
        let flow = try XCTUnwrap(added["flow"].string), id = try XCTUnwrap(added["profileId"].string)
        _ = try await f.call("profiles:signin-code", [.string(flow), .string("fixture-answer")])
        var answer = added
        for _ in 0..<100 where ["waiting", "needs-code"].contains(answer["state"].string ?? "") { try await Task.sleep(for: .milliseconds(20)); answer = try await f.call("profiles:signin-state", [.string(flow)]) }
        XCTAssertEqual(answer["state"].string, "done")
        let pending = await f.signer.pendingShutdownCount(); XCTAssertEqual(pending, 0)
        // Once a terminal result was observed, Quit must not consult its receipt
        // or profile again, even when those old reads are no longer available.
        await f.owner.revokeReads()
        try await f.signer.shutdown(context: f.context)
        try await f.signer.shutdown(context: f.context)
        let receipt = try await f.call("profiles:signin-state", [.string(flow)])
        XCTAssertEqual(receipt["state"].string, "done")
        let profiles = await f.owner.profiles; XCTAssertTrue(profiles.contains { $0.id == id })
    }
    func testExitZeroWaitsForStatusConfirmationEvenAfterAnotherCallerTakesSettlement() async throws {
        let flow = BackendAccountSignInFlow(profileID: "fixture", provider: "claude")
        try flow.start(runnable: "/usr/bin/true", arguments: [], environment: [:], cwd: FileManager.default.temporaryDirectory.path)
        for _ in 0..<100 where flow.wire["message"].string != "Checking the account’s login…" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(flow.wire["state"].string, "waiting")
        XCTAssertTrue(flow.takeSettled()); XCTAssertFalse(flow.takeSettled())
        XCTAssertEqual(flow.wire["state"].string, "waiting")
        flow.confirmSuccess()
        XCTAssertEqual(flow.wire["state"].string, "done")
    }
    func testCompletedSignInRejectsSameSystemEmailAndDiscardsNewFolder() async throws {
        let f = try await fixture(signedIn: true)
        await f.owner.setReport("system", report: .object([.init("state", .string("signed-in")), .init("account", .string("same@accounts18.invalid"))]))
        try await completedCollision(f, expectedName: "Default")
    }
    func testCompletedSignInRejectsUnavailableKeptNamedCopy() async throws {
        let f = try await fixture(signedIn: true)
        let kept = BackendAccountProfile(id: "kept", name: "same@accounts18.invalid", provider: "claude", configDir: f.configuration.profilesRoot.appendingPathComponent("kept").path, system: false, color: "--accent", createdAt: 0, loginStore: "app")
        await f.owner.put(kept)
        await f.owner.setReport("kept", report: .object([.init("state", .string("unknown"))]))
        try await completedCollision(f, expectedName: "same@accounts18.invalid")
        let stillKept = try await f.owner.find("kept", context: f.context); XCTAssertNotNil(stillKept)
    }
    // 18 Oct (#414): a finished sign-in checks only the new account afresh; the others answer from their saved reports.
    func testCompletedSignInDoesNotRecheckEveryOtherAccount() async throws {
        let f = try await fixture(signedIn: true)
        for name in ["one", "two", "three"] {
            await f.owner.put(BackendAccountProfile(id: name, name: name, provider: "claude", configDir: f.configuration.profilesRoot.appendingPathComponent(name).path,
                                                    system: false, color: "--accent", createdAt: 0))
        }
        let added = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("Fresh"))])])
        let flow = try XCTUnwrap(added["flow"].string)
        _ = try await f.call("profiles:signin-code", [.string(flow), .string("fixture-answer")])
        var answer = added
        for _ in 0..<100 where ["waiting", "needs-code"].contains(answer["state"].string ?? "") { try await Task.sleep(for: .milliseconds(20)); answer = try await f.call("profiles:signin-state", [.string(flow)]) }
        XCTAssertEqual(answer["state"].string, "done")
        let reads = await f.owner.reads, refreshed = await f.owner.refreshedReads
        XCTAssertEqual(reads, 4)   // this Mac's own login and the three saved accounts
        XCTAssertEqual(refreshed, 0)
    }
    // 18 Oct (#513): a sign-in answers the sheet when it changes, not when asked once a second.
    func testSignInAnswersWhenItChanges() async throws {
        let flow = BackendAccountSignInFlow(profileID: "fixture", provider: "claude")
        try flow.start(runnable: "/bin/sh", arguments: ["-c", "sleep 0.5; printf 'Paste the code here\\n'; read answer"],
                       environment: ["PATH": "/usr/bin:/bin"], cwd: FileManager.default.temporaryDirectory.path)
        defer { flow.cancel() }
        let before = try XCTUnwrap(flow.wire["revision"].number), asked = ContinuousClock.now
        await flow.waitForChange(after: Int(before), seconds: 10)
        XCTAssertLessThan(ContinuousClock.now - asked, .seconds(5))
        XCTAssertEqual(flow.wire["state"].string, "needs-code")
        let quiet = try XCTUnwrap(flow.wire["revision"].number), waited = ContinuousClock.now
        await flow.waitForChange(after: Int(quiet), seconds: 0.3)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - waited, .milliseconds(250))
        await flow.waitForChange(after: Int(before), seconds: 10)   // already changed: answered at once
        XCTAssertLessThan(ContinuousClock.now - waited, .seconds(5))
    }
    private func completedCollision(_ f: Fixture, expectedName: String) async throws {
        let added = try await f.call("profiles:add-signin", [.object([.init("provider", .string("claude")), .init("name", .string("New copy"))])])
        let flow = try XCTUnwrap(added["flow"].string), id = try XCTUnwrap(added["profileId"].string)
        let before = try await f.owner.find(id, context: f.context), profile = try XCTUnwrap(before)
        _ = try await f.call("profiles:signin-code", [.string(flow), .string("fixture-answer")])
        var answer = added
        for _ in 0..<100 where ["waiting", "needs-code"].contains(answer["state"].string ?? "") { try await Task.sleep(for: .milliseconds(20)); answer = try await f.call("profiles:signin-state", [.string(flow)]) }
        XCTAssertEqual(answer["state"].string, "failed"); XCTAssertEqual(answer["message"].string, "That is the same account as " + expectedName)
        let again = try await f.call("profiles:signin-state", [.string(flow)])
        XCTAssertEqual(again["state"].string, "failed"); XCTAssertEqual(again["message"].string, "That is the same account as " + expectedName)
        let after = try await f.owner.find(id, context: f.context); XCTAssertNil(after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.configDir))
    }
}

actor Accounts18OldOwner: BackendHOSTAppAccountFrontend {
    let configuration: BackendAccountConfiguration
    var profiles: [BackendAccountProfile] = []
    var creates = 0
    var reports: [String: NativeRPCValue] = [:]
    var reads = 0, refreshedReads = 0
    private var readsRevoked = false
    init(configuration: BackendAccountConfiguration) { self.configuration = configuration }
    func find(_ id: String, context: NativeRPCContext) async throws -> BackendAccountProfile? {
        guard !readsRevoked else { throw BackendAccountFailure("Fixture read is no longer available.") }
        if id == "system" { return .init(id: id, name: "Default", provider: "claude", configDir: configuration.homeDirectory.appendingPathComponent(".claude").path, system: true, color: "--accent", createdAt: 0) }
        return profiles.first { $0.id == id }
    }
    func list(provider: String?, context: NativeRPCContext) async throws -> [BackendAccountProfile] { [try await find("system", context: context)!] + profiles.filter { provider == nil || $0.provider == provider } }
    func put(_ profile: BackendAccountProfile) { profiles.append(profile) }
    func setReport(_ id: String, report: NativeRPCValue) { reports[id] = report }
    func revokeReads() { readsRevoked = true }
    func snapshot(context: NativeRPCContext) async throws -> BackendAccountProfilesSnapshot { .init(profiles: profiles, defaultProfileID: nil, projectDefaults: [:], systemNames: [:]) }
    func resolve(sessionProfileID: String?, projectPath: String?, provider: String?, context: NativeRPCContext) async throws -> BackendAccountProfile { try await find(sessionProfileID ?? "system", context: context)! }
    func managed(_ id: String, context: NativeRPCContext) async throws -> Bool { false }
    func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        if channel == "profiles:create" {
            creates += 1
            let name = args[0].string ?? "", options = args[1]
            let profile = BackendAccountProfile(id: BackendAccountProfile.slugifyProfileID(name), name: name, provider: options["provider"].string ?? "claude", configDir: options["configDir"].string ?? "", system: false, color: "--accent", createdAt: 0)
            profiles.append(profile); return try NativeRPCValue.parseJSON(JSONEncoder().encode(profile))
        }
        if channel == "profiles:delete" { profiles.removeAll { $0.id == args[0].string }; return .object([.init("removed", .bool(true))]) }
        if channel == "profiles:signin" {
            reads += 1; if args.count > 1, args[1]["refresh"].bool == true { refreshedReads += 1 }
            return reports[args[0].string ?? ""] ?? .object([.init("state", .string("unknown"))])
        }
        throw BackendAccountFailure("Older fixture does not know \(channel).")
    }
}
#endif
