import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import TerminalDeckNativeCore

/// The live device screen, decoded natively.
///
/// The engine's H.264 stream arrives on `devices:frame` exactly as the web
/// page gets it (`ScreenPacket`): the decoder configuration, then one coded
/// picture per packet. Here the configuration becomes a `CMVideoFormatDescription`,
/// each picture a `CMSampleBuffer`, and an `AVSampleBufferDisplayLayer` decodes
/// them in hardware and composites the newest one at the display's own density
/// — the same thing `screen-player.ts` does with WebCodecs and a canvas, with
/// one less copy.
///
/// Falling behind is handled the way the page handles it: what has not been
/// decoded is dropped, and the next keyframe is waited for and asked for.
@MainActor
final class DeviceScreenPlayer {
    let displayLayer = AVSampleBufferDisplayLayer()
    let stillLayer = CALayer()

    /// A picture of a new size arrived — first, or after a rotation.
    var onPictureSize: ((CGSize) -> Void)?
    /// The decoder needs a fresh keyframe; watching again asks the engine for one.
    var needKeyframe: (() -> Void)?
    /// Any picture arrived. Called per frame, so it must not touch observed state.
    var onPicture: (() -> Void)?

    private(set) var pictureSize: CGSize?
    private var format: CMVideoFormatDescription?
    private var lastConfig: Data?
    private var waitingForKey = true
    private var lastAsk = Date.distantPast

    // What the hidden diagnostics readout shows.
    private(set) var received = 0
    private(set) var enqueued = 0
    private(set) var resets = 0
    private(set) var codec: String?
    private(set) var hardware = "unknown"

    init() {
        displayLayer.videoGravity = .resizeAspect
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        let still: [String: any CAAction] = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        stillLayer.actions = still
        displayLayer.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    /// One packet from the engine, tagged with its kind.
    func push(_ data: Data) {
        guard let packet = ScreenPacket(data) else { return }
        switch packet {
        case .config(let avcC): configure(avcC)
        case let .picture(timestamp, key, bytes): decode(timestamp: timestamp, key: key, bytes: bytes)
        case .jpeg(let bytes), .still(let bytes): still(bytes)
        }
    }

    /// Forget the stream — a new device, or the screen closing.
    func reset() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        format = nil
        lastConfig = nil
        waitingForKey = true
        stillLayer.contents = nil
        stillLayer.isHidden = true
        pictureSize = nil
        received = 0
        enqueued = 0
        resets = 0
    }

    private func configure(_ avcC: Data) {
        guard let config = AVCConfiguration(avcC: avcC) else { return }
        codec = config.codec
        if avcC == lastConfig, format != nil {
            // The same stream again (a window watching again): a keyframe follows.
            waitingForKey = true
            return
        }
        do {
            let next = try CMVideoFormatDescription(h264ParameterSets: config.parameterSets,
                                                    nalUnitHeaderLength: config.nalLengthSize)
            format = next
            lastConfig = avcC
            waitingForKey = true
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            }
            let dims = next.presentationDimensions(usePixelAspectRatio: false, useCleanAperture: true)
            setPictureSize(CGSize(width: dims.width, height: dims.height))
        } catch {
            format = nil
            askForKeyframe()
        }
    }

    private func decode(timestamp: UInt64, key: Bool, bytes: Data) {
        received += 1
        guard let format else {
            // A picture with nothing to decode it: this screen joined after the
            // configuration went past. Watching again sends it.
            askForKeyframe()
            return
        }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            hardware = renderer.status == .failed ? "failed" : hardware
            waitingForKey = true
            resets += 1
            askForKeyframe()
        }
        if waitingForKey && !key { return }
        if !renderer.isReadyForMoreMediaData {
            // Behind. Drop what has not been decoded and start again from a keyframe.
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            resets += 1
            waitingForKey = true
            askForKeyframe()
            if !key { return }
        }
        guard let sample = Self.sample(bytes: bytes, format: format, timestamp: timestamp, key: key) else {
            waitingForKey = true
            askForKeyframe()
            return
        }
        waitingForKey = false
        renderer.enqueue(sample)
        enqueued += 1
        if hardware == "unknown" { hardware = "VideoToolbox" }
        if !stillLayer.isHidden {
            stillLayer.isHidden = true
            stillLayer.contents = nil
        }
        onPicture?()
    }

    private func still(_ bytes: Data) {
        guard let image = NSImage(data: bytes),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        stillLayer.contents = cgImage
        stillLayer.isHidden = false
        setPictureSize(CGSize(width: cgImage.width, height: cgImage.height))
        onPicture?()
    }

    private func setPictureSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != pictureSize else { return }
        pictureSize = size
        onPictureSize?(size)
    }

    private func askForKeyframe() {
        let now = Date()
        guard now.timeIntervalSince(lastAsk) >= 0.5 else { return }
        lastAsk = now
        needKeyframe?()
    }

    /// One coded picture as a sample shown the moment it is decoded.
    private static func sample(bytes: Data, format: CMVideoFormatDescription, timestamp: UInt64, key: Bool) -> CMSampleBuffer? {
        guard !bytes.isEmpty else { return nil }
        do {
            let block = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
            try bytes.withUnsafeBytes { raw in try block.replaceDataBytes(with: raw) }
            let timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp & 0x7FFF_FFFF_FFFF_FFFF), timescale: 1_000_000),
                                            decodeTimeStamp: .invalid)
            let sample = try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: 1,
                                            sampleTimings: [timing], sampleSizes: [bytes.count])
            // Shown the moment it is decoded — no clock to wait for — and marked as
            // depending on the pictures before it unless it is a keyframe.
            if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(array) > 0 {
                let attachments = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
                func set(_ key: CFString) {
                    CFDictionarySetValue(attachments, Unmanaged.passUnretained(key).toOpaque(),
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                set(kCMSampleAttachmentKey_DisplayImmediately)
                if !key { set(kCMSampleAttachmentKey_NotSync) }
            }
            return sample
        } catch {
            return nil
        }
    }
}

