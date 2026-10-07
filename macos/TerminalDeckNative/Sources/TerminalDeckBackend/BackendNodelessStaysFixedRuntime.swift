import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// Decision D2 (night plan, 6 Oct 2026): the app is Node-free; Stays Fixed is a
/// Node + Playwright product, so it keeps its own Node runtime, fetched and
/// used only when someone uses Stays Fixed. Nothing here is on the app's
/// start path, the plugin path or any agent/session PATH.
///
/// The service asks `installed()` (never touches the network) for status and
/// `prepare()` (downloads on first use, then reuses) before it runs the product.
public protocol BackendStaysFixedProvisioning: Sendable {
    func installed() async -> BackendNodelessStaysFixedInstall?
    func prepare() async throws -> BackendNodelessStaysFixedInstall
    /// Plain sentence a status row shows while nothing is downloaded yet.
    var pendingNote: String { get }
}

/// Status-only answer while the runtime is not downloaded yet: Stays Fixed
/// stays usable (Set up / Check fetch it); this is not a failure.
public struct BackendStaysFixedNotDownloaded: Error, LocalizedError, Sendable {
    public let note: String
    public init(note: String) { self.note = note }
    public var errorDescription: String? { note }
}

/// One verified install: product-only Node plus the pinned product package.
public struct BackendNodelessStaysFixedInstall: Sendable, Equatable {
    public let root: URL
    /// `<root>/node/bin/node`: the only executable, never put on another PATH.
    public let node: URL
    /// `<root>/package`: its `node_modules` holds staysfixed and its three deps.
    public let packageParent: URL
    /// `<root>/package/node_modules/staysfixed`, the engine locator override.
    public let package: URL
    /// The existing locator over exactly this package (no other candidate).
    public func engineHome() throws -> BackendStaysFixedEngineHome {
        try BackendStaysFixedEngineFiles.locate(resources: nil, appPath: packageParent.path, cwd: packageParent.path, override: package.path)
    }
}

/// Exact pinned artifacts. Node from nodejs.org (official SHASUMS256), npm
/// packages from the registry with the lockfile's SRI, the product itself from
/// the app bundle (Asad's vendored build, same SRI as package-lock.json).
public struct BackendNodelessStaysFixedPins: Sendable, Equatable {
    public enum Digest: Sendable, Equatable { case sha256Hex(String), sha512Base64(String) }
    public struct Artifact: Sendable, Equatable {
        public let name: String
        public let version: String
        /// nil for the bundled product (copied from the app's Resources).
        public let url: URL?
        public let digest: Digest
        /// Relative to the install root.
        public let destination: String
        public let stripComponents: Int
        /// Archive members to extract (empty = all).
        public let members: [String]
        public let maximumBytes: Int
    }
    public let nodeVersion: String
    public let architecture: String
    public let artifacts: [Artifact]
    /// `r2`: installs made before modes were normalised (unreadable pngjs/lib) are replaced.
    public var key: String { "node-\(nodeVersion)-staysfixed-\(artifacts.first { $0.name == "staysfixed" }?.version ?? "?")-\(architecture)-r2" }

    public static let nodeVersion = "24.21.0"
    public static let staysFixedVersion = "0.15.0"
    public static let bundledProductName = "staysfixed-0.15.0-neutral.tgz"
    /// nodejs.org/dist/v24.21.0/SHASUMS256.txt, read 6 Oct 2026.
    public static let nodeSHA256 = [
        "arm64": "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
        "x64": "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097",
    ]

