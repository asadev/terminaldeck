import AppKit
import SwiftUI

// DeckMenu: the app's ONE menu and popover (review of 18 Nov 2026, items 8 and 17: "all of these pop-ups should be
// our own style, not Apple's", "we don't need this glossy ones ... not this much transparent").
// A solid rounded surface with a hairline border and a soft shadow, no arrow, no glass. Numbers: DESIGN-shell.md §1.
//
// How to use it (the same three steps everywhere):
//   1. Present:  someButton.deckMenu(isPresented: $open) { ...content... }        (in place of `.popover`)
//   2. Fill:     DeckMenuSection("Claude"); DeckMenuRow("Add account", symbol: "plus") { ... }; DeckMenuDivider()
//                Free content (bars, a switch, a sentence) goes in with `.deckMenuInset()`.
//   3. Nothing else: a row closes the menu by itself (pass `keepsOpen: true` when it should not).
// For a picture or a test, draw `DeckMenuSurface { ...the same content... }`: it is the panel's own look.

// MARK: - Numbers and colours

enum DeckMenuMetrics {
    /// The surface's corner radius.
    static let radius: CGFloat = 12
    /// Room between the surface's edge and its rows.
    static let padding: CGFloat = 5
    static let rowHeight: CGFloat = 30
    /// Row radius = surface radius less the padding, so the hover shape sits concentric in the corner.
    static let rowRadius: CGFloat = 7
    static let rowHorizontal: CGFloat = 9
    /// The icon's box; a symbol is drawn at 13 pt inside it.
    static let icon: CGFloat = 16
    static let iconGap: CGFloat = 9
    static let text: CGFloat = 13
    static let detailText: CGFloat = 11
    static let minWidth: CGFloat = 208
    static let maxWidth: CGFloat = 380
    /// Between the control and its menu.
    static let gap: CGFloat = 6
    /// Clear room around the surface inside its panel, for the shadow.
    static let shadowRoom: CGFloat = 30
    /// Kept between the menu and the screen's edge.
    static let screenMargin: CGFloat = 8
}

@MainActor
enum DeckMenuColours {
    static let surfaceNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2B / 255, green: 0x2B / 255, blue: 0x2F / 255, alpha: 1) : .white
    }
    static let borderNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.11)
    }
    static let surface = Color(nsColor: surfaceNS)
    static let border = Color(nsColor: borderNS)
    /// The pointer's row: the accent, thin. Text keeps its own colour (never white on blue).
    static func hover(_ scheme: ColorScheme) -> Color { Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.12) }
    static func pressed(_ scheme: ColorScheme) -> Color { Color.accentColor.opacity(scheme == .dark ? 0.34 : 0.20) }
    static func shadow(_ scheme: ColorScheme) -> Color { Color.black.opacity(scheme == .dark ? 0.50 : 0.17) }
    static func contactShadow(_ scheme: ColorScheme) -> Color { Color.black.opacity(scheme == .dark ? 0.30 : 0.07) }
}

// MARK: - Closing from inside

/// Closes the menu a view sits in. Outside a DeckMenu it does nothing.
struct DeckMenuDismissAction: Sendable {
    var run: @MainActor @Sendable () -> Void = {}
    @MainActor func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var deckMenuDismiss = DeckMenuDismissAction()
}

// MARK: - The surface

/// The menu's look: solid, radius 12, a hairline border, a soft shadow. `.deckMenu` wraps its content in this.
struct DeckMenuSurface<Content: View>: View {
    /// A fixed width; nil sizes to the content between 208 and 380 pt.
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DeckMenuMetrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(DeckMenuMetrics.padding)
            .frame(minWidth: width ?? DeckMenuMetrics.minWidth, maxWidth: width ?? DeckMenuMetrics.maxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(DeckMenuColours.surface, in: shape)
            .overlay(shape.strokeBorder(DeckMenuColours.border, lineWidth: 1 / max(displayScale, 1)))
            .clipShape(shape)
            .shadow(color: DeckMenuColours.contactShadow(scheme), radius: 1.5, y: 1)
            .shadow(color: DeckMenuColours.shadow(scheme), radius: 20, y: 9)
            .accessibilityElement(children: .contain)
    }
}

// MARK: - What goes in it

