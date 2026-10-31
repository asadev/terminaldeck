import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor ROUTINESScopeAuthorityStub {
    var roots: [String]?
    var writes: [String]?
    var owner = false
    var identity = "key:fixture"
    var revoked = false
    var reads = 0
    var revokeOnRead: Int?
    init(roots: [String]?, writes: [String]?) { self.roots = roots; self.writes = writes }
    func current(_ approved: Bool) throws -> BackendROUTINESSkillsGrant {
        reads += 1
        if revoked || revokeOnRead == reads { throw NativeRPCError(code: "not-granted", message: "The key was revoked.") }
        return .init(readRoots: roots, writeRoots: approved ? writes : [], identity: identity, localOwner: owner)
    }
    func revoke() { revoked = true }
    func change(_ roots: [String]) { self.roots = roots; writes = roots }
    func revokeBeforeEffect() { revokeOnRead = 3 }
}

private actor ROUTINESScopeEffectsStub {
    var effects = 0
    var profiles: [NativeRPCValue]
    init(profiles: [NativeRPCValue]) { self.profiles = profiles }
    func list() -> [NativeRPCValue] { profiles }
    func record() -> NativeRPCValue { effects += 1; return .object([.init("ok", .bool(true))]) }
    func count() -> Int { effects }
    func change(_ id: String, _ skill: String, _ assigned: Bool, _ root: String?) throws -> NativeRPCValue {
        guard let index = profiles.firstIndex(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("Missing profile") }
        if let root { guard let folder = profiles[index]["defaultProject"].string, BackendROUTINESSkillsScope(roots: [root]).allows(folder) else { throw NativeRPCError(code: "not-granted", message: "Moved profile") } }
        profiles[index] = ROUTINESSkillsRules.changing(profiles[index], skill: skill, assigned: assigned); effects += 1
        return profiles[index]
    }
}

@Suite("ROUTINES credential and remote Skills scopes")
struct BackendROUTINESSkillsScopeSwiftTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ROUTINES-scope-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func skill(_ root: URL, _ name: String = "local") throws -> String {
        let folder = root.appendingPathComponent(".claude/skills/" + name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: Project instructions\n---\n# Read safely\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        return folder.path
    }
    private func service(_ root: URL, effects: ROUTINESScopeEffectsStub) -> BackendROUTINESSkills {
        let first = root.appendingPathComponent("inside"), other = root.appendingPathComponent("outside")
        let item = NativeRPCValue.object([
            .init("id", .string("pub/skill")),
            .init("kind", .string("skill")),
            .init("agents", .array([.string("claude")]))
        ])
        let catalogue = NativeRPCValue.object([.init("items", .array([item]))])
        return .init(dependencies: .init(projects: { [.init(id: "inside", name: "Inside", folders: [first.path]), .init(id: "outside", name: "Outside", folders: [other.path])] },
            profiles: { await effects.list() }, catalogue: { catalogue }, install: { _, _ in await effects.record() }, remove: { _ in await effects.record() },
            changeSkill: { id, name, assigned, boundary in try await effects.change(id, name, assigned, boundary) },
            guardedInstall: { _, _, guardAtOwner in try await guardAtOwner.verify(); return await effects.record() },
            guardedRemove: { _, guardAtOwner in try await guardAtOwner.verify(); return await effects.record() },
            guardedChangeSkill: { id, name, assigned, boundary, guardAtOwner in try await guardAtOwner.verify(); return try await effects.change(id, name, assigned, boundary) }),
            sharedRoots: [], home: root.appendingPathComponent("home"), writable: true)
    }
    private func create(_ project: String) -> NativeRPCValue { .object([.init("name", .string("new")), .init("summary", .string("New instructions")), .init("markdown", .string("Do the work")), .init("project", .string(project))]) }

