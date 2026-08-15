/**
 * The find bar: a field, a count, and two arrows.
 *
 * ## It floats over the terminal rather than pushing it down
 *
 * A bar inserted into the layout would take about three rows off the session,
 * and taking rows off a session is not a layout change — it is a `resize` on the
 * wire, which makes the program on the far end reflow and an agent's box
 * repaint. Searching is a thing you do *while reading*, so it must not disturb
 * the thing being read. It covers the top of the scrollback instead, which
 * costs nothing, because the one row a search is about is scrolled into the
 * middle of the screen by SwiftTerm anyway.
 *
 * ## The counter is mono and the words are not
 *
 * "3 of 17" is data — two counted numbers — so it is set in mono, per the design
 * brief. "Find in output" and "Done" are chrome and are set in the system face.
 * The whole bar sits on a material for the same reason the connection banner
 * does: it is over content that scrolls beneath it, and it has to stay legible
 * without becoming a wall.
 *
 * ## Nothing here is a dead control
 *
 * The arrows are disabled with no term and with no matches, which are the only
 * two states where they could do nothing. The clear button exists only while
 * there is something to clear.
 */

import SwiftUI

struct FindBar: View {
    let find: FindSession
    /// Raised when the bar should go away. The screen owns that, because it is
    /// also what puts the keyboard down.
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            field
            stepper
            Button("Done", action: onClose)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("find.done")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            // The one case space cannot do the job: there is no space between a
            // floating bar and the output sliding under it.
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .onAppear {
            // Raised straight away. The bar exists because somebody chose Find;
            // making them tap the field they just asked for would be a second
            // tap for nothing.
            focused = true
        }
        // No identifier on this row, deliberately. One put here — it was
        // `find.bar` — is applied to **every descendant** and overwrites the
        // identifiers on the field, the two arrows and Done, so the whole bar
        // comes back as five elements all called the same thing and a test can
        // reach none of them. Measured: `find.field` matched nothing while the
        // bar was plainly on screen.
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.faint)

            TextField("Find in output", text: Binding(get: { find.term },
                                                      set: { find.type($0) }))
                .font(.system(size: 15))
                .foregroundStyle(Theme.primary)
                .textInputAutocapitalization(.never)
                // Both off, and neither is a preference: what gets typed in here
                // is a fragment of terminal output — a flag, half a path, a hash
                // — and autocorrect turns `--dir` into `-dir` and capitalises
                // `error` into something that will not match.
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { find.earlier() }
                .accessibilityIdentifier("find.field")

            if find.hasTerm {
                Text(find.status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(find.hasMatches ? Theme.secondary : Theme.warning)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("find.count")

                Button {
                    find.type("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.faint)
                }
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("find.clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Earlier and later, in that order, because a scrollback grows downwards:
    /// up is back in time and it is the direction a search starts in.
    private var stepper: some View {
        HStack(spacing: 2) {
            Button {
                find.earlier()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .disabled(!find.hasMatches)
            .accessibilityLabel("Earlier match")
            .accessibilityIdentifier("find.earlier")

            Button {
                find.later()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .disabled(!find.hasMatches)
            .accessibilityLabel("Later match")
            .accessibilityIdentifier("find.later")
        }
        .foregroundStyle(find.hasMatches ? Theme.primary : Theme.faint)
    }
}
