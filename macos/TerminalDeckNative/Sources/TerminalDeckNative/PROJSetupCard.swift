import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// What the project page's setup card reads: the project's settings and its lead seat's card.
/// The registry and the agents come from the stores the page already watches, so the score
/// redraws by itself when either changes; settings and the card are read again on their pushes.
@MainActor @Observable
final class PROJSetupStatusModel {
    var settings: NativeRPCValue = .object([])
    var card = ""
    var loaded = false
    @ObservationIgnored private var projectID: String?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored private let fixture: Bool
    /// A fixed picture for offscreen renders and tests.
    init(settings: NativeRPCValue? = nil, card: String? = nil) {
        fixture = settings != nil
        if let settings { self.settings = settings; self.card = card ?? ""; loaded = true }
    }

    func start(_ projectID: String) async {
        guard !fixture else { return }
        if self.projectID != projectID { loaded = false; card = ""; settings = .object([]) }
        self.projectID = projectID
        if subscriptions.isEmpty {
            subscriptions.append(EngineBridge.shared.on("settings:changed") { [weak self] _ in Task { @MainActor in await self?.read() } })
            for name in [Notification.Name.deckMemoryChanged, .projSetupChanged] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { _ = Task { await self?.read() } }
                })
            }
        }
        AGTAgentsStore.shared.start()
        await read()
    }
    func stop() {
        subscriptions.forEach { $0.cancel() }; subscriptions = []
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }
    private func read() async {
        guard let projectID else { return }
        if let raw = try? await EngineBridge.shared.invoke("project-settings:get", [["projectId": projectID]]),
           let value = try? NativeRPCValue.fromFoundation(raw) { settings = value }
        card = (try? await DeckMemory.store.card(.lead(projectID)).text) ?? card
        loaded = true
    }

    /// Nil until read once, and for Independent.
    func score(_ project: PROJProject, agents: [AgentProfile]) -> PROJSetupScore? {
        guard loaded, project.id != PROJProjects.independentID else { return nil }
        return PROJSetup.score(PROJSetup.facts(project: project, settings: settings, agents: agents.map(PROJSetupAgent.init), card: card))
    }
}

/// "Setup N%" and the missing parts, each with the button that opens that page of the guide.
/// Shown until every part is set; it comes back by itself if something goes missing again.
struct PROJSetupCard: View {
    let project: PROJProject
    let score: PROJSetupScore
    var openGuide: (PROJGuideStep) -> Void = { _ in }

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "checklist").foregroundStyle(.secondary)
                    Text("Setup \(score.percent)%").font(DeckTokens.Typography.section).monospacedDigit()
                    PROJSetupMeter(percent: score.percent).frame(maxWidth: 220)
                    Spacer(minLength: 8)
                    Text("\(score.done.count) of \(PROJSetupPart.allCases.count) set").font(DeckTokens.Typography.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(score.missing.enumerated()), id: \.element) { index, part in
                        if index > 0 { Divider().padding(.leading, 30) }
                        HStack(spacing: 10) {
                            Image(systemName: Self.symbol(part)).foregroundStyle(.secondary).frame(width: 20)
                            Text(part.missingLine)
                            Spacer(minLength: 8)
                            Button(part.action) { openGuide(part.step) }.controlSize(.small)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup \(score.percent) percent")
    }
    static func symbol(_ part: PROJSetupPart) -> String {
        switch part {
        case .description: "text.alignleft"
        case .logo: "photo"
        case .lead: "person.crop.circle.badge.checkmark"
        case .team: "person.3"
        case .skills: "wand.and.stars"
        case .card: "note.text"
        }
    }
}

/// A thin progress bar in the accent colour.
struct PROJSetupMeter: View {
    let percent: Int
    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(DeckTokens.selection)
                Capsule().fill(DeckTokens.meter).frame(width: box.size.width * CGFloat(max(0, min(100, percent))) / 100)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// A folder opened without the guide: a plain session folder under Independent, with the way to make it a project.
struct PROJPlainFolderCard: View {
    let folder: String
    var body: some View {
        DeckCard {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not a project").font(DeckTokens.Typography.rowTitle)
                    Text("Sessions here belong to Independent.").font(DeckTokens.Typography.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Set up as a project…") { PROJGuideWindow.open(folder: folder) }
            }
        }
    }
}
