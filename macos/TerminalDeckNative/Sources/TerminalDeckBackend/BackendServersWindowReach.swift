import Foundation

public enum BackendServersWindowLocalEnd: Sendable, Equatable { case port(Int), socketPath(String) }
public enum BackendServersWindowBindAnswer: String, Sendable { case loopback, `public`, unknown }
public enum BackendServersWindowReachResult: Sendable { case opened(BackendServersWindowReach), refused(String) }

public final class BackendServersWindowReach: @unchecked Sendable {
    public let port: Int
    private let lease: any BackendServersReverseForward
    private let lock = NSLock(); private var closed = false
    private var unsubscribe: BackendServersUnsubscribe?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var isClosed: Bool { lock.withLock { closed } }
    init(port: Int, lease: any BackendServersReverseForward) { self.port = port; self.lease = lease }
    func watch(_ connection: any BackendServersConnection) {
        let stop = connection.onClose { [weak self] in self?.close() }
        let kept = lock.withLock { () -> Bool in guard !closed else { return false }; unsubscribe = stop; return true }
        if !kept { stop() }
    }
    public func close() {
        let state = lock.withLock { () -> (Bool, BackendServersUnsubscribe?, [CheckedContinuation<Void, Never>]) in
            guard !closed else { return (false, nil, []) }; closed = true
            let state = (true, unsubscribe, waiters); unsubscribe = nil; waiters.removeAll(); return state
        }
        guard state.0 else { return }; lease.close(); state.1?(); for waiter in state.2 { waiter.resume() }
    }
    func waitForClosed() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in if closed { return true }; waiters.append(continuation); return false }
            if now { continuation.resume() }
        }
    }
    deinit { close() }
}

public enum BackendServersWindowReachRules {
    public static let loopback = "127.0.0.1"
    public static let requestTimeoutMilliseconds = 5_000
    public static let maximumReachStreams = 16
    public static let cannotForward = "this server would not open a port of its own for this app to answer on. Its SSH settings decide that — `AllowTcpForwarding` and `PermitListen` — and only somebody who can change them on that machine can turn it on."
    public static let boundTooWidely = "this server put that port on every one of its network addresses instead of on its own loopback, which is what `GatewayPorts yes` in its SSH settings does. Nothing was connected and the port has been closed again: a way in to this computer’s browser must not be reachable from that server’s network."
    public static let cannotTellWhereBound = "this server has neither `ss` nor `netstat`, so this app cannot check that the port it opened there is on that machine’s loopback and nowhere else. That check is the whole boundary here, so the port has been closed again rather than used unchecked."
    public static func bindCheckScript(_ port: Int) -> String {
        #"""
        p=\#(port)
        if command -v ss >/dev/null 2>&1; then
          found=$(ss -H -tln 2>/dev/null | awk -v p=":$p\$" '$4 ~ p {print $4}')
        elif command -v netstat >/dev/null 2>&1; then
          found=$(netstat -tln 2>/dev/null | awk -v p=":$p\$" '/LISTEN/ && $4 ~ p {print $4}')
        else
          echo unknown; exit 0
        fi
        if [ -z "$found" ]; then echo unknown; exit 0; fi
        for a in $found; do
          case "$a" in
            127.0.0.1:*) ;;
            "[::1]:"*) ;;
            ::1:*) ;;
            *) echo public; exit 0 ;;
          esac
        done
        echo loopback
        """#
    }
    public static func readBindAnswer(_ stdout: String) -> BackendServersWindowBindAnswer {
        BackendServersWindowBindAnswer(rawValue: stdout.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? "") ?? .unknown
    }
    /// The system SSH implementation assigns each lease its own inactive sink.
    /// It rejects sockets until this bind check passes; the sink enforces the
    /// 16-stream cap and drains ordered EOF before closing either byte pipe.
    public static func open(connection: any BackendServersConnection, local: BackendServersWindowLocalEnd,
                            runScript: @Sendable (String) async throws -> BackendServersRunResult) async -> BackendServersWindowReachResult {
        let lease: any BackendServersReverseForward
        do { lease = try await connection.reverseForward(bindAddress: loopback, bindPort: 0) }
        catch { return .refused(cannotForward) }
        guard (1...65_535).contains(lease.port) else { lease.close(); return .refused(cannotForward) }
        let answer: BackendServersWindowBindAnswer
        do { answer = readBindAnswer(try await runScript(bindCheckScript(lease.port)).stdout) }
        catch { lease.close(); return .refused(cannotTellWhereBound) }
        guard answer == .loopback else { lease.close(); return .refused(answer == .public ? boundTooWidely : cannotTellWhereBound) }
        let target: BackendServersReverseTarget
        switch local {
        case .port(let port):
            guard (1...65_535).contains(port) else { lease.close(); return .refused("this app’s control endpoint is not running here yet.") }
            target = .tcp(host: loopback, port: port)
        case .socketPath(let path):
            guard path.hasPrefix("/"), !path.contains("\u{0}") else { lease.close(); return .refused("this app’s hook endpoint is not running here yet.") }
            target = .unix(path: path)
        }
        do { try await lease.activate(target: target) }
        catch { lease.close(); return .refused(cannotForward) }
        let reach = BackendServersWindowReach(port: lease.port, lease: lease); reach.watch(connection)
        return .opened(reach)
    }
}
