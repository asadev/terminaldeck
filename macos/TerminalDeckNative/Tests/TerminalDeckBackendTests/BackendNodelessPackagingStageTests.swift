import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendNodelessPackagingStageTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private func receipt() -> BackendNodelessPackagingGateReceipt {
        .init(inventorySHA256: digest, sourceSHA256: digest, graphSHA256: digest, artifactSetSHA256: digest,
              domains: [], combinedGateEvidence: [], visualGateEvidence: [], ownershipTransferEvidence: [],
              noMainNodeFallbackEvidence: [], staysFixedChoice: .pending, asadDecisionEvidence: nil,
              staysFixedCompatibilityEvidence: [], pluginCompatibilityEvidence: [], unresolved: ["The combined gate has not run."])
    }
    private func plan(app: String) -> BackendNodelessPackagingStagePlan {
        let artifact = BackendNodelessPackagingArtifact(path: "Contents/MacOS/TerminalDeckNative", sha256: digest, kind: .nativeExecutable, executable: true)
        let manifest = BackendNodelessPackagingManifest(version: "fixture", architecture: "arm64", mode: .nativeOnly,
            inventorySHA256: digest, sourceSHA256: digest, graphSHA256: digest, artifacts: [artifact])
        return .init(appRelativePath: app, manifest: manifest, inputs: [.init(source: "input", artifact: artifact)])
    }
    func testUnperformedGateRefusesBeforeCreatingAnApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendNodelessStage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try BackendNodelessPackagingStage.stage(plan: plan(app: "Fixture.app"), receipt: receipt(), receiptRelativePath: "receipt.json", buildRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Fixture.app").path))
    }
    func testExistingAppAndTraversalArePreservedAndRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendNodelessStage-" + UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: app.appendingPathComponent("marker"))
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Fixture.app", "../Escape.app"] {
            XCTAssertThrowsError(try BackendNodelessPackagingStage.stage(plan: plan(app: name), receipt: receipt(), receiptRelativePath: "receipt.json", buildRoot: root))
        }
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "keep")
    }
}
