import Foundation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Additive names from SHELL-SPEC, and the Devices window's own tools (owner, 13 Nov: devices join by signing in to the
/// account; no tool makes a code, a link or lets a waiting device in any more).
enum MACHINESMCP {
    typealias Invoke = @Sendable (String, [NativeRPCValue], BackendMCPCallContext) async throws -> NativeRPCValue
    typealias OpenServer = @Sendable (CodingAIServer) async throws -> Void
    /// The account half of the Devices window: signed in, the account's devices, the reach switch.
    struct AccountHalf: Sendable {
        let signedIn: Bool
        let devices: [DevicesPage.AccountDevice]
        let reach: DevicesPage.Reach
    }
    typealias Account = @Sendable () async -> AccountHalf
    /// "Sign out this device" for an account device: exactly what the Settings → Devices row does once its Undo passed.
    typealias SignOut = @Sendable (String) async throws -> Void
    static let liveSignOut: SignOut = { deviceId in try await signOutLive(deviceId) }
    @MainActor private static func signOutLive(_ deviceId: String) async throws {
        try await NativeDeviceSignOut.Actions.live(account: .shared, reach: .shared).signOutBoth(deviceId)
    }

    /// The device page's "Name" row (review-fixes 2, 15 Nov): the same `NativeCloudAccount.renameDevice` it calls.
    typealias Rename = @Sendable (String, String) async throws -> Void
    static let liveRename: Rename = { deviceId, name in try await renameLive(deviceId, name) }
    @MainActor private static func renameLive(_ deviceId: String, _ name: String) async throws {
        try await NativeCloudAccount.shared.renameDevice(deviceId, name: name)
    }

    /// What the Devices window reads, live.
    static let liveAccount: Account = {
        await MainActor.run {
            let snapshot = NativeCloudAccount.shared.snapshot
            return AccountHalf(signedIn: MACHINESDevicesScreen.signedIn(snapshot.phase), devices: DevicesPage.accountDevices(snapshot),
                               reach: NativeReachAccount.shared.devicesReach)
        }
    }
    /// Channels through the same engine door the window uses.
    static let liveInvoke: Invoke = { channel, args, _ in
        try await Task { @MainActor in try NativeRPCValue.fromFoundation(try await RemoteCall.invoke(channel, args.map(\.foundation))) }.value
    }

    static let pageDescription = "Settings → Devices, and more: every device signed in to their Terminal Deck account (name, what it is, when it was added, when it was last seen, which one is this Mac), whether \"Let my signed-in devices open this Mac\" is on and its last connections, then the devices connected before accounts, which the page no longer shows (name, when last seen, and the ref devices_remove takes). " + DevicesPage.joinBySigningIn
    static let removeDescription = "Sign a device out, exactly as \"Sign out this device\" on Settings → Devices: for a device signed in to the account (ref account:… from devices_page) its sign-in to the account ends, its live connections to this Mac end at once and it leaves the account's device list on every device; signing in on it again brings it back by itself. This Mac itself cannot be signed out here. A Mac that keeps the saved-passwords key is signed out too (the key then changes by itself on his other Macs). Signing an account device out is Hoot's alone, in the person's own conversation. For a device connected before accounts (ref device:… or machine:…) it is disconnected and can no longer reach this Mac (a computer this Mac reached is forgotten); notSeenRecently true removes every such device not seen for 14 days. Runs when the calling AI's permission mode allows it; the action is logged. It never adds a device: " + DevicesPage.joinBySigningIn

    static let renameDescription = "Rename a device of the account, exactly as the \"Name\" row on its page in Settings → Devices: the new name shows on every device signed in to the account. Give ref (account:… from devices_page) for another device, or thisMac true for this Mac, and name (1-64 characters). Runs when the calling AI's permission mode allows it; the action is logged."

