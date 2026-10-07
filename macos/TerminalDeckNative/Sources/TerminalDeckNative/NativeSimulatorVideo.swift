import AppKit
import AVFoundation
import CoreMedia
import VideoToolbox
import SwiftUI
import TerminalDeckNativeCore

/// The live device screen, decoded natively.
///
/// The engine's H.264 stream arrives on `devices:frame` exactly as the web
/// page gets it (`ScreenPacket`): the decoder configuration, then one coded
/// picture per packet. A `VTDecompressionSession` decodes each in hardware, and
/// only the newest decoded picture is handed to an `AVSampleBufferDisplayLayer`,
/// which composites it at the display's own density — what `screen-player.ts`
/// does with WebCodecs and a canvas, with the same counts behind the hidden
/// diagnostics readout.
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
    /// Any picture was painted. Called per frame, so it must not touch observed state.
    var onPicture: (() -> Void)?
    /// The display's density, told by the view, for the readout.
    var backingScale = 1.0
    /// The picture's drawn size in pixels, told by the view.
    var canvas = CGSize.zero
    /// Inspect is on: the picture on show is fingerprinted (at most fifteen times a
    /// second, the last one always) for `onSignature`, so a change can be noticed
    /// without ever pausing the video.
    var signing = false {
        didSet { if !signing { signPending = false } }
    }
    var onSignature: ((ScreenSignature) -> Void)?

    private(set) var pictureSize: CGSize?
    private var format: CMVideoFormatDescription?
    private var lastConfig: Data?
    private var decoder: VTDecompressionSession?
    /// Bumped whenever the decoder is replaced, so a late picture from the old one is let go.
    private var generation = 0
    private var inFlight = 0
    private var waitingForKey = true
    private var lastAsk = Date.distantPast
    private var pending: CVImageBuffer?
    /// The picture on show, kept so a marker can keep the frame the person saw.
    private var shown: CVImageBuffer?
    private var shownStill: CGImage?
    private var signedAt: CFTimeInterval = 0
    private var signPending = false
    private static let signEvery: CFTimeInterval = 1.0 / 15
    private var paintScheduled = false
    private var inputAt: CFTimeInterval?
    private var counts = PlayerStats()

    /// More coded pictures than this waiting to decode means this screen is behind.
    private static let maxBacklog = 12

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

    /// A touch, key or wheel just went to the device: the next picture painted is timed from here.
    func markInput() {
        if inputAt == nil { inputAt = CACurrentMediaTime() }
    }

    /// A copy of the numbers, for the readout.
    func stats() -> PlayerStats {
        var copy = counts
        copy.stream = pictureSize
        copy.canvas = canvas
        return copy
    }

    /// Forget the stream — a new device, or the screen closing.
    func reset() {
        dropDecoder()
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        format = nil
        lastConfig = nil
        waitingForKey = true
        pending = nil
        shown = nil
        shownStill = nil
        stillLayer.contents = nil
        stillLayer.isHidden = true
        pictureSize = nil
        inputAt = nil
        counts = PlayerStats()
    }

    private func dropDecoder() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        generation += 1
        inFlight = 0
    }

    private func configure(_ avcC: Data) {
        guard let config = AVCConfiguration(avcC: avcC) else { return }
        counts.codec = config.codec
        if avcC == lastConfig, decoder != nil {
            // The same stream again (a screen watching again): a keyframe follows.
            waitingForKey = true
            return
        }
        guard let next = try? CMVideoFormatDescription(h264ParameterSets: config.parameterSets,
                                                       nalUnitHeaderLength: config.nalLengthSize) else {
            askForKeyframe()
            return
        }
        format = next
        lastConfig = avcC
        waitingForKey = true
        makeDecoder()
        let dims = next.presentationDimensions(usePixelAspectRatio: false, useCleanAperture: true)
        setPictureSize(CGSize(width: dims.width, height: dims.height))
    }

    private func makeDecoder() {
        dropDecoder()
        guard let format else { return }
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue] as CFDictionary
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        var made: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &made) == noErr, let made else {
            counts.hardware = "no"
            return
        }
        decoder = made
        var usingHardware: CFTypeRef?
        if VTSessionCopyProperty(made, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                 allocator: nil, valueOut: &usingHardware) == noErr {
            counts.hardware = (usingHardware as? Bool) == true ? "yes" : "no"
        }
    }

    private func decode(timestamp: UInt64, key: Bool, bytes: Data) {
        counts.received += 1
        guard let format, decoder != nil else {
            // A picture with nothing to decode it: this screen joined after the
            // configuration went past. Watching again sends it.
            askForKeyframe()
            return
        }
        if waitingForKey && !key { return }
        if inFlight > Self.maxBacklog {
            // Behind. Drop everything not yet decoded and start again from a keyframe,
            // rather than paint a minute-old screen in slow motion.
            makeDecoder()
            counts.resets += 1
            waitingForKey = true
            askForKeyframe()
            if !key { return }
        }
        guard let decoder, let sample = Self.sample(bytes: bytes, format: format, timestamp: timestamp) else {
            recover()
            return
        }
        waitingForKey = false
        inFlight += 1
        let started = CACurrentMediaTime()
        let generation = self.generation
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
                                                       flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
                                                       infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            let decoded = DecodedPicture(image: status == noErr ? image : nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.decoded(decoded, generation: generation, started: started) }
            }
        }
        if status != noErr {
            inFlight -= 1
            recover()
        }
    }

    private func decoded(_ picture: DecodedPicture, generation: Int, started: CFTimeInterval) {
        guard generation == self.generation else { return }
        inFlight = max(0, inFlight - 1)
        guard let image = picture.image else {
            recover()
            return
        }
        counts.decoded += 1
        PlayerStats.remember(&counts.decodeMs, (CACurrentMediaTime() - started) * 1000)
        // Only the newest is painted; one waiting before it was never shown and is let go.
        if pending != nil { counts.dropped += 1 }
        pending = image
        guard !paintScheduled else { return }
        paintScheduled = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.paint() } }
    }

    private func paint() {
        paintScheduled = false
        guard let image = pending else { return }
        pending = nil
        guard let description = try? CMVideoFormatDescription(imageBuffer: image),
              let sample = try? CMSampleBuffer(imageBuffer: image, formatDescription: description,
                                               sampleTiming: CMSampleTimingInfo(duration: .invalid,
                                                                                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                                                                decodeTimeStamp: .invalid))
        else { return }
        Self.showImmediately(sample)
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
        renderer.enqueue(sample)
        counts.painted += 1
        if let inputAt {
            PlayerStats.remember(&counts.inputToPictureMs, (CACurrentMediaTime() - inputAt) * 1000)
            self.inputAt = nil
        }
        if !stillLayer.isHidden {
            stillLayer.isHidden = true
            stillLayer.contents = nil
        }
        shown = image
        shownStill = nil
        onPicture?()
        sign()
    }

    private func recover() {
        waitingForKey = true
        makeDecoder()
        askForKeyframe()
    }

    private func still(_ bytes: Data) {
        guard let image = NSImage(data: bytes),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        stillLayer.contents = cgImage
        stillLayer.isHidden = false
        shownStill = cgImage
        setPictureSize(CGSize(width: cgImage.width, height: cgImage.height))
        counts.painted += 1
        onPicture?()
        sign()
    }

    // MARK: The picture on show, for Inspect

    /// The picture on show now, as an image — the frame a marker keeps.
    func currentPicture() -> CGImage? {
        if !stillLayer.isHidden, let shownStill { return shownStill }
        guard let shown else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(shown, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    private func sign() {
        guard signing, onSignature != nil else { return }
        let now = CACurrentMediaTime()
        let wait = signedAt + Self.signEvery - now
        if wait > 0 {
            // Too soon after the last: fingerprint whatever is on show once the gap has passed.
            guard !signPending else { return }
            signPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    guard self.signPending else { return }
                    self.signPending = false
                    self.sign()
                }
            }
            return
        }
        signedAt = now
        let signature: ScreenSignature?
        if !stillLayer.isHidden, let shownStill {
            signature = Self.signature(shownStill)
        } else if let shown {
            signature = Self.signature(shown)
        } else {
            signature = nil
        }
        if let signature { onSignature?(signature) }
    }

    /// The brightness grid of a decoded picture, read straight from its luma plane
    /// (or the green of a 32-bit one) — a thousand bytes, no copy, no drawing.
    static func signature(_ buffer: CVPixelBuffer) -> ScreenSignature? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let eightBitPlanar: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                           kCVPixelFormatType_420YpCbCr8Planar,
                                           kCVPixelFormatType_420YpCbCr8PlanarFullRange]
        let base: UnsafeMutableRawPointer?
        let rowBytes: Int
        let width: Int
        let height: Int
        let step: Int
        let offset: Int
        if CVPixelBufferIsPlanar(buffer), eightBitPlanar.contains(format) {
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            step = 1
            offset = 0
        } else if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            base = CVPixelBufferGetBaseAddress(buffer)
            rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            step = 4
            offset = format == kCVPixelFormatType_32BGRA ? 1 : 2
        } else {
            return nil
        }
        guard let base else { return nil }
        return ScreenSignature.sample(width: width, height: height) { x, y in
            base.load(fromByteOffset: y * rowBytes + x * step + offset, as: UInt8.self)
        }
    }

    /// The same grid for a still picture, drawn down into a tiny grey bitmap.
    static func signature(_ image: CGImage) -> ScreenSignature? {
        let columns = ScreenSignature.columns
        let rows = ScreenSignature.rows
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        let bytes = data.bindMemory(to: UInt8.self, capacity: columns * rows)
        return ScreenSignature(columns: columns, rows: rows, samples: Array(UnsafeBufferPointer(start: bytes, count: columns * rows)))
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

    /// One coded picture, as the decoder takes it.
    private static func sample(bytes: Data, format: CMVideoFormatDescription, timestamp: UInt64) -> CMSampleBuffer? {
        guard !bytes.isEmpty else { return nil }
        do {
            let block = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
            try bytes.withUnsafeBytes { raw in try block.replaceDataBytes(with: raw) }
            let timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp & 0x7FFF_FFFF_FFFF_FFFF), timescale: 1_000_000),
                                            decodeTimeStamp: .invalid)
            return try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: 1,
                                      sampleTimings: [timing], sampleSizes: [bytes.count])
        } catch {
            return nil
        }
    }

    /// Shown the moment it is enqueued — no clock to wait for.
    private static func showImmediately(_ sample: CMSampleBuffer) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(array) > 0 else { return }
        let attachments = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

