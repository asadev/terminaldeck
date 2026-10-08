import XCTest
@testable import TerminalDeckBackend

/// O2 (8 Oct 2026, release blocker): Machines must start with the panels that are actually supplied.
/// The phone panels widened BackendRemotePanelRegistry.Domain to cases that are deliberately never
/// supplied (memory, plugins, github, ai-apps); requiring every case made every launch fail.
final class O2MachinePanelRequirementTests: XCTestCase {
    /// What production registers: 4 in NativeCompositionProductionMachines + 7 phone panels.
    private let productionSupplied = ["artifacts", "store", "readiness", "mcp",
                                      "tasks", "goals", "staysfixed", "settings", "simulators", "hooks", "servers"]

    func testElevenSuppliedDomainsAreEnough() {
        XCTAssertEqual(productionSupplied.count, 11)
        XCTAssertTrue(BackendMachineRegistration.hasRequiredPanels(productionSupplied))
        XCTAssertTrue(BackendMachineRegistration.hasRequiredPanels(["artifacts", "store", "readiness", "mcp"]))
        XCTAssertLessThan(Set(productionSupplied).count, BackendRemotePanelRegistry.Domain.allCases.count,
                          "some domains are never supplied, so equality with allCases can never hold")
    }

    func testAMissingRequiredPanelIsRefused() {
        for missing in ["artifacts", "store", "readiness", "mcp"] {
            XCTAssertFalse(BackendMachineRegistration.hasRequiredPanels(productionSupplied.filter { $0 != missing }), missing)
        }
        XCTAssertFalse(BackendMachineRegistration.hasRequiredPanels([]))
    }
}
