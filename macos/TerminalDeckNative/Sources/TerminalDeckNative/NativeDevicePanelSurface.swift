import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Device panels follow their inherited page appearance, not the separately loaded terminal paper.
enum NativeDevicePanelSurface {
    @MainActor static func background(_ scheme: ColorScheme) -> NSColor {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        var result = DeckTokens.pageNS
        appearance.performAsCurrentDrawingAppearance { result = DeckTokens.pageNS.usingColorSpace(.sRGB) ?? DeckTokens.pageNS }
        return result
    }
    static func permitsOwner(chat: Bool, hasPTY: Bool, ended: Bool) -> Bool { !ended && (chat || hasPTY) }
    static func slot(_ value: Double?) throws -> Int {
        guard let value, value == 0 || value == 1 else { throw NativeRPCError.invalidArguments("Choose device slot 0 or 1.") }
        return Int(value)
    }
}
struct NativeDevicePanelBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.background(Color(nsColor: NativeDevicePanelSurface.background(scheme))).clipped() }
}
