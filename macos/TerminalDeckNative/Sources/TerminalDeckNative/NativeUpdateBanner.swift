import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// updates/UpdateBanner.tsx, drawn natively in the sidebar's foot: nothing while
/// idle or checking; otherwise the headline, the detail line, the one button the
/// phase needs (Update / Restart to finish / Try again), Dismiss, the download
/// bar, "What changed", and the releases link for a build that cannot update.
/// The engine does the work: `update:get`, `update:state`, `update:download`,
/// `update:install`, `update:check`, and `settings:about` for the link.
struct NativeUpdateBanner: View {
    let model: AppModel
    @State private var feed = NativeUpdateFeed.shared

    var body: some View {
        let state = feed.state
        Group {
            if state.shown && !state.isDismissed(by: feed.dismissed) {
                banner(state)
            }
        }
        .task { feed.start() }
    }

    private func banner(_ state: UpdateState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.headline).font(.callout.weight(.semibold))
                if let line = state.detail {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if case .unsupported = state, let link = feed.releasesUrl, let url = URL(string: link) {
                    Button(Update.releasesLink) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .accessibilityElement(children: .combine)

            if case .downloading = state {
                Group {
                    if let percent = state.progress {
                        ProgressView(value: percent, total: 100)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .accessibilityLabel("Update download")
            }

            HStack(spacing: 8) {
                primaryButton(state)
                Spacer(minLength: 0)
                Button("Dismiss") { feed.dismiss() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(Update.dismissHelp)
            }

            if let notes = state.notes {
                DisclosureGroup(Update.notesTitle) {
                    ScrollView {
                        Text(Self.markdown(notes))
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.caption)
            }
            if let notice = feed.notice {
                Text(notice).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Update")
    }

    @ViewBuilder private func primaryButton(_ state: UpdateState) -> some View {
        let busy = feed.busy
        switch state {
        case .available:
            Button(busy == .update ? "Starting…" : "Update") { feed.run(.update) }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy != nil)
        case .ready:
            Button(busy == .restart ? "Restarting…" : "Restart to finish") { feed.run(.restart) }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy != nil)
        case .error:
            Button(busy == .retry ? "Trying again…" : "Try again") { feed.run(.retry) }
                .controlSize(.small).disabled(busy != nil)
        default:
            EmptyView()
        }
    }

    /// The notes are markdown, as the page rendered them; plain text if they do not parse.
    static func markdown(_ notes: String) -> AttributedString {
        (try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(notes)
    }
}

/// The banner's state for the whole run. Dismissing lasts until the app is
/// started again (the page kept it in sessionStorage for the same reason).
@MainActor @Observable
final class NativeUpdateFeed {
    static let shared = NativeUpdateFeed()

    private(set) var state = UpdateState.none
    private(set) var busy: UpdateBusy?
    private(set) var notice: String?
    private(set) var dismissed: String?
    private(set) var releasesUrl: String?
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var asked = false

    func start() {
        guard subscription == nil else { return }
        subscription = EngineBridge.shared.on("update:state") { [weak self] args in
            self?.apply(UpdateState(raw: args.first))
        }
        Task {
            // Silence on failure: the feature is optional and About answers why.
            if let answer = try? await EngineBridge.shared.invoke("update:get") { apply(UpdateState(raw: answer)) }
        }
    }

    private func apply(_ next: UpdateState) {
        state = next
        if case .unsupported = next, releasesUrl == nil, !asked {
            asked = true
            Task {
                let about = try? await EngineBridge.shared.invoke("settings:about")
                releasesUrl = Update.releasesUrl(for: (about as? [String: Any])?["repository"] as? String)
            }
        }
    }

    func run(_ action: UpdateBusy) {
        busy = action
        notice = nil
        Task {
            do {
                _ = try await EngineBridge.shared.invoke(action.channel)
                busy = nil
            } catch {
                busy = nil
                let text = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
                notice = text.isEmpty ? Update.failed : text
            }
        }
    }

    func dismiss() {
        dismissed = state.dismissKey
    }
}
