import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatLibraryRegistrationTests: XCTestCase, @unchecked Sendable {
    private func definitions(_ ids: [String]) throws -> [BackendDeckToolsDefinition] {
        try ids.map { id in
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: "Chat library registration fixture", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
            return BackendDeckToolsDefinition(spec: spec, title: spec.description) { _, _ in .value(.object([])) }
        }
    }

    func testProductionRegistrarAcceptsLibraryWithSharedChatTools() async throws {
        let server = BackendNativeMCPServer()
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        let chat = try definitions(["sessions.chat", "sessions.start_agent", "sessions.chat_library"])
        let installed = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + chat)
        XCTAssertTrue(installed.toolIDs.contains("sessions.chat_library"))
        let names = await server.registrations().map { $0.0.wireName }
        XCTAssertTrue(names.contains("sessions_chat_library"))
    }

    func testLibraryWithoutChatOwnerFailsWithoutChangingServer() async throws {
        let server = BackendNativeMCPServer()
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        _ = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline)
        let before = Set(await server.registrations().map { $0.0.id })
        do {
            _ = try await BackendDeckToolsRegistration.register(on: server,
                definitions: baseline + definitions(["sessions.chat_library"]))
            XCTFail("A library without its Chat owner was accepted")
        } catch { }
        let after = Set(await server.registrations().map { $0.0.id })
        XCTAssertEqual(before, after)
    }

    func testNativeExtensionsAndDevicePanelsRegisterWithTheChatOwner() async throws {
        let server = BackendNativeMCPServer()
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        let ids = ["sessions.chat", "sessions.start_agent", "sessions.chat_feature", "sessions.chat_organize", "sessions.chat_provider", "sessions.chat_diffs", "sessions.chat_children", "sessions.chat_terminal", "sessions.device_panels"]
        let installed = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + definitions(ids))
        XCTAssertTrue(Set(ids).isSubset(of: Set(installed.toolIDs)))
        let names = Set(await server.registrations().map { $0.0.wireName })
        XCTAssertTrue(Set(ids.map { $0.replacingOccurrences(of: ".", with: "_") }).isSubset(of: names))
    }

    func testNativeChatExtensionsCannotRegisterWithoutTheirOwner() async throws {
        for id in ["sessions.chat_feature", "sessions.chat_organize", "sessions.chat_provider", "sessions.chat_diffs", "sessions.chat_children", "sessions.chat_terminal"] {
            let server = BackendNativeMCPServer()
            let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
            _ = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline)
            let before = Set(await server.registrations().map { $0.0.id })
            do {
                _ = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + definitions([id]))
                XCTFail("A native Chat extension without its owner was accepted")
            } catch { }
            let after = Set(await server.registrations().map { $0.0.id })
            XCTAssertEqual(before, after)
        }
    }

}
