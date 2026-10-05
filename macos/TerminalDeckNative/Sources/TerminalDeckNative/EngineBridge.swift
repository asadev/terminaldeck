import Foundation
import TerminalDeckNativeCore

/// The native app's own line to the engine, for screens drawn in Swift.
///
/// The same `/__td` API the pages use (see `EngineWire`), with the per-launch
/// key sent as `X-TD-Token`. One live event stream for the whole app, fanned
/// out by channel; it reconnects on its own after a drop, and the engine
/// re-announces its sessions each time a stream opens.
@MainActor
final class EngineBridge {
    static let shared = EngineBridge()

    private(set) var base: URL?
    private var token: String?
    private var listeners: [String: [UUID: ([Any]) -> Void]] = [:]
    private var stream: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()

    var isReady: Bool { base != nil }

    /// Called when the engine prints its ready line.
    func configure(engineURL: URL) {
        guard let endpoint = EngineWire.endpoint(from: engineURL) else { return }
        base = endpoint.base
        token = endpoint.token
        if !listeners.isEmpty { openStream() }
    }

    /// Called when the engine stops. Listeners stay registered for the next start.
    func reset() {
        stream?.cancel()
        stream = nil
        base = nil
        token = nil
    }

    /// Call a handler the engine registered with `ipcMain.handle`, and wait for its answer.
    func invoke(_ channel: String, _ args: [Any?] = []) async throws -> Any {
        let data = try await post("/__td/invoke", channel: channel, args: args)
        switch EngineWire.invokeResult(data) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    /// Fire-and-forget to an `ipcMain.on` listener (e.g. `session:write`), in order.
    func send(_ channel: String, _ args: [Any?] = []) {
        let previous = lastSend
        lastSend = Task { [weak self] in
            await previous?.value
            _ = try? await self?.post("/__td/send", channel: channel, args: args)
        }
    }
    private var lastSend: Task<Void, Never>?

    /// Listen to one channel of the live event stream.
    @discardableResult
    func on(_ channel: String, _ handler: @escaping ([Any]) -> Void) -> EngineSubscription {
        let id = UUID()
        listeners[channel, default: [:]][id] = handler
        if stream == nil, base != nil { openStream() }
        return EngineSubscription { [weak self] in
            Task { @MainActor in self?.listeners[channel]?[id] = nil }
        }
    }

    // MARK: - inside

    private func post(_ path: String, channel: String, args: [Any?]) async throws -> Data {
        guard let base, let token else { throw EngineWireError.notReady }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-TD-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try EngineWire.requestBody(channel: channel, args: args)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw EngineWireError.http(code) }
        return data
    }

    private func openStream() {
        stream?.cancel()
        stream = Task { [weak self] in
            var delay: UInt64 = 250_000_000
            while !Task.isCancelled {
                guard let self, let request = await self.eventsRequest() else { return }
                do {
                    let (bytes, response) = try await self.session.bytes(for: request)
                    if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 { throw EngineWireError.http(code) }
                    delay = 250_000_000
                    var parser = EngineWire.EventParser()
                    for try await line in bytes.lines {
                        if let event = parser.feed(line) { await self.dispatch(event) }
                        // `lines` drops empty lines, so the blank line that ends an event
                        // never arrives. The engine sends each event as one `data:` line,
                        // so a data line is a whole event: end it here.
                        if line.hasPrefix("data:"), let event = parser.feed("") { await self.dispatch(event) }
                    }
                    // `lines` drops the blank separator after the last event; flush it.
                    if let event = parser.feed("") { await self.dispatch(event) }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 5_000_000_000)
            }
        }
    }

    private func eventsRequest() -> URLRequest? {
        guard let base, let token else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("/__td/events"))
        request.setValue(token, forHTTPHeaderField: "X-TD-Token")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity
        return request
    }

    private func dispatch(_ event: EngineWire.Event) {
        for handler in (listeners[event.channel] ?? [:]).values { handler(event.args) }
    }
}

/// Stops one listener. Keep it for as long as the screen wants events.
final class EngineSubscription {
    private var cancelAction: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    func cancel() { cancelAction?(); cancelAction = nil }
    deinit { cancelAction?() }
}
