import Foundation
import Testing
@testable import TerminalDeckNativeCore

struct SharedRulesTests {
    @Test func projectSnapshotsKeepAllFieldsAndEmptyLists() throws {
        let project = PROJProject(id: "work", name: "Work", folders: ["/one", "/two"], icon: "star", colour: "blue", logo: "logo.png", lead: "agent:lead", leadName: "Lead")
        let snapshot = NativeRPCValue.object([.init("projects", .array([project.wireValue]))])
        #expect(try PROJProjects.registeredProjects(snapshot) == [project])
        #expect(try PROJProjects.registeredProjects(.object([.init("projects", .array([]))])).isEmpty)
        #expect(throws: (any Error).self) { try PROJProjects.registeredProjects(.null) }
    }

    @Test func effortReadersShareOptionsAndKeepProviderDifferences() {
        #expect(EFFORT_CHOICES.map(\.id) == AGSCapabilities.claudeEffortOptions.map(\.id))
        #expect(Set(TerminalControlCatalog.effort.map(\.id)) == Set(AGSCapabilities.claudeEffortOptions.map(\.id)))
        #expect(AGSCapabilities.efforts(provider: "claude") == AGSCapabilities.claudeEffortOptions.map(\.id).filter { $0 != "auto" })
        #expect(AGSCapabilities.efforts(provider: "codex").contains("ultra"))
        #expect(AGSCapabilities.efforts(provider: "gemini").contains("minimal"))
    }
}
