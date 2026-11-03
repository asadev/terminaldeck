import Foundation

/// Where this Mac's keyboard focus may be asked (1 Nov hotfix, install #18 crash): an Accessibility question about
/// ANOTHER app goes to that app over IPC and may wait, so it is asked off the main thread; a question about Terminal
/// Deck itself is answered inside this process by AppKit, which walks our own views — those are main-thread only, so
/// it must be asked on the main thread (asked from a background queue it trapped in `DeviceScreenNSView`).
public enum MacFocusProbe {
    /// True when the app in front is this process (or unknown): ask on the main thread.
    public static func mustAskOnMain(focusedPID: Int32, ownPID: Int32) -> Bool { focusedPID <= 0 || focusedPID == ownPID }
}
