import Foundation
import TerminalDeckNativeCore

// #108 (L6-SIMMENU, from Codex FIXES drafts): simulator management for the menu and MCP.

public protocol BackendFIXESDeviceManaging: Sendable {
    func deviceFolder(_ id: String) async throws -> URL
    func manageDevice(_ action: BackendFIXESDeviceManagement.Action, id: String, name: String?, confirmed: Bool) async throws -> NativeRPCValue
    func presentDevice(_ id: String, destination: String, sessionID: String?) async throws -> NativeRPCValue
}

/// The app window registers how a listed device is shown (tab, window, beside a
/// session, Finder). A process without a window answers with a plain refusal.
public final class BackendFIXESDevicePresenter: @unchecked Sendable {
    public typealias Present = @Sendable (NativeRPCValue, String, String?) async throws -> Void
    public static let shared = BackendFIXESDevicePresenter()
    private let lock = NSLock()
    private var present: Present?
    public init() {}
    public func install(_ present: @escaping Present) { lock.withLock { self.present = present } }
    public func show(_ row: NativeRPCValue, destination: String, sessionID: String?) async throws {
        let present = lock.withLock { self.present }
        guard let present else { throw NativeRPCError(code: "unavailable", message: "Open Terminal Deck's window to show a simulator.") }
        try await present(row, destination, sessionID)
    }
}

