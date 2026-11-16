import SwiftUI

/// A settings/object page containing a grouped Form, List, or other view which owns its scrolling.
/// The shared page owns the solid background and pinned header; there is no second ScrollView.
///
/// Inside the Settings window (owner, 15 Nov; DESIGN.md section 1) the page takes the window's look: the 52 pt top bar
/// (back / forward and the page name) instead of the big heading, and the Form's own scroll view fills the whole pane
/// (its scroll bar at the window's edge) with its rows in a 560 pt column centred in the pane.
struct DeckSettingsFrame: View {
    private let title: String
    private let subtitle: String?
    private let switcher: AnyView?
    private let actions: AnyView?
    private let content: AnyView
    @Environment(\.deckSettingsColumn) private var inColumn

    init<Content: View>(title: String, subtitle: String? = nil,
                        @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; switcher = nil; actions = nil
        self.content = AnyView(content())
    }

    init<Content: View, Switcher: View>(title: String, subtitle: String? = nil,
                                      @ViewBuilder switcher: () -> Switcher,
                                      @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.switcher = AnyView(switcher()); actions = nil
        self.content = AnyView(content())
    }

    init<Content: View, Actions: View>(title: String, subtitle: String? = nil,
                                     @ViewBuilder actions: () -> Actions,
                                     @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; switcher = nil; self.actions = AnyView(actions())
        self.content = AnyView(content())
    }

    init<Content: View, Switcher: View, Actions: View>(
        title: String, subtitle: String? = nil,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title; self.subtitle = subtitle; self.switcher = AnyView(switcher()); self.actions = AnyView(actions())
        self.content = AnyView(content())
    }

    @ViewBuilder var body: some View {
        if inColumn {
            VStack(spacing: 0) {
                DeckSettingsTopBar(title: title, trailing: actions)
                if let switcher {
                    switcher.frame(maxWidth: .infinity).padding(.bottom, DeckTokens.Spacing.s8)
                }
                GeometryReader { pane in
                    content.scrollContentBackground(.hidden)
                        .contentMargins(.horizontal, DeckSettingsColumnMargin.of(pane.size.width), for: .scrollContent)
                        .frame(width: pane.size.width, height: pane.size.height, alignment: .top)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        } else if let switcher, let actions {
            DeckPage(title: title, subtitle: subtitle, scrolls: false, switcher: { switcher }, actions: { actions }) { framed }
        } else if let switcher {
            DeckPage(title: title, subtitle: subtitle, scrolls: false, switcher: { switcher }) { framed }
        } else if let actions {
            DeckPage(title: title, subtitle: subtitle, scrolls: false, actions: { actions }) { framed }
        } else {
            DeckPage(title: title, subtitle: subtitle, scrolls: false) { framed }
        }
    }

    private var framed: some View {
        content.scrollContentBackground(.hidden)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    /// Inside the Settings window's pane (owner review 14 Nov, item 11; 15 Nov: the window's own top bar and a centred
    /// 560 pt column, DESIGN.md section 1).
    @Entry var deckSettingsColumn = false
}
