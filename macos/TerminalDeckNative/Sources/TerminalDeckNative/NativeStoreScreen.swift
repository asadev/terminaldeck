import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The Store, drawn in Swift — src/renderer/store/StorePage.tsx one for one: "Search
/// the store" with "N of M · Show everything" while narrowed, the rail (Everything,
/// then each department and its shelves, with counts), and the departments —
/// Browser extensions (lane B's view), MCP servers (lane E2's view) and Community.
struct NativeStoreScreen: View {
    @State private var model = StorePageModel()

    var body: some View {
        StoreFrame(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
            .task { await model.start() }
    }
}

@MainActor
@Observable
final class StorePageModel {
    var query = ""
    var chips: [StoreDepartmentId: StoreFilter] = [.extensions: .none, .servers: .none, .community: .none]
    var place: StorePlace = .all
    /// The open row's key ("e:…", "t:…", "m:…", "c:…"), or "".
    var detail = ""
    var rows: [StoreDepartmentId: [StoreFacets]] = [.extensions: [], .servers: [], .community: []]
    private(set) var features: [String: String] = [:]
    /// `hereName`: this machine's name from `machines:list`, else "This Mac".
    private(set) var here = "This Mac"

    func start() async {
        features = await DeckPage.features()
        if let view = try? await EngineBridge.shared.invoke("machines:list", []) as? [String: Any],
           let named = (view["here"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            here = named
        }
    }

    private func on(_ feature: String) -> Bool { (features[feature] ?? "on") == "on" }

    /// Which departments this build stocks.
    func wired(_ id: StoreDepartmentId) -> Bool {
        switch id {
        case .extensions: return NativeBrowserStoreDepartment.isWired
        case .servers: return on("mcp") && NativeMcpStoreDepartment.wired
        case .community: return true
        }
    }

    var departments: [StoreDepartmentInput] {
        [
            StoreDepartmentInput(id: .extensions, name: "Browser tools", wired: wired(.extensions),
                                 shelves: [(BrowserStore.builtInShelf, BrowserStore.builtInName)], rows: rows[.extensions] ?? [], filter: filterOf(.extensions)),
            StoreDepartmentInput(id: .servers, name: "MCP servers", wired: wired(.servers),
                                 shelves: NativeMcpStoreDepartment.shelves, rows: rows[.servers] ?? [], filter: filterOf(.servers)),
            StoreDepartmentInput(id: .community, name: "Community", wired: wired(.community),
                                 shelves: CommunityRules.shelves.filter { $0.id != "extension" }, rows: rows[.community] ?? [], filter: filterOf(.community)),
        ]
    }

    private func filterOf(_ id: StoreDepartmentId) -> StoreFilter {
        var filter = chips[id] ?? .none
        filter.query = query
        return filter
    }

    func department(_ id: StoreDepartmentId) -> StoreDepartmentInput { departments.first { $0.id == id }! }

    /// The filter a department sees (the place's shelf as its category), and what it writes back.
    func filterBinding(_ id: StoreDepartmentId) -> Binding<StoreFilter> {
        Binding(get: { StoreNav.filterFor(self.place, self.department(id)) },
                set: { next in
                    self.query = next.query
                    self.chips[id] = next
                })
    }

    func goTo(_ next: StorePlace) {
        detail = ""
        place = next
    }

    func search(_ text: String) {
        detail = ""
        query = text
    }

    func clear() {
        detail = ""
        query = ""
        chips = [.extensions: .none, .servers: .none, .community: .none]
        place = .all
    }
}

private struct StoreFrame: View {
    let model: StorePageModel

