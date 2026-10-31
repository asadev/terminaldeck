import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// TRUTH-B (12 Oct, SETTINGS-TRUTH.md): Settings › Notifications › Sound did nothing on the Mac. Its only player was the
// hidden web page, and the switch it waited for ("Play a sound when a session finishes") was not on the Mac page. Now
// the app itself plays the chosen sound when a session finishes and the switch is on; the hidden page's own copy is
// switched off (WebBridge), so it is never heard twice.

enum NativeFinishSound {
    /// Pushed events only: one listener on session status for the app's lifetime.
    nonisolated(unsafe) private static var subscription: NativeRPCSubscription?
    nonisolated(unsafe) private static var lastPlayed = Date.distantPast

    static func start(root: BackendCompositionRoot) async {
        guard subscription == nil else { return }
        let settings = root.settings, state = root.state
        subscription = try? await root.registry.subscribe("session:status", ownerID: BackendCompositionRoot.appOwnerID) { event in
            guard event.arguments.count >= 2, event.arguments[1].string == "completed" else { return }
            let raw = await settings.get(), values = raw["values"].fields != nil ? raw["values"] : raw
            let merged = SettingsSchema.values(settings: CodingAIJSON(values.foundation), preferences: CodingAIJSON(await state.getPreferences().foundation))
            guard SettingsSchema.bool(merged, "notifications.onFinishSound") else { return }
            let chosen = SettingsSchema.string(merged, "notifications.soundName")
            let id = SettingsSound.isSoundId(chosen) ? chosen : "chime"
            await MainActor.run {
                // Several sessions finishing together make one sound.
                guard Date().timeIntervalSince(lastPlayed) > 1.5 else { return }
                lastPlayed = Date()
                _ = NativeSettingsSoundPlayer.shared.play(id)
            }
        }
    }
}
