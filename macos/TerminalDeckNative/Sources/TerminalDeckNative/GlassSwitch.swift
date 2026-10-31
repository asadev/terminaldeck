import AppKit
import SwiftUI

struct DeckSwitchItem<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
    let symbol: String?
    init(id: Value, title: String, symbol: String? = nil) {
        self.id = id; self.title = title; self.symbol = symbol
    }
}

struct GlassSwitch<Value: Hashable>: View {
    @Binding private var selection: Value
    private let items: [DeckSwitchItem<Value>]
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(selection: Binding<Value>, items: [DeckSwitchItem<Value>]) {
        // Design rule: 2–5 distinct views. Never crash the app over it: keep the first
        // five distinct ids (the owner's order) and draw whatever remains.
        var seen = Set<Value>()
        _selection = selection
        self.items = Array(items.filter { seen.insert($0.id).inserted }.prefix(5))
    }

    var body: some View {
        // No GlassEffectContainer and no glass on the selection: in a real window the container
        // composited its glass OVER the labels (empty frosted pill, ghosted titles; 10 Oct walk).
        // The cluster is glass behind the content; the selection is a solid pill.
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = selection == item.id
                Button {
                    guard item.id != selection else { return }
                    if reduceMotion { selection = item.id }
                    else { withAnimation(.smooth(duration: 0.2)) { selection = item.id } }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = item.symbol { Image(systemName: symbol).imageScale(.small) }
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: DeckTokens.Metrics.iconHit, minHeight: 30, maxHeight: 30)
                    .contentShape(Capsule())
                    .background {
                        if selected {
                            Capsule()
                                .fill(DeckTokens.switchPill)
                                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                                .overlay(Capsule().strokeBorder(DeckTokens.hairline, lineWidth: 0.5))
                                .matchedGeometryEffect(id: "selection", in: glass)
                        }
                    }
                }
                .buttonStyle(.plain)
                // Each segment keeps its own ideal width (equal shares truncated long titles).
                .frame(minWidth: DeckTokens.Metrics.iconHit)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background {
            if reduceTransparency {
                Capsule().fill(DeckTokens.card)
            } else {
                Capsule().fill(DeckTokens.selection).glassEffect(.regular, in: .capsule)
            }
        }
        .overlay(Capsule().strokeBorder(DeckTokens.hairline, lineWidth: 1).allowsHitTesting(false))
        // Publish the real cluster minimum when HeaderLayout probes width0;
        // a final minWidth0 frame would hide the segments' 28pt minima.
        .frame(minWidth: CGFloat(items.count) * DeckTokens.Metrics.iconHit + CGFloat(max(0, items.count - 1)) * 2 + 8,
               maxWidth: .infinity)
        .transaction { transaction in if reduceMotion { transaction.animation = nil } }
        .accessibilityElement(children: .contain)
    }
}
