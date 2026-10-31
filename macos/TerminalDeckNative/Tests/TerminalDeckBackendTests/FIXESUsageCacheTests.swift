import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class FIXESUsageCacheTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let project: URL
        let config: URL
        let path: URL
        var scope: NativeTranscriptScope { .init(configDirectory: config.path, projectFolders: [project.path]) }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FIXES-usage-" + UUID().uuidString + ".noindex")
        let project = root.appendingPathComponent("project"), config = root.appendingPathComponent("config")
        let directory = config.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, project: project, config: config, path: directory.appendingPathComponent("fixture.jsonl"))
    }
    private func row(_ f: Fixture, _ id: String, output: Int = 7, text: String = "Hello", timestamp: String? = nil) throws -> Data {
        var raw: [String: Any] = ["type": "assistant", "sessionId": "stub-session", "cwd": f.project.path,
            "message": ["id": id, "model": "claude-sonnet-5", "content": [["type": "text", "text": text]],
                "usage": ["input_tokens": 2, "output_tokens": output]]]
        if let timestamp { raw["timestamp"] = timestamp }
        var data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]); data.append(10); return data
    }
    private func append(_ data: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func testUnchangedFileParsesNoMoreBytes() async throws {
        let f = try fixture(), data = try row(f, "one")
        try data.write(to: f.path)
        let cache = BackendFIXESUsageCache()
        let cold = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        let warm = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(cold.bytesRead, data.count); XCTAssertEqual(warm.bytesRead, 0)
        XCTAssertEqual(warm.transcript.usage.output, 7); XCTAssertFalse(warm.scanning)
    }
    func testAppendReadsOnlyNewBytesAndKeepsRequestDedupe() async throws {
        let f = try fixture(), first = try row(f, "one"), second = try row(f, "two", output: 13)
        try first.write(to: f.path)
        let cache = BackendFIXESUsageCache()
        _ = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        try append(second + first, to: f.path)
        let next = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(next.bytesRead, second.count + first.count)
        XCTAssertEqual(next.transcript.requestCount, 2); XCTAssertEqual(next.transcript.usage.output, 20)
    }
    func testTornJSONAndSplitUTF8SurviveIncrementalSteps() async throws {
        let f = try fixture(), data = try row(f, "one", text: "Hi 🦉")
        let owl = try XCTUnwrap(data.range(of: Data("🦉".utf8)))
        let cut = owl.lowerBound + 2
        try data.prefix(cut).write(to: f.path)
        let cache = BackendFIXESUsageCache()
        // Membership may occur after the text field in this sorted record;
        // the unproven fragment must never be returned as another project's data.
        do { _ = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path) }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "transcript-membership") }
        try append(data.suffix(from: cut), to: f.path)
        let full = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(full.bytesRead, data.count - cut); XCTAssertEqual(full.transcript.requestCount, 1)
    }
    func testCompleteFinalRecordWithoutNewlineIsNotCountedTwiceAfterAppend() async throws {
        let f = try fixture(), first = try row(f, "one"), second = try row(f, "two")
        try first.dropLast().write(to: f.path)
        let cache = BackendFIXESUsageCache()
        let partial = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(partial.transcript.requestCount, 1)
        try append(Data([10]) + second, to: f.path)
        let next = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(next.transcript.requestCount, 2); XCTAssertEqual(next.transcript.usage.output, 14)
    }
    func testReplacementAndTruncationRestartTheCheckpoint() async throws {
        let f = try fixture(), first = try row(f, "one", output: 100), replacement = try row(f, "two", output: 3)
        try (first + first).write(to: f.path)
        let cache = BackendFIXESUsageCache()
        _ = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        try replacement.write(to: f.path, options: [.atomic])
        let replaced = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(replaced.transcript.usage.output, 3)
        let handle = try FileHandle(forWritingTo: f.path)
        try handle.truncate(atOffset: 0); try handle.close()
        var unrestricted = f.scope; unrestricted.projectFolders = nil
        let empty = try await cache.read(path: f.path.path, scope: unrestricted, cwd: f.project.path)
        XCTAssertEqual(empty.transcript.requestCount, 0); XCTAssertEqual(empty.bytesRead, 0)
    }
    func testCurrentScopeRejectsPreviouslyCachedProject() async throws {
        let f = try fixture(); try row(f, "one").write(to: f.path)
        let cache = BackendFIXESUsageCache()
        _ = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        var denied = f.scope; denied.projectFolders = []
        do { _ = try await cache.read(path: f.path.path, scope: denied, cwd: f.project.path); XCTFail("The cached file bypassed the current grant") }
        catch { XCTAssertTrue(error is NativeTranscriptPaths.Failure) }
    }
    func testCollidingFolderCannotReadCachedUsage() async throws {
        let f = try fixture(); try row(f, "one").write(to: f.path)
        let cache = BackendFIXESUsageCache()
        _ = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        // Replace the literal folder's punctuation so its encoded directory
        // still collides, then bind the current grant to that other folder.
        let other = f.project.path.replacingOccurrences(of: "FIXES-usage-", with: "FIXES_usage_")
        var denied = f.scope; denied.projectFolders = [other]
        XCTAssertEqual(NativeTranscriptPaths.encodeProjectPath(other), NativeTranscriptPaths.encodeProjectPath(f.project.path))
        do { _ = try await cache.read(path: f.path.path, scope: denied, cwd: other); XCTFail("The colliding folder received cached usage") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
    }
    func testByteBudgetReturnsUsefulPartialTotalsAndEventuallyCompletes() async throws {
        let f = try fixture()
        var data = Data()
        for index in 0..<100 { data.append(try row(f, "stub-\(index)")) }
        try data.write(to: f.path)
        let cache = BackendFIXESUsageCache()
        var result = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path, maximumNewBytes: 1_024)
        XCTAssertTrue(result.scanning); XCTAssertGreaterThan(result.transcript.requestCount, 0)
        var totalRead = result.bytesRead
        for _ in 0..<100 where result.scanning {
            result = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path, maximumNewBytes: 1_024)
            totalRead += result.bytesRead
        }
        XCTAssertFalse(result.scanning); XCTAssertEqual(result.transcript.requestCount, 100)
        XCTAssertEqual(totalRead, data.count)
    }
    func testLargeSparseTranscriptReturnsPartialInsteadOfProjectByteBudgetError() async throws {
        let f = try fixture(); try row(f, "one").write(to: f.path)
        let handle = try FileHandle(forWritingTo: f.path)
        try handle.truncate(atOffset: 600 * 1024 * 1024); try handle.close()
        let cache = BackendFIXESUsageCache()
        let result = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path, maximumNewBytes: 1_024)
        XCTAssertTrue(result.scanning); XCTAssertTrue(result.transcript.truncated)
        XCTAssertEqual(result.bytesRead, 1_024); XCTAssertEqual(result.transcript.requestCount, 1)
    }
    func testProjectChannelReturnsFastThenPushesCompletedStubTotalsAndRechecksGrant() async throws {
        let f = try fixture()
        var data = Data()
        for index in 0..<12_000 { data.append(try row(f, "stub-\(index)")) }
        XCTAssertGreaterThan(data.count, 2 * 1024 * 1024)
        try data.write(to: f.path)
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let grant = FIXESUsageGrant(root: f.root)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in await grant.scope() })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let complete = XCTestExpectation(description: "stub transcript completion update")
        let scope = f.scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { owner, channel, value in
            if owner == "FIXES-stub", channel == "cost:update", value["scanning"].bool == false,
               value["requests"].number == 12_000 { complete.fulfill() }
        })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "FIXES-stub")
        let started = Date()
        let initial = try await service.invoke("cost:project", args: [.string(f.project.path)], ownerID: context.ownerID, context: context)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(initial["scanning"].bool, true)
        XCTAssertGreaterThan(initial["requests"].number ?? 0, 0)
        await fulfillment(of: [complete], timeout: 30)
        let warm = try await service.project(f.project.path, context: context)
        XCTAssertEqual(warm["scanning"].bool, false); XCTAssertEqual(warm["scanBytesRead"].number, 0)
        XCTAssertEqual(warm["requests"].number, 12_000); XCTAssertEqual(warm["usage"]["output"].number, 84_000)
        await grant.revoke()
        do { _ = try await service.project(f.project.path, context: context); XCTFail("Warm project cache bypassed revoked filesystem access") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        await service.stop()
    }
    func testBadSiblingDoesNotHideGoodProjectUsage() async throws {
        let f = try fixture(); try row(f, "one").write(to: f.path)
        try Data("{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":999}}}\n".utf8)
            .write(to: f.path.deletingLastPathComponent().appendingPathComponent("bad.jsonl"))
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, _ in })
        let value = try await service.project(f.project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        XCTAssertEqual(value["usage"]["output"].number, 7); XCTAssertEqual(value["requests"].number, 1)
        XCTAssertEqual(value["skippedTranscripts"].number, 1); XCTAssertEqual(value["truncated"].bool, true)
        await service.stop()
    }
    func testCatalogueDiscoversAndRevalidatesInBoundedSteps() async throws {
        let f = try fixture()
        for index in 0..<300 {
            try row(f, "stub-\(index)").write(to: f.path.deletingLastPathComponent().appendingPathComponent("stub-\(index).jsonl"))
        }
        let cache = BackendFIXESUsageCache()
        var result = try await cache.catalogue(project: f.project.path, scope: f.scope, deadline: BackendFIXESUsageCache.budgetNow() + 250)
        XCTAssertTrue(result.scanning); XCTAssertLessThanOrEqual(result.files.count, 128)
        for _ in 0..<20 where result.scanning {
            result = try await cache.catalogue(project: f.project.path, scope: f.scope, deadline: BackendFIXESUsageCache.budgetNow() + 250)
        }
        XCTAssertFalse(result.scanning); XCTAssertEqual(result.files.count, 300)
        let path = try XCTUnwrap(result.files.first?.path)
        try append(row(f, "append"), to: URL(fileURLWithPath: path))
        var updated = try await cache.catalogue(project: f.project.path, scope: f.scope, deadline: BackendFIXESUsageCache.budgetNow() + 250)
        for _ in 0..<20 where updated.scanning {
            updated = try await cache.catalogue(project: f.project.path, scope: f.scope, deadline: BackendFIXESUsageCache.budgetNow() + 250)
        }
        XCTAssertGreaterThan(try XCTUnwrap(updated.files.first(where: { $0.path == path })?.bytes), try XCTUnwrap(result.files.first(where: { $0.path == path })?.bytes))
    }
    func testZeroUsagePrefixCannotStarveALaterTranscript() async throws {
        let f = try fixture(); try row(f, "one").write(to: f.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: f.path.path)
        let empty = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": f.project.path]) + Data([10])
        for index in 0..<180 {
            try empty.write(to: f.path.deletingLastPathComponent().appendingPathComponent("empty-\(index).jsonl"))
        }
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope, complete = XCTestExpectation(description: "later stub transcript is reached")
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, value in
            if value["scanning"].bool == false, value["requests"].number == 1 { complete.fulfill() }
        })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "FIXES-stub")
        let initial = try await service.project(f.project.path, context: context)
        XCTAssertEqual(initial["scanning"].bool, true)
        await fulfillment(of: [complete], timeout: 30)
        let completed = try await service.project(f.project.path, context: context)
        XCTAssertEqual(completed["requests"].number, 1); XCTAssertEqual(completed["usage"]["output"].number, 7)
        await service.stop()
    }
    func testOverviewSkipsToolMetadataWhileExistingParserKeepsIt() async throws {
        let f = try fixture()
        let raw: [String: Any] = ["type": "assistant", "cwd": f.project.path, "sessionId": "stub-session",
            "message": ["id": "one", "model": "claude-sonnet-5", "content": [["type": "tool_use", "id": "tool-one", "name": "Read"]],
                "usage": ["input_tokens": 2, "output_tokens": 7]]]
        let data = try JSONSerialization.data(withJSONObject: raw) + Data([10])
        try data.write(to: f.path)
        let cache = BackendFIXESUsageCache()
        let overview = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        let existing = try await BackendCostTranscript.read(path: f.path.path, scope: f.scope)
        XCTAssertEqual(existing.tools["Read"]?.calls, 1); XCTAssertTrue(overview.transcript.tools.isEmpty)
        XCTAssertTrue(overview.transcript.requests.first?.tools.isEmpty == true)
        XCTAssertEqual(existing.summary, overview.transcript.summary)
    }
    func testRecoverableMalformedRecordKeepsLaterHealthyRecords() async throws {
        let f = try fixture()
        try (row(f, "one") + row(f, String(repeating: "x", count: 1_100)) + row(f, "two", output: 13)).write(to: f.path)
        let cache = BackendFIXESUsageCache()
        let result = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(result.transcript.requestCount, 2); XCTAssertEqual(result.transcript.usage.output, 20)
        XCTAssertTrue(result.transcript.truncated); XCTAssertFalse(result.limited)
    }
    func testOversizedRecordDoesNotPreventHealthySiblingUsage() async throws {
        let f = try fixture()
        try (row(f, "one") + Data(repeating: 120, count: 9 * 1024 * 1024) + Data([10])).write(to: f.path)
        let sibling = f.path.deletingLastPathComponent().appendingPathComponent("healthy.jsonl")
        try row(f, "two", output: 13).write(to: sibling)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: sibling.path)
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope, complete = XCTestExpectation(description: "oversized record skipped, healthy sibling read")
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, value in
            if value["scanning"].bool == false, value["requests"].number == 2 { complete.fulfill() }
        })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "FIXES-stub")
        _ = try await service.project(f.project.path, context: context)
        await fulfillment(of: [complete], timeout: 30)
        let value = try await service.project(f.project.path, context: context)
        XCTAssertEqual(value["usage"]["output"].number, 20); XCTAssertEqual(value["truncated"].bool, true)
        await service.stop()
    }
    func testCompletedProjectInvalidatesAtomicReplacementWithSameSizeAndDate() async throws {
        let f = try fixture(), first = try row(f, "one", output: 7), replacement = try row(f, "two", output: 3)
        XCTAssertEqual(first.count, replacement.count); try first.write(to: f.path)
        let modified = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path.path)
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, _ in })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "FIXES-stub")
        let original = try await service.project(f.project.path, context: context)
        XCTAssertEqual(original["usage"]["output"].number, 7); XCTAssertEqual(original["scanning"].bool, false)
        try replacement.write(to: f.path, options: [.atomic])
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path.path)
        let replaced = try await service.project(f.project.path, context: context)
        XCTAssertEqual(replaced["usage"]["output"].number, 3)
        XCTAssertGreaterThan(replaced["scanBytesRead"].number ?? 0, 0)
        await service.stop()
    }
    func testMalformedFinalRecordWithoutNewlineKeepsEarlierUsage() async throws {
        let f = try fixture()
        try (row(f, "one") + row(f, String(repeating: "x", count: 1_100)).dropLast()).write(to: f.path)
        let cache = BackendFIXESUsageCache()
        let result = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(result.transcript.requestCount, 1); XCTAssertEqual(result.transcript.usage.output, 7)
        XCTAssertTrue(result.transcript.truncated); XCTAssertFalse(result.limited)
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, _ in })
        let value = try await service.project(f.project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        XCTAssertEqual(value["requests"].number, 1); XCTAssertEqual(value["usage"]["output"].number, 7)
        XCTAssertEqual(value["truncated"].bool, true)
        await service.stop()
    }
    func testFullCompletionCapacityReturnsTerminalPartialAndRetry() async throws {
        let f = try fixture()
        var data = Data()
        for index in 0..<12_000 { data.append(try row(f, "stub-\(index)")) }
        try data.write(to: f.path)
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        // Deterministically saturate the same production admission branch;
        // no worker, real AI, queue timer, or user data is involved.
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, maximumCompletions: 0, push: { _, _, _ in })
        let value = try await service.project(f.project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        XCTAssertEqual(value["scanning"].bool, false); XCTAssertEqual(value["truncated"].bool, true)
        XCTAssertEqual(value["canRetry"].bool, true); XCTAssertTrue(value["scanNote"].string?.contains("Try Again") == true)
        XCTAssertGreaterThan(value["requests"].number ?? 0, 0); XCTAssertLessThan(value["requests"].number ?? .infinity, 12_000)
        await service.stop()
    }
    func testBroadScopeDoesNotMixEncodedProjectFolderCollision() async throws {
        let original = try fixture(), project = original.root.appendingPathComponent("folder-a")
        let other = original.root.appendingPathComponent("folder_a")
        for folder in [project, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        XCTAssertEqual(NativeTranscriptPaths.encodeProjectPath(project.path), NativeTranscriptPaths.encodeProjectPath(other.path))
        let directory = original.config.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = Fixture(root: original.root, project: other, config: original.config, path: directory.appendingPathComponent("other.jsonl"))
        try row(f, "other", output: 999).write(to: f.path)
        let state = NativeStateStore(); _ = try await state.addProject(project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = NativeTranscriptScope(configDirectory: f.config.path)
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, _ in })
        let value = try await service.project(project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        XCTAssertEqual(value["requests"].number, 0); XCTAssertEqual(value["usage"]["output"].number, 0)
        XCTAssertEqual(value["skippedTranscripts"].number, 1)
        await service.stop()
    }
    func testInPlaceSameSizeRewriteWithRestoredDateInvalidatesCompletedProject() async throws {
        let f = try fixture(), first = try row(f, "one", output: 7), replacement = try row(f, "two", output: 3)
        XCTAssertEqual(first.count, replacement.count); try first.write(to: f.path)
        let modified = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path.path)
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, _ in })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "FIXES-stub")
        let old = try await service.project(f.project.path, context: context)
        XCTAssertEqual(old["usage"]["output"].number, 7)
        let handle = try FileHandle(forWritingTo: f.path); try handle.write(contentsOf: replacement); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path.path)
        let next = try await service.project(f.project.path, context: context)
        XCTAssertEqual(next["usage"]["output"].number, 3); XCTAssertGreaterThan(next["scanBytesRead"].number ?? 0, 0)
        await service.stop()
    }
    func testRegisteredMCPQuickSummarySkipsBadCatalogueAndRechecksRevokedGrant() async throws {
        let f = try fixture(); try row(f, "one").write(to: f.path)
        try Data("{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":999}}}\n".utf8)
            .write(to: f.path.deletingLastPathComponent().appendingPathComponent("bad.jsonl"))
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let grant = FIXESUsageGrant(root: f.root)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in await grant.scope() })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in scope }, push: { _, _, _ in })
        let access = BackendUsageToolAccess(rpcContext: { _ in .init(caller: .nativeApp, ownerID: "FIXES-MCP-stub") },
            authorize: { _, id, _, tier in
                guard id == "usage.cost", tier == .read else { throw NativeRPCError(code: "test", message: "Expected a free read.") }
            }, session: { _, _ in throw NativeRPCError(code: "test", message: "No real session is used.") }, machineUsage: { _ in })
        let tool = try BackendUsageMCPTools.costTool(cost: service, projects: projects, access: access)
        let server = BackendNativeMCPServer(); try await server.registerTool(tool.tool, handler: tool.handler)
        let registrations = await server.registrations()
        let registered = try XCTUnwrap(registrations.first)
        XCTAssertEqual(registered.0.inputSchema["properties"]["summaryOnly"]["type"].string, "boolean")
        let caller = BackendMCPCallContext(sessionID: "FIXES-stub", machineID: "", projectRoot: f.project.path, attended: false,
            allowedTools: ["usage.cost"], allowedTiers: [.read], cancellation: BackendMCPCancellation())
        let args = BackendUsageIO.object([("projectPath", .string(f.project.path)), ("summaryOnly", .bool(true))])
        let reply = try await registered.1(caller, args)
        let value = try XCTUnwrap(reply.structuredContent)
        XCTAssertEqual(value["project"]["usage"]["output"].number, 7)
        XCTAssertEqual(value["project"]["skippedTranscripts"].number, 1)
        XCTAssertEqual(value["transcriptsIncluded"].bool, false); XCTAssertEqual(value["totalTranscripts"], .null)
        do { _ = try await registered.1(caller, args.setting("transcriptPath", .string(f.path.path))); XCTFail("Mixed quick/exact request was accepted") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        do { _ = try await registered.1(caller, args.removing("summaryOnly")); XCTFail("Default catalogue contract was silently changed") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "transcript-membership") }
        await grant.revoke()
        do { _ = try await registered.1(caller, args); XCTFail("MCP warm cache bypassed the current filesystem grant") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        await service.stop(); await server.stop()
    }
    func testDirectoryEntryBudgetReturnsTerminalPartialProject() async throws {
        let f = try fixture()
        for index in 0..<3 {
            try row(f, "stub-\(index)").write(to: f.path.deletingLastPathComponent().appendingPathComponent("stub-\(index).jsonl"))
        }
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        var scope = f.scope; scope.maximumDirectoryEntries = 2
        let limited = scope
        let service = BackendCostService(projects: projects, scopeProvider: { _, _ in limited }, push: { _, _, _ in })
        let value = try await service.project(f.project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        XCTAssertEqual(value["scanning"].bool, false); XCTAssertEqual(value["truncated"].bool, true)
        XCTAssertEqual(value["requests"].number, 2); XCTAssertEqual(value["usage"]["output"].number, 14)
        await service.stop()
    }
    func testConsumedLargeLineReleasesPendingBuffer() async throws {
        let f = try fixture()
        let large = Data("{\"type\":\"user\",\"text\":\"".utf8) + Data(repeating: 120, count: 1024 * 1024) + Data("\"}\n".utf8)
        try (row(f, "one") + large).write(to: f.path)
        let cache = BackendFIXESUsageCache()
        let result = try await cache.read(path: f.path.path, scope: f.scope, cwd: f.project.path)
        XCTAssertEqual(result.transcript.requestCount, 1); XCTAssertFalse(result.scanning)
        let pending = await cache.pendingBytes(), retained = await cache.retainedCheckpointBytes()
        XCTAssertEqual(pending, 0); XCTAssertLessThan(retained, 20_000)
    }
    private func periodService(_ f: Fixture, clock: FIXESUsagePeriodClock) async throws -> BackendCostService {
        let state = NativeStateStore(); _ = try await state.addProject(f.project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [f.root], writeRoots: []) })
        let projects = try BackendProjectService(store: state, files: files, home: f.root.path, appDataRoot: f.config, liveSessions: { [] })
        let scope = f.scope
        return BackendCostService(projects: projects, scopeProvider: { _, _ in scope },
            periodCalendar: { clock.calendar() }, periodNow: { clock.now() }, push: { _, _, _ in })
    }
    func testPeriodsUseCalendarRangesKeepLifetimeAndLabelUnknownTimestamps() async throws {
        let f = try fixture()
        try (row(f, "today", output: 7, timestamp: "2026-10-10T12:00:00Z") +
            row(f, "yesterday", output: 13, timestamp: "2026-10-09T12:00:00Z") +
            row(f, "six-days", output: 23, timestamp: "2026-10-04T12:00:00Z") +
            row(f, "seven-days", output: 19, timestamp: "2026-10-03T12:00:00Z") + row(f, "unknown", output: 100)).write(to: f.path)
        let clock = try FIXESUsagePeriodClock(now: "2026-10-10T18:00:00Z", zone: "UTC")
        let service = try await periodService(f, clock: clock)
        let value = try await service.project(f.project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        XCTAssertEqual(value["requests"].number, 5); XCTAssertEqual(value["usage"]["output"].number, 162)
        let today = value["periods"]["today"], week = value["periods"]["week"]
        XCTAssertEqual(today["requests"].number, 1); XCTAssertEqual(today["usage"]["output"].number, 7)
        XCTAssertEqual(week["requests"].number, 3); XCTAssertEqual(week["usage"]["output"].number, 43)
        XCTAssertEqual(today["timeZone"].string, clock.calendar().timeZone.identifier)
        XCTAssertEqual(today["unknownTimestamps"].number, 1); XCTAssertEqual(today["partial"].bool, true)
        for period in [today, week] {
            let bars = try XCTUnwrap(period["bars"].elements)
            XCTAssertEqual(bars.count, 12); XCTAssertTrue(bars.allSatisfy { (0...1).contains($0.number ?? -1) })
            XCTAssertEqual(bars.compactMap(\.number).max(), 1)
        }
        await service.stop()
    }
    func testWarmPeriodsFollowMidnightAndTimezoneWithoutReadingTranscriptsAgain() async throws {
        let f = try fixture()
        try (row(f, "noon", output: 7, timestamp: "2026-10-10T12:00:00Z") +
            row(f, "late", output: 5, timestamp: "2026-10-10T22:00:00Z") +
            row(f, "next", output: 9, timestamp: "2026-10-11T00:00:00Z")).write(to: f.path)
        let clock = try FIXESUsagePeriodClock(now: "2026-10-10T23:59:00Z", zone: "UTC")
        let service = try await periodService(f, clock: clock), context = NativeRPCContext(caller: .nativeApp, ownerID: "FIXES-stub")
        let old = try await service.project(f.project.path, context: context)
        XCTAssertEqual(old["periods"]["today"]["usage"]["output"].number, 12)
        try clock.set(now: "2026-10-11T00:01:00Z", zone: "UTC")
        let midnight = try await service.project(f.project.path, context: context)
        XCTAssertEqual(midnight["scanBytesRead"].number, 0)
        XCTAssertEqual(midnight["periods"]["today"]["usage"]["output"].number, 9)
        XCTAssertNotEqual(midnight["periods"]["today"]["startAt"], old["periods"]["today"]["startAt"])
        try clock.set(now: "2026-10-11T00:01:00Z", zone: "Asia/Dubai")
        let zone = try await service.project(f.project.path, context: context)
        XCTAssertEqual(zone["scanBytesRead"].number, 0); XCTAssertEqual(zone["periods"]["today"]["usage"]["output"].number, 14)
        XCTAssertEqual(zone["usage"], old["usage"]); XCTAssertEqual(zone["requests"], old["requests"])
        await service.stop()
    }
    func testCalendarPeriodsRespectDaylightSavingDayAndSevenDayLengths() async throws {
        let f = try fixture()
        try (row(f, "first-hour", output: 7, timestamp: "2026-11-01T05:30:00Z") +
            row(f, "repeated-hour", output: 9, timestamp: "2026-11-01T06:30:00Z")).write(to: f.path)
        let clock = try FIXESUsagePeriodClock(now: "2026-11-01T12:00:00Z", zone: "America/New_York")
        let service = try await periodService(f, clock: clock)
        let value = try await service.project(f.project.path, context: .init(caller: .nativeApp, ownerID: "FIXES-stub"))
        let today = value["periods"]["today"], week = value["periods"]["week"]
        XCTAssertEqual(today["requests"].number, 2); XCTAssertEqual(today["usage"]["output"].number, 16)
        XCTAssertEqual((today["endAt"].number ?? 0) - (today["startAt"].number ?? 0), 25 * 3_600_000)
        XCTAssertEqual((week["endAt"].number ?? 0) - (week["startAt"].number ?? 0), 169 * 3_600_000)
        await service.stop()
    }
}

private actor FIXESUsageGrant {
    let root: URL
    var allowed = true
    init(root: URL) { self.root = root }
    func scope() -> BackendFilesystemScope { .init(readRoots: allowed ? [root] : [], writeRoots: []) }
    func revoke() { allowed = false }
}

private final class FIXESUsagePeriodClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var value: Calendar
    init(now: String, zone: String) throws {
        date = try XCTUnwrap(ISO8601DateFormatter().date(from: now))
        value = Calendar(identifier: .gregorian); value.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
    }
    func now() -> Date { lock.withLock { date } }
    func calendar() -> Calendar { lock.withLock { value } }
    func set(now: String, zone: String) throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: now)), zone = try XCTUnwrap(TimeZone(identifier: zone))
        lock.withLock { self.date = date; value.timeZone = zone }
    }
}
