import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// #108 (L6-SIMMENU): the Simulators row menu. Pure model checks always run; the
/// offscreen render runs with L6SIM_RENDER=1. Stub devices only: no engine call,
/// no simulator, no clipboard, no visible window, no app activation.
final class L6SimMenuTests: XCTestCase {
    private let iosOn = DeviceEntry(id: "ios:00000000-0000-0000-0000-000000000108", platform: "ios", kind: "simulator",
                                    state: "ready", available: true, name: "iPhone 17 Pro", runtime: "iOS 27.0", canShutDown: true)
    private let iosOff = DeviceEntry(id: "ios:00000000-0000-0000-0000-000000000109", platform: "ios", kind: "simulator",
                                     state: "shutdown", available: false, name: "iPhone 17", runtime: "iOS 27.0", canBoot: true)
    private let android = DeviceEntry(id: "avd:Pixel_9", platform: "android", kind: "emulator", state: "shutdown",
                                      available: false, name: "Pixel 9", runtime: "Android 16", canBoot: true)
    private let phone = DeviceEntry(id: "android:R5CT", platform: "android", kind: "physical", state: "ready",
                                    available: true, name: "Galaxy", runtime: "Android 15")

    /// 3 Nov (Asad: Hoot "should not be always open until we open the Hoot"): the phone panel with no session on show
    /// lands on Hoot's page only when Hoot's page is what is on show; anywhere else it opens in its own phone window.
    @MainActor func testPhonePanelWithoutASessionNeverOpensHootsPage() {
        XCTAssertTrue(SHELLRoutes.onHootsPage("hoot"))
        XCTAssertFalse(SHELLRoutes.onHootsPage("panel"))
        XCTAssertFalse(SHELLRoutes.onHootsPage("browser"))
        XCTAssertFalse(SHELLRoutes.onHootsPage(nil))
        let source = (try? String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/TerminalDeckNativeUITests/L6SimMenuTests.swift",
            with: "Sources/TerminalDeckNative/SHELLRoutes.swift"), encoding: .utf8)) ?? ""
        let body = source.components(separatedBy: "static func openPhonePanel").dropFirst().first?.components(separatedBy: "static func onHootsPage").first ?? ""
        XCTAssertFalse(body.isEmpty)
        XCTAssertFalse(body.contains("select(\"hoot\")"), "opening the phone panel must never select Hoot's page")
    }

    func testSectionsFollowTheSpec() {
        XCTAssertEqual(FIXESDeviceContextAction.sections(for: iosOn),
                       [[.shutDown, .restart], [.newTab, .newWindow, .beside, .sendToHoot], [.finder, .copyID, .rename], [.reset, .delete]])
        XCTAssertEqual(FIXESDeviceContextAction.sections(for: iosOff).first, [.start, .startAndOpen])
        XCTAssertEqual(FIXESDeviceContextAction.sections(for: android).first, [.start, .coldStart, .shutDown])
        XCTAssertEqual(FIXESDeviceContextAction.sections(for: phone), [[.newTab, .newWindow, .beside, .sendToHoot], [.copyID]])
        XCTAssertEqual(FIXESDeviceContextAction.reset.title(for: iosOn), "Erase all content and settings…")
        XCTAssertEqual(FIXESDeviceContextAction.reset.title(for: android), "Wipe data…")
        XCTAssertEqual(FIXESDeviceContextAction.newTab.title, "Open in a new tab")
        XCTAssertEqual(FIXESDeviceContextAction.sendToHoot.title, "Send the screen to Hoot")
    }

    func testAvailabilityFencesStateAndPhones() {
        XCTAssertFalse(FIXESDeviceContextAction.start.available(for: iosOn))
        XCTAssertTrue(FIXESDeviceContextAction.shutDown.available(for: iosOn))
        XCTAssertFalse(FIXESDeviceContextAction.sendToHoot.available(for: iosOff))
        XCTAssertFalse(FIXESDeviceContextAction.delete.available(for: phone))
        XCTAssertTrue(FIXESDeviceContextAction.copyID.available(for: iosOn, working: true))
        XCTAssertFalse(FIXESDeviceContextAction.shutDown.available(for: iosOn, working: true))
    }

    func testDestructiveAndRenameConfirmFirst() {
        var menu = FIXESDeviceMenuInteraction()
        XCTAssertNil(menu.choose(.delete, entry: iosOn), "Delete must wait for the named alert")
        XCTAssertEqual(menu.pending, .delete)
        menu.cancel()
        XCTAssertNil(menu.pending)
        XCTAssertNil(menu.choose(.reset, entry: iosOn))
        XCTAssertEqual(menu.confirm(), .init(action: .reset, deviceID: iosOn.id, name: nil, confirmed: true))
        XCTAssertNil(menu.choose(.rename, entry: iosOn))
        XCTAssertEqual(menu.name, "iPhone 17 Pro")
        menu.name = "   "
        XCTAssertNil(menu.confirm(), "An empty name never renames")
        menu.name = "Review phone"
        XCTAssertEqual(menu.confirm(), .init(action: .rename, deviceID: iosOn.id, name: "Review phone", confirmed: false))
        XCTAssertEqual(menu.choose(.shutDown, entry: iosOn), .init(action: .shutDown, deviceID: iosOn.id, name: nil, confirmed: false))
    }

    @MainActor func testOnlyEraseAndDeleteCloseTheDeviceBeforeTheChange() {
        // #455: a refused Shut down bounced the person to the list although the device did not change.
        for action in [FIXESDeviceContextAction.shutDown, .restart, .coldStart, .rename] {
            XCTAssertFalse(NativeFIXESDeviceContextMenu.closesBeforeChange(action), "\(action)")
        }
        XCTAssertTrue(NativeFIXESDeviceContextMenu.closesBeforeChange(.reset))
        XCTAssertTrue(NativeFIXESDeviceContextMenu.closesBeforeChange(.delete))
    }

    func testOnlyNewSessionsAreReadAgain() {
        // #466: a start, end or rename re-read every session; the push keeps the known ones current.
        XCTAssertEqual(FIXESDeviceSessionUsage.unread(before: [], after: ["a", "b"], pending: []), ["a", "b"])
        XCTAssertEqual(FIXESDeviceSessionUsage.unread(before: ["a", "b"], after: ["a", "b"], pending: []), [])
        XCTAssertEqual(FIXESDeviceSessionUsage.unread(before: ["a", "b"], after: ["a", "b", "c"], pending: []), ["c"])
        XCTAssertEqual(FIXESDeviceSessionUsage.unread(before: ["a", "b"], after: ["a"], pending: []), [])
        // A read cut short by the next change is read again; an ended session never is.
        XCTAssertEqual(FIXESDeviceSessionUsage.unread(before: ["a", "c"], after: ["a", "c", "d"], pending: ["c"]), ["c", "d"])
        XCTAssertEqual(FIXESDeviceSessionUsage.unread(before: ["a", "c"], after: ["a"], pending: ["c"]), [])
    }

    @MainActor func testEveryChangeUsesOneDeviceChannel() {
        XCTAssertEqual(NativeFIXESDeviceContextMenu.channel(for: .shutDown), "devices:shutdown")
        XCTAssertEqual(NativeFIXESDeviceContextMenu.channel(for: .restart), "devices:restart")
        XCTAssertEqual(NativeFIXESDeviceContextMenu.channel(for: .coldStart), "devices:cold-start")
        XCTAssertEqual(NativeFIXESDeviceContextMenu.channel(for: .rename), "devices:rename")
        XCTAssertEqual(NativeFIXESDeviceContextMenu.channel(for: .reset), "devices:reset")
        XCTAssertEqual(NativeFIXESDeviceContextMenu.channel(for: .delete), "devices:delete")
    }

    @MainActor func testCopyIDUsesInjectedWriterAndBareID() {
        var copied: [String] = []
        XCTAssertTrue(NativeFIXESDeviceMenuServices.copyID(iosOn.id) { copied.append($0); return true })
        XCTAssertTrue(NativeFIXESDeviceMenuServices.copyID(android.id) { copied.append($0); return true })
        XCTAssertEqual(copied, ["00000000-0000-0000-0000-000000000108", "Pixel_9"])
    }

    @MainActor func testDeviceTabIDsRoundTrip() {
        XCTAssertEqual(NativeFIXESDeviceTabs.screenID(iosOn.id), "simulator:" + iosOn.id)
        XCTAssertEqual(NativeFIXESDeviceTabs.deviceID("simulator:avd:Pixel_9"), "avd:Pixel_9")
        XCTAssertNil(NativeFIXESDeviceTabs.deviceID("simulators"))
    }

    // MARK: Offscreen render (L6SIM_RENDER=1)

    @MainActor func testRailAndMenuRender() throws {
        guard ProcessInfo.processInfo.environment["L6SIM_RENDER"] == "1" else { throw XCTSkip("L6-SIMMENU renders run on request") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = NativeSimulatorModel(deviceRail: true)
        let rows: [(DeviceEntry, [String])] = [
            (iosOn, ["Commander"]), (iosOff, []),
            (DeviceEntry(id: "ios:00000000-0000-0000-0000-000000000110", platform: "ios", state: "shutdown", available: false,
                         name: "iPad Air 13-inch (M4)", runtime: "iPadOS 27.0", canBoot: true), []),
            (DeviceEntry(id: "android:emulator-5554", platform: "android", kind: "emulator", state: "ready", available: true,
                         name: "Pixel 9", runtime: "Android 16", canShutDown: true), ["CRM session"]),
            (android, []),
        ]
        let menuEntry = iosOn
        for dark in [false, true] {
            let view = HStack(alignment: .top, spacing: 0) {
                railView(rows, model: model)
                Divider()
                menuListing(menuEntry)
                Spacer(minLength: 0)
            }
            try render(view, dark: dark, size: CGSize(width: 1000, height: 460), name: "L6-SIMMENU-rail-\(dark ? "dark" : "light")")
        }
    }

    // Split out so the type checker sees small expressions.
    @MainActor private func railView(_ rows: [(DeviceEntry, [String])], model: NativeSimulatorModel) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                self.railRow(row.0, labels: row.1, first: index == 0, model: model)
            }
            Spacer()
        }
        .padding(6).frame(width: 280)
    }

    @MainActor private func railRow(_ entry: DeviceEntry, labels: [String], first: Bool, model: NativeSimulatorModel) -> some View {
        let menu = NativeFIXESDeviceContextMenu(entry: entry, model: model, start: {}, selected: first,
                                                readsEnabled: false, forceEllipsis: first)
        return NativeUIGSimulatorRailRow(entry: entry, selected: first, working: "", sessionLabels: labels, action: {})
            .modifier(menu)
    }

    // Fixture listing of the menu's real sections (an NSMenu cannot be drawn offscreen).
    @MainActor private func menuListing(_ entry: DeviceEntry) -> some View {
        let sections: [[FIXESDeviceContextAction]] = FIXESDeviceContextAction.sections(for: entry)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.offset) { section in
                if section.offset > 0 { Divider().padding(.vertical, 3) }
                ForEach(section.element, id: \.self) { action in
                    self.menuItem(action, entry: entry)
                }
            }
        }
        .padding(12).frame(width: 300).background(.regularMaterial, in: .rect(cornerRadius: 10))
        .padding(16)
    }

    @MainActor @ViewBuilder private func menuItem(_ action: FIXESDeviceContextAction, entry: DeviceEntry) -> some View {
        let colour: Color = action == .delete ? .red : .primary
        if action == .sendToHoot, let owl = NativeFIXESDeviceContextMenu.hootImage {
            Label { Text(action.title) } icon: { Image(nsImage: owl) }.foregroundStyle(colour)
        } else {
            Label(action.title(for: entry), systemImage: action.symbol).foregroundStyle(colour)
        }
    }

    @MainActor private func render<V: View>(_ view: V, dark: Bool, size: CGSize, name: String) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["L6SIM_RENDER_OUTPUT"] ??
            "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex")
        XCTAssertTrue(output.lastPathComponent.hasSuffix(".noindex"))
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)))
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        appearance.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertFalse(window.isVisible); XCTAssertFalse(NSApp.isActive)
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(png).write(to: output.appendingPathComponent(name + ".png"))
    }
}
