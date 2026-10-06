import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Session updates (the provider hooks), drawn in Swift — the web page
/// (`components/HooksPanel.tsx`) one-to-one: the line naming Settings → Coding AI
/// and Refresh, the endpoint line while it is not running, the error, one row per
/// assistant (its dot, name and state, what that means, other tools' hooks, the
/// removal promise while confirming, the outcome) with Turn off and its main
/// button, the reading note, and the empty state.
///
/// `hooks:status` and `hooks:server` read; `hooks:install` and `hooks:remove`
/// write, exactly as the page called them.
struct NativeHooksScreen: View {
    @State private var model = HooksScreenModel()

    var body: some View {
        ScrollView {
            HooksPage(model: model)
                .frame(maxWidth: 1312, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task { await model.refresh() }
    }
}

@MainActor
@Observable
final class HooksScreenModel {
    /// nil until the first read answers.
    private(set) var statuses: [HookProviderStatus]?
    private(set) var server: HookServerInfo?
    private(set) var error: String?
    private(set) var busy: String?
    private(set) var results: [String: HookWriteResult] = [:]

    func refresh() async {
        error = nil
        do {
            // One after the other: the answers are `Any`, which cannot cross into a child task.
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
        busy = id
        do {
            results[id] = HookWriteResult(json: try await EngineBridge.shared.invoke(channel, [id]))
            await refresh()
        } catch {
            results[id] = HookWriteResult(ok: false, message: Self.sentence(error))
        }
        busy = nil
    }

    static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        return error.localizedDescription
    }
}

private struct HooksPage: View {
    let model: HooksScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Text(HooksRules.subtitle())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 12)
                Button("Refresh") { Task { await model.refresh() } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(HooksRules.heading)
            .accessibilityAddTraits(.isHeader)

            if !(model.server?.running ?? false) {
                Text(HooksRules.endpointLine(model.server))
                    .foregroundStyle(HooksColors.warn)
            }

            if let error = model.error {
                Text(error).foregroundStyle(HooksColors.bad).textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.statuses ?? []) { status in
                    HookRow(status: status, busy: model.busy == status.id, result: model.results[status.id],
                            install: { Task { await model.install(status.id) } },
                            remove: { Task { await model.remove(status.id) } })
                }
            }

            if model.statuses == nil && model.error == nil {
                NativePageNote("Reading settings files…", busy: true)
                    .frame(minHeight: 160)
            }

            if let statuses = model.statuses, statuses.isEmpty, model.error == nil {
                NativePageEmpty(symbol: "paperclip", title: HooksRules.emptyTitle) {
                    Text(HooksRules.emptyMessage())
                }
                .frame(minHeight: 280)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider hooks")
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

private struct HookRow: View {
    let status: HookProviderStatus
    let busy: Bool
    let result: HookWriteResult?
    let install: () -> Void
    let remove: () -> Void
    @State private var confirming = false

    var body: some View {
        let action = HooksRules.primaryAction(status.state)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(HooksColors.dot(status.state)).frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityHidden(true)
                    Text(status.label).font(.body.weight(.semibold))
                    Text(HooksRules.stateLabel(status.state))
                        .font(.callout)
                        .foregroundStyle(HooksColors.state(status.state))
                }
                Text(status.state == .error ? status.message : HooksRules.consequence(status.state))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let foreign = HooksRules.foreignNote(status) {
                    Text(foreign).font(.callout).foregroundStyle(.tertiary)
                }
                if confirming {
                    Text(HooksRules.removalPromise(file: status.file, backupPath: status.backupPath))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let result {
                    Text(result.message)
                        .font(.callout)
                        .foregroundStyle(result.ok ? HooksColors.ok : HooksColors.bad)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if HooksRules.canRemove(status) {
                    Button(confirming ? "Yes, turn it off" : "Turn off") {
                        if !confirming {
                            confirming = true
                            return
                        }
                        confirming = false
                        remove()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(confirming ? HooksColors.bad : .secondary)
                    .disabled(busy)
                }
                Button(busy ? "Working…" : action.label) {
                    confirming = false
                    install()
                }
                .disabled(busy || !action.enabled)
                .help(HooksRules.writesFile(status.file))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: result) { confirming = false }
        .onChange(of: status.state) { confirming = false }
    }
}

// MARK: - The one-time ask (HooksOffer)

/// The page's `HooksOffer`: the strip above Settings in the sidebar's foot that
/// asks, once, to turn session updates on for every assistant that has none —
/// "Turn it on" / "Not now", then the step still left, or the refusals. Drawn
/// by the native sidebar where the page drew it (above the update banner).
struct NativeHooksOffer: View {
    @State private var model = HooksOfferModel()

    var body: some View {
        Group {
            if !model.hidden, !model.offer.providers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.followUps.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(HooksOffer.followUpTitle).font(.callout.weight(.semibold))
                            ForEach(model.followUps, id: \.self) { step in
                                Text(step).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityAddTraits(.updatesFrequently)
                        Button("Dismiss") { model.hidden = true }
                            .buttonStyle(.borderless)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(HooksOffer.headline(model.offer.providers.count)).font(.callout.weight(.semibold))
                            Text(HooksOffer.detail(model.offer.providers.count)).font(.caption).foregroundStyle(.secondary)
                            ForEach(model.failures, id: \.self) { failure in
                                Text(failure).font(.caption).foregroundStyle(HooksColors.bad)
                            }
                        }
                        HStack(spacing: 8) {
                            if model.failures.isEmpty {
                                Button(model.busy == .accept ? "Turning on…" : "Turn it on") { model.accept() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(model.busy != nil)
                                    .help(HooksOffer.writesTitle(model.offer.providers))
                                Button("Not now") { model.decline() }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .disabled(model.busy != nil)
                                    .help(HooksOffer.notNowTitle)
                            } else {
                                Button("Dismiss") { model.hidden = true }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Session updates")
            }
        }
        .task { await model.load() }
    }
}

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
