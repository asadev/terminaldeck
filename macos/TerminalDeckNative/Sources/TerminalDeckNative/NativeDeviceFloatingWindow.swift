import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// A simulator or emulator in its own window (ANDROID lane, 10 Oct). Asad: "when open a simulator in new
// window open only phone frame and a small seperate stip of action buttons with little bit distance but
// attache means moves with it". The window is the phone frame alone: transparent, no title bar, the
// shadow follows the frame, dragged by the frame; the traffic lights show only while the pointer is over
// it. The action buttons live in a small glass strip, a child window a few points under the phone, so it
// moves with it and stays put under it when the phone is resized or turned. iOS and Android alike.

private struct PhoneFrameDragsWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The phone frame moves its window (a device in a window of its own has no title bar to drag).
    var phoneFrameDragsWindow: Bool {
        get { self[PhoneFrameDragsWindowKey.self] }
        set { self[PhoneFrameDragsWindowKey.self] = newValue }
    }
}

/// Dragging the frame drags the window (only in the floating device window).
struct NativeFrameDragsWindow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.gesture(WindowDragGesture()) } else { content }
    }
}

/// Placed behind a device window's content: turns its window into the floating phone and keeps the strip.
struct NativeDeviceFloatingWindow: NSViewRepresentable {
    let model: NativeSimulatorModel
    var moveBack: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> Host { Host(model: model) }

    func updateNSView(_ view: Host, context: Context) {
        view.moveBack = moveBack
        view.keepFloating()
        // Read here so a turned phone (or the first picture) re-shapes the window.
        view.shape(content: model.frameContent, device: model.device)
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detachStrip() }

    @MainActor final class Host: NSView {
        let model: NativeSimulatorModel
        var moveBack: (@MainActor () -> Void)?
        private var strip: StripPanel?
        private var observers: [NSObjectProtocol] = []
        private var shapedFor: CGSize?
        private var sized = false

        /// The stage's own padding around the frame (DeviceStage pads by 12).
        static let stagePadding: CGFloat = 12
        /// Extra room above the phone for the window buttons (traffic lights left, back/close right).
        static let topInset: CGFloat = 18
        private var corner: NSTitlebarAccessoryViewController?
        /// Seen gap between the phone and the strip: the stage's transparent padding plus this.
        static let gap: CGFloat = -4

        init(model: NativeSimulatorModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { detachStrip(); return }
            configure(window)
            attachStrip(to: window)
            updateTrackingAreas()
        }

        /// SwiftUI sets the title back when the screen's title changes: keep it the phone alone.
        func keepFloating() {
            guard let window else { return }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.backgroundColor != .clear { window.backgroundColor = .clear; window.isOpaque = false }
            if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
            if !hovering { setControls(visible: false, animated: false) } // AppKit shows them again when the window is first ordered in
        }

        private func configure(_ window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbar?.isVisible = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = false // the frame drags it; the screen taps
            window.minSize = NSSize(width: 120, height: 120)
            addCornerButtons(to: window)
            setControls(visible: false, animated: false)
        }

        /// Back to the panel and close, at the window's top right, level with the traffic lights.
        private func addCornerButtons(to window: NSWindow) {
            guard corner == nil else { return }
            let buttons = NativeDeviceWindowCornerButtons(moveBack: { [weak self] in self?.moveBack?() },
                                                          close: { [weak self] in self?.window?.performClose(nil) })
            let hosting = NSHostingView(rootView: buttons)
            hosting.frame = NSRect(x: 0, y: 0, width: 64, height: 28)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = hosting
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
            corner = accessory
        }

        // MARK: Shape

