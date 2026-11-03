import Foundation
import TerminalDeckNativeCore

/// What the profile (and anything else in the app) calls about the flow:
/// `await DeckMemoryFlow.status()`, `runHelperNow`, `runTidyNow`, `addCorrection`.
/// Before the flow has started every call answers plainly instead of failing.
public enum DeckMemoryFlow {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var engine: DeckMemoryFlowEngine?
    }
    private static let box = Box()

    public static var engine: DeckMemoryFlowEngine? { box.lock.withLock { box.engine } }
    public static func install(_ engine: DeckMemoryFlowEngine?) { box.lock.withLock { box.engine = engine } }

    /// The helper's settings, its waiting line and its last runs; the tidy-up's state.
    public static func status() async -> DeckMemoryFlowStatus {
        guard let engine else { return DeckMemoryFlowStatus(problem: "The memory flow is still starting.") }
        return await engine.status()
    }
    /// Reads what this owner's conversations said since the helper last looked, now. One plain sentence back.
    public static func runHelperNow(ownerKey: String) async -> String {
        guard let engine else { return "The memory flow is still starting. Try again in a moment." }
        return await engine.runHelperNow(ownerKey: ownerKey)
    }
    /// Runs this owner's tidy-up now (backup first, index refresh after). One plain sentence back.
    public static func runTidyNow(ownerKey: String) async -> String {
        guard let engine else { return "The memory flow is still starting. Try again in a moment." }
        return await engine.runTidyNow(ownerKey: ownerKey)
    }
    /// "You should have noted X": added to the checklist. False when it was already there.
    @discardableResult
    public static func addCorrection(_ text: String) async -> Bool {
        guard let engine else { DeckMemoryFlowInbox.correction(text); return true }
        return await engine.addCorrection(text)
    }
    /// Call after changing a helper or tidy-up setting, so it applies at once.
    public static func settingsChanged() async { await engine?.settingsChanged() }
}
