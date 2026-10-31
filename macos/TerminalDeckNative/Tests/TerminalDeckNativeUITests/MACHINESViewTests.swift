import Foundation
import XCTest

/// Real XCTest entry points. The dedicated runner never launches Terminal Deck.
final class MACHINESViewTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testViewSourcesStayInsideThePackage() throws {
        let directory = packageRoot.appendingPathComponent("Tests/TerminalDeckNativeUITests")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]))
        for case let file as URL in files where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            XCTAssertEqual(values.isSymbolicLink, false, file.lastPathComponent)
            XCTAssertEqual(values.isRegularFile, true, file.lastPathComponent)
        }
    }

    func testSourceLayoutHasNoBackupsNotesOrEmptyTestTargets() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: packageRoot.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil))
        for case let file as URL in files {
            XCTAssertFalse(["orig", "md"].contains(file.pathExtension), file.lastPathComponent)
        }
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"\.testTarget\(\s*name:\s*"([^"]+)""#)
        let text = manifest as NSString
        let targets = expression.matches(in: manifest, range: NSRange(location: 0, length: text.length))
        XCTAssertFalse(targets.isEmpty)
        for target in targets {
            let name = text.substring(with: target.range(at: 1))
            let directory = packageRoot.appendingPathComponent("Tests/" + name)
            let sources = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            XCTAssertTrue(sources.allObjects.compactMap { $0 as? URL }.contains { $0.pathExtension == "swift" }, name)
        }
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_WIP"] == "MACHINES" else { throw XCTSkip("WIP MACHINES") }
    }
    func testMCPToolSecurity() {
        let done = expectation(description: "MACHINES MCP checks")
        Task { @MainActor in
            defer { done.fulfill() }
            do {
                let count = try await MACHINESMCPFocusedChecks.run()
                XCTAssertEqual(count, 16)
                print("MACHINES MCP focused checks: \(count) passed; no app, AI or server calls")
            } catch { XCTFail(error.localizedDescription) }
        }
        wait(for: [done], timeout: 15)
    }

    func testModelInteractions() {
        let done = expectation(description: "MACHINES model checks")
        Task { @MainActor in
            defer { done.fulfill() }
            do {
                let count = try await MACHINESRenderEvidence.focusedChecks()
                XCTAssertEqual(count, 16)
                print("MACHINES model focused checks: \(count) passed; no app, AI or server calls")
            } catch { XCTFail(error.localizedDescription) }
        }
        wait(for: [done], timeout: 15)
    }

    @MainActor
    func testLightAndDarkContentRenders() throws {
        guard ProcessInfo.processInfo.environment["MACHINES_RENDER_VIEWS"] == "1" else {
            throw XCTSkip("Set MACHINES_RENDER_VIEWS=1 for fixed-frame content snapshots.")
        }
        let out = packageRoot.deletingLastPathComponent().appendingPathComponent("design-2026-10-10/built.noindex", isDirectory: true)
        try MACHINESRenderEvidence.renderAll(to: out)
    }
}
