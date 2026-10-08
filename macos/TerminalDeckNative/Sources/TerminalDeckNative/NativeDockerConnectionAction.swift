import SwiftUI

/// Both server views open the existing connection section; they never create
/// another sign-in flow or read credentials to explain an unavailable result.
private struct NativeDockerConnectionActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var nativeServerCheckConnection: (@MainActor () -> Void)? {
        get { self[NativeDockerConnectionActionKey.self] }
        set { self[NativeDockerConnectionActionKey.self] = newValue }
    }
}
