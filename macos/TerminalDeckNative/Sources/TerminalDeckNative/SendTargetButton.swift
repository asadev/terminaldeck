import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// One send control for browser and phone feedback. The chevron changes its destination;
/// it never sends a message. A click on the main half sends to the current destination.
struct SendTargetButton: View {
    struct HootRow: View {
        var body: some View {
            HStack {
                HootMark(size: 14, animated: false)
                Text("Hoot").foregroundStyle(.primary)
                Spacer()
                Text("finds the right agent").foregroundStyle(.secondary)
            }
        }
    }
    struct SessionRow: View {
        let session: Session
        var body: some View {
            HStack {
                NativeSessionRowIdentity(id: session.id, project: session.projectRecord).picture(size: 22)
                Text(session.name).foregroundStyle(.primary)
                Spacer()
                Text(session.project).foregroundStyle(.secondary)
            }
        }
    }
    struct Session: Identifiable {
        let id: String
        let name: String
        let project: String
        let colour: Color

        /// Fixtures use explicit labels/colours and never touch the app or project store.
        /// The registry project, for its logo (nil: the letter tile of `project`).
        var projectRecord: PROJProject? = nil
        init(id: String, name: String, project: String, colour: Color) {
            self.id = id; self.name = name; self.project = project; self.colour = colour
        }

        @MainActor init(id: String, name: String, folder: String) {
            self.id = id
            self.name = NativeBRBindings.sessionName(id) ?? name
            let projects = SIDEBARProjectStore.shared.projects
            let projectID = PROJProjects.resolve(projectID: nil, folder: folder, projects: projects)
            let record = projects.first { $0.id == projectID }
            self.projectRecord = record
            self.project = record?.name ?? (folder.isEmpty ? "Independent" : URL(fileURLWithPath: folder).lastPathComponent)
            let hex = SIDEBARLayout.colour(path: folder, projects: AppModel.shared.sidebar?.projects ?? [], registry: projects)
            self.colour = SIDEBARChrome.dot(hex)
        }
    }

    @Binding var targetID: String
    let sessions: [Session]
    var sending = false
    var disabled = false
    var reason = ""
    var canCopy = true
    let send: () -> Void
    let copy: () -> Void

    private var targetName: String {
        targetID == NativeHOOTSIMFeedback.targetID ? "Hoot" : sessions.first { $0.id == targetID }?.name ?? "session"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: send) {
                HStack(spacing: 6) {
                    if targetID == NativeHOOTSIMFeedback.targetID { HootMark(size: 14, animated: false) }
                    Text(sending ? "Sending…" : "Send to \(targetName)").lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
                .contentShape(.rect)
            }
            .disabled(disabled || sending)
            .keyboardShortcut(.defaultAction)
            .help(reason.isEmpty ? "Send to \(targetName)" : reason)
            .accessibilityLabel("Send to \(targetName)")
            Rectangle().fill(Color.white.opacity(0.24)).frame(width: 1, height: 18)
            Menu {
                Button { targetID = NativeHOOTSIMFeedback.targetID } label: {
                    HootRow()
                }
                Divider()
                Section("A session") {
                    ForEach(sessions) { session in
                        Button { targetID = session.id } label: {
                            SessionRow(session: session)
                        }
                    }
                }
                Divider()
                Button("Copy as a picture", systemImage: "doc.on.doc", action: copy).disabled(!canCopy)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(sending)
            .help("Choose where to send")
            .accessibilityLabel("Choose where to send")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: .capsule)
        .clipShape(.capsule)
        .opacity(disabled ? 0.6 : 1)
    }
}

/// Remember the person's destination per browser tab or phone panel, across cards.
/// There is no second session list or poller: the existing card/model supplies rows.
@MainActor @Observable final class NativeHOOTSIMTargets {
    static let shared = NativeHOOTSIMTargets()
    private(set) var notice: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// U143 (#469): every choice lives in one saved list ([scope, target] pairs, newest last), kept to the
    /// latest `kept` tabs and panels, so tabs and panels long closed do not pile up in the preferences.
    static let key = "td.feedback.targets.v2"
    static let kept = 64
    private static let oneKeyPerScope = "td.feedback.target."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The former one-key-per-scope entries are folded into the list once and removed.
        let old = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.oneKeyPerScope) }
        guard !old.isEmpty else { return }
        var list = saved
        for (key, value) in old {
            let scope = String(key.dropFirst(Self.oneKeyPerScope.count))
            if let id = value as? String, !list.contains(where: { $0[0] == scope }) { list.insert([scope, id], at: 0) }
            defaults.removeObject(forKey: key)
        }
        defaults.set(Array(list.suffix(Self.kept)), forKey: Self.key)
    }
    private var saved: [[String]] { ((defaults.array(forKey: Self.key) as? [[String]]) ?? []).filter { $0.count == 2 } }
    func target(scope: String, originatingSession: String?) -> String {
        saved.last { $0[0] == scope }?[1] ?? originatingSession ?? NativeHOOTSIMFeedback.targetID
    }
    func remember(_ id: String, scope: String) {
        let list = saved.filter { $0[0] != scope } + [[scope, id]]
        defaults.set(Array(list.suffix(Self.kept)), forKey: Self.key)
    }
    func sentToHoot() {
        noticeTask?.cancel()
        notice = "Sent to Hoot"
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
        AppModel.shared.select("hoot")
    }
}

/// One glass cluster for the browser's floating note/send bar; cards stay solid.
struct NativeHOOTSIMGlassBar: ViewModifier {
    @Environment(\.agkitOffscreenSolid) private var offscreen
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if !offscreen && !reduceTransparency {
            GlassEffectContainer { content.glassEffect(.regular, in: .capsule) }
        } else {
            content.background(AGKITStyle.card, in: .capsule)
                .overlay(Capsule().strokeBorder(AGKITStyle.hairline, lineWidth: 0.5))
        }
    }
}
