import Foundation

/// The service owns indexing; the injected source only reports actual paths.
/// Production retains native FSEvents. Tests can deliver a deterministic event.
public protocol BackendMemoryWatching: Sendable { func stop() }
public typealias BackendMemoryWatchEvent = @Sendable ([String], Bool) -> Void
public typealias BackendMemoryWatchFactory = @Sendable (String, @escaping BackendMemoryWatchEvent) throws -> any BackendMemoryWatching
public protocol BackendMemoryDebounceClock: Sendable { func wait(milliseconds: Int) async throws }
public struct BackendMemorySystemDebounceClock: BackendMemoryDebounceClock {
    public init() {}
    public func wait(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}