    static let signOutDescription = "Sign one of the person's devices out of their Terminal Deck account by its name, exactly as \"Sign out this device\" on Settings → Devices: a Mac, a phone or a browser, a Mac that keeps the saved-passwords key included (for a lost or stolen device). Its sign-in ends at once and it can fetch nothing more; the saved-passwords key then changes by itself on his other Macs. Nothing on any of his devices or in Cloud is deleted, and signing in on it again brings everything back. Only Hoot may call it, only in the person's own conversation; this Mac itself is signed out from Profile. Give device (its name as devices_page shows it)."
    /// Design B6 (a lost Mac): signing a device out is Hoot's alone, in his own conversation. Every refusal changes nothing.
    static let onlyHootLine = "Only Hoot can sign a device out; ask Hoot. Nothing was changed."
    static let ownRequestLine = "Signing out a device needs your own request. Nothing was changed."
    static let thisMacLine = "To sign out this Mac use Profile. Nothing was changed."
    static func signOutCaller(_ access: BackendDeckToolsAppAccess, _ context: BackendMCPCallContext) async throws {
        // `.local` = the app's own caller: Hoot (and the person's own window). Coding sessions, AI apps with a key and
        // paired devices never.
        guard try await access.caller(context).kind == .local else { throw NativeRPCError(code: "not-granted", message: onlyHootLine) }
        // A turn nobody is attending (a task, the Receiver, mail, someone else's request) never signs a device out.
        guard context.attended else { throw NativeRPCError(code: "not-granted", message: ownRequestLine) }
    }
    /// The device of the account with exactly that name (case and spacing ignored). Refusals list his devices by name.
    static func accountDevice(named raw: String, in devices: [DevicesPage.AccountDevice]) throws -> DevicesPage.AccountDevice {
        func key(_ value: String) -> String { DevicesPage.plain(value).trimmingCharacters(in: .whitespaces).lowercased() }
        let wanted = key(raw)
        guard !wanted.isEmpty else { throw NativeRPCError.invalidArguments("Give device: its name as devices_page shows it.") }
        let names = devices.map { DevicesPage.plain($0.name) + ($0.isThisMac ? " (this Mac)" : "") }.joined(separator: ", ")
        let found = devices.filter { key($0.name) == wanted }
        if found.contains(where: \.isThisMac) { throw NativeRPCError(code: "this-mac", message: thisMacLine) }
        guard !found.isEmpty else { throw NativeRPCError(code: "not-found", message: "No device of yours is called “\(raw)”. Your devices: \(names). Nothing was changed.") }
        guard found.count == 1, found[0].deviceId?.isEmpty == false else {
            throw NativeRPCError(code: "ambiguous", message: "More than one device is called “\(raw)”. Rename one first (devices_rename), or use devices_remove with its ref. Your devices: \(names). Nothing was changed.")
        }
        return found[0]
    }
    static let nothingToRemove = "Nothing to remove: no device connected before accounts has gone unseen for 14 days."

