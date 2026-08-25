/**
 * The find bar for a page: a field, a sentence, and two arrows.
 *
 * Deliberately the same controls in the same order as `FindBar` — the
 * terminal's — because a person who has learned one find bar in this app has
 * learned both, and the two screens this app pushes you into are a session and a
 * page. `FindBar.tsx` on the desktop opens by saying the identical thing about
 * its own sibling. Three surfaces, one bar.
 *
 * ## It sits **in** the layout, not over the page
 *
 * This is the one place the two phone bars differ, and each is right about its
 * own content.
 *
 * The terminal's floats over the scrollback because inserting it would take
 * about three rows off the session — and taking rows off a session is not a
 * layout change, it is a `resize` on the wire that makes the program on the far
 * end reflow and an agent's box repaint. None of that is true of a web page. A
 * page is not a fixed grid, it is not on the wire, and it reflows for a living:
 * giving it a shorter rectangle costs nothing and is what every browser on this
 * phone does. Floating here would instead cover the last line of the page — the
 * footer, the last log row, the submit button — with no way to scroll it out
 * from under the bar, which is the defect `TabBarClearance` was written for
 * after the About row on Settings ended up behind the tab pill.
 *
 * The desktop reached the same answer from a different constraint: over there a
 * browser page is a native view composited above the whole renderer, so anything
 * floated would be painted *behind* the website. Same bar, same place, two
 * unrelated reasons — which is usually a sign the place is right.
 *
 * ## Above the keyboard, and that is why it is a `safeAreaInset`
 *
 * A bottom `safeAreaInset` is placed above the bottom safe area **including the
 * keyboard**, which is exactly the behaviour wanted and is the same modifier
 * `CopilotView` lifts its composer with. It also means the bar sits above the
 * screen's bottom toolbar when the keyboard is down, and the toolbar is the
 * thing the keyboard covers when it is up — so while somebody is typing, this
 * bar's own Done is the way out rather than the toolbar's.
 *
 * `TabBarClearance` is deliberately **not** used here, and the reason is a fact
 * rather than an oversight: `DeckChrome.showsTabBar(on: .localhostPage)` is
 * false — *"pill should be on here only on the homepage or machines or
 * settings, but not inside the session and not also inside the localhost
 * page"* — so there is no floating pill under this screen to reserve room for.
 * The probe would measure zero and add zero, which is the right answer arrived
 * at expensively.
 *
 * ## The sentence is only ever bad news
 *
 * `BrowserFindSession.status` is empty on a match and says *"No matches"* when
 * there is none — read that file's header for why there is no *"3 of 17"* here
 * and why inventing one was refused. So the counter slot is set in the warning
 * colour unconditionally: unlike the terminal's, the only thing it can ever
 * contain is the state the page cannot show for itself.
 */

import SwiftUI

struct BrowserFindBar: View {
    let find: BrowserFindSession
    /// Raised when the bar should go away. The screen owns that, because the
    /// screen is also what puts the keyboard down and what re-hands the bottom
    /// of the page back to the toolbar.
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            field
            stepper
            Button("Done", action: onClose)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("localhost.find.done")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // A material rather than a fill, for the reason the sibling bar uses
        // one: this lands directly on top of the keyboard about half the time it
        // is on screen, and a material is what every other band that sits there
        // is made of.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            // At the **top** edge, where the sibling puts it at the bottom, and
            // for the same reason read the other way up: the seam belongs
            // between the bar and the content, and the content is above this one.
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .onAppear {
            // Raised straight away. The bar exists because somebody chose Find;
            // making them tap the field they just asked for is a second tap for
            // nothing.
            focused = true
        }
        // No identifier on this row, deliberately — the same trap the terminal's
        // bar records: one applied here reaches **every descendant** and
        // overwrites the identifiers on the field, the arrows and Done, so the
        // whole bar comes back as five elements with one name and a test can
        // reach none of them.
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.faint)

            TextField("Find in page", text: Binding(get: { find.term },
                                                    set: { find.type($0) }))
                .font(.system(size: 15))
                .foregroundStyle(Theme.primary)
                .textInputAutocapitalization(.never)
                // Both off, and neither is a preference. What gets typed in here
                // is a fragment of a page — a class name, half a route, a label,
                // an id — and autocorrect capitalises `error` and turns `nav-`
                // into `nav` before it ever reaches WebKit, which then honestly
                // reports that the thing you did not type is not there.
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                // Forwards, because that is the direction a document runs and
                // the direction a fresh search already went. The terminal's
                // return key goes the other way for the same reason — see
                // `BrowserFind`'s header on the two directions.
                .onSubmit { find.next() }
                .accessibilityIdentifier("localhost.find.field")

            if !find.status.isEmpty {
                Text(find.status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("localhost.find.status")
            }

            if find.hasTerm {
                Button {
                    find.type("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.faint)
                }
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("localhost.find.clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Radius 14 rather than the 20 the cards on this app use, because this
        // is not a card — it is the same search field the terminal's bar draws,
        // and the two being one shape is worth more here than either matching
        // the surfaces around it.
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /**
     * Up towards the top of the page, then down towards the end.
     *
     * Both disabled until something has actually matched — the only two states
     * where they could do nothing are no term and no match, and this app does
     * not draw a control that does nothing. Note that "no more matches" is not
     * one of those states: the search wraps, so ↓ on the last match moves the
     * page to the first one rather than going dead. See `BrowserFind` on why
     * wrapping is on.
     */
    private var stepper: some View {
        HStack(spacing: 2) {
            Button {
                find.previous()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .disabled(!find.hasMatch)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("localhost.find.previous")

            Button {
                find.next()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .disabled(!find.hasMatch)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("localhost.find.next")
        }
        .foregroundStyle(find.hasMatch ? Theme.primary : Theme.faint)
    }
}
