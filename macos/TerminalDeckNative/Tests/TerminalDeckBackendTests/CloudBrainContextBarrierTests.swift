import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud full-context barrier — no success from partial registration")
struct CloudBrainContextBarrierTests {
    @Test func allCatalogSourcesAndLocalVerificationAreRequired() async throws {
        let f = try await Fixture.make(); let ready = try await f.barrier.context(projectId: "p", rootId: f.rootId, throughSeq: .init(7))
        #expect(ready.verified)
        #expect(ready.missingSources.isEmpty)
        await f.close()
    }
    @Test func aMissingUnregisteredRowCannotBecomeFullContext_S16_S20() async throws {
        let f = try await Fixture.make()
        await f.configure(coverage: f.coverage.filter { $0.inventoryRow != "I20" })
        let ready = try await f.barrier.context(projectId: "p", rootId: f.rootId, throughSeq: .init(7))
        #expect(!ready.verified)
        #expect(ready.missingSources.contains("source/I20"))
        await f.close()
    }
    @Test func oneProfileCannotHideAnotherMissingProfile_S16() async throws {
        let f = try await Fixture.make()
        let extra = CloudSourceInventory(sourceId: "another-profile", inventoryRow: "I17", domain: "fixture", items: 1, bytes: 1, complete: true, blockedReasons: [])
        let barrier = try CloudBrainContextBarrier(paths: f.paths, outbox: f.pathFixture.outbox, deviceId: f.pathFixture.firstDevice,
                                                 probes: [f.probe], expectedInventory: { f.catalog + [extra] })
        let ready = try await barrier.context(projectId: "p", rootId: f.rootId, throughSeq: .init(7))
        #expect(!ready.verified)
        #expect(ready.missingSources.contains("another-profile"))
        await f.close()
    }
    @Test func theTargetHeadMustBeReachedBeforeContinuing_S06() async throws {
        let f = try await Fixture.make()
        let ready = try await f.barrier.context(projectId: "p", rootId: f.rootId, throughSeq: .init(8))
        #expect(!ready.verified)
        #expect(ready.missingSources.contains("Cloud catch-up"))
        await f.close()
    }
    @Test func anotherDevicesPathCannotStartThisDevice_S14_S11() async throws {
        let f = try await Fixture.make()
        let barrier = try CloudBrainContextBarrier(paths: f.paths, outbox: f.pathFixture.outbox, deviceId: f.pathFixture.secondDevice,
                                                 probes: [f.probe], expectedInventory: { f.catalog })
        let ready = try await barrier.context(projectId: "p", rootId: f.rootId, throughSeq: .init(7))
        #expect(!ready.verified)
        #expect(ready.missingSources.contains("Project folder"))
        await f.close()
    }
    @Test func incompleteStagedBytesBlockReadinessDespiteCompleteRemoteCounters_S20() async throws {
        let f = try await Fixture.make(), source = try CloudBrainMemoryFixture()
        try source.write("hoot/card.md", String(repeating: "x", count: 100_000))
        let operations = try await source.snapshot("I01").operations
        _ = try await f.memory.apply([operations[0]], row: "I01")
        let ready = try await f.barrier.context(projectId: "p", rootId: f.rootId, throughSeq: .init(7))
        #expect(!ready.verified)
        #expect(ready.missingSources.contains("memory-owner"))
        await source.close(); await f.close()
    }
    struct Fixture: Sendable {
        let memory: CloudBrainMemoryFixture
        let pathFixture: CloudBrainPathsTests.Fixture
        let paths: BackendCloudBrainPaths
        let rootId: String
        let catalog: [CloudSourceInventory]
        let coverage: [CloudCoverage]
        let probe: CloudBrainContextBarrier.Probe
        let barrier: CloudBrainContextBarrier
        static func make() async throws -> Self {
            let memory = try CloudBrainMemoryFixture(); try await memory.activate("I01")
            let pathFixture = try CloudBrainPathsTests.Fixture(), rootId = UUID().uuidString
            let paths = try pathFixture.port(device: pathFixture.firstDevice, file: "context-paths.json")
            let plan = try await paths.planMapping(projectId: "p", rootId: rootId, destination: pathFixture.projects.appendingPathComponent("restored").path)
            try pathFixture.restore(plan.destination); _ = try await paths.commitMapping(planDigest: plan.digest, receipt: pathFixture.receipt)
            // An empty-brain catalog is a real valid boundary case. This is not a full domain-restore fixture.
            let catalog = CloudBrainContextBarrier.requiredInventoryRows.sorted().map { CloudSourceInventory(sourceId: "source/" + $0, inventoryRow: $0, domain: "fixture", items: 0, bytes: 0, complete: true, blockedReasons: []) }
            let coverage = catalog.map { CloudCoverage(sourceId: $0.sourceId, inventoryRow: $0.inventoryRow, complete: true, items: 0, bytes: 0, blockedReasons: []) }
            let probe = CloudBrainContextBarrier.Probe(sourceId: "memory-owner", verify: { try await memory.store.cloudMemoryReadiness() })
            let barrier = try CloudBrainContextBarrier(paths: paths, outbox: pathFixture.outbox, deviceId: pathFixture.firstDevice, probes: [probe], expectedInventory: { catalog })
            let result = Self(memory: memory, pathFixture: pathFixture, paths: paths, rootId: rootId, catalog: catalog, coverage: coverage, probe: probe, barrier: barrier)
            await result.configure(coverage: coverage)
            return result
        }
        func configure(coverage: [CloudCoverage]) async {
            await pathFixture.outbox.setContext(progress: .init(queued: 0, applied: 0, blocked: 0, brainSeq: .init(7), secretsSeq: .zero, coverage: coverage),
                                                context: .init(projectId: "p", throughSeq: .init(7), sourceCounts: .init(domains: coverage.count, records: 0, files: 0, bytes: 0, blocked: 0), verified: true, missingSources: []))
        }
        func close() async { await memory.close(); try? FileManager.default.removeItem(at: pathFixture.base) }
    }
}
