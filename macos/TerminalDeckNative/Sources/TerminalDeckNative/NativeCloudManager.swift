import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// Cloud file manager (owner, 15 Nov, items 26, 27, 30: "I need a proper file manager where I can go inside and see things
// ... manage files, delete files, folder. I need folders shape ... go inside the folder, read ... file versus folder").
// Laid out as the lead's design section 9: places on the left (215 pt, DESIGN-FIXES CM-1), a top bar with back / forward, the crumbs, search
// and the actions for the selection, the list (Name · Changed · On · Size: folders first, then files) and a closable
// reading pane (340 pt). Rows stay clean: the two bin actions live in the top bar and the right-click menu only, and
// nothing changes on hover. The folder tree per kind is `BackendCloudManagerTree`.

/// Rows that have no name on this Mac (owner, 18 Nov, item 30: nine rows all reading "A task not on this Mac"). A task,
/// agent or project that is in the Cloud but not in this Mac's own list has no name here, so the list said the same
/// stand-in words once per row. They are ONE quiet row per place now ("9 tasks that are not on this Mac"); a click
/// selects all of them, so the bar's actions and the right-click menu still act on them. Real names are a logic job
/// (notes/review-20261118/LOGIC-HANDOFF.md, "file manager names").
enum NativeCloudNameless {
    /// The stand-in name the contents builder gives a row of this kind that has no name on this Mac (nil: the kind has
    /// none). Kept equal to `BackendCloudContents`'s own words by a test.
    static func standIn(_ kind: BackendCloudContents.Kind) -> String? {
        switch kind {
        case .tasks: "A task not on this Mac"
        case .agents: "An agent not on this Mac"
        case .projects: "A project not on this Mac"
        default: nil
        }
    }
    static func isNameless(_ item: BackendCloudContents.Item) -> Bool { standIn(item.kind) == item.name }
    /// The list's files as it shows them: the named rows, and the nameless ones apart when there are two or more (one
    /// alone stays an ordinary row).
    static func split(_ files: [BackendCloudContents.Item]) -> (named: [BackendCloudContents.Item], nameless: [BackendCloudContents.Item]) {
        let nameless = files.filter(isNameless)
        guard nameless.count > 1 else { return (files, []) }
        return (files.filter { !isNameless($0) }, nameless)
    }
    /// "9 tasks that are not on this Mac".
    static func title(_ kind: BackendCloudContents.Kind, count: Int) -> String {
        let noun: String
        switch kind {
        case .agents: noun = count == 1 ? "agent" : "agents"
        case .projects: noun = count == 1 ? "project" : "projects"
        default: noun = count == 1 ? "task" : "tasks"
        }
        return BackendCloudPageCounts.number(count) + " " + noun + (count == 1 ? " that is not on this Mac" : " that are not on this Mac")
    }
}

/// One place of the page: a kind and a folder inside it, the Bin, or Code. Back / forward walk these.
struct NativeCloudPlace: Equatable {
    var kind: BackendCloudContents.Kind
    var bin: Bool
    var code: Bool
    var path: [String]
}

/// A saved password's value after his click on Show (nil value: not on this Mac / not one plain value).
struct NativeCloudRevealed: Equatable {
    let itemId: String
    let value: String?
}

/// One crumb of the top bar.
struct NativeCloudCrumb: Identifiable {
    let id: Int
    let title: String
    let place: NativeCloudPlace
}

extension NativeCloudContentsModel {
    // MARK: Opening the page

    /// THE way to open the file manager from anywhere: the side panel's Cloud item selects the same page, and Settings ›
    /// Profile › Cloud › "Manage files" (another lane) calls this. `kind` opens that place at its top; nil keeps the place
    /// he left it on. The main window comes forward.
    static func openFileManager(kind: BackendCloudContents.Kind? = nil) {
        guard NativeCloudOffers.shows(.fileManager) else { return }
        if let kind { shared.chooseShelf(kind: kind) }
        AppModel.shared.select(Sidebar21Pages.cloudID)
        NativeLaunchWindow.ensureShown(front: true)
        // His own Manage files click (Settings › Cloud): the app is active and the click is the current event.
        NativeFront.onlyForPerson("Cloud: Manage files") { NSApp?.activate() }
    }

    // MARK: Places, folders, back and forward

