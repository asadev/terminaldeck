import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// The shared pieces every Settings page is built from (owner, 15 Nov; DESIGN.md section 1, macOS System Settings as the
// model). Other lanes use them for Coding AIs, Agents, Tasks, AI apps and Dynamic Island:
//
//   DeckSettingsScaffold   the page: 52 pt top bar (back / forward + page name) and ONE scroll view filling the pane
//                          (its scroll bar at the window's edge), content in a 560 pt column centred in the pane.
//   DeckSettingsGroup      a rounded group (radius 10, quaternary fill), optional title (+ info) 8 pt above it, rows
//                          separated by a hairline inset 44 pt; groups 20 pt apart (the scaffold's spacing).
//   DeckSettingsRow        one row: optional icon tile, title, optional info button, optional state, ONE control.
//   DeckSettingsLinkRow    a row that opens a page: the whole row is the click target, ends with a chevron.
//   DeckSettingsInfoButton the (i): a click opens a 280 pt popover with the explanation (never a sentence on the page).
//   DeckSettingsIconTile   the coloured tile with a white SF Symbol (26 pt in rows, 20 pt in the left list).
//   DeckSettingsProblem    the one orange line an error may take inside a group.
//   DeckSettingsLook       every number above, in one place.
//   DeckSettingsHistory    back / forward across everything opened in the window.

/// Every number of the Settings look (DESIGN.md section 1). Added here because the app's DeckTokens has no Settings
/// group and no grouped-row fill; spacing, radii and type reuse DeckTokens where a token matches.
enum DeckSettingsLook {
    // Window
    static let listWidth: CGFloat = 215
    static let column: CGFloat = 560
    static let topBar: CGFloat = 52
    static let topPadding: CGFloat = DeckTokens.Spacing.s20
    static let bottomPadding: CGFloat = DeckTokens.Metrics.pageBottom
    static let sideMargin: CGFloat = DeckTokens.Spacing.s16
    // Groups and rows
    static let groupRadius: CGFloat = DeckTokens.Metrics.groupedSectionRadius // 10
    static let groupGap: CGFloat = DeckTokens.Spacing.s20
    static let groupTitleGap: CGFloat = DeckTokens.Spacing.s8
    static let rowHeight: CGFloat = 44
    static let rowPadding: CGFloat = DeckTokens.Spacing.s12
    static let rowTile: CGFloat = 26
    static let rowTileRadius: CGFloat = DeckTokens.Metrics.chipRadius // 6
    static let rowGlyph: CGFloat = 14
    static let separatorInset: CGFloat = 44
    static let chevron: CGFloat = 12
    static let infoGlyph: CGFloat = 13
    static let infoGap: CGFloat = 6
    static let popoverWidth: CGFloat = 280
    /// The state dot of an account row (green signed in, orange needs sign-in; DESIGN.md section 6).
    static let stateDot: CGFloat = 7
    /// The coding AI's mark in front of its group title.
    static let groupMark: CGFloat = 14
    // Left list
    static let searchHeight: CGFloat = 28
    static let searchRadius: CGFloat = DeckTokens.Metrics.rowRadius // 8
    static let searchInset: CGFloat = 10
    static let profileRowHeight: CGFloat = 56
    static let profileRowPicture: CGFloat = 36
    static let listRowHeight: CGFloat = 28
    static let listTile: CGFloat = 20
    static let listTileRadius: CGFloat = 5
    static let listGroupGap: CGFloat = 14
    // Profile
    static let profilePicture: CGFloat = 96
    static let deviceGlyph: CGFloat = 28
    // Type
    static let pageName = Font.system(size: 15, weight: .semibold)
    static let groupTitle = Font.system(size: 13, weight: .semibold)
    static let rowTitle = DeckTokens.Typography.body           // 13 regular
    static let rowSecond = DeckTokens.Typography.caption       // 11
    static let profileName = Font.system(size: 22, weight: .semibold)
    // Colour: the system's fill for grouped rows (light and dark follow the system).
    static let groupFill = Color(nsColor: .quaternarySystemFill)
    static let separator = Color(nsColor: .separatorColor)
}

// MARK: - Opening a page, back and forward

/// What a row that opens a page calls. The Settings window hands in its own (it moves the window's selection); anywhere
/// else (a page drawn in the main window) it opens the Settings window on that page.
struct DeckSettingsOpenAction {
    let open: @MainActor (String) -> Void
    @MainActor func callAsFunction(_ id: String) { open(id) }
}

extension EnvironmentValues {
    @Entry var deckSettingsOpen = DeckSettingsOpenAction { AppModel.shared.openSettings(section: $0) }
    /// The Settings window draws back / forward in every page's top bar; a page shown elsewhere (the Browser's own
    /// settings window, the main window) shows its name only.
    @Entry var deckSettingsNavigation = false
}

