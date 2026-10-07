import Foundation
import CryptoKit
import Darwin

public struct BackendNodelessPackagingFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Read-only artifact and evidence checks. Every path is supplied explicitly;
/// initialization never discovers a data root, reads credentials or runs tools.
public enum BackendNodelessPackagingFiles {
    public static let maximumManifestBytes = 4 * 1024 * 1024
    public static let maximumArtifacts = 50_000
    private static func fail(_ message: String) -> BackendNodelessPackagingFailure { .init(message) }
    private final class ScanState: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func failedRead() { lock.lock(); failed = true; lock.unlock() }
        var incomplete: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    }

    public static func scratchRoot(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw fail("An explicit absolute scratch build root is required.") }
        // realpath(3), the same form F_GETPATH reports. Foundation's
        // resolvingSymlinksInPath strips /private (/var, /tmp), so every opened
        // source under a temporary root would look outside it.
        guard let resolved = realpath(url.standardizedFileURL.path, nil) else { throw fail("The explicit scratch build root does not exist.") }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true); free(resolved)
        guard root.path != "/", root.path != "/Applications", !root.path.hasPrefix("/Applications/"),
              !root.path.contains("/Library/Application Support/"), !root.path.hasSuffix("/Library/Application Support") else {
            throw fail("Native packaging cannot inspect or write an installation or live data directory.")
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw fail("The explicit scratch build root does not exist.") }
        return root
    }
    private static func within(_ path: URL, _ root: URL) -> Bool { path.path.hasPrefix(root.path + "/") }
    private static func confined(_ relative: String, to root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("\0") else { throw fail("A build path must be relative to its explicit scratch root.") }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw fail("A build path leaves the explicit scratch root.") }
        var current = root
        for part in parts {
            current.appendPathComponent(String(part))
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw fail("A native package path is missing or is a symbolic link: \(relative)") }
        }
        guard within(current, root) else { throw fail("A native package path escaped its scratch root.") }
        return current
    }
    /// Establish descriptor authority before the first byte read. F_GETPATH
    /// checks the opened inode's actual location after any parent replacement.
    public static func openRegularSource(_ url: URL, within root: URL? = nil) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fail("The native artifact could not be opened: \(url.path)") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw fail("Native package evidence must be a regular file.")
        }
        if let root {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
            guard result == 0 else { Darwin.close(fd); throw fail("The opened native source location is unavailable.") }
            let actual = String(cString: buffer)
            guard actual.hasPrefix(root.path + "/") else { Darwin.close(fd); throw fail("The opened native source is outside the explicit build root.") }
        }
        return fd
    }
    public static func digest(_ url: URL, within root: URL? = nil) throws -> String {
        let fd = try openRegularSource(url, within: root)
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw fail("Native package evidence must be a regular file.") }
        var hasher = SHA256(), bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw fail("The native artifact could not be hashed.") }
            if count == 0 { break }
            hasher.update(data: Data(bytes.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw fail("A native artifact changed while it was hashed.") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func artifactSetDigest(_ artifacts: [BackendNodelessPackagingArtifact]) -> String {
        let rows = artifacts.sorted { $0.path < $1.path }.map { "\($0.path)\0\($0.kind.rawValue)\0\($0.executable ? 1 : 0)\0\($0.sha256)\n" }.joined()
        return SHA256.hash(data: Data(rows.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func read<T: Decodable>(_ type: T.Type, file: URL) throws -> T {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
              info.st_size <= maximumManifestBytes else { throw fail("A native manifest/receipt is unavailable or exceeds its bound.") }
        let data = try Data(contentsOf: file)
        guard data.count <= maximumManifestBytes else { throw fail("A native manifest/receipt exceeded its bound while reading.") }
        return try JSONDecoder().decode(type, from: data)
    }
    private static func supportsArchitecture(_ header: Data, named architecture: String) -> Bool {
        let bytes = Array(header)
        guard bytes.count >= 8 else { return false }
        func word(_ offset: Int, little: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let part = Array(bytes[offset..<offset + 4]); let ordered = little ? Array(part.reversed()) : part
            return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let wanted: UInt32 = architecture == "arm64" ? 0x0100000c : 0x01000007
        let magic = Array(bytes.prefix(4))
        if magic == [0xcf,0xfa,0xed,0xfe] { return word(4, little: true) == wanted }
        if magic == [0xfe,0xed,0xfa,0xcf] { return word(4, little: false) == wanted }
        let little = magic == [0xbe,0xba,0xfe,0xca] || magic == [0xbf,0xba,0xfe,0xca]
        let fat64 = magic == [0xca,0xfe,0xba,0xbf] || magic == [0xbf,0xba,0xfe,0xca]
        guard little || magic == [0xca,0xfe,0xba,0xbe] || magic == [0xca,0xfe,0xba,0xbf],
              let count = word(4, little: little), count > 0, count <= 16 else { return false }
        let stride = fat64 ? 32 : 20
        guard bytes.count >= 8 + Int(count) * stride else { return false }
        return (0..<Int(count)).contains { word(8 + $0 * stride, little: little) == wanted }
    }
    /// Draft creation records actual copied bytes, but cannot mark a gate passed.
    /// The integration worker signs nested binaries before producing this draft.
    public static func manifest(version: String, architecture: String, mode: BackendNodelessPackagingMode,
                                inventorySHA256: String, sourceSHA256: String, graphSHA256: String,
                                artifacts: [BackendNodelessPackagingArtifact], appRelativePath: String,
                                buildRoot: URL) throws -> BackendNodelessPackagingManifest {
        let root = try scratchRoot(buildRoot), app = try confined(appRelativePath, to: root)
        guard app.pathExtension == "app", !artifacts.isEmpty, artifacts.count <= maximumArtifacts else { throw fail("A bounded explicit native app artifact plan is required.") }
        var actual: [BackendNodelessPackagingArtifact] = []
        for artifact in artifacts {
            guard BackendNodelessPackagingPolicy.validPath(artifact.path), artifact.path != BackendNodelessPackagingPolicy.manifestPath else { throw fail("The native artifact plan contains an invalid path.") }
            let file = try confined(artifact.path, to: app)
            actual.append(.init(path: artifact.path, sha256: try digest(file, within: root), kind: artifact.kind, executable: artifact.executable))
        }
        return .init(version: version, architecture: architecture, mode: mode, inventorySHA256: inventorySHA256,
            sourceSHA256: sourceSHA256, graphSHA256: graphSHA256, artifacts: actual)
    }
    public static func verify(buildRoot: URL, appRelativePath: String, receiptRelativePath: String) throws -> BackendNodelessPackagingReport {
        let root = try scratchRoot(buildRoot), app = try confined(appRelativePath, to: root)
        guard app.pathExtension == "app" else { throw fail("The package gate needs the explicit scratch .app directory.") }
        let manifest = try read(BackendNodelessPackagingManifest.self, file: confined(BackendNodelessPackagingPolicy.manifestPath, to: app))
        let receipt = try read(BackendNodelessPackagingGateReceipt.self, file: confined(receiptRelativePath, to: root))
        guard manifest.artifacts.count <= maximumArtifacts else { throw fail("The native artifact manifest exceeds its file bound.") }
        var actual: [BackendNodelessPackagingArtifact] = []
        for artifact in manifest.artifacts {
            guard BackendNodelessPackagingPolicy.validPath(artifact.path) else { throw fail("The native artifact manifest contains a path escape.") }
            let file = try confined(artifact.path, to: app)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw fail("A native artifact is not a regular file.") }
            let executable = info.st_mode & 0o111 != 0
            guard executable == artifact.executable else { throw fail("A native artifact's execution mode changed: \(artifact.path)") }
            let hash = try digest(file, within: root)
            guard hash == artifact.sha256 else { throw fail("A native artifact does not match its manifest: \(artifact.path)") }
            if [.nativeExecutable, .javaScriptCoreHelper, .staysFixedRuntime].contains(artifact.kind) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let header = try handle.read(upToCount: 4096) ?? Data()
                guard supportsArchitecture(header, named: manifest.architecture) else {
                    throw fail("A packaged native executable does not carry the declared Mach-O architecture: \(artifact.path)")
                }
            }
            if artifact.executable && artifact.kind != .staysFixedPackage {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let prefix = String(decoding: try handle.read(upToCount: 256) ?? Data(), as: UTF8.self)
                if prefix.hasPrefix("#!") && prefix.components(separatedBy: "\n").first?.range(of: #"\bnode(?:js)?\b"#, options: .regularExpression) != nil {
                    throw fail("A Node shebang remains in the native app payload: \(artifact.path)")
                }
            }
            actual.append(artifact)
        }
        // Reject undeclared payloads rather than trusting only listed filenames.
        let declared = Set(manifest.artifacts.map(\.path))
        let scan = ScanState()
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in scan.failedRead(); return false }) else { throw fail("The native app payload could not be enumerated.") }
        var count = 0
        for case let file as URL in enumerator {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw fail("The native package contains a missing entry or symbolic link.") }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            count += 1; guard count <= maximumArtifacts + 2 else { throw fail("The native package exceeds its artifact bound.") }
            let relative = String(file.path.dropFirst(app.path.count + 1))
            if relative == BackendNodelessPackagingPolicy.manifestPath || relative == "Contents/_CodeSignature/CodeResources" { continue }
            guard declared.contains(relative) else { throw fail("An undeclared native app payload remains: \(relative)") }
        }
        guard !scan.incomplete else { throw fail("The native app payload could not be read completely.") }
        let evidence = receipt.combinedGateEvidence + receipt.visualGateEvidence + receipt.ownershipTransferEvidence + receipt.noMainNodeFallbackEvidence
            + receipt.pluginCompatibilityEvidence + receipt.staysFixedCompatibilityEvidence + receipt.domains.flatMap(\.evidence)
            + [receipt.asadDecisionEvidence].compactMap { $0 }
        for path in Set(evidence) {
            let file = try confined(path, to: root)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw fail("A native gate evidence file is empty or unavailable.") }
            _ = try digest(file, within: root)
        }
        return BackendNodelessPackagingPolicy.evaluate(manifest: manifest, receipt: receipt, artifactSetSHA256: artifactSetDigest(actual))
    }
}

/// Integration adds this branch to the existing native helper before ordinary
/// RPC dispatch. It does no copying/building/signing and launches no process.
public enum BackendNodelessPackagingCommand {
    public static let argument = "--nodeless-package-gate"
    public static func run(arguments: [String]) -> (code: Int32, output: String) {
        guard arguments.count == 4, arguments.first == argument, arguments[1].hasPrefix("/") else { return (2, "Use --nodeless-package-gate <absolute scratch root> <relative app> <relative receipt>.\n") }
        do {
            let report = try BackendNodelessPackagingFiles.verify(buildRoot: URL(fileURLWithPath: arguments[1]), appRelativePath: arguments[2], receiptRelativePath: arguments[3])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (report.allowed ? 0 : 1, String(decoding: try encoder.encode(report), as: UTF8.self) + "\n")
        } catch { return (1, "Native-only packaging unavailable: \(error.localizedDescription)\n") }
    }
}
