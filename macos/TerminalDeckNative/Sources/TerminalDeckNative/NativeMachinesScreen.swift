import SwiftUI
import TerminalDeckNativeCore

/// Machines, drawn in Swift (src/renderer/machines/MachinesPanel.tsx): servers above,
/// your own devices below, on one page — and Add a server or one server's page in
/// place of the whole list, exactly as the web panel swaps its view.
///
/// The halves are their lanes' views: the servers (`NativeServersArea`, lane G) and
/// the devices (`NativeRemoteSection`, lane V). This file is the page around them:
/// the route between list / add / one server, the scroll, the measure, and the
/// "Your own devices" heading with its one line of prose.
struct NativeMachinesScreen: View {
    @State private var route: NativeServersRoute = .list

    /// MachinesPanel.tsx draws the list (servers + devices) unless it is adding, or
    /// showing a server it can find — a server it cannot find falls back to the list.
    private var showsList: Bool {
        switch route {
        case .list: return true
        case .add: return false
        case .server(let id): return !NativeServersModel.shared.servers.contains { $0.id == id }
        }
    }

    var body: some View {
        Group {
            if showsList {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        NativeServersArea(route: $route)
                        YourOwnDevices()
                            .padding(.top, 40) // .machines-kind { margin-top: --sp-10 }
                    }
                    .frame(maxWidth: MachinesPage.measure, alignment: .leading)
                    .padding(.horizontal, MachinesPage.gutter)
                    .padding(.top, 24)    // .panel-page padding-block: --sp-6 …
                    .padding(.bottom, 40) // … --sp-10
                    .frame(maxWidth: .infinity)
                }
            } else {
                // AddServer and ServerPage bring their own scroll and fill the page.
                NativeServersArea(route: $route)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }
}

/// `.panel-page`: a centred column of `--page-measure`, never closer than `--sp-8` to the edges.
enum MachinesPage {
    static let measure: CGFloat = 940
    static let gutter: CGFloat = 32
}

/// `<section className="machines-kind">`: the heading, the line that tells a device from
/// a server, then everything RemoteSection draws.
private struct YourOwnDevices: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your own devices")
                .font(.subheadline.weight(.semibold)) // .settings-group-title, as the Servers heading above
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            Text("Computers and phones of your own, running this app too — paired with a code, not an address and a sign-in.")
                .font(.callout) // .settings-prose
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.vertical, 12)
            NativeRemoteSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
