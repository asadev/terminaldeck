import AppKit
import SwiftUI
import Observation
import TerminalDeckNativeCore

// Re-arranging the stack by dragging (Asad, 2026-10-08): "keep overall stack re-arrangeable by
// dragging like sessions and simulator — move session to the right and simulator to the left, or
// two sessions one at left and the other at right, or drag anything outside to make a separate window".
//
//  * One drag system for everything: a pane's header (session, browser, second session), the
//    simulator panel's header, and a tab in the strip. Grab, move; a left/right highlight shows where
//    it lands (Chrome / VS Code style); let go to drop.
//  * Dropped outside the window it opens in its own window through the EXISTING pop-out path
//    (NativePoppedSessions / AppModel.openTabInWindow / the simulator's own window), which already
//    has "move back to Terminal Deck". No second pop-out system.
//  * The order is remembered per set of panes, the simulator's side per session, across restarts.

/// What is being dragged.
enum NativePaneItem: Equatable {
    case page(ScreenRef) // whole pages drag out through the existing screen scene
    case pane(tabId: String)          // a session or browser pane of the split row
    case simulator(sessionId: String, slot: Int) // a device panel docked beside a session (a session has up to two)
    case tab(tabId: String)           // a tab of the strip (outside the window it pops out; nothing else)
}

// MARK: Remembered arrangement

@MainActor @Observable
final class NativePaneArrangement {
    static let shared = NativePaneArrangement()
    private static let key = "paneArrangement.v1"

    private struct Saved: Codable {
        var orders: [String: [String]] = [:]; var simulatorLeading: [String] = []
        var panelOrder: [String: [Int]]? = nil
        var tabOrder: [String]? = nil
    }
    /// The order of the top strip's tabs, as the person arranged them.
    private(set) var tabOrder: [String] = []
    func arrangedTabs(_ ids: [String]) -> [String] { TabOrderRules.arranged(ids, saved: tabOrder) }
    func setTabOrder(_ order: [String]) {
        guard order != tabOrder else { return }
        tabOrder = order; save()
    }
    /// The order of a session's device panels (the first slot first until they are dragged).
    private(set) var panelOrders: [String: [Int]] = [:]

    /// Sessions that have a simulator panel docked beside them now, and the width it wants (not saved).
    struct Docked: Equatable { var width: Double; var count: Int }
    private(set) var dockedSimulators: [String: Docked] = [:]
    @ObservationIgnored private var dockedOwners: [String: UUID] = [:]
    /// The room a session's docked device panels want in all (one or two panels).
    /// `owner` tells which view said it: a view replaced by its successor (a pane that moved) must not
    /// remove the successor's entry when it goes.
    func setDocked(_ sessionId: String, width: Double?, count: Int = 1, owner: UUID) {
        if let width {
            dockedOwners[sessionId] = owner
            let next = Docked(width: width, count: count)
            if dockedSimulators[sessionId] != next { dockedSimulators[sessionId] = next }
        } else if dockedOwners[sessionId] == owner {
            dockedOwners[sessionId] = nil; dockedSimulators[sessionId] = nil
        }
    }

    // The width rules for a row of sessions (Asad, 2026-10-08): sessions share the free space equally, a
    // simulator keeps its phone width, and no session is squeezed below a readable width — the panel goes
    // compact first.
    static let minimumSession = 480.0
    static let compactSimulator = 280.0

    /// A simulator's width given the room its pane has: its own width, or less (never below compact) so the
    /// session beside it keeps `minimumSession`.
    static func simulatorWidth(wanted: Double, paneWidth: Double) -> Double {
        simulatorWidths(wanted: [wanted], paneWidth: paneWidth)[0]
    }

