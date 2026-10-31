import Foundation
import TerminalDeckNativeCore

/// A phone reaches Hoot only as one of your own approved devices. Device kind
/// is asked on every frame; an unreadable kind store is a guest.
public struct BackendCopilotRemoteAccess: Sendable {
    private let isMine: @Sendable (String) async throws -> Bool
    public init(isMine: @escaping @Sendable (String) async throws -> Bool) { self.isMine = isMine }
    public init(trust: BackendRemoteTrustStore) {
        isMine = { id in
            guard await trust.isApproved(id) else { return false }
            return await trust.kindOf(id) == .mine
        }
    }
    public func linked(_ deviceID: String) async -> Bool {
        guard !deviceID.isEmpty else { return false }
        return (try? await isMine(deviceID)) == true
    }
}

/// The phone's Hoot frames and their tiers: no tool/run/PTY names inbound.
public enum BackendCopilotRemoteSurface {
    public static let submitGapMilliseconds = 50
    public static let untiered: Set<String> = ["hoot.hello", "hoot.bye"]
    public static let frameTier: [String: BackendMCPTier] = [
        "hoot.attach": .read, "hoot.detach": .read, "hoot.state": .read,
        "hoot.sessions": .read, "hoot.log": .read, "hoot.pending": .read, "hoot.older": .read,
        "hoot.start": .act, "hoot.say": .act, "hoot.cancel": .act, "hoot.stop": .act,
        "hoot.files": .read, "hoot.file.read": .read, "hoot.file.write": .alter,
        "hoot.file.reset": .alter, "hoot.memory.delete": .alter,
        "hoot.answer": .alter, "hoot.interactive": .alter,
    ]
    public static func typeAndSubmit(_ text: String, write: @escaping @Sendable (String) throws -> Void,
                                    deferWrite: @escaping @Sendable (Int, @escaping @Sendable () -> Void) -> Void = { ms, action in
                                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(ms), execute: action)
                                    }, onDeferredError: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) throws {
        try write(text)
        deferWrite(submitGapMilliseconds) {
            do { try write("\r") }
            catch { onDeferredError("[remote] could not submit a Hoot message: \(error.localizedDescription)") }
        }
    }
}