/// A quiet title over a group of rows: 11 pt, secondary. An optional small mark sits before the words.
struct DeckMenuSection<Mark: View>: View {
    let title: String
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        HStack(spacing: 5) {
            mark()
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, DeckMenuMetrics.rowHorizontal)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

extension DeckMenuSection where Mark == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// A hairline between groups, inset to the rows' text.
struct DeckMenuDivider: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle().fill(DeckMenuColours.border)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.horizontal, DeckMenuMetrics.rowHorizontal)
            .padding(.vertical, 5)
            .accessibilityHidden(true)
    }
}

enum DeckMenuRole { case normal, destructive }

/// One row: 30 pt high, an optional 16 pt icon, 13 pt text, an optional quiet detail, then at the trailing end either
/// what the caller puts there or an accent check when it is the chosen one. The pointer's row wears the accent at 12%.
/// Nothing changes size on hover. Pressing it runs the action and closes the menu.
struct DeckMenuRow<Icon: View, Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var checked = false
    var role: DeckMenuRole = .normal
    /// False keeps the row readable but not pressable (a choice that cannot be made now).
    var enabled = true
    /// True for a row that changes something in place (a switch): the menu stays.
    var keepsOpen = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var trailing: () -> Trailing
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.deckMenuDismiss) private var dismiss

    var body: some View {
        Button {
            if !keepsOpen { dismiss() }
            action()
        } label: {
            DeckMenuRowBody(title: title, detail: detail, checked: checked, role: role, icon: icon, trailing: trailing)
        }
        .buttonStyle(DeckMenuRowButtonStyle(hovering: hovering && enabled, scheme: scheme))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

extension DeckMenuRow where Icon == DeckMenuSymbol, Trailing == EmptyView {
    /// The usual row: words, an SF Symbol or none, checked or not.
    init(_ title: String, symbol: String? = nil, detail: String? = nil, checked: Bool = false, role: DeckMenuRole = .normal,
         enabled: Bool = true, keepsOpen: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, checked: checked, role: role, enabled: enabled, keepsOpen: keepsOpen,
                  icon: { DeckMenuSymbol(name: symbol) }, trailing: { EmptyView() }, action: action)
    }
}

extension DeckMenuRow where Trailing == EmptyView {
    /// A row with its own picture (an AI's mark, a profile photo, a project logo) in the 16 pt icon box.
    init(_ title: String, detail: String? = nil, checked: Bool = false, role: DeckMenuRole = .normal, enabled: Bool = true,
         keepsOpen: Bool = false, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, detail: detail, checked: checked, role: role, enabled: enabled, keepsOpen: keepsOpen,
                  icon: icon, trailing: { EmptyView() }, action: action)
    }
}

extension DeckMenuRow where Icon == DeckMenuSymbol {
    /// A row that ends in something of its own (a shortcut, a count, a dot that needs him).
    init(_ title: String, symbol: String? = nil, detail: String? = nil, checked: Bool = false, role: DeckMenuRole = .normal,
         enabled: Bool = true, keepsOpen: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, detail: detail, checked: checked, role: role, enabled: enabled, keepsOpen: keepsOpen,
                  icon: { DeckMenuSymbol(name: symbol) }, trailing: trailing, action: action)
    }
}

/// An SF Symbol in the row's icon box; nil draws nothing and takes no room.
struct DeckMenuSymbol: View {
    let name: String?
    var body: some View {
        if let name {
            Image(systemName: name).font(.system(size: 13, weight: .regular))
                .frame(width: DeckMenuMetrics.icon, height: DeckMenuMetrics.icon)
                .accessibilityHidden(true)
        }
    }
}

/// The row's inside, apart from the button, so a row that is not a button (a switch row) lines up with the rest.
struct DeckMenuRowBody<Icon: View, Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var checked = false
    var role: DeckMenuRole = .normal
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DeckMenuMetrics.iconGap) {
            icon().foregroundStyle(role == .destructive ? AnyShapeStyle(DeckTokens.bad) : AnyShapeStyle(.secondary))
            Text(title).font(.system(size: DeckMenuMetrics.text)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(role == .destructive ? AnyShapeStyle(DeckTokens.bad) : AnyShapeStyle(.primary))
            if let detail {
                Text(detail).font(.system(size: DeckMenuMetrics.detailText)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            trailing()
            if checked {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 14, height: DeckMenuMetrics.icon)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DeckMenuMetrics.rowHorizontal)
        .frame(maxWidth: .infinity, minHeight: DeckMenuMetrics.rowHeight, maxHeight: DeckMenuMetrics.rowHeight, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct DeckMenuRowButtonStyle: ButtonStyle {
    let hovering: Bool
    let scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DeckMenuColours.pressed(scheme) : hovering ? DeckMenuColours.hover(scheme) : Color.clear,
                        in: .rect(cornerRadius: DeckMenuMetrics.rowRadius, style: .continuous))
    }
}

/// A row with a switch at its end. The whole row flips it; the menu stays open.
struct DeckMenuToggleRow: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil
    @Binding var isOn: Bool
    var enabled = true
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { isOn.toggle() } label: {
            DeckMenuRowBody(title: title, detail: detail, icon: { DeckMenuSymbol(name: symbol) }, trailing: { DeckSwitch(isOn: isOn) })
        }
        .buttonStyle(DeckMenuRowButtonStyle(hovering: hovering && enabled, scheme: scheme))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { if enabled { isOn.toggle() } }
    }
}

