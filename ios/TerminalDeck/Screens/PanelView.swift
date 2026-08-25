/**
 * The four panels the desktop has — **artifacts, store, AI readiness, MCP
 * servers** — and everything the machine will let a person do to them.
 *
 * > *"what about files, artifacts, source control, store, ai readiness, mcp
 * > servers in ios app too for server"*
 *
 * > *"all what i asked for so many times, i need all no exceptions."*
 *
 * and, once all four were on the phone and all four were lists to look at:
 *
 * > *"these pages are not just to view the information — exactly all actions
 * > that we have in desktop application, they should be inside each option of
 * > them. All the features and options to edit or add or whatever the actions we
 * > have in the desktop app should be in mobile app too."*
 *
 * ## One screen for four panels, because the wire says they are one shape
 *
 * `panel.rows` carries rows, filters and buttons in one answer, and that is not
 * a shortcut taken on the host: every one of these four is a list of rows with
 * things that can be done to them, and the differences between them are in the
 * words. Four bespoke screens would be four copies of this file differing in a
 * navigation title, and the first change to the row metric would land in one of
 * them.
 *
 * So the panel id and the title come in as parameters and **everything else is
 * declared by the machine**: which filters exist, what the buttons say, what
 * each button asks for before it fires, and which of them are dangerous. This
 * file knows none of that and must not learn it. A panel that grows an action
 * next month is a change to one file in `src/main/remote/panels/` and no change
 * here at all — which is the property that made a generic frame worth it
 * instead of `mcp.add`, `mcp.remove`, `readiness.fix`, `store.install` and a
 * codec case for each, written once in TypeScript and once again in Swift.
 *
 * ## An action answers with the panel
 *
 * `panel.act` comes back as the same payload a `panel.read` would have — see the
 * rule stated at the top of `src/main/remote/panels/contract.ts`. So **this
 * screen never re-reads after acting**: the rows arriving *are* the
 * confirmation, and a second read behind every button would be a screen that
 * draws the answer twice and can disagree with itself in between.
 *
 * `notice` is the one thing that rides along — *"Added context7."* — and it is
 * drawn outside the card rather than in it, because it is an event that belongs
 * to one answer, where `note` is a standing fact about what was read.
 *
 * ## `note` is an answer, not a failure
 *
 * A host with nothing to say sends no rows and a sentence — *"No MCP servers are
 * configured for /home/asad"*. Drawn **instead of** the list, in the card, in
 * the ordinary secondary ink. An empty card under a spinner that has stopped is
 * how a person concludes the machine is broken when it has in fact answered
 * precisely. Three states, each saying which it is: waiting, an answer (rows or
 * a note), or a machine that could not answer.
 *
 * ## Which screen offers a search field, and how it knows
 *
 * **The host does not say.** `PanelRequest` carries `query` and `PanelPayload`
 * carries no flag admitting whether it was read, so there is nothing on the wire
 * to draw the field from — and a field over a panel that ignores it is a control
 * that cannot act, which is the defect this whole round is about.
 *
 * Inferring it from `scopes` was the obvious guess and it is measurably wrong:
 * `readiness.ts` declares scopes — one pill per agent the scan graded — and says
 * in its own header *"**No `query`.** The desktop panel has no search box over
 * these ten rows and neither does this."* A rule keyed on scopes would put a
 * dead field over exactly that list.
 *
 * So the set is named here, from the three host panels that actually read
 * `request.query` today: `artifacts.ts`, `store.ts` and `mcp.ts` all filter on
 * it, and readiness is the one that does not. Naming them is a phone that knows
 * something about the host it cannot verify, and it fails the safe way round: a
 * host that grows search on the fourth panel is a field that is missing until
 * this line changes, rather than a field that quietly filters nothing. The right
 * home for it is a flag on the payload, or failing that a property on
 * `PanelKind` beside `title` and `symbol`.
 *
 * ## Typing is not reading
 *
 * Each read is a frame across a relay to a machine that then walks a project. A
 * read per keystroke is four of those to type *docs*, three of which are already
 * stale when they land, so the field settles first. See `typingSettles`.
 */

