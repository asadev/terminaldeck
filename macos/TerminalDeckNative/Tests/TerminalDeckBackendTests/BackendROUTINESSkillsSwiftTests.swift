import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor ROUTINESMovingRegistry {
    let inside: String, outside: String
    var reads = 0
    init(inside: String, outside: String) { self.inside = inside; self.outside = outside }
    func projects() -> [PROJProject] {
        reads += 1
        return [.init(id: "p", name: "P", folders: [reads == 1 ? inside : outside])]
    }
}

private actor ROUTINESSkillsStub {
    var profiles: [NativeRPCValue] = [.object([.init("id", .string("a")), .init("name", .string("A")), .init("defaultProject", .string("/scratch/project")),
                                             .init("skills", .array([.string("old")])), .init("model", .string("keep-model")), .init("future", .bool(true))])]
    var installs: [(String, NativeRPCValue)] = []
    var removals: [String] = []
    var profileReads = 0
    func read() -> [NativeRPCValue] { profileReads += 1; return profiles }
    func readCount() -> Int { profileReads }
    func replace(_ values: [NativeRPCValue]) { profiles = values }
    func save(_ value: NativeRPCValue) { profiles = [value] }
    func change(_ id: String, _ skill: String, _ assigned: Bool) throws -> NativeRPCValue {
        guard let index = profiles.firstIndex(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("Missing stub agent") }
        profiles[index] = ROUTINESSkillsRules.changing(profiles[index], skill: skill, assigned: assigned)
        return profiles[index]
    }
    func install(_ id: String, _ choice: NativeRPCValue) -> NativeRPCValue { installs.append((id, choice)); return .object([.init("ok", .bool(true))]) }
    func remove(_ id: String) -> NativeRPCValue { removals.append(id); return .object([.init("ok", .bool(true))]) }
    func lastInstall() -> NativeRPCValue? { installs.last?.1 }
    func removed() -> [String] { removals }
}

