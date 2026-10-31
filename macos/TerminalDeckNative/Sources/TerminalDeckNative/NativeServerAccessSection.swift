import Observation
import SwiftUI
import TerminalDeckNativeCore

/// What AI apps and sessions may do on one server (`servers:access:*`), and which
/// AI app keys may use it at all (`servers:ai-access:*`). Hoot and this Mac's own
/// sessions are always allowed; other AI apps only when ticked here.
@MainActor
@Observable
final class NativeServerAccessModel {
    let serverId: String
    private(set) var lookOnly: Bool?
    private(set) var sshAlias: String?
    private(set) var keyIDs: Set<String> = []
    private(set) var keys: [AiAccessKey] = []
    private(set) var problem: String?
    private(set) var saving = false
    private let live: Bool

    init(serverId: String, live: Bool = true) { self.serverId = serverId; self.live = live }

    /// Offscreen renders only: fixed state, no engine calls.
    init(fixture serverId: String, lookOnly: Bool, sshAlias: String?, keys: [AiAccessKey], allowed: Set<String>) {
        self.serverId = serverId; self.lookOnly = lookOnly; self.sshAlias = sshAlias
        self.keys = keys; keyIDs = allowed; live = false
    }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func load() {
        guard live else { return }
        Task {
            do {
                take(try await call("servers:access:read", [serverId]))
                let allowed = try await call("servers:ai-access:read", [serverId])
                keyIDs = Set((allowed["keyIDs"].array ?? []).compactMap(\.string))
                keys = AiAppsState.from(try await call("ai-apps:state"))?.keys ?? []
                problem = nil
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "Could not read who may use this server.")
            }
        }
    }

    private func take(_ raw: CodingAIJSON) {
        lookOnly = raw["lookOnly"].isTrue
        sshAlias = raw["sshAlias"].text
    }

    func setLookOnly(_ value: Bool) {
        guard live, value != lookOnly else { return }
        saving = true
        Task {
            do {
                take(try await call("servers:access:set", [serverId, ["lookOnly": value]]))
                problem = nil
                NativeServersModel.shared.reread()
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "That choice was not saved. Try again.")
            }
            saving = false
        }
    }

    func setKey(_ id: String, allowed: Bool) {
        guard live else { return }
        var next = keyIDs
        if allowed { next.insert(id) } else { next.remove(id) }
        saving = true
        Task {
            do {
                let raw = try await call("servers:ai-access:set", [serverId, next.sorted()])
                keyIDs = Set((raw["keyIDs"].array ?? []).compactMap(\.string))
                problem = nil
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "That choice was not saved. Try again.")
            }
            saving = false
        }
    }
}

/// The server page's section: "What AI apps and sessions may do here".
struct NativeServerAccessSection: View {
    @State private var model: NativeServerAccessModel

    init(serverId: String) { _model = State(initialValue: NativeServerAccessModel(serverId: serverId)) }
    init(model: NativeServerAccessModel) { _model = State(initialValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What AI may do here").font(.system(size: 15, weight: .semibold))
            MACHINESCard {
                VStack(spacing: 0) {
                    if let lookOnly = model.lookOnly {
                        choice(title: "Look only", detail: "See what runs, read logs and usage. Nothing changes.", selected: lookOnly) { model.setLookOnly(true) }
                        Divider()
                        choice(title: "Look and change", detail: "Also start, stop and remove. Every change asks you first.", selected: !lookOnly) { model.setLookOnly(false) }
                    } else if model.problem == nil {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)).frame(height: 72)
                    }
                }.disabled(model.saving)
            }
            Text("AI apps that may use this server").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            MACHINESCard {
                VStack(spacing: 0) {
                    accessRow(title: "Hoot and sessions on this Mac", subtitle: "Always allowed.") {
                        // SETTINGS-TRUTH row 115: it can never change, so it is a statement, not a switch.
                        Label("Allowed", systemImage: "checkmark").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    }
                    ForEach(model.keys) { key in
                        Divider()
                        accessRow(title: key.name, subtitle: "Outside AI app") {
                            Toggle(key.name, isOn: Binding(get: { model.keyIDs.contains(key.id) }, set: { model.setKey(key.id, allowed: $0) }))
                                .labelsHidden().toggleStyle(.switch).disabled(model.saving)
                        }
                    }
                }
            }
            if let problem = model.problem {
                HStack {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    DeckRetryButton("Try again", autoRetry: true) { model.load() } // autoRetry: re-reads the access settings
                }
            }
            Label("Changes save as you make them.", systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
        }.onAppear { model.load() }
    }

    private func accessRow<Control: View>(title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }.padding(.vertical, 10)
    }

    private func choice(title: String, detail: String, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(.rect)
        }.buttonStyle(MACHINESRowStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One quiet line at the top of a look-only server's Docker page.
struct NativeServerLookOnlyBanner: View {
    static let reason = "This server is set to Look only, so nothing on it can be changed from Terminal Deck. To allow changes, open the server’s page and choose Look and change."

    var body: some View {
        Label {
            Text("Look only — you can see everything here, but nothing can be changed from Terminal Deck.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "eye").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .help(Self.reason)
        .accessibilityElement(children: .combine)
    }
}