    @Test func restrictedKeyCannotListOrPreviewAnotherRoot() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        _ = try skill(inside); let privateSkill = try skill(outside, "private")
        let scope = BackendROUTINESSkillsScope(roots: [inside.path]), service = service(root, effects: .init(profiles: []))
        let listed = try await service.call("skills:list", .object([.init("installed", .bool(true))]), scope: scope)
        #expect(listed["skills"].elements?.compactMap { $0["name"].string } == ["local"])
        await #expect(throws: NativeRPCError.self) { _ = try await service.call("skills:preview", .object([.init("skill", .string(privateSkill))]), scope: scope) }
    }
    @Test func absentOrEmptyCredentialRootsNeverInheritOwnerAccess() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root, effects: .init(profiles: []))
        let missing = ROUTINESScopeAuthorityStub(roots: nil, writes: nil)
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:list", arguments: .object([]), changing: false, service: service,
                currentGrant: { try await missing.current($0) }, approve: { _ in Issue.record("Missing grants must be denied before approval") })
        }
        let empty = ROUTINESScopeAuthorityStub(roots: [], writes: [])
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:list", arguments: .object([]), changing: false, service: service,
                currentGrant: { try await empty.current($0) }, approve: { _ in Issue.record("Empty grants must be denied before approval") })
        }
    }
    @Test func revokedKeyWhileApprovalIsOpenMakesNoChange() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: [inside.path])
        let effects = ROUTINESScopeEffectsStub(profiles: []), service = service(root, effects: effects)
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:create", arguments: create("inside"), changing: true, service: service,
                currentGrant: { try await authority.current($0) }, approve: { _ in await authority.revoke() })
        }
        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent(".claude/skills/new").path))
        #expect(await effects.count() == 0)
    }
    @Test func changedKeyFoldersWhileApprovalIsOpenMakesNoChange() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        let authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: [inside.path]), service = service(root, effects: .init(profiles: []))
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:create", arguments: create("inside"), changing: true, service: service,
                currentGrant: { try await authority.current($0) }, approve: { _ in await authority.change([outside.path]) })
        }
        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent(".claude/skills/new").path))
    }
    @Test func revocationAfterApprovalIsRecheckedAtTheEffect() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: [inside.path])
        await authority.revokeBeforeEffect()
        let service = service(root, effects: .init(profiles: []))
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:create", arguments: create("inside"), changing: true, service: service,
                currentGrant: { try await authority.current($0) }, approve: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent(".claude/skills/new").path))
    }
    @Test func readOnlyRemoteScopeCannotCreateEvenAfterOwnerApproval() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: [])
        let service = service(root, effects: .init(profiles: []))
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:create", arguments: create("inside"), changing: true, service: service,
                currentGrant: { try await authority.current($0) }, approve: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent(".claude/skills/new").path))
    }
    @Test func assignmentValidatesEveryProfileInsteadOfOnlyTheSkill() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside"), skillID = try skill(inside)
        let profiles: [NativeRPCValue] = ["inside": inside.path, "outside": outside.path].map { id, folder in .object([.init("id", .string(id)), .init("name", .string(id)), .init("defaultProject", .string(folder)), .init("skills", .array([]))]) }
        let effects = ROUTINESScopeEffectsStub(profiles: profiles), service = service(root, effects: effects)
        let authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: [inside.path])
        await #expect(throws: NativeRPCError.self) {
            _ = try await BackendROUTINESSkillsBoundary.run(channel: "skills:assign", arguments: .object([.init("skill", .string(skillID)), .init("agentIds", .array([.string("inside"), .string("outside")]))]), changing: true, service: service,
                currentGrant: { try await authority.current($0) }, approve: { _ in Issue.record("An outside profile must be denied before approval") })
        }
        #expect(await effects.count() == 0)
    }
    @Test func sessionGrantAlwaysIntersectsItsCurrentRoot() {
        let scope = BackendROUTINESSkillsScope(roots: ["/scratch"], projectRoot: "/scratch/one")
        #expect(scope.allows("/scratch/one/.claude/skills/local"))
        #expect(!scope.allows("/scratch/two/.claude/skills/private"))
        #expect(!scope.allows("/scratch/one-neighbour/.claude/skills/private"))
    }
    @Test func approvedWritableScopeCreatesOnlyInsideItsGrant() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        let authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: [inside.path]), service = service(root, effects: .init(profiles: []))
        let result = try await BackendROUTINESSkillsBoundary.run(channel: "skills:create", arguments: create("inside").setting("name", .string("fresh-skill")), changing: true, service: service,
            currentGrant: { try await authority.current($0) }, approve: { _ in })
        #expect(result["ok"] == .bool(true))
        #expect(FileManager.default.fileExists(atPath: inside.appendingPathComponent(".claude/skills/fresh-skill/SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }
    @Test func readOnlyScopeStillReadsItsInstalledSkillFreely() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"); _ = try skill(inside)
        let authority = ROUTINESScopeAuthorityStub(roots: [inside.path], writes: []), service = service(root, effects: .init(profiles: []))
        let result = try await BackendROUTINESSkillsBoundary.run(channel: "skills:list", arguments: .object([.init("installed", .bool(true))]), changing: false, service: service,
            currentGrant: { try await authority.current($0) }, approve: { _ in })
        #expect(result["skills"].elements?.compactMap { $0["name"].string } == ["local"])
    }
}
