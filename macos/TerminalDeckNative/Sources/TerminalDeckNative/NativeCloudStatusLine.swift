import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The one Cloud status line (owner, 14 Nov). It lives in the side panel's bottom bar, above his profile and the gear:
/// the place the window frame already has on every page. One state in plain words (`BackendCloudStatusLineBuilder`)
/// and one "Sync now". A click on the line opens the side panel's Cloud page; nothing else.
@MainActor @Observable
final class NativeCloudStatusLineModel {
    static let shared = NativeCloudStatusLineModel()
    /// When this Mac last saw everything level: set when the line becomes level and when a pass ends level.
    private(set) var levelAt: Date?
    /// The memory question that waits for "They are gone" / "Keep them" (pointed to, never answered here).
    private(set) var memoryAnswer: DeckMemoryAnswer?
    private(set) var binGroups: [CloudBinGroup] = []
    /// Lane L3 slice 1 (merge): the Cloud folder's question, read with memory's.
    private(set) var folderAnswer: CloudFolderAnswer?
    /// Lane L3 slice 2: the artifacts' question, read with the Cloud folder's.
    private(set) var artifactsAnswer: CloudFolderAnswer?
    /// Review fix 3: the memory question was read once since start-up (before any "Everything is…").
    private(set) var memoryChecked = false
    @ObservationIgnored private var memoryTries = 0
    @ObservationIgnored private var binReadAt: Date?
    @ObservationIgnored let account: NativeCloudAccount
    init(account: NativeCloudAccount = .shared) { self.account = account }

    func input(overview: BackendCloudOverview?) -> BackendCloudStatusLineInput {
        let stage = account.signInStage
        var saved = false
        // Review fix 1: a saved sign-in not checked yet counts as saved (no "Signed out" flash at launch).
        switch stage {
        case .reaching, .unchecked: saved = true
        default: break
        }
        var made = BackendCloudStatusLineInput(snapshot: account.snapshot, savedSignIn: saved, online: account.online, overview: overview,
                                               memoryAnswer: memoryAnswer, syncingNow: account.syncingNow,
                                               progressRead: account.progressRead, levelAt: levelAt)
        made.memoryChecked = memoryChecked
        made.folderAnswer = folderAnswer
        made.artifactsAnswer = artifactsAnswer
        made.binGroups = binGroups
        // Open files (15 Nov): "Sending your files so your phones can open them: 12 of 80" while they go up.
        if let files = NativeCloudShelf.shared.filesProgress { made.shelfFilesDone = files.done; made.shelfFilesTotal = files.total }
        return made
    }
    /// The line now, from the same summary Settings → Cloud shows.
    func current() -> BackendCloudStatusLine {
        BackendCloudStatusLineBuilder.build(input(overview: NativeCloudOverview.current(model: account)))
    }
    /// The line's state changed (or a pass ended): a level state is stamped with the time it was seen level.
    func noted(_ kind: BackendCloudStatusLine.Kind, now: Date = Date()) {
        if kind == .level { levelAt = now } else if kind == .signedOut { levelAt = nil }
        // Review fix 2: while it says "Everything is…", this Mac's queue is re-read every 10 seconds (no notice exists).
        account.lineSays(level: kind == .level)
    }
    /// The memory store's own small read (two counts and a name), never the page's full read.
    func readMemoryAnswer() async {
        memoryTries += 1
        // This keeps the existing status refresh cadence; no delete question is read or answered.
        memoryAnswer = nil; folderAnswer = nil; artifactsAnswer = nil
        // Only for "<N> removed by an AI tonight · Bin": the Bin groups alone, at most once a minute (the line itself
        // refreshes every 10 seconds; the owners' Bin reads are not needed that often).
        if binReadAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true, let groups = await NativeCloudDeleteOwners.binGroups() {
            binReadAt = Date()
            if binGroups != groups { binGroups = groups }
        }
        if !memoryChecked { memoryChecked = true }
    }
    #if DEBUG
    func fixture(memoryAnswer: DeckMemoryAnswer?, levelAt: Date?, memoryChecked: Bool = true) {
        self.memoryAnswer = memoryAnswer; self.levelAt = levelAt; self.memoryChecked = memoryChecked
    }
    #endif
    /// `cloud.status`: the line and the space per kind, exactly as on screen.
    func wire() -> NativeRPCValue {
        let space = BackendCloudSpace.make(account.snapshot, bytesLeft: account.storageLeft)
        return .object([.init("statusLine", current().wireValue), .init("space", space.wireValue)])
    }
}

