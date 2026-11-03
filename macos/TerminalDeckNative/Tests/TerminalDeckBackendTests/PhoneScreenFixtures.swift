import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// What the screen tests share (3 Nov, m5-direct-only: the JPEG picture tests that held these are gone with the
/// pictures): a scripted Mac display giving raw pixels to the video encoder, a real-looking code page, and a fake direct
/// link that hands every `sims.video` message to the test (the screen goes only on the link now).
enum PhoneScreenFixtures {
    static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }

    actor Welcomed { var done = false; func set() { done = true } }

    /// A Mac display that draws what the script says; `pixels` gives the newest picture once it changed (as
    /// NativeMacScreenStream does).
    actor ScriptedScreen: BackendPhoneDeviceStream {
        var image: CGImage?
        var generation = 0
        var seen = 0
        var stopped = false
        init() {}
        func set(_ image: CGImage) { self.image = image; generation += 1 }
        func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
            let deadline = PhoneScreenFixtures.now() + seconds * 1_000
            while !stopped, !Task.isCancelled {
                if generation != seen, let image, let buffer = VideoPipelineTests.buffer(image) {
                    seen = generation
                    return .pixels(.init(buffer, capturedAt: PhoneScreenFixtures.now()))
                }
                if PhoneScreenFixtures.now() >= deadline { return .unchanged }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return .ended
        }
        func endReason() -> String { "gone" }
        func stop() { stopped = true }
    }

    /// The connection has moved onto a (fake) direct link: video goes to `carry`, parsed, in the order it was sent.
    static func link(_ source: inout BackendPhoneDevices.Source, carry: @escaping @Sendable (NativeRPCValue) async -> Void) {
        source.direct = { _, data, _ in
            if let value = try? NativeRPCValue.parseJSON(data) { await carry(value) }
            return true
        }
        source.linkVideo = { _ in BackendLinkVideo(reliableOnly: false) }
    }

    // MARK: Pictures like a real Mac screen

    static let width = 2560, height = 1600
    nonisolated(unsafe) static let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)

    static func makeContext(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }

    static func draw(_ text: String, at point: CGPoint, in context: CGContext, color: CGColor = CGColor(gray: 0.1, alpha: 1)) {
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                   NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }

    /// A long page of code in two columns with a side bar: what a terminal or an editor looks like.
    static let tall: CGImage = {
        let h = 6_400
        let context = makeContext(width, h)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: h))
        context.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 420, height: h))
        let words = ["let", "frame", "await", "stream.pixels(within:", "lane:", "return", "guard", "else", "budget", "picture", "// the phone", "ack", "seq", "self", "watch"]
        var seed: UInt32 = 7
        for row in 0..<(h / 34) {
            var line = String(repeating: " ", count: Int(seed % 8))
            for _ in 0..<(4 + Int(seed % 9)) { seed = seed &* 1664525 &+ 1013904223; line += words[Int(seed >> 24) % words.count] + " " }
            draw(line, at: CGPoint(x: 460, y: h - 40 - row * 34), in: context)
            draw("File\(row % 40).swift", at: CGPoint(x: 24, y: h - 40 - row * 34), in: context, color: CGColor(gray: 0.35, alpha: 1))
            if row % 3 == 0 { draw(String(line.reversed()), at: CGPoint(x: 1560, y: h - 40 - row * 34), in: context, color: CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1)) }
        }
        return context.makeImage()!
    }()

    /// The display scrolled `offset` pixels down the page, with `typed` characters at the prompt.
    static func screen(offset: Int, typed: String = "") -> CGImage {
        let context = makeContext(width, height)
        context.draw(tall, in: CGRect(x: 0, y: -(tall.height - offset - height), width: width, height: tall.height))
        if !typed.isEmpty {
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 460, y: 60, width: 1900, height: 40))
            draw("$ " + typed, at: CGPoint(x: 470, y: 70), in: context)
        }
        return context.makeImage()!
    }
}
