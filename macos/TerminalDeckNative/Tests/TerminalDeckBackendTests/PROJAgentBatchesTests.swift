import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("PROJ read-only agent scans and selected batches")
struct PROJAgentBatchesTests {
    private let names = ["crm-db", "diff-verifier", "portal-mechanic"]
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-batches-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    private func copyCRM(_ root: URL, name: String = "crm-copy.noindex") throws -> URL {
        let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("PROJAgentFixtures")
        let folder = root.appendingPathComponent(name), directory = folder.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try FileManager.default.copyItem(at: source.appendingPathComponent(name + ".md"), to: directory.appendingPathComponent(name + ".md")) }
        return folder
    }
    private func paths(_ root: URL) -> [String] { names.map { root.appendingPathComponent(".claude/agents/" + $0 + ".md").path } }
    private func request(_ folder: URL, project: NativeRPCValue = .missing, selected: NativeRPCValue = .missing) -> NativeRPCValue {
        var batch: NativeRPCValue = .object([.init("folder", .string(folder.path))])
        if project != .missing { batch = batch.setting("project", project) }
        if selected != .missing { batch = batch.setting("selectedFiles", selected) }
        return .object([.init("batches", .array([batch]))])
    }

    @Test func scanIsReadOnlyGroupedAndMarksOnlyExactImportedSource() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root), files = paths(folder)
        let before = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let missing = root.appendingPathComponent("registered-without-agents")
        let projects = [PROJProject(id: "crm", name: "CRM", folders: [folder.path]), .init(id: "empty", name: "Empty", folders: [missing.path])]
        let existing: [NativeRPCValue] = [.object([.init("id", .string("crm-db")), .init("sourceFile", .string(files[0]))])]
        let result = try BackendPROJAgentBatches.scan(folders: [folder.path, missing.path], projects: projects, agents: existing)
        let groups = try #require(result["batches"].elements), group = try #require(groups.first)
        #expect(groups.count == 1 && group["projectId"].string == "crm" && result["errors"].elements?.isEmpty == true)
        let rows = try #require(group["agents"].elements)
        #expect(rows.count == 3 && rows.filter { $0["alreadyImported"].bool == true }.count == 1)
        #expect(rows.allSatisfy { !$0.has("prompt") && !$0.has("instructions") })
        #expect(try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } == before)
    }

    @Test func scanNeverAddsRegistryFoldersOutsideCallerSuppliedScope() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let allowed = try copyCRM(root, name: "allowed.noindex"), privateFolder = try copyCRM(root, name: "private.noindex")
        let projects = [PROJProject(id: "crm", name: "CRM", folders: [allowed.path]), .init(id: "private", name: "Private", folders: [privateFolder.path])]
        let result = try BackendPROJAgentBatches.scan(folders: [allowed.path], projects: projects, agents: [])
        #expect(result["batches"].elements?.count == 1)
        #expect(result["batches"].elements?.first?["projectId"].string == "crm")
        #expect(try BackendPROJAgentBatches.scan(folders: [], projects: projects, agents: [])["batches"].elements?.isEmpty == true)
    }

    @Test func explicitMissingFolderIsAnErrorAndAddedFolderInfersIndependent() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root)
        let result = try BackendPROJAgentBatches.scan(folders: [folder.path, root.appendingPathComponent("not-here").path], projects: [], agents: [])
        #expect(result["batches"].elements?.first?["projectId"].string == "independent")
        #expect(result["errors"].elements?.count == 1)
    }

    @Test func batchProjectAliasesNullAndDerivedExecutionFolderAreHonest() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root), projects = [PROJProject(id: "crm", name: "CRM", folders: [folder.path])]
        let inferred = try #require(BackendPROJAgentBatches.batches(request(folder), projects: projects).first)
        #expect(inferred.projectID == "crm" && inferred.options["defaultProject"].string == folder.path)
        let independent = try #require(BackendPROJAgentBatches.batches(request(folder, project: .null), projects: projects).first)
        #expect(independent.projectID == "independent" && independent.options["projectIdInferred"].bool == false)
        let file = paths(folder)[0]
        let chosen = try #require(BackendPROJAgentBatches.batches(request(folder, project: .string("crm"), selected: .array([.string(file)])), projects: projects).first)
        #expect(chosen.selectedFiles == [file] && chosen.options["selectedFiles"].elements == [.string(file)])
    }

    @Test func legacyFolderOptionsKeepOwnerOverrides() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root)
        let input: NativeRPCValue = .object([.init("folder", .string(folder.path)), .init("options", .object([
            .init("projectId", .string("independent")), .init("defaultProject", .string("/work/owner-choice")), .init("maxConcurrent", .number(1))]))])
        let batch = try #require(BackendPROJAgentBatches.batches(input, projects: []).first)
        #expect(batch.projectID == "independent" && batch.selectedFiles == nil)
        #expect(batch.options["defaultProject"].string == "/work/owner-choice" && batch.options["maxConcurrent"].number == 1)
    }

    @Test func selectionRejectsMissingOutsideNestedAndSymlinkBeforeAnyImport() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root), directory = folder.appendingPathComponent(".claude/agents")
        let other = try copyCRM(root, name: "outside.noindex")
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("crm-db.md"), to: nested.appendingPathComponent("crm-db.md"))
        let link = directory.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: paths(other)[0]))
        for path in [directory.appendingPathComponent("missing.md").path, paths(other)[0], nested.appendingPathComponent("crm-db.md").path, link.path] {
            #expect(throws: NativeRPCError.self) { try BackendPROJAgentBatches.batches(request(folder, selected: .array([.string(path)])), projects: []) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("task-config.json").path))
    }

    @Test func duplicateSelectionsAndDuplicateFolderChoicesAreRejected() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root), file = paths(folder)[0]
        #expect(throws: NativeRPCError.self) { try BackendPROJAgentBatches.batches(request(folder, selected: .array([.string(file), .string(file)])), projects: []) }
        let batch = try #require(request(folder, selected: .array([.string(file)]))["batches"].elements?.first)
        #expect(throws: NativeRPCError.self) { try BackendPROJAgentBatches.batches(.object([.init("batches", .array([batch, batch]))]), projects: []) }
    }

    @Test func invalidLaterBatchCannotWriteEarlierValidBatch() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try copyCRM(root, name: "first.noindex"), second = try copyCRM(root, name: "second.noindex")
        let valid = try #require(request(first, project: .string("crm"))["batches"].elements?.first)
        let missing = second.appendingPathComponent(".claude/agents/not-here.md").path
        let invalid = try #require(request(second, project: .null, selected: .array([.string(missing)]))["batches"].elements?.first)
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("records"), ownership: .memory))
        try await config.start()
        let input: NativeRPCValue = .object([.init("batches", .array([valid, invalid]))])
        await #expect(throws: NativeRPCError.self) {
            try await BackendPROJAgentBatches.importBatches(configuration: config, request: input, projects: [])
        }
        #expect(try await config.allAgents().isEmpty)
        try await config.stop()
    }

    @Test func selectionAndBatchLimitsRejectBeforeWriting() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copyCRM(root)
        let tooManyFiles = NativeRPCValue.array((0...50).map { .string(folder.appendingPathComponent(".claude/agents/\($0).md").path) })
        #expect(throws: NativeRPCError.self) { try BackendPROJAgentBatches.selectedFiles(tooManyFiles, directory: folder.appendingPathComponent(".claude/agents")) }
        let batch = try #require(request(folder)["batches"].elements?.first)
        #expect(throws: NativeRPCError.self) { try BackendPROJAgentBatches.batches(.object([.init("batches", .array(Array(repeating: batch, count: 33)))]), projects: []) }
        #expect(throws: NativeRPCError.self) { try BackendPROJAgentBatches.batches(request(folder, project: .string("../crm")), projects: []) }
    }
}
