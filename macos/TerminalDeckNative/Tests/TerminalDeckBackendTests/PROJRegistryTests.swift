import AppKit
import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor PROJRegistryEvents {
    private var snapshots: [NativeRPCValue] = []
    private var tiers: [BackendMCPTier] = []
    func add(_ value: NativeRPCValue) { snapshots.append(value) }
    func record(_ tier: BackendMCPTier) { tiers.append(tier) }
    func values() -> [NativeRPCValue] { snapshots }
    func authorizations() -> [BackendMCPTier] { tiers }
}

final class PROJRegistryTests: XCTestCase, @unchecked Sendable {
    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-registry-" + UUID().uuidString + ".noindex") }
    /// An existing install's saved registry (made-up folders), written as the app writes it.
    private func seeded(_ root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("projects.json")
        try Data(PROJMadeUp.registryJSON.utf8).write(to: file); return file
    }
    /// Tests here load and save registries, which publish the live project list: put back a new install's.
    override func tearDown() { PROJProjects.publishRegistered([PROJProjects.independent]); super.tearDown() }
    private func caller(cancellation: BackendMCPCancellation = .init(), root: String? = nil) -> BackendMCPCallContext {
        .init(sessionID: "proj-fixture", machineID: "", projectRoot: root, attended: true,
              allowedTools: Set(["project_registry.list", "project_registry.resolve", "project_registry.switch", "project_registry.save", "project_registry.filter"]),
              allowedTiers: [.read, .alter], cancellation: cancellation)
    }
    private func handler(_ name: String, registry: BackendPROJRegistry, authorize: @escaping BackendPROJMCP.Authorize = { _, _, _, _ in },
                         resources: BackendPROJMCP.Resources? = nil) throws -> BackendNativeMCPServer.Handler {
        try XCTUnwrap(BackendPROJMCP.contribution(registry: registry, authorize: authorize, resources: resources).first { $0.0.id == name }?.1)
    }