import SwiftUI

// MARK: - The screen

struct PanelView: View {

    /**
     * How much of a row's sentence is drawn at rest, and when the ⓘ appears.
     *
     * Two lines is what a row can carry without the list stopping being a list.
     * The character count is deliberately a different question from the line
     * count: a sentence can wrap to three lines on a narrow phone and still be
     * short, and putting a dot next to a short sentence that merely wrapped is a
     * control that opens a sheet saying what is already on screen. 150 is about
     * two full lines at this size, measured on the 6.3-inch simulator these
     * screens are reviewed on.
     */
    static let detailLines = 2
    static let detailCharacters = 150
    /// The wire's panel id — `artifacts`, `store`, `readiness`, `mcp`. Passed
    /// through to `panel.read` untouched, so a host that grows a fifth panel
    /// needs one row in `MachineToolsSection` and nothing here.
    /// `PanelKind` rather than a string, so a panel this build cannot draw is a
    /// compile error here instead of a refused frame — and a refused frame
    /// closes the socket, which reads to a person as the network dropping.
    let panel: PanelKind
    /// What the panel is called on screen. Not derived from `panel`: the id is
    /// the wire's word and the title is the person's — `mcp` is *MCP servers*.
    let title: String
    let model: DeckModel
    /// The folder the panel is about, when the screen that pushed this knows
    /// one. `nil` lets the host answer for its own default rather than the
    /// phone inventing a path it cannot verify.
    var path: String?

    /// The filter this screen is asking under, once anything has chosen one.
    /// The host is authoritative — it may refuse a scope and answer under
    /// another — so every answer that names one overwrites this.
    @State private var scope: String?
    @State private var query = ""
    /// The pending read behind the search field. Held so the next keystroke can
    /// cancel it; this is the debounce.
    @State private var typing: Task<Void, Never>?

    /**
     * The filters and the panel's own buttons, **kept across a read**.
     *
     * `HostLink.readPanel` clears the held answer on purpose, so that a screen
     * under a new filter never draws last filter's rows under this filter's
     * caption. Read straight through, that would also take the pills and the
     * Add button off screen for the length of the round trip — the control
     * somebody just pressed vanishing under their thumb, and reappearing a
     * second later. So the chrome is held here and replaced by the next answer,
     * while the rows follow the model exactly as before.
     */
    @State private var pills: [PanelScope] = []
    @State private var offered: [PanelAction] = []

    /// The action whose form is up, and the one waiting on a yes. Two separate
    /// optionals because they present two different things, and one optional
    /// driving two presentations is the coin toss `MachineProfilesView` writes
    /// down — where the losing side of the toss is a destructive act.
    @State private var forming: PanelActionTarget?
    @State private var confirming: PanelActionTarget?

    /// The action in flight, or nil.
    ///
    /// Held here rather than on the model because this wire has no correlation
    /// id and needs none: an action answers with the whole panel, so *the panel
    /// changed* is the completion. `settle` is the backstop for an action whose
    /// answer is identical to what was already on screen — connecting a server
    /// that was already connected — where nothing would otherwise end it.
    @State private var working: String?
    @State private var settle: Task<Void, Never>?

    /// The panels whose host half reads `PanelRequest.query`. See the header for
    /// why this list is on the phone and what it costs.
    private static let searching: Set<PanelKind> = [.artifacts, .store, .mcp]

    /// How long the field waits after the last keystroke. Long enough to cover
    /// the gap between two characters typed at speed, short enough that a person
    /// who has stopped typing does not notice waiting for it.
    private static let typingSettles = Duration.milliseconds(350)