    static func definitions(access: BackendDeckToolsAppAccess, invoke: @escaping Invoke,
                            openServer: @escaping OpenServer) throws -> [BackendDeckToolsDefinition] {
        let schema = #"{"type":"object","properties":{"serverId":{"type":"string"}},"required":["serverId"],"additionalProperties":false}"#
        let description = "Open a server's settings window."
        let spec = try BackendMCPTool(id: "server.settings.open", wireName: "server_settings_open", description: description,
                                      inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: description, index: description) { context, args in
            try await BackendDeckToolsSupport.reply {
                try await guarded(access, context, spec.id, spec.wireName, .read, "Devices and server settings")
                try await access.authorize(context, spec.id, args, .read, description, false)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                let id = try args["serverId"].requireString("serverId", nonempty: true)
                let saved = try await invoke("servers:list", [], context)
                guard let server = CodingAIServer.parseList(CodingAIJSON(saved.foundation)).first(where: { $0.id == id }) else {
                    throw NativeRPCError(code: "missing-server", message: "That server is no longer in the saved list.")
                }
                try await openServer(server)
                try await access.record(context, spec.id, args, .object([.init("finished", .bool(true))]))
                return .value(.object([.init("ok", .bool(true)), .init("serverId", .string(id))]))
            }
        }]
    }

    /// devices_page and devices_remove: the window's rows and its Remove, for every AI that may use them.
    static func deviceDefinitions(access: BackendDeckToolsAppAccess, invoke: @escaping Invoke = liveInvoke,
                                  account: @escaping Account = liveAccount, signOut: @escaping SignOut = liveSignOut,
                                  rename: @escaping Rename = liveRename) throws -> [BackendDeckToolsDefinition] {
        let pageSpec = try BackendMCPTool(id: "devices.page", wireName: "devices_page", description: pageDescription,
            inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)), tier: .read)
        let removeSpec = try BackendMCPTool(id: "devices.remove", wireName: "devices_remove", description: removeDescription,
            inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"ref":{"type":"string"},"notSeenRecently":{"type":"boolean"}},"additionalProperties":false}"#.utf8)),
            tier: .alter)
        let page = BackendDeckToolsDefinition(spec: pageSpec, title: "See your devices (Settings → Devices)", index: "Devices signed in to your account, and the ones connected before accounts.") { context, args in
            try await BackendDeckToolsSupport.reply {
                try await guarded(access, context, pageSpec.id, pageSpec.wireName, .read, "Reading the Devices window")
                try await access.authorize(context, pageSpec.id, args, .read, "Read the devices on the Devices window", false)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                return .value(try await read(invoke, account, context).wireValue)
            }
        }
        let remove = BackendDeckToolsDefinition(spec: removeSpec, title: "Sign a device out", index: "Sign out one device of the account, remove one device connected before accounts, or every old one not seen for 14 days.") { context, args in
            try await BackendDeckToolsSupport.reply {
                try await guarded(access, context, removeSpec.id, removeSpec.wireName, .alter, "Signing a device out")
                let all = args["notSeenRecently"].bool == true, ref = args["ref"].string ?? ""
                guard all != !ref.isEmpty else { throw NativeRPCError.invalidArguments("Give ref from devices_page, or notSeenRecently true.") }
                let before = try await read(invoke, account, context)
                // An account device: the same sign-out as the page's row, with the same approval as every removal.
                if !all, ref.hasPrefix(DevicesPage.accountRef("")) {
                    // Design B6: one rule for both doors that sign an account device out.
                    try await signOutCaller(access, context)
                    guard let row = before.accountRows.first(where: { !$0.isThisMac && $0.ref.map(DevicesPage.accountRef) == ref }), let deviceId = row.ref else {
                        throw NativeRPCError(code: "not-found", message: "No other device of the account has that ref (this Mac cannot be signed out here). devices_page lists them.")
                    }
                    try await access.authorize(context, removeSpec.id, args, .alter,
                                               "Sign out “\(row.name)”: its sign-in ends and it leaves your devices; signing in on it again brings it back", true)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    do { try await signOut(deviceId) }
                    catch BackendDeviceSignOutRefusal.holdsSavedPasswordsKey {
                        throw NativeRPCError(code: "keeps-saved-passwords-key", message: NativeDeviceSignOut.holdsKeyLine)
                    }
                    catch BackendDeviceSignOutRefusal.thisMac {
                        throw NativeRPCError(code: "this-mac", message: "This Mac cannot be signed out from here. Nothing was changed.")
                    }
                    catch let refusal as BackendDeviceSignOutRefusal where refusal == .notSignedIn {
                        throw NativeRPCError(code: "signed-out", message: "This Mac is not signed in to the account. Nothing was changed.")
                    }
                    try await access.record(context, removeSpec.id, args, .object([.init("signedOut", .string(row.name))]))
                    return .value(.object([.init("signedOut", .array([.string(row.name)]))]))
                }
                let rows = all ? before.oldQuiet : (before.oldRecent + before.oldQuiet).filter { $0.ref == ref }
                guard all || !rows.isEmpty else {
                    throw NativeRPCError(code: "not-found", message: "No device connected before accounts has that ref. devices_page lists them.")
                }
                // Nothing matches: nothing to ask the person about and nothing to log as a change.
                if rows.isEmpty { return .value(.object([.init("removed", .array([])), .init("message", .string(Self.nothingToRemove))])) }
                let sentence = all ? "Remove the \(rows.count) devices connected before accounts that were not seen for 14 days"
                                   : "Remove “\(rows[0].name)”: it is disconnected and can no longer reach this Mac"
                try await access.authorize(context, removeSpec.id, args, .alter, sentence, true)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                for row in rows { try await removeOld(row, invoke, context) }
                try await access.record(context, removeSpec.id, args, .object([.init("removed", .number(Double(rows.count)))]))
                return .value(.object([.init("removed", .array(rows.map { .string($0.name) }))]))
            }
        }
        let renameSpec = try BackendMCPTool(id: "devices.rename", wireName: "devices_rename", description: renameDescription,
            inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"ref":{"type":"string"},"thisMac":{"type":"boolean"},"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#.utf8)),
            tier: .alter)
        let renameTool = BackendDeckToolsDefinition(spec: renameSpec, title: "Rename a device", index: "Give a device of the account a new name, shown on every device.") { context, args in
            try await BackendDeckToolsSupport.reply {
                try await guarded(access, context, renameSpec.id, renameSpec.wireName, .alter, "Renaming a device")
                let mine = args["thisMac"].bool == true, ref = args["ref"].string ?? ""
                guard mine != !ref.isEmpty else { throw NativeRPCError.invalidArguments("Give ref from devices_page, or thisMac true.") }
                guard let name = CloudDeviceRename.cleaned(args["name"].string ?? "") else { throw NativeRPCError.invalidArguments("Give the new name.") }
                let half = await account()
                guard half.signedIn else { throw NativeRPCError(code: "signed-out", message: "This Mac is not signed in to the account. Nothing was changed.") }
                guard let device = half.devices.first(where: { mine ? $0.isThisMac : ($0.deviceId.map(DevicesPage.accountRef) == ref && !$0.isThisMac) }),
                      let deviceId = device.deviceId, !deviceId.isEmpty else {
                    throw NativeRPCError(code: "not-found", message: "No device of the account has that ref. devices_page lists them.")
                }
                let old = DevicesPage.plain(device.name)
                try await access.authorize(context, renameSpec.id, args, .alter, "Rename “\(old)” to “\(name)” on every device", true)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                do { try await rename(deviceId, name) }
                catch let refusal as BackendDeviceSignOutRefusal where refusal == .notSignedIn {
                    throw NativeRPCError(code: "signed-out", message: "This Mac is not signed in to the account. Nothing was changed.")
                }
                catch { throw NativeRPCError(code: "not-renamed", message: "The Cloud did not take the new name. Nothing was changed.") }
                try await access.record(context, renameSpec.id, args, .object([.init("renamed", .string(name))]))
                return .value(.object([.init("renamed", .string(name)), .init("was", .string(old))]))
            }
        }
        let signOutSpec = try BackendMCPTool(id: "devices.sign_out", wireName: "devices_sign_out", description: signOutDescription,
            inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"device":{"type":"string"}},"required":["device"],"additionalProperties":false}"#.utf8)),
            tier: .alter)
        let signOutTool = BackendDeckToolsDefinition(spec: signOutSpec, title: "Sign out a lost device", index: "Sign one of your devices out by its name (a lost or stolen Mac included); nothing is deleted anywhere.") { context, args in
            try await BackendDeckToolsSupport.reply {
                try await guarded(access, context, signOutSpec.id, signOutSpec.wireName, .alter, "Signing a device out")
                try await signOutCaller(access, context)
                let half = await account()
                guard half.signedIn else { throw NativeRPCError(code: "signed-out", message: "This Mac is not signed in to the account. Nothing was changed.") }
                let device = try accountDevice(named: args["device"].string ?? "", in: half.devices)
                guard let deviceId = device.deviceId else { throw NativeRPCError(code: "not-found", message: "That device cannot be signed out from here. Nothing was changed.") }
                let name = DevicesPage.plain(device.name)
                try await access.authorize(context, signOutSpec.id, args, .alter,
                                           "Sign out “\(name)”: its sign-in ends at once; nothing on it or in Cloud is deleted, and signing in on it again brings everything back", true)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                do { try await signOut(deviceId) }
                catch BackendDeviceSignOutRefusal.holdsSavedPasswordsKey {
                    throw NativeRPCError(code: "keeps-saved-passwords-key", message: NativeDeviceSignOut.holdsKeyLine)
                }
                catch BackendDeviceSignOutRefusal.thisMac { throw NativeRPCError(code: "this-mac", message: thisMacLine) }
                catch let refusal as BackendDeviceSignOutRefusal where refusal == .notSignedIn {
                    throw NativeRPCError(code: "signed-out", message: "This Mac is not signed in to the account. Nothing was changed.")
                }
                try await access.record(context, signOutSpec.id, args, .object([.init("signedOut", .string(name))]))
                return .value(.object([.init("signedOut", .string(name))]))
            }
        }
        return [page, remove, renameTool, signOutTool]
    }

    private static func guarded(_ access: BackendDeckToolsAppAccess, _ context: BackendMCPCallContext, _ id: String, _ wire: String,
                                _ tier: BackendMCPTier, _ what: String) async throws {
        guard context.allowedTools.contains(id) || context.allowedTools.contains(wire), context.allowedTiers.contains(tier) else {
            throw NativeRPCError(code: "not-granted", message: "This caller cannot use that Devices or Servers control.")
        }
        let caller = try await access.caller(context)
        try BackendDeckToolsAppKit.hereOnly(caller, what)
        guard !context.cancellation.isCancelled else { throw CancellationError() }
    }

    /// The same page the window builds: the account's half, then the old way read through the engine.
    static func read(_ invoke: Invoke, _ account: Account, _ context: BackendMCPCallContext) async throws -> DevicesPage {
        let half = await account()
        let status = try await invoke("remote:status", [], context)
        let devices = try await invoke("remote:devices", [], context)
        let machines = (try? await invoke("machines:list", [], context)) ?? .null
        let state = RemoteRead.state(status: status.foundation, devices: devices.foundation)
        let view = MachinesView(json: machines.foundation)
        let old = DevicesPage.oldDevices(devices: state?.devices ?? [], connected: Set(state?.connections.map(\.deviceId) ?? []),
                                         machines: view.machines, online: Set(view.links.filter { $0.phase == .online }.map(\.id)))
        return DevicesPage(signedIn: half.signedIn, account: half.devices, reach: half.reach, old: old)
    }

    /// Exactly what the old Revoke (a device) and Forget (a computer) did.
    static func removeOld(_ row: DevicesPage.OldRow, _ invoke: Invoke, _ context: BackendMCPCallContext) async throws {
        let parts = row.ref.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { throw NativeRPCError.invalidArguments("That ref is not one devices_page gave.") }
        _ = try await invoke(row.source == .device ? "remote:device:revoke" : "machines:forget", [.string(parts[1])], context)
    }
}
