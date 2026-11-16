import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud paths — explicit verified roots, no project writes")
struct CloudBrainPathsTests {
    @Test func twoMachinesKeepDifferentRootsAndNeverGuessByFolderName_S14() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let first = try f.port(device: f.firstDevice, file: "first.json"), second = try f.port(device: f.secondDevice, file: "second.json")
        let rootId = UUID().uuidString, project = "project-fixture"
        let one = try await first.planMapping(projectId: project, rootId: rootId, destination: f.projects.appendingPathComponent("one/site").path)
        try f.restore(one.destination)
        let firstMap = try await first.commitMapping(planDigest: one.digest, receipt: f.receipt)
        let firstOperations = try await first.retainedOperations()
        _ = try await second.importMaps(firstOperations)
        #expect(try await second.map(projectId: project, rootId: rootId, deviceId: f.secondDevice) == nil)
        let two = try await second.planMapping(projectId: project, rootId: rootId, destination: f.projects.appendingPathComponent("two/site").path)
        try f.restore(two.destination)
        let secondMap = try await second.commitMapping(planDigest: two.digest, receipt: f.receipt)
        #expect(firstMap.rootId == secondMap.rootId)
        #expect(firstMap.canonicalPath != secondMap.canonicalPath)
        #expect(try await second.map(projectId: project, rootId: rootId, deviceId: f.firstDevice) == firstMap)
        #expect(try await second.map(projectId: project, rootId: UUID().uuidString, deviceId: f.secondDevice) == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: one.destination).appendingPathComponent("work.txt")) == f.bytes)
    }
    @Test func planningAnOccupiedFolderCannotOverwriteIt_S05_S11() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let port = try f.port(device: f.firstDevice, file: "paths.json"), target = f.projects.appendingPathComponent("occupied")
        try f.restore(target.path)
        let plan = try await port.planMapping(projectId: "p", rootId: UUID().uuidString, destination: target.path)
        #expect(!plan.conflicts.isEmpty)
        await #expect(throws: CloudFailure.versionChanged) { _ = try await port.commitMapping(planDigest: plan.digest, receipt: f.receipt) }
        #expect(try Data(contentsOf: target.appendingPathComponent("work.txt")) == f.bytes)
        #expect(await f.outbox.operations.isEmpty)
    }
    @Test func aReceiptFromAnotherDestinationCannotApproveTheMap_S05() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let port = try f.port(device: f.firstDevice, file: "paths.json")
        let plan = try await port.planMapping(projectId: "p", rootId: UUID().uuidString, destination: f.projects.appendingPathComponent("empty").path)
        await #expect(throws: CloudFailure.checksumMismatch) { _ = try await port.commitMapping(planDigest: plan.digest, receipt: f.receipt) }
        #expect(await f.outbox.operations.isEmpty)
    }
    @Test func failedOutboxDoesNotActivateAPathAndRetryIsStable_S02_S03() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let port = try f.port(device: f.firstDevice, file: "paths.json"), rootId = UUID().uuidString
        let plan = try await port.planMapping(projectId: "p", rootId: rootId, destination: f.projects.appendingPathComponent("restore").path)
        try f.restore(plan.destination); await f.outbox.failNext()
        await #expect(throws: CloudFailure.unavailable) { _ = try await port.commitMapping(planDigest: plan.digest, receipt: f.receipt) }
        #expect(try await port.map(projectId: "p", rootId: rootId, deviceId: f.firstDevice) == nil)
        let map = try await port.commitMapping(planDigest: plan.digest, receipt: f.receipt)
        #expect(try await port.commitMapping(planDigest: plan.digest, receipt: f.receipt) == map)
        #expect(await f.outbox.operations.count == 1)
    }
    @Test func destinationsOutsideTheGrantedRootsAreRejected_S11() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let port = try f.port(device: f.firstDevice, file: "paths.json")
        await #expect(throws: CloudFailure.unsafeConfiguration) { _ = try await port.planMapping(projectId: "p", rootId: UUID().uuidString, destination: f.base.appendingPathComponent("outside").path) }
        #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("outside").path))
    }
    @Test func publishingAnExistingFolderOnlyRecordsItsPath_S11_S14() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let port = try f.port(device: f.firstDevice, file: "paths.json"), rootId = UUID().uuidString
        let folder = f.base.appendingPathComponent("Elsewhere/site"); try f.restore(folder.path)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let map = try await port.publishLocal(projectId: "p", rootId: rootId, path: folder.path)
        #expect(map.canonicalPath == folder.resolvingSymlinksInPath().path)
        #expect(map.deviceId == f.firstDevice && map.rootId == rootId)
        #expect(try await port.publishLocal(projectId: "p", rootId: rootId, path: folder.path) == map)
        #expect(await f.outbox.operations.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == before)
        await #expect(throws: CloudFailure.unavailable) { _ = try await port.publishLocal(projectId: "p", rootId: rootId, path: f.base.appendingPathComponent("missing").path) }
        #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("missing").path))
    }
    @Test func aFailedLocalPublishRetriesTheSameOperation_S03() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let port = try f.port(device: f.firstDevice, file: "paths.json"), rootId = UUID().uuidString
        let folder = f.base.appendingPathComponent("Elsewhere/app"); try f.restore(folder.path)
        await f.outbox.failNext()
        await #expect(throws: CloudFailure.unavailable) { _ = try await port.publishLocal(projectId: "p", rootId: rootId, path: folder.path) }
        #expect(try await port.map(projectId: "p", rootId: rootId, deviceId: f.firstDevice) == nil)
        // The staged operation is on disk before the outbox call; the retry sends exactly those bytes.
        _ = try await port.publishLocal(projectId: "p", rootId: rootId, path: folder.path)
        #expect(await f.outbox.operations.count == 1)
        #expect(try await port.retainedOperations().count == 1)
    }
    @Test func defaultDestinationsNeverCollideByNameAndSkipOccupiedFolders_S05_S14() throws {
        let home = URL(fileURLWithPath: "/fixture-home"), a = UUID().uuidString, b = UUID().uuidString
        let one = try BackendCloudBrainPaths.defaultDestination(projectName: "Site", rootId: a, home: home, developmentRoot: nil, occupied: { _ in false })
        let two = try BackendCloudBrainPaths.defaultDestination(projectName: "Site", rootId: b, home: home, developmentRoot: nil, occupied: { _ in false })
        #expect(one != two)
        #expect(one.hasPrefix("/fixture-home/Terminal Deck Projects/Site/"))
        let dev = try BackendCloudBrainPaths.defaultDestination(projectName: "Site", rootId: a, home: home, developmentRoot: URL(fileURLWithPath: "/fixture-dev/code"), occupied: { _ in false })
        #expect(dev.hasPrefix("/fixture-dev/code/Site/"))
        let sibling = try BackendCloudBrainPaths.defaultDestination(projectName: "../Site", rootId: a, home: home, developmentRoot: nil, occupied: { $0 == one })
        #expect(sibling == one + "-2")
        #expect(!sibling.contains("/../"))
    }
    struct Fixture: Sendable {
        let base: URL, projects: URL
        let outbox = CloudBrainMemoryOutboxFixture()
        let firstDevice = "10000000-0000-4000-8000-000000000001", secondDevice = "10000000-0000-4000-8000-000000000002"
        let bytes = Data("Uncommitted fixture work.\n".utf8)
        var receipt: CloudVerification { .init(verified: true, counts: .init(domains: 1, records: 0, files: 1, bytes: Int64(bytes.count), blocked: 0), reasons: []) }
        init() throws {
            base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("a-paths-" + UUID().uuidString, isDirectory: true)
            projects = base.appendingPathComponent("Projects")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        }
        func restore(_ destination: String) throws {
            let url = URL(fileURLWithPath: destination); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try bytes.write(to: url.appendingPathComponent("work.txt"), options: .withoutOverwriting)
        }
        func port(device: String, file: String) throws -> BackendCloudBrainPaths {
            let expected = bytes
            return try .init(file: base.appendingPathComponent("Cloud/" + file), allowedRoots: [projects], subject: .init(issuer: "https://issuer.example.invalid/auth/v1", sub: "20000000-0000-4000-8000-000000000001"), deviceId: device, outbox: outbox,
                             verifyRestore: { plan, receipt in
                guard receipt.verified, receipt.counts.files == 1, receipt.counts.bytes == Int64(expected.count) else { return false }
                return (try? Data(contentsOf: URL(fileURLWithPath: plan.destination).appendingPathComponent("work.txt"))) == expected
            }, now: { 1000 })
        }
    }
}
