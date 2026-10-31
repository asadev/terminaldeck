import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Clients handoff item 8: the same supplier and destination table serve the
/// installer and the displayed plan. Tests use scratch homes and no agent CLI.
final class BackendOSStoreSupplierTests: XCTestCase {
    private func exercise(kind: String, install: NativeRPCValue,
                          extra: [BackendOSStoreArchiveFixture.Entry], agents: [String],
                          tier: Int = 1, folder: String? = nil) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSStoreSupplier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home").path
        let environment = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("custom claude").path,
                           "CODEX_HOME": root.appendingPathComponent("custom codex").path,
                           "GEMINI_CLI_HOME": root.appendingPathComponent("gemini parent").path]
        let fixture = try BackendOSStoreInstallFixture.item(kind: kind, install: install, extra: extra, tier: tier)
        let installer = try BackendOSStoreInstaller(userData: data, environment: environment, home: home, writable: true,
            loadIndex: { BackendOSStoreInstallFixture.loaded([fixture.row]) },
            fetchArtifact: { _, _ in .init(ok: true, bytes: fixture.archive) })
        let supplier: any BackendCommunityStoreProviding = installer
        let before = try await supplier.view()
        XCTAssertEqual(before["items"].elements?.first?["state"].string, "available")
        let homes = BackendOSStoreInstaller.agentHomes(environment: environment, home: home)
        let plan = BackendCommunityProjection.plannedTargets(row: fixture.row, agents: agents, homes: homes, userData: data.path)
        var choice: NativeRPCValue = .object([.init("agents", .array(agents.map(NativeRPCValue.string)))])
        if let folder { choice = choice.setting("folder", .string(folder)) }
        let installed = try await supplier.install(id: "pub/thing", choice: choice)
        XCTAssertEqual(installed["ok"].bool, true, installed["message"].string ?? "")
        let record = try XCTUnwrap(BackendOSStoreInstaller.readLedger(data).first)
        XCTAssertEqual(record["root"].string, plan.first)
        let writes = record["writes"].elements ?? [], paths = writes.compactMap { $0["path"].string }
        let directTargets = Set(writes.filter { $0["kind"].string == "dir" || $0["kind"].string == "block" }.compactMap { $0["path"].string })
        let payloadTargets: Set<String>
        if kind == "skill" { payloadTargets = directTargets }
        else { payloadTargets = Set([record["root"].string].compactMap { $0 } + writes.filter { $0["kind"].string == "block" || ($0["kind"].string == "file" && !$0["path"].string!.hasPrefix(plan[0] + "/")) }.compactMap { $0["path"].string }) }
        XCTAssertEqual(payloadTargets, Set(plan), "Displayed plan differs from actual ledger destinations")
        for target in plan {
            XCTAssertTrue(paths.contains(target), "Plan target has no ledger entry: \(target)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: target), "Plan target is absent on disk: \(target)")
        }
        if kind == "skill" {
            for agent in agents {
                let one = BackendCommunityProjection.plannedTargets(row: fixture.row, agents: [agent], homes: homes, userData: data.path)
                XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: one[1]).appendingPathComponent("SKILL.md"), encoding: .utf8), "# Skill\n")
            }
        } else if kind == "instructions" {
            for agent in agents {
                let one = BackendCommunityProjection.plannedTargets(row: fixture.row, agents: [agent], homes: homes, userData: data.path)
                XCTAssertEqual(try String(contentsOfFile: one[1], encoding: .utf8), "Be brief.\n")
                XCTAssertTrue(try String(contentsOfFile: one[2], encoding: .utf8).contains("terminaldeck-store pub.thing"))
            }
        } else {
            let text = try String(contentsOfFile: plan[1], encoding: .utf8)
            XCTAssertTrue(text.contains("enabled: no")); XCTAssertTrue(text.contains("in: \(folder!)"))
        }
        let after = try await supplier.view()
        XCTAssertEqual(after["items"].elements?.first?["state"].string, "installed")
        let removed = try await supplier.remove(id: "pub/thing")
        XCTAssertEqual(removed["ok"].bool, true, removed["message"].string ?? "")
        XCTAssertEqual(BackendOSStoreInstaller.readLedger(data), [])
        for target in plan {
            let memory = writes.contains { $0["kind"].string == "block" && $0["path"].string == target }
            if memory { XCTAssertFalse(try String(contentsOfFile: target, encoding: .utf8).contains("terminaldeck-store pub.thing")) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: target), "Remove left an owned payload target: \(target)") }
        }
    }
    func testSkillSupplierUsesSharedRootPayloadAndMemoryPlan() async throws {
        try await exercise(kind: "skill", install: .object([.init("dir", .string("skill"))]),
                           extra: [.init("skill/SKILL.md", "# Skill\n")], agents: ["claude", "codex", "gemini"])
    }
    func testInstructionsSupplierUsesSharedPayloadAndMemoryPlan() async throws {
        try await exercise(kind: "instructions", install: .object([.init("file", .string("rules.md"))]),
                           extra: [.init("rules.md", "Be brief.\n")], agents: ["claude", "codex", "gemini"])
    }
    func testRoutineSupplierUsesSharedDisarmedDestinationPlan() async throws {
        try await exercise(kind: "routine", install: .object([.init("file", .string("routine.md"))]),
                           extra: [.init("routine.md", "# Sweep\n\nwhen: schedule 09:00\nin: /publisher\n\n---\n\nSweep.\n")], agents: [], tier: 2, folder: "/chosen")
    }
    func testSupplierRefusesChromeExtensionInstallationBeforeDownload() async throws {
        actor Effects {
            var downloads = 0, commands = 0
            func fetched() -> BackendOSStoreInstaller.Artifact { downloads += 1; return .init(ok: false, message: "unexpected download") }
            func run() -> NativeRPCValue { commands += 1; return .object([.init("ok", .bool(false)), .init("message", .string("unexpected runner"))]) }
            func counts() -> (Int, Int) { (downloads, commands) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSStoreSupplier-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackendOSStoreInstallFixture.item(kind: "extension", install: .object([.init("dir", .string(".")), .init("reach", .array([]))]), extra: [], tier: 2)
        let effects = Effects()
        let supplier: any BackendCommunityStoreProviding = try BackendOSStoreInstaller(userData: root, environment: [:], home: root.path, writable: true,
            loadIndex: { BackendOSStoreInstallFixture.loaded([fixture.row]) }, fetchArtifact: { _, _ in await effects.fetched() },
            runAgent: { _, _ in await effects.run() })
        let result = try await supplier.install(id: "pub/thing", choice: .object([]))
        XCTAssertEqual(result["ok"].bool, false); XCTAssertEqual(result["message"].string, BackendOSStoreInstaller.unsupported["extension"])
        XCTAssertTrue(result["message"].string?.contains("retired") == true)
        let counts = await effects.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
