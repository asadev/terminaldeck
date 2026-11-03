import Foundation
import Darwin

/// A serial writer and retained descriptor; shutdown interrupts active I/O,
/// close waits until every operation has released its retained connection.
final class BackendHOSTAppRelayConnection: @unchecked Sendable {
    let connection: BackendHOSTConnection
    var fd: Int32 { connection.fd }
    let attachment: UUID
    let peerPID: Int32
    private let writer = DispatchQueue(label: "dev.terminaldeck.host.app-relay.writer", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false
    init(connection: BackendHOSTConnection, attachment: UUID, peerPID: Int32) {
        self.connection = connection; self.attachment = attachment; self.peerPID = peerPID
    }
    func send(_ frame: BackendHOSTAppRelayProtocol.Frame, failed: @escaping @Sendable () -> Void) {
        writer.async { [self] in
            guard !lock.withLock({ closed }) else { return }
            do { try BackendHOSTSocket.write(frame, to: fd, maximum: BackendHOSTAppRelayProtocol.maximumFrame) }
            catch { shutdown(); failed() }
        }
    }
    func handshake(_ frame: BackendHOSTAppRelayProtocol.Frame, activate: @Sendable () -> Bool) throws {
        try writer.sync {
            guard activate() else { throw BackendHOSTFailure.unavailable }
            // Publishing is inside this serial write. Calls queued by the new
            // binding run only after ACK; ACK cannot precede activation either.
            try BackendHOSTSocket.write(frame, to: fd, maximum: BackendHOSTAppRelayProtocol.maximumHandshake)
        }
    }
    func shutdown() { lock.withLock { closed = true }; connection.shutdown() }
    deinit { shutdown() }
}

enum BackendHOSTAppRelayPeer {
    static func pid(_ fd: Int32) throws -> Int32 {
        try BackendHOSTSocket.sameUser(fd)
        var pid: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else { throw BackendHOSTFailure.authentication }
        return pid
    }
}