    var place: NativeCloudPlace { .init(kind: kind, bin: showingBin, code: showingCode, path: path) }
    func go(to place: NativeCloudPlace) {
        if place != self.place { backStack.append(self.place); forwardStack.removeAll() }
        apply(place)
    }
    private func apply(_ place: NativeCloudPlace) {
        kind = place.kind; showingBin = place.bin; showingCode = place.code; path = place.path
        search = ""
        clearSelection()
        anchor = nil
        choose(nil)
    }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    func goBack() {
        guard let last = backStack.popLast() else { return }
        forwardStack.append(place)
        apply(last)
    }
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(place)
        apply(next)
    }
    /// A double click on a folder (or Open with one folder selected): the folder opens in place, the crumbs follow.
    func openFolder(_ folder: [String]) { go(to: .init(kind: kind, bin: false, code: false, path: folder)) }
    var crumbs: [NativeCloudCrumb] {
        if showingBin { return [.init(id: 0, title: BackendCloudFilesWords.bin, place: place)] }
        if showingCode { return [.init(id: 0, title: BackendCodeBackupWords.title, place: place)] }
        var made = [NativeCloudCrumb(id: 0, title: kind.title, place: .init(kind: kind, bin: false, code: false, path: []))]
        for index in path.indices {
            made.append(.init(id: index + 1, title: path[index], place: .init(kind: kind, bin: false, code: false, path: Array(path[...index]))))
        }
        return made
    }

    // MARK: Selection (a click selects, Command adds, Shift takes a range, a double click opens)

    /// The rows in the order the list shows them: folders, then files; the rows with no name on this Mac count as ONE
    /// row (its key is the first of them).
    var rowKeys: [String] {
        let shown = listing
        let parts = NativeCloudNameless.split(shown.files)
        return shown.folders.map(\.id) + parts.named.map(\.id) + (parts.nameless.first.map { [$0.id] } ?? [])
    }
    /// The rows of the list on show that are drawn as the one "not on this Mac" row.
    var namelessKeys: [String] { NativeCloudNameless.split(listing.files).nameless.map(\.id) }
    func isPicked(_ key: String) -> Bool { selection.contains(key) || folderSelection.contains(key) }
    var hasSelection: Bool { !selection.isEmpty || !folderSelection.isEmpty }
    func clearSelection() { selection.removeAll(); folderSelection.removeAll() }
    func setPicked(_ keys: Set<String>) {
        var keys = keys
        // Picking the one "not on this Mac" row picks every row it stands for.
        let nameless = namelessKeys
        if let first = nameless.first, keys.contains(first) { keys.formUnion(nameless) }
        folderSelection = keys.filter { $0.hasPrefix(BackendCloudManagerTree.folderPrefix) }
        selection = keys.subtracting(folderSelection)
    }
    func click(_ key: String, command: Bool = false, shift: Bool = false) {
        let keys = rowKeys
        if shift, let anchor, let from = keys.firstIndex(of: anchor), let to = keys.firstIndex(of: key) {
            setPicked(Set(keys[min(from, to)...max(from, to)]))
        } else if command {
            var now = selection.union(folderSelection)
            let nameless = namelessKeys
            if now.contains(key) { now.remove(key); if nameless.first == key { now.subtract(nameless) } } else { now.insert(key) }
            setPicked(now)
            anchor = key
        } else {
            setPicked([key])
            anchor = key
        }
        followReader()
    }
    /// Double click (or Return): a folder opens; an item opens in the reading pane.
    func activate(_ key: String) {
        if let folder = BackendCloudManagerTree.path(ofFolderId: key) { openFolder(folder); return }
        setPicked([key]); anchor = key
        if let item = model?.items.first(where: { $0.id == key }) { choose(item) }
    }
    func selectAll() { setPicked(Set(rowKeys)) }
    /// Up / down arrows move the one selection.
    func move(_ step: Int) {
        let keys = rowKeys
        guard !keys.isEmpty else { return }
        let current = anchor.flatMap { keys.firstIndex(of: $0) } ?? (step > 0 ? -1 : keys.count)
        let next = min(max(current + step, 0), keys.count - 1)
        setPicked([keys[next]]); anchor = keys[next]
        followReader()
    }
    /// While the reading pane is open it shows the one selected item.
    private func followReader() {
        guard selected != nil, let item = soleItem, item.id != selected else { return }
        choose(item)
    }
    /// The one selected item (no folder with it), or nil.
    var soleItem: BackendCloudContents.Item? {
        guard folderSelection.isEmpty, selection.count == 1, let id = selection.first else { return nil }
        return model?.items.first { $0.id == id }
    }
    /// The one selected folder (no item with it), or nil.
    var soleFolder: [String]? {
        guard selection.isEmpty, folderSelection.count == 1, let id = folderSelection.first else { return nil }
        return BackendCloudManagerTree.path(ofFolderId: id)
    }
    /// Every row the selection stands for: the selected items and everything inside the selected folders, once each.
    var selectedRows: [BackendCloudContents.Item] {
        guard let model else { return [] }
        var seen: Set<String> = []
        var rows: [BackendCloudContents.Item] = []
        for item in model.items where selection.contains(item.id) && !BackendCloudNoteIdentity.isBin(item.state) && seen.insert(item.id).inserted {
            rows.append(item)
        }
        for id in folderSelection.sorted() {
            guard let folder = BackendCloudManagerTree.path(ofFolderId: id) else { continue }
            for item in BackendCloudManagerTree.items(under: folder, kind: kind, in: model, device: device) where seen.insert(item.id).inserted {
                rows.append(item)
            }
        }
        return rows
    }
    /// The rows a right-click acts on: the selection when that row is in it, else that row alone.
    func menuRows(for key: String) -> [BackendCloudContents.Item] {
        if isPicked(key) { return selectedRows }
        let nameless = namelessKeys
        if nameless.first == key, let model { return model.items.filter { nameless.contains($0.id) } }
        if let folder = BackendCloudManagerTree.path(ofFolderId: key), let model {
            return BackendCloudManagerTree.items(under: folder, kind: kind, in: model, device: device)
        }
        return model?.items.filter { $0.id == key } ?? []
    }

    // MARK: Actions for the selection

    var canOpenSelection: Bool { soleFolder != nil || soleItem != nil }
    func openSelection() {
        if let folder = soleFolder { openFolder(folder) } else if let item = soleItem { choose(item) }
    }
    /// Space: the reading pane opens on the selected item, or closes.
    func toggleReader() {
        if selected != nil { choose(nil) } else { openSelection() }
    }
    /// The two bin actions for `rows`: nil = not offered here (hidden: settings, a closed gate for saved passwords, an
    /// owner that refuses right now); otherwise its scopes and whether a press can act now (greyed with nothing usable
    /// selected). Tasks, agents and chats: Everywhere only (`BackendCloudDeletePage.scopes`).
    func binChoice(for rows: [BackendCloudContents.Item]) -> (scopes: [CloudDeleteScope], enabled: Bool)? {
        guard !showingBin, !showingCode, kind != .settings else { return nil }
        let usable = rows.filter { $0.canRemove && $0.localMark != .onlyOnThisMac }
        let scopes = BackendCloudDeletePage.scopes(for: usable.isEmpty ? [kind] : usable.map(\.kind), gateOpen: deleteGateOpen)
        guard !scopes.isEmpty else { return nil }
        if usable.flatMap(\.deleteItems).contains(where: { deleteRefusedRoutes.contains(BackendCloudDeletePage.route($0)) }) { return nil }
        return (scopes, !usable.isEmpty && !usable.contains { pendingWhat(for: $0) != nil })
    }
    /// One press, one removal: every usable selected row (folders included) as one group, with the 10-second Undo.
    func binRows(_ rows: [BackendCloudContents.Item], scope: CloudDeleteScope) {
        let usable = rows.filter { $0.canRemove && $0.localMark != .onlyOnThisMac }
        guard !usable.isEmpty else { return }
        startDelete(usable, scope: scope)
    }
    /// The rows with a mark, by mark ("Bring back" for Not on this Mac, "Put in Cloud again" for Only on this Mac).
    func marked(_ rows: [BackendCloudContents.Item], _ mark: CloudLocalMark) -> [BackendCloudContents.Item] {
        rows.filter { $0.localMark == mark }
    }
    /// A saved password's value, only on his own press of Show, only for the open item.
    func reveal(_ item: BackendCloudContents.Item) {
        guard item.kind == .passwords, let handle = handles[item.id] else { return }
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            let id = item.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                let value = await self.secretReveal(handle)
                guard self.selected == id else { return }
                self.revealed = NativeCloudRevealed(itemId: id, value: value)
            }
        }
    }
    func hideRevealed() { revealed = nil }
}