    /// How long an action may be in flight before the screen goes back to taking
    /// taps. The same figure `MachineProfilesView` waits on a clear and
    /// `DeviceRosterLink` on a revoke: long enough that a slow machine is not
    /// called dead, short enough that a person does not conclude the app is
    /// stuck.
    private static let settleAfter: TimeInterval = 30

    /**
     * The field is attached in a branch, and the branch is safe.
     *
     * `.searchable` has no "absent" state to bind to a condition, so the
     * alternative to two spellings of the screen is a field that is always
     * there — over a readiness list that cannot filter, which is the control
     * that cannot act. The usual objection to an `if` around a modifier is that
     * SwiftUI rebuilds the subtree when the condition flips; this one is
     * decided by `panel`, which is a `let`, so it cannot flip while the screen
     * is up.
     */
    var body: some View {
        if Self.searching.contains(panel) {
            screen
                .searchable(text: $query,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search")
                // A server name is not a sentence, and a command is less of one:
                // capitalising sends `Localhost` and correcting sends `local
                // host`, neither of which matches a row. The same three lines
                // the history screen and the address bar carry, for the same
                // bite.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Return means *now*, so it overtakes the settle rather than
                // adding to it.
                .onSubmit(of: .search) {
                    typing?.cancel()
                    typing = nil
                    read()
                }
                .onChange(of: query) { _, _ in settleThenRead() }
        } else {
            screen
        }
    }

    private var screen: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    folderLine
                    scopeRow
                    noticeLine
                    content
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Asked on appear rather than on first construction: this screen is
        // pushed and popped from a section that is redrawn on every capability
        // change, and a read fired from an initialiser would go out on redraws
        // nobody navigated.
        .onAppear { read() }
        .onDisappear {
            typing?.cancel()
            typing = nil
            settle?.cancel()
            settle = nil
        }
        // The answer landed. Cheap because `PanelData` is `Equatable` all the
        // way down, so an identical frame does not even fire this — which is
        // what `settle` is for.
        .onChange(of: model.panelData(panel)) { _, arrived in absorb(arrived) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                panelActions
                refreshControl
            }
        }
        .sheet(item: $forming) { target in
            PanelActionForm(title: target.subject ?? title, action: target.action) { fields in
                send(target, fields: fields)
            }
        }
        /*
         * One dialog, and it is the only way a destructive action with no form
         * can fire. *"It should give the warning also"* — and the warning is the
         * host's own `confirm` sentence, which names what is lost and is the
         * only part of this the phone could not have written.
         */
        .confirmationDialog(confirming.map { "\($0.action.label)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible,
                            presenting: confirming) { target in
            Button(target.action.label, role: .destructive) {
                confirming = nil
                send(target, fields: [:])
            }
            Button("Keep", role: .cancel) { confirming = nil }
        } message: { target in
            if let line = target.action.confirm, !line.isEmpty { Text(line) }
        }
    }

    // MARK: - Asking

    /// One read, under whatever filter and search text the screen is holding.
    /// Empty is sent as *nothing* rather than as an empty string, so a host that
    /// distinguishes the two sees the same request it would have seen from a
    /// screen with no field at all.
    private func read() {
        model.current?.readPanel(panel,
                                 path: path,
                                 scope: scope,
                                 query: query.isEmpty ? nil : query)
    }

    /// The debounce. Every keystroke cancels the read the last one queued, so a
    /// word typed at speed costs one frame rather than one per character.
    private func settleThenRead() {
        typing?.cancel()
        typing = Task {
            try? await Task.sleep(for: Self.typingSettles)
            guard !Task.isCancelled else { return }
            read()
        }
    }

    /**
     * Take what the machine said about itself.
     *
     * The rows are not copied — they are read from the model where they always
     * were. What is taken is the chrome, for the reason `pills` records, and the
     * chosen scope, because the host is entitled to answer under a different one
     * from the one that was asked for and the pills must show what is actually
     * being looked at.
     */
    private func absorb(_ data: PanelData?) {
        finished()
        guard let data else { return }
        pills = data.scopes
        offered = data.actions
        if let on = data.scopes.first(where: { $0.on })?.id { scope = on }
    }

