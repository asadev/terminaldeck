import Foundation
import AppKit
import TerminalDeckNativeCore

/// Root supplies the app's existing session view, event sink and readiness.
/// This is a second view of the existing PTY, never a second terminal owner.
@MainActor public protocol BackendMacAppWindowsContent: AnyObject {
    var readiness: BackendLaunchReadiness { get }
    func make(sessionID: String, ownerID: String) throws -> NSView
    func whenReady(ownerID: String, show: @escaping @MainActor () -> Void)
    func destroyed(ownerID: String) -> Bool
    func deliver(ownerID: String, channel: String, arguments: [NativeRPCValue])
    func closed(ownerID: String)
}

@MainActor public final class BackendMacAppWindowsAppKitHandle: NSObject, BackendMacAppWindowsHandle, NSWindowDelegate {
    public let window: NSWindow
    public let ownerID: String
    public let windowID: Int
    private let content: any BackendMacAppWindowsContent
    private let primaryTop: @MainActor () -> Double
    private var savedNormal: BackendOSPopoutRules.Rect
    private var gone = false
    private var listeners: [String: [@MainActor () -> Void]] = [:]
    private static var nextID = 1
    public init(sessionID: String, title: String, bounds: BackendOSPopoutRules.Rect,
                content: any BackendMacAppWindowsContent, primaryTop: @escaping @MainActor () -> Double) throws {
        guard content.readiness == .ready else { throw NativeRPCError(code: "unavailable", message: "The native single-session window view is unavailable: its actual session adapter has not been supplied.") }
        self.content = content; self.primaryTop = primaryTop; savedNormal = bounds
        let nativeOwnerID = "native-popout-" + UUID().uuidString.lowercased()
        ownerID = nativeOwnerID
        let frame = BackendOSPopoutRules.toAppKit(bounds, primaryTop: primaryTop())
        let contentView = try content.make(sessionID: sessionID, ownerID: nativeOwnerID)
        let nativeWindow = NSWindow(contentRect: NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        nativeWindow.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
        window = nativeWindow
        windowID = Self.nextID; Self.nextID += 1
        super.init()
        window.title = title; window.minSize = NSSize(width: 480, height: 320)
        window.backgroundColor = NSColor(srgbRed: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1)
        window.isReleasedWhenClosed = false; window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = contentView; window.delegate = self
        BackendMacAppWindowsTitleBar.apply(to: window)
        content.whenReady(ownerID: ownerID) { [weak self] in self?.show() }
    }
    public var bounds: BackendOSPopoutRules.Rect {
        let frame = window.frame
        return BackendOSPopoutRules.fromAppKit(.init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), primaryTop: primaryTop())
    }
    public var normalBounds: BackendOSPopoutRules.Rect { fullScreen ? savedNormal : bounds }
    public var fullScreen: Bool { window.styleMask.contains(.fullScreen) }
    public var minimized: Bool { window.isMiniaturized }
    public var focused: Bool { window.isKeyWindow }
    public var destroyed: Bool { gone }
    public var contentDestroyed: Bool { gone || content.destroyed(ownerID: ownerID) }
    public func title(_ value: String) { window.title = value }
    public func fullscreen(_ on: Bool) { if on != fullScreen { if on { savedNormal = bounds }; window.toggleFullScreen(nil) } }
    public func restore() { window.deminiaturize(nil) }
    public func show() { if !gone { window.orderFront(nil) } }
    public func focus() { if !gone { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) } }
    public func close() { if !gone { window.close() } }
    public func send(_ channel: String, arguments: [NativeRPCValue]) { if !contentDestroyed { content.deliver(ownerID: ownerID, channel: channel, arguments: arguments) } }
    public func on(_ event: String, callback: @escaping @MainActor () -> Void) { listeners[event, default: []].append(callback) }
    private func emit(_ event: String) { for callback in listeners[event] ?? [] { callback() } }
    public func windowWillClose(_ notification: Notification) { if gone { return }; emit("close"); gone = true; content.closed(ownerID: ownerID); emit("closed") }
    public func windowDidMove(_ notification: Notification) { if !fullScreen { savedNormal = bounds }; emit("move") }
    public func windowDidResize(_ notification: Notification) { if !fullScreen { savedNormal = bounds }; BackendMacAppWindowsTitleBar.positionTrafficLights(in: window); emit("resize") }
    public func windowDidBecomeKey(_ notification: Notification) { emit("focus") }
    public func windowDidResignKey(_ notification: Notification) { emit("blur") }
    public func windowWillEnterFullScreen(_ notification: Notification) { savedNormal = bounds }
    public func windowDidEnterFullScreen(_ notification: Notification) { emit("enter-full-screen") }
    public func windowDidExitFullScreen(_ notification: Notification) { emit("leave-full-screen") }
}

