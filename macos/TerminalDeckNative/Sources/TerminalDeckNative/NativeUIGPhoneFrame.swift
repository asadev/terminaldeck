import SwiftUI
import TerminalDeckNativeCore

/// The device itself, drawn behind the screen. Light and dark alike: the device is black.
struct NativePhoneFrameView: View {
    let frame: NativePhoneFrame
    let layout: NativePhoneFrame.Layout
    /// The buttons this device has (`DeviceDetails.buttons`) and how to press one: the side
    /// buttons on the frame are the real controls.
    var available: [String] = []
    var press: ((String) -> Void)? = nil

    /// The one colour this adds: the device's black.
    static let deviceBlack = Color(red: 0.035, green: 0.035, blue: 0.04)

    var body: some View {
        // Drawn upright, then turned for a landscape screen.
        let size = layout.landscape ? CGSize(width: layout.body.height, height: layout.body.width) : layout.body.size
        upright(size: size)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(layout.landscape ? 90 : 0))
            .position(x: layout.body.midX, y: layout.body.midY)
    }

    private func upright(size: CGSize) -> some View {
        let unit = layout.unit
        let band = max(1.5, unit * frame.band)
        let screenRadius = unit * frame.screenRadius
        let bezel = unit * frame.side
        let outerRadius = frame.homeButton ? unit * 0.16 : screenRadius + bezel
        let body = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
        let metal = Self.deviceBlack.mix(with: .white, by: 0.16)
        // The side buttons a touch lighter than the band, so they read on a dark page too.
        let keys = Self.deviceBlack.mix(with: .white, by: 0.34)
        return ZStack {
            ForEach(Array(frame.buttons.enumerated()), id: \.offset) { _, button in
                buttonShape(button, size: size, unit: unit, fill: keys)
            }
            Group {
                body.fill(metal)
                body.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.08), .white.opacity(0.28)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1, band * 0.45))
                RoundedRectangle(cornerRadius: max(0, outerRadius - band), style: .continuous)
                    .fill(Self.deviceBlack)
                    .padding(band)
                body.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if frame.homeButton {
                let diameter = unit * 0.19
                let ring = Circle().strokeBorder(.white.opacity(0.22), lineWidth: max(1, unit * 0.008))
                    .frame(width: diameter, height: diameter)
                if let press, available.contains("home") {
                    SwiftUI.Button { press("home") } label: { ring.contentShape(.circle) }
                        .buttonStyle(NativeFrameKeyStyle(round: true))
                        .help("Home").accessibilityLabel("Home")
                        .position(x: size.width / 2, y: size.height - unit * frame.bottom / 2)
                } else {
                    ring.position(x: size.width / 2, y: size.height - unit * frame.bottom / 2).allowsHitTesting(false)
                }
            }
        }
    }

    private func buttonShape(_ button: NativePhoneFrame.Button, size: CGSize, unit: CGFloat, fill: Color) -> some View {
        let depth = max(2, unit * frame.depth)
        let thickness = depth * 2 // half of it hides under the body
        let shape = RoundedRectangle(cornerRadius: depth * 0.8, style: .continuous)
        let vertical = button.edge != .top
        let edge: AnyView
        if let press, let kind = button.kind, available.contains(kind) {
            // A real control: hover lightens it, a press pushes it in, the tooltip names it.
            edge = AnyView(SwiftUI.Button { press(kind) } label: {
                shape.fill(fill).overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                    // A finger-sized target: the slim button plus a margin around it.
                    .padding(vertical ? .horizontal : .vertical, -5).contentShape(.rect).padding(vertical ? .horizontal : .vertical, 5)
            }
            .buttonStyle(NativeFrameKeyStyle(edge: button.edge))
            .help(button.name).accessibilityLabel(button.name))
        } else {
            edge = AnyView(shape.fill(fill).overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .help(button.name).accessibilityLabel(button.name))
        }
        switch button.edge {
        case .left:
            let length = (button.to - button.from) * size.height
            return AnyView(edge.frame(width: thickness, height: length)
                .position(x: 0, y: size.height * (button.from + button.to) / 2))
        case .right:
            let length = (button.to - button.from) * size.height
            return AnyView(edge.frame(width: thickness, height: length)
                .position(x: size.width, y: size.height * (button.from + button.to) / 2))
        case .top:
            let length = (button.to - button.from) * size.width
            return AnyView(edge.frame(width: length, height: thickness)
                .position(x: size.width * (button.from + button.to) / 2, y: 0))
        }
    }
}

extension NativeSimulatorModel {
    /// The screen's shape for the frame: the live picture's, or the device's points before it arrives.
    var frameContent: CGSize? {
        if let fitSize { return fitSize }
        guard let device, device.pointWidth > 0, device.pointHeight > 0 else { return nil }
        return CGSize(width: device.pointWidth, height: device.pointHeight)
    }
}

/// A side button on the frame: lighter under the pointer, pushed into the body while pressed.
struct NativeFrameKeyStyle: ButtonStyle {
    var edge: NativePhoneFrame.Edge = .left
    var round = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let push: CGFloat = configuration.isPressed ? 1.5 : 0
        configuration.label
            .brightness(configuration.isPressed ? 0.12 : hovered ? 0.22 : 0)
            .offset(x: edge == .left ? push : edge == .right ? -push : 0, y: edge == .top && !round ? push : 0)
            .scaleEffect(round && configuration.isPressed ? 0.94 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
