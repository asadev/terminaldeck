/**
 * The open pages, in a row, with the one you are on marked.
 *
 * ## Nothing draws this any more, and that is the honest state rather than an
 * oversight
 *
 * It was the strip under the localhost screen's address bar, and that screen is
 * gone: *"you still kept localhost as a separate page inside the page… I wanted
 * it to be like ONE page where I can start a new window."* The pages this phone
 * holds over a tunnel are **rows on the Browser tab's own list** now, beside the
 * machine's windows and marked *On this phone* — see `MachineBrowserView`. A
 * strip of them somewhere else would be the second place to look that the whole
 * change exists to remove.
 *
 * The file is kept because `PanelView` cites the pill decision below and because
 * nothing about it is wrong; it is a component with no caller. Anyone reaching
 * for it should check first whether what they want is a row on that list.
 *
 * Asad: *"it should have all those options — to start a new windows thing should
 * be there."* `BrowserTabs` is the half that decides what a tab is and which
 * tunnels stay bound; this is the half you touch. Four things and nothing else:
 * every open page by name, a close on each, the current one marked, and a `+`.
 *
 * ## The `+` does not open a page — it opens the address bar
 *
 * There is one place in this app where an address can be typed and it is the
 * field at the top of the Browser screen. A `+` that raised a sheet with a
 * second field in it would be the control this screen already deleted once: the
 * old `+` in the toolbar put up a modal to show somebody a control they were
 * already looking at (see `NewWindowSheet`). So it clears that
 * field and puts the keyboard in it, which is what a new tab is on a phone.
 *
 * ## No glyph on the pills
 *
 * Every row on the screen above carries one — 19 point, light, in a 24-point
 * column — and a strip is the one place that would be wrong. Nine identical
 * globes are nine pieces of emphasis that distinguish nothing, in the width the
 * only distinguishing thing has: the name. *"No quantity spam, no free
 * emphasis."* A pill is scanned for its title, so a pill is its title.
 *
 * ## Two buttons in one pill, not a button inside a button
 *
 * The same shape `PortSuggestions`' `SplitRow` uses on the port rows and for the
 * same reason: SwiftUI does not nest tap targets, so a close glyph inside the
 * selecting button is a close glyph that selects. They sit side by side over one
 * shared background, which is what makes them read as one object and behave as
 * two.
 *
 * The pill is 38 points tall rather than 44, which is the same trade `InfoDot`
 * argues: 44 cannot be had in a band that sits between an address bar and a
 * list without pushing one of them off the screen, and the *label* half of the
 * pill is a target the width of the name. The close is 30 by 38 — a real target
 * for a small glyph.
 *
 * ## And there is no swipe-to-close here, which was a decision rather than an
 * ## omission
 *
 * The lists on this tab and its home grew swipe actions in this build — *"we can swipe them
 * left and right and we can have options there to delete or close… just like
 * WhatsApp has the chats"* — and the strip was measured against the same rule
 * and left alone. Three reasons, in the order they matter:
 *
 *  1. **The verb is already visible.** Every pill carries an `×` with a 30×38
 *     target, permanently, one thumb-width from the name. A swipe would be a
 *     second way to reach a control nobody has to discover — which is exactly
 *     the second door this screen deleted when the toolbar `+` went.
 *  2. **`.swipeActions` does not apply.** It exists only inside a `List`, and
 *     this is a horizontal `ScrollView`; the gesture would have to be a
 *     hand-rolled vertical `DragGesture` on each pill, which is a swipe that is
 *     not the system's — no rubber band, no depth, nothing a person's hand
 *     already knows.
 *  3. **It would fight the scroll.** A vertical drag recogniser on a child of a
 *     horizontal scroll view competes with the scroll for the first few points
 *     of every gesture, and the strip scrolls constantly — twelve pills do not
 *     fit on a phone. Trading a reliable scroll for a redundant close is a bad
 *     trade in both directions.
 *
 * The gesture belongs where there is a verb with no visible control: the ports
 * and the machine's windows, both of which had theirs behind a `…`.
 */

import SwiftUI

struct BrowserTabStrip: View {

    let tabs: [BrowserTab]
    /// The tab whose page is open, or nil while the list is on screen and none
    /// of them is. Passed in rather than asked of `BrowserTabs`, because which
    /// page is *pushed* is the screen's business — see `MachineBrowserView`.
    let current: BrowserTab?
    let select: (BrowserTab) -> Void
    let close: (BrowserTab) -> Void
    /// Clear the address field and put the keyboard in it. See the header.
    let new: () -> Void

    var body: some View {
        // Absent, not empty. A machine with nothing open has no tabs to show and
        // no `+` to press: the address bar directly above is the `+`, and a
        // second control saying so would be the duplication this screen keeps
        // deleting.
        if !tabs.isEmpty { strip }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        pill(tab, index: index)
                            // The scroll target below addresses tabs by id; the
                            // identifiers on the controls are by position,
                            // because a UI test can predict a position and
                            // cannot predict a UUID.
                            .id(tab.id)
                    }
                    plus
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            /*
             * The current tab, brought into view.
             *
             * Twelve pills do not fit on a phone, so the tab you just came back
             * from is routinely off the left edge — and a strip that marks a tab
             * you cannot see has marked nothing. Animated, so it reads as the
             * strip moving rather than as the row having been different all
             * along.
             */
            .onChange(of: current?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                guard let id = current?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .accessibilityIdentifier("browser.tabs")
    }

    private func pill(_ tab: BrowserTab, index: Int) -> some View {
        let isCurrent = tab.id == current?.id
        return HStack(spacing: 0) {
            Button {
                select(tab)
            } label: {
                Text(tab.label)
                    .font(.system(size: 13,
                                  weight: isCurrent ? .semibold : .regular,
                                  // Mono while the page is still nameless,
                                  // because what is being drawn then is an
                                  // address — the same rule `PortRow` follows
                                  // one section down, where an unnamed port
                                  // leads with its number in mono and a named
                                  // one leads with the name.
                                  design: tab.title.isEmpty ? .monospaced : .default))
                    .foregroundStyle(isCurrent ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 148, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.trailing, 2)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.label)
            .accessibilityIdentifier("browser.tab.\(String(index))")

            Button {
                close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 30, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.label)")
            .accessibilityIdentifier("browser.tab.close.\(String(index))")
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // The mark is the border rather than a filled pill, and that is not a
        // preference either: a filled accent pill puts white text on blue in a
        // row of grey cards and reads as the only *button* on the strip. A
        // border says "this one" without claiming to be a different kind of
        // thing from the ones beside it.
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isCurrent ? Theme.accent : Theme.hairline,
                        lineWidth: isCurrent ? 1.5 : 1))
        .accessibilityElement(children: .contain)
    }

    private var plus: some View {
        Button(action: new) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 46, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline))
        .accessibilityLabel("New tab")
        .accessibilityIdentifier("browser.tab.new")
    }
}
