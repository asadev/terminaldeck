import SwiftUI
import TerminalDeckNativeCore

/// AGT: an agent's picture in a soft grey circle — a monoline symbol, an emoji,
/// or Hoot's own mark. Grey like the sidebar's icons; no colours of its own.
struct AGTIconView: View {
    let icon: AGTIcon
    var size: CGFloat = 28
    var hoot = false

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            if hoot {
                HootMark(size: size * 0.62, animated: false)
            } else {
                switch icon {
                case .symbol(let name):
                    Image(systemName: SymbolName.resolve(name, fallback: "person.crop.circle"))
                        .font(.system(size: size * 0.44, weight: .regular))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                case .emoji(let text):
                    Text(text).font(.system(size: size * 0.52))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// AGT: choose an agent's icon — symbols in six groups, or emoji — with search.
/// The selected one takes the app's accent, like every other selection.
struct AGTIconPicker: View {
    let current: AGTIcon?
    let choose: (AGTIcon?) -> Void
    @State private var tab: Tab
    @State private var query = ""

    enum Tab: String, CaseIterable { case symbols = "Symbols", emoji = "Emoji" }

    init(current: AGTIcon?, choose: @escaping (AGTIcon?) -> Void) {
        self.current = current
        self.choose = choose
        if case .emoji = current { _tab = State(initialValue: .emoji) } else { _tab = State(initialValue: .symbols) }
    }

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Kind", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                TextField("Search icons", text: $query).textFieldStyle(.roundedBorder)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if tab == .symbols {
                        ForEach(AGTIconCatalog.symbolCategories) { category in
                            let found = AGTIconCatalog.search(query, in: category.choices)
                            if !found.isEmpty {
                                Text(category.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                grid(found)
                            }
                        }
                    } else {
                        grid(AGTIconCatalog.search(query, in: AGTIconCatalog.emojiChoices))
                    }
                    if noMatches {
                        Text("No icons match “\(query)”.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 260)
            HStack {
                Text("\(AGTIconCatalog.all.count) icons").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Use the default") { choose(nil) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private var noMatches: Bool {
        let pool = tab == .symbols ? AGTIconCatalog.symbolCategories.flatMap(\.choices) : AGTIconCatalog.emojiChoices
        return AGTIconCatalog.search(query, in: pool).isEmpty
    }

    private func grid(_ choices: [AGTIconCatalog.Choice]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(choices) { choice in
                let selected = choice.icon == current
                Button { choose(choice.icon) } label: {
                    Group {
                        switch choice.icon {
                        case .symbol(let name):
                            Image(systemName: SymbolName.resolve(name, fallback: "questionmark")).font(.system(size: 14))
                                .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                        case .emoji(let text):
                            Text(text).font(.system(size: 17))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(choice.words.components(separatedBy: " ").prefix(3).joined(separator: " "))
                .accessibilityLabel(choice.words)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
