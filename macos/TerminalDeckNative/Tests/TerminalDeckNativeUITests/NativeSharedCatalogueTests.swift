import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class NativeSharedCatalogueTests: XCTestCase {
    func testSessionMenuUsesTheBackendCatalogue() {
        let state = NativeSessionControlsState(target: .local("catalogue-test"))
        let rows = BackendSharedModelCatalog.fallbackModels + BackendSharedModelCatalog.previousModels
        let options = state.options("model")
        XCTAssertEqual(options.map(\.id), rows.map(\.alias))
        XCTAssertEqual(options.map(\.label), rows.map(\.model))
        XCTAssertEqual(options.first { $0.group != nil }?.id, BackendSharedModelCatalog.previousModels.first?.alias)
        XCTAssertEqual(state.options("effort"), TerminalControlCatalog.effort)
    }
}
