import AppKit
import Foundation
import Darwin
import TerminalDeckNativeCore

/// A project's logo (Asad 10 Oct: "for projects let us choose logo instead of color of dot"). The chosen image is
/// drawn into a 256 pt square PNG inside the app's data (`<data>/project-logos`), so moving or deleting the original
/// breaks nothing. The ONE implementation: Project settings › Logo, the projects_logo window tool and
/// project_registry_save's `logo` all adopt and discard through here.
public enum BackendPROJLogos {
    public static let folderName = "project-logos"
    /// The source image is read only when it is a regular file of at most this size (decoding a huge file would stall).
    public static let maximumSourceBytes = 50 * 1024 * 1024

    /// A stored logo name: a plain file name inside the logos folder.
    public static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    /// The image path a tool gave: absolute (or "~/…"), an existing regular file within the size above.
    public static func source(_ raw: String) throws -> URL {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw NativeRPCError.invalidArguments("Give the logo as a full path to an image file on this Mac, or \"\" to remove it.")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw NativeRPCError(code: "logo-unreadable", message: "There is no image file at \(url.path).")
        }
        guard info.st_size <= maximumSourceBytes else {
            throw NativeRPCError(code: "logo-unreadable", message: "That image is larger than 50 MB. Choose a smaller one.")
        }
        return url
    }

    /// Draws the chosen image into a 256 pt square PNG in `directory`; returns its file name.
    public static func adopt(_ source: URL, projectID: String, directory: URL) throws -> String {
        var info = stat()
        if stat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > maximumSourceBytes {
            throw NativeRPCError(code: "logo-unreadable", message: "That image is larger than 50 MB. Choose a smaller one.")
        }
        guard let image = NSImage(contentsOf: source), image.isValid, image.size.width > 0, image.size.height > 0 else {
            throw NativeRPCError(code: "logo-unreadable", message: "That file isn't an image Terminal Deck can read.")
        }
        let side = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NativeRPCError(code: "logo-unreadable", message: "Couldn't prepare the logo.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let scale = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        image.draw(in: NSRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NativeRPCError(code: "logo-unreadable", message: "Couldn't save the logo.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeID = projectID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = (safeID.isEmpty ? "project" : safeID) + "-" + UUID().uuidString.prefix(8).lowercased() + ".png"
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// Removes a logo the app made (a name from `adopt`); anything else is left alone.
    public static func discard(_ name: String, directory: URL) {
        guard isSafe(name) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
