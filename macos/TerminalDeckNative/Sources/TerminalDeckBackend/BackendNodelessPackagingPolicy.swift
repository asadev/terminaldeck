import Foundation

/// Source-only release gate. The integration owner supplies observations from
/// the single combined gate; writing or registering source is never a pass.
public enum BackendNodelessPackagingMode: String, Codable, Sendable {
    case nativeOnly
    case nativeAppWithIsolatedStaysFixed
    case nativeAppWithExternalStaysFixed
}
public enum BackendNodelessPackagingPhase: String, Codable, Sendable { case written, wired, verified }
/// `onDemandRuntime` is night-plan decision D2 (6 Oct 2026): no Node in the
/// bundle; Stays Fixed fetches its own pinned Node the first time it is used
/// (BackendNodelessStaysFixedRuntime). It pairs with the external mode.
public enum BackendNodelessStaysFixedChoice: String, Codable, Sendable { case pending, isolatedRuntime, javaScriptCore, userProvidedRuntime, onDemandRuntime }
public enum BackendNodelessPackagingArtifactKind: String, Codable, Sendable {
    case nativeExecutable, resource, notice, remoteHostArchive, javaScriptCoreHelper, staysFixedRuntime, staysFixedPackage
}
public struct BackendNodelessPackagingArtifact: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let kind: BackendNodelessPackagingArtifactKind
    public let executable: Bool
    public init(path: String, sha256: String, kind: BackendNodelessPackagingArtifactKind, executable: Bool = false) {
        self.path = path; self.sha256 = sha256; self.kind = kind; self.executable = executable
    }
}
public struct BackendNodelessPackagingManifest: Codable, Equatable, Sendable {
    public let format: Int
    public let version: String
    public let architecture: String
    public let mode: BackendNodelessPackagingMode
    public let inventorySHA256: String
    public let sourceSHA256: String
    public let graphSHA256: String
    public let artifacts: [BackendNodelessPackagingArtifact]
    public init(format: Int = 1, version: String, architecture: String, mode: BackendNodelessPackagingMode,
                inventorySHA256: String, sourceSHA256: String, graphSHA256: String, artifacts: [BackendNodelessPackagingArtifact]) {
        self.format = format; self.version = version; self.architecture = architecture; self.mode = mode
        self.inventorySHA256 = inventorySHA256; self.sourceSHA256 = sourceSHA256; self.graphSHA256 = graphSHA256; self.artifacts = artifacts
    }
}
public struct BackendNodelessPackagingDomainReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let phase: BackendNodelessPackagingPhase
    public let evidence: [String]
    public let unresolved: [String]
    public init(id: String, phase: BackendNodelessPackagingPhase, evidence: [String], unresolved: [String] = []) {
        self.id = id; self.phase = phase; self.evidence = evidence; self.unresolved = unresolved
    }
}
public struct BackendNodelessPackagingGateReceipt: Codable, Equatable, Sendable {
    public let format: Int
    public let inventorySHA256: String
    public let sourceSHA256: String
    public let graphSHA256: String
    public let artifactSetSHA256: String
    public let domains: [BackendNodelessPackagingDomainReceipt]
    public let combinedGateEvidence: [String]
    public let visualGateEvidence: [String]
    public let ownershipTransferEvidence: [String]
    public let noMainNodeFallbackEvidence: [String]
    public let staysFixedChoice: BackendNodelessStaysFixedChoice
    public let asadDecisionEvidence: String?
    public let staysFixedCompatibilityEvidence: [String]
    public let pluginCompatibilityEvidence: [String]
    public let unresolved: [String]
    public init(format: Int = 1, inventorySHA256: String, sourceSHA256: String, graphSHA256: String, artifactSetSHA256: String,
                domains: [BackendNodelessPackagingDomainReceipt], combinedGateEvidence: [String], visualGateEvidence: [String],
                ownershipTransferEvidence: [String], noMainNodeFallbackEvidence: [String], staysFixedChoice: BackendNodelessStaysFixedChoice,
                asadDecisionEvidence: String?, staysFixedCompatibilityEvidence: [String], pluginCompatibilityEvidence: [String], unresolved: [String] = []) {
        self.format = format; self.inventorySHA256 = inventorySHA256; self.sourceSHA256 = sourceSHA256
        self.graphSHA256 = graphSHA256; self.artifactSetSHA256 = artifactSetSHA256; self.domains = domains
        self.combinedGateEvidence = combinedGateEvidence; self.visualGateEvidence = visualGateEvidence
        self.ownershipTransferEvidence = ownershipTransferEvidence; self.noMainNodeFallbackEvidence = noMainNodeFallbackEvidence
        self.staysFixedChoice = staysFixedChoice; self.asadDecisionEvidence = asadDecisionEvidence
        self.staysFixedCompatibilityEvidence = staysFixedCompatibilityEvidence; self.pluginCompatibilityEvidence = pluginCompatibilityEvidence
        self.unresolved = unresolved
    }
}
public struct BackendNodelessPackagingReport: Codable, Equatable, Sendable {
    public let allowed: Bool
    public let entireBundleNodeFree: Bool
    public let reasons: [String]
}

