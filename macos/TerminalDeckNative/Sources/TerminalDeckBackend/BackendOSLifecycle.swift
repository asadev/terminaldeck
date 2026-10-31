import Foundation

/// Live push channel names the native owners subscribe to.
public enum BackendOSLivePush {
    public static let prefsChanged = "prefs:changed"
    public static let settingsChanged = "settings:changed"
    public static let sessionRemoved = "session:removed"
    public static let sessionRenamed = "session:renamed"
}
