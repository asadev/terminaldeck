import Foundation
import TerminalDeckNativeCore

/// A policy is supported only when its actual execution owner supplies both
/// callbacks. A settings-file write alone is not an implementation of a policy.
public struct BackendROUTINESHootField: Sendable {
    public let read: @Sendable () async throws -> NativeRPCValue
    public let apply: @Sendable (NativeRPCValue) async throws -> Void
    public init(read: @escaping @Sendable () async throws -> NativeRPCValue,
                apply: @escaping @Sendable (NativeRPCValue) async throws -> Void) {
        self.read = read; self.apply = apply
    }
}

/// No new runtime, chat store, permission store or memory store lives here.
public struct BackendROUTINESHootDependencies: Sendable {
    public let fields: [String: BackendROUTINESHootField]
    public let readyRead: (@Sendable () async throws -> NativeRPCValue)?
    public let readySave: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)?
    public let start: (@Sendable () async throws -> NativeRPCValue)?
    public let stop: (@Sendable () async throws -> NativeRPCValue)?
    public let restart: (@Sendable () async throws -> NativeRPCValue)?
    /// Must quiesce actual launches, stop Hoot, then clear ONLY its chat+notes.
    /// Never delete user folders, instructions, action logs, settings or routines.
    public let reset: (@Sendable () async throws -> Void)?
    public let memoryList: (@Sendable () async throws -> NativeRPCValue)?
    public let memoryDelete: (@Sendable (String) async throws -> NativeRPCValue)?
    public let actions: (@Sendable () async throws -> NativeRPCValue)?
    public let reveal: (@Sendable () async throws -> NativeRPCValue)?
    public init(fields: [String: BackendROUTINESHootField] = [:],
                readyRead: (@Sendable () async throws -> NativeRPCValue)? = nil,
                readySave: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)? = nil,
                start: (@Sendable () async throws -> NativeRPCValue)? = nil,
                stop: (@Sendable () async throws -> NativeRPCValue)? = nil,
                restart: (@Sendable () async throws -> NativeRPCValue)? = nil,
                reset: (@Sendable () async throws -> Void)? = nil,
                memoryList: (@Sendable () async throws -> NativeRPCValue)? = nil,
                memoryDelete: (@Sendable (String) async throws -> NativeRPCValue)? = nil,
                actions: (@Sendable () async throws -> NativeRPCValue)? = nil,
                reveal: (@Sendable () async throws -> NativeRPCValue)? = nil) {
        self.fields = fields; self.readyRead = readyRead; self.readySave = readySave
        self.start = start; self.stop = stop; self.restart = restart; self.reset = reset
        self.memoryList = memoryList; self.memoryDelete = memoryDelete; self.actions = actions; self.reveal = reveal
    }
}

