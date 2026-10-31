import Foundation
import TerminalDeckNativeCore

/// Replace the existing device contribution with this wrapper; never register a second devices.* family.
public struct BackendUIGSessionSimulatorMCP: Sendable {
    public let service: any BackendDeckToolsMachinesDeviceService
    public let attachments: BackendUIGSessionSimulatorAttachments
    public let recording: BackendUIGSessionSimulatorRecording?
    public init(service: any BackendDeckToolsMachinesDeviceService, attachments: BackendUIGSessionSimulatorAttachments,
                recording: BackendUIGSessionSimulatorRecording? = nil) {
        self.service = service; self.attachments = attachments; self.recording = recording
    }
    private func session(_ context: BackendDeckToolsMachinesContext, args: NativeRPCValue, manages: Bool = false) throws -> String {
        if context.kind == .session {
            guard !manages, context.machineID.isEmpty, let id = context.sessionID, !id.isEmpty,
                  args["sessionId"].isNullish, args["machineId"].isNullish else {
                throw BackendUIGSessionSimulatorAttachments.refused("Only the person may attach or detach a device. A session can read and drive only its own device on this Mac.")
            }
            return id
        }
        guard context.actsAsOwner else { throw BackendUIGSessionSimulatorAttachments.refused("Device attachments can be managed only by the person at this Mac.") }
        return try args["sessionId"].requireString("sessionId", nonempty: true)
    }
    /// A session drives only its own devices (up to two). `deviceId` may be a device's id or its name.
    private func scoped(_ context: BackendDeckToolsMachinesContext, args: NativeRPCValue, cancellation: BackendMCPCancellation) async throws -> (BackendDeckToolsMachinesDevices, [BackendUIGSessionSimulatorTicket], NativeRPCValue) {
        guard context.kind == .session else { return (BackendDeckToolsMachinesDevices(service: service), [], args) }
        let id = try session(context, args: args)
        try await attachments.refresh(service: service)
        var tickets = try await attachments.attached(sessionID: id)
        if tickets.isEmpty { tickets = [try await attachments.snapshot(sessionID: id)] } // nothing attached: the old "attach a device first" answers
        var driven = args
        if args["deviceId"] != .missing {
            let typed = args["deviceId"].string ?? "" // an id, or a name: the id rules run on the id it resolves to
            let wanted = BackendAppDeviceIDs.normalize(typed) // "emulator-5554" or a bare UDID is the listed id
            if tickets.contains(where: { $0.deviceID == wanted }) { if wanted != typed { driven = args.setting("deviceId", .string(wanted)) } }
            else {
                // By name: the attached device whose name matches (case-insensitive), when exactly one does.
                let ids = Set(tickets.compactMap(\.deviceID))
                let rows = (try? await service.list()) ?? []
                let named = rows.filter { ids.contains($0["id"].string ?? "") && BackendAppDeviceIDs.matches($0, typed) }
                guard named.count == 1, let match = named[0]["id"].string else {
                    // Listed (devices.list shows the whole Mac) but not in this panel: say so, not "changed".
                    if rows.contains(where: { BackendAppDeviceIDs.matches($0, typed) }) {
                        throw BackendUIGSessionSimulatorAttachments.refused("\(typed) is not in this session’s phone panel, so this session cannot drive it. Call devices_open_app with its id to show it there first; a running device is shown as it is, never restarted.")
                    }
                    throw BackendUIGSessionSimulatorAttachments.stale()
                }
                driven = args.setting("deviceId", .string(match))
            }
        }
        return (BackendDeckToolsMachinesDevices(service: BackendUIGSessionSimulatorDeviceService(base: service, attachments: attachments, tickets: tickets, cancellation: cancellation)), tickets, driven)
    }
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        let original = try BackendDeckToolsMachinesDevices(service: service).definitions(environment: environment)
        let wrapped = original.map { row in
            BackendDeckToolsDefinition(spec: row.spec, title: row.title, index: row.index, aliases: row.aliases,
                audience: row.audience, keyIndex: row.keyIndex, keyGrant: row.keyGrant) { call, args in
                var prepared: BackendDeckToolsMachinesPolicy?
                do {
                    let context = try await environment.context(for: call)
                    try await environment.validate(arguments: args, schema: row.spec.inputSchema)
                    let (devices, tickets, driven) = try await scoped(context, args: args, cancellation: call.cancellation)
                    let policy = try await devices.policy(row.spec, driven, context); prepared = policy
                    return try await environment.execute(context: context, policy: policy) {
                        if call.cancellation.isCancelled { throw CancellationError() }
                        for ticket in tickets { try await attachments.validate(ticket) }
                        return try await devices.run(row.spec.id, driven, context)
                    }
                } catch {
                    return await environment.failed(call: call, tool: row.spec, policy: prepared,
                        loggedArguments: prepared?.loggedArguments ?? BackendDeckToolsMachinesFactory.loggedArguments(toolID: row.spec.id, arguments: args), error: error)
                }
            }
        }
        return wrapped + (try attachmentDefinitions(environment: environment)) + (try recordingDefinitions(environment: environment))
    }
    /// Pick the exact live attachment before approval; never guess between two phones.
    private func recordingTicket(_ context: BackendDeckToolsMachinesContext, args: NativeRPCValue) async throws -> BackendUIGSessionSimulatorTicket {
        let target = try session(context, args: args)
        try await attachments.refresh(service: service)
        let tickets = try await attachments.attached(sessionID: target)
        if !args["deviceId"].isNullish {
            let deviceID = try BackendDeckToolsMachinesDeviceRules.id(args)
            guard let ticket = tickets.first(where: { $0.deviceID == deviceID }) else {
                throw BackendUIGSessionSimulatorAttachments.refused("That device is not attached to this session. Read devices.attached first.")
            }
            return ticket
        }
        guard tickets.count <= 1 else {
            throw BackendUIGSessionSimulatorAttachments.refused("Two devices are attached. Say which one to record or read (deviceId).")
        }
        if let ticket = tickets.first { return ticket }
        return try await attachments.snapshot(sessionID: target)
    }
    private func recordingDefinitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        guard let recording else { return [] }
        return try [false, true].map { changes in
            let id = changes ? "devices.record" : "devices.recording"
            var properties: [NativeRPCValue.Field] = [.init("sessionId", .object([.init("type", .string("string"))])),
                .init("deviceId", .object([.init("type", .string("string")), .init("description", .string("Which attached device. Required when the session has two devices."))]))]
            if changes { properties.append(.init("action", .object([.init("type", .string("string")), .init("enum", .array([.string("start"), .string("stop")]))]))) }
            let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object(properties)),
                .init("required", .array(changes ? [.string("action")] : [])), .init("additionalProperties", .bool(false))])
            let title = changes ? "Record this session’s phone screen" : "Read this session’s recording status"
            let spec = try BackendMCPTool(id: id, wireName: changes ? "devices_record" : "devices_recording", description: title + ". Uses the session phone panel’s existing recorder for a running iOS simulator or Android device on this Mac. Sessions omit sessionId; owner callers name a live local session. Name deviceId when two devices are attached. When Hoot calls, start and stop count as a change; they run when its permission mode allows them. Videos save in the app’s Pictures folder.", inputSchema: schema, tier: changes ? .act : .read, advertised: false)
            return BackendDeckToolsDefinition(spec: spec, title: title, index: spec.description) { call, args in
                var prepared: BackendDeckToolsMachinesPolicy?
                do {
                    let context = try await environment.context(for: call)
                    try await environment.validate(arguments: args, schema: spec.inputSchema)
                    let ticket = try await recordingTicket(context, args: args)
                    let policy = BackendDeckToolsMachinesPolicy(tool: spec, arguments: args, loggedArguments: args,
                        tier: spec.tier, ownerMustAnswer: changes && context.kind == .local,
                        spends: changes ? "device-input" : "changes", sentence: title)
                    prepared = policy
                    return try await environment.execute(context: context, policy: policy) {
                        if call.cancellation.isCancelled { throw CancellationError() }
                        try await attachments.validate(ticket)
                        let value: NativeRPCValue
                        if !changes { value = try await recording.status(ticket) }
                        else if args["action"].string == "start" { value = try await recording.start(ticket, cancellation: call.cancellation) }
                        else { value = try await recording.stop(ticket) }
                        return .init(value, ticket.value.setting("recording", value["recording"]))
                    }
                } catch { return await environment.failed(call: call, tool: spec, policy: prepared, loggedArguments: args, error: error) }
            }
        }
    }
    private func attachmentDefinitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try ["attached", "attach", "detach"].map { action in
            let manages = action != "attached", id = "devices." + action
            var properties: [NativeRPCValue.Field] = [.init("sessionId", .object([.init("type", .string("string")), .init("description", .string("Owner-only target session. Calling sessions must omit this."))]))]
            if action == "attach" { properties.append(.init("deviceId", .object([.init("type", .string("string"))]))) }
            // A session shows up to two devices. Attach fills the first free place; detach names the device (id or name) when two are attached.
            if action == "detach" { properties.append(.init("deviceId", .object([.init("type", .string("string")), .init("description", .string("Which attached device to detach (id or name); needed when two are attached."))]))) }
            let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object(properties)),
                .init("required", .array((action == "attach" ? ["sessionId", "deviceId"] : manages ? ["sessionId"] : []).map(NativeRPCValue.string))),
                .init("additionalProperties", .bool(false))])
            let title = action == "attached" ? "Read this session’s attached device" : action == "attach" ? "Attach a device to a session" : "Detach a session’s device"
            let spec = try BackendMCPTool(id: id, wireName: "devices_" + action,
                description: title + ". Devices stay on this Mac. A session shows up to two devices at once (iOS or Android). Attach and detach are owner-only changes that run when the calling AI’s permission mode allows them; attached reads the calling session’s devices. Use existing devices tools, with either device’s id or name, to see and drive it.",
                inputSchema: schema, tier: manages ? .alter : .read, advertised: false)
            return BackendDeckToolsDefinition(spec: spec, title: title, index: spec.description) { call, args in
                var prepared: BackendDeckToolsMachinesPolicy?
                do {
                    let context = try await environment.context(for: call)
                    try await environment.validate(arguments: args, schema: spec.inputSchema)
                    let target = try session(context, args: args, manages: manages)
                    try await attachments.refresh(service: service)
                    let ticket = try await attachments.snapshot(sessionID: target)
                    let deviceID = action == "attach" ? try BackendDeckToolsMachinesDeviceRules.id(args) : nil
                    let current = try await attachments.attached(sessionID: target)
                    let policy = BackendDeckToolsMachinesPolicy(tool: spec, arguments: args, loggedArguments: args, tier: spec.tier,
                        ownerMustAnswer: manages, sentence: title + " " + target)
                    prepared = policy
                    return try await environment.execute(context: context, policy: policy) {
                        if call.cancellation.isCancelled { throw CancellationError() }
                        try await attachments.validate(ticket)
                        let result: BackendUIGSessionSimulatorTicket
                        if let deviceID {
                            if let held = current.first(where: { $0.deviceID == deviceID }) { result = held }
                            else {
                                // The first free place; two is the limit.
                                let taken = Set(current.map(\.slot))
                                guard let slot = BackendUIGSessionSimulatorAttachments.slots.first(where: { !taken.contains($0) }) else {
                                    throw BackendUIGSessionSimulatorAttachments.refused("A session can show at most two devices. Detach one first.")
                                }
                                result = try await attachments.attach(sessionID: target, deviceID: deviceID, slot: slot, service: service)
                            }
                        } else if action == "detach" {
                            var which = current.first
                            if let named = args["deviceId"].string, !named.isEmpty {
                                let rows = (try? await service.list()) ?? []
                                which = current.first { $0.deviceID == named }
                                    ?? current.first { held in rows.contains { $0["id"].string == held.deviceID && ($0["name"].string ?? "").lowercased() == named.lowercased() } }
                                guard which != nil else { throw BackendUIGSessionSimulatorAttachments.stale() }
                            } else if current.count > 1 {
                                throw BackendUIGSessionSimulatorAttachments.refused("Two devices are attached. Say which one to detach (deviceId).")
                            }
                            if let which { result = try await attachments.detach(sessionID: target, slot: which.slot, expected: which) } else { result = ticket }
                        } else {
                            result = current.first ?? ticket
                        }
                        // Every attached device, so an agent can address each by id or name.
                        let all = try await attachments.attached(sessionID: target)
                        return .init(result.value.setting("devices", .array(all.map(\.value))), result.value.setting("devices", .array(all.map(\.value))))
                    }
                } catch {
                    return await environment.failed(call: call, tool: spec, policy: prepared, loggedArguments: args, error: error)
                }
            }
        }
    }
}