// MARK: - The page

struct NativeCloudContentsBrowser: View {
    @Bindable var model: NativeCloudContentsModel
    let contents: BackendCloudContents
    /// 232 pt (18 Nov; was 215): "Sessions and chats" beside a three-digit count was cut ("Sessions and ch…").
    static let sidebarWidth: CGFloat = 232
    /// The reading pane (design section 9: 340 pt, closable).
    static let readerWidth: CGFloat = 340
    static let listMinimum: CGFloat = 300
    /// The reading pane's width: always 340, never taking the list below its minimum.
    static func detailWidth(total: CGFloat) -> CGFloat { max(0, min(readerWidth, total - sidebarWidth - listMinimum)) }
    /// The side panel's own symbol for the Code page (`Sidebar21Pages.standard`).
    static let codeSymbol = Sidebar21Pages.standard.first { $0.id == Sidebar21Pages.codeID }?.symbol ?? "chevron.left.forwardslash.chevron.right"

    var body: some View {
        GeometryReader { space in
            HStack(spacing: 0) {
                NativeCloudPlaces(model: model, contents: contents).frame(width: Self.sidebarWidth)
                VStack(spacing: 0) {
                    NativeCloudTopBar(model: model, contents: contents)
                    HStack(spacing: 0) {
                        main.frame(minWidth: Self.listMinimum, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        if !model.showingCode, !model.showingBin, let item = model.selectedItem {
                            NativeCloudContentsDetail(model: model, item: item)
                                .frame(width: Self.detailWidth(total: space.size.width))
                                .frame(maxHeight: .infinity)
                                .background(DeckTokens.textPrimary.opacity(0.03))
                        }
                    }
                    NativeCloudStatusBar(model: model, contents: contents)
                }
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
        }
        .task(id: NativeCloudOpenKey(item: model.selected, version: model.versionChosen, changedAt: model.selectedItem?.changedAt)) { await model.open() }
    }
    @ViewBuilder private var main: some View {
        if model.showingCode {
            ScrollView {
                NativeCodeBackupContent(model: model.code)
                    .padding(DeckTokens.Spacing.s16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("cloud.code")
        } else if model.showingBin {
            NativeCloudBinRows(model: model)
        } else {
            NativeCloudManagerList(model: model, contents: contents)
        }
    }
}

/// What the details read again when it changes.
struct NativeCloudOpenKey: Hashable {
    let item: String?
    let version: String?
    let changedAt: Int64?
}

// MARK: Places

struct NativeCloudPlaces: View {
    let model: NativeCloudContentsModel
    let contents: BackendCloudContents
    /// The design's order. Every place is always there (an empty one says so when opened); "Other" only while it holds
    /// something.
    static let order: [BackendCloudContents.Kind] = [.memory, .projects, .agents, .instructionFiles, .tasks, .settings, .artifacts,
                                                     .cloudFolder, .sessions, .passwords]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.order + (BackendCloudManagerTree.count(contents, kind: .other) > 0 ? [BackendCloudContents.Kind.other] : [])) { kind in
                        // The number is the rows the place lists, from the same listing (never a separate count).
                        place(kind.title, symbol: kind.symbol, count: BackendCloudManagerTree.count(contents, kind: kind),
                              chosen: !model.showingBin && !model.showingCode && model.kind == kind) { model.chooseShelf(kind: kind) }
                    }
                    // Mac tidy (Owner, 15 Nov): code backup, where he looks for backups. Its number counts projects.
                    place(BackendCodeBackupWords.title, symbol: NativeCloudContentsBrowser.codeSymbol, count: model.code.report?.projects.count,
                          chosen: model.showingCode) { model.chooseCode() }
                        .accessibilityIdentifier("cloud.shelf.code")
                }
            }
            Spacer(minLength: DeckTokens.Spacing.s8)
            place(BackendCloudFilesWords.bin, symbol: BackendCloudFilesWords.binSymbol,
                  count: model.binGroups.isEmpty ? nil : model.binGroups.reduce(0) { $0 + $1.count },
                  chosen: model.showingBin) { model.chooseShelf(kind: nil) }
        }
        .padding(DeckTokens.Spacing.s8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DeckTokens.textPrimary.opacity(0.03))
    }
    /// The number beside a place: what it holds, and nothing at all for a place with nothing in it (never "0"; CM-1).
    static func shownCount(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return BackendCloudPageCounts.number(count)
    }
    private func place(_ title: String, symbol: String, count: Int?, chosen: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                Image(systemName: symbol).frame(width: DeckTokens.Metrics.iconColumn)
                    .foregroundStyle(chosen ? Color.white : DeckTokens.textSecondary)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Spacer(minLength: DeckTokens.Spacing.s4)
                if let number = Self.shownCount(count) {
                    Text(number).monospacedDigit()
                        .foregroundStyle(chosen ? Color.white.opacity(0.85) : DeckTokens.textSecondary)
                }
            }
            .font(DeckTokens.Typography.body)
            .foregroundStyle(chosen ? Color.white : DeckTokens.textPrimary)
            .padding(.horizontal, DeckTokens.Spacing.s8)
            .frame(minHeight: DeckTokens.Metrics.rowMin)
            .background(chosen ? DeckTokens.accent : Color.clear, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.chipRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: Top bar

struct NativeCloudTopBar: View {
    @Bindable var model: NativeCloudContentsModel
    let contents: BackendCloudContents
    static let height: CGFloat = 52
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            backForward
            crumbs.layoutPriority(-1)
            Spacer(minLength: DeckTokens.Spacing.s8)
            if model.showingCode {
                NativeCodeBackupRefresh(model: model.code).controlSize(.small)
            } else {
                NativeCloudSearchField(text: $model.search)
                    .frame(minWidth: 110, idealWidth: 180, maxWidth: 180)
                if model.showingBin { binActions } else { actions }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, DeckTokens.Spacing.s12)
        .frame(height: Self.height)
    }
    /// Back and forward in one rounded capsule.
    private var backForward: some View {
        HStack(spacing: 0) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 24).contentShape(Rectangle()) }
                .disabled(!model.canGoBack).accessibilityLabel("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 24).contentShape(Rectangle()) }
                .disabled(!model.canGoForward).accessibilityLabel("Forward")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DeckTokens.textSecondary)
        .background(DeckTokens.textPrimary.opacity(0.06), in: Capsule())
    }
    /// The path as crumbs ("Memory › Terminal Deck › Decker"); each one opens its place.
    private var crumbs: some View {
        HStack(spacing: DeckTokens.Spacing.s4) {
            let all = model.crumbs
            ForEach(all) { crumb in
                if crumb.id > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DeckTokens.textTertiary)
                        .accessibilityHidden(true)
                }
                let last = crumb.id == all.count - 1
                Button { model.go(to: crumb.place) } label: {
                    Text(crumb.title).lineLimit(1).truncationMode(.middle)
                        .font(last ? DeckTokens.Typography.section : DeckTokens.Typography.body)
                        .foregroundStyle(last ? DeckTokens.textPrimary : DeckTokens.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(last)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud.crumbs")
    }
    /// 15 Nov (DESIGN-FIXES CM-3, CM-5): the bar is back / forward, the crumbs, search, then Open, bin "Cloud", bin
    /// "Everywhere". Nothing else: no device filter. When the selected rows are "Not on this Mac" (or "Only on this
    /// Mac"), that one action ("Bring back" / "Put in Cloud again") stands in the place of the two bin buttons; the
    /// right-click menu keeps both.
    @ViewBuilder private var actions: some View {
        let rows = model.selectedRows
        HStack(spacing: DeckTokens.Spacing.s8) {
            Button(BackendCloudManagerWords.open) { model.openSelection() }
                .disabled(!model.canOpenSelection)
            switch NativeCloudTopBar.markedAction(selected: rows.count, missing: model.marked(rows, .notOnThisMac), local: model.marked(rows, .onlyOnThisMac)) {
            case .bringBack(let missing):
                Button(CloudDeleteWords.bringBack) { model.bringBack(missing, to: .thisMac) }
            case .putInCloudAgain(let local):
                Button(CloudDeleteWords.putInCloudAgain) { model.bringBack(local, to: .cloud) }
            case .bin:
                NativeCloudDeleteButtons(model: model, rows: rows)
            }
        }
        .fixedSize()
    }
    /// What stands where the bin buttons are (CM-5): the marked rows' one action, else the bin buttons.
    enum MarkedAction<Row> {
        case bringBack([Row]), putInCloudAgain([Row]), bin
    }
    /// Only when every selected row carries that mark; a mixed selection keeps the bin buttons.
    static func markedAction<Row>(selected: Int, missing: [Row], local: [Row]) -> MarkedAction<Row> {
        if selected > 0, missing.count == selected { return .bringBack(missing) }
        if selected > 0, local.count == selected { return .putInCloudAgain(local) }
        return .bin
    }
    /// The Bin's one control: Empty Bin, or its Undo line while it waits.
    @ViewBuilder private var binActions: some View {
        if model.pending[.emptyBin] != nil {
            NativeCloudUndoLine(model: model, what: .emptyBin)
        } else if !model.binGroups.isEmpty {
            Button(BackendCloudFilesWords.emptyBin) { model.startEmptyBin() }
        }
    }
}

/// The file manager's search (18 Nov): the Settings search look (magnifier, radius 8, a quiet fill), not the system's
/// bordered box.
struct NativeCloudSearchField: View {
    @Binding var text: String
    static let height: CGFloat = 26
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DeckTokens.textSecondary).accessibilityHidden(true)
            NativeSessionTextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(DeckTokens.Typography.body)
                .accessibilityLabel("Search this place")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DeckTokens.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DeckTokens.Spacing.s8)
        .frame(height: Self.height)
        .background(DeckTokens.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
    }
}

