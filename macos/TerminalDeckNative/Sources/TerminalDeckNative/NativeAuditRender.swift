#if DEBUG
import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Render checks only (Debug builds; a scratch copy with defaults key `auditRender` = true). A distributed
/// notification `dev.terminaldeck.audit.render` {name, dark} draws a screen offscreen (a window far outside
/// every display, never ordered front, never activating) and saves it as a PNG under the app's test-renders.noindex folder.
@MainActor
enum NativeAuditRender {
    private static var installed = false
    static func install() {
        guard !installed else { return }; installed = true
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.terminaldeck.audit.render"), object: nil, queue: .main) { note in
            guard UserDefaults.standard.bool(forKey: "auditRender"), let info = note.userInfo, let name = info["name"] as? String else { return }
            let dark = info["dark"] as? Bool ?? false
            MainActor.assumeIsolated { Task { await render(name, dark: dark) } }
        }
    }

    /// The drag-out / drag-back cycle for the strip's tab `item`, without showing any window: the same calls a
    /// drag makes (pop out through the existing path, then the merge call a drop over the main window makes).
    /// Writes the evidence to ~/popout-cycle.txt and renders what the pop-out window would hold.
    static func cycle(item: Int) {
        Task { @MainActor in
            let model = AppModel.shared
            var lines: [String] = []
            guard let tab = model.stripTabs?.tabs[safe: item] else { lines.append("no tab \(item)"); write(lines); return }
            lines.append("tab: \(tab.title) (\(tab.id))")
            // 1. dragged out of the window
            NativePaneDragSpace.popOut(.tab(tabId: tab.id))
            let refs = model.takePendingScreens()
            lines.append("drag out -> windows asked for: \(refs.map { $0.screenKind + "/" + $0.id })")
            guard let ref = refs.first(where: { $0.id == tab.id }) else { lines.append("FAIL: no pop-out queued"); write(lines); return }
            // 2. the pop-out's page exists (what the window's .onAppear does) and its content draws
            _ = model.attachScreen(ref)
            lines.append("pop-out screen attached: yes")
            await renderWindow(name: "popout-window", ref: ref, model: model)
            // 3. dragged back over the main window
            let over = NativePopoutMerge.isOverMain(CGPoint(x: (AppModel.shared.web.webView.window?.frame.midX ?? -1), y: (AppModel.shared.web.webView.window?.frame.midY ?? -1)))
            lines.append("pointer over the main window counts as a merge: \(over)")
            guard over else {
                lines.append("UNPROVEN: main window is not a merge target; return was not called")
                model.detachScreen(ref)
                write(lines); return
            }
            NativeFront.proofActing = true
            var opened = false, closed = false
            model.returnScreenToMain(ref, from: nil, openMain: { opened = true }, closeWindow: { closed = true })
            NativeFront.proofActing = false
            lines.append("merge -> main window ensured: \(opened); pop-out closed: \(closed); selected tab: \(model.stripTabs?.tabs.first(where: \.active)?.id == tab.id ? "the dragged one" : "OTHER")")
            write(lines)
        }
    }

    private static func write(_ lines: [String]) {
        try? lines.joined(separator: "\n").write(toFile: NSHomeDirectory() + "/popout-cycle.txt", atomically: true, encoding: .utf8)
    }

    private static func renderWindow(name: String, ref: ScreenRef, model: AppModel) async {
        let size = CGSize(width: 900, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 12000, y: 12000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ScreenWindow(ref: ref, model: model).frame(width: size.width, height: size.height))
        host.sizingOptions = []; window.contentView = host; window.setContentSize(size); host.setFrameSize(size)
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: FIXESTestRenderPaths.image(URL(fileURLWithPath: NSHomeDirectory() + "/test-renders.noindex/audit-\(name).png")))
        }
        window.close()
    }

    static func render(_ name: String, dark: Bool) async {
        let size: CGSize
        let view: AnyView
        switch name {
        case "simulators":
            let model = NativeSimulatorModel(deviceRail: true)
            await model.refresh()
            try? await Task.sleep(for: .milliseconds(600))
            size = CGSize(width: 900, height: 620); view = AnyView(NativeUIGSimulatorScreen(model: model))
        case "simulators-stopped":
            // A stopped device selected: the rail's Start button and the stage's, from fixture rows.
            let rows = [DeviceEntry(id: "ios:A", name: "iPhone 17 Pro", runtime: "iOS 27.0", canBoot: true),
                        DeviceEntry(id: "ios:B", platform: "ios", state: "ready", name: "iPhone 18 Pro with a long name", runtime: "iOS 27.0", canShutDown: true),
                        DeviceEntry(id: "avd:P", platform: "android", kind: "emulator", state: "shutdown", available: false, name: "Pixel 9", canBoot: true)]
            size = CGSize(width: 900, height: 620)
            view = AnyView(HStack(spacing: 0) {
                VStack(spacing: 2) {
                    HStack { Text("Devices").font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.vertical, 10)
                    ForEach(rows) { NativeUIGSimulatorRailRow(entry: $0, selected: $0.id == "ios:A", working: "", openAction: {}) {} }
                    Spacer()
                }.padding(.horizontal, 6).frame(width: 190).background(.quaternary.opacity(0.12))
                Divider()
                NativeUIGSimulatorStoppedDevice(entry: rows[0], working: "") {}
            })
        case "buttons":
            // Before (the old style of each main button) and after (blue), by label and screen.
            let rows: [(String, String, Bool)] = [("Machines", "Add a server", true), ("Machines (a machine)", "Connect", false), ("Tasks (My Work)", "Add task", true),
                ("Browser settings", "Add a profile", false), ("Hoot on a machine", "Send", false), ("Hoot files", "Create its files", false),
                ("Database connection", "Create app", false), ("Hoot's AI", "Save", false), ("Notify an AI app", "Save", false),
                ("Apps options / alerts / cleanup", "Save", false), ("Server name", "Save", false)]
            size = CGSize(width: 760, height: 120 + CGFloat(rows.count) * 34)
            view = AnyView(VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Screen").frame(width: 250, alignment: .leading); Text("Before").frame(width: 200, alignment: .leading); Text("After") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).frame(width: 250, alignment: .leading)
                        Group {
                            if row.2 && row.0 == "Tasks (My Work)" { TasksLinkButton("+ Add task") {} }
                            else if row.2 { Button(row.1) {}.buttonStyle(.bordered).nativeUIGGreyControl() }
                            else { Button(row.1) {} }
                        }.frame(width: 200, alignment: .leading)
                        Button(row.1) {}.buttonStyle(.borderedProminent)
                    }
                }
                Divider()
                HStack(spacing: 14) {
                    Text("Stay as they are:").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") {}; Button("Refresh") {}; Button("Deny") {}
                    Picker("", selection: .constant(1)) { Text("Table").tag(0); Text("Board").tag(1) }.pickerStyle(.segmented).frame(width: 140).nativeUIGGreyControl()
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        case "two-devices":
            // The production split with two stub device panels (an iPhone and an Android), no simulator booted.
            func dock(_ slot: Int, _ entry: DeviceEntry) -> NativeUIGSessionSimulatorSplit<AnyView>.Dock {
                .init(slot: slot, state: .constant(UIGSessionSimulatorState(isOpen: true, width: 300)), title: entry.name,
                      view: AnyView(VStack(spacing: 0) {
                          HStack { Text(entry.platform == "ios" ? "iOS Simulator" : "Android").font(.callout.weight(.semibold)); Spacer() }.padding(12)
                          Text("\(entry.name) · \(entry.runtime)").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                          NativeUIGSimulatorStoppedDevice(entry: entry, working: "") {}
                      }.background(Color(nsColor: .windowBackgroundColor))))
            }
            size = CGSize(width: 1080, height: 640)
            view = AnyView(NativeUIGSessionSimulatorSplit(docks: [dock(0, DeviceEntry(id: "ios:A", name: "iPhone 17 Pro", runtime: "iOS 27.0", canBoot: true)),
                                                                  dock(1, DeviceEntry(id: "android:P", platform: "android", kind: "emulator", state: "shutdown", available: false, name: "Pixel 9", runtime: "Android 16", canBoot: true))],
                                                          sessionId: nil) {
                AnyView(VStack(alignment: .leading) { Text("Session 1  acme-api").font(.headline); Text("imatch@mini acme-api % ").font(.system(.body, design: .monospaced)); Spacer() }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor)))
            })
        case "agents":
            let sessions = try? JSONSerialization.jsonObject(with: Data(#"[{"id":"s1","provider":"claude","title":"Build the API","cwd":"/p/api","status":"working"}]"#.utf8))
            let tasks = try? JSONSerialization.jsonObject(with: Data(#"[{"id":"t1","assignee":"me","agent":"Me","title":"Review the invoice"},{"id":"t2","assignee":{"kind":"human","agentId":"p2"},"agent":"Person","title":"Call the client"},{"id":"t3","assignee":"builder","agent":"Builder","title":"Write the tests","process":"working"}]"#.utf8))
            let model = AWAgentsWatchModel(read: { _, _ in try await Task.sleep(for: .seconds(3600)); return NSNull() })
            model.agents = AWWatchProjection.inventory(sessions: (sessions as? [Any])?.compactMap { try? NativeRPCValue.fromFoundation($0) } ?? [],
                                                       tasks: (tasks as? [Any])?.compactMap { try? NativeRPCValue.fromFoundation($0) } ?? [])
            model.loading = false
            size = CGSize(width: 900, height: 520); view = AnyView(AWAgentsWatchScreen(model: model))
        default: return
        }
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 12000, y: 12000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        window.contentView = host; window.setContentSize(size); host.setFrameSize(size)
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { window.close(); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: FIXESTestRenderPaths.image(URL(fileURLWithPath: NSHomeDirectory() + "/test-renders.noindex/audit-\(name)-\(dark ? "dark" : "light").png")))
        }
        window.close()
    }
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
#endif
