import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Restart 1112: a Usage continuation does not restart its file walk")
struct Restart1112UsageTests {
    @Test func item6OverlappingExternalReadOwesAFullPassAfterAnAppend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restart-review-usage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("work"), config = root.appendingPathComponent("config")
        let directory = config.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let files = (0..<150).map { directory.appendingPathComponent("stub-\($0).jsonl") }
        for file in files { try Data("{}\n".utf8).write(to: file) }
        let scope = NativeTranscriptScope(configDirectory: config.path, projectFolders: [project.path])
        let cache = BackendFIXESUsageCache()
        var warm = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 10_000)
        for _ in 0..<30 where warm.scanning {
            warm = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 10_000, revalidate: false)
        }
        #expect(!warm.scanning && warm.files.count == 150)
        let readA = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 10_000)
        #expect(readA.scanning && readA.progress == warm.progress + 128)
        // Appending every file guarantees an append in the checked prefix, independent of directory order.
        for file in files {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
        }
        var readB = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 10_000)
        #expect(readB.scanning, "Read B cannot finish using read A's stale prefix")
        for _ in 0..<30 where readB.scanning {
            readB = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 10_000, revalidate: false)
        }
        #expect(!readB.scanning)
        #expect(readB.files.count == 150 && readB.files.allSatisfy { $0.bytes == 6 })
    }

    @Test func finishedCatalogueStaysFinishedUntilANewReadAndStillNoticesAppends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restart1112-usage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("work"), config = root.appendingPathComponent("config")
        let directory = config.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for index in 0..<150 { try Data("{}\n".utf8).write(to: directory.appendingPathComponent("stub-\(index).jsonl")) }
        let scope = NativeTranscriptScope(configDirectory: config.path, projectFolders: [project.path])
        let cache = BackendFIXESUsageCache()
        var result = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 250)
        for _ in 0..<30 where result.scanning {
            result = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 250, revalidate: false)
        }
        #expect(!result.scanning)
        #expect(result.files.count == 150)
        for _ in 0..<5 {
            let continued = try await cache.catalogue(project: project.path, scope: scope,
                deadline: BackendFIXESUsageCache.budgetNow() + 250, revalidate: false)
            #expect(!continued.scanning)
            #expect(continued.progress == result.progress)
        }
        let file = try #require(result.files.first)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file.path))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
        var updated = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 250)
        for _ in 0..<30 where updated.scanning {
            updated = try await cache.catalogue(project: project.path, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 250, revalidate: false)
        }
        #expect(!updated.scanning)
        #expect(updated.files.first(where: { $0.path == file.path })?.bytes == file.bytes + 3)
    }
}
