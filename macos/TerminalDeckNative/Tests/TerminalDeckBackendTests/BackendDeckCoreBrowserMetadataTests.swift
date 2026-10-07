import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreBrowserMetadataTests: XCTestCase {
    func testSourceDisclosureDecoratesActualSpecWithoutReplacingCapability() throws {
        let schema = try BackendBrowserFactories.schema(for: .read)
        let actual = try BackendMCPTool(id: "browser.read", wireName: "browser_read", description: "Actual native capability description",
            inputSchema: schema, tier: .read)
        let row = try XCTUnwrap(BackendDeckCoreBrowserMetadata.entries(specs: [actual]).first)
        XCTAssertEqual(row.title, "Read the page")
        XCTAssertNil(row.index)
        XCTAssertEqual(row.tool.description, actual.description)
        XCTAssertEqual(row.tool.inputSchema, schema)
        XCTAssertEqual(row.tool.tier, actual.tier)
    }
    func testBrowserMapHasSixFullVerbsAndTenHeldToolsWithoutRetiredChrome() throws {
        let rows = try BackendDeckCoreBrowserMetadata.sourceDescriptors()
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(Set(rows.filter { $0["index"].isNullish }.compactMap { $0["id"].string }),
            ["browser.open", "browser.read", "browser.step", "browser.screenshot", "browser.handover", "browser.close"])
        XCTAssertFalse(rows.contains { BackendDeckCoreBrowserMetadata.retiredIDs.contains($0["id"].string ?? "") })
    }
    func testCompleteFixtureCannotSilentlyDropUnavailableOrDuplicateSpecs() throws {
        XCTAssertThrowsError(try BackendDeckCoreBrowserMetadata.entries(specs: [], requireComplete: true))
        let actual = try BackendMCPTool(id: "browser.read", wireName: "browser_read", description: "Read", inputSchema: BackendBrowserFactories.schema(for: .read), tier: .read)
        XCTAssertThrowsError(try BackendDeckCoreBrowserMetadata.entries(specs: [actual, actual]))
        XCTAssertThrowsError(try BackendDeckCoreBrowserMetadata.entries(specs: [actual], requireComplete: true))
    }
}
