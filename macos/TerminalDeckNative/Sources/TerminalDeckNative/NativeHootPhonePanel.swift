import SwiftUI
import TerminalDeckNativeCore

/// Hoot owns one phone panel, the same NativeUIGSessionSimulatorController/Panel a terminal
/// session opens from its phone icon ("Choose a device", start/open, live phone, tools).
@MainActor final class NativeHootSimulatorOwner: NativeUIGSimulatorOwner {
    static let shared = NativeHootSimulatorOwner()
    let sessionId = "hoot"
    var ended: Bool { false }
    var removed: Bool { false }
    var panel: NativeUIGSessionSimulatorController { NativeUIGSessionSimulatorStore.shared.entry(self) }
}
