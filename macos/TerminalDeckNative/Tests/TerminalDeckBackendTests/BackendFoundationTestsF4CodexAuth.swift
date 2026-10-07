import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// codex-auth.test.ts `codexLogin()`: `auth.json` in the shape Codex writes it, as JSON.stringify prints it. Fake values only.
private func codexLogin(_ token: String) -> String {
    "{\"OPENAI_API_KEY\":null,\"tokens\":{\"access_token\":\"at-\(token)\",\"refresh_token\":\"rt-\(token)\"}}"
}

/// codex-auth.test.ts `fire` + `watch` + `settleWatch()`: watcher events fired by hand and a debounce
/// that runs when the test says, so nothing waits on the filesystem's timing.
private final class BackendF4CodexWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable () async -> Void] = [:]
    private var pending: [(id: Int, fire: @Sendable () async -> Void)] = []
    private var counter = 0

    var watch: BackendAccountCodexLease.DirWatch {
        { [self] directory, onEvent in
            lock.withLock { handlers[directory] = onEvent }
            return { [self] in lock.withLock { _ = handlers.removeValue(forKey: directory) } }
        }
    }
    var schedule: BackendAccountCodexLease.Debounce {
        { [self] _, fire in
            let id: Int = lock.withLock { counter += 1; pending.append((counter, fire)); return counter }
            return { [self] in lock.withLock { pending.removeAll { $0.id == id } } }
        }
    }
    func watching(_ directory: String) -> Bool { lock.withLock { handlers[directory] != nil } }
    /// Fire the watcher and let the debounce run.
    func settle(_ directory: String) async {
        let handler = lock.withLock { handlers[directory] }
        await handler?()
        let due = lock.withLock { () -> [@Sendable () async -> Void] in let due = pending.map(\.fire); pending.removeAll(); return due }
        for fire in due { await fire() }
    }
}

