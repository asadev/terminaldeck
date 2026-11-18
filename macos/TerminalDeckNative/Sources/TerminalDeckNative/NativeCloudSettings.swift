import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// 18 Nov (owner, item 29: "It is still showing the yellow one. Why? ... See all of this"; DESIGN-settings 5): what the
/// Cloud page's ONE top row says and what sits folded under it. Before, one cause (saved passwords not sent) was said
/// four times: the orange line "Something needs you: saved passwords", a grey box, a cut-off state and nine orange
/// sentences. Now it is said once, in plain words, and the rest is behind a click. Pure, so it is tested without a page.
enum NativeCloudCalm {
    static let passwordsGapsID = "passwords:gaps"
    static let passwordsHeadline = "Some saved passwords are not in your Cloud yet"
    /// The Saved passwords row's state while some are not in the Cloud (short, never cut off).
    static let passwordsShort = "Not all in Cloud yet"
    static let triedAgain = "This Mac tries again at every sync."
    static let needsPrefix = "Something needs you: "
    static let somethingWaits = "Something is waiting for you"
    static let notSavedPrefix = "Not saved to Cloud from this Mac: "

    /// The row's words: the line's own state, said plainly. A wait is named without "Something needs you: " in front;
    /// saved passwords that are not in the Cloud are named as that.
    static func headline(_ line: BackendCloudStatusLine, passwordGaps: Bool) -> String {
        guard line.kind == .needsYou, line.text.hasPrefix(needsPrefix) else {
            return line.kind == .needsYou && line.text == "Something needs you" ? somethingWaits : line.text
        }
        var words = String(line.text.dropFirst(needsPrefix.count))
        if passwordGaps, words.hasPrefix(BackendCloudStatusLineWords.passwords),
           !words.hasPrefix(BackendCloudStatusLineWords.passwords + " ") {
            words = passwordsHeadline + words.dropFirst(BackendCloudStatusLineWords.passwords.count)
        }
        if words.hasPrefix(BackendCloudStatusLineWords.other) {
            words = somethingWaits + words.dropFirst(BackendCloudStatusLineWords.other.count)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A kind's title inside a sentence: "Project secret files" reads "project secret files"; names and short forms
    /// ("API keys", "MCP servers", "WhatsApp keys", "Receiver secrets") stay as they are; "The voice key" reads "the …".
    static func inSentence(_ title: String) -> String {
        let first = title.prefix { !$0.isWhitespace && $0 != "-" }
        if ["WhatsApp", "Receiver", "Hoot"].contains(String(first)) { return title }
        if first.dropFirst().contains(where: \.isUppercase) { return title }
        return title.prefix(1).lowercased() + title.dropFirst()
    }
    /// The saved passwords that are not in the Cloud, as the details say them: ONE sentence naming the kinds whose save
    /// did not get through, then any other line the saved passwords report (a key too large to save) as it is.
    static func passwordLines(_ page: BackendCloudSecretsPage?) -> [String] {
        guard let page, !page.gaps.isEmpty else { return [] }
        var kinds: [String] = []
        var others: [String] = []
        for gap in page.gaps {
            if gap.hasPrefix(notSavedPrefix), let end = gap.dropFirst(notSavedPrefix.count).firstIndex(of: ".") {
                kinds.append(String(gap[gap.index(gap.startIndex, offsetBy: notSavedPrefix.count)..<end]))
            } else {
                others.append(gap)
            }
        }
        var lines: [String] = []
        if !kinds.isEmpty {
            let named = kinds.enumerated().map { $0.offset == 0 ? $0.element : inSentence($0.element) }
            let joined = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
            lines.append("Not in your Cloud yet from this Mac: " + joined + ". " + triedAgain)
        }
        return lines + others
    }
    /// The summary's lines that still need drawing under the row (the saved-passwords sentence is said by
    /// `passwordLines`, never twice).
    static func hasSummary(_ overview: BackendCloudOverview?, changes: Int) -> Bool {
        guard let overview else { return false }
        return overview.notUsedHere || overview.later != nil || changes > 0
            || overview.notices.contains { NativeCloudOverviewSection.shownHere($0.action) }
            || NativeCloudOverviewSection.shownWaiting(overview).contains { $0.id != passwordsGapsID }
    }
    /// The details start OPEN only when one of them carries a button he must press (a file to review, a folder to
    /// choose, a device to trust again, Cloud not used here yet); plain information stays folded.
    static func startsOpen(_ overview: BackendCloudOverview?) -> Bool {
        guard let overview else { return false }
        if overview.notUsedHere { return true }
        if overview.notices.contains(where: { NativeCloudOverviewSection.shownHere($0.action) }) { return true }
        return NativeCloudOverviewSection.shownWaiting(overview).contains { $0.id != passwordsGapsID && $0.action != .none }
    }
    /// The Saved passwords row's one state: short while some are not in the Cloud, else the state's own words.
    static func passwordsState(_ page: BackendCloudSecretsPage) -> String {
        if case .protected = page.standing, !page.gaps.isEmpty { return passwordsShort }
        return BackendCloudSecretsWords.state(page)
    }
}

struct NativeCloudSettings: View {
    let model: NativeCloudAccount
    let secrets: NativeCloudSecrets
    let parts: NativeCloudFeatureParts
    /// Pictures: the details under the top row drawn open or folded (nil = as the state says).
    var fixtureDetailsOpen: Bool? = nil
    @Environment(\.deckSettingsOpen) private var openSettings
    /// His own press on the row's words; nil = as the state says (`NativeCloudCalm.startsOpen`).
    @State private var detailsOpen: Bool?
    init(model: NativeCloudAccount = .shared, secrets: NativeCloudSecrets = .shared, parts: NativeCloudFeatureParts = .shared,
         fixtureDetailsOpen: Bool? = nil) {
        self.model = model
        self.secrets = secrets
        self.parts = parts
        self.fixtureDetailsOpen = fixtureDetailsOpen
    }
    /// Review B-M4: the switch says both directions, like the question it changes.
    static let useCloudToggle = "Use Cloud on this Mac"
    static let useCloudNote = "On: this Mac's memory, projects, agents and boot files are added to your Cloud, and what is in your Cloud comes to this Mac. Off: this Mac's memory, projects, agents and boot files are not sent, and none arrive here. Nothing is deleted on either side."
    /// "How this Mac trusts your other devices" (owner, 13 Nov).
    static let trustModeTitle = "How this Mac trusts your other devices"
    static func trustModeLabel(_ mode: BackendCloudTrustMode) -> String {
        mode == .account ? "Automatically, with my account" : "Ask me for each new device"
    }
    static func trustModeNote(_ mode: BackendCloudTrustMode) -> String {
        mode == .account
            ? "Every device you sign in to with your account is trusted here by itself. If a device's identity changes later, its changes wait until you trust it again."
            : "A new device's changes wait until you trust it here. Before you trust one, compare its code on both devices."
    }
    static let devicesNote = "Your devices signed in to this account."
    /// Owner, 14 Nov: the dropdown became a switch. On = "Automatically, with my account"; off = "Ask me for each new device".
    static let trustSwitchTitle = "Trust my signed-in devices automatically"
    static func trustSwitchOn(_ mode: BackendCloudTrustMode) -> Bool { mode == .account }
    static func trustMode(switchOn: Bool) -> BackendCloudTrustMode { switchOn ? .account : .ask }
    /// Sync now is disabled only while this Mac really prepares its first copy (page-names lane: never once every
    /// change of it is prepared, n = m).
    static func syncNowWaits(_ snapshot: CloudAccountSnapshot) -> Bool { BackendCloudOverviewWords.preparingNow(snapshot.baseline) }
    /// The Devices list: judged as a whole first (the group's alarm), then without the devices Cloud reports as
    /// removed and without stale earlier entries of a device that signed in again (two-Mac proof, 13 Nov).
    static func shownDevices(_ rows: [CloudDeviceTrustRow]) -> [CloudDeviceTrustRow] {
        BackendCloudTrustRows.alarmed(rows).filter { !$0.removed && !$0.stale }
    }
    /// The status group's one line opens the side panel's Cloud page; "Manage files" opens the same page (its file
    /// manager), in the main window.
    static func openFiles(bin: Bool = false) {
        guard NativeCloudOffers.shows(.fileManager) else { return }
        if bin { NativeCloudContentsModel.shared.chooseShelf(kind: nil) }
        NativeLaunchWindow.ensureShown(front: true)
        AppModel.shared.select(Sidebar21Pages.cloudID)
    }
    static let manageFiles = "Manage files"
    static let review = "Review"
    /// The devices list lives on the Profile page (DESIGN.md section 2, group "Devices").
    static let devicesListID = "profile"
    /// The first group's line: while new devices wait and the line says something needs him, it says that in one line.
    static func statusLine(_ line: BackendCloudStatusLine, devices: String?) -> BackendCloudStatusLine {
        guard let devices, line.kind == .needsYou || line.kind == .level || line.kind == .checking else { return line }
        return BackendCloudStatusLine(kind: .needsYou, text: devices, needs: [devices], canSyncNow: line.canSyncNow,
                                      levelAt: line.levelAt, opensBin: false)
    }
    /// The summary's lines that need him (a choice to make, a device's key that changed, a project without a folder, a
    /// file another device changed here). While nothing needs him the summary is not drawn: the status line says it.
    /// Exactly what the compact summary draws (15 Nov, lead): a "needs you" standing that is only new devices is the
    /// first group's "N new devices need a look" line, so no empty group is drawn under it.
    static func summaryNeedsHim(_ overview: BackendCloudOverview, changes: Int) -> Bool {
        overview.notUsedHere || overview.later != nil || changes > 0
            || overview.notices.contains { NativeCloudOverviewSection.shownHere($0.action) }
            || !NativeCloudOverviewSection.shownWaiting(overview).isEmpty
    }
    /// "Space used": the total only (never "of 5.37 GB"); the breakdown per kind is in its info popover.
    static func spaceTotal(_ space: BackendCloudSpace) -> String { BackendCloudSpace.size(space.total) }
    static func spaceBreakdown(_ space: BackendCloudSpace) -> String {
        space.parts.map { $0.title + ": " + BackendCloudSpace.size($0.bytes) }.joined(separator: "\n")
    }

    /// Owner, 15 Nov (DESIGN.md section 3): calm. The status with Sync now · Keep in sync on this Mac · Manage files ·
    /// Saved passwords · the phones' copy and Space used. Every explanation sits behind an info button. 18 Nov: what
    /// waits is ONE row at the top in plain words with its details folded under it; when nothing waits, nothing more.
    var body: some View {
        DeckSettingsScaffold(title: "Cloud") {
            let overview = NativeCloudOverview.current(model: model, secrets: secrets, parts: parts)
            // Owner, 15 Nov: the Cloud line and its Sync now left the side panel and live here, at the top. While Cloud
            // is paused here the one button is Resume (pausing stays with the cloud.sync tool and "Use Cloud on this Mac").
            if NativeCloudOffers.shows(.syncSwitches), NativeCloudDisplayGate.shared.shows || model.snapshot.phase != .signedOut {
                let line = NativeCloudStatusLineModel.shared.current()
                let preparing = Self.syncNowWaits(model.snapshot)
                // SW-1: new devices are ONE line here ("4 new devices need a look") with Review, which opens the devices
                // list (Profile); their sentences are never written out on this page.
                let devices = NativeCloudOverviewSection.devicesNeedALook(overview)
                let passwordLines = NativeCloudCalm.passwordLines(secrets.shown)
                let summary = NativeCloudCalm.hasSummary(overview, changes: parts.changes.count)
                let hasDetails = summary || !passwordLines.isEmpty
                let open = fixtureDetailsOpen ?? detailsOpen ?? NativeCloudCalm.startsOpen(overview)
                DeckSettingsGroup {
                    NativeCloudSettingsStatusRow(line: Self.statusLine(line, devices: devices),
                                                 words: NativeCloudCalm.headline(Self.statusLine(line, devices: devices), passwordGaps: !passwordLines.isEmpty),
                                                 detailsOpen: hasDetails ? open : nil, toggleDetails: { detailsOpen = !open },
                                                 open: { Self.openFiles(bin: line.opensBin) }) {
                        if devices != nil {
                            Button(Self.review) { openSettings(Self.devicesListID) }
                        }
                        if model.snapshot.phase == .paused {
                            Button("Resume") { model.change("resume") }
                        } else {
                            // Fetch what Cloud holds, then send what this Mac holds. While this Mac prepares its first
                            // copy, Sync now waits with it (disabled, the progress as its tooltip).
                            Button("Sync now") { model.change("now"); secrets.syncNow() }
                                .disabled(preparing)
                                .help(preparing ? BackendCloudOverviewWords.syncNowWhilePreparing(model.snapshot.baseline) : "")
                        }
                    }
                    .onAppear { NativeCloudStatusLineModel.shared.noted(line.kind) }
                    .onChange(of: line.kind) { _, kind in NativeCloudStatusLineModel.shared.noted(kind) }
                    // The details, folded under the row: what is not in the Cloud yet (one sentence) and only what
                    // needs him from the summary (never the per-kind "All saved" rows: the list below has the counts).
                    if hasDetails, open {
                        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                            ForEach(passwordLines, id: \.self) { text in
                                Text(text).font(DeckTokens.Typography.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let overview, summary {
                                NativeCloudOverviewSection(overview: overview, model: model, secrets: secrets, parts: parts, compact: true,
                                                           hiding: [NativeCloudCalm.passwordsGapsID])
                            }
                        }
                        .font(DeckSettingsLook.rowTitle)
                        // Under the words, not under the dot.
                        .padding(.leading, DeckSettingsLook.rowPadding + NativeCloudSettingsStatusRow<EmptyView>.dotSize + DeckTokens.Spacing.s8)
                        .padding(.trailing, DeckSettingsLook.rowPadding)
                        .padding(.vertical, DeckTokens.Spacing.s8 + 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // The summary carries the "can't reach Cloud" line; without a summary it is said here.
                    if let text = model.notice ?? (overview == nil ? model.snapshot.problem : nil) { DeckSettingsProblem(text: text, warn: false) }
                }
            }
            // Same everywhere (owner, 15 Nov): one switch per kind, all on by default, this Mac only; "Use Cloud on this
            // Mac" is the list's first row (off: nothing is sent or arrives, nothing is deleted).
            NativeCloudSyncChoicesSection(cloudOn: model.memoryIncluded != false, useCloud: Binding(get: { model.memoryIncluded != false },
                                                                                                    // Review S-B4: the Cloud switch is a guarded page press.
                                                                                                    set: { value in
                                                                                                        NativeCloudSheetGuard.shared.pagePress(model: model) { NativeCloudBrainRegistration.setMemoryIncluded(value) }
                                                                                                    }))
            DeckSettingsGroup {
                DeckSettingsLinkRow(title: Self.manageFiles, symbol: "folder.fill", tint: .blue) { NativeCloudContentsModel.openFileManager() }
            }
            // Saved passwords (lean scope item 3): present only while this identity's saved passwords are wired.
            NativeCloudSecretsSection(model: secrets)
            if NativeCloudOffers.shows(.phonesCopy) {
            DeckSettingsGroup {
                // Mac shelf (owner, 15 Nov): ON by default. Off empties what the Cloud keeps for the phones and stops.
                DeckSettingsToggleRow(NativeCloudShelf.switchTitle, info: NativeCloudShelf.switchInfo,
                                      isOn: Binding(get: { NativeCloudShelf.shared.on }, set: { on in
                                          NativeCloudSheetGuard.shared.pagePress(model: model) { NativeCloudShelf.shared.setOn(on) }
                                      }))
                    .disabled(!NativeCloudShelf.shared.attached)
                // Status-line lane (owner, 14 Nov): space used, from the one source both Cloud pages read.
                if let space = NativeCloudPageCounts.shared.counts?.space, space.total > 0 || !space.parts.isEmpty {
                    DeckSettingsRow(BackendCloudSpace.title, info: Self.spaceBreakdown(space), state: Self.spaceTotal(space))
                }
            }
            }
        }
        .onAppear { model.pageShown(true); model.refreshDevices(); NativeCloudBrainRegistration.pageOpened(); secrets.reload(fresh: "opened Cloud page"); NativeCloudRecords.shared.refresh() }
        .onDisappear { model.pageShown(false) }
        // Page-names lane: the page's numbers come from the one source the Your Cloud window reads too.
        .task {
            while !Task.isCancelled {
                await NativeCloudPageCounts.shared.refresh(snapshot: model.snapshot)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView().controlSize(.small) } }
    }
}

/// One device on the Cloud page (owner, 13 Nov): its name, when it was added, when it was last seen, and a plain
/// state. Trust… only in "Ask me for each new device", for a new device.
struct NativeCloudDevicePlainRow: View {
    let row: CloudDeviceTrustRow
    let lastSeen: Int64?
    /// When the service says the device was added (else when this Mac first trusted it).
    let added: Int64?
    let askMode: Bool
    let trust: @MainActor () -> Void
    init(row: CloudDeviceTrustRow, lastSeen: Int64?, added: Int64? = nil, askMode: Bool, trust: @escaping @MainActor () -> Void) {
        self.row = row
        self.lastSeen = lastSeen
        self.added = added ?? row.addedAt
        self.askMode = askMode
        self.trust = trust
    }
    /// The service's entry for a row: by id, else by its plain name (real check 4: the other Mac's row showed no dates
    /// at all, only "Trusted").
    static func device(for row: CloudDeviceTrustRow, in devices: [CloudDevice]) -> CloudDevice? {
        devices.first { $0.deviceId == row.deviceId } ?? devices.first { BackendCloudTrustRows.plainName($0.shownName) == row.name || BackendCloudTrustRows.plainName($0.label) == row.name }
    }
    /// Page-names 3: the same "last seen" as the Your Cloud cards: the newest of the service's check-in and the time it
    /// reported receiving the device's last read (`lastPulledAt`). nil when the service reported neither.
    static func lastSeen(_ device: CloudDevice?) -> Int64? {
        guard let device else { return nil }
        let at = max(device.lastSeenAt, device.lastPulledAt ?? 0)
        return at > 0 ? at : nil
    }
    /// "Added 13 Nov 2026 · Last seen Today, 3:35 PM" for every device alike.
    static func dates(added: Int64?, lastSeen: Int64?, now: Date = Date()) -> String {
        var parts: [String] = []
        if let added, added > 0 { parts.append("Added " + NativeCloudTrustWords.day(added)) }
        if let lastSeen, lastSeen > 0 { parts.append(BackendCloudPageWords.lastSeen(lastSeen, now: now)) }
        return parts.joined(separator: " · ")
    }
    /// The word on the right. "This Mac" for this device. Page-names 3: "Trusted" only under the stricter setting ("Ask
    /// me for each new device"); with automatic trust every one of his devices is trusted, so it says nothing.
    static func state(_ row: CloudDeviceTrustRow, askMode: Bool) -> String {
        switch row.standing {
        case .thisMac: return "This Mac"
        case .trusted: return row.keyChanged ? "Waiting for you" : (askMode ? "Trusted" : "")
        case .new: return row.removed ? "Removed" : (askMode ? "New device" : "Not trusted on this Mac")
        }
    }
    /// The row as one line to read (and as the testers read it): name, dates, state.
    static func spoken(_ row: CloudDeviceTrustRow, added: Int64?, lastSeen: Int64?, askMode: Bool, now: Date = Date()) -> String {
        [row.name, dates(added: added, lastSeen: lastSeen, now: now), state(row, askMode: askMode)].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                Text(row.name).lineLimit(1)
                let dates = Self.dates(added: added, lastSeen: lastSeen)
                if !dates.isEmpty { Text(dates).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary) }
            }
            Spacer(minLength: DeckTokens.Spacing.s12)
            let state = Self.state(row, askMode: askMode)
            if !state.isEmpty { Text(state).foregroundStyle(DeckTokens.textSecondary) }
            if askMode, row.standing == .new { Button("Trust…", action: trust).disabled(!row.canBeTrusted) }
        }
    }
}

/// Settings → Cloud: the full Cloud page while Cloud is open for this account, otherwise the small Sign in page.
struct NativeCloudPage: View {
    var model: NativeCloudAccount = .shared
    var body: some View {
        Group {
            if NativeCloudOffers.shows(.settingsCloud) {
        if model.visible { NativeCloudSettings(model: model) } else { NativeCloudSignInPage(model: model) }
            }
        }
    }
}

/// One plain sentence and one button. Showing it reads only what the model already holds: nothing of Cloud is
/// built, requested or stored until the button is pressed.
struct NativeCloudSignInPage: View {
    let model: NativeCloudAccount
    nonisolated static let signedOutLine = "Sign in with your Terminal Deck account to keep your work on all your devices."
    nonisolated static func notOpen(_ name: String?) -> String {
        if let name, !name.isEmpty { return "You are signed in as \(name). Cloud is not open for this account yet." }
        return "You are signed in, but Cloud is not open for this account yet."
    }
    nonisolated static func reaching(_ name: String) -> String {
        "You are signed in\(name.isEmpty ? "" : " as \(name)"). Your work is kept on this Mac; Cloud connects again by itself."
    }
    static func content(_ stage: NativeCloudAccount.SignInStage) -> (line: String, button: String, enabled: Bool) {
        switch stage {
        case .signedOut(let waiting): (signedOutLine, waiting ? "Signing in…" : "Sign in", !waiting)
        case .notOpen(let name): (notOpen(name), "Sign out", true)
        case .unchecked: (notOpen(nil), "Check again", true)
        case .reaching(let name): (reaching(name), "Check again", true)
        }
    }
    var body: some View {
        let stage = model.signInStage
        let content = Self.content(stage)
        DeckSettingsScaffold(title: "Cloud") {
            DeckSettingsGroup {
                HStack(spacing: DeckTokens.Spacing.s12) {
                    Text(content.line).font(DeckSettingsLook.rowTitle).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DeckTokens.Spacing.s8)
                    Button(content.button) {
                        if case .notOpen = stage { Task { await model.pressSignOut() } }
                        else if case .reaching = stage { model.pressCheckAgain() }
                        else { model.pressSignIn() }
                    }
                    .disabled(!content.enabled || model.busy)
                }
                .padding(DeckSettingsLook.rowPadding)
                if let text = model.notice ?? (stage == .signedOut(waiting: false) || stage == .reaching(name: model.snapshot.displayName ?? "")
                                               ? model.snapshot.problem : nil) {
                    DeckSettingsProblem(text: text, warn: false)
                }
            }
        }
    }
}
