import CoreGraphics
import Foundation

/// Hoot, Terminal Deck's owl, drawn natively from the same art as the web app's
/// `src/renderer/copilot/HootMark.tsx`: the same 64×64 drawing, path data copied
/// verbatim, the same fixed brand colours (an app-icon-style mascot, identical in
/// light and dark). Eyes open, lids folded — the still pose of the web mark.
///
/// Vector all the way down, so it is crisp at 14 pt in a tab and 200 pt anywhere.
/// A test checks every path string still appears in HootMark.tsx.
public enum HootArt {
    public static let viewBox = CGRect(x: 0, y: 0, width: 64, height: 64)

    /// Fixed brand art, named as in HootMark.tsx.
    public enum Colour {
        public static let body = RGB(0xF7882F)
        public static let bodyDark = RGB(0xE8701A)
        public static let belly = RGB(0xFFD3A8)
        public static let bellyLine = RGB(0xF2A86A)
        public static let face = RGB(0xFFE7CF)
        public static let eyeWhite = RGB(0xFFFFFF)
        public static let pupil = RGB(0x2A1A10)
        public static let frames = RGB(0x5A3418)
        public static let beak = RGB(0xB4500F)
        public static let glint = RGB(0xFFFFFF)
    }

    public struct RGB: Equatable, Sendable {
        public let red, green, blue: CGFloat
        public init(_ hex: UInt32) {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
        }
        func cgColor(alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    public enum Shape: Sendable {
        case path(String)
        case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    }

    public enum Paint: Sendable {
        case fill(RGB)
        case stroke(RGB, width: CGFloat, opacity: CGFloat = 1)
    }

    public struct Element: Sendable {
        public let shape: Shape
        public let paint: Paint
    }

    private static func fill(_ d: String, _ c: RGB) -> Element { Element(shape: .path(d), paint: .fill(c)) }
    private static func line(_ d: String, _ c: RGB, _ w: CGFloat, opacity: CGFloat = 1) -> Element {
        Element(shape: .path(d), paint: .stroke(c, width: w, opacity: opacity))
    }

    /// In paint order, exactly as the SVG.
    public static let elements: [Element] = {
        let c = Colour.self
        return [
            // ear tufts
            fill("M15 17 L18 5 L26 14 Z", c.bodyDark),
            fill("M49 17 L46 5 L38 14 Z", c.bodyDark),
            // body
            fill("M32 9 C48 9 55 21 55 35 C55 50 45 59 32 59 C19 59 9 50 9 35 C9 21 16 9 32 9 Z", c.body),
            // belly
            fill("M32 33 C42 33 46 41 46 47 C46 54 40 58 32 58 C24 58 18 54 18 47 C18 41 22 33 32 33 Z", c.belly),
            line("M26 44 q3 3 6 0 q3 3 6 0", c.bellyLine, 1.6),
            line("M28.5 50 q3.5 3 7 0", c.bellyLine, 1.6),
            // wings
            fill("M10 33 C8 42 11 50 17 54 C15 46 15 39 17 33 Z", c.bodyDark),
            fill("M54 33 C56 42 53 50 47 54 C49 46 49 39 47 33 Z", c.bodyDark),
            // face disc
            Element(shape: .ellipse(cx: 22.5, cy: 25.5, rx: 9.5, ry: 9), paint: .fill(c.face)),
            Element(shape: .ellipse(cx: 41.5, cy: 25.5, rx: 9.5, ry: 9), paint: .fill(c.face)),
            // eyes
            Element(shape: .circle(cx: 23, cy: 26, r: 5.4), paint: .fill(c.eyeWhite)),
            Element(shape: .circle(cx: 41, cy: 26, r: 5.4), paint: .fill(c.eyeWhite)),
            Element(shape: .circle(cx: 23.6, cy: 26.6, r: 3), paint: .fill(c.pupil)),
            Element(shape: .circle(cx: 41.6, cy: 26.6, r: 3), paint: .fill(c.pupil)),
            Element(shape: .circle(cx: 24.6, cy: 25.4, r: 1), paint: .fill(c.eyeWhite)),
            Element(shape: .circle(cx: 42.6, cy: 25.4, r: 1), paint: .fill(c.eyeWhite)),
            // (eyelids are folded to nothing in the still pose)
            // glasses: round frames, a bridge, and arms to the tufts
            Element(shape: .circle(cx: 23, cy: 26, r: 8), paint: .stroke(c.frames, width: 2.4)),
            Element(shape: .circle(cx: 41, cy: 26, r: 8), paint: .stroke(c.frames, width: 2.4)),
            line("M30.6 24.6 Q32 23 33.4 24.6", c.frames, 2.4),
            line("M15 24 L11.5 22.5", c.frames, 2.2),
            line("M49 24 L52.5 22.5", c.frames, 2.2),
            // a glint on each lens
            line("M18.5 21.5 q2 -2 4.5 -2.2", c.glint, 1.3, opacity: 0.75),
            line("M36.5 21.5 q2 -2 4.5 -2.2", c.glint, 1.3, opacity: 0.75),
            // beak
            fill("M29.6 33 L34.4 33 L32 37.4 Z", c.beak),
        ]
    }()

    /// Draws the owl into `rect` of a standard (y-up) Core Graphics context.
    public static func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let drawn = CGSize(width: viewBox.width * scale, height: viewBox.height * scale)
        // Centre, then flip to the SVG's y-down space.
        context.translateBy(x: rect.midX - drawn.width / 2, y: rect.midY + drawn.height / 2)
        context.scaleBy(x: scale, y: -scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for element in elements {
            let path = cgPath(element.shape)
            context.addPath(path)
            switch element.paint {
            case .fill(let colour):
                context.setFillColor(colour.cgColor())
                context.fillPath()
            case .stroke(let colour, let width, let opacity):
                context.setStrokeColor(colour.cgColor(alpha: opacity))
                context.setLineWidth(width)
                context.strokePath()
            }
        }
    }

    /// The owl as a bitmap (tests, previews). `pixels` is the square edge length.
    public static func image(pixels: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(in: context, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }

    static func cgPath(_ shape: Shape) -> CGPath {
        switch shape {
        case .path(let d):
            return (try? SVGPath.parse(d)) ?? CGMutablePath()
        case .ellipse(let cx, let cy, let rx, let ry):
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
        case .circle(let cx, let cy, let r):
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
        }
    }
}

/// The SVG path commands the owl uses (M L C Q Z, absolute and relative; H V too).
public enum SVGPath {
    public struct ParseError: Error, Equatable { public let message: String }

    public static func parse(_ d: String) throws -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokenizer(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character?

        while let next = tokens.peek() {
            if case .command(let c) = next {
                command = c
                tokens.advance()
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    command = nil
                    continue
                }
            }
            guard let c = command else { throw ParseError(message: "numbers without a command in \(d)") }
            let relative = c.isLowercase
            func point() throws -> CGPoint {
                let x = try tokens.number(), y = try tokens.number()
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch c.uppercased() {
            case "M":
                current = try point(); start = current
                path.move(to: current)
                command = relative ? "l" : "L" // extra pairs after M are line-tos
            case "L":
                current = try point()
                path.addLine(to: current)
            case "H":
                let x = try tokens.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                let y = try tokens.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "C":
                let c1 = try point(), c2 = try point(), end = try point()
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
            case "Q":
                let control = try point(), end = try point()
                path.addQuadCurve(to: end, control: control)
                current = end
            default:
                throw ParseError(message: "unsupported command \(c) in \(d)")
            }
        }
        return path
    }

    private struct Tokenizer {
        enum Token: Equatable { case command(Character), number(CGFloat) }
        private var tokens: [Token] = []
        private var index = 0

        init(_ d: String) {
            var number = ""
            func flush() {
                if let v = Double(number) { tokens.append(.number(CGFloat(v))) }
                number = ""
            }
            for ch in d {
                if ch.isLetter && ch != "e" && ch != "E" {
                    flush(); tokens.append(.command(ch))
                } else if ch == "-" {
                    if !(number.last == "e" || number.last == "E") { flush() }
                    number.append(ch)
                } else if ch == "." {
                    if number.contains(".") && !number.contains("e") { flush() }
                    number.append(ch)
                } else if ch.isNumber || ch == "e" || ch == "E" {
                    number.append(ch)
                } else {
                    flush() // space or comma
                }
            }
            flush()
        }

        func peek() -> Token? { index < tokens.count ? tokens[index] : nil }
        mutating func advance() { index += 1 }
        mutating func number() throws -> CGFloat {
            guard index < tokens.count, case .number(let v) = tokens[index] else {
                throw ParseError(message: "expected a number")
            }
            index += 1
            return v
        }
    }
}
