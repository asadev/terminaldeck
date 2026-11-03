import SwiftUI

/// The only child-view factories used by the existing Machines/server route.
/// UI and client implementation remain with APU and DKU respectively.
@MainActor
enum NativeServerControlScreens {
    static func apps(_ target: String) -> AnyView {
        guard target != "local" else {
            return unavailable(symbol: "square.grid.2x2", title: "Apps are unavailable",
                               sentence: "Apps are managed on a connected server.")
        }
        return AnyView(NativeAppsScreen(serverID: target, serverName: serverName(target)))
    }

    static func advanced(_ target: String) -> AnyView {
        if target == "local" {
            return AnyView(NativeDockerAdvancedView())
        }
        return AnyView(NativeDockerAdvancedView(serverID: target, serverName: serverName(target)))
    }

    private static func serverName(_ target: String) -> String {
        NativeServersModel.shared.servers.first { $0.id == target }?.name ?? "this server"
    }

    private static func unavailable(symbol: String, title: String, sentence: String) -> AnyView {
        AnyView(NativePageEmpty(symbol: symbol, title: title) {
            NativeSettingsProse(text: sentence)
        }.frame(minHeight: 320))
    }
}
