import AppKit
import TerminalDeckNativeCore

/// A browser screenshot with every password, one-time-code and file field
/// painted out (NativeSafariRuntime's capture).
enum NativeBrowserShotMask {
    static func maskedPNG(_ image: CGImage, rects: [CGRect], scale: Double) throws -> Data {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BrowserDriverRefusal("the picture could not be made")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for rect in rects {
            // CSS rects run top-down; the bitmap runs bottom-up.
            context.fill(CGRect(x: rect.minX * scale, y: Double(height) - rect.maxY * scale,
                                width: rect.width * scale, height: rect.height * scale).insetBy(dx: -2, dy: -2))
        }
        guard let masked = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: masked).representation(using: .png, properties: [:]) else {
            throw BrowserDriverRefusal("the picture could not be made")
        }
        return png
    }
}
