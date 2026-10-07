import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeMachinesTestsPanelsStore: XCTestCase {
    private let path = "/Users/asad/Projects/thing"
    private func read(_ rig: BackendRemoteServeMachinesTestsPanelsStoreRig, scope: String? = nil, query: String? = nil, tools: Bool = true, writable: Bool = true) async throws -> NativeRPCValue {
        let panel = try await rig.provider(tools: tools, writable: writable)
        return try await panel.read(.init(path: path, scope: scope, query: query), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func act(_ rig: BackendRemoteServeMachinesTestsPanelsStoreRig, _ action: String, _ id: String, tools: Bool = true, writable: Bool = true) async throws -> NativeRPCValue {
        let panel = try await rig.provider(tools: tools, writable: writable), run = try XCTUnwrap(panel.act)
        return try await run(.init(panel: .init(path: path, scope: nil, query: nil), action: action, id: id, fields: [:]), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func titles(_ value: NativeRPCValue) -> [String] { value["rows"].elements?.compactMap { $0["title"].string } ?? [] }
    private func row(_ value: NativeRPCValue, _ id: String) throws -> NativeRPCValue { try XCTUnwrap(value["rows"].elements?.first { $0["id"].string == id }) }
    private func actions(_ value: NativeRPCValue, _ id: String) -> [String] { value["rows"].elements?.first { $0["id"].string == id }?["actions"].elements?.compactMap { $0["id"].string } ?? [] }
    func testBothDepartmentsListBrowserToolsFirst() async throws {
        let payload = try await read(.init()); XCTAssertEqual(titles(payload), ["Images", "Tables", "filesystem", "tavily", "sqlite"])
        XCTAssertEqual(payload["path"].string, path); XCTAssertFalse(payload.has("note"))
    }
    func testDepartmentPrefixedIDsCannotCrossDepartments() async throws {
        let payload = try await read(.init()); XCTAssertEqual(payload["rows"].elements?.map { $0["id"].string }, ["tool:page-images", "tool:page-tables", "server:filesystem", "server:tavily", "server:sqlite"])
    }
    func testCostChangesToInstalledState() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(), before = try await read(rig)
        XCTAssertEqual(try row(before, "server:tavily")["value"].string, "Free to a limit, then paid")
        await rig.configure("tavily"); let after = try await read(rig); XCTAssertEqual(try row(after, "server:tavily")["value"].string, "Installed")
    }
    func testUnavailableRuntimeShowsWhyAndHasNoAction() async throws {
        let payload = try await read(.init()), row = try row(payload, "server:sqlite")
        XCTAssertEqual(row["status"].string, "warn"); XCTAssertTrue(row["detail"].string?.contains("docker is not on this machine") == true); XCTAssertFalse(row.has("actions"))
    }
    func testSearchNarrowsAcrossBothDepartments() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(), web = try await read(rig, query: "web"), table = try await read(rig, query: "table")
        XCTAssertEqual(titles(web), ["tavily"]); XCTAssertEqual(titles(table), ["Tables"])
    }
    func testSearchAlsoMatchesShelfName() async throws { let payload = try await read(.init(), query: "databases"); XCTAssertEqual(titles(payload), ["sqlite"]) }
    func testEmptySearchExplainsInsteadOfBlankScreen() async throws {
        let payload = try await read(.init(), query: "nothing at all like this"); XCTAssertEqual(payload["rows"], .array([])); XCTAssertTrue(payload["note"].string?.contains("Nothing in the store matches") == true)
    }
    func testInstalledChipFiltersAndMarksSelection() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.configure("filesystem"); let payload = try await read(rig, scope: "installed")
        XCTAssertEqual(titles(payload), ["filesystem"]); XCTAssertEqual(payload["scopes"].elements?.first { $0["on"].bool == true }?["id"].string, "installed")
    }
    func testAddableChipExcludesRuntimeUnavailableRows() async throws { let payload = try await read(.init(), scope: "addable"); XCTAssertEqual(titles(payload), ["Images", "Tables", "filesystem", "tavily"]) }
    func testEmptyInstalledChipIsNotDrawn() async throws { let payload = try await read(.init()); XCTAssertEqual(payload["scopes"].elements?.map { $0["id"].string }, ["all", "addable", "free"]) }
    func testInstallActionsIncludeFolderScopeOnlyForServer() async throws {
        let payload = try await read(.init()); XCTAssertEqual(actions(payload, "server:filesystem"), ["install", "install.here"]); XCTAssertEqual(actions(payload, "tool:page-tables"), ["install"])
    }
    func testRequiredSecretFieldNeverPrefillsValue() async throws {
        let payload = try await read(.init()), action = try XCTUnwrap(try row(payload, "server:tavily")["actions"].elements?.first { $0["id"].string == "install" })
        XCTAssertEqual(action["fields"], .array([.object([.init("id", .string("TAVILY_API_KEY")), .init("label", .string("API key")), .init("placeholder", .string("From tavily.com")), .init("required", .bool(true))])]))
    }
    func testInstallReturnsRedrawWithInstalledGreenRow() async throws {
        let payload = try await act(.init(), "install", "server:filesystem")
        XCTAssertEqual(payload["notice"].string, "filesystem was added at user scope."); XCTAssertEqual(try row(payload, "server:filesystem")["value"].string, "Installed"); XCTAssertEqual(try row(payload, "server:filesystem")["status"].string, "ok")
    }
    func testFolderInstallUsesProjectScope() async throws { let payload = try await act(.init(), "install.here", "server:filesystem"); XCTAssertEqual(payload["notice"].string, "filesystem was added at project scope.") }
    func testInstalledRowsOfferOnlyRemove() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.configure("filesystem"); await rig.configure("page-images"); let payload = try await read(rig)
        XCTAssertEqual(actions(payload, "server:filesystem"), ["remove"]); XCTAssertEqual(actions(payload, "tool:page-images"), ["remove"])
    }
    func testRemoveConfirmationNamesIrrecoverableKeys() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.configure("filesystem"); let payload = try await read(rig)
        let remove = try XCTUnwrap(try row(payload, "server:filesystem")["actions"].elements?.first { $0["id"].string == "remove" })
        XCTAssertEqual(remove["kind"].string, "destructive"); XCTAssertTrue(remove["confirm"].string?.contains("never kept a copy") == true)
    }
    func testRemovingServerRedrawsInstallActionsAgain() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.configure("filesystem"); let payload = try await act(rig, "remove", "server:filesystem")
        XCTAssertEqual(payload["notice"].string, "filesystem was removed from user."); XCTAssertEqual(actions(payload, "server:filesystem"), ["install", "install.here"])
    }
    func testBrowserToolRemovalUsesItsOwnDepartment() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.configure("page-images"); let payload = try await act(rig, "remove", "tool:page-images")
        XCTAssertEqual(payload["notice"].string, "page-images is removed."); XCTAssertEqual(actions(payload, "tool:page-images"), ["install"])
    }
    func testUnknownActionRefusesAndMutatesNothing() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(), payload = try await act(rig, "sabotage", "server:filesystem")
        XCTAssertTrue(payload["notice"].string?.contains("This store has no") == true); let count = await rig.configured.count; XCTAssertEqual(count, 0)
    }
    func testCatalogueReadFailureBecomesNoteAndOtherDepartmentSurvives() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.fail(serverRead: "store(...).read is not a function")
        let payload = try await read(rig); XCTAssertEqual(titles(payload), ["Images", "Tables"])
        XCTAssertTrue(payload["note"].string?.contains("The MCP server catalogue could not be read") == true); XCTAssertTrue(payload["note"].string?.contains("store(...).read is not a function") == true)
    }
    func testActionFailureStillRedrawsWithExactNotice() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.fail(toolInstall: "the download failed")
        let payload = try await act(rig, "install", "tool:page-tables"); XCTAssertEqual(payload["notice"].string, "That could not be done — the download failed."); XCTAssertTrue(titles(payload).contains("Tables"))
    }
    func testOnlyTheFailedDepartmentDisappears() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.fail(toolRead: "the store was never built"); let payload = try await read(rig)
        XCTAssertEqual(titles(payload), ["filesystem", "tavily", "sqlite"]); XCTAssertTrue(payload["note"].string?.contains("the store was never built") == true)
    }
    func testReadOnlyHostListsCatalogueWithoutButtons() async throws {
        let payload = try await read(.init(), tools: false, writable: false); XCTAssertEqual(titles(payload), ["filesystem", "tavily", "sqlite"])
        XCTAssertTrue(payload["rows"].elements?.allSatisfy { !$0.has("actions") } == true)
        XCTAssertTrue(payload["note"].string?.contains("cannot be read from here") == true); XCTAssertTrue(payload["note"].string?.contains("not installed from here") == true)
    }
    func testMissingCLIWriterDisablesAllButtons() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(); await rig.missingWriter(); let payload = try await read(rig, tools: false)
        XCTAssertEqual(titles(payload), ["filesystem", "tavily", "sqlite"]); XCTAssertTrue(payload["rows"].elements?.allSatisfy { !$0.has("actions") } == true)
        XCTAssertTrue(payload["note"].string?.contains("was not found on this machine") == true)
    }
    func testReadOnlyInstallRefusesRatherThanPretending() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsStoreRig(), payload = try await act(rig, "install", "server:filesystem", tools: false, writable: false)
        XCTAssertEqual(payload["notice"].string, "Nothing can be installed from here."); let count = await rig.configured.count; XCTAssertEqual(count, 0)
    }
    func testHostWithNoStoreHasOneExactNote() async throws {
        let panel = try BackendRemotePanelStore.provider(categoryNames: [:])
        let payload = try await panel.read(.init(path: path, scope: nil, query: nil), .init(caller: .nativeApp, ownerID: "test"))
        XCTAssertEqual(payload["rows"], .array([])); XCTAssertEqual(payload["note"].string, "The tools this app installs into its own browser cannot be read from here. The MCP server catalogue cannot be read from here.")
    }
}
private struct BackendRemoteServeMachinesTestsPanelsStoreError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
private actor BackendRemoteServeMachinesTestsPanelsStoreRig {
    private(set) var configured: Set<String> = []
    private var writerFound = true, serverReadError: String?, toolReadError: String?, toolInstallError: String?
    func configure(_ id: String) { configured.insert(id) }
    func missingWriter() { writerFound = false }
    func fail(serverRead: String? = nil, toolRead: String? = nil, toolInstall: String? = nil) { serverReadError = serverRead; toolReadError = toolRead; toolInstallError = toolInstall }
    func provider(tools: Bool = true, writable: Bool = true) throws -> BackendRemotePanelProvider {
        let toolDepartment = tools ? BackendRemotePanelStore.Department(read: { _, _ in try await self.tools() }, install: { id, _ in try await self.installTool(id) }, remove: { id, _ in await self.removeTool(id) }) : nil
        let servers = BackendRemotePanelStore.Department(read: { _, _ in try await self.servers() }, install: writable ? { @Sendable input, _ in await self.installServer(input) } : nil, remove: writable ? { @Sendable input, _ in await self.removeServer(input) } : nil)
        return try BackendRemotePanelStore.provider(tools: toolDepartment, servers: servers, categoryNames: ["data": "Databases", "web": "Web", "files": "Files", "utility": "Utility"])
    }
    private func tools() throws -> NativeRPCValue {
        if let toolReadError { throw BackendRemoteServeMachinesTestsPanelsStoreError(message: toolReadError) }
        return .object([.init("tools", .array([tool("page-images", "Images", "Every image on the page."), tool("page-tables", "Tables", "Every table on the page.")]))])
    }
    private func tool(_ id: String, _ name: String, _ summary: String) -> NativeRPCValue { .object([.init("id", .string(id)), .init("name", .string(name)), .init("summary", .string(summary)), .init("state", .string(configured.contains(id) ? "installed" : "available")), .init("message", .string(""))]) }
    private func servers() throws -> NativeRPCValue {
        if let serverReadError { throw BackendRemoteServeMachinesTestsPanelsStoreError(message: serverReadError) }
        let key = NativeRPCValue.object([.init("key", .string("TAVILY_API_KEY")), .init("label", .string("API key")), .init("hint", .string("From tavily.com")), .init("kind", .string("secret")), .init("into", .string("env")), .init("required", .bool(true)), .init("inEnvironment", .bool(false))])
        return .object([.init("rows", .array([server("filesystem", "Reads and writes files under one directory.", "files", tags: ["disk"]), server("tavily", "Searches the web and reads the results.", "web", cost: "metered", inputs: [key]), server("sqlite", "Queries a SQLite database.", "data", unavailable: true)])), .init("writer", .object([.init("found", .bool(writerFound)), .init("path", .string(writerFound ? "/usr/local/bin/claude" : ""))]))])
    }
    private func server(_ id: String, _ summary: String, _ category: String, tags: [String] = [], cost: String = "free", inputs: [NativeRPCValue] = [], unavailable: Bool = false) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(id)), .init("summary", .string(summary)), .init("category", .string(category)), .init("tags", .array(tags.map(NativeRPCValue.string))), .init("cost", .string(cost)), .init("inputs", .array(inputs)), .init("state", .string(unavailable ? "unavailable" : configured.contains(id) ? "installed" : "available")), .init("scope", .string(configured.contains(id) ? "user" : "")), .init("runtimeMissing", .bool(unavailable)), .init("blocked", .string(unavailable ? "docker is not on this machine. It needs Docker Desktop" : "")), .init("caveat", .string(""))])
    }
    private func outcome(_ text: String) -> NativeRPCValue { .object([.init("ok", .bool(true)), .init("message", .string(text))]) }
    private func installTool(_ raw: NativeRPCValue) throws -> NativeRPCValue { if let toolInstallError { throw BackendRemoteServeMachinesTestsPanelsStoreError(message: toolInstallError) }; let id = raw.string!; configured.insert(id); return outcome("\(id) is installed.") }
    private func removeTool(_ raw: NativeRPCValue) -> NativeRPCValue { let id = raw.string!; configured.remove(id); return outcome("\(id) is removed.") }
    private func installServer(_ input: NativeRPCValue) -> NativeRPCValue { let id = input["id"].string!; configured.insert(id); return outcome("\(id) was added at \(input["scope"].string!) scope.") }
    private func removeServer(_ input: NativeRPCValue) -> NativeRPCValue { let id = input["name"].string!; configured.remove(id); return outcome("\(id) was removed from \(input["scope"].string!).") }
}
