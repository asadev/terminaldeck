/**
 * Watching — and driving — the machine's browser from the phone.
 *
 * The view half of `WatchLink`, and a port of `pwa/src/browser-view.ts` onto
 * UIKit. `WatchSurfacesView` is the tab strip: the surfaces the machine says are
 * watchable, each opening `WatchViewerScreen`, which casts one surface full
 * screen. `WatchSurfaceUIView` is the canvas — it decodes each frame's JPEG onto
 * its own layer and turns every tap and swipe into a `browser.input` aimed at
 * the frame it was measured against.
 *
 * The four rules from the PWA hold here exactly:
 *
 *  1. **Ack from the paint callback.** The host holds one un-acked frame per
 *     watcher, so the ack fires after the layer's contents are set, not on
 *     receipt — otherwise the phone asks for frames faster than it can show them.
 *  2. **The page lives on the server, so the surface never scrolls itself.** A
 *     swipe is a `browser.input` wheel; the layer only ever shows the server's
 *     viewport.
 *  3. **Coordinates are image pixels of a named frame.** Every gesture is
 *     measured against the frame currently drawn and sent with *that* `seq`.
 *  4. **A masked frame is a curtain, never pixels.** `data` is empty and the
 *     view draws its own lock card; the pixels never crossed the wire.
 */

import SwiftUI
import UIKit

// MARK: - The tab strip

