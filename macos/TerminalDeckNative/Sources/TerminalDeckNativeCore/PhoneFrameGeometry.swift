import CoreGraphics
import Foundation

/// A device drawn around the live screen, the way Claude's iOS Simulator panel shows one:
/// a black bezel matched to the screen's corners, a thin metal band, and the side buttons.
/// Pure geometry (here in Core so it is tested); the app draws it (NativeUIGPhoneFrame.swift).
/// The screen view is laid out on its own, exactly over the frame's hole, so taps map as before.
public struct NativePhoneFrame: Equatable, Sendable {
    public enum Edge: Equatable, Sendable { case left, right, top }
    /// A side button: its edge and where it runs along it, as fractions of that edge.
    public struct Button: Equatable, Sendable {
        public var edge: Edge; public var from: CGFloat; public var to: CGFloat
        /// The device button it presses (`devices:button`), nil for one the simulator has no action for.
        public var kind: String? = nil
        public var name = ""
    }

    /// Every length below is a fraction of the screen's SHORT side.
    public var screenRadius: CGFloat
    public var side: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    public var band: CGFloat
    public var depth: CGFloat
    public var buttons: [Button]
    /// A home-button iPhone's round button under the screen.
    public var homeButton = false
    /// A Pixel-style front camera: a small round hole at the top of the screen.
    public var punchHole = false

    /// The frame for a device, or nil where a phone frame would be wrong (watch, TV, unknown).
    public static func spec(for device: DeviceDetails?, content: CGSize) -> NativePhoneFrame? {
        guard let device, content.width > 0, content.height > 0 else { return nil }
        let name = device.name.lowercased()
        let long = max(content.width, content.height), short = min(content.width, content.height)
        let aspect = long / short
        if device.platform == "android" {
            return NativePhoneFrame(screenRadius: 0.07, side: 0.035, top: 0.035, bottom: 0.035, band: 0.01, depth: 0.012,
                                    buttons: [Button(edge: .right, from: 0.20, to: 0.26, kind: "lock", name: "Power"),
                                              Button(edge: .right, from: 0.30, to: 0.36, kind: "volume-up", name: "Volume up"),
                                              Button(edge: .right, from: 0.36, to: 0.42, kind: "volume-down", name: "Volume down")],
                                    punchHole: true)
        }
        guard device.platform == "ios" else { return nil }
        if name.contains("watch") || name.contains("tv") || name.contains("vision") { return nil }
        if name.contains("ipad") {
            return NativePhoneFrame(screenRadius: 0.025, side: 0.045, top: 0.045, bottom: 0.045, band: 0.008, depth: 0.008,
                                    buttons: [Button(edge: .top, from: 0.80, to: 0.90, kind: "lock", name: "Top button"),
                                              Button(edge: .right, from: 0.07, to: 0.13, kind: "volume-up", name: "Volume up"),
                                              Button(edge: .right, from: 0.15, to: 0.21, kind: "volume-down", name: "Volume down")])
        }
        if aspect < 1.9 {
            // iPhone SE and the other home-button phones: square screen, forehead and chin.
            return NativePhoneFrame(screenRadius: 0, side: 0.075, top: 0.29, bottom: 0.29, band: 0.012, depth: 0.012,
                                    buttons: [Button(edge: .left, from: 0.13, to: 0.17, name: "Ring/Silent switch"),
                                              Button(edge: .left, from: 0.22, to: 0.29, kind: "volume-up", name: "Volume up"),
                                              Button(edge: .left, from: 0.31, to: 0.38, kind: "volume-down", name: "Volume down"),
                                              Button(edge: .right, from: 0.22, to: 0.30, kind: "lock", name: "Side button (lock)")],
                                    homeButton: true)
        }
        // Face ID iPhones: action button and volume on the left, side button on the right.
        return NativePhoneFrame(screenRadius: 0.135, side: 0.05, top: 0.05, bottom: 0.05, band: 0.014, depth: 0.012,
                                buttons: [Button(edge: .left, from: 0.17, to: 0.21, kind: "action", name: "Action button"),
                                          Button(edge: .left, from: 0.245, to: 0.315, kind: "volume-up", name: "Volume up"),
                                          Button(edge: .left, from: 0.335, to: 0.405, kind: "volume-down", name: "Volume down"),
                                          Button(edge: .right, from: 0.29, to: 0.37, kind: "lock", name: "Side button (lock)")])
    }

    /// The whole drawing (device plus room for its buttons) for a screen of `content`'s shape,
    /// in the same units as `content`: what to fit into the space on offer.
    public func outerSize(content: CGSize) -> CGSize {
        let landscape = content.width > content.height
        let short = min(content.width, content.height), long = max(content.width, content.height)
        let portrait = CGSize(width: short * (1 + 2 * side + 2 * depth), height: long + short * (top + bottom + 2 * depth))
        return landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
    }

    public struct Layout: Equatable, Sendable {
        /// The device's body, buttons excluded, in the stage's coordinates.
        public var body: CGRect
        /// The screen: the hole the live picture sits in.
        public var screen: CGRect
        public var landscape: Bool
        /// The screen's short side in points: every fraction is multiplied by it.
        public var unit: CGFloat
    }

    /// Where the body and the screen go when the drawing is fitted into `bounds`, centred.
    public func layout(content: CGSize, in bounds: CGSize) -> Layout? {
        let outer = DeviceGeometry.fitted(content: outerSize(content: content), in: bounds)
        guard outer.width > 0 else { return nil }
        let landscape = content.width > content.height
        let short = min(content.width, content.height)
        let scale = (landscape ? outer.height : outer.width) / (short * (1 + 2 * side + 2 * depth))
        let unit = short * scale
        let body = outer.insetBy(dx: unit * depth, dy: unit * depth)
        let screen: CGRect
        if landscape {
            // Turned clockwise: the portrait top is on the right, the bottom on the left.
            screen = CGRect(x: body.minX + unit * bottom, y: body.minY + unit * side,
                            width: body.width - unit * (top + bottom), height: body.height - unit * 2 * side)
        } else {
            screen = CGRect(x: body.minX + unit * side, y: body.minY + unit * top,
                            width: body.width - unit * 2 * side, height: body.height - unit * (top + bottom))
        }
        return Layout(body: body, screen: Self.pixelAligned(screen), landscape: landscape, unit: unit)
    }

    private static func pixelAligned(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }
}

