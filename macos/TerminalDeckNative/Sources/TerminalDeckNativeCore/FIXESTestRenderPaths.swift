import Foundation

/// All test images remain under a Spotlight-excluded directory, even when a
/// caller supplies a legacy indexed output path. Product captures do not use this.
public enum FIXESTestRenderPaths {
    public static func directory(_ requested: URL) throws -> URL {
        let resolved = requested.standardizedFileURL.resolvingSymlinksInPath()
        let safe = resolved.pathComponents.contains(where: { $0.hasSuffix(".noindex") })
            ? resolved : resolved.appendingPathComponent("test-renders.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        return safe
    }
    public static func image(_ requested: URL) throws -> URL {
        let safe = try directory(requested.deletingLastPathComponent())
        return safe.appendingPathComponent(requested.lastPathComponent)
    }
}