/// The top bar's two bin buttons for the selection (greyed with nothing selected, hidden where nothing can be removed).
/// One selection is one press and one removal group.
struct NativeCloudDeleteButtons: View {
    let model: NativeCloudContentsModel
    let rows: [BackendCloudContents.Item]
    var body: some View {
        if let choice = model.binChoice(for: rows) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                if choice.scopes.contains(.cloud) {
                    Button { model.binRows(rows, scope: .cloud) } label: { Label(CloudDeleteWords.cloud, systemImage: "trash") }
                        .help("Your devices keep their copies")
                }
                Button { model.binRows(rows, scope: .everywhere) } label: { Label(CloudDeleteWords.everywhere, systemImage: "trash") }
                    .help("Removed from all devices, in the Bin for 30 days")
            }
            .fixedSize()
            .disabled(!choice.enabled)
        }
    }
}

// MARK: The list

struct NativeCloudManagerList: View {
    @Bindable var model: NativeCloudContentsModel
    let contents: BackendCloudContents
    @FocusState private var focused: Bool
    var body: some View {
        let listing = model.listing
        let parts = NativeCloudNameless.split(listing.files)
        GeometryReader { space in
            // 18 Nov: "On" and "Size" are drawn only when a row of this list has something to say there.
            let columns = NativeCloudColumnsShown(width: space.size.width,
                                                  hasOn: listing.files.contains { !BackendCloudManagerWords.onColumn($0).isEmpty },
                                                  hasSize: !listing.folders.isEmpty || listing.files.contains { !BackendCloudManagerWords.size($0).isEmpty })
            VStack(alignment: .leading, spacing: 0) {
                if model.path.isEmpty, model.search.isEmpty { placeLines }
                if listing.count == 0 {
                    // No column titles over nothing: the place's own glyph and one line.
                    NativeCloudEmptyList(symbol: !model.search.isEmpty ? "magnifyingglass" : model.path.isEmpty ? model.kind.symbol : "folder",
                                         text: !model.search.isEmpty || model.device != nil ? BackendCloudManagerWords.nothingMatches
                                             : model.path.isEmpty ? BackendCloudContentsWords.nothingYet : BackendCloudManagerWords.emptyFolder)
                } else {
                    NativeCloudColumns(shown: columns) {
                        Text(BackendCloudManagerWords.name)
                    } changed: { Text(BackendCloudManagerWords.changed) } on: { Text(BackendCloudManagerWords.on) } size: { Text(BackendCloudManagerWords.size) }
                        .font(DeckTokens.Typography.caption).foregroundStyle(DeckTokens.textSecondary)
                        .padding(.horizontal, DeckTokens.Spacing.s16)
                        .frame(height: 24)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(listing.folders) { folder in
                                NativeCloudFolderRow(folder: folder, shown: columns, picked: model.isPicked(folder.id))
                                    .modifier(NativeCloudRowClicks(model: model, key: folder.id, focus: { focused = true }))
                            }
                            ForEach(parts.named) { item in
                                NativeCloudContentsRow(item: item, model: model, shown: columns, picked: model.isPicked(item.id),
                                                       searching: !model.search.isEmpty)
                                    .modifier(NativeCloudRowClicks(model: model, key: item.id, focus: { focused = true }))
                            }
                            if let first = parts.nameless.first {
                                NativeCloudNamelessRow(items: parts.nameless, shown: columns, picked: model.isPicked(first.id))
                                    .modifier(NativeCloudRowClicks(model: model, key: first.id, focus: { focused = true }, opens: false))
                            }
                        }
                        .padding(.horizontal, DeckTokens.Spacing.s8)
                        .padding(.bottom, DeckTokens.Spacing.s8)
                    }
                }
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.clearSelection(); focused = true }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) { model.toggleReader(); return .handled }
        .onKeyPress(.return) { model.openSelection(); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.escape) {
            if model.selected != nil { model.choose(nil) } else { model.clearSelection() }
            return .handled
        }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selectAll()
            return .handled
        }
        .accessibilityIdentifier("cloud.list")
    }
    /// At the top of the Cloud folder and Artifacts only: their plain lines and "Make it again" (unchanged), and the one
    /// line when some items could not be checked.
    @ViewBuilder private var placeLines: some View {
        let lines: [String] = (model.kind == .cloudFolder ? contents.folderLines : model.kind == .artifacts ? contents.artifactsLines : [])
        let missing = (model.kind == .cloudFolder ? contents.folderAnswer : model.kind == .artifacts ? contents.artifactsAnswer : nil)?.folderMissing == true
        let replaced = model.kind == .cloudFolder ? contents.folderReplaced : []
        if !lines.isEmpty || missing || !replaced.isEmpty {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(replaced) { line in
                    HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                        Text(line.text).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DeckTokens.Spacing.s8)
                        Button("Show") { model.showFolderKept(line.id) }.controlSize(.small).fixedSize()
                    }
                }
                if missing {
                    Button(BackendCloudFolderWords.makeItAgain) { model.makeRootAgain(model.kind) }.controlSize(.small)
                }
            }
            .padding(.horizontal, DeckTokens.Spacing.s16)
            .padding(.vertical, DeckTokens.Spacing.s8)
        }
    }
}

