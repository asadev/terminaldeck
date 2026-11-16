import Foundation
import TerminalDeckNativeCore

/// Session startup must use the device's original grant/spawn path, including guest git and confinement.
public protocol BackendDeckToolsMachinesDeviceFolders: Sendable {
    func deviceFolders(_ deviceID: String) async throws -> [String]
}

/// Incoming remote access: all effects go through the registered Remote panel operations.
public actor BackendDeckToolsMachinesRemote {
    public typealias V = NativeRPCValue
    typealias A = BackendDeckToolsArgs
    typealias S = BackendDeckToolsMachinesShared
    public static let ids = ["remote.status", "remote.manage"]
    public static let verbs = ["start", "stop", "revoke", "rename", "set-folders", "set-accounts", "set-sessions", "set-windows", "disconnect", "stop-tunnel", "keep-awake"]
    /// The old ways to add a device (a six-digit number on screen, letting a waiting device in, the local web version with
    /// its one-time address) are gone (owner, 13 Nov): a call for one is answered with how devices join now.
    public static let retired = ["show-code", "cancel-code", "approve", "open-web"]
    private static let needsDevice = ["revoke", "rename", "set-folders", "set-accounts", "set-sessions", "set-windows"]
    private let channels: any BackendDeckToolsMachinesChannels
    private var lastDevices: [V]?
    public init(channels: any BackendDeckToolsMachinesChannels) { self.channels = channels }
    private func call(_ name: String, _ args: [V], _ context: BackendDeckToolsMachinesContext) async throws -> V { try await channels.call(name, args, context: context) }
    private func name(_ id: String) -> String { lastDevices?.first { $0["id"].string == id }?["name"].string.map { "“\($0)”" } ?? "the device \(id)" }
    private func known(_ id: String) throws { if let lastDevices, !lastDevices.contains(where: { $0["id"].string == id }) { throw S.refused("There is no device \(id) connected to this computer. remote.status lists them.") } }
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsMachinesFactory.definitions(ids: Self.ids, environment: environment, prepare: { [self] spec, args, context in try await self.policy(spec, args, context) }, run: { [self] id, args, context in try await self.run(id, args, context) })
    }
    public func policy(_ spec: BackendMCPTool, _ args: V, _ context: BackendDeckToolsMachinesContext) throws -> BackendDeckToolsMachinesPolicy {
        try S.hereOnly(context, spec.id == "remote.status" ? "Reading who can reach this computer" : "Changing who can reach this computer")
        if spec.id == "remote.manage" {
            if let asked = args["do"].string, Self.retired.contains(asked) { throw S.refused(DevicesPage.joinBySigningIn) }
            let verb = try A.oneOf(args, "do", Self.verbs)
            if Self.needsDevice.contains(verb) { try known(A.str(args, "deviceId")) }
            if verb == "rename" { _ = try Self.newName(args) }
            if verb == "set-folders" { _ = try A.strList(args, "folders") }; if verb == "set-accounts" { _ = try A.oneOf(args, "loginShare", ["all", "selected"]) }; if verb == "set-sessions" { _ = try A.oneOf(args, "sessionShare", ["all", "selected"]) }
            if verb == "set-windows" { _ = try A.bool(args, "allowed") }; if ["disconnect", "stop-tunnel"].contains(verb) { _ = try A.str(args, "connectionId") }; if verb == "stop-tunnel" { _ = try A.str(args, "tunnelId") }; if verb == "keep-awake" { _ = try A.bool(args, "on") }
        }
        return .init(tool: spec, arguments: args, loggedArguments: args, tier: spec.tier, ownerMustAnswer: spec.id == "remote.manage", sentence: sentence(spec.id, args))
    }
    public func sentence(_ id: String, _ args: V) -> String {
        if id == "remote.status" { return "Read who can reach this computer" }
        let device = name(args["deviceId"].string ?? "?"), verb = args["do"].string ?? ""
        func list(_ key: String) -> String { let rows = args[key].elements?.compactMap(\.string) ?? []; return rows.isEmpty ? "none" : rows.joined(separator: ", ") }
        switch verb {
        case "start": return "Turn remote access on, so devices connected before accounts can reach this one"
        case "stop": return "Turn remote access off: every phone and computer connected to this one is cut off"
        case "revoke": return "Remove \(device): it is disconnected and can no longer reach this computer"
        case "rename": return "Rename \(device) to “\((args["name"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))”"
        case "set-folders": return "Let \(device) start sessions in: \(list("folders"))"
        case "set-accounts": return args["loginShare"].string == "all" ? "Let \(device) use every agent login" : "Let \(device) use only the logins: \(list("logins"))"
        case "set-sessions": return args["sessionShare"].string == "all" ? "Let \(device) see every session" : "Let \(device) see only the sessions: \(list("sessions"))"
        case "set-windows": return args["allowed"].bool == true ? "Let \(device) drive browser windows here" : "Stop \(device) driving browser windows here"
        case "disconnect": return "Disconnect the connection \(args["connectionId"].string ?? "undefined") now (the device may reconnect)"
        case "stop-tunnel": return "Stop the port \(args["tunnelId"].string ?? "undefined") that connection \(args["connectionId"].string ?? "undefined") opened"
        case "keep-awake": return args["on"].bool == true ? "Keep this computer awake with the lid closed (macOS will ask for the administrator password here)" : "Let this computer sleep with the lid closed again"
        default: return "Change remote access"
        }
    }
    /// The Devices page's Rename rule: 1 to 128 characters once trimmed.
    static func newName(_ args: V) throws -> String {
        let name = try A.str(args, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 128 else { throw A.bad("name must be 1 to 128 characters") }
        return name
    }
    public static func rows(devices: [V], kinds: [V], folders: [V], accounts: [V], sessions: [V], windows: [String], connected: Set<String>) -> [V] {
        devices.map { device in
            let id = device["id"].string ?? "", kind = kinds.first { $0["deviceId"].string == id }?["kind"] ?? .null, account = accounts.first { $0["deviceId"].string == id }, session = sessions.first { $0["deviceId"].string == id }
            var row = S.object(["id": device["id"], "name": device["name"], "status": device["status"], "kind": kind, "connected": .bool(connected.contains(id)), "lastSeenAt": device["lastSeenAt"], "fingerprint": device["fingerprint"], "platform": device["platform"], "sessions": session.map { S.object(["share": $0["mode"], "ids": $0["sessions"]]) } ?? .null, "drivesWindows": .bool(windows.contains(id)), "joined": .string("before accounts")])
            if kind.string == "guest" { row = row.setting("folders", folders.first { $0["deviceId"].string == id }?["folders"] ?? .array([])).setting("logins", account.map { S.object(["share": $0["mode"], "ids": $0["accounts"]]) } ?? .null) }; return row
        }
    }
    public func run(_ id: String, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesOutput {
        if id == "remote.status" {
            async let status = call("remote:status", [], context); async let devices = call("remote:devices", [], context); async let kinds = call("remote:kinds", [], context); async let folders = call("remote:folders", [], context); async let accounts = call("remote:accounts", [], context); async let sessions = call("remote:sessions", [], context); async let windows = call("remote:windows", [], context); async let offered = call("remote:sessions:running", [], context); async let awake = call("power:lid-awake:get", [], context); async let confinement = call("confine:state", [], context)
            let (remote, deviceRows, kindRows, folderRows, accountRows, sessionRows, windowIDs, running, keepAwake, confine) = try await (status, devices, kinds, folders, accounts, sessions, windows, offered, awake, confinement)
            let connections = remote["connections"].elements ?? []; lastDevices = deviceRows.elements ?? []
            let rows = Self.rows(devices: lastDevices!, kinds: kindRows.elements ?? [], folders: folderRows.elements ?? [], accounts: accountRows.elements ?? [], sessions: sessionRows.elements ?? [], windows: windowIDs.elements?.compactMap(\.string) ?? [], connected: Set(connections.compactMap { $0["deviceId"].string }))
            let relay = remote["relay"].isNullish ? V.null : S.object(["connected": remote["relay"]["connected"], "why": remote["relay"]["reason"], "fingerprint": remote["relay"]["fingerprint"]])
            var result = S.object(["remoteAccess": S.object(["on": remote["running"], "why": remote["reason"], "relay": relay]), "devices": .array(rows), "connections": .array(connections.map { S.object(["id": $0["id"], "deviceId": $0["deviceId"], "device": $0["deviceName"], "platform": $0["platform"], "connectedAt": $0["connectedAt"], "sessions": $0["sessionIds"], "tunnels": $0["tunnels"]]) }), "offeredSessions": running, "keepAwake": keepAwake, "confinement": confine])
            // The account's own devices are on the Devices window and in devices_page; these rows are the old way only.
            result = result.setting("howDevicesJoin", .string(DevicesPage.joinBySigningIn))
            if try A.optBool(args, "tailscale", false) { result = result.setting("tailscale", S.object(["optional": .bool(true), "status": try await call("tailnet:status", [.bool(false)], context)])) }
            return .init(result, S.object(["on": remote["running"], "devices": .number(Double(rows.count)), "connected": .number(Double(connections.count))]))
        }
        if let asked = args["do"].string, Self.retired.contains(asked) { throw S.refused(DevicesPage.joinBySigningIn) }
        let verb = try A.oneOf(args, "do", Self.verbs), deviceID = args["deviceId"].string ?? ""
        if Self.needsDevice.contains(verb) { lastDevices = try await call("remote:devices", [], context).elements ?? []; try known(deviceID) }
        func list(_ key: String) throws -> V { args[key] == .missing ? .array([]) : .array(try A.strList(args, key).map(V.string)) }
        let summary = S.object(["deviceId": .string(deviceID)])
        switch verb {
        case "start", "stop": let after = try await call(verb == "start" ? "remote:start" : "remote:stop", [], context); return .init(S.object(["on": after["running"], "why": after["reason"]]), S.object(["on": after["running"]]))
        case "revoke": let after = try await call("remote:device:revoke", [.string(deviceID)], context); lastDevices = after.elements ?? []; return .init(S.object(["device": lastDevices!.first { $0["id"].string == deviceID } ?? .null]), summary)
        case "rename":
            let newName = try Self.newName(args), after = try await call("remote:device:rename", [.string(deviceID), .string(newName)], context)
            lastDevices = after.elements ?? []; return .init(S.object(["device": lastDevices!.first { $0["id"].string == deviceID } ?? .null]), summary.setting("name", .string(newName)))
        case "set-folders": let after = try await call("remote:folders:set", [.string(deviceID), .array(A.strList(args, "folders").map(V.string))], context); return .init(S.object(["folders": after.elements?.first { $0["deviceId"].string == deviceID }?["folders"] ?? .array([])]), summary)
        case "set-accounts", "set-sessions": let account = verb == "set-accounts", after = try await call(account ? "remote:accounts:set" : "remote:sessions:set", [.string(deviceID), .string(A.oneOf(args, account ? "loginShare" : "sessionShare", ["all", "selected"])), list(account ? "logins" : "sessions")], context); return .init(S.object([account ? "logins" : "sessions": after.elements?.first { $0["deviceId"].string == deviceID } ?? .null]), summary)
        case "set-windows": let allowed = try A.bool(args, "allowed"), after = try await call("remote:windows:set", [.string(deviceID), .bool(allowed)], context); return .init(S.object(["drivesWindows": .bool(after.elements?.contains(.string(deviceID)) == true)]), summary.setting("allowed", .bool(allowed)))
        case "disconnect": let connection = try A.str(args, "connectionId"), after = try await call("remote:connection:disconnect", [.string(connection)], context); return .init(S.object(["connectionsLeft": .number(Double(after.elements?.count ?? 0))]), S.object(["connectionId": .string(connection)]))
        case "stop-tunnel": let connection = try A.str(args, "connectionId"), tunnel = try A.str(args, "tunnelId"); _ = try await call("remote:tunnel:stop", [.string(connection), .string(tunnel)], context); return .init(S.object(["stopped": .bool(true)]), S.object(["connectionId": .string(connection), "tunnelId": .string(tunnel)]))
        default: let on = try A.bool(args, "on"); return .init(try await call("power:lid-awake:set", [.bool(on)], context), S.object(["on": .bool(on)]))
        }
    }
}