        /// The window takes the phone's proportions (frame and its padding), so it is the phone and nothing else.
        func shape(content: CGSize?, device: DeviceDetails?) {
            guard let window, let content, content.width > 0, content.height > 0 else { return }
            let outer = NativePhoneFrame.spec(for: device, content: content)?.outerSize(content: content) ?? content
            let padded = CGSize(width: outer.width + Self.stagePadding * 2, height: outer.height + Self.stagePadding * 2 + Self.topInset)
            guard padded != shapedFor else { return }
            let turned = shapedFor.map { ($0.width > $0.height) != (padded.width > padded.height) } ?? false
            shapedFor = padded
            window.contentAspectRatio = padded
            let current = window.contentLayoutRect.size
            var height = current.height
            if !sized || turned {
                // First picture: a comfortable phone height on this screen; turned: keep the long side.
                let limit = (window.screen?.visibleFrame.height ?? 900) * 0.78
                height = !sized ? min(limit, 760) : min(limit, max(current.width, current.height) * padded.height / max(padded.width, padded.height))
                sized = true
            }
            let width = (height * padded.width / padded.height).rounded()
            var frame = window.frame
            let top = frame.maxY
            frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: width, height: height.rounded()))).size
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: true, animate: false)
            placeStrip()
            DispatchQueue.main.async { [weak window] in window?.invalidateShadow() }
        }

        // MARK: Window controls on hover

        private var hover: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hover { removeTrackingArea(hover) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); hover = area
        }
        private var hovering = false
        override func mouseEntered(with event: NSEvent) { hovering = true; setControls(visible: true, animated: true) }
        override func mouseExited(with event: NSEvent) { hovering = false; setControls(visible: false, animated: true) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // a backdrop only: every click goes to the phone

        private func setControls(visible: Bool, animated: Bool) {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) as NSView? }
                + [corner?.view].compactMap { $0 }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    for button in buttons { button.animator().alphaValue = visible ? 1 : 0 }
                }
            } else { for button in buttons { button.alphaValue = visible ? 1 : 0 } }
        }

        // MARK: The strip

        private func attachStrip(to window: NSWindow) {
            if strip == nil {
                let panel = StripPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false // the glass draws its own edge
                panel.isReleasedWhenClosed = false
                panel.becomesKeyOnlyIfNeeded = true
                panel.hidesOnDeactivate = false
                panel.animationBehavior = .none
                let content = NativeDeviceControlStrip(model: model,
                    moveBack: { [weak self] in self?.moveBack?() },
                    close: { [weak self] in self?.window?.performClose(nil) },
                    resized: { [weak self] in self?.placeStrip() })
                let hosting = NSHostingView(rootView: content)
                hosting.sizingOptions = [.intrinsicContentSize]
                panel.contentView = hosting
                strip = panel
            }
            guard let strip else { return }
            if strip.parent !== window {
                strip.parent?.removeChildWindow(strip)
                window.addChildWindow(strip, ordered: .above)
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeStrip(); self?.window?.invalidateShadow() }
                }
            } + [NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepFloating() }
            }, NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detachStrip() }
            }]
            placeStrip()
        }

        /// Centred under the phone, a few points below its frame.
        func placeStrip() {
            guard let window, let strip, let hosting = strip.contentView else { return }
            let size = hosting.fittingSize
            let frame = window.frame
            let origin = NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.minY - Self.gap - size.height).rounded())
            strip.setFrame(NSRect(origin: origin, size: size), display: true)
            if strip.parent == nil { window.addChildWindow(strip, ordered: .above) }
            keepFloating()
        }

        func detachStrip() {
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            if let strip { strip.parent?.removeChildWindow(strip); strip.orderOut(nil) }
        }

        /// The strip itself, for checks.
        var stripWindow: NSWindow? { strip }
    }

    /// A borderless panel that can still take typing (the Annotate box, a screenshot's note).
    final class StripPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

/// Record for a device outside a session (a device tab or its own window): the same Record button,
/// card and voice as the session panel (NativeSimRecorder), recorded straight from this Mac: `simctl io
/// recordVideo` for an iOS Simulator, the segmenting `adb screenrecord` for Android. Videos go to
/// ~/Movies/Terminal Deck; the card sends them to a session or Hoot like the panel's.
@MainActor final class NativeDeviceDirectRecorder {
    private var process: (any BackendUIGSessionSimulatorRecordingProcess)?
    private var file: URL?
    private var stopping = false

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent(BackendSharedBrand.name, isDirectory: true)
    }

    /// Gives `model` a Record button (once per model).
    static func attach(to model: NativeSimulatorModel) {
        guard NativeSimRecorder.of(model) == nil else { return }
        let recorder = NativeDeviceDirectRecorder()
        NativeSimRecorder.attach(to: model) { [weak model] action in
            guard let id = model?.device?.id else { throw failure("Open a running simulator or emulator to record it.") }
            return try await recorder.run(action, deviceID: id)
        }
    }

    func run(_ action: String, deviceID: String) async throws -> Any {
        switch action {
        case "start":
            if stopping { throw Self.failure("The last recording is still finishing.") }
            if let process, process.running, let file { return ["path": file.path] }
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let file = Self.folder.appendingPathComponent("simulator-recording-" + UUID().uuidString + ".mp4")
            if let serial = BackendAndroidScreenRecord.serial(deviceID) {
                process = try BackendAndroidScreenRecordProcess.live(serial: serial, file: file)
            } else {
                process = try BackendUIGSessionSimulatorOwnedRecordingProcess(arguments: try BackendUIGSessionSimulatorRecording.arguments(deviceID: deviceID, file: file))
            }
            self.file = file
            return ["path": file.path]
        case "stop":
            if stopping { throw Self.failure("The last recording is still finishing.") }
            guard let process, let file else { throw Self.failure("Nothing is recording.") }
            // Held until it has really ended, so Start cannot begin a second recorder beside it (#123).
            stopping = true
            defer { self.process = nil; self.file = nil; stopping = false }
            let status = await process.stop()
            guard status == 0, FileManager.default.fileExists(atPath: file.path) else { throw Self.failure("The recorder did not save a finished video.") }
            return ["path": file.path]
        default:
            throw Self.failure("Unknown recording step.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TerminalDeck.DeviceRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The floating phone window's top-right buttons (shown with the traffic lights).
struct NativeDeviceWindowCornerButtons: View {
    var moveBack: () -> Void
    var close: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            button("Move back to the panel", "arrow.down.left.square", moveBack)
            button("Close this window", "xmark", close)
        }
        .padding(.trailing, 8).frame(height: 28)
    }
    private func button(_ label: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .background(.regularMaterial, in: Circle())
            .help(label).accessibilityLabel(label)
    }
}
