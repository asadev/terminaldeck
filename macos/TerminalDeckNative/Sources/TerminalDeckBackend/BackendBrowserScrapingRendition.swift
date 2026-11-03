import Foundation
import TerminalDeckNativeCore

public struct BackendBrowserAssetImage: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let format: String
    public init(width: Int, height: Int, format: String) { self.width = width; self.height = height; self.format = format }
}

public struct BackendBrowserRenditionProbe: Sendable {
    public let status: Int
    public let bytes: Int?
    public let contentType: String
    public let image: BackendBrowserAssetImage?
    public let method: String
    public let finalURL: URL
    public init(status: Int, bytes: Int?, contentType: String, image: BackendBrowserAssetImage? = nil, method: String, finalURL: URL) {
        self.status = status; self.bytes = bytes; self.contentType = contentType; self.image = image; self.method = method; self.finalURL = finalURL
    }
    public var wire: NativeRPCValue {
        .object([.init("status", .number(Double(status))), .init("bytes", bytes.map { .number(Double($0)) } ?? .null),
            .init("contentType", .string(contentType)), .init("method", .string(method)), .init("finalUrl", .string(finalURL.absoluteString)),
            .init("image", image.map { .object([.init("width", .number(Double($0.width))), .init("height", .number(Double($0.height))), .init("format", .string($0.format))]) } ?? .null)])
    }
}

public enum BackendBrowserScrapingRendition {
    public struct Verdict: Sendable {
        public let ok: Bool
        public let reason: String
        public let comparedBytes: Bool
        public let comparedDimensions: Bool
        public let byteRatio: Double?
        public var wire: NativeRPCValue { .object([.init("ok", .bool(ok)), .init("reason", .string(reason)),
            .init("comparedBytes", .bool(comparedBytes)), .init("comparedDimensions", .bool(comparedDimensions)),
            .init("byteRatio", byteRatio.map(NativeRPCValue.number) ?? .null)]) }
    }
    public static func accepts(url: URL, probe: BackendBrowserRenditionProbe?, original: BackendBrowserRenditionProbe?,
                               arguments: NativeRPCValue, isOriginal: Bool) -> Verdict {
        func no(_ reason: String, bytes: Bool = false, dimensions: Bool = false, ratio: Double? = nil) -> Verdict {
            .init(ok: false, reason: reason, comparedBytes: bytes, comparedDimensions: dimensions, byteRatio: ratio)
        }
        guard let probe else { return no("The request failed.") }
        guard (200..<300).contains(probe.status) else { return no("HTTP \(probe.status).") }
        let binaryExtensions = Set(["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "tif", "tiff", "svg", "pdf", "mp4", "webm", "mov", "zip", "dwg", "dxf"])
        if binaryExtensions.contains(url.pathExtension.lowercased()), probe.contentType.hasPrefix("text/") {
            return no("The server answered with \(probe.contentType), a text document rather than the requested asset.")
        }
        if probe.bytes == 0 { return no("The server answered with nothing.") }
        let minimum = max(0, arguments["minBytes"].number ?? 0).rounded(.towardZero)
        if let bytes = probe.bytes, Double(bytes) < minimum { return no("\(bytes) bytes is below this run's \(Int(minimum)) byte minimum.") }
        for (key, measured) in [("minWidth", probe.image?.width), ("minHeight", probe.image?.height)] {
            if let minimum = arguments[key].number, minimum > 0 {
                guard let measured else { return no("The image dimension required by \(key) could not be measured.") }
                if Double(measured) < minimum { return no("\(key) requires \(Int(minimum)); the image measured \(measured).") }
            }
        }
        var comparedBytes = false, comparedDimensions = false, ratio: Double?
        if !isOriginal {
            if let bytes = probe.bytes, let originalBytes = original?.bytes, originalBytes > 0 {
                ratio = Double(bytes) / Double(originalBytes)
                if arguments["requireLarger"].bool != false {
                    comparedBytes = true
                    if bytes <= originalBytes { return no("\(bytes) bytes against the original's \(originalBytes) is not a bigger copy.", bytes: true, ratio: ratio) }
                }
            }
            // Source-compatible requireLarger does not invent a comparison when
            // either length is unknown. An explicit ratio is a stronger request.
            if let minimumRatio = arguments["minByteRatio"].number, minimumRatio > 0 {
                guard let ratio else { return no("The requested byte ratio could not be measured against the original.") }
                comparedBytes = true
                if ratio < minimumRatio { return no("Measured byte ratio \(ratio) is below \(minimumRatio).", bytes: true, ratio: ratio) }
            }
            if arguments["requireLargerDimensions"].bool == true {
                guard let image = probe.image, let base = original?.image else { return no("The requested image dimension comparison could not be measured.") }
                comparedDimensions = true
                if image.width < base.width || image.height < base.height || image.width == base.width && image.height == base.height {
                    return no("\(image.width)×\(image.height) does not improve on the original's \(base.width)×\(base.height).", bytes: comparedBytes, dimensions: true, ratio: ratio)
                }
            }
        }
        return .init(ok: true, reason: "", comparedBytes: comparedBytes, comparedDimensions: comparedDimensions, byteRatio: ratio)
    }

    /// The system engine supplies exact source replacement expansion, including
    /// $11920 when only group 1 exists, named groups, literal dollars and u/y.
    public static func replacing(_ source: String, pattern: String, replacement: String, flags: String) throws -> String {
        try BackendBrowserScrapingRegex.replace(source, pattern: pattern, replacement: replacement, flags: flags)
    }
}
