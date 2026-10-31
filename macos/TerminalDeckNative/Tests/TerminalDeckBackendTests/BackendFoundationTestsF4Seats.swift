import Foundation
import XCTest
import CryptoKit
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/account-vault/seats.test.ts: a session's seat at the vault —
/// the login it is handed can change while the process, and so the keychain
/// names it asks for, stays exactly as it was.
///
/// Native wire contract: TS sends a NUL-joined body (ticket, argc, argv, stdin;
/// server.ts:310 `readBody`); native sends the framed JSON object
/// `{ticket, argv, stdin}`. `body()` builds that object and reads it through the
/// production `BackendAccountVaultServer.readBody`, so every case runs the real
/// request path. The real `security` is a recorder; no keychain is reached.
final class BackendFoundationTestsF4Seats: XCTestCase, @unchecked Sendable {
    typealias Server = BackendAccountVaultServer
    typealias Answer = BackendAccountSwitchInPlace.KeychainAnswer
    typealias Source = BackendAccountSwitchInPlace.LoginSource
    static let slot = "keychain:Claude Code-credentials"
    static let dirs = ["a": "/cfg/a", "b": "/cfg/b", "c": "/cfg/c", "mine": "/Users/me/.claude-work"]

    struct Ran: Equatable, Sendable { let argv: [String]; let stdin: String? }

    /// seats.test.ts:44 `beforeEach`.
    final class Rig: @unchecked Sendable {
        let vault: BackendAccountVault
        let tickets = BackendAccountTicketBook()
        let sources = BackendF4Box<[String: Source?]>([
            "a": .vault, "b": .vault, "c": .vault,
            "system": .keychain(directory: nil), "mine": .keychain(directory: BackendFoundationTestsF4Seats.dirs["mine"]),
        ])
        let adopting = BackendF4Box<Set<String>>([])
        let ran = BackendF4Box<[Ran]>([])
        let keychainAnswer = BackendF4Box<Answer>(Answer(code: 0, stdout: "FROM-KEYCHAIN\n", stderr: ""))
        var deps: Server.Deps
        init(vault: BackendAccountVault) {
            self.vault = vault
            let providers: [String: String] = ["a": "claude", "b": "claude", "c": "claude", "system": "claude", "mine": "claude"]
            let sources = sources, adopting = adopting, ran = ran, keychainAnswer = keychainAnswer
            deps = Server.Deps(
                vault: vault, tickets: tickets,
                providerOf: { providers[$0] },
                configDirOf: { BackendFoundationTestsF4Seats.dirs[$0] },
                adopting: { id, _ in adopting.value.contains(id) },
                markKept: { id, _ in adopting.update { $0.remove(id) } },
                sourceOf: { id in sources.value[id] ?? nil },
                runReal: { argv, stdin in
                    ran.update { $0.append(Ran(argv: argv, stdin: stdin)) }
                    return keychainAnswer.value
                })
        }
        func answer(_ request: Server.Request?) async -> Server.WireAnswer { await Server.answerShim(request, deps: deps) }
        func run(_ wire: Server.WireAnswer, file: StaticString = #filePath, line: UInt = #line) async throws -> Answer {
            guard case .steps(let ticket, let steps) = wire else { XCTFail("expected steps, got \(wire)", file: file, line: line); throw BackendAccountFailure("not steps") }
            return await Server.runSteps(ticket: ticket, steps: steps, deps: deps, user: "me")
        }
        /// A seat for a session started as `launch` in its own folder (TS `seated`). `dir: .some(nil)` is TS `null`.
        func seated(_ session: String = "s1", _ launch: String = "a", dir: String?? = .none) -> String {
            let launchDir: String? = dir ?? BackendFoundationTestsF4Seats.dirs[launch]
            let ticket = tickets.seat(launch: launch, launchDir: launchDir)
            tickets.bind(ticket, sessionID: session)
            return ticket
        }
    }

