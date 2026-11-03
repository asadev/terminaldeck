import CoreGraphics
import Foundation

/// The inspector's pure half: where the picture sits in a view, how a point in
/// the view becomes a point on the device and back, and the quick checks an
/// accessibility audit starts with.

// MARK: - The picture in a view

public enum DeviceGeometry {
    /// The largest rectangle of `content`'s shape that fits `bounds`, centred —
    /// where the picture is drawn, and therefore what every point is measured
    /// against. Zero when either size is empty.
    public static func fitted(content: CGSize, in bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A point in the view (top-left origin) as a normalised point on the
    /// screen, clamped to it — what input is sent in. Nil when nothing is drawn.
    public static func normalized(_ point: CGPoint, in fitted: CGRect) -> (x: Double, y: Double)? {
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let x = Double((point.x - fitted.minX) / fitted.width)
        let y = Double((point.y - fitted.minY) / fitted.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// The same, but nil when the point is outside the picture — for hovering,
    /// where the letterbox around a phone is not part of it.
    public static func normalizedInside(_ point: CGPoint, in fitted: CGRect) -> (x: Double, y: Double)? {
        guard fitted.contains(point) else { return nil }
        return normalized(point, in: fitted)
    }

    /// A normalised rectangle on the screen, in the view's coordinates.
    public static func viewRect(_ rect: NormRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + CGFloat(rect.x) * fitted.width,
               y: fitted.minY + CGFloat(rect.y) * fitted.height,
               width: CGFloat(rect.width) * fitted.width,
               height: CGFloat(rect.height) * fitted.height)
    }

    /// The screen's size in points (or dp) the way up the picture is. The engine
    /// reports it once, upright; a picture wider than tall is a turned device.
    public static func screenPoints(pointWidth: Double, pointHeight: Double,
                                    pictureWidth: Double, pictureHeight: Double) -> CGSize? {
        guard pointWidth > 0, pointHeight > 0 else { return nil }
        let pictureLandscape = pictureWidth > pictureHeight
        let pointsLandscape = pointWidth > pointHeight
        if pictureWidth > 0, pictureHeight > 0, pictureLandscape != pointsLandscape {
            return CGSize(width: pointHeight, height: pointWidth)
        }
        return CGSize(width: pointWidth, height: pointHeight)
    }

    /// A box around a point, for a mark that landed on nothing with a frame.
    public static func boxAround(x: Double, y: Double, size: Double = 0.04) -> NormRect {
        NormRect(x: min(max(x - size / 2, 0), 1 - size), y: min(max(y - size / 2, 0), 1 - size), width: size, height: size)
    }
}

// MARK: - The numbered markers, drawn into the picture an agent receives

/// `marked-picture.ts`'s geometry: every size a fraction of the picture's
/// shorter side, so a marker reads the same on a 400px preview and a 1206px screen.
public struct MarkerGeometry: Equatable, Sendable {
    /// The element's outline, in picture pixels (top-left origin).
    public let box: CGRect
    /// The numbered disc, at the outline's top-left corner and kept inside the picture.
    public let badgeCentre: CGPoint
    public let badgeRadius: CGFloat
    public let stroke: CGFloat

    public init(rect: NormRect, width: Double, height: Double) {
        let short = max(1, min(width, height))
        let stroke = max(2, (short / 220).rounded())
        let radius = max(9, (short / 34).rounded())
        let box = CGRect(x: rect.x * width, y: rect.y * height,
                         width: max(rect.width * width, 1), height: max(rect.height * height, 1))
        self.box = box
        self.stroke = CGFloat(stroke)
        self.badgeRadius = CGFloat(radius)
        self.badgeCentre = CGPoint(x: min(max(box.minX, radius + stroke), width - radius - stroke),
                                   y: min(max(box.minY, radius + stroke), height - radius - stroke))
    }
}

// MARK: - Quick checks

/// One thing the quick checks found.
public struct DeviceFinding: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// Something a person can act on that a screen reader has no name for.
        case missingLabel
        /// Smaller than the platform's minimum touch target, in points (dp on Android).
        case smallTarget(width: Double, height: Double)
    }