    /// Widths for one or two device panels in a pane: each keeps its own width; when the pane is too narrow for the
    /// session to keep `minimumSession`, they give up room together (never below compact).
    static func simulatorWidths(wanted: [Double], paneWidth: Double) -> [Double] {
        guard !wanted.isEmpty else { return [] }
        let allowed = max(compactSimulator * Double(wanted.count), paneWidth - minimumSession)
        let excess = wanted.reduce(0, +) - allowed
        var result = wanted
        if excess > 0 {
            let spare = wanted.map { max(0, $0 - compactSimulator) }, total = spare.reduce(0, +)
            if total > 0 { result = zip(wanted, spare).map { $0 - min(excess, total) * $1 / total } }
        }
        // And never so wide that the session has less than a sliver.
        let cap = max(0, paneWidth - min(160, paneWidth / 2)), sum = result.reduce(0, +)
        return sum > cap && sum > 0 ? result.map { $0 * cap / sum } : result
    }

    /// Width of the first pane of a horizontal split when the person has not dragged the divider:
    /// equal room for the sessions, each simulator riding with its own session.
    static func balancedFirst(free: Double, firstSimulators: Double, secondSimulators: Double,
                              firstCount: Int = 1, secondCount: Int = 1) -> Double {
        var f = firstSimulators, s = secondSimulators
        let deficit = 2 * minimumSession + f + s - free
        if deficit > 0 {
            let fSpare = f > 0 ? max(0, f - compactSimulator * Double(firstCount)) : 0
            let sSpare = s > 0 ? max(0, s - compactSimulator * Double(secondCount)) : 0
            let spare = fSpare + sSpare
            if spare > 0 {
                let take = min(deficit, spare)
                f -= take * fSpare / spare; s -= take * sSpare / spare
            }
        }
        return (free - f - s) / 2 + f
    }

    private(set) var orders: [String: [String]] = [:]
    private(set) var simulatorLeading: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    /// The ids that still exist (the side panel's rows, the strip's tabs); nil while they are not known
    /// yet, and then nothing is dropped.
    @ObservationIgnored private let known: @MainActor () -> Set<String>?

