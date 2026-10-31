import AppKit
import SwiftUI
@preconcurrency import SwiftTerm
import WebKit

/// Cached screens stay mounted while transparent. Their event monitors must sleep too.
private struct NativeScreenActiveKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var nativeScreenActive: Bool {
        get { self[NativeScreenActiveKey.self] }
        set { self[NativeScreenActiveKey.self] = newValue }
    }
}

@MainActor enum NativeKeyboardFocus {
    /// Native terminals and web content are text clients too, not just NSTextView.
    static func isTyping(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is TerminalView || current is NSText || current is NSTextField ||
                current is NSTextInputClient || current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    static func tourMayTakeKey(_ event: NSEvent, panel: NSWindow?) -> Bool {
        guard let panel, event.window === panel, panel.isKeyWindow,
              panel.attachedSheet == nil else { return false }
        return !isTyping(panel.firstResponder)
    }
}
