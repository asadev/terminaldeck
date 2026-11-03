import AppKit
import SwiftUI

/// Fixed-frame content captures called only from MACHINESViewTests.
/// No app bundle, window, panel or production backend is created.
@MainActor
enum MACHINESHiddenRender {
    static func render<V: View>(_ view: V, dark: Bool, size: CGSize, to output: URL) throws {
        guard output.deletingLastPathComponent().lastPathComponent.hasSuffix(".noindex"),
              output.lastPathComponent.hasPrefix("MACHINES-"), output.pathExtension == "png" else {
            throw failure("Render output must be MACHINES-*.png inside a .noindex folder.")
        }
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard host.window == nil, NSApp?.windows.contains(where: { $0.isVisible }) != true,
              NSApp?.isActive != true else { throw failure("A content render created a visible or active app window.") }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw failure("SwiftUI did not provide a bitmap.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Could not encode the render.") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        print("Rendered \(output.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh); fixed NSHostingView; no window")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MACHINESHiddenRender", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
