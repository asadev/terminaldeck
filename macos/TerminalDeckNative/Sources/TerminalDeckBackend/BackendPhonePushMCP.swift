import Foundation
import TerminalDeckNativeCore

/// deck-tools for alerts on closed phones (31 Oct): read which phones hear what while their app is closed, and send
/// one a test alert. The phone's own choices (which alerts, preview on or off) are set on the phone, in its Alerts
/// sheet — the one place for them — so no tool changes them.
public enum BackendPhonePushMCP {
    public static func definitions(push: @escaping @Sendable () async -> BackendPhonePush?,
                                   access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let entries: [(String, String, String, BackendMCPTier, String)] = [
            ("phone.alerts", "phone_alerts",
             "Read which paired phones get alerts while their app is closed: per phone, how they arrive (instant through Apple/Google, or a background check every few minutes), which alerts it wants (an agent needs you, an agent finished, Hoot replied), whether it shows a short preview, and the last delivery.",
             .read, #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("phone.alerts_test", "phone_alerts_test",
             "Send a paired phone a test alert (\"Terminal Deck test\") through the same path a real one takes, to check alerts reach it while its app is closed. deviceId from phone.alerts.",
             .act, #"{"type":"object","properties":{"deviceId":{"type":"string"}},"required":["deviceId"],"additionalProperties":false}"#),
        ]
        return try entries.map { id, wire, title, tier, schema in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: title,
                inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return .init(spec: spec, title: title, index: title, audience: "hoot") { context, args in
                guard let service = await push() else { throw NativeRPCError(code: "unavailable", message: "Phone alerts are not running on this Mac.") }
                let device = args["deviceId"].string
                if tier == .act {
                    guard let device, await service.rows().contains(where: { $0["deviceId"].string == device }) else {
                        throw NativeRPCError.invalidArguments("That phone has not turned on alerts. phone.alerts lists the phones that have.")
                    }
                }
                try await access.authorize(context, id, args, tier, tier == .read ? "Read which phones get alerts" : "Send a test alert to phone \(device ?? "")", false)
                try Task.checkCancellation()
                var result = NativeRPCValue.object([.init("phones", .array(await service.rows()))])
                if tier == .act, let device {
                    let sent = await service.notify(.init(kind: .needsYou, session: "test", agent: "Terminal Deck", title: "Terminal Deck test",
                                                          folder: "", preview: "This is a test alert from your Mac."), only: device)
                    result = .object([.init("sent", .bool(sent > 0)), .init("phones", .array(await service.rows()))])
                }
                try await access.record(context, id, args, .object([.init("phones", .number(Double(result["phones"].elements?.count ?? 0)))]))
                return .value(result)
            }
        }
    }
}
