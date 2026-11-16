import SwiftUI
import TerminalDeckNativeCore

/// 15 Nov (Asad's recording, items 17-20): Hoot's account and model lists are the New session page's own lists, read
/// through the same call (`NativePhoneStart.newSessionLists`, which fills the models with `NativeLandingModels`), so
/// every account (API-key accounts included) and every model of the chosen AI shows, by name, exactly as there.
/// Read when the Hoot page (or the island) opens, so nothing waits after a click.
@MainActor @Observable
final class HootSharedLists {
    typealias Load = @MainActor () async -> NativeRPCValue
    static let shared = HootSharedLists()
    /// The New session page's lists (nil until the first read).
    private(set) var value: NativeRPCValue?
    @ObservationIgnored private let read: Load
    @ObservationIgnored private var reading = false
    init(read: @escaping Load = {
        await NativePhoneStart.newSessionLists(folder: nil, invoke: { channel, args in
            try await EngineBridge.shared.invokeNativeValue(channel, args)
        })
    }) { self.read = read }
    /// A fixed copy (pictures and tests).
    init(fixture: NativeRPCValue) { value = fixture; read = { fixture } }

    func load() {
        guard !reading else { return }
        reading = true
        Task {
            defer { reading = false }
            let next = await read()
            if next["providers"].elements != nil || next["accounts"].elements != nil { value = next }
        }
    }

    /// The AIs Hoot can run on, in the page's order (never Shell: Hoot is an AI).
    var ais: [(id: String, name: String)] {
        (value?["providers"].elements ?? []).compactMap { row in
            guard let id = row["id"].string, ["claude", "codex", "gemini"].contains(id) else { return nil }
            return (id, row["name"].string ?? NativePhoneStart.name(id))
        }
    }
    /// Every account of one AI, as the page lists them (signed-in logins and API-key accounts alike).
    func accounts(_ provider: String) -> [(id: String, name: String)] {
        (value?["accounts"].elements ?? []).compactMap { row in
            guard let id = row["id"].string, (row["provider"].string ?? "claude") == provider else { return nil }
            return (id, row["name"].string ?? id)
        }
    }
    /// The account menu's groups, exactly as the New session page builds them: each AI with its logins by name (e-mail
    /// and state kept for the menu's rules). Hoot never runs on Shell, so only AIs.
    var menuGroups: [NewSessionAccountGroup] {
        ais.map { ai in
            let rows = (value?["accounts"].elements ?? []).filter { ($0["provider"].string ?? "claude") == ai.id }
            return NewSessionAccountGroup(provider: ai.id, name: ai.name, accounts: rows.compactMap { row in
                guard let id = row["id"].string else { return nil }
                return NativeLandingModel.Account(id: id, name: row["name"].string ?? id, provider: ai.id, email: row["email"].string,
                                                  state: NativeLandingModel.Account.State(rawValue: row["state"].string ?? "") ?? .unknown)
            })
        }
    }
    /// The chosen AI's models, by name, as the page offers them.
    func models(_ provider: String) -> [(id: String, name: String)] {
        let row = (value?["providers"].elements ?? []).first { $0["id"].string == provider }
        return (row?["models"].elements ?? []).compactMap { model in
            model["id"].string.map { ($0, model["name"].string ?? $0) }
        }
    }

    /// Hoot's box with the page's model list for the AI in use; everything else (efforts, Fast mode, the alias a saved
    /// choice stands for) stays the chat's own. With no list read yet, the chat's own list stays.
    func catalogue(base: HootComposerCatalogue, modelID: String) -> HootComposerCatalogue {
        let provider = modelID.split(separator: ":").first.map(String.init) ?? "claude"
        let list = models(provider)
        guard !list.isEmpty else { return base }
        var next = base
        let name = ais.first { $0.id == provider }?.name ?? NativePhoneStart.name(provider)
        var rows = list.map { HootComposerModel(id: provider + ":" + $0.id, provider: name, name: $0.name) }
        // The model Hoot uses now always shows, by its real name when the chat knows it.
        if !rows.contains(where: { base.isChosen($0, savedID: modelID) }),
           let known = (base.featured + base.more).first(where: { base.isChosen($0, savedID: modelID) }) {
            rows.insert(known, at: 0)
        }
        let fast = base.sections.first { $0.id == provider }?.fastMode
        next.sections = [HootModelSection(id: provider, name: name, featured: rows, more: [], fastMode: fast)]
        return next
    }
}

/// Hoot's account, where the New session page has its account: in the bar's second line, after a dot. The same chip
/// label (`AccountChipLabel`) and the same menu (`NewSessionAccountMenu`) as the page's account list; picking an
/// account of another AI switches Hoot to that AI (the chat carries on). Names, never e-mail addresses or ids.
struct HootAccountChip: View {
    @Bindable var brain: ROUTINESHootBrainModel
    var lists: HootSharedLists = .shared
    var live = true
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            AccountChipLabel {
                NativeCodingAIProviderMark(provider: brain.chosenProvider, size: 13)
                Text(chipName).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        // Until Hoot's choices are read, nothing (never a wrong value that then changes).
        .opacity(brain.loaded ? 1 : 0).disabled(!brain.loaded)
        .help("The account Hoot uses")
        .accessibilityLabel("Hoot's account: " + chipName)
        .accessibilityIdentifier("hoot.account")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HootAccountList(brain: brain, lists: lists, live: live) { open = false }
        }
        .task(id: EngineBridge.shared.isReady) { if live { await NativeChatAccountNames.shared.start() } }
    }

    private var chipName: String {
        // The page's own name for it first (API-key accounts included), then Hoot's.
        let listed = lists.accounts(brain.chosenProvider).first { $0.id == brain.currentAccountID }?.name
        return HootAccountNames.name(brain.currentAccountID, fallback: listed ?? brain.currentAccountName, provider: brain.chosenProvider, live: live)
    }
}

enum HootAccountNames {
    /// The account's name as every chip shows it; an e-mail address becomes the part before the @.
    @MainActor static func name(_ id: String, fallback: String, provider: String, live: Bool) -> String {
        let label = live ? NativeChatAccountNames.shared.label(id, fallback: fallback, provider: provider) : fallback
        if let at = label.firstIndex(of: "@"), CodingAILogins.normalizedEmail(label) != nil { return String(label[..<at]) }
        return label
    }
}

/// The chip's list: each AI's name, then its accounts (the one Hoot uses ticked), then Add account.
struct HootAccountList: View {
    @Bindable var brain: ROUTINESHootBrainModel
    var lists: HootSharedLists = .shared
    var live = true
    var close: () -> Void = {}

    /// 15 Nov (DESIGN-FIXES H-5): the New session page's own menu (`NewSessionAccountMenu`): the AI's mark once in the
    /// group title, rows = the account's name only, a check mark for the chosen one, an orange dot only where it needs him.
    var body: some View {
        NewSessionAccountMenu(groups: lists.menuGroups, chosenProvider: brain.chosenProvider, chosenAccount: brain.currentAccountID,
                              pick: { provider, account in
                                  if let account { brain.selectAccount(account, provider: provider) }
                                  else if provider != brain.chosenProvider { brain.selectProvider(provider) }
                              },
                              addAccount: { if live { NativeAccountSwitcher.addAccount(provider: brain.chosenProvider) } },
                              close: close)
        .accessibilityIdentifier("hoot.account.list")
    }
}
