#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import Darwin

extension BackendHOSTLaunchAgent {
    /// Probe the helper's kernel owner lock, without preparing a host folder.
    /// Absence permits local ownership; every uncertain owner stays protected.
    public static func agentsOwnerMayBeHeld(_ paths: BackendHOSTPaths) throws -> Bool {
        guard paths.namespace == "agents" else { throw BackendHOSTFailure.invalid("The account-owner probe requires the agents namespace.") }
        let file = paths.directory.appendingPathComponent("owner.lock")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            let code = errno
            guard code == ENOENT else { throw BackendHOSTFailure.io(code) }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600 else { throw BackendHOSTFailure.unavailable }
        do {
            let probe = try BackendHOSTFileLock(file, createIfMissing: false)
            withExtendedLifetime(probe) {}
            return false
        } catch BackendHOSTFailure.unavailable { return true }
    }

    public func connectAfterCoreExit(sourceHelper: URL, agents: BackendHOSTPaths) async throws -> Result {
        try await Self.retryCoreExit(agents: agents) { try await self.connectOrStart(sourceHelper: sourceHelper) }
    }

    // Only retry the pre-attachment core connection while the agents owner remains.
    // Never retry assembly, configure resources twice, or replace an occupied host.
    static func retryCoreExit<Value: Sendable>(agents: BackendHOSTPaths,
        connect: @Sendable () async throws -> Value) async throws -> Value {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do { return try await connect() }
            catch BackendHOSTFailure.occupiedHost {
                try Task.checkCancellation()
                guard attempt < 3, try agentsOwnerMayBeHeld(agents) else { throw BackendHOSTFailure.occupiedHost }
            }
        }
        throw BackendHOSTFailure.occupiedHost
    }
}
#endif
