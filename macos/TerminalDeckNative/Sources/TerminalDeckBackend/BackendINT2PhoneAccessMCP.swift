import Foundation
import TerminalDeckNativeCore

public enum BackendINT2PhoneAccessMCP {
    /// remote.device_access_set's arguments: the levels the Devices screen offers, in its order (#153).
    static var setSchema: String {
        #"{"type":"object","properties":{"deviceId":{"type":"string"},"level":{"type":"string","enum":["#
            + BackendINT2PhoneAccessLevel.offered.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
            + #"]}},"required":["deviceId","level"],"additionalProperties":false}"#
    }
    public static func definitions(trust: BackendRemoteTrustStore, access: BackendDeckToolsAppAccess,
        changed: @escaping @Sendable (String) async -> Void) throws -> [BackendDeckToolsDefinition] {
        let levels = BackendINT2PhoneAccessLevel.offered
        let titles = levels.map(\.title).dropLast().joined(separator: ", ") + " or " + (levels.last?.title ?? "")
        let entries: [(String, String, String, BackendMCPTier, String)] = [
            ("remote.device_access", "remote_device_access", "Read the host-issued access of approved paired devices.", .read,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("remote.device_access_set", "remote_device_access_set", "Change a paired device to \(titles); it runs when the calling AI's permission mode allows it. Existing folder/account/Hoot grants still apply.", .alter,
             setSchema)
        ]
        return try entries.map { id, wire, title, tier, schema in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: title,
                inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return .init(spec: spec, title: title, index: title, audience: "hoot") { context, args in
                guard try await access.caller(context).kind == .local else {
                    throw NativeRPCError(code: "access-denied", message: "A device or outside agent cannot grant itself access.")
                }
                let device = args["deviceId"].string
                if tier == .alter {
                    guard let device, await trust.isApproved(device),
                          args["level"].string.flatMap(BackendINT2PhoneAccessLevel.init(rawValue:)) != nil else {
                        throw NativeRPCError.invalidArguments("Choose an approved device and a known access level.")
                    }
                }
                try await access.authorize(context, id, args, tier,
                    tier == .read ? title : "Change device \(device ?? "") access to \(args["level"].string ?? "")", tier == .alter)
                try Task.checkCancellation()
                guard try await access.caller(context).kind == .local else { throw NativeRPCError(code: "access-denied", message: "The device-access owner changed.") }
                if tier == .alter, let device {
                    guard await trust.isApproved(device) else { throw NativeRPCError(code: "access-denied", message: "This device was revoked while approval was pending.") }
                    try await trust.setPhoneAccess(device, level: BackendINT2PhoneAccessLevel(rawValue: args["level"].string!))
                    await changed(device)
                }
                let result = await trust.phoneAccessRows()
                try await access.record(context, id, args, .object([.init("devices", .number(Double(result.elements?.count ?? 0)))]))
                return .value(result)
            }
        }
    }
}
