import Foundation
import XCTest
@testable import TerminalDeckBackend

/// Synthetic receipt fixtures exercise policy only. They are not observations
/// of a real native app, compiled helper, browser or installed plugin corpus.
final class BackendNodelessPackagingPolicyTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private var nativeArtifacts: [BackendNodelessPackagingArtifact] {
        [.init(path: "Contents/MacOS/TerminalDeckNative", sha256: digest, kind: .nativeExecutable, executable: true),
         .init(path: "Contents/MacOS/TerminalDeckNativeHelper", sha256: digest, kind: .nativeExecutable, executable: true),
         .init(path: BackendNodelessPackagingPolicy.helperPath, sha256: digest, kind: .javaScriptCoreHelper, executable: true),
         .init(path: "Contents/Resources/licenses/SwiftTerm.txt", sha256: digest, kind: .notice)]
    }
    private func manifest(mode: BackendNodelessPackagingMode = .nativeOnly, artifacts: [BackendNodelessPackagingArtifact]? = nil) -> BackendNodelessPackagingManifest {
        .init(version: "fixture", architecture: "arm64", mode: mode, inventorySHA256: digest, sourceSHA256: digest,
              graphSHA256: digest, artifacts: artifacts ?? nativeArtifacts)
    }
    private func receipt(choice: BackendNodelessStaysFixedChoice = .javaScriptCore, phase: BackendNodelessPackagingPhase = .verified,
                         domains: [BackendNodelessPackagingDomainReceipt]? = nil, artifactHash: String? = nil,
                         decision: String? = "reports/decision.txt", unresolved: [String] = []) -> BackendNodelessPackagingGateReceipt {
        .init(inventorySHA256: digest, sourceSHA256: digest, graphSHA256: digest, artifactSetSHA256: artifactHash ?? digest,
              domains: domains ?? BackendNodelessPackagingPolicy.requiredDomains.sorted().map { .init(id: $0, phase: phase, evidence: ["reports/combined.txt"]) },
              combinedGateEvidence: ["reports/combined.txt"], visualGateEvidence: ["reports/visual.txt"],
              ownershipTransferEvidence: ["reports/ownership.txt"], noMainNodeFallbackEvidence: ["reports/no-fallback.txt"],
              staysFixedChoice: choice, asadDecisionEvidence: decision, staysFixedCompatibilityEvidence: ["reports/product.txt"],
              pluginCompatibilityEvidence: ["reports/plugins.txt"], unresolved: unresolved)
    }
    private func evaluate(_ manifest: BackendNodelessPackagingManifest, _ receipt: BackendNodelessPackagingGateReceipt) -> BackendNodelessPackagingReport {
        BackendNodelessPackagingPolicy.evaluate(manifest: manifest, receipt: receipt, artifactSetSHA256: digest)
    }
    func testWrittenAndWiredCodeNeverCountAsVerifiedGraph() {
        for phase in [BackendNodelessPackagingPhase.written, .wired] {
            let report = evaluate(manifest(), receipt(phase: phase))
            XCTAssertFalse(report.allowed); XCTAssertFalse(report.entireBundleNodeFree)
            XCTAssertTrue(report.reasons.contains { $0.contains("not verified") })
        }
    }
    func testEveryNamedDomainAndUniqueReceiptAreRequired() {
        var domains = BackendNodelessPackagingPolicy.requiredDomains.sorted().map { BackendNodelessPackagingDomainReceipt(id: $0, phase: .verified, evidence: ["report"]) }
        domains.removeAll { $0.id == "ssh-enrollment" }
        XCTAssertTrue(evaluate(manifest(), receipt(domains: domains)).reasons.contains("Native verification is unavailable for ssh-enrollment."))
        domains.append(domains[0])
        XCTAssertFalse(evaluate(manifest(), receipt(domains: domains)).allowed)
    }
    func testChangedArtifactReceiptAndOpenCompatibilityGapsRefuse() {
        XCTAssertFalse(evaluate(manifest(), receipt(artifactHash: String(repeating: "b", count: 64))).allowed)
        let unresolved = evaluate(manifest(), receipt(unresolved: ["Installed plugin uses an unsupported npm dependency."]))
        XCTAssertFalse(unresolved.allowed)
        XCTAssertTrue(unresolved.reasons.contains("Installed plugin uses an unsupported npm dependency."))
    }
    func testPendingOrMissingAsadDecisionCannotSelectShippingMode() {
        XCTAssertFalse(evaluate(manifest(), receipt(choice: .pending)).allowed)
        XCTAssertFalse(evaluate(manifest(), receipt(decision: nil)).allowed)
        XCTAssertFalse(evaluate(manifest(mode: .nativeAppWithIsolatedStaysFixed), receipt()).allowed)
    }
    func testRequiredExecutablesCannotBeSatisfiedByResourceLabelsOrNonExecutableFiles() {
        for index in 0..<3 {
            var artifacts = nativeArtifacts
            let old = artifacts[index]
            artifacts[index] = .init(path: old.path, sha256: old.sha256, kind: .resource, executable: false)
            XCTAssertFalse(evaluate(manifest(artifacts: artifacts), receipt()).allowed)
        }
    }
    func testLegacyAppEngineAddonAndChromiumPayloadsAreRejected() {
        for path in ["Contents/Resources/engine/engine.cjs", "Contents/Resources/runtime/bin/node",
                     "Contents/Resources/native/binding.node", "Contents/Frameworks/Electron.framework/Electron",
                     "Contents/Resources/Chromium.app/Contents/MacOS/Chromium", "Contents/Resources/node_modules/other/index.js"] {
            let artifacts = nativeArtifacts + [.init(path: path, sha256: digest, kind: .resource)]
            XCTAssertFalse(evaluate(manifest(artifacts: artifacts), receipt()).allowed, path)
        }
    }
    func testIsolatedProductIsApprovedBoundedAndNeverClaimedEntirelyNodeFree() {
        let artifacts = nativeArtifacts + [
            .init(path: BackendNodelessPackagingPolicy.productRuntimePath, sha256: digest, kind: .staysFixedRuntime, executable: true),
            .init(path: BackendNodelessPackagingPolicy.productNoticePrefix + "Node.txt", sha256: digest, kind: .notice),
            .init(path: BackendNodelessPackagingPolicy.productPackagePrefix + "node_modules/staysfixed/src/index.js", sha256: digest, kind: .staysFixedPackage)]
        let report = evaluate(manifest(mode: .nativeAppWithIsolatedStaysFixed, artifacts: artifacts), receipt(choice: .isolatedRuntime))
        XCTAssertTrue(report.allowed); XCTAssertFalse(report.entireBundleNodeFree)
        XCTAssertFalse(evaluate(manifest(artifacts: artifacts), receipt()).allowed)
        let stray = artifacts + [.init(path: BackendNodelessPackagingPolicy.productPackagePrefix + "hidden-tool", sha256: digest, kind: .nativeExecutable, executable: true)]
        XCTAssertFalse(evaluate(manifest(mode: .nativeAppWithIsolatedStaysFixed, artifacts: stray), receipt(choice: .isolatedRuntime)).allowed)
    }
    func testPathDigestAndSelfDigestRefusalsAndOrderStableHash() {
        for path in ["/Contents/MacOS/tool", "Contents/../tool", "Contents//tool", "Contents/./tool", "Contents\\tool", "Contents/a\0b"] {
            XCTAssertFalse(BackendNodelessPackagingPolicy.validPath(path))
        }
        XCTAssertFalse(BackendNodelessPackagingPolicy.validDigest(digest + "\n"))
        XCTAssertFalse(BackendNodelessPackagingPolicy.validDigest(digest.uppercased()))
        XCTAssertEqual(BackendNodelessPackagingFiles.artifactSetDigest(nativeArtifacts), BackendNodelessPackagingFiles.artifactSetDigest(Array(nativeArtifacts.reversed())))
        let selfEntry = nativeArtifacts + [.init(path: BackendNodelessPackagingPolicy.manifestPath, sha256: digest, kind: .resource)]
        XCTAssertFalse(evaluate(manifest(artifacts: selfEntry), receipt()).allowed)
    }
}
