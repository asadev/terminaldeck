import Foundation
import TerminalDeckNativeCore

/// Whether phones may view and control this Mac's screen (round 3, #24; Asad, 1 Nov: no "Controlled from iPhone" card
/// "at all completely" — one ON/OFF switch in Devices → Device access → General instead (the Settings window has no Devices page)). On: it works silently. Off: a phone that
/// tries is told why, in `refusal`. The phones' own access levels apply on top either way.
///
/// Stored with every other option, in this copy's `settings.json` in its data folder, under `key`. The `remote.` prefix
/// makes it a protected setting: no AI tool may turn it on, and Advanced → Start over keeps it. The backend stays that
/// file's one writer (`settings:set`); this type only reads it once, then keeps the answer behind a lock so the phone
/// feature can ask from any thread.
enum NativeMacScreenSetting {
    static let key = "remote.macScreenAllowed"
    static let title = "Phones may view and control this Mac's screen"
    static let detail = "Off: a phone that tries is told why. Your phones' access levels still apply."
    static let refusal = "This Mac does not let phones view or control its screen. Turn it on at the Mac: Devices → Device access → General → Phones may view and control this Mac's screen."

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Bool?

    /// Called after `set`, with the new value (the phone feature lets every watching phone go when it is turned off).
    nonisolated(unsafe) static var changed: (@Sendable (Bool) -> Void)?

    /// The current choice; true until the person turns it off. Safe from any thread.
    nonisolated static var allowed: Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let stored = storedValue() ?? true
        cached = stored
        return stored
    }

    /// The switch: takes effect at once (before the save finishes), tells `changed`, and saves through the settings
    /// store so the choice survives a restart.
    @MainActor static func set(_ on: Bool) {
        lock.lock(); cached = on; lock.unlock()
        changed?(on)
        Task { @MainActor in
            do { _ = try await EngineBridge.shared.invoke("settings:set", [[key: on]]) }
            catch { NSLog("Terminal Deck: could not save \(key): \(error.localizedDescription)") }
        }
    }

    /// The saved value in this copy's settings file, or nil when it was never set (or the file cannot be read).
    nonisolated private static func storedValue() -> Bool? {
        let standalone = Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let root = EngineConfiguration.resolve(environment: ProcessInfo.processInfo.environment, applicationSupport: support,
                                               resources: standalone ? Bundle.main.resourceURL : nil).dataRoot
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let values = raw["values"] as? [String: Any] ?? raw
        return values[key] as? Bool
    }
}
