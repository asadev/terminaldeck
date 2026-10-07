import Foundation
import XCTest
import CryptoKit
import Darwin
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/account-vault/server.test.ts (and vault-profiles.test.ts:376).
///
/// Native wire contract, kept on purpose: TS's shim is a `sh` script speaking
/// HTTP over the socket with a NUL-joined body and three lines of text back
/// (server.ts:310 `readBody`, :760 `wireText`). Native replaced that with a
/// signed helper exchanging framed JSON over a 0600 same-UID unix socket, plus
/// a peer-PID check for credential receipts. So: the request is the JSON
/// object `{ticket, argv, stdin}` read by `BackendAccountVaultServer.readBody`;
/// the answer is `{kind: pass|capture|exit, code, stdout, stderr}`; the capture
/// report (TS `/keychain/captured`) is `{operation: "captured", ticket, code,
/// argv, stdout}`. What the agent observes from `security` is byte-identical to
/// TS. The "real shell against a real socket" group runs the helper's client
/// in-process against the broker's real socket; the real `security` is a fake
/// that records how it was called (TS server.test.ts:270), never a keychain.
final class BackendFoundationTestsF4Server: XCTestCase, @unchecked Sendable {
    typealias Server = BackendAccountVaultServer
    typealias Answer = BackendAccountSwitchInPlace.KeychainAnswer
    static let slot = "keychain:Claude Code-credentials"
    /// Each account's own config directory — the hash on its keychain items comes from it.
    static let configDirs = ["one": "/cfg/one", "two": "/cfg/two"]
    static let notFoundText = "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."

    static func hex(_ text: String) -> String { Data(text.utf8).map { String(format: "%02x", $0) }.joined() }
    /// `sha256(dir)[:8]`, the suffix the CLI names an account's keychain items with.
    static func suffixOf(_ dir: String) -> String { SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description }
    /// The login item's service name for one account, as the CLI spells it.
    static func serviceOf(_ account: String) -> String { "Claude Code-credentials-\(suffixOf(configDirs[account] ?? ""))" }

    /// server.test.ts:56 `beforeEach`.
    final class Rig: @unchecked Sendable {
        let vault: BackendAccountVault
        let tickets = BackendAccountTicketBook()
        let adopting = BackendF4Box<Set<String>>([])
        /// Slots settled, as `<account>|<slot>`.
        let settled = BackendF4Box<Set<String>>([])
        let kept = BackendF4Box<[String]>([])
        var deps: Server.Deps
        init(vault: BackendAccountVault) {
            self.vault = vault
            let accounts = ["one": "claude", "two": "claude"]
            let adopting = adopting, settled = settled, kept = kept
            deps = Server.Deps(
                vault: vault, tickets: tickets,
                providerOf: { accounts[$0] },
                configDirOf: { BackendFoundationTestsF4Server.configDirs[$0] },
                adopting: { id, slot in adopting.value.contains(id) && !settled.value.contains("\(id)|\(slot)") },
                markKept: { id, slot in kept.update { $0.append(id) }; settled.update { $0.insert("\(id)|\(slot)") } })
        }
        func answer(_ request: Server.Request?) async -> Server.WireAnswer { await Server.answerShim(request, deps: deps) }
        /// The account a ticket names, for spelling its own service — `one` for a forged one.
        func accountOf(_ ticket: String) -> String { tickets.accountFor(ticket) ?? "one" }
        func body(_ ticket: String, _ argv: [String], _ stdin: String = "") -> Server.Request? {
            Server.readBody(.object([.init("ticket", .string(ticket)), .init("argv", .array(argv.map(NativeRPCValue.string))), .init("stdin", .string(stdin))]))
        }
        func find(_ ticket: String, _ account: String? = nil) -> Server.Request? {
            body(ticket, ["find-generic-password", "-a", "me", "-w", "-s", BackendFoundationTestsF4Server.serviceOf(account ?? accountOf(ticket))])
        }
        func add(_ ticket: String, _ value: String, _ account: String? = nil) -> Server.Request? {
            body(ticket, ["-i"], "add-generic-password -U -a \"me\" -s \"\(BackendFoundationTestsF4Server.serviceOf(account ?? accountOf(ticket)))\" -X \"\(BackendFoundationTestsF4Server.hex(value))\"\n")
        }
        func remove(_ ticket: String, _ account: String? = nil) -> Server.Request? {
            body(ticket, ["delete-generic-password", "-a", "me", "-s", BackendFoundationTestsF4Server.serviceOf(account ?? accountOf(ticket))])
        }
        func put(_ account: String, _ value: String) async { _ = await vault.write(accountID: account, provider: "claude", slot: BackendFoundationTestsF4Server.slot, value: value, source: "sign-in") }
        func read(_ account: String) async -> String? { await vault.readSlot(account, slot: BackendFoundationTestsF4Server.slot) }
    }

