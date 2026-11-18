import SwiftUI
import TerminalDeckNativeCore

/// App-wide preferences. Store ids remain stable when their titles change.
struct SettingsWindow: View {
    static let sceneID = "settings"
    let model: AppModel

    var body: some View {
        NativeSettingsShell(selection: Binding(
            get: { NativeSettingsNavigation.shown(model.settingsSelection) },
            set: { model.selectSettingsSection($0) })) { section in
                NativeSettingsDetail(section: section)
        }
        // Hoot's settings live on the Hoot page now (Asad, 10 Oct): an old "copilot"/"hoot" link opens
        // that page and this window shows General instead of an empty pane.
        .onChange(of: model.settingsSelection, initial: true) { _, selected in
            guard let selected, NativeSettingsNavigation.isHoot(selected) else { return }
            HootProfileRoute.open()
            model.selectSettingsSection(NativeSettingsNavigation.opening)
        }
        // Owner, 14 Nov: about twice the old 760 x 560, as large as fits on a smaller screen, his own size remembered,
        // centred on the window he is using (NativeSettingsWindowFrame). No pop-out button: Settings is one window.
        .frame(minWidth: NativeSettingsWindowFrame.minimum.width, minHeight: NativeSettingsWindowFrame.minimum.height)
        .frame(idealWidth: NativeSettingsWindowFrame.preferred.width, idealHeight: NativeSettingsWindowFrame.preferred.height)
        .background(NativeSettingsWindowPlacer())
        .deckWindowAppear() // L1-SHELL: glass until the first layout, then a 0.15 s fade in
        .navigationTitle("Settings")
    }
}

/// Shared shell also used by hidden renders; the sidebar always stays the same.
/// Owner, 15 Nov (DESIGN.md section 1): two panes. The left list (215 pt, the sidebar material): the search field, the
/// big profile row, small rows, space between groups and never a line. The right pane is the page, full width, so a
/// page's scroll bar sits at the window's edge; every page draws its own 52 pt top bar with back and forward.
struct NativeSettingsShell<Content: View>: View {
    @Binding var selection: String
    @ViewBuilder var content: (String) -> Content
    @State private var search = ""
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let _ = NativeCloudAccount.shared.snapshot
        HStack(spacing: 0) {
            NativeSettingsSidebarList(selection: $selection, search: $search, appearsActive: appearsActive)
                .frame(width: DeckSettingsLook.listWidth)
                // The system sidebar material, up under the traffic lights, never changing with the pane.
                .background(DeckSidebarMaterial().ignoresSafeArea())
            content(selection)
                .environment(\.deckSettingsColumn, true)
                .environment(\.deckSettingsNavigation, true)
                .environment(\.deckSettingsOpen, DeckSettingsOpenAction { selection = $0 })
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(NativeSettingsStyle.page)
                .overlay(alignment: .bottom) { NativeSettingsSaveProblem() }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(NativeSettingsStyle.frame)
        // Back and forward walk every page opened in this window.
        .onChange(of: selection, initial: true) { _, page in DeckSettingsHistory.shared.moved(to: page) }
    }
}

/// The left list (DESIGN.md section 1): search field (28 pt, radius 8, translucent fill, 10 pt inset), the profile row
/// (56 pt, picture 36 pt, name and "Terminal Deck account"), then 28 pt rows with 20 pt tiles; groups 14 pt apart.
struct NativeSettingsSidebarList: View {
    @Binding var selection: String
    @Binding var search: String
    let appearsActive: Bool
    static let profileSecondLine = "Terminal Deck account"
    /// The profile picture's "needs you" badge (SW-4).
    static let badgeSize: CGFloat = 8