/// The line as drawn: the bottom bar's own row style (`DeckSidebarRowStyle`, 13 pt, an 18 pt symbol column, the same
/// as "A page is waiting for you") and the gear's own icon button style for "Sync now". Pictures draw this directly.
struct SidebarCloudStatusLine: View {
    let line: BackendCloudStatusLine
    let syncing: Bool
    let open: () -> Void
    let syncNow: () -> Void

    static func symbol(_ kind: BackendCloudStatusLine.Kind) -> String {
        switch kind {
        case .level: return "checkmark.circle.fill"
        case .sending, .getting, .checking, .signingIn: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .signedOut: return "icloud.slash"
        case .needsYou: return "exclamationmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle"
        case .off: return "minus.circle"
        }
    }
    static func tint(_ kind: BackendCloudStatusLine.Kind) -> Color {
        switch kind {
        case .level: return DeckTokens.good
        case .needsYou, .problem: return DeckTokens.warn
        default: return DeckTokens.textSecondary
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(line.kind)).font(.caption).foregroundStyle(Self.tint(line.kind)).frame(width: 18)
                        .accessibilityHidden(true)
                    Text(line.text).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle([.needsYou, .problem].contains(line.kind) ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(DeckSidebarRowStyle())
            .help(line.text)
            .accessibilityLabel(line.text)
            .accessibilityHint(line.opensBin ? "Opens the Bin" : "Opens Cloud")
            if line.canSyncNow || syncing {
                Button(action: syncNow) {
                    Group {
                        if syncing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(DeckSidebarIconStyle()).fixedSize()
                .help(BackendCloudStatusLineWords.syncNow).accessibilityLabel(BackendCloudStatusLineWords.syncNow)
                .disabled(syncing)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
}

/// Same everywhere (15 Nov): the line left the side panel ("Just keep it inside the settings. Inside the cloud section"),
/// but what kept it current stays, drawing nothing: the queue re-read while level, the time it was last level, and the
/// memory question read every 10 seconds, so the Cloud item's mark and Settings › Cloud say the same as before.
struct NativeCloudStatusWatch: View {
    var account = NativeCloudAccount.shared
    var model = NativeCloudStatusLineModel.shared
    /// The Cloud item's existing small mark (`StatusMark`): only signed out, something needs him, or a real problem.
    static func mark(_ line: BackendCloudStatusLine) -> (status: String, help: String)? {
        switch line.kind {
        case .signedOut, .needsYou: return ("attention", line.text)
        case .problem: return ("failed", line.text)
        default: return nil
        }
    }
    var body: some View {
        if NativeCloudOffers.shows(.syncSwitches), NativeCloudDisplayGate.shared.shows || account.snapshot.phase != .signedOut {
            let kind = model.current().kind
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
                .onAppear { account.lineShown(true); model.noted(kind) }
                .onDisappear { account.lineShown(false) }
                .onChange(of: kind) { _, next in model.noted(next) }
                .onChange(of: account.syncingNow) { _, running in if !running { model.noted(model.current().kind) } }
                .task {
                    while !Task.isCancelled {
                        await model.readMemoryAnswer()
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
        }
    }
}

/// The line as Settings › Cloud shows it at its top (15 Nov), calm since 18 Nov (owner: "It is still showing the yellow
/// one. Why? ... See all of this"; DESIGN-settings 5): ONE row, a coloured dot and the state in plain words in ordinary
/// ink (never orange text, never "Something needs you: …"), the page's own button beside it (`buttons`). When there is
/// more to read, a small chevron follows the words and a press on them opens the details in place, under the row.
struct NativeCloudSettingsStatusRow<Buttons: View>: View {
    let line: BackendCloudStatusLine
    /// The row's words; nil = the line's own text.
    var words: String? = nil
    /// nil = nothing more to read; else whether the details under the row are open now.
    var detailsOpen: Bool? = nil
    var toggleDetails: () -> Void = {}
    let open: () -> Void
    @ViewBuilder let buttons: () -> Buttons
    static var dotSize: CGFloat { 8 }

    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            if detailsOpen != nil {
                Button(action: toggleDetails) { label.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(words ?? line.text)
                    .accessibilityHint(detailsOpen == true ? "Hides the details" : "Shows the details")
            } else if line.opensBin {
                // "N removed by an AI tonight · Bin": the words still open the Bin.
                Button(action: open) { label.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(words ?? line.text)
                    .accessibilityHint("Opens the Bin")
            } else {
                label.accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            buttons()
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            Circle().fill(SidebarCloudStatusLine.tint(line.kind)).frame(width: Self.dotSize, height: Self.dotSize).accessibilityHidden(true)
            Text(words ?? line.text).font(DeckSettingsLook.rowTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color.primary)
            if let detailsOpen {
                Image(systemName: detailsOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor)).accessibilityHidden(true)
            }
        }
    }
}

/// The live line in the bottom bar. Absent where this copy of the app cannot use Cloud at all.
/// (15 Nov: no longer placed in the side panel; kept for the pictures of its states.)
struct SidebarCloudStatus: View {
    var account = NativeCloudAccount.shared
    var model = NativeCloudStatusLineModel.shared
    let open: () -> Void
    var body: some View {
        if NativeCloudOffers.shows(.syncSwitches), NativeCloudDisplayGate.shared.shows || account.snapshot.phase != .signedOut {
            let line = model.current()
            SidebarCloudStatusLine(line: line, syncing: account.syncingNow, open: {
                if line.opensBin { NativeCloudContentsModel.shared.chooseShelf(kind: nil) }
                open()
            }, syncNow: { account.syncNow() })
                .padding(.top, 4)
                .onAppear { account.lineShown(true); model.noted(line.kind) }
                .onDisappear { account.lineShown(false) }
                .onChange(of: line.kind) { _, kind in model.noted(kind) }
                // A pass that ends level is a fresh "level" time.
                .onChange(of: account.syncingNow) { _, running in if !running { model.noted(model.current().kind) } }
                .task {
                    while !Task.isCancelled {
                        await model.readMemoryAnswer()
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
        }
    }
}

/// The line's short form in the main window's toolbar, ONLY while the side panel (and so its bottom bar) is hidden:
/// the Cloud mark, plain when everything is on his other devices, with one or two words beside it otherwise. The
/// toolbar's own borderless 28 pt button (as "Move to new window"). A click opens the side panel's Cloud page.
struct NativeCloudStatusShort: View {
    let line: BackendCloudStatusLine
    let open: () -> Void
    /// Hidden = the system collapse button chose detail only, or the page starts at the window's left edge (a narrow
    /// window collapsed the panel by itself).
    static func panelHidden(_ visibility: NavigationSplitViewVisibility, detailMinX: CGFloat) -> Bool {
        visibility == .detailOnly || detailMinX < 40
    }
    static func symbol(_ kind: BackendCloudStatusLine.Kind) -> String {
        switch kind {
        case .offline, .signedOut: return "icloud.slash"
        case .needsYou, .problem: return "exclamationmark.icloud"
        default: return "icloud"
        }
    }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(line.kind)).font(.system(size: 14))
                    .foregroundStyle(SidebarCloudStatusLine.tint(line.kind) == DeckTokens.good ? DeckTokens.textSecondary : SidebarCloudStatusLine.tint(line.kind))
                if let words = BackendCloudStatusLineWords.short(line.kind) { Text(words).font(.system(size: 12)).foregroundStyle(DeckTokens.textSecondary) }
            }
            .frame(minWidth: 28, minHeight: 28).contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(line.text)
        .accessibilityLabel(line.text)
        .accessibilityHint(line.opensBin ? "Opens the Bin" : "Opens Cloud")
    }
}

/// The live short form (absent where this copy cannot use Cloud).
struct NativeCloudStatusShortLive: View {
    var account = NativeCloudAccount.shared
    var model = NativeCloudStatusLineModel.shared
    let open: () -> Void
    var body: some View {
        if NativeCloudOffers.shows(.syncSwitches), NativeCloudDisplayGate.shared.shows || account.snapshot.phase != .signedOut {
            NativeCloudStatusShort(line: model.current(), open: {
                if model.current().opensBin { NativeCloudContentsModel.shared.chooseShelf(kind: nil) }
                open()
            })
        }
    }
}

/// Space used per kind, plain numbers (no chart), under the kinds of the side panel's Cloud page.
struct NativeCloudSpaceList: View {
    let space: BackendCloudSpace
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(BackendCloudSpace.title).foregroundStyle(DeckTokens.textSecondary)
                .padding(.bottom, 2)
            ForEach(space.parts) { part in
                HStack {
                    Text(part.title)
                    Spacer(minLength: DeckTokens.Spacing.s8)
                    Text(BackendCloudSpace.size(part.bytes)).monospacedDigit()
                }
                .foregroundStyle(DeckTokens.textSecondary)
            }
            Text(space.totalLine).monospacedDigit().foregroundStyle(DeckTokens.textPrimary)
                .padding(.top, 2)
        }
        .font(DeckTokens.Typography.callout)
        .padding(.horizontal, DeckTokens.Spacing.s8)
        .padding(.bottom, DeckTokens.Spacing.s8)
        .accessibilityElement(children: .combine)
    }
}