    public static func current(architecture: String = NativeHost.architecture) throws -> BackendNodelessStaysFixedPins {
        guard let nodeDigest = nodeSHA256[architecture] else {
            throw NativeRPCError(code: "unavailable", message: "Stays Fixed has no Node runtime for this Mac's processor (\(architecture)).")
        }
        let folder = "node-v\(nodeVersion)-darwin-\(architecture)"
        func npm(_ name: String, _ version: String, _ sri: String, max: Int) -> Artifact {
            .init(name: name, version: version, url: URL(string: "https://registry.npmjs.org/\(name)/-/\(name)-\(version).tgz")!,
                  digest: .sha512Base64(sri), destination: "package/node_modules/\(name)", stripComponents: 1, members: [], maximumBytes: max)
        }
        return .init(nodeVersion: nodeVersion, architecture: architecture, artifacts: [
            .init(name: "node", version: nodeVersion, url: URL(string: "https://nodejs.org/dist/v\(nodeVersion)/\(folder).tar.gz")!,
                  digest: .sha256Hex(nodeDigest), destination: "node", stripComponents: 1,
                  members: ["\(folder)/bin/node", "\(folder)/LICENSE"], maximumBytes: 160 * 1024 * 1024),
            .init(name: "staysfixed", version: staysFixedVersion, url: nil,
                  digest: .sha512Base64("bVgqUsA2s65tjKqISJGADAAgeb5zN1ZKkj5i4UPxjGtbtDN8YdKCPLHptbfZS/+rKiyH8cU9/wDcG0Pvpt+dbg=="),
                  destination: "package/node_modules/staysfixed", stripComponents: 1, members: [], maximumBytes: 32 * 1024 * 1024),
            npm("playwright-core", "1.63.0", "rYCsBF/M5HjUch52bbtVONEFjv6Xu8sm8h72dNlR5bzIE1fvC/bxgspzkjSfU+MweEMmPM8KJebG6nnyxo5mCg==", max: 64 * 1024 * 1024),
            npm("pngjs", "7.0.0", "LKWqWJRhstyYo9pGvgor/ivk2w94eSjE3RGVuzLGlr3NmD8bf7RcYGze1mNdEHRP6TRP6rMuDHk5t44hnTRyow==", max: 8 * 1024 * 1024),
            npm("pixelmatch", "7.2.0", "xhcb4yHu9sM/G7foGzoLtXYcC0zHEaOXXjRKhGup0fw78Nf2Tkiapv4EQyMzrbcmQPsllAI7DbFY2UT7PlI9Pg==", max: 8 * 1024 * 1024),
        ])
    }

    public static func matches(_ data: Data, _ digest: Digest) -> Bool {
        switch digest {
        case .sha256Hex(let hex): return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hex.lowercased()
        case .sha512Base64(let base64): return Data(SHA512.hash(data: data)).base64EncodedString() == base64
        }
    }
}

/// Download seam (tests supply files; production uses URLSession). The
/// destination is a fresh file inside the staging folder.
public protocol BackendNodelessStaysFixedFetching: Sendable {
    func fetch(_ url: URL, to destination: URL, maximumBytes: Int) async throws
}
public struct BackendNodelessStaysFixedURLFetch: BackendNodelessStaysFixedFetching {
    public init() {}
    public func fetch(_ url: URL, to destination: URL, maximumBytes: Int) async throws {
        guard url.scheme == "https" else { throw NativeRPCError(code: "unavailable", message: "Stays Fixed only downloads its runtime over HTTPS.") }
        var request = URLRequest(url: url); request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NativeRPCError(code: "unavailable", message: "Stays Fixed could not download \(url.lastPathComponent) (the server did not answer with the file).")
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= maximumBytes else { throw NativeRPCError(code: "unavailable", message: "\(url.lastPathComponent) is larger than Stays Fixed expects. Nothing was installed.") }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// The on-demand product runtime. One install per pinned key under
/// `<userData>/staysfixed-runtime/`; staging is a sibling folder renamed into
/// place only after every digest, layout and Mach-O check passed.
public actor BackendNodelessStaysFixedRuntime: BackendStaysFixedProvisioning {
    public static let folderName = "staysfixed-runtime"
    public nonisolated let base: URL
    public nonisolated let pins: BackendNodelessStaysFixedPins
    private let bundledProduct: URL?
    private let fetcher: any BackendNodelessStaysFixedFetching
    private let runner: BackendCommandRunner
    private var pending: Task<BackendNodelessStaysFixedInstall, Error>?

    /// `bundledProduct` is the app's `Contents/Resources/staysfixed/package/staysfixed-0.15.0-neutral.tgz`
    /// (repo `vendor/` for a checkout build). Nil means this build has no Stays Fixed.
    public init(userData: URL, bundledProduct: URL?, pins: BackendNodelessStaysFixedPins? = nil,
                fetcher: any BackendNodelessStaysFixedFetching = BackendNodelessStaysFixedURLFetch(),
                runner: BackendCommandRunner = BackendCommandRunner()) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/"), userData.path != "/", !userData.path.contains("\0") else {
            throw NativeRPCError.invalidArguments("Stays Fixed's runtime needs the app's absolute data folder.")
        }
        base = userData.standardizedFileURL.appendingPathComponent(Self.folderName, isDirectory: true)
        self.pins = try pins ?? .current()
        self.bundledProduct = bundledProduct?.standardizedFileURL; self.fetcher = fetcher; self.runner = runner
    }

