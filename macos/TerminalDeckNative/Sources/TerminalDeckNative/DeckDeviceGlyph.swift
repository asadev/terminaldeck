import SwiftUI

// A device's small picture by its type (review of 18 Nov, items 25 and 31: "we can show laptop icon here ... shape of
// that device"; "will system automatically know this is Mac mini, this is laptop, this is MacBook, this is Windows,
// this is iPhone, this is Android"). One place for the whole app: the session header, the device lists in Settings.

/// What kind of device something is, for its picture.
enum DeckDeviceKind: String, Sendable, CaseIterable {
    case laptop, desktop, macMini, pc, iPhone, iPad, android, server, computer

    /// The outline SF Symbol for this kind.
    var symbol: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .macMini: "macmini"
        case .pc: "pc"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .android: "smartphone"
        case .server: "server.rack"
        case .computer: "display"
        }
    }

    /// For VoiceOver and tooltips.
    var words: String {
        switch self {
        case .laptop: "Laptop"
        case .desktop: "Desktop Mac"
        case .macMini: "Mac mini"
        case .pc: "PC"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .android: "Android phone"
        case .server: "Server"
        case .computer: "Computer"
        }
    }

    /// SEAM (LOGIC-HANDOFF R1): `reported` is the device's real type as the device itself says it (not sent by any
    /// device yet: the Cloud's session rows and the machine links carry only a name). Until it exists the picture is
    /// read from the device's own name ("Asad's MacBook Pro" is a laptop), and a name that says nothing is a plain
    /// computer. The reported type always wins.
    static func resolve(reported: String?, name: String?) -> DeckDeviceKind {
        if let kind = reported.flatMap(fromReported) { return kind }
        return name.flatMap(fromName) ?? .computer
    }

    /// The words a device may report for itself.
    static func fromReported(_ value: String) -> DeckDeviceKind? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "laptop", "macbook", "macbook-pro", "macbook-air", "notebook": .laptop
        case "desktop", "imac", "mac-studio", "mac-pro": .desktop
        case "mac-mini", "macmini": .macMini
        case "pc", "windows": .pc
        case "iphone", "ios": .iPhone
        case "ipad", "ipados": .iPad
        case "android": .android
        case "server", "linux": .server
        default: nil
        }
    }

    /// A stopgap, only while no type is reported: what the device's name says about itself.
    static func fromName(_ name: String) -> DeckDeviceKind? {
        let folded = name.lowercased()
        if folded.contains("macbook") || folded.contains("laptop") { return .laptop }
        if folded.contains("mac mini") || folded.contains("macmini") { return .macMini }
        if folded.contains("imac") || folded.contains("mac studio") || folded.contains("mac pro") { return .desktop }
        if folded.contains("iphone") { return .iPhone }
        if folded.contains("ipad") { return .iPad }
        if folded.contains("android") || folded.contains("pixel") || folded.contains("galaxy") { return .android }
        if folded.contains("windows") || folded.hasPrefix("desktop-") || folded.hasSuffix("-pc") || folded.hasSuffix(" pc")
            || folded.hasPrefix("pc-") || folded == "pc" { return .pc }
        return nil
    }
}

/// "Runs on that device": the device's glyph and its name, in the grey of the line it sits in. The ONLY thing that
/// tells a session on another device from one on this Mac (Asad, 18 Nov: "100% should be same. Only the difference,
/// we can see a small icon ... inside").
struct NativeDeviceMark: View {
    let name: String
    let kind: DeckDeviceKind

    private var glyphModel: NativeDeviceModel {
        switch kind {
        case .laptop: .macBook
        case .desktop: .iMac
        case .macMini: .macMini
        case .pc: .windowsPC
        case .iPhone: .iPhone
        case .iPad: .iPad
        case .android: .androidPhone
        case .server, .computer: .desktop
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            NativeDeviceGlyph(model: NativeDeviceModel.from(reported: name) ?? glyphModel, size: 13)
            Text(name)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Runs on \(name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runs on \(name), \(kind.words)")
    }
}
