import SwiftUI

/// A settings/object page containing a grouped Form, List, or other view which owns its scrolling.
/// The shared page owns the solid background and pinned header; there is no second ScrollView.
struct DeckSettingsFrame: View {
    private let page: DeckPage

    init<Content: View>(title: String, subtitle: String? = nil,
                        @ViewBuilder content: () -> Content) {
        page = DeckPage(title: title, subtitle: subtitle, scrolls: false) {
            content().scrollContentBackground(.hidden)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    init<Content: View, Switcher: View>(title: String, subtitle: String? = nil,
                                      @ViewBuilder switcher: () -> Switcher,
                                      @ViewBuilder content: () -> Content) {
        page = DeckPage(title: title, subtitle: subtitle, scrolls: false,
                        switcher: switcher) {
            content().scrollContentBackground(.hidden)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    init<Content: View, Actions: View>(title: String, subtitle: String? = nil,
                                     @ViewBuilder actions: () -> Actions,
                                     @ViewBuilder content: () -> Content) {
        page = DeckPage(title: title, subtitle: subtitle, scrolls: false,
                        actions: actions) {
            content().scrollContentBackground(.hidden)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    init<Content: View, Switcher: View, Actions: View>(
        title: String, subtitle: String? = nil,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        page = DeckPage(title: title, subtitle: subtitle, scrolls: false,
                        switcher: switcher, actions: actions) {
            content().scrollContentBackground(.hidden)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    var body: some View { page }
}
