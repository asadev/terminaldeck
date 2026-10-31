import XCTest

/// U35 (#41): the divider's drag must read the pointer across the whole split; named on the
/// 8-pt bar itself, every drag snapped the first pane to its smallest size.
final class SplitDividerTests: XCTestCase {
    func testDividerDragMeasuresAcrossTheWholeSplit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeLayoutScreen.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.range(of: "GeometryReader { box in"))
        let divider = try XCTUnwrap(source.range(of: "private func divider(size: Double)"))
        let end = try XCTUnwrap(source.range(of: "private func send(_ value: Double)"))
        XCTAssertTrue(source[body.lowerBound..<divider.lowerBound].contains(".coordinateSpace(name: splitId)"))
        XCTAssertFalse(source[divider.lowerBound..<end.lowerBound].contains(".coordinateSpace("))
        XCTAssertTrue(source[divider.lowerBound..<end.lowerBound].contains("coordinateSpace: .named(splitId)"))
    }
}