/// A click selects (Command adds, Shift takes a range), a double click opens, a right-click shows the row's menu.
struct NativeCloudRowClicks: ViewModifier {
    let model: NativeCloudContentsModel
    let key: String
    let focus: () -> Void
    /// false for the one "not on this Mac" row: it stands for several rows with nothing to read, so a double click
    /// selects it like a single one and its menu has no Open.
    var opens = true
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                let event = NSApp?.currentEvent
                let flags = event?.modifierFlags ?? []
                if opens, (event?.clickCount ?? 1) >= 2 { model.activate(key) }
                else { model.click(key, command: flags.contains(.command), shift: flags.contains(.shift)) }
                focus()
            }
            .contextMenu { NativeCloudRowMenu(model: model, key: key, opens: opens) }
            .accessibilityAddTraits(model.isPicked(key) ? .isSelected : [])
            .accessibilityAction(named: Text(opens ? BackendCloudManagerWords.open : "Select")) {
                if opens { model.activate(key) } else { model.click(key) }
            }
    }
}

/// The right-click menu: Open, Bring back / Put in Cloud again, the two bin actions, Show in Finder, Copy name.
struct NativeCloudRowMenu: View {
    let model: NativeCloudContentsModel
    let key: String
    var opens = true
    var body: some View {
        let rows = model.menuRows(for: key)
        let folder = BackendCloudManagerTree.path(ofFolderId: key)
        if opens { Button(BackendCloudManagerWords.open) { model.activate(key) } }
        let missing = model.marked(rows, .notOnThisMac)
        let local = model.marked(rows, .onlyOnThisMac)
        if !missing.isEmpty { Button(CloudDeleteWords.bringBack) { model.bringBack(missing, to: .thisMac) } }
        if !local.isEmpty { Button(CloudDeleteWords.putInCloudAgain) { model.bringBack(local, to: .cloud) } }
        if let choice = model.binChoice(for: rows), choice.enabled {
            if opens || !missing.isEmpty || !local.isEmpty { Divider() }
            if choice.scopes.contains(.cloud) {
                Button { model.binRows(rows, scope: .cloud) } label: { Label(CloudDeleteWords.cloud + " (your devices keep their copies)", systemImage: "trash") }
            }
            Button { model.binRows(rows, scope: .everywhere) } label: { Label(CloudDeleteWords.everywhere + " (in the Bin for 30 days)", systemImage: "trash") }
        }
        if opens, folder == nil, let item = rows.first, rows.count == 1 {
            Divider()
            if model.localFile(item) != nil { Button("Show in Finder") { model.showInFinder(item) } }
            Button("Copy name") { model.copyName(item) }
        }
    }
}

/// The list's four columns (18 Nov, DESIGN-settings 6): the table is packed to the LEFT, as in Finder: Name is at most
/// 520 pt wide and Changed, On and Size follow it directly, so a date is read beside its name (before, Name stretched
/// over the whole window and the date sat a thousand points away). On and Size are drawn only when a row of the list
/// has something to say there; in a narrow list Size, then On, step aside (never squeezed or cut).
struct NativeCloudColumnsShown: Equatable {
    var on = true
    var size = true
    init(on: Bool = true, size: Bool = true) { self.on = on; self.size = size }
    init(width: CGFloat, hasOn: Bool = true, hasSize: Bool = true) { on = hasOn && width >= 520; size = hasSize && width >= 640 }
    static let nameMax: CGFloat = 520
    static let nameMin: CGFloat = 100
    static let changedWidth: CGFloat = 150
    static let onWidth: CGFloat = 130
    /// Fits "47,927 entries" (76 pt cut it to "47,927 en…").
    static let sizeWidth: CGFloat = 104
}

