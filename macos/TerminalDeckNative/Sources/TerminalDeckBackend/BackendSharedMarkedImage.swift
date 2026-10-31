import Foundation
import TerminalDeckNativeCore

/// main/marked-image.ts's PNG data-url boundary. Header validation only, as
/// in the source: CRC/decompression are deliberately the image decoder's job.
public enum BackendSharedMarkedImage {
    public static let maxBytes = 64 * 1024 * 1024
    public static let dataUrlPrefix = "data:image/png;base64,"
    public struct Size: Equatable, Sendable { public let width: UInt32; public let height: UInt32 }
    public struct Image: Equatable, Sendable { public let bytes: Data; public let width: UInt32; public let height: UInt32 }
    public static func readPngSize(_ bytes: Data) -> Size? {
        guard bytes.count >= 24 else { return nil }
        let header = Array(bytes.prefix(24))
        guard Array(header.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], Array(header[12..<16]) == Array("IHDR".utf8) else { return nil }
        func word(_ index: Int) -> UInt32 { header[index..<index + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
        let width = word(16), height = word(20)
        return width > 0 && height > 0 ? .init(width: width, height: height) : nil
    }
    public static func decodePngDataUrl(_ value: NativeRPCValue) -> Image? {
        guard let text = value.string, text.hasPrefix(dataUrlPrefix) else { return nil }
        let encoded = String(text.dropFirst(dataUrlPrefix.count))
        guard !encoded.isEmpty, encoded.utf16.count <= ((maxBytes + 2) / 3) * 4,
              BackendSharedText.matches(encoded, #"^[A-Za-z0-9+/]+={0,2}$"#) else { return nil }
        let bytes = BackendSharedServerAddresses.fromBase64Url(encoded)
        guard !bytes.isEmpty, bytes.count <= maxBytes, let size = readPngSize(bytes) else { return nil }
        return .init(bytes: bytes, width: size.width, height: size.height)
    }
    public static func markedName(_ plain: String) -> String { (plain.hasSuffix(".png") ? String(plain.dropLast(4)) : plain) + "-marked.png" }
}