final class BackendFoundationTestsF4CodexAuth: XCTestCase {
    /// beforeEach/afterEach: a temp root, a vault on a fake cipher, a hand-driven watcher.
    private func withVault(cipher: BackendF4FakeCipher = BackendF4FakeCipher(),
                           _ body: (BackendFoundationTestsAccountsFixture, BackendAccountVault, BackendF4CodexWatch) async throws -> Void) async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let vault = try BackendF4Vault(f, cipher: cipher)
            do { try await body(f, vault, BackendF4CodexWatch()) } catch { await vault.close(); throw error }
            await vault.close()
        }
    }

    /// codex-auth.test.ts `account()`: its own directory under the temp root.
    private func account(_ f: BackendFoundationTestsAccountsFixture, _ id: String) throws -> BackendAccountProfile {
        let profile = f.profile(id, provider: "codex")
        try FileManager.default.createDirectory(atPath: profile.configDir, withIntermediateDirectories: true)
        return profile
    }
    private func authPath(_ profile: BackendAccountProfile) -> String { profile.configDir + "/auth.json" }
    private func writeAuth(_ profile: BackendAccountProfile, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: authPath(profile))) }

    /// `inUse: () => <value>`; nil stands for a keeper the TS test builds without one — it must never be asked,
    /// and is never answered from the real process table.
    private func keeper(_ vault: BackendAccountVault, _ watch: BackendF4CodexWatch, inUse: Bool?, debounceMs: Int = 250,
                        file: StaticString = #filePath, line: UInt = #line) -> BackendAccountCodexLease {
        BackendAccountCodexLease(vault: vault, inUse: { _ in
            guard let inUse else { XCTFail("the foreign-use check was asked by a keeper the TS test builds without one", file: file, line: line); return true }
            return inUse
        }, watch: watch.watch, debounceMs: debounceMs, schedule: watch.schedule)
    }

    private func put(_ vault: BackendAccountVault, _ id: String, _ value: String) async {
        let written = await vault.write(accountID: id, provider: "codex", slot: BackendAccountCodexLease.authSlot, value: value, source: "sign-in")
        XCTAssertTrue(written.ok, written.message)
    }
    private func kept(_ vault: BackendAccountVault, _ id: String) async -> String? { await vault.readSlot(id, slot: BackendAccountCodexLease.authSlot) }

    // codex-auth.test.ts:47
    func testMovesAnExistingLoginIntoTheVaultTheFirstTimeItIsSeen() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            try writeAuth(work, codexLogin("EXISTING"))
            let keeper = self.keeper(vault, watch, inUse: false, debounceMs: 0)
            let settled = try await keeper.settle(work)
            XCTAssertEqual(settled, .kept)
            XCTAssertEqual(settled.rawValue, "kept")
            let value = await kept(vault, "work")
            XCTAssertEqual(value, codexLogin("EXISTING"))
            let summary = await vault.summary("work")
            XCTAssertEqual(summary?.lastSource, "adopted")
        }
    }

    // codex-auth.test.ts:56
    func testPutsAKeptLoginBackWhereCodexReadsItOwnerOnly() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            await put(vault, "work", codexLogin("KEPT"))
            let keeper = self.keeper(vault, watch, inUse: false, debounceMs: 0)
            let settled = try await keeper.settle(work)
            XCTAssertEqual(settled, .placed)
            XCTAssertEqual(settled.rawValue, "placed")
            XCTAssertEqual(try String(contentsOfFile: authPath(work), encoding: .utf8), codexLogin("KEPT"))
            var info = stat()
            XCTAssertEqual(stat(authPath(work), &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
        }
    }

    // codex-auth.test.ts:66
    func testCapturesTheSignInAndEveryRefreshCodexWritesBack() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            let keeper = self.keeper(vault, watch, inUse: false, debounceMs: 0)
            try await keeper.settle(work)
            try writeAuth(work, codexLogin("SIGNED-IN"))
            await watch.settle(work.configDir)
            var value = await kept(vault, "work")
            XCTAssertEqual(value, codexLogin("SIGNED-IN"))
            try writeAuth(work, codexLogin("REFRESHED"))
            await watch.settle(work.configDir)
            value = await kept(vault, "work")
            XCTAssertEqual(value, codexLogin("REFRESHED"))
            let summary = await vault.summary("work")
            XCTAssertEqual(summary?.lastSource, "refresh")
        }
    }

    // codex-auth.test.ts:79
    func testIgnoresAHalfWrittenFileRatherThanKeepingIt() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            let keeper = self.keeper(vault, watch, inUse: false, debounceMs: 0)
            try await keeper.settle(work)
            try writeAuth(work, codexLogin("GOOD"))
            await watch.settle(work.configDir)
            try writeAuth(work, "{\"tokens\": {\"acc")
            await watch.settle(work.configDir)
            let value = await kept(vault, "work")
            XCTAssertEqual(value, codexLogin("GOOD"))
        }
    }

    // codex-auth.test.ts:90
    func testTreatsCodexRemovingItsOwnFileAsASignOut() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            await put(vault, "work", codexLogin("A"))
            let keeper = self.keeper(vault, watch, inUse: false, debounceMs: 0)
            try await keeper.settle(work)
            try FileManager.default.removeItem(atPath: authPath(work))
            await watch.settle(work.configDir)
            let has = await vault.has("work")
            XCTAssertFalse(has)
        }
    }

    // codex-auth.test.ts:100
    func testAtQuitKeepsTheNewestCopyAndLeavesNoPlaintextLoginOnDisk() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            let keeper = self.keeper(vault, watch, inUse: false, debounceMs: 0)
            try await keeper.settle(work)
            // Codex refreshed a moment before quit, before the watcher's tick.
            try writeAuth(work, codexLogin("LAST-MINUTE"))
            let released = await keeper.release(work)
            XCTAssertEqual(released, .removed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: authPath(work)))
            let value = await kept(vault, "work")
            XCTAssertEqual(value, codexLogin("LAST-MINUTE"))
            // And the next launch puts it back.
            let next = try await self.keeper(vault, BackendF4CodexWatch(), inUse: nil).settle(work)
            XCTAssertEqual(next, .placed)
        }
    }

    // codex-auth.test.ts:113
    func testEachAccountHasItsOwnFileSoTwoCodexLoginsRunSideBySide() async throws {
        try await withVault { f, vault, watch in
            let one = try account(f, "one"), two = try account(f, "two")
            await put(vault, "one", codexLogin("ONE"))
            await put(vault, "two", codexLogin("TWO"))
            let keeper = self.keeper(vault, watch, inUse: nil)
            try await keeper.settle(one)
            try await keeper.settle(two)
            XCTAssertEqual(BackendAccountCodexLease.readAuthFile(authPath(one)), codexLogin("ONE"))
            XCTAssertEqual(BackendAccountCodexLease.readAuthFile(authPath(two)), codexLogin("TWO"))
            let following = await keeper.following()
            XCTAssertEqual(following.sorted(), ["one", "two"])
        }
    }

    // codex-auth.test.ts:126
    func testForgettingAnAccountRemovesItsFileAndStopsFollowingIt() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            await put(vault, "work", codexLogin("A"))
            let keeper = self.keeper(vault, watch, inUse: nil)
            try await keeper.settle(work)
            try await keeper.forget(work)
            XCTAssertFalse(FileManager.default.fileExists(atPath: authPath(work)))
            let following = await keeper.following()
            XCTAssertEqual(following, [])
            XCTAssertFalse(watch.watching(work.configDir), "the watcher is stopped too")
        }
    }

    // codex-auth.test.ts:136
    func testNeverTakesAwayAFileItCouldNotKeep() async throws {
        try await withVault(cipher: BackendF4FakeCipher(available: false)) { f, noStore, watch in
            let work = try account(f, "work")
            try writeAuth(work, codexLogin("ONLY-COPY"))
            let keeper = self.keeper(noStore, watch, inUse: false)
            try await keeper.settle(work)
            _ = await keeper.release(work)
            XCTAssertEqual(BackendAccountCodexLease.readAuthFile(authPath(work)), codexLogin("ONLY-COPY"))
        }
    }

    // codex-auth.test.ts:151 — review finding 5: never sign out a Codex something else runs on that folder.
    func testLeavesTheFileWhereItIsWhenSomethingOutsideTheAppIsRunningCodexOnThatFolder() async throws {
        try await withVault { f, vault, watch in
            let work = try account(f, "work")
            let keeper = self.keeper(vault, watch, inUse: true, debounceMs: 0)
            try writeAuth(work, codexLogin("SHARED"))
            try await keeper.settle(work)
            let released = await keeper.release(work)
            XCTAssertEqual(released, .retainedForForeignProcess)
            XCTAssertEqual(BackendAccountCodexLease.readAuthFile(authPath(work)), codexLogin("SHARED"))
            let value = await kept(vault, "work")
            XCTAssertEqual(value, codexLogin("SHARED"))
        }
    }

    // MARK: - who else is running Codex on a folder (codex-auth.test.ts:162)

    private let dir = "/Users/x/Library/Application Support/terminaldeck/profiles/work"
    private func row(_ pid: Int, _ ppid: Int, _ env: String) -> String { "\(pid) \(ppid) codex PATH=/usr/bin \(env)" }

    // codex-auth.test.ts:166
    func testCountsAProcessOutsideThisAppWithExactlyThatCodexHome() {
        XCTAssertTrue(BackendAccountForeignCodexUse.codexHomeInUse(listing: row(500, 1, "CODEX_HOME=\(dir) TERM=xterm"), directory: dir, ownPID: 100))
        XCTAssertTrue(BackendAccountForeignCodexUse.codexHomeInUse(listing: row(500, 1, "TERM=xterm CODEX_HOME=\(dir)"), directory: dir, ownPID: 100))
    }

    // codex-auth.test.ts:171
    func testDoesNotCountThisAppsOwnSessionsWhichAreBeingStopped() {
        let listing = ["101 100 node-pty-helper", row(500, 101, "CODEX_HOME=\(dir)")].joined(separator: "\n")
        XCTAssertFalse(BackendAccountForeignCodexUse.codexHomeInUse(listing: listing, directory: dir, ownPID: 100))
    }

    // codex-auth.test.ts:176
    func testDoesNotMistakeASiblingFolderWhoseNameStartsTheSameWay() {
        XCTAssertFalse(BackendAccountForeignCodexUse.codexHomeInUse(listing: row(500, 1, "CODEX_HOME=\(dir)-2 TERM=xterm"), directory: dir, ownPID: 100))
        XCTAssertFalse(BackendAccountForeignCodexUse.codexHomeInUse(listing: row(500, 1, "TERM=xterm"), directory: dir, ownPID: 100))
    }

    // codex-auth.ts:117 `codexHomeInUseNow`: when the process table cannot be read, the answer is "in use".
    // The listing comes from the injected runner, never from /bin/ps.
    func testAFailedProcessListingCountsAsInUse() async {
        let failed = await BackendAccountForeignCodexUse.inUse(dir, processList: { nil }, ownPID: 100)
        XCTAssertTrue(failed)
        let rows = row(500, 1, "CODEX_HOME=\(dir)")
        let foreign = await BackendAccountForeignCodexUse.inUse(dir, processList: { rows }, ownPID: 100)
        XCTAssertTrue(foreign)
        let child = "500 100 codex CODEX_HOME=\(dir)"
        let ours = await BackendAccountForeignCodexUse.inUse(dir, processList: { child }, ownPID: 100)
        XCTAssertFalse(ours)
    }

    // codex-auth.ts:68 `defaultWatch` (fs.watch reports a file rewritten in place, as Codex rewrites
    // auth.json): the real watcher must see an in-place rewrite, not only the file appearing or going.
    // Temp folder and synthetic text only.
    func testTheRealWatcherSeesAnInPlaceRewrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-f4-codex-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("auth.json")
        try Data(codexLogin("BEFORE").utf8).write(to: file)
        let seen = expectation(description: "an event for the in-place rewrite")
        seen.assertForOverFulfill = false
        let stop = BackendAccountCodexLease.realWatch(folder.path) { seen.fulfill() }
        defer { stop() }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(codexLogin("AFTER").utf8))
        try handle.close()
        wait(for: [seen], timeout: 10)
    }
}