@Suite("ROUTINES BackendROUTINESSkillsTests")
struct BackendROUTINESSkillsSwiftTests {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ROUTINES-skills-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func write(_ folder: URL, name: String, category: String = "Data") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: Read the project\ncategory: \(category)\n---\n# Instructions\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    }
    private func catalogue(id: String = "publisher/skill") -> NativeRPCValue {
        let item = NativeRPCValue.object([
            .init("id", .string(id)),
            .init("kind", .string("skill")),
            .init("agents", .array([.string("claude")]))
        ])
        return .object([.init("items", .array([item]))])
    }
    private func service(root: URL, stub: ROUTINESSkillsStub, writable: Bool = true, owned: String? = nil) -> BackendROUTINESSkills {
        let project = PROJProject(id: "p", name: "Project", folders: [root.appendingPathComponent("project").path])
        let catalog = catalogue()
        return BackendROUTINESSkills(dependencies: .init(projects: { [project] }, profiles: { await stub.read() },
            catalogue: { catalog }, install: { await stub.install($0, $1) }, remove: { await stub.remove($0) }, ownedSkill: { folder in
                guard let id = owned else { return nil }
                let payloadWrite = NativeRPCValue.object([.init("kind", .string("dir")), .init("path", .string(folder))])
                return .object([
                    .init("id", .string(id)),
                    .init("root", .string(root.appendingPathComponent("archive").path)),
                    .init("writes", .array([payloadWrite]))
                ])
            }, changeSkill: { id, skill, assigned, _ in try await stub.change(id, skill, assigned) }),
            sharedRoots: [.init(folder: root.appendingPathComponent("home/.claude/skills"), source: "Every project"),
                          .init(folder: root.appendingPathComponent("builtins"), source: "Terminal Deck · built in", builtIn: true)],
            home: root.appendingPathComponent("home"), writable: writable)
    }
    @Test func testBulkAssignmentLoadsProfilesOnce() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project/.claude/skills/local")
        try write(folder, name: "local")
        let stub = ROUTINESSkillsStub(), service = service(root: root, stub: stub)
        let ids = (0..<40).map { "worker-" + String($0) }
        await stub.replace(ids.map { .object([.init("id", .string($0)), .init("provider", .string("claude")), .init("projectId", .string("p")), .init("skills", .array([]))]) })
        _ = try await service.assign(folder.path, agentIDs: ids, assigned: true)
        #expect(await stub.readCount() == 1)
        _ = try await service.rename(folder.path, name: "renamed")
        #expect(await stub.readCount() == 2)
        let profiles = await stub.read()
        #expect(profiles.allSatisfy { ($0["skills"].elements ?? []).contains(.string("renamed")) })
    }
    @Test func testDiscoveryRefreshesOnlyOwnedMirrorsAfterInstructionEdits() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project/.claude/skills/local")
        try write(folder, name: "local")
        let mirror = try #require(BackendSkillsMirror.mirror(folder))
        let file = folder.appendingPathComponent("SKILL.md")
        let updated = try String(contentsOf: file, encoding: .utf8) + "\nUpdated instructions\n"
        try Data(updated.utf8).write(to: file)
        let service = service(root: root, stub: .init())
        _ = try await service.list(installed: true)
        #expect(try String(contentsOf: mirror.appendingPathComponent("SKILL.md"), encoding: .utf8) == updated)
        try FileManager.default.removeItem(at: mirror.appendingPathComponent(BackendSkillsMirror.marker))
        try Data((updated + "Another edit").utf8).write(to: file)
        _ = try await service.list(installed: true)
        #expect(try String(contentsOf: mirror.appendingPathComponent("SKILL.md"), encoding: .utf8) == updated)
    }
    @Test func testDiscoversAllRegisteredProjectAndBuiltInCopies() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("project/.claude/skills/local"), name: "local")
        try write(root.appendingPathComponent("home/.claude/skills/global"), name: "global")
        try write(root.appendingPathComponent("builtins/release"), name: "release", category: "Release")
        let service = service(root: root, stub: .init()), rows = try await service.installed()
        #expect(Set(rows.map(\.name)) == Set(["local", "global", "release"]))
        #expect(rows.first { $0.name == "local" }?.projectID == "p")
        #expect(rows.first { $0.name == "release" }?.builtIn == true)
        let preview = try await service.preview(rows.first { $0.name == "local" }!.id)
        #expect(preview["markdown"].string?.contains("# Instructions") == true)
        #expect(preview["files"] == .array([.string("SKILL.md")]))
    }
    @Test func testAssignmentUsesTaskSaveAndPreservesUnknownFields() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("project/.claude/skills/local"), name: "local")
        let stub = ROUTINESSkillsStub(), service = service(root: root, stub: stub)
        let original = await stub.read().first!
        _ = try await service.assign("local", agentIDs: ["a"], assigned: true)
        let assigned = await stub.read().first!
        #expect(assigned["skills"] == .array([.string("old"), .string("local")]))
        #expect(assigned.removing("skills") == original.removing("skills"))
        _ = try await service.assign("local", agentIDs: ["a"], assigned: false)
        let unassigned = await stub.read().first!
        #expect(unassigned == original)
    }
    @Test func testAmbiguousNameNeedsExactCopyID() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("project/.claude/skills/a"), name: "same")
        try write(root.appendingPathComponent("home/.claude/skills/b"), name: "same")
        let service = service(root: root, stub: .init())
        do { _ = try await service.preview("same"); Issue.record("Ambiguous names must be refused") } catch {}
        let rows = try await service.installed()
        let exact = try await service.preview(rows[0].id)
        #expect(exact["name"] == .string("same"))
    }
    /// AGENTS-GAP (11 Oct): skills_assign "resume" with a resume skill in iMatch AND in Terminal Deck said "That skill is
    /// no longer installed". By name, the copy in the agents' own project is the one.
    @Test func testNameShowingInTwoProjectsPicksTheAgentsOwnProjectCopy() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("imatch/.claude/skills/recover"), name: "recover")
        try write(root.appendingPathComponent("deck/.claude/skills/recover"), name: "recover")
        let stub = ROUTINESSkillsStub()
        await stub.save(.object([.init("id", .string("a")), .init("name", .string("A")), .init("projectId", .string("terminal-deck")),
                                 .init("defaultProject", .string(root.appendingPathComponent("deck").path)), .init("skills", .array([]))]))
        let projects = [PROJProject(id: "imatch", name: "iMatch", folders: [root.appendingPathComponent("imatch").path]),
                        PROJProject(id: "terminal-deck", name: "Terminal Deck", folders: [root.appendingPathComponent("deck").path])]
        let service = BackendROUTINESSkills(dependencies: .init(projects: { projects }, profiles: { await stub.read() }, catalogue: { .object([]) },
            install: { await stub.install($0, $1) }, remove: { await stub.remove($0) },
            changeSkill: { id, skill, assigned, _ in try await stub.change(id, skill, assigned) }),
            sharedRoots: [], home: root.appendingPathComponent("home"), writable: true)
        let plan = try await service.scoped(.object([.init("skill", .string("recover")), .init("agentIds", .array([.string("a")]))]), channel: "skills:assign")
        #expect(plan["skillFolder"].string?.hasSuffix("/deck/.claude/skills/recover") == true)
        _ = try await service.assign("recover", agentIDs: ["a"], assigned: true)
        #expect(await stub.read().first?["skills"] == .array([.string("recover")]))
        // With no agents to go by, a shared name still has to be named by its folder (and says which copies exist).
        do { _ = try await service.preview("recover"); Issue.record("An ambiguous name was answered") }
        catch { #expect(error.localizedDescription.contains("More than one skill is called recover")) }
    }
    /// The person's own copy beats a built-in of the same name; a Codex built-in says it belongs to Codex.
    @Test func testOwnCopyBeatsABuiltInAndCodexBuiltInsNameCodex() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("home/.claude/skills/release"), name: "release")
        try write(root.appendingPathComponent("builtins/release"), name: "release")
        try write(root.appendingPathComponent("codex/hello"), name: "hello")
        let stub = ROUTINESSkillsStub()
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [] }, profiles: { await stub.read() }, catalogue: { .object([]) },
            install: { await stub.install($0, $1) }, remove: { await stub.remove($0) }),
            sharedRoots: [.init(folder: root.appendingPathComponent("home/.claude/skills"), source: "Every project"),
                          .init(folder: root.appendingPathComponent("builtins"), source: BackendBuiltInSkills.source, builtIn: true),
                          .init(folder: root.appendingPathComponent("codex"), source: BackendBuiltInSkills.codexSource, builtIn: true)],
            home: root.appendingPathComponent("home"), writable: true)
        let preview = try await service.preview("release")
        #expect(preview["folder"].string?.contains("/home/.claude/skills/release") == true)
        do { _ = try await service.remove("hello"); Issue.record("A built-in skill was removed") }
        catch { #expect(error.localizedDescription.contains("built into Codex")) }
    }
    @Test func testReadOnlyOwnerCannotCreateAndBuiltInCannotBeRemoved() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("builtins/release"), name: "release")
        let readonly = service(root: root, stub: .init(), writable: false)
        do { _ = try await readonly.create(name: "new", summary: "New", category: "Code", markdown: "Instructions", projectID: "p"); Issue.record("Read-only write") } catch {}
        let writable = service(root: root, stub: .init())
        do { _ = try await writable.remove("release"); Issue.record("Built-in removal") } catch {}
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("builtins/release/SKILL.md").path))
    }
    @Test func testInstallUsesVerifiedInstallerAtChosenProjectAndGlobalHome() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let stub = ROUTINESSkillsStub(), service = service(root: root, stub: stub)
        _ = try await service.install("publisher/skill", projectID: "p")
        let project = await stub.lastInstall()
        #expect(project?["folder"] == .string(root.appendingPathComponent("project").path))
        _ = try await service.install("publisher/skill", projectID: nil)
        let global = await stub.lastInstall()
        #expect(global?["folder"] == .string(root.appendingPathComponent("home").path))
    }
    @Test func testStoreOwnedRemovalUsesLedgerInsteadOfDeletingDirectly() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project/.claude/skills/local"); try write(folder, name: "local")
        let stub = ROUTINESSkillsStub(), service = service(root: root, stub: stub, owned: "publisher/skill")
        _ = try await service.remove(folder.path)
        let removed = await stub.removed()
        #expect(removed == ["publisher/skill"])
        #expect(FileManager.default.fileExists(atPath: folder.path), "The stub installer, not the service, owns deletion")
    }
    @Test func testSessionCannotChangeAnotherProjectOrGlobalSkills() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("home/.claude/skills/global"), name: "global")
        let service = service(root: root, stub: .init())
        do { _ = try await service.scoped(.object([.init("skill", .string("global"))]), channel: "skills:remove", projectRoot: root.appendingPathComponent("project").path); Issue.record("Global removal") } catch {}
        do { _ = try await service.scoped(.object([.init("id", .string("publisher/skill")), .init("project", .null)]), channel: "skills:install", projectRoot: root.appendingPathComponent("project").path); Issue.record("Global install") } catch {}
    }
    @Test func testPreviewNeverReturnsAgentPrivateInstructionsOrAccount() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("project/.claude/skills/local"), name: "local")
        let stub = ROUTINESSkillsStub()
        await stub.save(.object([.init("id", .string("a")), .init("name", .string("A")), .init("skills", .array([.string("local")])), .init("instructions", .string("private")), .init("account", .string("secret-account")), .init("icon", .string("sf:person"))]))
        let value = try await service(root: root, stub: stub).preview("local")
        let agent = try #require(value["agents"].elements?.first)
        #expect(agent["name"] == .string("A"))
        #expect(agent["instructions"].isNullish); #expect(agent["account"].isNullish)
        #expect(agent["skills"].isNullish)
    }
    @Test func testLinkedProjectSkillRootIsSkippedWithWarning() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write(elsewhere.appendingPathComponent("skills/private"), name: "private")
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".claude"), withDestinationURL: elsewhere)
        let result = try await service(root: root, stub: .init()).list(installed: true)
        #expect(result["skills"] == .array([]))
        #expect(!((result["warnings"].elements ?? []).isEmpty))
    }
    @Test func testScopedReadDoesNotExposeSiblingFolderInSameProject() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try write(first.appendingPathComponent(".claude/skills/first"), name: "first")
        try write(second.appendingPathComponent(".claude/skills/second"), name: "second")
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [.init(id: "p", name: "P", folders: [first.path, second.path])] }, profiles: { [] },
            catalogue: { .object([]) }, install: { _, _ in Issue.record("read must not install"); return .object([]) }, remove: { _ in Issue.record("read must not remove"); return .object([]) }), sharedRoots: [], home: root.appendingPathComponent("home"), writable: true)
        let result = try await service.call("skills:list", .object([.init("installed", .bool(true))]), projectRoot: first.path)
        #expect(result["skills"].elements?.compactMap { $0["name"].string } == ["first"])
    }
    @Test func changedRegistryAfterApprovalCannotRedirectInstall() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        let registry = ROUTINESMovingRegistry(inside: inside.path, outside: outside.path)
        let catalog = catalogue(id: "pub/skill")
        let service = BackendROUTINESSkills(dependencies: .init(projects: { await registry.projects() }, profiles: { [] },
            catalogue: { catalog },
            install: { _, _ in Issue.record("The moved target must not reach the installer"); return .object([.init("ok", .bool(true))]) },
            remove: { _ in .object([]) }), sharedRoots: [], home: root.appendingPathComponent("home"), writable: true)
        do {
            _ = try await service.call("skills:install", .object([.init("id", .string("pub/skill")), .init("project", .string("p"))]), projectRoot: inside.path)
            Issue.record("The moved project must be refused")
        } catch let error as NativeRPCError { #expect(error.code == "not-granted") }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent(".claude/skills").path))
    }
    @Test func changedRegistryAfterApprovalCannotRedirectCreate() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        let registry = ROUTINESMovingRegistry(inside: inside.path, outside: outside.path)
        let service = BackendROUTINESSkills(dependencies: .init(projects: { await registry.projects() }, profiles: { [] },
            catalogue: { .object([]) }, install: { _, _ in .object([]) }, remove: { _ in .object([]) }), sharedRoots: [], home: root.appendingPathComponent("home"), writable: true)
        do {
            _ = try await service.call("skills:create", .object([.init("name", .string("safe")), .init("summary", .string("A safe skill")), .init("markdown", .string("Instructions")), .init("project", .string("p"))]), projectRoot: inside.path)
            Issue.record("The moved project must be refused")
        } catch let error as NativeRPCError { #expect(error.code == "not-granted") }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent(".claude/skills/safe/SKILL.md").path))
    }
}