/// The app's small solid switch (28 x 16): accent when on, a quiet grey when off. A picture of the value only; the
/// row or button around it takes the press.
struct DeckSwitch: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.26 : 0.16)))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 12, height: 12).padding(2)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            }
            .animation(.easeOut(duration: 0.14), value: isOn)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Free content in a DeckMenu (a sentence, bars, a field): lined up with the rows' text.
    func deckMenuInset() -> some View {
        padding(.horizontal, DeckMenuMetrics.rowHorizontal).padding(.vertical, 7)
    }
}

/// A sentence in a menu: small, quiet, wraps.
struct DeckMenuNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckMenuInset()
    }
}

// MARK: - Presenting

/// Which edges of the control and the menu line up. The menu opens under the control, or over it when the screen
/// has no room below.
enum DeckMenuAlignment { case leading, trailing, center }

extension View {
    /// The app's menu, in place of `.popover`: opens under this view while `isPresented` is true. A click anywhere
    /// else, Escape, a row's press, or leaving the app closes it.
    func deckMenu<Content: View>(isPresented: Binding<Bool>, alignment: DeckMenuAlignment = .leading, width: CGFloat? = nil,
                                 @ViewBuilder content: @escaping () -> Content) -> some View {
        background(DeckMenuAnchor(isPresented: isPresented, alignment: alignment, width: width, content: content))
    }
}

private struct DeckMenuAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let alignment: DeckMenuAlignment
    let width: CGFloat?
    let content: () -> Content

    func makeCoordinator() -> DeckMenuController { DeckMenuController() }

    func makeNSView(context: Context) -> NSView { DeckMenuAnchorView() }

    func updateNSView(_ view: NSView, context: Context) {
        let controller = context.coordinator
        let binding = $isPresented
        controller.onDismiss = { if binding.wrappedValue { binding.wrappedValue = false } }
        if isPresented {
            controller.present(AnyView(content()), from: view, alignment: alignment, width: width)
        } else {
            controller.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: DeckMenuController) {
        coordinator.close()
    }
}

/// Never takes a click: it only marks where the control is.
private final class DeckMenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DeckMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class DeckMenuHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reported by the content when its natural height changes, so the panel follows (a list that arrives late).
private struct DeckMenuContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The panel's root: the surface inside clear room for its shadow; when the screen is too short the rows scroll.
private struct DeckMenuRoot: View {
    let content: AnyView
    let width: CGFloat?
    let dismiss: DeckMenuDismissAction
    let heightChanged: @MainActor (CGFloat) -> Void

    var body: some View {
        DeckMenuSurface(width: width) {
            ViewThatFits(in: .vertical) {
                measured
                ScrollView(.vertical) { measured }.scrollIndicators(.automatic)
            }
        }
        .environment(\.deckMenuDismiss, dismiss)
        .padding(DeckMenuMetrics.shadowRoom)
        .onPreferenceChange(DeckMenuContentHeight.self) { height in
            Task { @MainActor in heightChanged(height) }
        }
    }

    private var measured: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: DeckMenuContentHeight.self, value: proxy.size.height)
            })
    }
}

/// Owns the menu's panel: a borderless child window of the control's window, placed under the control.
@MainActor
final class DeckMenuController {
    var onDismiss: (() -> Void)?
    private var panel: DeckMenuPanel?
    private var host: DeckMenuHost?
    private weak var anchor: NSView?
    private var alignment: DeckMenuAlignment = .leading
    private var width: CGFloat?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var lastHeight: CGFloat = 0
    private var pending = false

    var isOpen: Bool { panel != nil }

