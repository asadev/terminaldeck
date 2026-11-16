import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The New session page IS the chat window with no session yet (Owner, 14 Nov: "it should be looking like all other
/// chat windows ... the rest should be exactly the same"). It draws through the chat's own views: the session bar's
/// frame (`NativeSessionBarFrame`, the title, "where and who" under it), the chat's frame (`NativeChatFrame`) and its box
/// and the quiet line under it (`HootComposer`, `.box` and `.meta`). A later change to the chat window changes this page.
///
/// 15 Nov review (items 4-13, the lead's DESIGN.md section 7): calm and empty above the box (no mark, no sentence: the
/// box's own placeholder says what to do); the line under the heading is [project] · [account]; Chat | Terminal is the
/// standard segmented control on the heading's line at the right edge; the three pills under the box (permission, model,
/// effort) open the same small menus. The basics only: project (last used, else Independent), Choose folder…, Choose
/// agent (the lead by default), account (by name; Add account), Chat or Terminal.
struct NativeLandingPage: View {
    @Bindable var model: NativeLandingModel
    var focus: NativeLandingFocus = .shared
    /// Pictures and checks: no microphone lookup (the chat's own pictures do the same).
    var fixture = false

    var body: some View {
        VStack(spacing: 0) {
            NativeLandingBar(model: model)
            NativeChatFrame(compact: false) {
                EmptyView()
            } transcript: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Owner, 15 Nov: "we don't need to show this actually. Just need to keep it maybe empty".
                        Color.clear.frame(height: 1).accessibilityHidden(true)
                        if let problem = model.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("landing.problem")
                        }
                    }
                    // The open chat's own column, insets and placement (at the bottom, right above the box).
                    .modifier(NativeChatColumnInsets(compact: false))
                }
                .modifier(NativeChatScrollPlacement())
                .scrollEdgeEffectHidden(true, for: .all)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [DeckTokens.chatPage, DeckTokens.chatPage.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16).allowsHitTesting(false).accessibilityHidden(true)
                }
            } box: {
                composer(.box)
            } meta: {
                composer(.meta)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DeckTokens.chatBody)
        }
        .background(DeckTokens.chatPage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("landing.page")
    }

    private func composer(_ part: HootComposerPart) -> some View {
        let ticket = focus.ticket // read here: a new ticket draws the box again, which then claims the keyboard once
        return HootComposer(draft: Binding(get: { model.composerDraft }, set: { model.takeFromBox($0) }),
                            ownerID: NativeLanding.pageID, focusWhenShown: false, catalogue: model.composerCatalogue,
                            showMeta: true, part: part, busy: false, allowsSteering: false, enabled: true,
                            placeholder: "Message \(model.aiName)", agentName: model.aiName, plainMeta: true,
                            microphoneAvailable: fixture ? false : nil,
                            onSend: { model.sendFromBox($0) }, onStop: {},
                            onPermissionChange: { model.choosePermission($0) },
                            onModelChange: { model.chooseComposerModel($0) },
                            onEffortChange: { model.chooseEffort($0) },
                            attachmentLimits: model.attachmentLimits,
                            canStop: false, stopping: model.sending,
                            keyboardClaim: part == .box ? HootComposerKeyboardClaim(ticket: ticket, take: { focus.take() }) : nil,
                            boxIdentifier: part == .box ? "landing.box" : nil,
                            showsPermission: model.hasPermissionModes,
                            fixedMeta: model.agentRuns.map { (text: $0, help: model.agentRunsHelp ?? "") },
                            sendAllowed: { model.canSend(with: $0) },
                            fixedPermissionHelp: model.permissionFixedHelp,
                            permissionModes: model.permissionModes,
                            confirmsRiskyPermission: false)
    }
}

/// The bar of the New session page: the open session's bar (`NativeSessionBarFrame`) with "New session" as its name,
/// the Chat | Terminal switch on the same line at the right edge, and under the name [project] · [account].
struct NativeLandingBar: View {
    @Bindable var model: NativeLandingModel

    var body: some View {
        NativeSessionBarFrame {
            EmptyView()
        } title: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The open session's title, at its height (its renamable form keeps 28 pt).
                NativeSessionTitle(title: "New session", rename: nil).frame(minHeight: 28, alignment: .leading)
                Spacer(minLength: 8)
                if model.canChat { NewSessionOpenAsControl(chat: Binding(get: { model.chat }, set: { model.chooseChat($0) })) }
            }
        } place: {
            NativeLandingPlaceMenu(model: model)
            ChipSeparator()
            NativeLandingAccountChip(model: model)
        } trailing: {
            EmptyView()
        }
    }
}

