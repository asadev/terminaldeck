import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Agent public identity lookup keeps private profiles private")
struct AgentPublicProfileLookupTests {
    @Test func namesAndCaseFoldedIDsAlwaysUseThePublicReader() async throws {
        let config = try BackendTaskConfiguration(persistence: .init(directory: URL(fileURLWithPath: "/agent-public-memory"), ownership: .memory))
        try await config.start()
        let row = try await config.saveAgent(.object([.init("id", .string("saved-worker")), .init("name", .string("Another builder")),
            .init("provider", .string("codex")), .init("model", .string("chosen-model")), .init("instructions", .string("PRIVATE-FIXTURE-NOTES"))]))
        let authority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { _ in }, visible: { _, _ in true }, project: { _, _ in },
            authorize: { _, _, _, _ in }, actorName: { _ in "Seat" }, callerKeyID: { _ in nil })
        let service = BackendAGTDirectoryService(config: config, authority: authority, profileRead: { _, id in
            #expect(id == row["id"].string)
            return BackendAgentStartSelection.publicProfile(row)
        })
        let caller = BackendMCPCallContext(sessionID: "seat", machineID: "", projectRoot: "/fixture", attended: true,
            allowedTools: ["agents.profile"], allowedTiers: [.read], cancellation: .init())
        for name in ["saved-worker", "SAVED-WORKER", "ANOTHER BUILDER"] {
            let value = try await service.invoke("agents.profile", arguments: .object([.init("id", .string(name))]), caller: caller)
            #expect(value["coverage"].string == "public-agent-identity")
            #expect(value["model"].string == "chosen-model")
            #expect(!value.compact.contains("PRIVATE-FIXTURE-NOTES"))
            #expect(!value.has("settings") && !value.has("sessions"))
        }
        try await config.stop()
    }
}