    public nonisolated var pendingNote: String {
        "Stays Fixed downloads its own runtime (Node \(pins.nodeVersion), about 60 MB) the first time you set up or check a project. The app itself does not use Node."
    }
    private nonisolated var root: URL { base.appendingPathComponent(pins.key, isDirectory: true) }
    private nonisolated func layout(_ root: URL) -> BackendNodelessStaysFixedInstall {
        let parent = root.appendingPathComponent("package", isDirectory: true)
        return .init(root: root, node: root.appendingPathComponent("node/bin/node"), packageParent: parent,
            package: parent.appendingPathComponent("node_modules/staysfixed", isDirectory: true))
    }

    public func installed() async -> BackendNodelessStaysFixedInstall? {
        let install = layout(root)
        guard let receipt = try? Data(contentsOf: root.appendingPathComponent("receipt.json")),
              let value = try? NativeRPCValue.parseJSON(receipt), value["key"].string == pins.key,
              FileManager.default.isExecutableFile(atPath: install.node.path),
              FileManager.default.fileExists(atPath: install.package.appendingPathComponent("bin/staysfixed.js").path) else { return nil }
        return install
    }

    public func prepare() async throws -> BackendNodelessStaysFixedInstall {
        if let ready = await installed() { return ready }
        if let pending { return try await pending.value }
        let attempt = Task { try await self.install() }
        pending = attempt
        defer { pending = nil }
        return try await attempt.value
    }

