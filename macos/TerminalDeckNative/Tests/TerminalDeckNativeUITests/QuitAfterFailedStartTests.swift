import XCTest

/// 2 Nov 06:37: the dev copy aborted while quitting after a failed start ("session host unavailable").
/// AppModel.prepareShutdown → NativeCompositionINT2HOSTManaged.current.stopAppAccountSignIns read its `unowned`
/// owner, the production graph the failed start had already freed (swift_abortRetainUnowned). The quit path must
/// never reach a freed owner: `current` is weak, a failed start clears it, and both quit entry points check the
/// owner is still alive before using it.
final class QuitAfterFailedStartTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/" + file), encoding: .utf8)
    }
    private func body(_ text: String, of function: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(function)"), function)
        let end = text.range(of: "\n    func ", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return text[start.lowerBound..<end]
    }

    func testTheQuitPathNeverReachesAFreedProductionGraph() throws {
        let managed = try source("NativeCompositionINT2HOSTManaged.swift")
        XCTAssertTrue(managed.contains("static weak var current: NativeCompositionINT2HOSTManaged?"))
        XCTAssertTrue(managed.contains("private weak var liveOwner: NativeCompositionProduction?"))
        for function in ["stopAppAccountSignIns()", "keepForExit()"] {
            let text = try body(managed, of: function)
            let guardAt = try XCTUnwrap(text.range(of: "guard let owner = liveOwner else { return }"), function)
            // Nothing in the function touches the production graph before the liveness check.
            XCTAssertNil(text[text.startIndex..<guardAt.lowerBound].range(of: "owner."), function)
        }
        let start = try source("NativeCompositionProductionStart.swift")
        let release = try body(start, of: "releaseAfterFailedStart()")
        XCTAssertTrue(release.contains("NativeCompositionINT2HOSTManaged.current === hostManaged { NativeCompositionINT2HOSTManaged.current = nil }"))
    }
}
