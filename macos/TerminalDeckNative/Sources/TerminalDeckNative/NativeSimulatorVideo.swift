import AppKit
import AVFoundation
import CoreMedia
import IOSurface
import Metal
import MetalPerformanceShaders
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
    /// The device's own screen buffer, shown as it is (finding 3, `DeviceDirectSource`): no video.
    let directLayer = CALayer()

    /// A picture of a new size arrived — first, or after a rotation.
    var onPictureSize: ((CGSize) -> Void)?
    /// The decoder needs a fresh keyframe; watching again asks the engine for one.
    var needKeyframe: (() -> Void)?
    /// Any picture was painted. Called per frame, so it must not touch observed state.
    var onPicture: (() -> Void)?
    /// The display's density, told by the view, for the readout.
    var backingScale = 1.0
    /// When a screen view holding the keyboard left its window: the view that replaces it takes it back.
    var keyboardWantedAt: CFTimeInterval?
    /// The picture's drawn size in screen pixels, told by the view. The picture on show is
    /// drawn again at a new size at once, so it is sharp right after a resize too.
    var canvas = CGSize.zero {
        didSet { if canvas != oldValue { redrawAtNewSize() } }
    }
    /// Inspect is on: the picture on show is fingerprinted (at most fifteen times a
    /// second, the last one always) for `onSignature`, so a change can be noticed
    /// without ever pausing the video.
    var signing = false {
        didSet { if !signing && !narrating { signPending = false } }
    }
    var onSignature: ((ScreenSignature) -> Void)?
    /// Recording with "Talk while recording": the same fingerprints, for the narration's
    /// screen changes (lane NARR). Independent of Inspect, so either can stop alone.
    var narrating = false {
        didSet { if !signing && !narrating { signPending = false } }
    }
    var onNarrationSignature: ((ScreenSignature) -> Void)?

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
    /// Scales a decoded picture down to the screen pixels it covers (lane STREAM).
    private let fitter = ScreenPixelFitter()
    /// Pictures handed to `show`, and the newest one that reached the display layer: a
    /// shrunk picture comes back from the GPU a moment later, and one older than what is
    /// already on screen (or from before a reset) is let go.
    private var showTicket = 0
    private var enqueuedTicket = 0
    /// The direct path: the device's surface, wrapped once for the GPU and for fingerprints.
    private var direct: CVPixelBuffer?
    /// The shrunk pictures on show (and the one before), kept until the screen has moved past them.
    private var directShown: [CVPixelBuffer] = []
    private var directTicket = 0
    private var directEnqueued = 0
    var isDirect: Bool { direct != nil }

    /// More coded pictures than this waiting to decode means this screen is behind.
    private static let maxBacklog = 12

    init() {
        displayLayer.videoGravity = .resizeAspect
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        let still: [String: any CAAction] = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        stillLayer.actions = still
        displayLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        directLayer.contentsGravity = .resizeAspect
        directLayer.isHidden = true
        directLayer.actions = still
    }

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    /// One packet from the engine, tagged with its kind.
    func push(_ data: Data) {
        // The device's own screen is on show: video still on its way from before is let go.
        guard direct == nil, let packet = ScreenPacket(data) else { return }
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
        endDirect()
        dropDecoder()
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        showTicket += 1
        enqueuedTicket = showTicket
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
        guard show(image) else { return }
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

    /// Hands a decoded picture to the display layer, first shrunk to exactly the screen
    /// pixels it covers. The device's picture is its full native size (1206×2622 on an
    /// iPhone 17 Pro — the engine ignores any size asked for), and a phone panel on a 1x
    /// display covers a quarter to a third of that each way. Left to the compositor, that
    /// shrink samples only a few source pixels per screen pixel: text breaks up and
    /// sparkles while it scrolls (measured: 20–26 dB against an ideal shrink, 39–45 dB
    /// with `ScreenPixelFitter`; round7/STREAM.md).
    @discardableResult
    private func show(_ image: CVImageBuffer) -> Bool {
        showTicket += 1
        let ticket = showTicket
        let started = fitter.fit(image, to: canvas) { [weak self] small in
            guard let self, ticket > self.enqueuedTicket else { return }
            if !self.enqueue(small ?? image, ticket: ticket), small != nil { self.enqueue(image, ticket: ticket) }
        }
        return started || enqueue(image, ticket: ticket)
    }

    @discardableResult
    private func enqueue(_ drawn: CVImageBuffer, ticket: Int) -> Bool {
        guard let description = try? CMVideoFormatDescription(imageBuffer: drawn),
              let sample = try? CMSampleBuffer(imageBuffer: drawn, formatDescription: description,
                                               sampleTiming: CMSampleTimingInfo(duration: .invalid,
                                                                                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                                                                decodeTimeStamp: .invalid))
        else { return false }
        Self.showImmediately(sample)
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
        renderer.enqueue(sample)
        enqueuedTicket = max(enqueuedTicket, ticket)
        return true
    }

    /// The panel changed size (or moved to a display of another density): the picture on
    /// show is drawn again for it, rather than waiting for the device's next frame.
    private func redrawAtNewSize() {
        if direct != nil {
            paintDirect()
        } else if !stillLayer.isHidden, let shownStill {
            stillLayer.contents = ScreenPixelFitter.fit(shownStill, to: canvas)
        } else if let shown {
            show(shown)
        }
    }

    private func recover() {
        waitingForKey = true
        makeDecoder()
        askForKeyframe()
    }

    private func still(_ bytes: Data) {
        guard let image = NSImage(data: bytes),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        stillLayer.contents = ScreenPixelFitter.fit(cgImage, to: canvas)
        stillLayer.isHidden = false
        shownStill = cgImage
        setPictureSize(CGSize(width: cgImage.width, height: cgImage.height))
        counts.painted += 1
        onPicture?()
        sign()
    }

    // MARK: The device's own screen (finding 3)

    /// The direct path handed over the device's screen surface (first, or a replacement).
    func showDirect(_ surface: IOSurfaceRef) {
        var wrapped: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &wrapped) == kCVReturnSuccess,
              let buffer = wrapped?.takeRetainedValue() else { return }
        direct = buffer
        directShown = []
        directTicket += 1
        directEnqueued = directTicket
        displayLayer.isHidden = true
        stillLayer.isHidden = true
        stillLayer.contents = nil
        directLayer.isHidden = false
        setPictureSize(CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface)))
        directFrame()
    }

    /// The device drew a new picture into the surface on show.
    func directFrame() {
        guard direct != nil else { return }
        paintDirect()
        counts.received += 1
        counts.decoded += 1
        counts.painted += 1
        if let inputAt {
            PlayerStats.remember(&counts.inputToPictureMs, (CACurrentMediaTime() - inputAt) * 1000)
            self.inputAt = nil
        }
        onPicture?()
        sign()
    }

    /// Back to the video stream: the direct path ended, or the device closed.
    func endDirect() {
        guard direct != nil else { return }
        // The last direct picture stays on show until the video's first picture replaces it.
        let last = currentPicture()
        direct = nil
        directShown = []
        directTicket += 1
        directEnqueued = directTicket
        directLayer.contents = nil
        directLayer.isHidden = true
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer.isHidden = false
        if let last {
            stillLayer.contents = ScreenPixelFitter.fit(last, to: canvas)
            stillLayer.isHidden = false
            shownStill = last
        }
        waitingForKey = true
    }

    /// The surface, shrunk on the GPU to exactly the screen pixels it covers (the same Lanczos as the
    /// video, so text stays sharp), or as it is when the panel is as big as the picture.
    private func paintDirect() {
        guard let direct else { return }
        directTicket += 1
        let ticket = directTicket
        let started = fitter.fit(direct, to: canvas) { [weak self] small in
            // Older than what is on show, or from a surface since replaced: let go.
            guard let self, self.direct != nil, ticket > self.directEnqueued else { return }
            self.directEnqueued = ticket
            guard let small, let surface = CVPixelBufferGetIOSurface(small)?.takeUnretainedValue() else {
                self.showDirectSurface()
                return
            }
            self.directShown.append(small)
            if self.directShown.count > 3 { self.directShown.removeFirst(self.directShown.count - 3) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.directLayer.contents = surface
            CATransaction.commit()
        }
        if !started {
            directEnqueued = ticket
            showDirectSurface()
        }
    }

    /// The surface itself as contents; the same surface again needs telling that its pixels changed.
    private func showDirectSurface() {
        guard let direct, let surface = CVPixelBufferGetIOSurface(direct)?.takeUnretainedValue() else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if directLayer.contents.map({ $0 as AnyObject === surface }) == true {
            let changed = Selector(("setContentsChanged"))
            if directLayer.responds(to: changed) { directLayer.perform(changed) } else { directLayer.contents = nil; directLayer.contents = surface }
        } else {
            directLayer.contents = surface
        }
        CATransaction.commit()
    }

    // MARK: The picture on show, for Inspect

    /// The picture on show now, as an image — the frame a marker keeps.
    func currentPicture() -> CGImage? {
        if let direct {
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(direct, options: nil, imageOut: &image) == noErr else { return nil }
            return image
        }
        if !stillLayer.isHidden, let shownStill { return shownStill }
        guard let shown else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(shown, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    private func sign() {
        let forInspect = signing && onSignature != nil, forNarration = narrating && onNarrationSignature != nil
        guard forInspect || forNarration else { return }
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
        if let direct {
            signature = Self.signature(direct)
        } else if !stillLayer.isHidden, let shownStill {
            signature = Self.signature(shownStill)
        } else if let shown {
            signature = Self.signature(shown)
        } else {
            signature = nil
        }
        if let signature {
            if forInspect { onSignature?(signature) }
            if forNarration { onNarrationSignature?(signature) }
        }
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

/// A shrunk picture coming back from the GPU, with the texture wrappers that must live
/// until the GPU is done. Not touched on the way, only handed over.
private struct FittedPicture: @unchecked Sendable {
    let image: CVPixelBuffer
    let wrappers: [CVMetalTexture]
    let done: @MainActor (CVPixelBuffer?) -> Void
}

/// Shrinks the device's picture to the exact screen pixels it is drawn on (lane STREAM,
/// Asad 9 Oct: "streaming too low quality… it should be fast and high quality").
///
/// A Lanczos filter on the GPU (Metal Performance Shaders), run straight on the decoded
/// picture's two planes — brightness, then colour — so nothing is converted or copied on
/// the CPU: the textures are the decoder's own memory (`CVMetalTextureCache`), and the
/// result lands in a small pool of video buffers of the screen's size. Measured on this
/// Mac: about 3% of one core more per panel at a full 60 fps scroll, nothing when the
/// screen is still (no frames come then). Rules learnt measuring it (round7/STREAM.md):
///  - one Lanczos pass holds up to about a 2.5x shrink; bigger ones go in steps;
///  - a kernel keeps its weights for the shrink it last did, so each step has its own;
///  - the size must be even both ways, or the colour plane no longer lines up;
///  - edges clamp, or the rim turns dark and green.
/// Only ever shrinks; when the panel is as big as the picture or bigger, or anything is
/// missing (no Metal, another pixel format), the caller shows the picture as before.
@MainActor
final class ScreenPixelFitter {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolKey: (Int, Int, OSType) = (0, 0, 0)
    private var middles: [String: any MTLTexture] = [:]
    private var kernels: [Int: MPSImageLanczosScale] = [:]
    private var uses = 0

    private static let planar: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    /// The direct path's pictures (a simulator's own screen buffer): one plane of 32-bit colour.
    private static let packed: OSType = kCVPixelFormatType_32BGRA

    /// The even pixel size to shrink to, or nil when the picture needs no shrinking.
    static func target(width: Int, height: Int, canvas: CGSize) -> (Int, Int)? {
        let w = Int(canvas.width.rounded()) & ~1, h = Int(canvas.height.rounded()) & ~1
        guard w >= 16, h >= 16, w < width - 1, h < height - 1 else { return nil }
        return (w, h)
    }

    /// Sizes to pass through on the way, so no single step shrinks more than 2.5x.
    static func steps(from: Int, to: (Int, Int)) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var size = to
        while Double(from) / Double(size.0) > 2.5 {
            size = (size.0 * 2, size.1 * 2)
            out.insert(size, at: 0)
        }
        return out
    }

    /// Starts shrinking `image`; `done` gets the small picture on the main thread (nil:
    /// show the original). False when there is nothing to do: show the original now.
    func fit(_ image: CVPixelBuffer, to canvas: CGSize, done: @escaping @MainActor (CVPixelBuffer?) -> Void) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(image)
        let packed = format == Self.packed && CVPixelBufferGetPlaneCount(image) == 0
        guard packed || (Self.planar.contains(format) && CVPixelBufferGetPlaneCount(image) == 2),
              let size = Self.target(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), canvas: canvas),
              let device = Self.device, let queue = Self.queue else { return false }
        let w = size.0, h = size.1
        if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        if pool == nil || poolKey != (w, h, format) {
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferPixelFormatTypeKey: format,
                                               kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &made) == kCVReturnSuccess
            else { return false }
            pool = made
            poolKey = (w, h, format)
            middles = [:]
        }
        var out: CVPixelBuffer?
        var wrappers: [CVMetalTexture] = []
        func texture(_ buffer: CVPixelBuffer, _ plane: Int, _ pixel: MTLPixelFormat) -> (any MTLTexture)? {
            guard let cache else { return nil }
            var made: CVMetalTexture?
            let usage = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
            let planes = CVPixelBufferIsPlanar(buffer)
            let width = planes ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
            let height = planes ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, usage, pixel, width, height, plane, &made) == kCVReturnSuccess,
                  let made else { return nil }
            wrappers.append(made)   // must outlive the GPU work that uses it
            return CVMetalTextureGetTexture(made)
        }
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              let commands = queue.makeCommandBuffer() else { return false }
        var passes: [(any MTLTexture, any MTLTexture, MTLPixelFormat)] = []
        if packed {
            guard let source = texture(image, 0, .bgra8Unorm), let target = texture(out, 0, .bgra8Unorm) else { return false }
            passes = [(source, target, .bgra8Unorm)]
            // The same colours as the device's own picture.
            if let from = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue(), let to = CVPixelBufferGetIOSurface(out)?.takeUnretainedValue(),
               let space = IOSurfaceCopyValue(from, kIOSurfaceColorSpace) {
                IOSurfaceSetValue(to, kIOSurfaceColorSpace, space)
            }
        } else {
            guard let sourceLuma = texture(image, 0, .r8Unorm), let sourceChroma = texture(image, 1, .rg8Unorm),
                  let targetLuma = texture(out, 0, .r8Unorm), let targetChroma = texture(out, 1, .rg8Unorm) else { return false }
            passes = [(sourceLuma, targetLuma, .r8Unorm), (sourceChroma, targetChroma, .rg8Unorm)]
        }
        for (index, (source, target, pixel)) in passes.enumerated() {
            let plane = packed ? 2 : index
            var from = source
            var step = 0
            for (mw, mh) in Self.steps(from: source.width, to: (target.width, target.height)) {
                guard let middle = intermediate(mw, mh, pixel, device) else { return false }
                kernel(plane, step, device).encode(commandBuffer: commands, sourceTexture: from, destinationTexture: middle)
                from = middle
                step += 1
            }
            kernel(plane, step, device).encode(commandBuffer: commands, sourceTexture: from, destinationTexture: target)
        }
        CVBufferPropagateAttachments(image, out)
        let handoff = FittedPicture(image: out, wrappers: wrappers, done: done)
        commands.addCompletedHandler { finished in
            let ok = finished.status == .completed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    withExtendedLifetime(handoff.wrappers) { handoff.done(ok ? handoff.image : nil) }
                }
            }
        }
        commands.commit()
        uses += 1
        if uses % 240 == 0, let cache { CVMetalTextureCacheFlush(cache, 0) }
        return true
    }

    private func intermediate(_ w: Int, _ h: Int, _ pixel: MTLPixelFormat, _ device: any MTLDevice) -> (any MTLTexture)? {
        let key = "\(w)x\(h)/\(pixel.rawValue)"
        if let made = middles[key] { return made }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixel, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let made = device.makeTexture(descriptor: descriptor)
        middles[key] = made
        return made
    }

    private func kernel(_ plane: Int, _ step: Int, _ device: any MTLDevice) -> MPSImageLanczosScale {
        if let made = kernels[plane * 16 + step] { return made }
        let made = MPSImageLanczosScale(device: device)
        made.edgeMode = .clamp   // the default reads zeros past the edge: a dark, green rim
        kernels[plane * 16 + step] = made
        return made
    }

    /// A still, drawn once at the screen's pixels with the high-quality filter.
    static func fit(_ image: CGImage, to canvas: CGSize) -> CGImage {
        guard let size = target(width: image.width, height: image.height, canvas: canvas),
              let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
        return context.makeImage() ?? image
    }
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
    /// Two fingers, from a drag with ⌥ held (the second mirrored through the middle, as in Simulator):
    /// false when the device cannot take them, and the drag is one finger instead.
    var pinch: ((_ phase: String, _ first: CGPoint, _ second: CGPoint) -> Bool)? = nil
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
    /// The screen's rounded corners when a phone frame is drawn around it (0: square).
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }
    /// Input goes to the device.
    var live = true
    /// The direct path takes fingers (finding 3): press, move and lift go as they happen.
    var directTouch = false
    /// The direct path takes keys: each one goes at once, never gathered for 60 ms first.
    var immediateKeys = false
    private var rawTouch: Bool { directTouch || details?.rawTouch == true }
    private var pinching = false
    /// The last event this screen acted on itself, and the keys whose press it took (their release is its
    /// too): such an event is never the person moving the keyboard elsewhere (`DeviceKeyboardHold`).
    private var phoneTook: (type: NSEvent.EventType, stamp: TimeInterval)?
    private var keysTaken: Set<UInt16> = []
    private func took(_ event: NSEvent) { phoneTook = (event.type, event.timestamp) }
    private func tookKey(_ event: NSEvent) { took(event); keysTaken.insert(event.keyCode) }
    func tookItself(_ event: NSEvent) -> Bool {
        guard let phoneTook else { return false }
        return phoneTook.type == event.type && phoneTook.stamp == event.timestamp
    }
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
    /// Snip: the mouse draws a box on the screen instead (a drag), handed over on release
    /// as a normalised rectangle. Nothing reaches the device meanwhile.
    var snipping = false {
        didSet {
            if snipping != oldValue {
                window?.invalidateCursorRects(for: self)
                press = nil; snipStart = nil; band.path = nil
            }
        }
    }
    var onSnip: ((CGRect) -> Void)?
    private var snipStart: CGPoint?
    private lazy var band: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer.fillRule = .evenOdd
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = 1.5
        layer.zPosition = 10
        return layer
    }()
    /// What VoiceOver and accessibility tools call the live picture (it is the device's screen, not a bare image).
    /// Readable from any thread (1 Nov hotfix 2): AppKit's Accessibility walk may reach this view from whatever thread
    /// asks, so the answers below never touch main-actor state and never trap.
    var spokenName: String {
        get { spokenNameBox.withLock { $0 } }
        set { spokenNameBox.withLock { $0 = newValue } }
    }
    private let spokenNameBox = NativeLockedValue("")

    /// Snip without a pointer (VoiceOver, keyboard, Accessibility clients): a box by name.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard snipping else { return super.accessibilityCustomActions() }
        let boxes: [(String, CGRect)] = [("Snip the top half", CGRect(x: 0, y: 0, width: 1, height: 0.5)),
                                         ("Snip the middle", CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)),
                                         ("Snip the bottom half", CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
                                         ("Snip the whole screen", CGRect(x: 0, y: 0, width: 1, height: 1))]
        return boxes.map { name, box in
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, self.snipping else { return false }
                self.onSnip?(box); return true
            }
        }
    }

    nonisolated override func isAccessibilityElement() -> Bool { true }
    nonisolated override func accessibilityRole() -> NSAccessibility.Role? { .image }
    nonisolated override func accessibilityLabel() -> String? { spokenNameBox.withLock { $0 } }

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
        // Only a view in a window holds the picture: a view leaving (the panel, as its phone pops out to a
        // window) must not pull the layers back from the view that now shows it (black window, 10 Oct).
        guard let player, let layer, window != nil else { return }
        for sub in [player.displayLayer, player.stillLayer, player.directLayer] where sub.superlayer !== layer {
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
        // On whole screen pixels, and an even number of them each way (the shrunk video
        // picture is even), so the picture lands 1:1 instead of being blended across pixel
        // edges. Input keeps using `fitted`; the two differ by about a pixel at most.
        let scale = window?.backingScaleFactor ?? 2
        var rect = backingAlignedRect(fitted, options: .alignAllEdgesNearest)
        rect.size = CGSize(width: CGFloat(Int((rect.width * scale).rounded()) & ~1) / scale,
                           height: CGFloat(Int((rect.height * scale).rounded()) & ~1) / scale)
        player.displayLayer.frame = rect
        player.stillLayer.frame = rect
        player.directLayer.frame = rect
        for sub in [player.displayLayer, player.stillLayer, player.directLayer] {
            sub.cornerRadius = cornerRadius
            sub.cornerCurve = .continuous
            sub.masksToBounds = cornerRadius > 0
        }
        CATransaction.commit()
        player.backingScale = Double(scale)
        player.canvas = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    /// Dragged to a display of another density: the picture is drawn again for its pixels.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        attachPlayer()
        if window != nil { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.takeKeyboardBackIfWanted() } } }
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
        if inspecting || snipping { addCursorRect(fitted, cursor: .crosshair) }
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

    /// The box between two points, kept on the picture.
    private func snipBox(from a: CGPoint, to b: CGPoint) -> CGRect {
        let clamp = { (p: CGPoint) in CGPoint(x: min(max(p.x, self.fitted.minX), self.fitted.maxX),
                                             y: min(max(p.y, self.fitted.minY), self.fitted.maxY)) }
        let p = clamp(a), q = clamp(b)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        return DeviceGeometry.normalized(point, in: fitted).map { CGPoint(x: $0.x, y: $0.y) }
    }

    override func mouseDown(with event: NSEvent) {
        took(event)
        window?.makeFirstResponder(self)
        if snipping {
            let point = convert(event.locationInWindow, from: nil)
            guard fitted.contains(point) else { return }
            snipStart = point
            if band.superlayer !== layer { layer?.addSublayer(band) }
            return
        }
        if inspecting {
            // A click marks (on release, if it did not move); a drag is still a swipe.
            let point = convert(event.locationInWindow, from: nil)
            guard live, let at = DeviceGeometry.normalizedInside(point, in: fitted) else { return }
            press = Press(x: at.x, y: at.y, at: Date(), moved: false, last: CGPoint(x: at.x, y: at.y))
            return
        }
        guard live, let at = normalized(event) else { return }
        press = Press(x: at.x, y: at.y, at: Date(), moved: false, last: at)
        if directTouch, event.modifierFlags.contains(.option), let pinch = events?.pinch,
           pinch("down", at, Self.mirror(at)) {
            pinching = true
            return
        }
        pinching = false
        if rawTouch { events?.input(.touch(phase: "down", x: at.x, y: at.y)) }
    }

    private static func mirror(_ point: CGPoint) -> CGPoint {
        let other = DeviceDirectGesture.mirrored(x: point.x, y: point.y)
        return CGPoint(x: other.x, y: other.y)
    }

    override func mouseDragged(with event: NSEvent) {
        took(event)
        if snipping, let start = snipStart {
            let box = snipBox(from: start, to: convert(event.locationInWindow, from: nil))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            band.frame = bounds
            let path = CGMutablePath(); path.addRect(fitted); path.addRect(box)
            band.path = path
            CATransaction.commit()
            return
        }
        guard var held = press, let at = normalized(event) else { return }
        held.last = at
        if hypot(at.x - held.x, at.y - held.y) > DeviceGesture.tapTravel { held.moved = true }
        press = held
        if pinching {
            _ = events?.pinch?("move", at, Self.mirror(at))
            return
        }
        // Moves that pile up while one is on its way are folded into the newest (`DeviceInputQueue`).
        if rawTouch, !inspecting { events?.input(.touch(phase: "move", x: at.x, y: at.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        took(event)
        if snipping {
            defer { snipStart = nil; band.path = nil }
            guard let start = snipStart, fitted.width > 0, fitted.height > 0 else { return }
            guard let box = ShotCropMath.snip(from: start, to: convert(event.locationInWindow, from: nil), picture: fitted) else { return }
            onSnip?(box)
            return
        }
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
        if pinching {
            pinching = false
            _ = events?.pinch?("up", at, Self.mirror(at))
            return
        }
        if rawTouch {
            events?.input(.touch(phase: "up", x: at.x, y: at.y))
            return
        }
        let heldMs = Date().timeIntervalSince(held.at) * 1000
        events?.input(DeviceGesture.release(fromX: held.x, fromY: held.y, toX: at.x, toY: at.y,
                                            moved: held.moved, heldMs: heldMs))
    }

    override func scrollWheel(with event: NSEvent) {
        guard live else { return }
        took(event)
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
        guard takeKey(event) else { return super.keyDown(with: event) }
        tookKey(event)
    }

    override func keyUp(with event: NSEvent) {
        if keysTaken.remove(event.keyCode) != nil { took(event) }
        super.keyUp(with: event)
    }

    /// The phone takes the key: false passes it on (shortcuts, ⌥ keys, keys the device has no use for).
    private func takeKey(_ event: NSEvent) -> Bool {
        guard live, let details else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) || flags.contains(.control) {
            if chars == "v" { paste(nil); return true }
            if chars == "a", details.keys.contains("select-all") { selectAll(nil); return true }
            return false
        }
        if flags.contains(.option) { return false }
        if let named = Self.namedKeys[event.keyCode] {
            flushTyping()
            if immediateKeys || details.keys.contains(named) {
                events?.input(.key(named))
            } else if named == "return" {
                events?.input(.type("\n"))
            }
            return true
        }
        guard let text = event.characters, !text.isEmpty, immediateKeys || details.text != "none",
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        if immediateKeys, DeviceDirectKeys.strokes(text) != nil {
            // Straight to the device, key by key (finding 3: typing that waited felt broken). Keys the direct
            // path cannot type (é, Urdu, emoji) go the engine's way, which pastes them: those are gathered for
            // 60 ms as before, so a quickly typed word lands as one piece, not letter by letter.
            flushTyping()
            events?.input(.type(text))
            return true
        }
        typed += text
        typeTimer?.invalidate()
        typeTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushTyping() }
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V and ⌘A belong to the device while its screen has focus.
        guard window?.firstResponder === self, live else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, chars == "v" { tookKey(event); paste(nil); return true }
        // ⌘C: what was copied inside the phone comes to the Mac's clipboard.
        if flags == .command, chars == "c" { tookKey(event); NativeSimPasteboard.fromPhone(details?.id); return true }
        if flags == .command, chars == "a", details?.keys.contains("select-all") == true { tookKey(event); selectAll(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard live, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        // The phone's own pasteboard gets it too, so its Paste menu has it.
        NativeSimPasteboard.toPhone(details?.id, force: true)
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
        // Finding 3 ("i cant type inside"): while the phone has the keyboard, only the person moves it
        // elsewhere — a click on something else, a key (Tab, a shortcut), the screen going away. A box
        // that grabs the keyboard by itself (a chat update, a terminal re-showing) is refused.
        if DeviceKeyboardHold.refuses(self, event: NSApp.currentEvent) { return false }
        flushTyping()
        NativeSimPasteboard.fromPhone(details?.id)
        let resigned = super.resignFirstResponder()
        // 28 Oct (bug B): the session terminals say whether their keys go to this phone.
        if resigned { DispatchQueue.main.async { MainActor.assumeIsolated { NativeTerminalKeyboard.holderMoved() } } }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        NativeSimPasteboard.toPhone(details?.id)
        DeviceKeyboardHold.watch()
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { MainActor.assumeIsolated { NativeTerminalKeyboard.holderMoved() } } }
        return became
    }

    /// Leaving the window (the panel re-made, or popped out) while holding the keyboard: the screen that
    /// replaces it takes the keyboard back.
    private(set) var leavingWindow = false
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let window, window.firstResponder === self { player?.keyboardWantedAt = CACurrentMediaTime() }
        leavingWindow = newWindow !== window
        super.viewWillMove(toWindow: newWindow)
    }

    private func takeKeyboardBackIfWanted() {
        leavingWindow = false
        guard let window, let player, let wanted = player.keyboardWantedAt, CACurrentMediaTime() - wanted < 1.5 else { return }
        player.keyboardWantedAt = nil
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }
}