    private func install() async throws -> BackendNodelessStaysFixedInstall {
        guard let bundledProduct, FileManager.default.fileExists(atPath: bundledProduct.path) else {
            throw NativeRPCError(code: "unavailable", message: "Stays Fixed is not part of this build.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let needed = Int64(pins.artifacts.reduce(0) { $0 + $1.maximumBytes }) * 2
        if let free = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw NativeRPCError(code: "unavailable", message: "Stays Fixed needs about \(needed / 1_048_576) MB free to download its runtime. Nothing was installed.")
        }
        let staging = base.appendingPathComponent(".staging-" + UUID().uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        let downloads = staging.appendingPathComponent(".downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var receipt: [NativeRPCValue] = []
        for artifact in pins.artifacts {
            try Task.checkCancellation()
            let archive = downloads.appendingPathComponent(artifact.name + ".tgz")
            if let url = artifact.url { try await fetcher.fetch(url, to: archive, maximumBytes: artifact.maximumBytes) }
            else { try fm.copyItem(at: bundledProduct, to: archive) }
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard data.count <= artifact.maximumBytes, BackendNodelessStaysFixedPins.matches(data, artifact.digest) else {
                throw NativeRPCError(code: "unavailable", message: "\(artifact.name) \(artifact.version) did not match its pinned checksum. Nothing was installed.")
            }
            let destination = staging.appendingPathComponent(artifact.destination, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let result = try await runner.run(command: "/usr/bin/tar",
                arguments: ["-xzf", archive.path, "-C", destination.path, "--strip-components", String(artifact.stripComponents),
                            "--no-same-owner"] + artifact.members,
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], cwd: staging.path, timeoutMilliseconds: 60_000)
            guard result.succeeded else {
                throw NativeRPCError(code: "unavailable", message: "Stays Fixed could not unpack \(artifact.name). Nothing was installed.")
            }
            // npm's own extractor normalises entry modes; bsdtar keeps them. The
            // pngjs 7.0.0 tarball records its directories as 0666 (no search
            // bit), which left `pngjs/lib` unreadable: "Cannot find package".
            try Self.normaliseModes(destination)
            try fm.removeItem(at: archive)
            receipt.append(.object([.init("name", .string(artifact.name)), .init("version", .string(artifact.version))]))
        }
        try fm.removeItem(at: downloads)
        try Self.confine(staging)
        let install = layout(staging)
        guard Self.isMachO(install.node) else {
            throw NativeRPCError(code: "unavailable", message: "Stays Fixed's downloaded Node is not a program for this Mac. Nothing was installed.")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: install.node.path)
        guard fm.fileExists(atPath: install.package.appendingPathComponent("bin/staysfixed.js").path) else {
            throw NativeRPCError(code: "unavailable", message: "The Stays Fixed package in this build is incomplete. Nothing was installed.")
        }
        let stamp = NativeRPCValue.object([.init("key", .string(pins.key)), .init("node", .string(pins.nodeVersion)),
            .init("architecture", .string(pins.architecture)), .init("artifacts", .array(receipt))])
        try (try stamp.encodedJSON() + Data([10])).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        let final = root
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) } // an incomplete earlier key (no receipt)
        try fm.moveItem(at: staging, to: final)
        published = true
        removeOtherKeys(keeping: final)
        return layout(final)
    }

    /// Every extracted entry must be a regular file or directory inside the
    /// staging root: no symlinks, devices or FIFOs from any archive.
    private static func confine(_ root: URL) throws {
        let unreadable = BackendNodelessStaysFixedWalkFailure()
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                                                       options: [], errorHandler: { _, _ in unreadable.mark(); return false }) else {
            throw NativeRPCError(code: "unavailable", message: "Stays Fixed could not check its unpacked runtime.")
        }
        for case let item as URL in walk {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw NativeRPCError(code: "unavailable", message: "Stays Fixed's download contained an unexpected link or special file. Nothing was installed.")
            }
        }
        // A walk that stopped early checked nothing past that point: fail closed.
        if unreadable.failed { throw NativeRPCError(code: "unavailable", message: "Stays Fixed could not read all of its unpacked runtime. Nothing was installed.") }
    }
    /// Directories 0755, files 0644, or 0755 when the archive marked them executable.
    /// Owner-only data stays readable by this user alone above (the install root is 0700).
    static func normaliseModes(_ root: URL) throws {
        func fix(_ path: String, isDirectory: Bool, mode: mode_t) throws {
            let wanted: mode_t = isDirectory || mode & 0o111 != 0 ? 0o755 : 0o644
            if mode & 0o7777 != wanted, chmod(path, wanted) != 0 {
                throw NativeRPCError(code: "unavailable", message: "Stays Fixed could not set permissions in its unpacked runtime.")
            }
        }
        // Breadth-first so a directory becomes searchable before its children are visited.
        var queue = [root.path]
        while !queue.isEmpty {
            let directory = queue.removeFirst()
            var info = stat()
            guard lstat(directory, &info) == 0 else { continue }
            try fix(directory, isDirectory: true, mode: info.st_mode)
            for name in (try FileManager.default.contentsOfDirectory(atPath: directory)) {
                let child = directory + "/" + name
                guard lstat(child, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: queue.append(child)
                case S_IFREG: try fix(child, isDirectory: false, mode: info.st_mode)
                default: break // links and special files are refused by `confine`
                }
            }
        }
    }
    private static func isMachO(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        try? handle.close()
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xfeedfacf, 0xcafebabe, 0xbebafeca].contains(magic)
    }
    private func removeOtherKeys(keeping: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.standardizedFileURL != keeping.standardizedFileURL && !entry.lastPathComponent.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// Records that the enumerator hit an entry it could not read.
private final class BackendNodelessStaysFixedWalkFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var failed: Bool { lock.withLock { value } }
}
