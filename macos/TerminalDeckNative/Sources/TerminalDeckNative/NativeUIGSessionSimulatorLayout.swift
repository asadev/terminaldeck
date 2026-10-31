import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The actual production split is shared with the safe session render fixture.
/// A session shows up to two device panels (iOS and/or Android) beside its terminal: each keeps its own
/// width, side and place, can be dragged to move (NativePaneDrag), and the terminal keeps a readable width.
struct NativeUIGSessionSimulatorSplit<Content: View>: View {
    /// One device panel: its place (0 or 1), its saved layout and its view.
    struct Dock: Identifiable {
        let slot: Int
        let state: Binding<UIGSessionSimulatorState>
        var detached = false
        let title: String
        let view: AnyView
        var id: Int { slot }
        var docked: Bool { state.wrappedValue.isOpen && !detached }
    }

    var docks: [Dock]
    /// The session these panels are docked beside: lets a panel be dragged to the other side (or out to a window).
    var sessionId: String? = nil
    @ViewBuilder var content: () -> Content
    @State private var dragWidth: Double?
    private let arrangement = NativePaneArrangement.shared
    @State private var owner = UUID()

    /// The single-panel form (fixtures and the first device).
    init<Panel: View>(state: Binding<UIGSessionSimulatorState>, detached: Bool = false, sessionId: String? = nil,
                      @ViewBuilder content: @escaping () -> Content, @ViewBuilder panel: () -> Panel) {
        self.docks = [Dock(slot: 0, state: state, detached: detached, title: "Simulator", view: AnyView(panel()))]
        self.sessionId = sessionId; self.content = content
    }

    init(docks: [Dock], sessionId: String?, @ViewBuilder content: @escaping () -> Content) {
        self.docks = docks; self.sessionId = sessionId; self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let shown = ordered(docks.filter(\.docked))
            let widths = NativePaneArrangement.simulatorWidths(wanted: shown.map { $0.state.wrappedValue.width }, paneWidth: geometry.size.width)
            let width = Dictionary(uniqueKeysWithValues: zip(shown.map(\.slot), widths))
            let leading = shown.filter { isLeading($0.slot) }, trailing = shown.filter { !isLeading($0.slot) }
            HStack(spacing: 0) {
                ForEach(leading) { dock in simulator(dock, width: width[dock.slot] ?? 0, leading: true) }
                content().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .modifier(SimulatorZone(id: sessionId.map { "content:\($0)" }))
                ForEach(trailing) { dock in simulator(dock, width: width[dock.slot] ?? 0, leading: false) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            // The row of panes shares space with these widths in mind (NativeLayoutScreen).
            .onChange(of: shown.map { $0.state.wrappedValue.width }, initial: true) { _, wanted in
                guard let sessionId else { return }
                arrangement.setDocked(sessionId, width: wanted.isEmpty ? nil : wanted.reduce(0, +), count: wanted.count, owner: owner)
            }
            .onDisappear { if let sessionId { arrangement.setDocked(sessionId, width: nil, owner: owner) } }
        }
    }

    private func isLeading(_ slot: Int) -> Bool {
        sessionId.map { arrangement.isSimulatorLeading($0, slot: slot) } ?? false
    }

    /// The panels in the order the person left them.
    private func ordered(_ docks: [Dock]) -> [Dock] {
        guard let sessionId else { return docks }
        let order = arrangement.panelOrder(sessionId)
        return docks.sorted { (order.firstIndex(of: $0.slot) ?? $0.slot) < (order.firstIndex(of: $1.slot) ?? $1.slot) }
    }

    /// A docked panel and its resize bar, on the side the person put it (right until they drag it left).
    @ViewBuilder private func simulator(_ dock: Dock, width: Double, leading: Bool) -> some View {
        // PFRAME: no visible line between the session and the phone; the bar still resizes.
        let bar = Color.clear.frame(width: 4).contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                var state = dock.state.wrappedValue
                if dragWidth == nil { dragWidth = state.width }
                let delta = leading ? drag.translation.width : -drag.translation.width
                state.resize(to: (dragWidth ?? state.width) + delta)
                dock.state.wrappedValue = state
            }.onEnded { _ in dragWidth = nil })
            .help("Drag to resize the device panel")
        let key = sessionId.map { NativePaneArrangement.panelKey($0, slot: dock.slot) }
        let panel = dock.view.frame(width: max(0, width - 4))
            .modifier(SimulatorZone(id: key.map { "sim:\($0)" }))
            .overlay(alignment: .topLeading) { grip(dock) }
        if leading { panel; bar } else { bar; panel }
    }

    /// The panel's title strip is its handle (the buttons at its right end stay buttons).
    @ViewBuilder private func grip(_ dock: Dock) -> some View {
        if let sessionId {
            // The grip is the title strip LEFT of the two buttons. (The shape used to be set after the
            // padding, so the drag took the clicks meant for "own window" and × too: 10 Oct, ANDROID.)
            HStack(spacing: 0) {
                Color.clear.contentShape(.rect)
                    .nativePaneDrag(.simulator(sessionId: sessionId, slot: dock.slot), title: dock.title)
                    .help("Drag to move this device, or out of the window")
                Color.clear.frame(width: 76).allowsHitTesting(false)
            }.frame(height: 40)
        }
    }
}

private struct SimulatorZone: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.nativePaneDropZone(id) } else { content }
    }
}