/// Who may take the keyboard from a phone screen that has it (finding 3, "i cant type inside"): the
/// person, never a box grabbing it by itself. `NSApp.currentEvent` is only the last event the app took,
/// so it counts as the person's only while fresh (taken at most 150 ms ago) and only when the phone did
/// not act on it itself (`DeviceKeyboardClaim`): a grab right after typing into the phone, or seconds after
/// a click, is refused; a click elsewhere, a key or a shortcut such as ⌘F that focuses a field a moment
/// later moves it as always. A modifier key alone never moves it. A screen that is hidden, leaving its
/// window or in a window that is not the key one never holds on.
@MainActor enum DeviceKeyboardHold {
    /// The last event the app took off its queue, and when: a click that waited behind a busy moment is
    /// still fresh when it is finally handled (its own timestamp is when it happened, not when it was taken).
    private static var lastTaken: (type: NSEvent.EventType, stamp: TimeInterval, at: TimeInterval)?
    private static var monitor: Any?

    /// Starts noting when events are taken (once, the first time a phone screen takes the keyboard).
    static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
            let entry = (type: event.type, stamp: event.timestamp, at: ProcessInfo.processInfo.systemUptime)
            MainActor.assumeIsolated { lastTaken = entry }
            return event
        }
    }

    static func age(of event: NSEvent, now: TimeInterval) -> TimeInterval {
        if let lastTaken, lastTaken.type == event.type, lastTaken.stamp == event.timestamp { return now - lastTaken.at }
        return now - event.timestamp
    }

    static func refuses(_ view: DeviceScreenNSView, event: NSEvent?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard view.live, !view.leavingWindow, let window = view.window, window.isKeyWindow, window.firstResponder === view,
              view.superview != nil, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
        // 28 Oct (bug B, Sessions): he just chose a session (session list, tab strip, ⌘-number): its terminal takes
        // the keyboard, or what he types next goes into the phone and on into the session the phone has open.
        if NativeTerminalKeyboard.choiceMoves(now: now) { return false }
        guard let event, DeviceKeyboardClaim.isPersons(age: age(of: event, now: now), phoneTookIt: view.tookItself(event)) else { return true }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click on the phone itself keeps the keyboard there; a click anywhere else moves it.
            guard event.window === window, let content = window.contentView else { return false }
            let point = content.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
            guard let hit = content.hitTest(point) else { return false }
            return hit === view || hit.isDescendant(of: view)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .keyDown, .keyUp, .gesture, .magnify, .swipe, .rotate, .beginGesture, .endGesture, .pressure:
            return false
        default:
            return true
        }
    }
}

