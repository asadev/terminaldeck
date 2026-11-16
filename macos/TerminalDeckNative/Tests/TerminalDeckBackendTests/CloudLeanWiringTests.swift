import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean item 7: lane A2 registers NOTHING. Lane A is handed one assembly call and one contribution; the
/// two rows stay off in the app until the integrator proved them.
@Suite("Cloud lean — lane A2 registers nothing: one assembly call and one read-only tool for lane A's wiring")
struct CloudLeanWiringTests {
    private func owners(_ root: URL) async throws -> (registry: BackendPROJRegistry, roster: BackendTaskConfiguration) {
        let folder = root.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let roster = try BackendTaskConfiguration(persistence: try BackendTaskPersistence(directory: folder, ownership: .exclusive))
        try await roster.start()
        return (BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.registry.json")), roster)
    }

    @Test func withNoRowSwitchedOnNothingIsBuiltAndNothingIsWritten() async throws {
        let root = try CloudLeanFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await owners(root)
        let cloud = root.appendingPathComponent("cloud")
        let none = try BackendCloudLeanRecords.make(enabledRows: [], cloudFolder: cloud, subjectHash: CloudLeanFixture.subjectX, deviceId: CloudLeanFixture.deviceA,
            serviceTime: { nil }, registry: made.registry, roster: made.roster)
        #expect(none == nil)
        let memoryOnly = try BackendCloudLeanRecords.make(enabledRows: ["I01", "I02", "I03", "I04", "I05", "I06"], cloudFolder: cloud, subjectHash: CloudLeanFixture.subjectX,
            deviceId: CloudLeanFixture.deviceA, serviceTime: { nil }, registry: made.registry, roster: made.roster)
        #expect(memoryOnly == nil, "Lane A's memory rows switch on nothing of lane A2")
        #expect(!FileManager.default.fileExists(atPath: cloud.path), "With the rows off not even a folder is made")
        let noDomains = try BackendCloudLeanRecords.domains(["I01", "I06"])
        #expect(noDomains.isEmpty)
    }

    @Test func theTwoRowsAreBuiltOnlyWhenNamedAndJoinTheSyncCoreOnlyAtStart() async throws {
        let root = try CloudLeanFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await owners(root)
        let cloud = root.appendingPathComponent("cloud")
        let both = try BackendCloudLeanRecords.domains(BackendCloudLeanRecords.rows)
        #expect(both == ["agents", "projects"])
        #expect(both.allSatisfy { CloudWire.isValidDomainName($0) })
        let onlyProjects = try BackendCloudLeanRecords.domains([BackendCloudLeanRecords.projectsRow])
        #expect(onlyProjects == ["projects"])

        let one = try BackendCloudLeanRecords.make(enabledRows: [BackendCloudLeanRecords.projectsRow], cloudFolder: cloud, subjectHash: CloudLeanFixture.subjectX,
            deviceId: CloudLeanFixture.deviceA, serviceTime: { nil }, registry: made.registry, roster: made.roster, every: nil)
        let projectsOnly = try #require(one)
        let oneDomains = projectsOnly.adapters.map { $0.domain }
        #expect(oneDomains == ["projects"])
        #expect(projectsOnly.agents == nil && projectsOnly.projects != nil)

        let two = try BackendCloudLeanRecords.make(enabledRows: BackendCloudLeanRecords.rows, cloudFolder: cloud, subjectHash: CloudLeanFixture.subjectX,
            deviceId: CloudLeanFixture.deviceA, serviceTime: { nil }, registry: made.registry, roster: made.roster, every: nil)
        let records = try #require(two)
        let domains = records.adapters.map { $0.domain }
        #expect(domains == ["projects", "agents"], "Projects first: a project is on this Mac before the agents that name it")
        let rows = records.adapters.flatMap { $0.inventoryRows }
        #expect(rows == ["I11", "I10"])

        // Built is not registered: the sync core hears of the adapters only when lane A calls start.
        let outbox = CloudLeanFixtureOutbox()
        let before = await outbox.registered
        #expect(before == 0)
        let running = await records.activation.isRunning
        #expect(!running)
        try await records.activation.start(outbox: outbox)
        let after = await outbox.registered
        #expect(after == 2)
        await records.activation.stop()
    }

    @Test func theContributionIsOneReadOnlyToolAndNoAction() throws {
        let contribution = BackendCloudLeanTools.contribution
        #expect(contribution.owner == "A2")
        let ids = contribution.tools.map { $0.id }
        #expect(ids == ["cloud.versions"])
        let mutating = contribution.tools.filter { $0.mutates }
        #expect(mutating.isEmpty, "Nothing is chosen, approved or changed through a tool")
        #expect(contribution.actions.isEmpty)
        #expect(Set(contribution.inventoryRows) == BackendCloudLeanRecords.rows)
        // It survives the contract's own encoding (lane A stores and compares contributions).
        let encoded = try JSONEncoder().encode(contribution)
        let decoded = try JSONDecoder().decode(CloudFeatureContribution.self, from: encoded)
        #expect(decoded == contribution)
    }

    /// 0.22.0: after the integrator's proof the app's proven rows name lane A2's two rows (I10 agents, I11 projects),
    /// by their literal names, and never the device path map. They still run only for a signed-in, allowed account.
    @Test func theAppsProvenRowsNameLaneA2sRows() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = package.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudBrainRegistration.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let line = text.split(separator: "\n").first { $0.contains("static let provenRows") }.map(String.init) ?? ""
        #expect(!line.isEmpty, "The app's list of proven rows was not found where lane A keeps it")
        #expect(line.contains("\"I10\"") && line.contains("\"I11\""), "Rows I10 and I11 are switched on for 0.22.0: \(line)")
        #expect(!line.contains("paths"), "The device path map is not part of 0.22.0: \(line)")
    }

    /// Decker, 12 Nov: an arrived project is offered "Choose a folder on this Mac" and nothing else in this version
    /// (no git address is on the signed field list). No other offer is worded anywhere in lane A2's lean files.
    @Test func anArrivedProjectIsOfferedAFolderChoiceAndNothingElse() throws {
        let row = BackendCloudLeanProjects.NeedsFolder(id: "deck", name: "Deck")
        let labels = Mirror(reflecting: row).children.compactMap { $0.label }
        #expect(labels == ["id", "name"], "The row for a project without a folder carries an id and a name, nothing to fetch it from")
        let fields = Set(CloudBrainMergeTables.project.classes.keys)
        let addressLike = fields.filter { $0.lowercased().contains("git") || $0.lowercased().contains("remote") || $0.lowercased().contains("url") }
        #expect(addressLike.isEmpty, "No address of any kind is on the signed project field list")

        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/TerminalDeckBackend/BackendCloudLeanProjects.swift", "Sources/TerminalDeckBackend/BackendCloudLeanAgents.swift",
            "Sources/TerminalDeckBackend/BackendCloudLeanRecords.swift", "Sources/TerminalDeckNativeCore/CloudBrainRecordSync.swift",
            "../night/codex/cloud-adapters-wiring.md"]
        let word = ["cl", "one"].joined()   // the offer that is not made in this version
        for file in files {
            let text = try String(contentsOf: package.appendingPathComponent(file), encoding: .utf8)
            let found = text.lowercased().contains(word)
            #expect(!found, "\(file) words an offer this version does not make")
        }
    }
}