public actor BackendROUTINESHootSettings {
    /// Asad, 12 Oct: the four "What Hoot may do" switches (run sessions, hand problems out, use simulators and phones,
    /// folders it can open) are gone: Hoot can always do all of them. Only the permission mode is left here.
    public static let policyFields = ["permissionMode"]
    /// The retired switches: a call that still names one is refused as an unknown setting.
    public static let retiredFields = ["runSessions", "routingMode", "useDevices", "folders"]
    public static let brainFields = ["provider", "profileId", "model", "effort", "contextWindow"]
    public static let channels = ["hoot:settings:read", "hoot:settings:set", "hoot:settings:reset"]
    private let dependencies: BackendROUTINESHootDependencies
    private var changing = false
    public init(_ dependencies: BackendROUTINESHootDependencies) { self.dependencies = dependencies }

    public static func unavailable(_ field: String) -> NativeRPCError {
        .init(code: "unavailable", message: "Hoot's \(field) control is unavailable in this build.")
    }
    public static func validate(field: String, value: NativeRPCValue) throws {
        switch field {
        case "permissionMode":
            guard ["ask", "plan", "allow"].contains(value.string ?? "") else { throw NativeRPCError.invalidArguments("Choose Asks first, Plans only or Changes without asking.") }
        case _ where retiredFields.contains(field):
            throw NativeRPCError.invalidArguments("Hoot can always run sessions, hand problems to the right agent, use simulators and phones, and open any folder. There is no setting for that any more.")
        case "provider", "profileId", "model", "effort", "contextWindow":
            _ = try HootReadyPreferences(wire: .object([.init(field, value)]))
        default: throw NativeRPCError.invalidArguments("Unknown Hoot setting.")
        }
    }
    public func read() async throws -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [], capabilities: [NativeRPCValue.Field] = [], problems: [NativeRPCValue.Field] = []
        for name in Self.policyFields {
            guard let owner = dependencies.fields[name] else {
                capabilities.append(.init(name, .bool(false))); continue
            }
            do {
                let value = try await owner.read()
                try Self.validate(field: name, value: value)
                fields.append(.init(name, value)); capabilities.append(.init(name, .bool(true)))
            } catch {
                capabilities.append(.init(name, .bool(false)))
                problems.append(.init(name, .string(NativeRPCError.wrapping(error).message)))
            }
        }
        capabilities.append(.init("reset", .bool(dependencies.reset != nil)))
        if let ready = dependencies.readyRead {
            fields.append(.init("brain", try await ready()))
        }
        fields.append(.init("capabilities", .object(capabilities)))
        fields.append(.init("problems", .object(problems)))
        return .object(fields)
    }
    public func set(field: String, value: NativeRPCValue) async throws -> NativeRPCValue {
        // With no separate policy owner, "permissionMode" is the brain's CLI permission mode.
        let brain = Self.brainFields.contains(field) || field == "permissionMode" && dependencies.fields["permissionMode"] == nil
        if brain { _ = try HootReadyPreferences(wire: .object([.init(field, value)])) } else { try Self.validate(field: field, value: value) }
        guard !changing else { throw NativeRPCError(code: "busy", message: "Hoot settings are already changing. Try again after that finishes.") }
        changing = true; defer { changing = false }
        if brain {
            guard let read = dependencies.readyRead, let save = dependencies.readySave else { throw Self.unavailable("AI defaults") }
            let current = try await read()
            _ = try await save(current["choices"].setting(field, value))
        } else {
            guard let owner = dependencies.fields[field] else { throw Self.unavailable(field) }
            try await owner.apply(value)
        }
        return try await read()
    }
    public func reset(confirmation: String) async throws -> NativeRPCValue {
        guard confirmation == "Reset Hoot" else { throw NativeRPCError.invalidArguments("Confirm Reset Hoot to clear Hoot's chat and notes.") }
        guard let reset = dependencies.reset else { throw Self.unavailable("reset") }
        guard !changing else { throw NativeRPCError(code: "busy", message: "Hoot settings are already changing.") }
        changing = true; defer { changing = false }
        try await reset()
        return .object([.init("ok", .bool(true))])
    }
    public func perform(_ operation: String, arguments: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        switch operation {
        case "read": return try await read()
        case "set": return try await set(field: arguments["field"].requireString("field"), value: arguments["value"])
        case "reset": return try await reset(confirmation: arguments["confirm"].requireString("confirm"))
        case "start": guard let start = dependencies.start else { throw Self.unavailable("start") }; return try await start()
        case "stop": guard let stop = dependencies.stop else { throw Self.unavailable("stop") }; return try await stop()
        case "restart": guard let restart = dependencies.restart else { throw Self.unavailable("restart") }; return try await restart()
        case "memory-list": guard let list = dependencies.memoryList else { throw Self.unavailable("memory") }; return try await list()
        case "memory-delete":
            let name = try arguments["name"].requireString("name", nonempty: true)
            guard BackendCopilotInspect.isMemoryName(.string(name)) else { throw NativeRPCError.invalidArguments("Choose a plain memory filename.") }
            guard let remove = dependencies.memoryDelete else { throw Self.unavailable("memory delete") }
            return try await remove(name)
        case "actions": guard let actions = dependencies.actions else { throw Self.unavailable("actions") }; return try await actions()
        case "reveal": guard let reveal = dependencies.reveal else { throw Self.unavailable("folder") }; return try await reveal()
        default: throw Self.unavailable(operation)
        }
    }
    /// The composition must authenticate the genuine Settings window here.
    /// The nativeApp caller tag alone is not enough.
    public func register(registry: NativeChannelRegistry, ownerID: String = "routines-hoot-settings",
                         requireWindow: @escaping @Sendable (NativeRPCContext) async throws -> Void) async throws {
        for channel in Self.channels {
            try await registry.register(channel, ownerID: ownerID) { [self] context, args in
                try await requireWindow(context)
                let operation = channel == "hoot:settings:read" ? "read" : channel == "hoot:settings:set" ? "set" : "reset"
                return try await perform(operation, arguments: context.argument(0, in: args).isNullish ? .object([]) : context.argument(0, in: args))
            }
        }
    }
}