    init(defaults: UserDefaults = .standard, known: @escaping @MainActor () -> Set<String>? = NativePaneArrangement.liveIDs) {
        self.defaults = defaults; self.known = known
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            orders = saved.orders; simulatorLeading = Set(saved.simulatorLeading); panelOrders = saved.panelOrder ?? [:]; tabOrder = saved.tabOrder ?? []
        }
    }
    static func liveIDs() -> Set<String>? {
        guard let sidebar = AppModel.shared.sidebar, let tabs = AppModel.shared.tabs else { return nil }
        let panes = tabs.layout?.root?.leaves.compactMap(\.tabId) ?? []
        return Set(sidebar.groups.flatMap(\.items).map(\.id) + sidebar.projects.flatMap(\.sessions).map(\.id) + tabs.tabs.map(\.id) + panes + ["hoot"])
    }

    static func rowKey(_ ids: [String]) -> String { ids.sorted().joined(separator: ",") }

    /// The panes' ids left to right as the split draws them: the tabs in the order the person dragged them to,
    /// an empty pane keeping its place (the same slots as `NativeSplitScreen`). ⌘⌥← / ⌘⌥→ walk this.
    static func shownOrder(_ root: PaneNode) -> [String] {
        let tabLeaves = root.leaves.compactMap { leaf in leaf.tabId.map { (pane: leaf.id, tab: $0) } }
        var order = shared.arranged(tabLeaves.map(\.tab)).makeIterator()
        let byTab = Dictionary(tabLeaves.map { ($0.tab, $0.pane) }, uniquingKeysWith: { first, _ in first })
        return root.leaves.map { leaf in leaf.tabId == nil ? leaf.id : (order.next().flatMap { byTab[$0] } ?? leaf.id) }
    }

    /// The tab ids of this row of panes in the order the person left them (tree order until they move one).
    func arranged(_ ids: [String]) -> [String] {
        guard let saved = orders[Self.rowKey(ids)], saved.count == ids.count, Set(saved) == Set(ids) else { return ids }
        return saved
    }

    /// Put `id` just before or after `target` in the row currently shown as `current`.
    @discardableResult
    func move(_ id: String, relativeTo target: String, after: Bool, current: [String]) -> Bool {
        guard id != target, current.contains(id), current.contains(target) else { return false }
        var next = current.filter { $0 != id }
        guard let at = next.firstIndex(of: target) else { return false }
        next.insert(id, at: after ? at + 1 : at)
        guard next != current else { return false }
        orders[Self.rowKey(current)] = next
        save(); return true
    }

    /// A device panel's own key: its session, plus the slot when it is the second (the first keeps the old key).
    static func panelKey(_ sessionId: String, slot: Int) -> String { slot == 0 ? sessionId : sessionId + "#\(slot)" }

    func isSimulatorLeading(_ sessionId: String, slot: Int = 0) -> Bool { simulatorLeading.contains(Self.panelKey(sessionId, slot: slot)) }

    /// One panel to a side (`slot`), or every panel of the session.
    func setSimulatorLeading(_ sessionId: String, slot: Int? = nil, _ leading: Bool) {
        var changed = false
        for s in slot.map({ [$0] }) ?? [0, 1] {
            let key = Self.panelKey(sessionId, slot: s)
            guard simulatorLeading.contains(key) != leading else { continue }
            if leading { simulatorLeading.insert(key) } else { simulatorLeading.remove(key) }
            changed = true
        }
        if changed { save() }
    }

    func panelOrder(_ sessionId: String) -> [Int] { panelOrders[sessionId] ?? [0, 1] }

    /// Put `slot` before or after the session's other device panel, on that panel's side.
    func movePanel(_ sessionId: String, slot: Int, relativeTo other: Int, after: Bool) {
        guard slot != other else { return }
        var next = panelOrder(sessionId).filter { $0 != slot }
        let at = next.firstIndex(of: other) ?? next.count
        next.insert(slot, at: after ? at + 1 : at)
        panelOrders[sessionId] = next
        setSimulatorLeading(sessionId, slot: slot, isSimulatorLeading(sessionId, slot: other))
        save()
    }

    private func save() {
        // U143 (#645): rows, phone sides and panel orders of sessions that are gone are dropped, so the
        // saved arrangement does not keep every session ever arranged.
        if let alive = known() {
            orders = orders.filter { $0.key.split(separator: ",").allSatisfy { alive.contains(String($0)) } }
            simulatorLeading = simulatorLeading.filter { alive.contains($0.split(separator: "#").first.map(String.init) ?? $0) }
            panelOrders = panelOrders.filter { alive.contains($0.key) }
        }
        let saved = Saved(orders: orders, simulatorLeading: simulatorLeading.sorted(), panelOrder: panelOrders, tabOrder: tabOrder)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: The drag, per window

struct NativePaneDropTarget: Equatable {
    enum Kind: Equatable {
        case reorder(item: String, relativeTo: String, after: Bool)
        /// A device panel (`slot`), or every panel of the session (nil), to the left or right.
        case simulatorSide(sessionId: String, slot: Int?, leading: Bool)
        /// A device panel next to the session's other device panel.
        case simulatorReorder(sessionId: String, slot: Int, relativeTo: Int, after: Bool)
    }
    var kind: Kind
    /// Where it will land: the half of the zone under the pointer, in window coordinates.
    var highlight: CGRect
    var leadingEdge: Bool
}

@MainActor @Observable
final class NativePaneDragSpace {
    /// Zones by id; the token says which view registered it, so a view that is replaced by a new one
    /// with the same id (a pane that moved) does not remove its successor's zone when it goes.
    var zoneEntries: [String: (token: UUID, rect: CGRect)] = [:]
    var zones: [String: CGRect] { zoneEntries.mapValues(\.rect) }
    @ObservationIgnored private var zoneOwners: [String: UUID] = [:]
    /// A view that just appeared owns the zone from then on (a stale view still reporting its last
    /// geometry while it is replaced must not take it back).
    func claimZone(_ id: String, token: UUID, rect: CGRect?) {
        zoneOwners[id] = token
        if let rect { zoneEntries[id] = (token, rect) }
    }
    func setZone(_ id: String, token: UUID, rect: CGRect) {
        guard zoneOwners[id] == nil || zoneOwners[id] == token else { return }
        zoneOwners[id] = token; zoneEntries[id] = (token, rect)
    }
    func clearZone(_ id: String, token: UUID) {
        guard zoneOwners[id] == token else { return }
        zoneOwners[id] = nil; zoneEntries[id] = nil
    }
    /// The tab ids of the row of panes as drawn now, left to right.
    var leafOrder: [String] = []
    @ObservationIgnored private let openWindow: @MainActor (NativePaneItem) -> Void
    init(openWindow: @escaping @MainActor (NativePaneItem) -> Void = { NativePaneDragSpace.popOut($0) }) {
        self.openWindow = openWindow // front-ok: only stored here; it runs in finish(), the person's own drag release, and every pop-out path is gated itself
    }
    private(set) var item: NativePaneItem?
    private(set) var title = ""
    private(set) var pointer: CGPoint = .zero
    private(set) var outside = false
    private(set) var target: NativePaneDropTarget?
    /// Simulator panels that are open (their zones exist only then).
    var isDragging: Bool { item != nil }

    func update(item: NativePaneItem, title: String, pointer: CGPoint, outside: Bool) {
        self.item = item; self.title = title; self.pointer = pointer; self.outside = outside
        target = outside ? nil : resolve(item, at: pointer)
    }

    /// Re-read the release location: a last move may have landed before the pointer crossed an edge.
    func finish(item: NativePaneItem, title: String, pointer: CGPoint, outside: Bool) {
        update(item: item, title: title, pointer: pointer, outside: outside)
        finish()
    }

    /// Let go: drop on the highlighted half, or — outside the window — open in a window of its own.
    func finish() {
        defer { item = nil; target = nil; outside = false }
        guard let item else { return }
        if outside { openWindow(item); return }
        guard let target else { return }
        switch target.kind {
        case .reorder(let moving, let relative, let after):
            NativePaneArrangement.shared.move(moving, relativeTo: relative, after: after, current: leafOrder)
        case .simulatorSide(let sessionId, let slot, let leading):
            NativePaneArrangement.shared.setSimulatorLeading(sessionId, slot: slot, leading)
        case .simulatorReorder(let sessionId, let slot, let other, let after):
            NativePaneArrangement.shared.movePanel(sessionId, slot: slot, relativeTo: other, after: after)
        }
    }

    func cancel() { item = nil; target = nil; outside = false }

    // The zones: "leaf:<tab>" a whole pane of the row, "content:<session>" a session's terminal area,
    // "sim:<session>" its docked simulator panel. The smallest zone under the pointer that fits the item wins.
    private func resolve(_ item: NativePaneItem, at point: CGPoint) -> NativePaneDropTarget? {
        let hit = zones.filter { $0.value.contains(point) }.sorted { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
        for (zone, rect) in hit {
            let kind = zone.prefix { $0 != ":" }
            let id = String(zone.dropFirst(kind.count + 1))
            let leading = point.x < rect.midX
            let half = CGRect(x: leading ? rect.minX : rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
            switch item {
            case .tab, .page: return nil
            case .pane(let moving):
                if kind == "leaf", id != moving {
                    return .init(kind: .reorder(item: moving, relativeTo: id, after: !leading), highlight: half, leadingEdge: leading)
                }
                // Over its own simulator panels or terminal area (only when one is docked beside it): the session
                // goes to the side the pointer is on, so its panels go to the other.
                if (kind == "sim" || kind == "content") && Self.session(of: id) == moving && zones["sim:\(moving)"] != nil {
                    return .init(kind: .simulatorSide(sessionId: moving, slot: nil, leading: !leading), highlight: half, leadingEdge: leading)
                }
            case .simulator(let session, let slot):
                guard Self.session(of: id) == session, kind == "sim" || kind == "content" || kind == "leaf" else { break }
                // Over the session's other panel: next to it, on its side. Elsewhere in the pane: to that side.
                if kind == "sim", let other = Self.slot(of: id), other != slot {
                    return .init(kind: .simulatorReorder(sessionId: session, slot: slot, relativeTo: other, after: !leading), highlight: half, leadingEdge: leading)
                }
                if kind == "sim", Self.slot(of: id) == slot { break }
                return .init(kind: .simulatorSide(sessionId: session, slot: slot, leading: leading), highlight: half, leadingEdge: leading)
            }
        }
        return nil
    }

    /// The pointer (this drag event) is outside the window it started in.
    static func pointerOutsideWindow() -> Bool {
        guard let event = NSApp.currentEvent, let window = event.window else { return false }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        return !window.frame.insetBy(dx: -2, dy: -2).contains(screen)
    }

    /// A zone id's session ("<session>" or "<session>#<slot>").
    static func session(of id: String) -> String { id.split(separator: "#", maxSplits: 1).first.map(String.init) ?? id }
    static func slot(of id: String) -> Int? { id.contains("#") ? Int(id.split(separator: "#").last ?? "") : 0 }

    /// The existing pop-out paths.
    static func popOut(_ item: NativePaneItem) {
        switch item {
        case .page(let ref):
            AppModel.shared.movePageToWindow(ref)
        case .pane(let tabId), .tab(let tabId):
            let model = AppModel.shared
            if let tab = model.stripTabs?.tabs.first(where: { $0.id == tabId }) {
                model.openTabInWindow(tab)
            } else {
                NativePoppedSessions.shared.popOut(tabId, title: nil)
            }
        case .simulator(let sessionId, let slot):
            let store = NativeUIGSessionSimulatorStore.shared
            store.popOut(store.entry(NativeUIGSessionSimulatorStore.owner(sessionId), slot: slot))
        }
    }
}

/// What a pop-out window hands its content so dragging it back over the main window merges it again.
struct NativePopoutReturn {
    let ref: ScreenRef
    let moveBack: @MainActor () -> Void
}
private struct NativePopoutReturnKey: EnvironmentKey { static let defaultValue: NativePopoutReturn? = nil }
extension EnvironmentValues {
    var popoutReturn: NativePopoutReturn? {
        get { self[NativePopoutReturnKey.self] }
        set { self[NativePopoutReturnKey.self] = newValue }
    }
}

enum NativePopoutMerge {
    /// Geometry and return share one path for pointer events and hidden checks.
    @MainActor @discardableResult
    static func finish(pointer: CGPoint, targetFrame: CGRect?, moveBack: @MainActor () -> Void) -> Bool {
        guard let targetFrame, targetFrame.contains(pointer) else { return false }
        moveBack()
        return true
    }

    @MainActor static var mainFrame: CGRect? {
        guard let main = AppModel.shared.web.webView.window, main.isVisible else { return nil }
        return main.frame
    }

    @MainActor static var releasePointer: CGPoint {
        if let event = NSApp.currentEvent, let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    /// The pointer (screen coordinates) is over the main window: letting go there puts the screen back.
    @MainActor static func isOverMain(_ point: CGPoint) -> Bool { mainFrame?.contains(point) == true }
}

private struct NativePopoutDragBack: ViewModifier {
    let action: (@MainActor () -> Void)?
    @Environment(\.popoutReturn) private var back
    func body(content: Content) -> some View {
        if let moveBack = action ?? back?.moveBack {
            content.simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onEnded { _ in
                    NativePopoutMerge.finish(pointer: NativePopoutMerge.releasePointer,
                                             targetFrame: NativePopoutMerge.mainFrame, moveBack: moveBack)
                })
        } else { content }
    }
}
extension View {
    /// Pass an action for toolbar and device handles; session headers inherit their screen's action.
    func nativePopoutDragBack(perform action: (@MainActor () -> Void)? = nil) -> some View {
        modifier(NativePopoutDragBack(action: action))
    }
}

private struct NativePaneDragSpaceKey: EnvironmentKey { static let defaultValue: NativePaneDragSpace? = nil }
extension EnvironmentValues {
    var paneDragSpace: NativePaneDragSpace? {
        get { self[NativePaneDragSpaceKey.self] }
        set { self[NativePaneDragSpaceKey.self] = newValue }
    }
}

// MARK: Modifiers

private struct NativePaneDragSource: ViewModifier {
    let item: NativePaneItem
    let title: String
    @Environment(\.paneDragSpace) private var space

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { value in
                    space?.update(item: item, title: title, pointer: value.location, outside: Self.outsideWindow())
                    if space == nil { Self.lone = (item, Self.outsideWindow()) }
                }
                .onEnded { value in
                    let outside = Self.outsideWindow()
                    if let space { space.finish(item: item, title: title, pointer: value.location, outside: outside) }
                    else if outside { NativePaneDragSpace.popOut(item) }
                    Self.lone = nil
                })
    }

    /// A drag whose view has no drop space (the tab strip lives in the toolbar): only "outside" matters.
    @MainActor private static var lone: (NativePaneItem, Bool)?

    /// The pointer is outside the window the drag started in (screen coordinates of the event itself).
    @MainActor static func outsideWindow() -> Bool { NativePaneDragSpace.pointerOutsideWindow() }
}

private struct NativePaneDropZone: ViewModifier {
    let id: String
    @Environment(\.paneDragSpace) private var space
    @State private var token = UUID()
    @State private var last: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { last = $0; space?.setZone(id, token: token, rect: $0) }
            .onAppear { space?.claimZone(id, token: token, rect: last) }
            .onDisappear { space?.clearZone(id, token: token) }
    }
}