/// Back and forward across every page opened in the Settings window (as System Settings). Pure bookkeeping: the window
/// reports each move (`moved`), the buttons ask for the page to go to (`back` / `forward`).
@MainActor @Observable
final class DeckSettingsHistory {
    static let shared = DeckSettingsHistory()
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var current: String?
    /// The page a back / forward press is moving to: its arrival is not a new step.
    @ObservationIgnored private var expected: String?
    static let limit = 50

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The window shows `page` now.
    func moved(to page: String) {
        defer { current = page }
        guard let current, current != page else { return }
        if page == expected { expected = nil; return }
        expected = nil
        backStack.append(current)
        if backStack.count > Self.limit { backStack.removeFirst(backStack.count - Self.limit) }
        forwardStack.removeAll()
    }
    /// The page Back goes to (nil: nothing before).
    func back() -> String? {
        guard let target = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        expected = target
        return target
    }
    func forward() -> String? {
        guard let target = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        expected = target
        return target
    }
    func reset() { backStack = []; forwardStack = []; current = nil; expected = nil }
}

/// The 52 pt bar at the top of the right pane: back and forward in one capsule, then the page name (15 pt semibold).
/// `trailing` holds a page's own one action, when it has one.
struct DeckSettingsTopBar: View {
    let title: String
    var trailing: AnyView? = nil
    @Environment(\.deckSettingsNavigation) private var navigation
    @Environment(\.deckSettingsOpen) private var open
    private var history: DeckSettingsHistory { .shared }

    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            if navigation {
                HStack(spacing: 0) {
                    arrow("chevron.left", label: "Back", enabled: history.canGoBack) { if let page = history.back() { open(page) } }
                    Rectangle().fill(DeckSettingsLook.separator).frame(width: 0.5, height: 16)
                    arrow("chevron.right", label: "Forward", enabled: history.canGoForward) { if let page = history.forward() { open(page) } }
                }
                .background(DeckSettingsLook.groupFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
            Text(title).font(DeckSettingsLook.pageName).lineLimit(1).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DeckTokens.Spacing.s8)
            if let trailing { trailing }
        }
        .padding(.horizontal, DeckSettingsLook.sideMargin)
        .frame(height: DeckSettingsLook.topBar)
        .frame(maxWidth: .infinity)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color(nsColor: .tertiaryLabelColor))
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - The page

/// A Settings page: the top bar, then ONE scroll view filling the pane (scroll bar at the window's edge) with the page's
/// groups in a 560 pt column centred in it, 20 pt apart.
struct DeckSettingsScaffold<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            DeckSettingsTopBar(title: title, trailing: trailing)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DeckSettingsLook.groupGap) { content() }
                    .frame(maxWidth: DeckSettingsLook.column, alignment: .leading)
                    .padding(.horizontal, DeckSettingsLook.sideMargin)
                    .padding(.top, DeckSettingsLook.topPadding)
                    .padding(.bottom, DeckSettingsLook.bottomPadding)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

/// The side margin that centres a 560 pt column in a pane `width` wide (used for the Form pages, whose own scroll view
/// then still fills the pane).
enum DeckSettingsColumnMargin {
    static func of(_ width: CGFloat) -> CGFloat {
        max(DeckSettingsLook.sideMargin, (width - DeckSettingsLook.column) / 2)
    }
}

// MARK: - Group and rows

/// A group of rows: a rounded rectangle (radius 10, the grouped-row fill, no border, no shadow); rows separated by a
/// hairline inset 44 pt from the left. An optional title (13 pt semibold) 8 pt above it, with an optional info button.
struct DeckSettingsGroup<Content: View>: View {
    var title: String? = nil
    var info: String? = nil
    /// Where the hairlines between rows start (the rows' text edge): 44 pt for rows with a 26 pt tile; a list whose
    /// rows carry a wider picture (the devices) hands in its own.
    var separatorInset: CGFloat = DeckSettingsLook.separatorInset
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, info: String? = nil, separatorInset: CGFloat = DeckSettingsLook.separatorInset,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.info = info; self.separatorInset = separatorInset; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeckSettingsLook.groupTitleGap) {
            if let title {
                HStack(spacing: DeckSettingsLook.infoGap) {
                    Text(title).font(DeckSettingsLook.groupTitle).foregroundStyle(.primary)
                    if let info { DeckSettingsInfoButton(label: title, text: info) }
                }
                .padding(.horizontal, DeckSettingsLook.rowPadding)
                .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            DeckSettingsHairline().padding(.leading, separatorInset)
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeckSettingsLook.groupFill, in: RoundedRectangle(cornerRadius: DeckSettingsLook.groupRadius))
            .clipShape(RoundedRectangle(cornerRadius: DeckSettingsLook.groupRadius))
        }
    }
}

