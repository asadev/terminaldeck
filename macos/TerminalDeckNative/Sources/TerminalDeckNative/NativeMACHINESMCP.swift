import Foundation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Additive names from SHELL-SPEC; the existing machines/servers/remote tools remain.
enum MACHINESMCP {
    typealias Invoke = @Sendable (String, [NativeRPCValue], BackendMCPCallContext) async throws -> NativeRPCValue
    typealias OpenServer = @Sendable (CodingAIServer) async throws -> Void

    static func definitions(access: BackendDeckToolsAppAccess, invoke: @escaping Invoke,
                            openServer: @escaping OpenServer) throws -> [BackendDeckToolsDefinition] {
        let rows: [(String, String, BackendMCPTier, String)] = [
            ("server.settings.open", "Open a server's settings window.", .read,
             #"{"type":"object","properties":{"serverId":{"type":"string"}},"required":["serverId"],"additionalProperties":false}"#),
            ("devices.pair.start", "Show a one-use pairing code and QR link.", .act,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("devices.pair.allow", "Let a waiting device in with its chosen access. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{"deviceId":{"type":"string"},"access":{"type":"string","enum":["full","hoot","look"]}},"required":["deviceId","access"],"additionalProperties":false}"#),
            ("devices.access.set", "Choose a paired device's access. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{"deviceId":{"type":"string"},"access":{"type":"string","enum":["full","hoot","look"]}},"required":["deviceId","access"],"additionalProperties":false}"#),
            ("devices.rename", "Rename a paired device. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{"deviceId":{"type":"string"},"name":{"type":"string","minLength":1,"maxLength":128}},"required":["deviceId","name"],"additionalProperties":false}"#)
        ]
        return try rows.map { id, description, tier, schema in
            let wire = id == "server.settings.open" ? "server_settings_open" : id.replacingOccurrences(of: ".", with: "_")
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description,
                                         inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description) { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTools.contains(id) || context.allowedTools.contains(wire), context.allowedTiers.contains(tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use that Devices or Servers control.")
                    }
                    let caller = try await access.caller(context)
                    try BackendDeckToolsAppKit.hereOnly(caller, "Devices and server settings")
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    let device = args["deviceId"].string ?? ""
                    let selected = args["access"].string ?? ""
                    if id == "devices.pair.allow" || id == "devices.access.set" {
                        guard !device.isEmpty, ["full", "hoot", "look"].contains(selected) else {
                            throw NativeRPCError.invalidArguments("Choose a device and full, hoot or look access.")
                        }
                    }
                    let safe = args
                    try await access.authorize(context, id, safe, tier, description, tier != .read)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    let output: NativeRPCValue
                    switch id {
                    case "server.settings.open":
                        let id = try args["serverId"].requireString("serverId", nonempty: true)
                        let saved = try await invoke("servers:list", [], context)
                        guard let server = CodingAIServer.parseList(CodingAIJSON(saved.foundation)).first(where: { $0.id == id }) else {
                            throw NativeRPCError(code: "missing-server", message: "That server is no longer in the saved list.")
                        }
                        try await openServer(server)
                        output = .object([.init("ok", .bool(true)), .init("serverId", .string(id))])
                    case "devices.pair.start":
                        let status = try await invoke("remote:status", [], context)
                        guard !context.cancellation.isCancelled else { throw CancellationError() }
                        if status["running"].bool != true {
                            let started = try await invoke("remote:start", [], context)
                            guard !context.cancellation.isCancelled else { throw CancellationError() }
                            guard started["running"].bool == true else {
                                throw NativeRPCError(code: "unavailable", message: started["reason"].string ?? "Device access could not start.")
                            }
                        }
                        output = try await invoke("remote:pair", [], context)
                    case "devices.pair.allow":
                        output = try await invoke("remote:device:approve-access", [.string(device), .string(selected)], context)
                        guard let row = output.elements?.first(where: { $0["id"].string == device }),
                              row["status"].string == "approved" || row["approved"].bool == true,
                              row["revoked"].bool != true, row["access"].string == selected else {
                            throw NativeRPCError(code: "access-unconfirmed", message: "The reply did not confirm the chosen access.")
                        }
                    case "devices.access.set":
                        output = try await invoke("remote:device-access:set", [.string(device), .string(selected)], context)
                        guard output.elements?.first(where: { $0["id"].string == device })?["access"].string == selected else {
                            throw NativeRPCError(code: "access-unconfirmed", message: "The device did not confirm its chosen access.")
                        }
                    default:
                        let device = try args["deviceId"].requireString("deviceId", nonempty: true)
                        let name = try args["name"].requireString("name", nonempty: true).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, name.count <= 128 else { throw NativeRPCError.invalidArguments("Use a name from 1 to 128 characters.") }
                        output = try await invoke("remote:device:rename", [.string(device), .string(name)], context)
                    }
                    // Pairing tokens never enter the action history.
                    try await access.record(context, id, safe, .object([.init("finished", .bool(true))]))
                    return .value(output)
                }
            }
        }
    }
}