extension View {
    /// Grab this view (a header) to move the pane / simulator / tab; outside the window it pops out.
    func nativePaneDrag(_ item: NativePaneItem, title: String, enabled: Bool = true) -> some View {
        modifier(NativePaneDragEnabled(item: item, title: title, enabled: enabled))
    }
    /// A place a dragged pane can land (left or right half).
    func nativePaneDropZone(_ id: String) -> some View { modifier(NativePaneDropZone(id: id)) }
    /// The window's drag space and its drop indicator and ghost.
    func nativePaneDragHost() -> some View { modifier(NativePaneDragHost()) }
}

private struct NativePaneDragEnabled: ViewModifier {
    let item: NativePaneItem
    let title: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(NativePaneDragSource(item: item, title: title)) } else { content }
    }
}

private struct NativePaneDragHost: ViewModifier {
    @State private var space = NativePaneDragSpace()

    func body(content: Content) -> some View {
        content
            .environment(\.paneDragSpace, space)
#if DEBUG
            // Render checks only (Debug builds, scratch copy with defaults key paneDragTest=true): the same
            // calls a real mouse drag makes, sent as a notification, so a drag can be shown without a pointer.
            //   dev.terminaldeck.tabs.drag  userInfo: item "pane:<n>" | "sim:<n>" | "tab:<n>" (n = place in the row),
            //   phase "move" | "drop" | "cancel", x, y (window points; x < 0 = outside the window)
            .onAppear { NativeAuditRender.install() }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("dev.terminaldeck.tabs.drag"))) { note in
                guard UserDefaults.standard.bool(forKey: "paneDragTest"), let info = note.userInfo,
                      let phase = info["phase"] as? String else { return }
                switch phase {
                case "dump":
                    let text = space.zones.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n") + "\norder \(space.leafOrder)"
                    try? text.write(toFile: NSHomeDirectory() + "/pane-zones.txt", atomically: true, encoding: .utf8)
                case "cycle":
                    // The whole drag-out and drag-back cycle for tab n, with no window ever shown (see NativeAuditRender).
                    NativeAuditRender.cycle(item: Int(info["item"] as? String ?? "") ?? 0)
                case "add":
                    // The same call the phone button's "Add another device" makes (no menu is opened).
                    let n = Int(info["item"] as? String ?? "") ?? 0
                    if let id = space.leafOrder.indices.contains(n) ? space.leafOrder[n] : AppModel.shared.currentScreen?.id {
                        NativeUIGSessionSimulatorStore.shared.addSecond(NativeUIGSessionSimulatorStore.owner(id))
                    }
                case "hide":
                    let n = Int(info["item"] as? String ?? "") ?? 0
                    if let id = space.leafOrder.indices.contains(n) ? space.leafOrder[n] : AppModel.shared.currentScreen?.id {
                        NativeUIGSessionSimulatorStore.shared.closeAll(NativeUIGSessionSimulatorStore.owner(id))
                    }
                case "cancel": space.cancel()
                case "drop": space.finish(); NativeTabReorder.shared.end()
                case "strip":
                    // A tab of the top strip held and slid `x` points sideways (y = the pointer's height in the strip).
                    let reorder = NativeTabReorder.shared
                    let ids = NativePaneArrangement.shared.arrangedTabs(AppModel.shared.stripTabs?.tabs.map(\.id) ?? [])
                    if reorder.dragID == nil, let n = Int(info["item"] as? String ?? ""), ids.indices.contains(n) { reorder.begin(ids[n], in: ids) }
                    reorder.update(translation: CGFloat(info["x"] as? Double ?? 0), pointerY: CGFloat(info["y"] as? Double ?? 20), outsideWindow: false)
                default:
                    let parts = (info["item"] as? String ?? "").split(separator: ":")
                    guard parts.count == 2, let n = Int(parts[1]), space.leafOrder.indices.contains(n) else { return }
                    let tab = space.leafOrder[n]
                    let item: NativePaneItem = parts[0] == "sim" ? .simulator(sessionId: tab, slot: Int(info["slot"] as? Double ?? 0)) : parts[0] == "tab" ? .tab(tabId: tab) : .pane(tabId: tab)
                    let x = (info["x"] as? Double) ?? 0, y = (info["y"] as? Double) ?? 0
                    space.update(item: item, title: info["title"] as? String ?? "Moving", pointer: CGPoint(x: x, y: y), outside: x < 0)
                }
            }
#endif
            .overlay {
                GeometryReader { proxy in
                    let origin = proxy.frame(in: .global).origin
                    ZStack(alignment: .topLeading) {
                        if let target = space.target {
                            let r = target.highlight.offsetBy(dx: -origin.x, dy: -origin.y)
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(NativeSessionChrome.accent.opacity(0.16))
                                .overlay(alignment: target.leadingEdge ? .leading : .trailing) {
                                    Capsule().fill(NativeSessionChrome.accent).frame(width: 3).padding(.vertical, 6).padding(.horizontal, 2)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(NativeSessionChrome.accent.opacity(0.55), lineWidth: 1.5))
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                        }
                        if space.isDragging, !space.outside {
                            Text(space.title.isEmpty ? "Moving" : space.title)
                                .font(.callout.weight(.medium)).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.regularMaterial, in: .capsule)
                                .overlay(Capsule().strokeBorder(.separator))
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                                .offset(x: space.pointer.x - origin.x + 12, y: space.pointer.y - origin.y + 14)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .allowsHitTesting(false)
            }
    }
}