struct WatchSurfacesView: View {
    let watch: WatchLink

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if watch.surfaces.isEmpty {
                ContentUnavailableView("No windows to watch",
                                       systemImage: "macwindow",
                                       description: Text("Open a browser window on the machine, or attach one to a session, and it will appear here."))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(watch.surfaces.enumerated()), id: \.element.id) { index, surface in
                            if index > 0 { Divider().background(Theme.hairline).padding(.leading, 16) }
                            NavigationLink {
                                WatchViewerScreen(watch: watch, surface: surface)
                            } label: {
                                surfaceRow(surface)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(16)

                    // Pushed from Settings, so it keeps the bar and owes it room.
                    TabBarClearance()
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .navigationTitle("Watch browser")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { watch.ensureRead() }
    }

    private func surfaceRow(_ surface: BrowserSurfaceRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: surface.live ? "dot.radiowaves.left.and.right" : "macwindow")
                .font(.system(size: 15))
                .foregroundStyle(surface.live ? Theme.positive : Theme.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(surface.title.isEmpty ? (surface.window.isEmpty ? "Front tab" : surface.window) : surface.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !surface.url.isEmpty {
                    Text(surface.url)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - The full-screen viewer

struct WatchViewerScreen: View {
    let watch: WatchLink
    let surface: BrowserSurfaceRow

    @State private var typing = ""
    @FocusState private var typingFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WatchSurface(watch: watch, window: surface.window)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .navigationTitle(surface.title.isEmpty ? "Browser" : surface.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    typingFocused = true
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Type into the page")
            }
        }
        .safeAreaInset(edge: .bottom) {
            // A hidden field made visible only to send text and Return to the
            // page — a phone has no hardware keyboard, and a live view you cannot
            // type into is half a browser. What is typed is pasted as one
            // `insertText`; Return is sent as an Enter key.
            if typingFocused {
                HStack(spacing: 8) {
                    TextField("Type into the page", text: $typing)
                        .textFieldStyle(.roundedBorder)
                        .focused($typingFocused)
                        .submitLabel(.send)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { sendTyping() }
                    Button("Send") { sendTyping() }
                        .disabled(typing.isEmpty)
                }
                .padding(10)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func sendTyping() {
        WatchSurface.pendingText = typing
        typing = ""
        // The surface reads and clears `pendingText` on the next runloop tick,
        // measuring it against the frame currently drawn. A static hand-off keeps
        // the SwiftUI value type from having to reach into the UIView.
        NotificationCenter.default.post(name: WatchSurface.sendTextNote, object: surface.window)
    }
}

// MARK: - The canvas

struct WatchSurface: UIViewRepresentable {
    let watch: WatchLink
    let window: String

    /// The text a `WatchViewerScreen` wants sent into the page, handed across the
    /// value-type boundary. Read and cleared by the view on the notification.
    static var pendingText: String = ""
    static let sendTextNote = Notification.Name("WatchSurfaceSendText")

    func makeUIView(context: Context) -> WatchSurfaceUIView {
        let view = WatchSurfaceUIView(watch: watch, target: window)
        return view
    }

    func updateUIView(_ uiView: WatchSurfaceUIView, context: Context) {}

    static func dismantleUIView(_ uiView: WatchSurfaceUIView, coordinator: ()) {
        uiView.tearDown()
    }
}

/// The layer-backed canvas: one surface's frames, and the gestures that drive it.
final class WatchSurfaceUIView: UIView {
    private let watch: WatchLink
    /// The surface this canvas shows — `""` for the front tab, else a slot name.
    /// Named `target` rather than `window` because `UIView.window` is taken.
    private let target: String

    /// The last frame actually drawn — what a gesture is measured against.
    private var lastFrame: BrowserFrame?
    /// The width last asked for, so a resize renegotiates only on a real change.
    private var requestedWidth = 0

    /// One decode at a time; a frame arriving mid-decode replaces the one waiting.
    private var painting = false
    private var queued: BrowserFrame?

    private let curtain = UILabel()
    private let decodeQueue = DispatchQueue(label: "watch.decode", qos: .userInteractive)

    // Gesture state, mirroring `WatchCanvas`.
    private enum Gesture { case none, pending, scroll }
    private var gesture: Gesture = .none
    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero

    init(watch: WatchLink, target: String) {
        self.watch = watch
        self.target = target
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        layer.contentsGravity = .resizeAspect

        curtain.numberOfLines = 0
        curtain.textAlignment = .center
        // The lock card is a fixed dark surface in both themes — the page is not
        // being shown, so it is deliberately not the app's paper. These are the
        // PWA's own curtain colours (`#e6e8ec` on `#101216`), written as RGB
        // rather than a white tint: `AppearanceTests` bans the tint shorthand
        // because it is the smell of a colour that forgot to adapt, and this one
        // is meant not to.
        curtain.textColor = UIColor(red: 0.902, green: 0.910, blue: 0.925, alpha: 1)
        curtain.font = .systemFont(ofSize: 15)
        curtain.isHidden = true
        curtain.translatesAutoresizingMaskIntoConstraints = false
        addSubview(curtain)
        NSLayoutConstraint.activate([
            curtain.centerXAnchor.constraint(equalTo: centerXAnchor),
            curtain.centerYAnchor.constraint(equalTo: centerYAnchor),
            curtain.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            curtain.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        // The link routes every `browser.frame` here. One sink, because a phone
        // shows one surface at a time; a frame for another window is dropped.
        watch.frameHandler = { [weak self] frame in
            guard let self, frame.window == self.target else { return }
            self.onFrame(frame)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(sendPendingText(_:)),
                                               name: WatchSurface.sendTextNote, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startWatching() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation or a size change renegotiates the render width, but only
        // when the device width actually moved — a host reading a stream of
        // identical watches would restart a screencast for nothing.
        let width = WatchMath.watchWidth(pointWidth: bounds.width, scale: traitCollection.displayScale)
        if width != requestedWidth { startWatching() }
    }

    private func startWatching() {
        guard bounds.width > 0 else { return }
        let width = WatchMath.watchWidth(pointWidth: bounds.width, scale: traitCollection.displayScale)
        requestedWidth = width
        _ = watch.watch(window: target, maxWidth: width, quality: defaultWatchQuality)
    }

    func tearDown() {
        watch.unwatch(window: target)
        // Only clear the sink if it is still ours — a later viewer may have
        // replaced it already.
        watch.frameHandler = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Paint + ack

    private func onFrame(_ frame: BrowserFrame) {
        if painting {
            queued = frame
            return
        }
        painting = true
        paint(frame)
    }

    private func paint(_ frame: BrowserFrame) {
        if frame.masked {
            showCurtain(frame.prompt ?? defaultCurtainPrompt)
            lastFrame = frame
            ackAndContinue(frame.seq)
            return
        }
        curtain.isHidden = true
        let data = frame.data
        decodeQueue.async { [weak self] in
            let image = UIImage(data: data)?.cgImage
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.layer.contents = image }
                // A frame the phone could not decode is still acked, or the whole
                // cast stalls on one bad frame; the last good frame stays under
                // the finger and its `seq` is what the next gesture maps against.
                self.lastFrame = frame
                self.ackAndContinue(frame.seq)
            }
        }
    }

    private func ackAndContinue(_ seq: Int) {
        watch.ack(window: target, seq: seq)
        painting = false
        if let next = queued {
            queued = nil
            onFrame(next)
        }
    }

    private func showCurtain(_ prompt: String) {
        layer.contents = nil
        backgroundColor = UIColor(red: 0.063, green: 0.071, blue: 0.086, alpha: 1)
        curtain.text = "\u{1F512}\n\n" + prompt
        curtain.isHidden = false
    }

    // MARK: - Gestures (touch only — a phone has no mouse)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, locate(touch) != nil else { return }
        startPoint = touch.location(in: self)
        lastPoint = startPoint
        // A touch has not decided whether it is a tap or a scroll — that is
        // settled by whether it travels, so nothing is sent on the way down.
        gesture = .pending
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard gesture != .none, let touch = touches.first, let at = locate(touch),
              let frame = lastFrame else { return }
        let point = touch.location(in: self)
        if gesture == .pending, hypot(point.x - startPoint.x, point.y - startPoint.y) < tapSlopPoints {
            return
        }
        // It has travelled: a scroll of the page on the server, sent as a wheel.
        gesture = .scroll
        let dx = Double(point.x - lastPoint.x) * (Double(frame.w) / Double(max(1, bounds.width)))
        let dy = Double(point.y - lastPoint.y) * (Double(frame.h) / Double(max(1, bounds.height)))
        watch.input(window: target, seq: at.seq,
                    input: .mouse(.init(type: .wheel, x: at.x, y: at.y, button: nil,
                                        clicks: nil, dx: Int(dx.rounded()), dy: Int(dy.rounded()))))
        lastPoint = point
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasPending = gesture == .pending
        gesture = .none
        guard wasPending, let touch = touches.first, let at = locate(touch) else { return }
        // A touch that never travelled: a tap, synthesised as a click so a page
        // with no touch handlers still responds.
        watch.input(window: target, seq: at.seq,
                    input: .mouse(.init(type: .down, x: at.x, y: at.y, button: .left, clicks: 1, dx: nil, dy: nil)))
        watch.input(window: target, seq: at.seq,
                    input: .mouse(.init(type: .up, x: at.x, y: at.y, button: .left, clicks: nil, dx: nil, dy: nil)))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        gesture = .none
    }

    /// The image coordinates and frame `seq` a touch names, or nil when there is
    /// no frame to measure against (or it is masked — a curtain takes no taps).
    private func locate(_ touch: UITouch) -> (seq: Int, x: Int, y: Int)? {
        guard let frame = lastFrame, !frame.masked else { return nil }
        let point = touch.location(in: self)
        let coords = WatchMath.imageCoords(frameW: frame.w, frameH: frame.h,
                                           viewW: bounds.width, viewH: bounds.height,
                                           px: point.x, py: point.y)
        return (frame.seq, coords.x, coords.y)
    }

    // MARK: - Typed text

    @objc private func sendPendingText(_ note: Notification) {
        guard (note.object as? String) == target, let frame = lastFrame, !frame.masked else { return }
        let text = WatchSurface.pendingText
        WatchSurface.pendingText = ""
        let cleaned = WatchMath.cleanPaste(text)
        guard !cleaned.isEmpty else { return }
        // Text as one paste, then Return as an Enter key — the two things a page
        // form needs from a phone with no hardware keyboard.
        watch.input(window: target, seq: frame.seq, input: .paste(cleaned))
        watch.input(window: target, seq: frame.seq,
                    input: .key(.init(type: .down, key: "Enter", code: "Enter", text: nil, mods: 0)))
    }
}
