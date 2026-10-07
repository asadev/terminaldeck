import Foundation
import TerminalDeckNativeCore

public enum BackendServersForwardRefusal: String, Sendable { case prohibited, unreachable, unknown }
public struct BackendServersForwardError: Error, LocalizedError, Sendable {
    public let refusal: BackendServersForwardRefusal, message: String
    public init(refusal: BackendServersForwardRefusal, message: String) { self.refusal = refusal; self.message = message }
    public var errorDescription: String? { message }
    static func from(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        let said = error.localizedDescription.lowercased()
        if said.contains("administratively prohibited") || said.contains("port forwarding is disabled") { return .init(refusal: .prohibited, message: error.localizedDescription) }
        if said.contains("connect failed") || said.contains("connection refused") || said.contains("no route to host") { return .init(refusal: .unreachable, message: error.localizedDescription) }
        return .init(refusal: .unknown, message: error.localizedDescription)
    }
}
public enum BackendServersForwardResult: Sendable {
    case opened(any BackendServersDuplex)
    case refused(BackendServersForwardRefusal, message: String)
}
public struct BackendServersForwarding: Codable, Equatable, Sendable {
    public let known: String, why: String?
    public init(known: String, why: String? = nil) { self.known = known; self.why = why }
}
public typealias BackendServersForwarder = @Sendable (String, Int) async -> BackendServersForwardResult
public enum BackendServersForward {
    public static let willNotForward = "This server does not let another computer open the things it is running. That is a setting on the server itself."
    public static let maximumStreams = 64, maximumTunnels = 4, openTimeoutMilliseconds = 5000, maximumChunkBytes = 24 * 1024, windowBytes = 256 * 1024
    public static func forwardOn(_ connection: any BackendServersConnection) -> BackendServersForwarder {
        { host, port in do { return .opened(try await connection.forward(host: host, port: port)) } catch { let issue = BackendServersForwardError.from(error); return .refused(issue.refusal, message: issue.message) } }
    }
    public static func deadPort(_ listening: [Int]) -> Int { let taken = Set(listening); return (1..<65535).first { !taken.contains($0) } ?? 1 }
    public static func askWhetherItForwards(_ forward: @escaping BackendServersForwarder, listening: [Int] = []) async -> BackendServersForwarding {
        let first = await forward("127.0.0.1", deadPort(listening))
        switch first {
        case .opened(let channel): channel.close(); return .init(known: "yes")
        case .refused(.unreachable, _): return .init(known: "yes")
        case .refused(.unknown, let message): return .init(known: "cannot", why: message)
        case .refused(.prohibited, _): break
        }
        guard let real = listening.first else { return .init(known: "no", why: willNotForward) }
        switch await forward("127.0.0.1", real) {
        case .opened(let channel): channel.close(); return .init(known: "yes")
        case .refused(.unreachable, _): return .init(known: "yes")
        case .refused(.unknown, let message): return .init(known: "cannot", why: message)
        case .refused(.prohibited, _): return .init(known: "no", why: willNotForward)
        }
    }
    public static func whyNot(_ refusal: BackendServersForwardRefusal, port: Int, name: String) -> String {
        switch refusal { case .prohibited: willNotForward; case .unreachable: "Nothing is answering on port \(port) on \(name)."; case .unknown: "\(name) could not be asked about port \(port) just now." }
    }
}