struct NativeCloudColumns<Name: View, Changed: View, On: View, Size: View>: View {
    let shown: NativeCloudColumnsShown
    @ViewBuilder let name: () -> Name
    @ViewBuilder let changed: () -> Changed
    @ViewBuilder let on: () -> On
    @ViewBuilder let size: () -> Size
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            name().frame(minWidth: NativeCloudColumnsShown.nameMin, maxWidth: NativeCloudColumnsShown.nameMax, alignment: .leading)
            changed().lineLimit(1).frame(width: NativeCloudColumnsShown.changedWidth, alignment: .leading)
            if shown.on { on().lineLimit(1).frame(width: NativeCloudColumnsShown.onWidth, alignment: .leading) }
            if shown.size { size().lineLimit(1).monospacedDigit().frame(width: NativeCloudColumnsShown.sizeWidth, alignment: .trailing) }
            Spacer(minLength: 0)
        }
    }
}

/// An empty place, folder or search: the place's glyph (26 pt, tertiary) over one line. No column titles over nothing.
struct NativeCloudEmptyList: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: DeckTokens.Spacing.s8 + 2) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(DeckTokens.textTertiary).accessibilityHidden(true)
            Text(text).font(DeckTokens.Typography.body).foregroundStyle(DeckTokens.textSecondary).multilineTextAlignment(.center)
        }
        .padding(DeckTokens.Spacing.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The rows with no name on this Mac, as ONE quiet row: the place's glyph, "9 tasks that are not on this Mac" in
/// secondary ink, their newest change. A click selects all of them.
struct NativeCloudNamelessRow: View {
    let items: [BackendCloudContents.Item]
    let shown: NativeCloudColumnsShown
    let picked: Bool
    var body: some View {
        let kind = items.first?.kind ?? .tasks
        let title = NativeCloudNameless.title(kind, count: items.count)
        let newest = items.map(\.changedAt).max() ?? 0
        NativeCloudColumns(shown: shown) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                Image(systemName: "square.stack").foregroundStyle(DeckTokens.textTertiary).frame(width: DeckTokens.Metrics.iconColumn)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(DeckTokens.textSecondary).lineLimit(1).truncationMode(.tail)
            }
        } changed: {
            Text(newest > 0 ? BackendCloudContentsWords.time(newest) : "").foregroundStyle(DeckTokens.textSecondary)
        } on: {
            Text("")
        } size: {
            Text("")
        }
        .font(DeckTokens.Typography.body)
        .modifier(NativeCloudRowLook(picked: picked))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A folder row: folder glyph, bold name, its newest change, how many items are inside.
struct NativeCloudFolderRow: View {
    let folder: BackendCloudManagerTree.Folder
    let shown: NativeCloudColumnsShown
    let picked: Bool
    var body: some View {
        NativeCloudColumns(shown: shown) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                Image(systemName: "folder.fill").foregroundStyle(DeckTokens.accent.opacity(0.85)).frame(width: DeckTokens.Metrics.iconColumn)
                    .accessibilityHidden(true)
                Text(folder.name).font(DeckTokens.Typography.rowTitle).lineLimit(1).truncationMode(.middle)
            }
        } changed: {
            Text(folder.changedAt > 0 ? BackendCloudContentsWords.time(folder.changedAt) : "")
        } on: {
            Text("")
        } size: {
            Text(BackendCloudManagerWords.items(folder.count))
        }
        .font(DeckTokens.Typography.body)
        .foregroundStyle(DeckTokens.textPrimary)
        .modifier(NativeCloudRowLook(picked: picked))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.name + ", folder, " + BackendCloudManagerWords.items(folder.count))
    }
}

/// One look for every row: 28 pt high, the selection as a soft accent fill. Nothing changes on hover.
struct NativeCloudRowLook: ViewModifier {
    let picked: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DeckTokens.Spacing.s8)
            .frame(minHeight: DeckTokens.Metrics.rowMin)
            .background(picked ? DeckTokens.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.chipRadius))
    }
}