    func present(_ content: AnyView, from anchor: NSView, alignment: DeckMenuAlignment, width: CGFloat?) {
        self.anchor = anchor
        self.alignment = alignment
        self.width = width
        let root = AnyView(DeckMenuRoot(content: content, width: width,
                                        dismiss: DeckMenuDismissAction { [weak self] in self?.dismiss() },
                                        heightChanged: { [weak self] height in self?.contentHeight(height) }))
        if let host {
            host.rootView = root
            fit()
            return
        }
        guard let parent = anchor.window else {
            // Asked to open before the control is on screen: once, on the next turn.
            guard !pending else { return }
            pending = true
            Task { @MainActor [weak self, weak anchor] in
                guard let self else { return }
                self.pending = false
                if let anchor, anchor.window != nil, self.panel == nil { self.present(content, from: anchor, alignment: alignment, width: width) }
            }
            return
        }
        let host = DeckMenuHost(rootView: root)
        let panel = DeckMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = parent.effectiveAppearance
        panel.identifier = .init("dev.terminaldeck.deck-menu")
        panel.contentView = host
        self.panel = panel
        self.host = host
        fit()
        panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            panel.animator().alphaValue = 1
        }
        watch(parent: parent, panel: panel)
    }

    /// Closes the panel and tells the owner (its `isPresented` goes false).
    func dismiss() {
        close()
        onDismiss?()
    }

    func close() {
        guard let panel else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        self.panel = nil
        host = nil
        lastHeight = 0
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func contentHeight(_ height: CGFloat) {
        guard abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height
        fit()
    }

    /// Sizes the panel to its content and puts it under (or over) the control, inside the screen.
    private func fit() {
        guard let panel, let host, let anchor, let window = anchor.window else { return }
        let room = DeckMenuMetrics.shadowRoom
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? rect.insetBy(dx: -600, dy: -600)
        let margin = DeckMenuMetrics.screenMargin
        let natural = host.fittingSize
        let surface = CGSize(width: natural.width - room * 2, height: natural.height - room * 2)
        let below = rect.minY - DeckMenuMetrics.gap - (screen.minY + margin)
        let above = (screen.maxY - margin) - (rect.maxY + DeckMenuMetrics.gap)
        let opensBelow = surface.height <= below || below >= above
        let height = min(surface.height, max(120, opensBelow ? below : above))
        var x: CGFloat
        switch alignment {
        case .leading: x = rect.minX
        case .trailing: x = rect.maxX - surface.width
        case .center: x = rect.midX - surface.width / 2
        }
        x = min(max(x, screen.minX + margin), screen.maxX - margin - surface.width)
        let y = opensBelow ? rect.minY - DeckMenuMetrics.gap - height : rect.maxY + DeckMenuMetrics.gap
        let frame = CGRect(x: x - room, y: y - room, width: surface.width + room * 2, height: height + room * 2)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func watch(parent: NSWindow, panel: DeckMenuPanel) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in self?.swallows(event) ?? false }
            return swallow ? nil : event
        }
        let center = NotificationCenter.default
        let closes: [(Notification.Name, NSObject?)] = [
            (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didResizeNotification, parent),
            (NSWindow.willCloseNotification, parent),
            (NSWindow.willBeginSheetNotification, parent),
        ]
        for (name, object) in closes {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.dismiss() } }
            })
        }
        // Another window took the keyboard: close, unless it is a menu or pop-up opened from inside this one.
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // A turn later: the window that takes the keyboard is known only then.
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
                if let key = NSApp.keyWindow, DeckMenuController.window(key, descendsFrom: panel) { return }
                self.dismiss()
            }
        })
    }

    /// True when the menu took the event (it is not passed on).
    private func swallows(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false } // Escape
            // A menu opened from inside this one closes first.
            if let key = NSApp.keyWindow, key !== panel, Self.window(key, descendsFrom: panel) { return false }
            dismiss()
            return true
        }
        if let window = event.window, Self.window(window, descendsFrom: panel) {
            if window === panel {
                // The clear room around the surface (its shadow) is outside the menu.
                let surface = panel.contentLayoutRect.insetBy(dx: DeckMenuMetrics.shadowRoom, dy: DeckMenuMetrics.shadowRoom)
                if !surface.contains(event.locationInWindow) { dismiss(); return true }
            }
            return false
        }
        // The control itself: its own press closes the menu (it toggles), so it must not be closed twice.
        if let anchor, event.window === anchor.window, anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) {
            return false
        }
        // A click anywhere else closes the menu and still lands where it was aimed.
        dismiss()
        return false
    }

    private static func window(_ window: NSWindow, descendsFrom ancestor: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let each = current {
            if each === ancestor { return true }
            current = each.parent
        }
        return false
    }
}
