import AppKit

/// MAC-NEXT-15b (Asad: his clipboard is never read or written by a tool). An iOS Simulator takes long or non-US text
/// only through its own pasteboard (`simctl pbcopy`, then ⌘V): the simulator helper types US keys only, and Apple
/// offers no other way in. When Apple's Simulator app is running with Edit > Automatically Sync Pasteboard on (its
/// default), it copies the simulator's pasteboard to the Mac's, so that path would put an AI's text on HIS clipboard.
/// That path is then refused (short US-keyboard text still goes key by key).
/// MAC-NEXT-15c: refused by DEFAULT. Only the person's own typing, explicitly marked (`typingForPerson`), may use it:
/// any other route into the simulator's typing, today's or a later one, is safe without remembering to mark it.
public enum BackendSimulatorPasteboard {
    /// Set only around the person's own typing: the phone panel's `devices:type` from the app's own window
    /// (BackendAppDeviceChannels) and his phone's Devices page (NativeCompositionPhoneDevices). Never set by a tool.
    @TaskLocal public static var typingForPerson = false

    /// Apple's Simulator app is running with its pasteboard sync on. Reads only the running-app list and Simulator's
    /// own setting, never the clipboard.
    @MainActor public static func syncsToTheMac() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").isEmpty else { return false }
        return UserDefaults(suiteName: "com.apple.iphonesimulator")?.object(forKey: "PasteboardAutomaticSync") as? Bool ?? true
    }

    /// Test stand-in for `syncsToTheMac` (nil: ask the Mac).
    nonisolated(unsafe) public static var syncOverride: Bool?

    public static let toolRefusal = "Nothing was typed. This text has characters the simulator can only take through its pasteboard, and Apple's Simulator app is open with Edit > Automatically Sync Pasteboard on, which would put your text on the person's own Mac clipboard. Short text with US-keyboard characters still types key by key; split the text into such pieces, or ask the person to type the rest."
}