public enum BackendNodelessPackagingPolicy {
    public static let manifestPath = "Contents/Resources/nodeless-manifest.json"
    public static let helperPath = "Contents/MacOS/TerminalDeckJSCorePluginHelper"
    public static let productRuntimePath = "Contents/Resources/staysfixed/runtime/bin/node"
    public static let productPackagePrefix = "Contents/Resources/staysfixed/package/"
    public static let productNoticePrefix = "Contents/Resources/licenses/staysfixed/"
    /// Whole graph, including consumers whose source exists but is not wired.
    public static let requiredDomains: Set<String> = [
        "state", "sessions", "accounts", "provider-controls", "hooks", "files", "git", "dev-services", "artifacts",
        "usage", "readiness", "tasks", "goals", "routines", "crm", "memory", "knowledge", "mcp-clients", "mcp-output-validation",
        "deck-core", "deck-tools", "hoot", "remote", "machines", "ssh-servers", "ssh-enrollment", "devices", "device-react-native-tree",
        "safari", "community", "plugins", "staysfixed", "notifications", "native-ui-os", "updates", "native-helpers"
    ]
    public static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } && parts.first == "Contents"
    }
    public static func evaluate(manifest: BackendNodelessPackagingManifest, receipt: BackendNodelessPackagingGateReceipt,
                                artifactSetSHA256: String) -> BackendNodelessPackagingReport {
        var reasons: [String] = []
        if manifest.format != 1 || receipt.format != 1 { reasons.append("The native packaging manifest or gate format is unavailable.") }
        if manifest.version.isEmpty || !["arm64", "x64"].contains(manifest.architecture) { reasons.append("The native package needs its actual version and Mac architecture.") }
        for (label, actual, expected) in [
            ("inventory", manifest.inventorySHA256, receipt.inventorySHA256), ("source", manifest.sourceSHA256, receipt.sourceSHA256),
            ("graph", manifest.graphSHA256, receipt.graphSHA256), ("artifact set", artifactSetSHA256, receipt.artifactSetSHA256)
        ] where !validDigest(actual) || actual != expected { reasons.append("The verified \(label) receipt does not match this package.") }
        let ids = receipt.domains.map(\.id)
        if Set(ids).count != ids.count { reasons.append("A native domain has duplicate gate receipts.") }
        for missing in requiredDomains.subtracting(Set(ids)).sorted() { reasons.append("Native verification is unavailable for \(missing).") }
        for domain in receipt.domains.sorted(by: { $0.id < $1.id }) {
            if domain.phase != .verified || domain.evidence.isEmpty || domain.evidence.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                reasons.append("\(domain.id) is not verified by the combined gate.")
            }
            reasons += domain.unresolved.map { "\(domain.id): \($0)" }
        }
        for (label, evidence) in [
            ("combined build and functional gate", receipt.combinedGateEvidence), ("whole-frame visual gate", receipt.visualGateEvidence),
            ("single-writer ownership transfer", receipt.ownershipTransferEvidence), ("absence of main Node fallback", receipt.noMainNodeFallbackEvidence),
            ("installed plugin compatibility", receipt.pluginCompatibilityEvidence), ("Stays Fixed product and browser compatibility", receipt.staysFixedCompatibilityEvidence)
        ] where evidence.isEmpty || evidence.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            reasons.append("Evidence is unavailable for the \(label).")
        }
        reasons += receipt.unresolved
        if receipt.staysFixedChoice == .pending || receipt.asadDecisionEvidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            reasons.append("Stays Fixed needs Asad's recorded runtime and browser decision.")
        }
        if manifest.mode == .nativeOnly && receipt.staysFixedChoice != .javaScriptCore { reasons.append("A wholly Node-free bundle cannot retain a Stays Fixed Node runtime.") }
        if manifest.mode == .nativeAppWithIsolatedStaysFixed && receipt.staysFixedChoice != .isolatedRuntime { reasons.append("The isolated Stays Fixed runtime has not been selected by Asad.") }
        if manifest.mode == .nativeAppWithExternalStaysFixed && receipt.staysFixedChoice != .userProvidedRuntime && receipt.staysFixedChoice != .onDemandRuntime { reasons.append("Neither the user-provided nor the on-demand Stays Fixed runtime has been selected.") }
        let paths = manifest.artifacts.map(\.path)
        if paths.isEmpty || Set(paths).count != paths.count { reasons.append("The native artifact manifest is empty or has duplicate paths.") }
        for (path, kind) in [("Contents/MacOS/TerminalDeckNative", BackendNodelessPackagingArtifactKind.nativeExecutable),
                             ("Contents/MacOS/TerminalDeckNativeHelper", .nativeExecutable), (helperPath, .javaScriptCoreHelper)] {
            if !manifest.artifacts.contains(where: { $0.path == path && $0.kind == kind && $0.executable }) {
                reasons.append("The actual native executable is missing or misclassified: \(path)")
            }
        }
        if !manifest.artifacts.contains(where: { $0.kind == .notice }) { reasons.append("Distributed native dependency notices are unavailable.") }
        var productRuntimes = 0
        for artifact in manifest.artifacts {
            if !validPath(artifact.path) || !validDigest(artifact.sha256) { reasons.append("Invalid native artifact path or digest: \(artifact.path)"); continue }
            if artifact.path == manifestPath { reasons.append("The manifest cannot contain its own digest.") }
            let parts = artifact.path.lowercased().split(separator: "/").map(String.init)
            if artifact.path.hasPrefix("Contents/Resources/engine/") || artifact.path.hasPrefix("Contents/Resources/runtime/") ||
                parts.contains(where: { $0.hasSuffix(".node") || $0 == "engine.cjs" || $0 == "native-state-worker.cjs" || $0.contains("electron.framework") || $0 == "chromium.app" || $0 == "google chrome.app" }) {
                reasons.append("Legacy app Node/Electron/Chromium payload is forbidden: \(artifact.path)")
            }
            if parts.contains("node_modules") && artifact.kind != .staysFixedPackage { reasons.append("An app Node dependency tree remains: \(artifact.path)") }
            if artifact.kind == .javaScriptCoreHelper && (artifact.path != helperPath || !artifact.executable) { reasons.append("The JavaScriptCore helper must use its own native executable.") }
            if artifact.kind == .staysFixedRuntime {
                productRuntimes += 1
                if manifest.mode != .nativeAppWithIsolatedStaysFixed || artifact.path != productRuntimePath || !artifact.executable {
                    reasons.append("A Node runtime is not confined to the approved Stays Fixed executable.")
                }
            } else if parts.last == "node" { reasons.append("An undeclared Node executable remains: \(artifact.path)") }
            if artifact.kind == .staysFixedPackage && (manifest.mode != .nativeAppWithIsolatedStaysFixed || !artifact.path.hasPrefix(productPackagePrefix)) {
                if manifest.mode != .nativeAppWithExternalStaysFixed || !artifact.path.hasPrefix(productPackagePrefix) {
                    reasons.append("Stays Fixed package files are outside their approved product-only directory.")
                }
            }
            if artifact.path.hasPrefix(productPackagePrefix) && (artifact.kind != .staysFixedPackage || artifact.executable) {
                reasons.append("Product package files must be nonexecutable Stays Fixed package data: \(artifact.path)")
            }
            if artifact.path.hasPrefix("Contents/Resources/staysfixed/runtime/") &&
                (artifact.path != productRuntimePath || artifact.kind != .staysFixedRuntime || !artifact.executable) {
                reasons.append("Only the sole declared executable may occupy the product runtime directory.")
            }
            if manifest.mode == .nativeOnly && artifact.path.hasPrefix("Contents/Resources/staysfixed/") {
                reasons.append("Product Node payload cannot be included in a native-only package.")
            }
            if artifact.kind == .remoteHostArchive && !artifact.path.hasPrefix("Contents/Resources/headless/") { reasons.append("A Linux server receipt is outside the remote-host asset directory.") }
        }
        if manifest.mode == .nativeAppWithIsolatedStaysFixed && productRuntimes != 1 { reasons.append("The selected Stays Fixed option needs exactly one isolated runtime.") }
        if manifest.mode != .nativeOnly {
            if !manifest.artifacts.contains(where: { $0.kind == .staysFixedPackage }) { reasons.append("The selected Stays Fixed option has no declared product package.") }
            if !manifest.artifacts.contains(where: { $0.kind == .notice && $0.path.hasPrefix(productNoticePrefix) }) { reasons.append("Stays Fixed and its selected runtime/dependencies need their actual notices.") }
        }
        // The external option has no bundled Node executable, but its product
        // still depends on Node. It never satisfies the strict whole-product flag.
        return .init(allowed: reasons.isEmpty, entireBundleNodeFree: reasons.isEmpty && manifest.mode == .nativeOnly, reasons: reasons)
    }
}
