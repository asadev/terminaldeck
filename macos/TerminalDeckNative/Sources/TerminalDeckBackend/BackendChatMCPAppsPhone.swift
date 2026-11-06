import Foundation
import TerminalDeckNativeCore

extension BackendChatMCPApps {
    public static func phoneFeature(apps: BackendChatMCPApps, endpoint: BackendRemoteHost, trust: BackendRemoteTrustStore) -> BackendRemoteHostFeature {
        .init(capability: "chats", messageTypes: ["chats.app.read", "chats.app.bridge"], policy: .grantedDevice,
              additionalAdvertisedCapabilities: ["chats.apps", "chats.rich"]) { message, source in
            let context = try await endpoint.refreshedContext(source)
            // The existing access tier owns chat reads/writes; the new message name grants nothing.
            let bridge = message.type == "chats.app.bridge"
            let session = try message["id"].requireString("chat", nonempty: true)
            let changes = bridge && ["tools/call", "ui/open-link"].contains(message["message"]["method"].string ?? "")
            let gate = session == "hoot" ? (changes ? "hoot.say" : "hoot.state") : (changes ? "chats.say" : "chats.watch")
            try await trust.requirePhoneAccess(context.deviceID, message: gate)
            if session == "hoot" {
                guard context.kind == .mine, await BackendCopilotRemoteAccess(trust: trust).linked(context.deviceID) else {
                    throw NativeRPCError(code: "access-denied", message: "Hoot is not shared with this phone.")
                }
            } else {
                guard try await endpoint.panelSessionIDs(context).contains(session) else {
                    throw NativeRPCError(code: "unknown-session", message: "That source chat is not shared with this phone.")
                }
            }
            let row = try message["rowId"].requireString("tool row", nonempty: true)
            let revalidate: @Sendable () async throws -> Void = {
                let refreshed = try await endpoint.refreshedContext(context)
                try await trust.requirePhoneAccess(refreshed.deviceID, message: gate)
                if session == "hoot" {
                    guard refreshed.kind == .mine, await BackendCopilotRemoteAccess(trust: trust).linked(refreshed.deviceID) else {
                        throw NativeRPCError(code: "access-denied", message: "Hoot is no longer shared with this phone.")
                    }
                } else {
                    guard try await endpoint.panelSessionIDs(refreshed).contains(session) else {
                        throw NativeRPCError(code: "access-denied", message: "This phone no longer has the source chat.")
                    }
                }
            }
            let owner = context.deviceID + ":" + context.connectionID.uuidString
            let value: NativeRPCValue
            if bridge {
                value = try await BackendChatMCPApps.$phoneAccessCheck.withValue(revalidate) {
                    try await apps.phoneBridge(session: session, rowID: row, owner: owner, message: message["message"],
                        viewID: owner + ":" + (message["viewId"].string ?? "default"))
                }
            } else {
                value = try await BackendChatMCPApps.$phoneAccessCheck.withValue(revalidate) {
                    try await apps.phoneDocument(session: session, rowID: row, owner: owner,
                        offset: Int(message["offset"].number ?? 0), documentID: message["documentId"].string)
                }
            }
            try await revalidate()
            return [try BackendRemoteServerMessage(bridge ? .chatsAppResult : .chatsApp,
                fields: [.init("rid", message["rid"]), .init("id", .string(session)), .init("rowId", .string(row)),
                         .init(bridge ? "messages" : "app", value[bridge ? "messages" : "app"].isNullish ? (bridge ? .array([]) : .null) : value[bridge ? "messages" : "app"])]
                    + (value.fields ?? []).filter { !["app", "messages"].contains($0.key) })]
        }
    }
}