/// The line between two rows: exactly one device pixel (0.5 pt on a 2x screen, 1 pt on a 1x screen), so every row
/// boundary sits on a whole pixel and looks the same. A fixed 0.5 pt line on a 1x screen lands on a half pixel under
/// every second row and is dropped there (WhatsApp seven-agents picture, 16 Nov).
struct DeckSettingsHairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(DeckSettingsLook.separator).frame(height: 1 / max(scale, 1))
    }
}

/// The coloured tile with a white glyph (System Settings' icon tiles): a soft top-to-bottom shading of the tint.
struct DeckSettingsIconTile: View {
    let symbol: String
    var tint: Color = .gray
    var size: CGFloat = DeckSettingsLook.rowTile
    var radius: CGFloat = DeckSettingsLook.rowTileRadius
    var glyph: CGFloat? = nil
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            Image(systemName: symbol)
                .font(.system(size: glyph ?? size * DeckSettingsLook.rowGlyph / DeckSettingsLook.rowTile, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The (i): SF Symbol `info.circle`, 13 pt, secondary; a CLICK (never hover) opens a 280 pt popover with 13 pt text.
struct DeckSettingsInfoButton: View {
    let label: String
    let text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: DeckSettingsLook.infoGlyph)).foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(label)")
        .popover(isPresented: $shown, arrowEdge: .bottom) { DeckSettingsInfoPopoverContent(text: text) }
    }
}

/// What the (i) popover shows: 13 pt text in a 280 pt column (also drawn by the pictures, which cannot open a popover).
struct DeckSettingsInfoPopoverContent: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DeckSettingsLook.rowTitle)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: DeckSettingsLook.popoverWidth, alignment: .leading)
            .padding(14)
    }
}

