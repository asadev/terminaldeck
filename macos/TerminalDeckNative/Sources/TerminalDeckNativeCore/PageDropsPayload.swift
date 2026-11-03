import Foundation

/// Files dropped on an engine page: their real paths, handed to the page as
/// `window.tdNative.run('drop-paths', {paths, x, y})` (x/y in the page's CSS pixels).
public enum DropPayload {
    public static let command = "drop-paths"
    public static let maxPaths = 500

    /// Absolute paths of the file URLs, in order, each once. Anything that is not a
    /// file URL (a web link, a promise of a file) is left out.
    public static func paths(from urls: [URL]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix("/"), !path.contains("\0"), seen.insert(path).inserted else { continue }
            out.append(path)
            if out.count == maxPaths { break }
        }
        return out
    }

    /// A point in the web view's own points (top-left origin) as CSS pixels at this zoom.
    public static func cssPoint(x: Double, y: Double, zoom: Double) -> (x: Double, y: Double) {
        let scale = zoom.isFinite && zoom > 0 ? zoom : 1
        return ((x / scale).rounded(), (y / scale).rounded())
    }

    /// nil when there is nothing to hand over.
    public static func script(paths: [String], x: Double, y: Double) -> String? {
        guard !paths.isEmpty else { return nil }
        return PageScript.run(command, .object([
            ("paths", .array(paths.map(PageValue.string))),
            ("x", .number(x.isFinite ? x : 0)),
            ("y", .number(y.isFinite ? y : 0)),
        ]))
    }
}
