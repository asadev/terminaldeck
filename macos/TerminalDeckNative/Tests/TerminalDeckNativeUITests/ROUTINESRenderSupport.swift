import AppKit
import SwiftUI

/// Direct NSHostingView capture in the Swift Testing process. No windows,
/// production app initialization, app bundles, engine, data stores or AI calls.
@MainActor
enum ROUTINESHiddenRender {
    static func render<V: View>(_ view: V, dark: Bool, size: CGSize, to output: URL) throws {
        guard output.deletingLastPathComponent().lastPathComponent == "built.noindex",
              output.lastPathComponent.hasPrefix("ROUTINES-"), output.pathExtension == "png" else {
            throw failure("Render output must be ROUTINES-*.png inside built.noindex.")
        }
        let application = NSApplication.shared
        guard application.windows.allSatisfy({ !$0.isVisible }), !application.isActive else {
            throw failure("The test process has a visible window or is active.")
        }
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard application.windows.allSatisfy({ !$0.isVisible }), !application.isActive else {
            throw failure("The view capture showed a window or activated the test process.")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw failure("SwiftUI did not provide a view bitmap.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw failure("Could not encode the view capture.")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        print("Rendered \(output.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh); direct NSHostingView; visible=false; active=false")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ROUTINESHiddenRender", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
