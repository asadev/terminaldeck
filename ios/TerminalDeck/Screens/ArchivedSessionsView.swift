/**
 * The sessions this phone has put away, and the one sentence that keeps the
 * feature honest.
 *
 * Asad, asking for the swipe: *"close the session (with a confirmation),
 * archive, move. When we will have a lot of sessions we will not like to have
 * all of them over here."* This is the *over here* — the place a row goes, and
 * therefore the place it comes back from.
 *
 * ## Why this screen exists at all, rather than archive being one-way
 *
 * Because a one-way archive is a delete with a friendlier word on it, and there
 * is nothing on this phone that can delete a session. An archive that could not
 * be undone would also make the swipe frightening, and a frightening swipe is one
 * nobody uses — which would leave the long list he complained about exactly as
 * long, with a gesture on it people have learned to avoid.
 *
 * ## And why the sentence at the foot is load-bearing
 *
 * The real risk of this feature is not that somebody cannot find a row. It is
 * that somebody archives four sessions, believes they have **stopped** four
 * agents, closes the app, and comes back to a machine that has been working — or
 * waiting on a question — for two hours. So the screen says what archiving did
 * and did not do, in the place people arrive when they wonder where something
 * went.
 *
 * ## Only rows the machine is still listing
 *
 * The store keeps an id until it is bounded out; this screen is handed the
 * *intersection* of that and the live session list, by `SessionListView`. A
 * machine that has been restarted has archived ids for sessions that no longer
 * exist and there is nothing to draw for them — a row for a session that has
 * gone would offer a tap that opens a terminal on nothing.
 */

import SwiftUI

struct ArchivedSessionsView: View {
    /// The archived sessions the machine is still listing, in the order it
    /// listed them. Passed in rather than derived here, so that the count on the
    /// menu item and the rows on this screen come from one calculation.
    let sessions: [RemoteSession]
    /// What to call the machine in the sentence at the foot. A name rather than
    /// "the machine", because somebody with two paired needs to know which one
    /// is still working.
    let machine: String
    let unarchive: (String) -> Void
    let open: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if sessions.isEmpty { empty } else { list }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("archived.done")
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(sessions) { session in
                Button {
                    open(session.id)
                } label: {
                    ArchivedRow(session: session)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("archived.session.\(session.id)")
                .plainRow()
                /*
                 * The **same edge** the archive was on, so one physical gesture
                 * undoes itself.
                 *
                 * A left swipe put the row here and a left swipe takes it back,
                 * which is what every messaging app on this phone does and is the
                 * only pairing somebody has to learn once. Putting it on the
                 * leading edge instead would have been tidier to argue about —
                 * "towards you means bring it back" — and would have meant that
                 * the person who has just learned the gesture reaches for it and
                 * finds nothing there.
                 *
                 * `allowsFullSwipe: false`, as on the list this row came from.
                 * There is only one action here and a full swipe would be
                 * harmless, but a gesture that behaves differently on two screens
                 * showing the same rows is a gesture nobody trusts.
                 */
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        unarchive(session.id)
                    } label: {
                        Label("Put back", systemImage: "tray.and.arrow.up")
                    }
                    .tint(Theme.accent)
                    .accessibilityIdentifier("archived.swipe.unarchive.\(session.id)")
                }
            }

            footnote.plainRow(top: 18, bottom: 28)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing archived", systemImage: "archivebox")
        } description: {
            // The gesture, named, because this screen is where somebody who has
            // not found it will end up — the menu item is deliberately drawn
            // even when this list is empty, precisely so that this sentence has
            // somewhere to be said.
            Text("Swipe a session to the left and choose Archive to move it off the list. It keeps "
                 + "running; it just stops being in the way.")
        }
        .accessibilityIdentifier("archived.empty")
    }

    private var footnote: some View {
        Text("Archiving is something this phone does to its own list. These sessions are still "
             + "running on \(machine), still producing output, and can still raise an alert.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("archived.footnote")
    }
}

/**
 * One archived session.
 *
 * The same three lines the live row draws, minus the chevron and minus the
 * activity time. The chevron goes because the tap is not the main verb on this
 * screen — putting it back is — and the time goes because it is measured from
 * the last thing this phone saw, which for a row it has not been drawing is a
 * number about the archive rather than about the session.
 */
private struct ArchivedRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: session.status)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)

                Text(session.cwd)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)

                Text(SessionDetails.statusLine(session))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