    var body: some View {
        let departments = model.departments
        let nav = StoreNav.nav(departments, model.place)
        let wired = departments.filter(\.wired)
        let stock = wired.reduce(0) { $0 + $1.rows.count }
        let empty = StoreNav.empty(departments, model.place)
        let reading = StoreNav.departmentOfRow(model.detail)
        let searching = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let narrowed = searching || model.place != .all

        // The page's column: the search on top, then the rail beside the departments.
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("adblock, cookies, youtube, postgres, github…",
                              text: Binding(get: { model.query }, set: { model.search($0) }))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                .frame(maxWidth: 640)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Search the store")
                if narrowed {
                    Text("\(StoreNav.shown(departments, model.place)) of \(stock)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Button("Show everything", action: model.clear)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)

            HStack(alignment: .top, spacing: 18) {
                StoreRail(model: model, nav: nav)
                    .frame(width: 228)
                Divider()
                ScrollView {
                    StoreContent(model: model, wired: wired, nav: nav, empty: empty, reading: reading, narrowed: narrowed)
                        .padding(.trailing, 20)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 28)
        .padding(.top, 34)
        .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The departments on the right, or the store's empty page. Every wired department
/// stays loaded, hidden when the place or a detail page leaves it out, as on the page:
/// they report their rows for the rail's counts whether they are shown or not.
private struct StoreContent: View {
    let model: StorePageModel
    let wired: [StoreDepartmentInput]
    let nav: [StoreNavDepartment]
    let empty: StoreEmpty?
    let reading: StoreDepartmentId?
    let narrowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let empty, reading == nil { emptyPage(empty) }
            ForEach(wired.map(\.id), id: \.self) { id in
                let gone = hidden(id)
                DepartmentSection(model: model, input: wired.first { $0.id == id }!, count: count(id), narrowed: narrowed)
                    .padding(.bottom, gone ? 0 : 28)
                    .frame(height: gone ? 0 : nil, alignment: .top)
                    .clipped()
                    .opacity(gone ? 0 : 1)
                    .allowsHitTesting(!gone)
                    .accessibilityHidden(gone)
            }
        }
    }

    private func emptyPage(_ empty: StoreEmpty) -> some View {
        let model = self.model
        let elsewhere = empty.elsewhere > 0
        let label: String? = elsewhere ? "Look in the whole store" : nil
        let action: (() -> Void)? = elsewhere ? { model.clear() } : nil
        return DeckPageEmpty(symbol: "bag", title: empty.title, message: empty.detail, actionLabel: label, action: action)
            .frame(minHeight: 320)
    }

    private func count(_ id: StoreDepartmentId) -> Int { nav.first { $0.id == id }?.count ?? 0 }

    private func hidden(_ id: StoreDepartmentId) -> Bool {
        if let reading { return reading != id }
        return !StoreNav.shows(model.place, id) || empty != nil || (narrowed && count(id) == 0)
    }
}

/// One department: its name (and count when nothing is narrowed), then its own view.
private struct DepartmentSection: View {
    let model: StorePageModel
    let input: StoreDepartmentInput
    let count: Int
    let narrowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(input.name).font(.system(size: 17, weight: .semibold))
                if !narrowed { Text("\(count)").font(.callout).foregroundStyle(.secondary).monospacedDigit() }
            }
            StoreDepartmentView(model: model, id: input.id)
        }
    }
}

private struct StoreDepartmentView: View {
    let model: StorePageModel
    let id: StoreDepartmentId

    var body: some View {
        let detail = Binding(get: { model.detail }, set: { model.detail = $0 })
        let report: ([StoreFacets]) -> Void = { model.rows[id] = $0 }
        switch id {
        case .community:
            CommunityDepartmentView(filter: model.filterBinding(.community), detail: detail, onRows: report)
        case .extensions:
            NativeBrowserStoreDepartment(filter: model.filterBinding(.extensions), detail: detail, onRows: report)
        case .servers:
            // The page keys an MCP row "m:<id>"; the department speaks in bare ids.
            NativeMcpStoreDepartment(
                filter: model.filterBinding(.servers),
                detail: Binding(get: { model.detail.hasPrefix("m:") ? String(model.detail.dropFirst(2)) : "" },
                                set: { model.detail = $0.isEmpty ? "" : "m:\($0)" }),
                onRows: report, projectPath: DeckProject.current, here: model.here)
        }
    }
}

/// The rail: Everything, then each department and its shelves, each with its count.
private struct StoreRail: View {
    let model: StorePageModel
    let nav: [StoreNavDepartment]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                RailButton(title: "Everything", count: StoreNav.total(nav), on: model.place == .all, shelf: false) { model.goTo(.all) }
                ForEach(nav) { entry in
                    RailButton(title: entry.name, count: entry.count, on: model.place == .department(entry.id), shelf: false) {
                        model.goTo(.department(entry.id))
                    }
                    .padding(.top, 14)
                    ForEach(entry.shelves) { shelf in
                        let chosen = model.place == .shelf(entry.id, shelf.id)
                        RailButton(title: shelf.name, count: shelf.count, on: chosen, shelf: true) {
                            model.goTo(chosen ? .department(entry.id) : .shelf(entry.id, shelf.id))
                        }
                    }
                }
            }
            .padding(.trailing, 6)
        }
        .accessibilityLabel("Departments and shelves")
    }
}

private struct RailButton: View {
    let title: String
    let count: Int
    let on: Bool
    let shelf: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout).foregroundStyle(on ? Color.primary : Color.secondary) // grey rail, no blue (Asad, 2026-10-07)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Text("\(count)").font(.caption).foregroundStyle(Color.secondary).monospacedDigit()
            }
            .padding(.leading, shelf ? 16 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(on ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