    static func hex(_ text: String) -> String { Data(text.utf8).map { String(format: "%02x", $0) }.joined() }
    static func suffixOf(_ dir: String) -> String { SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description }
    /// The service a process started with this config directory asks for. `nil`: the machine's own install.
    static func serviceIn(_ dir: String?) -> String { dir.map { "Claude Code-credentials-\(suffixOf($0))" } ?? "Claude Code-credentials" }
    static func body(_ ticket: String, _ argv: [String], _ stdin: String = "") -> Server.Request? {
        Server.readBody(.object([.init("ticket", .string(ticket)), .init("argv", .array(argv.map(NativeRPCValue.string))), .init("stdin", .string(stdin))]))
    }
    static func find(_ ticket: String, _ dir: String?) -> Server.Request? { body(ticket, ["find-generic-password", "-a", "me", "-w", "-s", serviceIn(dir)]) }
    static func add(_ ticket: String, _ dir: String?, _ value: String) -> Server.Request? {
        body(ticket, ["-i"], "add-generic-password -U -a \"me\" -s \"\(serviceIn(dir))\" -X \"\(hex(value))\"\n")
    }
    static func exitAnswer(_ wire: Server.WireAnswer) -> Answer? { if case .exit(let answer) = wire { answer } else { nil } }
    static let notFound = Answer(code: 44, stdout: "", stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.")

    private func withRig(_ body: (Rig) async throws -> Void) async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let vault = try BackendF4Vault(f)
            let rig = Rig(vault: vault)
            _ = await vault.write(accountID: "a", provider: "claude", slot: Self.slot, value: BackendF4ClaudeLogin("A"), source: "sign-in")
            _ = await vault.write(accountID: "b", provider: "claude", slot: Self.slot, value: BackendF4ClaudeLogin("B"), source: "sign-in")
            do { try await body(rig); await vault.close() } catch { await vault.close(); throw error }
        }
    }

    // MARK: a seat: one process, its login changeable in place

    // seats.test.ts:94
    func testAnsweredAsLaunchThenAsSwitchedAccountSameTicketSameNames() async throws {
        try await withRig { r in
            let ticket = r.seated()
            let first = Self.exitAnswer(await r.answer(Self.find(ticket, Self.dirs["a"])))
            XCTAssertEqual(first?.code, 0); XCTAssertEqual(first?.stdout, BackendF4ClaudeLogin("A"))
            XCTAssertTrue(r.tickets.retarget("s1", to: "b"))
            // The process still asks under its own folder's name; it is handed b's login.
            let second = Self.exitAnswer(await r.answer(Self.find(ticket, Self.dirs["a"])))
            XCTAssertEqual(second?.code, 0); XCTAssertEqual(second?.stdout, BackendF4ClaudeLogin("B"))
        }
    }

    // seats.test.ts:102
    func testSwitchingOneSessionChangesNothingForAnotherOnTheSameAccount() async throws {
        try await withRig { r in
            let one = r.seated("s1"), two = r.seated("s2")
            r.tickets.retarget("s1", to: "b")
            let w1 = await r.answer(Self.find(one, Self.dirs["a"]))
            XCTAssertEqual(Self.exitAnswer(w1)?.stdout, BackendF4ClaudeLogin("B"))
            let w2 = await r.answer(Self.find(two, Self.dirs["a"]))
            XCTAssertEqual(Self.exitAnswer(w2)?.stdout, BackendF4ClaudeLogin("A"))
        }
    }

    // seats.test.ts:110
    func testNestedAgentWithItsOwnFolderHoldingTheTicketGoesToTheRealCommand() async throws {
        try await withRig { r in
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "b")
            let w3 = await r.answer(Self.find(ticket, "/somewhere/else"))
            XCTAssertEqual(w3, .pass)
        }
    }

    // seats.test.ts:116
    func testRefreshWrittenAfterSwitchBeforeRereadLandsInTheAccountItRefreshed() async throws {
        try await withRig { r in
            let ticket = r.seated()
            _ = await r.answer(Self.find(ticket, Self.dirs["a"])) // the agent holds a's login
            r.tickets.retarget("s1", to: "b")
            // a's refresh, already under way when the switch happened, comes back:
            _ = await r.answer(Self.add(ticket, Self.dirs["a"], BackendF4ClaudeLogin("A-REFRESHED")))
            let a = await r.vault.readSlot("a", slot: Self.slot), b = await r.vault.readSlot("b", slot: Self.slot)
            XCTAssertEqual(a, BackendF4ClaudeLogin("A-REFRESHED"))
            XCTAssertEqual(b, BackendF4ClaudeLogin("B"))
        }
    }

    // seats.test.ts:126
    func testOnceTheNewLoginIsReadItsRefreshLandsInTheNewAccount() async throws {
        try await withRig { r in
            let ticket = r.seated()
            _ = await r.answer(Self.find(ticket, Self.dirs["a"]))
            r.tickets.retarget("s1", to: "b")
            _ = await r.answer(Self.find(ticket, Self.dirs["a"])) // the compare-and-swap read: b's login
            _ = await r.answer(Self.add(ticket, Self.dirs["a"], BackendF4ClaudeLogin("B-REFRESHED")))
            let a = await r.vault.readSlot("a", slot: Self.slot), b = await r.vault.readSlot("b", slot: Self.slot)
            XCTAssertEqual(b, BackendF4ClaudeLogin("B-REFRESHED"))
            XCTAssertEqual(a, BackendF4ClaudeLogin("A"))
        }
    }

    // seats.test.ts:136
    func testSaysWhenASwitchedSeatIsFirstHandedTheNewLogin() async throws {
        try await withRig { r in
            let heard = BackendF4Box<[BackendAccountSeatServed]>([])
            r.deps.onServed = { event in heard.update { $0.append(event) } }
            let ticket = r.seated()
            _ = await r.answer(Self.find(ticket, Self.dirs["a"]))
            r.tickets.retarget("s1", to: "b")
            _ = await r.answer(Self.find(ticket, Self.dirs["a"]))
            _ = await r.answer(Self.find(ticket, Self.dirs["a"]))
            XCTAssertEqual(heard.value, [BackendAccountSeatServed(sessionID: "s1", accountID: "b")])
        }
    }

    // seats.test.ts:147
    func testSeatServingADeletedAccountAnswersNotFoundNeverAnotherLogin() async throws {
        try await withRig { r in
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "b")
            r.tickets.revoke("b")
            let w4 = await r.answer(Self.find(ticket, Self.dirs["a"]))
            XCTAssertEqual(w4, .exit(Self.notFound))
        }
    }

    // seats.test.ts:157
    func testIsForgottenWhenItsSessionEnds() async throws {
        try await withRig { r in
            let ticket = r.seated()
            r.tickets.release("s1")
            XCTAssertNil(r.tickets.sessionSeat("s1"))
            let w5 = await r.answer(Self.find(ticket, Self.dirs["a"]))
            XCTAssertEqual(Self.exitAnswer(w5)?.code, 44)
        }
    }

    // MARK: a seat started on a login the agent keeps itself

    // seats.test.ts:166
    func testAgentKeptSeatPassesEveryLookupUntilSwitched() async throws {
        try await withRig { r in
            let ticket = r.seated("s1", "system", dir: .some(nil))
            let w6 = await r.answer(Self.find(ticket, nil))
            XCTAssertEqual(w6, .pass)
            let w7 = await r.answer(Self.add(ticket, nil, BackendF4ClaudeLogin("MINE")))
            XCTAssertEqual(w7, .pass)
            let held = await r.vault.has("system")
            XCTAssertFalse(held)
        }
    }

    // seats.test.ts:173
    func testAgentKeptSeatSwitchedToAnAppKeptAccountIsAnsweredFromTheVault() async throws {
        try await withRig { r in
            let ticket = r.seated("s1", "system", dir: .some(nil))
            r.tickets.retarget("s1", to: "b")
            let answer = Self.exitAnswer(await r.answer(Self.find(ticket, nil)))
            XCTAssertEqual(answer?.code, 0); XCTAssertEqual(answer?.stdout, BackendF4ClaudeLogin("B"))
        }
    }

    // seats.test.ts:179
    func testSwitchedBackItsOwnLoginIsTheRealItemAgainNotCopiedIn() async throws {
        try await withRig { r in
            let ticket = r.seated("s1", "system", dir: .some(nil))
            r.tickets.retarget("s1", to: "b")
            _ = await r.answer(Self.find(ticket, nil))
            r.tickets.retarget("s1", to: "system")
            _ = await r.answer(Self.find(ticket, nil)) // reads its own item: pass
            let w8 = await r.answer(Self.find(ticket, nil))
            XCTAssertEqual(w8, .pass)
            let held = await r.vault.has("system")
            XCTAssertFalse(held)
        }
    }

    // MARK: a seat switched onto a login the agent keeps

    // seats.test.ts:191
    func testSwitchedOntoAgentKeptLoginReadsItsOwnItemUnderItsOwnName() async throws {
        try await withRig { r in
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "system")
            let answer = await r.answer(Self.find(ticket, Self.dirs["a"]))
            guard case .steps = answer else { return XCTFail("expected steps, got \(answer)") }
            let ranAnswer = try await r.run(answer)
            XCTAssertEqual(r.ran.value, [Ran(argv: ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials"], stdin: nil)])
            XCTAssertEqual(ranAnswer, Answer(code: 0, stdout: "FROM-KEYCHAIN", stderr: ""))
        }
    }

    // seats.test.ts:202
    func testAFolderThePersonChoseIsReadUnderThatFoldersHash() async throws {
        try await withRig { r in
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "mine")
            _ = try await r.run(await r.answer(Self.find(ticket, Self.dirs["a"])))
            XCTAssertEqual(r.ran.value.first?.argv.last, Self.serviceIn(Self.dirs["mine"]))
        }
    }

    // seats.test.ts:211
    func testRefreshWrittenBackGoesToThatItemOverStdinNeverOnACommandLine() async throws {
        try await withRig { r in
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "system")
            _ = try await r.run(await r.answer(Self.find(ticket, Self.dirs["a"])))
            _ = try await r.run(await r.answer(Self.add(ticket, Self.dirs["a"], BackendF4ClaudeLogin("SYS-REFRESHED"))))
            let last = r.ran.value.last
            XCTAssertEqual(last?.argv, ["-i"])
            XCTAssertEqual(last?.stdin, "add-generic-password -U -a \"me\" -s \"Claude Code-credentials\" -X \"\(Self.hex(BackendF4ClaudeLogin("SYS-REFRESHED")))\"\n")
            XCTAssertTrue(r.ran.value.allSatisfy { !$0.argv.joined(separator: " ").contains("SYS-REFRESHED") })
            let a = await r.vault.readSlot("a", slot: Self.slot)
            XCTAssertEqual(a, BackendF4ClaudeLogin("A"))
        }
    }

    // seats.test.ts:229
    func testPreVaultAccountIsMovedInFromItsOwnItemOnFirstUseThenAnsweredFromTheVault() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("c") }
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "c")
            r.keychainAnswer.value = Answer(code: 0, stdout: BackendF4ClaudeLogin("C") + "\n", stderr: "")
            let ran = try await r.run(await r.answer(Self.find(ticket, Self.dirs["a"])))
            XCTAssertEqual(ran.code, 0); XCTAssertEqual(ran.stdout, BackendF4ClaudeLogin("C"))
            XCTAssertEqual(r.ran.value.first?.argv.last, Self.serviceIn(Self.dirs["c"]))
            let c = await r.vault.readSlot("c", slot: Self.slot)
            XCTAssertEqual(c, BackendF4ClaudeLogin("C"))
            // Settled: the next lookup never touches the keychain.
            let w9 = await r.answer(Self.find(ticket, Self.dirs["a"]))
            XCTAssertEqual(Self.exitAnswer(w9)?.stdout, BackendF4ClaudeLogin("C"))
        }
    }

    // seats.test.ts:243
    func testAccountWhoseLoginIsOutOfReachIsNotFoundNeverTheFoldersItem() async throws {
        try await withRig { r in
            r.sources.update { $0["b"] = .some(nil) }
            let ticket = r.seated()
            r.tickets.retarget("s1", to: "b")
            let w10 = await r.answer(Self.find(ticket, Self.dirs["a"]))
            XCTAssertEqual(Self.exitAnswer(w10)?.code, 44)
            XCTAssertTrue(r.ran.value.isEmpty)
        }
    }

    // MARK: a seat whose credential folder is the app's own

    static let store = "/app/data/account-vault/store/system"

    // seats.test.ts:260
    func testMachinesOwnLoginIsReadFromItsRealItemNamesRewrittenNeverPassed() async throws {
        try await withRig { r in
            let ticket = r.tickets.seat(launch: "system", launchDir: Self.store, serving: "system", storeDir: Self.store)
            r.tickets.bind(ticket, sessionID: "s1")
            let answer = await r.answer(Self.find(ticket, Self.store))
            guard case .steps = answer else { return XCTFail("expected steps, got \(answer)") }
            _ = try await r.run(answer)
            XCTAssertEqual(r.ran.value, [Ran(argv: ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials"], stdin: nil)])
        }
    }

    // seats.test.ts:270
    func testItsSignInOrRefreshIsWrittenToTheRealItemOverStdin() async throws {
        try await withRig { r in
            let ticket = r.tickets.seat(launch: "system", launchDir: Self.store, serving: "system", storeDir: Self.store)
            r.tickets.bind(ticket, sessionID: "s1")
            _ = try await r.run(await r.answer(Self.find(ticket, Self.store)))
            _ = try await r.run(await r.answer(Self.add(ticket, Self.store, BackendF4ClaudeLogin("SYS-NEW"))))
            XCTAssertTrue(r.ran.value.last?.stdin?.contains("-s \"Claude Code-credentials\" -X") == true)
        }
    }

    // seats.test.ts:282
    func testAppFolderSeatSwitchedToAnAppKeptAccountIsAnsweredFromTheVault() async throws {
        try await withRig { r in
            let ticket = r.tickets.seat(launch: "system", launchDir: Self.store, serving: "system", storeDir: Self.store)
            r.tickets.bind(ticket, sessionID: "s1")
            r.tickets.retarget("s1", to: "b")
            let w11 = await r.answer(Self.find(ticket, Self.store))
            XCTAssertEqual(Self.exitAnswer(w11)?.stdout, BackendF4ClaudeLogin("B"))
        }
    }

    // seats.test.ts:289
    func testPreVaultAccountStartedInAppFolderIsMovedInNotCapturedUnderTheWrongName() async throws {
        try await withRig { r in
            r.adopting.update { $0.insert("c") }
            let own = "/app/data/account-vault/store/c"
            let ticket = r.tickets.seat(launch: "c", launchDir: own, serving: "c", storeDir: own)
            r.tickets.bind(ticket, sessionID: "s1")
            r.keychainAnswer.value = Answer(code: 0, stdout: BackendF4ClaudeLogin("C") + "\n", stderr: "")
            let answer = await r.answer(Self.find(ticket, own))
            guard case .steps = answer else { return XCTFail("expected steps, got \(answer)") }
            let ran = try await r.run(answer)
            XCTAssertEqual(ran.code, 0); XCTAssertEqual(ran.stdout, BackendF4ClaudeLogin("C"))
            XCTAssertEqual(r.ran.value.first?.argv.last, Self.serviceIn(Self.dirs["c"]))
            let c = await r.vault.readSlot("c", slot: Self.slot)
            XCTAssertEqual(c, BackendF4ClaudeLogin("C"))
        }
    }
}
