import AppKit
import SwiftUI
import TerminalDeckNativeCore
import TerminalDeckBackend

/// The main page's latest snapshot for the island.

/// The native island uses the same structured chat as Hoot's main page.

struct NativeIslandContent: View {
    static var isNative: Bool { NativeScreens.registered.contains("island") }
    let expanded: Bool
    var chatTopInset: CGFloat = 0
    @State private var desk = NativePermissionDesk.shared

    var body: some View {
        if expanded {
            VStack(spacing: 8) {
                if let request = desk.current {
                    NativePermissionCard(item: request, more: max(0, desk.visible.count - 1))
                        .padding(.horizontal, 8).padding(.top, max(8, chatTopInset))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                NativeHootChat(compact: true)
                    .contentMargins(.top, desk.current == nil ? chatTopInset : 0, for: .scrollContent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.primary)
        }
    }
}

/// `AllSessions`: one row each, scrolling when there are more than fit.
