import Foundation
import TerminalDeckNativeCore

/// Keeps unknown saved fields intact while turning only verified source fields
/// into a launch. Device identity remains outside renderer-controlled input.
public struct BackendSessionSaved: Equatable, Sendable {
    public let raw: NativeRPCValue
    public let cwd: String
    public let provider: String
    public init(_ raw: NativeRPCValue) throws {
        _ = try raw.requireObject("saved session")
        cwd = try raw["cwd"].requireString("saved session folder", nonempty: true)
        provider = try raw["provider"].requireString("saved agent", nonempty: true)
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), !provider.contains("\0") else { throw BackendSessionFailure.invalidInput("A saved session has an invalid folder or provider.") }
        for name in ["cols", "rows"] { if let value = raw[name].number, value < 1 || value > 1000 || value.rounded(.towardZero) != value { throw BackendSessionFailure.invalidInput("A saved session has invalid terminal dimensions.") } }
        self.raw = raw
    }
    public var profileID: String? { raw["profileId"].string }
    public var homeProfileID: String? { raw["homeProfileId"].string }
    public var conversationID: String? { raw["agentSessionId"].string.flatMap { $0.isEmpty ? nil : $0 } }
    public var deviceID: String? { raw["confineDeviceId"].string }
    public var tabKey: String? { raw["tabKey"].string }
    public var lastSeenAt: Double { raw["lastSeenAt"].number ?? 0 }
    public func input(resume: Bool, pick: Bool = false, profileID: String? = nil, conversationID: String? = nil, replaces: String? = nil) -> BackendCreateSessionInput {
        var input = BackendCreateSessionInput(cwd: cwd, cols: Int(raw["cols"].number ?? 100), rows: Int(raw["rows"].number ?? 30), provider: provider)
        input.profileId = profileID ?? self.profileID; input.homeProfileId = homeProfileID
        input.resume = resume; input.pickConversation = pick ? true : nil; input.resumeConversationId = conversationID ?? self.conversationID
        input.replaces = replaces; input.tabKey = tabKey; input.model = raw["model"].string
        let denied = (raw["deniedTools"].elements ?? []).compactMap(\.string)
        input.deniedTools = denied.isEmpty ? nil : denied
        input.noSkills = raw["noSkills"].bool == true ? true : nil
        input.agentInstructions = raw["agentInstructions"].string.flatMap { $0.isEmpty ? nil : $0 }
        return input
    }
    public static func from(_ input: BackendCreateSessionInput) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("cwd", .string(input.cwd)), .init("provider", .string(input.provider ?? "claude")),
            .init("profileId", input.profileId.map(NativeRPCValue.string) ?? .null), .init("cols", .number(Double(input.cols))),
            .init("rows", .number(Double(input.rows))), .init("lastSeenAt", .number(Date().timeIntervalSince1970 * 1000))])
        for (key, string) in [("homeProfileId", input.homeProfileId), ("agentSessionId", input.resumeConversationId),
                              ("model", input.model), ("agentInstructions", input.agentInstructions), ("tabKey", input.tabKey)] {
            if let string { value = value.setting(key, .string(string)) }
        }
        if let denied = input.deniedTools, !denied.isEmpty { value = value.setting("deniedTools", .array(denied.map(NativeRPCValue.string))) }
        if input.noSkills == true { value = value.setting("noSkills", .bool(true)) }
        return value
    }
}

public struct BackendSessionRestoreDecision: Sendable {
    public enum Outcome: String, Sendable { case resume, fresh, skip, failed }
    public enum Conversation: String, Sendable { case found, none, unknown }
    public let session: BackendSessionSaved
    public let outcome: Outcome
    public let reason: String
    public let configDirectory: String?
    public let conversation: Conversation?
    public let pick: Bool
    public init(session: BackendSessionSaved, outcome: Outcome, reason: String, configDirectory: String? = nil,
                conversation: Conversation? = nil, pick: Bool = false) {
        self.session = session; self.outcome = outcome; self.reason = reason; self.configDirectory = configDirectory; self.conversation = conversation; self.pick = pick
    }
    public var wireValue: NativeRPCValue {
        var value = NativeRPCValue.object([.init("session", session.raw), .init("outcome", .string(outcome.rawValue)), .init("reason", .string(reason))])
        if let configDirectory { value = value.setting("configDir", .string(configDirectory)) }
        if let conversation { value = value.setting("conversation", .string(conversation.rawValue)) }
        if pick { value = value.setting("pick", .bool(true)) }
        return value
    }
}

public enum BackendSessionLifecycleEvent: Sendable {
    case created(BackendSessionMeta)
    case accountChanged(BackendSessionMeta, BackendAccountCredentialLookup)
    case switchPending(sessionID: String, targetID: String, targetName: String)
    case switchFailed(sessionID: String, message: String)
    /// `note` is the sentence for the window (TS SESSION_SWITCHED_CHANNEL's
    /// fourth argument, switchedNote); empty when the window asked and is told
    /// by the answer itself.
    case replaced(oldID: String, session: BackendSessionMeta, note: String = "")
    case held([NativeHeldSession])
    case restored([BackendSessionRestoreDecision])
    case status(sessionID: String, status: BackendSessionStatus, source: String)
    case process(BackendSessionEvent)
}

public struct BackendSessionLifecycleCleanup: Sendable {
    public let readiness: BackendLaunchReadiness
    public let release: @Sendable (String) async throws -> Void
    /// Root supplies real browser binding, device ownership, transient grant and
    /// credential-proxy cleanup here. MCP launch leases remain with launch.
    public init(readiness: BackendLaunchReadiness, release: @escaping @Sendable (String) async throws -> Void) {
        self.readiness = readiness; self.release = release
    }
}

public struct BackendSessionRestoreContext: Sendable {
    public let readiness: BackendLaunchReadiness
    private let resolveDevice: @Sendable (String, String) async throws -> BackendDeviceBoundary
    public init(readiness: BackendLaunchReadiness, resolveDevice: @escaping @Sendable (String, String) async throws -> BackendDeviceBoundary) {
        self.readiness = readiness; self.resolveDevice = resolveDevice
    }
    public func context(for saved: BackendSessionSaved) async throws -> BackendLaunchContext {
        if let device = saved.deviceID {
            guard readiness == .ready else { throw BackendSessionFailure.missingCapability("the saved device's actual grant and confinement resolver") }
            let boundary = try await resolveDevice(device, saved.cwd)
            guard boundary.deviceKey == device, NativeTranscriptPaths.canonical(boundary.folder) == NativeTranscriptPaths.canonical(saved.cwd) else {
                throw BackendSessionFailure.invalidInput("The saved device boundary did not match its granted session folder.")
            }
            return BackendLaunchContext(deviceBoundary: boundary, rememberTab: true)
        }
        return BackendLaunchContext(rememberTab: true)
    }
}

extension BackendLaunchContext {
    func remembering(_ remember: Bool) -> BackendLaunchContext {
        BackendLaunchContext(deviceBoundary: deviceBoundary, appFenceID: appFenceID, extraArguments: extraArguments,
            rememberTab: remember, environmentOverrides: environmentOverrides, removeEnvironment: removeEnvironment, isAppComposed: isAppComposed,
            beforeExposure: beforeExposure)
    }
}
