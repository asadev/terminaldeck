import Testing
import TerminalDeckNativeCore

/// Standalone pure fixtures: no engine, user data, account, app or AI calls.
struct ROUTINESProjectProjectionChecks {
    private let projects: [PROJProject] = [
        .init(id: "fleet-platform", name: "Fleet", folders: ["/work/fleet"], colour: "green"),
        .init(id: "fleet-api", name: "Fleet API", folders: ["/work/fleet/services"], colour: "orange")
    ]
    private func routine(_ projectID: String? = nil, inferred: Bool = false, agent: String = "critic") -> CodingAIJSON {
        var fields: [String: CodingAIJSON] = ["id": .string("audit"), "name": .string("Audit"),
            "folder": .string("/work/fleet/services/api"), "agentId": .string(agent), "projectIdInferred": .bool(inferred),
            "state": .string("armed"), "enabled": .bool(true)]
        if let projectID { fields["projectId"] = .string(projectID) }
        return .array([.object(fields)])
    }
    @Test func inferredFallbackUsesLiveCustomRegistryAndLongestFolder() throws {
        let raw = routine("independent", inferred: true)
        #expect(try #require(ROUTINESRoutine.list(raw, projects: []).first).projectID == "independent")
        let projected = try #require(ROUTINESRoutine.list(raw, projects: projects).first)
        #expect(projected.projectID == "fleet-api")
        #expect(projected.agentID == "critic")
        #expect(projected.routine.folder == "/work/fleet/services/api")
    }
    @Test func explicitIndependentAndAbsentHootProjectKeepTheirMeaning() throws {
        #expect(try #require(ROUTINESRoutine.list(routine("independent"), projects: projects).first).projectID == "independent")
        #expect(try #require(ROUTINESRoutine.list(routine(agent: "@hoot"), projects: projects).first).projectID == "every-project")
        #expect(try #require(ROUTINESRoutine.list(routine("every-project", agent: "@hoot"), projects: projects).first).projectID == "every-project")
    }
    @Test func validated128ByteExplicitIDSurvivesMissingRegistryEntry() throws {
        let exact = String(repeating: "x", count: 128)
        #expect(PROJProjects.isValidID(exact))
        #expect(try #require(ROUTINESRoutine.list(routine(exact), projects: projects).first).projectID == exact)
        let invalid = exact + "x"
        #expect(!PROJProjects.isValidID(invalid))
        #expect(try #require(ROUTINESRoutine.list(routine(invalid), projects: projects).first).projectID == "fleet-api")
    }
}