/// Chat or Terminal: the app's standard segmented control at the standard size (15 Nov review item 9). Shared with Hoot's
/// lane by name.
struct NewSessionOpenAsControl: View {
    @Binding var chat: Bool

    var body: some View {
        Picker("Open as", selection: $chat) {
            Text("Chat").tag(true)
            Text("Terminal").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.regular).fixedSize()
        .help("Open this session as a chat, or as the AI's own terminal")
        .accessibilityLabel("Open as")
        .accessibilityIdentifier("landing.mode")
    }
}

/// Where the session starts, in the place an open chat's bar names its folder: the project's picture and name (and the
/// agent when he chose one other than the lead). Its menu holds ONLY (Owner, 15 Nov: "it should just give me projects
/// ... Instead, we can have a choose folder here. That's it." and "a plus button of choose agent"): his projects (the
/// chosen one ticked), "Choose folder…", and one line "Choose agent" that opens the chosen project's agents (the lead is
/// chosen by default, so nobody has to). No "No project", no "No agent", no "All choices…".
struct NativeLandingPlaceMenu: View {
    @Bindable var model: NativeLandingModel

    var body: some View {
        Menu {
            ForEach(model.registeredProjects) { project in
                Toggle(project.name, isOn: Binding(get: { model.folder != nil && model.projectID == project.id },
                                                   set: { _ in model.chooseProject(project) }))
            }
            if !model.registeredProjects.isEmpty { Divider() }
            Button("Choose folder\u{2026}") { model.browse() }
            if !model.agents.isEmpty {
                Menu("Choose agent") {
                    ForEach(model.agents) { agent in
                        Toggle(agent.lead ? agent.name + " (lead)" : agent.name,
                               isOn: Binding(get: { model.agentID == agent.id }, set: { _ in model.chooseAgent(agent.id) }))
                    }
                }
                .accessibilityIdentifier("landing.place.agent")
            }
        } label: {
            AccountChipLabel {
                Image(nsImage: projectImage).resizable().scaledToFit().frame(width: 13, height: 13)
                Text(placeName).foregroundStyle(.primary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.folder.map { "Starts in " + SessionFolder.shown($0, assistant: false) } ?? "Starts in Terminal Deck's Independent folder")
        .accessibilityLabel("Project: " + placeName)
        .accessibilityIdentifier("landing.place")
    }

    /// The project (or "Independent"), and the agent only when it is not the project's lead (the lead is the default).
    var placeName: String {
        let project = model.folder == nil ? "Independent" : model.projectName
        guard let agent = model.chosenAgent, !agent.lead else { return project }
        let role = agent.name.hasPrefix(project + " \u{00B7} ") ? String(agent.name.dropFirst(project.count + 3)) : agent.name
        return project + " \u{00B7} " + role
    }

    private var projectImage: NSImage {
        if let project = model.project { return DeckRowIcon.project(project) }
        if let folder = model.folder { return DeckRowIcon.project(folder: folder) }
        return DeckRowIcon.independent
    }
}

/// The AI and its account, in the open chat's account chip. Picking another AI's account changes the AI, as it hands
/// an open chat to that AI.
struct NativeLandingAccountChip: View {
    @Bindable var model: NativeLandingModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            AccountChipLabel {
                NativeCodingAIProviderMark(provider: model.chosenProvider, size: 13)
                Text(chipName).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .help("The AI and the account this session starts with")
        .accessibilityLabel("AI and account: " + model.aiName + (model.providerAccounts.isEmpty ? "" : ", " + model.accountName))
        .accessibilityIdentifier("landing.account")
        .popover(isPresented: $open, arrowEdge: .bottom) { NativeLandingAccountList(model: model) { open = false } }
    }

    /// The account's name, as an open chat's chip shows it; the AI's own name when it has no accounts.
    private var chipName: String { model.providerAccounts.isEmpty ? model.aiName : model.accountName }
}

/// The account chip's list for the page (drawn on its own for the pictures): the shared `NewSessionAccountMenu` fed
/// with the page's AIs and logins.
struct NativeLandingAccountList: View {
    @Bindable var model: NativeLandingModel
    var close: () -> Void = {}

    var body: some View {
        NewSessionAccountMenu(groups: model.ais.map { ai in
                                  NewSessionAccountGroup(provider: ai.id, name: ai.name, accounts: model.accounts.filter { $0.provider == ai.id })
                              },
                              chosenProvider: model.chosenProvider, chosenAccount: model.effectiveAccount,
                              pick: { provider, account in
                                  if let account { model.pickAccount(account, of: provider) } else { model.chooseAI(provider) }
                              },
                              addAccount: { NativeAccountSwitcher.addAccount(provider: model.chosenProvider) },
                              close: close)
            .accessibilityIdentifier("landing.account.list")
    }
}

// MARK: - Shared with Hoot's box (lane/hoot-review): the account menu and its rows

/// One AI in the account menu: its logins by name. An AI with no logins of its own (Shell, an added CLI) is one row.
struct NewSessionAccountGroup: Identifiable, Equatable {
    var id: String { provider }
    let provider: String
    let name: String
    let accounts: [NativeLandingModel.Account]
}

/// The account menu (15 Nov review items 6-7; DESIGN.md 7): logins by the NAME he gave them, grouped under the AI's
/// name with the AI's mark once in the group title; a check mark for the chosen row; the address only as small grey
/// text where two logins of one AI share a name; one orange dot only on a login that needs him (sign in, limit
/// reached); AIs without logins (Shell) after them; "+ Add account" at the foot. 13 pt rows, 26 pt high; group titles
/// 11 pt secondary.
struct NewSessionAccountMenu: View {
    let groups: [NewSessionAccountGroup]
    let chosenProvider: String
    let chosenAccount: String?
    var pick: (_ provider: String, _ account: String?) -> Void
    /// nil: no Add account row (a paired machine's menu: its accounts are added there).
    var addAccount: (() -> Void)?
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ordered) { group in
                if group.accounts.isEmpty {
                    NewSessionMenuRow(title: group.name, chosen: group.provider == chosenProvider, mark: group.provider) {
                        pick(group.provider, nil); close()
                    }
                } else {
                    NewSessionMenuTitle(text: group.name, provider: group.provider)
                    ForEach(group.accounts) { account in
                        NewSessionMenuRow(title: account.name, chosen: group.provider == chosenProvider && account.id == chosenAccount,
                                          detail: sharesName(account, in: group) ? account.email : nil,
                                          attention: account.needsHim ? account.stateWords : nil) {
                            pick(group.provider, account.id); close()
                        }
                    }
                }
            }
            if let addAccount {
                Divider().padding(.vertical, 4)
                NewSessionMenuRow(title: "Add account", chosen: false, symbol: "plus") { close(); addAccount() }
            }
        }
        .padding(6)
        .frame(minWidth: 240, maxWidth: 380, alignment: .leading)
    }

    /// AIs with logins first, in their order; then the ones without (Shell, an added CLI).
    private var ordered: [NewSessionAccountGroup] { groups.filter { !$0.accounts.isEmpty } + groups.filter { $0.accounts.isEmpty } }

    private func sharesName(_ account: NativeLandingModel.Account, in group: NewSessionAccountGroup) -> Bool {
        group.accounts.filter { $0.name.caseInsensitiveCompare(account.name) == .orderedSame }.count > 1
    }
}

/// A group title in the shared menus: 11 pt secondary, the AI's mark once before its name.
struct NewSessionMenuTitle: View {
    let text: String
    var provider: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let provider { NativeCodingAIProviderMark(provider: provider, size: 11) }
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One row of the shared menus: 13 pt, 26 pt high, a check mark when chosen, the title, optional small grey detail,
/// and at the trailing end one orange dot only when it needs him (its words as help and for VoiceOver).
struct NewSessionMenuRow: View {
    let title: String
    let chosen: Bool
    var detail: String? = nil
    var attention: String? = nil
    /// An AI's mark for a single-row group (Shell), or nil.
    var mark: String? = nil
    var symbol: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol ?? "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(symbol != nil || chosen ? 1 : 0).frame(width: 14)
                if let mark { NativeCodingAIProviderMark(provider: mark, size: 13) }
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 12)
                if let attention {
                    Circle().fill(DeckTokens.warn).frame(width: 7, height: 7).help(attention).accessibilityLabel(attention)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 5))
            .foregroundStyle(hovering ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(attention ?? "")
    }
}
