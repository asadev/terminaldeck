import CoreGraphics
import Foundation

/// The phone panel's pure decisions, kept here so they are tested: crop and snip rectangles,
/// and when the clipboard is carried between the Mac and a simulator.

public enum ShotCropMath {
    /// The whole picture, as fractions.
    public static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func isFull(_ crop: CGRect) -> Bool {
        crop.minX <= 0.0005 && crop.minY <= 0.0005 && crop.maxX >= 0.9995 && crop.maxY >= 0.9995
    }

    /// A crop (fractions of the picture) in the picture's pixels: whole pixels, inside the picture, at least one pixel.
    public static func pixels(_ crop: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let x0 = max(0, min(w - 1, (crop.minX * w).rounded()))
        let y0 = max(0, min(h - 1, (crop.minY * h).rounded()))
        let x1 = max(x0 + 1, min(w, (crop.maxX * w).rounded()))
        let y1 = max(y0 + 1, min(h, (crop.maxY * h).rounded()))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// "1,206 × 2,622", for a card's size label.
    public static func sizeLabel(_ crop: CGRect, width: Int, height: Int) -> String {
        let rect = pixels(crop, width: width, height: height)
        return "\(Int(rect.width).formatted()) × \(Int(rect.height).formatted())"
    }

    /// A snip dragged from `a` to `b` (view points) over the picture drawn at `picture`: the box kept on
    /// the picture, as fractions of it. Nil for a click or a box too small to mean anything (under 6 points).
    public static func snip(from a: CGPoint, to b: CGPoint, picture: CGRect, minimum: CGFloat = 6) -> CGRect? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, picture.minX), picture.maxX), y: min(max(p.y, picture.minY), picture.maxY))
        }
        let p = clamp(a), q = clamp(b)
        let box = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
        guard box.width >= minimum, box.height >= minimum else { return nil }
        return CGRect(x: (box.minX - picture.minX) / picture.width, y: (box.minY - picture.minY) / picture.height,
                      width: box.width / picture.width, height: box.height / picture.height)
    }
}

/// When text is carried between the Mac's clipboard and a simulator's pasteboard. Event-driven: the
/// app asks at focus, ⌘C/⌘V and when it goes to the back; this decides whether anything moves,
/// so nothing goes back and forth for nothing.
public struct SimPasteboardSync: Equatable, Sendable {
    public private(set) var lastMacChange = -1
    public private(set) var lastCarried: String?
    public init() {}

    /// The iOS Simulator UDID for a device id ("ios:<UDID>"); nil for Android and anything else.
    public static func simulatorUDID(_ deviceID: String?) -> String? {
        guard let deviceID, deviceID.hasPrefix("ios:") else { return nil }
        let raw = String(deviceID.dropFirst(4))
        return UUID(uuidString: raw) != nil ? raw : nil
    }

    /// The screen took focus (or ⌘V, `force`): the Mac text to put on the phone, or nil.
    public mutating func toPhone(macChangeCount: Int, macText: String?, force: Bool = false) -> String? {
        guard force || macChangeCount != lastMacChange else { return nil }
        lastMacChange = macChangeCount
        guard let macText, !macText.isEmpty, force || macText != lastCarried else { return nil }
        lastCarried = macText
        return macText
    }

    /// One read of the phone's pasteboard: the text to put on the Mac's clipboard, or nil.
    public mutating func toMac(phoneText: String?, macText: String?) -> String? {
        guard let phoneText, !phoneText.isEmpty, phoneText != lastCarried else { return nil }
        lastCarried = phoneText
        return phoneText == macText ? nil : phoneText
    }

    /// The Mac clipboard was written by the app itself (its change count, so it is not sent straight back).
    public mutating func macWritten(changeCount: Int) { lastMacChange = changeCount }
}
