import Foundation
import TerminalDeckNativeCore

public actor BackendAppStoreIndexCache {
    public struct Fetched: Sendable {
        public let ok: Bool, text: String, message: String
        public init(ok: Bool, text: String = "", message: String = "") { self.ok = ok; self.text = text; self.message = message }
    }
    public typealias Fetch = @Sendable (String, Int) async -> Fetched
    public let directory: URL
    private let writable: Bool, keys: [BackendSharedStoreKey], fetch: Fetch
    public init(userData: URL, writable: Bool = false, keys: [BackendSharedStoreKey] = BackendSharedStoreKeys.live, fetch: @escaping Fetch = BackendAppStoreIndexCache.httpsFetch) {
        directory = userData.appendingPathComponent("community"); self.writable = writable; self.keys = keys; self.fetch = fetch
    }
    public var file: URL { directory.appendingPathComponent("index.json") }
    public func hasCache() -> Bool { FileManager.default.fileExists(atPath: file.path) }
    private func rawCache() -> NativeRPCValue? {
        guard let data = try? Data(contentsOf: file), let raw = try? NativeRPCValue.parseJSON(data), raw.fields != nil else { return nil }; return raw
    }
    public func highWater() -> Double {
        guard let value = rawCache()?["highWater"].number, value.rounded(.towardZero) == value, abs(value) <= 9_007_199_254_740_991 else { return 0 }; return value
    }
    public func read(now: Double) -> NativeRPCValue? {
        guard let raw = rawCache(), raw["v"] == .number(1), let envelope = raw["envelope"].string, let savedAt = raw["savedAt"].string else { return nil }
        guard case .accepted(let index, _, _) = BackendAppStoreIndex.check(envelope, keys: keys, highWater: 0, now: now) else { return nil }
        let stored = raw["highWater"].number.flatMap { $0.rounded(.towardZero) == $0 && abs($0) <= 9_007_199_254_740_991 ? $0 : nil } ?? 0
        return .object([.init("index", index), .init("savedAt", .string(savedAt)), .init("highWater", .number(max(stored, index["serial"].number ?? 0)))])
    }
    public func write(envelope: String, serial: Double, at: Double) throws {
        guard writable else { throw NativeRPCError(code: "unavailable", message: "Native catalogue cache writes are unavailable until the app transfers its single writer") }
        let payload = NativeRPCValue.object([.init("v", .number(1)), .init("savedAt", .string(BackendAppSettingsStore.iso(at))),
            .init("highWater", .number(max(serial, highWater()))), .init("envelope", .string(envelope))])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try payload.encodedJSON(pretty: true); data.append(10)
        try data.write(to: file, options: .atomic)
    }
    public func load(base: String, now: Double = Date().timeIntervalSince1970 * 1000) async -> NativeRPCValue {
        let fetched = await fetch(BackendSharedStoreApi.indexUrl(base), BackendAppStoreIndex.maxBytes)
        var refusal = fetched.message
        if fetched.ok {
            switch BackendAppStoreIndex.check(fetched.text, keys: keys, highWater: highWater(), now: now) {
            case .accepted(let index, _, let stale):
                // Source allows an uncached but verified list when the disk cannot save it.
                try? write(envelope: fetched.text, serial: index["serial"].number ?? 0, at: now)
                return loaded(index, from: "store", at: BackendAppSettingsStore.iso(now), stale: stale, because: nil)
            case .refused(let why): refusal = why
            }
        }
        guard let kept = read(now: now), let savedAt = kept["savedAt"].string else { return .object([.init("ok", .bool(false)), .init("why", .string(refusal))]) }
        return loaded(kept["index"], from: "kept", at: savedAt, stale: BackendAppStoreIndex.staleness(kept["index"], now: now), because: refusal)
    }
    private func loaded(_ index: NativeRPCValue, from: String, at: String, stale: String?, because: String?) -> NativeRPCValue {
        .object([.init("ok", .bool(true)), .init("index", index), .init("from", .string(from)), .init("at", .string(at)),
            .init("stale", stale.map(NativeRPCValue.string) ?? .null), .init("because", because.map(NativeRPCValue.string) ?? .null)])
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public static func httpsFetch(_ raw: String, _ limit: Int) async -> Fetched {
        guard let parts = URLComponents(string: raw), let url = parts.url, let scheme = parts.scheme?.lowercased(), let host = parts.host else { return Fetched(ok: false, message: "that is not a URL") }
        guard scheme == "https" || scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) else { return Fetched(ok: false, message: "the catalogue can only be fetched over https") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20
        let delegate = NoRedirect(), session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return Fetched(ok: false, message: "the store could not be reached from this machine") }
            if (300..<400).contains(http.statusCode) { return Fetched(ok: false, message: "the store could not be reached from this machine") }
            guard (200..<300).contains(http.statusCode) else { return Fetched(ok: false, message: "the store answered \(http.statusCode)") }
            var data = Data()
            for try await byte in bytes {
                if data.count >= limit { return Fetched(ok: false, message: "the store sent more than this app will read") }
                data.append(byte)
            }
            return Fetched(ok: true, text: String(decoding: data, as: UTF8.self))
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut || error is CancellationError || (error as? URLError)?.code == .cancelled
            return Fetched(ok: false, message: timedOut ? "the store did not answer in time" : "the store could not be reached from this machine")
        }
    }
}
