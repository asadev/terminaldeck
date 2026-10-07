import Foundation
import TerminalDeckNativeCore

/// Session startup must use the device's original grant/spawn path, including guest git and confinement.
public protocol BackendDeckToolsMachinesDeviceFolders: Sendable {
    func deviceFolders(_ deviceID: String) async throws -> [String]
}
public enum BackendDeckToolsMachinesRemoteStart {
    public static func remoteDevice(_ caller: BackendDeckToolsMachinesContext) -> String? { caller.kind == .remote ? caller.deviceID ?? "" : nil }
    public static func sameFolder(_ a: String, _ b: String) -> Bool {
        // POSIX path.normalize, without resolving symlinks or expanding a tilde.
        func normalized(_ path: String) -> String {
            let absolute = path.hasPrefix("/")
            var parts: [String] = []
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                if component == "." { continue }
                if component == ".." {
                    if let last = parts.last, last != ".." { parts.removeLast() }
                    else if !absolute { parts.append("..") }
                } else { parts.append(String(component)) }
            }
            let value = (absolute ? "/" : "") + parts.joined(separator: "/")
            return value.isEmpty ? "." : value
        }
        return normalized(a) == normalized(b)
    }
    public static func requireDeviceFolder(_ service: (any BackendDeckToolsMachinesDeviceFolders)?, deviceID: String, folder: String) async throws -> String {
        guard let service else { throw BackendDeckToolsMachinesShared.refused("starting a session on behalf of a device is not available on this machine, so this was refused. Tell the person what you would have started and let them start it.") }
        let offered = deviceID.isEmpty ? [] : try await service.deviceFolders(deviceID)
        guard let granted = offered.first(where: { sameFolder($0, folder) }) else {
            throw BackendDeckToolsMachinesShared.refused(offered.isEmpty ? "this device has no folders chosen for it, so it cannot start a session anywhere. Nothing was started. Say so, and do not retry — the folders are chosen on the desktop, in Settings." : "this device may only start a session in: \(offered.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed.")
        }; return granted
    }
    public static func requireKeyFolder(_ caller: BackendDeckToolsMachinesContext, folder: String) throws -> String {
        guard caller.kind == .key, let folders = caller.folders, !folders.isEmpty else { return folder }
        if folders.contains(where: { allowed in sameFolder(allowed, folder) || folder.hasPrefix(allowed.hasSuffix("/") || allowed.hasSuffix("\\") ? allowed : allowed + "/") }) { return folder }
        throw BackendDeckToolsMachinesShared.refused("the access key this app is using may only start sessions in: \(folders.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed — the owner chooses the folders in Settings.")
    }
}

