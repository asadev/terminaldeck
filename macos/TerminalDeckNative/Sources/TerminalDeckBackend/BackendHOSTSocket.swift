import Foundation
import Darwin

/// 22 Oct (Reviewer, finding 5): launchd starts the session helper with 256 open files. A running chat holds about
/// three and a terminal one, so about 75 chats or 220 terminals used them all and the app's connections were refused.
/// The helper raises its own soft limit when it starts: to the hard limit, within the system's per-process limit and
/// `ceiling`. It never lowers a limit.
public enum BackendHOSTOpenFiles {
    public static let ceiling: rlim_t = 10_240
    /// The soft limit afterwards.
    @discardableResult
    public static func raise(ceiling wanted: rlim_t = ceiling) -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        var target = min(wanted, limit.rlim_max)
        var perProcess: Int32 = 0, size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0, perProcess > 0 { target = min(target, rlim_t(perProcess)) }
        guard limit.rlim_cur < target else { return limit.rlim_cur }
        let before = limit.rlim_cur
        limit.rlim_cur = target
        return setrlimit(RLIMIT_NOFILE, &limit) == 0 ? target : before
    }
}

/// Length-prefixed JSON, no logs of launch arguments, environments or secrets.
enum BackendHOSTSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BackendHOSTFailure.invalid("The session host data folder is too long for a private Unix socket.")
        }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            for (index, byte) in bytes.enumerated() { target[index] = UInt8(bitPattern: byte) }
        }
        return address
    }

    static func secure(_ fd: Int32, timeoutSeconds: Int = 10) throws {
        var noPipe: Int32 = 1
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw BackendHOSTFailure.io(errno)
        }
    }

    static func sameUser(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw BackendHOSTFailure.authentication }
    }

    static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendHOSTFailure.io(errno) }
        do {
            try secure(fd)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw BackendHOSTFailure.io(errno) }
            try sameUser(fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func write<T: Encodable>(_ value: T, to fd: Int32, maximum: Int = BackendHOSTProtocol.maximumFrameBytes) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count > 0, data.count <= maximum else {
            throw BackendHOSTFailure.invalid("The session host frame exceeds its size limit.")
        }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeBytes($0, to: fd) }
        try data.withUnsafeBytes { try writeBytes($0, to: fd) }
    }

    private static func writeBytes(_ bytes: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while offset < bytes.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR { continue }
            else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            else { throw BackendHOSTFailure.io(count == 0 ? EPIPE : errno) }
        }
    }

    static let maximumFrameTimeoutMilliseconds = 120_000
    static func read<T: Decodable>(_ type: T.Type, from fd: Int32,
                                   maximum: Int = BackendHOSTProtocol.maximumFrameBytes, allowIdle: Bool = false,
                                   frameTimeoutMilliseconds: Int = 10_000) throws -> T {
        // 18 Oct (#81): a caller that knows its request is slow (a chat start, a Codex fork) passes its own deadline.
        guard (1...maximumFrameTimeoutMilliseconds).contains(frameTimeoutMilliseconds) else { throw BackendHOSTFailure.invalid("Invalid host frame deadline.") }
        let duration = UInt64(frameTimeoutMilliseconds) * 1_000_000
        let initialDeadline: UInt64? = allowIdle ? nil : DispatchTime.now().uptimeNanoseconds + duration
        let first = try readBytes(1, from: fd, deadline: initialDeadline)
        let deadline = initialDeadline ?? DispatchTime.now().uptimeNanoseconds + duration
        let header = first + (try readBytes(3, from: fd, deadline: deadline))
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximum else {
            throw BackendHOSTFailure.invalid("The session host frame has an invalid size.")
        }
        return try JSONDecoder().decode(type, from: readBytes(Int(count), from: fd, deadline: deadline))
    }

    private static func readBytes(_ count: Int, from fd: Int32, deadline: UInt64?) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < count {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
                let received = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
                if received > 0 { offset += received }
                else if received < 0, errno == EINTR { continue }
                else if received < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                else { throw BackendHOSTFailure.io(received == 0 ? ECONNRESET : errno) }
            }
        }
        return data
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64?) throws {
        while true {
            var milliseconds: Int32 = -1
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw BackendHOSTFailure.io(ETIMEDOUT) }
                milliseconds = Int32(max(1, (deadline - now) / 1_000_000))
            }
            var event = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&event, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw BackendHOSTFailure.io(ready == 0 ? ETIMEDOUT : errno) }
            return
        }
    }

    static func sameSecret(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