// MARK: - The view that shows it and takes the mouse and the keyboard

/// What the screen reports back. Closures, so the view stays a plain AppKit view.
struct DeviceScreenEvents {
    /// Something to send to the device — only while the screen is live and not inspecting.
    var input: (DeviceInput) -> Void
    /// Inspecting: the pointer is over this normalised point, or left the picture.
    var hover: (_ point: CGPoint?) -> Void
    /// Inspecting: a click on this normalised point.
    var pick: (_ point: CGPoint) -> Void
    /// The window can or cannot be seen.
    var visibility: (Bool) -> Void
}

/// A device's screen: the decoded picture, and the mouse as a finger.
///
/// Where the device can hold a finger down (every iOS Simulator), a press is a
/// finger going down, a drag is it moving and a release is it lifting. Where it
/// cannot, a press-and-release is a tap, a long press a long press, and a drag
/// one swipe. The wheel scrolls as a short swipe. Once the screen has focus —
/// a click gives it focus — typing goes to the device; ⌘V types this Mac's
/// clipboard. In Inspect mode the mouse points instead of touching.
final class DeviceScreenNSView: NSView {
    var player: DeviceScreenPlayer? {
        didSet { attachPlayer() }
    }
    /// The picture's size, for fitting it and measuring points against it.
    var fitSize: CGSize? {
        didSet { if fitSize != oldValue { needsLayout = true } }
    }
    var details: DeviceDetails?
    /// Input goes to the device.
    var live = true
    /// The mouse points at elements instead.
    var inspecting = false {
        didSet {
            if inspecting != oldValue {
                window?.invalidateCursorRects(for: self)
                press = nil
                if !inspecting { events?.hover(nil) }
            }
        }
    }
    var events: DeviceScreenEvents?

    private struct Press {
        var x: Double
        var y: Double
        var at: Date
        var moved: Bool
        var last: CGPoint
    }
    private var press: Press?
    private var typed = ""
    private var typeTimer: Timer?
    private var wheelX = 0.0
    private var wheelY = 0.0
    private var wheelTimer: Timer?
    private var occlusion: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func attachPlayer() {
        guard let player, let layer else { return }
        for sub in [player.displayLayer, player.stillLayer] where sub.superlayer !== layer {
            sub.removeFromSuperlayer()
            layer.addSublayer(sub)
        }
        needsLayout = true
    }

    /// Where the picture is drawn in this view.
    var fitted: CGRect {
        DeviceGeometry.fitted(content: fitSize ?? bounds.size, in: bounds.size)
    }

