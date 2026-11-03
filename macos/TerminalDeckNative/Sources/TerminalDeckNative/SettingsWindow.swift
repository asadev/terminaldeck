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
        // that page and this window shows the first remaining section instead of an empty pane.
        .onChange(of: model.settingsSelection, initial: true) { _, selected in
            guard let selected, NativeSettingsNavigation.isHoot(selected) else { return }
            HootProfileRoute.open()
            model.selectSettingsSection(NativeSettingsNavigation.items.first?.id ?? "general")
        }
        .frame(minWidth: 680, minHeight: 440)
        .frame(idealWidth: 760, idealHeight: 560)
        .deckWindowAppear() // L1-SHELL: glass until the first layout, then a 0.15 s fade in
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .primaryAction) {
            NativePagePopoutButton(ref: ScreenRef(kind: .panel, id: "settings:" + NativeSettingsNavigation.shown(model.settingsSelection)))
        } }
        .sheet(isPresented: Binding(get: { model.settingsShortcuts != nil },
                                   set: { if !$0 { model.settingsShortcuts = nil } })) {
            NativeShortcutsSheet(hidden: model.settingsShortcuts ?? [], fromSettings: true) { model.settingsShortcuts = nil }
        }
    }
}

/// Shared shell also used by hidden renders; the sidebar always stays the same.
struct NativeSettingsShell<Content: View>: View {
    @Binding var selection: String
    @ViewBuilder var content: (String) -> Content
    @State private var search = ""
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search Settings")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                    .padding(.horizontal, 12).padding(.top, 12)
                    ScrollView {
                        VStack(spacing: 0) {
                            let items = NativeSettingsNavigation.matching(search)
                            ForEach(0..<4, id: \.self) { group in
                                let rows = items.filter { $0.group == group }
                                if !rows.isEmpty {
                                    if group > 0 { Divider().padding(.horizontal, 10).padding(.vertical, 6) }
                                    ForEach(rows) { item in
                                        Button { selection = item.id } label: {
                                            HStack(spacing: 8) {
                                                ZStack {
                                                    if NativeSettingsNavigation.isHoot(item.id) {
                                                        RoundedRectangle(cornerRadius: 5).fill(Color.white)
                                                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(item.tint.opacity(0.5), lineWidth: 1))
                                                        HootMark(size: 15, animated: false)
                                                    } else {
                                                        RoundedRectangle(cornerRadius: 5).fill(item.tint)
                                                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                                                        Image(systemName: item.symbol)
                                                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                                                    }
                                                }.frame(width: 20, height: 20)
                                                Text(item.title).font(.system(size: 13))
                                                    .foregroundStyle(selection == item.id && appearsActive ? Color.white : Color.primary)
                                                Spacer(minLength: 0)
                                            }
                                            .padding(.horizontal, 8)
                                            .frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
                                            .contentShape(.rect)
                                            // Apple's selected sidebar row: blue pill, white text (grey in the background).
                                            .background(selection == item.id ? DeckSidebar.selectionFill(active: appearsActive) : .clear,
                                                        in: RoundedRectangle(cornerRadius: DeckSidebar.rowRadius))
                                        }
                                        .buttonStyle(DeckSidebarRowStyle())
                                        .id(item.id)
                                        .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                                    }
                                }
                            }
                            if items.isEmpty { Text("No matching settings").font(.callout).foregroundStyle(.secondary).padding(12) }
                        }.padding(.horizontal, 8)
                    }
                    .focusable()
                    .focusEffectDisabled() // row selection shows focus; no ring around the whole list
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                }
                .frame(width: 194)
                // The system sidebar material, up under the traffic lights, never changing with the pane.
                .background(DeckSidebarMaterial().ignoresSafeArea())
                Divider()
                content(selection)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background(NativeSettingsStyle.page)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            NativeSettingsFoot()
        }
        .background(NativeSettingsStyle.frame)
    }
    private func move(_ offset: Int) {
        let items = NativeSettingsNavigation.matching(search)
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selection }) ?? 0
        selection = items[min(items.count - 1, max(0, index + offset))].id
    }
}

struct NativeSettingsDetail: View {
    let section: String
    var body: some View {
        Group {
            if section == "island" {
                NativeIslandSettings()
            } else if section == "agent-defaults" {
                NativeSettingsPage(sectionId: section) { NativeAGSDefaultsSettingsSections() }
            } else if let screen = NativeScreens.settings(sectionId: NativeSettingsNavigation.canonical(section)) {
                screen
            } else {
                ContentUnavailableView("Choose a setting", systemImage: "gearshape")
            }
        }.id(section)
    }
}
