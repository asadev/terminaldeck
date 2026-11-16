import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One file another device changed on this Mac by itself (Security Ruling 2, T13; security review M4).
struct NativeCloudChangeLine: Sendable, Equatable, Identifiable {
    let id: String
    /// "Changed /…/CLAUDE.md · from “MacBook Air” · 13 Nov 2026": paths and names filtered to one plain line.
    let text: String
    /// What this Mac's file held before (lane F's `previousHash`); nil when the file was new here.
    let earlierHash: String?
    /// The one rule (14 Nov): a newer version from another device replaced this Mac's own, which is still kept. Shown as
    /// its own line on the page with Show (the kept text, with Restore), not only inside the folded list.
    var keptLine: Bool = false
}

/// What the lanes that join the account later (projects and agents, boot files) report for the Cloud page's one
/// summary, and the presses that summary passes on to them. Everything is nil until that lane is wired for the
/// signed-in identity: its row is then ABSENT and no button is drawn. Cleared at sign-out.
@MainActor @Observable
final class NativeCloudFeatureParts {
    static let shared = NativeCloudFeatureParts()
    /// Projects and agents (lane A2). nil = not switched on.
    var projects: BackendCloudOverviewInput.Feature?
    /// Boot files (lane F). nil = not switched on.
    var bootFiles: BackendCloudOverviewInput.Feature?
    /// "Review…" for a file that waits to be accepted (lane F's item id). Opens this Mac's own accept sheet.
    @ObservationIgnored var acceptFile: (@MainActor (String) -> Void)?
    /// "Choose folder…" for a project that arrived without a folder on this Mac (lane A2's project id).
    @ObservationIgnored var chooseFolder: (@MainActor (String) -> Void)?
    /// Which of a project's folders on this Mac gets its AI instruction files (lane F; Decker's ruling on S2).
    @ObservationIgnored var chooseBootFolder: (@MainActor (String, String) -> Void)?
    /// Security review M4: the standing list "Changed from your other devices", newest first (boot files).
    var changes: [NativeCloudChangeLine] = []
    /// "Show earlier version" and "Put the earlier version back" for one line (its id). Each is a guarded page press.
    @ObservationIgnored var showEarlier: (@MainActor (String) -> Void)?
    @ObservationIgnored var putBack: (@MainActor (String) -> Void)?
    init() {}
    func clear() {
        projects = nil
        bootFiles = nil
        acceptFile = nil
        chooseFolder = nil
        chooseBootFolder = nil
        changes = []
        showEarlier = nil
        putBack = nil
    }
}

/// The Cloud page's one summary, put together from what is already in hand. Reads no file, Keychain item or network.
@MainActor
enum NativeCloudOverview {
    static func input(model: NativeCloudAccount, secrets: NativeCloudSecrets, parts: NativeCloudFeatureParts,
                      memoryOn: Bool = !NativeCloudBrainRegistration.memoryRows.isEmpty && NativeCloudSyncChoices.shared.isOn(.memory)) -> BackendCloudOverviewInput {
        var made = BackendCloudOverviewInput(snapshot: model.snapshot, newMacPending: model.newMacPending,
                                  memory: memoryOn ? BackendCloudOverviewInput.Memory(included: model.memoryIncluded) : nil,
                                  projects: parts.projects, bootFiles: parts.bootFiles, passwords: secrets.page,
                                  // Review B-M3: wired but not read yet is "Checking…", never an absent row.
                                  passwordsChecking: secrets.graph != nil && secrets.page == nil)
        // Owner, 13 Nov: "Automatically, with my account" shows no Trust buttons; joins and key changes are said.
        made.automaticTrust = model.trustMode == .account
        made.joined = model.joinedNotices()
        // Page-names lane: the same numbers as the Your Cloud window, from the one shared source.
        made.counts = NativeCloudPageCounts.shared.counts
        // Lane L3: a Tasks row and a Settings row while their owners run for this account (the side panel lists both).
        if let kinds = NativeCloudBrainRegistration.kinds {
            if kinds.tasks != nil { made.tasks = .init() }
            if kinds.settings != nil { made.settings = .init() }
        }
        // Page-names 3: until the page's own first read of this Mac's progress, no queue or feed number is said.
        made.progressRead = model.progressRead
        return made
    }
    /// nil while Cloud is not open for this Mac, and when no row is switched on and nothing waits.
    static func current(model: NativeCloudAccount = .shared, secrets: NativeCloudSecrets = .shared,
                        parts: NativeCloudFeatureParts = .shared,
                        memoryOn: Bool = !NativeCloudBrainRegistration.memoryRows.isEmpty && NativeCloudSyncChoices.shared.isOn(.memory)) -> BackendCloudOverview? {
        guard model.snapshot.visible(at: 0) else { return nil }
        return BackendCloudOverviewBuilder.build(input(model: model, secrets: secrets, parts: parts, memoryOn: memoryOn))
    }
}