    var body: some View {
        VStack(spacing: DeckTokens.Spacing.s8) {
            searchField
            ScrollView {
                VStack(spacing: 0) {
                    let items = NativeSettingsNavigation.matching(search)
                    let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let lit = NativeSettingsNavigation.listRow(selection)
                    // One flat run (owner, 14 Nov): an entry not shown takes no space; groups apart by space only.
                    ForEach(NativeSettingsNavigation.entries(items)) { entry in
                        switch entry {
                        case .gap:
                            Color.clear.frame(height: DeckSettingsLook.listGroupGap).accessibilityHidden(true)
                        case .row(let id):
                            if let item = byId[id] { row(item, selected: lit == item.id) }
                        }
                    }
                    if items.isEmpty { Text("No matching settings").font(.callout).foregroundStyle(.secondary).padding(12) }
                }.padding(.horizontal, DeckSettingsLook.searchInset)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled() // row selection shows focus; no ring around the whole list
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(DeckSettingsLook.rowTitle)
                .accessibilityLabel("Search Settings")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: DeckSettingsLook.searchHeight)
        // The system search field's look: translucent fill, a hairline edge, radius 8.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DeckSettingsLook.searchRadius))
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DeckSettingsLook.searchRadius))
        .overlay(RoundedRectangle(cornerRadius: DeckSettingsLook.searchRadius).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, DeckSettingsLook.searchInset).padding(.top, DeckSettingsLook.searchInset)
    }

    @ViewBuilder private func row(_ item: NativeSettingsNavigation.Item, selected: Bool) -> some View {
        let profile = item.id == NativeSettingsNavigation.profileID
        let ink = DeckSidebar.ink(selected: selected, active: appearsActive)
        Button { selection = item.id } label: {
            HStack(spacing: profile ? 10 : 8) {
                if profile {
                    let facts = NativeProfileFacts.current()
                    // His picture (initials until the account service sends one), twice the size of a row's tile.
                    NativeProfileAvatar(name: facts.name, picture: facts.picture, local: facts.localPicture,
                                        size: DeckSettingsLook.profileRowPicture)
                        // SW-4: something needs him: an 8 pt orange badge on the picture's corner, never at the row's
                        // right edge where it squeezed the second line.
                        .overlay(alignment: .topTrailing) {
                            if item.id == NativeSettingsNavigation.listRow(NativeSettingsNavigation.devicesID), NativeDevicesSettings.somethingWaits() {
                                Circle().fill(Color.orange).frame(width: Self.badgeSize, height: Self.badgeSize)
                                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                    .offset(x: 1, y: -1)
                                    .accessibilityLabel("A device waits for you")
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(facts.sidebarTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(ink)
                        // SW-4: never cut ("Terminal Deck acc…"): it keeps its whole width.
                        Text(Self.profileSecondLine).font(DeckSettingsLook.rowSecond).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(selected && appearsActive ? Color.white.opacity(0.85) : Color.secondary)
                    }
                } else {
                    DeckSettingsIconTile(symbol: item.symbol, tint: item.tint, size: DeckSettingsLook.listTile,
                                         radius: DeckSettingsLook.listTileRadius, glyph: 11)
                    Text(item.title).font(DeckSettingsLook.rowTitle).lineLimit(1).foregroundStyle(ink)
                }
                Spacer(minLength: 0)
                // A device waits for his OK (review 14 Nov, item 5): a dot on the row that lists the devices; on the
                // profile row it is the picture's badge (above).
                if !profile, item.id == NativeSettingsNavigation.listRow(NativeSettingsNavigation.devicesID), NativeDevicesSettings.somethingWaits() {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                        .accessibilityLabel("A device waits for you")
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: profile ? DeckSettingsLook.profileRowHeight : DeckSettingsLook.listRowHeight,
                   alignment: .leading)
            .contentShape(.rect)
            // Apple's selected sidebar row: accent fill, white text (grey in the background).
            .background(selected ? DeckSidebar.selectionFill(active: appearsActive) : .clear,
                        in: RoundedRectangle(cornerRadius: DeckSidebar.rowRadius))
        }
        .buttonStyle(DeckSidebarRowStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ offset: Int) {
        let items = NativeSettingsNavigation.matching(search)
        guard !items.isEmpty else { return }
        let lit = NativeSettingsNavigation.listRow(selection)
        let index = items.firstIndex(where: { $0.id == lit }) ?? 0
        selection = items[min(items.count - 1, max(0, index + offset))].id
    }
}

struct NativeSettingsDetail: View {
    let section: String
    var body: some View {
        let _ = NativeCloudAccount.shared.snapshot
        let section = NativeSettingsNavigation.canonical(section)
        let shows = NativeCloudDisplayGate.shared.accountShows
        Group {
            if section == NativeSettingsNavigation.profileID, shows {
                NativeProfileSettings()
            } else if section == NativeSettingsNavigation.personalID, shows {
                NativeProfilePersonalPage()
            } else if section == NativeSettingsNavigation.signInID, shows {
                NativeProfileSignInPage()
            } else if section == CloudSubscriptionPage.id {
                NativeCloudSubscriptionPage()
            } else if section == NativeSettingsNavigation.cloudID, shows {
                NativeCloudPage()
            } else if section == NativeSettingsNavigation.planID, shows {
                // Paywall off (or the plan not known): the page does not exist; an old link shows Profile.
                if let plan = NativeCloudPlanSeam.shown() { NativeCloudPlanPage(facts: plan) } else { NativeProfileSettings() }
            } else if section == NativeSettingsNavigation.devicesID {
                NativeDevicesSettings()
            } else if let row = NativeSettingsNavigation.deviceRow(section) {
                NativeDevicePage(rowID: row)
            } else if section == "island" {
                NativeIslandSettings()
            } else if section == "agent-defaults" {
                NativeAGSDefaultsSettingsSections()
            } else if section == NativeSettingsNavigation.agentHooksID {
                NativeAGSHooksPage()
            } else if section == NativeSettingsNavigation.whichAccountID {
                NativeWhichAccountPage()
            } else if section == NativeSettingsNavigation.taskConnectionsID {
                NativeTaskConnectionsPage()
            } else if let agent = NativeSettingsNavigation.taskAgent(section) {
                NativeTaskAgentPage(agentID: agent)
            } else if let project = NativeSettingsNavigation.taskWorkflow(section) {
                NativeProjectWorkflowPage(projectID: project)
            } else if let screen = NativeScreens.settings(sectionId: NativeSettingsNavigation.canonical(section)) {
                screen
            } else {
                ContentUnavailableView("Choose a setting", systemImage: "gearshape")
            }
        }.id(section)
    }
}
