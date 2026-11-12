import SwiftUI
import TerminalDeckNativeCore

/// The production Tasks toolbar, driven by bindings rather than another model.
/// Keeping it independent also lets an isolated fixture render the actual controls.
///
/// 13 Oct (the main all-tasks page): the views are tabs, and every list control is one click on the
/// bar itself: Group by, Subtasks, Columns, Filter, Closed, Me, Search. The filter popover keeps only
/// the filters.
struct NativeUIGTasksToolbar<Filters: View, ColumnsMenu: View>: View {
    var model: MyWorkModel? = nil
    @State private var columnsOpen = false
    @State private var namingView = false
    @State private var renameID: String?
    @State private var viewName = ""
    @Binding var tab: TasksTab
    @Binding var search: String
    @Binding var trashOpen: Bool
    @Binding var filtersOpen: Bool
    @Binding var groupBy: ListGroupBy
    @Binding var subtasks: SubtaskDisplay
    @Binding var sort: TasksListSort
    @Binding var showClosed: Bool
    @Binding var me: Bool
    let filterCount: Int
    let matchingCount: Int
    let totalCount: Int
    let contentCount: Int
    let trashCount: Int
    /// All projects: the list is already in project sections.
    var projectSections = false
    @ViewBuilder let columnsMenu: () -> ColumnsMenu
    @ViewBuilder let filters: () -> Filters

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trashOpen { trashControls.padding(.trailing, 36) } else {
                tabsRow.padding(.trailing, 36)
                controlsRow
            }
        }
        .overlay(alignment: .topTrailing) {
            NativePagePopoutButton(ref: ScreenRef(kind: .panel, id: "tasks"))
        }
        .controlSize(.small)
    }

    // MARK: Views as tabs

    private var tabsRow: some View {
        ScrollView(.horizontal) { HStack(alignment: .bottom, spacing: 18) {
            ForEach(TasksTab.allCases, id: \.self) { destination in
                NativeSessionButton { if let model { model.selectTab(destination) } else { tab = destination } } label: {
                    VStack(spacing: 5) {
                        Label(destination.label, systemImage: symbol(destination))
                            .font(.callout.weight(tab == destination && model?.activeViewID == nil ? .semibold : .regular))
                            .foregroundStyle(tab == destination && model?.activeViewID == nil ? Color.primary : Color.secondary)
                        Capsule().fill(tab == destination && model?.activeViewID == nil ? Color.accentColor : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == destination && model?.activeViewID == nil ? .isSelected : [])
            }
            if let model {
                ForEach(model.savedViews) { saved in
                    HStack(spacing: 4) {
                    NativeSessionButton { model.selectView(saved.id) } label: {
                        VStack(spacing: 5) {
                            Text(saved.name).font(.callout).lineLimit(1)
                            Capsule().fill(model.activeViewID == saved.id ? Color.accentColor : .clear).frame(height: 2)
                        }.frame(maxWidth: 150).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(model.activeViewID == saved.id ? .isSelected : [])
                    let edited = model.activeViewID == saved.id && model.activeViewChanged
                    if edited {
                        NativeSessionButton("Update view") { model.resaveView(saved.id) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(.bottom, 6)
                            .help("Keep the filters and columns shown now in \(saved.name)")
                    }
                    Menu {
                        NativeSessionButton("Update view") { model.resaveView(saved.id) }.disabled(!edited)
                        NativeSessionButton("Revert to saved") { model.revertView(saved.id) }.disabled(!edited)
                        Divider()
                        NativeSessionButton("Rename") { renameID = saved.id; viewName = saved.name; namingView = true }
                        NativeSessionButton("Delete view", role: .destructive) { model.deleteView(saved.id) }
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("View menu for \(saved.name)") }
                    .menuStyle(.borderlessButton).fixedSize().padding(.bottom, 6)
                    }
                }
                NativeSessionButton("+ View") { renameID = nil; viewName = ""; namingView = true }
                    .buttonStyle(.plain).padding(.bottom, 6)
                    .popover(isPresented: $namingView) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(renameID == nil ? "Save this view" : "Rename view").font(.headline)
                            NativeSessionTextField("View name", text: $viewName).sessionOnSubmit { saveName(model) }
                            HStack {
                                NativeSessionButton("Cancel") { namingView = false }
                                Spacer()
                                NativeSessionButton("Save") { saveName(model) }.disabled(viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }.padding(16).frame(width: 280)
                    }
            }
            Spacer(minLength: 8)
            countLine.padding(.bottom, 6)
            NativeSessionButton { trashOpen = true } label: {
                Label(trashCount == 0 ? "Trash" : "Trash · \(trashCount)", systemImage: "trash")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .help("Deleted tasks. Anything there can be brought back.")
        }
        }.frame(height: 34).scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task views")
    }

    private var trashControls: some View {
        HStack(spacing: 10) {
            NativeSessionButton { trashOpen = false } label: { Label("Back to tasks", systemImage: "chevron.left") }
                .buttonStyle(.bordered)
            Text("Trash · \(trashCount)").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: One click each

    private var controlsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controls; Spacer(minLength: 8); searchField }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { controls }
                searchField
            }
            VStack(alignment: .leading, spacing: 8) {
                TasksFlow(spacing: 8, lineSpacing: 8) { controls }
                searchField
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if tab == .table {
            Menu {
                Picker("Group by", selection: $groupBy) {
                    ForEach(ListGroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Group: \(groupLabel)", systemImage: "square.stack.3d.up")
            }
            .fixedSize()
            .help(projectSections ? "Inside each project, group its tasks by this" : "Group the list by this")
            Menu {
                Picker("Subtasks", selection: $subtasks) {
                    ForEach(SubtaskDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Subtasks: \(subtasks.label)", systemImage: "arrow.turn.down.right")
            }
            .fixedSize()
            .help("Child tasks under their parent: folded until you open one, or all open")
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(TasksListSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.inline)
            } label: { Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down") }
            .fixedSize()
            NativeSessionButton { columnsOpen.toggle() } label: { Label("Columns", systemImage: "rectangle.split.3x1") }
                .fixedSize().popover(isPresented: $columnsOpen) { columnsMenu() }
        }
        NativeSessionButton { filtersOpen.toggle() } label: {
            Label(filterCount == 0 ? "Filter" : "Filter · \(filterCount)", systemImage: "line.3.horizontal.decrease")
        }
        .popover(isPresented: $filtersOpen, arrowEdge: .bottom, content: filters)
        if tab == .table {
            Toggle(isOn: $showClosed) { Label("Closed", systemImage: "checkmark.circle") }
                .toggleStyle(.button)
                .help(showClosed ? "Done tasks are in their groups" : "Show Done tasks in their groups")
        }
        Toggle(isOn: $me) { Label("Me", systemImage: "person.crop.circle") }
            .toggleStyle(.button)
            .help(me ? "Showing only the tasks you have" : "Show only the tasks you have")
    }

    private var groupLabel: String {
        projectSections && (groupBy == .project || groupBy == .none) ? "Project" : groupBy.label
    }

    private var searchField: some View {
        NativeSessionTextField("Search tasks", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160, maxWidth: 240)
            .accessibilityLabel("Search tasks")
    }

    private var countLine: some View {
        Text(tab == .calendar ? "\(contentCount) this week · \(matchingCount) matching"
            : tab == .board ? "\(contentCount) on board · \(matchingCount) matching"
            : matchingCount == totalCount ? "\(totalCount) \(totalCount == 1 ? "task" : "tasks")"
            : "\(matchingCount) of \(totalCount) tasks")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func saveName(_ model: MyWorkModel) {
        guard !viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = renameID { model.renameView(id, to: viewName) } else { model.saveView(named: viewName) }
        namingView = false
    }

    private func symbol(_ tab: TasksTab) -> String {
        switch tab {
        case .table: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .calendar: "calendar"
        }
    }
}