/// Settings → Cloud, the one place that says where this Mac stands with the Cloud.
struct NativeCloudOverviewSection: View {
    let overview: BackendCloudOverview
    let model: NativeCloudAccount
    let secrets: NativeCloudSecrets
    let parts: NativeCloudFeatureParts
    /// Settings › Cloud since 15 Nov: only what needs him (no headline, no per-kind rows; the status line and the
    /// "Keep in sync on this Mac" list say those).
    var compact = false
    /// The "Changed from your other devices" list starts collapsed: one compact line until opened.
    @State private var changesOpen = false
    /// Page-names 2: the projects without a folder here start folded under their one quiet line.
    @State private var laterOpen = false
    static let changesTitle = "Changed from your other devices"

    static func symbol(_ standing: BackendCloudOverview.Standing) -> String {
        switch standing {
        case .upToDate: return "checkmark.circle.fill"
        case .needsYou: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .unreachable: return "wifi.slash"
        case .saving, .catchingUp, .savingAndCatchingUp: return "arrow.triangle.2.circlepath"
        case .notReady: return "clock"
        case .checking: return "hourglass"
        case .notUsed: return "minus.circle"
        }
    }
    private func tint(_ standing: BackendCloudOverview.Standing) -> Color {
        switch standing {
        case .upToDate: return DeckTokens.good
        case .needsYou, .unreachable: return DeckTokens.warn
        default: return DeckTokens.textSecondary
        }
    }
    /// The headline's lines, without the "not used here" line, which has its own row with its button. Owner, 14 Nov: none
    /// while up to date (the headline says it); while something moves or waits they say what.
    private var otherLines: [String] {
        guard overview.standing != .upToDate else { return [] }
        return overview.lines.filter { !(overview.notUsedHere && $0 == BackendCloudOverviewWords.notUsedHere) }
    }
    /// Owner, 14 Nov: "Boot files" is called "Instruction files" everywhere.
    nonisolated static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "Boot files", with: "Instruction files")
            .replacingOccurrences(of: "boot files", with: "instruction files")
            .replacingOccurrences(of: "Boot file", with: "Instruction file")
            .replacingOccurrences(of: "boot file", with: "instruction file")
    }
    /// A part's row: its name and its count, nothing under it ("All saved · 3,538 notes").
    nonisolated static func rowState(_ state: String) -> String {
        words(state.replacingOccurrences(of: ": ", with: " · "))
    }
    /// A device that joined the account, or a new device waiting for his OK, is Settings → Devices' business (its row
    /// says "Waiting for you" with Trust, and the Settings list marks Devices): never said again here.
    nonisolated static func shownHere(_ action: BackendCloudOverview.Action) -> Bool {
        switch action {
        case .removeDevice, .trust: return false
        default: return true
        }
    }
    /// 15 Nov (DESIGN-FIXES SW-1): a new device's line ("… is a new device that cannot be trusted right now. Look at it
    /// under Devices.") is never written out on the Cloud page: the first group says how many need a look, with Review.
    nonisolated static func isDeviceLine(_ item: BackendCloudOverview.Waiting) -> Bool { item.id.hasPrefix("device:") }
    /// The waiting lines the summary writes out.
    nonisolated static func shownWaiting(_ overview: BackendCloudOverview) -> [BackendCloudOverview.Waiting] {
        overview.waiting.filter { shownHere($0.action) && !isDeviceLine($0) }
    }
    /// "4 new devices need a look"; nil while none waits.
    nonisolated static func devicesNeedALook(_ overview: BackendCloudOverview?) -> String? {
        let count = overview?.waiting.filter(isDeviceLine).count ?? 0
        guard count > 0 else { return nil }
        return count == 1 ? "1 new device needs a look" : "\(count) new devices need a look"
    }
    /// The headline never counts a device's wait it no longer shows: that wait is on Settings → Devices.
    nonisolated static let deviceWaitsTitle = "A new device waits for you in Devices"
    nonisolated static func title(_ overview: BackendCloudOverview) -> String {
        guard overview.standing == .needsYou else { return overview.title }
        let shown = shownWaiting(overview).count + overview.notices.filter { shownHere($0.action) }.count
        let hidden = overview.waiting.count + overview.notices.count - shown
        return shown == 0 && hidden > 0 ? deviceWaitsTitle : overview.title
    }
    var body: some View {
        Section {
            if !compact {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                Label {
                    Text(Self.title(overview)).font(DeckTokens.Typography.section).foregroundStyle(DeckTokens.textPrimary)
                } icon: {
                    // Page-names 3: decorative; the headline beside it says the state. Never read out as a symbol name.
                    Image(systemName: Self.symbol(overview.standing)).foregroundStyle(tint(overview.standing)).accessibilityHidden(true)
                }
                ForEach(otherLines, id: \.self) { line in
                    Text(Self.words(line)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            }
            // Review B-M4: "Not now" was chosen here. One line says both directions; the button turns Cloud on later.
            if overview.notUsedHere {
                HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                    Text(BackendCloudOverviewWords.notUsedHere).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DeckTokens.Spacing.s12)
                    Button(NativeCloudLaunch.cloudHereYes) {
                        NativeCloudSheetGuard.shared.pagePress(model: model) { NativeCloudBrainRegistration.setMemoryIncluded(true) }
                    }
                }
            }
            // Automatic trust: "<device> joined your account and is now trusted on this Mac." with Remove. Non-blocking.
            ForEach(overview.notices.filter { Self.shownHere($0.action) }) { item in
                HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                    Text(Self.words(item.text)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DeckTokens.Spacing.s12)
                    button(item.action)
                }
            }
            // Page-names 2: what he can do here when he wants (never counted as needing him): one quiet line, and the
            // projects by name under it, each with its own button.
            if let later = overview.later {
                if later.items.isEmpty {
                    Text(Self.words(later.summary)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    DisclosureGroup(isExpanded: $laterOpen) {
                        ForEach(later.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                                Text(Self.words(item.text))
                                Spacer(minLength: DeckTokens.Spacing.s12)
                                button(item.action)
                            }
                        }
                    } label: {
                        Text(Self.words(later.summary)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(Self.shownWaiting(overview)) { item in
                HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                    Text(Self.words(item.text)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DeckTokens.Spacing.s12)
                    button(item.action)
                }
            }
            // The one rule: "<Mac>'s newer CLAUDE.md (<project>) is in use; this Mac's version is kept until <date>" · Show.
            // Never counted as needing him.
            ForEach(parts.changes.filter { $0.keptLine }) { change in
                HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                    Text(change.text).font(DeckTokens.Typography.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DeckTokens.Spacing.s12)
                    if let putBack = parts.putBack {
                        Button("Show") { NativeCloudSheetGuard.shared.pagePress(model: model) { putBack(change.id) } }.controlSize(.small)
                    }
                }
            }
            // Owner, 14 Nov: three plain rows, name and count; what stays on this Mac and why is not repeated under them.
            if !compact {
                ForEach(overview.rows) { row in
                    LabeledContent(Self.words(row.title), value: Self.rowState(row.state))
                }
            }
            // Security review M4 (Security Ruling 2, T13): every file another device changed here by itself, one by
            // one, with its earlier version to read or put back. A standing record, not something that waits.
            if !parts.changes.isEmpty {
                DisclosureGroup(isExpanded: $changesOpen) {
                    ForEach(parts.changes) { change in
                        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                            Text(change.text).font(DeckTokens.Typography.callout).fixedSize(horizontal: false, vertical: true)
                            if change.earlierHash != nil {
                                HStack(spacing: DeckTokens.Spacing.s12) {
                                    if let show = parts.showEarlier {
                                        Button("Show earlier version") { NativeCloudSheetGuard.shared.pagePress(model: model) { show(change.id) } }
                                    }
                                    if let putBack = parts.putBack {
                                        Button("Put the earlier version back") { NativeCloudSheetGuard.shared.pagePress(model: model) { putBack(change.id) } }
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                } label: {
                    Text(Self.changesTitle + " (\(parts.changes.count))")
                }
            }
            // Page-names 3 (real check 4: the old "Not saved in this version" block still sat above the one saved-passwords
            // sentence): the page no longer draws that list. What saved passwords carry is said only in their own section
            // (one sentence and "Turn on" while off); agents still read the list through `cloud.status`.
        }
    }
    /// The press a waiting line leads to. Each opens one of this Mac's own sheets; where the lane that owns the
    /// press is not wired, no button is drawn.
    @ViewBuilder private func button(_ action: BackendCloudOverview.Action) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .chooseDevices:
            if model.trustMode == .ask { Button("Choose devices…") { model.reopenSetup() } }
        case .trust(let deviceId):
            if model.trustMode == .ask, let row = model.snapshot.trust.first(where: { $0.deviceId == deviceId }) {
                Button("Trust…") { model.openTrust(row) }
            }
        case .checkAgain:
            // Looks again at everything the summary is built from: the account, saved passwords and both lanes.
            Button("Check again") {
                model.change("check")
                secrets.reload(fresh: "your press")
                NativeCloudRecords.shared.refresh()
                NativeCloudBoot.shared.refresh()
            }
        case .acceptFile(let id):
            if let accept = parts.acceptFile { Button("Review…") { accept(id) } }
        case .chooseFolder(let projectId):
            // Review S-B4: a folder choice lets Cloud write boot files there, so it is a guarded page press.
            if let choose = parts.chooseFolder {
                Button("Choose folder…") { NativeCloudSheetGuard.shared.pagePress(model: model) { choose(projectId) } }
            }
        case .chooseBootFolder(let projectId, let folders):
            // The folders are this Mac's own (folder paths never arrive from the Cloud). The pick is a page press.
            if let choose = parts.chooseBootFolder {
                Menu("Choose folder…") {
                    ForEach(folders, id: \.self) { folder in
                        Button(folder) { NativeCloudSheetGuard.shared.pagePress(model: model) { choose(projectId, folder) } }
                    }
                }
                .fixedSize()
            }
        case .reviewApproval(let id):
            Button("Review…") { secrets.perform(.openApproval, approvalId: id) }
        case .removeDevice(let deviceId):
            // A guarded page press: this Mac stops taking that device's changes.
            Button("Remove") { NativeCloudSheetGuard.shared.pagePress(model: model) { model.removeJoined(deviceId) } }
        case .trustAgain(let deviceId):
            Button("Trust it again") { NativeCloudSheetGuard.shared.pagePress(model: model) { model.trustAgain(deviceId) } }
        }
    }
}
