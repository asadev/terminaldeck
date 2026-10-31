import SwiftUI
import TerminalDeckNativeCore

/// The legacy Machines route now opens Servers. Devices has its own page.
struct NativeMachinesScreen: View {
    @State private var route: NativeServersRoute = .list
    init(initialRoute: NativeServersRoute = .list) { _route = State(initialValue: initialRoute) }
    var body: some View { ServersScreen(route: $route) }
}

struct ServersScreen: View {
    @Binding var route: NativeServersRoute
    var model = NativeServersModel.shared
    var live = true
    @State private var requestedFilter = "All"
    @State private var requestedView = "Apps"

    var body: some View {
        Group {
            switch route {
            case .list, .add:
                dashboard
            case .server(let id):
                if let server = model.servers.first(where: { $0.id == id }) {
                    NativeServerPage(model: model, server: server, route: $route, live: live,
                        initialFilter: requestedFilter, initialView: requestedView)
                        .id(id)
                } else {
                    dashboard
                }
            case .thisMac:
                NativeServerControlLocalSurface(route: $route, advanced: NativeServerControlScreens.advanced)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private var dashboard: some View {
        NativeMACHINESServersDashboard(model: model, route: $route, live: live,
            onReview: { id in
                requestedFilter = NativeMACHINESServersDashboard.stopped(model.states[id]) > 0 ? "Stopped" : "All"
                requestedView = model.states[id]?.link == .failed ? "Health" : "Apps"
                route = .server(id)
            }, onOpen: { id in
                requestedFilter = "All"; requestedView = "Apps"; route = .server(id)
            })
    }
}

/// Kept for older child views; the shared page owns scroll and padding.
enum MachinesPage {
    static let measure: CGFloat = 1120
    static let gutter: CGFloat = 24
}
