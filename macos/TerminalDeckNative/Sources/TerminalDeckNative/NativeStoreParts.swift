import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The Store's shared pieces, drawn in Swift — src/renderer/store/StoreFilterBar.tsx,
// StoreLogo.tsx, StoreRowName.tsx, StoreRowMore.tsx, StoreDetail.tsx and
// StoreLinkOut.tsx. Every department uses them: Browser extensions (lane B), MCP
// servers (lane E2) and Community.
//
// A department is a view the Store page embeds with the page's three props:
//     init(filter: Binding<StoreFilter>, detail: Binding<String>, onRows: @escaping ([StoreFacets]) -> Void)
// `filter` is `filter`/`onFilter`, `detail` is the open row's key ("e:…", "t:…",
// "m:…", "c:…") or "", and `onRows` reports every row's facets for the rail's counts.

/// `StoreFilterBar`: an optional search box, "N of M" with Clear while filtering, and one chip row per facet.
struct StoreFilterBarView: View {
    var placeholder = ""
    var search = true
    @Binding var filter: StoreFilter
    let controls: [FacetControl]
    let showing: Int
    let total: Int
    let active: Bool

    var body: some View {
        if search || !controls.isEmpty || active {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if search {
                        HStack(spacing: 5) {
                            Text("Search").font(.caption).foregroundStyle(.secondary)
                            TextField(placeholder, text: $filter.query)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .frame(maxWidth: 320)
                        }
                    }
                    Spacer(minLength: 0)
                    if active {
                        Text("\(showing) of \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button("Clear") { filter = .none }.buttonStyle(.link)
                    }
                }
                ForEach(controls) { control in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(control.label).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(minWidth: 90, alignment: .leading)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                StoreChip(title: control.anyName, count: control.total, on: control.value == StoreFront.any) {
                                    filter = filter.with(control.facet, StoreFront.any)
                                }
                                ForEach(control.options) { option in
                                    StoreChip(title: option.name, count: option.count, on: control.value == option.id) {
                                        filter = filter.with(control.facet, control.value == option.id ? StoreFront.any : option.id)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(control.label)
                }
            }
        }
    }
}

/// One filter chip with its count; the lit one is filled.
struct StoreChip: View {
    let title: String
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(on ? AnyShapeStyle(Color.primary.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? Color.secondary.opacity(0.45) : .clear, lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// `StoreLogo`: the item's own logo from the bundled set, else a coloured monogram.
struct StoreLogoView: View {
    let name: String
    let id: String
    var logo: String?
    var size: CGFloat = 32

    var body: some View {
        if let logo, !logo.isEmpty, let asset = StoreLogoData.assets[logo],
           let data = StoreLogoRules.imageData(asset.src), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(asset.plate ? size * 0.14 : 0)
                .frame(width: size, height: size)
                .background(asset.plate ? AnyShapeStyle(Color.white) : AnyShapeStyle(.clear), in: .rect(cornerRadius: size * 0.22))
                .clipShape(.rect(cornerRadius: size * 0.22))
                .accessibilityHidden(true)
        } else {
            Text(StoreLogoRules.monogram(name))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Self.fill(StoreLogoRules.monogramFill(id)), in: .rect(cornerRadius: size * 0.22))
                .accessibilityHidden(true)
        }
    }

    static func fill(_ n: Int) -> Color {
        switch n {
        case 1: return Color(red: 0.36, green: 0.42, blue: 0.85)
        case 2: return Color(red: 0.20, green: 0.60, blue: 0.52)
        case 3: return Color(red: 0.80, green: 0.45, blue: 0.25)
        default: return Color(red: 0.62, green: 0.35, blue: 0.72)
        }
    }
}

/// `StoreRowName`: the row's name, a button that opens the row on its own page when it can.
struct StoreRowNameView: View {
    let name: String
    var font: Font = .system(size: 14, weight: .semibold)
    var onOpen: (() -> Void)?

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { Text(name).font(font) }
                .buttonStyle(.plain)
                .help("Open \(name) on its own")
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        } else {
            Text(name).font(font)
        }
    }
}

/// Where a row is drawn: in a shelf (its details fold away) or on its own page (open).
enum StoreRowPlace { case shelf, page }

private struct StoreRowPlaceKey: EnvironmentKey {
    static let defaultValue = StoreRowPlace.shelf
}

extension EnvironmentValues {
    var storeRowPlace: StoreRowPlace {
        get { self[StoreRowPlaceKey.self] }
        set { self[StoreRowPlaceKey.self] = newValue }
    }
}

/// `StoreRowMore`: the row's fuller facts, folded on a shelf and open on the row's own page.
struct StoreRowMoreView<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.storeRowPlace) private var place
    @State private var open = false

    var body: some View {
        if place == .page {
            content
        } else {
            DisclosureGroup(isExpanded: $open) {
                content.padding(.top, 4)
            } label: {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// `StoreDetail`: "Back to <shelf>" and the one row, drawn as its own page.
struct StoreDetailView<Content: View>: View {
    let backTo: String
    let onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                Label("Back to \(backTo)", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            content.environment(\.storeRowPlace, .page)
        }
    }
}

/// `StoreLinkOut`: "Get it" (or the caller's words) — opens the http(s) page in the default browser.
struct StoreLinkOutView: View {
    let url: String
    var label = "Get it"
    let describes: String

    var body: some View {
        if let target = URL(string: url), let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            Button(label) { NSWorkspace.shared.open(target) }
                .buttonStyle(.link)
                .help(url)
                .accessibilityLabel("\(label) — \(describes)")
        }
    }
}
