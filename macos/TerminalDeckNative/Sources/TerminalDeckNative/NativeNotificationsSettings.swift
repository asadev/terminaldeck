import AVFoundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Notifications (owner, 15 Nov; DESIGN.md section 4, item 50): ONE group, three rows. "When a session
/// finishes" (a banner; turning it on proves it with one) · "Play a sound" with the sound beside its switch while on ·
/// "Test notification" with its "Send" button (a test banner, and the sound when it is on). Approvals (always on) and the way to the Mac's own
/// notification settings are in the info buttons; what the check found is one line.
struct NativeNotificationsSettings: View {
    @State private var check = NativeNotificationCheck()
    @State private var soundNote: String?
    private let store = NativeSettingsValues.shared
    static let finishInfo = "A banner on this Mac when a session finishes. Approval requests always reach you, here and on your phone; they cannot be turned off. If no banner shows, allow Terminal Deck in the Mac's own notification settings."

    var body: some View {
        let soundOn = store.bool("notifications.onFinishSound")
        DeckSettingsScaffold(title: "Notifications") {
            DeckSettingsGroup {
                // TRUTH-B: shown on the Mac too (it was compiled out, so session banners could not be turned off here).
                DeckSettingsSchemaRow(id: "notifications.onComplete", title: "When a session finishes", info: Self.finishInfo, onSave: saveAndProve)
                DeckSettingsRow("Play a sound") {
                    HStack(spacing: DeckTokens.Spacing.s8) {
                        if soundOn {
                            Picker("Sound", selection: Binding(get: { store.string("notifications.soundName") },
                                set: { store.save(["notifications.soundName": .string($0)]); testSound() })) {
                                Text("Chime").tag("chime"); Text("Blip").tag("blip"); Text("Knock").tag("knock")
                            }
                            .pickerStyle(.menu).fixedSize().labelsHidden()
                        }
                        Toggle("Play a sound", isOn: Binding(get: { soundOn }, set: { store.save(["notifications.onFinishSound": .bool($0)]) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    .disabled(store.loading)
                }
                DeckSettingsRow(SettingsNotifications.testTitle) {
                    Button(check.busy ? SettingsNotifications.askingLabel : SettingsNotifications.testLabel) {
                        check.fire(test: true)
                        if soundOn { testSound() }
                    }
                    .controlSize(.small)
                    .disabled(check.busy)
                }
                if let soundNote { DeckSettingsProblem(text: soundNote) }
                if let state = check.state {
                    DeckSettingsProblem(text: state.text, warn: state.tone != .info)
                    if state.offerSettings && check.canOpenSettings {
                        DeckSettingsButtonRow(title: "Open notification settings") { check.openSettings() }
                    }
                }
            }
        }
        .onAppear { store.start(); check.readSupport() }
    }

    private func saveAndProve(_ patch: [String: CodingAIJSON]) {
        store.save(patch)
        if SettingsNotifications.turnedOnABanner(patch) { check.fire(test: false) }
    }

    private func testSound() {
        let name = store.string("notifications.soundName")
        let id = SettingsSound.isSoundId(name) ? name : "chime"
        soundNote = NativeSettingsSoundPlayer.shared.play(id) ? nil : SettingsNotifications.noAudio
    }
}

/// `useNotificationCheck`: show a banner through the engine, then ask the OS
/// whether it recorded one.
@MainActor
@Observable
final class NativeNotificationCheck {
    private(set) var canOpenSettings = false
    private(set) var state: SettingsNotifications.CheckState?
    private(set) var busy = false

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func readSupport() {
        Task {
            guard let raw = try? await call("notifications:support") else { return }
            canOpenSettings = SettingsNotifications.support(raw).settingsPane
        }
    }

    func fire(test: Bool) {
        let since = Date().timeIntervalSince1970 * 1000
        let banner = SettingsNotifications.banner(test: test)
        let id = "settings-\(UUID().uuidString)"
        Task {
            do {
                _ = try await call("native-shell:notify", [["id": id, "title": banner.title, "body": banner.body]])
            } catch {
                state = .init(text: CodingAIErrorText.from(error, fallback: SettingsNotifications.refused), tone: .error, offerSettings: true)
                return
            }
            busy = true
            state = SettingsNotifications.checking
            let raw = (try? await call("notifications:delivery", [since])) ?? .null
            _ = try? await call("native-shell:notify-close", [id])
            busy = false
            let report = SettingsNotifications.report(raw)
            state = SettingsNotifications.deliveryCopy(verdict: report.verdict, at: report.at, test: test)
        }
    }

    func openSettings() {
        Task {
            do {
                _ = try await call("notifications:open-settings")
            } catch {
                state = .init(text: SettingsNotifications.wouldNotOpen, tone: .error, offerSettings: false)
            }
        }
    }
}

/// Plays the synthesised finish sounds (`notification-sound.ts`).
@MainActor
final class NativeSettingsSoundPlayer {
    static let shared = NativeSettingsSoundPlayer()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// False when there is no audio output to play it on.
    func play(_ id: String) -> Bool {
        let rate = 44_100.0
        let samples = SettingsSound.samples(id, sampleRate: rate)
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        let engine = self.engine ?? AVAudioEngine()
        let player = self.player ?? AVAudioPlayerNode()
        if self.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.player = player
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return false
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        return true
    }
}
