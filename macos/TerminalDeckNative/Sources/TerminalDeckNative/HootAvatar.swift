import SwiftUI
import TerminalDeckNativeCore

/// Shared Hoot picture. Tasks are view-scoped; removing the avatar cancels its eye animations.
struct HootAvatar: View {
    enum State: String, CaseIterable, Sendable {
        case awake, thinking, working, waiting, stopped

        @MainActor var colour: Color {
            switch self {
            case .awake: AGKITStyle.good
            case .thinking, .working: AGKITStyle.hoot
            case .waiting: AGKITStyle.warn
            case .stopped: AGKITStyle.textTertiary
            }
        }

        var label: String {
            switch self {
            case .awake: "Awake"
            case .thinking: "Thinking"
            case .working: "Working"
            case .waiting: "Waiting for you"
            case .stopped: "Stopped"
            }
        }
    }

    var state: State = .awake
    var size: CGFloat = 40
    var animated = true
    var showsStatus = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lid: CGFloat = 0
    @State private var glance: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(AGKITStyle.card)
            Circle().strokeBorder(AGKITStyle.hairline, lineWidth: 0.5)
            // Reuse the existing brand vector. Its original 7–9.5s blink is disabled;
            // the same lids below use this design's 4–7s cadence instead.
            HootMark(size: markSize, animated: false)
                .overlay { eyes }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if showsStatus {
                Circle().fill(state.colour)
                    .frame(width: dotSize, height: dotSize)
                    .background(Circle().fill(AGKITStyle.page).padding(-2))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hoot")
        .accessibilityValue(state.label)
        .task(id: moves) { await blink() }
        .task(id: thinks) { await lookAround() }
    }

    private var markSize: CGFloat { size * 0.75 }
    private var dotSize: CGFloat { max(7, size * 0.275) }
    private var moves: Bool { animated && !reduceMotion }
    private var thinks: Bool { moves && state == .thinking }

    private var eyes: some View {
        let scale = markSize / HootArt.viewBox.width
        return ZStack(alignment: .topLeading) {
            if thinks {
                // Replace just the eye whites and pupils, preserving the original glasses and art.
                ForEach([CGFloat(23), CGFloat(41)], id: \.self) { centre in
                    ZStack {
                        Circle().fill(.white)
                        Circle().fill(artColour(HootArt.Colour.pupil))
                            .frame(width: 6 * scale, height: 6 * scale)
                            .offset(x: 0.6 * scale + glance * size / 40, y: 0.6 * scale)
                        Circle().fill(.white)
                            .frame(width: 2 * scale, height: 2 * scale)
                            .offset(x: 1.6 * scale + glance * size / 40, y: -0.6 * scale)
                    }
                    .frame(width: 10.8 * scale, height: 10.8 * scale)
                    .clipShape(Circle())
                    .offset(x: (centre - 5.4) * scale, y: (26 - 5.4) * scale)
                }
            }
            if moves {
                ForEach(HootArt.lids.indices, id: \.self) { index in
                    let eye = HootArt.lids[index]
                    Circle().fill(artColour(HootArt.Colour.body))
                        .frame(width: eye.r * 2 * scale, height: eye.r * 2 * scale)
                        .scaleEffect(x: 1, y: lid, anchor: .top)
                        .offset(x: (eye.cx - eye.r) * scale, y: (eye.cy - eye.r) * scale)
                }
            }
        }
        .frame(width: markSize, height: markSize, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func artColour(_ rgb: HootArt.RGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func blink() async {
        lid = 0
        guard moves else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(Double.random(in: 4...7))) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.07)) { lid = 1 }
            do { try await Task.sleep(for: .milliseconds(110)) }
            catch { lid = 0; return }
            withAnimation(.easeOut(duration: 0.10)) { lid = 0 }
        }
    }

    private func lookAround() async {
        glance = 0
        guard thinks else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { glance = 0; return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { glance = glance > 0 ? -1.2 : 1.2 }
        }
    }
}

/// The shared, single-line status below Hoot's name. The host supplies the real stage/tool text.
struct HootStatusLine: View {
    var state: HootAvatar.State = .awake
    var text: String
    var action: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if state == .thinking {
                HStack(spacing: 3) {
                    ForEach(0..<3) { index in
                        Circle().fill(AGKITStyle.hoot).frame(width: 3, height: 3)
                            .phaseAnimator([false, true]) { dot, phase in
                                dot.opacity(reduceMotion || !phase ? 1 : 0.35)
                            } animation: { _ in .easeInOut(duration: 0.55 + Double(index) * 0.15) }
                    }
                }
            } else if state == .waiting {
                Circle().fill(AGKITStyle.warn).frame(width: 6, height: 6)
            }
            if state == .waiting, let action {
                Button(action: action) { statusText.frame(minHeight: 28).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .help("Show the request")
            } else {
                statusText
            }
            if state == .stopped, let action {
                Text("·")
                Button(action: action) {
                    Text("Start Hoot").padding(.horizontal, 6)
                        .frame(minHeight: 28).contentShape(.rect)
                }
                    .buttonStyle(.link)
                    .help("Start Hoot")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var statusText: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .overlay {
                if state == .thinking && !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, AGKITStyle.hoot.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(30, geometry.size.width * 0.4))
                            .phaseAnimator([false, true]) { sheen, phase in
                                sheen.offset(x: phase ? geometry.size.width : -geometry.size.width * 0.4)
                            } animation: { _ in .linear(duration: 2) }
                    }
                    .mask(Text(text).lineLimit(1).truncationMode(.middle))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}