    static func exitAnswer(_ wire: Server.WireAnswer) -> Answer? { if case .exit(let answer) = wire { answer } else { nil } }

    private func withRig(_ body: (Rig) async throws -> Void) async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let vault = try BackendF4Vault(f)
            do { try await body(Rig(vault: vault)); await vault.close() } catch { await vault.close(); throw error }
        }
    }

    // MARK: answering a session from the vault

    // server.test.ts:85
    func testEachSessionIsAnsweredWithItsOwnAccountAndNoOther() async throws {
        try await withRig { r in
            await r.put("one", BackendF4ClaudeLogin("ONE")); await r.put("two", BackendF4ClaudeLogin("TWO"))
            let a = await r.answer(r.find(r.tickets.ticketFor("one")))
            let b = await r.answer(r.find(r.tickets.ticketFor("two")))
            XCTAssertEqual(a, .exit(Answer(code: 0, stdout: BackendF4ClaudeLogin("ONE"), stderr: "")))
            XCTAssertEqual(b, .exit(Answer(code: 0, stdout: BackendF4ClaudeLogin("TWO"), stderr: "")))
        }
    }

    // server.test.ts:94
    func testASwitchIsANewTicketAndChangesNothingForAnyOtherSession() async throws {
        try await withRig { r in
            await r.put("one", BackendF4ClaudeLogin("ONE")); await r.put("two", BackendF4ClaudeLogin("TWO"))
            let sessionB = r.tickets.ticketFor("two")
            // Session A was on `one` and is restarted on `two` — it is simply handed
            // `two`'s ticket. Session B keeps working, and `one`'s login is untouched.
            let sessionA = r.tickets.ticketFor("two")
            let a = await r.answer(r.find(sessionA)), b = await r.answer(r.find(sessionB))
            XCTAssertEqual(a, b)
            let one = await r.answer(r.find(r.tickets.ticketFor("one")))
            XCTAssertEqual(Self.exitAnswer(one)?.stdout, BackendF4ClaudeLogin("ONE"))
        }
    }

    // server.test.ts:108
    func testASignOutInOneAccountSignsOutThatAccountOnly() async throws {
        try await withRig { r in
            await r.put("one", BackendF4ClaudeLogin("ONE")); await r.put("two", BackendF4ClaudeLogin("TWO"))
            let removed = await r.answer(r.remove(r.tickets.ticketFor("one")))
            XCTAssertEqual(Self.exitAnswer(removed)?.code, 0)
            let held = await r.vault.has("one")
            XCTAssertFalse(held)
            let two = await r.answer(r.find(r.tickets.ticketFor("two")))
            XCTAssertEqual(Self.exitAnswer(two)?.stdout, BackendF4ClaudeLogin("TWO"))
        }
    }

    // server.test.ts:116
    func testCapturesTheSignInAndEveryRefreshTheAgentWritesBack() async throws {
        try await withRig { r in
            let ticket = r.tickets.ticketFor("one")
            let heard = BackendF4Box<[String]>([])
            r.deps.onCapture = { event in heard.update { $0.append(event.kind) } }
            let first = await r.answer(r.find(ticket))
            XCTAssertEqual(first, .exit(Answer(code: 44, stdout: "", stderr: Self.notFoundText)))
            let signIn = await r.answer(r.add(ticket, BackendF4ClaudeLogin("FIRST")))
            XCTAssertEqual(Self.exitAnswer(signIn)?.code, 0)
            let refresh = await r.answer(r.add(ticket, BackendF4ClaudeLogin("REFRESHED")))
            XCTAssertEqual(Self.exitAnswer(refresh)?.code, 0)
            let value = await r.read("one")
            XCTAssertEqual(value, BackendF4ClaudeLogin("REFRESHED"))
            XCTAssertEqual(heard.value, ["sign-in", "refresh"])
            XCTAssertTrue(r.kept.value.contains("one"))
            let summary = await r.vault.summary("one")
            XCTAssertEqual(summary?.lastSource, "refresh")
        }
    }

    // server.test.ts:133
    func testNeverAnswersALoginLookupWithoutATicketThisRunMintedNorWithAToken() async throws {
        try await withRig { r in
            await r.put("one", BackendF4ClaudeLogin("ONE"))
            let forged = String(repeating: "a", count: 48)
            let forgedFind = await r.answer(r.find(forged))
            XCTAssertEqual(forgedFind, .exit(Answer(code: 44, stdout: "", stderr: Self.notFoundText)))
            let empty = await r.answer(r.find(""))
            XCTAssertEqual(Self.exitAnswer(empty)?.code, 44)
            // A write with a bad ticket keeps nothing.
            _ = await r.answer(r.add(forged, BackendF4ClaudeLogin("EVIL")))
            let summaries = await r.vault.allSummaries()
            XCTAssertFalse(String(describing: summaries).contains("EVIL"))
            let value = await r.read("one")
            XCTAssertEqual(value, BackendF4ClaudeLogin("ONE"))
        }
    }

    // server.test.ts:144
    func testStopsAnsweringForAnAccountTheMomentItIsDeleted() async throws {
        try await withRig { r in
            await r.put("one", BackendF4ClaudeLogin("ONE"))
            let ticket = r.tickets.ticketFor("one")
            r.tickets.revoke("one")
            let found = await r.answer(r.find(ticket))
            XCTAssertEqual(Self.exitAnswer(found)?.code, 44)
            // And a fresh ticket for a re-made account of the same name is a different one.
            XCTAssertNotEqual(r.tickets.ticketFor("one"), ticket)
        }
    }

    // server.test.ts:153
    func testPassesEverythingThatIsNotALoginStraightToTheRealCommand() async throws {
        try await withRig { r in
            let ticket = r.tickets.ticketFor("one")
            let identity = await r.answer(r.body(ticket, ["find-identity", "-v"]))
            XCTAssertEqual(identity, .pass)
            let deviceKeys = await r.answer(r.body(ticket, ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-device-keys"]))
            XCTAssertEqual(deviceKeys, .pass)
        }
    }

    // server.test.ts:161
    func testMovesAPreVaultAccountByKeepingWhatTheAgentItselfReadsOnce() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("one") }
            let ticket = r.tickets.ticketFor("one")
            let first = await r.answer(r.find(ticket))
            XCTAssertEqual(first, .capture)
            // The shim ran the real command and reports what it printed (TS: the
            // NUL body ticket, '0', '6', argv, stdout; native: the `captured` frame).
            let report = Server.CaptureReport(ticket: ticket, code: 0, argv: ["find-generic-password", "-a", "me", "-w", "-s", Self.serviceOf("one")],
                                              stdout: BackendF4ClaudeLogin("OLD-KEYCHAIN") + "\n")
            let accepted = await Server.acceptCapture(report, deps: r.deps)
            XCTAssertTrue(accepted)
            let value = await r.read("one")
            XCTAssertEqual(value, BackendF4ClaudeLogin("OLD-KEYCHAIN"))
            let summary = await r.vault.summary("one")
            XCTAssertEqual(summary?.lastSource, "adopted")
            // Moved for good: the next lookup is the vault's, not the keychain's.
            let next = await r.answer(r.find(ticket))
            XCTAssertEqual(Self.exitAnswer(next)?.stdout, BackendF4ClaudeLogin("OLD-KEYCHAIN"))
        }
    }

    // server.test.ts:177
    func testKeepsNothingFromAFailedCaptureAndSettlesASlotTheKeychainNeverHad() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("one") }
            let ticket = r.tickets.ticketFor("one")
            func report(_ code: Int, _ out: String) -> Server.CaptureReport {
                Server.CaptureReport(ticket: ticket, code: code, argv: ["find-generic-password", "-a", "me", "-w", "-s", Self.serviceOf("one")], stdout: out)
            }
            // Locked keychain: nothing kept, nothing settled — the next lookup tries again.
            let locked = await Server.acceptCapture(report(36, ""), deps: r.deps)
            XCTAssertFalse(locked)
            XCTAssertFalse(r.settled.value.contains("one|\(Self.slot)"))
            // "Not found" in the real keychain: nothing to move, and the slot is settled.
            let missing = await Server.acceptCapture(report(44, ""), deps: r.deps)
            XCTAssertTrue(missing)
            XCTAssertTrue(r.settled.value.contains("one|\(Self.slot)"))
            let heldAfterMissing = await r.vault.has("one")
            XCTAssertFalse(heldAfterMissing)
            // Settled for good: a late report of a value is not kept.
            let late = await Server.acceptCapture(report(0, "x"), deps: r.deps)
            XCTAssertFalse(late)
            let heldAfterLate = await r.vault.has("one")
            XCTAssertFalse(heldAfterLate)
        }
    }

    // server.test.ts:200 (review finding 3)
    func testASignOutOfALoginStillInTheKeychainReallyDeletesItAndItStaysDeleted() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("one") }
            let ticket = r.tickets.ticketFor("one")
            let removed = await r.answer(r.remove(ticket))
            XCTAssertEqual(removed, .pass)
            XCTAssertTrue(r.settled.value.contains("one|\(Self.slot)"))
            // The next lookup is the vault's — empty — and never a capture.
            let next = await r.answer(r.find(ticket))
            XCTAssertEqual(Self.exitAnswer(next)?.code, 44)
        }
    }

    // server.test.ts:209
    func testMovesEachSlotOnItsOwnSoSettlingTheLoginDoesNotStrandTheAPIKeySlot() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("one") }
            let ticket = r.tickets.ticketFor("one")
            let apiKey = r.body(ticket, ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-\(Self.suffixOf(Self.configDirs["one"] ?? ""))"])
            let login = await r.answer(r.find(ticket))
            XCTAssertEqual(login, .capture)
            r.settled.update { $0.insert("one|\(Self.slot)") }
            let key = await r.answer(apiKey)
            XCTAssertEqual(key, .capture)
        }
    }

    // server.test.ts:223 (review finding 11)
    func testPassesAnInteractiveModeLookupThroughRatherThanPromisingACapture() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("one") }
            let ticket = r.tickets.ticketFor("one")
            let interactive = await r.answer(r.body(ticket, ["-i"], "find-generic-password -a \"me\" -w -s \"\(Self.serviceOf("one"))\"\n"))
            XCTAssertEqual(interactive, .pass)
        }
    }

    // server.test.ts:235 (review finding 6)
    func testAnswersOnlyLookupsCarryingThisAccountsOwnDirectoryHash() async throws {
        try await withRig { r in
            await r.put("one", BackendF4ClaudeLogin("ONE"))
            let ticket = r.tickets.ticketFor("one")
            let elsewhere = "Claude Code-credentials-\(Self.suffixOf("/somewhere/else"))"
            let nestedFind = r.body(ticket, ["find-generic-password", "-a", "me", "-w", "-s", elsewhere])
            let nestedWrite = r.body(ticket, ["-i"], "add-generic-password -U -a \"me\" -s \"\(elsewhere)\" -X \"\(Self.hex("EVIL"))\"\n")
            let nestedDelete = r.body(ticket, ["delete-generic-password", "-a", "me", "-s", elsewhere])
            let machineOwn = r.body(ticket, ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials"])
            for request in [nestedFind, nestedWrite, nestedDelete, machineOwn] {
                let answer = await r.answer(request)
                XCTAssertEqual(answer, .pass)
            }
            let value = await r.read("one")
            XCTAssertEqual(value, BackendF4ClaudeLogin("ONE"))
            // And this account's own spelling is answered as before.
            let own = await r.answer(r.find(ticket))
            XCTAssertEqual(Self.exitAnswer(own)?.stdout, BackendF4ClaudeLogin("ONE"))
        }
    }

    // server.test.ts:251 — TS `wireText` is three shell lines ('pass\n'; 'exit 44\na b\n').
    // Native equivalent: the framed answer, whose stderr is one line, as the helper reads it.
    func testSpeaksAFrameTheHelperCanRead() throws {
        XCTAssertEqual(Server.wire(.pass), BackendAccountShimAnswer(kind: "pass", code: 0, stdout: "", stderr: ""))
        let notFound = Server.wire(.exit(Answer(code: 44, stdout: "", stderr: "a\nb")))
        XCTAssertEqual(notFound, BackendAccountShimAnswer(kind: "exit", code: 44, stdout: "", stderr: "a b"))
        let decoded = try JSONDecoder().decode(BackendAccountShimAnswer.self, from: JSONEncoder().encode(notFound))
        XCTAssertEqual(decoded, notFound)
    }

    // MARK: the shim, run against a real socket

    /// TS server.test.ts:270: the "real" security records how it was called and
    /// answers like a file would. Every pass-through lands here.
    final class FakeSecurity: @unchecked Sendable {
        /// nil: never written (TS `readFileSync(fakeLog)` throws).
        let log = BackendF4Box<String?>(nil)
        let stdout = BackendF4Box(Data())
        let stderr = BackendF4Box(Data())
        let stdinReads = BackendF4Box(0)
        private func run(_ argv: [String], input: Data?, original: Data) -> (Int32, Data) {
            log.update { $0 = ($0 ?? "") + "REAL: \(argv.joined(separator: " "))\n" }
            if argv.first == "-i" {
                let fed = input ?? original
                log.update { $0 = ($0 ?? "") + String(decoding: fed, as: UTF8.self) }
                return (0, Data())
            }
            if argv.joined(separator: " ").contains("credentials") { return (0, Data((BackendF4ClaudeLogin("FROM-OLD-KEYCHAIN") + "\n").utf8)) }
            return (44, Data())
        }
        func io(stdin: String?) -> BackendAccountShimIO {
            let original = Data((stdin ?? "").utf8)
            return BackendAccountShimIO(
                stdinIsTerminal: { false },
                readStdin: { [self] in stdinReads.update { $0 += 1 }; return original },
                writeStdout: { [self] data in stdout.update { $0.append(data) } },
                writeStderr: { [self] data in stderr.update { $0.append(data) } },
                passThrough: { [self] argv, input in
                    let (code, out) = run(argv, input: input, original: original)
                    stdout.update { $0.append(out) }
                    return code
                },
                capture: { [self] argv, input in let (code, out) = run(argv, input: input, original: original); return (code, out) })
        }
    }
    struct ShimResult: Equatable { let code: Int32; let stdout: String; let stderr: String }

    final class SocketRig: @unchecked Sendable {
        let rig: Rig
        let broker: BackendAccountBroker
        let fake = FakeSecurity()
        let configuration: BackendAccountConfiguration
        init(rig: Rig, broker: BackendAccountBroker, configuration: BackendAccountConfiguration) { self.rig = rig; self.broker = broker; self.configuration = configuration }
        func vaultEnv(_ account: String) -> [String: String] {
            [configuration.socketEnvironment: broker.socketPath, configuration.ticketEnvironment: rig.tickets.ticketFor(account)]
        }
        /// TS `shim()`: one `security` call through the helper's client, in-process.
        func shim(_ args: [String], _ env: [String: String], _ input: String? = nil) async -> ShimResult {
            let fresh = FakeSecurity()
            let io = fresh.io(stdin: input)
            let arguments = broker.shimArguments + args
            let code = await Task.detached { BackendAccountSecurityShimClient.main(arguments: arguments, environment: env, io: io) }.value
            fake.log.update { log in if let more = fresh.log.value { log = (log ?? "") + more } }
            fake.stdinReads.update { $0 += fresh.stdinReads.value }
            return ShimResult(code: code, stdout: String(decoding: fresh.stdout.value, as: UTF8.self), stderr: String(decoding: fresh.stderr.value, as: UTF8.self))
        }
    }

    /// A data folder short enough for a unix socket path (104 bytes), with the
    /// broker listening on its real socket — offline: the helper is never run.
    private func withSocket(_ body: (SocketRig) async throws -> Void) async throws {
        var template = Array("/tmp/tdv-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw BackendAccountFailure("no temporary folder") }
        let root = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Terminal Deck Fixture", appID: "terminaldeck",
            helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: ["USER": "me"])
        let state = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .exclusive, clock: { 1_000 })
        let profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
        let vault = try BackendAccountVault(configuration: configuration, stateStore: state, vaultCipher: BackendF4FakeCipher())
        let rig = Rig(vault: vault)
        let realCalls = BackendF4Box(0)
        let broker = try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault,
            runner: { _, _ in realCalls.update { $0 += 1 }; return Answer(code: 44, stdout: "", stderr: "") }, deps: rig.deps)
        let socket = SocketRig(rig: rig, broker: broker, configuration: configuration)
        do { try await body(socket) } catch { await broker.close(); await vault.close(); await profiles.close(); await state.close(); throw error }
        await broker.close(); await vault.close(); await profiles.close(); await state.close()
        XCTAssertEqual(realCalls.value, 0, "the broker's own keychain runner is never used by the shim path")
    }

    // server.test.ts:308
    func testAnswersALookupFromTheVaultExactlyAsSecurityWPrintsIt() async throws {
        try await withSocket { s in
            await s.rig.put("one", BackendF4ClaudeLogin("ONE"))
            let out = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", Self.serviceOf("one")], s.vaultEnv("one"))
            XCTAssertEqual(out, ShimResult(code: 0, stdout: BackendF4ClaudeLogin("ONE") + "\n", stderr: ""))
        }
    }

    // server.test.ts:314
    func testSaysNotFoundWithExit44ForAnAccountWithNoLogin() async throws {
        try await withSocket { s in
            let out = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", Self.serviceOf("two")], s.vaultEnv("two"))
            XCTAssertEqual(out.code, 44)
            XCTAssertTrue(out.stderr.contains("could not be found in the keychain"))
        }
    }

    // server.test.ts:320
    func testKeepsASecurityIWriteWithoutTheTokenEverAppearingInAnArgument() async throws {
        try await withSocket { s in
            let login = BackendF4ClaudeLogin("WRITTEN")
            let out = await s.shim(["-i"], s.vaultEnv("one"), "add-generic-password -U -a \"me\" -s \"\(Self.serviceOf("one"))\" -X \"\(Self.hex(login))\"\n")
            XCTAssertEqual(out.code, 0)
            let value = await s.rig.read("one")
            XCTAssertEqual(value, login)
            // The real command was never involved.
            XCTAssertNil(s.fake.log.value)
        }
    }

    // server.test.ts:329
    func testHandsAnythingNotALoginToTheRealCommandArgvAndStdinUntouched() async throws {
        try await withSocket { s in
            let out = await s.shim(["find-identity", "-v", "-p", "codesigning"], s.vaultEnv("one"))
            XCTAssertEqual(out.code, 44)
            let stdin = "add-generic-password -U -a \"me\" -s \"Claude Code-device-keys\" -X \"00\"\n"
            _ = await s.shim(["-i"], s.vaultEnv("one"), stdin)
            let log = try XCTUnwrap(s.fake.log.value)
            XCTAssertTrue(log.contains("REAL: find-identity -v -p codesigning"))
            XCTAssertTrue(log.contains("REAL: -i"))
            XCTAssertTrue(log.contains("Claude Code-device-keys"))
        }
    }

    // server.test.ts:340
    func testWithoutATicketOrWithAnotherRunsVaultItIsTheRealCommandAndNothingElse() async throws {
        try await withSocket { s in
            await s.rig.put("one", BackendF4ClaudeLogin("ONE"))
            let noTicket = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials"], [:])
            XCTAssertTrue(noTicket.stdout.contains("FROM-OLD-KEYCHAIN"))
            let otherRun = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials"],
                [s.configuration.socketEnvironment: "/somewhere/else.sock", s.configuration.ticketEnvironment: s.rig.tickets.ticketFor("one")])
            XCTAssertTrue(otherRun.stdout.contains("FROM-OLD-KEYCHAIN"))
        }
    }

    // server.test.ts:351
    func testMovesAnOldAccountAcrossOnItsFirstLookupThroughTheRealCommandAndKeepsIt() async throws {
        try await withSocket { s in
            s.rig.adopting.update { $0.insert("one") }
            let out = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", Self.serviceOf("one")], s.vaultEnv("one"))
            XCTAssertEqual(out.code, 0)
            XCTAssertEqual(out.stdout, BackendF4ClaudeLogin("FROM-OLD-KEYCHAIN") + "\n")
            let value = await s.rig.read("one")
            XCTAssertEqual(value, BackendF4ClaudeLogin("FROM-OLD-KEYCHAIN"))
            XCTAssertTrue(s.rig.kept.value.contains("one"))
        }
    }

    // server.test.ts:365 (review finding 2): `security cms -D -i file` — whose
    // `-i` is an input file — must not wait on a stdin that never closes.
    func testDoesNotReadStdinForACommandWhoseIIsAnOrdinaryFlag() async throws {
        try await withSocket { s in
            _ = await s.shim(["cms", "-D", "-i", "profile.mobileprovision"], s.vaultEnv("one"))
            XCTAssertEqual(s.fake.stdinReads.value, 0)
            XCTAssertTrue(s.fake.log.value?.contains("REAL: cms -D -i profile.mobileprovision") == true)
        }
    }

    // server.test.ts:391 (review finding 10)
    func testFailsClosedForTheAPIKeySlotTooAndRefusesAWriteRatherThanCallingItNotFound() async throws {
        try await withSocket { s in
            let env = s.vaultEnv("one")
            await s.broker.close()
            let suffix = Self.suffixOf(Self.configDirs["one"] ?? "")
            let apiKey = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-\(suffix)"], env)
            XCTAssertEqual(apiKey.code, 44)
            let write = await s.shim(["-i"], env, "add-generic-password -U -a \"me\" -s \"\(Self.serviceOf("one"))\" -X \"\(Self.hex("x"))\"\n")
            XCTAssertEqual(write.code, 1)
            XCTAssertTrue(write.stderr.contains("nothing was changed"))
            XCTAssertNil(s.fake.log.value)
        }
    }

    // server.test.ts:404
    func testFailsClosedForALoginWhenTheAppIsNotAnsweringNeverTheItemAHashNames() async throws {
        try await withSocket { s in
            let env = s.vaultEnv("one")
            await s.broker.close()
            let out = await s.shim(["find-generic-password", "-a", "me", "-w", "-s", Self.serviceOf("one")], env)
            XCTAssertEqual(out.code, 44)
            XCTAssertNil(s.fake.log.value)
        }
    }

    // vault-profiles.test.ts:376 (review finding 9): a confined session's plan
    // grants a PATH entry called `bin` and its parent, so the shim lives in a
    // folder of its own, outside the vault folder, holding nothing else.
    func testKeepsTheShimInAFolderOfItsOwnOutsideTheVaultFolderAndNotCalledBin() async throws {
        try await withSocket { s in
            let shim = s.broker.shimDirectory
            XCTAssertFalse(shim.hasPrefix(s.configuration.dataDirectory.appendingPathComponent("account-vault").path + "/"))
            XCTAssertFalse(shim.hasSuffix("/bin"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shim), ["security"])
            // The script hands this run's socket to the helper; it names keys, never values.
            let script = try String(contentsOfFile: shim + "/security", encoding: .utf8)
            XCTAssertTrue(script.contains("vault:security 'TERMINALDECK_ACCOUNT_VAULT' 'TERMINALDECK_ACCOUNT_TICKET' 'TERMINALDECK_ACCOUNT_HOME' '--vault-socket=\(s.broker.socketPath)' \"$@\""))
        }
    }
}
