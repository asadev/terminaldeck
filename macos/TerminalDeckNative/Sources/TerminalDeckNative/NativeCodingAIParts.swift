import SwiftUI
import TerminalDeckNativeCore

// Small pieces the Coding AI screen is built from: the ⓘ, a notice line, an
// agent's mark, an account's dot, and a badge.

/// The ⓘ: the long half of an explanation, on hover (tooltip) and on click (popover).
struct NativeCodingAIInfo: View {
    let label: String
    let text: String
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .accessibilityLabel("About \(label)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(14)
        }
    }
}

/// One line of news: info, a warning, or an error.
struct NativeCodingAINotice: View {
    enum Tone { case info, warn, error }
    let tone: Tone
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.callout)
    }

    private var symbol: String {
        switch tone {
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .info: return .accentColor
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// A small capsule beside a name ("Default", "Your own install").
struct NativeCodingAIBadge: View {
    let text: String
    var quiet = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(quiet ? Color.secondary : Color.accentColor)
            .background(Capsule().fill(quiet ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.14)))
    }
}

/// An account's dot, in the colour the engine stored for it.
struct NativeCodingAIDot: View {
    let token: String?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        guard let token else { return .secondary }
        switch CodingAIDotColor.of(token) {
        case .accent: return .accentColor
        case .green: return .green
        case .amber: return .yellow
        case .orange: return .orange
        case .red: return .red
        }
    }
}

/// The mark beside a sign-in state: green in, grey out, amber unknown.
struct NativeCodingAIStateMark: View {
    let state: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case "signed-in": return .green
        case "signed-out", "unsupported": return .secondary
        default: return .yellow
        }
    }
}

/// An agent's mark, drawn from the same geometric rules as the web's `ProviderBadge`
/// (a 16-unit box; strokes for three, a fill for Gemini). Nothing for an unknown agent.
struct NativeCodingAIProviderMark: View {
    let provider: String?
    var size: CGFloat = 14

    var body: some View {
        if let provider, ["claude", "codex", "gemini", "shell"].contains(provider) {
            Canvas { context, canvas in
                let scale = canvas.width / 16
                let style = StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
                let ink = GraphicsContext.Shading.foreground
                func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
                switch provider {
                case "claude":
                    var path = Path()
                    for index in 0..<8 {
                        let angle = CGFloat(index) * .pi / 4
                        path.move(to: point(8 + cos(angle) * 1.6, 8 - sin(angle) * 1.6))
                        path.addLine(to: point(8 + cos(angle) * 6.2, 8 - sin(angle) * 6.2))
                    }
                    context.stroke(path, with: ink, style: style)
                case "codex":
                    var path = Path()
                    path.move(to: point(13.2, 5))
                    for (x, y) in [(13.2, 11.0), (8, 14), (2.8, 11), (2.8, 5), (8, 2)] { path.addLine(to: point(x, y)) }
                    path.move(to: point(8, 2)); path.addLine(to: point(10.4, 3.4))
                    path.move(to: point(13.2, 5)); path.addLine(to: point(10.9, 6.35))
                    context.stroke(path, with: ink, style: style)
                case "gemini":
                    var path = Path()
                    path.move(to: point(8, 1.4))
                    path.addQuadCurve(to: point(14.6, 8), control: point(9.1, 6.9))
                    path.addQuadCurve(to: point(8, 14.6), control: point(9.1, 9.1))
                    path.addQuadCurve(to: point(1.4, 8), control: point(6.9, 9.1))
                    path.addQuadCurve(to: point(8, 1.4), control: point(6.9, 6.9))
                    path.closeSubpath()
                    context.fill(path, with: ink)
                default:
                    var path = Path()
                    path.move(to: point(3.6, 4.8)); path.addLine(to: point(7.4, 8)); path.addLine(to: point(3.6, 11.2))
                    path.move(to: point(8.8, 11.6)); path.addLine(to: point(12.6, 11.6))
                    context.stroke(path, with: ink, style: style)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

/// A command a person can copy (an install line).
struct NativeCodingAICommand: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
    }
}