    // MARK: - Doing

    /**
     * A button was pressed. What happens next is decided by the action, not by
     * where it was drawn.
     *
     * Fields first: an action that asks for something opens its form, and a
     * destructive one that also has fields is confirmed **inside** that form
     * rather than before it. Confirming first would ask *are you sure* about a
     * thing nobody has filled in yet, and the answer to that question is not
     * knowable until the form is complete.
     */
    private func raise(_ action: PanelAction, row: PanelRow?) {
        let target = PanelActionTarget(action: action, rowKey: row?.key, subject: row?.title)
        if !action.fields.isEmpty {
            forming = target
        } else if action.destructive {
            confirming = target
        } else {
            send(target, fields: [:])
        }
    }

    /// Off it goes. The rows are deliberately **not** cleared — see
    /// `HostLink.actOnPanel`: an action is a change to a list somebody is
    /// looking at, and blanking it for the round trip loses their place in it.
    private func send(_ target: PanelActionTarget, fields: [String: String]) {
        working = target.action.id
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .seconds(Self.settleAfter))
            guard !Task.isCancelled else { return }
            working = nil
        }
        model.current?.actOnPanel(panel,
                                  action: target.action.id,
                                  path: path,
                                  id: target.rowKey,
                                  fields: fields)
    }

    private func finished() {
        settle?.cancel()
        settle = nil
        working = nil
    }

    // MARK: - Its chrome at the top

    /*
     * One line, monospaced, truncated in the middle — because the two ends of a
     * path are what identify it and the middle is what is long.
     *
     * Drawn only when a path is known. It is not a description and it is not a
     * caption for the card: it answers *which folder is this about*, which is
     * the first question somebody has about a readiness check that says no.
     */
    @ViewBuilder
    private var folderLine: some View {
        if let path, !path.isEmpty {
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)
                .padding(.bottom, 10)
                .accessibilityIdentifier("panel.\(panel).path")
        }
    }

    /**
     * The filters, when the panel has any.
     *
     * Absent rather than empty for a panel with none — an empty bar is a control
     * strip that exists to look furnished, and there are two panels here that
     * legitimately have nothing to filter by.
     *
     * A border rather than a fill on the chosen one, which is the call
     * `BrowserTabStrip` made and wrote down: a filled accent pill in a row of
     * grey ones reads as the only *button* on the strip, where a border says
     * "this one" without claiming to be a different kind of thing.
     */
    @ViewBuilder
    private var scopeRow: some View {
        if !pills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pills) { pill in scopePill(pill) }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .padding(.bottom, 10)
        }
    }

    private func scopePill(_ pill: PanelScope) -> some View {
        let chosen = pill.id == (scope ?? pills.first(where: { $0.on })?.id)
        return Button {
            scope = pill.id
            // A search in progress is part of the question, so it goes with the
            // filter rather than being dropped by it.
            typing?.cancel()
            typing = nil
            read()
        } label: {
            Text(pill.label)
                .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? Theme.primary : Theme.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pressing the filter already being shown would re-ask the same
        // question and blank the rows to do it. It is not a dead control — it
        // is the selected segment of a picker, and it says so to VoiceOver.
        .disabled(chosen || working != nil)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(chosen ? Theme.accent : Theme.hairline, lineWidth: chosen ? 1.5 : 1))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityIdentifier("panel.\(panel).scope.\(pill.id)")
    }

    /**
     * What just happened, in the machine's own words.
     *
     * Deliberately uncoloured. A notice is *"Added context7."* on the way out
     * and `messageOf(cause)` on the way back — the host writes both into the
     * same field — so a tick over one of them would be a lie told in green. It
     * is told apart from a `note` by where it is and how it is set: outside the
     * card, over the rows, in ordinary ink, and gone on the next plain read.
     */
    @ViewBuilder
    private var noticeLine: some View {
        if let notice = model.panelData(panel)?.notice, !notice.isEmpty {
            Text(notice)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 10)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("panel.\(panel).notice")
        }
    }

    // MARK: - The toolbar

    /**
     * The panel's own buttons — *Add a server*, *Scan again*.
     *
     * In the navigation bar rather than in a strip under the caption, because a
     * strip is a second horizontal row of controls above a list that already has
     * one, and because a button that scrolls away is a button somebody scrolls
     * back for.
     *
     * One is drawn as its own words; more than one becomes a menu, because two
     * labels and a Refresh do not fit across a phone beside an inline title. The
     * cost of the menu is that XCUITest cannot reach its rows by identifier —
     * measured twice in this target — so a test that must press one asks for its
     * label instead.
     */
    @ViewBuilder
    private var panelActions: some View {
        if model.canReadPanels, !offered.isEmpty {
            if offered.count == 1, let only = offered.first {
                Button(only.label) { raise(only, row: nil) }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(only.destructive ? Theme.warning : Theme.accent)
                    .disabled(working != nil)
                    .accessibilityIdentifier("panel.\(panel).act.\(only.id)")
            } else {
                Menu {
                    ForEach(offered) { action in
                        Button(action.label,
                               role: action.destructive ? ButtonRole.destructive : nil) {
                            raise(action, row: nil)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .regular))
                }
                .disabled(working != nil)
                .accessibilityLabel("What this panel can do")
                .accessibilityIdentifier("panel.\(panel).actions")
            }
        }
    }

    /**
     * Refresh, and the one place this screen says something is in flight.
     *
     * The spinner takes the same slot rather than being added beside it: an
     * action's answer replaces the rows in place, so there is no other moment on
     * this screen where anything moves, and a phone on a slow relay with no
     * spinner anywhere is a phone somebody presses twice.
     */
    @ViewBuilder
    private var refreshControl: some View {
        if working != nil {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")
                .accessibilityIdentifier("panel.\(panel).working")
        } else {
            Button {
                typing?.cancel()
                typing = nil
                read()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .regular))
            }
            .accessibilityLabel("Refresh")
            .accessibilityIdentifier("panel.\(panel).refresh")
        }
    }

    // MARK: - The three states

    @ViewBuilder
    private var content: some View {
        // Three states from two facts: no data yet is waiting, an error is an
        // error, and data is data.
        if let problem = model.readError {
            failure(problem)
        } else if let data = model.panelData(panel) {
            rowsView(note: data.note, rows: data.rows)
        } else {
            waiting
        }
    }

    /// The rows, or the note that stands in for them.
    @ViewBuilder
    private func rowsView(note: String?, rows: [PanelRow]) -> some View {
        if rows.isEmpty {
            card { noteRow(note ?? "This machine has nothing to show here.") }
        } else {
            card {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { line }
                    panelRow(row, at: index)
                }
            }
            // A note can arrive *with* rows — "3 of 5 features installed", said
            // once under the list rather than repeated in every row.
            if let note, !note.isEmpty { footnote(note) }
        }
    }

    private var waiting: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Asking the machine…")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("panel.\(panel).loading")
    }

    /**
     * The machine could not answer — which is a different sentence from "there
     * is nothing here", and the whole reason `note` and this are separate.
     *
     * The reason is drawn because it is the host's, and it is the only thing
     * that distinguishes a dropped connection from a panel this build of the
     * desktop does not serve. Retry is here rather than only in the toolbar: a
     * person who has just been told something failed reaches for the control
     * under the failure.
     */
    private func failure(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.critical)
                    .frame(width: 24)
                Text("This machine could not answer.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
            }
            if !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
            Button("Try again") { read() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .padding(.leading, 36)
                .accessibilityIdentifier("panel.\(panel).retry")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("panel.\(panel).error")
    }

    // MARK: - Rows

    /**
     * One row: what it is on the left, what it says on the right, and what can
     * be done to it after that.
     *
     * The whole row is **not** a button. Nothing on any of these four panels
     * navigates, so a row-wide target would be a press with no outcome — and a
     * row with no actions gains nothing here at all: no chevron, no highlight,
     * no press state. Hover implies clickable is a standing rule in this app and
     * it is the rule this screen is most easily made to break, because three
     * rows out of four on an MCP panel *do* have something under the thumb.
     *
     * `children: .contain` rather than `.combine`, and it matters: combining
     * folds the buttons into the row's own label and they stop existing for
     * VoiceOver and for XCUITest. The words are combined one level in instead,
     * where they are genuinely one thing to read.
     *
     * ## The one panel where a row *does* navigate
     *
     * > *"The artifact page should be able to drive the artifacts actually — to
     * > show the visual artifacts, files and things."*
     *
     * An artifacts row is a **file**, and opening it is the whole point of the
     * page. It had a button that said *Open in Files* and answered *"Opening
     * PLAN.md."* while nothing opened, which is the control-that-cannot-act this
     * screen's own rule is about; the row is the control now and
     * {@link ArtifactView} is where it goes.
     *
     * The condition is not `panel == .artifacts` alone, and the second half is
     * what keeps the rule honest: the row must also **parse** into an
     * `ArtifactRef`. A host older than this build sends an id that does not, and
     * such a row draws no chevron and takes no tap — a list, exactly as before,
     * rather than a press that lands on a screen with nothing on it.
     */
    @ViewBuilder
    private func panelRow(_ row: PanelRow, at index: Int) -> some View {
        if panel == .artifacts, let artifact = ArtifactRef(id: row.key) {
            NavigationLink {
                ArtifactView(model: model,
                             opened: artifact,
                             title: row.title,
                             // The host's own spelling of the folder, echoed on
                             // the answer, so `panel.act` is asked about the
                             // same project the list came from rather than about
                             // whatever string this screen was pushed with.
                             project: model.panelData(panel)?.path ?? path)
            } label: {
                rowBody(row, chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("panel.\(panel).row.\(index)")
        } else {
            rowBody(row, chevron: false)
                .accessibilityIdentifier("panel.\(panel).row.\(index)")
        }
    }

    private func rowBody(_ row: PanelRow, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail, !detail.isEmpty {
                    /*
                     * **Two lines, and the rest behind the ⓘ.**
                     *
                     * > *"Here you have a very long description… remove this
                     * > full shit. I don't want any kind of long descriptions
                     * > anywhere. Just if somewhere it's very required, give the
                     * > i icon."*
                     *
                     * The host writes these and some of them are paragraphs: the
                     * readiness scanner explains what a failing check costs, in
                     * four or five lines, which is right in the desktop's panel
                     * and turns a phone list into a wall. Photographed on his own
                     * server before this: six rows filled a screen and a half.
                     *
                     * Clamped here rather than shortened at the host, because the
                     * host is also the desktop's source and that text is correct
                     * there. `PanelRow.detail` is a whole sentence either way;
                     * what changes is how much of it a phone draws at rest.
                     */
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(PanelView.detailLines)
                            .fixedSize(horizontal: false, vertical: true)
                        if detail.count > PanelView.detailCharacters {
                            InfoDot(about: row.title, text: detail)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(voiceOver(row))

            trailing(row)
            rowActions(row, at: row.index)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    /**
     * What sits on the right of a row.
     *
     * A value takes the tint. A status with **no** value would otherwise be
     * invisible — a check that passed and had nothing to print — so it becomes
     * a dot in the same colour rather than nothing at all.
     *
     * Hidden from VoiceOver because `voiceOver(row)` already says both, and a
     * reader that met them twice would hear the value, then the row, then the
     * value again.
     */
    @ViewBuilder
    private func trailing(_ row: PanelRow) -> some View {
        if let value = row.value, !value.isEmpty {
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(tint(row.status))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .accessibilityHidden(true)
        } else if row.status != nil {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint(row.status))
                .accessibilityHidden(true)
        }
    }

    /**
     * What can be done to this row.
     *
     * One action is drawn as its own word, because *Connect* under the thumb is
     * one press and *Connect* inside a menu is two for no gain. More than one
     * becomes a menu: three words beside a server name and a status is a row
     * nobody can read, and the desktop's own MCP row puts its verbs behind a
     * `…` for the same reason.
     *
     * A row with no actions gets **nothing** — not a disabled ellipsis, not a
     * chevron. See `panelRow`.
     */
    @ViewBuilder
    private func rowActions(_ row: PanelRow, at index: Int) -> some View {
        // Gone, not disabled, the moment the machine stops offering the
        // capability — a machine that dropped while this screen was up leaves
        // rows on it that are still worth reading and verbs that would be sent
        // into nothing. `HostLink.actOnPanel` refuses them anyway; a button
        // whose only outcome is a silent refusal is not a button.
        if !model.canReadPanels {
            EmptyView()
        } else if row.actions.count == 1, let only = row.actions.first {
            Button {
                raise(only, row: row)
            } label: {
                Text(only.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(only.destructive ? Theme.warning : Theme.accent)
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
            .accessibilityLabel("\(only.label) \(row.title)")
            .accessibilityIdentifier("panel.\(panel).row.\(index).act.\(only.id)")
        } else if row.actions.count > 1 {
            Menu {
                ForEach(row.actions) { action in
                    Button(action.label,
                           role: action.destructive ? ButtonRole.destructive : nil) {
                        raise(action, row: row)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    // A target rather than a glyph, at the 32 points a row this
                    // height can give without pushing the words off centre —
                    // the same trade `InfoDot` records for its own 24.
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(working != nil)
            .accessibilityLabel("What can be done to \(row.title)")
            .accessibilityIdentifier("panel.\(panel).row.\(index).more")
        }
    }

    /**
     * `ok` positive, `warn` warning, `bad` critical — and anything else plain.
     *
     * Absent means *information*, not *good*: a row saying which model a machine
     * is configured for is neither, and tinting it green would make a screen of
     * facts read as a screen of passes.
     */
    private func tint(_ status: PanelStatus?) -> Color {
        switch status {
        case .ok: return Theme.positive
        case .warn: return Theme.warning
        case .bad: return Theme.critical
        case nil: return Theme.faint
        }
    }

    /// The status said aloud, since the tint is the only thing carrying it for
    /// a sighted reader and colour is never the only channel.
    private func voiceOver(_ row: PanelRow) -> String {
        var said = row.title
        if let detail = row.detail, !detail.isEmpty { said += ". \(detail)" }
        if let value = row.value, !value.isEmpty { said += ". \(value)" }
        switch row.status {
        case .ok: said += ". OK"
        case .warn: said += ". Warning"
        case .bad: said += ". Problem"
        case nil: break
        }
        return said
    }

    /// The host's sentence when it has no rows. Inside the card, in ordinary
    /// ink — it is an answer, and an answer belongs where the answers go.
    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .accessibilityIdentifier("panel.\(panel).note")
    }

    /// A note that came *with* rows: under the card, faint, said once.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .accessibilityIdentifier("panel.\(panel).footnote")
    }

    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed, for the reason `MachineDetailView` states
     * at the same place: `SectionCaption`, `SettingsGroup` and `SettingsDivider`
     * are **private to `DeckTabs.swift`**, and a screen that reached for them
     * would have to live inside that file. Same metrics — a `Theme.surface` card
     * at radius 20, and a hairline inset to where the words start.
     *
     * 16 rather than the settings screen's 52, because these rows have no icon
     * column: the inset follows the label, and here the label starts at 16.
     */
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