    override func layout() {
        super.layout()
        guard let player else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = fitted
        player.displayLayer.frame = rect
        player.stillLayer.frame = rect
        CATransaction.commit()
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        attachPlayer()
        guard let window else {
            events?.visibility(false)
            return
        }
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportVisibility() }
        }
        reportVisibility()
    }

    private func reportVisibility() {
        events?.visibility(window?.occlusionState.contains(.visible) ?? false)
    }

    // MARK: Cursor and hover

    override func resetCursorRects() {
        if inspecting { addCursorRect(fitted, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard inspecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        events?.hover(DeviceGeometry.normalizedInside(point, in: fitted).map { CGPoint(x: $0.x, y: $0.y) })
    }

    override func mouseExited(with event: NSEvent) {
        if inspecting { events?.hover(nil) }
    }

    // MARK: The mouse is a finger

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        return DeviceGeometry.normalized(point, in: fitted).map { CGPoint(x: $0.x, y: $0.y) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if inspecting {
            let point = convert(event.locationInWindow, from: nil)
            if let at = DeviceGeometry.normalizedInside(point, in: fitted) {
                events?.pick(CGPoint(x: at.x, y: at.y))
            }
            return
        }
        guard live, let at = normalized(event) else { return }
        press = Press(x: at.x, y: at.y, at: Date(), moved: false, last: at)
        if details?.rawTouch == true { events?.input(.touch(phase: "down", x: at.x, y: at.y)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var held = press, let at = normalized(event) else { return }
        held.last = at
        if hypot(at.x - held.x, at.y - held.y) > DeviceGesture.tapTravel { held.moved = true }
        press = held
        // Moves that pile up while one is on its way are folded into the newest (`DeviceInputQueue`).
        if details?.rawTouch == true { events?.input(.touch(phase: "move", x: at.x, y: at.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let held = press else { return }
        press = nil
        let at = normalized(event) ?? held.last
        if details?.rawTouch == true {
            events?.input(.touch(phase: "up", x: at.x, y: at.y))
            return
        }
        let heldMs = Date().timeIntervalSince(held.at) * 1000
        events?.input(DeviceGesture.release(fromX: held.x, fromY: held.y, toX: at.x, toY: at.y,
                                            moved: held.moved, heldMs: heldMs))
    }

    override func scrollWheel(with event: NSEvent) {
        guard live, !inspecting else { return }
        // The page's convention: positive is further down the content. A line
        // from a notched wheel is counted as forty points, as a browser does.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
        wheelY += -Double(event.scrollingDeltaY) * scale
        wheelX += -Double(event.scrollingDeltaX) * scale
        guard wheelTimer == nil else { return }
        wheelTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wheelTimer = nil
                let gesture = DeviceGesture.wheel(dx: self.wheelX, dy: self.wheelY)
                self.wheelX = 0
                self.wheelY = 0
                if let gesture { self.events?.input(gesture) }
            }
        }
    }

    // MARK: The keyboard is the device's keyboard

    private static let namedKeys: [UInt16: String] = [
        36: "return", 76: "return", 51: "delete", 48: "tab",
        126: "arrow-up", 125: "arrow-down", 123: "arrow-left", 124: "arrow-right",
    ]

    override func keyDown(with event: NSEvent) {
        guard live, !inspecting, let details else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) || flags.contains(.control) {
            if chars == "v" { return paste(nil) }
            if chars == "a", details.keys.contains("select-all") { return selectAll(nil) }
            return super.keyDown(with: event)
        }
        if flags.contains(.option) { return super.keyDown(with: event) }
        if let named = Self.namedKeys[event.keyCode] {
            flushTyping()
            if details.keys.contains(named) {
                events?.input(.key(named))
            } else if named == "return" {
                events?.input(.type("\n"))
            }
            return
        }
        guard let text = event.characters, !text.isEmpty, details.text != "none",
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return super.keyDown(with: event) }
        typed += text
        typeTimer?.invalidate()
        typeTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushTyping() }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V and ⌘A belong to the device while its screen has focus.
        guard window?.firstResponder === self, live, !inspecting else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, chars == "v" { paste(nil); return true }
        if flags == .command, chars == "a", details?.keys.contains("select-all") == true { selectAll(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard live, !inspecting, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        flushTyping()
        events?.input(.type(String(text.prefix(2_000))))
    }

    override func selectAll(_ sender: Any?) {
        guard live, !inspecting else { return }
        flushTyping()
        events?.input(.key("select-all"))
    }

    private func flushTyping() {
        typeTimer?.invalidate()
        typeTimer = nil
        let text = typed
        typed = ""
        if !text.isEmpty { events?.input(.type(text)) }
    }

    override func resignFirstResponder() -> Bool {
        flushTyping()
        return super.resignFirstResponder()
    }
}

/// The screen in SwiftUI. The model owns the player; this only hosts its layers.
struct DeviceScreenSurface: NSViewRepresentable {
    let model: NativeSimulatorModel

    func makeNSView(context: Context) -> DeviceScreenNSView {
        let view = DeviceScreenNSView(frame: .zero)
        view.player = model.player
        view.events = DeviceScreenEvents(
            input: { [weak model] input in model?.sendInput(input) },
            hover: { [weak model] point in model?.hover(at: point) },
            pick: { [weak model] point in model?.pick(at: point) },
            visibility: { [weak model] visible in model?.setVisible(visible) })
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DeviceScreenNSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DeviceScreenNSView) {
        view.fitSize = model.fitSize
        view.details = model.device
        view.live = model.device != nil && !model.isFrozen
        view.inspecting = model.inspecting
    }
}
