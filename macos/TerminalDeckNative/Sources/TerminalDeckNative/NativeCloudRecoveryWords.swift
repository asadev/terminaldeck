import AppKit
import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import CoreText
import TerminalDeckNativeCore

/// Sensitive text is drawn only into protected video image data. It is never a
/// SwiftUI Text, accessibility value, ordinary CALayer image or clipboard item.
@MainActor
final class NativeCloudRecoveryWordsView: NSView {
    private let protectedLayer = AVSampleBufferDisplayLayer()
    private var words: [String] = []
    private(set) var renderFailed = false
    var protectsCapture: Bool { protectedLayer.preventsCapture }
    init(words: [String]) {
        super.init(frame: CGRect(origin: .zero, size: .init(width: DeckTokens.Metrics.objectSize.width, height: DeckTokens.Metrics.rowMin * 6)))
        self.words = words
        wantsLayer = true
        protectedLayer.preventsCapture = true
        protectedLayer.videoGravity = .resizeAspect
        layer?.addSublayer(protectedLayer)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); protectedLayer.frame = bounds
        do { try render() } catch { renderFailed = true; clear() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
    func clear() {
        words.removeAll(keepingCapacity: false)
        protectedLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
    private func render() throws {
        guard words.count == 24, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw CloudFailure.unavailable }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw CloudFailure.unavailable }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(DeckTokens.cardNS.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize * scale, weight: .medium)
            for (index, word) in words.enumerated() {
                let column = index / 6, row = index % 6
                let label = NSAttributedString(string: "\(index + 1). \(word)", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                context.textPosition = CGPoint(x: CGFloat(column) * CGFloat(width) / 4 + DeckTokens.Spacing.s8 * scale,
                    y: CGFloat(height) - CGFloat(row + 1) * CGFloat(height) / 6 + DeckTokens.Spacing.s8 * scale)
                CTLineDraw(CTLineCreateWithAttributedString(label), context)
            }
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                          formatDescriptionOut: &format) == noErr, let format else { throw CloudFailure.unavailable }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw CloudFailure.unavailable }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        protectedLayer.sampleBufferRenderer.enqueue(sample)
    }
}

struct NativeCloudRecoveryProtectedWords: NSViewRepresentable {
    let words: [String]
    func makeNSView(context: Context) -> NativeCloudRecoveryWordsView { .init(words: words) }
    func updateNSView(_ view: NativeCloudRecoveryWordsView, context: Context) {}
    static func dismantleNSView(_ view: NativeCloudRecoveryWordsView, coordinator: ()) { view.clear() }
}
