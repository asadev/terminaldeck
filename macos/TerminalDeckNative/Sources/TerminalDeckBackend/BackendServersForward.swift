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

final class BackendServersForwardSequence: @unchecked Sendable {
    private let lock = NSLock(); private var previous: Task<Void, Never>?
    func append(_ action: @escaping @Sendable () async -> Void) { lock.withLock { let old = previous; previous = Task { await old?.value; await action() } } }
    func flush() async { let pending = lock.withLock { previous }; await pending?.value }
}
