import SwiftUI
import TerminalDeckNativeCore

/// The shared agent picture: the icon picker’s symbol/emoji on a neutral rounded tile.
struct AgentAvatar: View {
    var icon: AGTIcon
    var size: CGFloat = 34
    /// The agent's colour is used only on its glyph; the tile always stays neutral.
    var tint: Color?
    var hoot = false
    /// The agent id picks a stable colour when none was chosen; `colour` is the chosen one.
    var id: String?
    var colour: String?

    init(icon: AGTIcon, size: CGFloat = 34, tint: Color? = nil, hoot: Bool = false, id: String? = nil, colour: String? = nil) {
        self.icon = icon
        self.size = size
        self.tint = tint
        self.hoot = hoot
        self.id = id
        self.colour = colour
    }

    init(agent: AGTAgent, size: CGFloat = 34, tint: Color? = nil) {
        self.init(icon: agent.icon, size: size, tint: tint, hoot: agent.isHoot, id: agent.profileID ?? agent.id, colour: agent.iconColour)
    }

    /// From a stored profile row (`id`, `icon` with an optional `@colour`).
    init(id: String, iconRaw: String?, fallback: AGTIcon = .symbol("person.crop.circle"), size: CGFloat = 34) {
        self.init(icon: AGTIcon.parse(iconRaw) ?? fallback, size: size, id: id, colour: AGTIcon.colour(iconRaw))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(DeckTokens.avatarTile)
            if hoot {
                HootMark(size: size * 0.78, animated: false)
            } else {
                switch icon {
                case .symbol(let name):
                    Image(systemName: SymbolName.resolve(name, fallback: "person.crop.circle"))
                        .font(.system(size: size * 0.52, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(glyphColour)
                case .emoji(let text):
                    Text(text).font(.system(size: size * 0.60))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var glyphColour: Color {
        if let tint { return tint }
        return AgentColour.color(id: id, chosen: colour, icon: icon)
    }
}

/// The one resolver for an agent's glyph colour: the colour chosen in its profile, else a
/// stable one from its id (same on every screen and launch). System colours adapt to light/dark.
enum AgentColour {
    static func color(named name: String) -> Color {
        switch name {
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "green": .green
        case "teal": .teal
        case "indigo": .indigo
        case "mint": .mint
        case "brown": .brown
        default: .blue
        }
    }
    static func name(id: String?, chosen: String?) -> String? {
        if let chosen, AGTIcon.colourNames.contains(chosen) { return chosen }
        return id.map { AGTIcon.stableColour(id: $0) }
    }
    static func color(id: String?, chosen: String?, icon: AGTIcon) -> Color {
        if let name = name(id: id, chosen: chosen) { return color(named: name) }
        if case .emoji = icon { return .secondary }
        return .blue
    }
}

/// Automatic plus the ten colours; picks the glyph colour in an agent's settings.
struct AgentColourPicker: View {
    let id: String?
    @Binding var colour: String?
    var body: some View {
        HStack(spacing: 6) {
            swatch(nil)
            ForEach(AGTIcon.colourNames, id: \.self) { swatch($0) }
        }
    }
    private func swatch(_ name: String?) -> some View {
        let selected = colour == name
        let fill = AgentColour.color(named: name ?? AgentColour.name(id: id, chosen: nil) ?? "blue")
        return Button { colour = name } label: {
            ZStack {
                Circle().fill(fill).frame(width: 16, height: 16)
                if name == nil { Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
            }
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name.map { $0.capitalized } ?? "Automatic")
        .accessibilityLabel(name.map { $0.capitalized } ?? "Automatic colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
