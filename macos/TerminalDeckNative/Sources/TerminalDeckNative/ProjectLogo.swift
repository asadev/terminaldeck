import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

// Asad 10 Oct: "for projects let us choose logo instead of color of dot". A project shows its
// logo (or a neutral tile with its first letter) wherever the colour dot used to show it.
// The picked image is copied into the app's own data, so moving the original breaks nothing.

@MainActor
enum ProjectLogos {
    static var directory: URL {
        AppModel.shared.engine.configuration.dataRoot.appendingPathComponent(BackendPROJLogos.folderName, isDirectory: true)
    }
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ project: PROJProject?) -> NSImage? {
        guard let name = project?.logo, isSafe(name) else { return nil }
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)), image.isValid else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    private static func isSafe(_ name: String) -> Bool { BackendPROJLogos.isSafe(name) }

    /// Draws the chosen image into a 256 pt square PNG in the app's data; returns its file name.
    /// One implementation for the screen and the tools: `BackendPROJLogos`.
    static func adopt(_ source: URL, projectID: String) throws -> String {
        try BackendPROJLogos.adopt(source, projectID: projectID, directory: directory)
    }

    static func discard(_ name: String) {
        guard isSafe(name) else { return }
        cache.removeObject(forKey: name as NSString)
        BackendPROJLogos.discard(name, directory: directory)
    }

    /// A 16 pt menu image: the logo, or the letter tile.
    static func menuImage(_ project: PROJProject?, name: String) -> NSImage {
        let side: CGFloat = 16
        let logo = image(project)
        let letter = ProjectLogoView.letter(project?.name ?? name)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            if let logo {
                path.addClip()
                logo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                NSColor.secondaryLabelColor.withAlphaComponent(0.2).setFill(); path.fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                 .foregroundColor: NSColor.secondaryLabelColor]
                let text = NSAttributedString(string: letter, attributes: attributes)
                let size = text.size()
                text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            }
            return true
        }
    }

    // MARK: Suggestions from the project's folder (only what is actually there)

    nonisolated static func suggestions(folder: String) -> [URL] {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let files = FileManager.default
        var found: [URL] = []
        func add(_ url: URL) {
            guard found.count < 8, !found.contains(url), files.fileExists(atPath: url.path) else { return }
            found.append(url)
        }
        let images = ["png", "svg", "jpg", "jpeg", "icns"]
        for base in ["logo", "icon", "Logo", "Icon"] { for ext in images { add(root.appendingPathComponent("\(base).\(ext)")) } }
        for dir in ["public", "static", "assets", "public/images", "src/assets"] {
            let folder = root.appendingPathComponent(dir, isDirectory: true)
            for name in ["apple-touch-icon.png", "favicon.svg", "favicon.png", "favicon.ico", "logo.svg", "logo.png", "icon.png", "icon.svg"] {
                add(folder.appendingPathComponent(name))
            }
        }
        // App icons: an AppIcon set in an asset catalog (largest PNG), and .icns files, a few levels down.
        let skip: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData", "Pods", ".next", "dist", "vendor", ".gradle"]
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return found }
        var visited = 0
        while let url = walker.nextObject() as? URL, found.count < 8, visited < 20_000 {
            visited += 1
            let depth = url.pathComponents.count - root.pathComponents.count
            let name = url.lastPathComponent
            if skip.contains(name) || depth > 5 { walker.skipDescendants(); continue }
            if name == "AppIcon.appiconset" || name.hasSuffix(".appiconset") && name.lowercased().contains("appicon") {
                walker.skipDescendants()
                let pngs = (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]))?
                    .filter { $0.pathExtension.lowercased() == "png" } ?? []
                if let largest = pngs.max(by: {
                    ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }) { add(largest) }
            } else if url.pathExtension.lowercased() == "icns", depth <= 4 {
                add(url)
            }
        }
        return found
    }
}

/// The project's logo at a small size with rounded corners, or a neutral tile with its first letter.
struct ProjectLogoView: View {
    let project: PROJProject?
    /// Used for the letter when there is no registry project.
    var name: String? = nil
    var size: CGFloat = 16
    /// On a blue selected row: a lighter tile and white letter.
    var onAccent = false

    static func letter(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(3, size * 0.25), style: .continuous)
        Group {
            if let image = ProjectLogos.image(project) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                shape.fill(onAccent ? Color.white.opacity(0.25) : Color.primary.opacity(0.12))
                    .overlay {
                        Text(Self.letter(project?.name ?? name ?? "?"))
                            .font(.system(size: size * 0.6, weight: .semibold))
                            .foregroundStyle(onAccent ? Color.white : Color.secondary)
                    }
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}
