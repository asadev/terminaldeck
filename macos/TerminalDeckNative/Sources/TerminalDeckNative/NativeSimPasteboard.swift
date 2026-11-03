import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Copy and paste between this Mac and an iOS Simulator on it, both ways, through the
/// simulator's own pasteboard (`simctl pbcopy` / `simctl pbpaste`). Event-driven only: the
/// Mac's clipboard goes to the phone when its screen takes focus or on ⌘V; the phone's comes
/// back to the Mac on ⌘C, when the screen loses focus, and when this app stops being the
/// front one. Never polled. Text only.
/// Android (#57): Mac → phone is typed into the field with focus on ⌘V (the screen view does that);
/// phone → Mac reads the phone's clip through adb's shell (`AndroidClipParcel`), on the same moments.
@MainActor enum NativeSimPasteboard {
    /// The simulator whose screen last had focus, for the read when the app goes to the back.
    private static var lastDevice: String?
    /// What moved last, each way (Core's SimPasteboardSync decides; it is tested there).
    private static var sync = SimPasteboardSync()
    private static var observing = false

    static func udid(_ deviceID: String?) -> String? { SimPasteboardSync.simulatorUDID(deviceID) }

    /// The screen took focus (or ⌘V): the Mac's clipboard text, when it changed, onto the phone's pasteboard.
    static func toPhone(_ deviceID: String?, force: Bool = false) {
        observeAppLeaving()
        if androidSerial(deviceID) != nil { lastDevice = deviceID; return } // typed on ⌘V by the screen view
        guard let udid = udid(deviceID) else { return }
        lastDevice = deviceID
        let board = NSPasteboard.general
        guard let text = sync.toPhone(macChangeCount: board.changeCount, macText: board.string(forType: .string), force: force) else { return }
        Task.detached { _ = await run(["simctl", "pbcopy", udid], input: Data(text.utf8)) }
    }

    /// ⌘C, focus leaving the screen, or the app going to the back: one read of the phone's
    /// pasteboard; new text there lands on the Mac's clipboard.
    static func fromPhone(_ deviceID: String?) {
        let id = deviceID ?? lastDevice
        if let serial = androidSerial(id) {
            lastDevice = id
            guard let adb = BackendAndroidScreenRecord.adbPath() else { return }
            Task.detached {
                let printed = await run(AndroidClipParcel.arguments(serial: serial), input: nil, tool: adb).flatMap { String(data: $0, encoding: .utf8) }
                let phone = printed.flatMap(AndroidClipParcel.text)
                await MainActor.run { land(phone) }
            }
            return
        }
        guard let udid = udid(id) else { return }
        Task.detached {
            let data = await run(["simctl", "pbpaste", udid], input: nil)
            let phone = data.flatMap { String(data: $0, encoding: .utf8) }
            await MainActor.run {
                let board = NSPasteboard.general
                guard let text = sync.toMac(phoneText: phone, macText: board.string(forType: .string)) else { return }
                board.clearContents()
                board.setString(text, forType: .string)
                sync.macWritten(changeCount: board.changeCount)
            }
        }
    }

    private static func observeAppLeaving() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if lastDevice != nil { fromPhone(nil) } }
        }
    }

    /// The phone's text, when new, onto the Mac's clipboard.
    private static func land(_ phone: String?) {
        let board = NSPasteboard.general
        guard let text = sync.toMac(phoneText: phone, macText: board.string(forType: .string)) else { return }
        board.clearContents()
        board.setString(text, forType: .string)
        sync.macWritten(changeCount: board.changeCount)
    }

    /// The adb serial of an Android device id ("android:emulator-5554"), else nil.
    static func androidSerial(_ deviceID: String?) -> String? { deviceID.flatMap(BackendAndroidScreenRecord.serial) }

    /// `xcrun simctl …` (or `tool …`; off the main thread); its output, or nil when it failed. Through the
    /// standard child runner: a simulator or phone that stops answering is ended after 10 s (it had no limit),
    /// and a clipboard past 16 MiB is not text worth carrying.
    nonisolated private static func run(_ arguments: [String], input: Data?, tool: String = "/usr/bin/xcrun") async -> Data? {
        // A UTF-8 locale, or simctl pbcopy turns "café" into "caf√©" (DeviceToolEnvironment).
        let environment = DeviceToolEnvironment.utf8(ProcessInfo.processInfo.environment)
        guard let outcome = try? await NativeChild.run(.init(URL(fileURLWithPath: tool).path, arguments, environment: environment, errors: .discard), input: input,
                                                       timeoutMilliseconds: 10_000, outputLimit: 16 << 20) else { return nil }
        return outcome.succeeded ? outcome.output : nil
    }
}
