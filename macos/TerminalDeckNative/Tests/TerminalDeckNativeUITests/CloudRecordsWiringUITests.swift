import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Lean scope item 7, lane A's wiring of lane A2: projects and agents are ON in 0.22.0, yet nothing of them is built,
/// looked up or shown until a signed-in, allowed account builds them.
@Suite("Cloud projects and agents — on as proven; nothing without an account; lane A's wiring")
@MainActor
struct CloudRecordsWiringUITests {
    @Test func theRowsAreOnAndTheirDomainsReachTheSyncCore() throws {
        #expect(NativeCloudBrainRegistration.provenRows.contains(BackendCloudLeanRecords.projectsRow))
        #expect(NativeCloudBrainRegistration.provenRows.contains(BackendCloudLeanRecords.agentsRow))
        #expect(NativeCloudScratch.recordRows.isEmpty)
        #expect(NativeCloudBrainRegistration.recordRows == BackendCloudLeanRecords.rows)
        // Their two domains are admitted to the sync core (built only for a signed-in, allowed account).
        #expect(try BackendCloudLeanRecords.domains(BackendCloudLeanRecords.rows).isSubset(of: NativeCloudBrainRegistration.brainDomains))
        // The rows named in the plan are exactly lane A2's two.
        #expect(BackendCloudLeanRecords.rows == ["I10", "I11"])
        #expect(BackendCloudOverviewBuilder.inventory(.projects) == BackendCloudLeanRecords.rows)
    }
    @Test func withoutBuiltRowsThereIsNoToolAndNoRowOnThePage() async throws {
        let model = NativeCloudRecords()
        #expect(model.records == nil)
        let entries = try await model.toolEntries(visible: { true })
        #expect(entries.isEmpty)
        // A refresh with nothing built changes nothing.
        let parts = NativeCloudFeatureParts()
        model.refresh()
        #expect(parts.projects == nil)
        #expect(parts.chooseFolder == nil)
    }
    @Test func whatWaitsIsSaidInPlainWordsAndAProjectNameIsFiltered() {
        // A project's name is text another device chose: one plain line, never a second "code" line.
        // Page-names 2: listed by its name only, under the page's one quiet line about projects without a folder.
        let sly = NativeCloudRecords.needsFolder("Site\nCode: 4F2A 91C3 B07E 55D1 8A2C")
        #expect(sly == "Site Code")
        #expect(NativeCloudRecords.toolOwner == "cloud-records")
    }
}