    func testFolderBoundaryLongestMatchAndExplicitIdentity() { PROJMadeUp.with {
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/imatch/.claude/agents"), "imatch")
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/crm/.claude/agents"), "crm")
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/crm-backup"), "independent")
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/crm/../imatch"), "imatch")
        XCTAssertEqual(PROJProjects.resolve(projectID: "independent", folder: "/work/crm"), "independent")
        XCTAssertEqual(PROJProjects.resolve(projectID: "future-project", folder: "/work/crm"), "future-project")
        let projects = PROJProjects.defaults + [.init(id: "portal", name: "Portal", folders: ["/work/crm/portal"])]
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/crm/portal/src", projects: projects), "portal")
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: nil), "independent")
    } }

    // MARK: No built-in projects (11 Oct, Asad's decision)

    /// AGENTS-GAP (Asad, 11 Oct: "give terminal deck logo to the project profile"): project_registry_save takes a logo,
    /// adopted exactly as Project settings › Logo does (one implementation, a 256 px PNG in <data>/project-logos);
    /// omitted keeps it, "" removes it and its file. Before, the tool refused the logo argument.
    func testProjectRegistrySaveSetsKeepsAndRemovesTheLogo() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.registry.json"))
        let image = root.appendingPathComponent("deck.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: image)
        let save = try handler("project_registry.save", registry: registry)
        func args(_ logo: NativeRPCValue?) -> NativeRPCValue {
            var value = NativeRPCValue.object([.init("id", .string("terminal-deck")), .init("name", .string("Terminal Deck")),
                                               .init("folders", .array([.string(root.appendingPathComponent("deck").path)]))])
            if let logo { value = value.setting("logo", logo) }
            return value
        }
        let saved = try await save(caller(), args(.string(image.path)))
        XCTAssertFalse(saved.isError)
        let afterSave = try await registry.projects()
        let logo = try XCTUnwrap(afterSave.first { $0.id == "terminal-deck" }?.logo)
        XCTAssertFalse(logo.isEmpty)
        let file = registry.logoDirectory.appendingPathComponent(logo)
        XCTAssertEqual(file.deletingLastPathComponent().path, root.appendingPathComponent("project-logos").path)
        let stored = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        XCTAssertEqual(stored.pixelsWide, 256); XCTAssertEqual(stored.pixelsHigh, 256)
        _ = try await save(caller(), args(nil))
        let kept = try await registry.projects().first { $0.id == "terminal-deck" }?.logo
        XCTAssertEqual(kept, logo, "a save without logo keeps it")
        _ = try await save(caller(), args(.string("")))
        let removed = try await registry.projects().first { $0.id == "terminal-deck" }?.logo
        XCTAssertEqual(removed, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the old picture is discarded")
        do { _ = try await save(caller(), args(.string(root.appendingPathComponent("missing.png").path))); XCTFail("a missing image was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no image file"), error.localizedDescription) }
    }

    func testANewInstallHasIndependentOnlyAndNoFolderMatchesAProject() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.json"))
        let projects = try await registry.projects()
        XCTAssertEqual(projects, [PROJProjects.independent])
        XCTAssertEqual(PROJProjects.defaults, [PROJProjects.independent], "the live list is the registry's")
        for folder in ["/work/imatch", "/Users/imatch/ClaudeiMatch", "/Users/imatch/ClaudeCRM", "/anything"] {
            XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: folder), "independent", folder)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "reading a new install writes nothing")
    }

    func testAnExistingRegistryKeepsItsProjectsIdsFoldersColoursAndWhatIsFiledUnderThem() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try seeded(root), before = try Data(contentsOf: file)
        let registry = BackendPROJRegistry(fileURL: file)
        let projects = try await registry.projects()
        XCTAssertEqual(projects.map(\.id), ["imatch", "crm", "independent"])
        XCTAssertEqual(projects.map(\.name), ["iMatch", "CRM", "Independent"])
        XCTAssertEqual(projects.map(\.folders), [["/work/imatch"], ["/work/crm"], []])
        XCTAssertEqual(projects.map(\.colour), ["blue", "purple", "graphite"])
        XCTAssertEqual(try Data(contentsOf: file), before, "loading never rewrites the file")
        // Everything sorted by folder follows the saved projects through the live list (no list passed).
        XCTAssertEqual(PROJProjects.defaults.map(\.id), ["imatch", "crm", "independent"])
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/imatch/app/src"), "imatch")
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/crm"), "crm")
        XCTAssertEqual(PROJProjects.resolve(projectID: "crm", folder: "/work/imatch"), "crm", "a saved project id always wins")
        XCTAssertEqual(PROJProjects.name(for: "imatch"), "iMatch")
        // An older saved row with no colour gets the same colour the built-in list used to give it.
        let old = root.appendingPathComponent("old.json")
        try Data(PROJMadeUp.registryJSON.replacingOccurrences(of: #","colour":"blue""#, with: "").replacingOccurrences(of: #","colour":"purple""#, with: "").utf8).write(to: old)
        let colours = try await BackendPROJRegistry(fileURL: old).projects().map(\.colour)
        XCTAssertEqual(colours, ["blue", "purple", "graphite"])
    }

    func testTheSavedProjectsAreTheLiveListFromTheStartAndFollowEverySave() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        BackendPROJRegistry.publishSaved(fileURL: root.appendingPathComponent("missing.json"))
        XCTAssertEqual(PROJProjects.defaults, [PROJProjects.independent], "no file: Independent only")
        let file = try seeded(root), before = try Data(contentsOf: file)
        BackendPROJRegistry.publishSaved(fileURL: file)
        XCTAssertEqual(PROJProjects.defaults.map(\.id), ["imatch", "crm", "independent"])
        XCTAssertEqual(try Data(contentsOf: file), before, "the early read writes nothing")
        let registry = BackendPROJRegistry(fileURL: file)
        _ = try await registry.save(.init(id: "portal", name: "Portal", folders: ["/work/portal"]))
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/portal/web"), "portal")
        _ = try await registry.save(.init(id: "portal", name: "Portal", folders: ["/work/portal-moved"]))
        XCTAssertEqual(PROJProjects.resolve(projectID: nil, folder: "/work/portal/web"), "independent", "a moved folder is followed at once")
        // A list a test or preview scopes for itself is never changed by a save.
        try await PROJMadeUp.with {
            _ = try await registry.save(.init(id: "other", name: "Other", folders: ["/work/other"]))
            XCTAssertEqual(PROJProjects.defaults, PROJMadeUp.projects)
        }
    }

    func testReadHasNoWriteAndProjectSelectionSurvivesRestart() async throws {
        let root = scratch(), file = root.appendingPathComponent("projects.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: file)
        let first = try await registry.snapshot()
        XCTAssertEqual(first["projects"].elements?.count, 1, "a new install: Independent only")
        XCTAssertEqual(first["activeProjectId"], .null)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let saved = try await registry.save(.init(id: "portal", name: "Portal", folders: ["/work/crm/portal/", "/work/crm/portal"]))
        XCTAssertEqual(saved["colour"].string, "blue", "the first project the person adds")
        XCTAssertEqual(saved["folders"].elements?.count, 1)
        _ = try await registry.select("portal")
        let bytes = try Data(contentsOf: file), reopened = BackendPROJRegistry(fileURL: file)
        let loaded = try await reopened.snapshot()
        XCTAssertEqual(loaded["activeProjectId"].string, "portal")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let project = try await reopened.resolve(projectID: nil, folder: "/work/crm/portal/src")
        XCTAssertEqual(project, "portal")
        let all = try await reopened.select(nil)
        XCTAssertEqual(all["activeProjectId"], .null)
    }

    func testMissingMetadataDecodesAndRenamingKeepsProjectColour() async throws {
        let root = scratch(), file = root.appendingPathComponent("projects.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: file)
        let project = try JSONDecoder().decode(PROJProject.self, from: Data(#"{"id":"portal","name":"Portal","folders":["/work/portal"]}"#.utf8))
        let first = try await registry.save(project)
        let renamed = try await registry.save(.init(id: "portal", name: "New portal", folders: ["/work/portal"], icon: "folder.fill"))
        XCTAssertEqual(renamed["colour"], first["colour"])
    }

    func testFilteringBackfillsOldRowsAndKeepsIndependentChoice() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: try seeded(root))
        let rows: [NativeRPCValue] = [
            .object([.init("id", .string("imatch")), .init("folder", .string("/work/imatch/src"))]),
            .object([.init("id", .string("crm-old")), .init("folder", .string("/work/crm/.claude/agents"))]),
            .object([.init("id", .string("solo")), .init("folder", .string("/work/crm")), .init("projectId", .string("independent"))]),
            .object([.init("id", .string("alias")), .init("projectID", .string("crm"))]),
            .object([.init("id", .string("unknown")), .init("folder", .string("/elsewhere"))])
        ]
        let crm = try await registry.filter(rows, projectID: "crm")
        XCTAssertEqual(crm.map { $0["id"].string }, ["crm-old", "alias"])
        XCTAssertTrue(crm.allSatisfy { $0["projectId"].string == "crm" })
        let independent = try await registry.filter(rows, projectID: "independent")
        XCTAssertEqual(independent.map { $0["id"].string }, ["solo", "unknown"])
        XCTAssertFalse(rows[1].has("projectId"))
    }

    func testChangesPublishSnapshotsWithoutPolling() async throws {
        let root = scratch(), events = PROJRegistryEvents()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: try seeded(root), changed: { await events.add($0) })
        _ = try await registry.snapshot()
        let before = await events.values(); XCTAssertTrue(before.isEmpty)
        _ = try await registry.save(.init(id: "extra", name: "Extra", folders: ["/extra"]))
        _ = try await registry.select("crm")
        let snapshots = await events.values()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0]["projects"].elements?.count, 4)
        XCTAssertEqual(snapshots[1]["activeProjectId"].string, "crm")
    }

    func testReadOnlyRegistryRefusesMutationsWithoutChangingBytes() async throws {
        let root = scratch(), file = root.appendingPathComponent("projects.json")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try seeded(root)
        let writer = BackendPROJRegistry(fileURL: file)
        _ = try await writer.select("imatch")
        let bytes = try Data(contentsOf: file), reader = BackendPROJRegistry(fileURL: file, writable: false)
        let before = try await reader.snapshot(); XCTAssertEqual(before["activeProjectId"].string, "imatch")
        do { _ = try await reader.select("crm"); XCTFail("read-only switch changed data") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "read-only") }
        do { _ = try await reader.save(.init(id: "x", name: "X")); XCTFail("read-only save changed data") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "read-only") }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testInvalidMetadataAndUnknownSelectionLeaveDiskAbsent() async throws {
        let root = scratch(), file = root.appendingPathComponent("projects.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: file)
        for project in [PROJProject(id: "bad\0id", name: "Bad"), .init(id: "bad", name: "Bad", folders: ["relative"]), .init(id: "bad", name: String(repeating: "x", count: 257))] {
            do { _ = try await registry.save(project); XCTFail("invalid metadata saved") } catch {}
        }
        do { _ = try await registry.select("missing"); XCTFail("unknown project selected") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMalformedAndOversizeRegistryPreservesWarningsAndExactDamagedCopies() async throws {
        let root = scratch(), file = root.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, [String])] = [
            (#"{"projects":[{"id":"x","name":"X"},{"id":"x","name":"Again"}]}"#, ["x", PROJProjects.independentID]),
            (#"{"projects":[{"id":"x","name":"X","folders":["relative"]}]}"#, [PROJProjects.independentID]),
            (#"{"projects":[{"id":"bad\u0000id","name":"X"}]}"#, [PROJProjects.independentID]),
            ("{bad JSON", [PROJProjects.independentID])
        ]
        func hasExactCopy(_ bytes: Data) throws -> Bool {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + DamagedFile.marker) }
                .contains { (try? Data(contentsOf: $0)) == bytes }
        }
        for (text, ids) in cases {
            let bytes = Data(text.utf8); try bytes.write(to: file)
            let registry = BackendPROJRegistry(fileURL: file), recovered = try await registry.projects()
            XCTAssertEqual(recovered.map(\.id).sorted(), ids.sorted())
            if ids.contains("x") { XCTAssertEqual(recovered.first { $0.id == "x" }?.name, "X") }
            let warning = await registry.loadProblem(); XCTAssertFalse(warning?.isEmpty ?? true)
            XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertTrue(try hasExactCopy(bytes))
        }
        let huge = Data(repeating: 32, count: BackendPROJRegistry.maximumFileBytes + 1); try huge.write(to: file)
        let registry = BackendPROJRegistry(fileURL: file), recovered = try await registry.projects()
        XCTAssertEqual(recovered.map(\.id), [PROJProjects.independentID])
        let warning = await registry.loadProblem(); XCTAssertFalse(warning?.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: file), huge); XCTAssertTrue(try hasExactCopy(huge))
    }

    func testMCPReadIsFreeAndDeniedChangeDoesNotWrite() async throws {
        let root = scratch(), events = PROJRegistryEvents(), file = root.appendingPathComponent("projects.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: file)
        let authorize: BackendPROJMCP.Authorize = { _, _, _, tier in
            await events.record(tier)
            if tier != .read { throw NativeRPCError(code: "denied", message: "The owner declined.") }
        }
        let read = try handler("project_registry.list", registry: registry, authorize: authorize)
        let result = try await read(caller(), .object([]))
        XCTAssertEqual(result.structuredContent?["projects"].elements?.count, 1)
        let change = try handler("project_registry.switch", registry: registry, authorize: authorize)
        do { _ = try await change(caller(), .object([.init("projectId", .string("independent"))])); XCTFail("denied switch wrote") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "denied") }
        let tiers = await events.authorizations(); XCTAssertEqual(tiers, [.read, .alter])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let contributions = try BackendPROJMCP.contribution(registry: registry, authorize: authorize)
        XCTAssertFalse(contributions.contains { $0.0.wireName == "projects_list" })
    }

    func testMCPFilteringPassesScopeAndOriginalCallerToRealSource() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: try seeded(root))
        _ = try await registry.select("crm")
        let filter = try handler("project_registry.filter", registry: registry, resources: { kind, project, caller in
            guard kind == "servers", project == "crm", caller.projectRoot == "/scope", caller.sessionID == "proj-fixture" else { throw NativeRPCError.invalidArguments("The source received the wrong scope.") }
            return [.object([.init("id", .string("crm-server")), .init("projectId", .string("crm"))]), .object([.init("id", .string("imatch-server")), .init("projectId", .string("imatch"))])]
        })
        let result = try await filter(caller(root: "/scope"), .object([.init("kind", .string("servers"))]))
        XCTAssertEqual(result.structuredContent?["rows"].elements?.map { $0["id"].string }, ["crm-server"])
        let unavailable = try handler("project_registry.filter", registry: registry)
        do { _ = try await unavailable(caller(), .object([.init("kind", .string("servers"))])); XCTFail("missing source returned fake success") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
    }

    func testCancellationAfterApprovalCannotChangeSelection() async throws {
        let root = scratch(), file = root.appendingPathComponent("projects.json"), cancellation = BackendMCPCancellation()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: file)
        let change = try handler("project_registry.switch", registry: registry, authorize: { caller, _, _, _ in caller.cancellation.cancel() })
        do { _ = try await change(caller(cancellation: cancellation), .object([.init("projectId", .string("independent"))])); XCTFail("cancelled switch wrote") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
