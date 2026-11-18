import SwiftUI
import TerminalDeckNativeCore

// The pictures of his devices (owner, 18 Nov, item 25: "How you will know PC versus Mac mini? Will system automatically
// know this is Mac mini, this is laptop, this is MacBook, this is Windows, this is iPhone, this is Android").
// ONE small family, drawn here in the app's line style (never SF Symbols, whose phone, laptop and desktop marks come
// from three different sets): a 28 pt box, one stroke weight, round joins, the same ink everywhere.
// Design: notes/review-20261118/DESIGN-settings.md section 2.

/// The real kind of a device, as far as the app can know it.
enum NativeDeviceModel: String, CaseIterable, Sendable {
    case macMini, macStudio, macPro, macBook, iMac, windowsPC, laptop, desktop
    case iPhone, iPad, androidPhone, androidTablet, phone, browser

    /// The side of the square every picture is drawn in (the drawings' own coordinates).
    static let glyphBox: CGFloat = 28

    /// The kind as a person says it.
    var word: String {
        switch self {
        case .macMini: "Mac mini"
        case .macStudio: "Mac Studio"
        case .macPro: "Mac Pro"
        case .macBook: "MacBook"
        case .iMac: "iMac"
        case .windowsPC: "Windows PC"
        case .laptop: "Laptop"
        case .desktop: "Computer"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .androidPhone: "Android phone"
        case .androidTablet: "Android tablet"
        case .phone: "Phone"
        case .browser: "Browser"
        }
    }

    /// The model a device REPORTS about itself, read loosely: the fixed words of the hand-off ("mac-mini", "macbook",
    /// "windows-laptop", "android-tablet" …), a marketing name ("MacBook Pro", "Mac mini (2024)", "Pixel 8") or an
    /// older Apple identifier that names its family ("Macmini9,1", "MacBookPro18,3", "iPhone15,2"). nil = it says
    /// nothing this app can read (a bare "Mac16,10" names no family), so the caller falls back to the name.
    static func from(reported raw: String?) -> NativeDeviceModel? {
        guard let raw else { return nil }
        let text = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !text.isEmpty else { return nil }
        let table: [(String, NativeDeviceModel)] = [
            ("macmini", .macMini), ("macstudio", .macStudio), ("macpro", .macPro), ("macbook", .macBook), ("imac", .iMac),
            ("ipad", .iPad), ("iphone", .iPhone), ("ipod", .iPhone),
            ("androidtablet", .androidTablet), ("androidphone", .androidPhone), ("pixeltablet", .androidTablet),
            ("pixel", .androidPhone), ("galaxytab", .androidTablet), ("galaxy", .androidPhone), ("android", .androidPhone),
            ("windowslaptop", .laptop), ("windowsdesktop", .windowsPC), ("windows", .windowsPC), ("laptop", .laptop),
            ("notebook", .laptop), ("desktop", .desktop), ("browser", .browser), ("tablet", .androidTablet),
        ]
        return table.first { text.contains($0.0) }?.1
    }

    /// The picture's kind for a row of the devices list: what the device reports (the seam), else what its name and
    /// platform say (as before: "Asad's Mac mini" is a Mac mini; a Mac with no family in its name is a MacBook).
    @MainActor static func of(_ row: NativeDevicesSettings.Row) -> NativeDeviceModel {
        if NativeDevicesSettings.isBrowser(row) { return .browser }
        if let model = from(reported: row.reportedModel) { return model }
        switch NativeDevicesSettings.kindWord(row) {
        case "Mac mini": return .macMini
        case "Mac Studio": return .macStudio
        case "Mac Pro": return .macPro
        case "iMac": return .iMac
        case "MacBook", "MacBook Air", "MacBook Pro", "Mac": return .macBook
        case "iPhone": return .iPhone
        case "iPad": return .iPad
        case "Android phone": return .androidPhone
        case "Phone": return .phone
        case "PC": return .windowsPC
        case "Browser": return .browser
        default: return .desktop
        }
    }
}

/// One device picture. `size` is the box; the drawing is made for 28 pt and scales with it.
struct NativeDeviceGlyph: View {
    let model: NativeDeviceModel
    var size: CGFloat = NativeDeviceGlyph.box
    static let box: CGFloat = NativeDeviceModel.glyphBox
    static let stroke: CGFloat = 1.35
    static let ink: Double = 0.78

