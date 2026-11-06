import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installMacReachTools(_ devices: BackendPhoneDevices, authority: BackendCompositionAuthority) async {
        let tools: [(String, String, NativeRPCValue)] = [
            ("mac_screen.keep_awake", "Change General → Keep this Mac awake, the single Mac sleep setting, including its existing lid-closed behavior. Screens may turn off. An approved helper keeps the Mac awake from boot. Requires the person's approval.",
             .object([.init("type", .string("object")), .init("properties", .object([.init("on", .object([.init("type", .string("boolean"))]))])), .init("required", .array([.string("on")])), .init("additionalProperties", .bool(false))])),
            ("mac_screen.helper", "Set up access before sign-in, disable its helper, check setup again, or open the exact Login Items or Remote Login settings page for the person. Never changes a system switch itself. Requires approval. Scratch copies cannot register a service.",
             .object([.init("type", .string("object")), .init("properties", .object([.init("do", .object([.init("type", .string("string")), .init("enum", .array(["enable", "disable", "check", "login-items", "remote-login"].map(NativeRPCValue.string)))]))])), .init("required", .array([.string("do")])), .init("additionalProperties", .bool(false))])),
            ("mac_screen.sign_in", "Prepare the sign-in flow on phones already showing this Mac. Wakes the displays and brings up the phone keyboard. The person enters the password on the phone, never in an AI tool. Full control and existing screen approval still apply; does not start a new screen watch.",
             .object([.init("type", .string("object")), .init("properties", .object([])), .init("additionalProperties", .bool(false))])),
        ]
        let joins = self.joins
        for (id, description, schema) in tools {
            do {
                let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: schema, tier: .act)
                try await root.mcp.registerTool(spec, ownerID: "native.phone-devices") { caller, args in
                    guard caller.allowedTiers.contains(.act) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                    _ = try await authority.resolve(caller)
                    try await joins.prepareNative(caller, tier: .act, sentence: id == "mac_screen.sign_in" ? "Prepare sign-in on the phones already showing this Mac" : "Change this Mac's phone access setup", ownerMustAnswer: true)
                    if id == "mac_screen.keep_awake" {
                        guard let on = args["on"].bool else { throw NativeRPCError.invalidArguments("Choose on or off.") }
                        try await NativeMacReach.shared.setKeepAwake(on)
                    } else if id == "mac_screen.helper" {
                        switch args["do"].string {
                        case "enable": try await NativeMacReach.shared.enable()
                        case "disable": try await NativeMacReach.shared.disable()
                        case "check": await NativeMacReach.shared.refresh()
                        case "login-items": await NativeMacReach.openLoginItems()
                        case "remote-login": await NativeMacReach.openRemoteLogin()
                        default: throw NativeRPCError.invalidArguments("Choose enable, disable, check, login-items or remote-login.")
                        }
                    } else {
                        guard let client = await NativeMacReach.shared.client else { throw NativeRPCError(code: "unavailable", message: MacReach.State.setup.words) }
                        _ = try await client.value("wake")
                        await devices.macFocus(text: true)
                    }
                    return .value(await NativeMacReach.shared.status())
                }
            } catch { report("The \(id) tool could not be installed.") }
        }
    }
}