/// Source forward.ts frame translator, available for the existing relay-shaped
/// browser ledger. Native reach also uses the same Forwarder and limits.
public actor BackendServersSshTunnelHost {
    private let forward: BackendServersForwarder, send: @Sendable (NativeRPCValue) async -> Void, name: String
    private struct Tunnel { let port: Int, host: String; var streams: Set<String> = [] }
    private struct Stream {
        let tunnel: String
        var channel: (any BackendServersDuplex)?
        var waiting: [Data] = [], waitingBytes = 0, unacked = 0, paused = false
        var subscriptions: [BackendServersUnsubscribe] = []
        let sequence = BackendServersForwardSequence()
    }
    private var tunnels: [String: Tunnel] = [:], streams: [String: Stream] = [:], opening: [String: UUID] = [:]
    public init(forward: @escaping BackendServersForwarder, name: String, send: @escaping @Sendable (NativeRPCValue) async -> Void) { self.forward = forward; self.name = name; self.send = send }
    private func frame(_ type: String, _ fields: [NativeRPCValue.Field]) async { await send(.object([.init("t", .string(type))] + fields)) }
    public func handle(_ value: NativeRPCValue) async {
        switch value["t"].string {
        case "tunnel.open": if let id = value["id"].string, let port = value["port"].number, port.rounded() == port, (1...65535).contains(port) { await openTunnel(id, port: Int(port)) }
        case "tunnel.close": if let id = value["id"].string { await closeTunnel(id, message: "Closed here.") }
        case "net.open": if let ch = value["ch"].string, let tunnel = value["tunnel"].string { await openStream(ch, tunnelID: tunnel) }
        case "net.data": if let ch = value["ch"].string, let text = value["data"].string, text.utf8.count <= 32768, let bytes = Data(base64Encoded: text), bytes.count <= BackendServersForward.maximumChunkBytes { await write(ch, bytes: bytes) }
        case "net.ack": if let ch = value["ch"].string, let count = value["bytes"].number, count.isFinite, count.rounded() == count, count > 0 { acknowledge(ch, bytes: Int(min(count, Double(Int.max)))) }
        case "net.close": if let ch = value["ch"].string { await drop(ch, tell: false, flush: true) }
        default: break
        }
    }
    private func openTunnel(_ id: String, port: Int) async {
        guard tunnels[id] == nil, opening[id] == nil else { await frame("tunnel.closed", [.init("id", .string(id)), .init("message", .string("A tunnel with that id is already open."))]); return }
        guard tunnels.count + opening.count < BackendServersForward.maximumTunnels else { await frame("tunnel.closed", [.init("id", .string(id)), .init("message", .string("\(name) already has 4 addresses open here. Close one first."))]); return }
        let token = UUID(); opening[id] = token; var host: String?, refusal = BackendServersForwardRefusal.unreachable
        for candidate in ["127.0.0.1", "::1"] {
            let result = await forward(candidate, port)
            guard opening[id] == token else { if case .opened(let channel) = result { channel.close() }; return }
            switch result { case .opened(let channel): channel.close(); host = candidate; case .refused(let why, _): refusal = why }
            if host != nil || refusal == .prohibited { break }
        }
        opening[id] = nil
        guard let host else { await frame("tunnel.closed", [.init("id", .string(id)), .init("message", .string(BackendServersForward.whyNot(refusal, port: port, name: name)))]); return }
        tunnels[id] = .init(port: port, host: host); await frame("tunnel.opened", [.init("id", .string(id)), .init("port", .number(Double(port)))])
    }
    private func openStream(_ ch: String, tunnelID: String) async {
        guard let tunnel = tunnels[tunnelID], streams[ch] == nil, streams.count < BackendServersForward.maximumStreams else { await frame("net.close", [.init("ch", .string(ch))]); return }
        streams[ch] = .init(tunnel: tunnelID); tunnels[tunnelID]?.streams.insert(ch)
        let result = await forward(tunnel.host, tunnel.port)
        guard streams[ch] != nil, case .opened(let channel) = result else { if case .opened(let channel) = result { channel.close() }; if streams[ch] != nil { await drop(ch, tell: true, flush: false) }; return }
        streams[ch]?.channel = channel
        let queue = streams[ch]!.sequence
        let bytes = channel.onBytes { [weak self] data in queue.append { [weak self] in await self?.received(ch, bytes: data) } }
        let end = channel.onEnd { [weak self] in queue.append { [weak self] in await self?.drop(ch, tell: true, flush: true) } }
        let close = channel.onClose { [weak self] in queue.append { [weak self] in await self?.drop(ch, tell: true, flush: false) } }
        streams[ch]?.subscriptions = [bytes, end, close]
        let waiting = streams[ch]?.waiting ?? []; streams[ch]?.waiting = []; streams[ch]?.waitingBytes = 0
        for bytes in waiting { await write(ch, bytes: bytes) }
    }
    private func write(_ ch: String, bytes: Data) async {
        guard var stream = streams[ch], !bytes.isEmpty else { return }
        guard let channel = stream.channel else {
            guard stream.waitingBytes + bytes.count <= BackendServersForward.windowBytes else { await drop(ch, tell: true, flush: false); return }
            stream.waiting.append(bytes); stream.waitingBytes += bytes.count; streams[ch] = stream; return
        }
        do { try await channel.write(bytes); if streams[ch] != nil { await frame("net.ack", [.init("ch", .string(ch)), .init("bytes", .number(Double(bytes.count)))]) } }
        catch { await drop(ch, tell: true, flush: false) }
    }
    private func received(_ ch: String, bytes: Data) async {
        guard streams[ch] != nil else { return }
        var at = 0
        while at < bytes.count {
            let end = min(bytes.count, at + BackendServersForward.maximumChunkBytes), part = Data(bytes[at..<end]); at = end
            streams[ch]?.unacked += part.count
            await frame("net.data", [.init("ch", .string(ch)), .init("data", .string(part.base64EncodedString()))])
        }
        if let stream = streams[ch], !stream.paused, stream.unacked >= BackendServersForward.windowBytes { streams[ch]?.paused = true; stream.channel?.pause() }
    }
    private func acknowledge(_ ch: String, bytes: Int) {
        guard var stream = streams[ch] else { return }; stream.unacked = max(0, stream.unacked - bytes)
        if stream.paused && stream.unacked < BackendServersForward.windowBytes { stream.paused = false; stream.channel?.resume() }; streams[ch] = stream
    }
    private func drop(_ ch: String, tell: Bool, flush: Bool) async {
        guard let stream = streams.removeValue(forKey: ch) else { return }; tunnels[stream.tunnel]?.streams.remove(ch)
        for cancel in stream.subscriptions { cancel() }
        if flush { try? await stream.channel?.end() } else { stream.channel?.close() }
        if tell { await frame("net.close", [.init("ch", .string(ch))]) }
    }
    private func closeTunnel(_ id: String, message: String) async {
        opening[id] = nil
        if let tunnel = tunnels.removeValue(forKey: id) { for ch in tunnel.streams { await drop(ch, tell: false, flush: false) } }
        await frame("tunnel.closed", [.init("id", .string(id)), .init("message", .string(message))])
    }
    public func closeAll() async { opening = [:]; for ch in Array(streams.keys) { await drop(ch, tell: false, flush: false) }; tunnels = [:] }
    public func openPorts() -> [Int] { tunnels.values.map(\.port).sorted() }
    func flushPendingEvents() async { for stream in streams.values { await stream.sequence.flush() } }
}
final class BackendServersForwardSequence: @unchecked Sendable {
    private let lock = NSLock(); private var previous: Task<Void, Never>?
    func append(_ action: @escaping @Sendable () async -> Void) { lock.withLock { let old = previous; previous = Task { await old?.value; await action() } } }
    func flush() async { let pending = lock.withLock { previous }; await pending?.value }
}
