import SwiftUI
import TerminalDeckNativeCore

/// One `Host` entry from this Mac's SSH settings (`servers:ssh-aliases`).
struct ServerSSHAlias: Identifiable, Equatable {
    let alias: String
    let hostname: String
    let user: String
    let port: Int
    let keyNames: [String]
    let ready: Bool
    let problem: String?
    let serverId: String?
    var id: String { alias }

    var whereLine: String {
        let place = user.isEmpty ? hostname : "\(user) at \(hostname)"
        return port == 22 ? place : "\(place), port \(port)"
    }

    static func parse(_ raw: CodingAIJSON) -> [ServerSSHAlias]? {
        guard raw["ok"].isTrue, let rows = raw["aliases"].array else { return nil }
        return rows.compactMap { row in
            guard let alias = row["alias"].text, !alias.isEmpty else { return nil }
            return ServerSSHAlias(alias: alias, hostname: row["hostname"].text ?? "", user: row["user"].text ?? "",
                                  port: row["port"].number.map { Int($0) } ?? 22,
                                  keyNames: (row["keyNames"].array ?? []).compactMap(\.string),
                                  ready: row["ready"].isTrue, problem: row["problem"].text, serverId: row["serverId"].text)
        }
    }
}

/// Add page: "From this Mac's SSH settings". Picking an alias adds the server with
/// the person's own SSH settings; no key is read or copied by Terminal Deck.
struct NativeServerSSHAliasesSection: View {
    @Bindable var model: NativeServersModel
    @Binding var route: NativeServersRoute
    @State private var aliases: [ServerSSHAlias]?
    @State private var problem: String?
    @State private var confirming: String?
    @State private var name = ""
    @State private var lookOnly = true
    @Binding private var projectId: String
    private let projects: [PROJProject]
    private let projectsReady: Bool
    private let fixture: Bool

    init(model: NativeServersModel, route: Binding<NativeServersRoute>,
         fixture: [ServerSSHAlias]? = nil, confirming: String? = nil,
         projectId: Binding<String> = .constant(PROJProjects.independentID),
         projects: [PROJProject] = PROJProjects.defaults, projectsReady: Bool = true) {
        self.model = model
        _projectId = projectId; self.projects = projects; self.projectsReady = projectsReady
        _route = route
        _aliases = State(initialValue: fixture)
        _confirming = State(initialValue: confirming)
        self.fixture = fixture != nil
    }

    var body: some View {
        Group {
            if let aliases, !aliases.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("From this Mac’s SSH settings").font(.headline)
                    Text("Servers you already reach with ssh on this Mac. Pick one to add it.")
                        .font(.callout).foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(aliases) { row($0) }
                    }
                    Label {
                        Text("Terminal Deck uses your own SSH settings and keys. It never copies or reads your private keys.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Divider().padding(.top, 6)
                    Text("Or type in the details").font(.headline).padding(.top, 2)
                }
            } else if let problem {
                NativeCodingAINotice(tone: .warn, text: problem)
            }
        }
        .task {
            guard !fixture else { return }
            do {
                let raw = CodingAIJSON(try await EngineBridge.shared.invoke("servers:ssh-aliases"))
                aliases = ServerSSHAlias.parse(raw) ?? []
                if !raw["ok"].isTrue, let sentence = raw["sentence"].text { problem = sentence }
            } catch {
                // No SSH settings to offer is not an error worth a line; the form below still works.
                aliases = []
            }
        }
    }

    @ViewBuilder private func row(_ alias: ServerSSHAlias) -> some View {
        let open = confirming == alias.alias
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alias.alias)
                    Text(alias.whereLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let id = alias.serverId {
                    Text("Already added").font(.callout).foregroundStyle(.secondary)
                    NativeSessionButton("Open") { route = .server(id) }
                } else if !alias.ready {
                    Text(alias.problem ?? "This one cannot be used yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 260, alignment: .trailing)
                } else if !open {
                    NativeSessionButton("Add") {
                        model.clearAddError()
                        name = ""; lookOnly = true; confirming = alias.alias
                        // A server name means no project by itself: the person picks one (or none) below.
                    }
                    .disabled(model.adding || !projectsReady)
                }
            }
            if open { confirm(alias) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func confirm(_ alias: ServerSSHAlias) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What to call it here").font(.subheadline.weight(.semibold))
                NativeSessionTextField("What to call it here", text: $name, prompt: Text(alias.alias))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 320)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What may AI apps and sessions do here?").font(.subheadline.weight(.semibold))
                Picker("What may AI apps and sessions do here?", selection: $lookOnly) {
                    Text("Look only").tag(true)
                    Text("Look and change (they ask you first)").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("You can change this later on the server’s page.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                NativeSessionButton(model.adding ? "Connecting…" : "Add server") { add(alias) }
                    .buttonStyle(NativeServersPrimaryButtonStyle())
                    .disabled(model.adding)
                NativeSessionButton("Cancel") { confirming = nil }
                    .disabled(model.adding)
            }
        }
        .padding(.leading, 28)
        .padding(.bottom, 2)
    }

    private func add(_ alias: ServerSSHAlias) {
        var draft: [String: Any] = ["method": "ssh-config", "sshAlias": alias.alias, "lookOnly": lookOnly, "projectId": projectId]
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { draft["name"] = typed }
        model.submit(CodingAIJSON(draft), route: $route)
    }
}
