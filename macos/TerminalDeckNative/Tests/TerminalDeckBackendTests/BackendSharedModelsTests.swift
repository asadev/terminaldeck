import XCTest
@testable import TerminalDeckBackend

final class BackendSharedModelsTests: XCTestCase {
    func testPickerReadsBothRealTerminalCaptures() throws {
        let mac = try XCTUnwrap(BackendSharedModelCatalog.readModelPicker(BackendSharedModelFixtures.macPicker))
        XCTAssertEqual(mac.map(\.name), ["Default (recommended)", "Opus (1M context)", "Fable", "Sonnet", "Haiku", "Opus"])
        XCTAssertEqual(mac.filter(\.current).map(\.name), ["Opus"])
        XCTAssertEqual(mac.filter(\.recommended).map(\.name), ["Default (recommended)"])
        let windows = try XCTUnwrap(BackendSharedModelCatalog.readModelPicker(BackendSharedModelFixtures.windowsPicker))
        XCTAssertEqual(windows.map(\.name), ["Default (recommended)", "Opus (1M context)", "Fable", "Sonnet", "Haiku"])
        XCTAssertEqual(windows.filter(\.current).map(\.name), ["Default (recommended)"])
    }
    func testHeadingAndCompleteRowsRequired() {
        for screen in [BackendSharedModelFixtures.cancelled, BackendSharedModelFixtures.boot, BackendSharedModelFixtures.fastOn, "An answer\n1. Opus  the big one\n2. Sonnet  the small one", "Select model\n1. Default (recommended)  Opus 5"] {
            XCTAssertNil(BackendSharedModelCatalog.readModelPicker(screen))
        }
    }
    func testAliasesAreDerivedAndSafeToType() {
        for (name, alias) in [("Default (recommended)", "default"), ("Opus (1M context)", "opus[1m]"), ("Opus ✔", "opus"), ("Opus Plan", "opusplan"), ("Sonnet", "sonnet")] { XCTAssertEqual(BackendSharedModelCatalog.aliasForRow(name), alias) }
        for row in BackendSharedModelCatalog.fallbackModels + BackendSharedModelCatalog.previousModels { XCTAssertTrue(BackendSharedModelCatalog.isTypeableModelValue(row.alias)) }
        for value in ["sonnet 5", "sonnet\r", "sonnet\nrm -rf /", "/model sonnet", "", " ", "a b", "ſonnet"] { XCTAssertFalse(BackendSharedModelCatalog.isTypeableModelValue(value)) }
    }
    func testDefaultFoldsIntoItsActualTwinAndCarriesSelection() throws {
        let rows = try XCTUnwrap(BackendSharedModelCatalog.readModelPicker(BackendSharedModelFixtures.windowsPicker))
        let folded = BackendSharedModelCatalog.foldDefaultRow(rows)
        XCTAssertEqual(folded.filter(\.current).map(\.name), ["Opus (1M context)"])
        XCTAssertEqual(folded.filter(\.recommended).map(\.name), ["Opus (1M context)"])
        let unmatched: [BackendSharedModelRow] = [.init(alias: "default", name: "Default (recommended)", model: "Something 9", current: true, recommended: true), .init(alias: "sonnet", name: "Sonnet", model: "Sonnet 5")]
        XCTAssertEqual(BackendSharedModelCatalog.foldDefaultRow(unmatched).first?.name, "Something 9")
        XCTAssertEqual(BackendSharedModelCatalog.foldDefaultRow(unmatched).first?.current, true)
        XCTAssertFalse(BackendSharedModelCatalog.fallbackModels.contains { $0.alias == "default" })
    }
}
