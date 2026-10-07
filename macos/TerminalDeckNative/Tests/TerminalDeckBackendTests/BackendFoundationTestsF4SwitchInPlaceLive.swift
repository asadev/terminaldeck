import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/host-core.switch-in-place.test.ts:149 and :190, end to end: a real PTY running a
/// stand-in `claude` (a shell loop that asks `security` for its login on every line it reads), the shim
/// on its PATH, the test-only F4AccountShimHelper binary, the broker's socket, the vault (fake cipher),
/// the session lifecycle and the switch verbs. Anything passed through to "the real `security`" reaches
/// the stand-in script, never a keychain (F4_FAKE_SECURITY).
final class BackendFoundationTestsF4SwitchInPlaceLive: XCTestCase, @unchecked Sendable {
    private let slot = "keychain:Claude Code-credentials"

    private struct Providers: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        let claude: String, path: String
        func loginPath() async throws -> String { path }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            guard input.provider == "claude" else { throw BackendSessionFailure.providerMismatch }
            return BackendProviderSpec(id: "claude", command: claude, args: [], resumeArgs: [])
        }
    }
    private struct Unconfined: BackendConfinementLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch,
                     context: BackendLaunchContext) async throws -> BackendConfinedLaunch { BackendConfinedLaunch(command: command, args: args) }
    }
    private struct NoInstructions: BackendInstructionLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
    }
    private struct NoProjectTools: BackendProjectMCPSource {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
    }

    private final class Core: @unchecked Sendable {
        let r: BackendF4Runtime, manager: BackendPTYManager, lifecycle: BackendSessionLifecycleCoordinator
        let switches: BackendSessionSwitchCoordinator, changed: BackendF4Box<[String]>, systemDir: URL
        init(r: BackendF4Runtime, manager: BackendPTYManager, lifecycle: BackendSessionLifecycleCoordinator, switches: BackendSessionSwitchCoordinator,
             changed: BackendF4Box<[String]>, systemDir: URL) {
            self.r = r; self.manager = manager; self.lifecycle = lifecycle; self.switches = switches; self.changed = changed; self.systemDir = systemDir
        }
        /// TS `until(check, ms)`.
        func until(_ milliseconds: Int = 8_000, _ check: () -> Bool) async {
            let end = Date().addingTimeInterval(Double(milliseconds) / 1000)
            while !check(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        private func answers(_ id: String) -> [(token: String, pid: String)] {
            let text = manager.scrollback(id), pattern = try! NSRegularExpression(pattern: #"ANSWER\[([^\]]*)\] PID=(\d+)"#)
            return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                (String(text[Range($0.range(at: 1), in: text)!]), String(text[Range($0.range(at: 2), in: text)!]))
            }
        }
        /// TS `ask(id)`: one line in, one lookup through the shim, one answer printed.
        func ask(_ id: String) async throws -> (token: String, pid: String) {
            let before = answers(id).count
            try manager.write(id, data: "x\r")
            await until { answers(id).count > before }
            return answers(id).last ?? ("", "")
        }
    }

    /// TS beforeAll: stand-in agent and `security`, the system install's folder and login, the runtime, the core.
    private func core() async throws -> Core {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = packageRoot.appendingPathComponent(".build/out/Products/Debug/F4AccountShimHelper")
        let helperSource = packageRoot.appendingPathComponent("Sources/F4AccountShimHelper/main.swift")
        guard (try? String(contentsOf: helperSource, encoding: .utf8))?.contains("F4_FAKE_SECURITY") == true,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Waiting on NIGHT-REQUESTS \"F4 → O2: the test shim helper uses a stand-in security\": without it a pass-through could reach the real keychain.")
        }
        let root = try BackendF4Runtime.makeRoot()
        let bin = root.appendingPathComponent("bin"), systemDir = root.appendingPathComponent("own-claude")
        for folder in [bin, systemDir] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // TS fakeBin/claude, line for line.
        let claude = bin.appendingPathComponent("claude")
        try ["#!/bin/sh", "echo \"PID=$$\"", "while IFS= read -r line; do", "  svc=\"Claude Code-credentials\"",
             "  dir=\"${CLAUDE_SECURESTORAGE_CONFIG_DIR:-$CLAUDE_CONFIG_DIR}\"", "  if [ -n \"$dir\" ]; then",
             "    h=$(printf \"%s\" \"$dir\" | shasum -a 256 | cut -c1-8)", "    svc=\"$svc-$h\"", "  fi",
             "  out=$(security find-generic-password -a me -w -s \"$svc\" 2>/dev/null)",
             "  token=$(printf \"%s\" \"$out\" | sed -n \"s/.*accessToken\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\")",
             "  echo \"ANSWER[$token] PID=$$\"", "done", ""].joined(separator: "\n").write(to: claude, atomically: true, encoding: .utf8)
        // TS fakeSecurity: the Mac's own login under its folder's name; anything else "not found"; writes swallowed.
        let systemService = "Claude Code-credentials-" + String(BackendAccountSwitchInPlace.sha256Hex(systemDir.path).prefix(8))
        let systemLogin = BackendF4ClaudeLogin("MAC-OWN")
        let fake = root.appendingPathComponent("fake-security")
        try ["#!/bin/sh", "[ \"$1\" = \"-i\" ] && { cat >/dev/null; exit 0; }",
             "svc=\"\"; prev=\"\"; for a in \"$@\"; do [ \"$prev\" = \"-s\" ] && svc=\"$a\"; prev=\"$a\"; done",
             "[ \"$1\" = find-generic-password ] && [ \"$svc\" = '\(systemService)' ] && { printf '%s\\n' '\(systemLogin)'; exit 0; }",
             "exit 44", ""].joined(separator: "\n").write(to: fake, atomically: true, encoding: .utf8)
        for file in [claude, fake] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let fakePath = fake.path
        // The broker's own keychain reads go to the same stand-in (TS `realSecurity: fakeSecurity`).
        let runner: BackendAccountSecurityRunner = { argv, stdin in
            let child = Process(), out = Pipe(), input = Pipe()
            child.executableURL = URL(fileURLWithPath: fakePath); child.arguments = argv
            child.standardOutput = out; child.standardError = FileHandle.nullDevice; child.standardInput = input
            do { try child.run() } catch { return .init(code: 1, stdout: "", stderr: "") }
            if let stdin { try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
            try? input.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
            return .init(code: child.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        let r = try await BackendF4Runtime.wire(root: root, environment: ["USER": "me", "CLAUDE_CONFIG_DIR": systemDir.path], helper: helper, runner: runner)
        do {
            let data = r.configuration.dataDirectory, profiles = await r.profiles
            let providers = Providers(claude: claude.path, path: "\(bin.path):/usr/bin:/bin")
            let manager = BackendPTYManager(inheritedEnvironment: ["HOME": r.configuration.homeDirectory.path, "USER": "me",
                                                                   "F4_FAKE_SECURITY": fakePath, "PATH": "/usr/bin:/bin"]) { _ in }
            let ledger = try await BackendNativeLedger.activate(store: r.state, oldSessionOwnerDisabled: true)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: try BackendSessionLaunchDependencies(providers: providers, accounts: r.adapter,
                confinement: Unconfined(), instructions: NoInstructions(), ledger: ledger))
            let endpoint = BackendSuppliedMCPBridge(readiness: .ready, description: { nil }, catalogue: { [] },
                register: { _, _ in throw BackendAccountFailure("No session tools in this test.") }, bind: { _, _, _ in }, revoke: { _ in })
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: providers, sessionTools: try BackendSessionToolLeases(endpoint: endpoint, userData: data),
                projectTools: try BackendProjectToolComposition(source: NoProjectTools(), userData: data, inheritedEnvironment: [:]),
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let attribution = BackendAccountAttribution(configuration: r.configuration, profiles: profiles)
            let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: r.adapter, attribution: attribution, ledger: ledger,
                store: r.state, cleanup: BackendSessionLifecycleCleanup(readiness: .ready, release: { _ in }), emit: { _ in })
            let planner = BackendSessionRestorePlanner(accounts: r.adapter, providers: providers,
                context: BackendSessionRestoreContext(readiness: .ready, resolveDevice: { _, _ in throw BackendAccountFailure("No devices in this test.") }))
            let changed = BackendF4Box<[String]>([])
            let switches = try await BackendSessionSwitchCoordinator.start(lifecycle: lifecycle, accounts: r.adapter, attribution: attribution, planner: planner,
                store: r.state, emit: { event in if case .accountChanged(let meta, _) = event { changed.update { $0.append(meta.id) } } })
            return Core(r: r, manager: manager, lifecycle: lifecycle, switches: switches, changed: changed, systemDir: systemDir)
        } catch { await r.dispose(removeRoot: true); throw error }
    }
    private func finish(_ c: Core) async {
        c.manager.killAll(); _ = await c.manager.drain()
        await c.switches.stop()
        await c.r.dispose(removeRoot: true)
    }
    private func start(_ c: Core, profile: String, folder: String) async throws -> BackendSessionMeta {
        let cwd = c.r.root.appendingPathComponent(folder + "-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        var input = BackendCreateSessionInput(cwd: cwd.path, cols: 100, rows: 30, provider: "claude"); input.profileId = profile
        return try await c.lifecycle.create(input)
    }
    /// The row after the agent has read the new login (native confirms the switch on that reread).
    private func row(_ c: Core, _ id: String) -> BackendSessionMeta? { c.manager.list().first { $0.id == id } }

    // host-core.switch-in-place.test.ts:149
    func testHandsTheSameProcessTheOtherAccountsLoginSameSessionSamePIDNothingRestarted() async throws {
        let c = try await core()
        do {
            let home = try await c.r.create("home@example.com"), work = try await c.r.create("work@example.com")
            await c.r.put(home.id, BackendF4ClaudeLogin("HOME")); await c.r.put(work.id, BackendF4ClaudeLogin("WORK"))
            let meta = try await start(c, profile: home.id, folder: "proj")
            XCTAssertEqual(meta.profileId, home.id)
            let pidBefore = c.manager.pidOf(meta.id)
            let first = try await c.ask(meta.id); XCTAssertEqual(first.token, "sk-ant-oat01-HOME")

            let plan = try await c.switches.subject(sessionID: meta.id, accountID: work.id)
            XCTAssertNil(plan.refusal); XCTAssertEqual(plan.mode, .inPlace); XCTAssertEqual(plan.conversation, "same")
            let switched = try await c.switches.perform(sessionID: meta.id, accountID: work.id)
            XCTAssertEqual(switched.session.id, meta.id)

            let after = try await c.ask(meta.id)
            XCTAssertEqual(after.token, "sk-ant-oat01-WORK")
            await c.until { self.row(c, meta.id)?.profileId == work.id }
            XCTAssertEqual(row(c, meta.id)?.profileId, work.id); XCTAssertEqual(row(c, meta.id)?.profileName, "work@example.com")
            XCTAssertEqual(row(c, meta.id)?.homeProfileId, home.id)
            XCTAssertEqual(c.changed.value, [meta.id])
            XCTAssertEqual(c.manager.pidOf(meta.id), pidBefore)
            XCTAssertEqual(c.manager.list().filter { $0.exitCode == nil }.map(\.id), [meta.id])
            let ledger = try await c.r.state.ledgerGet(meta.id)
            XCTAssertEqual(ledger["profileId"].string, work.id); XCTAssertEqual(ledger["homeProfileId"].string, home.id)

            let back = try await c.switches.perform(sessionID: meta.id, accountID: home.id)
            XCTAssertEqual(back.session.id, meta.id)
            let again = try await c.ask(meta.id); XCTAssertEqual(again.token, "sk-ant-oat01-HOME")
            await c.until { self.row(c, meta.id)?.profileId == home.id }
            XCTAssertNil(row(c, meta.id)?.homeProfileId)
            XCTAssertEqual(c.manager.pidOf(meta.id), pidBefore)
            let ledgerBack = try await c.r.state.ledgerGet(meta.id)
            XCTAssertNil(ledgerBack["homeProfileId"].string)
        } catch { await finish(c); throw error }
        await finish(c)
    }

    // host-core.switch-in-place.test.ts:190
    func testASessionOnTheMacsOwnLoginSwitchesInPlaceTooAndNothingIsWrittenIntoItsFolder() async throws {
        let c = try await core()
        do {
            let work = try await c.r.create("premium@example.com")
            await c.r.put(work.id, BackendF4ClaudeLogin("PREMIUM"))
            let meta = try await start(c, profile: BackendAccountProfile.systemID("claude"), folder: "crm")
            let pid = c.manager.pidOf(meta.id)
            let own = try await c.ask(meta.id); XCTAssertEqual(own.token, "sk-ant-oat01-MAC-OWN")
            let before = try FileManager.default.contentsOfDirectory(atPath: c.systemDir.path).sorted()

            let switched = try await c.switches.perform(sessionID: meta.id, accountID: work.id)
            XCTAssertEqual(switched.session.id, meta.id)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.systemDir.path).sorted(), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.systemDir.appendingPathComponent(".credentials.json").path))

            let after = try await c.ask(meta.id); XCTAssertEqual(after.token, "sk-ant-oat01-PREMIUM")
            await c.until { self.row(c, meta.id)?.profileId == work.id }
            XCTAssertEqual(row(c, meta.id)?.profileId, work.id)
            XCTAssertEqual(c.manager.pidOf(meta.id), pid)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.systemDir.path).sorted(), before)
            let store = c.r.configuration.dataDirectory.appendingPathComponent("account-vault/store")
                .appendingPathComponent(BackendAccountProfile.systemID("claude").replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
            await c.until { !FileManager.default.fileExists(atPath: store.appendingPathComponent(".credentials.json").path) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(".credentials.json").path))
        } catch { await finish(c); throw error }
        await finish(c)
    }
}
