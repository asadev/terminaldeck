import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Coding AI → Servers (`ServerAccounts.tsx`): every stored server,
/// and — once a row is opened, which is the press that connects to it — the
/// coding logins on it and the "Coding agents" panel that sets an agent up,
/// signs it in and signs it out (`NativeServerSetupPanel`, shared with the
/// server's own page in Machines).
///
/// Nothing is dialled until a row is opened; leaving the seat hangs up on every
/// server it opened.
@MainActor
@Observable
final class NativeCodingAIServersModel {
    private(set) var servers: [CodingAIServer] = []
    private(set) var reading = true
    private(set) var problem: String?
    private(set) var looks: [String: CodingAIServerLook] = [:]
    private(set) var setups: [String: NativeServerSetupModel] = [:]
    var expanded: Set<String> = []
    @ObservationIgnored private var opened: Set<String> = []
    @ObservationIgnored private var started = false

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func start() {
        guard !started else { return }
        started = true
        load()
    }

    func stop() {
        guard started else { return }
        started = false
        for setup in setups.values { setup.stop() }
        setups = [:]
        // Only the ones this seat opened.
        for id in opened { Task { _ = try? await call("servers:close", [id]) } }
        opened = []
        looks = [:]
        expanded = []
    }

    private func load() {
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

    /// Opening a row is the press that buys the round trip. Opening it again does not redial.
    func open(_ server: CodingAIServer) {
        guard !opened.contains(server.id) else { return }
        opened.insert(server.id)
        looks[server.id] = .looking
        Task {
            do {
                let raw = try await call("servers:look", [server.id])
                let look = CodingAIServerLook.parse(raw, serverName: server.name)
                looks[server.id] = look
                if case .failed = look {
                    opened.remove(server.id)
                } else {
                    let setup = setups[server.id] ?? NativeServerSetupModel(serverId: server.id)
                    setups[server.id] = setup
                    setup.start()
                }
            } catch {
                opened.remove(server.id)
                looks[server.id] = .failed(CodingAIErrorText.from(error, fallback: "\(server.name) did not answer."))
            }
        }
    }
}

// MARK: - The section

struct NativeCodingAIServersSection: View {
    @Bindable var model: NativeCodingAIServersModel

    var body: some View {
        Group {
            if model.reading && model.servers.isEmpty {
                Section { Text("Reading your servers…").foregroundStyle(.secondary) }
            } else if let problem = model.problem {
                Section { NativeCodingAINotice(tone: .error, text: problem) }
            } else if model.servers.isEmpty {
                Section { Text("No servers yet.").foregroundStyle(.secondary) }
            } else {
                Section {
                    NativeCodingAINotice(tone: .info, text: CodingAIServerAgents.intro)
                }
                ForEach(model.servers) { server in
                    Section {
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expanded.contains(server.id) },
                            set: { open in
                                if open {
                                    model.expanded.insert(server.id)
                                    model.open(server)
                                } else {
                                    model.expanded.remove(server.id)
                                }
                            })
                        ) {
                            NativeCodingAIServerBody(model: model, server: server)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.whereLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One opened server: its logins in the runs, then the setup rows.
struct NativeCodingAIServerBody: View {
    @Bindable var model: NativeCodingAIServersModel
    let server: CodingAIServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            logins
            if let setup = model.setups[server.id] {
                Divider()
                NativeServerSetupPanel(model: setup)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var logins: some View {
        switch model.looks[server.id] {
        case nil:
            EmptyView()
        case .looking?:
            Text("Asking \(server.name)…").foregroundStyle(.secondary)
        case .failed(let problem)?:
            NativeCodingAINotice(tone: .error, text: problem)
        case .notAsked?:
            Text(CodingAIServerAgents.notAsked(server.name)).foregroundStyle(.secondary)
        case .cannot(let why)?:
            Text(why).foregroundStyle(.secondary)
        case .agents(let found)?:
            ForEach(CodingAIServerAgents.runs(found)) { run in
                VStack(alignment: .leading, spacing: 4) {
                    if let title = run.title {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(run.agents) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                NativeCodingAIProviderMark(provider: row.id, size: 13)
                                Text(row.label)
                                if !row.version.isEmpty { NativeCodingAIBadge(text: row.version, quiet: true) }
                            }
                            HStack(spacing: 5) {
                                NativeCodingAIStateMark(state: row.state.rawValue)
                                Text(row.line).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}
