import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Where Machines → Servers is: the list (inside the Machines page, above
/// "Your own devices"), adding one, or one server's own page.
/// Mirrors `MachinesPanel`'s `View` state; lane E1's Machines frame holds it.
enum NativeServersRoute: Hashable {
    case list
    case add
    case server(String)
    case thisMac
}

/// Machines → Servers, drawn in Swift (`machines/servers/*`, and the server half
/// of `MachinesPanel.tsx`). In `.list` it draws only the "Servers" group, for the
/// Machines page to place; in `.add` and `.server` it is the whole page.
struct NativeServersArea: View {
    @Binding var route: NativeServersRoute
    @State private var model = NativeServersModel.shared

    init(route: Binding<NativeServersRoute>) {
        _route = route
    }

    var body: some View {
        Group {
            switch route {
            case .list:
                NativeServersSection(model: model, route: $route)
            case .add:
                NativeAddServerPage(model: model, route: $route)
            case .thisMac:
                if NativeServerControlRelease.enabled {
                    NativeServerControlLocalSurface(route: $route, advanced: NativeServerControlScreens.advanced)
                } else {
                    NativeServersSection(model: model, route: $route)
                        .onAppear { route = .list }
                }
            case .server(let id):
                if let server = model.servers.first(where: { $0.id == id }) {
                    NativeServerPage(model: model, server: server, route: $route)
                        .id(server.id)
                } else {
                    // Not in the list yet (just added, still reading): the list, as the page does.
                    NativeServersSection(model: model, route: $route)
                }
            }
        }
        .onAppear { model.start() }
    }
}

// MARK: - What the servers screens share (MachinesPanel's half)

@MainActor
@Observable
final class NativeServersModel {
    static let shared = NativeServersModel()

    private(set) var servers: [CodingAIServer] = []
    private(set) var extras: [String: CodingAIServer.Extra] = [:]
    private(set) var reading = true
    private(set) var problem: String?
    /// Each opened server's page state, kept while the app runs (the list's summaries read it).
    private(set) var states: [String: ServerRoomState] = [:]
    private(set) var adding = false
    private(set) var addError: String?
    private(set) var addReason: AddServerRules.Failure?
    /// The clock the "as of …" lines read; moved on only when one of them would change.
    private(set) var now = Date().timeIntervalSince1970 * 1000
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private init() {}

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func start() {
        guard !started, EngineBridge.shared.isReady else { return }
        started = true
        reread()
    }

    /// `useServers`'s read, with its eight-second deadline.
    func reread() {
        reading = true
        Task {
            let work = Task { try await call("servers:list") }
            let timer = Task {
                try? await Task.sleep(for: .seconds(CodingAIDeadline.readServers))
                work.cancel()
            }
            do {
                let raw = try await work.value
                timer.cancel()
                servers = CodingAIServer.parseList(raw)
                extras = CodingAIServer.parseExtras(raw)
                problem = nil
            } catch {
                timer.cancel()
                problem = work.isCancelled
                    ? CodingAIDeadline.overdue("reading your servers", seconds: CodingAIDeadline.readServers)
                    : CodingAIErrorText.from(error, fallback: "Could not read your servers.")
            }
            reading = false
        }
    }

    func remember(_ state: ServerRoomState) {
        states[state.id] = state
        scheduleTick()
    }

    /// `useAt(nextChange)`: wake when an age line or a grant would read differently.
    private func scheduleTick() {
        now = Date().timeIntervalSince1970 * 1000
        var soonest: Double?
        func consider(_ when: Double) { if when > now && (soonest == nil || when < soonest!) { soonest = when } }
        for state in states.values {
            if let view = state.view, view.measuredAt > 0 { consider(ServerWords.nextAgeChange(view.measuredAt, now: now)) }
            if let grant = state.grant { consider(grant.expiresAt) }
        }
        tick?.cancel()
        guard let soonest else { return }
        tick = Task {
            try? await Task.sleep(for: .milliseconds(Int(soonest - now) + 50))
            guard !Task.isCancelled else { return }
            scheduleTick()
        }
    }

    // MARK: Adding

    func clearAddError() {
        addError = nil
        addReason = nil
    }

    /// `servers:add`; on success the new server's page.
    func submit(_ draft: CodingAIJSON, route: Binding<NativeServersRoute>) {
        adding = true
        addError = nil
        Task {
            do {
                let result = AddServerRules.result(try await call("servers:add", [draft.foundation]))
                adding = false
                if result.ok, let id = result.id {
                    addReason = nil
                    route.wrappedValue = .server(id)
                    reread()
                    return
                }
                addReason = result.reason
                addError = result.message
            } catch {
                adding = false
                addReason = .unknown
                addError = "That attempt did not come back. Check the address and try it again."
            }
        }
    }

    func listKeys() async -> [AddServerRules.KeyOffer] {
        AddServerRules.keyOffers((try? await call("servers:keys")) ?? .null)
    }

    func pickKey() async throws -> AddServerRules.KeyOffer? {
        AddServerRules.KeyOffer.parse(try await call("servers:key-pick"))
    }

    func readKey(_ path: String) async -> (ok: Bool, key: String?, sentence: String) {
        do {
            return AddServerRules.keyText(try await call("servers:key-read", [path]))
        } catch {
            return (false, nil, "That file could not be read. Choose it again.")
        }
    }

    // MARK: A server's own acts

    func forget(_ id: String, route: Binding<NativeServersRoute>) {
        route.wrappedValue = .list
        states[id] = nil
        Task {
            _ = try? await call("servers:forget", [id])
            reread()
        }
    }

    func rename(_ id: String, to name: String) {
        Task {
            _ = try? await call("servers:rename", [id, name])
            reread()
        }
        // Open tabs on this server take the new name too.
        AppModel.shared.web.run(.serverRenamed(serverId: id, name: name))
    }

    func setDrivesWindows(_ id: String, _ allowed: Bool) {
        Task {
            _ = try? await call("servers:drive-windows", [id, allowed])
            reread()
        }
    }

    func extra(_ id: String) -> CodingAIServer.Extra {
        extras[id] ?? CodingAIServer.Extra(credential: nil, fingerprint: nil, drivesWindows: false)
    }
}

// MARK: - The list (`ServersSection.tsx`)

struct NativeServersSection: View {
    @Bindable var model: NativeServersModel
    @Binding var route: NativeServersRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Servers")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if let problem = model.problem {
                HStack(spacing: 8) {
                    NativeCodingAINotice(tone: .error, text: problem)
                    Button("Try again") { model.reread() }
                }
            }
            if model.problem == nil && model.reading && model.servers.isEmpty {
                Text("Reading your servers…").foregroundStyle(.secondary)
            }
            if !model.servers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.servers) { server in
                        NativeServerRow(server: server, state: model.states[server.id], now: model.now) {
                            route = .server(server.id)
                        }
                    }
                }
            }
            if NativeServerControlRelease.enabled {
                NativeServerControlLocalEntry { route = .thisMac }
            }
            Button("Add a server") {
                model.clearAddError()
                route = .add
            }
            .buttonStyle(.bordered).nativeUIGGreyControl()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One stored server: its mark, name and where it is, what was last seen, and the way in.
struct NativeServerRow: View {
    let server: CodingAIServer
    let state: ServerRoomState?
    let now: Double
    let open: () -> Void

    var body: some View {
        let view = state?.view
        let summary = view.map { ServerWords.overall($0.cards) } ?? ""
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                    Text(server.whereLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !summary.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(summary).font(.callout)
                        if let view, view.measuredAt > 0 {
                            Text(ServerWords.asOf(view.measuredAt, now: now))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// The page's main button (`settings-btn` tone primary): accent-filled whether or not
/// its window is in front, as on the web — a bordered-prominent button greys out in a
/// window that is not.
struct NativeServersPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}
