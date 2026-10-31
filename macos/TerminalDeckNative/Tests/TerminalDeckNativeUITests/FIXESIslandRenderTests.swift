import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor private final class FIXESIslandOwlBoundsBox { var frame = CGRect.zero }

/// The shared native view test target imports the actual app module. No app
/// initialization, bundle launch, window creation, ordering or activation.
final class FIXESIslandRenderTests: XCTestCase {
    @MainActor private func outputDirectory() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.lastPathComponent != "macos", directory.path != "/" { directory.deleteLastPathComponent() }
        guard directory.lastPathComponent == "macos" else { throw failure("Could not find the Mac test-output directory") }
        return try FIXESTestRenderPaths.directory(directory.appendingPathComponent("design-2026-10-10/built.noindex", isDirectory: true))
    }
    @MainActor func testActualIslandFramesUseTheAppAppearanceAndKeepHootVisible() throws {
        let out = try outputDirectory()
        let plain = IslandScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056))
        let notched = IslandScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32), auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32))
        let states: [(String, IslandState?)] = [("startup", nil),
            ("stopped", IslandState.native(sessionStatuses: [], line: "Hoot", hootStatus: "stopped")),
            ("working", IslandState.native(sessionStatuses: ["working"], line: "Commander is working", hootStatus: "running")),
            ("waiting", IslandState.native(sessionStatuses: ["input"], line: "Commander needs you", hootStatus: "running"))]
        for hasNotch in [false, true] { for dark in [false, true] { for (stateName, state) in states { for grown in [false, true] {
            let mode = dark ? "dark" : "light", screen = hasNotch ? "notched" : "external", size = grown ? "grown" : "resting"
            try render(screen: hasNotch ? notched : plain, builtIn: hasNotch, dark: dark, state: state,
                grown: grown, options: .init(), to: out.appendingPathComponent("FIXES-island-\(screen)-\(mode)-\(stateName)-\(size).png"))
        }}}}
        for width in [FIXESIslandOptions.Width.compact, .wide] { for dark in [false, true] { for grown in [false, true] {
            try render(screen: plain, builtIn: false, dark: dark, state: states[2].1, grown: grown, options: .init(width: width),
                to: out.appendingPathComponent("FIXES-island-\(width.rawValue)-\(dark ? "dark" : "light")-\(grown ? "grown" : "resting").png"))
        }}}
        for grown in [false, true] {
            try render(screen: plain, builtIn: false, dark: false, state: states[2].1, grown: grown, options: .init(look: .dark),
                to: out.appendingPathComponent("FIXES-island-always-dark-\(grown ? "grown" : "resting").png"))
        }
        for dark in [false, true] {
            try render(screen: plain, builtIn: false, dark: dark, state: nil, grown: false, options: .init(whenQuiet: .hide),
                to: out.appendingPathComponent("FIXES-island-quiet-hidden-\(dark ? "dark" : "light").png"))
        }
        for dark in [false, true] { for grown in [false, true] {
            try render(screen: plain, builtIn: false, dark: dark, state: nil, grown: grown, options: .init(whenQuiet: .hide), hootBusy: true,
                to: out.appendingPathComponent("FIXES-island-headless-hoot-busy-\(dark ? "dark" : "light")-\(grown ? "grown" : "resting").png"))
        }}
    }
    @MainActor func testSettingsOwnerRestartRemembersTheActualNativePreferences() async throws {
        let out = try outputDirectory()
        let directory = out.appendingPathComponent("settings-fixture-\(UUID().uuidString).noindex", isDirectory: true)
        let store = BackendAppSettingsStore(userData: directory, writable: true)
        let initial = await store.get()
        let preferences = NativeFIXESIslandPreferences(values: initial, write: { try await store.patch($0) })
        var changes = 0; preferences.changed = { changes += 1 }
        let screen = FIXESIslandScreenChoice(mode: .named, screenID: "fixture-screen-uuid", screenName: "Studio")
        try await preferences.update(showOn: screen, look: .dark, width: .wide, whenQuiet: .hide, enabled: false)
        let restartedStore = BackendAppSettingsStore(userData: directory, writable: true)
        let restarted = NativeFIXESIslandPreferences(values: await restartedStore.get())
        guard restarted.choice == screen, restarted.options == .init(look: .dark, width: .wide, whenQuiet: .hide), !restarted.enabled, changes == 1 else {
            throw failure("A restarted settings owner lost the screen or appearance choice.")
        }
        let patch = NativeRPCValue.object([.init(NativeFIXESIslandPreferences.widthKey, .string("compact"))])
        preferences.accept(try await store.patch(patch))
        guard preferences.options.width == .compact, changes == 2 else { throw failure("An ordinary settings write did not update the cached island.") }
        print("PASS actual NativeFIXESIslandPreferences + BackendAppSettingsStore save/restart and ordinary-settings update callback (2 changes).")
    }
    @MainActor private func render(screen: IslandScreen, builtIn: Bool, dark: Bool, state: IslandState?, grown: Bool, options: FIXESIslandOptions, hootBusy: Bool = false, to requested: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let quiet = !hootBusy && (state == nil || state?.status == .idle || state?.status == .offline)
        let model = IslandViewModel(layout: IslandGeometry.layout(for: screen))
        let wire = NativeRPCValue.object([.init("appearance", .string(dark ? "dark" : "light")), .init("quiet", .bool(quiet)),
            .init("label", .object([.init("text", .string(state?.line ?? (hootBusy ? "Hoot is working" : "All quiet")))])),
            .init("hoot", .object([.init("status", .string(quiet ? "stopped" : "running")), .init("busy", .bool(hootBusy))])),
            .init("sessions", .array(state?.status == .working ? [.object([.init("status", .string("working"))])] :
                state?.status == .needsYou ? [.object([.init("status", .string("input"))])] : [])),
            .init("geometry", .object([.init("displayWidth", .number(Double(screen.frame.width))),
                .init("barHeight", .number(Double(IslandGeometry.layout(for: screen).row)))]))])
        model.acceptNativeSnapshot(wire, screen: screen, builtIn: builtIn, options: options)
        if state == nil && !hootBusy { model.nativeState = nil }
        model.expanded = grown
        let layout = model.layout
        XCTAssertEqual(layout.panel.width, options.width.grown)
        XCTAssertEqual(layout.expandedFrame.midX, layout.centreX)
        XCTAssertEqual(layout.expandedFrame.maxY, screen.frame.maxY)
        let owlBounds = FIXESIslandOwlBoundsBox()
        let view = IslandView(model: model, suppliedContent: AnyView(
            NativeHootChat(model: NativeHootChatModel(fixture: .object([.init("messages", .array([]))])), compact: true)),
            owlBoundsChanged: { owlBounds.frame = $0 })
        let size = grown ? layout.expandedFrame.size : layout.collapsedFrame.size
        let container = IslandContainerView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: view); host.sizingOptions = []; host.appearance = appearance
        container.appearance = appearance
        container.canvasFrame = { model.layout.canvasFrame(inWindowOfSize: $0) }
        container.host(host)
        container.wantsLayer = true
        appearance.performAsCurrentDrawingAppearance { container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
        // Fixed-frame NSHostingView only: no NSApplication or NSWindow calls.
        container.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)); container.layoutSubtreeIfNeeded()
        guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { throw failure("No island bitmap") }
        container.cacheDisplay(in: container.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("No island PNG") }
        let output = try FIXESTestRenderPaths.image(requested); try png.write(to: output)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let topBounds = NSRect(x: (size.width - layout.pill.outerWidth) / 2, y: size.height - layout.row,
            width: layout.pill.outerWidth, height: layout.row)
        guard let topBitmap = container.bitmapImageRepForCachingDisplay(in: topBounds) else { throw failure("No top-row bitmap") }
        container.cacheDisplay(in: topBounds, to: topBitmap)
        let frame = owlBounds.frame
        guard frame.width > 0, frame.height > 0 else { throw failure("The real owl did not report its drawing bounds") }
        let glyphBounds = NSRect(x: host.frame.minX + frame.minX, y: host.frame.maxY - frame.maxY,
            width: frame.width, height: frame.height).intersection(container.bounds)
        guard let glyph = container.bitmapImageRepForCachingDisplay(in: glyphBounds) else { throw failure("No glyph bitmap") }
        container.cacheDisplay(in: glyphBounds, to: glyph)
        let glyphOutput = output.deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent + "-owl.png")
        if let glyphPNG = glyph.representation(using: .png, properties: [:]) { try glyphPNG.write(to: FIXESTestRenderPaths.image(glyphOutput)) }
        var contrastPixels = 0, palettePixels = 0
        var minimum = 1.0, maximum = 0.0
        let fill = model.usesBlack ? 0.0 : 1.0
        let colors = [HootArt.Colour.body, HootArt.Colour.bodyDark]
        // The real owl's measured rectangle excludes its status dot, text and
        // any owl in expanded content. Check the approved original brand palette.
        for y in 0..<glyph.pixelsHigh { for x in 0..<glyph.pixelsWide {
            guard let color = glyph.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let red = Double(color.redComponent), green = Double(color.greenComponent), blue = Double(color.blueComponent)
            let luminance = (red + green + blue) / 3
            minimum = min(minimum, luminance); maximum = max(maximum, luminance)
            if abs(luminance - fill) > 0.10 { contrastPixels += 1 }
            if colors.contains(where: { abs(red - Double($0.red)) < 0.025 && abs(green - Double($0.green)) < 0.025 && abs(blue - Double($0.blue)) < 0.025 }) { palettePixels += 1 }
        }}
        if model.hiddenWhileQuiet {
            guard palettePixels == 0, maximum - minimum < 0.025 else { throw failure("Quiet Hide still draws Hoot") }
        } else {
            guard palettePixels > 6, contrastPixels > 6, maximum - minimum > 0.15 else {
                throw failure("Hoot is blank or too faint in actual IslandView/IslandContainerView: \(output.lastPathComponent)")
            }
            let sampleX = layout.notched ? topBitmap.pixelsWide / 2 : Int(10 * scale)
            guard let surface = topBitmap.colorAt(x: sampleX, y: Int(8 * scale))?.usingColorSpace(.sRGB) else { throw failure("No surface sample") }
            let brightness = (surface.redComponent + surface.greenComponent + surface.blueComponent) / 3
            guard model.usesBlack ? brightness < 0.04 : brightness > 0.6 else { throw failure("Wrong surface \(brightness) in \(output.lastPathComponent)") }
        }
        host.removeFromSuperview()
        print("Rendered actual \(output.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh); owl palette pixels \(palettePixels), contrast pixels \(contrastPixels).")
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "FIXESIslandRender", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
