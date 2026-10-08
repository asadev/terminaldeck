import SwiftUI
import TerminalDeckNativeCore

/// The five inventories within one server's Advanced view. Counts remain absent
/// until that inventory has been read, rather than implying an empty server.
struct NativeDockerSectionList: View {
    @Binding var section: NativeDockerSection
    let counts: [NativeDockerSection: Int]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Docker")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 5)
                    .accessibilityAddTraits(.isHeader)

                ForEach(NativeDockerSection.allCases) { item in
                    NativeDockerSectionRow(
                        title: item.title,
                        symbol: item.symbol,
                        count: counts[item],
                        selected: section == item
                    ) { section = item }
                }
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Docker categories")
    }
}

/// A local search and explicit row selection avoid the system List's blue fill.
/// Refreshing keeps the last good rows visible; the parent owns server requests.
struct NativeDockerInventoryList: View {
    let items: [NativeDockerItem]
    @Binding var selection: String?
    @Binding var search: String
    let section: NativeDockerSection
    let loading: Bool
    let error: String?
    let retry: () -> Void

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [NativeDockerItem] {
        guard !query.isEmpty else { return items }
        return items.filter { item in
            [item.name, item.subtitle, item.state, item.id]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            if let error, !items.isEmpty {
                errorBanner(error)
                Divider()
            }

            inventory
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !items.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Text(query.isEmpty ? "\(items.count) \(items.count == 1 ? section.singular : section.title.lowercased())" : "\(filteredItems.count) of \(items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if loading {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel("Refreshing \(section.title.lowercased())")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .accessibilityLabel(section.title)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search \(section.title.lowercased())", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .accessibilityLabel("Search \(section.title.lowercased())")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
        .padding(10)
    }

    @ViewBuilder private var inventory: some View {
        if items.isEmpty && loading {
            NativeDockerInventorySkeleton(section: section)
        } else if items.isEmpty, let error {
            NativePageEmpty(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load \(section.title.lowercased())",
                action: PageEmptyAction(label: "Try again", primary: false, perform: retry)
            ) { Text(error) }
        } else if items.isEmpty {
            NativeDockerEmptyView(
                symbol: section.symbol,
                title: "No \(section.title.lowercased()) yet",
                message: emptyMessage
            )
        } else if filteredItems.isEmpty {
            NativePageEmpty(
                symbol: "magnifyingglass",
                title: "No matches",
                action: PageEmptyAction(label: "Clear search", primary: false, perform: { search = "" })
            ) { Text("Try a different name, ID or state.") }
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredItems) { item in
                        NativeDockerInventoryRow(
                            item: item,
                            symbol: section.symbol,
                            selected: selection == item.id
                        ) { selection = item.id }
                    }
                }
                .padding(7)
            }
        }
    }

    private var emptyMessage: String {
        switch section {
        case .containers: "Containers on this Docker host will appear here."
        case .images: "Images on this Docker host will appear here."
        case .volumes: "Volumes store data that can outlive a container."
        case .networks: "Docker networks on this host will appear here."
        case .projects: "Compose projects appear when their containers have Compose labels."
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            NativeCodingAINotice(tone: .error, text: "Couldn't refresh. \(message)")
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(loading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inspect data uses selectable, wrapping values so IDs and paths stay readable.
struct NativeDockerFactsView: View {
    let facts: [NativeDockerFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Several mounts or environment facts can legitimately share a label.
            // Position identifies these read-only rows without duplicate label IDs.
            ForEach(facts.indices, id: \.self) { index in
                let fact = facts[index]
                NativeSettingRow(label: fact.label) {
                    Text(fact.value.isEmpty ? "—" : fact.value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                if index < facts.count - 1 { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrap the shared app empty-state layout rather than introduce a second style.
struct NativeDockerEmptyView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        NativePageEmpty(symbol: symbol, title: title) { Text(message) }
    }
}

private struct NativeDockerSectionRow: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 3)
                if let count {
                    Text(count.formatted())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.1) : hovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0) items" } ?? "Not loaded")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NativeDockerInventoryRow: View {
    let item: NativeDockerItem
    let symbol: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.callout.weight(selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !item.state.isEmpty {
                        HStack(spacing: 5) {
                            if let running = item.running {
                                Image(systemName: running ? "circle.fill" : "circle")
                                    .font(.system(size: 6))
                                    .accessibilityHidden(true)
                            }
                            Text(item.state).lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.1) : hovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help([item.name, item.subtitle, item.state].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue([item.subtitle, item.state].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NativeDockerInventorySkeleton: View {
    let section: NativeDockerSection

    var body: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(0..<6) { index in
                    NativeDockerInventoryRow(
                        item: NativeDockerItem(
                            id: "loading-\(index)",
                            name: "Reading \(section.singular)",
                            subtitle: "Getting details from this Docker host",
                            state: "Checking state"
                        ),
                        symbol: section.symbol,
                        selected: false,
                        choose: {}
                    )
                    .redacted(reason: .placeholder)
                    .allowsHitTesting(false)
                }
            }
            .padding(7)
            .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NativePageNote("Loading…", busy: true)
                .frame(height: 42)
        }
        .accessibilityLabel("Loading Docker inventory")
    }
}
