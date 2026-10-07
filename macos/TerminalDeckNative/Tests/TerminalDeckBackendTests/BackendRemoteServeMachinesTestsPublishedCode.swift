import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendRemoteServeMachinesTestsPublishedCode: XCTestCase {
    func testNoProductionCallerMintsUnpublishedCode() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = package.appendingPathComponent("Sources", isDirectory: true)
        let paths = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]))
        var callers: [String] = []
        for case let file as URL in paths where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?m)(^|\s)//.*$"#, with: "", options: .regularExpression)
            if text.range(of: #"\.\s*createPairingOffer\s*\("#, options: .regularExpression) != nil { callers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(callers.sorted(), ["BackendRemoteHostService.swift"])
        // The service publishes; raw trust-store minting is for the fixtures.
        // This source contract invokes no pairing or relay operation.
    }
}
