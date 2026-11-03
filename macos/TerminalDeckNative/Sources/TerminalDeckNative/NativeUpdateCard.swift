import SwiftUI
import TerminalDeckNativeCore

/// The updater's state as the side panel sees it. Only NativeAppUpdater.shared writes it (NativeAppUpdater.publish).
@MainActor @Observable final class NativeUpdateCardModel {
    static let shared = NativeUpdateCardModel()
    private(set) var state: UpdateState = .none
    private(set) var waitingFor: String?
    private(set) var restarting = false
    private(set) var notesURL: URL?
    private(set) var dismissedVersion: String?
    /// The version the card was offering; an error after it belongs to the card (an automatic check never errors).
    private(set) var offered: String?
    /// An error the person closed with ×, for this run only.
    var hiddenError: String?

    func update(from updater: NativeAppUpdater) {
        state = updater.state; waitingFor = updater.waitingFor; restarting = updater.relaunchOnQuit
        notesURL = updater.notesURL; dismissedVersion = updater.dismissedVersion
        switch state {
        case .available(let version, _, _), .downloading(let version, _, _), .ready(let version): offered = version
        case .idle: offered = nil
        default: break
        }
    }

    /// Render fixtures only (Release27UpdaterRestartTests): a state the live updater would have published.
    func show(_ state: UpdateState, waitingFor: String? = nil, restarting: Bool = false, notesURL: URL? = nil) {
        self.state = state; self.waitingFor = waitingFor; self.restarting = restarting; self.notesURL = notesURL; offered = "0.21.0"
    }

    func card(inAppSessions: Int) -> UpdateCard? {
        UpdateCard.make(state, waitingFor: waitingFor, restarting: restarting, dismissedVersion: dismissedVersion,
                        offered: offered, hiddenError: hiddenError, notesURL: notesURL, inAppSessions: inAppSessions)
    }
}

/// Just above Settings in the side panel: "Update available · 0.21.0" → Download → progress → "Restart to update".
/// Shown only while there is something real to say; the restart happens only on the person's press (and waits
/// for Hoot to finish an answer). Tinted surface, one blue primary action, a plain release-notes link.
struct NativeUpdateCard: View {
    var model: NativeUpdateCardModel = .shared
    var inAppSessions: @MainActor () -> Int = { NativeSVResident.shared.inAppSessionCount }
    @State private var pressed = false

    var body: some View {
        if let card = model.card(inAppSessions: inAppSessions()) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if card.busy && card.progress == nil {
                        // Waiting on Hoot or restarting: a real spinner, never a bar that looks like 1 %.
                        ProgressView().controlSize(.mini)
                    } else {
                        let problem = card.primary?.action == .retry
                        Image(systemName: problem ? "exclamationmark.triangle.fill" : card.primary?.action == .restart ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(problem ? Color.orange : Color.accentColor)
                    }
                    Text(card.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let key = card.dismissKey {
                        Button { dismiss(key) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 16, height: 16).contentShape(.rect)
                        }
                        .buttonStyle(.plain).help(UpdateCard.dismissHelp).accessibilityLabel("Hide this update")
                    }
                }
                if let progress = card.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                }
                if let detail = card.detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(4).help(detail)
                }
                if card.primary != nil || card.notesURL != nil {
                    HStack(spacing: 10) {
                        if let primary = card.primary {
                            // Blue only for the step forward (Download, Restart, Try again); Cancel is plain.
                            let button = Button(primary.label) { run(primary.action) }.controlSize(.small)
                                .disabled(pressed).accessibilityIdentifier("update-card-" + primary.action.rawValue)
                            if primary.action == .cancelWait { button.buttonStyle(.bordered) } else { button.buttonStyle(.borderedProminent) }
                        }
                        if let url = card.notesURL {
                            Link("What’s new", destination: url).font(.system(size: 11.5))
                                .help("Opens this release’s notes on GitHub")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Update")
        }
    }

    private func dismiss(_ key: String) {
        if key.hasPrefix("error:") { model.hiddenError = key }
        else { NativeAppUpdater.shared.dismiss(version: key) }
    }

    private func run(_ action: UpdateCard.Action) {
        pressed = true
        Task { @MainActor in
            defer { pressed = false }
            let updater = NativeAppUpdater.shared
            switch action {
            case .download: _ = await updater.handle("update:download")
            case .restart: await updater.requestRestart()
            case .cancelWait: updater.cancelRestart()
            case .retry: _ = await updater.handle("update:check")
            }
        }
    }
}
