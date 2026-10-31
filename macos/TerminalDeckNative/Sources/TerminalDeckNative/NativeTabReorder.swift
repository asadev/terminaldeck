import AppKit
import SwiftUI
import Observation
import TerminalDeckNativeCore

/// Reordering the top strip's tabs by dragging, like Chrome (Asad, 2026-10-09): grab a tab and slide it; the
/// others move aside while you go; drop and it stays (remembered across restarts). Far enough out of the
/// strip or the window, letting go opens the tab in its own window (the existing pop-out path).
@MainActor @Observable
final class NativeTabReorder {
    static let shared = NativeTabReorder()
    @ObservationIgnored private let popOut: @MainActor (NativePaneItem) -> Void
    @ObservationIgnored private let setTabOrder: @MainActor ([String]) -> Void

    init(popOut: @escaping @MainActor (NativePaneItem) -> Void = { NativePaneDragSpace.popOut($0) },
         setTabOrder: @escaping @MainActor ([String]) -> Void = { NativePaneArrangement.shared.setTabOrder($0) }) {
        self.popOut = popOut
        self.setTabOrder = setTabOrder
    }

    /// How far apart the tabs are, and the strip's height (the strip says, each time it is drawn).
    var step: CGFloat = 120
    var stripHeight: CGFloat = TabStripLayout.height

    private(set) var dragID: String?
    private(set) var startIndex = 0
    private(set) var translation: CGFloat = 0
    /// The order while a tab is held: the others have already moved aside.
    private(set) var order: [String] = []
    private(set) var popping = false
    @ObservationIgnored private var base: [String] = []

    var liveIndex: Int { dragID.flatMap { order.firstIndex(of: $0) } ?? startIndex }

    /// The sideways offset of a tab: the held one follows the pointer, the rest sit in their places.
    func offset(for id: String) -> CGFloat {
        id == dragID ? translation - CGFloat(liveIndex - startIndex) * step : 0
    }

    func begin(_ id: String, in current: [String]) {
        guard dragID == nil, let index = current.firstIndex(of: id) else { return }
        dragID = id; base = current; order = current; startIndex = index; translation = 0; popping = false
    }

    func update(translation: CGFloat, pointerY: CGFloat, outsideWindow: Bool) {
        guard let id = dragID else { return }
        self.translation = translation
        popping = outsideWindow || TabOrderRules.popsOut(pointerY: Double(pointerY), stripHeight: Double(stripHeight))
        // Over the pop-out line the tab stays where it was: only a tab still in the strip makes the others move.
        let target = popping ? startIndex : TabOrderRules.targetIndex(start: startIndex, translation: Double(translation), step: Double(step), count: base.count)
        let next = TabOrderRules.moved(base, id: id, to: target)
        if next != order { withAnimation(.easeOut(duration: 0.14)) { order = next } }
    }

    /// Let go: keep the new order, or pop the tab out.
    func end() {
        guard let id = dragID else { return }
        let keep = order, out = popping
        withAnimation(.easeOut(duration: 0.14)) { dragID = nil; translation = 0; popping = false }
        order = []; base = []
        if out { popOut(.tab(tabId: id)) }
        else { setTabOrder(keep) }
    }
}
