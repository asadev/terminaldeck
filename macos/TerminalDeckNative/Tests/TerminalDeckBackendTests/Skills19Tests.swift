import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor Skills19Profiles {
    var rows: [NativeRPCValue]
    var refuseNew = false
    init(rows: [NativeRPCValue] = []) { self.rows = rows }
    func read() -> [NativeRPCValue] { rows }
    func refuse() { refuseNew = true }
    func change(id: String, skill: String, assigned: Bool) throws -> NativeRPCValue {
        if refuseNew && assigned && skill == "where-are-we" { throw NativeRPCError.invalidArguments("Stub save refused") }
        let at = rows.firstIndex { $0["id"].string == id }!
        let next = ROUTINESSkillsRules.changing(rows[at], skill: skill, assigned: assigned)
        guard (next["skills"].elements ?? []).count <= 20 else { throw NativeRPCError.invalidArguments("Only 20 skills") }
        rows[at] = next
        return rows[at]
    }
}
final class Skills19Tests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills19-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func write(_ root: URL, name: String, header: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(".claude/skills/" + name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data("---\nname: \(header ?? name)\ndescription: Keep me\n---\n# Instructions\nUse /status as an example, unchanged.\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        try Data("helper stays".utf8).write(to: folder.appendingPathComponent("references/guide.md"))
        return folder
    }
    private func service(_ root: URL, profiles: Skills19Profiles = .init(), registered: Bool = true) -> BackendROUTINESSkills {
        let projects = registered ? [PROJProject(id: "p", name: "Project", folders: [root.path])] : []
        return .init(dependencies: .init(projects: { projects }, profiles: { await profiles.read() }, catalogue: { .object([]) }, install: { _, _ in .null }, remove: { _ in .null }, changeSkill: { id, skill, assigned, _ in try await profiles.change(id: id, skill: skill, assigned: assigned) }), sharedRoots: [], home: root, writable: true)
    }
    func testCreateRefusesEveryAINameBeforeWriting() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = service(root)
        for name in ["status", "resume", "approve", "compress"] {
            do { _ = try await owner.create(name: name, summary: "Test", category: "Code", markdown: "Instructions", projectID: "p"); XCTFail("Allowed \(name)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("command, so neither works")) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
    }
    func testListFlagsHeaderAndFolderClashes() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, name: "safe", header: "status")
        _ = try write(root, name: "resume", header: "another-safe")
        let rows = try await service(root).list(installed: true)
        XCTAssertEqual(rows["skills"].elements?.filter { $0["clash"].string != nil }.count, 2)
    }
    func testRenameThroughChannelKeepsHelpersAndAgentChoices() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status")
        let original: NativeRPCValue = .object([.init("id", .string("a")), .init("defaultProject", .string(root.path)), .init("skills", .array([.string("status"), .string("keep")])), .init("future", .string("keep"))])
        let profiles = Skills19Profiles(rows: [original]), owner = service(root, profiles: profiles)
        let result = try await owner.call("skills:rename", .object([.init("skill", .string(folder.path))]))
        XCTAssertEqual(result["name"].string, "where-are-we")
        let newFolder = URL(fileURLWithPath: result["folder"].string!)
        let text = try String(contentsOf: newFolder.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("name: \"where-are-we\"")); XCTAssertTrue(text.contains("Use /status as an example, unchanged."))
        XCTAssertEqual(try String(contentsOf: newFolder.appendingPathComponent("references/guide.md"), encoding: .utf8), "helper stays")
        let saved = await profiles.read().first!
        XCTAssertEqual(saved.removing("skills"), original.removing("skills"))
        XCTAssertEqual(saved["skills"], .array([.string("keep"), .string("where-are-we")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills/where-are-we/SKILL.md").path))
    }
    func testRenameWorksWhenAnAgentAlreadyHasTwentySkills() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status")
        let skills = ["status"] + (1...19).map { "keep-\($0)" }
        let profile: NativeRPCValue = .object([.init("id", .string("a")), .init("defaultProject", .string(root.path)), .init("skills", .array(skills.map(NativeRPCValue.string)))])
        let profiles = Skills19Profiles(rows: [profile])
        _ = try await service(root, profiles: profiles).rename(folder.path)
        let saved = await profiles.read().first!
        XCTAssertEqual(saved["skills"].elements?.count, 20)
        XCTAssertTrue(saved["skills"].elements!.contains(.string("where-are-we")))
    }
    func testTakenSuggestionGetsSuffixAndExplicitReservedNameIsRefused() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "resume"); _ = try write(root, name: "recover")
        let owner = service(root)
        do { _ = try await owner.rename(folder.path, name: "status"); XCTFail("Reserved rename") } catch {}
        let result = try await owner.rename(folder.path)
        XCTAssertEqual(result["name"].string, "recover-2")
    }
    func testUnregisteredProjectAndOutOfScopeRename() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status"), owner = service(root, registered: false)
        do { _ = try await owner.rename(folder.path, scope: .init(roots: [root.appendingPathComponent("elsewhere").path])); XCTFail("Out of scope") } catch {}
        let result = try await owner.rename(folder.path)
        XCTAssertEqual(result["name"].string, "where-are-we")
    }
    func testFailedAgentSaveLeavesOriginalSkillAndChoices() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status")
        let original: NativeRPCValue = .object([.init("id", .string("a")), .init("defaultProject", .string(root.path)), .init("skills", .array([.string("status")]))])
        let profiles = Skills19Profiles(rows: [original]); await profiles.refuse()
        do { _ = try await service(root, profiles: profiles).rename(folder.path); XCTFail("Refused save") } catch {}
        let rows = await profiles.read(); XCTAssertEqual(rows, [original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    func testChangedApprovalAndSharedNeighbourRefuse() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status"), owner = service(root)
        do { _ = try await owner.rename(folder.path, fingerprint: "old"); XCTFail("Changed file") } catch {}
        let mirror = root.appendingPathComponent(".agents/skills/where-are-we")
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: mirror.appendingPathComponent("SKILL.md"))
        do { _ = try await owner.rename(folder.path); XCTFail("Shared neighbour") } catch {}
        XCTAssertEqual(try String(contentsOf: mirror.appendingPathComponent("SKILL.md"), encoding: .utf8), "mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    func testSpacedQuotedAndDuplicateHeaderKeysRenameToOneSafeName() throws {
        for header in ["name : status", "\"name\": status", "name: safe\nname : status"] {
            let text = "---\n" + header + "\ndescription: Keep me\n---\nBody unchanged"
            let renamed = try BackendSkillRenameFiles.renamed(text, name: "where-are-we")
            XCTAssertEqual(SkillCommandNames.headerName(renamed), "where-are-we")
            XCTAssertFalse(renamed.contains("status"))
            XCTAssertTrue(renamed.contains("description: Keep me\n---\nBody unchanged"))
        }
    }
    func testChannelPreservesTheApprovedFingerprint() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status"), owner = service(root)
        let plan = try await owner.scoped(.object([.init("skill", .string(folder.path))]), channel: "skills:rename")
        try Data("---\nname: status\n---\nChanged after approval".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        do { _ = try await owner.call("skills:rename", plan); XCTFail("Channel discarded approved fingerprint") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    func testLinkedSkillIsRefused() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, name: "status"), linked = folder.deletingLastPathComponent().appendingPathComponent("resume")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
        do { _ = try BackendSkillRenameFiles.move(folder: linked, name: "recover"); XCTFail("Linked folder") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    func testStoreRefusesActualHeaderAndNestedCommandsBeforeAnyWrite() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        for entries in [[BackendOSStoreArchiveFixture.Entry("skill/SKILL.md", "---\nname: status\n---\n")], [.init("skill/SKILL.md", "---\nname: safe\n---\n"), .init("skill/commands/resume.md", "instructions")]] {
            let fixture = try BackendOSStoreInstallFixture.item(extra: entries)
            let installer = try BackendOSStoreInstaller(userData: root.appendingPathComponent("data"), environment: [:], home: root.appendingPathComponent("home").path, writable: true, loadIndex: { BackendOSStoreInstallFixture.loaded([fixture.row]) }, fetchArtifact: { _, _ in .init(ok: true, bytes: fixture.archive) })
            let result = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("claude")]))]))
            XCTAssertEqual(result["ok"].bool, false)
            XCTAssertTrue(result["message"].string!.contains("command"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/community/items/pub.thing").path))
            let installed = await installer.installed(); XCTAssertTrue(installed.isEmpty)
        }
    }
    func testAssetToolCannotPublishReservedCommandsOrSkillHeaders() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        for (index, relative, file, body) in [
            (0, ".claude/commands", "status.md", "Instructions"),
            (1, ".claude/skills/safe", "SKILL.md", "---\nname: status\n---\nInstructions"),
            (2, ".agents/skills/resume", "SKILL.md", "---\nname: safe\n---\nInstructions")
        ] {
            let directory = rig.directory.appendingPathComponent(relative)
            let url = "https://assets.test/\(index)/\(file)"
            rig.transport.serve(url, bytes: Data(body.utf8))
            let reply = await rig.call("assets.fetch", .object([.init("runId", .string("names-\(index)")), .init("dir", .string(directory.path)), .init("urls", .array([.string(url)]))]))
            XCTAssertFalse(reply.isError, S2Assets.error(reply))
            let value = S2Assets.value(reply)
            XCTAssertEqual(value["tally"]["failed"].number, 1)
            XCTAssertTrue(value["results"].elements?.first?["reason"].string?.contains("command") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path))
        }
    }
    func testOrdinaryAssetFolderIsUnaffectedBySkillLikeContent() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let url = "https://assets.test/status.md", body = Data("---\nname: status\n---\nJust an asset".utf8)
        rig.transport.serve(url, bytes: body)
        let reply = await rig.call("assets.fetch", .object([.init("runId", .string("ordinary")), .init("dir", .string(rig.files)), .init("urls", .array([.string(url)]))]))
        XCTAssertFalse(reply.isError, S2Assets.error(reply))
        let value = S2Assets.value(reply)
        XCTAssertEqual(value["tally"]["fetched"].number, 1)
        let path = try XCTUnwrap(value["results"].elements?.first?["path"].string)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), body)
    }
    func testKnownPathGuardChecksAliasesAndLeavesOrdinaryFilesAlone() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = root.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("downloads")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: commands)
        XCTAssertThrowsError(try BackendSkillFileWriteGuard.require(path: alias.appendingPathComponent("status.md").path, bytes: Data()))
        XCTAssertNoThrow(try BackendSkillFileWriteGuard.require(path: root.appendingPathComponent("assets/status.md").path, bytes: Data("---\nname: status\n---\n".utf8)))
        XCTAssertThrowsError(try BackendSkillFileWriteGuard.require(path: root.appendingPathComponent(".claude/skills/safe/SKILL.md").path, bytes: Data("---\nname: resume\n---\n".utf8)))
    }
    func testStoreRenameUpdatesRemovalPaths() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackendOSStoreInstallFixture.item(extra: [.init("skill/SKILL.md", "---\nname: safe\n---\nInstructions")])
        let installer = try BackendOSStoreInstaller(userData: root.appendingPathComponent("data"), environment: [:], home: root.appendingPathComponent("home").path, writable: true, loadIndex: { BackendOSStoreInstallFixture.loaded([fixture.row]) }, fetchArtifact: { _, _ in .init(ok: true, bytes: fixture.archive) })
        let result = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("claude")])), .init("folder", .string(root.path))]))
        XCTAssertEqual(result["ok"].bool, true)
        let source = root.appendingPathComponent(".claude/skills/pub.thing")
        try await installer.renameSkillGuarded(folder: source.path, name: "where-are-we", beforeWrite: {})
        let records = await installer.installed(), record = records.first!
        XCTAssertFalse(record["writes"].elements!.contains { $0["path"].string?.hasPrefix(source.path) == true })
        let removed = try await installer.remove(id: record["installationID"].string!)
        XCTAssertEqual(removed["ok"].bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/skills/where-are-we").path))
    }
}