    public let kind: Kind
    public let ref: String
    public let role: String
    /// How it is called in the list: its name, or its identifier when it has no name.
    public let what: String

    public var id: String {
        switch kind {
        case .missingLabel: "label:\(ref)"
        case .smallTarget: "size:\(ref)"
        }
    }

    /// One plain sentence for the list.
    public func sentence(minimum: Double, unit: String) -> String {
        let noun = role.isEmpty ? "element" : role
        switch kind {
        case .missingLabel:
            return what.isEmpty ? "A \(noun) with no label" : "A \(noun) with no label (\(what))"
        case let .smallTarget(width, height):
            let size = "\(Int(width.rounded())) × \(Int(height.rounded())) \(unit)"
            let name = what.isEmpty ? noun : "\(noun) \"\(what)\""
            let floor = Int(minimum.rounded())
            return "\(name) is \(size), under \(floor) × \(floor)"
        }
    }
}

public enum DeviceChecks {
    /// Roles a person taps, types into or drags — the ones that need a name and room for a finger.
    public static let interactiveRoles: Set<String> = [
        // iOS, as the Simulator's accessibility service names them.
        "AXButton", "AXLink", "AXTextField", "AXSecureTextField", "AXTextArea", "AXSearchField",
        "AXSwitch", "AXToggle", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor", "AXStepper",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSegmentedControl", "AXDisclosureTriangle", "AXTab",
        // Android.
        "android.widget.Button", "android.widget.ImageButton", "android.widget.EditText",
        "android.widget.CheckBox", "android.widget.Switch", "android.widget.RadioButton",
        "android.widget.ToggleButton", "android.widget.SeekBar", "android.widget.Spinner",
        "android.widget.CompoundButton",
    ]

    /// Roles where the hint text in the box is what is read when there is no label.
    static let textEntryRoles: Set<String> = [
        "AXTextField", "AXSecureTextField", "AXTextArea", "AXSearchField", "android.widget.EditText",
    ]

    public static func isInteractive(_ node: DeviceNode) -> Bool {
        interactiveRoles.contains(node.role ?? "")
    }

    /// What a screen reader would call it. An identifier is for code, not people, so it does not count.
    public static func spokenName(_ node: DeviceNode) -> String {
        var names = [node.label, node.title, node.text]
        if textEntryRoles.contains(node.role ?? "") { names.append(node.placeholder) }
        return names.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }

    /// The minimum touch target: 44 × 44 pt on iOS, 48 × 48 dp on Android.
    public static func minimumTarget(platform: String) -> Double {
        platform == "android" ? 48 : 44
    }

    /// Every finding on the screen, in reading order: missing labels first, then small targets.
    ///
    /// `points` is the screen's size in points (dp) the way up the picture is;
    /// without it the size check cannot be made and only labels are checked.
    /// Hidden elements and ones wholly off the screen are not checked — nobody can reach them.
    public static func run(_ root: DeviceNode, points: CGSize?, minimum: Double = 44) -> [DeviceFinding] {
        var labels: [DeviceFinding] = []
        var sizes: [DeviceFinding] = []
        for node in DeviceTreeQuery.flatten(root) where isInteractive(node) && node.hidden != true {
            guard let rect = node.usableFrame, !rect.isOffScreen else { continue }
            let role = DeviceTreeQuery.plainRole(node.role)
            let name = spokenName(node)
            if name.isEmpty {
                labels.append(DeviceFinding(kind: .missingLabel, ref: node.ref, role: role,
                                            what: node.identifier ?? node.testID ?? ""))
            }
            if let points {
                let width = rect.width * Double(points.width)
                let height = rect.height * Double(points.height)
                // A hair under the line is the rounding of a 44-point frame, not a small target.
                if width < minimum - 0.5 || height < minimum - 0.5 {
                    sizes.append(DeviceFinding(kind: .smallTarget(width: width, height: height), ref: node.ref, role: role,
                                               what: name.isEmpty ? (node.identifier ?? node.testID ?? "") : name))
                }
            }
        }
        return labels + sizes
    }
}