/// The row's leading part: optional tile, the title (13 pt), an optional second line (11 pt secondary), the info button.
struct DeckSettingsRowLabel: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    var leading: AnyView? = nil
    var info: String? = nil
    var titleColor: Color = .primary
    /// A short secondary word right after the title ("3,176 notes").
    var note: String? = nil
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s8 + 2) {
            if let leading { leading }
            else if let symbol { DeckSettingsIconTile(symbol: symbol, tint: tint) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DeckSettingsLook.infoGap) {
                    Text(title).font(DeckSettingsLook.rowTitle).foregroundStyle(titleColor).lineLimit(1).truncationMode(.tail)
                    if let note, !note.isEmpty {
                        Text(note).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let info, !info.isEmpty { DeckSettingsInfoButton(label: title, text: info) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(DeckSettingsLook.rowSecond).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

/// One row: title (and its tile, info and second line) on the left; at the right one short state in secondary text
/// and ONE control. Min height 44, 12 pt side padding.
struct DeckSettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    var info: String? = nil
    var state: String? = nil
    var stateColor: Color = .secondary
    var note: String? = nil
    @ViewBuilder let control: () -> Control

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .gray, info: String? = nil,
         state: String? = nil, stateColor: Color = .secondary, note: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint; self.info = info
        self.state = state; self.stateColor = stateColor; self.note = note; self.control = control
    }

    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            DeckSettingsRowLabel(title: title, subtitle: subtitle, symbol: symbol, tint: tint, info: info, note: note)
            Spacer(minLength: DeckTokens.Spacing.s8)
            if let state, !state.isEmpty {
                Text(state).font(DeckSettingsLook.rowTitle).foregroundStyle(stateColor).lineLimit(1).truncationMode(.middle)
            }
            control().labelsHidden()
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension DeckSettingsRow where Control == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .gray, info: String? = nil,
         state: String? = nil, stateColor: Color = .secondary) {
        self.init(title, subtitle: subtitle, symbol: symbol, tint: tint, info: info, state: state, stateColor: stateColor) { EmptyView() }
    }
}

/// A row with a switch: the title and the switch are one control (click or Space anywhere on the row).
struct DeckSettingsToggleRow: View {
    let title: String
    var info: String? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    var note: String? = nil
    @Binding var isOn: Bool
    init(_ title: String, info: String? = nil, symbol: String? = nil, tint: Color = .gray, note: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.info = info; self.symbol = symbol; self.tint = tint; self.note = note; _isOn = isOn
    }
    var body: some View {
        DeckSettingsRow(title, symbol: symbol, tint: tint, info: info, note: note) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A row that opens a page: the whole row is the click target and ends with a 12 pt tertiary chevron. `value` is the
/// short state at the right ("Connected", "3 devices").
struct DeckSettingsLinkRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    var leading: AnyView? = nil
    var value: String? = nil
    var valueColor: Color = .secondary
    var minHeight: CGFloat = DeckSettingsLook.rowHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DeckTokens.Spacing.s12) {
                DeckSettingsRowLabel(title: title, subtitle: subtitle, symbol: symbol, tint: tint, leading: leading)
                Spacer(minLength: DeckTokens.Spacing.s8)
                if let value, !value.isEmpty {
                    Text(value).font(DeckSettingsLook.rowTitle).foregroundStyle(valueColor).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: DeckSettingsLook.chevron - 2, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor)).accessibilityHidden(true)
            }
            .padding(.horizontal, DeckSettingsLook.rowPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(DeckSettingsPressStyle())
        .accessibilityLabel([title, subtitle, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// A row that is itself a button with a word in it ("Sign out", "Reset all settings"): accent or red text, centred left.
struct DeckSettingsButtonRow: View {
    let title: String
    var role: ButtonRole? = nil
    var info: String? = nil
    let action: () -> Void
    var body: some View {
        HStack(spacing: DeckSettingsLook.infoGap) {
            Button(action: action) {
                Text(title).font(DeckSettingsLook.rowTitle)
                    .foregroundStyle(role == .destructive ? Color(nsColor: .systemRed) : Color.accentColor)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let info { DeckSettingsInfoButton(label: title, text: info) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
    }
}

/// SP-2 (15 Nov): the kit's quiet text field: 120 pt wide, radius 6, the group's fill one step darker, no outline,
/// text right-aligned. The field itself is drawn without its bezel (`.textFieldStyle(.plain)` / `quietField()`).
struct DeckSettingsQuietField: ViewModifier {
    static let width: CGFloat = 120
    static let radius: CGFloat = 6
    static let fill = Color(nsColor: .tertiarySystemFill)
    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 6)
            .frame(width: Self.width, height: 22)
            .background(Self.fill, in: RoundedRectangle(cornerRadius: Self.radius))
    }
}

/// Press feedback only (owner: nothing changes on hover).
struct DeckSettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.primary.opacity(0.06) : Color.clear)
    }
}

/// The one line an error or a state he must act on may take inside a group: orange (or secondary), never a paragraph.
struct DeckSettingsProblem: View {
    let text: String
    var warn = true
    var body: some View {
        Text(text).font(DeckSettingsLook.rowTitle).foregroundStyle(warn ? DeckTokens.warn : .secondary)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DeckSettingsLook.rowPadding).padding(.vertical, DeckTokens.Spacing.s8 + 2)
            .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
    }
}

/// A row for one setting of the schema table: its kind decides the control; its help and its "more" go into the info
/// button (never a sentence under the title).
struct DeckSettingsSchemaRow: View {
    let id: String
    var title: String? = nil
    var info: String? = nil
    var onSave: (([String: CodingAIJSON]) -> Void)? = nil
    private let store = NativeSettingsValues.shared

    var body: some View {
        if let setting = SettingsSchema.setting(id), store.settingOn(id) {
            let value = SettingsSchema.value(store.values, setting)
            let explained = info ?? Self.explanation(setting)
            switch setting.kind {
            case .toggle:
                DeckSettingsToggleRow(title ?? setting.label, info: explained,
                                      isOn: Binding(get: { value.bool ?? false }, set: { save(setting, .bool($0)) }))
                    .disabled(store.loading)
            case .select:
                DeckSettingsRow(title ?? setting.label, info: explained) {
                    if setting.options.count == 1, let only = setting.options.first {
                        Text(only.label).foregroundStyle(.secondary)
                    } else {
                        Picker(setting.label, selection: Binding(get: { value.string ?? "" }, set: { save(setting, .string($0)) })) {
                            ForEach(setting.options) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.menu).fixedSize()
                    }
                }
                .disabled(store.loading)
            case .number:
                DeckSettingsRow(title ?? setting.label, info: explained) {
                    NativeSettingNumberField(setting: setting, value: value.number ?? 0, onCommit: { save(setting, .number($0)) })
                }
                .disabled(store.loading)
            case .text:
                DeckSettingsRow(title ?? setting.label, info: explained) {
                    NativeSettingTextField(setting: setting, value: value.string ?? "", onCommit: { save(setting, .string($0)) })
                }
                .disabled(store.loading)
            }
        }
    }

    /// The table's help line and its longer "more", as one popover text (nil when it has neither).
    static func explanation(_ setting: SettingDefinition) -> String? {
        let parts = [setting.help, setting.more].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func save(_ setting: SettingDefinition, _ value: CodingAIJSON) {
        let patch = [setting.id: value]
        if let onSave { onSave(patch) } else { store.save(patch) }
    }
}
