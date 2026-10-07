import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/account-vault/vault-profiles.test.ts against the real native account runtime
/// (BackendF4Runtime: profile store, vault with the fake cipher, offline broker with a fake
/// `security`, Codex lease, launch adapter, RPC, sign-in service). Temporary folders only.
final class BackendFoundationTestsF4VaultProfiles: XCTestCase, @unchecked Sendable {
    private typealias Kept = BackendSessionSwitchKeptLogin
    private let slot = "keychain:Claude Code-credentials"
    private let secret = "VERY-SECRET-TOKEN-VALUE"

    private func withRuntime(_ body: (BackendF4Runtime) async throws -> Void) async throws {
        let r = try await BackendF4Runtime.wire()
        do { try await body(r) } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }
    private func stdout(_ answer: BackendAccountVaultServer.WireAnswer) -> String? {
        if case .exit(let result) = answer, result.code == 0 { return result.stdout }
        return nil
    }
    private func code(_ answer: BackendAccountVaultServer.WireAnswer) -> Int32? {
        if case .exit(let result) = answer { return result.code }
        return nil
    }
    private func readJSON(_ file: URL) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: file)) }

    // vault-profiles.test.ts:110
    func testANewAccountIsKeptByTheAppFromItsFirstMoment() async throws { try await withRuntime { r in
        let work = try await r.create("work@example.com")
        XCTAssertEqual(work.loginStore, "app")
        let kept = try await r.keptBy(work.id); XCTAssertEqual(kept, "app")
        // Persisted, so a restart does not quietly read the keychain for it.
        let disk = try readJSON(r.configuration.dataDirectory.appendingPathComponent("profiles.json"))
        XCTAssertEqual(disk["profiles"].elements?.first { $0["id"].string == work.id }?["loginStore"].string, "app")
    } }

    // vault-profiles.test.ts:120. Without a vault (the profile store alone, as before the vault):
    // no loginStore field, the agent keeps the login, and a session gets only its directory.
    func testWithoutAVaultNothingChangesNoFieldNoTicketTheAgentKeepsTheLogin() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let work = try await f.create("work@example.com")
        XCTAssertNil(work.loginStore)
        let managed = await f.profiles.managed(work)
        XCTAssertEqual(Kept.keptBy(work, managed: managed, usable: false), .agent)
        XCTAssertEqual(BackendAccountStrategies.accountEnv(provider: "claude", account: (work.provider, work.configDir)), ["CLAUDE_CONFIG_DIR": work.configDir])
    } }

    // vault-profiles.test.ts:127
    func testASessionOnAKeptAccountGetsTheVaultAndItsOwnTicketTheMachinesOwnInstallNeverDoes() async throws { try await withRuntime { r in
        let one = try await r.create("one@example.com"), two = try await r.create("two@example.com")
        let a = try await r.sessionEnv(one), b = try await r.sessionEnv(two)
        let socket = await r.broker.socketPath, shim = await r.broker.shimDirectory
        XCTAssertEqual(a.environment[r.socketKey], socket)
        let ticket = try XCTUnwrap(a.environment[r.ticketKey])
        XCTAssertNotNil(ticket.range(of: "^[0-9a-f]{48}$", options: .regularExpression))
        XCTAssertNotEqual(ticket, b.environment[r.ticketKey])
        let system = try await XCTUnwrapAsync(try await r.profiles.find("system"))
        let own = try await r.sessionEnv(system)
        XCTAssertEqual(own.environment, [:])
        // The wrong agent gets neither the directory nor the ticket.
        let started = Date()
        if let wrong = try? await r.sessionEnv(one, "codex") {
            XCTAssertNil(wrong.environment[r.ticketKey]); XCTAssertNil(wrong.environment[r.socketKey])
            XCTAssertFalse(wrong.environment.values.contains(one.configDir), "\(wrong.environment)")
        }
        print("F4-timing wrong-agent resolve", Date().timeIntervalSince(started))
        // And the shim goes first on that session's PATH, and on no other.
        XCTAssertEqual(a.path.split(separator: ":").first.map(String.init), shim)
        XCTAssertEqual(own.path, "/usr/bin:/bin")
    } }

    // vault-profiles.test.ts:145
    func testTwoSessionsOnTwoAccountsReadTwoLoginsAndSwitchingOneLeavesTheOtherAlone() async throws { try await withRuntime { r in
        let one = try await r.create("one@example.com"), two = try await r.create("two@example.com")
        await r.put(one.id, BackendF4ClaudeLogin("ONE")); await r.put(two.id, BackendF4ClaudeLogin("TWO"))
        let sessionA = try await r.sessionEnv(one).environment[r.ticketKey] ?? ""
        let sessionB = try await r.sessionEnv(two).environment[r.ticketKey] ?? ""
        let answerA = await r.find(sessionA, configDir: one.configDir), answerB = await r.find(sessionB, configDir: two.configDir)
        XCTAssertEqual(stdout(answerA), BackendF4ClaudeLogin("ONE"))
        XCTAssertEqual(stdout(answerB), BackendF4ClaudeLogin("TWO"))
        // Session A is switched to `two`: it is restarted with `two`'s environment.
        let switched = try await r.sessionEnv(two).environment[r.ticketKey] ?? ""
        let answerSwitched = await r.find(switched, configDir: two.configDir)
        XCTAssertEqual(stdout(answerSwitched), BackendF4ClaudeLogin("TWO"))
        // B never noticed, and `one` is still signed in for anybody on it.
        let answerAgain = await r.find(sessionB, configDir: two.configDir)
        XCTAssertEqual(stdout(answerAgain), BackendF4ClaudeLogin("TWO"))
        let has = await r.vault.has(one.id); XCTAssertTrue(has)
    } }

    // vault-profiles.test.ts:165
    func testAnAccountMadeBeforeTheVaultMovesAcrossInsteadOfSigningOut() async throws {
        let root = try BackendF4Runtime.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Made while no vault existed — the shape every account on disk today has.
        let configuration = try BackendF4Runtime.configuration(root)
        let state = try NativeStateStore(file: configuration.dataDirectory.appendingPathComponent("state.json"), ownership: .exclusive, clock: { 1_000 })
        let store = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
        let old = try await store.create(name: "old@example.com", vaultManaged: false)
        XCTAssertNil(old.loginStore)
        await store.close(); await state.close()
        let r = try await BackendF4Runtime.wire(root: root)
        do {
            let kept = try await r.keptBy(old.id); XCTAssertEqual(kept, "adopting")
            let env = try await r.sessionEnv(old); XCTAssertNotNil(env.environment[r.ticketKey])
            // The vault cannot say yet whether it is signed in — its login is still where the agent
            // put it — so the sign-in check asks the agent, as before.
            let signed = try await r.signedIn(old.id); XCTAssertEqual(signed, .null)
            let executor = BackendF4Executor()
            _ = await (try r.signIn(executor: executor)).read(old)
            XCTAssertEqual(executor.runs.value.count, 1, "an adopting account is asked of the agent, not answered from the vault")
        } catch { await r.dispose(); throw error }
        await r.dispose()
    }

    // vault-profiles.test.ts:178
    func testDeletingAnAccountDeletesItsKeptLoginAndStopsAnsweringForIt() async throws { try await withRuntime { r in
        let gone = try await r.create("gone@example.com")
        await r.put(gone.id, BackendF4ClaudeLogin(secret))
        let ticket = try await r.sessionEnv(gone).environment[r.ticketKey] ?? ""
        let result = try await r.adapter.deleteProfile(id: gone.id, deleteFiles: true)
        XCTAssertFalse(result.credentialsRetained)
        let has = await r.vault.has(gone.id); XCTAssertFalse(has)
        let vaultFile = await r.vault.file
        XCTAssertFalse(try String(contentsOf: vaultFile, encoding: .utf8).contains(secret))
        let answer = await r.find(ticket, configDir: gone.configDir)
        XCTAssertEqual(code(answer), 44)
    } }

    // vault-profiles.test.ts:190
    func testAnAccountRemadeUnderADeletedOnesNameStartsSignedOutNotAsTheOldLogin() async throws { try await withRuntime { r in
        let first = try await r.create("same@example.com")
        await r.put(first.id, BackendF4ClaudeLogin("OLD"))
        _ = try await r.adapter.deleteProfile(id: first.id, deleteFiles: true)
        let again = try await r.create("same@example.com")
        XCTAssertEqual(again.id, first.id); XCTAssertEqual(again.loginStore, "app")
        let signed = try await r.signedIn(again.id); XCTAssertEqual(signed, .bool(false))
    } }

    // vault-profiles.test.ts:201
    func testACodexAccountIsFollowedFromTheMomentItIsMadeAndItsFileGoesAtQuit() async throws { try await withRuntime { r in
        let codex = try await r.create("codex@example.com", provider: "codex")
        let kept = try await r.keptBy(codex.id); XCTAssertEqual(kept, "app")
        let following = await r.codex.following(); XCTAssertTrue(following.contains(codex.id))
        let file = URL(fileURLWithPath: codex.configDir).appendingPathComponent("auth.json")
        try Data("{\"tokens\":{\"access_token\":\"at-X\"}}".utf8).write(to: file)
        _ = await r.codex.capture(codex)
        let has = await r.vault.has(codex.id); XCTAssertTrue(has)
        await r.dispose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // With the vault gone, sessions are exactly as before.
        XCTAssertEqual(BackendAccountStrategies.accountEnv(provider: "codex", account: (codex.provider, codex.configDir)), ["CODEX_HOME": codex.configDir])
    } }

    // vault-profiles.test.ts:217
    func testAnswersSignedInAsWhomForAKeptLoginWithoutRunningAnything() async throws { try await withRuntime { r in
        let work = try await r.create("typed-name")
        let executor = BackendF4Executor(), service = try r.signIn(executor: executor)
        let before = await service.read(work)
        XCTAssertEqual(before.state, "signed-out"); XCTAssertEqual(before.command, "")
        await r.put(work.id, BackendF4ClaudeLogin("A", plan: "max"))
        try FileManager.default.createDirectory(atPath: work.configDir, withIntermediateDirectories: true)
        try Data("{\"oauthAccount\":{\"emailAddress\":\"real@example.com\",\"organizationName\":\"Org\"}}".utf8)
            .write(to: URL(fileURLWithPath: work.configDir).appendingPathComponent(".claude.json"))
        let after = await service.read(work)
        XCTAssertEqual(after.state, "signed-in"); XCTAssertEqual(after.account, "real@example.com"); XCTAssertEqual(after.plan, "max")
        XCTAssertEqual(after.detail, "Signed in as real@example.com · max")
        XCTAssertEqual(executor.runs.value.count, 0)
    } }

    // vault-profiles.test.ts:235
    func testRefusesToSwitchASessionToAKeptAccountThatHasNoLoginBeforeAnythingIsStopped() async throws { try await withRuntime { r in
        let empty = try await r.create("empty@example.com")
        let meta = S5SwitchFixture.meta(profileId: "system", profileName: "Default"), saved = try S5SwitchFixture.saved()
        let signedOut = try await r.signedIn(empty.id).bool
        let refusal = BackendSessionSwitchCoordinator.refusal(meta: meta, saved: saved, target: empty, targetSignedIn: signedOut)
        XCTAssertTrue(refusal?.contains("is not signed in yet") == true, refusal ?? "nil")
        // Signed in, it goes ahead.
        await r.put(empty.id, BackendF4ClaudeLogin("A"))
        let signedIn = try await r.signedIn(empty.id).bool
        XCTAssertNil(BackendSessionSwitchCoordinator.refusal(meta: meta, saved: saved, target: empty, targetSignedIn: signedIn))
    } }

    // vault-profiles.test.ts:247
    func testNothingTheWindowCanAskForEverCarriesAKeptLogin() async throws { try await withRuntime { r in
        let work = try await r.create("work@example.com"), codex = try await r.create("codex@example.com", provider: "codex")
        await r.put(work.id, BackendF4ClaudeLogin(secret))
        await r.put(codex.id, "{\"tokens\":{\"access_token\":\"\(secret)\"}}", provider: "codex", slot: "file:auth.json")
        let c = BackendF4Runtime.context, service = try r.signIn(executor: BackendF4Executor())
        let answers: [NativeRPCValue] = [
            try await r.rpc.invoke("profiles:list", args: [], context: c),
            try await r.rpc.invoke("profiles:list", args: [.string("codex")], context: c),
            try await r.rpc.invoke("profiles:status", args: [.string(work.id)], context: c),
            try await r.rpc.invoke("profiles:resolve", args: [.object([.init("sessionProfileId", .string(work.id))])], context: c),
            (await service.read(work)).wireValue,
        ]
        let text = NativeRPCValue.array(answers).compact
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("sk-ant")); XCTAssertFalse(text.contains(r.ticketKey))
        // The list says the login is kept, and that it is signed in.
        XCTAssertEqual(answers[0]["vault"][work.id]["keptBy"].string, "app"); XCTAssertEqual(answers[0]["vault"][work.id]["signedIn"], .bool(true))
        XCTAssertEqual(answers[0]["vault"]["system"]["keptBy"].string, "agent"); XCTAssertEqual(answers[0]["vault"]["system"]["signedIn"], .null)
    } }

    // vault-profiles.test.ts:279
    func testNeverTakesAwayTheLoginFileOfACodexAccountInAFolderThePersonChose() async throws { try await withRuntime { r in
        let chosen = r.root.appendingPathComponent("my-codex-home")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try Data("{\"tokens\":{\"access_token\":\"MINE\"}}".utf8).write(to: chosen.appendingPathComponent("auth.json"))
        let mine = try await r.create("mine@example.com", provider: "codex", configDir: chosen.path)
        let kept = try await r.keptBy(mine.id); XCTAssertEqual(kept, "agent")
        _ = try await r.adapter.deleteProfile(id: mine.id, deleteFiles: true)
        XCTAssertTrue(try String(contentsOf: chosen.appendingPathComponent("auth.json"), encoding: .utf8).contains("MINE"))
    } }

    // vault-profiles.test.ts:296. "Where no vault runs": the profile store alone in a process whose
    // vault cannot be opened. (The usage half is the next test.)
    func testAnAccountTheAppKeepsIsUnavailableWhereNoVaultRunsRefusedNeverAKeychainRead() async throws {
        let r = try await BackendF4Runtime.wire()
        let work: BackendAccountProfile
        do { work = try await r.create("work@example.com") } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let state = try NativeStateStore(file: r.configuration.dataDirectory.appendingPathComponent("state.json"), ownership: .exclusive, clock: { 1_000 })
        let store = try BackendAccountProfileStore(configuration: r.configuration, stateStore: state)
        do {
            let current = try await XCTUnwrapAsync(try await store.find(work.id))
            let kept = Kept.keptBy(current, managed: await store.managed(current), usable: false)
            XCTAssertEqual(kept, .unavailable)
            XCTAssertEqual(BackendAccountStrategies.accountEnv(provider: "claude", account: (current.provider, current.configDir)), ["CLAUDE_CONFIG_DIR": current.configDir])
            XCTAssertEqual(Kept.unavailable(kept), Kept.unavailableSentence)
            let executor = BackendF4Executor(answer: .init(stdout: "{\"loggedIn\":true}", exitCode: 0))
            let service = BackendAppAccountSignInService(dependencies: BackendF4NoVaultSignInDependencies(configuration: r.configuration, profiles: store),
                executor: executor, clock: BackendAppSessionSystemClock(), authorizeMetadata: { _ in }, authorizeMutation: { _ in })
            let report = await service.read(current)
            XCTAssertEqual(executor.runs.value.count, 0)
            XCTAssertEqual(report.state, "unknown"); XCTAssertEqual(report.detail, Kept.unavailableSentence); XCTAssertEqual(report.command, "")
            let meta = S5SwitchFixture.meta(profileId: "system", profileName: "Default")
            XCTAssertEqual(BackendSessionSwitchCoordinator.refusal(meta: meta, saved: try S5SwitchFixture.saved(), target: current,
                                                                   targetUnavailable: Kept.unavailable(kept)), Kept.unavailableSentence)
        } catch { await store.close(); await state.close(); throw error }
        await store.close(); await state.close()
    }

    /// The usage probe over this runtime, with `ask` recorded instead of run (TS probeUsage `ask`), and a
    /// stand-in login shell + `claude` in the temporary folder, so no real shell or agent is started.
    private func usageProbe(_ r: BackendF4Runtime, asked: BackendF4Box<[[String: String]]>) async throws -> BackendUsageProbe {
        let bin = r.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shell = r.root.appendingPathComponent("login-shell"), claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '\\000%s\\000' '\(bin.path):/usr/bin:/bin'\n".write(to: shell, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho '2.1.0 (Claude Code)'\n".write(to: claude, atomically: true, encoding: .utf8)
        for file in [shell, claude] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let providers = try BackendNativeProviders(store: r.state, dataRoot: r.configuration.dataDirectory, inheritedEnvironment: ["SHELL": shell.path],
                                                   home: r.configuration.homeDirectory.path, runner: BackendCommandRunner())
        return BackendUsageProbe(accounts: r.adapter, providers: providers, ask: { _, _, environment, _, _ in
            asked.update { $0.append(environment) }
            return (usage: nil, error: nil)
        })
    }

    // vault-profiles.test.ts:296, the usage half: natively "no vault runs" is the D11 shape — the saved
    // logins will not unlock in this process (another build's key), so the vault is off.
    func testAnAccountTheAppKeepsIsUnavailableWhereNoVaultRunsSoItsUsageIsNeverAsked() async throws { try await withRuntime { r in
        let work = try await r.create("work@example.com")
        let vault = await r.vault
        try FileManager.default.createDirectory(at: vault.directory, withIntermediateDirectories: true)
        try Data("a vault from another build of the app".utf8).base64EncodedString().write(to: vault.file, atomically: true, encoding: .utf8)
        await vault.reload()
        let state = await vault.openState(); XCTAssertEqual(state, .locked)
        let kept = try await r.keptBy(work.id); XCTAssertEqual(kept, "unavailable")
        let asked = BackendF4Box<[[String: String]]>([])
        let probe = try await usageProbe(r, asked: asked)
        let usage = await probe.run(account: BackendUsageAccount(provider: "claude", id: work.id, name: work.name, configDirectory: work.configDir))
        XCTAssertTrue(asked.value.isEmpty)
        XCTAssertEqual(usage.detail, Kept.unavailableSentence)
    } }

    // vault-profiles.test.ts:399, the usage half: a ticket and socket inherited from whatever launched the app never reach the probe.
    func testNeverHandsAUsageProbeATicketInheritedFromWhateverLaunchedTheApp() async throws {
        let root = try BackendF4Runtime.makeRoot()
        let inherited = ["USER": "me", "TERMINALDECK_ACCOUNT_TICKET": String(repeating: "f", count: 48), "TERMINALDECK_ACCOUNT_VAULT": "/somewhere/else.sock"]
        let r = try await BackendF4Runtime.wire(root: root, environment: inherited)
        do {
            let asked = BackendF4Box<[[String: String]]>([])
            let probe = try await usageProbe(r, asked: asked)
            let system = try await XCTUnwrapAsync(try await r.profiles.find("system"))
            _ = await probe.run(account: BackendUsageAccount(provider: "claude", id: "system", name: nil, configDirectory: system.configDir))
            let usageEnv = try XCTUnwrap(asked.value.first, "the probe was asked")
            XCTAssertNil(usageEnv[r.ticketKey]); XCTAssertNil(usageEnv[r.socketKey])
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    // vault-profiles.test.ts:337
    func testAVaultThatWillNotUnlockIsLeftExactlyAsItIsAndItsAccountsReadUnavailable() async throws {
        let r = try await BackendF4Runtime.wire()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let work = try await r.create("work@example.com")
        await r.put(work.id, BackendF4ClaudeLogin(secret))
        let file = await r.vault.file
        await r.dispose()
        let before = try Data(contentsOf: file)
        // Another build's key: the runtime does not start (TS wireRaw -> null) and the file is untouched.
        do { let other = try await BackendF4Runtime.wire(root: r.root, cipher: BackendF4OtherBuildCipher()); await other.dispose(); XCTFail("a vault that will not unlock must not start") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
        let state = try NativeStateStore(file: r.configuration.dataDirectory.appendingPathComponent("state.json"), ownership: .exclusive, clock: { 1_000 })
        let store = try BackendAccountProfileStore(configuration: r.configuration, stateStore: state)
        let current = try await XCTUnwrapAsync(try await store.find(work.id))
        let managedNow = await store.managed(current)
        XCTAssertEqual(Kept.keptBy(current, managed: managedNow, usable: false), .unavailable)
        await store.close(); await state.close()
        // And with the right key it opens, every login still in it.
        let again = try await BackendF4Runtime.wire(root: r.root)
        let read = await again.vault.readSlot(work.id, slot: slot)
        XCTAssertEqual(read, BackendF4ClaudeLogin(secret))
        await again.dispose()
    }

    // vault-profiles.test.ts:359
    func testACodexAccountReadsCannotTellUntilSomethingHasBeenKeptForIt() async throws { try await withRuntime { r in
        let codex = try await r.create("codex@example.com", provider: "codex")
        let first = try await r.signedIn(codex.id); XCTAssertEqual(first, .null)
        let file = URL(fileURLWithPath: codex.configDir).appendingPathComponent("auth.json")
        try Data("{\"tokens\":{\"access_token\":\"at\"}}".utf8).write(to: file)
        _ = await r.codex.capture(codex)
        let kept = try await r.signedIn(codex.id); XCTAssertEqual(kept, .bool(true))
        try FileManager.default.removeItem(at: file)
        _ = await r.codex.capture(codex)
        let out = try await r.signedIn(codex.id); XCTAssertEqual(out, .bool(false))
    } }

    // vault-profiles.test.ts:384. TS asserts host-core.ts source: a confined session gets no ticket and no seat.
    // Natively a device-confined launch carries no vault variable at all; a kept Claude login under a
    // device is refused outright (it could not reach the host socket), so it reaches nothing either.
    func testGivesAConfinedSessionNoTicketSoAHeldDeviceReachesNothingItCouldNotReachBefore() async throws { try await withRuntime { r in
        let work = try await r.create("work@example.com")
        let device = BackendLaunchContext(deviceBoundary: BackendDeviceBoundary(deviceKey: "phone", folder: r.root.path))
        let spec = BackendProviderSpec(id: "claude", command: "/bin/sh", args: ["-c", "true"], resumeArgs: [])
        func launch(_ profile: String) async throws -> BackendAccountLaunch {
            var input = BackendCreateSessionInput(cwd: r.root.path, cols: 80, rows: 24, provider: "claude"); input.profileId = profile
            let launch = try await r.adapter.resolve(input, provider: spec, loginPath: "/usr/bin:/bin", context: device)
            await r.adapter.abandon(launch)
            return launch
        }
        let own = try await launch("system")
        XCTAssertTrue(r.configuration.vaultVariables.isDisjoint(with: own.environment.keys), "\(own.environment.keys)")
        XCTAssertEqual(own.path, "/usr/bin:/bin")
        do { let kept = try await launch(work.id); XCTAssertTrue(r.configuration.vaultVariables.isDisjoint(with: kept.environment.keys)) } catch {}
    } }

    // vault-profiles.test.ts:399, the sign-in half (the usage half follows).
    func testNeverHandsAProbeATicketInheritedFromWhateverLaunchedTheApp() async throws {
        let root = try BackendF4Runtime.makeRoot()
        let inherited = ["USER": "me", "TERMINALDECK_ACCOUNT_TICKET": String(repeating: "f", count: 48), "TERMINALDECK_ACCOUNT_VAULT": "/somewhere/else.sock"]
        let r = try await BackendF4Runtime.wire(root: root, environment: inherited)
        do {
            let executor = BackendF4Executor(answer: .init(stdout: "{\"loggedIn\":false}", exitCode: 0))
            let system = try await XCTUnwrapAsync(try await r.profiles.find("system"))
            _ = await (try r.signIn(executor: executor)).read(system, provider: "claude")
            let seen = try XCTUnwrap(executor.runs.value.first).environment
            XCTAssertNil(seen[r.ticketKey]); XCTAssertNil(seen[r.socketKey])
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    // vault-profiles.test.ts:443
    func testTheMCPAccountToolsShowAKeptAccountAsKeptAndSignedInAndNeverCarryItsLogin() async throws { try await withRuntime { r in
        let work = try await r.create("work@example.com")
        await r.put(work.id, BackendF4ClaudeLogin(secret))
        let service = try r.signIn(executor: BackendF4Executor())
        let accounts = BackendDeckToolsSessionsNativeAccounts(rpc: r.rpc, profiles: await r.profiles, context: { _ in BackendF4Runtime.context },
                                                              extras: BackendF4AccountExtras(service: service, profiles: await r.profiles))
        let fixture = BackendDeckCoreTestPortSessionsFixture()
        let definitions = try BackendDeckToolsSessionsArea.accountDefinitions(runtime: fixture, accounts: accounts, sessions: fixture)
        func run(_ id: String, _ args: NativeRPCValue) async throws -> BackendMCPToolReply {
            try await XCTUnwrap(definitions.first { $0.spec.id == id }).handler(BackendDeckCoreTestPortSessionsFixture.context(), args)
        }
        let listed = try await run("accounts.list", .object([]))
        let checked = try await run("accounts.status", .object([.init("accountId", .string(work.id))]))
        let text = NativeRPCValue.array([listed.structuredContent ?? .null, checked.structuredContent ?? .null]).compact
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("sk-ant")); XCTAssertFalse(text.contains(r.ticketKey))
        XCTAssertFalse(text.contains("[withheld]"))
        let snapshot = listed.structuredContent?["accounts"]["vault"][work.id]
        XCTAssertEqual(snapshot?["keptBy"].string, "app"); XCTAssertEqual(snapshot?["signedIn"], .bool(true))
        XCTAssertEqual(checked.structuredContent?["signIn"]["state"].string, "signed-in")
    } }
}

/// `try XCTUnwrap` for an awaited optional.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}

/// TS vault-profiles.test.ts:345 `otherBuild`: the fake cipher, but its key is not this one.
final class BackendF4OtherBuildCipher: BackendAccountVaultCipher, @unchecked Sendable {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { BackendF4FakeCipher.encrypt(text) }
    func decrypt(_ blob: Data) throws -> String { throw BackendAccountFailure("a different key") }
}

/// Sign-in dependencies in a process where no vault runs: the profile store alone.
struct BackendF4NoVaultSignInDependencies: BackendAppAccountSignInDependencies {
    let configuration: BackendAccountConfiguration
    let profiles: BackendAccountProfileStore
    func find(_ id: String) async throws -> BackendAccountProfile? { try await profiles.find(id) }
    func managed(_ profile: BackendAccountProfile) async -> Bool { await profiles.managed(profile) }
    func summaries() async throws -> [BackendAccountVaultSummary] { throw BackendAccountFailure("No vault runs in this process.") }
    func vaultUsable() async -> Bool { false }
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary {
        .init(id: provider, onPath: "/fixture/bin/" + provider, runnable: "/fixture/bin/" + provider, version: "fixture", broken: false, said: nil, usedAlternate: false, checkedAt: Date())
    }
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        BackendAppAccountSignInParsing.accountEnvironment(profile, provider: provider, inherited: configuration.inheritedEnvironment, path: path, vaultVariables: configuration.vaultVariables)
    }
    func recheck(_ profile: BackendAccountProfile) async throws {}
    func readJSON(_ file: URL) -> NativeRPCValue { .null }
    func nonEmptyFile(_ file: URL) -> Bool { false }
}

/// TS vault-profiles.test.ts:449 `accountTools({...})`: sign-in from the real service; history, sign-out and sharing are stubs.
struct BackendF4AccountExtras: BackendDeckToolsSessionsAccountExtras {
    let service: BackendAppAccountSignInService
    let profiles: BackendAccountProfileStore
    func signInStatus(accountID: String, refresh: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard let profile = try await profiles.find(accountID) else { throw BackendAccountFailure("no profile with id \(accountID)") }
        return await service.read(profile, refresh: refresh).wireValue
    }
    func history(accountID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        .object([.init("state", .null), .init("share", .string("")), .init("unshare", .string("")), .init("remove", .string(""))])
    }
    func signOut(accountID: String, context: NativeRPCContext) async throws -> NativeRPCValue { .object([.init("ok", .bool(true)), .init("message", .string(""))]) }
    func shareHistory(accountID: String, share: Bool, context: NativeRPCContext) async throws -> NativeRPCValue { .null }
}
