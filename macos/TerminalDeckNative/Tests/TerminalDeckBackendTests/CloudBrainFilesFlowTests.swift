import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud I08 — memory flow and Hoot knowledge")
struct CloudBrainFilesFlowTests {
    typealias F = CloudBrainFilesFixture

    @Test func flowHootAndKnowledgeRestoreOnAnotherMacWithItsOwnProjectFolder() async throws {
        let f = try F(); defer { f.close() }
        let rootId = UUID().uuidString.lowercased()
        let projectA = f.url("a/projects/site"), projectB = f.url("b/elsewhere/site")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        let realA = (try? BackendKnowledgeFormat.realProject(projectA.path)) ?? projectA.resolvingSymlinksInPath().path
        let realB = (try? BackendKnowledgeFormat.realProject(projectB.path)) ?? projectB.resolvingSymlinksInPath().path
        let keyA = BackendKnowledgeFormat.projectKey(realA), keyB = BackendKnowledgeFormat.projectKey(realB)
        try f.write("a/data/deck-memory/flow-state.json", #"{"version":1}"#)
        try f.write("a/data/deck-memory/job-flow.jsonl", "{\"a\":1}\n")
        try f.write("a/data/deck-memory/helper/out.txt", "helper result\n")
        try f.write("a/data/deck-memory/helper/run.lock", "") // runtime lock: excluded by design
        try f.write("a/hoot/memory/MEMORY.md", "# Hoot memory\n")
        try f.write("a/hoot/specs/brief.md", "spec\n")
        try f.write("a/hoot/runs/r1.json", "{}")
        try f.write("a/data/knowledge/\(keyA)/project.json", "{\"project\":\"\(realA)\"}")
        try f.write("a/data/knowledge/\(keyA)/k-1.md", "decision\n")
        try f.write("a/data/knowledge/\(keyA)/log.jsonl", "{}\n")
        let a = try BackendCloudBrainFlow.adapter(dataRoot: f.url("a/data"), hootRoot: f.url("a/hoot"), deviceId: f.deviceA, stateRoot: f.url("a/state"),
                                                  projects: [.init(projectId: "p-site", rootId: rootId, path: projectA)], resolveProject: { _, _ in projectA })
        let b = try BackendCloudBrainFlow.adapter(dataRoot: f.url("b/data"), hootRoot: f.url("b/hoot"), deviceId: f.deviceB, stateRoot: f.url("b/state"),
                                                  projects: [.init(projectId: "p-site", rootId: rootId, path: projectB)],
                                                  resolveProject: { id, root in id == "p-site" && root == rootId ? projectB : nil })
        let inventory = try await a.sourceInventory()
        #expect(inventory.map { $0.items } == [3, 3, 3])
        #expect(inventory.allSatisfy { $0.complete })
        let snapshot = try await F.snapshot(a)
        #expect(snapshot.coverage.map { $0.items } == [3, 3, 3])
        #expect(try !snapshot.operations.contains { try F.part($0).key.hasSuffix("run.lock") })
        #expect(snapshot.operations.filter { $0.source.recordId.hasPrefix("file/knowledge/") }.allSatisfy { $0.projectId == "p-site" && $0.rootId == rootId })
        let receipt = try await F.apply(b, snapshot.operations, device: f.deviceA)
        #expect(receipt.counts.records == 9)
        for path in ["hoot/memory/MEMORY.md", "hoot/specs/brief.md", "hoot/runs/r1.json"] { #expect(try f.read("b/" + path) == f.read("a/" + path)) }
        // Machine-bound flow state is readable on the other Mac but never made live there.
        #expect(!f.exists("b/data/deck-memory/flow-state.json"))
        let versions = try await b.retainedVersions(key: "file/flow/flow-state.json")
        #expect(versions.count == 1)
        #expect(try await b.readRetained(rawHash: versions[0].rawHash, offset: 0, limit: 1024) == f.read("a/data/deck-memory/flow-state.json"))
        // Knowledge moves to the folder key of this Mac's own project path; only the known path field is mapped.
        #expect(keyA != keyB)
        #expect(try f.read("b/data/knowledge/\(keyB)/k-1.md") == Data("decision\n".utf8))
        #expect(try f.read("b/data/knowledge/\(keyB)/log.jsonl") == Data("{}\n".utf8))
        #expect(try NativeRPCValue.parseJSON(f.read("b/data/knowledge/\(keyB)/project.json"))["project"].string == realB)
        #expect(try await b.readiness().verified)
        // Placed imports are not echoed back as local edits.
        #expect(try await b.reconcile().journaled == 0)
    }

    @Test func knowledgeOfAnUnmappedProjectWaitsRetained() async throws {
        let f = try F(); defer { f.close() }
        let rootId = UUID().uuidString.lowercased(), projectA = f.url("a/projects/site")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        let realA = (try? BackendKnowledgeFormat.realProject(projectA.path)) ?? projectA.resolvingSymlinksInPath().path
        let keyA = BackendKnowledgeFormat.projectKey(realA)
        try f.write("a/data/knowledge/\(keyA)/k-1.md", "decision\n")
        let a = try BackendCloudBrainFlow.adapter(dataRoot: f.url("a/data"), hootRoot: f.url("a/hoot"), deviceId: f.deviceA, stateRoot: f.url("a/state"),
                                                  projects: [.init(projectId: "p-site", rootId: rootId, path: projectA)], resolveProject: { _, _ in projectA })
        let b = try BackendCloudBrainFlow.adapter(dataRoot: f.url("b/data"), hootRoot: f.url("b/hoot"), deviceId: f.deviceB, stateRoot: f.url("b/state"),
                                                  projects: [], resolveProject: { _, _ in nil })
        let receipt = try await F.apply(b, try await F.snapshot(a).operations, device: f.deviceA)
        #expect(receipt.results.first?.reason == "retained_waiting")
        #expect(!f.exists("b/data/knowledge"))
        let readiness = try await b.readiness()
        #expect(!readiness.verified && readiness.counts.blocked == 1)
    }
}
