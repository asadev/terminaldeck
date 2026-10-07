import Foundation
import TerminalDeckNativeCore

/// updates/manual-strategy.ts's coupling layer. NativeAppUpdater remains the
/// only phase/launch/focus/quit controller; feed/package validation is reused.
public actor BackendAppManualUpdateStrategy {
    public struct Context: Sendable {
        public let feedURL: URL, updatesRoot: URL, currentBundle: URL, helper: URL
        public let currentVersion: String, bundleIdentifier: String, executableName: String, architecture: String
        public let relaunch: Bool
        public init(feedURL: URL, updatesRoot: URL, currentBundle: URL, helper: URL,
                    currentVersion: String, bundleIdentifier: String, executableName: String, architecture: String, relaunch: Bool = true) {
            self.feedURL = feedURL; self.updatesRoot = updatesRoot; self.currentBundle = currentBundle; self.helper = helper
            self.currentVersion = currentVersion; self.bundleIdentifier = bundleIdentifier; self.executableName = executableName; self.architecture = architecture; self.relaunch = relaunch
        }
    }
    public typealias Progress = @Sendable (Double, Double) -> Void
    public struct Operations: Sendable {
        public let feed: @Sendable () async throws -> NativeUpdateRelease
        public let stage: @Sendable (NativeUpdateRelease, @escaping Progress) async throws -> NativeStagedUpdate
        public let install: @Sendable (NativeStagedUpdate) async throws -> Void
        public init(feed: @escaping @Sendable () async throws -> NativeUpdateRelease,
                    stage: @escaping @Sendable (NativeUpdateRelease, @escaping Progress) async throws -> NativeStagedUpdate,
                    install: @escaping @Sendable (NativeStagedUpdate) async throws -> Void) {
            self.feed = feed; self.stage = stage; self.install = install
        }
        /// No default quit success: the real app owner supplies normal quit.
        /// The native package helper acknowledges before quit is requested.
        public static func native(_ context: Context, quitApplication: @escaping @MainActor @Sendable () throws -> Void) -> Operations {
            .init(feed: { try await BackendAppManualUpdateStrategy.fetchNativeFeed(context) }, stage: { release, progress in
                try await NativeUpdatePackage.stage(release: release, updatesRoot: context.updatesRoot, currentBundle: context.currentBundle,
                    executableName: context.executableName, onProgress: progress)
            }, install: { staged in
                try await Task.detached(priority: .utility) {
                    try NativeUpdatePackage.armInstall(staged, currentBundle: context.currentBundle, executableName: context.executableName,
                        helper: context.helper, relaunch: context.relaunch)
                }.value
                try await quitApplication()
            })
        }
    }
    public struct Offer: Sendable {
        public let release: NativeUpdateRelease
        public var wire: NativeRPCValue { .object([.init("version", .string(release.version)), .init("notes", .null), .init("sizeBytes", .number(Double(release.size)))]) }
    }
    private let currentVersion: String, operations: Operations
    private var staged: [String: NativeStagedUpdate] = [:]
    public init(currentVersion: String, operations: Operations) { self.currentVersion = currentVersion; self.operations = operations }
    public func check() async throws -> Offer? {
        let release = try await operations.feed()
        return Self.isNewer(release.version, than: currentVersion) ? Offer(release: release) : nil
    }
    public func download(version: String, onProgress: @escaping Progress) async throws -> NativeRPCValue {
        do {
            // The source fetches the feed again while downloading. Do not stage
            // a stale offer silently if a release changed after the check.
            let release = try await operations.feed()
            let receipt = try await operations.stage(release) { percent, rate in
                // NativeUpdatePackage already measures byte deltas/time. Keep
                // its one sampler, rounding for the source strategy callback.
                onProgress(percent, floor(max(0, rate) + 0.5))
            }
            guard receipt.release.version == version else {
                return Self.result(false, "The release changed while downloading — expected \(version), found \(receipt.release.version). Check again.")
            }
            staged[version] = receipt; return Self.result(true)
        } catch { return Self.result(false, error.localizedDescription) }
    }
    public func install(version: String) async -> NativeRPCValue {
        guard let receipt = staged[version] else { return Self.result(false, "Nothing is staged for this version. Download it again.") }
        do { try await operations.install(receipt); return Self.result(true) }
        catch { return Self.result(false, error.localizedDescription) }
    }
    /// Use only for NativeUpdatePackage.restore's revalidated receipt. This is
    /// not an IPC path accepting a caller-selected bundle or staging directory.
    public func adoptVerified(_ receipt: NativeStagedUpdate) { staged[receipt.release.version] = receipt }
    public func receipt(version: String) -> NativeStagedUpdate? { staged[version] }
    private static func result(_ ok: Bool, _ message: String? = nil) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("ok", .bool(ok))]
        if let message { fields.append(.init("message", .string(message))) }; return .object(fields)
    }
    /// Source parseInt behavior, including missing/trailing components and a
    /// pre-release suffix. It intentionally does not offer an equal release.
    public nonisolated static func isNewer(_ candidate: String, than running: String) -> Bool {
        func parts(_ raw: String) -> [Double] {
            let unprefixed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            return (unprefixed.components(separatedBy: "-").first ?? "").components(separatedBy: ".").map { field in
                let clean = BackendSharedText.trim(field)
                guard let range = clean.range(of: #"^[+-]?[0-9]+"#, options: .regularExpression), let number = Double(clean[range]), number != 0 else { return 0 }
                return number
            }
        }
        let a = parts(candidate), b = parts(running)
        for index in 0..<max(a.count, b.count) {
            let left = a.indices.contains(index) ? a[index] : 0, right = b.indices.contains(index) ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
    private final class NetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.flatMap { NativeUpdateFeed.allowedNetworkURL($0) ? request : nil })
        }
    }
    public nonisolated static func fetchNativeFeed(_ context: Context) async throws -> NativeUpdateRelease {
        try NativeUpdateFeed.validateFeedURL(context.feedURL)
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: NetworkPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: context.feedURL)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NativeUpdateFeed.Failure("the release feed answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let final = response.url, NativeUpdateFeed.allowedNetworkURL(final) else { throw NativeUpdateFeed.Failure("the release feed could not be read") }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < NativeUpdateFeed.maximumFeedBytes else { throw NativeUpdateFeed.Failure("The native update feed is too large.") }
            bytes.append(byte)
        }
        return try NativeUpdateFeed.decode(bytes, feedURL: context.feedURL, bundleIdentifier: context.bundleIdentifier, architecture: context.architecture)
    }
}