/// A file row: its glyph and name (a setting with its value; while searching, the folders it sits in), when it changed,
/// where it is, its size. No buttons on the row.
struct NativeCloudContentsRow: View {
    let item: BackendCloudContents.Item
    var model: NativeCloudContentsModel? = nil
    var shown = NativeCloudColumnsShown()
    var picked = false
    var searching = false
    /// The row's one state: "Put away", "In the Bin", else where it is ("On this Mac", "Arriving on this Mac",
    /// "Sending from this Mac", "Waiting on this Mac"). Kept for the shelf, the tools and the tests.
    static func presence(_ item: BackendCloudContents.Item) -> String {
        item.deleteLine ?? item.localMark?.title ?? item.elsewhere ?? BackendCloudFilesWords.state(item.state) ?? BackendCloudContentsWords.presenceLine(item.presence)
    }
    /// CLOUD-FILES-4: the row's place line (where it belongs, how many entries).
    static func placeLine(_ item: BackendCloudContents.Item) -> String? {
        let parts = [item.place, item.entries.map(BackendCloudContentsWords.entries)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// CLOUD-FILES-4: the row's date, always in full ("Yesterday, 11:18 AM"; in the Bin: "Removed 14 Nov").
    static func dateLine(_ item: BackendCloudContents.Item, now: Date = Date()) -> String {
        if case .inBin(let removedAt) = item.state { return BackendCloudFilesWords.goesOn(removedAt) }
        return BackendCloudContentsWords.time(item.changedAt, now: now)
    }
    /// Its state and its date in one line of text (the reading pane and the tests).
    static func stateAndDate(_ item: BackendCloudContents.Item, now: Date = Date()) -> String {
        (item.localMark?.title ?? presence(item)) + " · " + dateLine(item, now: now)
    }
    /// The glyph: a document for files, the kind's own symbol for things that are not files.
    static func symbol(_ item: BackendCloudContents.Item) -> String {
        switch item.kind {
        case .memory, .instructionFiles, .cloudFolder, .artifacts: return item.entries == nil ? "doc.text" : item.kind.symbol
        case .tasks: return "checkmark.circle"
        case .settings: return "gearshape"
        case .passwords: return "key"
        case .agents: return "person"
        case .projects: return "square.stack.3d.up"
        case .sessions: return "bubble.left"
        case .other: return "doc"
        }
    }
    var body: some View {
        let pending = model?.pendingWhat(for: item) != nil
        // CM-2: empty in the normal state; only "Not on this Mac" / "Only on this Mac". The rest is in the reading pane.
        let on = BackendCloudManagerWords.onColumn(item)
        NativeCloudColumns(shown: shown) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                Image(systemName: Self.symbol(item)).foregroundStyle(DeckTokens.textSecondary).frame(width: DeckTokens.Metrics.iconColumn)
                    .accessibilityHidden(true)
                Text(item.name).lineLimit(1).truncationMode(.tail)
                if let value = item.value {
                    Text(value).foregroundStyle(DeckTokens.textSecondary).lineLimit(1).layoutPriority(-1)
                } else if searching, !item.folder.isEmpty {
                    Text(item.folder.joined(separator: " › ")).foregroundStyle(DeckTokens.textSecondary).lineLimit(1).truncationMode(.head).layoutPriority(-1)
                }
            }
        } changed: {
            Text(Self.dateLine(item)).foregroundStyle(DeckTokens.textSecondary)
        } on: {
            Text(on).foregroundStyle(DeckTokens.textSecondary)
        } size: {
            Text(BackendCloudManagerWords.size(item)).foregroundStyle(DeckTokens.textSecondary)
        }
        .font(DeckTokens.Typography.body)
        .opacity(pending ? 0.55 : 1)
        .modifier(NativeCloudRowLook(picked: picked))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Status bar

/// The bottom line: how many items, the selection, the one line after a change, every Undo still waiting, and (in
/// Memory) Clean up of earlier versions.
struct NativeCloudStatusBar: View {
    let model: NativeCloudContentsModel
    let contents: BackendCloudContents
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            if !model.showingBin, !model.showingCode {
                let shown = model.listing.count
                let picked = model.selection.count + model.folderSelection.count
                Text(picked > 0 ? "\(picked) of \(BackendCloudManagerWords.items(shown)) selected" : BackendCloudManagerWords.items(shown))
                    .foregroundStyle(DeckTokens.textSecondary)
            }
            if let line = model.deleteReadProblem ?? model.actionLine {
                Text(line).foregroundStyle(DeckTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: DeckTokens.Spacing.s8)
            ForEach(Array(model.pending.keys).filter { $0 != .emptyBin && $0 != .cleanUp }, id: \.self) { what in
                NativeCloudUndoLine(model: model, what: what)
            }
            if model.pending[.cleanUp] != nil {
                NativeCloudUndoLine(model: model, what: .cleanUp)
            } else if !model.showingBin, !model.showingCode, model.kind == .memory, contents.versionsToClean > 0 {
                // 18 Nov: a quiet text button (it was the only bordered thing on the bottom line).
                Button { model.startCleanUp() } label: {
                    HStack(spacing: DeckTokens.Spacing.s4) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).accessibilityHidden(true)
                        Text(BackendCloudFilesWords.cleanUp(contents.versionsToClean))
                    }
                    .foregroundStyle(DeckTokens.textSecondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .fixedSize()
            }
        }
        .font(DeckTokens.Typography.callout)
        .controlSize(.small)
        .padding(.horizontal, DeckTokens.Spacing.s16)
        .frame(height: 30)
    }
}

/// "Removing… Undo": the 10 seconds in which one change can still be taken back.
struct NativeCloudUndoLine: View {
    let model: NativeCloudContentsModel
    let what: NativeCloudUndo.What
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            Text(model.pending[what]?.line ?? "").font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
            Button(BackendCloudFilesWords.undo) { model.undo(what) }.controlSize(.small)
        }
        .fixedSize()
    }
}

// MARK: Reading pane

