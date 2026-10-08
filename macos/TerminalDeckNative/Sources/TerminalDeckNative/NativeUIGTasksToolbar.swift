import SwiftUI
import TerminalDeckNativeCore

/// The production Tasks toolbar, driven by bindings rather than another model.
/// Keeping it independent also lets an isolated fixture render the actual controls.
struct NativeUIGTasksToolbar<Filters: View>: View {
    @Binding var tab: TasksTab
    @Binding var search: String
    @Binding var trashOpen: Bool
    @Binding var filtersOpen: Bool
    let filterCount: Int
    let matchingCount: Int
    let totalCount: Int
    let contentCount: Int
    let trashCount: Int
    @ViewBuilder let filters: () -> Filters

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { controls }
            VStack(alignment: .leading, spacing: 8) {
                if trashOpen { trashControls }
                else {
                    HStack(spacing: 10) { viewMenu; filterButton }
                    searchField
                    countLine
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private var controls: some View {
        if trashOpen { trashControls }
        else { viewMenu; searchField; filterButton; countLine }
    }

    private var trashControls: some View {
        HStack(spacing: 10) {
            Button { trashOpen = false } label: { Label("Back to tasks", systemImage: "chevron.left") }
            Text("Trash · \(trashCount)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var viewMenu: some View {
        Menu {
            ForEach(TasksTab.allCases, id: \.self) { destination in
                Button { tab = destination } label: {
                    if tab == destination { Label(destination.label, systemImage: "checkmark") }
                    else { Text(destination.label) }
                }
            }
            Divider()
            Button("Trash (\(trashCount))") { trashOpen = true }
        } label: {
            Label(tab.label, systemImage: viewSymbol)
        }
        .fixedSize()
        .accessibilityLabel("Task view: \(tab.label)")
    }

    private var searchField: some View {
        TextField("Search tasks", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160, maxWidth: 260)
            .accessibilityLabel("Search tasks")
    }

    private var filterButton: some View {
        Button { filtersOpen.toggle() } label: {
            Label(filterCount == 0 ? "Filters" : "Filters (\(filterCount))", systemImage: "line.3.horizontal.decrease")
        }
        .popover(isPresented: $filtersOpen, arrowEdge: .bottom, content: filters)
    }

    private var countLine: some View {
        Text(tab == .calendar ? "\(contentCount) this week · \(matchingCount) matching"
            : tab == .board ? "\(contentCount) on board · \(matchingCount) matching"
            : "\(matchingCount) matching · \(totalCount) total")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var viewSymbol: String {
        switch tab {
        case .table: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .calendar: "calendar"
        }
    }
}
