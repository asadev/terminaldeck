/**
 * The browser windows this phone has put away, and the one sentence that keeps
 * the feature honest.
 *
 * Asad, listing what a window's row should offer without being opened: *"from
 * the outside we can just make it archive, close, or connect to any session."*
 * This is the *away* — the place a row goes, and therefore the place it comes
 * back from.
 *
 * ## Why this screen exists at all, rather than archive being one-way
 *
 * Because a one-way archive is a delete with a friendlier word on it, and this
 * phone already has a real delete for a window: Close, which is the row above it
 * on the same menu. An archive that could not be undone would be a second Close
 * that lied about what it did, and it would make the swipe frightening — a
 * frightening swipe is one nobody uses, which would leave the list exactly as
 * long with a gesture on it people have learned to avoid.
 *
 * ## And why the sentence at the foot is load-bearing
 *
 * The real risk of this feature is not that somebody cannot find a row. It is
 * that somebody archives four windows, believes they have **closed** four
 * windows, and leaves an agent driving one of them — or leaves a click recorder
 * running on a page nobody is watching. So the screen says what archiving did
 * and did not do, in the place people arrive when they wonder where something
 * went. `ArchivedSessionsView` carries the same sentence about the same word for
 * the same reason.
 *
 * ## Only rows the machine is still listing
 *
 * `WindowShelf` keeps an id until it is bounded out; this screen draws the
 * *intersection* of that and the live window list. Shell tab ids churn — a
 * browser restart mints new ones for every window — so the store is full of ids
 * for windows that no longer exist, and a row for one of those would offer a tap
 * that opens a screen about nothing.
 *
 * ## A push rather than a sheet
 *
 * The sessions' archive is a sheet because it is raised from a tab's root, where
 * there is no stack to push onto. This one is reached from the Browser tab's
 * `…`, which sits above a `NavigationStack` that already carries the window's
 * own screens — so a row here can lead to the same `MachineWindowView` every
 * other row in this app leads to, instead of having to close a modal first.
 */

import SwiftUI

struct ArchivedWindowsView: View {
    let model: DeckModel
    var shelf: WindowShelf = .shared

    private var host: HostLink? { model.current }
    private var hostId: String { host?.id ?? "" }

    /// The archived windows the machine is still listing, in the order it listed
    /// them. Derived here rather than passed in, because this screen is pushed
    /// from a menu and the list moves while it is open — a window closed at the
    /// machine should leave this screen too.
    private var windows: [MachineWindow] {
        shelf.split(host?.machineBrowser?.windows ?? [], host: hostId).archived
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if windows.isEmpty { empty } else { list }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        // The list is only as fresh as the last answer, and this screen can be
        // opened minutes after one. The read is cheap and guarded on the
        // capability that draws the menu item in the first place.
        .onAppear { host?.readMachineWindows() }
    }

    private var list: some View {
        List {
            ForEach(windows) { window in
                NavigationLink {
                    MachineWindowView(model: model, windowID: window.id)
                } label: {
                    ArchivedWindowRow(window: window)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel(MachineBrowserText.spoken(window))
                .accessibilityIdentifier("browser.archived.row.\(window.id)")
                .plainRow()
                /*
                 * The **same edge** the archive was on, so one physical gesture
                 * undoes itself.
                 *
                 * A left swipe put the row here and a left swipe takes it back,
                 * which is what every messaging app on this phone does and is
                 * the only pairing somebody has to learn once. The sessions'
                 * archive makes the same choice, and a gesture that behaved
                 * differently on two screens showing two kinds of the same thing
                 * is one nobody trusts.
                 *
                 * `allowsFullSwipe: false`, as on the list this row came from.
                 * There is only one action here and a full swipe would be
                 * harmless, but the list it came from has a Close on the same
                 * edge and a full swipe learned here is a habit carried there.
                 */
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        shelf.setArchived(false, host: hostId, window: window.id)
                    } label: {
                        Label("Put back", systemImage: "tray.and.arrow.up")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Put \(window.label) back on the list")
                    .accessibilityIdentifier("browser.archived.swipe.unarchive.\(window.id)")
                }
            }

            footnote.plainRow(top: 18, bottom: 28)

            // Room for the pill that floats over this list. See `TabBarClearance`.
            TabBarClearance()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
            Text("Swipe a window to the left and choose Archive to move it off the list. It stays "
                 + "open on the machine; it just stops being in the way.")
        }
        .accessibilityIdentifier("browser.archived.empty")
    }

    private var footnote: some View {
        Text("Archiving is something this phone does to its own list. These windows are still open "
             + "in \(model.current?.label ?? model.theMachine)'s browser, still on the page they "
             + "were on, and still reachable by any session they are attached to.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("browser.archived.footnote")
    }
}

/**
 * One archived window.
 *
 * The same two lines the live row draws, minus the chevron and minus the marks.
 * The chevron goes because the tap is not the main verb on this screen — putting
 * it back is — and the marks go with one exception: **Recording** stays. A page
 * quietly collecting every interaction is the single state this whole screen's
 * footnote exists to warn about, and hiding it on the rows that are hidden would
 * be the exact failure it warns about.
 */
private struct ArchivedWindowRow: View {
    let window: MachineWindow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(window.recording ? Theme.critical : Theme.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(window.label)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !window.url.isEmpty && window.url != window.label {
                    Text(window.url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if window.recording {
                MachineWindowMark(text: "Recording", tone: Theme.critical)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