/// Spec §5 simulator names over the existing device manager and approval door.
/// These aliases add no engine, device list, process launcher or chat store.
public struct BackendFIXESSimulatorMCP: Sendable {
    let devices: any BackendDeckToolsMachinesDeviceService
    let management: any BackendFIXESDeviceManaging
    let attachments: BackendUIGSessionSimulatorAttachments?
    public init(devices: any BackendDeckToolsMachinesDeviceService, management: any BackendFIXESDeviceManaging,
                attachments: BackendUIGSessionSimulatorAttachments? = nil) {
        self.devices = devices; self.management = management; self.attachments = attachments
    }
    public static let ids = ["simulators.list", "simulators.start", "simulators.shutdown", "simulators.restart", "simulators.open", "simulators.rename", "simulators.erase", "simulators.delete"]
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try Self.ids.map { id in
            let read = id == "simulators.list", verb = String(id.dropFirst("simulators.".count))
            var properties: [NativeRPCValue.Field] = [], required: [NativeRPCValue] = []
            if !read { properties.append(.init("deviceId", .object([.init("type", .string("string"))]))); required.append(.string("deviceId")) }
            if verb == "start" { properties.append(.init("cold", .object([.init("type", .string("boolean"))]))) }
            if verb == "rename" { properties.append(.init("name", .object([.init("type", .string("string"))]))); required.append(.string("name")) }
            if verb == "open" {
                properties.append(.init("mode", .object([.init("type", .string("string")), .init("enum", .array([.string("tab"), .string("window"), .string("beside")]))])))
                properties.append(.init("sessionId", .object([.init("type", .string("string"))])))
                required.append(.string("mode"))
            }
            let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object(properties)),
                .init("required", .array(required)), .init("additionalProperties", .bool(false))])
            let title = read ? "List this Mac’s simulators" : verb.prefix(1).uppercased() + String(verb.dropFirst()) + " a simulator"
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: title + (read ? ". Uses the existing device list; reads are free." : ". Runs at once when the calling AI's permission mode allows it; the action is logged. Uses the same iOS/Android engine as the device panel."),
                inputSchema: schema, tier: read ? .read : .alter, advertised: false)
            return BackendDeckToolsDefinition(spec: spec, title: title, index: spec.description) { call, args in
                var prepared: BackendDeckToolsMachinesPolicy?
                do {
                    let context = try await environment.context(for: call)
                    try await environment.validate(arguments: args, schema: schema)
                    if let reason = await devices.unavailable() { throw NativeRPCError(code: "unavailable", message: reason) }
                    let id = read ? "" : try BackendDeckToolsMachinesDeviceRules.id(args)
                    let ticket: BackendUIGSessionSimulatorTicket?
                    if context.kind == .session {
                        guard context.machineID.isEmpty, let sessionID = context.sessionID, let attachments else {
                            throw NativeRPCError(code: "device-refused", message: "A session can use only its attached simulator on this Mac.")
                        }
                        let mine = try await attachments.attached(sessionID: sessionID)
                        ticket = mine.first { $0.deviceID == id }
                        if !read && ticket == nil { throw BackendUIGSessionSimulatorAttachments.stale() }
                        if verb == "open", args["mode"].string == "beside", args["sessionId"].string != sessionID {
                            throw NativeRPCError(code: "device-refused", message: "A session can show a simulator only beside itself.")
                        }
                    } else { ticket = nil }
                    if verb == "open", args["mode"].string == "beside" { _ = try args["sessionId"].requireString("sessionId", nonempty: true) }
                    let policy = BackendDeckToolsMachinesPolicy(tool: spec, arguments: args, loggedArguments: args,
                        tier: spec.tier, ownerMustAnswer: !read, sentence: read ? title : "\(title): \(id)")
                    prepared = policy
                    return try await environment.execute(context: context, policy: policy) {
                        if call.cancellation.isCancelled { throw CancellationError() }
                        if let ticket, let attachments { try await attachments.validate(ticket) }
                        var rows = try await devices.list()
                        if context.kind == .session, let sessionID = context.sessionID, let attachments {
                            let mine = Set(try await attachments.attached(sessionID: sessionID).compactMap(\.deviceID))
                            // Reading shows the whole Mac (marked); changing stays limited to this session's own panel.
                            if read { rows = rows.map { $0.setting("inThisPanel", .bool(mine.contains($0["id"].string ?? ""))) } }
                            else { rows = rows.filter { mine.contains($0["id"].string ?? "") } }
                        }
                        rows = rows.filter { ["simulator", "emulator"].contains($0["kind"].string ?? "") }
                        let value: NativeRPCValue
                        if read { value = .object([.init("devices", .array(rows))]) }
                        else {
                            guard let row = rows.first(where: { $0["id"].string == id }) else {
                                throw NativeRPCError(code: "device-refused", message: "That simulator is no longer listed. Refresh the list first.")
                            }
                            switch verb {
                            case "start":
                                if args["cold"].bool == true { value = try await management.manageDevice(.coldStart, id: id, name: nil, confirmed: true) }
                                else { guard row["canBoot"].bool == true else { throw NativeRPCError(code: "device-refused", message: "That simulator is already on or cannot be started.") }; value = try await devices.boot(id) }
                            case "shutdown": value = try await devices.shutDown(id)
                            case "restart": value = try await management.manageDevice(.restart, id: id, name: nil, confirmed: true)
                            case "open": value = try await management.presentDevice(id, destination: args["mode"].requireString("mode"), sessionID: args["sessionId"].string)
                            case "rename": value = try await management.manageDevice(.rename, id: id, name: args["name"].requireString("name"), confirmed: true)
                            case "erase": value = try await management.manageDevice(.reset, id: id, name: nil, confirmed: true)
                            default: value = try await management.manageDevice(.delete, id: id, name: nil, confirmed: true)
                            }
                            if value["ok"].bool == false { throw NativeRPCError(code: "device-fault", message: value["message"].string ?? "The simulator change did not finish.") }
                            if let ticket, let attachments, ["start", "restart"].contains(verb), let nextID = value["id"].string, nextID != ticket.deviceID {
                                _ = try await attachments.booted(ticket, as: nextID)
                            }
                        }
                        return .init(value, .object([.init("deviceId", .string(id)), .init("action", .string(verb)), .init("ok", .bool(true))]))
                    }
                } catch { return await environment.failed(call: call, tool: spec, policy: prepared, loggedArguments: args, error: error) }
            }
        }
    }
}