/// A decoded picture crossing from the decoder's thread to the main one. The buffer
/// is not touched on the way, only handed over.
private struct DecodedPicture: @unchecked Sendable {
    let image: CVImageBuffer?
}

// MARK: - The view that shows it and takes the mouse and the keyboard

/// What the screen reports back. Closures, so the view stays a plain AppKit view.
struct DeviceScreenEvents {
    /// Something to send to the device — a touch, swipe, wheel, key or typing, inspecting or not.
    var input: (DeviceInput) -> Void
    /// Inspecting: the pointer is over this normalised point, or left the picture.
    var hover: (_ point: CGPoint?) -> Void
    /// Inspecting: a click (without a drag) on this normalised point.
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
/// clipboard. In Inspect mode the live screen keeps playing: the pointer
/// highlights the element under it and a click marks it instead of tapping,
/// while a drag still swipes and the wheel and the keyboard still reach the device.
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
    /// What VoiceOver and accessibility tools call the live picture (it is the device's screen, not a bare image).
    var spokenName = ""

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { spokenName }

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
        let scale = window?.backingScaleFactor ?? 2
        player.backingScale = Double(scale)
        player.canvas = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
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
            // A click marks (on release, if it did not move); a drag is still a swipe.
            let point = convert(event.locationInWindow, from: nil)
            guard live, let at = DeviceGeometry.normalizedInside(point, in: fitted) else { return }
            press = Press(x: at.x, y: at.y, at: Date(), moved: false, last: CGPoint(x: at.x, y: at.y))
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
        if details?.rawTouch == true, !inspecting { events?.input(.touch(phase: "move", x: at.x, y: at.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let held = press else { return }
        press = nil
        let at = normalized(event) ?? held.last
        if inspecting {
            if held.moved {
                events?.input(DeviceGesture.release(fromX: held.x, fromY: held.y, toX: at.x, toY: at.y, moved: true,
                                                    heldMs: Date().timeIntervalSince(held.at) * 1000))
            } else {
                events?.pick(CGPoint(x: held.x, y: held.y))
            }
            return
        }
        if details?.rawTouch == true {
            events?.input(.touch(phase: "up", x: at.x, y: at.y))
            return
        }
        let heldMs = Date().timeIntervalSince(held.at) * 1000
        events?.input(DeviceGesture.release(fromX: held.x, fromY: held.y, toX: at.x, toY: at.y,
                                            moved: held.moved, heldMs: heldMs))
    }

    override func scrollWheel(with event: NSEvent) {
        guard live else { return }
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
        guard live, let details else { return super.keyDown(with: event) }
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
        guard window?.firstResponder === self, live else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, chars == "v" { paste(nil); return true }
        if flags == .command, chars == "a", details?.keys.contains("select-all") == true { selectAll(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard live, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        flushTyping()
        events?.input(.type(String(text.prefix(2_000))))
    }

    override func selectAll(_ sender: Any?) {
        guard live else { return }
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
        view.live = model.device != nil
        view.inspecting = model.inspecting
        let name = model.device?.name ?? "Device"
        view.spokenName = model.inspecting
            ? "\(name) screen, live, inspecting. Point at an element to see it, click to mark it, drag to swipe, type to type."
            : "\(name) screen, live. Click to tap, drag to swipe, type to type."
    }
}