/// Incoming remote access: all effects go through the registered Remote panel operations.
public actor BackendDeckToolsMachinesRemote {
    public typealias V = NativeRPCValue
    typealias A = BackendDeckToolsArgs
    typealias S = BackendDeckToolsMachinesShared
    public static let ids = ["remote.status", "remote.manage"]
    public static let verbs = ["start", "stop", "show-code", "cancel-code", "approve", "revoke", "set-folders", "set-accounts", "set-sessions", "set-windows", "disconnect", "stop-tunnel", "keep-awake"]
    private static let needsDevice = ["approve", "revoke", "set-folders", "set-accounts", "set-sessions", "set-windows"]
    private let channels: any BackendDeckToolsMachinesChannels
    private var lastDevices: [V]?
    public init(channels: any BackendDeckToolsMachinesChannels) { self.channels = channels }
    private func call(_ name: String, _ args: [V], _ context: BackendDeckToolsMachinesContext) async throws -> V { try await channels.call(name, args, context: context) }
    private func name(_ id: String) -> String { lastDevices?.first { $0["id"].string == id }?["name"].string.map { "“\($0)”" } ?? "the device \(id)" }
    private func known(_ id: String) throws { if let lastDevices, !lastDevices.contains(where: { $0["id"].string == id }) { throw S.refused("There is no device \(id) paired with this computer. remote.status lists them.") } }
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsMachinesFactory.definitions(ids: Self.ids, environment: environment, prepare: { [self] spec, args, context in try await self.policy(spec, args, context) }, run: { [self] id, args, context in try await self.run(id, args, context) })
    }
    public func policy(_ spec: BackendMCPTool, _ args: V, _ context: BackendDeckToolsMachinesContext) throws -> BackendDeckToolsMachinesPolicy {
        try S.hereOnly(context, spec.id == "remote.status" ? "Reading who can reach this computer" : "Changing who can reach this computer")
        if spec.id == "remote.manage" {
            let verb = try A.oneOf(args, "do", Self.verbs)
            if Self.needsDevice.contains(verb) { try known(A.str(args, "deviceId")) }
            if verb == "approve" { let kind = try A.oneOf(args, "kind", ["mine", "guest"]); if kind == "guest" { _ = try A.strList(args, "folders"); _ = try A.oneOf(args, "loginShare", ["all", "selected"]) } }
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
        case "start": return "Turn remote access on, so paired phones and computers can reach this one"
        case "stop": return "Turn remote access off: every phone and computer connected to this one is cut off"
        case "show-code": return "Show a pairing code on this computer, so a new phone or computer can be paired with it"
        case "cancel-code": return "Withdraw the pairing code on screen"
        case "approve": return args["kind"].string == "mine" ? "Approve \(device) as the owner’s own device: it can reach everything this computer offers" : "Approve \(device) as a guest: it may start sessions only in \(list("folders")), using \(args["loginShare"].string == "all" ? "every login" : "the logins " + list("logins"))"
        case "revoke": return "Revoke \(device): it is disconnected and can no longer reach this computer"
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
    public static func rows(devices: [V], kinds: [V], folders: [V], accounts: [V], sessions: [V], windows: [String], connected: Set<String>) -> [V] {
        devices.map { device in
            let id = device["id"].string ?? "", kind = kinds.first { $0["deviceId"].string == id }?["kind"] ?? .null, account = accounts.first { $0["deviceId"].string == id }, session = sessions.first { $0["deviceId"].string == id }
            var row = S.object(["id": device["id"], "name": device["name"], "status": device["status"], "kind": kind, "connected": .bool(connected.contains(id)), "lastSeenAt": device["lastSeenAt"], "fingerprint": device["fingerprint"], "sessions": session.map { S.object(["share": $0["mode"], "ids": $0["sessions"]]) } ?? .null, "drivesWindows": .bool(windows.contains(id))])
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
            if try A.optBool(args, "tailscale", false) { result = result.setting("tailscale", S.object(["optional": .bool(true), "status": try await call("tailnet:status", [.bool(false)], context)])) }
            return .init(result, S.object(["on": remote["running"], "devices": .number(Double(rows.count)), "connected": .number(Double(connections.count))]))
        }
        let verb = try A.oneOf(args, "do", Self.verbs), deviceID = args["deviceId"].string ?? ""
        if Self.needsDevice.contains(verb) { lastDevices = try await call("remote:devices", [], context).elements ?? []; try known(deviceID) }
        func list(_ key: String) throws -> V { args[key] == .missing ? .array([]) : .array(try A.strList(args, key).map(V.string)) }
        let summary = S.object(["deviceId": .string(deviceID)])
        switch verb {
        case "start", "stop": let after = try await call(verb == "start" ? "remote:start" : "remote:stop", [], context); return .init(S.object(["on": after["running"], "why": after["reason"]]), S.object(["on": after["running"]]))
        case "show-code": let shown = try await call("remote:pair", [], context); let found = shown["findable"].bool == true; return .init(S.object(["code": shown["token"], "expiresAt": shown["expiresAt"], "findable": .bool(found), "note": .string(found ? "Type this into the app on the new phone or computer. It works once." : "The code could not be published to the relay, so only a device on this computer’s own network can use it.")]), S.object(["shown": .bool(true), "findable": .bool(found)]))
        case "cancel-code": _ = try await call("remote:pair:cancel", [], context); return .init(S.object(["cancelled": .bool(true)]), S.object(["cancelled": .bool(true)]))
        case "approve":
            let kind = try A.oneOf(args, "kind", ["mine", "guest"]), guest = kind == "guest"
            let after = try await call("remote:device:approve", [.string(deviceID), .string(kind), guest ? .array(A.strList(args, "folders").map(V.string)) : .array([]), .string(guest ? A.oneOf(args, "loginShare", ["all", "selected"]) : "all"), guest ? list("logins") : .array([])], context)
            lastDevices = after.elements ?? []; guard let device = lastDevices!.first(where: { $0["id"].string == deviceID }), device["status"].string == "approved" else { throw S.refused("\(name(deviceID)) was not approved. It may already have been decided, or revoked.") }; return .init(S.object(["device": device]), summary.setting("kind", .string(kind)))
        case "revoke": let after = try await call("remote:device:revoke", [.string(deviceID)], context); lastDevices = after.elements ?? []; return .init(S.object(["device": lastDevices!.first { $0["id"].string == deviceID } ?? .null]), summary)
        case "set-folders": let after = try await call("remote:folders:set", [.string(deviceID), .array(A.strList(args, "folders").map(V.string))], context); return .init(S.object(["folders": after.elements?.first { $0["deviceId"].string == deviceID }?["folders"] ?? .array([])]), summary)
        case "set-accounts", "set-sessions": let account = verb == "set-accounts", after = try await call(account ? "remote:accounts:set" : "remote:sessions:set", [.string(deviceID), .string(A.oneOf(args, account ? "loginShare" : "sessionShare", ["all", "selected"])), list(account ? "logins" : "sessions")], context); return .init(S.object([account ? "logins" : "sessions": after.elements?.first { $0["deviceId"].string == deviceID } ?? .null]), summary)
        case "set-windows": let allowed = try A.bool(args, "allowed"), after = try await call("remote:windows:set", [.string(deviceID), .bool(allowed)], context); return .init(S.object(["drivesWindows": .bool(after.elements?.contains(.string(deviceID)) == true)]), summary.setting("allowed", .bool(allowed)))
        case "disconnect": let connection = try A.str(args, "connectionId"), after = try await call("remote:connection:disconnect", [.string(connection)], context); return .init(S.object(["connectionsLeft": .number(Double(after.elements?.count ?? 0))]), S.object(["connectionId": .string(connection)]))
        case "stop-tunnel": let connection = try A.str(args, "connectionId"), tunnel = try A.str(args, "tunnelId"); _ = try await call("remote:tunnel:stop", [.string(connection), .string(tunnel)], context); return .init(S.object(["stopped": .bool(true)]), S.object(["connectionId": .string(connection), "tunnelId": .string(tunnel)]))
        default: let on = try A.bool(args, "on"); return .init(try await call("power:lid-awake:set", [.bool(on)], context), S.object(["on": .bool(on)]))
        }
    }
}