/// The screen in SwiftUI. The model owns the player; this only hosts its layers.
struct DeviceScreenSurface: NSViewRepresentable {
    let model: NativeSimulatorModel
    var cornerRadius: CGFloat = 0
    var snipping = false
    var onSnip: ((CGRect) -> Void)? = nil

    func makeNSView(context: Context) -> DeviceScreenNSView {
        let view = DeviceScreenNSView(frame: .zero)
        view.player = model.player
        view.events = DeviceScreenEvents(
            input: { [weak model] input in model?.sendInput(input) },
            hover: { [weak model] point in model?.hover(at: point) },
            pick: { [weak model] point in model?.pick(at: point) },
            visibility: { [weak model, weak view] visible in
                guard let view else { return }
                model?.setVisible(visible, from: ObjectIdentifier(view))
            },
            pinch: { [weak model] phase, first, second in model?.pinch(phase: phase, first: first, second: second) ?? false })
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DeviceScreenNSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DeviceScreenNSView) {
        view.fitSize = model.fitSize
        view.cornerRadius = cornerRadius
        view.snipping = snipping
        view.onSnip = onSnip
        view.details = model.device
        view.live = model.device != nil
        view.directTouch = model.directTouch
        view.immediateKeys = model.directKeys
        view.inspecting = model.inspecting
        let name = model.device?.name ?? "Device"
        view.spokenName = model.inspecting
            ? "\(name) screen, live, inspecting. Point at an element to see it, click to mark it, drag to swipe, type to type."
            : "\(name) screen, live. Click to tap, drag to swipe, type to type."
    }
}


/// A value behind a lock, readable from any thread (an NSView's Accessibility answers).
final class NativeLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
