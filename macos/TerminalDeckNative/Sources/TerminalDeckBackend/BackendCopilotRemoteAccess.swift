import Foundation
import TerminalDeckNativeCore

/// remote/copilot-access.ts: immutable, explicitly enumerated tiers. Device kind
/// is asked on every frame and tool call; an unreadable kind store is a guest.
public struct BackendCopilotRemoteGrant: Equatable, Sendable {
    public let read: Bool
    public let act: Bool
    public let alter: Bool
    public init(read: Bool, act: Bool, alter: Bool) { self.read = read; self.act = act; self.alter = alter }
    public static let full = Self(read: true, act: true, alter: true)
    public static let none = Self(read: false, act: false, alter: false)
    public var tiers: Set<BackendMCPTier> {
        var result = Set<BackendMCPTier>()
        if read { result.insert(.read) }; if act { result.insert(.act) }; if alter { result.insert(.alter) }
        return result
    }
    public var wireValue: NativeRPCValue {
        .object([.init("read", .bool(read)), .init("act", .bool(act)), .init("alter", .bool(alter))])
    }
    public var grantsNothing: Bool { !read && !act && !alter }
}

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
    public func granted(_ deviceID: String) async -> BackendCopilotRemoteGrant { await linked(deviceID) ? .full : .none }
    public func list(_ devices: [String]) async -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        for id in devices where await linked(id) { result.append(.object([.init("deviceId", .string(id)), .init("tiers", BackendCopilotRemoteGrant.full.wireValue)])) }
        return result
    }
    public func caller(_ deviceID: String) async -> BackendDeckCoreSecurityCaller {
        .init(kind: .remote, tiers: await granted(deviceID).tiers, deviceID: deviceID)
    }
}

/// remote/copilot-remote.ts and protocol.ts: no tool/run/PTY names inbound.
public enum BackendCopilotRemoteSurface {
    public static let graceMilliseconds: Double = 600_000
    public static let maximumLogRows = 200
    public static let maximumMessageUnits = 8 * 1024
    public static let submitGapMilliseconds = 50
    public static let untiered: Set<String> = ["copilot.hello", "copilot.bye"]
    public static let frameTier: [String: BackendMCPTier] = [
        "copilot.attach": .read, "copilot.detach": .read, "copilot.state": .read,
        "copilot.sessions": .read, "copilot.log": .read, "copilot.pending": .read,
        "copilot.start": .act, "copilot.say": .act, "copilot.cancel": .act, "copilot.stop": .act,
        "copilot.files": .read, "copilot.file.read": .read, "copilot.file.write": .alter,
        "copilot.file.reset": .alter, "copilot.memory.delete": .alter,
        "copilot.answer": .alter, "copilot.interactive": .alter,
    ]
    public static func allowed(_ grant: BackendCopilotRemoteGrant, verb: String) -> Bool {
        guard let tier = frameTier[verb] else { return false }; return grant.tiers.contains(tier)
    }
    public static func runConfigName(_ deviceID: String) -> String {
        let safe = deviceID.unicodeScalars.map { scalar -> String in
            let v = scalar.value
            return (65...90).contains(v) || (97...122).contains(v) || (48...57).contains(v) ? String(scalar) : "-"
        }.prefix(64).joined()
        return "deck-control-device-\(safe.isEmpty ? "unnamed" : safe).json"
    }
    public static func submitWrites(_ text: String) -> [String] { [text, "\r"] }
    public static func typeAndSubmit(_ text: String, write: @escaping @Sendable (String) throws -> Void,
                                    deferWrite: @escaping @Sendable (Int, @escaping @Sendable () -> Void) -> Void = { ms, action in
                                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(ms), execute: action)
                                    }, onDeferredError: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) throws {
        try write(text)
        deferWrite(submitGapMilliseconds) {
            do { try write("\r") }
            catch { onDeferredError("[remote] could not submit a copilot message: \(error.localizedDescription)") }
        }
    }
}
