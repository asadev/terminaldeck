import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The Safari graph's side of BackendCompositionBrowserChannels: its one
/// binding map, read when a channel needs it (the browser graph starts after
/// the channel areas are assembled, and refuses until it has).
enum NativeCompositionBrowserChannels {
    static func bindings() -> BackendCompositionBrowserChannels.Bindings {
        { try await MainActor.run { try NativeCompositionRoot.shared.browserForComposition().bindings } }
    }
}
