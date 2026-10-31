import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsStoreTests: XCTestCase, @unchecked Sendable {
    func testLostAcquireResponseReleasesItsOwnerAndAllowsRetry() async throws {
        let fake = BackendAppsStoreFake(mode: .loseAcquireResponse)
        let store = BackendAppsStore(runtime: await fake.runtime())
        do { _ = try await store.withLock("fixture", "demo") { await fake.body(); return "unexpected" }; XCTFail("Lost response succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        var state = await fake.snapshot()
        XCTAssertEqual(state.bodyCalls, 0)
        XCTAssertTrue(state.owners.isEmpty)
        XCTAssertEqual(state.releases.filter(\.matched).count, 1)
        let result = try await store.withLock("fixture", "demo") { await fake.body(); return "done" }
        state = await fake.snapshot()
        XCTAssertEqual(result, "done")
        XCTAssertEqual(state.bodyCalls, 1)
        XCTAssertTrue(state.owners.isEmpty)
    }

    func testCancelledAcquireAfterOwnerWriteGetsIndependentAuthorizedCleanup() async throws {
        let fake = BackendAppsStoreFake(mode: .pauseAcquisition)
        let store = BackendAppsStore(runtime: await fake.runtime(requireContext: true))
        let operation = BackendAppsStoreFakeCallContext.$owner.withValue("approved-fixture") {
            Task { try await store.withLock("fixture", "demo") { await fake.body(); return "unexpected" } }
        }
        let finished = Task { _ = await operation.result; await fake.operationFinished() }
        guard await fake.waitForAcquisition() else {
            XCTFail("Acquisition ended before the fake wrote its owner")
            await finished.value
            return
        }
        operation.cancel()
        await fake.cancelPausedAcquisition()
        do { _ = try await operation.value; XCTFail("Cancelled acquisition succeeded") }
        catch is CancellationError { }
        await finished.value
        let state = await fake.snapshot()
        XCTAssertEqual(state.bodyCalls, 0)
        XCTAssertTrue(state.owners.isEmpty)
        XCTAssertEqual(state.releases.filter(\.matched).count, 1)
        XCTAssertEqual(state.releases.last?.authority, "approved-fixture")
        XCTAssertEqual(state.releases.last?.cancelled, false)
        // This proves injected callback behavior only. DKA separately verifies
        // its native cancellation ticket and approved transport integration.
    }

    func testExistingDifferentOwnerLockIsNeverDeleted() async throws {
        let fake = BackendAppsStoreFake()
        let path = BackendAppsStore.root + "/demo/.lock"
        await fake.putOwner("other-mac-owner", at: path)
        let store = BackendAppsStore(runtime: await fake.runtime())
        do { _ = try await store.withLock("fixture", "demo") { await fake.body(); return true }; XCTFail("Another owner's lock was acquired") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "busy") }
        let state = await fake.snapshot()
        XCTAssertEqual(state.owners[path], "other-mac-owner")
        XCTAssertEqual(state.bodyCalls, 0)
        XCTAssertTrue(state.releases.allSatisfy { !$0.matched })
    }

    func testTruncatedAcquireResponseDoesNotRunBodyOrStrandLock() async throws {
        let fake = BackendAppsStoreFake(mode: .truncateAcquireResponse)
        let store = BackendAppsStore(runtime: await fake.runtime())
        do { _ = try await store.withLock("fixture", "demo") { await fake.body(); return true }; XCTFail("Truncated acquisition succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-failed") }
        let state = await fake.snapshot()
        XCTAssertEqual(state.bodyCalls, 0)
        XCTAssertTrue(state.owners.isEmpty)
        XCTAssertEqual(state.releases.filter(\.matched).count, 1)
    }

    func testArchiveRetargetsReleaseToMovedLockAndSameOwner() async throws {
        let fake = BackendAppsStoreFake()
        let root = "/var/lib/td-test-apps", app = "td-test-demo"
        let original = root + "/" + app
        await fake.putFile(Data("saved-state".utf8), at: original + "/state.json")
        let store = BackendAppsStore(runtime: await fake.runtime(root: root, prefix: "td-test"))
        try await store.withLock("fixture", app) { try await store.archiveLocked("fixture", app) }
        let state = await fake.snapshot()
        let archive = try XCTUnwrap(state.archives.last)
        XCTAssertTrue(archive.hasPrefix(root + "/td-test-removed-"))
        XCTAssertEqual(state.files[archive + "/.archived-state.json"], Data("saved-state".utf8))
        XCTAssertNil(state.files[original + "/state.json"])
        XCTAssertTrue(state.owners.isEmpty)
        XCTAssertEqual(state.releases.last?.path, archive + "/.lock")
        XCTAssertEqual(state.releases.last?.token, state.acquiredTokens.last)
        XCTAssertEqual(state.releases.last?.matched, true)
        XCTAssertEqual(try store.directory(app), original)
    }

    func testFailedArchiveMoveRestoresStateAndReleasesOriginalLock() async throws {
        let fake = BackendAppsStoreFake(failArchiveMove: true)
        let original = BackendAppsStore.root + "/demo"
        await fake.putFile(Data("saved-state".utf8), at: original + "/state.json")
        let store = BackendAppsStore(runtime: await fake.runtime())
        do { try await store.withLock("fixture", "demo") { try await store.archiveLocked("fixture", "demo") }; XCTFail("Failed directory move succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-failed") }
        let state = await fake.snapshot()
        XCTAssertEqual(state.files[original + "/state.json"], Data("saved-state".utf8))
        XCTAssertNil(state.files[original + "/.archived-state.json"])
        XCTAssertTrue(state.owners.isEmpty)
        XCTAssertEqual(state.releases.last?.path, original + "/.lock")
    }

    func testSignalTrapStopsWriteBeforeReplaceAndCleansTemporaryFile() async throws {
        let fake = BackendAppsStoreFake(mode: .signalDuringWrite)
        let path = BackendAppsStore.root + "/demo/state.json"
        let old = Data("old-durable-state".utf8)
        await fake.putFile(old, at: path)
        let store = BackendAppsStore(runtime: await fake.runtime())
        do { try await store.writeFile("fixture", path: path, contents: Data("private-new-value".utf8)); XCTFail("Interrupted write succeeded") }
        catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "state-failed")
            XCTAssertFalse(error.message.contains("private-new-value"))
        }
        let state = await fake.snapshot()
        XCTAssertEqual(state.files[path], old)
        XCTAssertTrue(state.signalHaltedWrite)
        XCTAssertEqual(state.atomicReplaces, 0)
        XCTAssertFalse(state.files.keys.contains { $0.hasSuffix(".tmp") })
    }

    func testInvalidStateRootAndTraversalRefuseBeforeServerIO() async throws {
        let fake = BackendAppsStoreFake()
        let invalid = BackendAppsStore(runtime: await fake.runtime(root: "/tmp/arbitrary-state"))
        do { _ = try await invalid.read("fixture", "demo"); XCTFail("Arbitrary root read succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let valid = BackendAppsStore(runtime: await fake.runtime())
        do { _ = try await valid.readFile("fixture", path: BackendAppsStore.root + "/demo/../outside"); XCTFail("Traversal read succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let state = await fake.snapshot()
        XCTAssertEqual(state.calls, 0)
        XCTAssertTrue(state.reads.isEmpty)
    }

    func testEveryProtectedAncestorSymlinkIsRefusedBeforeFileRead() async throws {
        for link in ["/var/lib/terminaldeck", BackendAppsStore.root, BackendAppsStore.root + "/demo", BackendAppsStore.root + "/demo/backups"] {
            let fake = BackendAppsStoreFake()
            await fake.putSymlink(link, target: "/outside")
            await fake.putFile(Data("outside-private-data".utf8), at: "/outside/state.json")
            let store = BackendAppsStore(runtime: await fake.runtime())
            do { _ = try await store.readFile("fixture", path: BackendAppsStore.root + "/demo/backups/state.json"); XCTFail("Followed ancestor symlink: " + link) }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-failed") }
            let state = await fake.snapshot()
            XCTAssertTrue(state.reads.isEmpty)
            XCTAssertEqual(state.calls, 1)
        }
    }
}

/// Interprets just the store's emitted operations against in-memory files and
/// ownership. No subprocess, server, timer, sleep or filesystem is involved.
private actor BackendAppsStoreFake {
    enum Mode: Sendable, Equatable { case normal, loseAcquireResponse, pauseAcquisition, truncateAcquireResponse, signalDuringWrite }
    struct Release: Sendable { let path: String, token: String, matched: Bool, authority: String?, cancelled: Bool }
    struct Snapshot: Sendable {
        let owners: [String: String], files: [String: Data], archives: [String], acquiredTokens: [String]
        let releases: [Release], reads: [String]
        let calls: Int, bodyCalls: Int, atomicReplaces: Int
        let signalHaltedWrite: Bool
    }
    var mode: Mode
    let failArchiveMove: Bool
    var directories: Set<String> = []
    var files: [String: Data] = [:]
    var symlinks: [String: String] = [:]
    var acquiredTokens: [String] = [], archives: [String] = [], reads: [String] = []
    var releases: [Release] = []
    var calls = 0, bodyCalls = 0, atomicReplaces = 0
    var signalHaltedWrite = false, acquisitionWritten = false, acquisitionFinished = false
    var acquisitionWaiters: [CheckedContinuation<Bool, Never>] = []
    var pausedAcquisition: CheckedContinuation<Void, any Error>?

    init(mode: Mode = .normal, failArchiveMove: Bool = false) { self.mode = mode; self.failArchiveMove = failArchiveMove }
    func putFile(_ value: Data, at path: String) { files[path] = value }
    func putSymlink(_ path: String, target: String) { symlinks[path] = target }
    func putOwner(_ owner: String, at path: String) { directories.insert(path); files[path + "/owner"] = Data(owner.utf8) }
    func body() { bodyCalls += 1 }
    func snapshot() -> Snapshot {
        let owners = Dictionary(uniqueKeysWithValues: files.filter { $0.key.hasSuffix("/.lock/owner") }.map { (String($0.key.dropLast(6)), String(decoding: $0.value, as: UTF8.self)) })
        return .init(owners: owners, files: files, archives: archives, acquiredTokens: acquiredTokens, releases: releases, reads: reads,
                     calls: calls, bodyCalls: bodyCalls, atomicReplaces: atomicReplaces, signalHaltedWrite: signalHaltedWrite)
    }
    func runtime(root: String = BackendAppsStore.root, prefix: String = "terminaldeck", requireContext: Bool = false) -> BackendAppsRuntime {
        .init(execute: { _, command, input, _, _ in
            if requireContext, BackendAppsStoreFakeCallContext.owner != "approved-fixture" { throw NativeRPCError(code: "access-denied", message: "Approved call context missing") }
            return try await self.execute(command, input)
        }, resourcePrefix: prefix, stateRoot: root)
    }
    func waitForAcquisition() async -> Bool {
        if acquisitionWritten { return true }
        if acquisitionFinished { return false }
        return await withCheckedContinuation { acquisitionWaiters.append($0) }
    }
    func operationFinished() {
        acquisitionFinished = true
        let waiters = acquisitionWaiters; acquisitionWaiters.removeAll(); waiters.forEach { $0.resume(returning: acquisitionWritten) }
    }
    func cancelPausedAcquisition() { let paused = pausedAcquisition; pausedAcquisition = nil; paused?.resume(throwing: CancellationError()) }

    private func execute(_ command: String, _ input: Data?) async throws -> BackendServersRunResult {
        calls += 1
        let outer = try BackendAppsStoreShell.words(command)
        let script = outer.count == 3 && outer[0] == "sh" && outer[1] == "-c" ? outer[2] : command
        let words = try BackendAppsStoreShell.words(script)
        let blocked = guardedSymlink(words)
        if let owner = redirectedPath(words), owner.hasSuffix("/.lock/owner"), let input {
            if blocked { return .init(code: 45, stdout: "") }
            let lock = String(owner.dropLast(6))
            guard !directories.contains(lock) else { return .init(code: 73, stdout: "") }
            directories.insert(lock); files[owner] = input
            acquiredTokens.append(String(decoding: input, as: UTF8.self)); acquisitionWritten = true
            let waiters = acquisitionWaiters; acquisitionWaiters.removeAll(); waiters.forEach { $0.resume(returning: true) }
            switch mode {
            case .loseAcquireResponse: mode = .normal; throw NativeRPCError(code: "fixture-lost-response", message: "The response was lost after the write")
            case .pauseAcquisition:
                try await withCheckedThrowingContinuation { pausedAcquisition = $0 }
            case .truncateAcquireResponse: mode = .normal; return .init(code: 0, stdout: "", truncated: true)
            default: break
            }
            return .init(code: 0, stdout: "")
        }
        if words.contains("rmdir"), let equality = words.lastIndex(of: "="), equality + 1 < words.count,
           let remove = words.firstIndex(of: "rm"), let owner = argument(after: remove, words: words) {
            let token = words[equality + 1], lock = String(owner.dropLast(6))
            let matched = !blocked && files[owner] == Data(token.utf8)
            releases.append(.init(path: lock, token: token, matched: matched, authority: BackendAppsStoreFakeCallContext.owner, cancelled: Task.isCancelled))
            if matched { files[owner] = nil; directories.remove(lock) }
            return .init(code: matched ? 0 : 1, stdout: "")
        }
        if blocked { return .init(code: 45, stdout: "") }
        if script.contains(".archived-state.json") {
            let moves = moveArguments(words)
            guard moves.count >= 2 else { throw fixture("Unsupported archive operation") }
            moveFile(moves[0].0, moves[0].1)
            if failArchiveMove {
                guard moves.count >= 3 else { throw fixture("Archive rollback missing") }
                moveFile(moves[2].0, moves[2].1)
                return .init(code: 1, stdout: "")
            }
            moveDirectory(moves[1].0, moves[1].1); archives.append(moves[1].1)
            return .init(code: 0, stdout: "")
        }
        if let temporary = redirectedPath(words), let input, temporary.hasSuffix(".tmp") {
            files[temporary] = input
            if mode == .signalDuringWrite {
                mode = .normal
                let signal = trapAction(script, for: "TERM")
                let action = try signal.map(BackendAppsStoreShell.words) ?? []
                if action.first == "exit", let text = action.dropFirst().first, let code = Int(text), code != 0 {
                    signalHaltedWrite = true
                    cleanupExitTrap(script)
                    return .init(code: code, stdout: "")
                }
            }
            let moves = moveArguments(words)
            guard let move = moves.first else { throw fixture("Atomic replacement missing") }
            moveFile(move.0, move.1); atomicReplaces += 1
            cleanupExitTrap(script)
            return .init(code: 0, stdout: "")
        }
        if let cat = words.lastIndex(of: "cat"), let path = argument(after: cat, words: words) {
            let resolved = resolve(path)
            guard let data = files[resolved] else { return .init(code: 44, stdout: "") }
            reads.append(resolved)
            return .init(code: 0, stdout: String(decoding: data, as: UTF8.self))
        }
        throw fixture("The fake received an unsupported store operation")
    }

    private func guardedSymlink(_ words: [String]) -> Bool {
        guard words.count >= 4 else { return false }
        for index in 0..<(words.count - 3) where words[index] == "test" && words[index + 1] == "!" && words[index + 2] == "-L" {
            if symlinks[words[index + 3]] != nil { return true }
        }
        return false
    }
    private func resolve(_ path: String) -> String {
        for link in symlinks.keys.sorted(by: { $0.count > $1.count }) where path == link || path.hasPrefix(link + "/") {
            return symlinks[link]! + String(path.dropFirst(link.count))
        }
        return path
    }
    private func redirectedPath(_ words: [String]) -> String? {
        guard words.count >= 3 else { return nil }
        for at in 0..<(words.count - 2) where words[at] == "cat" && words[at + 1] == ">" { return words[at + 2] }
        return nil
    }
    private func argument(after index: Int, words: [String]) -> String? {
        var at = index + 1
        while at < words.count, words[at].hasPrefix("-") { at += 1 }
        return at < words.count ? words[at] : nil
    }
    private func moveArguments(_ words: [String]) -> [(String, String)] {
        words.indices.compactMap { index in
            guard words[index] == "mv", let source = argument(after: index, words: words), let at = words[(index + 1)...].firstIndex(of: source), at + 1 < words.count else { return nil }
            return (source, words[at + 1])
        }
    }
    private func moveFile(_ source: String, _ destination: String) { if let data = files.removeValue(forKey: source) { files[destination] = data } }
    private func moveDirectory(_ source: String, _ destination: String) {
        for path in Array(files.keys) where path.hasPrefix(source + "/") { files[destination + String(path.dropFirst(source.count))] = files.removeValue(forKey: path) }
        for path in Array(directories) where path == source || path.hasPrefix(source + "/") { directories.remove(path); directories.insert(destination + String(path.dropFirst(source.count))) }
    }
    private func trapAction(_ script: String, for signal: String) -> String? {
        for line in script.split(separator: "\n") {
            guard let words = try? BackendAppsStoreShell.words(String(line)), words.count >= 3, words[0] == "trap", words.dropFirst(2).contains(signal) else { continue }
            return words[1]
        }
        return nil
    }
    private func cleanupExitTrap(_ script: String) {
        guard let action = trapAction(script, for: "EXIT"), let words = try? BackendAppsStoreShell.words(action), words.first == "rm", let path = argument(after: 0, words: words) else { return }
        files[path] = nil
    }
    private func fixture(_ message: String) -> NativeRPCError { .init(code: "fixture", message: message) }
}

/// A tokenizer, not a shell: only unwraps quoting and identifies emitted
/// operands. The fake applies the operations itself to its in-memory model.
private enum BackendAppsStoreShell {
    static func words(_ script: String) throws -> [String] {
        let characters = Array(script)
        var result: [String] = [], token = "", quote: Character?, started = false, at = 0
        func flush() { if started { result.append(token); token = ""; started = false } }
        while at < characters.count {
            let character = characters[at]
            if let active = quote {
                if character == active { quote = nil }
                else if active == "\"", character == "\\" {
                    guard at + 1 < characters.count else { throw NativeRPCError(code: "fixture", message: "Incomplete shell escape") }
                    at += 1; token.append(characters[at])
                } else { token.append(character) }
                at += 1; continue
            }
            if character == "'" || character == "\"" { quote = character; started = true }
            else if character == "\\" {
                guard at + 1 < characters.count else { throw NativeRPCError(code: "fixture", message: "Incomplete shell escape") }
                at += 1; token.append(characters[at]); started = true
            } else if character.isWhitespace { flush() }
            else if [";", ">", "&", "|"].contains(character) {
                flush()
                if (character == "&" || character == "|"), at + 1 < characters.count, characters[at + 1] == character { result.append(String(repeating: String(character), count: 2)); at += 1 }
                else { result.append(String(character)) }
            } else { token.append(character); started = true }
            at += 1
        }
        guard quote == nil else { throw NativeRPCError(code: "fixture", message: "Incomplete shell quote") }
        flush(); return result
    }
}

private enum BackendAppsStoreFakeCallContext { @TaskLocal static var owner: String? }
