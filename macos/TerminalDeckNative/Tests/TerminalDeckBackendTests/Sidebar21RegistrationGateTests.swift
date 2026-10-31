import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Sidebar21RegistrationGateTests: XCTestCase, @unchecked Sendable {
    private func sidebarDefinitions() throws -> [BackendDeckToolsDefinition] {
        try ["sidebar.pages.list", "sidebar.page.open", "sidebar.page.pin", "sidebar.pages.reorder"].map { id in
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: "Side panel gate fixture", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
            return BackendDeckToolsDefinition(spec: spec, title: spec.description) { _, _ in .value(.object([])) }
        }
    }

    func testProductionRegistrarAcceptsTheCompleteSidebarFamily() async throws {
        let server = BackendNativeMCPServer()
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        let sidebar = try sidebarDefinitions()
        let installed = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + sidebar)
        XCTAssertTrue(Set(sidebar.map { $0.spec.id }).isSubset(of: Set(installed.toolIDs)))
        let names = Set(await server.registrations().map { $0.0.wireName })
        XCTAssertTrue(Set(sidebar.map { $0.spec.wireName }).isSubset(of: names))
    }

    func testPartialSidebarFamilyFailsBeforeChangingTheServer() async throws {
        let server = BackendNativeMCPServer()
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        _ = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline)
        let before = Set(await server.registrations().map { $0.0.id })
        let sidebar = try sidebarDefinitions()
        do {
            _ = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + [sidebar[0]])
            XCTFail("A partial sidebar family was accepted")
        } catch { }
        let after = Set(await server.registrations().map { $0.0.id })
        XCTAssertEqual(before, after)
    }
}
