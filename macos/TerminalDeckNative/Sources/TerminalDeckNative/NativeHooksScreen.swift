import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Compatibility route: live status now lives with each installed coding AI.
/// The channel names and provider-hook tools remain available to MCP callers.
struct NativeHooksScreen: View {
    var body: some View { NativeCodingAISettings() }
}

@MainActor
@Observable
final class HooksScreenModel {
    private(set) var statuses: [HookProviderStatus]?
    private(set) var server: HookServerInfo?
    private(set) var error: String?
    private(set) var busy: String?
    private(set) var refreshing = false
    private(set) var results: [String: HookWriteResult] = [:]
    @ObservationIgnored private var rereadRequested = false

    func refresh() async {
        guard !refreshing else {
            rereadRequested = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if rereadRequested {
                rereadRequested = false
                Task { await refresh() }
            }
        }
        error = nil
        do {
            let rows = try await EngineBridge.shared.invoke("hooks:status")
            let about = try await EngineBridge.shared.invoke("hooks:server")
            statuses = HookProviderStatus.list(rows)
            server = HookServerInfo(json: about)
        } catch {
            self.error = Self.sentence(error)
        }
    }

    func install(_ id: String) async { await write(id, channel: "hooks:install") }
    func remove(_ id: String) async { await write(id, channel: "hooks:remove") }

    private func write(_ id: String, channel: String) async {
        guard busy == nil else { return }
        busy = id
        defer { busy = nil }
        do {
            results[id] = HookWriteResult(json: try await EngineBridge.shared.invoke(channel, [id]))
            await refresh()
        } catch {
            results[id] = HookWriteResult(ok: false, message: Self.sentence(error))
        }
    }

    static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        return error.localizedDescription
    }
}

/// A real switch backed by the existing install/remove actions; no new keys.
struct NativeLiveStatusSetting: View {
    let providerId: String
    let model: HooksScreenModel
    @State private var confirmingRemoval = false

    private var status: HookProviderStatus? { model.statuses?.first { $0.id == providerId } }
    private var isBusy: Bool { model.busy == providerId }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { status.map(HooksRules.canRemove) ?? false }, set: change)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live status")
                    Text("Lets its tabs show Working, Waiting for you or Done.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(status == nil || status?.state == .error || model.busy != nil)
            .help(status.map { HooksRules.writesFile($0.file) } ?? "Reading live status")
            .contextMenu {
                if let status, status.state == .complete {
                    Button("Set up again") { Task { await model.install(providerId) } }
                        .disabled(model.busy != nil)
                }
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.refreshing)
            }

            if isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating live status…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityAddTraits(.updatesFrequently)
            } else if let status {
                stateLine(status)
            } else if model.error == nil {
                Text(model.statuses == nil ? "Reading live status…" : "Live status is unavailable for this AI.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let server = model.server, !server.running {
                HStack(spacing: 6) {
                    Label("Live status is not listening.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                    NativeCodingAIInfo(label: "Live status", text: HooksRules.endpointLine(server))
                }
            }
            if let result = model.results[providerId], !result.message.isEmpty {
                HStack(spacing: 6) {
                    Text(result.message).font(.callout)
                        .foregroundStyle(result.ok ? Color.secondary : Color.red)
                        .lineLimit(1).textSelection(.enabled)
                    NativeCodingAIInfo(label: "Live status result", text: result.message)
                }
            }
        }
        .alert("Turn off live status?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off", role: .destructive) {
                Task { await model.remove(providerId) }
            }
        } message: {
            if let status {
                Text(HooksRules.removalPromise(file: status.file, backupPath: status.backupPath))
            }
        }
    }

    @ViewBuilder private func stateLine(_ status: HookProviderStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(HooksColors.dot(status.state)).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(HooksRules.stateLabel(status.state))
                .font(.callout).foregroundStyle(HooksColors.state(status.state))
            NativeCodingAIInfo(label: "Live status", text: information(status))
            Spacer(minLength: 8)
            if status.state == .stale || status.state == .partial {
                Button("Fix it") { Task { await model.install(providerId) } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.busy != nil)
            }
        }
    }

    private func information(_ status: HookProviderStatus) -> String {
        var lines = [status.state == .error && !status.message.isEmpty
                     ? status.message : HooksRules.consequence(status.state)]
        if let foreign = HooksRules.foreignNote(status) { lines.append(foreign) }
        lines.append(HooksRules.writesFile(status.file))
        return lines.joined(separator: "\n\n")
    }

    private func change(_ enabled: Bool) {
        guard let status, status.state != .error, model.busy == nil else { return }
        if enabled {
            Task { await model.install(providerId) }
        } else if HooksRules.canRemove(status) {
            confirmingRemoval = true
        }
    }
}

enum HooksColors {
    static let ok = Color.green
    static let warn = Color.orange
    static let bad = Color.red

    static func dot(_ state: HookInstallState) -> Color {
        switch state {
        case .complete: ok
        case .stale, .partial: warn
        case .error: bad
        case .none: .secondary
        }
    }

    static func state(_ state: HookInstallState) -> Color {
        switch state {
        case .stale, .partial: warn
        case .error: bad
        default: .secondary
        }
    }
}

// MARK: - The one-time ask (HooksOffer)

@MainActor
@Observable
final class HooksOfferModel {
    enum Busy { case accept, decline }

    private(set) var offer = HooksOfferState.none
    private(set) var busy: Busy?
    private(set) var failures: [String] = []
    private(set) var followUps: [String] = []
    var hidden = false

    func load() async {
        guard let answer = try? await EngineBridge.shared.invoke("hooks:offer") else { return }
        offer = HooksOfferState(json: answer)
    }

    func accept() {
        busy = .accept
        Task {
            do {
                let found = HooksOffer.failures(try await EngineBridge.shared.invoke("hooks:offer-accept"))
                    .map { $0.replacingOccurrences(of: "the Session updates page in the sidebar",
                                                   with: "Settings → Coding AIs → Live status") }
                if !found.isEmpty {
                    failures = found
                } else if !offer.followUps.isEmpty {
                    followUps = offer.followUps
                } else {
                    hidden = true
                }
            } catch {
                failures = [HooksScreenModel.sentence(error)]
            }
            busy = nil
        }
    }

    func decline() {
        busy = .decline
        Task {
            _ = try? await EngineBridge.shared.invoke("hooks:offer-decline")
            busy = nil
            hidden = true
        }
    }
}
