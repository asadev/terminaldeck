import AppKit
import ImageIO
import SwiftUI
import TerminalDeckNativeCore

/// Crop for a screenshot card, shared by the Simulator's and the browser's Screenshot cards:
/// drag a rectangle on the preview, adjust it by its handles, Done applies, Reset is the full picture.
/// The rectangle is kept in fractions of the picture (0...1), so it is the same at any preview size.
enum NativeShotCrop {
    // The maths is in Core (ShotCropMath), where it is tested.
    static let full = ShotCropMath.full
    static func isFull(_ crop: CGRect) -> Bool { ShotCropMath.isFull(crop) }
    static func pixels(_ crop: CGRect, width: Int, height: Int) -> CGRect { ShotCropMath.pixels(crop, width: width, height: height) }
    static func sizeLabel(_ crop: CGRect, width: Int, height: Int) -> String { ShotCropMath.sizeLabel(crop, width: width, height: height) }

    static func cropped(_ image: CGImage, to crop: CGRect) -> CGImage? {
        image.cropping(to: pixels(crop, width: image.width, height: image.height))
    }

    /// The picture at full resolution, from its saved file (or the preview when the file cannot be read).
    static func load(path: String, fallback: NSImage?) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        return fallback?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Saves the cropped picture beside the original as `<name>-cropped.png`; the original stays.
    static func save(_ image: CGImage, beside path: String, suffix: String = "cropped") throws -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        let out = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix).png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: out, options: .atomic)
        return out.path
    }

    static func image(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// The preview with the crop rectangle over it: outside dimmed, eight handles, drag inside to move,
/// drag a handle to resize, drag anywhere else to draw a new rectangle.
struct NativeShotCropView: View {
    let image: NSImage
    @Binding var crop: CGRect
    let editing: Bool

    private enum Grip: Equatable { case move, draw, edges(left: Bool, right: Bool, top: Bool, bottom: Bool) }
    @State private var grip: Grip?
    @State private var startCrop = NativeShotCrop.full

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .overlay {
                if editing {
                    GeometryReader { geometry in
                        let fitted = DeviceGeometry.fitted(content: image.size, in: geometry.size)
                        overlay(fitted: fitted)
                            .contentShape(.rect)
                            .gesture(drag(fitted: fitted))
                    }
                }
            }
            .accessibilityLabel(editing ? "Crop: drag to choose the part of the screenshot to keep" : "Screenshot")
            .accessibilityValue(editing ? "\(Int((crop.width * 100).rounded()))% wide, \(Int((crop.height * 100).rounded()))% high" : "")
            // Without a pointer (VoiceOver, keyboard): increment tightens the rectangle around its
            // centre, decrement widens it back towards the whole picture.
            .accessibilityAdjustableAction { direction in
                guard editing else { return }
                let step: CGFloat = direction == .increment ? 0.05 : -0.05
                let width = min(1, max(0.1, crop.width - 2 * step)), height = min(1, max(0.1, crop.height - 2 * step))
                let x = min(max(0, crop.midX - width / 2), 1 - width), y = min(max(0, crop.midY - height / 2), 1 - height)
                crop = CGRect(x: x, y: y, width: width, height: height)
            }
    }

    private func overlay(fitted: CGRect) -> some View {
        let box = rect(crop, in: fitted)
        return Canvas { context, _ in
            var dim = Path(fitted)
            dim.addRect(box)
            context.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            for third in [1.0 / 3, 2.0 / 3] {
                var line = Path()
                line.move(to: CGPoint(x: box.minX + box.width * third, y: box.minY))
                line.addLine(to: CGPoint(x: box.minX + box.width * third, y: box.maxY))
                line.move(to: CGPoint(x: box.minX, y: box.minY + box.height * third))
                line.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * third))
                context.stroke(line, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
            context.stroke(Path(box), with: .color(.black.opacity(0.35)), lineWidth: 3)
            context.stroke(Path(box), with: .color(.white), lineWidth: 1.5)
            for point in handles(box) {
                let knob = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
                context.fill(Path(roundedRect: knob.insetBy(dx: -1, dy: -1), cornerRadius: 3), with: .color(.black.opacity(0.35)))
                context.fill(Path(roundedRect: knob, cornerRadius: 2.5), with: .color(.white))
            }
        }
    }

    private func handles(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY),
         CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
    }

    private func rect(_ crop: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + crop.minX * fitted.width, y: fitted.minY + crop.minY * fitted.height,
               width: crop.width * fitted.width, height: crop.height * fitted.height)
    }

    private func grip(at point: CGPoint, box: CGRect) -> Grip {
        let reach: CGFloat = 9
        let nearLeft = abs(point.x - box.minX) <= reach, nearRight = abs(point.x - box.maxX) <= reach
        let nearTop = abs(point.y - box.minY) <= reach, nearBottom = abs(point.y - box.maxY) <= reach
        let withinX = point.x >= box.minX - reach && point.x <= box.maxX + reach
        let withinY = point.y >= box.minY - reach && point.y <= box.maxY + reach
        let left = nearLeft && withinY, right = nearRight && withinY && !left
        let top = nearTop && withinX, bottom = nearBottom && withinX && !top
        if left || right || top || bottom { return .edges(left: left, right: right, top: top, bottom: bottom) }
        return box.contains(point) ? .move : .draw
    }

    private func drag(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard fitted.width > 0, fitted.height > 0 else { return }
                if grip == nil {
                    startCrop = crop
                    grip = grip(at: value.startLocation, box: rect(crop, in: fitted))
                }
                let dx = value.translation.width / fitted.width, dy = value.translation.height / fitted.height
                let minimum: CGFloat = 0.04
                switch grip {
                case .move:
                    let x = min(max(0, startCrop.minX + dx), 1 - startCrop.width)
                    let y = min(max(0, startCrop.minY + dy), 1 - startCrop.height)
                    crop = CGRect(x: x, y: y, width: startCrop.width, height: startCrop.height)
                case .draw:
                    let a = normalized(value.startLocation, in: fitted), b = normalized(value.location, in: fitted)
                    crop = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                case let .edges(left, right, top, bottom):
                    var x0 = startCrop.minX, x1 = startCrop.maxX, y0 = startCrop.minY, y1 = startCrop.maxY
                    if left { x0 = min(max(0, x0 + dx), x1 - minimum) }
                    if right { x1 = max(min(1, x1 + dx), x0 + minimum) }
                    if top { y0 = min(max(0, y0 + dy), y1 - minimum) }
                    if bottom { y1 = max(min(1, y1 + dy), y0 + minimum) }
                    crop = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                case nil: break
                }
            }
            .onEnded { _ in
                // A click, or a rectangle too small to keep, leaves the last one as it was.
                if grip == .draw, crop.width < 0.02 || crop.height < 0.02 { crop = startCrop }
                grip = nil
            }
    }

    private func normalized(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(x: min(max(0, (point.x - fitted.minX) / fitted.width), 1),
                y: min(max(0, (point.y - fitted.minY) / fitted.height), 1))
    }
}

/// Crop, or while cropping: Reset and Done. The same three buttons on every Screenshot card.
struct NativeShotCropButtons: View {
    let cropping: Bool
    let start: () -> Void
    let reset: () -> Void
    let done: () -> Void

    var body: some View {
        if cropping {
            Button("Reset", action: reset).buttonStyle(.borderless)
                .help("Back to the full screenshot")
            Button("Done", action: done).buttonStyle(.borderless).keyboardShortcut(.defaultAction)
                .help("Keep only the area inside the rectangle")
        } else {
            Button(action: start) { Label("Crop", systemImage: "crop") }
                .buttonStyle(.borderless)
                .help("Crop: drag a rectangle on the screenshot to keep only that part")
        }
    }
}