/// The open item, read only: what it is, where it sits, who changed it and when, its text (or its facts), a setting's
/// value, a saved password's value only after Show, and its earlier versions. Closable (Escape or the close button).
struct NativeCloudContentsDetail: View {
    let model: NativeCloudContentsModel
    let item: BackendCloudContents.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { model.choose(nil) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(DeckTokens.textSecondary)
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, DeckTokens.Spacing.s8)
            .padding(.top, DeckTokens.Spacing.s4)
            ScrollView {
                VStack(alignment: .leading, spacing: DeckTokens.Spacing.s16) {
                    header
                    if item.kind == .settings, let value = item.value {
                        Text(value).font(DeckTokens.Typography.section).textSelection(.enabled)
                    }
                    if item.kind == .passwords { secret }
                    content
                    versions
                    // CM-4: "Copy name" left the pane (it stays in the right-click menu).
                    if model.localFile(item) != nil {
                        Button("Show in Finder") { model.showInFinder(item) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, DeckTokens.Spacing.s16)
                .padding(.bottom, DeckTokens.Spacing.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("cloud.reader")
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
            // CLOUD-FILES-6: with an earlier version chosen, the header is THAT version's: its own title, Mac and time.
            let chosen = model.chosenVersion
            Text(chosen?.title ?? item.name).font(DeckTokens.Typography.section).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(([item.kind.title] + item.folder).joined(separator: " › "))
                .font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let file = item.fileName, file != item.name {
                Text(file).font(DeckTokens.Typography.caption).foregroundStyle(DeckTokens.textTertiary).textSelection(.enabled)
            }
            Text(chosen.map { BackendCloudFilesWords.chosenVersion($0) }
                 ?? (BackendCloudNoteIdentity.isBin(item.state) ? item.changedBy : BackendCloudContentsWords.changedBy(item.changedBy))
                    + " · " + BackendCloudContentsWords.time(item.changedAt))
                .font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            // CM-2: where it is, written in full (every device it still waits for, by name).
            Text(BackendCloudManagerWords.onInFull(item)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let state = item.deleteLine ?? item.elsewhere ?? BackendCloudFilesWords.state(item.state) {
                Text(state).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
            }
            if let note = item.note { Text(note).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.warn) }
        }
    }
    /// A note (memory, instruction files, any Markdown file) is drawn formatted; other text (JSON, a log) stays as it is.
    static func readsAsNote(_ item: BackendCloudContents.Item) -> Bool {
        if [.memory, .instructionFiles].contains(item.kind) { return true }
        let file = (item.fileName ?? item.name).lowercased()
        return file.hasSuffix(".md") || file.hasSuffix(".markdown")
    }
    /// A saved password: its value only after a click on Show, hidden again with Hide or any other selection.
    @ViewBuilder private var secret: some View {
        if let shown = model.revealed, shown.itemId == item.id {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                if let value = shown.value {
                    Text(value).font(DeckTokens.Typography.mono).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DeckTokens.Spacing.s12)
                        .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
                } else {
                    Text(BackendCloudManagerWords.noValue).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                }
                Button(BackendCloudManagerWords.hide) { model.hideRevealed() }.controlSize(.small)
            }
        } else {
            Button(BackendCloudManagerWords.show) { model.reveal(item) }
                .controlSize(.small)
                .accessibilityIdentifier("cloud.reader.show")
        }
    }
    /// The open item's text (or the chosen earlier version's), read only; for a kind with nothing to read, its facts.
    @ViewBuilder private var content: some View {
        let shown = model.opened?.itemId == item.id && model.opened?.versionId == model.versionChosen ? model.opened : nil
        if let text = shown?.text, !text.isEmpty, Self.readsAsNote(item) {
            // CM-4: a note reads as formatted text (the app's one markdown reader), never raw markdown in a mono box.
            NativeChatMarkdown(text: text).frame(maxWidth: .infinity, alignment: .leading)
        } else if let text = shown?.text, !text.isEmpty {
            Text(text).font(DeckTokens.Typography.mono).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DeckTokens.Spacing.s12)
                .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
        } else if shown != nil || !item.canOpen {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                if let about = item.about {
                    Text(about).font(DeckTokens.Typography.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, DeckTokens.Spacing.s4)
                }
                if let line = shown?.line ?? (shown != nil && item.canOpen ? NativeCloudContentsModel.textUnreadable : nil) {
                    Text(line).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, DeckTokens.Spacing.s4)
                }
                ForEach(item.presence, id: \.self) { Text($0).font(DeckTokens.Typography.callout) }
                if let entries = item.entries { Text(BackendCloudContentsWords.entries(entries)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary) }
                if let bytes = item.bytes { Text(BackendCloudContentsWords.size(bytes)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary) }
            }
        }
    }
    /// "Earlier versions": date and which Mac made it, newest first, only while they are kept. Choosing one shows it;
    /// "Use this version" makes it the newest everywhere.
    @ViewBuilder private var versions: some View {
        let list = model.versions(item)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(BackendCloudFilesWords.earlierVersions).font(DeckTokens.Typography.rowTitle)
                    .padding(.bottom, DeckTokens.Spacing.s4)
                versionRow(nil, BackendCloudFilesWords.current, chosen: model.versionChosen == nil) { model.versionChosen = nil }
                ForEach(list) { version in
                    versionRow(BackendCloudFilesWords.versionTitle(version), BackendCloudFilesWords.version(version),
                               chosen: model.versionChosen == version.id) { model.versionChosen = version.id }
                }
                if let chosen = model.chosenVersion, chosen.canUse {
                    Button(BackendCloudFilesWords.useThisVersion) { model.useChosenVersion() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, DeckTokens.Spacing.s8)
                }
            }
        }
    }
    private func versionRow(_ title: String?, _ text: String, chosen: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(DeckTokens.Typography.callout).fixedSize(horizontal: false, vertical: true)
                if let title {
                    Text(title).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary).lineLimit(2).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DeckTokens.Spacing.s8)
            .padding(.vertical, DeckTokens.Spacing.s4)
            .background(chosen ? DeckTokens.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: The Bin (tonight's design, unchanged: one line per removal, Put back all, a line opens to its items)

struct NativeCloudBinRows: View {
    @Bindable var model: NativeCloudContentsModel
    private var groups: [CloudBinGroup] {
        let search = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.binGroups.filter { group in
            (model.device == nil || group.macName == model.device)
                && (search.isEmpty || BackendCloudDeletePage.groupLine(group).localizedCaseInsensitiveContains(search)
                    || group.items.contains { $0.name.localizedCaseInsensitiveContains(search) })
        }
    }
    var body: some View {
        if groups.isEmpty {
            Text(model.binGroups.isEmpty ? BackendCloudFilesWords.binEmpty : BackendCloudManagerWords.nothingMatches)
                .foregroundStyle(DeckTokens.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DeckTokens.Spacing.s12) {
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded: Binding(get: { model.expandedBinGroups.contains(group.id) }, set: { open in
                            if open { model.expandedBinGroups.insert(group.id) } else { model.expandedBinGroups.remove(group.id) }
                        })) {
                            ForEach(group.items, id: \.selfKey) { item in
                                HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s8) {
                                    Text(BackendCloudContentsWords.plain(item.name) ?? BackendCloudDeletePage.kind(item).title)
                                        .font(DeckTokens.Typography.rowTitle).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if BackendCloudDeletePage.canPutBackAlone(item, in: group) {
                                        Button(BackendCloudFilesWords.putBack) { model.putBackBinItem(item, group: group) }
                                    }
                                    Button("Delete for good") { model.deleteForGood([item]) }
                                }
                                .controlSize(.small).padding(.vertical, DeckTokens.Spacing.s4)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                                Text(BackendCloudDeletePage.groupLine(group)).font(DeckTokens.Typography.callout)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                Button(model.busyBin.contains(group.id) ? "Putting back…" : CloudDeleteWords.putBackAll) { model.putBackGroup(group) }
                                    .controlSize(.small).fixedSize().disabled(model.busyBin.contains(group.id))
                            }
                        }
                    }
                }
                .padding(DeckTokens.Spacing.s16)
            }
        }
    }
}

private extension CloudDeleteItem {
    var selfKey: String { BackendCloudDeletePage.key(self) }
}
