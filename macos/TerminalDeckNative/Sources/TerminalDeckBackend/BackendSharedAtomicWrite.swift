import Foundation
import Darwin

public struct BackendSharedAtomicWriteOperations {
    public var writeFile: (String, String) throws -> Void
    public var rename: (String, String) throws -> Void
    public var unlink: (String) throws -> Void
    public init(writeFile: @escaping (String, String) throws -> Void, rename: @escaping (String, String) throws -> Void, unlink: @escaping (String) throws -> Void) {
        self.writeFile = writeFile; self.rename = rename; self.unlink = unlink
    }
    public static var native: Self {
        .init(writeFile: { path, contents in try Data(contents.utf8).write(to: URL(fileURLWithPath: path)) },
              rename: { from, to in
                  if Darwin.rename(from, to) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil) }
              }, unlink: { path in
                  if Darwin.unlink(path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil) }
              })
    }
}

/// shared main/atomic-write.ts's Mac path: one POSIX replacement attempt,
/// same-directory temporary name, explicit failure and cleanup. Windows retry
/// logic is not applicable to the native Mac app.
public final class BackendSharedAtomicWrite: @unchecked Sendable {
    public static let shared = BackendSharedAtomicWrite()
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var sequence: UInt64 = 0
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; sequence &+= 1; return sequence }
    }
    private static let counter = Counter()
    public init() {}
    public func tempNameFor(_ file: String, pid: Int32 = getpid()) -> String {
        let next = Self.counter.next()
        return "\(file).\(pid).\(next).tmp"
    }
    public func renameWithRetry(from: String, to: String, operations: BackendSharedAtomicWriteOperations = .native) throws { try operations.rename(from, to) }
    public func write(file: String, contents: String, operations: BackendSharedAtomicWriteOperations = .native) throws {
        let temporary = tempNameFor(file)
        try operations.writeFile(temporary, contents)
        do { try renameWithRetry(from: temporary, to: file, operations: operations) }
        catch { try? operations.unlink(temporary); throw error }
    }
}
