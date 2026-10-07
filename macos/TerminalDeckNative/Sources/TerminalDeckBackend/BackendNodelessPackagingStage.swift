import Foundation
import Darwin

public struct BackendNodelessPackagingInput: Codable, Equatable, Sendable {
    /// Relative to the explicit build root, not a live app or data path.
    public let source: String
    public let artifact: BackendNodelessPackagingArtifact
    public init(source: String, artifact: BackendNodelessPackagingArtifact) { self.source = source; self.artifact = artifact }
}
public struct BackendNodelessPackagingStagePlan: Codable, Equatable, Sendable {
    public let appRelativePath: String
    public let manifest: BackendNodelessPackagingManifest
    public let inputs: [BackendNodelessPackagingInput]
    public init(appRelativePath: String, manifest: BackendNodelessPackagingManifest, inputs: [BackendNodelessPackagingInput]) {
        self.appRelativePath = appRelativePath; self.manifest = manifest; self.inputs = inputs
    }
}

/// Fresh scratch-bundle publication only, after the gate receipt is available.
/// No builds, downloads, dependency install, signatures, product launch, deletes,
/// live-app replacement or permission changes outside the new bundle occur.
public enum BackendNodelessPackagingStage {
    private static func relative(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func source(_ value: String, root: URL) throws -> URL {
        guard relative(value) else { throw BackendNodelessPackagingFailure("A staged source must be relative to the explicit build root.") }
        var file = root
        for part in value.split(separator: "/") {
            file.appendPathComponent(String(part))
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw BackendNodelessPackagingFailure("A staged source is missing or uses a symbolic link.") }
        }
        return file
    }
    public static func stage(plan: BackendNodelessPackagingStagePlan, receipt: BackendNodelessPackagingGateReceipt,
                             receiptRelativePath: String, buildRoot: URL) throws -> URL {
        let root = try BackendNodelessPackagingFiles.scratchRoot(buildRoot)
        guard relative(plan.appRelativePath), plan.appRelativePath.hasSuffix(".app"), !plan.inputs.isEmpty,
              plan.inputs.count <= BackendNodelessPackagingFiles.maximumArtifacts else { throw BackendNodelessPackagingFailure("A bounded fresh scratch app plan is required.") }
        let app = root.appendingPathComponent(plan.appRelativePath)
        let parent = plan.appRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        if !parent.isEmpty { _ = try source(parent, root: root) }
        guard !FileManager.default.fileExists(atPath: app.path) else { throw BackendNodelessPackagingFailure("Native staging never replaces an existing app; use a fresh scratch destination.") }
        let artifacts = plan.inputs.map(\.artifact)
        guard artifacts == plan.manifest.artifacts else { throw BackendNodelessPackagingFailure("Staging inputs do not match the complete native manifest.") }
        let report = BackendNodelessPackagingPolicy.evaluate(manifest: plan.manifest, receipt: receipt,
            artifactSetSHA256: BackendNodelessPackagingFiles.artifactSetDigest(artifacts))
        guard report.allowed else { throw BackendNodelessPackagingFailure(report.reasons.joined(separator: "\n")) }
        // Check all sources before creating any destination. The source SHA is
        // the post-nested-signing digest; copying must preserve those bytes.
        var sources: [URL] = []
        for input in plan.inputs {
            let file = try source(input.source, root: root)
            guard try BackendNodelessPackagingFiles.digest(file, within: root) == input.artifact.sha256 else { throw BackendNodelessPackagingFailure("A staging source changed after the combined gate.") }
            sources.append(file)
        }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        for (input, from) in zip(plan.inputs, sources) {
            let sourceFD = try BackendNodelessPackagingFiles.openRegularSource(from, within: root)
            defer { Darwin.close(sourceFD) }
            let to = app.appendingPathComponent(input.artifact.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Exclusive create: no existing output or another worker's file can
            // be overwritten. Failure leaves the named scratch bundle visible.
            let fd = open(to.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, input.artifact.executable ? 0o755 : 0o644)
            guard fd >= 0 else { throw BackendNodelessPackagingFailure("A fresh native destination could not be created.") }
            do {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let readCount = chunk.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, $0.count) }
                    if readCount < 0 && errno == EINTR { continue }
                    guard readCount >= 0 else { throw BackendNodelessPackagingFailure("A staged source could not be read.") }
                    if readCount == 0 { break }
                    try chunk.withUnsafeBytes { buffer in
                        var at = 0
                        while at < readCount {
                            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: at), readCount - at)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw BackendNodelessPackagingFailure("A staged artifact could not be copied.") }
                            at += count
                        }
                    }
                }
                guard fsync(fd) == 0 else { throw BackendNodelessPackagingFailure("A staged native artifact could not be flushed.") }
                Darwin.close(fd)
            } catch { Darwin.close(fd); throw error }
            guard try BackendNodelessPackagingFiles.digest(to, within: root) == input.artifact.sha256 else { throw BackendNodelessPackagingFailure("A staged copy does not match its verified source.") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(plan.manifest); data.append(0x0a)
        try data.write(to: app.appendingPathComponent(BackendNodelessPackagingPolicy.manifestPath), options: .withoutOverwriting)
        let checked = try BackendNodelessPackagingFiles.verify(buildRoot: root, appRelativePath: plan.appRelativePath, receiptRelativePath: receiptRelativePath)
        guard checked.allowed else { throw BackendNodelessPackagingFailure(checked.reasons.joined(separator: "\n")) }
        return app
    }
}