    var body: some View {
        let scale = size / Self.box
        ZStack {
            NativeDeviceGlyphLines(model: model)
                .stroke(style: StrokeStyle(lineWidth: Self.stroke * max(1, scale * 0.82), lineCap: .round, lineJoin: .round))
            NativeDeviceGlyphDots(model: model).fill()
        }
        .foregroundStyle(Color.primary.opacity(Self.ink))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The stroked part, in a 28 x 28 space.
struct NativeDeviceGlyphLines: Shape {
    let model: NativeDeviceModel

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / NativeDeviceModel.glyphBox
        var path = Path()
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r), style: .continuous)
        }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: x1, y: y1)); path.addLine(to: CGPoint(x: x2, y: y2))
        }
        switch model {
        case .macMini:
            box(3, 10.5, 22, 7.6, 2.6)
            line(8, 20.6, 20, 20.6)
        case .macStudio:
            box(3.5, 7, 21, 13.2, 3.2)
            line(15.2, 16.4, 19.6, 16.4)
            line(8.5, 22.6, 19.5, 22.6)
        case .macPro:
            box(8.2, 5.6, 11.6, 18.4, 2.6)
            // The handles over the case.
            path.move(to: CGPoint(x: 10.4, y: 5.6))
            path.addQuadCurve(to: CGPoint(x: 17.6, y: 5.6), control: CGPoint(x: 14, y: 1.4))
            line(11.4, 20.2, 16.6, 20.2)
        case .macBook, .laptop:
            box(5.4, 6, 17.2, 12, 1.9)
            box(2.2, 19.6, 23.6, 2.5, 1.25)
        case .iMac:
            box(3, 4.4, 22, 15, 2.2)
            line(3.8, 15.6, 24.2, 15.6)
            line(11.6, 19.4, 10.8, 23.4)
            line(16.4, 19.4, 17.2, 23.4)
            line(8.6, 23.6, 19.4, 23.6)
        case .desktop:
            box(3, 5, 22, 14, 2)
            line(14, 19, 14, 22.6)
            line(9.4, 22.8, 18.6, 22.8)
        case .windowsPC:
            box(2.4, 6.4, 15.4, 11, 1.8)
            line(10.1, 17.4, 10.1, 20.6)
            line(6.4, 20.8, 13.8, 20.8)
            box(20, 6.4, 5.6, 14.6, 1.4)
            line(21.7, 17.6, 23.9, 17.6)
        case .iPhone:
            box(8.5, 3, 11, 22, 3)
        case .androidPhone:
            box(8.5, 3, 11, 22, 2.2)
        case .phone:
            box(8.5, 3, 11, 22, 2.6)
            line(12.2, 22.3, 15.8, 22.3)
        case .iPad:
            box(5, 3.5, 18, 21, 2.5)
        case .androidTablet:
            box(3, 6.5, 22, 15, 2.2)
        case .browser:
            box(3, 5, 22, 18, 2.8)
            line(3.4, 10.2, 24.6, 10.2)
            box(6.2, 13.2, 15.6, 3.4, 1.7)
        }
        return path.applying(CGAffineTransform(scaleX: s, y: s))
            .offsetBy(dx: rect.minX + (rect.width - NativeDeviceModel.glyphBox * s) / 2, dy: rect.minY + (rect.height - NativeDeviceModel.glyphBox * s) / 2)
    }
}

/// The filled details (a light, a camera, the island), in the same 28 x 28 space.
struct NativeDeviceGlyphDots: Shape {
    let model: NativeDeviceModel

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / NativeDeviceModel.glyphBox
        var path = Path()
        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        switch model {
        case .macMini: dot(21.4, 14.3, 0.95)
        case .macStudio: dot(8.2, 16.4, 0.95); dot(11.4, 16.4, 0.95)
        case .macPro: dot(14, 10.2, 1); dot(14, 14, 1)
        case .windowsPC: dot(22.8, 9.6, 0.9)
        case .iPhone:
            path.addRoundedRect(in: CGRect(x: 11.9, y: 5.1, width: 4.2, height: 1.7), cornerSize: CGSize(width: 0.85, height: 0.85))
        case .androidPhone: dot(14, 6, 0.95)
        case .iPad: dot(14, 5.6, 0.75)
        case .androidTablet: dot(5.5, 14, 0.75)
        case .browser: dot(6.2, 7.6, 0.8); dot(8.8, 7.6, 0.8); dot(11.4, 7.6, 0.8)
        case .macBook, .laptop, .iMac, .desktop, .phone: break
        }
        return path.applying(CGAffineTransform(scaleX: s, y: s))
            .offsetBy(dx: rect.minX + (rect.width - NativeDeviceModel.glyphBox * s) / 2, dy: rect.minY + (rect.height - NativeDeviceModel.glyphBox * s) / 2)
    }
}
