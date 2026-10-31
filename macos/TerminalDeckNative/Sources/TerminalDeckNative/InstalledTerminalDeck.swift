import Foundation
import TerminalDeckNativeCore

/// This app's own engine configuration: its pages come from its own bundle.
@MainActor
enum InstalledTerminalDeck {
    /// Where the engine comes from right now.
    static func configuration() -> EngineConfiguration {
        let standalone = Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true
        return EngineConfiguration.resolve(
            environment: ProcessInfo.processInfo.environment,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            resources: standalone ? Bundle.main.resourceURL : nil)
    }
}