/// Production dependency composition. Required functions are supplied by the
/// single lifecycle/window/UI graph; missing content throws unavailable.
@MainActor public final class BackendMacAppWindowsNativeDependencies: BackendMacAppWindowsDependencies {
    private let content: any BackendMacAppWindowsContent
    private let root: URL
    private let findSession: @MainActor (String) -> BackendSessionMeta?
    private let refuse: @MainActor (String) -> String?
    private let readStatus: @MainActor (String) -> String?
    private let boundsOfMain: @MainActor () -> BackendOSPopoutRules.Rect?
    private let bringMain: @MainActor (String?) throws -> Void
    private let announceWindows: @MainActor (NativeRPCValue, NativeRPCValue?) -> Void
    private let tellReplaced: @MainActor (String, BackendSessionMeta) -> Void
    private let note: @MainActor (String, NativeRPCValue) -> Void
    public init(userData: URL, content: any BackendMacAppWindowsContent,
                session: @escaping @MainActor (String) -> BackendSessionMeta?, refusal: @escaping @MainActor (String) -> String?,
                status: @escaping @MainActor (String) -> String?, mainBounds: @escaping @MainActor () -> BackendOSPopoutRules.Rect?,
                showMain: @escaping @MainActor (String?) throws -> Void,
                announce: @escaping @MainActor (NativeRPCValue, NativeRPCValue?) -> Void,
                announceReplaced: @escaping @MainActor (String, BackendSessionMeta) -> Void,
                log: @escaping @MainActor (String, NativeRPCValue) -> Void) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/"), userData.path != "/" else { throw NativeRPCError.invalidArguments("Session windows require the actual app user-data directory.") }
        root = userData; self.content = content; findSession = session; refuse = refusal; readStatus = status; boundsOfMain = mainBounds
        bringMain = showMain; announceWindows = announce; tellReplaced = announceReplaced; note = log
    }
    public static func primaryTop() -> Double { Double(NSScreen.screens.first?.frame.maxY ?? 0) }
    public func displays() throws -> (all: [BackendOSPopoutRules.Display], primary: BackendOSPopoutRules.Display) {
        let top = Self.primaryTop()
        let all = NSScreen.screens.compactMap { screen -> BackendOSPopoutRules.Display? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            func converted(_ frame: NSRect) -> BackendOSPopoutRules.Rect { BackendOSPopoutRules.fromAppKit(.init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), primaryTop: top) }
            return .init(id: id.doubleValue, label: screen.localizedName, bounds: converted(screen.frame), workArea: converted(screen.visibleFrame))
        }
        guard let primary = all.first else { throw NativeRPCError(code: "unavailable", message: "No native display is available for a session window.") }
        return (all, primary)
    }
    public func makeWindow(sessionID: String, bounds: BackendOSPopoutRules.Rect, title: String) throws -> any BackendMacAppWindowsHandle {
        try BackendMacAppWindowsAppKitHandle(sessionID: sessionID, title: title, bounds: bounds, content: content, primaryTop: Self.primaryTop)
    }
    public func mainBounds() -> BackendOSPopoutRules.Rect? { boundsOfMain() }
    public func showMain(command: String?) throws { try bringMain(command) }
    public func session(_ id: String) -> BackendSessionMeta? { findSession(id) }
    public func refusal(_ id: String) -> String? { refuse(id) }
    public func status(_ id: String) -> String? { readStatus(id) }
    public func readPlacements() throws -> NativeRPCValue {
        let file = root.appendingPathComponent(BackendOSPopoutRules.filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return .null }
        return try NativeRPCValue.parseJSON(Data(contentsOf: file))
    }
    public func writePlacements(_ file: NativeRPCValue) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var bytes = try file.encodedJSON(pretty: true); bytes.append(0x0a)
        try bytes.write(to: root.appendingPathComponent(BackendOSPopoutRules.filename), options: .atomic)
    }
    public func announce(view: NativeRPCValue, event: NativeRPCValue?) { announceWindows(view, event) }
    public func announceReplaced(previousID: String, meta: BackendSessionMeta) { tellReplaced(previousID, meta) }
    public func schedule(milliseconds: Int, run: @escaping @MainActor () -> Void) -> BackendMacAppWindowsScheduled {
        let task = Task { @MainActor in do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }; run() }
        return BackendMacAppWindowsScheduled { task.cancel() }
    }
    public func log(_ message: String, detail: NativeRPCValue) { note(message, detail) }
}

/// MCP window tools and native IPC use this exact same registry.
public struct BackendMacAppWindowsTools: BackendDeckToolsSessionsWindows, Sendable {
    private let registry: BackendMacAppWindowsRegistry
    private let authorize: @Sendable (BackendMCPCallContext) async throws -> Void
    public init(registry: BackendMacAppWindowsRegistry, authorize: @escaping @Sendable (BackendMCPCallContext) async throws -> Void) { self.registry = registry; self.authorize = authorize }
    public func view(context: BackendMCPCallContext) async throws -> NativeRPCValue { try await authorize(context); return try await registry.view() }
    public func open(sessionID: String, displayID: Double?, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await authorize(context); return try await registry.open(sessionID, displayID: displayID) }
    public func dock(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await authorize(context); return try await registry.dock(sessionID) }
}
