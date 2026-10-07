import Foundation
import ImageIO
import TerminalDeckBackend

/// Reads container metadata only: no pixel decoding, resizing, recompression or
/// output-file creation. A partial header that lacks dimensions stays unknown.
enum NativeSafariCaptureAssetQuality {
    static func image(_ bytes: Data, complete: Bool, contentType: String) -> BackendBrowserAssetImage? {
        guard !bytes.isEmpty else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, bytes as CFData, complete)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0, height > 0, width <= 1_000_000_000, height <= 1_000_000_000 {
            let format = CGImageSourceGetType(source).map { $0 as String } ?? contentType
            return .init(width: width, height: height, format: format)
        }
        guard contentType.lowercased().contains("svg"), bytes.count <= 262_144,
              let text = String(data: bytes, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { return nil }
        let reader = SVGDimensions(), parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        _ = parser.parse()
        guard let width = reader.width, let height = reader.height else { return nil }
        return .init(width: width, height: height, format: "image/svg+xml")
    }
    private final class SVGDimensions: NSObject, XMLParserDelegate {
        var width: Int?
        var height: Int?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            guard elementName.lowercased().split(separator: ":").last == "svg" else { return }
            func dimension(_ text: String?) -> Double? {
                guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
                if text.hasSuffix("px") { text = String(text.dropLast(2)) }
                guard let value = Double(text), value.isFinite, value > 0, value <= 1_000_000_000 else { return nil }
                return value
            }
            var w = dimension(attributes["width"]), h = dimension(attributes["height"])
            let box = attributes["viewBox"]?.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) } ?? []
            if box.count == 4, box[2].isFinite, box[3].isFinite, box[2] > 0, box[3] > 0 {
                if w == nil, let height = h { w = height * box[2] / box[3] }
                if h == nil, let width = w { h = width * box[3] / box[2] }
            }
            if let w, let h, w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 1_000_000_000, h <= 1_000_000_000 {
                width = Int(w.rounded()); height = Int(h.rounded())
            }
            // A viewBox by itself declares coordinates, not intrinsic pixels.
            // Percentages/default layout are deliberately left unmeasured.
            parser.abortParsing()
        }
    }
}
